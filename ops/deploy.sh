#!/usr/bin/env bash
# deploy.sh — install or update Prompt Enhancer on the VM (CS553 group 25). Idempotent.
#
# Runs on linux.wpi.edu (by hand, or from relock.sh after a relock / when the app is
# missing), or from the laptop with a different CONFIG. Two SSH calls:
#   1. upload the app env file (API keys) over stdin -> VM ~/.config/prompt-enhancer/app.env.incoming
#   2. stream ops/remote_install.sh over stdin -> `bash -s -- <repo> <ref> <uv_version>` on the VM
# Secrets travel only over SSH stdin: never in git, never on a command line.
#
# Exit codes: 0 deployed and healthy, 3 bad config (VM untouched), 6 remote install or
# health check failed, 7 another watchdog/deploy run holds the lock.

set -Eeuo pipefail

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
trap 'log ERROR "line ${LINENO}: command failed (exit $?): ${BASH_COMMAND}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- configuration (shared with relock.sh) --------------------------------------------------

CONFIG="${CONFIG:-$HOME/.cs553/relock.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null  # path is only known at runtime
  source "$CONFIG"
fi

HOST="${HOST:-paffenroth-23.dyn.wpi.edu}"
PORT="${PORT:-22025}" # SSH port of the VM (the app's own port lives in APP_ENV_FILE)
VM_USER="${VM_USER:-student-admin}"
MY_KEY="${MY_KEY:-}"
LOCK_FILE="${LOCK_FILE:-$HOME/.cs553/relock.lock}"
APP_ENV_FILE="${APP_ENV_FILE:-$HOME/.cs553/app.env}"
REPO_URL="${REPO_URL:-https://github.com/VivekChoudhary77/CS553-CaseStudy-02.git}"
REPO_REF="${REPO_REF:-main}"
UV_VERSION="${UV_VERSION:-0.11.32}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-$SCRIPT_DIR/remote_install.sh}"
LOCK_WAIT_S="${LOCK_WAIT_S:-120}"

bad_config() { log ERROR "bad config: $1"; exit 3; }

env_value() { sed -n "s/^$1=//p" "$APP_ENV_FILE" | tail -n 1 | tr -d "\"'\r[:space:]"; }

[[ -n "$MY_KEY" && -r "$MY_KEY" ]] || bad_config "MY_KEY is unset or unreadable"
[[ -r "$REMOTE_SCRIPT" ]] || bad_config "remote script not found: $REMOTE_SCRIPT"
[[ -s "$APP_ENV_FILE" ]] || bad_config "APP_ENV_FILE ($APP_ENV_FILE) is missing or empty"
if grep -q 'PRIVATE KEY' "$APP_ENV_FILE"; then
  bad_config "APP_ENV_FILE contains a private key; it must hold only app settings"
fi
[[ -n "$(env_value GEMINI_API_KEY)$(env_value OPENROUTER_API_KEY)" ]] ||
  bad_config "APP_ENV_FILE sets neither GEMINI_API_KEY nor OPENROUTER_API_KEY"
app_host="$(env_value HOST)"
[[ -z "$app_host" || "$app_host" == 0.0.0.0 ]] ||
  bad_config "APP_ENV_FILE has HOST=$app_host; the VM needs HOST=0.0.0.0"
app_port="$(env_value PORT)"
[[ -z "$app_port" || "$app_port" == 7860 ]] ||
  bad_config "APP_ENV_FILE has PORT=$app_port; the VM's public port 8025 forwards to 7860"
[[ "$REPO_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || bad_config "REPO_REF has unexpected characters"
[[ "$UV_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || bad_config "UV_VERSION must look like 0.11.32"

# ---- single instance, shared with relock.sh ----------------------------------------------------
# relock.sh already holds the lock when it runs us (it sets CS553_LOCK_HELD=1). When run by
# hand, take the same lock so the watchdog doesn't "repair" the app halfway through a deploy.
if [[ "${CS553_LOCK_HELD:-}" != 1 ]]; then
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -w "$LOCK_WAIT_S" 9; then
    log ERROR "another watchdog/deploy run still holds $LOCK_FILE after ${LOCK_WAIT_S}s"
    exit 7
  fi
fi

# Same host-key trade-off as relock.sh (the VM's host key changes on every rebuild; see
# ops/README.md). ServerAliveInterval keeps the long first install (~5 min) from idling out.
SSH_OPTS=(
  -p "$PORT"
  -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
)
vm() { ssh "${SSH_OPTS[@]}" -i "$MY_KEY" "$VM_USER@$HOST" "$@"; }

REMOTE_UPLOAD_ENV='umask 077; mkdir -p ~/.config/prompt-enhancer && cat > ~/.config/prompt-enhancer/app.env.incoming'

log INFO "deploy: uploading app settings to $VM_USER@$HOST"
if ! vm "$REMOTE_UPLOAD_ENV" <"$APP_ENV_FILE"; then
  log ERROR "deploy: could not upload app settings (VM unreachable?)"
  exit 6
fi

log INFO "deploy: installing $REPO_URL ($REPO_REF) on the VM"
remote_args="$(printf '%q ' "$REPO_URL" "$REPO_REF" "$UV_VERSION")"
if vm "bash -s -- $remote_args" <"$REMOTE_SCRIPT"; then
  log INFO "deploy: done; app healthy on the VM"
else
  rc=$?
  log ERROR "deploy: remote install failed (exit $rc)"
  exit 6
fi
