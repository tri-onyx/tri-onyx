import json
import logging

import httpx
from django.conf import settings

logger = logging.getLogger(__name__)

_client_instance = None


def _client() -> httpx.Client:
    global _client_instance
    if _client_instance is None:
        _client_instance = httpx.Client(
            base_url=settings.GATEWAY_URL,
            timeout=10.0,
        )
    return _client_instance


class GatewayError(Exception):
    def __init__(self, message: str, status_code: int = 502):
        self.message = message
        self.status_code = status_code
        super().__init__(message)


def get_agents() -> list[dict]:
    try:
        resp = _client().get("/agents")
        resp.raise_for_status()
        return resp.json().get("agents", [])
    except httpx.ConnectError:
        logger.error("Gateway unreachable: GET /agents")
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        logger.warning("Gateway error: GET /agents → %d", e.response.status_code)
        raise GatewayError(f"Gateway error: {e.response.status_code}", e.response.status_code)


def get_agent(name: str) -> dict:
    try:
        resp = _client().get(f"/agents/{name}")
        resp.raise_for_status()
        return resp.json()
    except httpx.ConnectError:
        logger.error("Gateway unreachable: GET /agents/%s", name)
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            raise GatewayError(f"Agent '{name}' not found", 404)
        logger.warning("Gateway error: GET /agents/%s → %d", name, e.response.status_code)
        raise GatewayError(f"Gateway error: {e.response.status_code}", e.response.status_code)


def get_health() -> dict:
    try:
        resp = _client().get("/health")
        resp.raise_for_status()
        return resp.json()
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return {"status": "unreachable", "active_sessions": 0}


def get_approval_count() -> int:
    try:
        bcp = _client().get("/bcp/approvals")
        bcp.raise_for_status()
        bcp_count = len(bcp.json().get("approvals", []))

        actions = _client().get("/actions/approvals")
        actions.raise_for_status()
        action_count = len(actions.json().get("approvals", []))

        return bcp_count + action_count
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return 0


def get_approvals() -> list[dict]:
    items = []
    try:
        bcp = _client().get("/bcp/approvals")
        bcp.raise_for_status()
        for a in bcp.json().get("approvals", []):
            a["kind"] = "bcp"
            items.append(a)
    except (httpx.ConnectError, httpx.HTTPStatusError):
        pass

    try:
        actions = _client().get("/actions/approvals")
        actions.raise_for_status()
        for a in actions.json().get("approvals", []):
            a["kind"] = "action"
            items.append(a)
    except (httpx.ConnectError, httpx.HTTPStatusError):
        pass

    items.sort(key=lambda x: x.get("submitted_at", ""))
    return items


def approve_item(item_id: str, kind: str) -> dict:
    prefix = "bcp" if kind == "bcp" else "actions"
    resp = _client().post(f"/{prefix}/approvals/{item_id}/approve")
    resp.raise_for_status()
    return resp.json()


def reject_item(item_id: str, kind: str, reason: str = "") -> dict:
    prefix = "bcp" if kind == "bcp" else "actions"
    resp = _client().post(
        f"/{prefix}/approvals/{item_id}/reject",
        json={"reason": reason} if reason else {},
    )
    resp.raise_for_status()
    return resp.json()


def get_heartbeat_status() -> dict:
    try:
        resp = _client().get("/heartbeats")
        resp.raise_for_status()
        return resp.json()
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return {"enabled": False, "heartbeats": []}


def start_agent(name: str) -> dict:
    try:
        resp = _client().post(
            f"/agents/{name}/start",
            json={"trigger_type": "verified_input"},
        )
        resp.raise_for_status()
        logger.info("Started agent %s", name)
        return resp.json()
    except httpx.ConnectError:
        logger.error("Gateway unreachable: POST /agents/%s/start", name)
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            raise GatewayError(f"Agent '{name}' not found", 404)
        logger.warning("Failed to start agent %s: %d", name, e.response.status_code)
        raise GatewayError(f"Failed to start agent: {e.response.status_code}", e.response.status_code)


def stop_agent(name: str) -> dict:
    try:
        resp = _client().post(f"/agents/{name}/stop", json={})
        resp.raise_for_status()
        logger.info("Stopped agent %s", name)
        return resp.json()
    except httpx.ConnectError:
        logger.error("Gateway unreachable: POST /agents/%s/stop", name)
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        logger.warning("Failed to stop agent %s: %d", name, e.response.status_code)
        raise GatewayError(f"Failed to stop agent: {e.response.status_code}", e.response.status_code)


def send_prompt(name: str, content: str) -> dict:
    try:
        resp = _client().post(
            f"/agents/{name}/prompt",
            json={"content": content},
        )
        resp.raise_for_status()
        logger.info("Sent prompt to %s (%d chars)", name, len(content))
        return resp.json()
    except httpx.ConnectError:
        logger.error("Gateway unreachable: POST /agents/%s/prompt", name)
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        logger.warning("Failed to send prompt to %s: %d", name, e.response.status_code)
        raise GatewayError(f"Failed to send prompt: {e.response.status_code}", e.response.status_code)


def list_agent_sessions(agent_name: str) -> list[dict]:
    try:
        resp = _client().get(f"/logs/{agent_name}")
        resp.raise_for_status()
        return resp.json().get("sessions", [])
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return []


def get_graph_analysis() -> dict:
    try:
        resp = _client().get("/graph/analysis")
        resp.raise_for_status()
        return resp.json()
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return {}


def get_session_image(agent_name: str, session_id: str, image_id: str):
    """Proxy a session image from the Elixir gateway. Returns raw httpx.Response."""
    resp = _client().get(
        f"/images/{agent_name}/{session_id}/{image_id}",
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp


def get_session_page(commit: str, page_path: str):
    """Proxy an HTML page artifact from the Elixir gateway. Returns raw httpx.Response."""
    resp = _client().get(
        f"/pages/{commit}/{page_path}",
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp


def get_session_log(agent_name: str, session_id: str) -> list[dict]:
    try:
        resp = _client().get(
            f"/logs/{agent_name}/{session_id}",
            timeout=30.0,
        )
        resp.raise_for_status()
        events = []
        for line in resp.text.strip().split("\n"):
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return events
    except (httpx.ConnectError, httpx.HTTPStatusError):
        return []
