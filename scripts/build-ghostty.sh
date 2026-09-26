#!/bin/sh
# Builds libghostty from a pinned Ghostty release into
# Frameworks/GhosttyKit.xcframework, which Package.swift links against.
#
# Everything it needs (Zig, the Ghostty source) is fetched into vendor/.
# patches/ghostty.patch makes the build work with the tools on hand:
#   - shaders are compiled at runtime, so Xcode's Metal toolchain isn't needed;
#   - archives are merged by unpacking them, since Apple's libtool drops the
#     unaligned members Zig 0.15 writes.
set -e
cd "$(dirname "$0")/.."
root=$PWD

tag=v1.3.1
zig_version=0.15.2

mkdir -p vendor
zig=vendor/zig-aarch64-macos-$zig_version/zig
if [ ! -x "$zig" ]; then
  curl -sSfL "https://ziglang.org/download/$zig_version/zig-aarch64-macos-$zig_version.tar.xz" | tar xJ -C vendor
fi

if [ ! -d vendor/ghostty ]; then
  git clone -q --depth 1 --branch "$tag" https://github.com/ghostty-org/ghostty.git vendor/ghostty
  git -C vendor/ghostty apply "$root/patches/ghostty.patch"
fi

# Zig 0.15 can't read the arm64e-only .tbd stubs in the macOS 26+ SDKs, so
# point its SDK lookups at the 15.4 SDK from the Command Line Tools.
shim=vendor/xcrun-shim
mkdir -p "$shim"
cat > "$shim/xcrun" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = --show-sdk-path ]; then echo /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; exit 0; fi
done
exec /usr/bin/xcrun "$@"
EOF
chmod +x "$shim/xcrun"

# The xcframework step itself needs a working xcodebuild; we only want the
# merged archive it would wrap, so its failure is expected and ignored. Any
# other failure is caught below.
(cd vendor/ghostty && PATH="$root/$shim:$PATH" "$root/$zig" build \
  -Doptimize=ReleaseFast -Di18n=false -Demit-macos-app=false \
  -Demit-xcframework=true -Dxcframework-target=native) >vendor/ghostty-build.log 2>&1 || true

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
