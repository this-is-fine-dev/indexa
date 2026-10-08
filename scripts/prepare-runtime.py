#!/usr/bin/env python3
"""Check external native dependencies, then atomically update the bundled Notes plugin.

Database schemas and native dependencies are deliberately not upgraded here. A release
requiring different versions must provide a separately tested migration first.
"""
import importlib.metadata
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


def check_versions(manifest, root):
    if manifest['format'] != 1:
        raise RuntimeError('runtime_manifest_unsupported')
    if '.'.join(map(str, sys.version_info[:2])) != manifest['python']:
        raise RuntimeError('runtime_python_incompatible')
    for package, expected in manifest['packages'].items():
        if importlib.metadata.version(package) != expected:
            raise RuntimeError('runtime_package_incompatible:' + package)
    for executable, expected, code in [
        (root / 'runtime/mas/mas-cli', manifest['mas'], 'mas'),
        (Path('/opt/homebrew/opt/postgresql@17/bin/postgres'), manifest['postgres_major'], 'postgres'),
    ]:
        result = subprocess.run([str(executable), '--version'], capture_output=True, text=True, timeout=10, check=True)
        versions = [part.strip('(),') for part in result.stdout.split()]
        matches = (expected in versions) if code == 'mas' else any(v.split('.')[0] == expected for v in versions)
        # The pinned native MAS build uses reproducible vergen output, not a version string.
        if code == 'mas':
            with executable.open('rb') as binary:
                matches = hashlib.file_digest(binary, 'sha256').hexdigest() == manifest['mas_sha256']
        if not matches:
            raise RuntimeError('runtime_' + code + '_incompatible')


def install_plugin(source, destination):
    names = ('__init__.py', 'notes.js', 'plugin.yaml')
    # Keep backups outside plugins/, so Hermes cannot discover a duplicate plugin.
    if all((destination / n).is_file() and (destination / n).read_bytes() == (source / n).read_bytes() for n in names):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    backup_root = destination.parent.parent / 'indexa-plugin-backups'
    backup_root.mkdir(mode=0o700, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.indexa-update-', dir=backup_root))
    backup = backup_root / str(uuid.uuid4())
    moved = False
    try:
        for name in names:
            shutil.copy2(source / name, stage / name)
        if destination.exists():
            os.rename(destination, backup)
            moved = True
        try:
            os.rename(stage, destination)
        except BaseException:
            if moved:
                os.rename(backup, destination)
            raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    resources = Path(sys.argv[1])
    root = Path(sys.argv[2])
    manifest = json.loads((resources / 'stack.json').read_text())
    check_versions(manifest, root)
    profile = Path.home() / '.hermes/profiles' / manifest['hermes_profile']
    if not (profile / 'config.yaml').is_file():
        raise RuntimeError('runtime_hermes_profile_missing')
    install_plugin(resources / 'hermes-plugin', profile / 'plugins/indexa-notes')
    print('runtime_compatible')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never include process output, paths, configuration or credentials in diagnostics.
        print(str(error) if isinstance(error, RuntimeError) else 'runtime_preflight_failed', file=sys.stderr)
        sys.exit(1)
