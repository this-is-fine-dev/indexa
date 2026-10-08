"""Indexa's local Notes worker. MCP authorization happens before this process starts."""
import os
import json
import pathlib
import sys

from __init__ import handle_core


def main():
    try:
        # Foundation Process already creates a private process group on macOS.
        # Calling setsid() as its leader fails with EPERM before handling input.
        if os.getpgrp() != os.getpid():
            os.setsid()
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536 or len(sys.argv) != 2:
            raise ValueError('invalid_request')
        home = pathlib.Path(sys.argv[1])
        if not home.is_dir():
            raise ValueError('profile_missing')
        result = handle_core(json.loads(raw), home, lambda _: True)
        # A very large note is not returned to the model or accumulated by the parent.
        if len(result.encode()) > 524288:
            result = json.dumps({'error': 'note_too_large'})
    except Exception:
        result = json.dumps({'error': 'invalid_notes_request'})
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
