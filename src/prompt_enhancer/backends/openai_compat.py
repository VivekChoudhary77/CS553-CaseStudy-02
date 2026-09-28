"""Shared logic for backends reached through an OpenAI-compatible chat completions API."""

from __future__ import annotations

import logging
from typing import Any

import openai

from prompt_enhancer.backends.base import (
    Backend,
    BackendError,
    BackendTimeoutError,
    EmptyResponseError,
    NotConfiguredError,
)
from prompt_enhancer.prompts import clean_output

log = logging.getLogger(__name__)


def reason_for(exc: openai.OpenAIError) -> str:
    """Map an openai exception to a short reason. Order matters: subclasses first."""
    if isinstance(exc, openai.APITimeoutError):  # subclass of APIConnectionError
        return "timeout"
    if isinstance(exc, openai.RateLimitError):
        return "rate limited (429)"
    if isinstance(exc, (openai.AuthenticationError, openai.PermissionDeniedError)):
        return "auth failed (401/403)"
    if isinstance(exc, openai.APIStatusError):
        return f"HTTP {exc.status_code}"
    if isinstance(exc, openai.APIConnectionError):
        return "connection error"
    return f"api error: {type(exc).__name__}"


class OpenAICompatBackend(Backend):
    is_local = False

    def __init__(
        self, name: str, api_key: str, model_id: str, base_url: str, timeout_s: float
    ) -> None:
        self.name = name
        self.model_id = model_id
        self._api_key = api_key
        self._base_url = base_url
        self._timeout_s = timeout_s
        self._client: openai.OpenAI | None = None

    def availability(self) -> tuple[bool, str]:
        if not (self._api_key and self.model_id):
            return False, "not configured"
        return True, "ok"

    def _get_client(self) -> openai.OpenAI:
        if self._client is None:
            # max_retries=0: failover across backends is the retry strategy.
            self._client = openai.OpenAI(
                api_key=self._api_key,
                base_url=self._base_url,
                timeout=self._timeout_s,
                max_retries=0,
            )
        return self._client

    def extra_params(self) -> dict[str, Any]:
        """Backend-specific keyword arguments for chat.completions.create."""
        return {}

    def generate(
        self, system_prompt: str, user_prompt: str, max_tokens: int, temperature: float
    ) -> str:
        if self.availability()[0] is False:
            raise NotConfiguredError()
        try:
            response = self._get_client().chat.completions.create(
                model=self.model_id,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                max_tokens=max_tokens,
                temperature=temperature,
                **self.extra_params(),
            )
        except openai.APITimeoutError:
            raise BackendTimeoutError() from None
        except openai.OpenAIError as exc:
            raise BackendError(reason_for(exc)) from None

        choices = getattr(response, "choices", None) or []
        content = choices[0].message.content if choices and choices[0].message else None
        if choices and choices[0].finish_reason == "length":
            usage = getattr(response, "usage", None)
            log.warning(
                "%s output hit max_tokens=%d (completion_tokens=%s); it may be cut off",
                self.name,
                max_tokens,
                getattr(usage, "completion_tokens", "?"),
            )
        text = clean_output(content or "")
        if not text:
            raise EmptyResponseError()
        return text
