import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('guard', Path(__file__).parents[1] / 'scripts/check-release.py')
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
complete = {'assets': [{'name': 'Indexa-0.5.3.zip', 'size': 42}, {'name': 'appcast.xml', 'size': 10}], 'draft': False}
assert guard.already_published(complete, 'v0.5.3')
for invalid in ({'assets': complete['assets'][:1]}, {**complete, 'draft': True},
                {'assets': [{'name': 'Indexa-0.5.3.zip', 'size': 0}, complete['assets'][1]]}):
    try:
        guard.already_published(invalid, 'v0.5.3')
        assert False, 'Never replace partially published signed artifacts'
    except RuntimeError:
        pass
print('PASS: release reruns preserve complete artifacts and reject partial/draft releases')

assert guard.newer_than_latest('v0.5.4', {'tag_name': 'v0.5.3'})
assert guard.newer_than_latest('v0.10.0', {'tag_name': 'v0.9.9'})
assert not guard.newer_than_latest('v0.5.3', {'tag_name': 'v0.5.4'})
assert not guard.newer_than_latest('v0.5.4', {'tag_name': 'v0.5.4'})
assert not guard.newer_than_latest('v0.5.4', {'tag_name': 'custom-name'})
assert guard.newer_than_latest('v0.5.4', None)
print('PASS: releasing an older tag cannot demote the latest release')
