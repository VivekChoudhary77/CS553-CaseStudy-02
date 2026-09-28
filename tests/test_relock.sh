#!/usr/bin/env bash
# Local simulation tests for ops/relock.sh — no network, no real keys.
#
# Fake `ssh`, `ssh-keygen` and `curl` executables go first on PATH. The "VM" is a
# directory holding a simulated authorized_keys file whose lines look like
# "ssh-fake <name> <comment>"; a fake key file just contains its <name>. Flag files in
# the VM directory inject faults (vm_down, append_broken, replace_broken, discord_down).
#
# Usage: bash tests/test_relock.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOCK="$ROOT/ops/relock.sh"
T="$(mktemp -d)"
trap 'kill "${LOCK_HOLDER:-}" 2>/dev/null; rm -rf "$T"' EXIT

FAKEBIN="$T/bin" VM="$T/vm" KEYS="$T/keys" HOMEDIR="$T/home"
mkdir -p "$FAKEBIN" "$KEYS" "$HOMEDIR"

# ---- fake executables ----------------------------------------------------------------

cat >"$FAKEBIN/ssh" <<'EOF'
#!/usr/bin/env bash
key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) key="$2"; shift 2 ;;
    -p|-o|-l|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift # user@host
cmd="$*"
echo "$(cat "$key") :: $cmd" >>"$SIM_VM/calls.log"
if [[ -e "$SIM_VM/vm_down" ]]; then echo "ssh: connect to host: Connection refused" >&2; exit 255; fi
auth="$SIM_VM/authorized_keys"
if ! awk -v n="$(cat "$key")" '$2 == n { f = 1 } END { exit !f }' "$auth" 2>/dev/null; then
  echo "student-admin@vm: Permission denied (publickey)." >&2
  exit 255
fi
case "$cmd" in
  true) exit 0 ;;
  *authorized_keys.new*) # atomic replace
    if [[ -e "$SIM_VM/replace_broken" ]]; then cat >/dev/null; exit 1; fi
    cat >"$auth.new" && mv "$auth.new" "$auth" ;;
  *'>>'*) # append
    if [[ -e "$SIM_VM/append_broken" ]]; then cat >/dev/null; exit 0; fi # "succeeds" but has no effect
    cat >>"$auth" ;;
  *) echo "fake ssh: unexpected remote command: $cmd" >&2; exit 127 ;;
esac
EOF

cat >"$FAKEBIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
file=""
while [[ $# -gt 0 ]]; do
  case "$1" in -f) file="$2"; shift 2 ;; -P) shift 2 ;; *) shift ;; esac
done
echo "ssh-fake $(cat "$file") fake-comment"
EOF

