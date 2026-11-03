#!/bin/sh
# Writes what the build is made from into Sources/CBuildStamp/generated.h:
# the git revision (with -dirty and a hash of the changes, when tracked
# files differ from it) and when that was first built. Rewritten only when
# the revision changes, so the binaries (and the servers installed on other
# hosts, which are sent again when theirs differ) stay as they were when
# nothing did.
set -e
cd "$(dirname "$0")/.."
out=Sources/CBuildStamp/generated.h
rev=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
if [ "$rev" != unknown ] && ! git diff --quiet HEAD -- 2>/dev/null; then
  rev="$rev-dirty.$(git diff HEAD -- | shasum -a 256 | cut -c1-8)"
fi
grep -q "\"$rev\"" "$out" 2>/dev/null && exit 0
printf '#define MANIFOLD_REVISION "%s"\n#define MANIFOLD_BUILT %sLL\n' "$rev" "$(date +%s)" > "$out"
# The header may be new to the compiler's record of what stamp.c includes.
touch Sources/CBuildStamp/stamp.c
