"""Backend interface, error hierarchy, and result dataclasses."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


class BackendError(Exception):
    """A backend failed; `reason` is a short, human-readable explanation."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class NotConfiguredError(BackendError):
    def __init__(self) -> None:
        super().__init__("not configured")


class ModelLoadingError(BackendError):
    def __init__(self) -> None:
        super().__init__("model still loading")


class EmptyResponseError(BackendError):
    def __init__(self) -> None:
        super().__init__("empty response")


class BackendTimeoutError(BackendError):
    def __init__(self) -> None:
        super().__init__("timeout")


class OutOfMemoryBackendError(BackendError):
    def __init__(self) -> None:
        super().__init__("out of memory")


@dataclass
class Attempt:
    backend: str
    model: str
    ok: bool
    reason: str
    latency_s: float
    label: str = ""  # display name; includes the model when a backend has several

    @property
    def display(self) -> str:
        return self.label or self.backend


@dataclass
class EnhanceResult:
    text: str
    backend: str
    model: str
    latency_s: float
    attempts: list[Attempt] = field(default_factory=list)


class Backend(ABC):
    name: str
    model_id: str
    is_local: bool = False

    @abstractmethod
    def availability(self) -> tuple[bool, str]:
        """Return (True, "ok") if usable now, else (False, reason)."""

    @abstractmethod
    def generate(
        self, system_prompt: str, user_prompt: str, max_tokens: int, temperature: float
    ) -> str:
        """Return the cleaned, non-empty output or raise a BackendError."""
