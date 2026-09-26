#!/bin/sh
# Builds Manifold.app into build/. `scripts/build-app.sh run` also launches it.
# Needs Frameworks/ from scripts/build-ghostty.sh.
set -e
cd "$(dirname "$0")/.."

[ -d Frameworks/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
[ -d Frameworks/monaspace ] || scripts/fetch-fonts.sh

config=${CONFIG:-release}
swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)
app=build/Manifold.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/Manifold" "$bin/manifoldd" "$app/Contents/MacOS/"
# The `manifold` command. It can't sit beside Manifold in MacOS/, as the
# file system doesn't tell the two names apart.
cp "$bin/ManifoldCLI" "$app/Contents/Helpers/manifold"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Ghostty looks for terminfo next to its resources directory.
cp -R Frameworks/ghostty-share/ghostty Frameworks/ghostty-share/terminfo "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/Fonts"
cp Frameworks/monaspace/* "$app/Contents/Resources/Fonts/"

# The icon is drawn by a script, and only redrawn when the script changes.
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  iconset=build/AppIcon.iconset
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app/Contents/MacOS/manifoldd" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/manifold" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Manifold 2>/dev/null || true
  open "$app"
fi
