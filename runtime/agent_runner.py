# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk==0.1.37"]
# ///
"""
TriOnyx Agent Runner

Bridge between the Elixir gateway and the Claude Agent SDK.  Spawned as a
subprocess via `uv run runtime/agent_runner.py` and communicates over a
structured JSON protocol on stdin/stdout.

The runner is not agentic -- it executes a controlled loop:
  1. Receive agent configuration from the gateway (start message)
  2. Signal readiness (ready message)
  3. Receive prompts from the gateway and drive SDK sessions
  4. Stream events back to the gateway for observation
  5. Handle shutdown requests gracefully

The agent talks to the Claude API directly and executes its own tools via the
SDK.  The gateway does NOT proxy tool calls at runtime.  Events streamed to
stdout are observational only -- the gateway uses them for taint tracking and
audit logging.

Uses ClaudeSDKClient (not query()) to maintain conversation context across
multiple prompts within the same session.

Protocol reference: docs/protocol.md
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
import time
import uuid
from pathlib import Path
from typing import Any

# Ensure runtime/ is importable so we can use protocol.py
sys.path.insert(0, str(Path(__file__).parent))

from protocol import (
    StartMessage,
    PromptMessage,
    InterruptMessage,
    ShutdownMessage,
    MemorySaveMessage,
    SendMessageResponse,
    RestartAgentResponse,
    BCPQueryMessage,
    BCPQueryErrorMessage,
    BCPResponseDeliveryMessage,
    BCPValidationResult,
    BCPSubscriptionsActive,
    SendEmailResponse,
    SaveDraftResponse,
    MoveEmailResponse,
    CreateFolderResponse,
    CalendarQueryResponse,
    CalendarCreateResponse,
    CalendarUpdateResponse,
    CalendarDeleteResponse,
    SubmitItemResponse,
    _INBOUND_PARSERS,
    parse_inbound,
    emit_ready,
    emit_text,
    emit_tool_use,
    emit_tool_result,
    emit_result,
    emit_error,
    emit_interrupted,
    emit_send_message_request,
    emit_restart_agent_request,
    emit_bcp_query_request,
    emit_bcp_response,
    emit_bcp_publish,
    emit_send_email_request,
    emit_save_draft_request,
    emit_move_email_request,
    emit_create_folder_request,
    emit_calendar_query_request,
    emit_calendar_create_request,
    emit_calendar_update_request,
    emit_calendar_delete_request,
    emit_submit_item_request,
    emit_log,
)

from claude_agent_sdk import (
    ClaudeAgentOptions,
    ClaudeSDKClient,
    AssistantMessage,
    UserMessage,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    ToolResultBlock,
    tool,
    create_sdk_mcp_server,
)

# ---------------------------------------------------------------------------
# Logging -- dual output: stderr for `docker logs`, stdout protocol for gateway
# ---------------------------------------------------------------------------


class ProtocolLogHandler(logging.Handler):
    """Logging handler that forwards log records to the gateway via the stdout JSON protocol."""

    _LEVEL_MAP = {
        logging.DEBUG: "debug",
        logging.INFO: "info",
        logging.WARNING: "warning",
        logging.ERROR: "error",
        logging.CRITICAL: "critical",
    }

    def emit(self, record: logging.LogRecord) -> None:
        try:
            level = self._LEVEL_MAP.get(record.levelno, "info")
            emit_log(level, self.format(record))
        except Exception:
            # Never let logging errors crash the runtime
            pass


log = logging.getLogger("agent_runner")
log.setLevel(logging.INFO)
log.propagate = False

# Only use the protocol handler — stderr is merged into stdout by the gateway
# port (:stderr_to_stdout), so plain-text log lines would break JSON parsing.
_protocol_handler = ProtocolLogHandler()
_protocol_handler.setLevel(logging.INFO)
_protocol_handler.setFormatter(logging.Formatter("%(message)s"))
log.addHandler(_protocol_handler)

# Maximum length for tool result content streamed to the gateway.
# Results are truncated to avoid flooding the protocol channel.
_MAX_TOOL_RESULT_LEN = 4096


# ---------------------------------------------------------------------------
# Inbound message dispatcher
# ---------------------------------------------------------------------------


class InboundDispatcher:
    """Reads stdin and dispatches messages to typed queues.

    The runtime needs to handle two kinds of inbound messages concurrently:

    1. **Control messages** (start, prompt, shutdown) -- consumed by the main
       event loop sequentially.
    2. **Tool responses** (send_message_response, email responses) -- consumed
       by handlers while the SDK session is running.

    A background reader task reads JSON lines from stdin and places parsed
    messages onto the correct queue.  This avoids the main loop and the
    send-message handler from competing over a single stdin read.
    """

    def __init__(self) -> None:
        self.control_queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        self.interrupt_event: asyncio.Event = asyncio.Event()
        self.send_message_responses: asyncio.Queue[SendMessageResponse] = asyncio.Queue()
        self.bcp_query_queue: asyncio.Queue[BCPQueryMessage] = asyncio.Queue()
        self.bcp_validation_results: asyncio.Queue[BCPValidationResult] = asyncio.Queue()
        self.send_email_responses: asyncio.Queue[SendEmailResponse] = asyncio.Queue()
        self.save_draft_responses: asyncio.Queue[SaveDraftResponse] = asyncio.Queue()
        self.move_email_responses: asyncio.Queue[MoveEmailResponse] = asyncio.Queue()
        self.create_folder_responses: asyncio.Queue[CreateFolderResponse] = asyncio.Queue()
        self.restart_agent_responses: asyncio.Queue[RestartAgentResponse] = asyncio.Queue()
        self.calendar_query_responses: asyncio.Queue[CalendarQueryResponse] = asyncio.Queue()
        self.calendar_create_responses: asyncio.Queue[CalendarCreateResponse] = asyncio.Queue()
        self.calendar_update_responses: asyncio.Queue[CalendarUpdateResponse] = asyncio.Queue()
        self.calendar_delete_responses: asyncio.Queue[CalendarDeleteResponse] = asyncio.Queue()
        self.submit_item_responses: asyncio.Queue[SubmitItemResponse] = asyncio.Queue()
        self.active_subscriptions: list[dict[str, Any]] = []
        self._task: asyncio.Task[None] | None = None

    def start(self) -> None:
        """Start the background stdin reader task."""
        self._task = asyncio.create_task(self._reader_loop())

    async def stop(self) -> None:
        """Cancel the background reader task."""
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    def drain_stale_responses(self) -> None:
        """Empty all response queues after an interrupt to avoid stale tool responses."""
        queues = [
            self.send_message_responses,
            self.bcp_validation_results,
            self.send_email_responses,
            self.save_draft_responses,
            self.move_email_responses,
            self.create_folder_responses,
            self.restart_agent_responses,
            self.calendar_query_responses,
            self.calendar_create_responses,
            self.calendar_update_responses,
            self.calendar_delete_responses,
            self.submit_item_responses,
        ]
        for q in queues:
            while not q.empty():
                try:
                    q.get_nowait()
                except asyncio.QueueEmpty:
                    break

    async def _read_line(self) -> str | None:
        """Read one line from stdin without blocking the event loop."""
        loop = asyncio.get_running_loop()
        line = await loop.run_in_executor(None, sys.stdin.readline)
        return line if line else None

    async def _reader_loop(self) -> None:
        """Continuously read stdin and dispatch to the appropriate queue."""
        while True:
            try:
                line = await self._read_line()
            except asyncio.CancelledError:
                break

            if line is None:
                # EOF -- signal the control queue
                await self.control_queue.put(None)
                break

            line = line.strip()
            if not line:
                continue

            try:
                data = json.loads(line)
            except json.JSONDecodeError as exc:
                log.error("Malformed JSON on stdin: %s", exc)
                emit_error(f"Malformed JSON: {exc}")
                continue

            msg_type = data.get("type")

            if msg_type == "send_message_response":
                try:
                    response = SendMessageResponse.from_dict(data)
                    await self.send_message_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse send_message_response: %s", exc)
            elif msg_type == "send_email_response":
                try:
                    response = SendEmailResponse.from_dict(data)
                    await self.send_email_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse send_email_response: %s", exc)
            elif msg_type == "save_draft_response":
                try:
                    response = SaveDraftResponse.from_dict(data)
                    await self.save_draft_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse save_draft_response: %s", exc)
            elif msg_type == "move_email_response":
                try:
                    response = MoveEmailResponse.from_dict(data)
                    await self.move_email_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse move_email_response: %s", exc)
            elif msg_type == "create_folder_response":
                try:
                    response = CreateFolderResponse.from_dict(data)
                    await self.create_folder_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse create_folder_response: %s", exc)
            elif msg_type == "restart_agent_response":
                try:
                    response = RestartAgentResponse.from_dict(data)
                    await self.restart_agent_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse restart_agent_response: %s", exc)
            elif msg_type == "calendar_query_response":
                try:
                    response = CalendarQueryResponse.from_dict(data)
                    await self.calendar_query_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse calendar_query_response: %s", exc)
            elif msg_type == "calendar_create_response":
                try:
                    response = CalendarCreateResponse.from_dict(data)
                    await self.calendar_create_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse calendar_create_response: %s", exc)
            elif msg_type == "calendar_update_response":
                try:
                    response = CalendarUpdateResponse.from_dict(data)
                    await self.calendar_update_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse calendar_update_response: %s", exc)
            elif msg_type == "calendar_delete_response":
                try:
                    response = CalendarDeleteResponse.from_dict(data)
                    await self.calendar_delete_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse calendar_delete_response: %s", exc)
            elif msg_type == "submit_item_response":
                try:
                    response = SubmitItemResponse.from_dict(data)
                    await self.submit_item_responses.put(response)
                except Exception as exc:
                    log.error("Failed to parse submit_item_response: %s", exc)
            elif msg_type == "interrupt":
                # Route directly to interrupt_event (not control_queue) because
                # the main loop is blocked awaiting run_prompt, not reading control.
                log.info("Interrupt received, setting interrupt event")
                self.interrupt_event.set()
            elif msg_type == "bcp_query":
                # Route to control queue so the main loop can present
                # the query to the LLM as a prompt
                await self.control_queue.put(data)
            elif msg_type == "bcp_query_error":
                # Route to control queue so the main loop can inform
                # the LLM that the query could not be routed
                await self.control_queue.put(data)
            elif msg_type == "bcp_response_delivery":
                # Route to control queue so the main loop can present
                # the delivery to the LLM as a prompt
                await self.control_queue.put(data)
            elif msg_type == "bcp_validation_result":
                try:
                    result = BCPValidationResult.from_dict(data)
                    await self.bcp_validation_results.put(result)
                except Exception as exc:
                    log.error("Failed to parse bcp_validation_result: %s", exc)
            elif msg_type == "bcp_subscriptions_active":
                try:
                    msg = BCPSubscriptionsActive.from_dict(data)
                    self.active_subscriptions = msg.subscriptions
                except Exception as exc:
                    log.error("Failed to parse bcp_subscriptions_active: %s", exc)
            else:
                # Only route recognised control types; skip unknown types
                # (e.g. rate_limit_event from the API) to avoid noisy errors.
                if msg_type in _INBOUND_PARSERS:
                    await self.control_queue.put(data)
                else:
                    log.debug("Ignoring unknown inbound message type: %s", msg_type)

    async def read_control(self) -> dict[str, Any] | None:
        """Read the next control message.  Returns None on EOF."""
        return await self.control_queue.get()


# ---------------------------------------------------------------------------
# SendMessage tool handler
# ---------------------------------------------------------------------------

# Timeout for the gateway to acknowledge a send_message_request.
_SEND_MESSAGE_TIMEOUT_S = 30


class SendMessageHandler:
    """Handles the SendMessage custom tool for inter-agent communication.

    When the LLM invokes SendMessage, this handler:
      1. Emits a ``send_message_request`` to stdout (picked up by the gateway)
      2. Awaits a ``send_message_response`` on the dispatcher's response queue
      3. Returns an acknowledgment string to the SDK so the LLM sees the result

    The gateway mediates and sanitizes the message before delivery.
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def handle(self, to: str, message_type: str, payload: dict[str, Any]) -> str:
        """Send a message and wait for the gateway acknowledgment."""
        request_id = uuid.uuid4().hex

        log.info("SendMessage -> %s (type=%s, request_id=%s)", to, message_type, request_id)
        emit_send_message_request(
            request_id=request_id,
            to=to,
            message_type=message_type,
            payload=payload,
        )

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(request_id),
                timeout=_SEND_MESSAGE_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("SendMessage timed out (request_id=%s)", request_id)
            return f"Error: SendMessage timed out after {_SEND_MESSAGE_TIMEOUT_S}s"

        if response.success:
            return f"Message delivered to {to}."
        return f"Error: {response.detail}"

    async def _wait_for_response(self, request_id: str) -> SendMessageResponse:
        """Poll the response queue until we get our matching response.

        Responses for other request IDs (shouldn't happen under normal
        operation, but defensive) are put back on the queue.
        """
        while True:
            response = await self._dispatcher.send_message_responses.get()
            if response.request_id == request_id:
                return response
            # Not ours -- put it back for another consumer
            await self._dispatcher.send_message_responses.put(response)
            await asyncio.sleep(0.01)


