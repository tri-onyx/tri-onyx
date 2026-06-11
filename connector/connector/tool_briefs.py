"""Tool brief rendering driven by gateway-served specs.

The gateway's ToolRegistry owns the per-tool brief specs (served as
``tool_briefs`` in ``GET /agents/schema``). Each spec is an ordered list
of segments: ``{keys, prefix?, suffix?, max_len?, transform?}``. A
segment renders the first non-empty input value among ``keys``; the
``"path"`` transform shortens workspace paths; ``max_len`` truncates
with an ellipsis. Tools without a spec render generically from their
first input field.

Specs are fetched once at connector startup via
:func:`load_brief_specs`; until then (or if the gateway is unreachable)
every tool uses the generic fallback.
"""

import asyncio
import json
import logging

import aiohttp

logger = logging.getLogger(__name__)

_specs: dict = {}

_FETCH_ATTEMPTS = 6
_FETCH_RETRY_DELAY_S = 5


def _http_base_from_ws_url(gateway_url: str) -> str:
    """Derive the gateway HTTP base URL from its connector WebSocket URL."""
    base = gateway_url.replace("ws://", "http://", 1).replace("wss://", "https://", 1)
    return base.split("/connectors/", 1)[0].rstrip("/")


async def load_brief_specs(gateway_url: str) -> None:
    """Fetch tool brief specs from the gateway, keeping {} on failure.

    Retries for a while since the connector and gateway typically
    restart together and the gateway takes longer to come up.
    """
    url = f"{_http_base_from_ws_url(gateway_url)}/agents/schema"
    for attempt in range(1, _FETCH_ATTEMPTS + 1):
        try:
            timeout = aiohttp.ClientTimeout(total=5)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as resp:
                    resp.raise_for_status()
                    payload = await resp.json()
            _specs.update(payload.get("tool_briefs", {}))
            logger.info("Loaded %d tool brief specs from gateway", len(_specs))
            return
        except Exception as exc:
            if attempt == _FETCH_ATTEMPTS:
                logger.warning(
                    "Could not load tool brief specs from %s after %d attempts: %s",
                    url, attempt, exc,
                )
            else:
                await asyncio.sleep(_FETCH_RETRY_DELAY_S)


def _short_path(path: str) -> str:
    """Compact a workspace path for display (same rule as the web UI)."""
    if not path:
        return ""
    parts = path.replace("/workspace/", "").split("/")
    if len(parts) > 3:
        return f".../{'/'.join(parts[-2:])}"
    return "/".join(parts)


def _stringify(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def format_tool_brief(tool_name: str, tool_input: dict) -> str:
    """One-line summary of a tool_use input, per the gateway's specs."""
    if not tool_input:
        return ""
    segments = _specs.get(tool_name)
    if segments:
        parts = []
        for seg in segments:
            value = next(
                (tool_input[k] for k in seg.get("keys", []) if tool_input.get(k) not in (None, "")),
                None,
            )
            if value is None:
                continue
            text = _stringify(value)
            if seg.get("transform") == "path":
                text = _short_path(text)
            max_len = seg.get("max_len")
            if max_len and len(text) > max_len:
                text = text[:max_len] + "…"
            parts.append(f"{seg.get('prefix', '')}{text}{seg.get('suffix', '')}")
        return "".join(parts)
    keys = list(tool_input.keys())
    if not keys:
        return ""
    text = _stringify(tool_input[keys[0]])
    return text[:80] + ("…" if len(text) > 80 else "")
