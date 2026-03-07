"""Abstract base class for chat platform adapters."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Callable, Coroutine

from connector.formatting import DEFAULT_MAX_CHUNK, chunk_message, markdown_to_matrix_html

# Callback type: adapter calls this with an InboundMessage-compatible dict
OnMessageCallback = Callable[..., Coroutine[Any, Any, None]]
OnReactionCallback = Callable[..., Coroutine[Any, Any, None]]


class BaseAdapter(ABC):
    """Interface every chat platform adapter must implement.

    Adapters are responsible for translating between platform-native events
    and the connector's internal protocol.  The gateway client wires the
    ``on_message`` callback at startup so inbound messages flow through to
    the gateway automatically.
    """

    @abstractmethod
    async def start(
        self,
        on_message: OnMessageCallback,
        on_reaction: OnReactionCallback | None = None,
    ) -> None:
        """Connect to the platform and begin listening for events."""

    @abstractmethod
    async def stop(self) -> None:
        """Disconnect and release resources."""

    @abstractmethod
    async def send_text(
        self, channel: dict[str, Any], content: str, *, agent_name: str = ""
    ) -> None:
        """Send a text message to the given channel."""

    @abstractmethod
    async def send_typing(self, channel: dict[str, Any], is_typing: bool) -> None:
        """Set or clear the typing indicator in the given channel."""

    @abstractmethod
    async def send_reaction(self, channel: dict[str, Any], emoji: str) -> None:
        """React to a message in the given channel with *emoji*."""

    @abstractmethod
    async def edit_message(
        self, channel: dict[str, Any], message_id: str, new_content: str
    ) -> None:
        """Replace the content of a previously sent message."""

    @abstractmethod
    async def delete_message(
        self, channel: dict[str, Any], message_id: str
    ) -> None:
        """Delete (redact) a previously sent message."""

    @abstractmethod
    async def send_file(
        self,
        channel: dict[str, Any],
        file_data: bytes,
        filename: str,
        mime_type: str,
    ) -> None:
        """Upload and send a file attachment."""

    def format_message(self, markdown: str) -> str:
        """Convert markdown to the platform's native rich-text format.

        The default implementation returns Matrix HTML.  Subclasses should
        override this for other platforms.
        """
        return markdown_to_matrix_html(markdown)

    def chunk_message(self, content: str, max_len: int = DEFAULT_MAX_CHUNK) -> list[str]:
        """Split content into platform-appropriate chunks."""
        return chunk_message(content, max_len)

    async def send_article(
        self,
        channel: dict[str, Any],
        title: str,
        url: str,
        source: str,
        summary: str,
        *,
        agent_name: str = "",
    ) -> None:
        """Send a formatted article to the given channel.

        The default implementation formats as markdown and delegates to
        ``send_text``.  Adapters may override for richer formatting.
        """
        text = f"**{title}** ({source})\n{summary}\n{url}"
        await self.send_text(channel, text, agent_name=agent_name)

    async def send_step(self, channel: dict[str, Any], step: Any) -> None:
        """Send an agent step (tool use, tool result, completion) to the channel.

        The default implementation is a no-op.  Adapters that support step
        rendering should override this method.
        """

    async def send_approval_request(
        self,
        approval_id: str,
        from_agent: str,
        to_agent: str,
        category: int,
        query_summary: str,
        response_content: str,
        anomalies: list[dict[str, Any]],
        channel: dict[str, Any] | None = None,
    ) -> None:
        """Send a BCP approval request to the platform for human review.

        The default implementation is a no-op.  Adapters that support approval
        workflows should override this method.
        """

    @abstractmethod
    async def health(self) -> dict[str, Any]:
        """Return a health-check dict for inclusion in heartbeat messages."""
