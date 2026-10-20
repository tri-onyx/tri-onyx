"""Agent-authored assets proxied from the gateway must not run script on the
dashboard origin."""

from unittest import mock

import httpx
import pytest
from django.test import Client

from trionyx_ui import gateway

SVG_WITH_SCRIPT = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'


@pytest.fixture
def client():
    return Client()


def _svg_response():
    return httpx.Response(
        200,
        content=SVG_WITH_SCRIPT,
        headers={"content-type": "image/svg+xml"},
    )


def test_agent_svg_is_served_sandboxed(client):
    """An agent-written SVG opened top-level (e.g. via a markdown link in its
    own output) must not execute script with the dashboard's origin: that
    would let an agent drive the approval endpoints and bypass the gate."""
    with mock.patch.object(gateway, "get_session_image", return_value=_svg_response()):
        resp = client.get("/workspace/images/agent/sess/evil.svg")

    assert resp.status_code == 200
    csp = resp["Content-Security-Policy"]
    assert "sandbox" in csp.split(), (
        "SVG must be served under a CSP sandbox without allow-scripts / "
        "allow-same-origin so embedded script cannot reach the dashboard origin"
    )
    assert "allow-scripts" not in csp
    assert "allow-same-origin" not in csp
    assert resp["X-Content-Type-Options"] == "nosniff"
