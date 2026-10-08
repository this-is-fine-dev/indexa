"""Synthetic boundary checks: no real Notes access."""
import importlib.util
import pathlib
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).parents[1] / 'hermes-plugin' / '__init__.py'
spec = importlib.util.spec_from_file_location('indexa_notes', path)
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)

class NotesTests(unittest.TestCase):
    def test_validation_prevents_script_injection_and_unknown_operations(self):
        with self.assertRaises(ValueError):
            notes.validate({'action':'delete','note_id':'anything'})
        with self.assertRaises(ValueError):
            notes.validate({'action':'append','text':'x','operation_id':'not-a-uuid'})
        valid={'action':'create','title':'"; do shell script "bad', 'text':'<script>żółć</script>', 'operation_id':'11111111-1111-4111-8111-111111111111'}
        self.assertEqual(notes.validate(valid),valid)

    def test_transport_does_not_put_private_text_in_argv(self):
        import json, subprocess
        args={'action':'read','note_id':'x-coredata://fixture'}
        with patch.object(notes.subprocess,'run',return_value=subprocess.CompletedProcess([],0,json.dumps({'verified':True,'note_id':'x-coredata://fixture'}),'')) as run:
            result=notes.invoke(args)
            self.assertTrue(result['verified'])
            self.assertNotIn('x-coredata://fixture', ' '.join(run.call_args.args[0]))
            self.assertEqual(json.loads(run.call_args.kwargs['input']),args)

if __name__ == '__main__':
    unittest.main()