# ---------------------------------------------------------------------------
# RestartAgent tool handler
# ---------------------------------------------------------------------------

# Timeout for the gateway to acknowledge a restart_agent_request.
_RESTART_AGENT_TIMEOUT_S = 60


class RestartAgentHandler:
    """Handles the RestartAgent custom tool for restarting other agents.

    When the LLM invokes RestartAgent, this handler:
      1. Emits a ``restart_agent_request`` to stdout (picked up by the gateway)
      2. Awaits a ``restart_agent_response`` on the dispatcher's response queue
      3. Returns an acknowledgment string to the SDK so the LLM sees the result

    The gateway performs the actual restart operation.
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def handle(self, agent_name: str, force: bool = False) -> str:
        """Request a restart and wait for the gateway acknowledgment."""
        request_id = uuid.uuid4().hex

        log.info("RestartAgent -> %s (force=%s, request_id=%s)", agent_name, force, request_id)
        emit_restart_agent_request(
            request_id=request_id,
            agent_name=agent_name,
            force=force,
        )

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(request_id),
                timeout=_RESTART_AGENT_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("RestartAgent timed out (request_id=%s)", request_id)
            return f"Error: RestartAgent timed out after {_RESTART_AGENT_TIMEOUT_S}s"

        if response.success:
            return f"Agent '{agent_name}' restart initiated. {response.detail}"
        return f"Error: {response.detail}"

    async def _wait_for_response(self, request_id: str) -> RestartAgentResponse:
        """Poll the response queue until we get our matching response."""
        while True:
            response = await self._dispatcher.restart_agent_responses.get()
            if response.request_id == request_id:
                return response
            # Not ours -- put it back for another consumer
            await self._dispatcher.restart_agent_responses.put(response)
            await asyncio.sleep(0.01)


# ---------------------------------------------------------------------------
# SubmitItem tool handler
# ---------------------------------------------------------------------------

_SUBMIT_ITEM_TIMEOUT_S = 30


class SubmitItemHandler:
    """Handles the SubmitItem virtual tool for posting items to connectors.

    When the LLM invokes SubmitItem, this handler:
      1. Emits a ``submit_item_request`` to stdout (picked up by the gateway)
      2. Awaits a ``submit_item_response`` on the dispatcher's response queue
      3. Returns an acknowledgment string to the SDK so the LLM sees the result
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def handle(self, item_type: str, title: str, url: str, metadata: dict[str, str]) -> str:
        """Submit an item and wait for the gateway acknowledgment."""
        request_id = uuid.uuid4().hex

        log.info("SubmitItem type=%r title=%r url=%s (request_id=%s)", item_type, title, url, request_id)
        emit_submit_item_request(
            request_id=request_id,
            item_type=item_type,
            title=title,
            url=url,
            metadata=metadata,
        )

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(request_id),
                timeout=_SUBMIT_ITEM_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("SubmitItem timed out (request_id=%s)", request_id)
            return f"Error: SubmitItem timed out after {_SUBMIT_ITEM_TIMEOUT_S}s"

        if response.success:
            return f"Item submitted: {title}"
        return f"Error: {response.detail}"

    async def _wait_for_response(self, request_id: str) -> SubmitItemResponse:
        """Poll the response queue until we get our matching response."""
        while True:
            response = await self._dispatcher.submit_item_responses.get()
            if response.request_id == request_id:
                return response
            await self._dispatcher.submit_item_responses.put(response)
            await asyncio.sleep(0.01)


# ---------------------------------------------------------------------------
# BCP tool handler
# ---------------------------------------------------------------------------

# Timeout for the gateway to deliver a BCP response.
# Cat-3 responses require human approval which can take minutes,
# so this must be at least as long as the gateway's approval timeout (5m).
_BCP_RESPONSE_TIMEOUT_S = 330


