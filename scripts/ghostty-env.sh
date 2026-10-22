# Sourced by build-ghostty.sh and build-manifold-vt.sh, from the repository's
# root: makes everything building Ghostty needs, on any Mac and whatever an
# earlier build left in vendor/, and sets up how the builds run —
#   $zig        the Zig to build with (relative to the root);
#   PATH        with vendor/xcrun-shim first, so Zig finds a usable SDK;
#   SDKROOT     that SDK.
# Each step is checked every time, not only when its folder is missing:
#   - Zig, fetched once and checked against its known SHA-256;
#   - vendor/ghostty, the pinned release with patches/ghostty.patch applied
#     — the current patch: when the patch changes, the tree is reset and
#     it's applied again (anything else changed there is saved first, to
#     vendor/ghostty-local-<time>.patch);
#   - the SDK: Zig 0.15 can't link against .tbd stubs that name only arm64e
#     (as the macOS 26 and 27 SDKs' do), so it gets a clone of the SDK
#     whose stubs name arm64 too, if any stub needs it;
#   - Ghostty's dependencies: ghostty_build runs a build, trying again when
#     a download fails, and saying which one if it keeps failing.

ghostty_tag=v1.3.1
ghostty_commit=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
zig_version=0.15.2
zig_sha256=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b
# Its physical path: Zig makes relative paths that a symlink above it
# (/tmp's, say) leads astray.
cd "$(pwd -P)"
root=$PWD

if [ "$(uname -m)" != arm64 ]; then
  echo "Ghostty is built here for Apple silicon Macs only" >&2
  exit 1
fi
mkdir -p vendor

# A download, tried a few times.
fetch_url() {
  for try in 1 2 3; do
    curl -sSfL --retry 2 -o "$1" "$2" && return 0
    sleep "$try"
  done
  echo "couldn't download $2" >&2
  return 1
}

# Zig.
zig=vendor/zig-aarch64-macos-$zig_version/zig
if [ ! -x "$zig" ]; then
  echo "Fetching Zig $zig_version"
  fetch_url vendor/zig.tar.xz "https://ziglang.org/download/$zig_version/zig-aarch64-macos-$zig_version.tar.xz" || exit 1
  if ! echo "$zig_sha256  vendor/zig.tar.xz" | shasum -a 256 -c -s; then
    echo "the Zig download isn't the one expected (SHA-256 differs)" >&2
    rm -f vendor/zig.tar.xz
    exit 1
  fi
  rm -rf "vendor/zig-aarch64-macos-$zig_version"
  tar xJf vendor/zig.tar.xz -C vendor
  rm vendor/zig.tar.xz
fi

# The Ghostty source, as the patch has it. What was applied is kept in
# .git/manifold.patch, which no diff shows.
g=vendor/ghostty
if [ -e "$g" ] && [ ! -d "$g/.git" ]; then
  echo "$g isn't a Git checkout: moved to $g.old" >&2
  rm -rf "$g.old"
  mv "$g" "$g.old"
fi
if [ ! -d "$g" ]; then
  echo "Fetching Ghostty $ghostty_tag"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$ghostty_tag" https://github.com/ghostty-org/ghostty.git "$g" || exit 1
fi
# New files count in the diff (the patch was made that way).
git -C "$g" add -N .
if [ "$(git -C "$g" rev-parse HEAD)" != "$ghostty_commit" ] || ! git -C "$g" diff | cmp -s - patches/ghostty.patch; then
  if git -C "$g" diff | cmp -s - "$g/.git/manifold.patch" 2>/dev/null || [ -z "$(git -C "$g" status --porcelain)" ]; then
    : # Only an older patch applied, or none: nothing of anyone's to keep.
  else
    saved=vendor/ghostty-local-$(date +%Y%m%d-%H%M%S).patch
    git -C "$g" diff > "$saved"
    echo "$g had changes of its own, not in patches/ghostty.patch: saved to $saved" >&2
  fi
  echo "Applying patches/ghostty.patch to $g"
  if [ "$(git -C "$g" rev-parse HEAD)" != "$ghostty_commit" ]; then
    git -C "$g" fetch -q --depth 1 origin tag "$ghostty_tag" || exit 1
  fi
  # The build's caches (.zig-cache, zig-out) are ignored, so kept.
  git -C "$g" reset -q --hard "$ghostty_commit"
  git -C "$g" clean -fdq
  git -C "$g" apply "$root/patches/ghostty.patch" || exit 1
  git -C "$g" add -N .
  cp patches/ghostty.patch "$g/.git/manifold.patch"
