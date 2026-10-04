# Prompt Enhancer

A small Gradio web app that rewrites a rough prompt into a clearer one. It was built for CS553 (MLOps) Case Study 2 and runs on a small CPU-only VM (2 CPUs, 4 GB of memory) that is rebuilt without notice.

It contains both products the case study asks for:
- **API-based:** the Gemini and OpenRouter backends.
- **Locally executed:** a small Qwen model that runs on the VM's CPU.

## How it works

| Backend | How it runs |
|---|---|
| **Local** | `Qwen/Qwen2.5-0.5B-Instruct` on the CPU, with `transformers`. It loads in the background at startup. |
| **Gemini** | Google's native `generateContent` API. `GEMINI_MODEL` may list several models, tried in order. |
| **OpenRouter** | OpenRouter's OpenAI-compatible API, with the `openai` SDK. |

You pick a backend on the page. If it fails, the app tries the others, and Local goes last unless you picked it:

| Selected | Try order |
|---|---|
| Local | Local → Gemini → OpenRouter |
| Gemini | Gemini → OpenRouter → Local |
| OpenRouter | OpenRouter → Gemini → Local |

The page shows a warning for each backend that failed and a trace of what happened, for example:
`Gemini ❌ rate limited (429) → OpenRouter ✅ 3.1 s`

## Setup

You need [`uv`](https://docs.astral.sh/uv/). It installs Python 3.11 and the CPU-only PyTorch build.

```bash
uv sync
cp .env.example .env        # then fill in your keys and model names
uv run python scripts/download_model.py
uv run python scripts/smoke_test.py
uv run prompt-enhancer      # open http://localhost:7860
```

A missing API key never stops the app. That backend is shown as not configured and skipped.

## Settings

All settings go in `.env`, which git ignores. `.env.example` lists every one with a comment.

| Variable | Default | Notes |
|---|---|---|
| `GEMINI_API_KEY`, `GEMINI_MODEL` | blank | One model, or a comma-separated list tried in order |
| `GEMINI_REASONING_EFFORT` | `low` | Use `none`: with reasoning on, short answers were cut off |
| `OPENROUTER_API_KEY`, `OPENROUTER_MODEL` | blank | |
| `OPENROUTER_REASONING_EFFORT` | `none` | `none` turns reasoning off |
| `LOCAL_MODEL_ID` | `Qwen/Qwen2.5-0.5B-Instruct` | Must fit in about 2 GB |
| `LOCAL_NUM_THREADS`, `LOCAL_MAX_TIME_S` | `2`, `90` | CPU threads and the time limit for one local answer |
| `API_TIMEOUT_S` | `20` | Time limit for one API call |
| `HOST`, `PORT` | `0.0.0.0`, `7860` | Keep these on the VM. Port 7860 is reached from outside on port 8025 |
| `DISCORD_WEBHOOK_URL` | blank | For the resource alerts below. Blank means no alerts |

API keys and prompt text are never written to the logs.

## Tests

```bash
uv run pytest                 # the app
bash tests/test_relock.sh     # the watchdog
bash tests/test_deploy.sh     # the deploy scripts
```

None of them needs a network, a model download or the VM.

## Deployment and recovery

The scripts and guides are in [`ops/`](ops/):

| File | What it is |
|---|---|
| [`ops/README.md`](ops/README.md) | How the watchdog, the deploy and the recovery work |
| [`ops/setup_watchdog.md`](ops/setup_watchdog.md) | Step-by-step: lock the VM to our SSH keys |
| [`ops/setup_deploy.md`](ops/setup_deploy.md) | Step-by-step: deploy the app and switch on recovery |

In short: `ops/deploy.sh` installs the app on the VM as a systemd service. `ops/relock.sh` runs from cron on `linux.wpi.edu` every 2 minutes. After a rebuild it restores our SSH keys and reinstalls the app, and it restarts the app if it stops answering.

## Resource monitoring and adaptive response

The app watches the machine it runs on and reduces its own load when the machine is near capacity.

**How usage is measured.** A background thread (`src/prompt_enhancer/monitor.py`) takes a sample every 5 seconds:
- **CPU %:** from `/proc/stat`, the share of time since the last sample that was not idle.
- **Memory %:** from `/proc/meminfo`, as `1 - MemAvailable / MemTotal`.

No extra package or service is needed. On the VM, with the local model loaded, memory sits at about 60%.

**Thresholds.**

| Setting | Default | Meaning |
|---|---|---|
| `CPU_HIGH_PCT` | `80` | CPU threshold |
| `MEM_HIGH_PCT` | `85` | Memory threshold |
| `MONITOR_TRIGGER_SAMPLES` | `4` | Samples in a row over a threshold before the app goes busy (20 s), so a short spike does not count |
| `MONITOR_CLEAR_SAMPLES` | `6` | Samples in a row under the clear level before it returns to normal (30 s) |
| `MONITOR_CLEAR_MARGIN_PCT` | `10` | The clear level is this far below each threshold (CPU under 70%, memory under 75%) |
| `MONITOR_INTERVAL_S` | `5` | Seconds between samples |
| `MONITOR_ENABLED` | `true` | Set to `false` to switch the monitor off |

**What happens when a threshold is crossed.** The app goes into busy mode and:
1. **Notifies the team** on Discord:
   `[group25] resource alert on group25: CPU 100% / memory 59% (thresholds 80% / 85%) -> local model paused`
2. **Reduces the workload.** The local model, which is the CPU-heavy part, is paused. Requests go to Gemini or OpenRouter instead, and the trace shows why:
   `Local ❌ paused: system near capacity → Gemini ✅ 4.0 s`
3. **Tells the user.** The page shows `Mode: busy` and a warning.

If Gemini and OpenRouter both fail while the app is busy, the request fails with an error listing each reason.

**How it returns to normal.** When CPU and memory both stay under the clear level for 30 seconds, the local model is available again, the warning disappears, and Discord gets:
`[group25] resources back to normal on group25: CPU 2% / memory 59% -> local model resumed`

Messages are sent only when the mode changes, never on every sample.

**Where to see it.** The page shows a live line (`System: CPU 42% · Memory 61% · Mode: normal`) and a chart of the last 10 minutes.

**How to test it.** Run two busy loops on the VM, one per CPU:

```bash
timeout 60 sh -c 'while :; do :; done' &
timeout 60 sh -c 'while :; do :; done' &
```

In our test on the VM, the alert came 23 s after the load started, and the app returned to normal 28 s after it ended.

## Size and limits

- **Disk on the VM:** about 2.3 GB (packages 1.2 GB, model 954 MB).
- **Memory:** about 2.4 GB with the local model loaded. The service is capped at 3200 MB.
- **Local model quality:** the 0.5B model is a fallback. Its rewrites are weaker than Gemini's or OpenRouter's, and it sometimes answers the prompt instead of rewriting it.
