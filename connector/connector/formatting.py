"""Formatting utilities: markdown conversion and message chunking."""

from __future__ import annotations

from markdown_it import MarkdownIt

_md = MarkdownIt("commonmark", {"html": False, "typographer": True})

# Maximum single message length for Matrix (conservative)
DEFAULT_MAX_CHUNK = 4000


def markdown_to_matrix_html(text: str) -> str:
    """Convert agent markdown to Matrix-flavoured HTML (``formatted_body``).

    Uses commonmark rendering which covers the subset that Matrix clients
    reliably support: bold, italic, code, lists, links, blockquotes.
    """
    return _md.render(text).strip()


def markdown_to_mrkdwn(text: str) -> str:
    """Convert markdown to Slack mrkdwn format.

    This is a best-effort pass-through for now; Slack's mrkdwn is close
    enough to standard markdown for most agent output.  A full converter
    can be added later.
    """
    return text


def chunk_message(text: str, max_len: int = DEFAULT_MAX_CHUNK) -> list[str]:
    """Split *text* into chunks of at most *max_len* characters.

    Splitting prefers paragraph boundaries (double newline), then single
    newlines, then sentence-ending punctuation, and finally hard-cuts as a
    last resort.
    """
    if len(text) <= max_len:
        return [text]

    chunks: list[str] = []
    remaining = text

    while remaining:
        if len(remaining) <= max_len:
            chunks.append(remaining)
            break

        segment = remaining[:max_len]

        # Try paragraph boundary
        split_idx = segment.rfind("\n\n")
        if split_idx > max_len // 4:
            split_idx += 1  # include first newline, second starts next chunk
        elif (nl_idx := segment.rfind("\n")) > max_len // 4:
            split_idx = nl_idx + 1
        elif (sent_idx := _last_sentence_boundary(segment)) > max_len // 4:
            split_idx = sent_idx
        else:
            # Hard cut at a space if possible
            space_idx = segment.rfind(" ")
            split_idx = space_idx if space_idx > max_len // 4 else max_len

        chunk = remaining[:split_idx].rstrip()
        if chunk:
            chunks.append(chunk)
        remaining = remaining[split_idx:].lstrip("\n")

    return chunks


def _last_sentence_boundary(text: str) -> int:
    """Return the index just past the last sentence-ending punctuation."""
    best = -1
    for i, ch in enumerate(text):
        if ch in ".!?" and i + 1 < len(text) and text[i + 1] == " ":
            best = i + 2
    return best