class BCPHandler:
    """Handles BCP query/response tools for bandwidth-constrained protocol.

    Controllers use ``send_query`` to request information from Reader agents.
    Readers use ``respond_to_query`` to answer incoming queries.  The gateway
    mediates, validates bandwidth constraints, and delivers results.
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def send_query(
        self, to: str, category: int, spec: dict[str, Any]
    ) -> str:
        """Send a BCP query and return immediately.

        The validated response will be delivered asynchronously as a
        ``bcp_response_delivery`` message routed to the control queue,
        which the main loop presents to the LLM as a follow-up prompt.
        """
        request_id = uuid.uuid4().hex

        log.info(
            "BCPQuery -> %s (category=%d, request_id=%s)", to, category, request_id
        )
        emit_bcp_query_request(
            request_id=request_id,
            to=to,
            category=category,
            spec=spec,
        )

        return (
            f"BCP query sent to {to} (category {category}, request_id: {request_id}). "
            f"The validated response will be delivered as a prompt when ready."
        )

    async def respond_to_query(
        self, query_id: str, response: dict[str, Any]
    ) -> str:
        """Respond to an incoming BCP query and wait for validation result."""
        log.info("BCPResponse for query_id=%s", query_id)
        emit_bcp_response(query_id=query_id, response=response)

        try:
            result = await asyncio.wait_for(
                self._wait_for_validation(query_id),
                timeout=_BCP_RESPONSE_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            return f"BCP response sent for query {query_id} (validation pending — timed out waiting for result)."

        if result.success:
            return f"BCP response for query {query_id} validated and delivered."
        else:
            return f"Error: BCP response for query {query_id} was rejected: {result.detail}"

    async def _wait_for_validation(
        self, query_id: str
    ) -> BCPValidationResult:
        """Poll the validation result queue until we get our matching result."""
        while True:
            result = await self._dispatcher.bcp_validation_results.get()
            if result.query_id == query_id:
                return result
            # Not ours -- put it back
            await self._dispatcher.bcp_validation_results.put(result)
            await asyncio.sleep(0.01)

    async def publish(self, subscription_id: str, controller: str, response: dict) -> str:
        """Publish data against a BCP subscription. Returns success/failure message."""
        log.info("BCPPublish for subscription_id=%s -> %s", subscription_id, controller)
        emit_bcp_publish(subscription_id, controller, response)

        # Wait for validation result matching this subscription_id
        result = await self._wait_for_subscription_validation(subscription_id)
        if result is None:
            return "Publish timed out waiting for gateway validation."
        if result.success:
            return f"Published successfully to {controller} via subscription '{subscription_id}'. {result.detail}"
        else:
            return f"Publish failed: {result.detail}"

    async def _wait_for_subscription_validation(self, subscription_id: str) -> BCPValidationResult | None:
        """Poll the validation results queue for a matching subscription_id."""
        deadline = asyncio.get_event_loop().time() + _BCP_RESPONSE_TIMEOUT_S
        unmatched: list[BCPValidationResult] = []
        try:
            while True:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    return None
                try:
                    result = await asyncio.wait_for(
                        self._dispatcher.bcp_validation_results.get(), timeout=remaining
                    )
                    if result.subscription_id == subscription_id:
                        return result
                    unmatched.append(result)
                except asyncio.TimeoutError:
                    return None
        finally:
            for item in unmatched:
                await self._dispatcher.bcp_validation_results.put(item)


# ---------------------------------------------------------------------------
# Email tool handler
# ---------------------------------------------------------------------------

# Timeout for the gateway to process email operations.
_EMAIL_OP_TIMEOUT_S = 60


class EmailHandler:
    """Handles gateway-mediated email tools (SendEmail, MoveEmail, CreateFolder).

    Each method emits a request to the gateway and awaits the response,
    following the same pattern as SendMessageHandler.
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def send_email(self, draft_path: str) -> str:
        """Send an email from a draft file via the gateway."""
        request_id = uuid.uuid4().hex
        log.info("SendEmail draft=%s (request_id=%s)", draft_path, request_id)
        emit_send_email_request(request_id=request_id, draft_path=draft_path)

        try:
            response = await asyncio.wait_for(
                self._wait_for_send_email(request_id),
                timeout=_EMAIL_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("SendEmail timed out (request_id=%s)", request_id)
            return f"Error: SendEmail timed out after {_EMAIL_OP_TIMEOUT_S}s"

        if response.success:
            return f"Email sent successfully. Message-ID: {response.message_id}"
        return f"Error: {response.detail}"

    async def save_draft(self, draft_path: str) -> str:
        """Save a draft to the IMAP Drafts folder via the gateway."""
        request_id = uuid.uuid4().hex
        log.info("SaveDraft draft=%s (request_id=%s)", draft_path, request_id)
        emit_save_draft_request(request_id=request_id, draft_path=draft_path)

        try:
            response = await asyncio.wait_for(
                self._wait_for_save_draft(request_id),
                timeout=_EMAIL_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("SaveDraft timed out (request_id=%s)", request_id)
            return f"Error: SaveDraft timed out after {_EMAIL_OP_TIMEOUT_S}s"

        if response.success:
            return "Draft saved to IMAP Drafts folder."
        return f"Error: {response.detail}"

    async def move_email(
        self, uid: str, source_folder: str, dest_folder: str
    ) -> str:
        """Move an email between IMAP folders via the gateway."""
        request_id = uuid.uuid4().hex
        log.info(
            "MoveEmail uid=%s %s->%s (request_id=%s)",
            uid, source_folder, dest_folder, request_id,
        )
        emit_move_email_request(
            request_id=request_id,
            uid=uid,
            source_folder=source_folder,
            dest_folder=dest_folder,
        )

        try:
            response = await asyncio.wait_for(
                self._wait_for_move_email(request_id),
                timeout=_EMAIL_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("MoveEmail timed out (request_id=%s)", request_id)
            return f"Error: MoveEmail timed out after {_EMAIL_OP_TIMEOUT_S}s"

        if response.success:
            return f"Email {uid} moved from {source_folder} to {dest_folder}."
        return f"Error: {response.detail}"

    async def create_folder(self, folder_name: str) -> str:
        """Create an IMAP folder via the gateway."""
        request_id = uuid.uuid4().hex
        log.info("CreateFolder name=%s (request_id=%s)", folder_name, request_id)
        emit_create_folder_request(
            request_id=request_id, folder_name=folder_name
        )

        try:
            response = await asyncio.wait_for(
                self._wait_for_create_folder(request_id),
                timeout=_EMAIL_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("CreateFolder timed out (request_id=%s)", request_id)
            return f"Error: CreateFolder timed out after {_EMAIL_OP_TIMEOUT_S}s"

        if response.success:
            return f"Folder '{folder_name}' created."
        return f"Error: {response.detail}"

    async def _wait_for_send_email(
        self, request_id: str
    ) -> SendEmailResponse:
        while True:
            response = await self._dispatcher.send_email_responses.get()
            if response.request_id == request_id:
                return response
            await self._dispatcher.send_email_responses.put(response)
            await asyncio.sleep(0.01)

    async def _wait_for_save_draft(
        self, request_id: str
    ) -> SaveDraftResponse:
        while True:
            response = await self._dispatcher.save_draft_responses.get()
            if response.request_id == request_id:
                return response
            await self._dispatcher.save_draft_responses.put(response)
            await asyncio.sleep(0.01)

    async def _wait_for_move_email(
        self, request_id: str
    ) -> MoveEmailResponse:
        while True:
            response = await self._dispatcher.move_email_responses.get()
            if response.request_id == request_id:
                return response
            await self._dispatcher.move_email_responses.put(response)
            await asyncio.sleep(0.01)

    async def _wait_for_create_folder(
        self, request_id: str
    ) -> CreateFolderResponse:
        while True:
            response = await self._dispatcher.create_folder_responses.get()
            if response.request_id == request_id:
                return response
            await self._dispatcher.create_folder_responses.put(response)
            await asyncio.sleep(0.01)


# ---------------------------------------------------------------------------
# Calendar tool handler
# ---------------------------------------------------------------------------

_CALENDAR_OP_TIMEOUT_S = 30

class CalendarHandler:
    """Handles gateway-mediated calendar tools (CalendarQuery, CalendarCreate, etc.).

    Each method emits a request to the gateway and awaits the response,
    following the same pattern as EmailHandler.
    """

    def __init__(self, dispatcher: InboundDispatcher) -> None:
        self._dispatcher = dispatcher

    async def calendar_query(self, calendar: str, from_dt: str = "", to_dt: str = "") -> str:
        """Query calendar events via the gateway."""
        request_id = uuid.uuid4().hex
        params: dict[str, str] = {"calendar": calendar}
        if from_dt:
            params["from"] = from_dt
        if to_dt:
            params["to"] = to_dt

        log.info("CalendarQuery calendar=%s (request_id=%s)", calendar, request_id)
        emit_calendar_query_request(request_id=request_id, params=params)

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(self._dispatcher.calendar_query_responses, request_id),
                timeout=_CALENDAR_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("CalendarQuery timed out (request_id=%s)", request_id)
            return f"Error: CalendarQuery timed out after {_CALENDAR_OP_TIMEOUT_S}s"

        if response.success:
            return json.dumps(response.events, indent=2)
        return f"Error: {response.detail}"

    async def calendar_create(self, draft_path: str) -> str:
        """Create a calendar event from a draft file."""
        request_id = uuid.uuid4().hex
        log.info("CalendarCreate draft=%s (request_id=%s)", draft_path, request_id)
        emit_calendar_create_request(request_id=request_id, draft_path=draft_path)

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(self._dispatcher.calendar_create_responses, request_id),
                timeout=_CALENDAR_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("CalendarCreate timed out (request_id=%s)", request_id)
            return f"Error: CalendarCreate timed out after {_CALENDAR_OP_TIMEOUT_S}s"

        if response.success:
            return f"Event created: {json.dumps(response.event, indent=2)}"
        return f"Error: {response.detail}"

    async def calendar_update(self, draft_path: str) -> str:
        """Update a calendar event from a draft file."""
        request_id = uuid.uuid4().hex
        log.info("CalendarUpdate draft=%s (request_id=%s)", draft_path, request_id)
        emit_calendar_update_request(request_id=request_id, draft_path=draft_path)

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(self._dispatcher.calendar_update_responses, request_id),
                timeout=_CALENDAR_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("CalendarUpdate timed out (request_id=%s)", request_id)
            return f"Error: CalendarUpdate timed out after {_CALENDAR_OP_TIMEOUT_S}s"

        if response.success:
            return f"Event updated: {json.dumps(response.event, indent=2)}"
        return f"Error: {response.detail}"

    async def calendar_delete(self, uid: str, calendar: str) -> str:
        """Delete a calendar event."""
        request_id = uuid.uuid4().hex
        log.info("CalendarDelete uid=%s calendar=%s (request_id=%s)", uid, calendar, request_id)
        emit_calendar_delete_request(request_id=request_id, uid=uid, calendar=calendar)

        try:
            response = await asyncio.wait_for(
                self._wait_for_response(self._dispatcher.calendar_delete_responses, request_id),
                timeout=_CALENDAR_OP_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("CalendarDelete timed out (request_id=%s)", request_id)
            return f"Error: CalendarDelete timed out after {_CALENDAR_OP_TIMEOUT_S}s"

        if response.success:
            return f"Event {uid} deleted from {calendar}"
        return f"Error: {response.detail}"

    async def _wait_for_response(self, queue: asyncio.Queue, request_id: str) -> Any:
        while True:
            response = await queue.get()
            if response.request_id == request_id:
                return response
            await queue.put(response)
            await asyncio.sleep(0.01)


# ---------------------------------------------------------------------------
# SDK MCP tool for inter-agent messaging
# ---------------------------------------------------------------------------

# Logical tool names as seen by the gateway and agent definitions.
_SEND_MESSAGE_TOOL = "SendMessage"
_BCP_QUERY_TOOL = "BCPQuery"
_BCP_RESPOND_TOOL = "BCPRespond"
_BCP_PUBLISH_TOOL = "BCPPublish"

# The SDK MCP server that hosts the tools.  The CLI sees them as
# mcp__interagent__<ToolName>, but we normalize back to the logical name
# in observational events so the gateway's ToolRegistry and
# InformationClassifier work unchanged.
_INTERAGENT_SERVER = "interagent"
_SEND_MESSAGE_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_SEND_MESSAGE_TOOL}"
_BCP_QUERY_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_BCP_QUERY_TOOL}"
_BCP_RESPOND_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_BCP_RESPOND_TOOL}"
_BCP_PUBLISH_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_BCP_PUBLISH_TOOL}"
_RESTART_AGENT_TOOL = "RestartAgent"
_RESTART_AGENT_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_RESTART_AGENT_TOOL}"

