#!/bin/sh
# I-3 (STATE-MACHINES.md): a space change leaves nothing of the old space's
# transient state behind — no drag catcher over the grid left, no ⌃⇥ walk
# of another space. Run against a debug instance of the app (MANIFOLD_DEBUG=1)
# with at least two spaces: MANIFOLD_DIR=/tmp/mft Tests/scenarios/space-change.sh
set -u
sock="${MANIFOLD_DIR:-$HOME/Library/Application Support/Manifold}/app-debug.sock"
d() { printf '%s\n' "$*" | nc -U -w 5 "$sock"; }
fail=0
check() { # what, got, want (a substring)
    case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: got «$2», want «$3»"; fail=1 ;; esac
}

d spaces pick 0 >/dev/null; sleep 0.5

# A drag that spring-loads another space, then ends there.
d drag begin >/dev/null
before=$(d drag); before=${before##*shown=}
d spaces pick 1 >/dev/null; sleep 0.5
state=$(d drag); shown=${state##*shown=}
[ "$shown" != "$before" ] || { echo "FAIL the second space is the first"; fail=1; }
check "the catcher moves to the grid shown, alone" "$state" "dragging=true catching=$shown shown="
d drag end >/dev/null
check "no grid catches once the drag is over" "$(d drag)" "catching=-"

# A walk begun in one space, another space shown before it settles.
d spaces pick 0 >/dev/null; sleep 0.5
d tilewalk step >/dev/null; sleep 0.3
check "the walk began" "$(d tilewalk)" "previewing=true"
d spaces pick 1 >/dev/null; sleep 0.5
check "another space shown ends the walk" "$(d tilewalk)" "walk=-"
check "and nothing of it is previewed" "$(d tilewalk)" "previewing=false"

d spaces pick 0 >/dev/null
exit $fail
