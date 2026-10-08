"""Synchronize only Indexa-owned MCP settings through Hermes' CLI command handler.

The access token arrives on stdin, never argv. Hermes owns config/.env serialization.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import sys
from types import SimpleNamespace
import tempfile
import asyncio
import hashlib


async def probe_catalog(token, modules):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client, create_mcp_http_client
    catalog = {}
    async with create_mcp_http_client(headers={'Authorization': 'Bearer ' + token}) as http:
        for module in modules:
            async with streamable_http_client('http://127.0.0.1:43121/mcp/' + module, http_client=http) as streams:
                async with ClientSession(*streams[:2]) as session:
                    await session.initialize()
                    listed = await session.list_tools()
                    catalog[module] = [tool.model_dump(mode='json', exclude_none=True) for tool in listed.tools]
    return catalog


def refresh_conversation_cache(profile, catalog, session_db):
    # Hermes persists tool schemas AND persona text. Refresh these snapshots only
    # when their inputs change; history, IDs, model and persona remain intact.
    soul = (profile / 'SOUL.md').read_text() if (profile / 'SOUL.md').exists() else ''
    fingerprint = hashlib.sha256(json.dumps([catalog, soul], sort_keys=True).encode()).hexdigest()
    marker = profile / 'indexa-catalog-fingerprint'
    if marker.exists() and marker.read_text() == fingerprint:
        return False
    sessions = session_db.list_sessions_rich(search_query='Bot Chat', include_hidden=True,
                                             order_by_last_active=True, limit=100)
    for session in sessions:
        if session.get('title') != 'Bot Chat' or session.get('archived'):
            continue
        session_id = session_db.get_compression_tip(session['id']) or session['id']
        session_db.update_session_tool_names(session_id, None)
        session_db.update_system_prompt(session_id, None)
    marker.write_text(fingerprint)
    marker.chmod(0o600)
    return True


def synchronize_style(profile):
    """One owned section; preserve the user's persona and keep a first-change backup."""
    path = profile / 'SOUL.md'
    previous = path.read_text() if path.exists() else ''
    start, end = '<!-- indexa-style:start -->', '<!-- indexa-style:end -->'
    block = start + '''
## Rozmowa w Indexie

Odpowiadaj naturalnie, krótko i po polsku. Najpierw wynik, zwykle 1–3 zdania.
Nie relacjonuj narzędzi, liczby rekordów, MCP, API, identyfikatorów ani kodów błędów,
chyba że użytkownik poprosi o szczegóły techniczne. Powiedz po prostu, co ustaliłeś,
czego nie udało się sprawdzić i jaki jest następny krok. Bez urzędowego tonu,
automatycznego „Masz rację”, zbędnych przeprosin i wyliczania wykonanych kroków.
Nie ukrywaj niepewności i nie deklaruj niepotwierdzonego sukcesu.

Pytanie o urlop obejmuje też loty i noclegi. Dla wskazanego okresu najpierw
przejrzyj wydarzenia bez filtra tytułu i wszystkie strony next_offset.
Historycznych rezerwacji nie przedstawiaj jako przyszłego urlopu.
Brak wpisu w danych Indexy nie dowodzi braku wpisu w aplikacji Kalendarz;
sugestie Siri mogą być widoczne w niej osobno od zapisanych wydarzeń.
''' + end
    if start in previous:
        before, remaining = previous.split(start, 1)
        if end not in remaining:
            raise ValueError('invalid_indexa_style_section')
        updated = before + block + remaining.split(end, 1)[1]
    else:
        updated = previous.rstrip() + '\n\n' + block + '\n'
    if updated == previous:
        return False
    backup = profile / 'indexa-persona-before-style.md'
    if previous and not backup.exists():
        with os.fdopen(os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600), 'w') as file:
            file.write(previous)
    with tempfile.NamedTemporaryFile(mode='w', dir=profile, prefix='.indexa-style-', delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(updated); file.flush(); os.fsync(file.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return True


def changes(config, current_token, token, modules):
    if not isinstance(token, str) or not re.fullmatch(r'[0-9a-f]{64}', token):
        raise ValueError('invalid_token')
    if (not isinstance(modules, list) or not modules or len(modules) > 32
            or len(set(modules)) != len(modules)
            or any(not isinstance(m, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', m) for m in modules)):
        raise ValueError('invalid_modules')
    pending = []
    # Hermes pins tool_search's catalog description across this shared conversation.
    # ponytail: expose our small catalog directly; revisit search when it grows
    # and Hermes refreshes pinned catalog descriptions after MCP changes.
    search = (config.get('tools') or {}).get('tool_search')
    if not isinstance(search, dict) or search.get('enabled') != 'off':
        pending.append(('tools.tool_search.enabled', 'off'))
    if current_token != token:
        pending.append(('INDEXA_MCP_TOKEN', token))
    servers = config.get('mcp_servers') or {}
    names = ['indexa-' + module for module in modules]
    for module, name in zip(modules, names):
        desired = {
            'url': 'http://127.0.0.1:43121/mcp/' + module,
            'headers': {'Authorization': 'Bearer ${INDEXA_MCP_TOKEN}'},
            'enabled': True, 'sampling': {'enabled': False},
        }
        if servers.get(name) != desired:
            pending.append(('mcp_servers.' + name, json.dumps(desired)))
    if 'notes' in modules:
        plugins = config.get('plugins') or {}
        enabled = plugins.get('enabled') or []
        disabled = plugins.get('disabled') or []
        if 'indexa-notes' in enabled:
            pending.append(('plugins.enabled', json.dumps([x for x in enabled if x != 'indexa-notes'])))
        if 'indexa-notes' not in disabled:
            pending.append(('plugins.disabled', json.dumps([*disabled, 'indexa-notes'])))
    # Migrate the old narrow toolset; preserve every other native/MCP selection.
    # An implicit MCP allowlist stays implicit, so unrelated servers remain available.
    for platform, selected in (config.get('platform_toolsets') or {}).items():
        if platform not in ('api_server', 'cli') or not isinstance(selected, list):
            continue
        if 'indexa_notes' in selected:
            updated = list(dict.fromkeys([*('indexa-notes' if x == 'indexa_notes' else x for x in selected if x != 'no_mcp'), *names]))
            pending.append(('platform_toolsets.' + platform, json.dumps(updated)))
        elif 'no_mcp' in selected:
            updated = list(dict.fromkeys([*(x for x in selected if x != 'no_mcp'), *names]))
            pending.append(('platform_toolsets.' + platform, json.dumps(updated)))
        elif set(selected).intersection(servers):
            updated = list(dict.fromkeys([*selected, *names]))
            if updated != selected:
                pending.append(('platform_toolsets.' + platform, json.dumps(updated)))
    disabled_tools = (config.get('agent') or {}).get('disabled_toolsets')
    if isinstance(disabled_tools, list) and set(disabled_tools).intersection(names):
        pending.append(('agent.disabled_toolsets', json.dumps([x for x in disabled_tools if x not in names])))
    return pending


def synchronize(profile, token, modules, writer, load, read_token):
    pending = changes(load(), read_token(), token, modules)
    for key, value in pending:
        writer(SimpleNamespace(key=key, value=value, force=False))
    # A CLI refusal or partial save must never be reported as successful.
    if changes(load(), read_token(), token, modules):
        raise RuntimeError('hermes_mcp_settings_not_saved')
    env = profile / '.env'
    if env.exists():
        env.chmod(0o600)
    return bool(pending)


def main():
    stage = 'hermes_mcp_setup_failed'
    try:
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384 or len(sys.argv) != 3:
            raise ValueError('invalid_request')
        request = json.loads(raw)
        token, modules = request['token'], request['modules']
        changes({}, None, token, modules)
        source, profile = Path(sys.argv[1]), Path(sys.argv[2])
        if not (source / 'hermes_bootstrap.py').is_file() or not (profile / 'config.yaml').is_file():
            raise RuntimeError('hermes_profile_missing')
        os.environ['HERMES_HOME'] = str(profile)
        os.environ['INDEXA_MCP_TOKEN'] = token
        sys.path.insert(0, str(source))
        # Serialize startup/manual retry/rotation without exposing token-bearing diagnostics.
        descriptor = os.open(profile / 'indexa-mcp-setup.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as lock, open(os.devnull, 'w') as quiet:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
                import hermes_bootstrap  # noqa: F401 — use Hermes' selected dependencies
                import yaml
                from dotenv import dotenv_values
                from hermes_cli.config import _cmd_config_set
                load = lambda: yaml.safe_load((profile / 'config.yaml').read_text()) or {}
                read_token = lambda: dotenv_values(profile / '.env').get('INDEXA_MCP_TOKEN')
                changed = synchronize(profile, token, modules, _cmd_config_set, load, read_token)
                changed = synchronize_style(profile) or changed
                stage = 'hermes_mcp_connection_failed'
                catalog = asyncio.run(asyncio.wait_for(probe_catalog(token, modules), 25))
                tools = sum(map(len, catalog.values()))
                from hermes_state import SessionDB
                database = SessionDB(profile / 'state.db')
                try:
                    changed = refresh_conversation_cache(profile, catalog, database) or changed
                finally:
                    database.close()
        print(json.dumps({'ok': True, 'changed': changed, 'tools': tools}))
    except BaseException:
        # Never forward third-party exception text: config failures can contain credentials.
        print(json.dumps({'ok': False, 'error': stage}))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
