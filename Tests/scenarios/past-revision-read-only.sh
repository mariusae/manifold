#!/bin/sh
# I-4 (STATE-MACHINES.md): a past revision shown in an editor stays
# read-only, whatever else changes — here its host going away and coming
# back. Run against a debug instance (MANIFOLD_DEBUG=1) of the app, from a
# git checkout: MANIFOLD_DIR=/tmp/mft Tests/scenarios/past-revision-read-only.sh
set -u
dir="${MANIFOLD_DIR:-$HOME/Library/Application Support/Manifold}"
sock="$dir/app-debug.sock"
d() { printf '%s\n' "$*" | nc -U -w 5 "$sock"; }
mani() { MANIFOLD_DIR="$dir" "${MANI:-$(dirname "$0")/../../build/Manifold-dev.app/Contents/Helpers/mani}" "$@"; }
fail=0
check() { case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: got «$2», want «$3»"; fail=1 ;; esac; }

# A file with a past, opened as text: the package manifest, in the repo.
file=$(cd "$(dirname "$0")/../.." && pwd)/Package.swift
mani open "$file" >/dev/null; sleep 2; mani show "$file" >/dev/null; sleep 1
d filehistory open >/dev/null; sleep 3
# The present as it is (editable, or not in view mode), to come back to.
present=$(d filehistory | grep -o 'editable [a-z]*')
d filehistory go 1 >/dev/null; sleep 2
check "a past revision is shown read-only" "$(d filehistory)" "editable false"
# The host away a moment, and back.
d fencing away 2 >/dev/null; sleep 6
check "still read-only once its host is back" "$(d filehistory)" "editable false"
d filehistory now >/dev/null; sleep 1
check "the present is as it was again" "$(d filehistory)" "$present"
d filehistory close >/dev/null
exit $fail
