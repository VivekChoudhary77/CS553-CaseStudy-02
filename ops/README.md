# ops/: VM watchdog and deployment

The professor destroys and rebuilds our VM without notice. After a rebuild:
- `~/.ssh/authorized_keys` contains only the class-wide shared key, which every student has.
- Our keys are gone.
- The host key changes.

`relock.sh` runs from cron on `linux.wpi.edu` every 2 minutes. It puts our keys back, reinstalls the app, and keeps the app running. It has to run there because that server is inside the WPI firewall and can reach the VM; GitHub Actions can't.

| File | Purpose |
|---|---|
| `relock.sh` | The watchdog. |
| `relock.env.example` | Config template. Copy it to `~/.cs553/relock.env` and `chmod 600` it. Never commit the real file. |
| `authorized_keys` | Public keys that must be authorized after every relock: laptop key and watchdog key. Safe to commit. |
| `setup_watchdog.md` | Step-by-step install and test runbook for the watchdog. |
| `deploy.sh` | Deploys the app: uploads the settings, then runs the installer on the VM. |
| `remote_install.sh` | The installer that runs on the VM. |
| `setup_deploy.md` | Step-by-step deploy and recovery runbook. |
| `../tests/test_deploy.sh` | Local tests of the deploy scripts: `bash tests/test_deploy.sh`. |
| `../tests/test_relock.sh` | Local simulation tests (no network): `bash tests/test_relock.sh`. |

## Four states

Each run tries to log in with our watchdog key and with the shared key, running the remote command `true`:

| Our key | Shared key | State | Action | Exit |
|---|---|---|---|---|
| works | rejected | **OK** | nothing | 0 |
| works | works | **ENFORCE** | replace `authorized_keys` with exactly `AUTH_KEYS`, using our key | 0 |
| rejected | works | **RELOCK** (wipe) | append `AUTH_KEYS` with the shared key → prove our key works → replace with exactly `AUTH_KEYS` using our key | 0 |
| rejected | rejected | **DOWN** | log only while the VM rebuilds; after `DOWN_ALERT_AFTER_MIN` (default 30) send **one** alert, then one "reachable again" message on recovery | 2 |

After ENFORCE or RELOCK, the script checks from the outside that our key works *and* the shared key is rejected. It then sends an optional Discord notification and runs the optional `POST_RELOCK_HOOK`, which we set to `deploy.sh` so the app is reinstalled after a wipe.

**Other exit codes:**
- `3`: bad config.
- `4`: our key is still rejected after the append.
- `5`: the post-relock verification failed.
- `6`: restarting or redeploying the app failed.

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

- **Schedule:** every 2 minutes. Real rebuilds were relocked about 40 s (2026-09-28) and 1 min 42 s (2026-10-01) after boot.
- **Why not faster:** with a check every 20 s, the WPI server was cut off from the VM and from Discord for about an hour, several times. We did not confirm the cause; it looked like an automatic block. During such an hour nothing can be repaired, so a slower schedule is safer.
- **Fewer failed logins:** the shared-key probe is a login that fails on purpose. While our key works it is tried only every `SHARED_CHECK_MIN` minutes (default 10). A wipe makes our key fail, and then the shared key is tried at once.
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

## Deployment and app recovery

`deploy.sh` installs or updates the app. It is safe to run again: a second run changes nothing.

1. **Check the settings file** (`~/.cs553/app.env`). It refuses to run if the file is empty, holds a private key, has no API key, or does not set `HOST=0.0.0.0` and `PORT=7860`.
2. **Upload the settings** to the VM over SSH standard input. Secrets never appear on a command line and never go through GitHub.
3. **Run `remote_install.sh` on the VM:**
   - install a pinned `uv`;
   - clone or update the repo from GitHub;
   - `uv sync --locked` (Python 3.11 and the exact package versions, with CPU-only PyTorch);
   - download the local model;
   - install a systemd service with `Restart=always` and a 3200 MB memory cap, so the app cannot starve SSH;
   - restart only if the code, the settings or the service changed;
   - wait until the app answers on port 7860.

**Exit codes of `deploy.sh`:** `0` healthy, `3` bad settings, `6` install or health check failed, `7` another run holds the lock.

**App check.** When `APP_CHECK_URL` is set, each watchdog run also requests the app's page:

| What it finds | Action |
|---|---|
| the app answers | nothing |
| the service was started less than `APP_GRACE_S` (180 s) ago | wait, it is still loading |
| the service is stopped or hung | `sudo systemctl restart`, Discord message |
| the app is not installed, or a restart did not help | run `deploy.sh`, at most every `DEPLOY_BACKOFF_MIN` (10) minutes |

It sends one Discord alert per problem, and one "healthy again" message afterwards. A crash is handled by systemd itself, without the watchdog.

**Measured on the VM:** first deploy 58 s; crash recovered in 34 s; stopped app in 20 s; deleted app in about 2 min; real rebuild on 2026-10-01: keys restored 1 min 42 s after boot, app back after 6 min 25 s.