# Email tool names
_SEND_EMAIL_TOOL = "SendEmail"
_SAVE_DRAFT_TOOL = "SaveDraft"
_MOVE_EMAIL_TOOL = "MoveEmail"
_CREATE_FOLDER_TOOL = "CreateFolder"

_EMAIL_SERVER = "email"
_SEND_EMAIL_MCP_NAME = f"mcp__{_EMAIL_SERVER}__{_SEND_EMAIL_TOOL}"
_SAVE_DRAFT_MCP_NAME = f"mcp__{_EMAIL_SERVER}__{_SAVE_DRAFT_TOOL}"
_MOVE_EMAIL_MCP_NAME = f"mcp__{_EMAIL_SERVER}__{_MOVE_EMAIL_TOOL}"
_CREATE_FOLDER_MCP_NAME = f"mcp__{_EMAIL_SERVER}__{_CREATE_FOLDER_TOOL}"

# Calendar tool names
_CALENDAR_QUERY_TOOL = "CalendarQuery"
_CALENDAR_CREATE_TOOL = "CalendarCreate"
_CALENDAR_UPDATE_TOOL = "CalendarUpdate"
_CALENDAR_DELETE_TOOL = "CalendarDelete"

_CALENDAR_SERVER = "calendar"
_CALENDAR_QUERY_MCP_NAME = f"mcp__{_CALENDAR_SERVER}__{_CALENDAR_QUERY_TOOL}"
_CALENDAR_CREATE_MCP_NAME = f"mcp__{_CALENDAR_SERVER}__{_CALENDAR_CREATE_TOOL}"
_CALENDAR_UPDATE_MCP_NAME = f"mcp__{_CALENDAR_SERVER}__{_CALENDAR_UPDATE_TOOL}"
_CALENDAR_DELETE_MCP_NAME = f"mcp__{_CALENDAR_SERVER}__{_CALENDAR_DELETE_TOOL}"

# SubmitItem tool name
_SUBMIT_ITEM_TOOL = "SubmitItem"
_SUBMIT_ITEM_MCP_NAME = f"mcp__{_INTERAGENT_SERVER}__{_SUBMIT_ITEM_TOOL}"

# Reverse map from MCP-prefixed name → logical name for the gateway.
_MCP_TO_LOGICAL: dict[str, str] = {
    _SEND_MESSAGE_MCP_NAME: _SEND_MESSAGE_TOOL,
    _BCP_QUERY_MCP_NAME: _BCP_QUERY_TOOL,
    _BCP_RESPOND_MCP_NAME: _BCP_RESPOND_TOOL,
    _BCP_PUBLISH_MCP_NAME: _BCP_PUBLISH_TOOL,
    _RESTART_AGENT_MCP_NAME: _RESTART_AGENT_TOOL,
    _SEND_EMAIL_MCP_NAME: _SEND_EMAIL_TOOL,
    _SAVE_DRAFT_MCP_NAME: _SAVE_DRAFT_TOOL,
    _MOVE_EMAIL_MCP_NAME: _MOVE_EMAIL_TOOL,
    _CREATE_FOLDER_MCP_NAME: _CREATE_FOLDER_TOOL,
    _CALENDAR_QUERY_MCP_NAME: _CALENDAR_QUERY_TOOL,
    _CALENDAR_CREATE_MCP_NAME: _CALENDAR_CREATE_TOOL,
    _CALENDAR_UPDATE_MCP_NAME: _CALENDAR_UPDATE_TOOL,
    _CALENDAR_DELETE_MCP_NAME: _CALENDAR_DELETE_TOOL,
    _SUBMIT_ITEM_MCP_NAME: _SUBMIT_ITEM_TOOL,
}


def _normalize_tool_name(name: str) -> str:
    """Map MCP-prefixed tool names back to logical names for the gateway."""
    return _MCP_TO_LOGICAL.get(name, name)


def build_send_message_tool(
    send_handler: SendMessageHandler,
) -> Any:
    """Create SendMessage as an in-process SDK MCP tool.

    The ``@tool`` decorator returns an ``SdkMcpTool`` instance that
    ``create_sdk_mcp_server`` can host.  Because the server runs in-process,
    the handler has direct access to the ``SendMessageHandler`` and the
    gateway protocol channel — no external MCP process or IPC needed.
    """

    @tool(
        _SEND_MESSAGE_TOOL,
        "Send a message to another agent. The gateway mediates and "
        "sanitizes all inter-agent communication before delivery.",
        {
            "type": "object",
            "properties": {
                "to": {
                    "type": "string",
                    "description": "Name of the recipient agent",
                },
                "message_type": {
                    "type": "string",
                    "description": (
                        "Message type (e.g. 'research_request', 'text')"
                    ),
                    "default": "text",
                },
                "payload": {
                    "type": "object",
                    "description": "Message payload (structured data to send)",
                    "additionalProperties": True,
                },
            },
            "required": ["to", "payload"],
        },
    )
    async def send_message(args: dict[str, Any]) -> dict[str, Any]:
        to = args.get("to", "")
        message_type = args.get("message_type", "text")
        payload = args.get("payload", {})

        if not to:
            return {
                "content": [
                    {
                        "type": "text",
                        "text": "Error: 'to' field is required.",
                    }
                ],
                "isError": True,
            }

        result = await send_handler.handle(
            to=to,
            message_type=message_type,
            payload=payload,
        )
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return send_message


def build_restart_agent_tool(restart_handler: RestartAgentHandler) -> Any:
    """Create RestartAgent as an in-process SDK MCP tool.

    Used by agents that have permission to restart other agents (e.g. when
    an agent is stuck or unresponsive).
    """

    @tool(
        _RESTART_AGENT_TOOL,
        "Restart another agent's session. Use force=true to skip memory save "
        "when an agent is stuck or unresponsive.",
        {
            "type": "object",
            "properties": {
                "agent_name": {
                    "type": "string",
                    "description": "Name of the agent to restart",
                },
                "force": {
                    "type": "boolean",
                    "description": "Skip memory save (default: false)",
                    "default": False,
                },
            },
            "required": ["agent_name"],
        },
    )
    async def restart_agent(args: dict[str, Any]) -> dict[str, Any]:
        agent_name = args.get("agent_name", "")
        force = args.get("force", False)

        if not agent_name:
            return {
                "content": [
                    {
                        "type": "text",
                        "text": "Error: 'agent_name' is required.",
                    }
                ],
                "isError": True,
            }

        result = await restart_handler.handle(
            agent_name=agent_name,
            force=force,
        )
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return restart_agent


