#!/bin/sh
# Fetches the fonts the app bundles (both SIL Open Font License): Monaspace,
# into Frameworks/monaspace, only the four faces a terminal uses of each of
# its five families; and Mona Sans, the editor's proportional font, into
# Frameworks/monasans. Files already there are kept.
set -e
cd "$(dirname "$0")/.."

# A file from a GitHub repository at a ref, through the API (which is also
# up when raw.githubusercontent.com isn't).
github_file() { # repo ref path out
  [ -s "$4" ] || curl -sSfL --retry 3 -H "Accept: application/vnd.github.raw" -o "$4" \
    "https://api.github.com/repos/$1/contents/$3?ref=$2"
}

version=v1.400
out=Frameworks/monaspace
mkdir -p vendor "$out"
zip=vendor/monaspace-static-$version.zip
[ -f "$zip" ] || curl -sSfL -o "$zip" \
  "https://github.com/githubnext/monaspace/releases/download/$version/monaspace-static-$version.zip"
for family in Argon Krypton Neon Radon Xenon; do
  for face in Regular Italic Bold BoldItalic; do
    [ -s "$out/Monaspace$family-$face.otf" ] ||
      unzip -qjo "$zip" "Static Fonts/Monaspace $family/Monaspace$family-$face.otf" -d "$out"
  done
done
github_file githubnext/monaspace $version LICENSE "$out/LICENSE"
echo "fetched $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"

mona=v2.0.27
out=Frameworks/monasans
mkdir -p "$out"
for face in Regular Italic Medium SemiBold Bold BoldItalic; do
  github_file github/mona-sans $mona "fonts/static/otf/MonaSans-$face.otf" "$out/MonaSans-$face.otf"
done
github_file github/mona-sans $mona OFL.txt "$out/OFL.txt"
echo "fetched $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"
