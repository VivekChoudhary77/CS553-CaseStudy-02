# Used Opus 5.5 with High Effort, for the tests of the Discord notifier.
# prompt: Write pytest tests for the notifier with a fake opener: the JSON payload and headers,
#   one retry, never raising, no request without a URL, and the URL never being logged.

import json
import urllib.error

from prompt_enhancer.notifier import notify

URL = "https://discord.invalid/api/webhooks/123/token"


class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    """Fails the first `failures` calls, then succeeds; records every request."""

    def __init__(self, failures=0, error=None):
        self.failures = failures
        self.error = error or urllib.error.URLError("no route")
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        if len(self.requests) <= self.failures:
            raise self.error
        return FakeResponse()


def test_posts_json_with_prefix_and_custom_user_agent():
    opener = FakeOpener()
    assert notify(URL, 'resource alert: CPU "97%"', opener=opener, sleep=lambda s: None) is True
    (request, timeout), = opener.requests
    assert request.full_url == URL
    assert request.get_method() == "POST"
    assert json.loads(request.data) == {"content": '[group25] resource alert: CPU "97%"'}
    assert request.get_header("Content-type") == "application/json"
    assert "urllib" not in request.get_header("User-agent").lower()
    assert timeout == 10.0


def test_retries_once_then_succeeds():
    opener, waits = FakeOpener(failures=1), []
    assert notify(URL, "hello", opener=opener, sleep=waits.append) is True
    assert len(opener.requests) == 2
    assert waits == [5.0]


def test_gives_up_after_two_failures_without_raising():
    opener = FakeOpener(failures=5, error=TimeoutError("slow"))
    assert notify(URL, "hello", opener=opener, sleep=lambda s: None) is False
    assert len(opener.requests) == 2


def test_no_url_means_no_request():
    opener = FakeOpener()
    assert notify("", "hello", opener=opener) is False
    assert opener.requests == []


def test_webhook_url_is_never_logged(caplog):
    opener = FakeOpener(failures=5)
    with caplog.at_level("WARNING"):
        notify(URL, "hello", opener=opener, sleep=lambda s: None)
    assert "discord.invalid" not in caplog.text
    assert "token" not in caplog.text
