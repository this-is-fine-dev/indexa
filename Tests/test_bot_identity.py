import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/'matrix'))
from bot_identity import signed_payload, signing_keys
from signedjson.key import generate_signing_key, encode_verify_key_base64
from signedjson.sign import sign_json, verify_signed_json
from signedjson.key import get_verify_key

user='@indexa:test'
key=generate_signing_key('INDEXA_BOT')
fingerprint=encode_verify_key_base64(key.verify_key)
device={'user_id':user,'device_id':'INDEXA_BOT','algorithms':['m.olm.v1.curve25519-aes-sha2','m.megolm.v1.aes-sha2'],
        'keys':{'ed25519:INDEXA_BOT':fingerprint,'curve25519:INDEXA_BOT':'synthetic-curve'}}
sign_json(device,user,key)
secret='synthetic-cross-signing-secret-not-for-production'
identity,signatures=signed_payload(user,device,fingerprint,secret)
keys=signing_keys(secret)
assert len({k.version for k in keys.values()}) == 3
assert keys['master'].version == signing_keys(secret)['master'].version
verify_signed_json(identity['self_signing_key'],user,get_verify_key(keys['master']))
verify_signed_json(signatures[user]['INDEXA_BOT'],user,get_verify_key(keys['self_signing']))
assert keys['self_signing'].version not in device['signatures'][user]
for invalid,expected in [(device,'wrong-key'),({**device,'user_id':'@stranger:test'},fingerprint),({**device,'device_id':'PHONE'},fingerprint)]:
    try:signed_payload(user,invalid,expected,secret)
    except ValueError:pass
    else:raise AssertionError('unmatched device signed')
print('PASS: pinned bot identity signatures, stable keys, mismatched device rejection')
