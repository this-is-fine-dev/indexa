"""Real MSC4108 + MAS round trip with a disposable Rust peer. Credentials on stdin."""
import asyncio
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
import aiohttp

REPO = Path(__file__).resolve().parent.parent
ROOT = Path.home() / 'Library/Application Support/Indexa'


class Inputs(HTMLParser):
    def __init__(self, text):
        super().__init__();self.fields = {};self.feed(text)
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'input' and attrs.get('type') == 'hidden' and attrs.get('name'):
            self.fields[attrs['name']] = attrs.get('value', '')


async def run(credentials):
    service_keys = {'matrix-transport-key', 'matrix-bot-token', 'matrix-pickle-key', 'matrix-owner-token', 'matrix-owner-pickle'}
    service = await asyncio.create_subprocess_exec(sys.executable, str(REPO / 'matrix/service.py'),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    service.stdin.write(json.dumps({k:credentials[k] for k in service_keys}).encode());await service.stdin.drain();service.stdin.close()
    peer = None
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as http:
        async def api(method, path, body=None):
            async with http.request(method, 'http://127.0.0.1:18764/' + path, json=body,
                    headers={'Authorization': 'Bearer ' + credentials['matrix-transport-key']}) as response:
                assert response.status == 200, f'{path}: HTTP {response.status}'
                return await response.json()
        async def state(wanted):
            for _ in range(180):
                value = await api('GET', 'qr/status')
                if value['state'] in wanted:
                    return value
                if value['state'] == 'error':
                    raise AssertionError('qr_failed_before_' + '/'.join(wanted))
                await asyncio.sleep(.25)
            raise AssertionError('qr_state_timeout_' + '/'.join(wanted))
        async def start_peer(qr):
            process = await asyncio.create_subprocess_exec(str(REPO / 'matrix/qr/target/release/examples/peer'),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            process.stdin.write(qr['data'].encode() + b'\n');await process.stdin.drain()
            line = await asyncio.wait_for(process.stdout.readline(), 30)
            assert line, 'peer_exited_before_code'
            first = json.loads(line);assert first['state'] == 'code'
            return process, int(first['code'])
        try:
            for _ in range(150):
                assert service.returncode is None, 'service_exited'
                try:
                    health = await api('GET', 'health')
                    if health['ready']:
                        break
                except aiohttp.ClientError:
                    pass
                await asyncio.sleep(.2)
            else:
                raise AssertionError('matrix_not_ready')
            public = health['homeserver']
            for path in ['/_synapse/admin/v1/server_version', '/api/admin/v1/users', '/health', '/metrics']:
                async with http.get(public + path) as response:
                    assert response.status == 404, 'private_endpoint_exposed'
            for path in ['qr/status', 'qr/start']:
                async with http.request('POST' if path.endswith('start') else 'GET', 'http://127.0.0.1:18764/' + path) as response:
                    assert response.status == 401, 'qr_requires_authentication'
            print('PASS: private admin routes and QR control authentication', flush=True)
            await api('POST', 'qr/start', {})
            qr = await state({'qr'})
            peer, code = await start_peer(qr)
            await state({'code'})
            await api('POST', 'qr/command', {'id':qr['id'], 'code':(code+1)%100})
            await state({'error'})
            if peer.returncode is None:
                peer.terminate();await peer.wait()
            peer = None
            print('PASS: incorrect check code rejects pairing', flush=True)
            await api('POST', 'qr/start', {})
            qr = await state({'qr'})
            peer, code = await start_peer(qr)
            await state({'code'})
            await api('POST', 'qr/command', {'id':qr['id'], 'code':code})
            consent = await state({'consent'})
            target = consent['url']
            assert urlsplit(target).netloc == urlsplit(public).netloc and urlsplit(target).path == '/link'
            line = await asyncio.wait_for(peer.stdout.readline(), 20)
            assert json.loads(line)['state'] == 'token', 'peer_waiting_for_token'
            # This approval is only for the disposable peer just created by this test.
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as browser:
                async with browser.get(target) as response:
                    page = await response.text();login = str(response.url)
                assert urlsplit(login).path == '/login', 'login_path_' + urlsplit(login).path + '_status_' + str(response.status)
                fields = Inputs(page).fields
                assert 'csrf' in fields
                fields.update(username=health['owner_user'], password=credentials['matrix-owner-password'])
                async with browser.post(login, data=fields) as response:
                    page = await response.text();grant_url = str(response.url)
                assert urlsplit(grant_url).path.startswith('/device/'), 'expected_consent_page:' + urlsplit(grant_url).path + ':' + str(response.status)
                assert 'Indexa disposable QR check' in page, 'wrong_consent_client'
                fields = Inputs(page).fields
                assert 'csrf' in fields
                fields.update(action='consent', confirm_device='on')
                async with browser.post(grant_url, data=fields) as response:
                    assert response.status == 200, 'consent_failed'
            line = await asyncio.wait_for(peer.stdout.readline(), 30)
            result = json.loads(line)
            assert result['state'] == 'done' and result['cross_signing'] is True, 'identity_not_imported'
            assert result['user'] == health['owner_user'], 'wrong_user'
            await state({'done'})
            devices = (await api('GET', 'devices'))['devices']
            assert any(d['id'] == result['device'] and d['verified'] for d in devices), 'bot_does_not_trust_paired_device'
            assert all(d['verified'] for d in devices), 'untrusted_owner_device_blocks_encrypted_replies'
            print('PASS: QR OAuth login, cross-signing transfer and exact verified-device trust', flush=True)
            peer.stdin.write(b'logout\n');await peer.stdin.drain()
            line = await asyncio.wait_for(peer.stdout.readline(), 15)
            assert json.loads(line)['state'] == 'logged_out'
            await peer.wait();peer = None
            print('PASS: disposable phone session logged out', flush=True)
        finally:
            if peer and peer.returncode is None:
                peer.terminate();await peer.wait()
            if service.returncode is None:
                service.terminate()
                await asyncio.wait_for(service.wait(), 30)


if __name__ == '__main__':
    asyncio.run(run(json.load(sys.stdin)))
