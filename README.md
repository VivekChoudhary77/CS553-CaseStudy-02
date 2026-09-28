# Prompt Enhancer

A small Gradio web app that rewrites a rough prompt into a clearer, more effective one. You can choose one of three LLM backends. If that backend fails, the app automatically tries the others.

Built for CS553 (MLOps) Case Study 2. The app is deliberately simple. The real target is a small, CPU-only, frequently wiped Ubuntu VM (2 vCPU, 4 GiB RAM), so installs are reproducible with `uv` and the app degrades gracefully when a backend is missing.

## Architecture

| Backend | How it runs |
|---|---|
| **Local** | A small instruct model (default `Qwen/Qwen2.5-0.5B-Instruct`) that runs in-process on CPU with 🤗 `transformers`. It loads in a background thread at startup. |
| **Gemini** | Google AI Studio's native `generateContent` REST API, called with the Python standard library (no vendor SDK). Google's OpenAI-compatible endpoint sometimes ended replies after a few tokens while still reporting a normal stop; the native API did not. |
| **OpenRouter** | OpenRouter's OpenAI-compatible endpoint, called with the `openai` SDK. |

The **Backend** radio sets the *preferred* backend. The router tries it first, then the others. When Local isn't preferred, it always goes **last**, because it's the one backend that can't be rate-limited or lose network access.

| Selected | Try order |
|---|---|
| Local | Local → Gemini → OpenRouter |
| Gemini | Gemini → OpenRouter → Local |
| OpenRouter | OpenRouter → Gemini → Local |

The router skips a backend immediately, with no network call, if it is `not configured` or its model is `still loading`.

`GEMINI_MODEL` can list several Gemini models. They are tried in order within the Gemini step, for example:
`Gemini (gemini-3.1-flash-lite) ❌ HTTP 503 → Gemini (gemini-3.5-flash) ✅`.

Rate limits, overload and timeouts move on to the next model. A missing config or a rejected API key skips the remaining Gemini models, because they share the key. The UI shows a warning toast for each failed attempt and a success toast naming the backend that answered. It also shows a **fallback trace**, for example:
`Gemini ❌ rate limited (429) → OpenRouter ✅ 3.1 s`.

```
src/prompt_enhancer/
├── app.py            Gradio UI + main() entry point
├── config.py         .env loading, Settings dataclass, logging setup
├── prompts.py        system prompt, Short/Medium/Long presets, output clean-up
├── router.py         failover logic (no gradio import)
└── backends/
    ├── base.py           Backend interface, BackendError, Attempt/EnhanceResult
    ├── openai_compat.py  OpenAI-compatible client + error mapping (used by OpenRouter)
    ├── gemini.py         native Gemini REST API
    ├── openrouter.py
    └── local.py          CPU transformers backend (background load, one-at-a-time lock)
scripts/
├── download_model.py     pre-fetch the local model into the HF cache
└── smoke_test.py         one tiny call per configured backend (health check)
```

## Setup

