"""Wire protocol message types for gateway <-> connector communication.

All messages are serialized as JSON over WebSocket frames. Each message has a
``type`` field used to discriminate on the receiving end.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from typing import Any


# ---------------------------------------------------------------------------
# Inbound (adapter -> gateway)
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class InboundMessage:
    """A message received from a chat platform, forwarded to the gateway."""

    agent_name: str
    content: str
    channel: dict[str, Any]
    trust: dict[str, Any] = field(default_factory=lambda: {"level": "unverified"})


@dataclass(slots=True)
class RegisterMessage:
    """Sent once after connecting to authenticate the connector."""

    connector_id: str
    platform: str
    token: str


@dataclass(slots=True)
class HealthMessage:
    """Periodic heartbeat sent to the gateway."""

    connector_id: str
    adapters: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Outbound (gateway -> adapter)
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class OutboundMessage:
    """Base for all gateway-originated messages routed to an adapter."""

    type: str
    channel: dict[str, Any]
    agent_name: str = ""
    session_id: str = ""


@dataclass(slots=True)
class AgentTextMessage(OutboundMessage):
    """Agent produced text output."""

    content: str = ""
    thread_id: str | None = None


@dataclass(slots=True)
class AgentTypingMessage(OutboundMessage):
    """Agent started or stopped typing."""

    is_typing: bool = True


@dataclass(slots=True)
class AgentResultMessage(OutboundMessage):
    """Agent finished processing and produced a final result."""

    content: str = ""
    thread_id: str | None = None


@dataclass(slots=True)
class AgentErrorMessage(OutboundMessage):
    """Agent encountered an error."""

    error: str = ""


@dataclass(slots=True)
class AgentStepMessage(OutboundMessage):
    """Intermediate agent step (tool use, tool result, or completion summary)."""

    step_type: str = ""
    name: str = ""
    input: dict[str, Any] = field(default_factory=dict)
    content: str = ""
    is_error: bool = False
    duration_ms: int = 0
    num_turns: int = 0
    cost_usd: float = 0.0


@dataclass(slots=True)
class HeartbeatNotification:
    """Proactive heartbeat output pushed from the gateway to connectors."""

    agent_name: str
    content: str


@dataclass(slots=True)
class RegisteredMessage:
    """Acknowledgement from the gateway after successful registration."""

    connector_id: str


@dataclass(slots=True)
class ActionRequest:
    """Gateway requests the adapter perform a platform action (e.g. react)."""

    action: str
    channel: dict[str, Any]
    params: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class ActionResult:
    """Adapter reports the outcome of an action request."""

    action: str
    success: bool
    detail: str = ""


@dataclass(slots=True)
class ApprovalRequestMessage:
    """Gateway requests human approval for a Cat-3 BCP response."""

    approval_id: str
    from_agent: str
    to_agent: str
    category: int
    query_summary: str
    response_content: str
    anomalies: list[dict[str, Any]] = field(default_factory=list)


@dataclass(slots=True)
class ReactionMessage:
    """A reaction received from a chat platform, forwarded to the gateway."""

    emoji: str
    sender: str
    channel: dict[str, Any]
    agent_name: str = ""
    approval_id: str | None = None
    event_id: str = ""
    trust: dict[str, Any] = field(default_factory=lambda: {"level": "unverified"})


# ---------------------------------------------------------------------------
# Encode / decode helpers
# ---------------------------------------------------------------------------

_OUTBOUND_TYPE_MAP: dict[str, type] = {
    "agent_text": AgentTextMessage,
    "agent_typing": AgentTypingMessage,
    "agent_result": AgentResultMessage,
    "agent_error": AgentErrorMessage,
    "agent_step": AgentStepMessage,
}


def encode(msg: object) -> str:
    """Serialize a protocol message to a JSON string."""
    data: dict[str, Any]
    if isinstance(msg, InboundMessage):
        data = {"type": "message", **asdict(msg)}
    elif isinstance(msg, RegisterMessage):
        data = {"type": "register", **asdict(msg)}
    elif isinstance(msg, HealthMessage):
        data = {"type": "health", **asdict(msg)}
    elif isinstance(msg, ReactionMessage):
        data = {"type": "reaction", **asdict(msg)}
    elif isinstance(msg, ActionResult):
        data = {"type": "action_result", **asdict(msg)}
    elif isinstance(msg, OutboundMessage):
        data = asdict(msg)
    else:
        data = {"type": "unknown", **asdict(msg)}  # type: ignore[arg-type]
    return json.dumps(data)


def decode(raw: str | bytes) -> object:
    """Deserialize a JSON string into a protocol message.

    Returns the appropriate dataclass instance based on the ``type`` field.
    Falls back to returning the raw dict if the type is unrecognised.
    """
    data: dict[str, Any] = json.loads(raw)
    msg_type = data.get("type", "")

    if msg_type == "registered":
        return RegisteredMessage(connector_id=data.get("connector_id", ""))

    if msg_type == "heartbeat_notification":
        return HeartbeatNotification(
            agent_name=data.get("agent_name", ""),
            content=data.get("content", ""),
        )

    if msg_type == "action_request":
        return ActionRequest(
            action=data.get("action", ""),
            channel=data.get("channel", {}),
            params=data.get("params", {}),
        )

    if msg_type == "approval_request":
        return ApprovalRequestMessage(
            approval_id=data.get("approval_id", ""),
            from_agent=data.get("from_agent", ""),
            to_agent=data.get("to_agent", ""),
            category=int(data.get("category", 0)),
            query_summary=data.get("query_summary", ""),
            response_content=data.get("response_content", ""),
            anomalies=data.get("anomalies", []),
        )

    if msg_type in _OUTBOUND_TYPE_MAP:
        cls = _OUTBOUND_TYPE_MAP[msg_type]
        # Only pass fields the dataclass actually accepts (gateway may send
        # extra fields like duration_ms, num_turns, etc.)
        import dataclasses as _dc
        valid = {f.name for f in _dc.fields(cls)}
        fields = {k: v for k, v in data.items() if k in valid and k != "type"}
        return cls(type=msg_type, **fields)

    # Unknown — return as raw dict so the caller can decide
    return data
