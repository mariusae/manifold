#!/bin/sh
# Builds manifoldd for Linux (x86_64 and aarch64, static, against musl), so
# the app can install it on hosts it attaches to.
#
# The Static Linux SDK goes with the swift.org toolchain of the same
# version (Xcode's Swift is another build of the compiler, and the SDK's
# modules won't load in it), so the build runs through swiftly, whatever
# Xcode is installed:
#   SWIFT_LINUX   the swift.org toolchain to use (default 6.4.1). It is
#                 installed with swiftly if it isn't yet, and its SDK is
#                 fetched into vendor/ and installed for it.
#   SWIFTLY       where swiftly is (default ~/.swiftly/bin/swiftly); get it
#                 from https://swiftlang.github.io/swiftly/
set -e
cd "$(dirname "$0")/.."
V=${SWIFT_LINUX:-6.4.1}
SWIFTLY=${SWIFTLY:-$HOME/.swiftly/bin/swiftly}
export SWIFTLY_HOME_DIR=${SWIFTLY_HOME_DIR:-$HOME/.swiftly} SWIFTLY_BIN_DIR=${SWIFTLY_BIN_DIR:-$HOME/.swiftly/bin}
if [ ! -x "$SWIFTLY" ]; then
  echo "scripts/build-linux.sh: swiftly is needed for the Linux servers (https://swiftlang.github.io/swiftly/); none at $SWIFTLY" >&2
  exit 1
fi

# The toolchain, installed if missing (not made the default).
if ! "$SWIFTLY" list 2>/dev/null | grep -q "^Swift $V\( \|$\)"; then
  echo "installing the swift.org Swift $V toolchain with swiftly…"
  "$SWIFTLY" install "$V" --assume-yes
fi

# Its Static Linux SDK, installed for it if missing. The bundle's own
# version went from 0.0.1 (Swift 6.2 and before) to 0.1.0.
if ! "$SWIFTLY" run +"$V" swift sdk list 2>/dev/null | grep -q "^swift-$V-RELEASE_static-linux"; then
  mkdir -p vendor
  installed=
  for b in 0.1.0 0.0.1; do
    f="swift-$V-RELEASE_static-linux-$b.artifactbundle.tar.gz"
    u="https://download.swift.org/swift-$V-release/static-sdk/swift-$V-RELEASE/$f"
    if [ -s "vendor/$f" ] || curl -sSfL -o "vendor/$f" "$u" 2>/dev/null; then
      echo "installing the Swift $V Static Linux SDK…"
      "$SWIFTLY" run +"$V" swift sdk install "vendor/$f"
      installed=1
      break
    fi
    rm -f "vendor/$f"
  done
  if [ -z "$installed" ]; then
    echo "scripts/build-linux.sh: no Static Linux SDK for Swift $V at download.swift.org" >&2
    exit 1
  fi
fi

# Named in full: other versions' SDKs may be installed too, and answer
# to the same triple.
sdk=$("$SWIFTLY" run +"$V" swift sdk list 2>/dev/null | grep "^swift-$V-RELEASE_static-linux" | head -1)
# The products land where the toolchain puts them (newer ones build into
# .build/out/Products/…), and are copied to a fixed place for build-app.sh,
# stripped: the symbols and debug info are most of the binary (148 MB of
# it, 58 without), and every host it's installed on gets it over the wire.
# The unstripped one stays where it was built, for symbolicating.
for t in x86_64 aarch64; do
  log=$(mktemp)
  if ! "$SWIFTLY" run +"$V" swift build -c release --swift-sdk "$sdk" --triple "$t-swift-linux-musl" --product manifoldd > "$log" 2>&1; then
    grep -v target-arch-variant "$log" | grep -E "error" | head -20 >&2
    rm -f "$log"
    echo "scripts/build-linux.sh: the $t build failed" >&2
    exit 1
  fi
  rm -f "$log"
  bin=$("$SWIFTLY" run +"$V" swift build -c release --swift-sdk "$sdk" --triple "$t-swift-linux-musl" --product manifoldd --show-bin-path 2>/dev/null)
  mkdir -p ".build/$t-swift-linux-musl/release"
  "$SWIFTLY" run +"$V" llvm-objcopy --strip-all "$bin/manifoldd" ".build/$t-swift-linux-musl/release/manifoldd"
  ls -la ".build/$t-swift-linux-musl/release/manifoldd"
done
