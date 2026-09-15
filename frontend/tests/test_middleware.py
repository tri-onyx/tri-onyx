"""PromptRateLimitMiddleware must key on the real connection, not on a
header any caller can set. The gateway (router.ex) documents exactly why:
X-Forwarded-For is only trustworthy behind a proxy that overwrites it (e.g.
Cloudflare's CF-Connecting-IP). This Django app has no such proxy in front
of it (see docker-compose.yml: frontend is bound to 127.0.0.1 only, with no
reverse proxy setting X-Forwarded-For) — so trusting the header lets any
caller bypass the per-client rate limit on the one endpoint that triggers a
real, billable LLM agent invocation, just by varying a header on every
request.
"""

from django.http import HttpResponse
from django.test import RequestFactory

from trionyx_ui import middleware as mw


def _make_middleware():
    mw._prompt_timestamps.clear()
    return mw.PromptRateLimitMiddleware(lambda request: HttpResponse("ok"))


def test_rate_limit_is_not_bypassable_via_spoofed_x_forwarded_for():
    """Two rapid prompts from the same real connection must be rate-limited
    even when each request carries a different (attacker-controlled)
    X-Forwarded-For value."""
    middleware = _make_middleware()
    factory = RequestFactory()

    first = factory.post(
        "/agents/demo/prompt", HTTP_X_FORWARDED_FOR="203.0.113.1"
    )
    second = factory.post(
        "/agents/demo/prompt", HTTP_X_FORWARDED_FOR="198.51.100.2"
    )
    assert first.META["REMOTE_ADDR"] == second.META["REMOTE_ADDR"]

    first_response = middleware(first)
    second_response = middleware(second)

    assert first_response.status_code == 200
    assert second_response.status_code == 429, (
        "second request was not rate-limited: a spoofed X-Forwarded-For "
        f"header let it bypass the limiter (got {second_response.status_code}, "
        "expected 429 since both requests came from the same REMOTE_ADDR)"
    )


def test_rate_limit_still_applies_without_any_forwarded_header():
    """Sanity check: the limiter works at all for two back-to-back prompts
    from a client that never sends X-Forwarded-For."""
    middleware = _make_middleware()
    factory = RequestFactory()

    first = factory.post("/agents/demo/prompt")
    second = factory.post("/agents/demo/prompt")

    assert middleware(first).status_code == 200
    assert middleware(second).status_code == 429
