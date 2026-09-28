import pytest

from prompt_enhancer.prompts import (
    BASE_SYSTEM_PROMPT,
    build_system_prompt,
    clean_output,
    max_tokens_for,
)


@pytest.mark.parametrize(
    "length, phrase, api_cap, local_cap",
    [
        ("Short", "2–3 sentences", 256, 128),
        ("Medium", "one detailed paragraph", 512, 256),
        ("Long", "Role, Context, Task, Constraints, Output format", 1024, 384),
    ],
)
def test_length_presets(length, phrase, api_cap, local_cap):
    system = build_system_prompt(length)
    assert system.startswith(BASE_SYSTEM_PROMPT)
    assert phrase in system
    assert max_tokens_for(length, local=False) == api_cap
    assert max_tokens_for(length, local=True) == local_cap


def test_unknown_length_rejected():
    with pytest.raises(ValueError):
        build_system_prompt("Huge")


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("  plain prompt \n", "plain prompt"),
        ("```\nWrite a poem.\n```", "Write a poem."),
        ("```markdown\nWrite a poem.\nAbout cats.\n```", "Write a poem.\nAbout cats."),
        ("Here is the improved prompt:\nWrite a poem.", "Write a poem."),
        ("Here's an improved version:\n\n```\nWrite a poem.\n```", "Write a poem."),
        ("Sure! Here is the improved prompt:\nWrite a poem.", "Write a poem."),
        # Fences in the middle of the text are content, not a wrapper.
        ("Use this format:\n```\nx\n```\nthen stop.", "Use this format:\n```\nx\n```\nthen stop."),
        # "Here is" that isn't a preamble line stays.
        ("Here is my dog Rex; describe him vividly.", "Here is my dog Rex; describe him vividly."),
        ("", ""),
        # A single pair of wrapping quotes is removed; inner quotes mean it isn't a wrapper.
        ('"Describe Kubernetes in simple terms."', "Describe Kubernetes in simple terms."),
        ("“Describe Kubernetes.”", "Describe Kubernetes."),
        ('"Cats" and "dogs" compared', '"Cats" and "dogs" compared'),
    ],
)
def test_clean_output(raw, expected):
    assert clean_output(raw) == expected
