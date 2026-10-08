"""Validate a generated appcast against its actual ZIP and embedded public key."""
import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

feed = Path(sys.argv[1])
enclosure = ET.parse(feed).find('./channel/item/enclosure')
assert enclosure is not None
archive = feed.parent / Path(enclosure.attrib['url']).name
with zipfile.ZipFile(archive) as zipped:
    prefix = 'Indexa.app/Contents/'
    info = plistlib.loads(zipped.read(prefix + 'Info.plist'))
    key = base64.b64decode(info['SUPublicEDKey'], validate=True)
    assert key == base64.b64decode(Path('release/sparkle-public-key.txt').read_bytes(), validate=True)
    names = set(zipped.namelist())
    for required in ('MacOS/Indexa', 'Resources/matrix/indexa-qr', 'Resources/matrix/service.py',
                     'Resources/stack.json', 'Resources/prepare-runtime.py', 'Resources/hermes-plugin/__init__.py',
                     'Frameworks/Sparkle.framework/Versions/B/Sparkle'):
        assert prefix + required in names, required
    assert not any(name.endswith(('.vault.key', 'private-key', 'bridge.sqlite', 'secrets.enc')) for name in names)
    assert info['SUFeedURL'] == 'https://github.com/this-is-fine-dev/indexa/releases/latest/download/appcast.xml'
    assert info['SUVerifyUpdateBeforeExtraction'] is True
assert archive.stat().st_size == int(enclosure.attrib['length'])
signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
Ed25519PublicKey.from_public_bytes(key).verify(base64.b64decode(signature, validate=True), archive.read_bytes())
print('PASS: release contents, appcast length, pinned Ed25519 signature')
