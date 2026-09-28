"""Pre-fetch LOCAL_MODEL_ID into the Hugging Face cache (respects HF_HOME).

Usage: uv run python scripts/download_model.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from huggingface_hub import snapshot_download

from prompt_enhancer.config import load_settings

# Only what AutoTokenizer / AutoModelForCausalLM need; skip GGUF/ONNX/other-framework weights.
ALLOW_PATTERNS = ["*.json", "*.safetensors", "*.txt", "*.model", "*.tiktoken", "*.jinja"]


def dir_size_bytes(path: Path) -> int:
    # Snapshot entries are symlinks into blobs/; resolve them to count real bytes.
    return sum(p.resolve().stat().st_size for p in path.rglob("*") if p.is_file())


def main() -> int:
    settings = load_settings()
    model_id = settings.local_model_id
    print(f"Downloading {model_id} ...", flush=True)
    start = time.perf_counter()
    try:
        path = Path(snapshot_download(repo_id=model_id, allow_patterns=ALLOW_PATTERNS))
    except Exception as exc:
        print(f"Download failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    elapsed = time.perf_counter() - start
    size_mb = dir_size_bytes(path) / 1024**2
    print(f"Done: {model_id}\n  path: {path}\n  size: {size_mb:.0f} MB\n  time: {elapsed:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
