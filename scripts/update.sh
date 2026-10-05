#!/bin/sh
# Updates the Mac app from GitHub (moloyb301-eng/wreckbox-mac): pull the latest code and rebuild WreckBox.app.
# Your library (~/Music/DJ Library) and settings aren't touched. Run by the app's "Update & restart" button.
set -e
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
git pull --ff-only --quiet origin main
# Keep the Python helpers' packages in step with the code (fast when nothing changed).
[ -x analysis/venv/bin/pip ] && analysis/venv/bin/pip install --quiet mutagen essentia >/dev/null 2>&1 || true
./scripts/make-app.sh >/dev/null
echo "updated to $(git log -1 --format='%h %s')"
