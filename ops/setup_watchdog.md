# Setting up the VM re-lock watchdog (group 25)

This runbook installs `ops/relock.sh` on `linux.wpi.edu` and runs it from cron every 2 minutes. Once installed, it re-secures the VM by itself after every rebuild.

Follow the steps in order and don't skip a checkpoint.

**Placeholders:**
- Replace `<wpi_user>` with your WPI username.
- If your copy of the class key isn't at `~/.ssh/student-admin_key` on the laptop, adjust that path wherever it appears.

**Where each command runs:** every command block starts with a comment. `# laptop` means a terminal on your laptop in this repo's folder. `# linux.wpi.edu` means a shell on the WPI server.

> **Safety habit:** keep one `ssh cs553` session open in a separate terminal while you do steps 4 and 6. If something goes wrong, you still have a way in.

---

## 1. Check that `linux.wpi.edu` can do the job

```bash
# laptop
ssh <wpi_user>@linux.wpi.edu
```

```bash
# linux.wpi.edu
hostname                                   # WRITE THIS DOWN
crontab -l; echo "crontab exit=$?"
command -v ssh ssh-keygen flock curl awk
timeout 5 bash -c '</dev/tcp/paffenroth-23.dyn.wpi.edu/22025' && echo "VM port reachable"
mkdir -p ~/.cs553 && chmod 700 ~/.cs553
```

✅ **Checkpoint:**
- **Hostname recorded.** `linux.wpi.edu` may be several machines behind one name, and cron runs only on the machine where you install it. For every later step, log in to that exact hostname: `ssh <wpi_user>@<recorded hostname>`.
- **Cron is allowed.** `crontab -l` printed a crontab or `no crontab for <wpi_user>`. If it says you are *not allowed* to use cron, do steps 2–6, then go to step 9 instead of step 7.
- **All five tools were found:** `ssh`, `ssh-keygen`, `flock`, `curl` and `awk`.
- **The VM port is reachable:** you saw `VM port reachable`.

## 2. Generate the watchdog key on `linux.wpi.edu`

```bash
# linux.wpi.edu
ssh-keygen -t ed25519 -N "" -f ~/.cs553/watchdog_key -C "cs553-g25-watchdog"
cat ~/.cs553/watchdog_key.pub              # public half, safe to show
```

✅ **Checkpoint:** `~/.cs553/watchdog_key` and `~/.cs553/watchdog_key.pub` both exist, and the `.pub` line starts with `ssh-ed25519`. The private key has no passphrase on purpose, because cron can't type one. It never leaves this server.

## 3. Build `ops/authorized_keys` and copy the files over

```bash
# laptop (repo root)
cat ~/.ssh/cs553_g25.pub > ops/authorized_keys
ssh <wpi_user>@<recorded hostname> 'cat ~/.cs553/watchdog_key.pub' >> ops/authorized_keys
wc -l ops/authorized_keys                  # expect: 2
grep -c 'PRIVATE KEY' ops/authorized_keys  # expect: 0
grep -c 'student-admin' ops/authorized_keys # expect: 0  (the class key must NOT be listed)

scp ops/relock.sh ops/authorized_keys ops/relock.env.example ~/.ssh/student-admin_key \
    <wpi_user>@<recorded hostname>:~/.cs553/
```

```bash
# linux.wpi.edu
cd ~/.cs553
cp -n relock.env.example relock.env        # defaults already point at ~/.cs553/...
chmod 700 relock.sh
chmod 600 watchdog_key student-admin_key authorized_keys relock.env
ls -l ~/.cs553
```

✅ **Checkpoint:**
- `ops/authorized_keys` has exactly 2 lines: laptop key + watchdog key.
- `ls -l` shows `-rwx------` for `relock.sh` and `-rw-------` for the keys, `authorized_keys` and `relock.env`.
- *Optional:* add `DISCORD_WEBHOOK_URL=...` to `~/.cs553/relock.env`. Only ever put it there, never in the repo.
- `ops/authorized_keys` holds only public keys and may be committed.

## 4. Install the key list on the VM now

The watchdog key must be authorized before the first automatic run.

```bash
# laptop — atomic replace: afterwards the VM accepts exactly the 2 keys in ops/authorized_keys
ssh cs553 'umask 077; mkdir -p ~/.ssh && cat > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys' < ops/authorized_keys
ssh cs553 true && echo "laptop key OK"
```

```bash
# linux.wpi.edu
ssh -p 22025 -i ~/.cs553/watchdog_key -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    student-admin@paffenroth-23.dyn.wpi.edu true && echo "watchdog key OK"
```

✅ **Checkpoint:** you see both `laptop key OK` and `watchdog key OK`. If the laptop check fails, use the still-open session from the safety habit to fix `~/.ssh/authorized_keys` on the VM.

## 5. First manual run: expect `[OK]`

```bash
# linux.wpi.edu
~/.cs553/relock.sh; echo "exit=$?"
```

✅ **Checkpoint:** you see a line like `2026-…Z [INFO] OK: our key works, shared key rejected` and `exit=0`.

