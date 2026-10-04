#!/usr/bin/env bash
# Used Opus 5.5 with High Effort, for the cron watchdog that re-secures the VM and keeps the app
#   running.
# prompt: Write a bash watchdog that runs from cron on linux.wpi.edu. Probe our key and the shared
#   class key and, for the four states (OK, ENFORCE, RELOCK, DOWN), restore authorized_keys
#   atomically, never removing the shared key before our key is proven to work. Use flock, log one
#   line per event, notify Discord and run a post-relock hook. Later also check the app's URL and
#   restart or redeploy it, alert after a long outage, and probe the shared key less often.
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
# The shared-key probe is a login that is REJECTED by design. Repeating it every run looked
# like SSH brute force to WPI's firewall, which then blocked linux.wpi.edu for an hour
# (twice). So while our key works it is probed only every SHARED_CHECK_MIN minutes, or at
# once if it worked last time; a wipe is still caught immediately because it makes OUR key
# fail, and then the shared key is always probed.
#
# App check (only when APP_CHECK_URL is set, and only in the OK state): if the app doesn't
# answer at APP_CHECK_URL, look at its systemd service over SSH and escalate:
#   still starting (within APP_GRACE_S)        -> wait
#   service present, first failure              -> sudo systemctl restart
#   files missing, or still down after restart  -> DEPLOY_CMD (at most every DEPLOY_BACKOFF_MIN)
# One Discord alert per failure streak, and one "healthy again" message when it recovers.
#
# Exit codes: 0 OK/relocked/app repaired, 2 DOWN, 3 bad config, 4 our key still rejected
# after append, 5 post-relock verification failed, 6 app restart/redeploy failed.

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
APP_CHECK_URL="${APP_CHECK_URL:-}" # empty = app check off
APP_SERVICE="${APP_SERVICE:-prompt-enhancer}"
DEPLOY_CMD="${DEPLOY_CMD:-$HOME/.cs553/deploy.sh}"
APP_GRACE_S="${APP_GRACE_S:-180}"
DEPLOY_BACKOFF_MIN="${DEPLOY_BACKOFF_MIN:-10}"
APP_STATE_FILE="${APP_STATE_FILE:-$HOME/.cs553/relock.app}"
NOTIFY_RETRY_S="${NOTIFY_RETRY_S:-5}"
SHARED_CHECK_MIN="${SHARED_CHECK_MIN:-10}"
SHARED_STATE_FILE="${SHARED_STATE_FILE:-$HOME/.cs553/relock.shared}"

bad_config() { log ERROR "bad config: $1"; exit 3; }

