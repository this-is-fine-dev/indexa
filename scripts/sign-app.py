"""Sign Indexa with its pinned certificate, without accessing any Keychain."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE = ROOT / 'release/code-signing.cer'
KEY = Path(os.environ.get('INDEXA_SIGNING_KEY', ROOT / '.signing/key.pem'))
IDENTIFIER = 'local.fine.indexa'

def sign(app):
    app = app.resolve()
    if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != IDENTIFIER:
        raise RuntimeError('unexpected_application_identifier')
    if not KEY.is_file() or KEY.is_symlink() or KEY.stat().st_mode & 0o077:
        raise RuntimeError('signing_key_missing_or_insecure: use the existing key with mode 0600; never generate a replacement')
    fingerprint = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest()
    requirement = f'identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    protected = {path: hashlib.sha256(path.read_bytes()).digest() for path in framework.rglob('*')
                 if path.is_file() and not path.is_symlink()}
    with tempfile.TemporaryDirectory() as temporary:
        compiled = Path(temporary) / 'designated.req'
        subprocess.run(['/usr/bin/csreq', '-r', '=' + requirement, '-b', str(compiled)], check=True)
        # Preserve the distributed Sparkle framework and its nested helpers.
        command = [str(ROOT / '.local-build/rcodesign'), '-C', '/dev/null', 'sign',
                   '--pem-file', str(KEY), '--certificate-der-file', str(CERTIFICATE),
                   '--timestamp-url', 'none', '--exclude', 'Contents/Frameworks/Sparkle.framework',
                   '--exclude', 'Contents/Frameworks/Sparkle.framework/**',
                   '--code-requirements-file', str(compiled), str(app)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('code_signing_failed\n' + result.stderr[-2000:])
    if any(hashlib.sha256(path.read_bytes()).digest() != digest for path, digest in protected.items()):
        raise RuntimeError('sparkle_framework_was_modified')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures',
                    '-R=' + requirement, str(app)], check=True)
    print('PASS: Indexa signature matches the pinned certificate')

if __name__ == '__main__':
    sign(Path(sys.argv[1]))
