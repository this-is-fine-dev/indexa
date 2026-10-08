"""Validate a generated appcast against its actual ZIP and embedded public key."""
import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile
import hashlib
import subprocess
import tempfile
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
    for required in ('MacOS/Indexa', 'Resources/Indexa.icns', 'Resources/matrix/indexa-qr', 'Resources/matrix/service.py',
                     'Resources/matrix/media.py', 'Resources/connect-hermes-mcp.py',
                     'Resources/stack.json', 'Resources/prepare-runtime.py', 'Resources/hermes-plugin/__init__.py',
                     'Frameworks/Sparkle.framework/Versions/B/Sparkle'):
        assert prefix + required in names, required
    assert not any(name.endswith(('.vault.key', 'private-key', 'bridge.sqlite', 'secrets.enc')) for name in names)
    assert info['SUFeedURL'] == 'https://github.com/this-is-fine-dev/indexa/releases/latest/download/appcast.xml'
    assert info['SUVerifyUpdateBeforeExtraction'] is True
    assert info['CFBundleIconFile'] == 'Indexa'
    assert zipped.read(prefix + 'Resources/Indexa.icns').startswith(b'icns')
    assert not any('/.signing/' in name or name.endswith(('key.pem', '.p12')) for name in names)

assert archive.stat().st_size == int(enclosure.attrib['length'])
signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
Ed25519PublicKey.from_public_bytes(key).verify(base64.b64decode(signature, validate=True), archive.read_bytes())
with tempfile.TemporaryDirectory() as temporary:
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), temporary], check=True)
    fingerprint = hashlib.sha1(Path('release/code-signing.cer').read_bytes()).hexdigest()
    requirement = f'identifier "local.fine.indexa" and certificate leaf = H"{fingerprint}"'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures',
                    '-R=' + requirement, str(Path(temporary) / 'Indexa.app')], check=True)
print('PASS: release contents, Ed25519 archive signature, pinned app identity')