You need [`uv`](https://docs.astral.sh/uv/). It installs Python 3.11 and the **CPU-only** PyTorch build automatically.

```bash
uv sync
cp .env.example .env        # then fill in keys and model ids
uv run python scripts/download_model.py
uv run python scripts/smoke_test.py
uv run prompt-enhancer      # open http://localhost:7860
uv run pytest
```

To check that torch is the CPU build (it should print a version ending in `+cpu`, then `False`):

```bash
uv run python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

A missing API key or model never stops the app from starting. That backend just shows ❌ and is skipped. `smoke_test.py` exits non-zero if no backend succeeds; `--skip-local` tests only the remote APIs.

## Environment variables

All of these go in `.env`, which git ignores. See `.env.example`.

| Variable | Default | Notes |
|---|---|---|
| `GEMINI_API_KEY` | *(blank)* | Blank → Gemini "not configured" |
| `GEMINI_MODEL` | *(blank)* | Exact model id from Google AI Studio, or a comma-separated list such as `gemini-3.1-flash-lite,gemini-3.5-flash,gemini-2.5-flash`. The models are tried in order, each as its own step, before failover moves to the next backend. Put the model with the biggest free quota first |
| `GEMINI_BASE_URL` | `https://generativelanguage.googleapis.com/v1beta` | The old `…/v1beta/openai/` URL is also accepted |
| `GEMINI_REASONING_EFFORT` | `low` | `none`/`minimal`/`low`/`medium`/`high` → thinking budget 0/512/1024/8192/24576 tokens; blank omits it. **Use `none`** unless you need reasoning: with `low`, thinking tokens count against the cap and Gemini 2.5 Flash cut Short/Medium outputs off mid-sentence (logged as a warning) |
| `OPENROUTER_API_KEY` | *(blank)* | Blank → OpenRouter "not configured" |
| `OPENROUTER_MODEL` | *(blank)* | Any OpenRouter model id (e.g. a `:free` model) |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | |
| `OPENROUTER_REASONING_EFFORT` | `none` | Sent as `reasoning.effort`; `none` turns reasoning off (about 2× faster, no hidden reasoning tokens counted against the cap). Blank uses the model's default |
| `LOCAL_MODEL_ID` | `Qwen/Qwen2.5-0.5B-Instruct` | Must fit in ~2 GB fp32; alternative: `HuggingFaceTB/SmolLM2-360M-Instruct` |
| `LOCAL_NUM_THREADS` | `2` | `torch.set_num_threads` |
| `LOCAL_MAX_TIME_S` | `90` | Hard wall-clock limit for one local generation |
| `API_TIMEOUT_S` | `20` | Per-request timeout for remote APIs (no SDK retries) |
| `HOST` | `0.0.0.0` | Must stay `0.0.0.0` on the VM (reached via port forward on `eth0`) |
| `PORT` | `7860` | |
| `LOG_LEVEL` | `INFO` | Logs go to stdout; API keys and prompt text are never logged, only lengths |

The Gemini free tier is small. For Gemini 2.5 Flash it is 5 requests per minute and 20 per day, which you can check under AI Studio → Rate Limit. Past that limit, requests fail with `rate limited (429)` and move on to the next Gemini model, then to the next backend. Put a model with a larger quota first in `GEMINI_MODEL`, such as `gemini-3.1-flash-lite` (15 per minute, 500 per day). `gemini-2.5-flash-lite` returns 404 ("no longer available to new users") for new keys.

Once the model has been downloaded, you can set `HF_HUB_OFFLINE=1` to stop the local backend from contacting the Hub at startup.

## Tests

```bash
uv run pytest
```

The tests use fake backends, so they need no network and download no model. They cover:
- failover order
- skip reasons
- empty-output handling
- `on_event` callbacks
- generation kwargs
- length presets
- output clean-up
- config defaults
- mapping of API errors to readable reasons

## Demoing failover

You can override variables for a single run on the command line without editing `.env`. Values set this way take precedence over `.env`.

1. **Gemini → OpenRouter.** Run `GEMINI_API_KEY= uv run prompt-enhancer` and select **Gemini**. You'll get the warning toast *"⚠️ Gemini failed (not configured) — trying OpenRouter"*, and the output comes from OpenRouter.
2. **… → Local.** Also break OpenRouter:
   `GEMINI_API_KEY= OPENROUTER_MODEL=bogus/model uv run prompt-enhancer`. Gemini and OpenRouter both fail and Local answers. The trace shows the whole chain.
3. **Local still loading → Gemini.** Select **Local** and click Enhance in the first few seconds after startup, while the status line still shows ⏳ loading. The request falls through to Gemini.
4. **Everything fails.** Break both remote backends and select **Local** while it is still loading. An error toast lists each backend with its reason.

## Resource notes

These numbers were measured on a laptop CPU with `LOCAL_NUM_THREADS=2`.

**Load time:** the local model loads in about 7 s with a warm disk cache and about 21 s with a cold one.

**Local generation latency (warm):**

| Preset | Token cap | Latency |
|---|---|---|
| Short | 128 | ~2–8 s |
| Medium | 256 | ~4–8 s |
| Long | 384 | ~4–11 s |

**Memory:**
- About 2.4–2.5 GB of resident (anon) memory with the model loaded and generating.
- The app ran all three presets under a hard 2.6 GiB cgroup limit with swap disabled, with no OOM.
- `VmHWM` reports a higher, transient ~3.2–3.5 GB peak while loading. That extra is ~1 GB of clean, memory-mapped weight-file pages held during the bf16 → fp32 upcast, which the kernel can reclaim.

The 0.5B local model is a fallback. Its rewrites are noticeably weaker than Gemini's or OpenRouter's, and it sometimes answers the prompt instead of rewriting it.
