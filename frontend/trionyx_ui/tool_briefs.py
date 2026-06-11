"""Tool brief rendering driven by gateway-served specs.

The gateway's ToolRegistry owns the per-tool brief specs (served as
``tool_briefs`` in ``GET /agents/schema``). Each spec is an ordered list
of segments: ``{keys, prefix?, suffix?, max_len?, transform?}``. A
segment renders the first non-empty input value among ``keys``; the
``"path"`` transform shortens workspace paths; ``max_len`` truncates
with an ellipsis. Tools without a spec render generically from their
first input field, so new tools degrade gracefully instead of showing
nothing.
"""

import json
import time

from trionyx_ui import gateway
from trionyx_ui.views.helpers import short_path

_CACHE_TTL_S = 300
_cache: dict = {"specs": None, "fetched_at": 0.0}


def get_brief_specs() -> dict:
    """Return brief specs keyed by tool name, cached for a few minutes.

    Falls back to the last known specs (or ``{}``) when the gateway is
    unreachable, backing off for a full TTL so page renders don't retry
    per message.
    """
    now = time.monotonic()
    if _cache["specs"] is not None and now - _cache["fetched_at"] < _CACHE_TTL_S:
        return _cache["specs"]
    try:
        _cache["specs"] = gateway.get_agent_schema().get("tool_briefs", {})
    except Exception:
        if _cache["specs"] is None:
            _cache["specs"] = {}
    _cache["fetched_at"] = now
    return _cache["specs"]


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
    segments = get_brief_specs().get(tool_name)
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
                text = short_path(text)
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
