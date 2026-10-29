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
# $EDITOR in Manifold's shells: one program, not a command with words (fish
# doesn't split a variable into words, so `mani open --wait` won't do).
printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$0")/mani" open --wait "$@"' > "$app/Contents/Helpers/mani-edit"
chmod +x "$app/Contents/Helpers/mani-edit"
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
# The oldest macOS it says it runs on: 15.0, or MACOS_MIN's (26.0 as the
# Dock may want, to draw its icon dark or tinted).
min=${MACOS_MIN:-15.0}
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $min" "$app/Contents/Info.plist"
# macOS knows an app by its identifier, and of the copies it's seen (old
# builds, a worktree's, a throwaway) takes the latest version as the app:
# the one whose icon the Dock shows, that `manifold:` links open. Each
# build is a version later than the last (when it was built), and one
# built elsewhere than this checkout's build/Manifold.app — APP's, a
# worktree's — is an app of its own, never taken for this one.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$app/Contents/Info.plist"
id=com.manifold.app
[ "$app" = build/Manifold.app ] || id="$id.$(basename "$app" .app | tr -cd 'A-Za-z0-9-')"
[ "$(git rev-parse --git-dir 2>/dev/null)" = "$(git rev-parse --git-common-dir 2>/dev/null)" ] || id="$id.$(basename "$PWD" | tr -cd 'A-Za-z0-9-')"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/AgentIcons"
cp Resources/AgentIcons/*.svg Resources/AgentIcons/*LICENSE* "$app/Contents/Resources/AgentIcons/"
# Mermaid, for diagrams in Markdown previews (MIT; its licence beside it).
mkdir -p "$app/Contents/Resources/Mermaid"
cp Resources/Mermaid/mermaid.min.js Resources/Mermaid/LICENSE "$app/Contents/Resources/Mermaid/"
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
# From macOS 26 the icon is Icon Composer's (Resources/Icons/Manifold.icon):
# the tiles as layers on a background, which the system draws light, dark,
# clear or tinted as Appearance ▸ Icon & widget style asks — compiled by
# Xcode's actool into Assets.car, the bundle naming it (CFBundleIconName).
# macOS 15 keeps AppIcon.icns (actool's own .icns isn't wanted); so does a
# build without Xcode.
rm -f "$app/Contents/Resources/Assets.car"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$app/Contents/Info.plist" >/dev/null 2>&1 || true
# actool is Xcode's: when the tools chosen (xcode-select) are only the
# command-line ones, an installed Xcode's (Xcode.app, or Xcode-beta.app
# and the like), as Prism's build does.
actool() {
  if xcrun --find actool >/dev/null 2>&1; then xcrun actool "$@"; return; fi
  for x in /Applications/Xcode.app /Applications/Xcode*.app; do
    [ -x "$x/Contents/Developer/usr/bin/actool" ] && { DEVELOPER_DIR="$x/Contents/Developer" xcrun actool "$@"; return; }
  done
  return 1
}
# (absolute paths: actool's helper may not run where we are)
if actool "$PWD/Resources/Icons/Manifold.icon" --compile "$(cd "$app/Contents/Resources" && pwd)" --app-icon Manifold \
     --platform macosx --minimum-deployment-target "$min" --output-partial-info-plist "$PWD/build/icon-partial.plist" >build/actool.log 2>&1 \
   && [ -f "$app/Contents/Resources/Assets.car" ]; then
  rm -f "$app/Contents/Resources/Manifold.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string Manifold" "$app/Contents/Info.plist"
else
  echo "warning: the icon wasn't compiled (no Xcode's actool, or it failed: build/actool.log); the app has AppIcon.icns alone, light whatever Icon & widget style says" >&2
fi
# SwiftPM marks what it links as built with the SDK of its deployment
# target (15.0), whichever it was built with, and macOS takes an app so
# marked as one from before 26: its Dock tile the plain AppIcon.icns,
# never the dark or tinted icon. The app is marked with the SDK it was
# built with (and MACOS_MIN's oldest macOS, if that's set).
sdk=$(xcrun --show-sdk-version 2>/dev/null || true)
if [ -n "$sdk" ] && xcrun vtool -set-build-version macos "$min" "$sdk" -replace -output build/Manifold.stamped "$app/Contents/MacOS/Manifold" >/dev/null 2>&1; then
  mv build/Manifold.stamped "$app/Contents/MacOS/Manifold"
fi

codesign --force --sign - "$app/Contents/MacOS/manifoldd" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/mani" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/mani-edit" >/dev/null 2>&1
codesign --force --sign - "$app/Contents/Helpers/manifoldd-darwin-aarch64" >/dev/null 2>&1
codesign --force --sign - "$app" >/dev/null 2>&1
# The Finder and the Dock cache a bundle's icon by its path: the bundle,
# finished, is touched and registered again so a new icon shows at the
# next launch.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" >/dev/null 2>&1 || true
echo "built $app"

if [ "$1" = run ]; then
  pkill -x Manifold 2>/dev/null || true
  open "$app"
fi
