"""Explicit local integration check; stdin-only credentials, sends one !status in own room."""
import asyncio
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile

import aiohttp
from nio import AsyncClient, AsyncClientConfig, LoginResponse, RoomMessageText, RoomSendResponse, SyncResponse

ROOT = Path.home() / "Library/Application Support/Indexa"


async def check(credentials):
    subprocess.run(["/usr/bin/open", "-a", str(Path.home() / "Applications/Indexa.app")], check=True)
    config = json.loads((ROOT / "matrix.json").read_text())
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=3)) as http:
        async def transport(method, endpoint, payload=None):
            async with http.request(method, "http://127.0.0.1:18764/" + endpoint,
                headers={"Authorization": "Bearer " + credentials["matrix-transport-key"]}, json=payload) as response:
                assert response.status == 200, "transport_http_" + str(response.status)
                return await response.json()
        for _ in range(60):
            try:
                health = await transport("GET", "health")
                if health["ready"]:
                    break
            except (aiohttp.ClientError, AssertionError):
                pass
            await asyncio.sleep(.5)
        else:
            raise RuntimeError("matrix_startup_timeout:" + health.get("problem", "unknown"))
        print("PASS: Matrix transport connected to encrypted room.", flush=True)
        async with http.get("http://127.0.0.1:18762/v1/capabilities", headers={"Authorization": "Bearer " + credentials["hermes-api-key"]}) as response:
            assert response.status == 200, "hermes_not_ready"
            features = (await response.json())["features"]
            assert features["run_submission"] and features["runs_idempotency"]["durable"] and features["run_approval_response"]
        print("PASS: Hermes Runs API, durable deduplication, approvals.", flush=True)
        async with http.get("http://127.0.0.1:18764/health") as response:
            assert response.status == 401, "unauthenticated_matrix_access"
        async with http.get("http://127.0.0.1:18762/v1/capabilities") as response:
            assert response.status == 401, "unauthenticated_hermes_access"
        print("PASS: local APIs reject requests without credentials.", flush=True)
        with tempfile.TemporaryDirectory(prefix="indexa-matrix-e2ee-") as directory:
            device = "INDEXA_TEST_" + secrets.token_hex(4).upper()
            owner = AsyncClient("http://127.0.0.1:18763", config["owner_user"], device_id=device, store_path=directory,
                config=AsyncClientConfig(encryption_enabled=True, pickle_key=secrets.token_hex(32), store_sync_tokens=False))
            replies = []
            async def receive(room, event):
                if room.room_id == config["room_id"] and event.sender == config["bot_user"] and event.decrypted:
                    replies.append(event.body)
            owner.add_event_callback(receive, RoomMessageText)
            logged_in = False
            try:
                result = await owner.login(credentials["matrix-owner-password"], device_name="Indexa local E2EE check")
                assert isinstance(result, LoginResponse), "owner_login_failed"
                logged_in = True
                await owner.keys_upload()
                assert isinstance(await owner.sync(timeout=1000, full_state=True), SyncResponse)
                await owner.keys_query()
                bot = owner.device_store[config["bot_user"]].get(config["device_id"])
                assert bot is not None, "bot_device_missing"
                owner.verify_device(bot)
                assert owner.rooms[config["room_id"]].encrypted, "room_not_encrypted"
                # Trust only the ephemeral device whose private key this check just created.
                for _ in range(30):
                    devices = (await transport("GET", "devices"))["devices"]
                    current = next((value for value in devices if value["id"] == owner.device_id), None)
                    if current:
                        assert current["key"] == owner.olm.account.identity_keys["ed25519"], "device_key_mismatch"
                        await transport("POST", "trust", {"id": current["id"], "key": current["key"]})
                        break
                    await asyncio.sleep(1)
                else:
                    raise RuntimeError("owner_device_discovery_timeout")
                sent = await owner.room_send(config["room_id"], "m.room.message", {"msgtype": "m.text", "body": "!status"})
                assert isinstance(sent, RoomSendResponse), "encrypted_send_failed"
                for _ in range(20):
                    await owner.sync(timeout=2000)
                    if replies:
                        break
                assert replies, "encrypted_status_reply_timeout"
                print("PASS: Element-compatible E2EE owner → Indexa → encrypted status reply; no LLM run.", flush=True)
            finally:
                if logged_in:
                    await owner.logout()
                await owner.close()


if __name__ == "__main__":
    try:
        credentials = json.loads(sys.stdin.buffer.read(16384))
        asyncio.run(asyncio.wait_for(check(credentials), 120))
    except Exception as error:
        print("Live check failed: " + type(error).__name__ + (":" + str(error) if isinstance(error, (AssertionError, RuntimeError)) else ""), file=sys.stderr)
        sys.exit(1)
