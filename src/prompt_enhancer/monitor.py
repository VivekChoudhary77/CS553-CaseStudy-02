"""Resource monitor: sample CPU and memory, and decide when the machine is "busy".

No third-party dependency: CPU comes from /proc/stat, memory from /proc/meminfo.
The threshold logic lives in the pure function `decide()` so it can be unit-tested
without threads or real load.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

NORMAL, BUSY = "normal", "busy"


@dataclass(frozen=True)
class MonitorConfig:
    interval_s: float = 5.0
    cpu_high_pct: float = 80.0
    mem_high_pct: float = 85.0
    trigger_samples: int = 4  # consecutive samples over a threshold before going busy
    clear_samples: int = 6  # consecutive samples under (threshold - margin) before recovering
    clear_margin_pct: float = 10.0
    history_s: float = 600.0  # how much history to keep for the chart


@dataclass(frozen=True)
class Sample:
    time: float  # epoch seconds
    cpu_pct: float
    mem_pct: float


@dataclass(frozen=True)
class Counters:
    over: int = 0  # consecutive samples over a threshold (while normal)
    under: int = 0  # consecutive samples under the clear level (while busy)


def parse_meminfo(text: str) -> float:
    """Memory in use, in percent: 1 - MemAvailable / MemTotal."""
    fields = {}
    for line in text.splitlines():
        name, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            fields[name] = int(parts[0])
    total, available = fields["MemTotal"], fields["MemAvailable"]
    if total <= 0:
        raise ValueError("MemTotal is zero")
    return max(0.0, min(100.0, 100.0 * (1.0 - available / total)))


def parse_cpu_times(text: str) -> tuple[int, int]:
    """(idle, total) jiffies from the aggregate `cpu` line of /proc/stat."""
    for line in text.splitlines():
        if line.startswith("cpu "):
            values = [int(v) for v in line.split()[1:]]
            # user nice system idle iowait irq softirq steal [guest guest_nice];
            # guest time is already counted inside user/nice.
            core = values[:8]
            idle = core[3] + (core[4] if len(core) > 4 else 0)
            return idle, sum(core)
    raise ValueError("no aggregate cpu line in /proc/stat")


def cpu_percent(prev: tuple[int, int], cur: tuple[int, int]) -> float:
    """CPU busy percent between two (idle, total) readings."""
    idle_delta, total_delta = cur[0] - prev[0], cur[1] - prev[1]
    if total_delta <= 0:
        return 0.0
    return max(0.0, min(100.0, 100.0 * (1.0 - idle_delta / total_delta)))


def decide(
    state: str, sample: Sample, counters: Counters, cfg: MonitorConfig
) -> tuple[str, Counters, str | None]:
    """One step of the busy/normal state machine. Returns (state, counters, event or None).

    normal -> busy   after `trigger_samples` consecutive samples with CPU or memory at or
                     above its threshold (a short spike does not count).
    busy -> normal   after `clear_samples` consecutive samples with BOTH below
                     threshold - margin (hysteresis, so it does not flap at the edge).
    """
    over = sample.cpu_pct >= cfg.cpu_high_pct or sample.mem_pct >= cfg.mem_high_pct
    clear = (
        sample.cpu_pct < cfg.cpu_high_pct - cfg.clear_margin_pct
        and sample.mem_pct < cfg.mem_high_pct - cfg.clear_margin_pct
    )
    if state == NORMAL:
        n = counters.over + 1 if over else 0
        if n >= cfg.trigger_samples:
            return BUSY, Counters(), BUSY
        return NORMAL, Counters(over=n), None
    n = counters.under + 1 if clear else 0
    if n >= cfg.clear_samples:
        return NORMAL, Counters(), NORMAL
    return BUSY, Counters(under=n), None


def _read_proc_stat() -> str:
    return Path("/proc/stat").read_text()


def _read_proc_meminfo() -> str:
    return Path("/proc/meminfo").read_text()


class ResourceMonitor:
    """Samples in a daemon thread; `on_event("busy" | "normal", sample)` fires on changes only."""

    def __init__(
        self,
        cfg: MonitorConfig,
        on_event: Callable[[str, Sample], None] | None = None,
        read_stat: Callable[[], str] = _read_proc_stat,
        read_meminfo: Callable[[], str] = _read_proc_meminfo,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.cfg = cfg
        self._on_event = on_event
        self._read_stat = read_stat
        self._read_meminfo = read_meminfo
        self._clock = clock
        self._lock = threading.Lock()
        self._state = NORMAL
        self._counters = Counters()
        self._prev_cpu: tuple[int, int] | None = None
        self._history: deque[Sample] = deque(maxlen=max(1, int(cfg.history_s / cfg.interval_s)))
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # ---- reading state (thread-safe) ---------------------------------------------------

    def is_busy(self) -> bool:
        with self._lock:
            return self._state == BUSY

    def snapshot(self) -> tuple[str, Sample | None]:
        with self._lock:
            return self._state, (self._history[-1] if self._history else None)

    def history(self) -> list[Sample]:
        with self._lock:
            return list(self._history)

    # ---- sampling --------------------------------------------------------------------------

    def sample_once(self) -> Sample:
        cur = parse_cpu_times(self._read_stat())
        cpu = cpu_percent(self._prev_cpu, cur) if self._prev_cpu is not None else 0.0
        self._prev_cpu = cur
        sample = Sample(self._clock(), cpu, parse_meminfo(self._read_meminfo()))
        with self._lock:
            self._history.append(sample)
            self._state, self._counters, event = decide(
                self._state, sample, self._counters, self.cfg
            )
        if event and self._on_event:
            try:
                self._on_event(event, sample)
            except Exception:  # a failing notifier must never stop the monitor
                log.exception("Resource monitor event handler failed")
        return sample

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.sample_once()
            except Exception:
                log.exception("Resource monitor sample failed")
            self._stop.wait(self.cfg.interval_s)

    def start(self) -> None:
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="resource-monitor", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=self.cfg.interval_s + 1)
