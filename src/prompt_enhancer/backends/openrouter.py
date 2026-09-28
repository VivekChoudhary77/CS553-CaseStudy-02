"""OpenRouter via its OpenAI-compatible endpoint."""

from __future__ import annotations

from typing import Any

from prompt_enhancer.backends.openai_compat import OpenAICompatBackend
from prompt_enhancer.config import Settings

ATTRIBUTION_HEADERS = {
    "HTTP-Referer": "http://localhost:7860",
    "X-Title": "CS553 Prompt Enhancer",
}


class OpenRouterBackend(OpenAICompatBackend):
    def __init__(self, settings: Settings) -> None:
        super().__init__(
            name="OpenRouter",
            api_key=settings.openrouter_api_key,
            model_id=settings.openrouter_model,
            base_url=settings.openrouter_base_url,
            timeout_s=settings.api_timeout_s,
        )
        self._reasoning_effort = settings.openrouter_reasoning_effort

    def extra_params(self) -> dict[str, Any]:
        params: dict[str, Any] = {"extra_headers": ATTRIBUTION_HEADERS}
        if self._reasoning_effort:
            # OpenRouter's unified reasoning control; "none" turns reasoning off.
            params["extra_body"] = {"reasoning": {"effort": self._reasoning_effort}}
        return params
