#!/usr/bin/env bash
# Local tests for ops/remote_install.sh and ops/deploy.sh — no network, no VM, no sudo.
#
# remote_install.sh runs for real in a temp HOME, with fake sudo/systemctl/apt-get/git/uv/
# curl/journalctl first on PATH (they record calls in $SIM/calls.log and simulate state).
# deploy.sh runs against a fake ssh that records its argv and stdin.
#
# Usage: bash tests/test_deploy.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/ops/remote_install.sh"
DEPLOY="$ROOT/ops/deploy.sh"
T="$(mktemp -d)"
trap 'kill "${LOCK_HOLDER:-}" 2>/dev/null; rm -rf "$T"' EXIT

FAKEBIN="$T/bin" SIM="$T/sim" HOMEDIR="$T/home"
mkdir -p "$FAKEBIN"
REPO=https://github.com/example/repo.git

# ---- fakes ------------------------------------------------------------------------------------

cat >"$FAKEBIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$SIM/calls.log"
exec "$@"
EOF

cat >"$FAKEBIN/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >>"$SIM/calls.log"
EOF

cat >"$FAKEBIN/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "fake journal: Traceback (most recent call last)"
EOF

cat >"$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SIM/calls.log"
case "$1" in
  is-active) [[ "$(cat "$SIM/svc_state" 2>/dev/null)" == active ]] ;;
  restart) echo active >"$SIM/svc_state" ;;
  *) : ;;
esac
EOF

cat >"$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >>"$SIM/calls.log"
dir=""
if [[ "$1" == -C ]]; then dir="$2"; shift 2; fi
case "$1" in
  clone) dest="${*: -1}"; mkdir -p "$dest/.git"; cp "$SIM/remote_commit" "$dest/.git/HEAD_commit" ;;
  rev-parse) cat "$dir/.git/HEAD_commit" ;;
  reset) cp "$SIM/remote_commit" "$dir/.git/HEAD_commit" ;;
  *) : ;;
esac
EOF

cat >"$FAKEBIN/uv.src" <<'EOF'
#!/usr/bin/env bash
echo "uv $* LOCAL_MODEL_ID=${LOCAL_MODEL_ID:-}" >>"$SIM/calls.log"
case "$1" in
  --version) echo "uv 0.11.32" ;;
  sync) mkdir -p .venv/bin && printf '#!/bin/sh\n' >.venv/bin/prompt-enhancer && chmod +x .venv/bin/prompt-enhancer ;;
  *) : ;;
esac
EOF

cat >"$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$SIM/calls.log"
url="${*: -1}"
case "$url" in
  https://astral.sh/*) # the uv installer, piped into sh
    echo "mkdir -p \"\$HOME/.local/bin\" && cp '$FAKEBIN_DIR/uv.src' \"\$HOME/.local/bin/uv\" && chmod +x \"\$HOME/.local/bin/uv\"" ;;
  http://127.0.0.1:7860/) [[ "$(cat "$SIM/svc_state" 2>/dev/null)" == active && ! -e "$SIM/unhealthy" ]] ;;
  *) exit 7 ;;
esac
EOF

