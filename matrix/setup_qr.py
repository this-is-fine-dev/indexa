"""Fresh MAS setup. Run only after explicit reset approval and with Indexa stopped."""
import asyncio
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import time
from urllib.parse import quote, urlsplit

import aiohttp
import yaml
from native_services import NativeServices, PG

ROOT = Path.home() / 'Library/Application Support/Indexa'
REPO = Path(__file__).resolve().parent.parent


async def command(*args, input=None):
    p = await asyncio.create_subprocess_exec(*map(str, args), stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        env={**os.environ, 'NO_COLOR': '1', 'TOKIO_WORKER_THREADS': '2'})
    output, _ = await p.communicate(input)
    if p.returncode:
        # Do not print CLI output: issuance commands contain access tokens.
        raise RuntimeError('setup_command_failed:' + Path(str(args[0])).name + ':' + str(args[1]))
    return output


async def setup(credentials):
    directory = ROOT / 'matrix-qr'
    if directory.exists():
        raise RuntimeError('qr_directory_exists_refusing_reset')
    previous = json.loads((ROOT / 'matrix.json').read_text())
    public = previous['homeserver'].rstrip('/')
    host = urlsplit(public).hostname
    if not host or not host.endswith('.ts.net') or urlsplit(public).scheme != 'https':
        raise RuntimeError('invalid_private_homeserver')
    directory.mkdir(mode=0o700)
    runtime = ROOT / 'runtime/mas'
    runtime.mkdir(mode=0o700, exist_ok=True)
    shutil.copy2(REPO / '.local-build/mas/matrix-authentication-service-1.26.0/target/release/mas-cli', runtime / 'mas-cli')
    shutil.copytree(REPO / '.local-build/mas/share', runtime / 'share', dirs_exist_ok=True)
    socket = ROOT / 'pgsocket'
    socket.mkdir(mode=0o700, exist_ok=True)
    await command(PG + '/initdb', '-D', directory / 'postgres', '--encoding=UTF8', '--locale=C', '--auth-local=peer', '--auth-host=scram-sha-256')
    with (directory / 'postgres/postgresql.conf').open('a') as f:
        f.write("\nlisten_addresses = ''\nport = 18767\nshared_buffers = '16MB'\nwork_mem = '1MB'\nmax_connections = 20\nmax_wal_size = '128MB'\nmin_wal_size = '80MB'\nunix_socket_permissions = 0700\n")
        f.write("unix_socket_directories = '" + str(socket).replace("'", "''") + "'\n")
    username = __import__('pwd').getpwuid(os.getuid()).pw_name
    (directory / 'postgres/pg_hba.conf').write_text(f'local indexa_mas indexa_mas peer map=indexa\nlocal all {username} peer\n')
    (directory / 'postgres/pg_ident.conf').write_text(f'indexa {username} indexa_mas\n')
    services = NativeServices(ROOT)
    try:
        await services.postgres()
        await command(PG + '/psql', '-h', socket, '-p', '18767', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1',
            input=b'CREATE ROLE indexa_mas LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;\nCREATE DATABASE indexa_mas OWNER indexa_mas;\n')
        mas = runtime / 'mas-cli'
        await command(mas, 'config', 'generate', '--output', directory / 'mas.yaml')
        auth_secret = secrets.token_hex(32)
        (directory / 'mas.secret').write_text(auth_secret)
        config = yaml.safe_load((directory / 'mas.yaml').read_text())
        share = runtime / 'share'
        config['http'] = {'public_base': public + '/', 'issuer': public + '/', 'trusted_proxies': ['127.0.0.1/32'],
            'listeners': [{'name': 'web', 'resources': [{'name': n} for n in ['discovery', 'human', 'oauth', 'compat', 'graphql']] +
                         [{'name': 'assets', 'path': str(share / 'assets')}], 'binds': [{'address': '127.0.0.1:18766'}]}]}
        config['database'] = {'socket': str(socket), 'port': 18767, 'username': 'indexa_mas', 'database': 'indexa_mas',
                              'ssl_mode': 'disable', 'max_connections': 5, 'min_connections': 0}
        config['matrix'] = {'kind': 'synapse', 'homeserver': host, 'endpoint': 'http://127.0.0.1:18765', 'secret_file': str(directory / 'mas.secret')}
        config['templates'] = {'path': str(share / 'templates'), 'assets_manifest': str(share / 'manifest.json'), 'translations_path': str(share / 'translations')}
        config['policy'] = {'wasm_module': str(share / 'policy.wasm')}
        config['account'] = {'password_registration_enabled': False, 'password_recovery_enabled': False}
        config['oauth'] = {'device_code_grant_enabled': True, 'device_code_user_code_auto_fill_enabled': True}
        (directory / 'mas.yaml').write_text(yaml.safe_dump(config))
        synapse = directory / 'homeserver.yaml'
        await command(sys.executable, '-m', 'synapse.app.homeserver', '--server-name', host,
                      '--config-path', synapse, '--generate-config', '--report-stats=no', '--data-directory', directory)
        settings = yaml.safe_load(synapse.read_text())
        settings.update(server_name=host, public_baseurl=public + '/',
            listeners=[{'port': 18765, 'type': 'http', 'tls': False, 'bind_addresses': ['127.0.0.1'],
                        'x_forwarded': True, 'resources': [{'names': ['client'], 'compress': False}]}],
            database={'name': 'sqlite3', 'args': {'database': str(directory / 'homeserver.sqlite')}},
            media_store_path=str(directory / 'media'), enable_registration=False, allow_guest_access=False,
            enable_metrics=False, report_stats=False, federation_domain_whitelist=[], trusted_key_servers=[],
            suppress_key_server_warning=True, url_preview_enabled=False, max_upload_size='5M', push={'include_content': False},
            matrix_authentication_service={'enabled': True, 'endpoint': 'http://127.0.0.1:18766/', 'secret_path': str(directory / 'mas.secret')},
            experimental_features={'msc4108_enabled': True},
            signing_key_path=str(directory / (host + '.signing.key')),
            log_config=str(directory / (host + '.log.config')), pid_file=str(directory / 'homeserver.pid'))
        settings.pop('registration_shared_secret', None)
        synapse.write_text(yaml.safe_dump(settings))
        await command(mas, 'database', 'migrate', '-c', directory / 'mas.yaml')
        await services.servers()
        tokens = {}
        for user, device, password_key, token_key in [('owner', 'INDEXA_OWNER', 'matrix-owner-password', 'matrix-owner-token'),
                                                     ('indexa', 'INDEXA_BOT', 'matrix-indexa-password', 'matrix-bot-token')]:
            await command(mas, 'manage', 'register-user', '--yes', '--no-admin', '--password-stdin', user,
                          '-c', directory / 'mas.yaml', input=credentials[password_key].encode())
            output = await command(mas, 'manage', 'issue-compatibility-token', user, device, '-c', directory / 'mas.yaml')
            match = re.search(rb'Compatibility token issued: ([A-Za-z0-9_\-]+)', output)
            if not match:
                raise RuntimeError('issued_token_missing')
            tokens[token_key] = match[1].decode()
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as session:
            async def request(path, body, token):
                async with session.post('http://127.0.0.1:18763' + path, json=body, headers={'Authorization': 'Bearer ' + token}) as response:
                    value = await response.json()
                    if response.status != 200:
                        raise RuntimeError('matrix_bootstrap_http_' + str(response.status) + ':' + str(value.get('errcode', 'unknown')))
                    return value
            bot = '@indexa:' + host
            room = await request('/_matrix/client/v3/createRoom', {'name': 'Indexa', 'preset': 'private_chat', 'is_direct': True,
                'invite': [bot], 'creation_content': {'m.federate': False}, 'initial_state': [
                    {'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}},
                    {'type': 'm.room.guest_access', 'state_key': '', 'content': {'guest_access': 'forbidden'}}]}, tokens['matrix-owner-token'])
            await request('/_matrix/client/v3/join/' + quote(room['room_id'], safe=''), {}, tokens['matrix-bot-token'])
        frame = {'homeserver': public, 'user': '@owner:' + host, 'token': tokens['matrix-owner-token'],
                 'pickle': credentials['matrix-owner-pickle'], 'store': str(directory / 'owner-crypto'), 'initialize': True}
        await command(REPO / 'matrix/qr/target/release/indexa-qr', input=json.dumps(frame).encode() + b'\n')
        # Keep reset reversible without reading or migrating the old identity.
        backup = ROOT / ('before-qr-' + time.strftime('%Y%m%d-%H%M%S'))
        backup.mkdir(mode=0o700)
        for name in ['matrix', 'matrix.json', 'bridge.sqlite', 'bridge.sqlite-wal', 'bridge.sqlite-shm']:
            path = ROOT / name
            if path.exists():
                path.rename(backup / name)
        (ROOT / 'matrix').mkdir(mode=0o700)
        (ROOT / 'matrix.json').write_text(json.dumps({'homeserver': public, 'owner_user': '@owner:' + host,
            'bot_user': bot, 'device_id': 'INDEXA_BOT', 'room_id': room['room_id'], 'qr_enabled': True}, indent=2))
        return tokens
    finally:
        await services.stop()


if __name__ == '__main__':
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384:
            raise RuntimeError('credential_frame_too_large')
        credentials = json.loads(raw)
        expected = {'matrix-owner-password', 'matrix-indexa-password', 'matrix-owner-pickle'}
        if set(credentials) != expected or not all(isinstance(x, str) and 16 <= len(x) <= 4096 for x in credentials.values()):
            raise RuntimeError('invalid_credentials')
        print(json.dumps(asyncio.run(setup(credentials))))
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else type(error).__name__, file=sys.stderr)
        sys.exit(1)
