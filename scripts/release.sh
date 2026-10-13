#!/usr/bin/env bash
# Tags a release and pushes it; GitHub Actions builds it and updates the Homebrew tap.
#   scripts/release.sh 1.2.0
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.2.0>}"
cd "$(dirname "$0")/.."
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "✗ You have uncommitted changes. Commit them first." >&2
  exit 1
fi
git tag -a "v${VERSION}" -m "RunXcodeApp ${VERSION}"
git push origin HEAD "v${VERSION}"
echo "✓ Pushed v${VERSION}. Watch the build: gh run watch"
