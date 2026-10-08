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
        if Path(src).name == 'staged':
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
# Simulate a real process death, bypassing finally, at each filesystem commit point.
import subprocess
import sys
for point in ('pending', 'indexa-notes'):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source, target = root / 'bundle', root / 'profile/plugins/indexa-notes'
        source.mkdir(); target.mkdir(parents=True)
        for name in ('__init__.py', 'notes.js', 'plugin.yaml'):
            (source / name).write_text('new'); (target / name).write_text('old')
        script = """
import importlib.util, os, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('runtime',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rename=m.os.rename
def die(src,dst):
    rename(src,dst)
    if Path(dst).name == sys.argv[4]: os._exit(23)
m.os.rename=die
m.install_plugin(Path(sys.argv[2]),Path(sys.argv[3]))
"""
        result = subprocess.run([sys.executable, '-B', '-c', script, runtime.__file__, str(source), str(target), point])
        assert result.returncode == 23
        runtime.recover_plugin(target)
        assert (target / '__init__.py').read_text() == ('old' if point == 'pending' else 'new')
        assert not (root / 'profile/indexa-plugin-backups/pending').exists()
        runtime.install_plugin(source, target)
        assert (target / '__init__.py').read_text() == 'new'
with patch.object(runtime.importlib.metadata, 'version', return_value='wrong'):
    try:
        runtime.check_versions({'format': 1, 'python': '.'.join(map(str, runtime.sys.version_info[:2])),
                                'packages': {'matrix-synapse': '1.162.0'}}, Path('/unused'))
        assert False, 'incompatible native dependencies must block an update'
    except RuntimeError as error:
        assert str(error) == 'runtime_package_incompatible:matrix-synapse'
print('runtime compatibility, update and rollback: OK')