fi

# The SDK: an older one if the Command Line Tools have one (15.x, else the
# 26 this was first built with), else whatever xcrun names. If any of its
# stubs name arm64e and not arm64, a copy of it (cloned, taking no room)
# whose stubs name both.
sdk=""
for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk \
                 /Library/Developer/CommandLineTools/SDKs/MacOSX14.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
  if [ -d "$candidate" ]; then sdk=$candidate; break; fi
done
[ -n "$sdk" ] || sdk=$(env -u SDKROOT /usr/bin/xcrun --sdk macosx --show-sdk-path) || exit 1
# A stub with a list of targets naming arm64e but not arm64 (a .tbd has a
# list for each library in it), if there's one: none, in an SDK Zig can use
# as it is.
arm64e_only() {
  find "$1/usr/lib" -name '*.tbd' -type f -print0 | xargs -0 perl -0ne \
    'while (/targets:\s*\[([^\]]*)\]/g) { my $t = $1; if ($t =~ /arm64e-macos/ && $t !~ /\barm64-macos/) { print "$ARGV\n"; exit } }' | head -1
}
if [ -n "$(arm64e_only "$sdk")" ]; then
  shimmed=vendor/sdk-arm64/$(basename "$sdk")
  if [ ! -f "$shimmed/.manifold-done" ] || [ -n "$(arm64e_only "$shimmed")" ]; then
    echo "Making $shimmed (its stubs naming arm64 too)"
    rm -rf "$shimmed"
    mkdir -p "$(dirname "$shimmed")"
    cp -c -R "$(cd "$sdk" && pwd -P)" "$shimmed" 2>/dev/null || cp -R "$(cd "$sdk" && pwd -P)" "$shimmed"
    find "$shimmed" -name '*.tbd' -type f -print0 | xargs -0 perl -0pi -e \
      's/(targets:\s*\[)([^\]]*)\]/my ($h, $t) = ($1, $2); ($t =~ \/arm64e-macos\/ && $t !~ \/\barm64-macos\/) ? "$h$t, arm64-macos ]" : "$h$t]"/ge'
    left=$(arm64e_only "$shimmed")
    if [ -n "$left" ]; then
      echo "$shimmed: $left still names only arm64e" >&2
      exit 1
    fi
    touch "$shimmed/.manifold-done"
  fi
  sdk=$root/$shimmed
fi
shim=vendor/xcrun-shim
mkdir -p "$shim"
cat > "$shim/xcrun" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = --show-sdk-path ]; then echo $sdk; exit 0; fi
done
exec /usr/bin/xcrun "\$@"
EOF
chmod +x "$shim/xcrun"
PATH=$root/$shim:$PATH
SDKROOT=$sdk
export PATH SDKROOT
echo "SDK: $sdk"

# A Zig build in vendor/ghostty, its output in the log named first. Zig
# fetches what the build asks for as it goes (Ghostty's dependencies are
# nearly all lazy, so a build for one target fetches only its own); a
# download that fails is tried again, twice, and then named.
ghostty_build() {
  log=$1
  shift
  for try in 1 2 3; do
    (cd "$root/vendor/ghostty" && "$root/$zig" build "$@") >"$log" 2>&1 && return 0
    grep -q -i -e "unable to fetch" -e "bad HTTP response" -e "unable to connect" -e "NameServerFailure" -e "ConnectionResetByPeer" "$log" || return 1
    sleep "$try"
  done
  echo "a download failed (Zig's error, from $log):" >&2
  grep -i -A2 "error:" "$log" | head -8 >&2
  return 1
}
