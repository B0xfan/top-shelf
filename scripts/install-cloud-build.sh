#!/bin/zsh
# Installs the latest successful cloud build: download, sign with the local identity, install to /Applications
# only if Top Shelf is not running. Installing on John's Mac goes through Audrey first. Run as:
#   taskpolicy -b nice -n 19 scripts/install-cloud-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="Top Shelf"
APP="build/$NAME.app"
DEST="/Applications/$NAME.app"
RUN=$(gh run list --workflow build.yml --status success --limit 1 --json databaseId -q '.[0].databaseId')
[ -n "$RUN" ] || { echo "No successful cloud build yet."; exit 1; }
rm -rf build/cloud "$APP"; mkdir -p build/cloud
gh run download "$RUN" -n TopShelf-app -D build/cloud
ditto -x -k build/cloud/TopShelf.zip build
rm -rf build/cloud
scripts/sign.sh "$APP"
codesign --verify --verbose=2 "$APP"
echo "Signed $APP (cloud run $RUN)"
if pgrep -x TopShelf >/dev/null; then echo "Top Shelf is running: NOT installed. The signed app is ready at $PWD/$APP."; exit 0; fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
rm -rf "$APP"
echo "Installed $DEST"
