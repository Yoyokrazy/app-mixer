#!/bin/bash
# Adopts the images a CI run rendered as that runner's snapshot references.
#
# When the Snapshots workflow fails, it prints every rendered (actual) image into its log as a base64 tar.gz,
# so this works even when artifact storage is full. Each image is copied to
# AppMixerSnapshotTests/__Snapshots__/<environment>/<name>.png; review and commit them.
#
# Usage: scripts/adopt-ci-snapshots.sh <run id>    (or: make adopt-ci-snapshots RUN=<run id>)
set -euo pipefail

run=${1:?usage: $0 <run id>}
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Log lines are "<job>\t<step>\t<timestamp> <text>"; the archive sits between two marker lines.
gh run view "$run" --log \
    | awk -F '\t' '
        { line = $3; sub(/^[^ ]* /, "", line); sub(/\r$/, "", line) }
        line == "END-SNAPSHOT-ARCHIVE" { inside = 0 }
        inside { print line }
        line == "BEGIN-SNAPSHOT-ARCHIVE" { inside = 1 }
    ' > "$scratch/archive.b64"

if [[ ! -s "$scratch/archive.b64" ]]; then
    echo "Run $run's log has no snapshot images (it only prints them when snapshot tests fail)." >&2
    exit 1
fi
base64 --decode < "$scratch/archive.b64" | tar -xzf - -C "$scratch"

count=0
while IFS= read -r -d '' image; do
    environment=$(basename "$(dirname "$image")")
    name=$(basename "$image" .actual.png)
    mkdir -p "$root/AppMixerSnapshotTests/__Snapshots__/$environment"
    cp "$image" "$root/AppMixerSnapshotTests/__Snapshots__/$environment/$name.png"
    echo "Adopted $environment/$name.png"
    count=$((count + 1))
done < <(find "$scratch" -name '*.actual.png' -print0)

echo "Adopted $count image(s) from run $run. Review them, then commit."
