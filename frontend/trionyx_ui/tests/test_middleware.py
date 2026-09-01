"""Security property: the per-client prompt rate limit cannot be bypassed by
spoofing the client-supplied X-Forwarded-For header."""

from django.test import Client, SimpleTestCase


class PromptRateLimitBypassTest(SimpleTestCase):
    def test_spoofed_x_forwarded_for_cannot_bypass_rate_limit(self):
        """The rate limiter keys on X-Forwarded-For, which any client can set
        to an arbitrary value on every request. A single real client (one
        REMOTE_ADDR) sending two prompts back-to-back with a different
        X-Forwarded-For each time must still be rate limited on the second
        request — the header must not let it evade the per-IP bucket."""
        client = Client()
        url = "/agents/demo/prompt"

        first = client.post(
            url, {"content": "hello"}, HTTP_X_FORWARDED_FOR="203.0.113.1"
        )
        self.assertNotEqual(
            first.status_code, 429, "first request should not be rate limited"
        )

        second = client.post(
            url, {"content": "hello again"}, HTTP_X_FORWARDED_FOR="203.0.113.2"
        )
        self.assertEqual(
            second.status_code,
            429,
            "a second prompt from the same real client, sent immediately "
            "after the first with only the X-Forwarded-For header changed, "
            "must still be rate limited — the real client identity "
            "(REMOTE_ADDR), not a client-supplied header, is what the rate "
            "limit must key on",
        )
