#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
target=${1:-"$source_dir/../Live Wallpaper.app"}
target=${target:A}
if [[ -e "$target" || -L "$target" ]]; then
    print -u2 "Die Ziel-App existiert bereits. Wähle einen neuen Ausgabepfad."
    exit 1
fi
ffmpeg_path=${FFMPEG_BINARY:-}
if [[ -z "$ffmpeg_path" ]]; then ffmpeg_path=$(command -v ffmpeg || true); fi
if [[ -z "$ffmpeg_path" || ! -x "$ffmpeg_path" ]]; then
    print -u2 "Setze FFMPEG_BINARY auf ein ausführbares, eigenständiges FFmpeg mit libx265."
    exit 1
fi
ffmpeg_path=${ffmpeg_path:A}
arch=$(uname -m)
work=$(mktemp -d "${target:h}/.livewallpaper-build.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
bundle="$work/Live Wallpaper.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
module_cache=${SWIFT_MODULE_CACHE:-"$work/module-cache"}
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
profile_path=${WALLPAPER_PROFILE:-"$source_dir/Resources/Wallpaper-Profil.mov"}
if [[ -n ${WALLPAPER_DONOR:-} ]]; then
    profile_path="$work/Wallpaper-Profil.mov"
    python3 "$source_dir/../tools/freeze_template.py" "$WALLPAPER_DONOR" "$profile_path"
fi
if [[ ! -f "$profile_path" ]]; then
    print -u2 "Setze WALLPAPER_PROFILE auf ein lokales Profil oder WALLPAPER_DONOR auf einen geeigneten MOV."
    print -u2 "Siehe App/Resources/README.md."
    exit 1
fi
cp "$profile_path" "$bundle/Contents/Resources/Wallpaper-Profil.mov"
cp "$ffmpeg_path" "$bundle/Contents/MacOS/ffmpeg"
chmod 755 "$bundle/Contents/MacOS/ffmpeg"
xcrun swiftc -target "$arch-apple-macos14.0" -O -suppress-warnings -parse-as-library \
    -module-cache-path "$module_cache" \
    "$source_dir/QuickTime.swift" "$source_dir/Converter.swift" "$source_dir/LiveWallpaper.swift" \
    -o "$bundle/Contents/MacOS/LiveWallpaper"
xcrun swift -module-cache-path "$module_cache" "$source_dir/Icon.swift" "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle/Contents/MacOS/ffmpeg"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
mv -n "$bundle" "$target"
if [[ -e "$bundle" ]]; then
    print -u2 "Ziel wurde während des Builds angelegt. Keine Datei überschrieben."
    exit 1
fi
print "$target"
