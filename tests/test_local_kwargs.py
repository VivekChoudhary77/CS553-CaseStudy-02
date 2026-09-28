from prompt_enhancer.backends.local import build_generation_kwargs


def test_temperature_zero_is_greedy_without_temperature_key():
    kwargs = build_generation_kwargs(max_new_tokens=128, temperature=0.0, max_time=90)
    assert kwargs["do_sample"] is False
    assert "temperature" not in kwargs
    assert "top_p" not in kwargs


def test_positive_temperature_samples():
    kwargs = build_generation_kwargs(max_new_tokens=256, temperature=0.7, max_time=90)
    assert kwargs["do_sample"] is True
    assert kwargs["temperature"] == 0.7
    assert kwargs["top_p"] == 0.9


def test_limits_and_repetition_penalty_passed_through():
    for temperature in (0.0, 1.2):
        kwargs = build_generation_kwargs(max_new_tokens=384, temperature=temperature, max_time=45.5)
        assert kwargs["max_new_tokens"] == 384
        assert kwargs["max_time"] == 45.5
        assert kwargs["repetition_penalty"] == 1.1
