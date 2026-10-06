"""Caller-supplied URL parts must not steer frontend→gateway requests."""

import httpx
import pytest
from django.test import Client

from trionyx_ui import gateway


@pytest.fixture
def seen(monkeypatch):
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={})

    client = httpx.Client(
        base_url="http://gateway.invalid", transport=httpx.MockTransport(handler)
    )
    monkeypatch.setattr(gateway, "_client_instance", client)
    return requests


def test_session_page_cannot_traverse_to_other_gateway_endpoints(seen):
    # Django decodes %3F to "?" before the view runs, so the ".html"
    # extension check passes while httpx would treat the rest as a query.
    resp = Client().get("/workspace/pages/abc1234/../../api/workspace/file%3F.html")

    assert not any(r.url.path == "/api/workspace/file" for r in seen), (
        "session_page let a dashboard client reach an arbitrary gateway "
        f"endpoint: {[str(r.url) for r in seen]}"
    )
    assert resp.status_code != 200


def test_session_page_legitimate_path_still_proxied(seen):
    resp = Client().get("/workspace/pages/abc1234/site/index.html")

    assert resp.status_code == 200
    assert [r.url.path for r in seen] == ["/pages/abc1234/site/index.html"]


@pytest.mark.parametrize("bad", ["..", ".", "", "a?b", "a#b"])
def test_agent_name_cannot_rewrite_gateway_path(seen, bad):
    for call in (
        lambda: gateway.start_agent(bad),
        lambda: gateway.get_agent(bad),
        lambda: gateway.delete_agent(bad),
    ):
        try:
            call()
        except Exception:
            pass

    for r in seen:
        assert r.url.raw_path.decode().split("?")[0].count("/") <= 3, (
            f"agent name {bad!r} escaped its path segment: {r.url}"
        )
        assert not r.url.query, f"agent name {bad!r} injected a query: {r.url}"
