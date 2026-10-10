"""Real loopback HTTP checks; synthetic webhook secrets and temporary listeners only."""
import asyncio
import gzip
import hashlib
import hmac
import sys
from pathlib import Path
from unittest.mock import patch

from aiohttp import ClientSession, web
from yarl import URL

sys.path.insert(0, str(Path(__file__).parents[1] / "matrix"))
import public_proxy


async def check():
    received = []
    secret = b"synthetic-webhook-secret"

    async def receiver(request):
        body = await request.read()
        received.append((request.method, request.raw_path, body, request.raw_headers))
        signature = hmac.new(secret, body, hashlib.sha256).hexdigest()
        signatures = request.headers.getall("X-Index-Signature", [])
        if len(signatures) > 1 or len(request.headers.getall("Authorization", [])) > 1:
            return web.Response(status=400, text="duplicate_authentication")
        if request.path == "/pebble/v1/ingest" and signatures != [signature]:
            return web.Response(status=401, text="unauthorized", headers={"WWW-Authenticate": "Bearer"})
        return web.Response(status=202, text="accepted", headers={"X-Test-Receipt": "synthetic"})

    app = web.Application(client_max_size=22 * 1024 * 1024)
    app.router.add_route("*", "/{path:.*}", receiver)
    upstream = web.AppRunner(app, access_log=None, auto_decompress=False)
    await upstream.setup()
    await web.TCPSite(upstream, "127.0.0.1", 0).start()
    receiver_port = upstream.addresses[0][1]
    proxy = await public_proxy.create_proxy(pebble_port=receiver_port, port=0)
    address = f"http://127.0.0.1:{proxy.addresses[0][1]}"
    try:
        async with ClientSession() as client:
            body = (b'--test-boundary\r\nContent-Disposition: form-data; name="transcription"\r\n\r\n'
                    + "Przypomnij mi o spotkaniu. Łódź".encode() + b"\x00\xfe\r\n--test-boundary--\r\n")
            signature = hmac.new(secret, body, hashlib.sha256).hexdigest()
            headers = [("Content-Type", "multipart/form-data; boundary=test-boundary"),
                       ("x-InDeX-Signature", signature), ("X-Index-Delivery", "synthetic-delivery"),
                       ("Authorization", "Bearer synthetic"), ("X-Forwarded-Proto", "http")]
            async with client.post(address + "/pebble/v1/ingest", data=body, headers=headers) as response:
                assert response.status == 202 and await response.text() == "accepted"
                assert response.headers["X-Test-Receipt"] == "synthetic"
            assert received[-1][:3] == ("POST", "/pebble/v1/ingest", body)
            assert (b"x-index-signature", signature.encode()) in received[-1][3]
            assert (b"x-index-delivery", b"synthetic-delivery") in received[-1][3]
            assert (b"authorization", b"Bearer synthetic") in received[-1][3]
            assert (b"X-Forwarded-Proto", b"https") in received[-1][3]

            async with client.post(address + "/pebble/v1/ingest", data=body) as response:
                assert response.status == 401 and await response.text() == "unauthorized"
                assert response.headers["WWW-Authenticate"] == "Bearer"
            for duplicate in [("X-Index-Signature", "second-signature"), ("authorization", "Bearer second")]:
                # ClientSession itself drops mixed-case duplicates; send actual HTTP bytes.
                reader, writer = await asyncio.open_connection("127.0.0.1", proxy.addresses[0][1])
                raw_headers = headers + [duplicate, ("Host", "localhost"), ("Content-Length", str(len(body))), ("Connection", "close")]
                wire = "POST /pebble/v1/ingest HTTP/1.1\r\n" + "".join(f"{key}: {value}\r\n" for key, value in raw_headers) + "\r\n"
                writer.write(wire.encode() + body)
                await writer.drain()
                response = await reader.read()
                writer.close()
                await writer.wait_closed()
                assert response.startswith(b"HTTP/1.1 400") and response.endswith(b"duplicate_authentication")
                assert (duplicate[0].lower().encode(), duplicate[1].encode()) in received[-1][3]

            # Even Content-Encoding must not alter bytes covered by the signature.
            compressed = gzip.compress(body)
            compressed_headers = [("Content-Encoding", "gzip"), ("X-Index-Signature", hmac.new(secret, compressed, hashlib.sha256).hexdigest())]
            async with client.post(address + "/pebble/v1/ingest", data=compressed, headers=compressed_headers) as response:
                assert response.status == 202
            assert received[-1][2] == compressed

            before = len(received)
            for method, path in [(verb, "/pebble/v1/ingest") for verb in ["GET", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"]] + [
                ("POST", path) for path in ["/pebble", "/pebble/v1/ingest/", "/pebble/v1/ingest?x=1", "/pebble/v1/health",
                "/pebble/admin", "/pebble-other", "/%70ebble/v1/ingest", "/pebble%2Fv1%2Fingest", "/health", "/api/admin", "/_synapse/admin/v1/users"]]:
                async with client.request(method, URL(address + path, encoded=True), data=body) as response:
                    assert response.status == 404, (method, path, response.status)
            assert len(received) == before

            limit = 20 * 1024 * 1024
            exact = b"x" * limit
            async with client.post(address + "/pebble/v1/ingest", data=exact,
                    headers={"X-Index-Signature": hmac.new(secret, exact, hashlib.sha256).hexdigest()}) as response:
                assert response.status == 202
            before = len(received)
            async def chunks():
                for _ in range(limit // (64 * 1024) + 1):
                    yield b"x" * (64 * 1024)
            for oversized in [b"x" * (limit + 1), chunks()]:
                async with client.post(address + "/pebble/v1/ingest", data=oversized) as response:
                    assert response.status == 413
            assert len(received) == before, "Oversized bodies must not reach the receiver"

            original_target = public_proxy.target
            def mock_matrix(path):
                return f"http://127.0.0.1:{receiver_port}" if original_target(path) else None
            with patch.object(public_proxy, "target", mock_matrix):
                matrix_body = b"m" * (20 * 1024 * 1024)
                async with client.post(address + "/_matrix/media/v3/upload?filename=test.bin", data=matrix_body) as response:
                    assert response.status == 202
                assert received[-1][1:3] == ("/_matrix/media/v3/upload?filename=test.bin", matrix_body)
                before = len(received)
                async with client.post(address + "/_matrix/media/v3/upload", data=b"x" * (21 * 1024 * 1024 + 1)) as response:
                    assert response.status == 413
                assert len(received) == before
    finally:
        await proxy.cleanup()
        await upstream.cleanup()

    for invalid_port in [None, "", "bad", "0", "65536", "18763/path", "١٢٣", "9" * 5000]:
        proxy = await public_proxy.create_proxy(pebble_port=invalid_port, port=0)
        try:
            async with ClientSession() as client:
                async with client.post(f"http://127.0.0.1:{proxy.addresses[0][1]}/pebble/v1/ingest") as response:
                    assert response.status == 404
        finally:
            await proxy.cleanup()
    print("PASS: exact Pebble routing, byte-preserving signed multipart, duplicate auth, limits and unchanged Matrix uploads")


if __name__ == "__main__":
    asyncio.run(check())