def build_bcp_query_tool(bcp_handler: BCPHandler) -> Any:
    """Create BCPQuery as an in-process SDK MCP tool.

    Used by Controller agents to send bandwidth-constrained queries to
    Reader agents through the gateway.
    """

    @tool(
        _BCP_QUERY_TOOL,
        "Send a BCP query to a Reader agent. The gateway validates "
        "bandwidth constraints and routes the query.",
        {
            "type": "object",
            "properties": {
                "to": {
                    "type": "string",
                    "description": "Name of the Reader agent to query",
                },
                "category": {
                    "type": "integer",
                    "description": "BCP category (1-5) determining bandwidth allocation",
                },
                "context": {
                    "type": "string",
                    "description": "Optional context for the Reader — what content to examine and why these questions are being asked",
                },
                "spec": {
                    "type": "object",
                    "description": "Query specification (fields, questions, or directive)",
                    "additionalProperties": True,
                },
            },
            "required": ["to", "category", "spec"],
        },
    )
    async def bcp_query(args: dict[str, Any]) -> dict[str, Any]:
        to = args.get("to", "")
        category = args.get("category", 0)
        spec = args.get("spec", {})

        # LLMs sometimes pass numbers as strings — coerce
        if isinstance(category, str):
            try:
                category = int(category)
            except ValueError:
                pass

        # LLMs sometimes pass spec as a JSON string — parse it
        if isinstance(spec, str):
            try:
                spec = json.loads(spec)
            except (json.JSONDecodeError, TypeError):
                return {
                    "content": [{"type": "text", "text": "Error: 'spec' must be a JSON object."}],
                    "isError": True,
                }

        if not to:
            return {
                "content": [{"type": "text", "text": "Error: 'to' field is required."}],
                "isError": True,
            }
        if not isinstance(category, int) or category < 1 or category > 5:
            return {
                "content": [{"type": "text", "text": "Error: 'category' must be an integer 1-5."}],
                "isError": True,
            }

        # Pass context into the spec so the gateway can forward it to the Reader
        context = args.get("context")
        if context:
            spec["context"] = context

        result = await bcp_handler.send_query(to=to, category=category, spec=spec)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return bcp_query


def build_bcp_respond_tool(bcp_handler: BCPHandler) -> Any:
    """Create BCPRespond as an in-process SDK MCP tool.

    Used by Reader agents to respond to incoming BCP queries.  The
    gateway validates the response against bandwidth constraints before
    delivering it to the requesting Controller.
    """

    @tool(
        _BCP_RESPOND_TOOL,
        "Respond to an incoming BCP query. The gateway validates the "
        "response against bandwidth constraints before delivery.",
        {
            "type": "object",
            "properties": {
                "query_id": {
                    "type": "string",
                    "description": "ID of the query to respond to",
                },
                "response": {
                    "type": "object",
                    "description": "Response data to send back",
                    "additionalProperties": True,
                },
            },
            "required": ["query_id", "response"],
        },
    )
    async def bcp_respond(args: dict[str, Any]) -> dict[str, Any]:
        query_id = args.get("query_id", "")
        response = args.get("response", {})

        # LLMs sometimes pass response as a JSON string — parse it
        if isinstance(response, str):
            try:
                response = json.loads(response)
            except (json.JSONDecodeError, TypeError):
                return {
                    "content": [{"type": "text", "text": "Error: 'response' must be a JSON object."}],
                    "isError": True,
                }

        if not query_id:
            return {
                "content": [{"type": "text", "text": "Error: 'query_id' field is required."}],
                "isError": True,
            }

        result = await bcp_handler.respond_to_query(
            query_id=query_id, response=response
        )
        return {
            "content": [{"type": "text", "text": result}],
            "isError": False,
        }

    return bcp_respond


def build_bcp_publish_tool(bcp_handler: BCPHandler) -> Any:
    """Build the BCPPublish MCP tool for Reader agents.

    Used by Reader agents to publish data against active BCP subscriptions.
    The gateway validates the response against the subscription spec before
    delivering it to the subscribing Controller.
    """

    @tool(
        _BCP_PUBLISH_TOOL,
        "Publish data against a BCP subscription. The gateway validates "
        "the response against the subscription spec before delivery.",
        {
            "type": "object",
            "properties": {
                "subscription_id": {
                    "type": "string",
                    "description": "ID of the subscription to publish against",
                },
                "controller": {
                    "type": "string",
                    "description": "Name of the subscribing Controller agent",
                },
                "response": {
                    "type": "object",
                    "description": "Response data matching the subscription's spec (JSON object)",
                    "additionalProperties": True,
                },
            },
            "required": ["subscription_id", "controller", "response"],
        },
    )
    async def bcp_publish(args: dict[str, Any]) -> dict[str, Any]:
        subscription_id = args.get("subscription_id", "")
        controller = args.get("controller", "")
        response = args.get("response", {})

        # LLMs sometimes pass response as a JSON string — parse it
        if isinstance(response, str):
            try:
                response = json.loads(response)
            except (json.JSONDecodeError, TypeError):
                return {
                    "content": [{"type": "text", "text": "Error: 'response' must be a JSON object."}],
                    "isError": True,
                }

        if not subscription_id:
            return {
                "content": [{"type": "text", "text": "Error: 'subscription_id' field is required."}],
                "isError": True,
            }

        if not controller:
            return {
                "content": [{"type": "text", "text": "Error: 'controller' field is required."}],
                "isError": True,
            }

        result = await bcp_handler.publish(
            subscription_id=subscription_id, controller=controller, response=response
        )
        return {
            "content": [{"type": "text", "text": result}],
            "isError": False,
        }

    return bcp_publish


# ---------------------------------------------------------------------------
# SDK MCP tools for email operations
# ---------------------------------------------------------------------------


def build_send_email_tool(email_handler: EmailHandler) -> Any:
    """Create SendEmail as an in-process SDK MCP tool."""

    @tool(
        _SEND_EMAIL_TOOL,
        "Send an email via SMTP from a draft JSON file. The gateway reads "
        "the draft, validates it, and sends via SMTP. Credentials never "
        "enter the agent.",
        {
            "type": "object",
            "properties": {
                "draft_path": {
                    "type": "string",
                    "description": "Path to draft JSON file in the agent workspace",
                },
            },
            "required": ["draft_path"],
        },
    )
    async def send_email(args: dict[str, Any]) -> dict[str, Any]:
        draft_path = args.get("draft_path", "")
        if not draft_path:
            return {
                "content": [{"type": "text", "text": "Error: 'draft_path' is required."}],
                "isError": True,
            }
        result = await email_handler.send_email(draft_path)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return send_email


def build_save_draft_tool(email_handler: EmailHandler) -> Any:
    """Create SaveDraft as an in-process SDK MCP tool."""

    @tool(
        _SAVE_DRAFT_TOOL,
        "Save a draft email to the IMAP Drafts folder so it appears in the "
        "user's email client for review. The draft JSON file must already "
        "exist in the agent workspace.",
        {
            "type": "object",
            "properties": {
                "draft_path": {
                    "type": "string",
                    "description": "Path to draft JSON file in the agent workspace",
                },
            },
            "required": ["draft_path"],
        },
    )
    async def save_draft(args: dict[str, Any]) -> dict[str, Any]:
        draft_path = args.get("draft_path", "")
        if not draft_path:
            return {
                "content": [{"type": "text", "text": "Error: 'draft_path' is required."}],
                "isError": True,
            }
        result = await email_handler.save_draft(draft_path)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return save_draft


def build_move_email_tool(email_handler: EmailHandler) -> Any:
    """Create MoveEmail as an in-process SDK MCP tool."""

    @tool(
        _MOVE_EMAIL_TOOL,
        "Move an email between IMAP folders. Both the IMAP server and the "
        "local filesystem are kept in sync.",
        {
            "type": "object",
            "properties": {
                "uid": {
                    "type": "string",
                    "description": "Email UID to move",
                },
                "source_folder": {
                    "type": "string",
                    "description": "Current folder (e.g. inbox)",
                },
                "dest_folder": {
                    "type": "string",
                    "description": "Destination folder (e.g. receipts)",
                },
            },
            "required": ["uid", "source_folder", "dest_folder"],
        },
    )
    async def move_email(args: dict[str, Any]) -> dict[str, Any]:
        uid = args.get("uid", "")
        source = args.get("source_folder", "")
        dest = args.get("dest_folder", "")

        if not uid or not source or not dest:
            return {
                "content": [{"type": "text", "text": "Error: 'uid', 'source_folder', and 'dest_folder' are required."}],
                "isError": True,
            }

        result = await email_handler.move_email(uid, source, dest)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return move_email


def build_create_folder_tool(email_handler: EmailHandler) -> Any:
    """Create CreateFolder as an in-process SDK MCP tool."""

    @tool(
        _CREATE_FOLDER_TOOL,
        "Create a new email folder. Both the IMAP server and the local "
        "filesystem are updated.",
        {
            "type": "object",
            "properties": {
                "folder_name": {
                    "type": "string",
                    "description": "Name of folder to create (alphanumeric, hyphens, underscores)",
                },
            },
            "required": ["folder_name"],
        },
    )
    async def create_folder(args: dict[str, Any]) -> dict[str, Any]:
        folder_name = args.get("folder_name", "")
        if not folder_name:
            return {
                "content": [{"type": "text", "text": "Error: 'folder_name' is required."}],
                "isError": True,
            }
        result = await email_handler.create_folder(folder_name)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return create_folder


# ---------------------------------------------------------------------------
# SDK MCP tools for calendar operations
# ---------------------------------------------------------------------------


