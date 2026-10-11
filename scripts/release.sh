#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ "$(git branch --show-current)" == main ]] || { echo 'Release from main only.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit or stash changes before releasing.' >&2; exit 1; }
git fetch origin main --tags
git merge-base --is-ancestor origin/main HEAD || { echo 'Update main from origin before releasing.' >&2; exit 1; }

latest_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main 2>/dev/null || true)
if [[ -n "$latest_tag" ]]; then
  IFS=. read -r major minor patch <<< "${latest_tag#v}"
  version="$major.$minor.$((patch + 1))"
else
  version=$(cat release/version.txt)
fi
tag="v$version"
git show-ref --verify --quiet "refs/tags/$tag" && { echo "Tag $tag already exists." >&2; exit 1; }
git tag -a "$tag" -m "Indexa $version"
git push --atomic origin HEAD:main "refs/tags/$tag"
echo "Release $tag started: https://github.com/this-is-fine-dev/indexa/actions/workflows/release.yml"
