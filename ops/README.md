# ops/: VM re-lock watchdog

The professor destroys and rebuilds our VM without notice. After a rebuild:
- `~/.ssh/authorized_keys` contains only the class-wide shared key, which every student has.
- Our keys are gone.
- The host key changes.

`relock.sh` runs from cron on `linux.wpi.edu` every 2 minutes and puts our keys back. It has to run there because that server is inside the WPI firewall and can reach the VM; GitHub Actions can't.

| File | Purpose |
|---|---|
| `relock.sh` | The watchdog. |
| `relock.env.example` | Config template. Copy it to `~/.cs553/relock.env` and `chmod 600` it. Never commit the real file. |
| `authorized_keys` | Public keys that must be authorized after every relock: laptop key and watchdog key. Safe to commit. |
| `setup_watchdog.md` | Step-by-step install and test runbook. |
| `../tests/test_relock.sh` | Local simulation tests (no network): `bash tests/test_relock.sh`. |

## Four states

Each run tries to log in with our watchdog key and with the shared key, running the remote command `true`:

| Our key | Shared key | State | Action | Exit |
|---|---|---|---|---|
| works | rejected | **OK** | nothing | 0 |
| works | works | **ENFORCE** | replace `authorized_keys` with exactly `AUTH_KEYS`, using our key | 0 |
| rejected | works | **RELOCK** (wipe) | append `AUTH_KEYS` with the shared key → prove our key works → replace with exactly `AUTH_KEYS` using our key | 0 |
| rejected | rejected | **DOWN** | log only while the VM rebuilds; after `DOWN_ALERT_AFTER_MIN` (default 30) send **one** alert, then one "reachable again" message on recovery | 2 |

After ENFORCE or RELOCK, the script checks from the outside that our key works *and* the shared key is rejected. It then sends an optional Discord notification and runs the optional `POST_RELOCK_HOOK` (later: redeploy the app).

**Other exit codes:**
- `3`: bad config.
- `4`: our key is still rejected after the append.
- `5`: the post-relock verification failed.

**Why DOWN gets a delayed alert.** The watchdog can only relock if the rebuilt VM accepts the class key on the expected user and port. If a rebuild changes any of these, every run lands in DOWN and nothing can be fixed automatically. Alerting on every DOWN run would spam during normal rebuilds.

So the first DOWN run records the time in `DOWN_STATE_FILE`. If DOWN is still going after `DOWN_ALERT_AFTER_MIN`, one alert says to check manually. The first reachable run afterwards clears the record, and sends a "reachable again" message only if an alert went out.

## Ordering guarantee: a failed run can't lock us out

The shared key is removed only after our key has been *proven* to work.

1. **Append.** Our keys are appended using the shared key; nothing is removed.
2. **Prove.** A fresh login with our key must succeed. If it doesn't, the script exits `4` and leaves the shared key in place, and the next run starts over.
3. **Replace.** `authorized_keys` is replaced with exactly `AUTH_KEYS`, *using our key*. The replace is atomic (write `authorized_keys.new`, then `mv`), so an interrupted transfer never leaves a half-written file.

If the run stops at any point, the VM is either still in the wiped state (the shared key works, so the next run redoes the relock) or in the ENFORCE state (both keys work, so the next run removes the shared key).

**Config checks.** Before touching the VM, `relock.sh` refuses to run (exit `3`) if `AUTH_KEYS`:
- is empty,
- contains a private key,
- is missing our own public key (the replace would lock us out), or
- contains the shared key (the relock could never finish).

**Tests.** `tests/test_relock.sh` checks each of these guarantees, including that the replace is always done with *our* key.

## Exposure window after a wipe

Between a rebuild and the next cron run, which is up to about 2 minutes plus the run itself, the VM accepts the class-wide shared key. Any classmate could log in during that window.

Our replace removes any keys they add to `authorized_keys`. It does *not* undo other changes they might make, such as a crontab, `~/.bashrc` or files. A faster schedule narrows the window but can't close it; only the professor's rebuild process could (e.g. by not installing the shared key).

- **Default:** every 2 minutes. The first real rebuild (2026-09-28) was relocked about 40 s after boot.
- **Red-teaming window:** for that window, `setup_watchdog.md` shows a 3-line crontab that checks about every 20 s.
- **To see whether anyone else got in:** `sudo grep 'Accepted publickey' /var/log/auth.log` on the VM lists every login and the key it used.

## Host-key trade-off: `UserKnownHostsFile=/dev/null`

The VM's SSH host key changes on every rebuild. With normal host-key checking, the first run after every wipe would fail with *REMOTE HOST IDENTIFICATION HAS CHANGED*, exactly when the watchdog is needed most.

So every call uses `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`.

**Cost:** SSH no longer verifies it is talking to the real VM. An attacker who can impersonate `paffenroth-23.dyn.wpi.edu:22025` on the network path from `linux.wpi.edu` could:
- accept the connection,
- receive our *public* keys, and
- make the watchdog believe the relock succeeded.

What such an attacker cannot do:
- steal our private keys, since public-key authentication never sends them;
- log in to the real VM as us.

We accept this risk because the path runs entirely inside the WPI network and the VM is a disposable course machine. The report discusses it further.