def build_calendar_query_tool(calendar_handler: CalendarHandler) -> Any:
    """Create CalendarQuery as an in-process SDK MCP tool."""

    @tool(
        _CALENDAR_QUERY_TOOL,
        "Query calendar events via CalDAV. Returns events within the "
        "specified date range as JSON. Events are also written to the "
        "agent workspace.",
        {
            "type": "object",
            "properties": {
                "calendar": {
                    "type": "string",
                    "description": "Calendar slug/ID to query",
                },
                "from": {
                    "type": "string",
                    "description": "Start of date range (ISO 8601, e.g. 2026-02-20T00:00:00Z)",
                },
                "to": {
                    "type": "string",
                    "description": "End of date range (ISO 8601, e.g. 2026-03-20T00:00:00Z)",
                },
            },
            "required": ["calendar"],
        },
    )
    async def calendar_query(args: dict[str, Any]) -> dict[str, Any]:
        calendar = args.get("calendar", "")
        if not calendar:
            return {
                "content": [{"type": "text", "text": "Error: 'calendar' is required."}],
                "isError": True,
            }
        result = await calendar_handler.calendar_query(
            calendar, args.get("from", ""), args.get("to", "")
        )
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return calendar_query


def build_calendar_create_tool(calendar_handler: CalendarHandler) -> Any:
    """Create CalendarCreate as an in-process SDK MCP tool."""

    @tool(
        _CALENDAR_CREATE_TOOL,
        "Create a new calendar event via CalDAV from a draft JSON file. "
        "The gateway reads the draft, generates iCal, and sends a CalDAV PUT. "
        "Credentials never enter the agent.",
        {
            "type": "object",
            "properties": {
                "draft_path": {
                    "type": "string",
                    "description": "Path to draft JSON file in the agent workspace",
                },
            },
            "required": ["draft_path"],
        },
    )
    async def calendar_create(args: dict[str, Any]) -> dict[str, Any]:
        draft_path = args.get("draft_path", "")
        if not draft_path:
            return {
                "content": [{"type": "text", "text": "Error: 'draft_path' is required."}],
                "isError": True,
            }
        result = await calendar_handler.calendar_create(draft_path)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return calendar_create


def build_calendar_update_tool(calendar_handler: CalendarHandler) -> Any:
    """Create CalendarUpdate as an in-process SDK MCP tool."""

    @tool(
        _CALENDAR_UPDATE_TOOL,
        "Update an existing calendar event via CalDAV from an update-draft "
        "JSON file. The draft must include uid, etag, and href for conflict "
        "detection. Uses conditional PUT with If-Match.",
        {
            "type": "object",
            "properties": {
                "draft_path": {
                    "type": "string",
                    "description": "Path to update-draft JSON file in the agent workspace",
                },
            },
            "required": ["draft_path"],
        },
    )
    async def calendar_update(args: dict[str, Any]) -> dict[str, Any]:
        draft_path = args.get("draft_path", "")
        if not draft_path:
            return {
                "content": [{"type": "text", "text": "Error: 'draft_path' is required."}],
                "isError": True,
            }
        result = await calendar_handler.calendar_update(draft_path)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return calendar_update


def build_calendar_delete_tool(calendar_handler: CalendarHandler) -> Any:
    """Create CalendarDelete as an in-process SDK MCP tool."""

    @tool(
        _CALENDAR_DELETE_TOOL,
        "Delete a calendar event via CalDAV. Looks up the event's href "
        "and etag from the cached event file, then sends a CalDAV DELETE.",
        {
            "type": "object",
            "properties": {
                "uid": {
                    "type": "string",
                    "description": "Event UID to delete",
                },
                "calendar": {
                    "type": "string",
                    "description": "Calendar slug/ID containing the event",
                },
            },
            "required": ["uid", "calendar"],
        },
    )
    async def calendar_delete(args: dict[str, Any]) -> dict[str, Any]:
        uid = args.get("uid", "")
        calendar = args.get("calendar", "")
        if not uid or not calendar:
            return {
                "content": [{"type": "text", "text": "Error: 'uid' and 'calendar' are required."}],
                "isError": True,
            }
        result = await calendar_handler.calendar_delete(uid, calendar)
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return calendar_delete


# ---------------------------------------------------------------------------
# SDK MCP tool for item submission
# ---------------------------------------------------------------------------


def build_submit_item_tool(item_handler: SubmitItemHandler) -> Any:
    """Create SubmitItem as an in-process SDK MCP tool."""

    @tool(
        _SUBMIT_ITEM_TOOL,
        "Submit an item for posting to the chat. Each item is posted as a "
        "separate formatted message. Users can react with thumbs up/down to "
        "provide feedback. Set 'type' to indicate the kind of item:\n"
        "- 'article': a news article (include 'source' and 'summary' in metadata)\n"
        "- 'listing': a for-sale listing (include 'price' and 'location' in metadata)",
        {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "description": "Item type: 'article' or 'listing'",
                },
                "title": {
                    "type": "string",
                    "description": "Item title or headline",
                },
                "url": {
                    "type": "string",
                    "description": "URL to the full item",
                },
                "metadata": {
                    "type": "object",
                    "description": (
                        "Type-specific fields. "
                        "For articles: {source, summary}. "
                        "For listings: {price, location}."
                    ),
                    "additionalProperties": {"type": "string"},
                },
            },
            "required": ["type", "title", "url"],
        },
    )
    async def submit_item(args: dict[str, Any]) -> dict[str, Any]:
        item_type = args.get("type", "")
        title = args.get("title", "")
        url = args.get("url", "")
        metadata = args.get("metadata") or {}

        if not item_type or not title or not url:
            return {
                "content": [
                    {
                        "type": "text",
                        "text": "Error: 'type', 'title', and 'url' are all required.",
                    }
                ],
                "isError": True,
            }

        # Ensure metadata values are strings
        metadata = {k: str(v) for k, v in metadata.items()}

        result = await item_handler.handle(
            item_type=item_type, title=title, url=url, metadata=metadata,
        )
        is_error = result.startswith("Error:")
        return {
            "content": [{"type": "text", "text": result}],
            "isError": is_error,
        }

    return submit_item


# ---------------------------------------------------------------------------
# BCP query → prompt formatting
# ---------------------------------------------------------------------------


def _format_bcp_query_prompt(query: BCPQueryMessage) -> str:
    """Format an inbound BCP query as a prompt for the LLM.

    The prompt tells the LLM exactly what information to research and how
    to respond using the BCPRespond tool with the correct query_id and
    response structure.
    """
    parts = [
        f"You received a BCP query (id: {query.query_id}) "
        f"from agent '{query.from_agent}' (category {query.category}).",
        "",
    ]

    if query.context:
        parts.append(f"**Context:** {query.context}")
        parts.append("")

    parts.extend([
        "Research the requested information and respond using the "
        "`mcp__interagent__BCPRespond` tool with:",
        f'  - query_id: "{query.query_id}"',
        "  - response: a JSON object with the field names and values described below",
        "",
    ])

    if query.category == 1 and query.fields:
        parts.append("**Category 1 — Structured fields (exact values required):**")
        parts.append("")
        for field in query.fields:
            name = field.get("name", "unknown")
            ftype = field.get("type", "unknown")
            if ftype == "boolean":
                parts.append(f'  - `{name}` (boolean): respond with `true` or `false`')
            elif ftype == "enum":
                options = field.get("options", [])
                parts.append(
                    f'  - `{name}` (enum): respond with exactly one of: {options}'
                )
            elif ftype == "integer":
                fmin = field.get("min")
                fmax = field.get("max")
                constraint = ""
                if fmin is not None and fmax is not None:
                    constraint = f" (range: {fmin}–{fmax})"
                elif fmin is not None:
                    constraint = f" (min: {fmin})"
                elif fmax is not None:
                    constraint = f" (max: {fmax})"
                parts.append(f"  - `{name}` (integer){constraint}")
            else:
                parts.append(f"  - `{name}` ({ftype})")

    elif query.category == 2 and query.questions:
        parts.append(
            "**Category 2 — Semi-structured questions (word limits enforced):**"
        )
        parts.append("")
        for q in query.questions:
            name = q.get("name", "unknown")
            fmt = q.get("format", "short_text")
            max_words = q.get("max_words", 10)
            parts.append(
                f"  - `{name}` (format: {fmt}, max {max_words} words)"
            )

    elif query.category == 3:
        parts.append("**Category 3 — Free-text directive (word limit enforced):**")
        parts.append("")
        parts.append(f"  Directive: {query.directive or 'N/A'}")
        if query.max_words:
            parts.append(f"  Max words: {query.max_words}")
        parts.append("")
        parts.append(
            '  Respond with: `{"response": "your free-text answer here"}`'
        )

    parts.append("")
    parts.append(
        "IMPORTANT: The gateway validates your response deterministically. "
        "Use exact types (boolean, not string). Stay within word limits. "
        "Only include the requested fields in your response object."
    )

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# BCP response delivery → prompt formatting
# ---------------------------------------------------------------------------


