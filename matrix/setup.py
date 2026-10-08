"""One-time local bootstrap. Credentials enter/leave through pipes, never Keychain."""
import asyncio
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import time
from urllib.parse import quote, urlsplit

import aiohttp
import yaml

ROOT = Path.home() / "Library/Application Support/Indexa"


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2))
    temporary.chmod(0o600)
    temporary.replace(path)


def verify_unused(root):
    """Never replace a server that contains real messages, devices, or queued work."""
    server = root / "matrix/homeserver.sqlite"
    if server.exists():
        with sqlite3.connect(f"file:{server}?mode=ro", uri=True) as db:
            if db.execute("SELECT count(*) FROM events WHERE type IN ('m.room.message','m.room.encrypted')").fetchone()[0]:
                raise RuntimeError("existing_matrix_has_messages")
            if db.execute("SELECT count(*) FROM devices WHERE user_id NOT LIKE '@indexa:%'").fetchone()[0]:
                raise RuntimeError("existing_matrix_has_user_devices")
    for name, tables in [("matrix/transport.sqlite", ["inbox", "deliveries"]), ("bridge.sqlite", ["tasks", "outbox", "inbound_events"])]:
        path = root / name
        if path.exists():
            with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
                for table in tables:
                    if db.execute("SELECT count(*) FROM " + table).fetchone()[0]:
                        raise RuntimeError("existing_indexa_has_work")


