#!/usr/bin/env bash
# Writes a release version and the checksums from build-xcframeworks.sh into
# Package.swift.
#
#   Scripts/update-manifest.sh 0.1.0 build/xcframeworks/checksums.txt

set -euo pipefail

VERSION="${1:?usage: update-manifest.sh VERSION CHECKSUMS_FILE}"
SUMS="${2:?usage: update-manifest.sh VERSION CHECKSUMS_FILE}"
MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/Package.swift"

perl -pi -e "s/^let version = \".*\"/let version = \"$VERSION\"/" "$MANIFEST"
while read -r module sum; do
    [[ -n "$module" ]] || continue
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
        echo "error: bad checksum for $module: $sum" >&2
        exit 1
    fi
    perl -pi -e "s/^(\s*\"$module\": )\"[0-9a-f]{64}\"/\$1\"$sum\"/" "$MANIFEST"
done < "$SUMS"

grep -E '^let version|"Moqom[A-Za-z]+": "' "$MANIFEST"
