#!/bin/sh
# Prints what Frameworks/ is built from: the pinned Ghostty and a hash of
# patches/ghostty.patch. build-ghostty.sh writes it to Frameworks/
# ghostty.stamp once everything is built, and build-app.sh and
# build-linux.sh build again when it differs: Frameworks/ isn't in Git, so
# a pull that changes the patch leaves the libraries as they were.
cd "$(dirname "$0")/.."
grep '^ghostty_commit=' scripts/ghostty-env.sh
shasum -a 256 < patches/ghostty.patch
