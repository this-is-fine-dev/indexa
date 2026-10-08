"""Cross-sign the existing nio bot device, pinned to its local identity key."""
import base64
import copy
import hmac

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from nacl.signing import SigningKey
from signedjson.key import decode_signing_key_base64
from signedjson.sign import sign_json, verify_signed_json
from signedjson.key import get_verify_key


def signing_keys(secret):
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError('invalid_identity_secret')
    result = {}
    for purpose in ['master', 'self_signing', 'user_signing']:
        seed = HKDF(algorithm=hashes.SHA256(), length=32, salt=None,
                    info=('Indexa Matrix cross signing v1 ' + purpose).encode()).derive(secret.encode())
        public = base64.b64encode(bytes(SigningKey(seed).verify_key)).decode().rstrip('=')
        result[purpose] = decode_signing_key_base64('ed25519', public, base64.b64encode(seed).decode())
    return result


def signed_payload(user, device, expected_key, secret):
    if device.get('user_id') != user or device.get('device_id') != 'INDEXA_BOT':
        raise ValueError('unexpected_bot_device')
    actual = device.get('keys', {}).get('ed25519:INDEXA_BOT', '')
    if not hmac.compare_digest(actual, expected_key):
        raise ValueError('bot_device_key_mismatch')
    from signedjson.key import decode_verify_key_bytes
    public = base64.b64decode(expected_key + '=' * (-len(expected_key) % 4))
    verify_signed_json(device, user, decode_verify_key_bytes('ed25519:INDEXA_BOT', public))
    keys = signing_keys(secret)
    identity = {}
    for purpose, key in keys.items():
        identity[purpose + '_key'] = {'user_id': user, 'usage': [purpose], 'keys': {'ed25519:' + key.version: key.version}}
        sign_json(identity[purpose + '_key'], user, keys['master'])
    signed = copy.deepcopy(device)
    sign_json(signed, user, keys['self_signing'])
    return identity, {user: {'INDEXA_BOT': signed}}


async def configure(session, base, user, token, local_key, secret):
    async def request(path, body):
        async with session.post(base + '/_matrix/client/v3/' + path, json=body,
                                headers={'Authorization': 'Bearer ' + token}) as response:
            value = await response.json()
            if response.status != 200 or value.get('failures'):
                raise RuntimeError('bot_identity_' + path.replace('/', '_') + '_failed')
            return value
    current = await request('keys/query', {'device_keys': {user: []}})
    device = current.get('device_keys', {}).get(user, {}).get('INDEXA_BOT')
    if not device:
        raise RuntimeError('bot_device_missing')
    identity, signatures = signed_payload(user, device, local_key, secret)
    existing = current.get('master_keys', {}).get(user)
    if existing and existing.get('keys') != identity['master_key']['keys']:
        raise RuntimeError('existing_bot_identity_does_not_match_refusing_reset')
    await request('keys/device_signing/upload', identity)
    await request('keys/signatures/upload', signatures)
    updated = await request('keys/query', {'device_keys': {user: []}})
    keys = signing_keys(secret)
    verify_signed_json(updated['self_signing_keys'][user], user, get_verify_key(keys['master']))
    verify_signed_json(updated['device_keys'][user]['INDEXA_BOT'], user, get_verify_key(keys['self_signing']))
    return keys['master'].version
