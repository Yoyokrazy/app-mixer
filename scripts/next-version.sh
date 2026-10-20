#!/usr/bin/env bash
# Prints the next release version (without the leading "v") from the Conventional Commits since the
# latest vX.Y.Z tag, or nothing if there's nothing to release:
#   breaking change (`type!:` or a BREAKING CHANGE footer) → major
#   feat                                                    → minor
#   anything else except docs/test/ci/chore/style           → patch
# Commits that are only docs/test/ci/chore/style don't produce a release unless --force is given,
# which turns them into a patch release. No commits since the last tag never produces a release.
set -euo pipefail

force=false
[[ "${1:-}" == "--force" ]] && force=true

previous=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)
range=${previous:+$previous..}HEAD

subjects=$(git log --no-merges --format=%s "$range")
[[ -z "$subjects" ]] && exit 0
bodies=$(git log --no-merges --format=%B "$range")

bump=""
if grep -qE '^[a-zA-Z]+(\([^)]*\))?!:' <<<"$subjects" || grep -qE '^BREAKING[ -]CHANGE:' <<<"$bodies"; then
  bump=major
elif grep -qE '^feat(\([^)]*\))?:' <<<"$subjects"; then
  bump=minor
elif grep -qvE '^(docs|test|tests|ci|chore|style)(\([^)]*\))?:' <<<"$subjects" || $force; then
  bump=patch
fi
[[ -z "$bump" ]] && exit 0

IFS=. read -r major minor patch <<<"${previous#v}"
major=${major:-0} minor=${minor:-0} patch=${patch:-0}
case "$bump" in
  major) major=$((major + 1)) minor=0 patch=0 ;;
  minor) minor=$((minor + 1)) patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
echo "$major.$minor.$patch"
