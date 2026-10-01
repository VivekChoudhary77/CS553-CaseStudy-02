import pytest

from prompt_enhancer.backends.local import PAUSED_REASON, STATUS_READY, LocalBackend
from prompt_enhancer.config import Settings
from prompt_enhancer.monitor import (
    BUSY,
    NORMAL,
    Counters,
    MonitorConfig,
    ResourceMonitor,
    Sample,
    cpu_percent,
    decide,
    parse_cpu_times,
    parse_meminfo,
)

MEMINFO = """MemTotal:        4194304 kB
MemFree:          227328 kB
MemAvailable:    1677722 kB
Buffers:               0 kB
Cached:          1468006 kB
"""

STAT = """cpu  896018 48138 239665 11318808 325074 0 5332 0 0 0
cpu0 112000 6000 30000 1414851 40634 0 666 0 0 0
intr 123456
"""

CFG = MonitorConfig(cpu_high_pct=80, mem_high_pct=85, trigger_samples=3, clear_samples=2, clear_margin_pct=10)


def sample(cpu, mem=50.0):
    return Sample(0.0, cpu, mem)


# ---- parsing ---------------------------------------------------------------------------


def test_parse_meminfo_uses_available_not_free():
    # 1 - 1677722/4194304 = 60 % (page cache counted as available, like `free`'s "available")
    assert parse_meminfo(MEMINFO) == pytest.approx(60.0, abs=0.1)


def test_parse_meminfo_missing_field_raises():
    with pytest.raises(KeyError):
        parse_meminfo("MemTotal: 100 kB\n")


def test_parse_cpu_times_counts_iowait_as_idle_and_ignores_guest():
    idle, total = parse_cpu_times(STAT)
    assert idle == 11318808 + 325074
    assert total == 896018 + 48138 + 239665 + 11318808 + 325074 + 0 + 5332 + 0


def test_parse_cpu_times_without_cpu_line_raises():
    with pytest.raises(ValueError):
        parse_cpu_times("intr 1 2 3\n")


@pytest.mark.parametrize(
    "prev, cur, expected",
    [
        ((100, 1000), (150, 1200), 75.0),  # 200 ticks, 50 idle -> 75 % busy
        ((100, 1000), (300, 1200), 0.0),  # all idle
        ((100, 1000), (100, 1200), 100.0),  # no idle
        ((100, 1000), (100, 1000), 0.0),  # no time passed
    ],
)
def test_cpu_percent(prev, cur, expected):
    assert cpu_percent(prev, cur) == pytest.approx(expected)


# ---- threshold logic --------------------------------------------------------------------


def run(samples, cfg=CFG):
    state, counters, events = NORMAL, Counters(), []
    for s in samples:
        state, counters, event = decide(state, s, counters, cfg)
        events.append(event)
    return state, events


def test_goes_busy_only_after_n_consecutive_samples():
    state, events = run([sample(95), sample(95)])
    assert state == NORMAL and events == [None, None]
    state, events = run([sample(95), sample(95), sample(95)])
    assert state == BUSY and events == [None, None, BUSY]


def test_short_spike_does_not_trigger():
    state, events = run([sample(95), sample(95), sample(10), sample(95), sample(95)])
    assert state == NORMAL and BUSY not in events


def test_memory_alone_can_trigger():
    state, _ = run([sample(5, 90), sample(5, 90), sample(5, 90)])
    assert state == BUSY


def test_threshold_is_inclusive():
    state, _ = run([sample(80), sample(80), sample(80)])
    assert state == BUSY


def test_recovers_only_after_m_samples_below_the_margin():
    busy = [sample(95)] * 3
    # 75 % is under the 80 % threshold but not under 80 - 10: still busy (hysteresis)
    state, events = run(busy + [sample(75), sample(75), sample(75)])
    assert state == BUSY and NORMAL not in events
    state, events = run(busy + [sample(60), sample(60)])
    assert state == NORMAL and events[-1] == NORMAL


def test_recovery_needs_both_metrics_clear():
    busy = [sample(95)] * 3
    state, _ = run(busy + [sample(10, 80), sample(10, 80)])  # memory 80 >= 85 - 10
    assert state == BUSY


