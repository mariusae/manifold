#!/bin/sh
# Fetches tree-sitter — its runtime and the grammars the editor parses code
# with (DESIGN.md §7.1) — into vendor/tree-sitter/, which Package.swift
# builds as CTreeSitter and CTreeSitterGrammars: each a pinned release,
# checked against its SHA-256, only its C sources (and licence) kept.
# Run again after changing the list; `-f` fetches everything again.
set -e
cd "$(dirname "$0")/.."
out=vendor/tree-sitter
stamp=$out/.fetched
list_hash=$(shasum -a 256 "$0" | cut -c1-16)
if [ "$1" != -f ] && [ "$(cat "$stamp" 2>/dev/null)" = "$list_hash" ]; then exit 0; fi

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
rm -rf "$out"
mkdir -p "$out/grammars/include" "$out/licenses"

# fetch <url> <sha256>: the archive unpacked into $tmp/x (members outside
# it skipped), its one top directory if it has one.
fetch() {
  rm -rf "$tmp/x" "$tmp/a"
  curl -sSfL -o "$tmp/a" "$1"
  echo "$2  $tmp/a" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $1" >&2; exit 1; }
  # Python's tarfile: bsdtar won't make the directories some of these
  # archives leave out.
  python3 -I -c '
import os, sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    for m in t.getmembers():
        p = os.path.normpath(m.name)
        if not m.isfile() or p.startswith("..") or os.path.isabs(p): continue
        d = os.path.join(sys.argv[2], p)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        with open(d, "wb") as f: f.write(t.extractfile(m).read())
' "$tmp/a" "$tmp/x"
  root=$tmp/x
  [ "$(ls "$root" | wc -l)" -eq 1 ] && [ -d "$root/$(ls "$root")" ] && root=$root/$(ls "$root")
  return 0
}

# The runtime: lib.c (which includes the rest) and its headers — the
# licences (its, ICU's) beside, not in the targets SwiftPM builds.
fetch https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v0.27.1.tar.gz \
  982cd3d4d9eb7be18c243240a622423fd2e4ecb4bec2cd98832c2f3fa1f0f333
mkdir -p "$out/runtime"
cp -R "$root/lib/src" "$root/lib/include" "$out/runtime/"
rm -rf "$out/runtime/src/wasm" "$out/runtime/src/wasm-stdlib"
cp "$root/LICENSE" "$out/licenses/tree-sitter"
mv "$out/runtime/src/unicode/LICENSE" "$out/licenses/icu"
rm "$out/runtime/src/unicode/README.md" "$out/runtime/src/unicode/ICU_SHA"

