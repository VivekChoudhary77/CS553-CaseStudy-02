# Used Opus 5.5 with High Effort, for the tests that API errors become readable reasons.
# prompt: Write pytest tests that openai exceptions and Gemini HTTP errors are mapped to the right
#   short reasons, and that the Gemini request body and response parsing are correct, including
#   blocked replies.

import httpx2
import openai
import pytest

from prompt_enhancer.backends.base import BackendError, EmptyResponseError
from prompt_enhancer.backends.gemini import (
    build_request_body,
    native_base_url,
    parse_response,
    reason_for_http,
)
from prompt_enhancer.backends.openai_compat import reason_for

REQUEST = httpx2.Request("POST", "https://example.invalid/v1/chat/completions")


def status_error(cls, code, message="error"):
    return cls(message, response=httpx2.Response(code, request=REQUEST), body=None)


# ---- OpenAI-compatible (OpenRouter) ------------------------------------------------


@pytest.mark.parametrize(
    "exc, reason",
    [
        (openai.APITimeoutError(request=REQUEST), "timeout"),
        (openai.APIConnectionError(request=REQUEST), "connection error"),
        (status_error(openai.RateLimitError, 429), "rate limited (429)"),
        (status_error(openai.AuthenticationError, 401), "auth failed (401/403)"),
        (status_error(openai.PermissionDeniedError, 403), "auth failed (401/403)"),
        (status_error(openai.NotFoundError, 404), "HTTP 404"),
        (status_error(openai.InternalServerError, 503), "HTTP 503"),
    ],
)
def test_reason_for(exc, reason):
    assert reason_for(exc) == reason


# ---- Gemini native API --------------------------------------------------------------


@pytest.mark.parametrize(
    "status, body, reason",
    [
        (429, "quota exceeded", "rate limited (429)"),
        (403, "forbidden", "auth failed (401/403)"),
        (400, '{"message": "Please pass a valid API key"}', "auth failed (invalid API key)"),
        (400, '{"message": "Thinking budget is not supported"}', "HTTP 400 (reasoning_effort rejected)"),
        (404, "model not found", "HTTP 404"),
        (503, "high demand", "HTTP 503"),
    ],
)
def test_gemini_reason_for_http(status, body, reason):
    assert reason_for_http(status, body) == reason


def test_gemini_base_url_accepts_openai_compat_url():
    native = "https://generativelanguage.googleapis.com/v1beta"
    assert native_base_url(native + "/openai/") == native
    assert native_base_url(native + "/") == native


def test_gemini_request_body():
    body = build_request_body("sys", "user", 512, 0.7, "none")
    assert body["systemInstruction"]["parts"][0]["text"] == "sys"
    assert body["contents"] == [{"role": "user", "parts": [{"text": "user"}]}]
    assert body["generationConfig"] == {
        "maxOutputTokens": 512,
        "temperature": 0.7,
        "thinkingConfig": {"thinkingBudget": 0},
    }
    assert "thinkingConfig" not in build_request_body("s", "u", 1, 0.0, "")["generationConfig"]


def test_gemini_parse_response_skips_thought_parts():
    data = {"candidates": [{"finishReason": "STOP", "content": {"parts": [
        {"text": "thinking...", "thought": True}, {"text": "Improved "}, {"text": "prompt."}]}}]}
    assert parse_response(data) == ("Improved prompt.", "STOP")


@pytest.mark.parametrize(
    "data, reason",
    [
        ({"candidates": [{"finishReason": "SAFETY"}]}, "blocked (safety)"),
        ({"candidates": [{"finishReason": "RECITATION", "content": {"parts": [{"text": "Giant"}]}}]}, "blocked (recitation)"),
        ({"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}}, "blocked (prohibited_content)"),
    ],
)
def test_gemini_parse_response_blocked(data, reason):
    with pytest.raises(BackendError) as info:
        parse_response(data)
    assert info.value.reason == reason


def test_gemini_parse_response_no_candidates_is_empty():
    with pytest.raises(EmptyResponseError):
        parse_response({})
