"""The dashboard is the human side of TriOnyx's approval gate: a BCP query or
a risky tool action stays blocked until an operator clicks Approve on
``/approvals/<item_id>`` (see ``trionyx_ui.views.approvals.approval_action``
and ``docs/`` on ``TriOnyx.BCP.ApprovalQueue``). If the response can be
embedded in a cross-origin iframe, an attacker's page can overlay decoy UI
over the real Approve button and UI-redress a click the operator never
intended — bypassing the approval gate without forging any request (the
click is genuine, so the CSRF token travels with it).

Django ships ``XFrameOptionsMiddleware`` for exactly this, defaulting to
``DENY``. The project's ``MIDDLEWARE`` list never includes it.
"""

from unittest.mock import Mock, patch

from django.test import Client


def test_approval_action_response_denies_framing():
    client = Client()
    resp = client.get("/approvals/some-item-id")  # 405: GET isn't allowed, but
    # the security headers must still apply to every response, not just 2xx.

    assert resp.status_code == 405
    assert resp.get("X-Frame-Options") == "DENY", (
        "response is missing X-Frame-Options: an attacker page can iframe "
        "the approvals endpoint and UI-redress a click onto the real "
        "Approve button, bypassing the human-in-the-loop approval gate"
    )


def test_healthz_response_denies_framing():
    client = Client()
    resp = client.get("/healthz")

    assert resp.get("X-Frame-Options") == "DENY", (
        "no response from the dashboard sets X-Frame-Options — every page, "
        "including the chat and approvals views, is embeddable in a "
        "cross-origin iframe"
    )


def test_session_page_stays_embeddable_same_origin():
    """chat.js deliberately embeds agent-authored HTML pages via
    ``<iframe sandbox="allow-scripts">`` on the same page (see
    ``static/js/chat.js``); that response is hardened by its own
    ``Content-Security-Policy: sandbox ...`` header (an opaque-origin
    sandbox), not by X-Frame-Options, so it must stay exempt from the
    blanket DENY or that feature breaks.
    """
    fake_gateway_resp = Mock(content=b"<p>hi</p>")
    client = Client()
    with patch(
        "trionyx_ui.gateway.get_session_page", return_value=fake_gateway_resp
    ):
        resp = client.get("/workspace/pages/0123456/whatever.html")

    assert resp.status_code == 200
    assert resp.get("Content-Security-Policy") == "sandbox allow-scripts"
    assert resp.get("X-Frame-Options") is None