cat >"$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "$SIM/ssh_n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$SIM/ssh_n"
printf '%s\n' "$*" >"$SIM/ssh_args_$n"
cat >"$SIM/ssh_stdin_$n"
if [[ "${*: -1}" == *'bash -s'* && -e "$SIM/remote_fails" ]]; then exit 6; fi
exit 0
EOF
chmod +x "$FAKEBIN"/*

# ---- harness ---------------------------------------------------------------------------------

PASSED=0 FAILED=0 RC=0
ENV_DIR="$HOMEDIR/.config/prompt-enhancer"
UNIT="$T/etc/prompt-enhancer.service"

fresh_vm() { # empty home, uv already installed, one commit on the remote
  rm -rf "${SIM:?}" "${HOMEDIR:?}" "${T:?}/etc"
  mkdir -p "$SIM" "$HOMEDIR/.local/bin" "$T/etc"
  cp "$FAKEBIN/uv.src" "$HOMEDIR/.local/bin/uv"
  echo commit-aaaaaaa >"$SIM/remote_commit"
}

incoming() { # incoming <env content>: what deploy.sh would have uploaded
  mkdir -p "$ENV_DIR"
  printf '%s\n' "$1" >"$ENV_DIR/app.env.incoming"
}

run_install() {
  : >"$SIM/calls.log"
  env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$HOMEDIR" SIM="$SIM" FAKEBIN_DIR="$FAKEBIN" \
    UNIT_PATH="$UNIT" HEALTH_TIMEOUT_S=1 HEALTH_INTERVAL_S=0 \
    bash "$INSTALL" "$REPO" main 0.11.32 >"$T/out.log" 2>&1
  RC=$?
}

check() {
  local name="$1"
  shift
  if "$@"; then return 0; fi
  echo "    [case $name] assertion failed: $*"
  return 1
}

finish_case() {
  if [[ "$2" -eq 0 ]]; then
    echo "PASS  $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL  $1   (exit $RC)"
    sed 's/^/    | /' "$T/out.log"
    FAILED=$((FAILED + 1))
  fi
}

rc_is() { [[ "$RC" -eq "$1" ]]; }
called() { grep -q -- "$1" "$SIM/calls.log"; }
not_called() { ! grep -q -- "$1" "$SIM/calls.log"; }
logged() { grep -q -- "$1" "$T/out.log"; }
unit_has() { grep -qxF -- "$1" "$UNIT"; }
mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }

ENV1='GEMINI_API_KEY=test-gemini
LOCAL_MODEL_ID=Qwen/Test-0.5B
HOST=0.0.0.0'

# ---- remote_install.sh ------------------------------------------------------------------------

# D1. fresh VM -> clone, sync, env 600, unit installed/enabled, started, healthy
fresh_vm
incoming "$ENV1"
run_install
ok=0
check D1 rc_is 0 || ok=1
check D1 test -d "$HOMEDIR/app/.git" || ok=1
check D1 called "git clone --quiet --depth 1 --branch main $REPO" || ok=1
check D1 called "uv sync --locked --no-dev" || ok=1
check D1 called "LOCAL_MODEL_ID=Qwen/Test-0.5B" || ok=1
check D1 mode_is "$ENV_DIR/app.env" 600 || ok=1
check D1 mode_is "$ENV_DIR" 700 || ok=1
check D1 test ! -e "$ENV_DIR/app.env.incoming" || ok=1
check D1 unit_has "Restart=always" || ok=1
check D1 unit_has "MemoryMax=3200M" || ok=1
check D1 unit_has "EnvironmentFile=$ENV_DIR/app.env" || ok=1
check D1 unit_has "ExecStart=$HOMEDIR/app/.venv/bin/prompt-enhancer" || ok=1
check D1 unit_has "WorkingDirectory=$HOMEDIR/app" || ok=1
check D1 called "systemctl daemon-reload" || ok=1
check D1 called "systemctl enable --quiet prompt-enhancer" || ok=1
check D1 called "systemctl restart prompt-enhancer" || ok=1
check D1 logged "healthy" || ok=1
finish_case "D1 fresh VM -> installed, env 600, unit enabled, started, healthy" $ok

# D2. same deploy again -> no restart, no daemon-reload (idempotent)
incoming "$ENV1"
run_install
ok=0
check D2 rc_is 0 || ok=1
check D2 not_called "systemctl restart" || ok=1
check D2 not_called "daemon-reload" || ok=1
check D2 not_called "git clone" || ok=1
check D2 logged "no changes" || ok=1
check D2 test ! -e "$ENV_DIR/app.env.incoming" || ok=1
finish_case "D2 identical re-run -> no restart, no reload (idempotent)" $ok

# D3. only the env changed -> restart
incoming "$ENV1
OPENROUTER_API_KEY=test-or"
run_install
ok=0
check D3 rc_is 0 || ok=1
check D3 called "systemctl restart" || ok=1
check D3 logged "changes: env" || ok=1
check D3 grep -q OPENROUTER_API_KEY "$ENV_DIR/app.env" || ok=1
finish_case "D3 env changed -> restart" $ok

# D4. new commit pushed -> fetch/reset + restart
echo commit-bbbbbbb >"$SIM/remote_commit"
run_install
ok=0
check D4 rc_is 0 || ok=1
check D4 called "reset --quiet --hard FETCH_HEAD" || ok=1
check D4 called "systemctl restart" || ok=1
check D4 logged "changes: code" || ok=1
finish_case "D4 new commit -> updated and restarted" $ok

# D5. nothing changed but the service is stopped -> start it
echo inactive >"$SIM/svc_state"
run_install
ok=0
check D5 rc_is 0 || ok=1
check D5 called "systemctl restart" || ok=1
check D5 logged "service was not running" || ok=1
finish_case "D5 no changes, service stopped -> started" $ok

# D6. app never becomes healthy -> exit 6 with the journal tail
touch "$SIM/unhealthy"
run_install
ok=0
check D6 rc_is 6 || ok=1
check D6 logged "not healthy" || ok=1
check D6 logged "fake journal" || ok=1
rm "$SIM/unhealthy"
finish_case "D6 never healthy -> exit 6 + journal tail" $ok

# D7. no env file at all -> exit 3 before touching systemd
fresh_vm
run_install
ok=0
check D7 rc_is 3 || ok=1
check D7 not_called "systemctl" || ok=1
finish_case "D7 no app env uploaded -> exit 3, systemd untouched" $ok

# D8. uv missing -> pinned installer fetched and used
fresh_vm
rm "$HOMEDIR/.local/bin/uv"
incoming "$ENV1"
run_install
ok=0
check D8 rc_is 0 || ok=1
check D8 called "curl -LsSf https://astral.sh/uv/0.11.32/install.sh" || ok=1
check D8 test -x "$HOMEDIR/.local/bin/uv" || ok=1
finish_case "D8 uv missing -> pinned version installed" $ok

# D9. a stray non-git ~/app (interrupted clone) -> replaced by a clean clone
fresh_vm
mkdir -p "$HOMEDIR/app" && touch "$HOMEDIR/app/partial"
incoming "$ENV1"
run_install
ok=0
check D9 rc_is 0 || ok=1
check D9 test ! -e "$HOMEDIR/app/partial" || ok=1
check D9 test -d "$HOMEDIR/app/.git" || ok=1
finish_case "D9 broken checkout -> re-cloned" $ok

# ---- deploy.sh ----------------------------------------------------------------------------------

KEY="$T/watchdog_key"
echo not-a-real-key >"$KEY"
APP_ENV="$T/app.env"
SECRET=sk-test-SECRET-value-123

reset_sim() { rm -rf "$SIM" && mkdir -p "$SIM" "$HOMEDIR/.cs553"; }
run_deploy() { # extra VAR=value args override the defaults (call reset_sim first)
  env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$HOMEDIR" SIM="$SIM" CONFIG="$T/no-such-config" \
    MY_KEY="$KEY" APP_ENV_FILE="$APP_ENV" LOCK_WAIT_S=1 \
    "$@" bash "$DEPLOY" >"$T/out.log" 2>&1
  RC=$?
}
ssh_calls() { cat "$SIM/ssh_n" 2>/dev/null || echo 0; }

# E1. valid env -> 2 ssh calls; env and installer only ever on stdin, never in argv
printf 'OPENROUTER_API_KEY=%s\nHOST=0.0.0.0\nPORT=7860\n' "$SECRET" >"$APP_ENV"
reset_sim
run_deploy
ok=0
check E1 rc_is 0 || ok=1
check E1 test "$(ssh_calls)" -eq 2 || ok=1
check E1 cmp -s "$SIM/ssh_stdin_1" "$APP_ENV" || ok=1
check E1 cmp -s "$SIM/ssh_stdin_2" "$ROOT/ops/remote_install.sh" || ok=1
check E1 grep -q 'app.env.incoming' "$SIM/ssh_args_1" || ok=1
check E1 grep -q "bash -s -- https://github.com/VivekChoudhary77/CS553-CaseStudy-02.git main 0.11.32" "$SIM/ssh_args_2" || ok=1
check E1 bash -c "! grep -q '$SECRET' '$SIM'/ssh_args_*" || ok=1
check E1 grep -q 'StrictHostKeyChecking=no' "$SIM/ssh_args_1" || ok=1
finish_case "E1 valid -> env + installer sent over stdin only, correct remote args" $ok

# E2-E6. bad config -> exit 3 and the VM is never contacted
bad_case() { # bad_case <id> <label> <env content>
  printf '%s\n' "$3" >"$APP_ENV"
  reset_sim
  run_deploy
  ok=0
  check "$1" rc_is 3 || ok=1
  check "$1" test "$(ssh_calls)" -eq 0 || ok=1
  finish_case "$1 $2 -> exit 3, VM untouched" $ok
}
bad_case E2 "empty app env" ""
FAKE_KEY_HEADER="-----BEGIN OPENSSH PRIVATE"" KEY-----" # split so secret scanners don't flag the test
bad_case E3 "app env contains a private key" "GEMINI_API_KEY=x
$FAKE_KEY_HEADER"
bad_case E4 "no API key at all" "GEMINI_MODEL=gemini-2.5-flash
HOST=0.0.0.0"
bad_case E5 "HOST=127.0.0.1" "GEMINI_API_KEY=x
HOST=127.0.0.1"
bad_case E6 "PORT not 7860" "GEMINI_API_KEY=x
PORT=8000"

# E7. remote install fails -> exit 6
printf 'GEMINI_API_KEY=%s\n' "$SECRET" >"$APP_ENV"
reset_sim
touch "$SIM/remote_fails"
run_deploy
ok=0
check E7 rc_is 6 || ok=1
check E7 logged "remote install failed" || ok=1
finish_case "E7 remote install fails -> exit 6" $ok

# E8. watchdog lock held -> wait, then exit 7 without touching the VM; unless CS553_LOCK_HELD=1
LOCK="$HOMEDIR/.cs553/relock.lock"
mkdir -p "$HOMEDIR/.cs553"
(exec 8>"$LOCK"; flock 8; exec sleep 30) &
LOCK_HOLDER=$!
for _ in $(seq 50); do flock -n "$LOCK" true 2>/dev/null || break; sleep 0.1; done
reset_sim
run_deploy
ok=0
check E8 rc_is 7 || ok=1
check E8 test "$(ssh_calls)" -eq 0 || ok=1
reset_sim
run_deploy CS553_LOCK_HELD=1
check E8 rc_is 0 || ok=1
kill "$LOCK_HOLDER" 2>/dev/null
wait "$LOCK_HOLDER" 2>/dev/null
finish_case "E8 lock busy -> exit 7, VM untouched; CS553_LOCK_HELD=1 -> proceeds" $ok

# E9. missing key -> exit 3
reset_sim
run_deploy MY_KEY="$T/nope"
ok=0
check E9 rc_is 3 || ok=1
check E9 test "$(ssh_calls)" -eq 0 || ok=1
finish_case "E9 MY_KEY missing -> exit 3" $ok

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
