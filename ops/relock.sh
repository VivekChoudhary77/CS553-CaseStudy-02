#!/usr/bin/env bash
# relock.sh — re-secure the CS553 group 25 VM after the professor rebuilds it.
#
# Runs from cron on linux.wpi.edu every 2 minutes (see ops/setup_watchdog.md).
# Each run probes which keys can log in and acts on the resulting state:
#
#   our key   shared key   state    action
#   works     rejected     OK       nothing
#   works     works        ENFORCE  replace authorized_keys with AUTH_KEYS (using our key)
#   rejected  works        RELOCK   append AUTH_KEYS (shared key) -> prove our key works
#                                   -> replace authorized_keys with AUTH_KEYS (our key)
#   rejected  rejected     DOWN     VM unreachable or rebuilding: exit 2. No notification,
#                                   except ONE alert if DOWN lasts DOWN_ALERT_AFTER_MIN
#                                   (e.g. the rebuild changed the key or port), and one
#                                   "back up" message when it recovers after that alert.
#
# Safety rule: the shared key is only removed after our key has been proven to work,
# so a run that fails part-way can never lock us out; the next run just retries.
#
# Exit codes: 0 OK/relocked, 2 DOWN, 3 bad config, 4 our key still rejected after
# append, 5 post-relock verification failed.

set -Eeuo pipefail

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2"; }
trap 'log ERROR "line ${LINENO}: command failed (exit $?): ${BASH_COMMAND}"' ERR

# ---- configuration ---------------------------------------------------------------

CONFIG="${CONFIG:-$HOME/.cs553/relock.env}"
if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null  # path is only known at runtime
  source "$CONFIG"
fi

HOST="${HOST:-paffenroth-23.dyn.wpi.edu}"
PORT="${PORT:-22025}"
VM_USER="${VM_USER:-student-admin}"
MY_KEY="${MY_KEY:-}"
SHARED_KEY="${SHARED_KEY:-}"
AUTH_KEYS="${AUTH_KEYS:-}"
LOCK_FILE="${LOCK_FILE:-$HOME/.cs553/relock.lock}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
POST_RELOCK_HOOK="${POST_RELOCK_HOOK:-}"
DOWN_STATE_FILE="${DOWN_STATE_FILE:-$HOME/.cs553/relock.down}"
DOWN_ALERT_AFTER_MIN="${DOWN_ALERT_AFTER_MIN:-30}"

bad_config() { log ERROR "bad config: $1"; exit 3; }

[[ "$DOWN_ALERT_AFTER_MIN" =~ ^[0-9]+$ ]] || bad_config "DOWN_ALERT_AFTER_MIN must be a whole number of minutes"

# Print the base64 key blob (2nd field) of a private key's public half, without ever
# printing the private key. -P "" makes a passphrase-protected key fail instead of prompting.
pub_blob() { ssh-keygen -y -P "" -f "$1" 2>/dev/null | awk 'NR == 1 { print $2 }'; }

[[ -n "$MY_KEY" && -r "$MY_KEY" ]] || bad_config "MY_KEY is unset or unreadable"
[[ -n "$SHARED_KEY" && -r "$SHARED_KEY" ]] || bad_config "SHARED_KEY is unset or unreadable"
[[ -n "$AUTH_KEYS" && -r "$AUTH_KEYS" ]] || bad_config "AUTH_KEYS is unset or unreadable"
# Never write an empty authorized_keys: that would lock everyone out.
grep -qvE '^[[:space:]]*(#|$)' "$AUTH_KEYS" || bad_config "AUTH_KEYS ($AUTH_KEYS) has no keys"
if grep -q 'PRIVATE KEY' "$AUTH_KEYS"; then
  bad_config "AUTH_KEYS contains a private key; it must list public keys only"
fi

# The final REPLACE is done with our key, so AUTH_KEYS must contain it, or we would lock
# ourselves out. And it must not contain the shared key, or the relock can never finish.
my_blob="$(pub_blob "$MY_KEY" || true)"
shared_blob="$(pub_blob "$SHARED_KEY" || true)"
[[ -n "$my_blob" ]] || bad_config "cannot read public half of MY_KEY (it must have no passphrase)"
[[ -n "$shared_blob" ]] || bad_config "cannot read public half of SHARED_KEY"
awk -v b="$my_blob" '$2 == b { found = 1 } END { exit !found }' "$AUTH_KEYS" \
  || bad_config "AUTH_KEYS does not contain MY_KEY's public key (replacing would lock us out)"
if awk -v b="$shared_blob" '$2 == b { found = 1 } END { exit !found }' "$AUTH_KEYS"; then
  bad_config "AUTH_KEYS contains the shared class key; it must not"
fi

# ---- single instance ---------------------------------------------------------------

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log INFO "another run holds $LOCK_FILE; exiting"
  exit 0
fi

# ---- helpers -------------------------------------------------------------------------

# StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null: the VM's host key changes on
# every rebuild, so a pinned known_hosts entry would make every post-wipe run fail.
# Trade-off: SSH can no longer detect a host impersonating the VM (MITM). Accepted for
# this course VM; discussed in the report.
SSH_OPTS=(
  -p "$PORT"
  -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
)

vm() { # vm <private key> <remote command>   (stdin is forwarded)
  local key="$1"
  shift
  ssh "${SSH_OPTS[@]}" -i "$key" "$VM_USER@$HOST" "$@"
}

can_login() { vm "$1" true </dev/null >/dev/null 2>&1; }