cat >"$FAKEBIN/curl" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -d) echo "$2" >>"$SIM_VM/discord.log"; shift 2 ;; *) shift ;; esac
done
[[ ! -e "$SIM_VM/discord_down" ]]
EOF
chmod +x "$FAKEBIN"/*

echo mine >"$KEYS/mine"
echo shared >"$KEYS/shared"
printf 'ssh-fake mine cs553-g25-watchdog\nssh-fake laptop cs553_g25-laptop\n' >"$T/auth_keys"
SHARED_LINE='ssh-fake shared student-admin-class-key'

# ---- harness -----------------------------------------------------------------------------

PASSED=0 FAILED=0 RC=0 ELAPSED=0

reset_vm() { # reset_vm <authorized_keys content>
  rm -rf "$VM"
  mkdir -p "$VM"
  printf '%s\n' "$1" >"$VM/authorized_keys"
  : >"$VM/calls.log"
  rm -rf "$HOMEDIR/.cs553"
}

run_relock() { # extra VAR=value args override the defaults
  local start=$SECONDS
  env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$HOMEDIR" SIM_VM="$VM" \
    CONFIG="$T/no-such-config" \
    MY_KEY="$KEYS/mine" SHARED_KEY="$KEYS/shared" AUTH_KEYS="$T/auth_keys" \
    "$@" bash "$RELOCK" >"$T/out.log" 2>&1
  RC=$?
  ELAPSED=$((SECONDS - start))
}

check() { # check <name> <condition...>; condition is a command
  local name="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    [case $name] assertion failed: $*"
  return 1
}

finish_case() { # finish_case <name> <ok 0/1>
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
vm_equals_file() { diff -q "$VM/authorized_keys" "$1" >/dev/null; }
vm_has() { grep -q "$1" "$VM/authorized_keys"; }
vm_lacks() { ! grep -q "$1" "$VM/authorized_keys"; }
vm_unchanged() { diff -q "$VM/authorized_keys" "$T/before" >/dev/null; }
no_ssh_calls() { [[ ! -s "$VM/calls.log" ]]; }
only_probes() { ! grep -qv ':: true$' "$VM/calls.log"; }
discord_has() { grep -q "$1" "$VM/discord.log" 2>/dev/null; }
# The final REPLACE must use OUR key (it only works once our key is proven), never the shared one.
replace_used_our_key() {
  grep -q '^mine :: .*authorized_keys\.new' "$VM/calls.log" &&
    ! grep -q '^shared :: .*authorized_keys\.new' "$VM/calls.log"
}
# The APPEND after a wipe must use the shared key (ours doesn't work yet).
append_used_shared_key() { grep -q '^shared :: .*>>' "$VM/calls.log"; }
snapshot() { cp "$VM/authorized_keys" "$T/before"; }

# ---- cases (1–7 from the spec) --------------------------------------------------------

# 1. wiped: only the shared key → relock, ends with exactly our keys
reset_vm "$SHARED_LINE"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook \
  POST_RELOCK_HOOK="touch '$VM/hook_ran'"
ok=0
check 1 rc_is 0 || ok=1
check 1 vm_equals_file "$T/auth_keys" || ok=1
check 1 discord_has 'wipe detected' || ok=1
check 1 discord_has 'relock complete' || ok=1
check 1 test -e "$VM/hook_ran" || ok=1
check 1 append_used_shared_key || ok=1
check 1 replace_used_our_key || ok=1
finish_case "1 wiped (only shared) -> relocked to exactly AUTH_KEYS" $ok

# 2. healthy → exit 0, unchanged, only login probes
reset_vm "$(cat "$T/auth_keys")"
snapshot
run_relock
ok=0
check 2 rc_is 0 || ok=1
check 2 vm_unchanged || ok=1
check 2 only_probes || ok=1
finish_case "2 healthy -> OK, unchanged, probes only" $ok

# 3. enforce: ours + shared → shared removed
reset_vm "$(cat "$T/auth_keys")
$SHARED_LINE"
run_relock
ok=0
check 3 rc_is 0 || ok=1
check 3 vm_equals_file "$T/auth_keys" || ok=1
check 3 vm_lacks 'ssh-fake shared' || ok=1
check 3 replace_used_our_key || ok=1
finish_case "3 enforce (ours + shared) -> shared removed" $ok

# 4. down → exit 2, unchanged, no notification
reset_vm "$SHARED_LINE"
touch "$VM/vm_down"
snapshot
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
ok=0
check 4 rc_is 2 || ok=1
check 4 vm_unchanged || ok=1
check 4 test ! -e "$VM/discord.log" || ok=1
finish_case "4 down -> exit 2, unchanged, no Discord spam" $ok

# 5. append "succeeds" but our key is still rejected → exit 4, shared key KEPT
reset_vm "$SHARED_LINE"
touch "$VM/append_broken"
run_relock
ok=0
check 5 rc_is 4 || ok=1
check 5 vm_has 'ssh-fake shared' || ok=1
check 5 test "$(grep -c 'authorized_keys.new' "$VM/calls.log")" -eq 0 || ok=1
finish_case "5 our key still rejected after append -> exit 4, shared key still present" $ok

# 6. empty AUTH_KEYS → exit 3, VM untouched
reset_vm "$SHARED_LINE"
snapshot
printf '# only a comment\n\n' >"$T/empty_keys"
run_relock AUTH_KEYS="$T/empty_keys"
ok=0
check 6 rc_is 3 || ok=1
check 6 vm_unchanged || ok=1
check 6 no_ssh_calls || ok=1
check 6 grep -q 'has no keys' "$T/out.log" || ok=1
finish_case "6 empty AUTH_KEYS -> exit 3, VM untouched" $ok

# 7. lock held by another run → exit 0 quickly, VM untouched
reset_vm "$SHARED_LINE"
snapshot
mkdir -p "$HOMEDIR/.cs553"
LOCK="$HOMEDIR/.cs553/relock.lock"
(exec 8>"$LOCK"; flock 8; exec sleep 30) &
LOCK_HOLDER=$!
for _ in $(seq 50); do flock -n "$LOCK" true 2>/dev/null || break; sleep 0.1; done
run_relock
kill "$LOCK_HOLDER" 2>/dev/null
wait "$LOCK_HOLDER" 2>/dev/null
ok=0
check 7 rc_is 0 || ok=1
check 7 test "$ELAPSED" -le 3 || ok=1
check 7 vm_unchanged || ok=1
check 7 no_ssh_calls || ok=1
finish_case "7 concurrent run while lock held -> exit 0 fast, VM untouched" $ok

# ---- extra safety cases --------------------------------------------------------------

# 8. AUTH_KEYS without our own public key → exit 3 (replacing would lock us out)
reset_vm "$SHARED_LINE"
snapshot
printf 'ssh-fake laptop cs553_g25-laptop\n' >"$T/no_mine"
run_relock AUTH_KEYS="$T/no_mine"
ok=0
check 8 rc_is 3 || ok=1
check 8 vm_unchanged || ok=1
check 8 no_ssh_calls || ok=1
finish_case "8 AUTH_KEYS missing our key -> exit 3, VM untouched" $ok

# 9. AUTH_KEYS that includes the shared key → exit 3 (relock could never finish)
reset_vm "$SHARED_LINE"
snapshot
{ cat "$T/auth_keys"; echo "$SHARED_LINE"; } >"$T/with_shared"
run_relock AUTH_KEYS="$T/with_shared"
ok=0
check 9 rc_is 3 || ok=1
check 9 vm_unchanged || ok=1
finish_case "9 AUTH_KEYS contains shared key -> exit 3, VM untouched" $ok

# 10. replace fails after a good append → exit 5, shared key still present, next run fixes it
reset_vm "$SHARED_LINE"
touch "$VM/replace_broken"
run_relock
ok=0
check 10 rc_is 5 || ok=1
check 10 vm_has 'ssh-fake shared' || ok=1
check 10 vm_has 'ssh-fake mine' || ok=1
rm "$VM/replace_broken"
run_relock
check 10 rc_is 0 || ok=1
check 10 vm_equals_file "$T/auth_keys" || ok=1
finish_case "10 replace fails -> exit 5 keeping shared key; next run ENFORCEs" $ok

# 11. Discord unreachable and hook failing must not fail a relock
reset_vm "$SHARED_LINE"
touch "$VM/discord_down"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook POST_RELOCK_HOOK="exit 7"
ok=0
check 11 rc_is 0 || ok=1
check 11 vm_equals_file "$T/auth_keys" || ok=1
check 11 grep -q 'POST_RELOCK_HOOK failed' "$T/out.log" || ok=1
finish_case "11 Discord down + failing hook -> relock still exit 0" $ok

# 12. settings read from the CONFIG file (no env vars)
reset_vm "$SHARED_LINE"
cat >"$T/relock.env" <<EOF
MY_KEY=$KEYS/mine
SHARED_KEY=$KEYS/shared
AUTH_KEYS=$T/auth_keys
EOF
env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$HOMEDIR" SIM_VM="$VM" CONFIG="$T/relock.env" \
  bash "$RELOCK" >"$T/out.log" 2>&1
RC=$?
ok=0
check 12 rc_is 0 || ok=1
check 12 vm_equals_file "$T/auth_keys" || ok=1
finish_case "12 config loaded from CONFIG file" $ok

# 13. log format: every line is "<UTC ISO timestamp> [LEVEL] message"
ok=0
check 13 test -s "$T/out.log" || ok=1
check 13 bash -c "! grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \[[A-Z]+\] ' '$T/out.log'" || ok=1
finish_case "13 log lines are '<UTC ISO> [LEVEL] message'" $ok

# ---- prolonged DOWN alert ------------------------------------------------------------
DOWN_FILE="$HOMEDIR/.cs553/relock.down"
discord_count() { grep -c "$1" "$VM/discord.log" 2>/dev/null || true; }

# 14. first DOWN run: start tracking, no alert
reset_vm "$SHARED_LINE"
touch "$VM/vm_down"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
ok=0
check 14 rc_is 2 || ok=1
check 14 grep -qE '^[0-9]+ 0$' "$DOWN_FILE" || ok=1
check 14 test ! -e "$VM/discord.log" || ok=1
finish_case "14 first DOWN run -> tracked, no alert" $ok

# 15. DOWN longer than DOWN_ALERT_AFTER_MIN -> exactly one alert across repeated runs
echo "$(($(date +%s) - 31 * 60)) 0" >"$DOWN_FILE" # pretend DOWN began 31 min ago
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
rc1=$RC
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
ok=0
check 15 test "$rc1" -eq 2 || ok=1
check 15 rc_is 2 || ok=1
check 15 test "$(discord_count unreachable)" -eq 1 || ok=1
check 15 grep -qE '^[0-9]+ 1$' "$DOWN_FILE" || ok=1
finish_case "15 DOWN > 30 min -> one alert, not repeated" $ok

# 16. VM comes back after an alert -> one "reachable again" message, tracking cleared
rm "$VM/vm_down"
printf '%s\n' "$(cat "$T/auth_keys")" >"$VM/authorized_keys"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
ok=0
check 16 rc_is 0 || ok=1
check 16 test "$(discord_count 'reachable again')" -eq 1 || ok=1
check 16 test ! -e "$DOWN_FILE" || ok=1
finish_case "16 recovery after alert -> 'reachable again' once, state cleared" $ok

# 17. short DOWN (normal rebuild) then a wipe -> no DOWN alert/recovery message, relock as usual
reset_vm "$SHARED_LINE"
mkdir -p "$HOMEDIR/.cs553"
echo "$(date +%s) 0" >"$DOWN_FILE"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook
ok=0
check 17 rc_is 0 || ok=1
check 17 vm_equals_file "$T/auth_keys" || ok=1
check 17 test ! -e "$DOWN_FILE" || ok=1
check 17 test "$(discord_count 'reachable again')" -eq 0 || ok=1
check 17 discord_has 'wipe detected' || ok=1
finish_case "17 short DOWN then wipe -> relocked, no DOWN messages" $ok

# 18. custom threshold from config: DOWN_ALERT_AFTER_MIN=0 alerts on the 2nd DOWN run
reset_vm "$SHARED_LINE"
touch "$VM/vm_down"
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook DOWN_ALERT_AFTER_MIN=0
run_relock DISCORD_WEBHOOK_URL=https://discord.invalid/webhook DOWN_ALERT_AFTER_MIN=0
ok=0
check 18 rc_is 2 || ok=1
check 18 test "$(discord_count unreachable)" -eq 1 || ok=1
run_relock DOWN_ALERT_AFTER_MIN=abc
check 18 rc_is 3 || ok=1
finish_case "18 DOWN_ALERT_AFTER_MIN honoured; invalid value -> exit 3" $ok

echo
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
