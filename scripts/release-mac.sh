#!/bin/bash
# Ships a Mac update on its own: packages WreckBox (scripts/package-mac.sh), tags this repo mac-v<version> and
# publishes the zip as release mac-v<version> in moloyb301-eng/wreckbox-releases. It's not marked "latest", so the
# phone app's update check (which reads the latest release) is untouched. Mac apps find it within 30 minutes; the
# friends' download page (https://wreckbox-api.moloyb301.workers.dev/download) shows it within 5.
#
#   scripts/release-mac.sh 0.6.1                  release notes = commit titles since the last Mac release
#   scripts/release-mac.sh 0.6.1 "Fixed X" "Y"    your own notes, one bullet each
set -e
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release-mac.sh <version> [note …]}"
shift
REPO=moloyb301-eng/wreckbox-releases
TAG="mac-v$VERSION"

[ -z "$(git status --porcelain -- Sources scripts soulseek youtube analysis Package.swift)" ] || { echo "Commit your changes first."; exit 1; }
git pull --rebase --quiet
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then echo "$TAG is already released."; exit 1; fi

# Notes: given, or this repo's commit titles since the previous Mac release.
NOTES=$(mktemp)
if [ $# -gt 0 ]; then
  for n in "$@"; do echo "- $n"; done > "$NOTES"
else
  PREV=$(git tag --list 'mac-v*' --sort=-v:refname | head -1)
  git log --format='- %s' ${PREV:+"$PREV"..}HEAD | grep -v '^- Merge' | head -20 > "$NOTES"
fi
printf '\nMac (Apple Silicon, macOS 13+): unzip, move WreckBox to Applications. First time: Done, then System Settings → Privacy & Security → Open Anyway.\nAll downloads: https://wreckbox-api.moloyb301.workers.dev/download\n' >> "$NOTES"

scripts/package-mac.sh "$VERSION"
git tag "$TAG" && git push --quiet origin "$TAG"
gh release create "$TAG" dist/WreckBox-mac-arm64.zip -R "$REPO" --title "WreckBox for Mac $VERSION" --notes-file "$NOTES" --latest=false
rm -f "$NOTES"
echo "Released $TAG — Macs see the update within 30 minutes."
