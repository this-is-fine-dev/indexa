"""Synthetic configuration checks; no real Hermes profile or credentials are used."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('connect_mcp', Path(__file__).parents[1] / 'scripts/connect-hermes-mcp.py')
connector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(connector)


class HermesMCPTests(unittest.TestCase):
    def test_setup_idempotence_rotation_and_unrelated_configuration(self):
        config = {
            'model': {'default': 'user-model'},
            'mcp_servers': {'unrelated': {'url': 'https://example.com/mcp'}},
            'plugins': {'enabled': ['other', 'indexa-notes'], 'disabled': ['already-off']},
            'platform_toolsets': {'api_server': ['indexa_notes'], 'cli': ['hermes-cli']},
        }
        original = copy.deepcopy(config)
        credential, writes = [None], []
        def writer(args):
            writes.append(args.key)
            if args.key == 'INDEXA_MCP_TOKEN':
                credential[0] = args.value
                return
            keys, target = args.key.split('.'), config
            for key in keys[:-1]:
                target = target.setdefault(key, {})
            target[keys[-1]] = json.loads(args.value)
        with tempfile.TemporaryDirectory() as directory:
            def sync(token):
                return connector.synchronize(Path(directory), token, ['notes'], writer, lambda: copy.deepcopy(config), lambda: credential[0])
            self.assertTrue(sync('a' * 64))
            self.assertEqual(config['model'], original['model'])
            self.assertEqual(config['mcp_servers']['unrelated'], original['mcp_servers']['unrelated'])
            self.assertEqual(config['platform_toolsets']['cli'], ['hermes-cli'])
            self.assertEqual(config['platform_toolsets']['api_server'], ['indexa-notes'])
            self.assertEqual(config['plugins']['enabled'], ['other'])
            self.assertEqual(config['plugins']['disabled'], ['already-off', 'indexa-notes'])
            self.assertNotIn('a' * 64, json.dumps(config))
            writes.clear()
            self.assertFalse(sync('a' * 64))
            self.assertEqual(writes, [])
            self.assertTrue(sync('b' * 64))
            self.assertEqual(writes, ['INDEXA_MCP_TOKEN'])
            writes.clear()
            self.assertTrue(connector.synchronize(Path(directory), 'b' * 64, ['notes', 'calendar', 'reminders'], writer, lambda: copy.deepcopy(config), lambda: credential[0]))
            self.assertEqual(config['platform_toolsets']['api_server'], ['indexa-notes', 'indexa-calendar', 'indexa-reminders'])
            self.assertFalse(connector.synchronize(Path(directory), 'b' * 64, ['notes', 'calendar', 'reminders'], writer, lambda: copy.deepcopy(config), lambda: credential[0]))

    def test_explicit_allowlist_preserves_other_servers_and_does_not_enable_all(self):
        config = {'mcp_servers': {'chosen': {}, 'unselected': {}},
                  'platform_toolsets': {'cli': ['file', 'chosen'], 'api_server': ['no_mcp']}}
        pending = dict(connector.changes(config, 'a' * 64, 'a' * 64, ['notes']))
        self.assertEqual(json.loads(pending['platform_toolsets.cli']), ['file', 'chosen', 'indexa-notes'])
        self.assertEqual(json.loads(pending['platform_toolsets.api_server']), ['indexa-notes'])

    def test_invalid_requests_and_failed_writes_never_report_success(self):
        for token, modules in [('bad', ['notes']), ('a' * 64, ['../other']), ('a' * 64, ['notes', 'notes'])]:
            with self.assertRaises(ValueError):
                connector.changes({}, None, token, modules)
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(RuntimeError):
            connector.synchronize(Path(directory), 'a' * 64, ['notes'], lambda _: None, lambda: {}, lambda: None)


if __name__ == '__main__':
    unittest.main()
