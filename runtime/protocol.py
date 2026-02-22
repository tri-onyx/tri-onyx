"""
TriOnyx Agent Runtime Protocol

Structured JSON message types exchanged between the Elixir gateway and the
Python agent runtime over stdin/stdout.  Each message is a single JSON object
on its own line (JSON Lines format).

Gateway -> Runtime (stdin):
  start                  -- agent configuration (name, tools, model, system_prompt, ...)
  prompt                 -- trigger payload to drive an agent session
  shutdown               -- graceful shutdown request
  send_message_response  -- gateway response after routing an inter-agent message
  restart_agent_response -- gateway response after a restart_agent_request
  bcp_query             -- BCP query delivered to a Reader agent
  bcp_response_delivery -- validated BCP response delivered to a Controller agent

Runtime -> Gateway (stdout):
  ready                -- runtime initialized, awaiting configuration
  text                 -- LLM text output (for audit logging)
  tool_use             -- tool invocation (observational, for audit logging)
  tool_result          -- tool result (observational, for taint tracking)
  result               -- session completed with metadata
  error                -- error occurred
  log                  -- runtime log message (level + message)
  send_message_request   -- request gateway to route a message to another agent
  restart_agent_request  -- request gateway to restart another agent
  bcp_query_request     -- Controller requests a BCP query to a Reader
  bcp_response        -- Reader responds to a BCP query
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from typing import Any


# ---------------------------------------------------------------------------
# Inbound message types (gateway -> runtime via stdin)
# ---------------------------------------------------------------------------


@dataclass
class StartMessage:
    """Agent configuration sent by the gateway at process start."""

    name: str
    tools: list[str]
    model: str
    system_prompt: str
    max_turns: int
    cwd: str
    skills: list[str]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> StartMessage:
        agent = data.get("agent", {})
        return cls(
            name=agent.get("name", "unnamed"),
            tools=agent.get("tools", []),
            model=agent.get("model", "claude-sonnet-4-20250514"),
            system_prompt=agent.get("system_prompt", ""),
            max_turns=agent.get("max_turns", 10),
            cwd=agent.get("cwd", "/workspace"),
            skills=agent.get("skills", []),
        )


@dataclass
class PromptMessage:
    """Trigger payload for an agent session."""

    content: str
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PromptMessage:
        return cls(
            content=data.get("content", ""),
            metadata=data.get("metadata", {}),
        )


@dataclass
class ShutdownMessage:
    """Graceful shutdown request from the gateway."""

    reason: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ShutdownMessage:
        return cls(reason=data.get("reason", ""))


@dataclass
class MemorySaveMessage:
    """Request from the gateway to save memory before shutdown."""

    reason: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MemorySaveMessage:
        return cls(reason=data.get("reason", ""))


@dataclass
class SendMessageResponse:
    """Response from the gateway after routing a send_message_request."""

    request_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SendMessageResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


@dataclass
class BCPQueryMessage:
    """BCP query delivered to a Reader agent by the gateway."""

    query_id: str
    category: int
    from_agent: str
    fields: list[dict[str, Any]] | None = None
    questions: list[dict[str, Any]] | None = None
    directive: str | None = None
    max_words: int | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BCPQueryMessage:
        return cls(
            query_id=data.get("query_id", ""),
            category=data.get("category", 0),
            from_agent=data.get("from_agent", ""),
            fields=data.get("fields"),
            questions=data.get("questions"),
            directive=data.get("directive"),
            max_words=data.get("max_words"),
        )


@dataclass
class BCPResponseDeliveryMessage:
    """Validated BCP response delivered to a Controller agent by the gateway."""

    query_id: str
    category: int
    from_agent: str
    response: dict[str, Any] = field(default_factory=dict)
    bandwidth_bits: float = 0.0

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BCPResponseDeliveryMessage:
        return cls(
            query_id=data.get("query_id", ""),
            category=data.get("category", 0),
            from_agent=data.get("from_agent", ""),
            response=data.get("response", {}),
            bandwidth_bits=data.get("bandwidth_bits", 0.0),
        )


@dataclass
class BCPValidationResult:
    """Result of BCP response validation, sent back to the Reader agent."""

    query_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BCPValidationResult:
        return cls(
            query_id=data.get("query_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


@dataclass
class SendEmailResponse:
    """Response from the gateway after sending an email."""

    request_id: str
    success: bool
    detail: str = ""
    message_id: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SendEmailResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
            message_id=data.get("message_id", ""),
        )


@dataclass
class MoveEmailResponse:
    """Response from the gateway after moving an email."""

    request_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MoveEmailResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


@dataclass
class CreateFolderResponse:
    """Response from the gateway after creating a folder."""

    request_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CreateFolderResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


@dataclass
class RestartAgentResponse:
    """Response from the gateway after a restart_agent_request."""

    request_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RestartAgentResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


@dataclass
class CalendarQueryResponse:
    """Response from the gateway after a CalendarQuery request."""

    request_id: str
    success: bool
    detail: str = ""
    events: list[dict[str, Any]] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CalendarQueryResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
            events=data.get("events", []),
        )


@dataclass
class CalendarCreateResponse:
    """Response from the gateway after a CalendarCreate request."""

    request_id: str
    success: bool
    detail: str = ""
    event: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CalendarCreateResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
            event=data.get("event", {}),
        )


@dataclass
class CalendarUpdateResponse:
    """Response from the gateway after a CalendarUpdate request."""

    request_id: str
    success: bool
    detail: str = ""
    event: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CalendarUpdateResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
            event=data.get("event", {}),
        )


@dataclass
class CalendarDeleteResponse:
    """Response from the gateway after a CalendarDelete request."""

    request_id: str
    success: bool
    detail: str = ""

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CalendarDeleteResponse:
        return cls(
            request_id=data.get("request_id", ""),
            success=data.get("success", False),
            detail=data.get("detail", ""),
        )


InboundMessage = (
    StartMessage
    | PromptMessage
    | ShutdownMessage
    | MemorySaveMessage
    | SendMessageResponse
    | BCPQueryMessage
    | BCPResponseDeliveryMessage
    | SendEmailResponse
    | MoveEmailResponse
    | CreateFolderResponse
    | RestartAgentResponse
    | CalendarQueryResponse
    | CalendarCreateResponse
    | CalendarUpdateResponse
    | CalendarDeleteResponse
)

_INBOUND_PARSERS: dict[str, type] = {
    "start": StartMessage,
    "prompt": PromptMessage,
    "shutdown": ShutdownMessage,
    "memory_save": MemorySaveMessage,
    "send_message_response": SendMessageResponse,
    "bcp_query": BCPQueryMessage,
    "bcp_response_delivery": BCPResponseDeliveryMessage,
    "send_email_response": SendEmailResponse,
    "move_email_response": MoveEmailResponse,
    "create_folder_response": CreateFolderResponse,
    "restart_agent_response": RestartAgentResponse,
    "calendar_query_response": CalendarQueryResponse,
    "calendar_create_response": CalendarCreateResponse,
    "calendar_update_response": CalendarUpdateResponse,
    "calendar_delete_response": CalendarDeleteResponse,
}


def parse_inbound(data: dict[str, Any]) -> InboundMessage:
    """Parse a raw dict into a typed inbound message.

    Raises ValueError if the message type is unknown.
    """
    msg_type = data.get("type")
    parser = _INBOUND_PARSERS.get(msg_type)  # type: ignore[arg-type]
    if parser is None:
        raise ValueError(f"Unknown message type: {msg_type!r}")
    return parser.from_dict(data)


# ---------------------------------------------------------------------------
# Outbound message emitters (runtime -> gateway via stdout)
# ---------------------------------------------------------------------------


def _emit(msg: dict[str, Any]) -> None:
    """Write a compact JSON line to stdout and flush immediately."""
    sys.stdout.write(json.dumps(msg, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def emit_ready() -> None:
    """Signal that the runtime is initialized and ready for prompts."""
    _emit({"type": "ready"})


def emit_text(content: str) -> None:
    """Stream LLM text output to the gateway."""
    _emit({"type": "text", "content": content})


def emit_tool_use(
    tool_use_id: str, name: str, input_data: dict[str, Any]
) -> None:
    """Report a tool invocation (observational -- for audit logging)."""
    _emit({"type": "tool_use", "id": tool_use_id, "name": name, "input": input_data})


def emit_tool_result(
    tool_use_id: str, content: str, is_error: bool = False
) -> None:
    """Report a tool result (observational -- for taint tracking).

    The gateway uses tool results to determine if untrusted data has entered
    the LLM context, and to update the session's taint status.
    """
    _emit({
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "content": content,
        "is_error": is_error,
    })


def emit_result(
    duration_ms: int,
    num_turns: int,
    cost_usd: float,
    is_error: bool = False,
) -> None:
    """Report session completion with metadata."""
    _emit({
        "type": "result",
        "duration_ms": duration_ms,
        "num_turns": num_turns,
        "cost_usd": cost_usd,
        "is_error": is_error,
    })


def emit_error(message: str) -> None:
    """Report an error to the gateway."""
    _emit({"type": "error", "message": message})


def emit_log(level: str, message: str) -> None:
    """Forward a runtime log message to the gateway."""
    _emit({"type": "log", "level": level, "message": message})


def emit_send_message_request(
    request_id: str,
    to: str,
    message_type: str,
    payload: dict[str, Any],
) -> None:
    """Request the gateway to route a message to another agent.

    The gateway mediates and sanitizes all inter-agent communication.
    The runtime blocks until it receives a `send_message_response` with
    the matching request_id.
    """
    _emit({
        "type": "send_message_request",
        "request_id": request_id,
        "to": to,
        "message_type": message_type,
        "payload": payload,
    })


def emit_bcp_query_request(
    request_id: str,
    to: str,
    category: int,
    spec: dict[str, Any],
) -> None:
    """Request the gateway to send a BCP query to a Reader agent.

    Emitted by a Controller agent's runtime.  The gateway validates the
    query against bandwidth constraints and routes it to the target Reader.
    """
    _emit({
        "type": "bcp_query_request",
        "request_id": request_id,
        "to": to,
        "category": category,
        "spec": spec,
    })


def emit_send_email_request(
    request_id: str,
    draft_path: str,
) -> None:
    """Request the gateway to send an email from a draft file."""
    _emit({
        "type": "send_email_request",
        "request_id": request_id,
        "draft_path": draft_path,
    })


def emit_move_email_request(
    request_id: str,
    uid: str,
    source_folder: str,
    dest_folder: str,
) -> None:
    """Request the gateway to move an email between IMAP folders."""
    _emit({
        "type": "move_email_request",
        "request_id": request_id,
        "uid": uid,
        "source_folder": source_folder,
        "dest_folder": dest_folder,
    })


def emit_create_folder_request(
    request_id: str,
    folder_name: str,
) -> None:
    """Request the gateway to create an IMAP folder."""
    _emit({
        "type": "create_folder_request",
        "request_id": request_id,
        "folder_name": folder_name,
    })


def emit_calendar_query_request(
    request_id: str,
    params: dict[str, Any],
) -> None:
    """Request the gateway to query calendar events."""
    _emit({
        "type": "calendar_query_request",
        "request_id": request_id,
        "params": params,
    })


def emit_calendar_create_request(
    request_id: str,
    draft_path: str,
) -> None:
    """Request the gateway to create a calendar event from a draft."""
    _emit({
        "type": "calendar_create_request",
        "request_id": request_id,
        "draft_path": draft_path,
    })


def emit_calendar_update_request(
    request_id: str,
    draft_path: str,
) -> None:
    """Request the gateway to update a calendar event from a draft."""
    _emit({
        "type": "calendar_update_request",
        "request_id": request_id,
        "draft_path": draft_path,
    })


def emit_calendar_delete_request(
    request_id: str,
    uid: str,
    calendar: str,
) -> None:
    """Request the gateway to delete a calendar event."""
    _emit({
        "type": "calendar_delete_request",
        "request_id": request_id,
        "uid": uid,
        "calendar": calendar,
    })


def emit_restart_agent_request(
    request_id: str,
    agent_name: str,
    force: bool,
) -> None:
    """Request the gateway to restart another agent's session."""
    _emit({
        "type": "restart_agent_request",
        "request_id": request_id,
        "agent_name": agent_name,
        "force": force,
    })


def emit_bcp_response(
    query_id: str,
    response: dict[str, Any],
) -> None:
    """Respond to a BCP query received from the gateway.

    Emitted by a Reader agent's runtime after the LLM has produced a
    response to the query.  The gateway validates the response against
    bandwidth constraints before delivering it to the requesting Controller.
    """
    _emit({
        "type": "bcp_response",
        "query_id": query_id,
        "response": response,
    })
