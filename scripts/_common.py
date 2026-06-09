"""Shared helpers for TriOnyx scripts. Stdlib-only so PEP 723 scripts can
import it without declaring extra dependencies."""

import os

GATEWAY_HOST_PORT = "localhost:4000"


def gateway_url(scheme: str = "http") -> str:
    """Gateway base URL: $TRI_ONYX_GATEWAY if set, else scheme://localhost:4000."""
    return os.environ.get("TRI_ONYX_GATEWAY", f"{scheme}://{GATEWAY_HOST_PORT}")
