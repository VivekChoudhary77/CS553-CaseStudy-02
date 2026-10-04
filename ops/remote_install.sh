#!/usr/bin/env bash
# Used Opus 5.5 with High Effort, for the installer that runs on the VM.
# prompt: Write the installer that runs on the VM: install a pinned uv, clone or update the GitHub
#   repo, run uv sync --locked, install the settings file with mode 600, download the local model,
#   write a systemd unit with Restart=always and a memory cap, restart only if something changed,
#   and wait until the app answers.
# remote_install.sh — install or update Prompt Enhancer ON THE VM. Idempotent.
#
# Normally streamed by ops/deploy.sh:  ssh vm 'bash -s -- <repo_url> <ref> <uv_version>'
# deploy.sh first uploads the app's env file to ~/.config/prompt-enhancer/app.env.incoming.
#
# Steps: base tools -> pinned uv -> clone/update repo -> uv sync --locked -> env file ->
# model download -> systemd unit -> restart only if something changed -> wait until healthy.
#
# Exit codes: 0 healthy, 3 missing input (no env file), 6 install or health check failed.

set -Eeuo pipefail

log() { printf '%s [%s] vm: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
trap 'log ERROR "line ${LINENO}: command failed (exit $?): ${BASH_COMMAND}"' ERR
fail() { log ERROR "$2"; exit "$1"; }

REPO_URL="${1:?usage: remote_install.sh <repo_url> <ref> <uv_version>}"
REF="${2:?missing git ref}"
UV_VERSION="${3:?missing uv version}"

APP_DIR="${APP_DIR:-$HOME/app}"
CONF_DIR="$HOME/.config/prompt-enhancer"
ENV_FILE="$CONF_DIR/app.env"
SERVICE="prompt-enhancer"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/$SERVICE.service}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:7860/}"
HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-180}"
HEALTH_INTERVAL_S="${HEALTH_INTERVAL_S:-3}"
UV="$HOME/.local/bin/uv"
changes=()

# Guard the one destructive step (re-cloning over a broken checkout).
[[ "$APP_DIR" == "$HOME"/?* ]] || fail 3 "APP_DIR must be inside \$HOME (got '$APP_DIR')"

# ---- a. base tools -------------------------------------------------------------------
missing=()
for tool in git curl; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if ((${#missing[@]})); then
  log INFO "installing base packages (missing: ${missing[*]})"
  sudo apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates
fi

# ---- b. uv (pinned) ------------------------------------------------------------------
if [[ "$("$UV" --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]]; then
  log INFO "installing uv $UV_VERSION"
  curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" | env UV_NO_MODIFY_PATH=1 sh >/dev/null
  [[ -x "$UV" ]] || fail 6 "uv install did not produce $UV"
fi

# ---- c. code -----------------------------------------------------------------------------
old_commit=""
if [[ -d "$APP_DIR/.git" ]]; then
  old_commit="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || true)"
  git -C "$APP_DIR" remote set-url origin "$REPO_URL"
  git -C "$APP_DIR" fetch --quiet --depth 1 origin "$REF"
  git -C "$APP_DIR" reset --quiet --hard FETCH_HEAD
  git -C "$APP_DIR" clean -fdq # untracked files only; .venv is git-ignored and kept
else
  log INFO "cloning $REPO_URL ($REF) into $APP_DIR"
  rm -rf "$APP_DIR" # leftovers of an interrupted clone
  git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$APP_DIR"
fi
new_commit="$(git -C "$APP_DIR" rev-parse HEAD)"
[[ "$old_commit" == "$new_commit" ]] || changes+=(code)
log INFO "code at commit ${new_commit:0:7}"

# ---- d. Python environment (exact versions from uv.lock; CPU-only torch) ----------------------
(cd "$APP_DIR" && "$UV" sync --locked --no-dev --quiet)
[[ -x "$APP_DIR/.venv/bin/prompt-enhancer" ]] || fail 6 "uv sync did not create the prompt-enhancer entry point"

# ---- e. secrets: kept OUTSIDE the checkout so git reset/clean never touch them ---------------------
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
if [[ -s "$ENV_FILE.incoming" ]]; then
  chmod 600 "$ENV_FILE.incoming"
  if cmp -s "$ENV_FILE.incoming" "$ENV_FILE"; then
    rm -f "$ENV_FILE.incoming"
  else
    mv "$ENV_FILE.incoming" "$ENV_FILE"
    changes+=(env)
  fi
fi
[[ -s "$ENV_FILE" ]] || fail 3 "no app env file at $ENV_FILE (deploy.sh uploads it)"
chmod 600 "$ENV_FILE"

# ---- f. local model (cached in ~/.cache/huggingface; a re-run only verifies it) ------------
model_id="$(sed -n 's/^LOCAL_MODEL_ID=//p' "$ENV_FILE" | tail -n 1 | tr -d "\"'\r")"
log INFO "ensuring local model ${model_id:-<default>} is downloaded"
(cd "$APP_DIR" && LOCAL_MODEL_ID="$model_id" "$UV" run --no-sync --quiet python scripts/download_model.py >/dev/null)

# ---- g. systemd unit -------------------------------------------------------------------------
unit_tmp="$(mktemp)"
trap 'rm -f "$unit_tmp"' EXIT
cat >"$unit_tmp" <<EOF
# Installed by ops/remote_install.sh — do not edit on the VM; change the repo and redeploy.
[Unit]
Description=Prompt Enhancer (CS553 group 25)
After=network-online.target
Wants=network-online.target
# Never stop retrying: the watchdog expects systemd to keep the app alive.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
Environment=HF_HUB_OFFLINE=1
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/.venv/bin/prompt-enhancer
Restart=always
RestartSec=5
# Cap the app so it can never starve sshd (that would lock the watchdog out). ~2.5 GB needed.
MemoryMax=3200M

[Install]
WantedBy=multi-user.target
EOF
if ! cmp -s "$unit_tmp" "$UNIT_PATH"; then
  sudo install -m 644 "$unit_tmp" "$UNIT_PATH"
  sudo systemctl daemon-reload
  changes+=(unit)
fi
sudo systemctl enable --quiet "$SERVICE"

# ---- h. restart only when needed ---------------------------------------------------------------
if ((${#changes[@]})) || ! systemctl is-active --quiet "$SERVICE"; then
  log INFO "restarting $SERVICE (changes: ${changes[*]:-none; service was not running})"
  sudo systemctl restart "$SERVICE"
else
  log INFO "no changes; $SERVICE already running"
fi

# ---- i. wait until the app answers ---------------------------------------------------------------
deadline=$((SECONDS + HEALTH_TIMEOUT_S))
until curl -fsS -m 5 -o /dev/null "$HEALTH_URL" 2>/dev/null; do
  if ((SECONDS >= deadline)); then
    log ERROR "$SERVICE not healthy at $HEALTH_URL after ${HEALTH_TIMEOUT_S}s; recent log:"
    sudo journalctl -u "$SERVICE" -n 30 --no-pager || true
    exit 6
  fi
  sleep "$HEALTH_INTERVAL_S"
done
log INFO "healthy: $SERVICE answering at $HEALTH_URL (commit ${new_commit:0:7}, changes: ${changes[*]:-none})"
