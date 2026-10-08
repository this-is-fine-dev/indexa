"""Fetch the pinned, file-based signer; no Keychain or system installation."""
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request

ARCHIVE = 'apple-codesign-0.29.0-macos-universal.tar.gz'
SHA256 = 'd98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d'
ROOT = Path(__file__).resolve().parents[1]

def prepare():
    target = ROOT / '.local-build/rcodesign'
    marker = target.with_suffix('.archive-sha256')
    if target.is_file() and marker.is_file():
        archive_hash, binary_hash = marker.read_text().split()
        if archive_hash == SHA256 and hashlib.sha256(target.read_bytes()).hexdigest() == binary_hash:
            return target
    url = 'https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/' + ARCHIVE
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(100 * 1024 * 1024)
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise RuntimeError('rcodesign_checksum_mismatch')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        matches = [entry for entry in archive if entry.isfile() and Path(entry.name).name == 'rcodesign']
        if len(matches) != 1:
            raise RuntimeError('rcodesign_archive_invalid')
        binary = archive.extractfile(matches[0]).read()
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(binary)
    target.chmod(0o755)
    marker.write_text(SHA256 + ' ' + hashlib.sha256(binary).hexdigest())
    return target

if __name__ == '__main__':
    print(prepare())