def _format_bcp_response_delivery_prompt(msg: BCPResponseDeliveryMessage) -> str:
    """Format a validated BCP response delivery as a prompt for the LLM.

    The prompt presents the delivered data so the Controller agent can act
    on the response from the Reader agent.
    """
    response_json = json.dumps(msg.response, indent=2)

    # Check if this is a subscription delivery or query response
    if msg.subscription_id:
        header = f"BCP Subscription Delivery (subscription: {msg.subscription_id})"
        source = f"subscription '{msg.subscription_id}'"
    else:
        header = f"BCP Response Delivery (query: {msg.query_id})"
        source = f"query '{msg.query_id}'"

    parts = [
        f"**{header}** — A validated response has arrived.",
        "",
        f"  - **From agent:** {msg.from_agent}",
        f"  - **Category:** {msg.category}",
        f"  - **Source:** {source}",
        f"  - **Bandwidth consumed:** {msg.bandwidth_bits} bits",
        "",
        "**Response data:**",
        f"```json\n{response_json}\n```",
        "",
        "This data has been structurally validated by the gateway and is safe to act on.",
    ]

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# SDK session driver
# ---------------------------------------------------------------------------


def _truncate(text: str, max_len: int = _MAX_TOOL_RESULT_LEN) -> str:
    """Truncate text, appending an indicator if it was shortened."""
    if len(text) <= max_len:
        return text
    return text[: max_len - 20] + "... [truncated]"


def _build_content_blocks(
    text: str, images: list[dict[str, str]]
) -> list[dict[str, Any]]:
    """Build Claude API content blocks from text and optional images."""
    blocks: list[dict[str, Any]] = []
    for img in images:
        blocks.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": img.get("media_type", "image/png"),
                "data": img["data"],
            },
        })
    if text:
        blocks.append({"type": "text", "text": text})
    return blocks


async def run_prompt(
    client: ClaudeSDKClient,
    prompt: str,
    interrupt_event: asyncio.Event | None = None,
    images: list[dict[str, str]] | None = None,
) -> bool:
    """Send a prompt and stream the response through the protocol.

    Uses the persistent ClaudeSDKClient which maintains conversation context
    across calls.  Each call to client.query() followed by
    client.receive_response() is a single turn within an ongoing conversation.

    When *images* are provided, the prompt is sent as structured content blocks
    (image + text) for Claude vision processing.

    Streams all events to the gateway via stdout for observation:
      - text events     -- LLM text output (audit logging)
      - tool_use events -- tool invocations (audit logging)
      - tool_result     -- tool returns (taint tracking)
      - result          -- session metadata on completion

    If *interrupt_event* is provided, the loop checks it between SDK messages
    and bails out immediately when set (no result emitted — the caller handles
    signalling the gateway).

    Returns True if the prompt completed normally, False if interrupted.
    """
    start_time = time.monotonic()
    num_turns = 0
    got_result = False

    try:
        if images:
            # Send structured content blocks for vision
            content_blocks = _build_content_blocks(prompt, images)
            log.info(
                "Calling client.query() with %d image(s) + text...",
                len(images),
            )

            async def _single_message():
                yield {
                    "type": "user",
                    "message": {"role": "user", "content": content_blocks},
                    "parent_tool_use_id": None,
                    "session_id": "default",
                }

            await client.query(_single_message())
        else:
            log.info("Calling client.query()...")
            await client.query(prompt)
        log.info("client.query() returned, calling receive_response()...")

        response_iter = client.receive_response().__aiter__()
        msg_count = 0
        while True:
            # Check for interrupt before awaiting the next SDK message.
            if interrupt_event is not None and interrupt_event.is_set():
                log.info("Interrupt detected between SDK messages, aborting prompt")
                return False

            try:
                log.debug("Awaiting next SDK message (received %d so far)...", msg_count)
                message = await response_iter.__anext__()
                msg_count += 1
                log.info("SDK message #%d: %s", msg_count, type(message).__name__)
            except StopAsyncIteration:
                log.info("SDK response stream ended after %d messages", msg_count)
                break
            except Exception as iter_exc:
                # The SDK may raise on unrecognised streaming events
                # (e.g. rate_limit_event).  Log and continue rather than
                # aborting the entire prompt.
                log.warning("Skipping SDK stream event: %s", iter_exc)
                continue

            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        emit_text(block.text)
                    elif isinstance(block, ToolUseBlock):
                        emit_tool_use(
                            tool_use_id=block.id,
                            name=_normalize_tool_name(block.name),
                            input_data=block.input,
                        )
                num_turns += 1

            elif isinstance(message, UserMessage):
                # Tool results come back in UserMessage, not AssistantMessage.
                # Observational: the gateway uses tool results to determine if
                # untrusted data entered the LLM context (taint tracking).
                for block in message.content:
                    if isinstance(block, ToolResultBlock):
                        content = block.content
                        if not isinstance(content, str):
                            content = json.dumps(content, default=str)
                        emit_tool_result(
                            tool_use_id=getattr(block, "tool_use_id", ""),
                            content=_truncate(content),
                            is_error=getattr(block, "is_error", False),
                        )

            elif isinstance(message, ResultMessage):
                got_result = True
                duration_ms = int((time.monotonic() - start_time) * 1000)
                emit_result(
                    duration_ms=duration_ms,
                    num_turns=num_turns,
                    cost_usd=getattr(
                        message,
                        "total_cost_usd",
                        getattr(message, "cost_usd", 0.0),
                    ),
                    is_error=False,
                )
                log.info(
                    "Prompt complete: %d turns, %dms",
                    num_turns,
                    duration_ms,
                )

            else:
                # Log unhandled message types (e.g. SystemMessage from
                # failed skill lookups) so they're visible in container logs.
                log.warning(
                    "Unhandled SDK message type %s: %s",
                    type(message).__name__,
                    getattr(message, "content", getattr(message, "message", str(message))),
                )

        # Ensure a result is always emitted even if the SDK stream ends
        # without a ResultMessage (e.g. rate-limited or dropped connection).
        if not got_result:
            duration_ms = int((time.monotonic() - start_time) * 1000)
            log.error("SDK stream ended without ResultMessage after %d messages", msg_count)
            emit_error("SDK stream ended without a result")
            emit_result(
                duration_ms=duration_ms,
                num_turns=num_turns,
                cost_usd=0.0,
                is_error=True,
            )

    except Exception as exc:
        duration_ms = int((time.monotonic() - start_time) * 1000)
        log.error("Prompt error: %s", exc)
        emit_error(str(exc))
        emit_result(
            duration_ms=duration_ms,
            num_turns=num_turns,
            cost_usd=0.0,
            is_error=True,
        )

    return True


# ---------------------------------------------------------------------------
# Interruptible prompt wrapper
# ---------------------------------------------------------------------------


async def run_prompt_interruptible(
    client: ClaudeSDKClient,
    prompt: str,
    dispatcher: InboundDispatcher,
    images: list[dict[str, str]] | None = None,
) -> bool:
    """Run a prompt with cooperative interrupt support.

    Returns True if the prompt completed normally, False if it was interrupted.
    On interrupt: ``run_prompt`` checks the event between SDK messages and
    returns early. We then drain stale responses and emit ``interrupted``.
    """
    dispatcher.interrupt_event.clear()

    completed = await run_prompt(
        client, prompt, interrupt_event=dispatcher.interrupt_event, images=images
    )

    if completed:
        return True
    else:
        log.info("Prompt was interrupted, draining stale responses")
        dispatcher.drain_stale_responses()
        emit_interrupted("user_message")
        return False


# ---------------------------------------------------------------------------
# Main event loop
# ---------------------------------------------------------------------------


