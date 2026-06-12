"""TTL-cached access to the gateway's /agents/schema metadata.

The schema response carries the gateway-owned vocabularies the UI must
not hardcode (tool brief specs, session event types, known tools, …).
Consumers read through this cache so a page render costs at most one
schema fetch per TTL window; on gateway errors the last known schema is
served (or ``{}`` before the first successful fetch).
"""

import time

from trionyx_ui import gateway

_CACHE_TTL_S = 300
_cache: dict = {"schema": None, "fetched_at": 0.0}


def get_schema() -> dict:
    now = time.monotonic()
    if _cache["schema"] is not None and now - _cache["fetched_at"] < _CACHE_TTL_S:
        return _cache["schema"]
    try:
        _cache["schema"] = gateway.get_agent_schema()
    except Exception:
        if _cache["schema"] is None:
            _cache["schema"] = {}
    _cache["fetched_at"] = now
    return _cache["schema"]


def visible_event_types() -> set:
    """Session event types the chat UI renders (gateway-owned list)."""
    return set(get_schema().get("session_events", {}).get("chat_visible", []))


def sse_event_types() -> list:
    """Event types the live chat SSE stream subscribes to: everything
    chat-visible plus the router's stream-level meta events."""
    events = get_schema().get("session_events", {})
    return events.get("chat_visible", []) + events.get("sse_meta", [])
