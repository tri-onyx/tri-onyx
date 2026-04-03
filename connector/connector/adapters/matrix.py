"""Matrix adapter using matrix-nio for E2E-capable communication."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any

from nio import (
    AsyncClient,
    AsyncClientConfig,
    DeleteDevicesAuthResponse,
    DeleteDevicesError,
    DownloadResponse,
    InviteMemberEvent,
    JoinError,
    KeyVerificationCancel,
    KeyVerificationKey,
    KeyVerificationMac,
    KeyVerificationStart,
    LoginResponse,
    MatrixRoom,
    MegolmEvent,
    RoomEncryptedAudio,
    RoomEncryptedImage,
    RoomKeyRequestError,
    RoomMessageAudio,
    RoomMessageImage,
    RoomMessageText,
    RoomSendResponse,
    ReactionEvent,
    RoomGetEventResponse,
    SyncResponse,
    UnknownEvent,
    UnknownToDeviceEvent,
)
from nio.crypto import decrypt_attachment

from connector.adapters.base import BaseAdapter, OnMessageCallback, OnReactionCallback
from connector.config import AdapterConfig, RoomConfig
from connector.formatting import markdown_to_matrix_html
from connector.protocol import AgentStepMessage, ApprovalRequestMessage, InboundMessage, ReactionMessage

logger = logging.getLogger(__name__)

# Default merge window: batch rapid-fire messages from the same user
_DEFAULT_MERGE_WINDOW_MS = 3000


class MatrixAdapter(BaseAdapter):
    """Bridges Matrix rooms to the TriOnyx gateway.

    Supports E2E encryption, threading, mention gating, message merging,
    trust mapping, rich formatting, and standard Matrix event types.
    """

    def __init__(
        self,
        config: AdapterConfig,
        transcriber: Any | None = None,
        adapter_name: str = "matrix",
        config_path: str = "",
        instance_name: str = "",
    ) -> None:
        self._config = config
        self._transcriber = transcriber
        self._adapter_name = adapter_name
        self._config_path = config_path
        self._instance_name = instance_name
        self._client: AsyncClient | None = None
        self._on_message: OnMessageCallback | None = None
        self._running = False
        self._sync_task: asyncio.Task[None] | None = None

        # Merge buffer: room_id -> list of (timestamp_ms, sender, body, images)
        self._merge_buffers: dict[str, list[tuple[float, str, str, list[dict[str, str]]]]] = {}
        self._merge_tasks: dict[str, asyncio.Task[None]] = {}

        # Room configs keyed by room_id
        self._rooms: dict[str, RoomConfig] = dict(config.rooms)

        # Skip messages from the initial sync (historical backfill)
        self._initial_sync_done = False

        # Track sessions we've already requested keys for (avoid spam)
        self._requested_key_sessions: set[str] = set()

        # Track event IDs we sent so we can ignore them in callbacks,
        # even if the sender check somehow fails (E2E edge cases).
        self._own_event_ids: set[str] = set()

        # Approval tracking: matrix_event_id -> approval_id
        self._approval_events: dict[str, str] = {}

        # Reaction callback
        self._on_reaction: OnReactionCallback | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(
        self,
        on_message: OnMessageCallback,
        on_reaction: OnReactionCallback | None = None,
    ) -> None:
        """Connect to the homeserver and begin syncing."""
        self._on_message = on_message
        self._on_reaction = on_reaction
        self._running = True

        store_path = self._config.store_path or None
        if store_path:
            os.makedirs(store_path, exist_ok=True)

        client_config = AsyncClientConfig(
            store_sync_tokens=True,
            encryption_enabled=True,
        )
        self._client = AsyncClient(
            homeserver=self._config.homeserver,
            user=self._config.user_id,
            device_id=self._config.device_id,
            store_path=store_path,
            config=client_config,
        )
        self._client.access_token = self._config.access_token
        # Set user_id explicitly — required for Olm account initialization
        self._client.user_id = self._config.user_id

        # Initialize the crypto store (creates Olm account on first run,
        # restores persisted keys on subsequent runs). Must be called after
        # user_id and device_id are set.
        if store_path:
            self._client.load_store()
            logger.info("Crypto store loaded from %s", store_path)

            # Share device keys with the homeserver so other users can
            # encrypt to-device messages for us (key sharing, etc.)
            try:
                resp = await self._client.keys_upload()
                logger.info("Device keys uploaded: %s", type(resp).__name__)
            except Exception:
                logger.info("Device keys already uploaded (restored from store)")

            # Remove stale device sessions so other clients see only our
            # active device and are willing to share Megolm keys with us.
            await self._delete_stale_devices()

        # Register event callbacks
        self._client.add_event_callback(self._on_room_message, RoomMessageText)
        self._client.add_event_callback(self._on_room_image, RoomMessageImage)
        self._client.add_event_callback(self._on_room_image, RoomEncryptedImage)
        if self._transcriber is not None:
            self._client.add_event_callback(self._on_room_audio, RoomMessageAudio)
            self._client.add_event_callback(self._on_room_audio, RoomEncryptedAudio)
        self._client.add_event_callback(self._on_megolm_event, MegolmEvent)
        self._client.add_event_callback(self._on_invite, InviteMemberEvent)
        self._client.add_event_callback(self._on_reaction_event, ReactionEvent)
        self._client.add_event_callback(self._on_unknown_event, UnknownEvent)

        # Key verification callbacks (SAS emoji verification)
        self._client.add_to_device_callback(self._on_key_verification_request, UnknownToDeviceEvent)
        self._client.add_to_device_callback(self._on_key_verification, KeyVerificationStart)
        self._client.add_to_device_callback(self._on_key_verification, KeyVerificationCancel)
        self._client.add_to_device_callback(self._on_key_verification, KeyVerificationKey)
        self._client.add_to_device_callback(self._on_key_verification, KeyVerificationMac)

        # Resolve room aliases if needed
        await self._resolve_rooms()

        logger.info(
            "Matrix adapter starting sync as %s on %s (device=%s)",
            self._config.user_id,
            self._config.homeserver,
            self._config.device_id,
        )
        self._sync_task = asyncio.create_task(self._sync_loop())

    async def stop(self) -> None:
        """Stop syncing and close the Matrix client."""
        self._running = False
        if self._sync_task is not None:
            self._sync_task.cancel()
            self._sync_task = None

        # Cancel pending merge timers
        for task in self._merge_tasks.values():
            task.cancel()
        self._merge_tasks.clear()
        self._merge_buffers.clear()

        if self._client is not None:
            await self._client.close()
            self._client = None

        logger.info("Matrix adapter stopped")

    # ------------------------------------------------------------------
    # Sync loop
    # ------------------------------------------------------------------

    async def _sync_loop(self) -> None:
        """Run the /sync loop until stopped."""
        assert self._client is not None
        try:
            # First sync with full_state to get device lists for E2E
            response = await self._client.sync(timeout=30000, full_state=True)
            if isinstance(response, SyncResponse):
                # Query device keys for all users we share rooms with
                # so we can verify and encrypt to them
                users = set()
                for room_id in self._rooms:
                    room = self._client.rooms.get(room_id)
                    if room:
                        users.update(room.users.keys())
                if users:
                    await self._client.keys_query()
                    logger.info("Queried device keys for %d user(s)", len(users))

                await self._trust_all_devices()
                await self._demote_self_in_rooms()
                self._initial_sync_done = True
                logger.info(
                    "Matrix adapter initial sync complete — "
                    "now listening for new messages"
                )

            sync_count = 0
            while self._running:
                response = await self._client.sync(timeout=30000, full_state=False)
                if isinstance(response, SyncResponse):
                    sync_count += 1
                    # Periodically re-trust new devices (every ~50 syncs ≈ 25 min)
                    if sync_count % 50 == 0:
                        await self._trust_all_devices()
        except asyncio.CancelledError:
            pass
        except Exception:
            logger.exception("Matrix sync loop crashed")

    # ------------------------------------------------------------------
    # Inbound event handling
    # ------------------------------------------------------------------

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent) -> None:
        """Auto-join rooms the bot is invited to, if they are in the config."""
        if event.state_key != self._config.user_id:
            return

        assert self._client is not None

        if room.room_id not in self._rooms:
            logger.warning("Ignoring invite to unconfigured room %s", room.room_id)
            return

        logger.info("Received invite to configured room %s, joining...", room.room_id)
        result = await self._client.join(room.room_id)
        if isinstance(result, JoinError):
            logger.error("Failed to join %s: %s", room.room_id, result)
        else:
            logger.info("Joined room %s", room.room_id)

    async def _on_room_message(self, room: MatrixRoom, event: RoomMessageText) -> None:
        """Handle an incoming text message."""
        # Skip messages from initial sync (historical backfill)
        if not self._initial_sync_done:
            return

        # Ignore own messages (primary: sender check, secondary: event ID tracking)
        if event.sender == self._config.user_id:
            self._own_event_ids.discard(event.event_id)
            return

        if event.event_id in self._own_event_ids:
            logger.warning(
                "Self-loop guard: event %s matched outbound tracking but had "
                "sender %s (expected %s) — dropping",
                event.event_id,
                event.sender,
                self._config.user_id,
            )
            self._own_event_ids.discard(event.event_id)
            return

        logger.info(
            "Message from %s in %s: %.100s",
            event.sender,
            room.room_id,
            event.body,
        )

        room_cfg = self._rooms.get(room.room_id)
        if room_cfg is None:
            logger.debug("Ignoring message — room %s not in config", room.room_id)
            return

        # Mention gating: in group rooms, require @mention or direct reply
        if not self._should_dispatch(room, event, room_cfg):
            logger.debug(
                "Ignoring message — mention gating filtered it (mode=%s, members=%d)",
                room_cfg.mode,
                room.member_count,
            )
            return

        # Extract threading info
        thread_id = self._extract_thread_id(event)

        now_ms = time.monotonic() * 1000
        merge_window = room_cfg.merge_window_ms

        # Buffer the message for merging
        buf = self._merge_buffers.setdefault(room.room_id, [])
        buf.append((now_ms, event.sender, event.body, []))

        # Reset or start the merge timer
        if room.room_id in self._merge_tasks:
            self._merge_tasks[room.room_id].cancel()

        self._merge_tasks[room.room_id] = asyncio.create_task(
            self._flush_merge_buffer(room.room_id, room_cfg, thread_id, merge_window)
        )

    async def _on_room_image(
        self, room: MatrixRoom, event: RoomMessageImage | RoomEncryptedImage
    ) -> None:
        """Handle an incoming image message by downloading and base64-encoding it."""
        if not self._initial_sync_done:
            return

        if event.sender == self._config.user_id:
            return

        if event.event_id in self._own_event_ids:
            self._own_event_ids.discard(event.event_id)
            return

        room_cfg = self._rooms.get(room.room_id)
        if room_cfg is None:
            return

        assert self._client is not None

        mxc_url = event.url
        if not mxc_url:
            logger.warning("Image event %s has no URL", event.event_id)
            return

        logger.info(
            "Image from %s in %s (%s), downloading...",
            event.sender,
            room.room_id,
            type(event).__name__,
        )

        resp = await self._client.download(mxc_url)
        if not isinstance(resp, DownloadResponse):
            logger.error("Failed to download image: %s", resp)
            return

        image_data = resp.body

        # Decrypt if this is an encrypted media event
        if isinstance(event, RoomEncryptedImage):
            try:
                key = event.key.get("k", "")
                sha256_hash = event.hashes.get("sha256", "")
                image_data = decrypt_attachment(image_data, key, sha256_hash, event.iv)
            except Exception:
                logger.exception("Failed to decrypt image for event %s", event.event_id)
                return

        import base64

        b64_data = base64.b64encode(image_data).decode("ascii")

        # Determine media type from the mimetype field or content-type header
        media_type = getattr(event, "mimetype", None) or resp.content_type or "image/png"

        image_entry = {
            "data": b64_data,
            "media_type": media_type,
        }

        # Use the image body (caption) as text, or empty string
        body = getattr(event, "body", "") or ""

        logger.info(
            "Image downloaded (%.1f KB, %s) from %s in %s",
            len(image_data) / 1024,
            media_type,
            event.sender,
            room.room_id,
        )

        # Feed into merge buffer (same path as text messages).
        # Images bypass mention gating since you can't @-mention in an image.
        now_ms = time.monotonic() * 1000
        merge_window = room_cfg.merge_window_ms

        buf = self._merge_buffers.setdefault(room.room_id, [])
        buf.append((now_ms, event.sender, body, [image_entry]))

        if room.room_id in self._merge_tasks:
            self._merge_tasks[room.room_id].cancel()

        self._merge_tasks[room.room_id] = asyncio.create_task(
            self._flush_merge_buffer(room.room_id, room_cfg, None, merge_window)
        )

    async def _on_room_audio(
        self, room: MatrixRoom, event: RoomMessageAudio | RoomEncryptedAudio
    ) -> None:
        """Handle an incoming voice/audio message by transcribing it."""
        if not self._initial_sync_done:
            return

        if event.sender == self._config.user_id:
            return

        if event.event_id in self._own_event_ids:
            self._own_event_ids.discard(event.event_id)
            return

        room_cfg = self._rooms.get(room.room_id)
        if room_cfg is None:
            return

        assert self._client is not None
        assert self._transcriber is not None

        mxc_url = event.url
        if not mxc_url:
            logger.warning("Audio event %s has no URL", event.event_id)
            return

        logger.info(
            "Voice message from %s in %s (%s), downloading...",
            event.sender,
            room.room_id,
            type(event).__name__,
        )

        resp = await self._client.download(mxc_url)
        if not isinstance(resp, DownloadResponse):
            logger.error("Failed to download audio: %s", resp)
            return

        audio_data = resp.body

        # Decrypt if this is an encrypted media event
        if isinstance(event, RoomEncryptedAudio):
            try:
                key = event.key.get("k", "")
                sha256_hash = event.hashes.get("sha256", "")
                audio_data = decrypt_attachment(audio_data, key, sha256_hash, event.iv)
            except Exception:
                logger.exception("Failed to decrypt audio for event %s", event.event_id)
                return

        # Transcribe in executor to avoid blocking the event loop
        loop = asyncio.get_running_loop()
        try:
            text = await loop.run_in_executor(
                None, self._transcriber.transcribe_bytes, audio_data
            )
        except Exception:
            logger.exception("Transcription failed for event %s", event.event_id)
            return

        if not text:
            logger.info("Transcription returned empty text for event %s", event.event_id)
            return

        logger.info(
            "Transcribed voice message: %.100s (from %s in %s)",
            text,
            event.sender,
            room.room_id,
        )

        # Feed into merge buffer (same path as text messages).
        # Voice messages bypass mention gating since you can't @-mention in audio.
        now_ms = time.monotonic() * 1000
        merge_window = room_cfg.merge_window_ms

        buf = self._merge_buffers.setdefault(room.room_id, [])
        buf.append((now_ms, event.sender, text, []))

        if room.room_id in self._merge_tasks:
            self._merge_tasks[room.room_id].cancel()

        self._merge_tasks[room.room_id] = asyncio.create_task(
            self._flush_merge_buffer(room.room_id, room_cfg, None, merge_window)
        )

    async def _on_megolm_event(self, room: MatrixRoom, event: MegolmEvent) -> None:
        """Handle undecryptable E2E events by requesting missing keys."""
        # During initial sync, these are all historical messages from before
        # the bot joined — they can never be decrypted. Skip silently.
        if not self._initial_sync_done:
            return

        assert self._client is not None
        session_id = getattr(event, "session_id", "unknown")

        # Only request keys once per session (avoid spamming duplicate requests)
        if session_id in self._requested_key_sessions:
            logger.debug(
                "Skipping duplicate key request for session %s (event %s)",
                session_id,
                event.event_id,
            )
            return

        logger.warning(
            "Unable to decrypt event %s in room %s (session %s) — requesting keys",
            event.event_id,
            room.room_id,
            session_id,
        )

        self._requested_key_sessions.add(session_id)

        try:
            resp = await self._client.request_room_key(event)
            if isinstance(resp, RoomKeyRequestError):
                logger.error("Key request failed for session %s: %s", session_id, resp)
            else:
                logger.info("Requested room key for session %s", session_id)
        except Exception:
            logger.warning("Key request error for session %s (may already be pending)", session_id)

    async def _on_key_verification_request(self, event: UnknownToDeviceEvent) -> None:
        """Handle m.key.verification.request events that nio doesn't parse natively.

        Element sends this as the first step before SAS begins.  We reply
        with m.key.verification.ready so the requesting client proceeds to
        m.key.verification.start, which our typed handler picks up.
        """
        source = getattr(event, "source", {})
        if source.get("type") != "m.key.verification.request":
            return

        assert self._client is not None

        sender = source.get("sender", "")
        content = source.get("content", {})
        transaction_id = content.get("transaction_id", "")
        from_device = content.get("from_device", "")
        methods = content.get("methods", [])

        logger.info(
            "Verification request from %s (device %s, transaction %s, methods %s)",
            sender,
            from_device,
            transaction_id,
            methods,
        )

        if "m.sas.v1" not in methods:
            logger.warning(
                "Verification %s: no supported method (got %s), ignoring",
                transaction_id,
                methods,
            )
            return

        # Reply with m.key.verification.ready so the requester proceeds to
        # m.key.verification.start
        from nio.event_builders.direct_messages import ToDeviceMessage

        ready_msg = ToDeviceMessage(
            type="m.key.verification.ready",
            recipient=sender,
            recipient_device=from_device,
            content={
                "transaction_id": transaction_id,
                "methods": ["m.sas.v1"],
                "from_device": self._config.device_id,
            },
        )

        resp = await self._client.to_device(ready_msg)

        logger.info(
            "Verification %s: sent ready response to %s (device %s)",
            transaction_id,
            sender,
            from_device,
        )

    async def _on_key_verification(self, event: KeyVerificationStart | KeyVerificationCancel | KeyVerificationKey | KeyVerificationMac) -> None:
        """Handle SAS key verification events.

        Automatically accepts incoming verification requests, logs the SAS
        emoji to the console for operator visibility, and confirms the
        match so users can verify the bot from their Matrix client.
        """
        assert self._client is not None

        if isinstance(event, KeyVerificationStart):
            logger.info(
                "Verification request from %s (transaction %s, method %s)",
                event.sender,
                event.transaction_id,
                event.method,
            )

            if event.method != "m.sas.v1":
                logger.warning(
                    "Verification %s: unsupported method %s, ignoring",
                    event.transaction_id,
                    event.method,
                )
                return

            # Refresh device keys so nio knows about the requesting device
            # (otherwise it rejects the verification as "unknown device").
            try:
                self._client.users_for_key_query = {event.sender}
                await self._client.keys_query()
            except Exception:
                pass  # best-effort; proceed with accept attempt anyway

            try:
                resp = await self._client.accept_key_verification(event.transaction_id)
            except Exception as exc:
                logger.error(
                    "Verification %s: failed to accept (%s), device may be unknown",
                    event.transaction_id, exc,
                )
                return
            if hasattr(resp, "status_code") and resp.status_code != 200:
                logger.error("Failed to accept verification %s: %s", event.transaction_id, resp)
                return

            sas = self._client.key_verifications.get(event.transaction_id)
            if sas:
                resp = await self._client.to_device(sas.share_key())
                logger.info("Verification %s: accepted, shared key", event.transaction_id)

        elif isinstance(event, KeyVerificationCancel):
            logger.warning(
                "Verification %s cancelled by %s: %s",
                event.transaction_id,
                event.sender,
                getattr(event, "reason", "unknown"),
            )

        elif isinstance(event, KeyVerificationKey):
            sas = self._client.key_verifications.get(event.transaction_id)
            if sas is None:
                logger.warning("Verification %s: unknown transaction", event.transaction_id)
                return

            emoji = sas.get_emoji()
            emoji_display = "  ".join(f"{e} ({desc})" for e, desc in emoji)

            logger.info(
                "Verification %s — SAS emoji:\n"
                "┌─────────────────────────────────────────────────┐\n"
                "│  %s\n"
                "└─────────────────────────────────────────────────┘\n"
                "Auto-confirming match for %s",
                event.transaction_id,
                emoji_display,
                event.sender,
            )

            resp = await self._client.confirm_short_auth_string(event.transaction_id)
            if hasattr(resp, "status_code") and resp.status_code != 200:
                logger.error("Failed to confirm SAS for %s: %s", event.transaction_id, resp)

        elif isinstance(event, KeyVerificationMac):
            sas = self._client.key_verifications.get(event.transaction_id)
            if sas is None:
                logger.warning("Verification %s: unknown transaction at MAC stage", event.transaction_id)
                return

            try:
                # confirm_short_auth_string (called in the Key stage) already
                # sent our MAC.  When we receive theirs, nio verifies the
                # exchange.  If both MACs match, sas.verified becomes True.
                if sas.verified:
                    device = getattr(sas, "other_olm_device", None)
                    if device:
                        self._client.verify_device(device)
                    logger.info(
                        "Verification %s: complete — %s is now verified",
                        event.transaction_id,
                        event.sender,
                    )
                else:
                    logger.info(
                        "Verification %s: MAC received from %s, waiting for our side to complete",
                        event.transaction_id,
                        event.sender,
                    )

                # Send m.key.verification.done so the other client knows we're
                # finished (Element hangs without this).
                from nio.event_builders.direct_messages import ToDeviceMessage

                other_device = getattr(sas, "other_olm_device", None)
                recipient_device = other_device.id if other_device else "*"
                done_msg = ToDeviceMessage(
                    type="m.key.verification.done",
                    recipient=event.sender,
                    recipient_device=recipient_device,
                    content={"transaction_id": event.transaction_id},
                )
                await self._client.to_device(done_msg)
                logger.info("Verification %s: sent done to %s", event.transaction_id, event.sender)

            except Exception:
                logger.exception("Verification %s: MAC stage failed", event.transaction_id)

    def _should_dispatch(
        self, room: MatrixRoom, event: RoomMessageText, room_cfg: RoomConfig
    ) -> bool:
        """Determine whether this message should be forwarded to the gateway.

        DMs always dispatch. Group rooms respect the room's mode setting.
        """
        # Direct messages always pass
        if room.member_count <= 2:
            return True

        mode = room_cfg.mode

        if mode == "all":
            return True

        if mode == "mention":
            # Check for @mention of bot user in plain body, formatted body,
            # or the m.mentions spec field. Matrix clients put the display
            # name in the plain body but the real MXID in the HTML / mentions.
            user_id = self._config.user_id
            localpart = user_id.split(":")[0].lstrip("@")
            body = event.body or ""

            # For E2E-decrypted events, source.content has the encrypted
            # envelope. The decrypted content is on the event object itself.
            # Try event.source.content first (unencrypted), fall back to
            # the decrypted_event field used by matrix-nio for Megolm events.
            source = getattr(event, "source", {})
            content = source.get("content", {})
            # If content looks encrypted, try the decrypted source
            if content.get("algorithm") == "m.megolm.v1.aes-sha2":
                decrypted = getattr(event, "decrypted", True)
                content = source.get("decrypted", {}).get("content", {})
            formatted = content.get("formatted_body", "")
            mentions = content.get("m.mentions", {})

            # Also check the event's own formatted_body attribute (set by nio
            # after decryption regardless of source structure)
            event_formatted = getattr(event, "formatted_body", "") or ""

            logger.debug(
                "Mention check: user_id=%s localpart=%s body=%.80s "
                "formatted=%.80s event_formatted=%.80s mentions=%s",
                user_id,
                localpart,
                body,
                formatted,
                event_formatted,
                mentions,
            )

            if (
                user_id in body
                or localpart in body
                or user_id in formatted
                or user_id in event_formatted
                or user_id in mentions.get("user_ids", [])
            ):
                return True

            # Check for reply (relates_to with in_reply_to)
            relates = content.get("m.relates_to", {})
            if "m.in_reply_to" in relates:
                return True
            return False

        # Default: dispatch everything
        return True

    def _extract_thread_id(self, event: RoomMessageText) -> str | None:
        """Extract the thread root event ID from ``m.relates_to``, if present."""
        source = getattr(event, "source", {})
        relates = source.get("content", {}).get("m.relates_to", {})

        # MSC3440 threads
        if relates.get("rel_type") == "m.thread":
            return relates.get("event_id")

        # Reply chain — use the replied-to event as a pseudo-thread
        in_reply_to = relates.get("m.in_reply_to", {})
        if "event_id" in in_reply_to:
            return in_reply_to["event_id"]

        return None

    def _compute_trust(self, sender: str) -> dict[str, Any]:
        """Map sender identity + E2E status to a trust level."""
        if sender in self._config.trusted_users:
            return {"level": "verified", "sender": sender}
        return {"level": "unverified", "sender": sender}

    # ------------------------------------------------------------------
    # Message merging
    # ------------------------------------------------------------------

    async def _flush_merge_buffer(
        self,
        room_id: str,
        room_cfg: RoomConfig,
        thread_id: str | None,
        merge_window_ms: int,
    ) -> None:
        """Wait for the merge window then flush buffered messages."""
        try:
            await asyncio.sleep(merge_window_ms / 1000.0)
        except asyncio.CancelledError:
            return

        buf = self._merge_buffers.pop(room_id, [])
        self._merge_tasks.pop(room_id, None)

        if not buf:
            return

        # Merge messages from the same sender
        merged_parts: list[str] = []
        merged_images: list[dict[str, str]] = []
        primary_sender: str = buf[0][1]
        for _, sender, body, images in buf:
            if sender == primary_sender:
                if body:
                    merged_parts.append(body)
                merged_images.extend(images)
            else:
                # Different sender breaks the merge — only take the first batch
                break

        merged_content = "\n".join(merged_parts)
        trust = self._compute_trust(primary_sender)

        channel = {
            "platform": "matrix",
            "room_id": room_id,
        }

        msg = InboundMessage(
            agent_name=room_cfg.agent,
            content=merged_content,
            channel=channel,
            trust=trust,
            images=merged_images,
        )

        if self._on_message:
            logger.info(
                "Dispatching message to gateway: agent=%s content=%.80s",
                msg.agent_name,
                msg.content,
            )
            await self._on_message(msg)
        else:
            logger.warning("No on_message callback set — message dropped")

    # ------------------------------------------------------------------
    # Outbound: send to Matrix
    # ------------------------------------------------------------------

    async def send_text(
        self,
        channel: dict[str, Any],
        content: str,
        *,
        agent_name: str = "",
    ) -> None:
        """Send a text message, with rich formatting and chunking."""
        if not content or not content.strip():
            return

        assert self._client is not None
        room_id = channel.get("room_id", "")
        thread_id = channel.get("thread_id")

        # Prefix messages from non-main agents so the user can identify the source,
        # but skip when the agent is posting to its own configured room.
        room_cfg = self._rooms.get(room_id)
        is_own_room = room_cfg is not None and room_cfg.agent == agent_name
        if agent_name and agent_name != "main" and not is_own_room:
            content = f"({agent_name}) {content}"

        chunks = self.chunk_message(content)
        for chunk in chunks:
            html = markdown_to_matrix_html(chunk)
            msg_content: dict[str, Any] = {
                "msgtype": "m.text",
                "body": chunk,
                "format": "org.matrix.custom.html",
                "formatted_body": html,
            }

            # Thread support
            if thread_id:
                msg_content["m.relates_to"] = {
                    "rel_type": "m.thread",
                    "event_id": thread_id,
                }

            await self._room_send(room_id, "m.room.message", msg_content)

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
        """Send a formatted article message and track the event for reaction feedback."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        if not room_id:
            return

        markdown = f"**{title}** ({source})\n{summary}\n{url}"
        html = self.format_message(markdown)

        msg_content = {
            "msgtype": "m.text",
            "body": markdown,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }

        await self._room_send(room_id, "m.room.message", msg_content)

    async def send_listing(
        self,
        channel: dict[str, Any],
        title: str,
        url: str,
        price: str,
        location: str,
        *,
        agent_name: str = "",
    ) -> None:
        """Send a formatted listing message and track the event for reaction feedback."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        if not room_id:
            return

        parts = [f"**{title}**"]
        if price:
            parts.append(f"💰 {price}")
        if location:
            parts.append(f"📍 {location}")
        parts.append(url)
        markdown = "\n".join(parts)
        html = self.format_message(markdown)

        msg_content = {
            "msgtype": "m.text",
            "body": markdown,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }

        await self._room_send(room_id, "m.room.message", msg_content)

    async def send_typing(self, channel: dict[str, Any], is_typing: bool) -> None:
        """Set the typing indicator."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        await self._client.room_typing(room_id, typing_state=is_typing, timeout=30000)

    async def send_reaction(self, channel: dict[str, Any], emoji: str) -> None:
        """Send a reaction to the referenced message."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        event_id = channel.get("event_id", channel.get("thread_id", ""))
        if not event_id:
            logger.warning("Cannot send reaction — no event_id in channel")
            return

        content: dict[str, Any] = {
            "m.relates_to": {
                "rel_type": "m.annotation",
                "event_id": event_id,
                "key": emoji,
            }
        }
        await self._room_send(room_id, "m.reaction", content)

    async def edit_message(
        self, channel: dict[str, Any], message_id: str, new_content: str
    ) -> None:
        """Edit a previously sent message via m.new_content replacement."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        html = markdown_to_matrix_html(new_content)

        content: dict[str, Any] = {
            "msgtype": "m.text",
            "body": f"* {new_content}",
            "format": "org.matrix.custom.html",
            "formatted_body": f"* {html}",
            "m.new_content": {
                "msgtype": "m.text",
                "body": new_content,
                "format": "org.matrix.custom.html",
                "formatted_body": html,
            },
            "m.relates_to": {
                "rel_type": "m.replace",
                "event_id": message_id,
            },
        }
        await self._room_send(room_id, "m.room.message", content)

    async def delete_message(
        self, channel: dict[str, Any], message_id: str
    ) -> None:
        """Redact a previously sent message."""
        assert self._client is not None
        room_id = channel.get("room_id", "")
        await self._client.room_redact(room_id, message_id, reason="Deleted by agent")

    async def send_file(
        self,
        channel: dict[str, Any],
        file_data: bytes,
        filename: str,
        mime_type: str,
    ) -> None:
        """Upload a file to the content repository and send it."""
        assert self._client is not None
        room_id = channel.get("room_id", "")

        import io

        upload_resp, _maybe_keys = await self._client.upload(
            io.BytesIO(file_data),
            content_type=mime_type,
            filename=filename,
            filesize=len(file_data),
        )

        if not hasattr(upload_resp, "content_uri"):
            logger.error("File upload failed: %s", upload_resp)
            return

        content: dict[str, Any] = {
            "msgtype": "m.file",
            "body": filename,
            "url": upload_resp.content_uri,
            "info": {
                "mimetype": mime_type,
                "size": len(file_data),
            },
        }

        thread_id = channel.get("thread_id")
        if thread_id:
            content["m.relates_to"] = {
                "rel_type": "m.thread",
                "event_id": thread_id,
            }

        await self._room_send(room_id, "m.room.message", content)

    async def send_step(self, channel: dict[str, Any], step: AgentStepMessage) -> None:
        """Render an agent step as a formatted message if show_steps is enabled."""
        room_id = channel.get("room_id", "")
        room_cfg = self._rooms.get(room_id)
        if room_cfg is None:
            return

        # Result steps are gated by show_result; other steps by show_steps
        if step.step_type == "result":
            if not room_cfg.show_result:
                return
        elif not room_cfg.show_steps:
            return

        # In brief mode, suppress tool_result messages (keep tool_use only)
        if room_cfg.step_mode == "brief" and step.step_type == "tool_result":
            return

        text = self._format_step(step, mode=room_cfg.step_mode)
        if not text:
            return

        # Prefix step messages from non-main agents (skip in agent's own room)
        agent_name = step.agent_name
        is_own_room = room_cfg is not None and room_cfg.agent == agent_name
        if agent_name and agent_name != "main" and not is_own_room:
            text = f"({agent_name}) {text}"

        thread_id = channel.get("thread_id")
        html = markdown_to_matrix_html(text)
        msg_content: dict[str, Any] = {
            "msgtype": "m.notice",
            "body": text,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }
        if thread_id:
            msg_content["m.relates_to"] = {
                "rel_type": "m.thread",
                "event_id": thread_id,
            }

        await self._room_send(room_id, "m.room.message", msg_content)

    @staticmethod
    def _format_step(step: AgentStepMessage, mode: str = "brief") -> str:
        """Build a string for an agent step in the requested display mode.

        Modes:
          pretty  — full input as a JSON code block (default)
          brief   — one-liner with tool name and primary parameter
          raw     — raw JSON dump of all step fields
        """
        if mode == "raw":
            return MatrixAdapter._format_step_raw(step)
        if mode == "brief":
            return MatrixAdapter._format_step_brief(step)
        return MatrixAdapter._format_step_pretty(step)

    @staticmethod
    def _format_step_pretty(step: AgentStepMessage) -> str:
        """Pretty mode: tool name + full input as a JSON code block."""
        max_content = 500

        if step.step_type == "tool_use":
            line = f"\U0001f527 Using **{step.name}**"
            if step.input:
                raw = json.dumps(step.input, indent=2)
                if len(raw) > max_content:
                    raw = raw[:max_content] + "\u2026"
                line += f"\n```json\n{raw}\n```"
            return line

        if step.step_type == "tool_result":
            icon = "\u274c" if step.is_error else "\u2705"
            line = f"{icon} Result from **{step.name}**"
            if step.content:
                content = step.content
                if len(content) > max_content:
                    content = content[:max_content] + "\u2026"
                line += f"\n```\n{content}\n```"
            return line

        if step.step_type == "result":
            duration_s = step.duration_ms / 1000.0
            parts = ["\u2705 Done"]
            if step.num_turns:
                parts.append(f"{step.num_turns} turns")
            parts.append(f"{duration_s:.1f}s")
            if step.cost_usd:
                parts.append(f"${step.cost_usd:.3f}")
            return " \u2014 ".join(parts)

        return ""

    @staticmethod
    def _format_step_brief(step: AgentStepMessage) -> str:
        """Brief mode: one-liner with tool name and primary parameter."""
        if step.step_type == "tool_use":
            inp = step.input or {}
            name = step.name or ""
            detail = ""
            if name == "Read":
                detail = inp.get("file_path", "")
            elif name in ("Write", "Edit"):
                detail = inp.get("file_path", "")
            elif name == "Bash":
                detail = (inp.get("command") or inp.get("description") or "")[:80]
            elif name == "Glob":
                detail = inp.get("pattern", "")
            elif name == "Grep":
                detail = f"/{inp.get('pattern', '')}/"
            elif name == "WebFetch":
                detail = inp.get("url", "")
            elif name == "WebSearch":
                detail = inp.get("query", "")
            elif name == "Task":
                detail = (inp.get("description") or inp.get("prompt") or "")[:80]
            else:
                keys = list(inp.keys())
                if keys:
                    v = inp[keys[0]]
                    detail = str(v)[:80] if isinstance(v, str) else json.dumps(v)[:80]
            line = f"\U0001f527 {name}"
            if detail:
                line += f" \u2014 {detail}"
            return line

        if step.step_type == "tool_result":
            icon = "\u274c" if step.is_error else "\u2705"
            return f"{icon} **{step.name}**"

        if step.step_type == "result":
            duration_s = step.duration_ms / 1000.0
            parts = ["\u2705 Done"]
            if step.num_turns:
                parts.append(f"{step.num_turns} turns")
            parts.append(f"{duration_s:.1f}s")
            if step.cost_usd:
                parts.append(f"${step.cost_usd:.3f}")
            return " \u2014 ".join(parts)

        return ""

    @staticmethod
    def _format_step_raw(step: AgentStepMessage) -> str:
        """Raw mode: JSON dump of all step fields."""
        d: dict[str, Any] = {"step_type": step.step_type}
        if step.name:
            d["name"] = step.name
        if step.input:
            d["input"] = step.input
        if step.content:
            d["content"] = step.content[:500]
        if step.is_error:
            d["is_error"] = step.is_error
        if step.step_type == "result":
            d["num_turns"] = step.num_turns
            d["duration_ms"] = step.duration_ms
            d["cost_usd"] = step.cost_usd
        return f"```json\n{json.dumps(d, indent=2)}\n```"

    async def _on_reaction_event(self, room: MatrixRoom, event: ReactionEvent) -> None:
        """Handle typed m.reaction events (nio >= 0.24)."""
        if not self._initial_sync_done:
            return

        if event.sender == self._config.user_id:
            return

        target_event_id = event.reacts_to
        emoji = event.key

        if not target_event_id or not emoji:
            return

        logger.info(
            "Reaction %s from %s on event %s in %s",
            emoji,
            event.sender,
            target_event_id,
            room.room_id,
        )

        await self._dispatch_reaction(room.room_id, target_event_id, emoji, event.sender)

    async def _on_unknown_event(self, room: MatrixRoom, event: UnknownEvent) -> None:
        """Handle unknown events — fallback for m.reaction on older nio versions."""
        if not self._initial_sync_done:
            return

        source = getattr(event, "source", {})
        event_type = source.get("type", "")
        if event_type != "m.reaction":
            return

        sender = source.get("sender", "")
        if sender == self._config.user_id:
            return

        content = source.get("content", {})
        relates_to = content.get("m.relates_to", {})
        target_event_id = relates_to.get("event_id", "")
        emoji = relates_to.get("key", "")

        if not target_event_id or not emoji:
            return

        logger.info(
            "Reaction (UnknownEvent fallback) %s from %s on event %s in %s",
            emoji,
            sender,
            target_event_id,
            room.room_id,
        )

        await self._dispatch_reaction(room.room_id, target_event_id, emoji, sender)

    async def _dispatch_reaction(
        self, room_id: str, target_event_id: str, emoji: str, sender: str
    ) -> None:
        """Shared logic for dispatching a reaction from either event type."""
        trust = self._compute_trust(sender)

        # Check if this is an approval reaction
        approval_id = self._approval_events.get(target_event_id)
        if approval_id:
            msg = ReactionMessage(
                emoji=emoji,
                sender=sender,
                channel={"platform": "matrix", "room_id": room_id},
                approval_id=approval_id,
                event_id=target_event_id,
                trust=trust,
            )
            if self._on_reaction:
                await self._on_reaction(msg)
            return

        # Determine agent from room config
        room_cfg = self._rooms.get(room_id)
        if not room_cfg:
            logger.debug("Reaction in unconfigured room %s — ignoring", room_id)
            return

        agent_name = room_cfg.agent

        # Fetch the original event to verify sender and extract URL
        assert self._client is not None
        resp = await self._client.room_get_event(room_id, target_event_id)
        if not isinstance(resp, RoomGetEventResponse):
            logger.warning(
                "Failed to fetch event %s for reaction: %s", target_event_id, resp
            )
            return

        event = resp.event
        if getattr(event, "sender", None) != self._config.user_id:
            logger.debug("Reaction on non-bot event %s — ignoring", target_event_id)
            return

        # Extract item URL: last line of the message body (convention for
        # submitted items — send_article and send_listing always end with URL)
        item_url: str | None = None
        body = getattr(event, "body", "") or ""
        if body:
            last_line = body.strip().rsplit("\n", 1)[-1].strip()
            if last_line.startswith("http"):
                item_url = last_line

        channel = {"platform": "matrix", "room_id": room_id}
        msg = ReactionMessage(
            emoji=emoji,
            sender=sender,
            channel=channel,
            agent_name=agent_name,
            event_id=target_event_id,
            item_url=item_url,
            trust=trust,
        )
        if self._on_reaction:
            await self._on_reaction(msg)

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
        kind: str = "bcp",
    ) -> None:
        """Send an approval request to Matrix with attachment."""
        assert self._client is not None

        # Determine target room: use channel if provided, otherwise look up
        # approval_rooms config, otherwise skip
        if channel:
            room_id = channel.get("room_id", "")
        else:
            room_id = (
                self._config.approval_rooms.get(from_agent)
                or self._config.approval_rooms.get(to_agent)
                or self._config.approval_rooms.get("_default", "")
            )

        if not room_id:
            logger.warning(
                "No approval room configured for agent %s — skipping",
                from_agent,
            )
            return

        if kind == "action":
            body = (
                f"**Action Approval Required**\n"
                f"Agent: {from_agent}\n"
                f"{query_summary}\n\n"
                f"{response_content}\n\n"
                f"React with 👍 to approve or 👎 to reject."
            )
        else:
            # BCP Cat-N approval — upload review file first
            anomaly_text = ""
            if anomalies:
                anomaly_lines = []
                for a in anomalies:
                    msg_text = a.get("message", str(a))
                    anomaly_lines.append(f"  - {msg_text}")
                anomaly_text = "\nAnomalies:\n" + "\n".join(anomaly_lines) + "\n"

            file_content = (
                f"BCP Cat-{category} Review\n"
                f"{'=' * 40}\n"
                f"From: {from_agent}\n"
                f"To: {to_agent}\n"
                f"Approval ID: {approval_id}\n"
                f"\nQuery Directive:\n{query_summary}\n"
                f"\nResponse Content:\n{response_content}\n"
                f"{anomaly_text}"
            )

            filename = f"bcp-review-{approval_id[:8]}.txt"
            target_channel = {"platform": "matrix", "room_id": room_id}
            await self.send_file(
                target_channel,
                file_content.encode("utf-8"),
                filename,
                "text/plain",
            )

            body = (
                f"**BCP Cat-{category} Approval Required**\n"
                f"From: {from_agent} → To: {to_agent}\n"
                f"React with 👍 to approve or 👎 to reject."
            )

        html = markdown_to_matrix_html(body)
        msg_content: dict[str, Any] = {
            "msgtype": "m.text",
            "body": body,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }

        resp = await self._room_send(room_id, "m.room.message", msg_content)
        if resp:
            self._approval_events[resp.event_id] = approval_id
            logger.info(
                "Sent %s approval request %s to room %s (event %s)",
                kind,
                approval_id,
                room_id,
                resp.event_id,
            )

    async def health(self) -> dict[str, Any]:
        """Return adapter health status."""
        connected = self._client is not None and self._running
        return {
            "platform": "matrix",
            "connected": connected,
            "user_id": self._config.user_id,
            "rooms": list(self._rooms.keys()),
        }

    # ------------------------------------------------------------------
    # E2E device management
    # ------------------------------------------------------------------

    async def _delete_stale_devices(self) -> None:
        """Delete any device sessions that aren't our active device.

        Stale sessions (e.g. from logging into the bot account via Element)
        prevent other clients from sharing Megolm keys with us, because
        they see unverified sessions on the bot user.
        """
        assert self._client is not None
        resp = await self._client.devices()
        if hasattr(resp, "devices"):
            stale = [
                d.id for d in resp.devices
                if d.id != self._config.device_id
            ]
            if not stale:
                logger.debug("No stale device sessions found")
                return
            logger.info(
                "Deleting %d stale device session(s): %s",
                len(stale), ", ".join(stale),
            )
            del_resp = await self._client.delete_devices(stale)
            if isinstance(del_resp, DeleteDevicesAuthResponse):
                # Server requires UIA — retry with empty password auth
                del_resp = await self._client.delete_devices(
                    stale,
                    auth={
                        "type": "m.login.password",
                        "user": self._config.user_id,
                        "password": "",
                    },
                )
            if isinstance(del_resp, DeleteDevicesError):
                logger.warning(
                    "Failed to delete stale devices: %s", del_resp.message
                )
            else:
                logger.info("Deleted stale device sessions: %s", ", ".join(stale))
        else:
            logger.warning("Could not list devices: %s", resp)

    async def _trust_all_devices(self) -> None:
        """Mark all devices of members in configured rooms as trusted.

        For a bot, interactive verification (emoji/SAS) isn't practical.
        Instead we trust-on-first-use (TOFU) for all devices we see.
        This allows other clients to share Megolm session keys with us.
        """
        assert self._client is not None
        trusted_count = 0
        for room_id in self._rooms:
            room = self._client.rooms.get(room_id)
            if room is None:
                continue
            for user_id in room.users:
                devices = self._client.device_store.active_user_devices(user_id)
                for device in devices:
                    if not device.verified:
                        self._client.verify_device(device)
                        trusted_count += 1
                        logger.debug(
                            "Trusted device %s of %s", device.id, user_id
                        )
        if trusted_count:
            logger.info("Trusted %d device(s) across configured rooms", trusted_count)

    async def _demote_self_in_rooms(self) -> None:
        """Demote the bot to power level 0 in any joined room where it is admin,
        and leave rooms that are not in the config.

        The bot should not hold admin privileges — trusted users are the
        room administrators.  This runs after initial sync so the room
        state is available.
        """
        assert self._client is not None
        demoted = 0
        left = 0

        # Collect all room IDs the bot is currently in (plus heartbeat/approval rooms)
        configured_room_ids = set(self._rooms.keys())
        configured_room_ids.update(self._config.heartbeat_rooms.values())
        configured_room_ids.update(self._config.approval_rooms.values())

        for room_id, room in list(self._client.rooms.items()):
            my_level = room.power_levels.get_user_level(self._config.user_id)

            if room_id not in configured_room_ids:
                # Demote first if we have elevated privileges, then leave
                if my_level > 0:
                    await self._set_own_power_level(room_id, room, 0)
                try:
                    resp = await self._client.room_leave(room_id)
                    await self._client.room_forget(room_id)
                    left += 1
                    logger.info("Left unconfigured room %s", room_id)
                except Exception:
                    logger.warning("Could not leave room %s", room_id)
                continue

            # Configured room — demote if needed
            if my_level > 0:
                if await self._set_own_power_level(room_id, room, 0):
                    demoted += 1

        if demoted:
            logger.info("Demoted bot in %d room(s)", demoted)
        if left:
            logger.info("Left %d unconfigured room(s)", left)

    async def _set_own_power_level(self, room_id: str, room: MatrixRoom, level: int) -> bool:
        """Set the bot's power level in a room. Returns True on success."""
        assert self._client is not None
        pl = room.power_levels
        old_level = pl.get_user_level(self._config.user_id)

        users = dict(pl.users)
        users[self._config.user_id] = level

        content: dict[str, Any] = {
            "users": users,
            "users_default": pl.defaults.users_default,
            "events_default": pl.defaults.events_default,
            "state_default": pl.defaults.state_default,
            "ban": pl.defaults.ban,
            "kick": pl.defaults.kick,
            "redact": pl.defaults.redact,
            "invite": pl.defaults.invite,
            "events": dict(pl.events),
        }
        if hasattr(pl.defaults, "notifications") and pl.defaults.notifications:
            content["notifications"] = pl.defaults.notifications

        try:
            resp = await self._client.room_put_state(
                room_id, "m.room.power_levels", content,
            )
            if hasattr(resp, "event_id"):
                logger.info(
                    "Set bot power level from %d to %d in room %s",
                    old_level, level, room_id,
                )
                return True
            logger.warning("Failed to set power level in room %s: %s", room_id, resp)
        except Exception:
            logger.warning("Could not set power level in room %s (may lack permission)", room_id)
        return False

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    async def _resolve_rooms(self) -> None:
        """Resolve room aliases in the config to room IDs, creating rooms that don't exist."""
        assert self._client is not None
        resolved: dict[str, RoomConfig] = {}
        created_rooms: dict[str, str] = {}  # alias -> room_id for config update

        for room_ref, room_cfg in self._rooms.items():
            if room_ref.startswith("#"):
                resp = await self._client.room_resolve_alias(room_ref)
                if hasattr(resp, "room_id") and resp.room_id in self._client.rooms:
                    logger.info("Resolved alias %s -> %s", room_ref, resp.room_id)
                    resolved[resp.room_id] = room_cfg
                    created_rooms[room_ref] = resp.room_id
                else:
                    if hasattr(resp, "room_id"):
                        logger.warning(
                            "Alias %s resolved to %s but bot is not a member — "
                            "creating a new room (without alias)",
                            room_ref,
                            resp.room_id,
                        )
                    else:
                        logger.info(
                            "Room alias %s does not exist, creating room for agent '%s'",
                            room_ref,
                            room_cfg.agent,
                        )
                    alias_taken = hasattr(resp, "room_id")
                    room_id = await self._create_room(
                        room_ref, room_cfg, skip_alias=alias_taken,
                    )
                    if room_id:
                        resolved[room_id] = room_cfg
                        created_rooms[room_ref] = room_id
                    else:
                        logger.error("Failed to create room for alias %s", room_ref)
            else:
                resolved[room_ref] = room_cfg

        self._rooms = resolved

        if created_rooms:
            self._save_created_rooms_to_config(created_rooms)

    async def _create_room(
        self, alias: str, room_cfg: RoomConfig, *, skip_alias: bool = False,
    ) -> str | None:
        """Create an encrypted Matrix room.

        Invites trusted users and grants them admin (power level 100).
        If *skip_alias* is True, the alias is already taken on the server
        so the room is created without one.
        Returns the new room_id or None on failure.
        """
        assert self._client is not None

        # Extract localpart from alias (e.g. "#agent-name:server" -> "agent-name")
        localpart = alias.split(":")[0].lstrip("#")

        # Build the room name: "<Instance> <agent>" or just "<agent>"
        agent_label = room_cfg.agent or localpart
        room_name = f"{self._instance_name} {agent_label}" if self._instance_name else agent_label

        # Power level override: trusted users get admin (100), bot starts at 100
        # (required to apply initial_state) and is demoted to 0 after creation.
        power_levels = {
            "users": {self._config.user_id: 100},
            "users_default": 0,
            "events_default": 0,
            "state_default": 50,
            "ban": 50,
            "kick": 50,
            "redact": 50,
            "invite": 0,
        }
        for user_id in self._config.trusted_users:
            power_levels["users"][user_id] = 100

        initial_state = [
            # Enable E2E encryption
            {
                "type": "m.room.encryption",
                "state_key": "",
                "content": {"algorithm": "m.megolm.v1.aes-sha2"},
            },
            # Set power levels
            {
                "type": "m.room.power_levels",
                "state_key": "",
                "content": power_levels,
            },
        ]

        try:
            create_kwargs: dict[str, Any] = {
                "name": room_name,
                "topic": f"TriOnyx agent: {room_cfg.agent}",
                "invite": list(self._config.trusted_users),
                "initial_state": initial_state,
            }
            if not skip_alias:
                create_kwargs["alias"] = localpart

            resp = await self._client.room_create(**create_kwargs)
        except Exception:
            logger.exception("Failed to create room %s", alias)
            return None

        if hasattr(resp, "room_id"):
            logger.info(
                "Created room %s (alias=%s) for agent '%s', invited %d user(s)",
                resp.room_id,
                alias,
                room_cfg.agent,
                len(self._config.trusted_users),
            )
            # Demote bot to power level 0 — trusted users are the admins
            await self._demote_in_new_room(resp.room_id, power_levels)
            return resp.room_id

        logger.error("room_create failed for %s: %s", alias, resp)
        return None

    async def _demote_in_new_room(
        self, room_id: str, power_levels: dict[str, Any],
    ) -> None:
        """Demote the bot to power level 0 in a freshly created room."""
        assert self._client is not None
        users = dict(power_levels["users"])
        users[self._config.user_id] = 0
        content = dict(power_levels)
        content["users"] = users
        try:
            resp = await self._client.room_put_state(
                room_id, "m.room.power_levels", content,
            )
            if hasattr(resp, "event_id"):
                logger.info("Demoted bot to power level 0 in new room %s", room_id)
            else:
                logger.warning("Failed to demote bot in new room %s: %s", room_id, resp)
        except Exception:
            logger.warning("Could not demote bot in new room %s", room_id)

    def _save_created_rooms_to_config(self, created_rooms: dict[str, str]) -> None:
        """Update the YAML config file, replacing aliases with resolved room IDs."""
        if not self._config_path:
            logger.warning("No config_path set — cannot persist created rooms")
            return

        from pathlib import Path

        import yaml

        config_file = Path(self._config_path)
        if not config_file.exists():
            logger.warning("Config file %s not found — cannot persist rooms", self._config_path)
            return

        try:
            raw = yaml.safe_load(config_file.read_text())
        except Exception:
            logger.exception("Failed to read config file for room persistence")
            return

        adapter_section = raw.get("adapters", {}).get(self._adapter_name, {})
        rooms_section = adapter_section.get("rooms", {})

        for alias, room_id in created_rooms.items():
            if alias in rooms_section:
                rooms_section[room_id] = rooms_section.pop(alias)
                logger.info("Config: replaced alias %s with room_id %s", alias, room_id)

        try:
            config_file.write_text(yaml.safe_dump(raw, default_flow_style=False, sort_keys=False))
            logger.info("Saved %d created room(s) to config file", len(created_rooms))
        except Exception:
            logger.exception("Failed to write updated config file")

    async def _room_send(
        self, room_id: str, event_type: str, content: dict[str, Any]
    ) -> RoomSendResponse | None:
        """Send an event to a room with basic rate-limit handling."""
        assert self._client is not None
        backoff = 1.0
        for attempt in range(5):
            resp = await self._client.room_send(
                room_id=room_id,
                message_type=event_type,
                content=content,
            )
            if isinstance(resp, RoomSendResponse):
                self._own_event_ids.add(resp.event_id)
                # Cap the tracking set to avoid unbounded growth
                if len(self._own_event_ids) > 500:
                    # Trim to ~250 entries to avoid unbounded growth.
                    # Sets are unordered, so the kept entries are arbitrary —
                    # acceptable since this is only used to filter self-echo.
                    self._own_event_ids = set(list(self._own_event_ids)[250:])
                return resp

            # Check for rate limiting (429)
            error_code = getattr(resp, "status_code", None)
            if error_code == 429 or "M_LIMIT_EXCEEDED" in str(resp):
                retry_after_ms = getattr(resp, "retry_after_ms", backoff * 1000)
                wait = retry_after_ms / 1000.0
                logger.warning(
                    "Rate limited on room_send (attempt %d), waiting %.1fs",
                    attempt + 1,
                    wait,
                )
                await asyncio.sleep(wait)
                backoff *= 2
            else:
                logger.error("room_send failed: %s", resp)
                return None

        logger.error("room_send exhausted retries for room %s", room_id)
        return None
