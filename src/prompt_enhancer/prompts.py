"""System prompt, length presets, and output post-processing."""

from __future__ import annotations

import re
from dataclasses import dataclass

BASE_SYSTEM_PROMPT = (
    "You are an expert prompt engineer. Rewrite the user's rough prompt into a clearer, "
    "more specific, more effective prompt for a large language model. Preserve the user's "
    "intent and any concrete details. Output ONLY the improved prompt — no preamble, no "
    "explanation, no quotes, no markdown code fences."
)


@dataclass(frozen=True)
class LengthPreset:
    name: str
    instruction: str
    api_max_tokens: int
    local_max_new_tokens: int


PRESETS: dict[str, LengthPreset] = {
    p.name: p
    for p in (
        LengthPreset("Short", "Keep the improved prompt to 2–3 sentences.", 256, 128),
        LengthPreset("Medium", "Write the improved prompt as one detailed paragraph.", 512, 256),
        LengthPreset(
            "Long",
            "Write a structured prompt with these labeled sections: "
            "Role, Context, Task, Constraints, Output format.",
            1024,
            384,
        ),
    )
}

LENGTHS = list(PRESETS)


def get_preset(length: str) -> LengthPreset:
    try:
        return PRESETS[length]
    except KeyError:
        raise ValueError(f"Unknown length preset: {length!r}") from None


def build_system_prompt(length: str) -> str:
    return f"{BASE_SYSTEM_PROMPT}\n\n{get_preset(length).instruction}"


def max_tokens_for(length: str, local: bool) -> int:
    preset = get_preset(length)
    return preset.local_max_new_tokens if local else preset.api_max_tokens


_FENCE_RE = re.compile(r"^```[\w+-]*[ \t]*\n(.*?)\n?```$", re.DOTALL)
_PREAMBLE_RE = re.compile(
    r"^(?:sure[,!.]?\s*)?(?:here\s+is|here's|here\s+are)\b[^\n]*:[ \t]*\n",
    re.IGNORECASE,
)


_QUOTE_PAIRS = {'"': '"', "“": "”"}


def clean_output(text: str) -> str:
    """Strip whitespace, a leading "Here is ...:" line, a single wrapping ``` fence,
    and a single pair of quotes wrapping the whole output."""
    text = (text or "").strip()
    text = _PREAMBLE_RE.sub("", text, count=1).strip()
    match = _FENCE_RE.match(text)
    if match:
        text = match.group(1).strip()
    if len(text) >= 2 and _QUOTE_PAIRS.get(text[0]) == text[-1]:
        inner = text[1:-1]
        if text[0] not in inner and text[-1] not in inner:  # only a true wrapper, not "a" and "b"
            text = inner.strip()
    return text
