"""Private Tailscale ingress for Matrix and MAS; admin APIs remain loopback-only."""
import re
from aiohttp import ClientSession, ClientTimeout, web

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "content-length"}


def target(path):
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


async def create_proxy():
    session = ClientSession(timeout=ClientTimeout(total=90), auto_decompress=False)

    async def proxy(request):
        base = target(request.path)
        if not base:
            raise web.HTTPNotFound()
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() not in HOP | {"host", "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"}}
        headers["X-Forwarded-Proto"] = "https"
        try:
            async with session.request(request.method, base + request.rel_url.raw_path_qs,
                    headers=headers, data=await request.read(), allow_redirects=False) as response:
                forwarded = [(k, v) for k, v in response.headers.items() if k.lower() not in HOP]
                return web.Response(status=response.status, headers=forwarded, body=await response.read())
        except (TimeoutError, OSError):
            raise web.HTTPBadGateway()

    app = web.Application(client_max_size=21 * 1024 * 1024)
    app.router.add_route("*", "/{path:.*}", proxy)
    async def cleanup(_):
        await session.close()
    app.on_cleanup.append(cleanup)
    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", 18763).start()
    return runner
