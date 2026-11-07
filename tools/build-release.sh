#!/bin/bash
set -euo pipefail
if [[ $# != 2 || ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Usage: bash tools/build-release.sh vMAJOR.MINOR.PATCH OUTPUT_DIR" >&2
    exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "The release is built on an Apple Silicon Mac." >&2
    exit 1
fi
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tag="$1"
version="${tag#v}"
version="${version%%-*}"
mkdir -p -- "$2"
out="$(cd -- "$2" && pwd)"
name="MacOs-Live-Wallpaper-$tag-arm64"
for asset in "$name.dmg" "$name.dmg.sha256" "$name-encoder-source.tar.gz"; do
    [[ ! -e "$out/$asset" && ! -L "$out/$asset" ]] || { echo "Asset already exists: $asset" >&2; exit 2; }
done
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
prefix="$work/encoder"
sources="$work/encoder-source"
mkdir -p "$prefix" "$sources"

get_source() {
    local url="$1" hash="$2" file="$3"
    if [[ -n "${RELEASE_DOWNLOAD_DIR:-}" && -f "$RELEASE_DOWNLOAD_DIR/${file##*/}" ]]; then
        cp "$RELEASE_DOWNLOAD_DIR/${file##*/}" "$file"
    else
        curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 180 "$url" -o "$file"
    fi
    printf '%s  %s\n' "$hash" "$file" | shasum -a 256 -c -
}

upstream="https://raw.githubusercontent.com/tmfadhlul/apple-video-to-livephotos/d0c2bf897962762fde4f1e0a1ec78a7948ff0567"
get_source "$upstream/templates/metadata.mov" d9aee0440214bfb0fad75cfe8cde11f098b4546a8ff9fff13807a63d12cff800 "$work/upstream.mov"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 120 "$upstream/LICENSE" -o "$work/Public-Profile-LICENSE.txt"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/tools/public_profile.py" "$work/upstream.mov" "$work/Wallpaper-Profil.mov"

get_source https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz 464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c "$sources/ffmpeg-8.1.2.tar.xz"
get_source https://downloads.videolan.org/pub/videolan/x265/x265_4.2.tar.gz 40b1ea0453e0309f0eba934e0ddf533f8f6295966679e8894e8f1c1c8d5e1210 "$sources/x265_4.2.tar.gz"
get_source https://codeload.github.com/sekrit-twc/zimg/tar.gz/refs/tags/release-3.0.6 be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577 "$sources/zimg-3.0.6.tar.gz"
for archive in "$sources"/*.tar.*; do tar -xf "$archive" -C "$work"; done

# Build static codec dependencies. Restrict FFmpeg discovery so Homebrew's
# shared libraries do not end up in the downloadable app.
export MACOSX_DEPLOYMENT_TARGET=14.0
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
jobs=3
cmake -S "$work/x265_4.2/source" -B "$work/x265-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF
cmake --build "$work/x265-build" --parallel "$jobs"
cmake --install "$work/x265-build"
(
    cd "$work/zimg-release-3.0.6"
    ./autogen.sh
    ./configure --prefix="$prefix" --disable-shared --enable-static
    make -j"$jobs"
    make install
)
(
    cd "$work/ffmpeg-8.1.2"
    ./configure --prefix="$prefix" --pkg-config-flags=--static \
        --disable-autodetect --disable-doc --disable-debug --disable-network \
        --disable-ffplay --disable-ffprobe --enable-gpl --enable-zlib \
        --enable-libx265 --enable-libzimg --extra-libs=-lc++
    make -j"$jobs" ffmpeg
    mkdir -p "$prefix/bin"
    cp ffmpeg "$prefix/bin/ffmpeg"
)
ffmpeg="$prefix/bin/ffmpeg"
otool -L "$ffmpeg"
otool -L "$ffmpeg" | awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System\/Library)\// { bad=1 } END { exit bad }'
"$ffmpeg" -hide_banner -encoders > "$work/encoders.txt" 2>&1
grep -q libx265 "$work/encoders.txt"
"$ffmpeg" -hide_banner -filters > "$work/filters.txt" 2>&1
grep -q zscale "$work/filters.txt"

app="$work/Live Wallpaper.app"
env -u WALLPAPER_DONOR FFMPEG_BINARY="$ffmpeg" WALLPAPER_PROFILE="$work/Wallpaper-Profil.mov" \
    zsh "$root/App/build.sh" "$app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
notices="$app/Contents/Resources/Third-Party"
mkdir "$notices"
cp "$work/ffmpeg-8.1.2/COPYING.GPLv2" "$notices/FFmpeg-GPLv2.txt"
cp "$work/x265_4.2/COPYING" "$notices/x265-LICENSE.txt"
cp "$work/zimg-release-3.0.6/COPYING" "$notices/zimg-LICENSE.txt"
cp "$work/Public-Profile-LICENSE.txt" "$notices/Public-Profile-LICENSE.txt"
cat > "$notices/README.txt" <<EOF
The bundled FFmpeg CLI is built with x265 and zimg.
The matching upstream source archives and build script are available as:
$name-encoder-source.tar.gz
https://github.com/Labbbe20/MacOs-Live-Wallpaper/releases/tag/$tag

The public metadata profile is adapted from tmfadhlul/apple-video-to-livephotos
(commit d0c2bf897962762fde4f1e0a1ec78a7948ff0567), under the MIT license.
EOF
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

# Exercise the specific FFmpeg pipeline, template mux, and ImageIO output with
# generated input (no personal video and no Photos library writes).
"$ffmpeg" -nostdin -hide_banner -loglevel error -f lavfi \
    -i 'testsrc2=size=180x390:rate=30:duration=1' -c:v mpeg4 "$work/test.mp4"
swiftc -O -parse-as-library -suppress-warnings \
    "$root/App/Converter.swift" "$root/App/QuickTime.swift" "$root/tools/release-smoke.swift" \
    -o "$work/smoke"
"$work/smoke" "$work/test.mp4" "$app"

bash "$root/tools/package-dmg.sh" "$app" "$out/$name.dmg"
cp "$root/tools/build-release.sh" "$sources/"
tar -czf "$out/$name-encoder-source.tar.gz" -C "$work" encoder-source
(cd "$out" && shasum -a 256 "$name.dmg" > "$name.dmg.sha256")
