# Deploying the app to the VM (group 25)

This guide installs Prompt Enhancer on the VM and switches on automatic recovery. Do the
watchdog guide (`setup_watchdog.md`) first: the deploy uses the same key and settings file.

**Where each command runs.** Every block starts with a comment:
- `# laptop`: a terminal on your laptop, in this repo's folder.
- `# linux.wpi.edu`: a shell on the WPI server (prompt `<wpi_user>@ccc-app-p-...`).
- `# VM`: a shell on the VM (prompt `student-admin@group25`). `sudo` never asks for a
  password there. If it does, you are in the wrong terminal.

From home you need the WPI VPN.

## How it works

```
linux.wpi.edu: deploy.sh
   1. checks the app settings file (~/.cs553/app.env)
   2. uploads it to the VM over SSH          (API keys never go through GitHub)
   3. runs remote_install.sh on the VM:
        install uv -> clone the repo from GitHub -> uv sync --locked
        -> download the local model -> install the systemd service
        -> restart only if something changed -> wait until the app answers
```

The app listens on port 7860 inside the VM and is reached from outside on port 8025.

## 1. Check the app port is reachable from linux.wpi.edu

```bash
# linux.wpi.edu
curl -sS -m 10 -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' http://paffenroth-23.dyn.wpi.edu:8025/
```

**Checkpoint:** before the first deploy this fails quickly ("Connection reset" or "Empty
reply"), which means the port is reachable and nothing is listening yet. A timeout after
10 s means a firewall blocks it.

## 2. Copy the app settings (API keys) to linux.wpi.edu

```bash
# laptop
scp .env <wpi_user>@linux.wpi.edu:~/.cs553/app.env
```

```bash
# linux.wpi.edu
chmod 600 ~/.cs553/app.env
grep -c '_API_KEY=.' ~/.cs553/app.env      # counts the keys without printing them
```

**Checkpoint:** the count is `2`. The file must have `HOST=0.0.0.0` and `PORT=7860`, or the
deploy refuses to run.

For Discord alerts from the resource monitor, copy the webhook line once:

```bash
# linux.wpi.edu
grep '^DISCORD_WEBHOOK_URL=' ~/.cs553/relock.env >> ~/.cs553/app.env
```

## 3. Copy the scripts

```bash
# laptop
scp ops/deploy.sh ops/remote_install.sh <wpi_user>@linux.wpi.edu:~/.cs553/
scp ops/relock.sh <wpi_user>@linux.wpi.edu:~/.cs553/relock.sh.new
```

```bash
# linux.wpi.edu
cd ~/.cs553
chmod 700 deploy.sh remote_install.sh relock.sh.new
mv relock.sh.new relock.sh
```

`relock.sh` is copied under a temporary name and then renamed, so cron never runs a
half-copied file.

## 4. First deploy

```bash
# linux.wpi.edu
~/.cs553/deploy.sh 2>&1 | tee ~/.cs553/deploy-first.log
```

**Checkpoint:** the last line is `deploy: done; app healthy on the VM`. Then open
`http://paffenroth-23.dyn.wpi.edu:8025` and try each backend.

Our first deploy on an empty VM took 58 s. Run it again and it reports `no changes` and
does not restart the app.

## 5. Switch on automatic recovery

```bash
# linux.wpi.edu
cat >> ~/.cs553/relock.env <<'EOF'

POST_RELOCK_HOOK=$HOME/.cs553/deploy.sh
APP_CHECK_URL=http://paffenroth-23.dyn.wpi.edu:8025/
EOF
~/.cs553/relock.sh; echo "exit=$?"
```

**Checkpoint:** the line ends in `; app up` and `exit=0`.

| Setting | What it switches on |
|---|---|
| `POST_RELOCK_HOOK` | after a wipe, once the keys are restored, reinstall the app |
| `APP_CHECK_URL` | every run, check the app answers; restart it, or redeploy if needed |

## 6. Test the recovery

Run each on the VM, then watch `~/.cs553/relock.log` on linux.wpi.edu and Discord.

| Test | Command on the VM | Recovered by | Our result |
|---|---|---|---|
| App crashes | `sudo kill -9 <pid>` | systemd | back in 34 s |
| App stopped | `sudo systemctl stop prompt-enhancer` | watchdog restart | 20 s (worst case about 2 min 15 s) |
| App deleted | `sudo systemctl stop prompt-enhancer; rm -rf ~/app` | watchdog redeploy | about 2 min |
| VM rebuilt | done by the professor (Oct 1) | relock, then redeploy | keys restored 1 min 42 s after boot, app back after 6 min 25 s |

## After changing the app's code

Push to GitHub first, then run `~/.cs553/deploy.sh` on linux.wpi.edu. The VM always takes
the code from GitHub, so unpushed changes never reach it.

## Things that went wrong, and what to do

- **Wrong terminal.** A command for the VM typed on linux.wpi.edu fails with
  `Could not resolve hostname cs553` or asks for a `sudo` password. Check the prompt.
- **Cron lives on one machine only.** `linux.wpi.edu` is several machines. Files are shared,
  the crontab is not. Change the cron job only on the machine where it was installed.
- **Do not check too often.** With a check every 20 seconds, the WPI server was cut off
  from the VM and from Discord for about an hour, several times. We did not confirm the
  cause; it looked like an automatic block. We now run every 2 minutes.
- **Slow redeploy.** When all VMs were rebuilt together, the redeploy took 4 min 45 s
  instead of 58 s, because every group was downloading at once.
