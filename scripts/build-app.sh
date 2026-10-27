#!/bin/sh
# Builds Manifold.app into build/ (or $APP). `scripts/build-app.sh run` also
# launches it.
# Needs Frameworks/ from scripts/build-ghostty.sh.
set -e
cd "$(dirname "$0")/.."

[ -d Frameworks/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
[ -f Frameworks/manifold-vt/macos/libmanifoldvt.a ] || scripts/build-manifold-vt.sh

config=${CONFIG:-release}
swift build -c "$config"
# The servers for Linux hosts (scripts/build-linux.sh), built by default
# when swiftly is there (the script installs the toolchain and SDK it
# needs); LINUX=0 skips them.
if [ "${LINUX:-1}" != 0 ] && [ -x "${SWIFTLY:-$HOME/.swiftly/bin/swiftly}" ]; then
  scripts/build-linux.sh
fi
bin=$(swift build -c "$config" --show-bin-path)
app=${APP:-build/Manifold.app}
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/Manifold" "$bin/manifoldd" "$app/Contents/MacOS/"
# The `mani` command, in Helpers/ with the servers carried for other hosts.
cp "$bin/ManifoldCLI" "$app/Contents/Helpers/mani"
# The servers carried for other hosts (DESIGN.md §8): this machine's, and
# Linux ones when scripts/build-linux.sh has made them. The Linux ones go
# under Resources: codesign won't seal a bundle with ELF files among its
# helpers.
cp "$bin/manifoldd" "$app/Contents/Helpers/manifoldd-darwin-aarch64"
mkdir -p "$app/Contents/Resources/servers"
for t in x86_64 aarch64; do
  [ -f ".build/$t-swift-linux-musl/release/manifoldd" ] && cp ".build/$t-swift-linux-musl/release/manifoldd" "$app/Contents/Resources/servers/manifoldd-linux-$t"
done
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/AgentIcons"
cp Resources/AgentIcons/*.svg Resources/AgentIcons/*LICENSE* "$app/Contents/Resources/AgentIcons/"
# Ghostty looks for terminfo next to its resources directory.
cp -R Frameworks/ghostty-share/ghostty Frameworks/ghostty-share/terminfo "$app/Contents/Resources/"
# No fonts are shipped: the themes are of those macOS has, or installed.

# The icon is drawn from its SVG by a script, and only redrawn when either changes.
# (manifold-tiles-mono.svg is its grey version, for where one color is wanted.)
icon=Resources/Icons/manifold-tiles.svg
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ] || [ "$icon" -nt build/AppIcon.icns ]; then
  iconset=build/AppIcon.iconset
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift scripts/make-icon.swift "$icon" build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The Finder and the Dock cache a bundle's icon by its path: the bundle
# is touched and registered again so a new icon shows at the next launch.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true

codesign --force --sign - "$app/Contents/MacOS/manifoldd" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/mani" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/manifoldd-darwin-aarch64" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Manifold 2>/dev/null || true
  open "$app"
fi
