"""Skip complete published releases and never overwrite a tag's signed artifacts."""
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request


def already_published(release, tag):
    expected = {f'Indexa-{tag[1:]}.zip', 'appcast.xml'}
    assets = {asset['name'] for asset in release.get('assets', []) if asset.get('size', 0) > 0}
    if not expected <= assets or release.get('draft'):
        raise RuntimeError('Existing release is incomplete or draft; refusing to replace signed artifacts. Use a new version tag.')
    return True


def get_release(repository, suffix):
    request = urllib.request.Request(f'https://api.github.com/repos/{repository}/releases/{suffix}',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        return None


def newer_than_latest(tag, latest):
    if latest is None:
        return True
    previous = latest.get('tag_name', '')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', previous):
        return False
    return tuple(map(int, tag[1:].split('.'))) > tuple(map(int, previous[1:].split('.')))


def main():
    tag = os.environ['GITHUB_REF_NAME']
    if not re.fullmatch(r'v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}', tag):
        raise RuntimeError('Select an existing version tag vX.Y.Z, not a branch, to run Release.')
    repository = os.environ['GITHUB_REPOSITORY']
    release = get_release(repository, 'tags/' + tag)
    if release is None:
        latest = newer_than_latest(tag, get_release(repository, 'latest'))
        with Path(os.environ['GITHUB_ENV']).open('a') as environment:
            environment.write('INDEXA_MAKE_LATEST=' + str(latest).lower() + '\n')
        print('No published release for this tag; building a new signed archive.')
    elif already_published(release, tag):
        with Path(os.environ['GITHUB_ENV']).open('a') as environment:
            environment.write('ALREADY_RELEASED=true\n')
        print('Release already contains ZIP and appcast; keeping the published artifacts and latest release unchanged.')


if __name__ == '__main__':
    main()
