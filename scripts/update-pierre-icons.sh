#!/bin/bash
# update-pierre-icons.sh <checkout of github.com/pierrecomputer/icons, or its npm package>
#
# Copies into Resources/PierreIcons the icons Manifold uses (those
# PierreIcons.swift names: Use("…") and its changes' squircles), each in
# outline and fill at 12, 16 and 24 pixels as the library has them, with
# its licence (Apache-2.0) and the version taken — pinned, since it's in
# beta and its names may change.
set -euo pipefail
src=$(cd "${1:?usage: $0 <icons checkout or package>}" && pwd)
cd "$(dirname "$0")/.."
svg="$src/beta/svg"
[ -d "$svg" ] || { echo "no beta/svg in $src" >&2; exit 1; }
out=Resources/PierreIcons
rm -rf "$out"
mkdir -p "$out"
names=$( { grep -o 'Use("[A-Za-z0-9]*"' Sources/Manifold/UI/PierreIcons.swift | sed 's/Use("//; s/"//'
           sed -n '/static func change(_ letter: Character) -> String?/,/^    }/p' Sources/Manifold/UI/PierreIcons.swift | grep -o '"[A-Z][A-Za-z][A-Za-z]*"' | tr -d '"'; } | sort -u)
missing=0
for n in $names; do
    d="$svg/Icon$n"
    if [ ! -d "$d" ]; then echo "missing: Icon$n" >&2; missing=1; continue; fi
    mkdir -p "$out/Icon$n"
    for f in "$d"/outline-*px.svg "$d"/fill-*px.svg; do [ -e "$f" ] && cp "$f" "$out/Icon$n/"; done
done
cp "$src/LICENSE" "$out/LICENSE"
version=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$src/package.json" | head -1)
echo "@pierre/icons $version" > "$out/VERSION"
echo "$(echo "$names" | wc -w | tr -d ' ') icons, @pierre/icons $version"
exit $missing
