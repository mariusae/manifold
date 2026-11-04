#!/bin/sh
# Writes Sources/ManifoldCore/GhosttyTerminfoEntry.swift: Ghostty's terminfo
# entry (xterm-ghostty, as tic compiled it), which every server carries so
# that a shell on any host can look up its terminal (GhosttyTerminfo). Run
# by scripts/build-ghostty.sh; by hand, after Frameworks/ghostty-share is
# made, to make it again without building Ghostty.
set -e
cd "$(dirname "$0")/.."
src=${1:-Frameworks/ghostty-share/terminfo/78/xterm-ghostty}
out=Sources/ManifoldCore/GhosttyTerminfoEntry.swift
if [ ! -f "$src" ]; then
  echo "scripts/embed-terminfo.sh: no $src (scripts/build-ghostty.sh makes it)" >&2
  exit 1
fi
{
  echo "// Ghostty's terminfo entry, compiled, in base64. Made by"
  echo "// scripts/embed-terminfo.sh from Ghostty's build; edits are lost."
  echo ""
  echo "extension GhosttyTerminfo {"
  echo "    static let compiled = \"\"\""
  base64 < "$src" | tr -d '\n' | fold -w 76 | sed 's/^/    /'
  echo ""
  echo "    \"\"\""
  echo "}"
} > "$out"
echo "wrote $out"