| Exit | Meaning |
|---|---|
| 3 | Bad config. The log line says which setting. |
| 2 | Neither key can log in. Re-check steps 1 and 4. |

## 6. Wipe simulation, relocked by hand

This recreates the state the VM is in right after the professor rebuilds it: `authorized_keys` contains only the class key.

**Why this is safe:** in that state the shared key still works, so you can always get back in with `ssh -p 22025 -i ~/.ssh/student-admin_key student-admin@paffenroth-23.dyn.wpi.edu`. And the watchdog never removes the shared key until our key has been proven to work.

```bash
# laptop
ssh cs553 'cat > ~/.ssh/authorized_keys' < ~/.ssh/student-admin_key.pub
ssh -o BatchMode=yes cs553 true; echo "laptop exit=$? (expect 255: locked out, as after a real wipe)"
```

```bash
# linux.wpi.edu
~/.cs553/relock.sh; echo "exit=$?"
```

Expect, in this order:
- `[WARN] RELOCK: wipe detected ...`
- `[INFO] RELOCK complete: our key works, shared key rejected`
- `exit=0`

```bash
# laptop
ssh cs553 true && echo "laptop key OK again"
ssh -p 22025 -i ~/.ssh/student-admin_key -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    student-admin@paffenroth-23.dyn.wpi.edu true; echo "shared key exit=$? (expect 255 = denied)"
```

✅ **Checkpoint:** `laptop key OK again`, and the shared key is denied with `exit=255`.

## 7. Install the cron job (safe to re-run)

```bash
# linux.wpi.edu  (on the recorded hostname!)
LINE='*/2 * * * * $HOME/.cs553/relock.sh >> $HOME/.cs553/relock.log 2>&1'
(crontab -l 2>/dev/null | grep -v relock.sh; echo "$LINE") | crontab -
crontab -l
```

Wait about 4 minutes, then:

```bash
# linux.wpi.edu
tail -n 5 ~/.cs553/relock.log
```

✅ **Checkpoint:**
- `crontab -l` shows exactly one `relock.sh` line.
- The log gains an `[INFO] OK: ...` line every 2 minutes.

### Optional: check every ~20 seconds (smaller exposure window)

Cron can't run more often than once a minute. Three lines offset by 0/20/40 s give a check about every 20 s, which shrinks the window after a rebuild from up to 2 minutes to about 20 s. `flock` inside `relock.sh` keeps runs from overlapping.

```bash
# linux.wpi.edu  (on the recorded hostname!) — replaces any existing relock.sh lines
(crontab -l 2>/dev/null | grep -v relock.sh
 echo '* * * * * $HOME/.cs553/relock.sh >> $HOME/.cs553/relock.log 2>&1'
 echo '* * * * * sleep 20; $HOME/.cs553/relock.sh >> $HOME/.cs553/relock.log 2>&1'
 echo '* * * * * sleep 40; $HOME/.cs553/relock.sh >> $HOME/.cs553/relock.log 2>&1'
) | crontab -
crontab -l
```

Each check tries the class key and gets rejected, so the VM logs a failed login about every 20 s. If the VM runs `fail2ban`, that could get `linux.wpi.edu` banned. Check first, on the VM: `systemctl is-active fail2ban` should print `inactive`, or report that the unit could not be found.

To go back to every 2 minutes, re-run step 7.

## 8. Hands-off test: let cron do it

```bash
# laptop
ssh cs553 'cat > ~/.ssh/authorized_keys' < ~/.ssh/student-admin_key.pub
date                                       # note the time; now touch NOTHING for up to 4 minutes
```

After 4 minutes:

```bash
# laptop
ssh cs553 true && echo "recovered automatically"
```

```bash
# linux.wpi.edu
tail -n 8 ~/.cs553/relock.log              # RELOCK ... complete, then OK lines
```

✅ **Checkpoint:** `recovered automatically` without you running `relock.sh`. The log shows `RELOCK complete`, and you got the Discord messages if you configured a webhook.

## 9. Fallback: cron not allowed on `linux.wpi.edu`

Run the watchdog in a loop inside `tmux` instead:

```bash
# linux.wpi.edu
tmux new -s relock
while true; do ~/.cs553/relock.sh >> ~/.cs553/relock.log 2>&1; sleep 120; done
# detach with Ctrl-b d; re-attach later with: tmux attach -t relock
```

**Limitations compared with cron:**
- The loop dies when the server reboots, when the tmux session is killed, or when an idle-session policy reaps it. Nothing restarts it; you'd have to notice.
- It only runs on the host where you started it.
- Check `tail ~/.cs553/relock.log` regularly.

---

## After a real rebuild

The VM's host key changes, so `ssh cs553` from the laptop will warn *REMOTE HOST IDENTIFICATION HAS CHANGED*. Remove the old entry, then connect again:

```bash
ssh-keygen -R "[paffenroth-23.dyn.wpi.edu]:22025"
```

The watchdog doesn't need this step, because it doesn't keep a `known_hosts` file (see `ops/README.md`).

## Turning the watchdog off

```bash
# linux.wpi.edu
crontab -l | grep -v relock.sh | crontab -
```
