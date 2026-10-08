"""Adopt Indexa's existing Matrix session as Hermes' Bot Chat, without copying messages.

Run with Hermes' Python and source on PYTHONPATH. Default is a read-only check;
--apply retires only an empty existing Bot Chat. Requires --profile-home and --bridge.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3


def fingerprint(connection):
    rows = connection.execute('SELECT * FROM messages ORDER BY id').fetchall()
    return hashlib.sha256(json.dumps([list(row) for row in rows], default=str).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile-home', required=True, type=Path)
    parser.add_argument('--bridge', required=True, type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    with sqlite3.connect(args.bridge.resolve().as_uri() + '?mode=ro', uri=True) as bridge:
        row = bridge.execute("SELECT value FROM meta WHERE key='conversation'").fetchone()
        if not row:
            raise SystemExit('No existing Indexa conversation to link')
        session_id = row[0]
        if args.apply and bridge.execute("SELECT 1 FROM tasks WHERE state NOT IN ('completed','failed','cancelled','interrupted') LIMIT 1").fetchone():
            raise SystemExit('Indexa has unfinished tasks; finish them before linking')

    path = args.profile_home.resolve() / 'state.db'
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as connection:
        before = fingerprint(connection)
        target = connection.execute('SELECT source FROM sessions WHERE id=?', (session_id,)).fetchone()
        if not target or target[0] != 'api_server':
            raise SystemExit('Bridge target is not an existing API session in this profile')
        if args.apply:
            backup = path.with_name('before-indexa-bot-chat.sqlite')
            fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            with sqlite3.connect(backup) as snapshot:
                connection.backup(snapshot)

    if args.apply:
        from hermes_state import SessionDB
        db = SessionDB(db_path=path)
        try:
            def adopt(conn):
                old = conn.execute("SELECT id FROM sessions WHERE title='Bot Chat' AND id<>?", (session_id,)).fetchone()
                if old:
                    # Check actual rows, not just the denormalized message count.
                    if conn.execute('SELECT 1 FROM messages WHERE session_id=? LIMIT 1', (old['id'],)).fetchone():
                        raise ValueError('Existing Bot Chat contains messages; refusing to replace it')
                    conn.execute('UPDATE sessions SET archived=1, auto_archived=0, hidden=1 WHERE id=?', (old['id'],))
                db._resolve_title_conflict(conn, session_id, 'Bot Chat')
                conn.execute("UPDATE sessions SET title='Bot Chat', title_source='user', hidden=1, archived=0, auto_archived=0 WHERE id=?", (session_id,))
            db._execute_write(adopt)
        finally:
            db.close()

    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as connection:
        canonical = connection.execute("SELECT id,hidden,archived FROM sessions WHERE title='Bot Chat'").fetchone()
        assert canonical == (session_id, 1, 0), 'FAIL: Bot Chat and Matrix point to different sessions'
        assert fingerprint(connection) == before, 'Message rows changed during linking'
    print('PASS: Bot Chat and Matrix use the same session; all message rows preserved')


if __name__ == '__main__':
    main()
