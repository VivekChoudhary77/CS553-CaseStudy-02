# Used Opus 5.5 with High Effort, for loading the app's settings from environment variables and a
#   .env file.
# prompt: Create a frozen Settings dataclass loaded with python-dotenv, with a default for every
#   variable. Missing API keys must never crash startup, bad numbers fall back to the default, and
#   keys are never printed. Add logging to stdout. Later add the resource monitor settings.

"""Settings loaded from environment variables (and an optional .env file)."""

from __future__ import annotations

import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

log = logging.getLogger(__name__)

DEFAULT_GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
DEFAULT_OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_LOCAL_MODEL_ID = "Qwen/Qwen2.5-0.5B-Instruct"


@dataclass(frozen=True)
class Settings:
    gemini_api_key: str = ""
    gemini_model: str = ""
    gemini_base_url: str = DEFAULT_GEMINI_BASE_URL
    gemini_reasoning_effort: str = "low"
    openrouter_api_key: str = ""
    openrouter_model: str = ""
    openrouter_base_url: str = DEFAULT_OPENROUTER_BASE_URL
    openrouter_reasoning_effort: str = "none"
    local_model_id: str = DEFAULT_LOCAL_MODEL_ID
    local_num_threads: int = 2
    local_max_time_s: float = 90.0
    api_timeout_s: float = 20.0
    host: str = "0.0.0.0"
    port: int = 7860
    log_level: str = "INFO"
    # resource monitor (bonus: monitoring + adaptive response)
    monitor_enabled: bool = True
    monitor_interval_s: float = 5.0
    cpu_high_pct: float = 80.0
    mem_high_pct: float = 85.0
    monitor_trigger_samples: int = 4
    monitor_clear_samples: int = 6
    monitor_clear_margin_pct: float = 10.0
    discord_webhook_url: str = ""

    @property
    def gemini_models(self) -> list[str]:
        """GEMINI_MODEL may be one id or a comma-separated list, tried in order."""
        return [m.strip() for m in self.gemini_model.split(",") if m.strip()]

    @property
    def gemini_configured(self) -> bool:
        return bool(self.gemini_api_key and self.gemini_models)

    @property
    def openrouter_configured(self) -> bool:
        return bool(self.openrouter_api_key and self.openrouter_model)

    def __repr__(self) -> str:  # never leak keys into logs or tracebacks
        return (
            f"Settings(gemini_configured={self.gemini_configured}, "
            f"openrouter_configured={self.openrouter_configured}, "
            f"local_model_id={self.local_model_id!r}, host={self.host!r}, port={self.port})"
        )


def _str(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def _int(name: str, default: int) -> int:
    try:
        return int(_str(name, str(default)))
    except ValueError:
        log.warning("Invalid %s; using default %s", name, default)
        return default


def _float(name: str, default: float) -> float:
    try:
        return float(_str(name, str(default)))
    except ValueError:
        log.warning("Invalid %s; using default %s", name, default)
        return default


def _bool(name: str, default: bool) -> bool:
    value = os.environ.get(name, "").strip().lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    if value:
        log.warning("Invalid %s; using default %s", name, default)
    return default


def _positive(name: str, default: float) -> float:
    value = _float(name, default)
    if value <= 0:
        log.warning("%s must be positive; using default %s", name, default)
        return default
    return value


def load_settings(env_file: str | Path | None = ".env") -> Settings:
    """Build Settings from the environment. Pass env_file=None to skip reading a .env file."""
    if env_file is not None:
        load_dotenv(env_file, override=False)
    return Settings(
        gemini_api_key=_str("GEMINI_API_KEY", ""),
        gemini_model=_str("GEMINI_MODEL", ""),
        gemini_base_url=_str("GEMINI_BASE_URL", DEFAULT_GEMINI_BASE_URL),
        # Explicitly blank means "omit reasoning_effort", so don't fall back to the default here.
        gemini_reasoning_effort=os.environ.get("GEMINI_REASONING_EFFORT", "low").strip(),
        openrouter_api_key=_str("OPENROUTER_API_KEY", ""),
        openrouter_model=_str("OPENROUTER_MODEL", ""),
        openrouter_base_url=_str("OPENROUTER_BASE_URL", DEFAULT_OPENROUTER_BASE_URL),
        openrouter_reasoning_effort=os.environ.get("OPENROUTER_REASONING_EFFORT", "none").strip(),
        local_model_id=_str("LOCAL_MODEL_ID", DEFAULT_LOCAL_MODEL_ID),
        local_num_threads=_int("LOCAL_NUM_THREADS", 2),
        local_max_time_s=_float("LOCAL_MAX_TIME_S", 90.0),
        api_timeout_s=_float("API_TIMEOUT_S", 20.0),
        host=_str("HOST", "0.0.0.0"),
        port=_int("PORT", 7860),
        log_level=_str("LOG_LEVEL", "INFO").upper(),
        monitor_enabled=_bool("MONITOR_ENABLED", True),
        monitor_interval_s=_positive("MONITOR_INTERVAL_S", 5.0),
        cpu_high_pct=_positive("CPU_HIGH_PCT", 80.0),
        mem_high_pct=_positive("MEM_HIGH_PCT", 85.0),
        monitor_trigger_samples=max(1, _int("MONITOR_TRIGGER_SAMPLES", 4)),
        monitor_clear_samples=max(1, _int("MONITOR_CLEAR_SAMPLES", 6)),
        monitor_clear_margin_pct=max(0.0, _float("MONITOR_CLEAR_MARGIN_PCT", 10.0)),
        discord_webhook_url=_str("DISCORD_WEBHOOK_URL", ""),
    )


def setup_logging(level: str = "INFO") -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
        force=True,
    )
    # httpx logs every request URL at INFO; keep the journal focused on our own lines.
    logging.getLogger("httpx").setLevel(logging.WARNING)
