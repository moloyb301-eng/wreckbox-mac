#!/bin/bash
# Builds the self-contained WreckBox for Apple Silicon Macs (macOS 13+) that friends download from GitHub:
# dist/WreckBox-mac-arm64.zip. Nothing else needs installing — inside the app:
#   Resources/runtime/python   standalone CPython 3.11 (python-build-standalone) with every helper's packages
#   Resources/helpers/…        the Soulseek / YouTube / analysis helpers (same layout as the repo)
#   Resources/bin              ffmpeg, ffprobe (martin-riedl.de static builds, GPL) and deno (yt-dlp's YouTube solver)
# No logins, tokens or settings of the person building it go in: Soulseek, Spotify and YouTube logins are each
# user's own, saved in their ~/Library/Application Support. Ad-hoc signed (no Apple Developer account), so the
# first launch needs right-click → Open / System Settings → Privacy & Security → Open Anyway (see INSTALL.md).
#
#   scripts/package-mac.sh 0.6.0
set -e
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package-mac.sh <version>}"
[ "$(uname -m)" = arm64 ] || { echo "build on an Apple Silicon Mac"; exit 1; }

PY_TAG=20261003
PY_FILE="cpython-3.11.17+$PY_TAG-aarch64-apple-darwin-install_only.tar.gz"
DENO_VERSION=v2.9.7
FFMPEG_BUILD=1789931890_9.0.2
VENDOR=build/vendor
mkdir -p "$VENDOR"

fetch() {   # url file
  [ -s "$VENDOR/$2" ] || curl -fL --retry 3 -o "$VENDOR/$2" "$1"
}
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/$PY_FILE" "$PY_FILE"
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/SHA256SUMS" "python-SHA256SUMS-$PY_TAG"
fetch "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-aarch64-apple-darwin.zip" "deno-$DENO_VERSION.zip"
fetch "https://github.com/denoland/deno/releases/download/$DENO_VERSION/deno-aarch64-apple-darwin.zip.sha256sum" "deno-$DENO_VERSION.zip.sha256sum"
for t in ffmpeg ffprobe; do
  fetch "https://ffmpeg.martin-riedl.de/download/macos/arm64/$FFMPEG_BUILD/$t.zip" "$t-$FFMPEG_BUILD.zip"
  fetch "https://ffmpeg.martin-riedl.de/download/macos/arm64/$FFMPEG_BUILD/$t.zip.sha256" "$t-$FFMPEG_BUILD.zip.sha256"
done

# Checksums: every download must match what its publisher lists.
( cd "$VENDOR"
  grep " $PY_FILE\$" "python-SHA256SUMS-$PY_TAG" | sed "s| $PY_FILE\$| $PY_FILE|" | shasum -a 256 -c -
  echo "$(awk '{print $1}' "deno-$DENO_VERSION.zip.sha256sum")  deno-$DENO_VERSION.zip" | shasum -a 256 -c -
  for t in ffmpeg ffprobe; do echo "$(awk '{print $1}' "$t-$FFMPEG_BUILD.zip.sha256")  $t-$FFMPEG_BUILD.zip" | shasum -a 256 -c -; done
)

# The app itself, then everything it needs inside it.
# (A copy in build/ship, so the developer's own build/WreckBox.app keeps working from the repo.)
VERSION="$VERSION" scripts/make-app.sh release
rm -rf build/ship && mkdir -p build/ship
ditto build/WreckBox.app build/ship/WreckBox.app
APP=build/ship/WreckBox.app
RES="$APP/Contents/Resources"
/usr/libexec/PlistBuddy -c "Delete :DJLibRepoDir" "$APP/Contents/Info.plist"   # shipped: no repo to build from

mkdir -p "$RES/runtime" "$RES/bin" "$RES/helpers/soulseek" "$RES/helpers/youtube" "$RES/helpers/analysis/venv/bin"
tar -xzf "$VENDOR/$PY_FILE" -C "$RES/runtime"          # → runtime/python
PY="$RES/runtime/python/bin/python3"
"$PY" -m pip install --quiet --no-warn-script-location --disable-pip-version-check --only-binary=:all: -r scripts/requirements-mac.txt
# Trim what the helpers never use.
rm -rf "$RES/runtime/python/lib/python3.11/test" "$RES/runtime/python/lib/python3.11/idlelib" "$RES/runtime/python/lib/python3.11/tkinter" \
       "$RES/runtime/python/lib/python3.11/turtledemo" "$RES/runtime/python/share"
find "$RES/runtime" -name __pycache__ -type d -prune -exec rm -rf {} +
"$PY" -m compileall -q -j 0 "$RES/runtime/python/lib/python3.11" >/dev/null 2>&1 || true   # fast first start; never written at runtime

cp soulseek/slsk_sync.py "$RES/helpers/soulseek/"
cp youtube/yt_fill.py "$RES/helpers/youtube/"
cp analysis/analyze.py analysis/tagger.py "$RES/helpers/analysis/"
# Launchers in the repo's layout, so the app finds them where a developer build does.
cat > "$RES/helpers/soulseek/slsk-sync" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
exec "$D/../../runtime/python/bin/python3" "$D/slsk_sync.py" "$@"
SH
cat > "$RES/helpers/youtube/yt-fill" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
exec "$D/../../runtime/python/bin/python3" "$D/yt_fill.py" "$@"
SH
cat > "$RES/helpers/analysis/venv/bin/python" <<'SH'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
exec "$D/../../../../runtime/python/bin/python3" "$@"
SH
chmod +x "$RES/helpers/soulseek/slsk-sync" "$RES/helpers/youtube/yt-fill" "$RES/helpers/analysis/venv/bin/python"

unzip -oq "$VENDOR/deno-$DENO_VERSION.zip" -d "$RES/bin"
for t in ffmpeg ffprobe; do unzip -oq "$VENDOR/$t-$FFMPEG_BUILD.zip" -d "$RES/bin"; done
chmod +x "$RES/bin/"*
cp scripts/THIRD-PARTY.txt "$RES/"

# Sign every binary inside (ad-hoc), then the app.
find "$RES" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then codesign --force -s - "$f" 2>/dev/null; fi
done
codesign --force -s - "$APP"

# Smoke test: every helper starts and imports what it needs.
"$RES/helpers/analysis/venv/bin/python" -c "import essentia, numpy, mutagen, yaml; print('analysis ok')"
"$PY" -c "import aioslsk, pydantic, aiohttp, yt_dlp, ytmusicapi, mutagen; print('helpers ok')"
"$RES/bin/ffmpeg" -hide_banner -version | head -1
"$RES/bin/deno" --version | head -1

mkdir -p dist
rm -f dist/WreckBox-mac-arm64.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/WreckBox-mac-arm64.zip
scripts/make-app.sh release >/dev/null   # put the developer build back as it was
echo "Built dist/WreckBox-mac-arm64.zip ($(du -h dist/WreckBox-mac-arm64.zip | cut -f1)) — WreckBox $VERSION"
