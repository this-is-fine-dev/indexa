import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).parents[1] / 'scripts/prepare-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    source, target = root / 'bundle', root / 'profile/plugins/indexa-notes'
    source.mkdir()
    target.mkdir(parents=True)
    for name in ('__init__.py', 'notes.js', 'plugin.yaml'):
        (source / name).write_text('new')
        (target / name).write_text('old')
    original = runtime.os.rename
    def fail_install(src, dst):
        if Path(src).name.startswith('.indexa-update-'):
            raise OSError('simulated install interruption')
        return original(src, dst)
    with patch.object(runtime.os, 'rename', fail_install):
        try:
            runtime.install_plugin(source, target)
            assert False, 'must fail'
        except OSError:
            pass
    assert (target / '__init__.py').read_text() == 'old', 'failed install must restore old plugin'
    runtime.install_plugin(source, target)
    assert (target / '__init__.py').read_text() == 'new'
    backups = list((root / 'profile/indexa-plugin-backups').iterdir())
    assert len(backups) == 1 and (backups[0] / '__init__.py').read_text() == 'old'
    runtime.install_plugin(source, target)
    assert list((root / 'profile/indexa-plugin-backups').iterdir()) == backups, 'unchanged plugin must not rewrite'
with patch.object(runtime.importlib.metadata, 'version', return_value='wrong'):
    try:
        runtime.check_versions({'format': 1, 'python': '.'.join(map(str, runtime.sys.version_info[:2])),
                                'packages': {'matrix-synapse': '1.162.0'}}, Path('/unused'))
        assert False, 'incompatible native dependencies must block an update'
    except RuntimeError as error:
        assert str(error) == 'runtime_package_incompatible:matrix-synapse'
print('runtime compatibility, update and rollback: OK')
