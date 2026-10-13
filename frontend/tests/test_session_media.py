"""Agent-submitted media must not execute in the dashboard origin."""

from unittest import mock

import httpx
from django.test import Client

SVG_WITH_SCRIPT = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'


def _gateway_response(content: bytes, content_type: str) -> httpx.Response:
    return httpx.Response(200, content=content, headers={"content-type": content_type})


def test_agent_svg_is_served_sandboxed():
    """An agent can submit an arbitrary .svg (submit_image). Opened directly
    it is a top-level document on the dashboard origin, so without a
    sandboxing CSP its <script> runs with the dashboard's privileges
    (e.g. posting to /approvals/<id>)."""
    resp_in = _gateway_response(SVG_WITH_SCRIPT, "image/svg+xml")
    with mock.patch("trionyx_ui.gateway.get_session_image", return_value=resp_in):
        resp = Client().get("/workspace/images/agent/sess/abc.svg")

    assert resp.status_code == 200
    csp = resp.headers.get("Content-Security-Policy", "")
    assert "sandbox" in csp and "default-src 'none'" in csp, (
        "agent-supplied SVG must be served with a sandboxing CSP, got %r" % csp
    )
    assert resp.headers.get("X-Content-Type-Options") == "nosniff"
