"""Native Matrix transport. No agent, model, shell commands or public control API."""
import asyncio
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import signal
import sqlite3
import sys
from pathlib import Path

from aiohttp import web
from nio import (AsyncClient, AsyncClientConfig, MegolmEvent, RoomMessage, RoomMessageText,
                 RoomSendResponse, RoomTypingResponse, RoomReadMarkersResponse, RoomRedactResponse, SyncResponse)

ROOT = Path.home() / "Library/Application Support/Indexa"


def read_credentials(stream):
    data = stream.read(16385)
    if len(data) > 16384:
        raise ValueError("credential_frame_too_large")
    values = json.loads(data)
    expected = {"matrix-transport-key", "matrix-bot-token", "matrix-pickle-key"}
    if not isinstance(values, dict) or set(values) not in (expected, expected | {"matrix-owner-token", "matrix-owner-pickle"}):
        raise ValueError("unexpected_credential_names")
    if not all(isinstance(value, str) and 16 <= len(value) <= 4096 for value in values.values()):
        raise ValueError("invalid_credential_frame")
    return values


class Journal:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.executescript("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS inbox(id TEXT PRIMARY KEY, payload TEXT, ack INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY,digest TEXT NOT NULL,event TEXT);
            CREATE TABLE IF NOT EXISTS feedback(id TEXT PRIMARY KEY,state TEXT NOT NULL,revision INTEGER DEFAULT 1,
                sent_revision INTEGER DEFAULT 0,event_id TEXT,old_event TEXT,read_sent INTEGER DEFAULT 0);
        """)

    def accept(self, event):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO inbox(id,payload) VALUES(?,?)", (event["id"], json.dumps(event)))

    def known(self, event):
        return self.db.execute("SELECT 1 FROM inbox WHERE id=?", (event,)).fetchone() is not None

    def queue_feedback(self, event, state):
        if not self.known(event):
            raise ValueError("unknown_event")
        previous = self.db.execute("SELECT state FROM feedback WHERE id=?", (event,)).fetchone()
        if previous and (previous[0] == state or state == "accepted" or
                         previous[0] in {"completed", "failed", "cancelled"}):
            return
        with self.db:
            self.db.execute("""INSERT INTO feedback(id,state) VALUES(?,?) ON CONFLICT(id)
                DO UPDATE SET state=excluded.state,revision=revision+1""", (event, state))

    def pending(self):
        return [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM inbox WHERE ack=0 ORDER BY rowid LIMIT 50")]

    def ack(self, event):
        with self.db:
            self.db.execute("UPDATE inbox SET ack=1,payload=NULL WHERE id=?", (event,))

    def get(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def put(self, key, value):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (key, value))

    def delivery(self, txn, digest):
        row = self.db.execute("SELECT digest,event FROM deliveries WHERE id=?", (txn,)).fetchone()
        if row and row[0] != digest:
            raise ValueError("transaction_payload_conflict")
        return row[1] if row else None

    def sent(self, txn, digest, event):
        self.delivery(txn, digest)
        with self.db:
            self.db.execute("INSERT INTO deliveries VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET event=excluded.event", (txn, digest, event))


class Transport:
    def __init__(self, config, directory, credentials):
        self.config = config
        self.key = credentials["matrix-transport-key"]
        self.journal = Journal(directory / "transport.sqlite")
        token = credentials["matrix-bot-token"]
        identity = hashlib.sha256(token.encode()).hexdigest()
        previous = self.journal.get("token_identity")
        if previous and previous != identity:
            raise RuntimeError("matrix_token_changed_manual_recovery_required")
        self.journal.put("token_identity", identity)
        self.client = AsyncClient(
            "http://127.0.0.1:18763", config["bot_user"], device_id=config["device_id"], store_path=str(directory),
            config=AsyncClientConfig(encryption_enabled=True, pickle_key=credentials["matrix-pickle-key"],
                                     store_sync_tokens=False, max_limit_exceeded=2, max_timeouts=1),
        )
        self.client.restore_login(config["bot_user"], config["device_id"], token)
        self.client.add_event_callback(self.message, (RoomMessage, MegolmEvent))
        self.media_root = directory / "attachments"
        for folder in ("incoming", "outgoing"):
            (self.media_root / folder).mkdir(parents=True, exist_ok=True, mode=0o700)
        self.ready = False
        self.problem = "connecting"
        self.undecrypted = set()
        self.send_lock = asyncio.Lock()
        self.inbox_changed = asyncio.Event()

    async def message(self, room, event):
        if room.room_id != self.config["room_id"] or event.sender != self.config["owner_user"]:
            return
        if isinstance(event, MegolmEvent):
            self.undecrypted.add(event.event_id)
            await self.client.request_room_key(event)
            return
        if not event.decrypted or not room.encrypted:
            self.problem = "unencrypted_owner_message_rejected"
            return
        self.undecrypted.discard(event.event_id)
        if event.source.get("content", {}).get("m.relates_to", {}).get("rel_type") == "m.replace":
            return
        if self.journal.known(event.event_id):
            return
        body = event.source.get("content", {}).get("body")
        text = body.strip() if isinstance(body, str) else ""
        if not text and not isinstance(event, RoomMessageText):
            text = "Załącznik"
        if not text or len(text.encode()) > 16384:
            self.problem = "invalid_message_size"
            return
        payload = {"id": event.event_id, "room": room.room_id, "sender": event.sender,
                   "text": text, "timestamp": event.server_timestamp / 1000}
        if not isinstance(event, RoomMessageText):
            from media import download
            try:
                attachment = await download(self.client, self.media_root, event,
                                            self.config["bot_user"].split(":", 1)[1])
                payload["attachments"] = [attachment]
            except ValueError as error:
                payload["attachment_error"] = str(error)
        self.journal.accept(payload)
        self.inbox_changed.set()

    async def sync(self):
        first = True
        failures = 0
        while True:
            try:
                since = self.journal.get("sync_token")
                # On restart nio must process full_state even if the server's token is unchanged.
                # The durable cursor still goes in `since`; clearing this local dedupe marker loses no backlog.
                self.client.next_batch = "" if first else (since or "")
                response = await self.client.sync(timeout=0 if first else 30000, since=since,
                    full_state=first, set_presence="offline",
                    sync_filter={"room": {"rooms": [self.config["room_id"]], "timeline": {"limit": 1000}}})
                if not isinstance(response, SyncResponse):
                    raise RuntimeError("matrix_sync_failed")
                if self.client.should_upload_keys:
                    await self.client.keys_upload()
                if self.client.should_query_keys:
                    await self.client.keys_query()
                if self.client.should_claim_keys:
                    await self.client.keys_claim(self.client.get_users_for_key_claiming())
                await self.client.send_to_device_messages()
                joined = response.rooms.join.get(self.config["room_id"])
                if joined and joined.timeline.limited:
                    # Do not silently skip an offline backlog; keep its cursor for explicit recovery.
                    self.problem = "matrix_timeline_gap_requires_review"
                    self.ready = False
                    # Keep syncing keys/health without losing the saved cursor.
                    first = True
                    await asyncio.sleep(30)
                    continue
                if self.undecrypted:
                    self.problem = "matrix_missing_room_keys"
                    self.ready = False
                    # Persist ciphertext backlog IDs across restart; never acknowledge an undecrypted command.
                    self.journal.put("undecrypted", json.dumps(sorted(self.undecrypted)))
                    await asyncio.sleep(5)
                else:
                    self.journal.put("sync_token", response.next_batch)
                    self.journal.put("undecrypted", "[]")
                    self.ready = self.config["room_id"] in self.client.rooms
                    self.problem = ""
                first = False
                failures = 0
                await asyncio.sleep(0.1)
            except asyncio.CancelledError:
                raise
            except Exception:
                self.ready = False
                self.problem = "matrix_connection_failed"
                first = True
                failures = min(failures + 1, 5)
                await asyncio.sleep(min(30, 2 ** failures))

    @web.middleware
    async def authenticate(self, request, handler):
        if not hmac.compare_digest(request.headers.get("Authorization", ""), "Bearer " + self.key):
            raise web.HTTPUnauthorized()
        return await handler(request)

    async def health(self, request):
        return web.json_response({"ready": self.ready, "problem": self.problem, **self.config})

    async def events(self, request):
        self.inbox_changed.clear()
        if not self.journal.pending():
            try:
                await asyncio.wait_for(self.inbox_changed.wait(), timeout=10)
            except asyncio.TimeoutError:
                pass
        return web.json_response({"events": self.journal.pending()})

    async def ack(self, request):
        data = await request.json()
        if not isinstance(data.get("id"), str):
            raise web.HTTPBadRequest()
        if self.journal.known(data["id"]):
            self.journal.queue_feedback(data["id"], "accepted")
            self.journal.ack(data["id"])
        return web.json_response({"ok": True})

    async def send(self, request):
        data = await request.json()
        if not isinstance(data, dict):
            raise web.HTTPBadRequest()
        txn, text = data.get("id"), data.get("text")
        if (data.get("room") != self.config["room_id"] or not isinstance(txn, str) or
            not 0 < len(txn) <= 128 or not isinstance(text, str) or not 0 < len(text.encode()) <= 20000):
            raise web.HTTPBadRequest()
        media_data = None
        if "attachment" in data:
            from media import outgoing
            try:
                media_data = outgoing(self.media_root, data["attachment"])
            except (ValueError, OSError):
                raise web.HTTPBadRequest(reason="invalid_attachment") from None
        digest = hashlib.sha256(text.encode()).hexdigest()
        if media_data is not None:
            binary, name, mime = media_data
            digest = hashlib.sha256(json.dumps([text, name, mime,
                hashlib.sha256(binary).hexdigest()], ensure_ascii=True).encode()).hexdigest()
        async with self.send_lock:
            try:
                existing = self.journal.delivery(txn, digest)
            except ValueError:
                raise web.HTTPConflict()
            if existing:
                return web.json_response({"event_id": existing})
            room = self.client.rooms.get(self.config["room_id"])
            if not self.ready or not room or not room.encrypted:
                return web.json_response({"error": "matrix_not_ready", "sent": False}, status=503)
            self.journal.sent(txn, digest, None)
            try:
                content = {"msgtype": "m.text", "body": text}
                if media_data is not None:
                    from media import upload
                    cache_key = "uploaded:" + txn
                    saved = self.journal.get(cache_key)
                    if saved:
                        content = json.loads(saved)
                    else:
                        content = await upload(self.client, *media_data)
                        # Matrix filename remains separate from a human readable caption.
                        content["body"] = text
                        self.journal.put(cache_key, json.dumps(content))
                response = await self.client.room_send(room.room_id, "m.room.message",
                    content, tx_id=txn, ignore_unverified_devices=False)
            except Exception:
                self.problem = "matrix_send_or_device_verification_failed"
                raise web.HTTPServiceUnavailable()
            if not isinstance(response, RoomSendResponse):
                raise web.HTTPBadGateway()
            self.journal.sent(txn, digest, response.event_id)
            return web.json_response({"event_id": response.event_id})

    async def feedback(self, request):
        data = await request.json()
        states = {"accepted", "running", "waiting_for_approval", "needs_review", "completed", "failed", "cancelled"}
        if (not isinstance(data, dict) or set(data) != {"id", "state"} or
            not isinstance(data["id"], str) or not isinstance(data["state"], str) or data["state"] not in states):
            raise web.HTTPBadRequest()
        try:
            self.journal.queue_feedback(data["id"], data["state"])
        except ValueError:
            raise web.HTTPNotFound() from None
        return web.json_response({"ok": True})

    async def flush_feedback(self):
        room = self.client.rooms.get(self.config["room_id"])
        if not self.ready or not room or not room.encrypted:
            return
        rows = self.journal.db.execute("""SELECT id,state,revision,sent_revision,event_id,old_event,read_sent
            FROM feedback WHERE revision!=sent_revision OR old_event IS NOT NULL OR read_sent=0 LIMIT 20""").fetchall()
        icons = {"accepted": "📥", "running": "⏳", "waiting_for_approval": "✋", "needs_review": "⚠️",
                 "completed": "✅", "failed": "❌", "cancelled": "⏹️"}
        for event, state, revision, sent_revision, previous, old_event, read_sent in rows:
            txn = "feedback-" + hashlib.sha256(event.encode()).hexdigest()
            if not read_sent:
                response = await asyncio.wait_for(self.client.room_read_markers(
                    room.room_id, event, read_event=event), 10)
                if not isinstance(response, RoomReadMarkersResponse):
                    raise RuntimeError("receipt_failed")
                with self.journal.db:
                    self.journal.db.execute("UPDATE feedback SET read_sent=1 WHERE id=?", (event,))
            if old_event:
                response = await asyncio.wait_for(self.client.room_redact(room.room_id, old_event,
                    tx_id=txn + "-redact-" + hashlib.sha256(old_event.encode()).hexdigest()[:16]), 10)
                if not isinstance(response, RoomRedactResponse):
                    raise RuntimeError("reaction_redact_failed")
                with self.journal.db:
                    self.journal.db.execute("UPDATE feedback SET old_event=NULL WHERE id=?", (event,))
            if revision != sent_revision:
                response = await asyncio.wait_for(self.client.room_send(room.room_id, "m.reaction",
                    {"m.relates_to": {"rel_type": "m.annotation", "event_id": event, "key": icons[state]}},
                    tx_id=txn + "-" + str(revision), ignore_unverified_devices=False), 10)
                if not isinstance(response, RoomSendResponse):
                    raise RuntimeError("reaction_failed")
                with self.journal.db:
                    self.journal.db.execute("""UPDATE feedback SET sent_revision=?,event_id=?,old_event=?
                        WHERE id=?""", (revision, response.event_id, previous, event))

    async def feedback_loop(self):
        while True:
            try:
                await self.flush_feedback()
            except asyncio.CancelledError:
                raise
            except Exception:
                pass  # Durable feedback retries independently; never hold up command delivery.
            await asyncio.sleep(3)

    async def typing(self, request):
        data = await request.json()
        if not isinstance(data, dict) or set(data) != {"typing"} or type(data["typing"]) is not bool:
            raise web.HTTPBadRequest()
        if data["typing"] and not self.ready:
            raise web.HTTPServiceUnavailable()
        # Fixed private room; a short lease clears the indicator even after a crash.
        response = await asyncio.wait_for(self.client.room_typing(
            self.config["room_id"], typing_state=data["typing"], timeout=25000), 5)
        if not isinstance(response, RoomTypingResponse):
            raise web.HTTPBadGateway()
        return web.json_response({"ok": True})

    async def devices(self, request):
        owner = self.config["owner_user"]
        devices = self.client.device_store.active_user_devices(owner)
        return web.json_response({"devices": [{"id": d.device_id, "key": d.ed25519,
            "name": d.display_name or d.device_id, "verified": d.verified} for d in devices]})

    async def trust(self, request):
        data = await request.json()
        device = self.client.device_store[self.config["owner_user"]].get(data.get("id"))
        if not device or not hmac.compare_digest(device.ed25519, data.get("key", "")):
            raise web.HTTPConflict()
        self.client.verify_device(device)
        return web.json_response({"ok": True})

    async def trust_signed_devices(self, devices):
        if not isinstance(devices, list) or not 1 <= len(devices) <= 10:
            raise ValueError("invalid_verified_devices")
        owner = self.config["owner_user"]
        self.client.users_for_key_query.add(owner)
        await self.client.keys_query()
        checked = []
        for item in devices:
            device = self.client.device_store[owner].get(item.get("id"))
            if not device or not isinstance(item.get("key"), str) or not hmac.compare_digest(device.ed25519, item["key"]):
                raise ValueError("verified_device_key_mismatch")
            checked.append(device)
        for device in checked:
            self.client.verify_device(device)


async def main():
    from qr_session import QRSession
    os.umask(0o077)
    credentials = read_credentials(sys.stdin.buffer)
    directory = ROOT / "matrix"
    lock = (directory / "service.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    config = json.loads((ROOT / "matrix.json").read_text())
    transport = Transport(config, directory, credentials)
    qr = QRSession(ROOT, config, {key:value for key,value in credentials.items() if key in {"matrix-owner-token", "matrix-owner-pickle"}}, transport)
    credentials.clear()
    from logging.handlers import RotatingFileHandler
    from native_services import NativeServices
    log = None
    log_task = None
    services = None
    if config.get("qr_enabled"):
        services = NativeServices(ROOT)
        await services.start()
        servers = services.children
    else:
        log = RotatingFileHandler(directory / "server.log", maxBytes=2*1024*1024, backupCount=2, encoding="utf-8")
        servers = [await asyncio.create_subprocess_exec(sys.executable, "-m", "synapse.app.homeserver",
            "-c", str(directory / "homeserver.yaml"), "-c", str(ROOT / "matrix-media-limits.yaml"), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)]
        log_task = asyncio.create_task(NativeServices.collect_log(servers[0].stdout, log))
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, stop.set)
    transport.undecrypted = set(json.loads(transport.journal.get("undecrypted") or "[]"))
    app = web.Application(middlewares=[transport.authenticate], client_max_size=32768)
    app.add_routes([web.get("/health", transport.health), web.get("/events", transport.events),
                    web.post("/ack", transport.ack), web.post("/send", transport.send), web.post("/typing", transport.typing), web.post("/feedback", transport.feedback),
                    web.get("/devices", transport.devices), web.post("/trust", transport.trust),
                    web.post("/qr/start", qr.start), web.get("/qr/status", qr.status), web.post("/qr/command", qr.command)])
    runner = web.AppRunner(app, access_log=None)
    sync_task = None
    feedback_task = None
    try:
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", 18764).start()
        sync_task = asyncio.create_task(transport.sync())
        feedback_task = asyncio.create_task(transport.feedback_loop())
        waiter = asyncio.create_task(stop.wait())
        server_waiters = [asyncio.create_task(server.wait()) for server in servers]
        await asyncio.wait([waiter, *server_waiters], return_when=asyncio.FIRST_COMPLETED)
        waiter.cancel()
    finally:
        await qr.stop()
        if feedback_task:
            feedback_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await feedback_task
        if sync_task:
            sync_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sync_task
        await runner.cleanup()
        await transport.client.close()
        if services:
            await services.stop()
        else:
            for server in servers:
                if server.returncode is None:
                    server.terminate()
                    try:
                        await asyncio.wait_for(server.wait(), 15)
                    except asyncio.TimeoutError:
                        server.kill()
                        await server.wait()
        if log_task:
            await log_task
        if log:
            log.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        print("matrix_service_failed:" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
