#!/bin/sh
# Builds libghostty from a pinned Ghostty release into
# Frameworks/GhosttyKit.xcframework, which Package.swift links against.
#
# Everything it needs (Zig, the Ghostty source, a usable SDK) is made in
# vendor/ by scripts/ghostty-env.sh. patches/ghostty.patch makes the build
# work with the tools on hand:
#   - shaders are compiled at runtime, so Xcode's Metal toolchain isn't needed;
#   - archives are merged by unpacking them, since Apple's libtool drops the
#     unaligned members Zig 0.15 writes.
set -e
cd "$(dirname "$0")/.."
. scripts/ghostty-env.sh

# The xcframework step itself needs a working xcodebuild; we only want the
# merged archive it would wrap, so its failure is expected and ignored. Any
# other failure is caught below.
ghostty_build "$root/vendor/ghostty-build.log" \
  -Doptimize=ReleaseFast -Di18n=false -Demit-macos-app=false \
  -Demit-xcframework=true -Dxcframework-target=native || true

lib=$(ls -t vendor/ghostty/.zig-cache/o/*/libghostty-fat.a 2>/dev/null | head -1)
other_errors=$(grep "error:" vendor/ghostty-build.log | grep -v -e "exited with code 70" -e "build command failed" || true)
if [ -n "$other_errors" ] || [ -z "$lib" ] || [ "$(stat -f %z "$lib")" -lt 1000000 ]; then
  echo "libghostty build failed; see vendor/ghostty-build.log" >&2
  exit 1
fi

out=Frameworks/GhosttyKit.xcframework
rm -rf "$out"
mkdir -p "$out/macos-arm64/Headers"
cp "$lib" "$out/macos-arm64/libghostty.a"
cp vendor/ghostty/include/ghostty.h vendor/ghostty/include/module.modulemap "$out/macos-arm64/Headers/"
cat > "$out/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libghostty.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

# Terminfo and shell integration, bundled into the app.
rm -rf Frameworks/ghostty-share
mkdir -p Frameworks/ghostty-share
cp -R vendor/ghostty/zig-out/share/ghostty vendor/ghostty/zig-out/share/terminfo Frameworks/ghostty-share/
echo "built $out"

# The host's terminal emulator, from the same source.
scripts/build-manifold-vt.sh
