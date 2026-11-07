#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: bash tools/package-dmg.sh APP OUTPUT.dmg" >&2
    exit 2
fi
app="$1"
dmg="$2"
if [[ "$dmg" != *.dmg || -e "$dmg" || -L "$dmg" ]]; then
    echo "Choose a new .dmg path." >&2
    exit 2
fi
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
codesign --verify --deep --strict "$app"
ditto "$app" "$stage/Live Wallpaper.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Live Wallpaper" -format UDZO -srcfolder "$stage" "$dmg"
hdiutil verify "$dmg"