async def main() -> None:
    """Main entry point: read messages from stdin and dispatch."""
    log.info("Agent runner started (pid=%d)", os.getpid())

    # Graceful shutdown on SIGTERM (sent by the gateway when stopping)
    shutdown_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _handle_sigterm() -> None:
        log.info("Received SIGTERM, shutting down")
        shutdown_event.set()

    try:
        loop.add_signal_handler(signal.SIGTERM, _handle_sigterm)
    except NotImplementedError:
        pass  # Windows doesn't support add_signal_handler

    dispatcher = InboundDispatcher()
    dispatcher.start()

    config: StartMessage | None = None
    client: ClaudeSDKClient | None = None
    send_handler: SendMessageHandler | None = None
    restart_handler: RestartAgentHandler | None = None
    bcp_handler: BCPHandler | None = None
    email_handler: EmailHandler | None = None

    try:
        while not shutdown_event.is_set():
            msg_raw = await dispatcher.read_control()

            if msg_raw is None:
                log.info("Stdin closed, shutting down")
                break

            try:
                msg = parse_inbound(msg_raw)
            except ValueError as exc:
                log.error("Unknown message: %s", exc)
                emit_error(str(exc))
                continue

            if isinstance(msg, StartMessage):
                config = msg
                send_handler = SendMessageHandler(dispatcher)
                restart_handler = RestartAgentHandler(dispatcher)
                bcp_handler = BCPHandler(dispatcher)
                email_handler = EmailHandler(dispatcher)
                item_handler = SubmitItemHandler(dispatcher)
                log.info(
                    "Configured: agent=%r tools=%s model=%s max_turns=%d cwd=%s",
                    config.name,
                    config.tools,
                    config.model,
                    config.max_turns,
                    config.cwd,
                )

                # Build SDK options from the gateway-provided configuration.
                # Custom tools (SendMessage, BCPQuery, BCPRespond) are hosted
                # as in-process SDK MCP tools.  We strip them from the SDK tool
                # list and replace with the MCP-prefixed names the SDK generates.
                _custom_tools = {
                    _SEND_MESSAGE_TOOL,
                    _RESTART_AGENT_TOOL,
                    _BCP_QUERY_TOOL,
                    _BCP_RESPOND_TOOL,
                    _BCP_PUBLISH_TOOL,
                    _SEND_EMAIL_TOOL,
                    _MOVE_EMAIL_TOOL,
                    _CREATE_FOLDER_TOOL,
                    _CALENDAR_QUERY_TOOL,
                    _CALENDAR_CREATE_TOOL,
                    _CALENDAR_UPDATE_TOOL,
                    _CALENDAR_DELETE_TOOL,
                    _SUBMIT_ITEM_TOOL,
                }
                sdk_tools = [
                    t for t in config.tools if t not in _custom_tools
                ]
                mcp_servers: dict[str, Any] = {}

                # Collect all in-process MCP tools for the interagent server
                interagent_tools: list[Any] = []

                if _SEND_MESSAGE_TOOL in config.tools:
                    interagent_tools.append(build_send_message_tool(send_handler))
                    sdk_tools.append(_SEND_MESSAGE_MCP_NAME)

                if _BCP_QUERY_TOOL in config.tools:
                    interagent_tools.append(build_bcp_query_tool(bcp_handler))
                    sdk_tools.append(_BCP_QUERY_MCP_NAME)

                if _RESTART_AGENT_TOOL in config.tools:
                    interagent_tools.append(build_restart_agent_tool(restart_handler))
                    sdk_tools.append(_RESTART_AGENT_MCP_NAME)

                if _BCP_RESPOND_TOOL in config.tools:
                    interagent_tools.append(build_bcp_respond_tool(bcp_handler))
                    sdk_tools.append(_BCP_RESPOND_MCP_NAME)

                if _BCP_PUBLISH_TOOL in config.tools:
                    interagent_tools.append(build_bcp_publish_tool(bcp_handler))
                    sdk_tools.append(_BCP_PUBLISH_MCP_NAME)

                if _SUBMIT_ITEM_TOOL in config.tools:
                    interagent_tools.append(build_submit_item_tool(item_handler))
                    sdk_tools.append(_SUBMIT_ITEM_MCP_NAME)

                if interagent_tools:
                    server = create_sdk_mcp_server(
                        name=_INTERAGENT_SERVER,
                        tools=interagent_tools,
                    )
                    mcp_servers[_INTERAGENT_SERVER] = server

                # Email MCP tools — hosted on a separate "email" MCP server
                email_tools: list[Any] = []

                if _SEND_EMAIL_TOOL in config.tools:
                    email_tools.append(build_send_email_tool(email_handler))
                    sdk_tools.append(_SEND_EMAIL_MCP_NAME)

                if _SAVE_DRAFT_TOOL in config.tools:
                    email_tools.append(build_save_draft_tool(email_handler))
                    sdk_tools.append(_SAVE_DRAFT_MCP_NAME)

                if _MOVE_EMAIL_TOOL in config.tools:
                    email_tools.append(build_move_email_tool(email_handler))
                    sdk_tools.append(_MOVE_EMAIL_MCP_NAME)

                if _CREATE_FOLDER_TOOL in config.tools:
                    email_tools.append(build_create_folder_tool(email_handler))
                    sdk_tools.append(_CREATE_FOLDER_MCP_NAME)

                if email_tools:
                    email_server = create_sdk_mcp_server(
                        name=_EMAIL_SERVER,
                        tools=email_tools,
                    )
                    mcp_servers[_EMAIL_SERVER] = email_server

                # Calendar MCP tools — hosted on a separate "calendar" MCP server
                calendar_handler = CalendarHandler(dispatcher)
                calendar_tools: list[Any] = []

                if _CALENDAR_QUERY_TOOL in config.tools:
                    calendar_tools.append(build_calendar_query_tool(calendar_handler))
                    sdk_tools.append(_CALENDAR_QUERY_MCP_NAME)

                if _CALENDAR_CREATE_TOOL in config.tools:
                    calendar_tools.append(build_calendar_create_tool(calendar_handler))
                    sdk_tools.append(_CALENDAR_CREATE_MCP_NAME)

                if _CALENDAR_UPDATE_TOOL in config.tools:
                    calendar_tools.append(build_calendar_update_tool(calendar_handler))
                    sdk_tools.append(_CALENDAR_UPDATE_MCP_NAME)

                if _CALENDAR_DELETE_TOOL in config.tools:
                    calendar_tools.append(build_calendar_delete_tool(calendar_handler))
                    sdk_tools.append(_CALENDAR_DELETE_MCP_NAME)

                if calendar_tools:
                    calendar_server = create_sdk_mcp_server(
                        name=_CALENDAR_SERVER,
                        tools=calendar_tools,
                    )
                    mcp_servers[_CALENDAR_SERVER] = calendar_server

                # Load project settings (including skills/plugins) when the
                # agent has declared skills or plugins. This enables the Claude
                # Code CLI to find SKILL.md / plugin.json files in the CWD.
                # FUSE policy has already restricted access to only the declared
                # skill/plugin directories, so undeclared ones are not readable.
                setting_sources = (
                    ["project"] if config.skills or config.plugins else None
                )

                # Build SDK plugin paths for declared workspace plugins
                sdk_plugins = (
                    [
                        {"type": "local", "path": f"/workspace/plugins/{p}"}
                        for p in config.plugins
                    ]
                    if config.plugins
                    else None
                )

                options = ClaudeAgentOptions(
                    system_prompt=config.system_prompt,
                    allowed_tools=sdk_tools,
                    permission_mode="acceptEdits",
                    max_turns=config.max_turns,
                    model=config.model,
                    cwd=config.cwd,
                    mcp_servers=mcp_servers,
                    setting_sources=setting_sources,
                    **({"plugins": sdk_plugins} if sdk_plugins else {}),
                )

                # Create a persistent client that maintains conversation context
                # across multiple prompts within this session.
                client = ClaudeSDKClient(options=options)
                await client.connect()
                log.info("ClaudeSDKClient connected")
                emit_ready()

            elif isinstance(msg, PromptMessage):
                if client is None or config is None:
                    emit_error("Received prompt before start message")
                    continue
                if not msg.content and not msg.images:
                    emit_error("Empty prompt content")
                    continue
                log.info(
                    "Received prompt (%d chars, %d images), dispatching to SDK",
                    len(msg.content), len(msg.images),
                )
                await run_prompt_interruptible(
                    client, msg.content, dispatcher,
                    images=msg.images if msg.images else None,
                )

            elif isinstance(msg, BCPQueryMessage):
                if client is None or config is None:
                    emit_error("Received BCP query before start message")
                    continue
                prompt = _format_bcp_query_prompt(msg)
                log.info("BCP query %s -> prompt (%d chars)", msg.query_id, len(prompt))
                await run_prompt_interruptible(client, prompt, dispatcher)

            elif isinstance(msg, BCPQueryErrorMessage):
                if client is None or config is None:
                    emit_error("Received BCP query error before start message")
                    continue
                prompt = (
                    f"**BCP Query Error** — Your query to **{msg.to_agent}** could not be delivered.\n\n"
                    f"  - **Reason:** {msg.reason}\n\n"
                    "You may need to use a different approach to accomplish this task."
                )
                log.info("BCP query error for %s -> prompt", msg.to_agent)
                await run_prompt_interruptible(client, prompt, dispatcher)

            elif isinstance(msg, BCPResponseDeliveryMessage):
                if client is None or config is None:
                    emit_error("Received BCP response delivery before start message")
                    continue
                prompt = _format_bcp_response_delivery_prompt(msg)
                log.info(
                    "BCP response delivery %s -> prompt (%d chars)",
                    msg.query_id, len(prompt),
                )
                await run_prompt_interruptible(client, prompt, dispatcher)

            elif isinstance(msg, MemorySaveMessage):
                log.info("Memory save requested: %s", msg.reason or "no reason given")
                if client is None or config is None:
                    log.info("No client for memory save, skipping")
                else:
                    prompt = (
                        "You are about to be shut down. "
                        f"Reason: {msg.reason or 'session ending'}.\n\n"
                        "Before shutdown, save any important context from this session "
                        "to your memory files. Write a brief summary of what you worked on, "
                        "key findings, and any unfinished tasks to today's daily memory file "
                        f"at agents/{config.name}/memory/ using the Write tool. "
                        "Update your HEARTBEAT.md if your current state has changed. "
                        "Be concise — only save information that would be useful in future sessions."
                    )
                    await run_prompt(client, prompt)
                break  # proceed to shutdown after memory save

            elif isinstance(msg, ShutdownMessage):
                log.info("Shutdown requested: %s", msg.reason or "no reason given")
                break

    finally:
        await dispatcher.stop()
        if client is not None:
            log.info("Disconnecting ClaudeSDKClient")
            try:
                await client.disconnect()
            except Exception as exc:
                log.debug("Client disconnect error (suppressed): %s", exc)

    log.info("Agent runner exiting")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Interrupted")
        sys.exit(0)
    except Exception as exc:
        log.critical("Fatal: %s", exc)
        emit_error(f"Fatal: {exc}")
        sys.exit(1)
