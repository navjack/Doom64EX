#!/usr/bin/env bash
# Package the macOS build into Doom64EX.app.
#
# The upstream link line mixes two SDL2s: the executable binds /Library/Frameworks/SDL2.framework
# while Homebrew's libSDL2_net binds sdl2-compat, so both end up loaded in one process. This
# retargets the executable onto sdl2-compat so a single SDL2 is used, and vendors it.
#
# Game data is NOT bundled. doom64.wad and doomsnd.sf2 are generated from the user's own ROM
# ("doom64ex -wadgen ROM") into ~/Library/Application Support/doom64ex, which is App.cc's
# _data_dir; doom64ex.pk3 is installed alongside them so the bundle stays free of data files
# (codesign rejects non-Mach-O files in Contents/MacOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
OUTDIR="${2:-$ROOT}"
APP="$OUTDIR/Doom64EX.app"
DATA="$HOME/Library/Application Support/doom64ex"

[ -x "$BUILD/doom64ex.app/Contents/MacOS/doom64ex" ] || { echo "error: doom64ex not built" >&2; exit 1; }
[ -f "$BUILD/doom64ex.pk3" ] || { echo "error: doom64ex.pk3 not built" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BUILD/doom64ex.app/Contents/MacOS/doom64ex" "$APP/Contents/MacOS/Doom64EX"

# Engine data file lives with the generated WAD in the user data dir.
mkdir -p "$DATA"
cp "$BUILD/doom64ex.pk3" "$DATA/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Doom 64 EX</string>
    <key>CFBundleDisplayName</key><string>Doom 64 EX</string>
    <key>CFBundleExecutable</key><string>Doom64EX</string>
    <key>CFBundleIdentifier</key><string>com.svkaiser.Doom64EX</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

FW="$APP/Contents/Frameworks"
cp "$(brew --prefix sdl2-compat)/lib/libSDL2-2.0.0.dylib" "$FW/"
cp "$(brew --prefix sdl3)/lib/libSDL3.0.dylib"            "$FW/libSDL3.dylib"
cp "$(brew --prefix sdl2_net)/lib/libSDL2_net-2.0.0.dylib" "$FW/"
cp "$(brew --prefix libpng)/lib/libpng16.16.dylib"        "$FW/"
chmod u+w "$FW"/*.dylib

install_name_tool -id @rpath/libSDL2-2.0.0.dylib      "$FW/libSDL2-2.0.0.dylib"
install_name_tool -id @rpath/libSDL2_net-2.0.0.dylib  "$FW/libSDL2_net-2.0.0.dylib"
install_name_tool -id @rpath/libpng16.16.dylib        "$FW/libpng16.16.dylib"
install_name_tool -id @loader_path/libSDL3.dylib      "$FW/libSDL3.dylib"
# SDL2_net must use the same SDL2 as the executable. Read the recorded path rather than
# guessing it: `brew --prefix sdl2` reports the sdl2-compat keg, but the dylib was linked
# against the /opt/homebrew/opt/sdl2 symlink, and install_name_tool needs an exact match.
NET_SDL2="$(otool -L "$FW/libSDL2_net-2.0.0.dylib" | awk '/libSDL2-2\.0\.0\.dylib/ && !/libSDL2_net/ {print $1; exit}')"
[ -n "$NET_SDL2" ] && install_name_tool -change "$NET_SDL2" \
    @loader_path/libSDL2-2.0.0.dylib "$FW/libSDL2_net-2.0.0.dylib"

BIN="$APP/Contents/MacOS/Doom64EX"
install_name_tool -change @rpath/SDL2.framework/Versions/A/SDL2 \
    @rpath/libSDL2-2.0.0.dylib "$BIN"
BIN_NET="$(otool -L "$BIN" | awk '/libSDL2_net-2\.0\.0\.dylib/ {print $1; exit}')"
[ -n "$BIN_NET" ] && install_name_tool -change "$BIN_NET" @rpath/libSDL2_net-2.0.0.dylib "$BIN"
BIN_PNG="$(otool -L "$BIN" | awk '/libpng16\.16\.dylib/ {print $1; exit}')"
[ -n "$BIN_PNG" ] && install_name_tool -change "$BIN_PNG" @rpath/libpng16.16.dylib "$BIN"
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN"

codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

if otool -L "$BIN" "$FW"/*.dylib | grep -q "$(brew --prefix)\|/Library/Frameworks/SDL2"; then
    echo "error: bundle still references external SDL/Homebrew paths" >&2; exit 1
fi
echo "built $APP"
