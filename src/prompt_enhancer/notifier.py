# Used Opus 5.5 with High Effort, for sending the resource alerts to Discord.
# prompt: Write a small Discord webhook notifier using only the standard library: post a JSON
#   message with a [group25] prefix, retry once, never raise, never log the URL, and do nothing
#   when no URL is set.

"""Discord webhook notifications (stdlib only). Never raises: alerts must not break the app."""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

log = logging.getLogger(__name__)

PREFIX = "[group25]"
TIMEOUT_S = 10.0


def build_request(webhook_url: str, message: str) -> urllib.request.Request:
    payload = json.dumps({"content": f"{PREFIX} {message}"}).encode()
    return urllib.request.Request(
        webhook_url,
        data=payload,
        # Discord rejects urllib's default User-Agent, so send our own.
        headers={"Content-Type": "application/json", "User-Agent": "prompt-enhancer-monitor/1.0"},
        method="POST",
    )


def notify(
    webhook_url: str,
    message: str,
    *,
    opener: Callable[..., Any] = urllib.request.urlopen,
    retry_wait_s: float = 5.0,
    sleep: Callable[[float], None] = time.sleep,
) -> bool:
    """Post `message` to the webhook; one retry. Returns True if delivered, False otherwise."""
    if not webhook_url:
        return False
    request = build_request(webhook_url, message)
    for attempt in (1, 2):
        try:
            with opener(request, timeout=TIMEOUT_S):
                return True
        except Exception as exc:  # network errors, HTTP errors, timeouts
            # Never log the URL: it is a secret.
            log.warning("Discord notification attempt %d failed: %s", attempt, type(exc).__name__)
            if attempt == 1:
                sleep(retry_wait_s)
    return False
