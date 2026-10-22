#!/bin/sh
# Fetches the fonts the app bundles (SIL Open Font License, bar Go): Monaspace,
# into Frameworks/monaspace, only the four faces a terminal uses of each of
# its five families; and Mona Sans, the editor's proportional font, into
# Frameworks/monasans; and Recursive and Go, for their themes. The Tiempos
# themes' Tiempos Text (Klim) is licensed, so not fetched: it is copied
# from $TIEMPOS_DIR, by default its folder in iCloud Drive's Fonts, when
# they're there. Files already there are kept.
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

# Recursive (OFL), its Linear statics, for the Recursive theme.
rec=v1.085
dir=fonts/ArrowType-Recursive-1.085/Recursive_Desktop/separate_statics/OTF
out=Frameworks/recursive
mkdir -p "$out"
for kind in Sans Mono; do
  for face in Regular Italic Med SemiBold Bold BoldItalic; do
    github_file arrowtype/recursive $rec "$dir/Recursive${kind}LnrSt-$face.otf" "$out/Recursive${kind}LnrSt-$face.otf"
  done
done
github_file arrowtype/recursive $rec OFL.txt "$out/OFL.txt"
echo "fetched $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"

# Go (BSD), for the Go theme.
go=v0.46.0
out=Frameworks/gofont
mkdir -p "$out"
for face in Regular Italic Medium Bold Bold-Italic Mono Mono-Italic Mono-Bold Mono-Bold-Italic; do
  github_file golang/image $go "font/gofont/ttfs/Go-$face.ttf" "$out/Go-$face.ttf"
done
github_file golang/image $go LICENSE "$out/LICENSE"
echo "fetched $(ls "$out"/*.ttf | wc -l | tr -d ' ') fonts into $out"

# Fira Code (OFL), for the Tiempos/Fira theme.
fira=6.2
out=Frameworks/firacode
mkdir -p "$out"
zip=vendor/Fira_Code_v$fira.zip
[ -f "$zip" ] || curl -sSfL -o "$zip" "https://github.com/tonsky/FiraCode/releases/download/$fira/Fira_Code_v$fira.zip"
for face in Light Regular Retina Medium SemiBold Bold; do
  [ -s "$out/FiraCode-$face.ttf" ] || unzip -qjo "$zip" "ttf/FiraCode-$face.ttf" -d "$out"
done
github_file tonsky/FiraCode $fira LICENSE "$out/LICENSE"
echo "fetched $(ls "$out"/*.ttf | wc -l | tr -d ' ') fonts into $out"

# JetBrains Mono (OFL), for the Tiempos/JetBrains theme.
jb=2.304
out=Frameworks/jetbrainsmono
mkdir -p "$out"
zip=vendor/JetBrainsMono-$jb.zip
[ -f "$zip" ] || curl -sSfL -o "$zip" "https://github.com/JetBrains/JetBrainsMono/releases/download/v$jb/JetBrainsMono-$jb.zip"
for face in Regular Italic Medium MediumItalic SemiBold SemiBoldItalic Bold BoldItalic; do
  [ -s "$out/JetBrainsMono-$face.ttf" ] || unzip -qjo "$zip" "fonts/ttf/JetBrainsMono-$face.ttf" -d "$out"
done
[ -s "$out/OFL.txt" ] || unzip -qjo "$zip" "OFL.txt" -d "$out"
echo "fetched $(ls "$out"/*.ttf | wc -l | tr -d ' ') fonts into $out"

# Anthrosevka Mono (OFL), Iosevka built after Anthropic Mono, for the
# Tiempos/Anthrosevka theme.
anth=v0.4.0
out=Frameworks/anthrosevka
mkdir -p "$out"
zip=vendor/AnthrosevkaMono-$anth.zip
[ -f "$zip" ] || curl -sSfL -o "$zip" "https://github.com/nanxstats/anthrosevka/releases/download/$anth/AnthrosevkaMono.zip"
for face in Regular Italic Bold BoldItalic; do
  [ -s "$out/AnthrosevkaMono-$face.ttf" ] || unzip -qjo "$zip" "AnthrosevkaMono-$face.ttf" -d "$out"
done
github_file nanxstats/anthrosevka $anth LICENSE "$out/LICENSE"
echo "fetched $(ls "$out"/*.ttf | wc -l | tr -d ' ') fonts into $out"

# Tiempos Text, for the Tiempos themes: copied, not fetched.
tiempos=${TIEMPOS_DIR:-"$HOME/Library/Mobile Documents/com~apple~CloudDocs/Fonts/Tiempos Text"}
out=Frameworks/tiempos
if [ -d "$tiempos" ]; then
  mkdir -p "$out"
  for face in Regular RegularItalic Bold BoldItalic; do
    [ -s "$out/TiemposText-$face.otf" ] || cp "$tiempos/TiemposText-$face.otf" "$out/"
  done
  echo "copied $(ls "$out"/*.otf | wc -l | tr -d ' ') fonts into $out"
else
  echo "no Tiempos Text at $tiempos; the Tiempos theme will fall back to the system's fonts" >&2
fi
