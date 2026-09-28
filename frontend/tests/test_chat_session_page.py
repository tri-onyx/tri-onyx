from unittest.mock import patch

import httpx
import pytest


@pytest.fixture
def capture_outgoing_url():
    """Patch httpx so we can see the request the frontend actually sends
    the gateway, without needing a live gateway or Docker."""
    captured = {}
    orig_build_request = httpx.Client.build_request

    def spy(self, method, url, **kwargs):
        request = orig_build_request(self, method, url, **kwargs)
        captured["url"] = str(request.url)
        return request

    with patch.object(httpx.Client, "build_request", spy):
        with patch.object(httpx.Client, "send", side_effect=httpx.ConnectError("no gateway in test")):
            yield captured


def test_session_page_cannot_redirect_to_an_arbitrary_gateway_route(client, capture_outgoing_url):
    """The `/workspace/pages/<commit>/<page_path>` proxy must only ever
    reach the gateway's `/pages/<commit>/...` route.

    `session_page` builds the gateway request as
    f"/pages/{commit}/{page_path}" and hands the raw string to httpx,
    which parses it as a URL. A page_path containing a literal "?"
    reopens the query string, letting a caller redirect the proxied
    request to an arbitrary gateway GET route (here, the audit log) with
    an attacker-chosen query string -- something this endpoint never
    intends to expose. The attacker sends the "?" percent-encoded
    (`%3F`) so it survives as literal path text instead of being parsed
    as the HTTP request's own query separator; Django's `path` converter
    decodes it back to a literal "?" before the view ever sees it.
    """
    # Decodes to page_path == '../../audit?leak=1.html'
    encoded_page_path = "..%2F..%2Faudit%3Fleak%3D1.html"

    response = client.get(f"/workspace/pages/abcdef1/{encoded_page_path}")

    assert "url" not in capture_outgoing_url, (
        "session_page must never let page_path redirect the proxied request "
        f"to a different gateway route, but it built: {capture_outgoing_url.get('url')!r}"
    )
    assert response.status_code == 400, (
        "session_page must reject a page_path that escapes the /pages/ "
        f"route instead of forwarding it to the gateway (got {response.status_code})"
    )


def test_session_page_rejects_parent_traversal(client, capture_outgoing_url):
    """Even without the "?" trick, a bare ".." segment must not be
    forwarded to the gateway -- it would let a caller address a
    different commit's file than the one named in the URL."""
    response = client.get("/workspace/pages/abcdef1/../secret.html")

    assert "url" not in capture_outgoing_url, (
        "session_page must not forward a page_path containing '..' to the "
        f"gateway, but it built: {capture_outgoing_url.get('url')!r}"
    )
    assert response.status_code == 400


def test_session_page_allows_ordinary_nested_page(client, capture_outgoing_url):
    """A normal artifact path (nested, no traversal) must still be
    forwarded to the gateway unchanged. No live gateway is reachable in
    this test (the mocked send() always raises), so the view falls back
    to its generic 404 -- we only care that it *attempted* the proxied
    request, and to the right URL."""
    response = client.get("/workspace/pages/abcdef1/reports/summary.html")

    assert response.status_code == 404
    assert capture_outgoing_url.get("url") == "http://localhost:4000/pages/abcdef1/reports/summary.html"
