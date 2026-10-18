#!/bin/sh
# Builds manifoldd for Linux (x86_64 and aarch64, static, against musl), so
# the app can install it on hosts it attaches to. Needs the swift.org 6.2.0
# toolchain and its static Linux SDK, installed with swiftly:
#   swiftly install 6.2.0
#   swiftly run +6.2.0 swift sdk install <swift-6.2-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz>
set -e
cd "$(dirname "$0")/.."
SWIFTLY=${SWIFTLY:-$HOME/.swiftly/bin/swiftly}
export SWIFTLY_HOME_DIR=${SWIFTLY_HOME_DIR:-$HOME/.swiftly} SWIFTLY_BIN_DIR=${SWIFTLY_BIN_DIR:-$HOME/.swiftly/bin}
for t in x86_64 aarch64; do
  "$SWIFTLY" run +6.2.0 swift build -c release --swift-sdk "$t-swift-linux-musl" --product manifoldd 2>&1 | grep -v target-arch-variant | grep -E "error|Compiling|Linking" || true
  ls -la ".build/$t-swift-linux-musl/release/manifoldd"
done
