# Used Opus 5.5 with High Effort, for the Gemini backend.
# prompt: Call Gemini through Google's native generateContent REST API with the standard library,
#   because the OpenAI-compatible endpoint cut replies short. Send the key in a header, map the
#   reasoning effort to a thinking budget, turn blocked replies and HTTP errors into clear
#   reasons, and build one backend for each model listed in GEMINI_MODEL.

"""Gemini via Google's native generateContent REST API (stdlib HTTP, no vendor SDK).

The OpenAI-compatible endpoint was dropped because it sometimes ends a reply after a
few tokens while still reporting finish_reason="stop"; the native API did not.
"""

from __future__ import annotations

import json
import logging
import socket
import urllib.error
import urllib.request
from typing import Any

from prompt_enhancer.backends.base import (
    Backend,
    BackendError,
    BackendTimeoutError,
    EmptyResponseError,
    NotConfiguredError,
)
from prompt_enhancer.config import Settings
from prompt_enhancer.prompts import clean_output

log = logging.getLogger(__name__)

# GEMINI_REASONING_EFFORT -> thinkingBudget (tokens). "none" turns thinking off.
THINKING_BUDGETS = {"none": 0, "minimal": 512, "low": 1024, "medium": 8192, "high": 24576}

# finishReason values that mean the reply was withheld or cut short by the API.
BLOCKED_REASONS = {"SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE", "OTHER"}


def native_base_url(base_url: str) -> str:
    """Accept the old OpenAI-compatible URL (…/v1beta/openai/) as well as the native one."""
    url = base_url.rstrip("/")
    if url.endswith("/openai"):
        url = url[: -len("/openai")]
    return url


def build_request_body(
    system_prompt: str, user_prompt: str, max_tokens: int, temperature: float, reasoning_effort: str
) -> dict[str, Any]:
    config: dict[str, Any] = {"maxOutputTokens": max_tokens, "temperature": temperature}
    if reasoning_effort:
        config["thinkingConfig"] = {"thinkingBudget": THINKING_BUDGETS[reasoning_effort]}
    return {
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
        "generationConfig": config,
    }


def reason_for_http(status: int, body: str) -> str:
    message = body.lower()
    if status == 429:
        return "rate limited (429)"
    if status in (401, 403):
        return "auth failed (401/403)"
    if status == 400 and ("api key" in message or "api_key" in message):
        return "auth failed (invalid API key)"  # Google answers a bad key with 400
    if status == 400 and "thinking" in message:
        return "HTTP 400 (reasoning_effort rejected)"
    return f"HTTP {status}"


def parse_response(data: dict[str, Any]) -> tuple[str, str]:
    """Return (text, finishReason). Raise BackendError if the reply was blocked."""
    candidates = data.get("candidates") or []
    if not candidates:
        block = (data.get("promptFeedback") or {}).get("blockReason")
        if block:
            raise BackendError(f"blocked ({block.lower()})")
        raise EmptyResponseError()
    candidate = candidates[0]
    finish = candidate.get("finishReason", "")
    if finish in BLOCKED_REASONS:
        raise BackendError(f"blocked ({finish.lower()})")
    parts = (candidate.get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
    return text, finish


def build_gemini_backends(settings: Settings) -> list[GeminiBackend]:
    """One backend per configured model, in GEMINI_MODEL order (the router tries each)."""
    return [GeminiBackend(settings, m) for m in settings.gemini_models] or [GeminiBackend(settings, "")]


class GeminiBackend(Backend):
    name = "Gemini"
    is_local = False

    def __init__(self, settings: Settings, model_id: str | None = None) -> None:
        if model_id is None:
            model_id = next(iter(settings.gemini_models), "")
        self.model_id = model_id
        self._api_key = settings.gemini_api_key
        self._base_url = native_base_url(settings.gemini_base_url)
        self._timeout_s = settings.api_timeout_s
        effort = settings.gemini_reasoning_effort.lower()
        if effort and effort not in THINKING_BUDGETS:
            log.warning(
                "Unknown GEMINI_REASONING_EFFORT %r (expected one of %s); omitting it",
                effort,
                ", ".join(THINKING_BUDGETS),
            )
            effort = ""
        self._reasoning_effort = effort

    def availability(self) -> tuple[bool, str]:
        if not (self._api_key and self.model_id):
            return False, "not configured"
        return True, "ok"

    def _post(self, body: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self._base_url}/models/{self.model_id}:generateContent",
            data=json.dumps(body).encode(),
            # Key goes in a header, never the URL, so it can't leak into logs.
            headers={"Content-Type": "application/json", "x-goog-api-key": self._api_key},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout_s) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise BackendError(reason_for_http(exc.code, detail)) from None
        except (TimeoutError, socket.timeout):
            raise BackendTimeoutError() from None
        except urllib.error.URLError as exc:
            if isinstance(exc.reason, (TimeoutError, socket.timeout)):
                raise BackendTimeoutError() from None
            raise BackendError("connection error") from None
        except json.JSONDecodeError:
            raise BackendError("invalid response") from None

    def generate(
        self, system_prompt: str, user_prompt: str, max_tokens: int, temperature: float
    ) -> str:
        if not self.availability()[0]:
            raise NotConfiguredError()
        body = build_request_body(
            system_prompt, user_prompt, max_tokens, temperature, self._reasoning_effort
        )
        text, finish = parse_response(self._post(body))
        if finish == "MAX_TOKENS":
            log.warning("Gemini output hit maxOutputTokens=%d; it may be cut off", max_tokens)
        text = clean_output(text)
        if not text:
            raise EmptyResponseError()
        return text