# grammar <name> <url> <sha256> <its src directory in the archive>: its
# parser (and scanner) in grammars/<name>/, declared in grammars.h.
grammar() {
  fetch "$2" "$3"
  d=$out/grammars/$1
  mkdir -p "$d/tree_sitter"
  cp "$root/$4/parser.c" "$d/"
  [ -f "$root/$4/scanner.c" ] && cp "$root/$4/scanner.c" "$d/"
  cp "$root/$4"/tree_sitter/*.h "$d/tree_sitter/"
  for h in "$root/$4"/*.h; do [ -f "$h" ] && cp "$h" "$d/"; done
  # TypeScript's two share a scanner header, beside each here.
  if [ -f "$root/common/scanner.h" ]; then
    cp "$root/common/scanner.h" "$d/common_scanner.h"
    sed -i '' 's|"../../common/scanner.h"|"common_scanner.h"|' "$d/scanner.c"
  fi
  # YAML's scanner includes its schema's tables, which aren't built alone.
  if [ -f "$root/$4/schema.core.c" ]; then
    cp "$root/$4/schema.core.c" "$d/schema_core.h"
    sed -i '' 's|^#include _file(YAML_SCHEMA)|#include "schema_core.h"|' "$d/scanner.c"
  fi
  for l in LICENSE LICENSE.md LICENSE.txt; do [ -f "$root/$l" ] && cp "$root/$l" "$out/licenses/$1" && break; done
  echo "const TSLanguage *tree_sitter_$1(void);" >> "$tmp/decls"
}

crate() { echo "https://static.crates.io/crates/$1/$1-$2.crate"; }
gh() { echo "https://github.com/$1/releases/download/$2"; }

grammar bash "$(crate tree-sitter-bash 0.25.1)" 9e5ec769279cc91b561d3df0d8a5deb26b0ad40d183127f409494d6d8fc53062 src
grammar c "$(crate tree-sitter-c 0.24.1)" 1a3aad8f0129083a59fe8596157552d2bb7148c492d44c21558d68ca1c722707 src
grammar cpp "$(crate tree-sitter-cpp 0.23.4)" df2196ea9d47b4ab4a31b9297eaa5a5d19a0b121dceb9f118f6790ad0ab94743 src
grammar css "$(crate tree-sitter-css 0.23.2)" 5ad6489794d41350d12a7fbe520e5199f688618f43aace5443980d1ddcf1b29e src
grammar elixir "$(crate tree-sitter-elixir 0.3.4)" e45d444647b4fd53d8fd32474c1b8bedc1baa22669ce3a78d083e365fa9a2d3f src
grammar go "$(crate tree-sitter-go 0.25.0)" c8560a4d2f835cc0d4d2c2e03cbd0dde2f6114b43bc491164238d333e28b16ea src
grammar html "$(crate tree-sitter-html 0.23.2)" 261b708e5d92061ede329babaaa427b819329a9d427a1d710abb0f67bbef63ee src
grammar java "$(gh tree-sitter/tree-sitter-java v0.23.5)/tree-sitter-java.tar.xz" ed766e1045be236e50a7f99295996f6705d7506628b79af80d1fd5efb63c86a7 src
grammar javascript "$(gh tree-sitter/tree-sitter-javascript v0.25.0)/tree-sitter-javascript.tar.gz" 3385229430f686c6ff6e756168d7e05a01da4c45acb7708239edc9fa9ee41514 src
grammar json "$(crate tree-sitter-json 0.24.8)" 4d727acca406c0020cffc6cf35516764f36c8e3dc4408e5ebe2cb35a947ec471 src
grammar kotlin "$(gh tree-sitter-grammars/tree-sitter-kotlin v1.1.0)/tree-sitter-kotlin.tar.xz" 60f60c06a00f022b74251b98a89e42f5f575d34ae63c60c74667813714543671 src
grammar lua "$(gh tree-sitter-grammars/tree-sitter-lua v0.5.0)/tree-sitter-lua.tar.gz" dd6d995634ea7dc2eac687f4890f995f03c421e0c42c34b3cfcfc81c47e48d7e src
grammar make "$(gh tree-sitter-grammars/tree-sitter-make v1.1.1)/tree-sitter-make.tar.xz" cac625af12a155a06fb4e2a2ade6b8476e579b5ebd493701dc08de894871fdb5 src
grammar python "$(crate tree-sitter-python 0.25.0)" 6bf85fd39652e740bf60f46f4cda9492c3a9ad75880575bf14960f775cb74a1c src
grammar ruby "$(crate tree-sitter-ruby 0.23.1)" be0484ea4ef6bb9c575b4fdabde7e31340a8d2dbc7d52b321ac83da703249f95 src
grammar rust "$(crate tree-sitter-rust 0.24.2)" 439e577dbe07423ec2582ac62c7531120dbfccfa6e5f92406f93dd271a120e45 src
grammar sql "$(gh DerekStride/tree-sitter-sql v0.3.11)/tree-sitter-sql-v0.3.11.tar.gz" a97a324eae9c81ed68f6e162b9b33f8911fc6442caa2950e57c498e2460d1387 src
grammar swift "$(gh alex-pinkus/tree-sitter-swift 0.7.3)/tree-sitter-swift.tar.gz" c595b41459b0816f246ec27f60e08392ff453135e12ef47a1852ed37fe6705fe src
grammar toml "$(gh tree-sitter-grammars/tree-sitter-toml v0.7.0)/tree-sitter-toml.tar.xz" a8292c1bb022b9e1cb4591959e5a92fbabeafafd5fd8e16c0894cb88a68bb384 src
grammar tsx "$(crate tree-sitter-typescript 0.23.2)" 6c5f76ed8d947a75cc446d5fccd8b602ebf0cde64ccf2ffa434d873d7a575eff tsx/src
grammar typescript "$(crate tree-sitter-typescript 0.23.2)" 6c5f76ed8d947a75cc446d5fccd8b602ebf0cde64ccf2ffa434d873d7a575eff typescript/src
grammar yaml "$(crate tree-sitter-yaml 0.7.2)" 53c223db85f05e34794f065454843b0668ebc15d240ada63e2b5939f43ce7c97 src
grammar zig "$(gh tree-sitter-grammars/tree-sitter-zig v1.1.2)/tree-sitter-zig.tar.xz" 80cbc2cae284b539930f9958003f8f28d4c056ddc3bed912f61bf64e7d6fd680 src

{
  echo "// Made by scripts/fetch-tree-sitter.sh: each grammar's language."
  echo "#pragma once"
  echo "typedef struct TSLanguage TSLanguage;"
  cat "$tmp/decls"
} > "$out/grammars/include/grammars.h"
echo "$list_hash" > "$stamp"
