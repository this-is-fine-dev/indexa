"""Indexa owns these native child processes; no system-wide daemon or container."""
import asyncio
import os
import logging
from logging.handlers import RotatingFileHandler
import signal
import sys
import aiohttp
from public_proxy import create_proxy

PG = '/opt/homebrew/opt/postgresql@17/bin'


class NativeServices:
    def __init__(self, root):
        self.root = root
        self.children = []
        self.logs = []
        self.log_tasks = []
        self.proxy = None

    async def spawn(self, *args, name):
        log = RotatingFileHandler(self.root / 'matrix-qr' / (name + '.log'), maxBytes=2*1024*1024, backupCount=2, encoding='utf-8')
        self.logs.append(log)
        p = await asyncio.create_subprocess_exec(*map(str, args), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                                                # Finder/Login Items do not inherit a shell locale. On macOS,
                                                # PostgreSQL needs one to avoid CoreFoundation starting threads.
                                                env={**os.environ, 'LC_ALL': 'C', 'NO_COLOR': '1', 'TOKIO_WORKER_THREADS': '2'})
        self.log_tasks.append(asyncio.create_task(self.collect_log(p.stdout, log)))
        self.children.append(p)
        return p

    @staticmethod
    async def collect_log(stream, handler):
        # Bounded chunks also handle programs writing a single enormous line.
        while chunk := await stream.read(8192):
            handler.handle(logging.LogRecord('indexa.native', logging.INFO, '', 0, chunk.decode('utf-8', errors='replace').rstrip('\n'), (), None))

    async def postgres(self):
        await self.spawn(PG + '/postgres', '-D', self.root / 'matrix-qr/postgres', name='postgres')
        for _ in range(100):
            if self.children[-1].returncode is not None:
                raise RuntimeError('postgres_exited')
            p = await asyncio.create_subprocess_exec(PG + '/pg_isready', '-h', str(self.root / 'pgsocket'), '-p', '18767', '-d', 'postgres',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            if await p.wait() == 0:
                return
            await asyncio.sleep(.1)
        raise RuntimeError('postgres_start_timeout')

    async def http_ready(self, url):
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=2)) as session:
            for _ in range(150):
                if any(p.returncode is not None for p in self.children):
                    raise RuntimeError('native_service_exited')
                try:
                    async with session.get(url) as response:
                        if response.status == 200:
                            return
                except (aiohttp.ClientError, TimeoutError):
                    pass
                await asyncio.sleep(.2)
        raise RuntimeError('native_service_start_timeout')

    async def servers(self):
        await self.spawn(sys.executable, '-m', 'synapse.app.homeserver', '-c', self.root / 'matrix-qr/homeserver.yaml', '-c', self.root / 'matrix-media-limits.yaml', name='synapse')
        await self.http_ready('http://127.0.0.1:18765/_matrix/client/versions')
        await self.spawn(self.root / 'runtime/mas/mas-cli', 'server', '-c', self.root / 'matrix-qr/mas.yaml', name='mas')
        await self.http_ready('http://127.0.0.1:18766/.well-known/openid-configuration')
        self.proxy = await create_proxy()

    async def start(self):
        try:
            await self.postgres()
            await self.servers()
        except BaseException:
            await self.stop()
            raise

    async def stop(self):
        if self.proxy:
            await self.proxy.cleanup()
            self.proxy = None
        for p in reversed(self.children):
            if p.returncode is None:
                # PostgreSQL SIGINT is fast orderly shutdown, not SIGKILL.
                p.send_signal(signal.SIGINT if p is self.children[0] else signal.SIGTERM)
                try:
                    await asyncio.wait_for(p.wait(), 15)
                except asyncio.TimeoutError:
                    p.kill()
                    await p.wait()
        self.children.clear()
        await asyncio.gather(*self.log_tasks, return_exceptions=True)
        self.log_tasks.clear()
        for log in self.logs:
            log.close()
        self.logs.clear()
