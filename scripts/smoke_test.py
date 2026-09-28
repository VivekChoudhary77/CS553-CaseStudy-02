"""Call each configured backend once with a tiny prompt; exit non-zero if none succeed.

Usage: uv run python scripts/smoke_test.py [--skip-local]
"""

from __future__ import annotations

import sys
import time

from prompt_enhancer.backends.base import Backend, BackendError
from prompt_enhancer.backends.gemini import build_gemini_backends
from prompt_enhancer.backends.local import LocalBackend
from prompt_enhancer.backends.openrouter import OpenRouterBackend
from prompt_enhancer.config import load_settings, setup_logging

SYSTEM = "You are a health check. Follow the instruction exactly."
PROMPT = "Reply with the single word OK"
MAX_TOKENS = 16


def check(backend: Backend) -> bool:
    available, reason = backend.availability()
    start = time.perf_counter()
    ok = False
    if available:
        try:
            backend.generate(SYSTEM, PROMPT, MAX_TOKENS, 0.0)
            ok, reason = True, "ok"
        except BackendError as exc:
            reason = exc.reason
        except Exception as exc:
            reason = f"error: {type(exc).__name__}"
    latency = time.perf_counter() - start
    status = "OK  " if ok else ("SKIP" if not available else "FAIL")
    print(f"{status} {backend.name:<11} model={backend.model_id or '-':<30} reason={reason:<32} latency={latency:.2f}s")
    return ok


def main() -> int:
    settings = load_settings()
    setup_logging("WARNING")
    # Every configured Gemini model is checked, so you can see which ones have quota left.
    backends: list[Backend] = [*build_gemini_backends(settings), OpenRouterBackend(settings)]
    if "--skip-local" not in sys.argv:
        local = LocalBackend(settings)
        local.load()  # synchronous here: we want to test the model, not the loading state
        backends.insert(0, local)
    results = [check(b) for b in backends]
    succeeded = sum(results)
    print(f"{succeeded}/{len(results)} backends/models succeeded")
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main())
