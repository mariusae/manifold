#!/bin/sh
# Fetches the fonts the app bundles (SIL Open Font License) for its Humanist
# theme: Lato (to edit) and Source Code Pro (code, terminals). Its reading
# font, Tiempos Text (Klim), is licensed, so not fetched: it is copied from
# $TIEMPOS_DIR, by default its folder in iCloud Drive's Fonts, when it's
# there. Files already there are kept.
set -e
cd "$(dirname "$0")/.."

# A file from a GitHub repository at a ref, through the API (which is also
# up when raw.githubusercontent.com isn't).
github_file() { # repo ref path out
  [ -s "$4" ] || curl -sSfL --retry 3 -H "Accept: application/vnd.github.raw" -o "$4" \
    "https://api.github.com/repos/$1/contents/$3?ref=$2"
}

# Lato (OFL), Google Fonts' copy of its 2.0 statics, and Source Code Pro
# (OFL), Adobe's, for the Lato theme.
gf=5d3b76120a319730fda218cc7410174a462b32cb
out=Frameworks/lato
mkdir -p "$out"
for face in Regular Italic Medium SemiBold Bold BoldItalic; do
  github_file google/fonts $gf "ofl/lato/Lato-$face.ttf" "$out/Lato-$face.ttf"
done
github_file google/fonts $gf ofl/lato/OFL.txt "$out/OFL.txt"
echo "fetched $(ls "$out"/*.ttf | wc -l | tr -d ' ') fonts into $out"
scp=803b7e23ec97ae58b6232ea76519a76d428ba268
out=Frameworks/sourcecodepro
mkdir -p "$out"
for face in Regular It Medium Semibold Bold BoldIt; do
  github_file adobe-fonts/source-code-pro $scp "OTF/SourceCodePro-$face.otf" "$out/SourceCodePro-$face.otf"
done
github_file adobe-fonts/source-code-pro $scp LICENSE.md "$out/LICENSE.md"
echo "fetched $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"

# Tiempos Text, Humanist's reading font: copied, not fetched.
tiempos=${TIEMPOS_DIR:-"$HOME/Library/Mobile Documents/com~apple~CloudDocs/Fonts/Tiempos Text"}
out=Frameworks/tiempos
if [ -d "$tiempos" ]; then
  mkdir -p "$out"
  for face in Regular RegularItalic Bold BoldItalic; do
    [ -s "$out/TiemposText-$face.otf" ] || cp "$tiempos/TiemposText-$face.otf" "$out/"
  done
  echo "copied $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"
else
  echo "no Tiempos Text at $tiempos; Humanist previews will read in the system font" >&2
fi
