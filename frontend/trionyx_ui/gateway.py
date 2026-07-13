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


class GatewayValidationError(GatewayError):
    def __init__(self, message: str, errors: list[dict]):
        super().__init__(message, 400)
        self.errors = errors


def _request(
    method: str,
    path: str,
    *,
    json_body: dict | None = None,
    not_found: str | None = None,
    conflict: str | None = None,
    check_validation: bool = False,
    error_prefix: str = "Gateway error",
) -> httpx.Response:
    """Issue a gateway request, translating httpx errors into GatewayError.

    - `not_found`: message for a 404 response (otherwise falls through to generic).
    - `conflict`: default message for a 409 response (gateway "message" field wins).
    - `check_validation`: raise GatewayValidationError on 400 with "details".
    - `error_prefix`: prefix for the generic error message and warning log.
    """
    try:
        resp = _client().request(method, path, json=json_body)
        resp.raise_for_status()
        return resp
    except httpx.RequestError as e:
        logger.error("Gateway unreachable: %s %s (%s)", method, path, type(e).__name__)
        raise GatewayError("Gateway unreachable")
    except httpx.HTTPStatusError as e:
        status = e.response.status_code
        body = {}
        if e.response.headers.get("content-type", "").startswith("application/json"):
            body = e.response.json()
        if check_validation and status == 400 and "details" in body:
            raise GatewayValidationError(body.get("error", "Validation failed"), body["details"])
        if not_found is not None and status == 404:
            raise GatewayError(not_found, 404)
        if conflict is not None and status == 409:
            raise GatewayError(body.get("message", conflict), 409)
        logger.warning("%s: %s %s → %d", error_prefix, method, path, status)
        raise GatewayError(f"{error_prefix}: {status}", status)


def _try_get_json(path: str, fallback):
    """GET a JSON endpoint, returning `fallback` if the gateway is unreachable
    or responds with an error. For endpoints where the UI degrades gracefully."""
    try:
        resp = _client().get(path)
        resp.raise_for_status()
        return resp.json()
    except (httpx.RequestError, httpx.HTTPStatusError):
        return fallback


def get_agents() -> list[dict]:
    return _request("GET", "/agents").json().get("agents", [])


def get_agent(name: str) -> dict:
    return _request("GET", f"/agents/{name}", not_found=f"Agent '{name}' not found").json()


def get_health() -> dict:
    return _try_get_json("/health", {"status": "unreachable", "active_sessions": 0})


def get_approval_count() -> int:
    count = 0
    for path in ("/bcp/approvals", "/actions/approvals"):
        data = _try_get_json(path, None)
        if data is not None:
            count += len(data.get("approvals", []))
    return count


def get_approvals() -> list[dict]:
    items = []
    for kind, path in (("bcp", "/bcp/approvals"), ("action", "/actions/approvals")):
        for a in _try_get_json(path, {}).get("approvals", []):
            a["kind"] = kind
            items.append(a)

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
    return _try_get_json("/heartbeats", {"enabled": False, "heartbeats": []})


def start_agent(name: str) -> dict:
    resp = _request(
        "POST",
        f"/agents/{name}/start",
        json_body={"trigger_type": "verified_input"},
        not_found=f"Agent '{name}' not found",
        error_prefix="Failed to start agent",
    )
    logger.info("Started agent %s", name)
    return resp.json()


def stop_agent(name: str, session_id: str | None = None) -> dict:
    body: dict = {}
    if session_id:
        body["session_id"] = session_id
    resp = _request(
        "POST",
        f"/agents/{name}/stop",
        json_body=body,
        error_prefix="Failed to stop agent",
    )
    logger.info("Stopped agent %s", name)
    return resp.json()


def send_prompt(name: str, content: str, session_id: str | None = None) -> dict:
    body: dict = {"content": content}
    if session_id:
        body["session_id"] = session_id
    resp = _request(
        "POST",
        f"/agents/{name}/prompt",
        json_body=body,
        error_prefix="Failed to send prompt",
    )
    logger.info("Sent prompt to %s (%d chars)", name, len(content))
    return resp.json()


def list_agent_sessions(agent_name: str) -> list[dict]:
    return _try_get_json(f"/logs/{agent_name}", {}).get("sessions", [])


def get_graph_analysis() -> dict:
    return _try_get_json("/graph/analysis", {})


def get_session_image(agent_name: str, session_id: str, image_id: str):
    """Proxy a session image from the Elixir gateway. Returns raw httpx.Response."""
    resp = _client().get(
        f"/images/{agent_name}/{session_id}/{image_id}",
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp


def get_session_audio(agent_name: str, session_id: str, audio_id: str):
    """Proxy a session audio file from the Elixir gateway. Returns raw httpx.Response."""
    resp = _client().get(
        f"/audio/{agent_name}/{session_id}/{audio_id}",
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
    except (httpx.RequestError, httpx.HTTPStatusError):
        return []


# --- Agent Builder ---


def get_agent_schema() -> dict:
    return _request("GET", "/agents/schema").json()


def get_agent_definition(name: str) -> dict:
    return _request(
        "GET",
        f"/agents/{name}/definition",
        not_found=f"Agent '{name}' not found",
    ).json()


def get_agent_context(name: str) -> str:
    return (
        _request(
            "GET",
            f"/agents/{name}/context",
            not_found=f"Agent '{name}' not found",
        )
        .json()
        .get("context", "")
    )


def create_agent(data: dict) -> dict:
    resp = _request(
        "POST",
        "/agents",
        json_body=data,
        conflict="Agent already exists",
        check_validation=True,
        error_prefix="Failed to create agent",
    )
    logger.info("Created agent %s", data.get("name", "?"))
    return resp.json()


def update_agent(name: str, data: dict) -> dict:
    resp = _request(
        "PUT",
        f"/agents/{name}",
        json_body=data,
        not_found=f"Agent '{name}' not found",
        check_validation=True,
        error_prefix="Failed to update agent",
    )
    logger.info("Updated agent %s", name)
    return resp.json()


def delete_agent(name: str) -> dict:
    resp = _request(
        "DELETE",
        f"/agents/{name}",
        not_found=f"Agent '{name}' not found",
        conflict="Agent has active sessions",
        error_prefix="Failed to delete agent",
    )
    logger.info("Deleted agent %s", name)
    return resp.json()
