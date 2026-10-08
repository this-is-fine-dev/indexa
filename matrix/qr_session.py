"""Short-lived, authenticated QR pairing; crypto is delegated to Matrix Rust SDK."""
import asyncio
import json
import secrets
from pathlib import Path

from aiohttp import web


class QRSession:
    def __init__(self, root, config, credentials, transport):
        self.root, self.config = root, config
        self.credentials = credentials
        self.transport = transport
        self.process = None
        self.reader = None
        self.state = {"state": "idle"}
        self.lock = asyncio.Lock()

    async def stop(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
        if self.reader:
            self.reader.cancel()
            await asyncio.gather(self.reader, return_exceptions=True)
        self.process = self.reader = None
        self.state = {"state": "idle"}

    async def start(self, request):
        async with self.lock:
            await self.stop()
            if not all(self.credentials.get(k) for k in ("matrix-owner-token", "matrix-owner-pickle")):
                raise web.HTTPServiceUnavailable(reason="qr_not_configured")
            binary = Path(__file__).parent / "indexa-qr"
            self.process = await asyncio.create_subprocess_exec(str(binary),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, limit=32768)
            self.state = {"state": "starting", "id": secrets.token_hex(16)}
            frame = {"homeserver": self.config["homeserver"], "user": self.config["owner_user"],
                     "token": self.credentials["matrix-owner-token"], "pickle": self.credentials["matrix-owner-pickle"],
                     "store": str(self.root / "matrix-qr/owner-crypto")}
            self.process.stdin.write(json.dumps(frame).encode() + b"\n")
            await self.process.stdin.drain()
            self.reader = asyncio.create_task(self.read())
            return web.json_response(self.state)

    async def read(self):
        session_id = self.state["id"]
        try:
            async for line in self.process.stdout:
                value = json.loads(line)
                if value.get("state") not in {"qr", "code", "consent", "done", "error"}:
                    raise ValueError("invalid_qr_state")
                if value["state"] == "done":
                    await self.transport.trust_signed_devices(value.pop("devices", []))
                self.state = {**value, "id": session_id}
            await self.process.wait()
            if self.state["state"] != "done":
                self.state = {"state": "error", "error": "pairing_failed", "id": session_id}
        except asyncio.CancelledError:
            raise
        except Exception:
            self.state = {"state": "error", "error": "pairing_failed", "id": session_id}

    async def status(self, request):
        return web.json_response(self.state, headers={"Cache-Control": "no-store"})

    async def command(self, request):
        data = await request.json()
        async with self.lock:
            if data.get("id") != self.state.get("id") or not self.process or self.process.returncode is not None:
                raise web.HTTPConflict()
            if data.get("cancel") is True:
                await self.stop()
                return web.json_response(self.state)
            code = data.get("code")
            if self.state["state"] == "code" and type(code) is int and 0 <= code < 100:
                payload = {"code": code}
            else:
                raise web.HTTPBadRequest()
            self.state = {"state": "waiting", "id": self.state["id"]}
            self.process.stdin.write(json.dumps(payload).encode() + b"\n")
            await self.process.stdin.drain()
            return web.json_response(self.state)
