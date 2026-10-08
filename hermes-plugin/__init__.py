"""One narrow Hermes tool. No shell, deletion, broad Notes search, or second LLM."""
import fcntl
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import uuid


def validate(args):
    if not isinstance(args, dict) or args.get('action') not in ('create', 'append', 'read'):
        raise ValueError('invalid_action')
    for field in ('title', 'text', 'note_id', 'operation_id'):
        if field in args and (not isinstance(args[field], str) or len(args[field].encode()) > 16384):
            raise ValueError('invalid_' + field)
    if args['action'] in ('append', 'read') and not args.get('note_id', '').startswith('x-coredata://'):
        raise ValueError('note_id_required')
    if args['action'] != 'read':
        uuid.UUID(args.get('operation_id', ''))
        if not args.get('text', '').strip():
            raise ValueError('text_required')
    if args['action'] == 'create' and (not args.get('title', '').strip() or len(args['title']) > 200):
        raise ValueError('title_required_max_200')
    return args


def invoke(args):
    result = subprocess.run(
        ['/usr/bin/osascript', '-l', 'JavaScript', str(pathlib.Path(__file__).with_name('notes.js'))],
        input=json.dumps(args, ensure_ascii=False), capture_output=True, text=True, timeout=40,
    )
    if result.returncode:
        # Never return script stderr: it can contain private note content.
        return {'error': 'notes_automation_failed', 'needs_review': args['action'] != 'read'}
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or value.get('verified') is not True:
        return {'error': 'notes_readback_failed', 'needs_review': args['action'] != 'read'}
    return value


def handle(args, **kwargs):
    try:
        validate(args)
        if args['action'] == 'read':
            return json.dumps(invoke(args), ensure_ascii=False)
        from hermes_cli.config import get_hermes_home
        ledger = get_hermes_home() / 'indexa-notes.sqlite'
        with ledger.with_suffix('.lock').open('a') as lock, sqlite3.connect(ledger, timeout=5) as db:
            ledger.with_suffix('.lock').chmod(0o600)
            # Native review uses this same lock; a live write can never be marked reviewed.
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ledger.chmod(0o600)
            db.execute('PRAGMA synchronous=FULL')
            db.execute('CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, digest TEXT, state TEXT, result TEXT)')
            digest = hashlib.sha256(json.dumps(args, sort_keys=True).encode()).hexdigest()
            prior = db.execute('SELECT digest,state,result FROM operations WHERE id=?', (args['operation_id'],)).fetchone()
            if prior:
                if prior[0] != digest:
                    return json.dumps({'error': 'operation_id_conflict'})
                return prior[2] or json.dumps({'error': 'operation_unknown_do_not_repeat', 'needs_review': True})
            if db.execute("SELECT 1 FROM operations WHERE state='pending' LIMIT 1").fetchone():
                return json.dumps({'error': 'previous_write_needs_review', 'needs_review': True})
            from tools.approval import request_tool_approval
            consent = request_tool_approval('indexa_notes', 'Utworzenie notatki w folderze Indexa' if args['action'] == 'create' else 'Dopisanie tekstu do wskazanej notatki Indexa', rule_key='indexa-notes-' + args['operation_id'])
            if not consent.get('approved'):
                return json.dumps({'error': 'permission_denied', 'written': False})
            db.execute('BEGIN IMMEDIATE')
            # Recheck under the write lock after the potentially long approval wait.
            if db.execute('SELECT 1 FROM operations WHERE id=? OR state=? LIMIT 1', (args['operation_id'], 'pending')).fetchone():
                db.rollback()
                return json.dumps({'error': 'concurrent_or_uncertain_operation', 'needs_review': True})
            db.execute('INSERT INTO operations VALUES(?,?,?,NULL)', (args['operation_id'], digest, 'pending'))
            db.commit()
            result = invoke(args)
            encoded = json.dumps(result, ensure_ascii=False)
            if result.get('verified'):
                # Store only identity + verification, not private contents, in the idempotency ledger.
                durable = json.dumps({k:result[k] for k in ('note_id','verified') if k in result})
                db.execute('UPDATE operations SET state=?,result=? WHERE id=?', ('done', durable, args['operation_id']))
                db.commit()
            return encoded
    except (ValueError, TypeError, KeyError):
        return json.dumps({'error': 'invalid_notes_request'})
    except subprocess.TimeoutExpired:
        return json.dumps({'error': 'notes_timeout_do_not_repeat', 'needs_review': True})
    except Exception:
        return json.dumps({'error': 'notes_unavailable', 'needs_review': True})


def register(ctx):
    ctx.register_tool(name='indexa_notes', toolset='indexa_notes', handler=handle, schema={
        'name': 'indexa_notes',
        'description': 'Create, append, or read an exact Apple Note in folder Indexa. Writes require human approval. Keep returned note_id for continuation. Each new write uses a UUID operation_id; retry uses the same ID. Never retry needs_review with a new ID. verified=true confirms read-back. No deletion.',
        'parameters': {'type':'object','properties': {
            'action': {'type':'string','enum':['create','append','read']},
            'title': {'type':'string'}, 'text': {'type':'string'},
            'note_id': {'type':'string'}, 'operation_id': {'type':'string'},
        }, 'required':['action'], 'additionalProperties':False},
    })
