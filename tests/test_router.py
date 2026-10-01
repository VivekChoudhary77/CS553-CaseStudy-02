import pytest

from prompt_enhancer.backends.base import Backend, BackendError
from prompt_enhancer.router import AllBackendsFailed, enhance, format_trace


class FakeBackend(Backend):
    def __init__(self, name, *, output="improved", error=None, available=True, reason="ok", local=False):
        self.name = name
        self.model_id = f"{name.lower()}-model"
        self.is_local = local
        self._output = output
        self._error = error
        self._available = available
        self._reason = reason
        self.calls = []

    def availability(self):
        return (True, "ok") if self._available else (False, self._reason)

    def generate(self, system_prompt, user_prompt, max_tokens, temperature):
        self.calls.append((system_prompt, user_prompt, max_tokens, temperature))
        if self._error:
            raise self._error
        return self._output


def make_backends(**overrides):
    backends = {
        "Local": FakeBackend("Local", local=True),
        "Gemini": FakeBackend("Gemini"),
        "OpenRouter": FakeBackend("OpenRouter"),
    }
    backends.update(overrides)
    return backends


def all_failing():
    return make_backends(
        Local=FakeBackend("Local", local=True, error=BackendError("out of memory")),
        Gemini=FakeBackend("Gemini", error=BackendError("rate limited (429)")),
        OpenRouter=FakeBackend("OpenRouter", error=BackendError("HTTP 500")),
    )


@pytest.mark.parametrize(
    "preferred, expected",
    [
        ("Local", ["Local", "Gemini", "OpenRouter"]),
        ("Gemini", ["Gemini", "OpenRouter", "Local"]),
        ("OpenRouter", ["OpenRouter", "Gemini", "Local"]),
    ],
)
def test_failover_order(preferred, expected):
    with pytest.raises(AllBackendsFailed) as info:
        enhance("hi", preferred, "Short", 0.7, all_failing())
    assert [a.backend for a in info.value.attempts] == expected


@pytest.mark.parametrize("preferred", ["Local", "Gemini", "OpenRouter"])
def test_preferred_backend_used_first_when_healthy(preferred):
    backends = make_backends()
    result = enhance("hi", preferred, "Short", 0.7, backends)
    assert result.backend == preferred
    assert len(result.attempts) == 1
    assert [name for name, b in backends.items() if b.calls] == [preferred]


def test_failing_preferred_falls_through_and_records_reason():
    backends = make_backends(Gemini=FakeBackend("Gemini", error=BackendError("rate limited (429)")))
    result = enhance("hi", "Gemini", "Medium", 0.7, backends)
    assert result.backend == "OpenRouter"
    assert result.model == "openrouter-model"
    assert [(a.backend, a.ok, a.reason) for a in result.attempts] == [
        ("Gemini", False, "rate limited (429)"),
        ("OpenRouter", True, "ok"),
    ]


@pytest.mark.parametrize("reason", ["not configured", "model still loading"])
def test_unavailable_backends_skipped_with_reason_and_zero_latency(reason):
    backends = make_backends(
        Gemini=FakeBackend("Gemini", available=False, reason=reason),
        OpenRouter=FakeBackend("OpenRouter", available=False, reason=reason),
    )
    result = enhance("hi", "Gemini", "Short", 0.7, backends)
    assert result.backend == "Local"
    skipped = result.attempts[:2]
    assert [a.reason for a in skipped] == [reason, reason]
    assert all(not a.ok and a.latency_s < 0.05 for a in skipped)
    assert not backends["Gemini"].calls and not backends["OpenRouter"].calls


@pytest.mark.parametrize("empty", ["", "   \n  "])
def test_empty_output_is_failure(empty):
    backends = make_backends(Gemini=FakeBackend("Gemini", output=empty))
    result = enhance("hi", "Gemini", "Short", 0.7, backends)
    assert result.attempts[0].reason == "empty response"
    assert result.backend == "OpenRouter"


def test_unexpected_exception_does_not_break_failover():
    backends = make_backends(Gemini=FakeBackend("Gemini", error=ValueError("boom")))
    result = enhance("hi", "Gemini", "Short", 0.7, backends)
    assert result.attempts[0].reason == "error: ValueError"
    assert result.backend == "OpenRouter"


def test_all_failing_raises_with_every_attempt():
    with pytest.raises(AllBackendsFailed) as info:
        enhance("hi", "Gemini", "Short", 0.7, all_failing())
    attempts = info.value.attempts
    assert [(a.backend, a.reason) for a in attempts] == [
        ("Gemini", "rate limited (429)"),
        ("OpenRouter", "HTTP 500"),
        ("Local", "out of memory"),
    ]
    assert not any(a.ok for a in attempts)
    assert "Gemini: rate limited (429)" in str(info.value)


