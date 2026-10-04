# Used Opus 5.5 with High Effort, for the tests of the settings loader.
# prompt: Write pytest tests for the settings: the defaults, missing keys making a backend
#   unavailable without an error, bad numbers falling back to the default, the Gemini model list,
#   the monitor settings, and keys never appearing in repr().

import pytest

from prompt_enhancer.backends.gemini import GeminiBackend
from prompt_enhancer.backends.base import NotConfiguredError
from prompt_enhancer.backends.openrouter import OpenRouterBackend
from prompt_enhancer.config import load_settings

ENV_VARS = [
    "GEMINI_API_KEY", "GEMINI_MODEL", "GEMINI_BASE_URL", "GEMINI_REASONING_EFFORT",
    "OPENROUTER_API_KEY", "OPENROUTER_MODEL", "OPENROUTER_BASE_URL", "OPENROUTER_REASONING_EFFORT",
    "LOCAL_MODEL_ID", "LOCAL_NUM_THREADS", "LOCAL_MAX_TIME_S", "API_TIMEOUT_S",
    "HOST", "PORT", "LOG_LEVEL",
    "MONITOR_ENABLED", "MONITOR_INTERVAL_S", "CPU_HIGH_PCT", "MEM_HIGH_PCT",
    "MONITOR_TRIGGER_SAMPLES", "MONITOR_CLEAR_SAMPLES", "MONITOR_CLEAR_MARGIN_PCT",
    "DISCORD_WEBHOOK_URL",
]


@pytest.fixture
def clean_env(monkeypatch):
    for var in ENV_VARS:
        monkeypatch.delenv(var, raising=False)
    return monkeypatch


def test_defaults(clean_env):
    s = load_settings(env_file=None)
    assert s.host == "0.0.0.0"
    assert s.port == 7860
    assert s.local_model_id == "Qwen/Qwen2.5-0.5B-Instruct"
    assert s.local_num_threads == 2
    assert s.local_max_time_s == 90
    assert s.api_timeout_s == 20
    assert s.gemini_reasoning_effort == "low"
    assert s.gemini_base_url.startswith("https://generativelanguage.googleapis.com/")
    assert s.openrouter_base_url == "https://openrouter.ai/api/v1"


def test_missing_keys_make_remote_backends_unavailable(clean_env):
    s = load_settings(env_file=None)
    assert not s.gemini_configured and not s.openrouter_configured
    for backend in (GeminiBackend(s), OpenRouterBackend(s)):
        assert backend.availability() == (False, "not configured")
        with pytest.raises(NotConfiguredError):
            backend.generate("sys", "user", 16, 0.7)


def test_key_without_model_is_not_configured(clean_env):
    clean_env.setenv("GEMINI_API_KEY", "dummy")
    s = load_settings(env_file=None)
    assert GeminiBackend(s).availability() == (False, "not configured")


def test_key_and_model_configured(clean_env):
    clean_env.setenv("OPENROUTER_API_KEY", "dummy")
    clean_env.setenv("OPENROUTER_MODEL", "some/model:free")
    s = load_settings(env_file=None)
    assert OpenRouterBackend(s).availability() == (True, "ok")


def test_reasoning_effort_defaults(clean_env):
    s = load_settings(env_file=None)
    assert s.gemini_reasoning_effort == "low"
    assert s.openrouter_reasoning_effort == "none"
    assert OpenRouterBackend(s).extra_params()["extra_body"] == {"reasoning": {"effort": "none"}}


def test_blank_reasoning_effort_is_omitted(clean_env):
    clean_env.setenv("GEMINI_REASONING_EFFORT", "")
    clean_env.setenv("OPENROUTER_REASONING_EFFORT", "")
    s = load_settings(env_file=None)
    assert GeminiBackend(s)._reasoning_effort == ""
    assert "extra_body" not in OpenRouterBackend(s).extra_params()


def test_unknown_gemini_reasoning_effort_is_dropped(clean_env):
    clean_env.setenv("GEMINI_REASONING_EFFORT", "turbo")
    assert GeminiBackend(load_settings(env_file=None))._reasoning_effort == ""


def test_bad_numbers_fall_back_to_defaults(clean_env):
    clean_env.setenv("PORT", "not-a-port")
    clean_env.setenv("LOCAL_MAX_TIME_S", "")
    s = load_settings(env_file=None)
    assert s.port == 7860
    assert s.local_max_time_s == 90


def test_repr_never_contains_keys(clean_env):
    clean_env.setenv("GEMINI_API_KEY", "secret-gemini-key")
    clean_env.setenv("OPENROUTER_API_KEY", "secret-or-key")
    text = repr(load_settings(env_file=None))
    assert "secret" not in text


def test_gemini_model_list(clean_env):
    from prompt_enhancer.backends.gemini import build_gemini_backends

    clean_env.setenv("GEMINI_API_KEY", "dummy")
    clean_env.setenv("GEMINI_MODEL", " gemini-3.1-flash-lite, gemini-3.5-flash ,,gemini-2.5-flash ")
    s = load_settings(env_file=None)
    assert s.gemini_models == ["gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-2.5-flash"]
    assert [b.model_id for b in build_gemini_backends(s)] == s.gemini_models


def test_gemini_without_models_is_one_unconfigured_backend(clean_env):
    from prompt_enhancer.backends.gemini import build_gemini_backends

    backends = build_gemini_backends(load_settings(env_file=None))
    assert len(backends) == 1
    assert backends[0].availability() == (False, "not configured")


def test_monitor_defaults(clean_env):
    s = load_settings(env_file=None)
    assert s.monitor_enabled is True
    assert (s.monitor_interval_s, s.cpu_high_pct, s.mem_high_pct) == (5.0, 80.0, 85.0)
    assert (s.monitor_trigger_samples, s.monitor_clear_samples) == (4, 6)
    assert s.monitor_clear_margin_pct == 10.0
    assert s.discord_webhook_url == ""


def test_monitor_settings_from_env(clean_env):
    clean_env.setenv("MONITOR_ENABLED", "false")
    clean_env.setenv("CPU_HIGH_PCT", "20")
    clean_env.setenv("MEM_HIGH_PCT", "10.5")
    clean_env.setenv("MONITOR_TRIGGER_SAMPLES", "2")
    s = load_settings(env_file=None)
    assert s.monitor_enabled is False
    assert (s.cpu_high_pct, s.mem_high_pct, s.monitor_trigger_samples) == (20.0, 10.5, 2)


def test_bad_monitor_values_fall_back_to_defaults(clean_env):
    clean_env.setenv("MONITOR_ENABLED", "maybe")
    clean_env.setenv("CPU_HIGH_PCT", "high")
    clean_env.setenv("MONITOR_INTERVAL_S", "0")
    clean_env.setenv("MONITOR_TRIGGER_SAMPLES", "0")
    s = load_settings(env_file=None)
    assert s.monitor_enabled is True
    assert s.cpu_high_pct == 80.0
    assert s.monitor_interval_s == 5.0
    assert s.monitor_trigger_samples == 1


def test_repr_never_contains_the_webhook(clean_env):
    clean_env.setenv("DISCORD_WEBHOOK_URL", "https://discord.com/api/webhooks/1/secret-token")
    assert "secret-token" not in repr(load_settings(env_file=None))
