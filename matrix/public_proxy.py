"""Private ingress for Matrix, MAS and the authenticated Pebble webhook."""
import re
from aiohttp import ClientSession, ClientTimeout, web

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "content-length"}


def target(path):
    if path.startswith("/pebble"):
        return None
    if path.startswith("/_synapse/client/rendezvous/"):
        return "http://127.0.0.1:18765"
    if path.startswith(("/_synapse", "/api/admin", "/health", "/metrics")):
        return None
    if re.fullmatch(r"/_matrix/client/(?:v3|r0|unstable)/(?:login|logout|logout/all|refresh)", path):
        return "http://127.0.0.1:18766"
    if path.startswith(("/_matrix/client/", "/_matrix/media/", "/_synapse/client/")) or path == "/.well-known/matrix/client":
        return "http://127.0.0.1:18765"
    if path.startswith("/_"):
        return None
    return "http://127.0.0.1:18766"


async def create_proxy(pebble_port=None, *, port=18763):
    # Missing/invalid configuration disables only Pebble, never exposes another route.
    pebble_port = str(pebble_port or "")
    pebble_base = ("http://127.0.0.1:" + pebble_port
                   if re.fullmatch(r"[0-9]{1,5}", pebble_port) and 1 <= int(pebble_port) <= 65535
                   and int(pebble_port) != port else None)
    session = ClientSession(timeout=ClientTimeout(total=90), auto_decompress=False)

    async def proxy(request):
        pebble = request.path.startswith("/pebble")
        base = (pebble_base if request.method == "POST" and request.rel_url.raw_path_qs == "/pebble/v1/ingest" else None) if pebble else target(request.path)
        if not base:
            raise web.HTTPNotFound()
        # aiohttp collapses mixed-case duplicates unless names are normalized first.
        # Keep every value: the authenticated receiver must reject duplicate headers.
        headers = [(k.lower(), v) for k, v in request.headers.items()
                   if k.lower() not in HOP | {"host", "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"}]
        headers.append(("X-Forwarded-Proto", "https"))
        if pebble:
            limit = 20 * 1024 * 1024
            if request.content_length is not None and request.content_length > limit:
                raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=request.content_length)
            body = bytearray()
            async for chunk in request.content.iter_chunked(64 * 1024):
                if len(body) + len(chunk) > limit:
                    raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=len(body) + len(chunk))
                body.extend(chunk)
        else:
            body = await request.read()
        try:
            async with session.request(request.method, base + request.rel_url.raw_path_qs,
                    headers=headers, data=body, allow_redirects=False) as response:
                forwarded = [(k, v) for k, v in response.headers.items() if k.lower() not in HOP]
                return web.Response(status=response.status, headers=forwarded, body=await response.read())
        except (TimeoutError, OSError):
            raise web.HTTPBadGateway()

    app = web.Application(client_max_size=21 * 1024 * 1024)
    app.router.add_route("*", "/{path:.*}", proxy)
    async def cleanup(_):
        await session.close()
    app.on_cleanup.append(cleanup)
    runner = web.AppRunner(app, access_log=None, auto_decompress=False)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    return runner
