"""Offline regression checks: encrypted media, limits, owner gate and durable feedback."""
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "matrix"))
import media
import service
from nio import RoomEncryptedImage, RoomMessageUnknown, RoomMessageText, RoomReadMarkersResponse, RoomRedactResponse, RoomSendResponse, UploadResponse
from nio.crypto.attachments import encrypt_attachment


class Request:
    def __init__(self, data): self.data = data
    async def json(self): return self.data


async def check():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "outgoing").mkdir()
        file = root / "outgoing/report.txt"
        file.write_bytes(b"Synthetic private report")
        assert media.outgoing(root, {"path": str(file)}) == (file.read_bytes(), "report.txt", "text/plain")
        secret = root / "outside.txt"
        secret.write_text("not authorized")
        link = root / "outgoing/link.txt"
        link.symlink_to(secret)
        hardlink = root / "outgoing/hardlink.txt"
        os.link(secret, hardlink)
        for bad in (secret, link, hardlink):
            try: media.outgoing(root, {"path": str(bad)})
            except ValueError: pass
            else: raise AssertionError("Unstaged/symlink/hardlink attachment accepted")
        with patch.object(media, "MAX_BYTES", 4):
            try: media.outgoing(root, {"path": str(file)})
            except ValueError as error: assert str(error) == "attachment_too_large"
            else: raise AssertionError("Oversized staged file accepted")

        ciphertext, encryption = encrypt_attachment(b"synthetic image")
        content = {"msgtype": "m.image", "body": "../../photo.png", "info": {"mimetype": "image/png"},
                   "file": {**encryption, "url": "mxc://test/synthetic_id"}}
        raw = {"type": "m.room.message", "event_id": "$photo", "sender": "@owner:test", "origin_server_ts": 1000, "content": content}
        event = RoomEncryptedImage.from_dict(raw)
        event.decrypted = True
        assert isinstance(event, RoomEncryptedImage)
        downloads = []
        class Response:
            status = 200
            content_length = None  # The malicious sender/server can't bypass the actual byte cap.
            @property
            def content(self): return self
            async def iter_chunked(self, size):
                yield ciphertext[:3]
                yield ciphertext[3:]
            def raise_for_status(self): pass
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
        class Session:
            def __init__(self, **kwargs): pass
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            def get(self, url, **kwargs):
                assert url.startswith("http://127.0.0.1:18763/_matrix/client/v1/media/download/test/")
                assert kwargs["params"] == {"allow_remote": "false"} and not kwargs["allow_redirects"]
                downloads.append(url)
                return Response()
        client = SimpleNamespace(homeserver="http://127.0.0.1:18763", access_token="synthetic-token")
        with patch.object(media.aiohttp, "ClientSession", Session):
            result = await media.download(client, root, event, "test")
            saved = Path(result["path"])
            assert result["name"] == "photo.png" and saved.read_bytes() == b"synthetic image"
            assert saved.stat().st_mode & 0o777 == 0o600
            with patch.object(media, "MAX_BYTES", 4):
                try: await media.download(client, root, event, "test")
                except ValueError as error: assert str(error) == "attachment_too_large"
                else: raise AssertionError("Stream exceeded byte limit")
            encryption["hashes"]["sha256"] = "a" * 43
            try: await media.download(client, root, event, "test")
            except ValueError as error: assert str(error) == "attachment_integrity_failed"
            else: raise AssertionError("Tampered encrypted media accepted")
            for uri in ("https://example.org/private", "mxc://elsewhere/id", "mxc://test/../private"):
                content["file"]["url"] = uri
                try: await media.download(client, root, event, "test")
                except ValueError as error: assert str(error) == "invalid_attachment_source"
                else: raise AssertionError("Arbitrary media source accepted")
        async def upload(stream, **kwargs):
            assert stream.read() == file.read_bytes()
            assert kwargs["encrypt"] is True and kwargs["content_type"] == "application/octet-stream"
            return UploadResponse("mxc://test/output"), {"key": {"k": "fake"}, "v": "v2"}
        client.upload = upload
        uploaded = await media.upload(client, file.read_bytes(), file.name, "text/plain")
        assert uploaded["file"]["url"] == "mxc://test/output" and "url" not in uploaded

        transport = service.Transport.__new__(service.Transport)
        transport.config = {"room_id": "!private:test", "owner_user": "@owner:test", "bot_user": "@bot:test"}
        transport.ready, transport.undecrypted, transport.problem = True, set(), ""
        transport.journal = service.Journal(root / "journal.sqlite")
        transport.media_root, transport.send_lock = root, asyncio.Lock()
        transport.inbox_changed = asyncio.Event()
        room = SimpleNamespace(room_id="!private:test", encrypted=True)
        sent, redacted, receipts = [], [], []
        async def markers(room_id, event_id, **kwargs):
            receipts.append(event_id)
            return RoomReadMarkersResponse(room_id)
        async def room_send(room_id, event_type, body, **kwargs):
            sent.append((event_type, body, kwargs))
            return RoomSendResponse("$sent" + str(len(sent)), room_id)
        async def redact(room_id, event_id, **kwargs):
            redacted.append(event_id)
            return RoomRedactResponse("$redaction", room_id)
        transport.client = SimpleNamespace(rooms={room.room_id: room}, room_read_markers=markers,
                                           room_send=room_send, room_redact=redact, upload=upload)
        event.sender = "@other:test"
        await transport.message(room, event)
        assert transport.journal.pending() == []
        event.sender = "@owner:test"
        event.decrypted = False
        await transport.message(room, event)
        assert transport.journal.pending() == []
        event.decrypted = True
        unknown = RoomMessageUnknown.from_dict({**raw, "event_id": "$custom", "content": {"msgtype": "org.example.custom"}})
        unknown.decrypted = True
        await transport.message(room, unknown)
        assert transport.journal.pending()[0]["attachment_error"] == "unsupported_attachment_type"
        transport.journal.ack("$custom")
        # Source is deliberately invalid: poison media is journalled as explicit error, never silently lost.
        await transport.message(room, event)
        pending = transport.journal.pending()
        assert pending[0]["attachment_error"] == "invalid_attachment_source"
        await transport.ack(Request({"id": "$photo"}))
        assert transport.journal.pending() == []
        await transport.flush_feedback()
        await transport.flush_feedback()
        assert len(sent) == 1 and receipts == ["$photo"]
        for state in ("running", "waiting_for_approval", "running", "completed"):
            await transport.feedback(Request({"id": "$photo", "state": state}))
            await transport.flush_feedback()
            await transport.flush_feedback()
        assert len(sent) == 5 and len(redacted) == 4
        assert len({call[2]["tx_id"] for call in sent}) == 5
        await transport.feedback(Request({"id": "$photo", "state": "running"}))
        await transport.ack(Request({"id": "$photo"}))
        restarted = service.Journal(root / "journal.sqlite")
        transport.journal = restarted
        await transport.flush_feedback()
        assert len(sent) == 5 and receipts == ["$photo"]
        try: await transport.feedback(Request({"id": "$unknown", "state": "accepted"}))
        except service.web.HTTPNotFound: pass
        else: raise AssertionError("Unknown event accepted for reaction")

        # Media transaction deduplication survives restart and uses the same encrypted content.
        request = Request({"id": "output-1", "room": room.room_id, "text": "Report", "attachment": {"path": str(file)}})
        await transport.send(request)
        transport.journal = service.Journal(root / "journal.sqlite")
        await transport.send(request)
        assert len(sent) == 6 and sent[-1][1]["file"]["url"] == "mxc://test/output"
        file.write_bytes(b"changed")
        try: await transport.send(request)
        except service.web.HTTPConflict: pass
        else: raise AssertionError("Transaction reused for changed media")
    print("PASS: bounded encrypted media, source/path isolation, integrity, owner gate, persistent feedback and attachment send dedupe")

asyncio.run(check())
