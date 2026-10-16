#!/bin/zsh
# Signs a built Top Shelf.app with the same stable local identity Mail uses (its own keychain file, not the
# login keychain), so macOS keeps the Calendar and Location permissions across updates. Usage: scripts/sign.sh <app>
set -euo pipefail
APP="$1"
SUPPORT="$HOME/Library/Application Support/Audrey Mail"
SIGNKC="$SUPPORT/signing.keychain-db"
[ -f "$SIGNKC" ] || { echo "Signing keychain missing: $SIGNKC"; exit 1; }
security unlock-keychain -p "$(cat "$SUPPORT/signing.pw")" "$SIGNKC"
codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" "$APP/Contents/Resources/libTopShelfNowPlaying.dylib"
codesign --force --keychain "$SIGNKC" --sign "Audrey Mail Local Signing" -i com.johnhesch.topshelf "$APP"
