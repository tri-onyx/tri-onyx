"""TriOnyx MCP server — a public MCP entry point into a small allowlist of agents.

The package is deliberately thin: the wire protocol to the gateway is reused
verbatim from the ``connector`` package, and OAuth 2.1 (DCR, PKCE, RFC 8707,
RFC 9728) is served by the ``mcp`` SDK's built-in authorization-server routes.
What lives here is the operator-only authorization policy, token storage, the
gateway request/response bridge, and the two-tool MCP surface.
"""

__all__ = ["__version__"]

__version__ = "0.1.0"
