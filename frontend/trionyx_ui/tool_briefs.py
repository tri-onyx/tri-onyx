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

from trionyx_ui.schema_cache import get_schema
from trionyx_ui.views.helpers import short_path


def get_brief_specs() -> dict:
    """Return brief specs keyed by tool name (TTL-cached schema fetch)."""
    return get_schema().get("tool_briefs", {})


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
