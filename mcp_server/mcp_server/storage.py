"""Persistent OAuth state.

Everything token-shaped is stored **hashed** (SHA-256 of the raw token), so a
leak of the store file yields no usable credential: an attacker would still need
to invert the hash. Registered client records are stored verbatim — they are not
secrets on their own (registration grants nothing without an operator login) —
except the client secret, which is only ever minted for confidential clients and
is needed in cleartext by the SDK's constant-time comparison at ``/token``.

The file is a single JSON document rewritten atomically. Losing it costs the
operator exactly one re-authorization in claude.ai; nothing else depends on it.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from collections.abc import Collection
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

STORE_VERSION = 1


def hash_token(token: str) -> str:
    """SHA-256 of a bearer/refresh/authorization token, hex encoded."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class OAuthStore:
    """JSON-backed store for clients, access tokens and refresh tokens.

    All lookups are by token hash. If the backing file cannot be written the
    store degrades to memory-only and logs once — the server keeps working, the
    operator just has to re-authorize after a restart.
    """

    def __init__(
        self,
        path: Path | str | None,
        *,
        max_clients: int = 10,
        client_ttl_seconds: float = 30 * 24 * 3600,
    ) -> None:
        self._path = Path(path) if path is not None else None
        self._max_clients = max_clients
        self._client_ttl = client_ttl_seconds
        self._clients: dict[str, dict[str, Any]] = {}
        self._access: dict[str, dict[str, Any]] = {}
        self._refresh: dict[str, dict[str, Any]] = {}
        self._write_failed = False
        self._load()

    # ------------------------------------------------------------------
    # Persistence
    # ------------------------------------------------------------------

    def _load(self) -> None:
        if self._path is None or not self._path.is_file():
            return
        try:
            data = json.loads(self._path.read_text())
        except (OSError, ValueError) as exc:
            logger.error("Could not read OAuth store %s (%s) — starting empty", self._path, exc)
            return
        if not isinstance(data, dict) or data.get("version") != STORE_VERSION:
            logger.error("OAuth store %s has unexpected format — starting empty", self._path)
            return
        self._clients = dict(data.get("clients") or {})
        self._access = dict(data.get("access_tokens") or {})
        self._refresh = dict(data.get("refresh_tokens") or {})
        removed = self.prune()
        logger.info(
            "Loaded OAuth store: %d client(s), %d access token(s), %d refresh token(s)"
            "%s",
            len(self._clients),
            len(self._access),
            len(self._refresh),
            f" ({removed} expired pruned)" if removed else "",
        )

    def _save(self) -> None:
        if self._path is None:
            return
        payload = {
            "version": STORE_VERSION,
            "clients": self._clients,
            "access_tokens": self._access,
            "refresh_tokens": self._refresh,
        }
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, separators=(",", ":"))
                fh.flush()
                os.fsync(fh.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._path)
            self._write_failed = False
        except OSError as exc:
            if not self._write_failed:
                logger.error(
                    "Cannot persist OAuth store to %s (%s) — running memory-only; "
                    "authorization will not survive a restart",
                    self._path,
                    exc,
                )
                self._write_failed = True
            try:
                tmp.unlink(missing_ok=True)
            except OSError:  # pragma: no cover - best effort cleanup
                pass

    # ------------------------------------------------------------------
    # Clients
    # ------------------------------------------------------------------

    def get_client(self, client_id: str) -> dict[str, Any] | None:
        record = self._clients.get(client_id)
        return dict(record) if record is not None else None

    def put_client(
        self,
        client_id: str,
        record: dict[str, Any],
        *,
        protected: Collection[str] = (),
    ) -> bool:
        """Store a client registration, bounded by ``max_clients``.

        Registration is unauthenticated, so the store must not grow without
        limit: at capacity the oldest *tokenless* registration is evicted to
        make room. Clients in *protected* (those with an authorization the
        operator may be in the middle of approving) are evicted only if there is
        nothing else to take. Returns False (nothing stored) only in the
        pathological case where every stored client holds live tokens.
        """
        if client_id not in self._clients and len(self._clients) >= self._max_clients:
            if not self._evict_one_client(protected):
                return False
        # RFC 7591 field; anchor for the TTL prune if the SDK didn't set it.
        record.setdefault("client_id_issued_at", int(time.time()))
        self._clients[client_id] = record
        self._save()
        return True

    def client_count(self) -> int:
        return len(self._clients)

    def _client_ids_with_tokens(self) -> set[str]:
        return {
            str(rec.get("client_id"))
            for bucket in (self._access, self._refresh)
            for rec in bucket.values()
        }

    @staticmethod
    def _issued_at(record: dict[str, Any]) -> float:
        try:
            return float(record.get("client_id_issued_at") or 0.0)
        except (TypeError, ValueError):
            return 0.0

    def _evict_one_client(self, protected: Collection[str] = ()) -> bool:
        live = self._client_ids_with_tokens()
        candidates = [cid for cid in self._clients if cid not in live]
        if not candidates:
            return False
        # A registration with a parked authorization is one operator password
        # away from holding live tokens, so a /register flood must not be able
        # to evict it while any idle registration is still available.
        preferred = [cid for cid in candidates if cid not in protected] or candidates
        oldest = min(preferred, key=lambda cid: self._issued_at(self._clients[cid]))
        self._clients.pop(oldest, None)
        logger.info("Evicted tokenless OAuth client %s (store at capacity)", oldest)
        return True

    # ------------------------------------------------------------------
    # Access tokens
    # ------------------------------------------------------------------

    def put_access_token(self, token: str, record: dict[str, Any]) -> str:
        digest = hash_token(token)
        self._access[digest] = record
        self._save()
        return digest

    def get_access_token(self, token: str) -> dict[str, Any] | None:
        record = self._access.get(hash_token(token))
        return dict(record) if record is not None else None

    def delete_access_token_hash(self, digest: str) -> None:
        if self._access.pop(digest, None) is not None:
            self._save()

    # ------------------------------------------------------------------
    # Refresh tokens
    # ------------------------------------------------------------------

    def put_refresh_token(self, token: str, record: dict[str, Any]) -> str:
        digest = hash_token(token)
        self._refresh[digest] = record
        self._save()
        return digest

    def get_refresh_token(self, token: str) -> dict[str, Any] | None:
        record = self._refresh.get(hash_token(token))
        return dict(record) if record is not None else None

    def pop_refresh_token(self, token: str) -> dict[str, Any] | None:
        """Atomically remove and return a refresh token record (rotation)."""
        record = self._refresh.pop(hash_token(token), None)
        if record is not None:
            self._save()
        return record

    def delete_refresh_token_hash(self, digest: str) -> None:
        if self._refresh.pop(digest, None) is not None:
            self._save()

    def delete_refresh_tokens_for_access(self, access_hash: str) -> int:
        """Drop every refresh token that last minted the given access token."""
        digests = [
            d for d, rec in self._refresh.items() if rec.get("access_hash") == access_hash
        ]
        for digest in digests:
            self._refresh.pop(digest, None)
        if digests:
            self._save()
        return len(digests)

    # ------------------------------------------------------------------
    # Maintenance
    # ------------------------------------------------------------------

    def prune(self, now: float | None = None) -> int:
        """Drop expired tokens and stale tokenless client registrations.

        Returns the number of records removed.
        """
        now = time.time() if now is None else now
        removed = 0
        for bucket in (self._access, self._refresh):
            for digest in [
                d
                for d, rec in bucket.items()
                if rec.get("expires_at") is not None and rec["expires_at"] < now
            ]:
                bucket.pop(digest, None)
                removed += 1
        # A registration that has outlived the TTL without holding any token is
        # abandoned (claude.ai re-registers transparently if it comes back).
        live = self._client_ids_with_tokens()
        for client_id in [
            cid
            for cid, rec in self._clients.items()
            if cid not in live and self._issued_at(rec) + self._client_ttl < now
        ]:
            self._clients.pop(client_id, None)
            removed += 1
        if removed:
            self._save()
        return removed