async def bootstrap(credentials):
    directory = ROOT / "matrix"
    marker = directory / "local-vault-bootstrap"
    config_path = directory / "homeserver.yaml"
    if not marker.exists():
        verify_unused(ROOT)
        previous = json.loads((ROOT / "matrix.json").read_text())
        hostname = urlsplit(previous["homeserver"]).hostname
        if not hostname or not hostname.endswith(".ts.net"):
            raise RuntimeError("unexpected_homeserver")
        # Preserve the previous empty bootstrap, including its signing/crypto keys.
        backup = ROOT / ("before-local-vault-" + time.strftime("%Y%m%d-%H%M%S"))
        backup.mkdir(mode=0o700)
        for name in ["matrix", "matrix.json", "bridge.sqlite", "bridge.sqlite-wal", "bridge.sqlite-shm"]:
            path = ROOT / name
            if path.exists():
                path.rename(backup / name)
        directory.mkdir(mode=0o700)
        process = await asyncio.create_subprocess_exec(sys.executable, "-m", "synapse.app.homeserver",
            "--server-name", hostname, "--config-path", str(config_path), "--generate-config", "--report-stats=no",
            cwd=directory, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        if await process.wait() != 0:
            raise RuntimeError("synapse_config_generation_failed")
        settings = yaml.safe_load(config_path.read_text())
        settings.update(server_name=hostname, public_baseurl=previous["homeserver"] + "/",
            listeners=[{"port": 18763, "type": "http", "tls": False, "bind_addresses": ["127.0.0.1"],
                        "x_forwarded": True, "resources": [{"names": ["client"], "compress": False}]}],
            # ponytail: SQLite is for this two-account private server; use PostgreSQL before expanding.
            database={"name": "sqlite3", "args": {"database": str(directory / "homeserver.sqlite")}},
            media_store_path=str(directory / "media"), enable_registration=False, allow_guest_access=False,
            enable_metrics=False, report_stats=False, federation_domain_whitelist=[], trusted_key_servers=[],
            suppress_key_server_warning=True, url_preview_enabled=False, max_upload_size="5M",
            push={"include_content": False}, password_config={"enabled": True},
            signing_key_path=str(directory / (hostname + ".signing.key")),
            log_config=str(directory / (hostname + ".log.config")), pid_file=str(directory / "homeserver.pid"))
        settings.pop("registration_shared_secret", None)
        config_path.write_text(yaml.safe_dump(settings));config_path.chmod(0o600)
        marker.write_text("pending\n")
    settings = yaml.safe_load(config_path.read_text())
    hostname = settings["server_name"]
    secret = secrets.token_hex(32)
    settings["registration_shared_secret"] = secret
    config_path.write_text(yaml.safe_dump(settings));config_path.chmod(0o600)
    output = (directory / "setup-server.log").open("ab")
    server = None
    try:
        server = await asyncio.create_subprocess_exec(sys.executable, "-m", "synapse.app.homeserver", "-c", str(config_path),
            cwd=directory, stdout=output, stderr=output)
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as session:
            async def request(method, path, body=None, token=None):
                headers = {"Authorization": "Bearer " + token} if token else {}
                async with session.request(method, "http://127.0.0.1:18763" + path, json=body, headers=headers) as response:
                    value = await response.json()
                    if response.status >= 400:
                        # Never include response bodies/passwords/tokens in diagnostics.
                        raise RuntimeError("matrix_http_" + str(response.status) + "_" + str(value.get("errcode", "unknown")))
                    return value
            for attempt in range(60):
                if server.returncode is not None:
                    raise RuntimeError("synapse_setup_exited")
                try:
                    await request("GET", "/_matrix/client/versions")
                    break
                except (aiohttp.ClientError, TimeoutError):
                    await asyncio.sleep(.5)
            else:
                raise RuntimeError("synapse_setup_timeout")
            for username, name in [("owner", "matrix-owner-password"), ("indexa", "matrix-indexa-password")]:
                password = credentials[name]
                nonce = (await request("GET", "/_synapse/admin/v1/register"))["nonce"]
                mac = hmac.new(secret.encode(), "\0".join([nonce, username, password, "notadmin"]).encode(), hashlib.sha1).hexdigest()
                try:
                    await request("POST", "/_synapse/admin/v1/register", {"nonce": nonce, "username": username,
                        "password": password, "admin": False, "inhibit_login": True, "mac": mac})
                except RuntimeError as error:
                    if str(error) != "matrix_http_400_M_USER_IN_USE":
                        raise
            async def login(username, password, device):
                return await request("POST", "/_matrix/client/v3/login", {"type": "m.login.password",
                    "identifier": {"type": "m.id.user", "user": username}, "password": password,
                    "device_id": device, "initial_device_display_name": "Indexa"})
            owner = await login("owner", credentials["matrix-owner-password"], "INDEXA_SETUP")
            bot = await login("indexa", credentials["matrix-indexa-password"], "INDEXA_BOT")
            try:
                existing = ROOT / "matrix.json"
                if existing.exists():
                    config = json.loads(existing.read_text())
                else:
                    room = await request("POST", "/_matrix/client/v3/createRoom", {
                        "name": "Indexa", "preset": "private_chat", "is_direct": True,
                        "invite": [bot["user_id"]], "creation_content": {"m.federate": False},
                        "initial_state": [{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}},
                                          {"type": "m.room.guest_access", "state_key": "", "content": {"guest_access": "forbidden"}}]}, owner["access_token"])
                    config = {"homeserver": settings["public_baseurl"].rstrip("/"), "owner_user": owner["user_id"],
                              "bot_user": bot["user_id"], "device_id": bot["device_id"], "room_id": room["room_id"]}
                    write_json(existing, config)
                await request("POST", "/_matrix/client/v3/join/" + quote(config["room_id"], safe=""), {}, bot["access_token"])
            finally:
                await request("POST", "/_matrix/client/v3/logout", {}, owner["access_token"])
            marker.write_text("complete\n")
            return {"matrix-bot-token": bot["access_token"]}
    finally:
        if server is not None and server.returncode is None:
            server.terminate()
            try:
                await asyncio.wait_for(server.wait(), 15)
            except asyncio.TimeoutError:
                server.kill();await server.wait()
        output.close()
        settings.pop("registration_shared_secret", None)
        config_path.write_text(yaml.safe_dump(settings));config_path.chmod(0o600)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384:
            raise ValueError("credential_frame_too_large")
        credentials = json.loads(raw)
        if set(credentials) != {"matrix-owner-password", "matrix-indexa-password"} or not all(isinstance(v, str) and 16 <= len(v) <= 4096 for v in credentials.values()):
            raise ValueError("invalid_credential_frame")
        print(json.dumps(asyncio.run(bootstrap(credentials))))
    except Exception as error:
        print("matrix_setup_failed:" + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
