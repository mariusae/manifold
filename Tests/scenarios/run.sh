#!/bin/sh
# Every scenario here, against a debug instance of the app (MANIFOLD_DEBUG=1,
# its data in MANIFOLD_DIR — a throwaway one; they open files and make
# threads): MANIFOLD_DIR=/tmp/mft Tests/scenarios/run.sh
# Each checks one of STATE-MACHINES.md's issues through the debug socket.
cd "$(dirname "$0")" || exit 1
status=0
for s in *.sh; do
    [ "$s" = run.sh ] && continue
    echo "== $s"
    ./"$s" || status=1
done
exit $status
