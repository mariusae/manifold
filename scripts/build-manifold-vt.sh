#!/bin/sh
# Builds libmanifoldvt — the host's terminal emulator, from the patched
# Ghostty in vendor/ (src/manifold_vt.zig) — for each OS manifoldd runs on,
# into Frameworks/manifold-vt/<macos|linux-x86_64|linux-aarch64>/, which
# Package.swift links (linux/ is set to one arch by build-linux.sh).
set -e
cd "$(dirname "$0")/.."
. scripts/ghostty-env.sh
out=Frameworks/manifold-vt
for t in native x86_64-linux-musl aarch64-linux-musl; do
  case $t in
    native) dir=macos; target= ;;
    x86_64-linux-musl) dir=linux-x86_64; target=-Dtarget=$t ;;
    aarch64-linux-musl) dir=linux-aarch64; target=-Dtarget=$t ;;
  esac
  prefix=$(mktemp -d)
  # Without SIMD, which would need libc++ beside the server; and without
  # the app, whose dependencies (GTK, Wayland…) it would fetch.
  if ! ghostty_build "$root/vendor/manifold-vt-$dir.log" manifold-vt $target \
       -Dmanifold-vt-only=true -Doptimize=ReleaseFast -Dsimd=false -Di18n=false --prefix "$prefix"; then
    echo "libmanifoldvt for $dir failed; see vendor/manifold-vt-$dir.log" >&2
    exit 1
  fi
  mkdir -p "$out/$dir"
  if [ "$dir" = macos ]; then
    # Zig leaves the archive's members unaligned, which Apple's linker
    # ignores: unpacked and packed again.
    rm -f "$out/$dir/libmanifoldvt.a"
    vendor/ghostty/merge-archives.sh "$out/$dir/libmanifoldvt.a" "$prefix/lib/libmanifoldvt.a"
  else
    cp "$prefix/lib/libmanifoldvt.a" "$out/$dir/"
  fi
  rm -rf "$prefix"
done
# The Linux arch linked by default: x86_64 (build-linux.sh sets it per build).
mkdir -p "$out/linux"
cp "$out/linux-x86_64/libmanifoldvt.a" "$out/linux/"
echo "built $out"
