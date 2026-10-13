#!/usr/bin/env bash
# Manual release from your Mac (no GitHub Actions needed):
#   1. builds a universal RunXcodeApp.app and packs it into a DMG
#   2. creates GitHub Release v<version> on MenubarRunApp with the DMG attached
#   3. writes Casks/runxcodeapp.rb (version + sha256) into the homebrew-tap repo and pushes
#
# Usage:  scripts/manual_release.sh 1.0.0
# Needs:  Xcode, GitHub CLI logged in (brew install gh && gh auth login)
set -euo pipefail

VERSION="${1:?usage: scripts/manual_release.sh <version, e.g. 1.0.0>}"
REPO="cse-ariful/MenubarRunApp"
TAP_REPO="cse-ariful/homebrew-tap"
TAG="v${VERSION}"

cd "$(dirname "$0")/.."
command -v gh >/dev/null || { echo "✗ GitHub CLI not found. Run: brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ Run: gh auth login" >&2; exit 1; }

# Make sure the release points at code that's actually on GitHub.
git push origin HEAD

echo "→ Building ${VERSION}"
UNIVERSAL=1 VERSION="$VERSION" ./build_app.sh --dmg
DMG="build/RunXcodeApp-${VERSION}.dmg"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

echo "→ GitHub Release ${TAG}"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" -R "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" -R "$REPO" \
    --target "$(git rev-parse HEAD)" \
    --title "RunXcodeApp ${VERSION}" \
    --generate-notes
fi

echo "→ Updating Homebrew tap ${TAP_REPO}"
if ! gh repo view "$TAP_REPO" >/dev/null 2>&1; then
  gh repo create "$TAP_REPO" --public --add-readme --description "Homebrew tap for RunXcodeApp"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP_REPO" "$WORK/tap" -- --depth 1 -q
mkdir -p "$WORK/tap/Casks"
sed -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA256}\"/" \
    packaging/homebrew/runxcodeapp.rb > "$WORK/tap/Casks/runxcodeapp.rb"
(
  cd "$WORK/tap"
  git add Casks/runxcodeapp.rb
  if git diff --cached --quiet; then
    echo "  cask already up to date"
  else
    git commit -q -m "runxcodeapp ${VERSION}"
    git push -q
  fi
)

echo
echo "✓ Released ${VERSION}  (sha256 ${SHA256})"
echo "  Install:  brew install --cask cse-ariful/tap/runxcodeapp"
echo "  Upgrade:  brew update && brew upgrade --cask runxcodeapp"
