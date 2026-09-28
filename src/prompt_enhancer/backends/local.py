"""Local CPU backend using Hugging Face transformers.

torch/transformers are imported lazily so the UI can start before they finish importing.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

from prompt_enhancer.backends.base import (
    Backend,
    BackendError,
    EmptyResponseError,
    ModelLoadingError,
    OutOfMemoryBackendError,
)
from prompt_enhancer.config import Settings
from prompt_enhancer.prompts import clean_output

log = logging.getLogger(__name__)

STATUS_LOADING = "loading"
STATUS_READY = "ready"


def build_generation_kwargs(
    max_new_tokens: int, temperature: float, max_time: float
) -> dict[str, Any]:
    """Sampling kwargs for model.generate. Temperature 0 means greedy decoding."""
    kwargs: dict[str, Any] = {
        "max_new_tokens": max_new_tokens,
        "max_time": max_time,
        "repetition_penalty": 1.1,
    }
    if temperature <= 0:
        kwargs["do_sample"] = False
    else:
        kwargs.update(do_sample=True, temperature=temperature, top_p=0.9)
    return kwargs


def _is_oom(exc: BaseException) -> bool:
    if isinstance(exc, MemoryError):
        return True
    msg = str(exc).lower()
    return "out of memory" in msg or "can't allocate memory" in msg or "cannot allocate memory" in msg


class LocalBackend(Backend):
    name = "Local"
    is_local = True

    def __init__(self, settings: Settings) -> None:
        self.model_id = settings.local_model_id
        self._num_threads = settings.local_num_threads
        self._max_time_s = settings.local_max_time_s
        self._status = STATUS_LOADING
        self._status_lock = threading.Lock()
        self._generate_lock = threading.Lock()  # one generation at a time (4 GiB RAM)
        self._load_thread: threading.Thread | None = None
        self._model: Any = None
        self._tokenizer: Any = None

    # ---- loading -------------------------------------------------------------------

    @property
    def status(self) -> str:
        with self._status_lock:
            return self._status

    def _set_status(self, status: str) -> None:
        with self._status_lock:
            self._status = status

    def start_background_load(self) -> None:
        if self._load_thread is not None:
            return
        self._load_thread = threading.Thread(target=self.load, name="local-model-load", daemon=True)
        self._load_thread.start()

    def wait_until_loaded(self, timeout: float | None = None) -> str:
        if self._load_thread is not None:
            self._load_thread.join(timeout)
        return self.status

    def load(self) -> None:
        start = time.perf_counter()
        log.info("Local model load started: %s (threads=%d)", self.model_id, self._num_threads)
        try:
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer

            torch.set_num_threads(self._num_threads)
            tokenizer = AutoTokenizer.from_pretrained(self.model_id)
            model = AutoModelForCausalLM.from_pretrained(
                self.model_id, dtype=torch.float32, low_cpu_mem_usage=True
            )
            model.to("cpu")  # always CPU, even if CUDA happens to be available
            model.eval()
        except Exception as exc:
            reason = "out of memory" if _is_oom(exc) else f"{type(exc).__name__}: {exc}"
            self._set_status(f"failed: {reason}")
            log.error("Local model load failed after %.1f s: %s", time.perf_counter() - start, reason)
            return
        self._tokenizer, self._model = tokenizer, model
        self._set_status(STATUS_READY)
        log.info("Local model loaded in %.1f s: %s", time.perf_counter() - start, self.model_id)

    # ---- Backend interface ---------------------------------------------------------

    def availability(self) -> tuple[bool, str]:
        status = self.status
        if status == STATUS_READY:
            return True, "ok"
        if status == STATUS_LOADING:
            return False, "model still loading"
        return False, f"model load {status}"

    def _encode(self, messages: list[dict[str, str]]) -> Any:
        common = dict(add_generation_prompt=True, return_tensors="pt", return_dict=True)
        try:
            # Only matters for Qwen3-style templates; never enable thinking locally.
            return self._tokenizer.apply_chat_template(messages, enable_thinking=False, **common)
        except Exception:
            return self._tokenizer.apply_chat_template(messages, **common)

    def generate(
        self, system_prompt: str, user_prompt: str, max_tokens: int, temperature: float
    ) -> str:
        available, reason = self.availability()
        if not available:
            raise ModelLoadingError() if self.status == STATUS_LOADING else BackendError(reason)
        import torch

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        kwargs = build_generation_kwargs(max_tokens, temperature, self._max_time_s)
        with self._generate_lock:
            try:
                inputs = self._encode(messages)
                input_len = inputs["input_ids"].shape[-1]
                with torch.inference_mode():
                    output = self._model.generate(
                        **inputs,
                        **kwargs,
                        pad_token_id=self._tokenizer.pad_token_id or self._tokenizer.eos_token_id,
                    )
                new_tokens = output[0][input_len:]
                text = self._tokenizer.decode(new_tokens, skip_special_tokens=True)
            except BackendError:
                raise
            except Exception as exc:
                if _is_oom(exc):
                    raise OutOfMemoryBackendError() from None
                raise BackendError(f"local error: {type(exc).__name__}") from None
        text = clean_output(text)
        if not text:
            raise EmptyResponseError()
        return text


_instance: LocalBackend | None = None
_instance_lock = threading.Lock()


def get_local_backend(settings: Settings) -> LocalBackend:
    """Process-wide singleton: exactly one local model is ever loaded."""
    global _instance
    with _instance_lock:
        if _instance is None:
            _instance = LocalBackend(settings)
        return _instance
