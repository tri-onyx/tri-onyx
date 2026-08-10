"""Entry point: load config, connect to the gateway, serve MCP over HTTP."""

from __future__ import annotations

import asyncio
import logging
import os
import sys

import uvicorn

from mcp_server.config import ConfigError, load_config
from mcp_server.server import build_all

logger = logging.getLogger("mcp_server")


def _configure_logging() -> None:
    logging.basicConfig(
        level=os.environ.get("MCP_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    # uvicorn's access log would record query strings — which carry the
    # single-use `txn` of a pending authorization. Keep it off.
    logging.getLogger("uvicorn.access").disabled = True


async def _serve() -> int:
    try:
        config = load_config()
    except ConfigError as exc:
        logger.error("Configuration error: %s", exc)
        return 2

    bridge, _mcp, app, _provider = build_all(config)

    logger.info(
        "TriOnyx MCP server starting — public_url=%s endpoint=%s agents=%s",
        config.public_url,
        config.resource_url,
        ", ".join(a.name for a in config.agents),
    )

    await bridge.start()
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            host=config.bind_host,
            port=config.bind_port,
            log_config=None,
            access_log=False,
            # The tunnel terminates TLS; we generate our own public URLs from
            # `public_url`, so forwarded headers are only used for client IPs.
            proxy_headers=True,
            forwarded_allow_ips="*",
            timeout_graceful_shutdown=10,
        )
    )
    try:
        await server.serve()
    finally:
        await bridge.stop()
    return 0


def main() -> None:
    _configure_logging()
    try:
        raise SystemExit(asyncio.run(_serve()))
    except KeyboardInterrupt:  # pragma: no cover
        raise SystemExit(0)


if __name__ == "__main__":
    main()