def test_on_event_called_in_order():
    events = []
    backends = make_backends(
        Local=FakeBackend("Local", local=True, available=False, reason="model still loading"),
        Gemini=FakeBackend("Gemini", error=BackendError("timeout")),
    )
    enhance("hi", "Local", "Short", 0.7, backends, on_event=lambda *args: events.append(args))
    assert [(e[0], e[1].backend, *e[2:]) for e in events] == [
        ("failed", "Local", "Gemini"),
        ("failed", "Gemini", "OpenRouter"),
        ("succeeded", "OpenRouter"),
    ]
    assert events[0][1].reason == "model still loading"
    assert events[1][1].reason == "timeout"


def test_on_event_last_failure_has_no_next_backend():
    events = []
    with pytest.raises(AllBackendsFailed):
        enhance("hi", "Gemini", "Short", 0.7, all_failing(), on_event=lambda *a: events.append(a))
    assert [e[0] for e in events] == ["failed"] * 3
    assert events[-1][2] is None


def test_local_and_api_backends_get_their_own_token_caps():
    backends = make_backends(Gemini=FakeBackend("Gemini", error=BackendError("timeout")))
    backends["OpenRouter"] = FakeBackend("OpenRouter", error=BackendError("timeout"))
    enhance("hi", "Gemini", "Long", 0.3, backends)
    assert backends["Gemini"].calls[0][2] == 1024
    assert backends["Local"].calls[0][2] == 384
    assert backends["Local"].calls[0][3] == 0.3


def test_format_trace():
    backends = make_backends(
        Local=FakeBackend("Local", local=True, available=False, reason="model still loading"),
        Gemini=FakeBackend("Gemini", error=BackendError("rate limited (429)")),
    )
    result = enhance("hi", "Local", "Short", 0.7, backends)
    trace = format_trace(result.attempts)
    assert trace.startswith("Local ❌ model still loading → Gemini ❌ rate limited (429) → OpenRouter ✅ ")
    assert trace.endswith(" s")


def gemini_group(*specs):
    """Several Gemini backends (one per model), like build_gemini_backends produces."""
    group = []
    for model, kwargs in specs:
        backend = FakeBackend("Gemini", **kwargs)
        backend.model_id = model
        group.append(backend)
    return group


def test_gemini_models_tried_in_order_before_next_backend():
    group = gemini_group(
        ("big-quota", {"error": BackendError("rate limited (429)")}),
        ("second", {"error": BackendError("HTTP 503")}),
        ("third", {}),
    )
    events = []
    result = enhance("hi", "Gemini", "Short", 0.7, make_backends(Gemini=group),
                     on_event=lambda *a: events.append(a))
    assert (result.backend, result.model) == ("Gemini", "third")
    assert format_trace(result.attempts).startswith(
        "Gemini (big-quota) ❌ rate limited (429) → Gemini (second) ❌ HTTP 503 → Gemini (third) ✅"
    )
    assert [(e[0], e[1].display, *e[2:]) for e in events] == [
        ("failed", "Gemini (big-quota)", "Gemini (second)"),
        ("failed", "Gemini (second)", "Gemini (third)"),
        ("succeeded", "Gemini (third)"),
    ]


def test_all_gemini_models_failing_falls_through_to_openrouter():
    group = gemini_group(("a", {"error": BackendError("HTTP 503")}), ("b", {"error": BackendError("timeout")}))
    result = enhance("hi", "Gemini", "Short", 0.7, make_backends(Gemini=group))
    assert result.backend == "OpenRouter"
    assert [a.display for a in result.attempts] == ["Gemini (a)", "Gemini (b)", "OpenRouter"]


@pytest.mark.parametrize("reason", ["auth failed (invalid API key)", "not configured"])
def test_group_wide_failure_skips_other_models(reason):
    kwargs = {"available": False, "reason": reason} if reason == "not configured" else {"error": BackendError(reason)}
    group = gemini_group(("a", kwargs), ("b", {}), ("c", {}))
    events = []
    result = enhance("hi", "Gemini", "Short", 0.7, make_backends(Gemini=group),
                     on_event=lambda *a: events.append(a))
    assert result.backend == "OpenRouter"
    assert [a.display for a in result.attempts] == ["Gemini (a)", "OpenRouter"]
    assert not group[1].calls and not group[2].calls
    assert events[0][2] == "OpenRouter"


def test_single_model_label_has_no_model_suffix():
    group = gemini_group(("only", {"error": BackendError("HTTP 503")}))
    result = enhance("hi", "Gemini", "Short", 0.7, make_backends(Gemini=group))
    assert result.attempts[0].display == "Gemini"


def test_paused_local_is_skipped_with_its_reason_and_api_backend_serves():
    """Resource monitor reaction: a paused Local backend reports itself unavailable."""
    reason = "paused: system near capacity"
    backends = make_backends(Local=FakeBackend("Local", local=True, available=False, reason=reason))
    events = []
    result = enhance("hi", "Local", "Short", 0.7, backends, on_event=lambda *a: events.append(a))
    assert result.backend == "Gemini"
    assert result.attempts[0].reason == reason
    assert result.attempts[0].latency_s < 0.05
    assert not backends["Local"].calls
    assert format_trace(result.attempts).startswith(f"Local ❌ {reason} → Gemini ✅")
    assert events[0][2] == "Gemini"
