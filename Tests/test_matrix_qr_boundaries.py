"""Small offline checks for the pairing trust boundary and private proxy routes."""
import asyncio
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parents[1] / 'matrix'))
from public_proxy import target
from service import Transport
from nio.crypto import OlmDevice

assert target('/_synapse/client/rendezvous/abc') == 'http://127.0.0.1:18765'
assert target('/_matrix/client/v3/sync') == 'http://127.0.0.1:18765'
assert target('/_matrix/client/v3/login') == 'http://127.0.0.1:18766'
assert target('/device/abc') == 'http://127.0.0.1:18766'
for path in ['/_synapse/admin/v1/users', '/api/admin/v1/users', '/health', '/metrics', '/_internal']:
    assert target(path) is None

async def check():
    with tempfile.TemporaryDirectory() as directory:
        config = {'owner_user':'@owner:test', 'bot_user':'@indexa:test', 'device_id':'BOT', 'room_id':'!room:test'}
        credentials = {k:'synthetic-credential-not-a-real-secret' for k in ['matrix-transport-key','matrix-bot-token','matrix-pickle-key']}
        transport = Transport(config, Path(directory), credentials)
        device = OlmDevice('@owner:test', 'PHONE', {'ed25519':'verified-public-key','curve25519':'synthetic-curve'})
        transport.client.device_store.add(device)
        async def keys_query():
            pass
        transport.client.keys_query = keys_query
        try:
            for invalid in [[], [{'id':'UNKNOWN','key':'verified-public-key'}], [{'id':'PHONE','key':'wrong-public-key'}]]:
                try:
                    await transport.trust_signed_devices(invalid)
                except ValueError:
                    pass
                else:
                    raise AssertionError('unmatched key trusted')
                assert not device.verified
            await transport.trust_signed_devices([{'id':'PHONE','key':'verified-public-key'}])
            assert device.verified
        finally:
            await transport.client.close()
asyncio.run(check())
print('PASS: QR trust requires exact device key; private proxy blocks admin routes')
