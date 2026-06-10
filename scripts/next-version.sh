#!/usr/bin/env bash
# Decides the next semantic version from git tags and the commits since the last tag.
#
# Output (GITHUB_OUTPUT key=value format):
#   skip=true                 when there are no new commits since the latest tag
#   skip=false
#   version=X.Y.Z             (only when skip=false)
#
# Bump rules for commits since the last vX.Y.Z tag (first match wins):
#   "#major", "BREAKING CHANGE", or a conventional `type!:` subject  -> major
#   "#minor" or a `feat:` / `feat(scope):` subject                   -> minor
#   anything else                                                    -> patch
# With no existing tags the first version is 1.0.0.
set -euo pipefail

latest=$(git tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)

if [ -z "$latest" ]; then
  echo "skip=false"
  echo "version=1.0.0"
  exit 0
fi

if [ "$(git rev-list "$latest..HEAD" --count)" -eq 0 ]; then
  echo "skip=true"
  exit 0
fi

base=${latest#v}
IFS=. read -r major minor patch <<< "$base"

log=$(git log "$latest..HEAD" --pretty='%s%n%b')

if grep -qiE '#major|BREAKING CHANGE' <<< "$log" || grep -qE '^[a-z]+(\([^)]*\))?!:' <<< "$log"; then
  major=$((major + 1)); minor=0; patch=0
elif grep -qi '#minor' <<< "$log" || grep -qE '^feat(\([^)]*\))?:' <<< "$log"; then
  minor=$((minor + 1)); patch=0
else
  patch=$((patch + 1))
fi

echo "skip=false"
echo "version=$major.$minor.$patch"