[[ "$DOWN_ALERT_AFTER_MIN" =~ ^[0-9]+$ ]] || bad_config "DOWN_ALERT_AFTER_MIN must be a whole number of minutes"
[[ "$APP_GRACE_S" =~ ^[0-9]+$ ]] || bad_config "APP_GRACE_S must be a whole number of seconds"
[[ "$DEPLOY_BACKOFF_MIN" =~ ^[0-9]+$ ]] || bad_config "DEPLOY_BACKOFF_MIN must be a whole number of minutes"
[[ "$NOTIFY_RETRY_S" =~ ^[0-9]+$ ]] || bad_config "NOTIFY_RETRY_S must be a whole number of seconds"
[[ "$SHARED_CHECK_MIN" =~ ^[0-9]+$ ]] || bad_config "SHARED_CHECK_MIN must be a whole number of minutes"
# APP_SERVICE is interpolated into remote commands, so keep it to a safe unit-name alphabet.
[[ "$APP_SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]] || bad_config "APP_SERVICE has unexpected characters"

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

# SHARED_STATE_FILE holds "<epoch of last shared-key probe> <works|rejected>".
shared_login() {
  local result=rejected rc=1
  if can_login "$SHARED_KEY"; then result=works rc=0; fi
  mkdir -p "$(dirname "$SHARED_STATE_FILE")"
  echo "$(date +%s) $result" >"$SHARED_STATE_FILE"
  return "$rc"
}

shared_check_due() {
  local last=0 result=""
  [[ -f "$SHARED_STATE_FILE" ]] && read -r last result <"$SHARED_STATE_FILE" || true
  [[ "$last" =~ ^[0-9]+$ && "$result" == rejected ]] || return 0 # unknown, or it worked last time
  (($(date +%s) - last >= SHARED_CHECK_MIN * 60))
}

REMOTE_APPEND='umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
REMOTE_REPLACE='umask 077; mkdir -p ~/.ssh && cat > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys'

post_discord() { # post_discord <json payload>
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "$1" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
}

notify() {
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  local msg="[group25] $1" payload
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  payload="{\"content\": \"$msg\"}"
  # One retry: a transient Discord/network hiccup once swallowed a 30-min DOWN alert.
  if post_discord "$payload"; then return 0; fi
  sleep "$NOTIFY_RETRY_S"
  if post_discord "$payload"; then
    log INFO "Discord notification sent on retry"
  else
    log WARN "Discord notification failed twice (ignored)"
  fi
}

replace_with_our_key() {
  vm "$MY_KEY" "$REMOTE_REPLACE" <"$AUTH_KEYS"
}

verify_and_finish() { # verify_and_finish <state>
  if can_login "$MY_KEY" && ! shared_login; then
    log INFO "$1 complete: our key works, shared key rejected"
    notify "relock complete ($1) on $HOST: our key works, shared key rejected"
    if [[ -n "$POST_RELOCK_HOOK" ]]; then
      log INFO "running POST_RELOCK_HOOK"
      # 9>&- : don't let the hook (or anything it backgrounds) keep holding our lock.
      # CS553_LOCK_HELD=1 : we hold the lock for the hook's whole run, so deploy.sh
      # must not try to take it again.
      if CS553_LOCK_HELD=1 bash -c "$POST_RELOCK_HOOK" 9>&-; then
        log INFO "POST_RELOCK_HOOK succeeded"
        notify "app redeployed after $1 on $HOST; healthy"
      else
        local rc=$? next="check the relock log"
        [[ -n "$APP_CHECK_URL" ]] && next="the app check will retry"
        log WARN "POST_RELOCK_HOOK failed (exit $rc); relock itself succeeded"
        notify "redeploy after $1 on $HOST FAILED (exit $rc); $next"
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

# ---- app check -------------------------------------------------------------------------
# APP_STATE_FILE holds "<epoch of our last action> <restart|deploy> <failed fixes> <alerted 0|1>".
# It exists only while the app is (or was just) unhealthy; a healthy check removes it.
read_app_state() {
  app_last=0 app_action=none app_fails=0 app_alerted=0
  [[ -f "$APP_STATE_FILE" ]] || return 0
  read -r app_last app_action app_fails app_alerted <"$APP_STATE_FILE" || true
  if ! [[ "$app_last" =~ ^[0-9]+$ && "$app_fails" =~ ^[0-9]+$ && "$app_alerted" =~ ^[01]$ ]]; then
    app_last=0 app_action=none app_fails=0 app_alerted=0
  fi
}

write_app_state() { # write_app_state <epoch> <action> <fails> <alerted>
  mkdir -p "$(dirname "$APP_STATE_FILE")"
  echo "$1 $2 $3 $4" >"$APP_STATE_FILE"
}

app_answers() { curl -fsS -m 10 -o /dev/null "$APP_CHECK_URL" >/dev/null 2>&1; }

# One SSH round trip: service state, whether the install exists, and how long ago the
# service became active. The age comes from systemd's wall-clock ActiveEnterTimestamp:
# inside the LXD VM `ps -o etimes` is always 0 (container uptime vs host boot time).
APP_PROBE="s=\$(systemctl is-active $APP_SERVICE 2>/dev/null); \
t=\$(systemctl show -p ActiveEnterTimestamp --value $APP_SERVICE 2>/dev/null); \
a=0; [ -n \"\$t\" ] && a=\$(( \$(date +%s) - \$(date -d \"\$t\" +%s 2>/dev/null || date +%s) )); \
[ \"\$a\" -ge 0 ] 2>/dev/null || a=0; \
f=no; [ -x ~/app/.venv/bin/prompt-enhancer ] && systemctl cat $APP_SERVICE >/dev/null 2>&1 && f=yes; \
echo \"state=\${s:-unknown} files=\$f age=\$a\""

alert_once() { # alert_once <message>: first failure message of a streak only
  if [[ "$app_alerted" == 0 ]]; then
    notify "$1"
    app_alerted=1
  fi
}

check_app() {
  local now age probe state files proc_age reason rc
  read_app_state
  if app_answers; then
    if [[ -f "$APP_STATE_FILE" ]]; then
      log INFO "app healthy again at $APP_CHECK_URL"
      [[ "$app_alerted" == 1 ]] && notify "app on $HOST healthy again"
      rm -f "$APP_STATE_FILE"
    fi
    log INFO "OK: our key works, shared key rejected; app up"
    exit 0
  fi

  now="$(date +%s)"
  age=$((now - app_last))
  if ((app_last > 0 && age < APP_GRACE_S)); then
    log INFO "OK: keys locked; app not answering yet (${app_action} ${age}s ago, grace ${APP_GRACE_S}s)"
    exit 0
  fi

  if ! probe="$(vm "$MY_KEY" "$APP_PROBE" </dev/null 2>/dev/null)" ||
    ! [[ "$probe" =~ state=([^[:space:]]+)\ files=(yes|no)\ age=([0-9]+) ]]; then
    log ERROR "APP DOWN at $APP_CHECK_URL and the service probe over SSH failed"
    exit 6
  fi
  state="${BASH_REMATCH[1]}" files="${BASH_REMATCH[2]}" proc_age="${BASH_REMATCH[3]}"

  # systemd (re)started it moments ago (crash, reboot, manual restart): give it time to load.
  if [[ "$files" == yes && "$state" =~ ^(active|activating)$ ]] && ((proc_age < APP_GRACE_S)); then
    log INFO "OK: keys locked; app process started ${proc_age}s ago, still starting"
    exit 0
  fi

  if [[ "$files" == yes && "$app_fails" -eq 0 ]]; then
    log WARN "APP DOWN at $APP_CHECK_URL (service $state); restarting $APP_SERVICE"
    if vm "$MY_KEY" "sudo systemctl restart $APP_SERVICE" </dev/null >/dev/null 2>&1; then
      write_app_state "$now" restart 1 "$app_alerted"
      notify "app on $HOST was down (service $state) -> restarted"
      exit 0
    fi
    log ERROR "restart of $APP_SERVICE failed"
    alert_once "app on $HOST is down and restarting it FAILED; will redeploy"
    write_app_state "$now" restart 1 "$app_alerted"
    exit 6
  fi

  # Escalate to a full redeploy: install missing, or a restart didn't bring it back.
  if [[ "$app_action" == deploy ]] && ((age < DEPLOY_BACKOFF_MIN * 60)); then
    log WARN "APP DOWN; last redeploy ${age}s ago, next attempt after ${DEPLOY_BACKOFF_MIN} min"
    exit 6
  fi
  if [[ "$files" == no ]]; then reason="app not installed"; else reason="still down after restart"; fi
  if ((app_fails >= 2)); then
    alert_once "app on $HOST still down after restart and redeploy; retrying every ${DEPLOY_BACKOFF_MIN} min. Check manually."
  elif [[ "$app_alerted" == 0 ]]; then
    notify "app on $HOST down ($reason) -> redeploying"
  fi
  log WARN "APP DOWN at $APP_CHECK_URL ($reason); running DEPLOY_CMD"
  # Recorded before running, so a deploy that dies half-way still counts toward backoff.
  write_app_state "$now" deploy $((app_fails + 1)) "$app_alerted"
  if CS553_LOCK_HELD=1 bash -c "$DEPLOY_CMD" 9>&-; then
    write_app_state "$(date +%s)" deploy $((app_fails + 1)) "$app_alerted"
    log INFO "redeploy finished"
    [[ "$app_alerted" == 1 ]] || notify "redeploy on $HOST finished; app healthy"
    exit 0
  else
    rc=$?
    log ERROR "redeploy failed (exit $rc); next attempt after ${DEPLOY_BACKOFF_MIN} min"
    alert_once "redeploy on $HOST FAILED (exit $rc); retrying every ${DEPLOY_BACKOFF_MIN} min. Check manually."
    write_app_state "$now" deploy $((app_fails + 1)) "$app_alerted"
    exit 6
  fi
}

# ---- main ------------------------------------------------------------------------------

ours=rejected shared=rejected
can_login "$MY_KEY" && ours=works
if [[ "$ours" == rejected ]] || shared_check_due; then
  shared_login && shared=works
else
  shared=skipped # our key works and the shared key was rejected recently
fi

# Any key working means the VM is reachable again: close out a DOWN period.
[[ "$ours/$shared" == rejected/rejected ]] || clear_down

case "$ours/$shared" in
  works/rejected | works/skipped)
    if [[ -n "$APP_CHECK_URL" ]]; then
      check_app
    fi
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
