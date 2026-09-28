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
