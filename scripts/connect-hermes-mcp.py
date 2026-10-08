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


def changes(config, current_token, token, modules):
    if not isinstance(token, str) or not re.fullmatch(r'[0-9a-f]{64}', token):
        raise ValueError('invalid_token')
    if (not isinstance(modules, list) or not modules or len(modules) > 32
            or len(set(modules)) != len(modules)
            or any(not isinstance(m, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', m) for m in modules)):
        raise ValueError('invalid_modules')
    pending = []
    # Hermes pins tool_search's catalog description across this shared conversation.
    # ponytail: expose our ten tools directly; revisit search when the catalog grows
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
                from hermes_cli.mcp_config import _probe_single_server
                load = lambda: yaml.safe_load((profile / 'config.yaml').read_text()) or {}
                read_token = lambda: dotenv_values(profile / '.env').get('INDEXA_MCP_TOKEN')
                changed = synchronize(profile, token, modules, _cmd_config_set, load, read_token)
                stage = 'hermes_mcp_connection_failed'
                config = load()
                tools = sum(len(_probe_single_server('indexa-' + m, config['mcp_servers']['indexa-' + m], connect_timeout=5)) for m in modules)
        print(json.dumps({'ok': True, 'changed': changed, 'tools': tools}))
    except BaseException:
        # Never forward third-party exception text: config failures can contain credentials.
        print(json.dumps({'ok': False, 'error': stage}))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