REMOTE_APPEND='umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
REMOTE_REPLACE='umask 077; mkdir -p ~/.ssh && cat > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys'

notify() {
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  local msg="[group25] $1"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  if ! curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"content\": \"$msg\"}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1; then
    log WARN "Discord notification failed (ignored)"
  fi
}

replace_with_our_key() {
  vm "$MY_KEY" "$REMOTE_REPLACE" <"$AUTH_KEYS"
}

verify_and_finish() { # verify_and_finish <state>
  if can_login "$MY_KEY" && ! can_login "$SHARED_KEY"; then
    log INFO "$1 complete: our key works, shared key rejected"
    notify "relock complete ($1) on $HOST: our key works, shared key rejected"
    if [[ -n "$POST_RELOCK_HOOK" ]]; then
      log INFO "running POST_RELOCK_HOOK"
      # 9>&- : don't let the hook (or anything it backgrounds) keep holding our lock.
      if bash -c "$POST_RELOCK_HOOK" 9>&-; then
        log INFO "POST_RELOCK_HOOK succeeded"
      else
        log WARN "POST_RELOCK_HOOK failed (exit $?); relock itself succeeded"
      fi
    fi
    exit 0
  fi
  log ERROR "$1 verification failed: our key and/or shared key not in the expected state"
  notify "verification FAILED after $1 on $HOST; will retry in 2 minutes"
  exit 5
}

# DOWN is normal for a few minutes while the VM rebuilds, so it isn't notified each run.
# DOWN_STATE_FILE holds "<epoch first seen DOWN> <alerted 0|1>" so that a DOWN lasting
# longer than DOWN_ALERT_AFTER_MIN (e.g. the rebuild changed the key or port) gets
# exactly one alert, and its recovery gets one "back up" message.
read_down_state() { # sets down_since, down_alerted; returns 1 if no (valid) state
  down_since="" down_alerted=0
  [[ -f "$DOWN_STATE_FILE" ]] || return 1
  read -r down_since down_alerted <"$DOWN_STATE_FILE" || true
  [[ "$down_since" =~ ^[0-9]+$ && "$down_alerted" =~ ^[01]$ ]]
}

track_down() {
  local now minutes
  now="$(date +%s)"
  if ! read_down_state; then
    mkdir -p "$(dirname "$DOWN_STATE_FILE")"
    echo "$now 0" >"$DOWN_STATE_FILE"
    return 0
  fi
  minutes=$(((now - down_since) / 60))
  if [[ "$down_alerted" == 0 && "$minutes" -ge "$DOWN_ALERT_AFTER_MIN" ]]; then
    log ERROR "DOWN for ${minutes} min: VM unreachable with both keys (rebuild may have changed the key/port)"
    notify "VM $HOST unreachable with both keys for ${minutes} min; the rebuild may have changed the key or port. Check manually."
    echo "$down_since 1" >"$DOWN_STATE_FILE"
  fi
}

clear_down() {
  if read_down_state && [[ "$down_alerted" == 1 ]]; then
    local minutes=$((($(date +%s) - down_since) / 60))
    log INFO "VM reachable again after ${minutes} min DOWN"
    notify "VM $HOST reachable again after ${minutes} min DOWN"
  fi
  rm -f "$DOWN_STATE_FILE"
}

# ---- main ------------------------------------------------------------------------------

ours=rejected shared=rejected
can_login "$MY_KEY" && ours=works
can_login "$SHARED_KEY" && shared=works

# Any key working means the VM is reachable again: close out a DOWN period.
[[ "$ours/$shared" == rejected/rejected ]] || clear_down

case "$ours/$shared" in
  works/rejected)
    log INFO "OK: our key works, shared key rejected"
    exit 0
    ;;

  works/works)
    log WARN "ENFORCE: shared key is accepted; replacing authorized_keys with AUTH_KEYS"
    if ! replace_with_our_key; then
      log ERROR "ENFORCE: replace failed; shared key still present, will retry"
      notify "verification FAILED: could not replace authorized_keys on $HOST"
      exit 5
    fi
    verify_and_finish ENFORCE
    ;;

  rejected/works)
    log WARN "RELOCK: wipe detected (only the shared key works); re-adding our keys"
    notify "wipe detected on $HOST; relocking"
    # Step 1: APPEND with the shared key. A leading newline guards against a file that
    # doesn't end in one (appending onto the shared key's line would break both keys).
    if ! { echo; cat "$AUTH_KEYS"; } | vm "$SHARED_KEY" "$REMOTE_APPEND"; then
      log ERROR "RELOCK: append via shared key failed; will retry"
      notify "verification FAILED: could not append our keys on $HOST"
      exit 4
    fi
    # Step 2: prove our key works BEFORE removing the shared key.
    if ! can_login "$MY_KEY"; then
      log ERROR "RELOCK: our key still rejected after append; shared key left in place, will retry"
      notify "verification FAILED: our key still rejected after append on $HOST"
      exit 4
    fi
    # Step 3: REPLACE with exactly AUTH_KEYS, using our (now proven) key.
    if ! replace_with_our_key; then
      log ERROR "RELOCK: replace failed; shared key still present, next run will ENFORCE"
      notify "verification FAILED: could not replace authorized_keys on $HOST"
      exit 5
    fi
    verify_and_finish RELOCK
    ;;

  rejected/rejected)
    log WARN "DOWN: neither key can log in to $HOST:$PORT (VM down or rebuilding)"
    track_down
    exit 2
    ;;
esac
