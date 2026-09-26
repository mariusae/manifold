#!/bin/sh
# Fetches the Monaspace fonts (SIL Open Font License) into
# Frameworks/monaspace, which build-app.sh bundles into the app. Only the four
# faces a terminal uses are kept, for each of the five families.
set -e
cd "$(dirname "$0")/.."

version=v1.400
out=Frameworks/monaspace
mkdir -p vendor "$out"
zip=vendor/monaspace-static-$version.zip
[ -f "$zip" ] || curl -sSfL -o "$zip" \
  "https://github.com/githubnext/monaspace/releases/download/$version/monaspace-static-$version.zip"
for family in Argon Krypton Neon Radon Xenon; do
  for face in Regular Italic Bold BoldItalic; do
    unzip -qjo "$zip" "Static Fonts/Monaspace $family/Monaspace$family-$face.otf" -d "$out"
  done
done
curl -sSfL -o "$out/LICENSE" "https://raw.githubusercontent.com/githubnext/monaspace/$version/LICENSE"
echo "fetched $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"
