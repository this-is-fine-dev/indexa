"""Provision/repair only Indexa's pinned bot identity; never reset an existing identity."""
import asyncio
import json
import os
from pathlib import Path
import sys
import aiohttp
from nio import AsyncClient, AsyncClientConfig
from bot_identity import configure

ROOT = Path.home() / 'Library/Application Support/Indexa'
REPO = Path(__file__).resolve().parent.parent


async def repair(credentials):
    config = json.loads((ROOT/'matrix.json').read_text())
    # Indexa must be stopped: obtain the device fingerprint from its local crypto store.
    client = AsyncClient('http://127.0.0.1:18763', config['bot_user'], device_id=config['device_id'],
        store_path=str(ROOT/'matrix'), config=AsyncClientConfig(encryption_enabled=True, pickle_key=credentials['matrix-pickle-key']))
    client.restore_login(config['bot_user'], config['device_id'], credentials['matrix-bot-token'])
    local_key = client.olm.account.identity_keys['ed25519']
    await client.close()
    service_keys = {'matrix-transport-key','matrix-bot-token','matrix-pickle-key','matrix-owner-token','matrix-owner-pickle'}
    service = await asyncio.create_subprocess_exec(sys.executable, '-B', str(REPO/'matrix/service.py'),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    service.stdin.write(json.dumps({key:credentials[key] for key in service_keys}).encode())
    await service.stdin.drain();service.stdin.close()
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as session:
            for _ in range(150):
                assert service.returncode is None, 'matrix_service_exited'
                try:
                    async with session.get('http://127.0.0.1:18764/health', headers={'Authorization':'Bearer '+credentials['matrix-transport-key']}) as response:
                        health = await response.json()
                        if health.get('ready'):
                            break
                except (aiohttp.ClientError, TimeoutError):
                    pass
                await asyncio.sleep(.2)
            else:
                raise RuntimeError('matrix_start_timeout')
            master = await configure(session, 'http://127.0.0.1:18763', config['bot_user'], credentials['matrix-bot-token'],
                                     local_key, credentials['matrix-bot-cross-signing'])
            print('PASS: bot device signed by its pinned cross-signing identity', flush=True)
            frame = {'homeserver':config['homeserver'],'user':config['owner_user'],'token':credentials['matrix-owner-token'],
                'store':str(ROOT/'matrix-qr/owner-crypto'),'pickle':credentials['matrix-owner-pickle'],
                'verify_identity':{'user':config['bot_user'],'master':master,'device':'INDEXA_BOT','key':local_key}}
            verifier = await asyncio.create_subprocess_exec(str(REPO/'matrix/qr/target/release/indexa-qr'),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            output,_ = await verifier.communicate(json.dumps(frame).encode()+b'\n')
            if verifier.returncode or json.loads(output).get('state') != 'identity_verified':
                raise RuntimeError('owner_did_not_verify_bot_identity')
            print('PASS: Matrix SDK verifies full owner → bot identity → bot device signature chain', flush=True)
    finally:
        if service.returncode is None:
            service.terminate()
            await asyncio.wait_for(service.wait(),30)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        frame=sys.stdin.buffer.read(32769)
        if len(frame)>32768:raise ValueError('credential_frame_too_large')
        asyncio.run(repair(json.loads(frame)))
    except Exception as error:
        print(str(error) if isinstance(error,RuntimeError) else type(error).__name__,file=sys.stderr)
        sys.exit(1)