def test_no_flapping_one_event_per_transition():
    samples = [sample(95)] * 6 + [sample(10)] * 5 + [sample(95)] * 3
    _, events = run(samples)
    assert [e for e in events if e] == [BUSY, NORMAL, BUSY]


# ---- ResourceMonitor with fake readers ----------------------------------------------------


class FakeProc:
    """Feeds /proc text for a sequence of CPU-busy percentages."""

    def __init__(self):
        self.idle, self.total, self.mem_available = 0, 0, 2000

    def tick(self, busy_pct, mem_pct=50.0):
        self.total += 1000
        self.idle += int(1000 * (1 - busy_pct / 100))
        self.mem_available = int(4000 * (1 - mem_pct / 100))

    def stat(self):
        return f"cpu  {self.total - self.idle} 0 0 {self.idle} 0 0 0 0 0 0\n"

    def meminfo(self):
        return f"MemTotal: 4000 kB\nMemAvailable: {self.mem_available} kB\n"


def make_monitor(events, **kwargs):
    proc = FakeProc()
    monitor = ResourceMonitor(
        CFG,
        on_event=lambda event, s: events.append((event, round(s.cpu_pct))),
        read_stat=proc.stat,
        read_meminfo=proc.meminfo,
        clock=lambda: 1000.0,
        **kwargs,
    )
    proc.tick(0)
    monitor.sample_once()  # first sample only establishes the CPU baseline
    return monitor, proc


def test_monitor_emits_one_event_per_transition_and_tracks_state():
    events = []
    monitor, proc = make_monitor(events)
    for _ in range(4):
        proc.tick(100)
        monitor.sample_once()
    assert monitor.is_busy()
    assert events == [(BUSY, 100)]
    for _ in range(3):
        proc.tick(5)
        monitor.sample_once()
    assert not monitor.is_busy()
    assert events == [(BUSY, 100), (NORMAL, 5)]
    state, last = monitor.snapshot()
    assert state == NORMAL and last.cpu_pct == pytest.approx(5.0)
    assert len(monitor.history()) == 8


def test_first_sample_reports_zero_cpu():
    proc = FakeProc()
    proc.tick(100)
    monitor = ResourceMonitor(CFG, read_stat=proc.stat, read_meminfo=proc.meminfo)
    assert monitor.sample_once().cpu_pct == 0.0


def test_failing_event_handler_does_not_break_sampling():
    def boom(event, s):
        raise RuntimeError("discord is down")

    proc = FakeProc()
    monitor = ResourceMonitor(CFG, on_event=boom, read_stat=proc.stat, read_meminfo=proc.meminfo)
    for _ in range(5):
        proc.tick(100)
        monitor.sample_once()
    assert monitor.is_busy()


def test_history_is_bounded():
    proc = FakeProc()
    cfg = MonitorConfig(interval_s=5, history_s=20)  # keeps 4 samples
    monitor = ResourceMonitor(cfg, read_stat=proc.stat, read_meminfo=proc.meminfo)
    for _ in range(10):
        proc.tick(10)
        monitor.sample_once()
    assert len(monitor.history()) == 4


def test_thread_survives_a_reader_error():
    calls = {"n": 0}

    def flaky_stat():
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("transient /proc error")
        return "cpu  1 0 0 1 0 0 0 0 0 0\n"

    cfg = MonitorConfig(interval_s=0.01)
    monitor = ResourceMonitor(cfg, read_stat=flaky_stat, read_meminfo=lambda: MEMINFO)
    monitor.start()
    for _ in range(200):
        if monitor.history():
            break
        import time

        time.sleep(0.01)
    monitor.stop()
    assert calls["n"] >= 2 and monitor.history()


# ---- the reaction: Local backend paused while busy ---------------------------------------


def ready_local():
    backend = LocalBackend(Settings())
    backend._set_status(STATUS_READY)  # pretend the model is loaded (no download in tests)
    return backend


def test_local_backend_is_paused_while_busy_and_resumes():
    backend = ready_local()
    busy = {"value": True}
    backend.set_pause_check(lambda: busy["value"])
    assert backend.availability() == (False, PAUSED_REASON)
    busy["value"] = False
    assert backend.availability() == (True, "ok")


def test_pause_check_does_not_mask_a_loading_model():
    backend = LocalBackend(Settings())
    backend.set_pause_check(lambda: True)
    assert backend.availability() == (False, "model still loading")
