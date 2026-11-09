#!/bin/sh
# I-8, M36 (STATE-MACHINES.md): a thread's card, closed, is let go — not
# kept, refreshed and acted on as if shown. Run against a debug instance
# (MANIFOLD_DEBUG=1) with a tile focused that takes a comment (a file):
# MANIFOLD_DIR=/tmp/mft Tests/scenarios/thread-card-closed.sh
set -u
sock="${MANIFOLD_DIR:-$HOME/Library/Application Support/Manifold}/app-debug.sock"
d() { printf '%s\n' "$*" | nc -U -w 5 "$sock"; }
fail=0
check() { case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: got «$2», want «$3»"; fail=1 ;; esac; }

d threads comment >/dev/null; sleep 1
check "a card is shown" "$(d threads card)" "shown true"
d threads close >/dev/null; sleep 0.5
check "closed, there's no card" "$(d threads card)" "no card"
check "and nothing acts on one" "$(d threads reply hello)" "no card"
exit $fail
