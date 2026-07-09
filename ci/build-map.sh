#!/usr/bin/env bash
#
# ci/build-map.sh — build gmapsupp.img from one or more Geofabrik PBFs.
#
# Runs the full Default-Van pipeline used for the GPSMAP 276Cx:
#   download PBF(s) -> (merge) -> preprocess-fuel-areas -> splitter -> mkgmap.
#
# Designed to run on a fresh Ubuntu VM (see .github/workflows/build-release.yml)
# but also works locally. Only needs: openjdk, osmium-tool, wget/curl, unzip,
# python3 (the CI cloud-init installs these).
#
# Usage:
#   ci/build-map.sh "<PBF_URL>[,<PBF_URL2>,...]"
#
# One URL  -> built directly. Several (comma-separated) -> osmium-merged first
# (use extracts from the SAME Geofabrik daily run so border objects share a
# version — see CLAUDE.md build invariant on duplicate IDs).
#
# Env knobs (all optional):
#   WORK            work dir            (default: ./work)
#   OUT             output .img path    (default: ./out/gmapsupp.img)
#   MAXNODES        splitter tile size  (default: 2400000)
#   MEM             JVM heap            (default: 6g; use 24g for Germany)
#   MKGMAP_VER      mkgmap build        (default: r4924)
#   SPLITTER_VER    splitter build      (default: r654)
#   SEA_SOURCE      generate-sea|precomp|none   (default: generate-sea)
#   BOUNDS_SOURCE   none|precomp                (default: none)
#   MIRROR          precomp sea/bounds mirror   (default: thkukuk www host)
#
set -euo pipefail

PBF_URLS="${1:?usage: build-map.sh <pbf_url[,pbf_url2,...]>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out/gmapsupp.img}"
MAXNODES="${MAXNODES:-1800000}"   # 1.8M: the Default-Van style is heavy per
                                  # tile (buildings+landcover+area-POIs+fuel);
                                  # 2.4M overflowed Garmin's 16 MB RGN limit on
                                  # the densest Germany metro tile.
MEM="${MEM:-6g}"
MKGMAP_VER="${MKGMAP_VER:-r4924}"
SPLITTER_VER="${SPLITTER_VER:-r654}"
SEA_SOURCE="${SEA_SOURCE:-generate-sea}"
BOUNDS_SOURCE="${BOUNDS_SOURCE:-none}"
MIRROR="${MIRROR:-https://www.thkukuk.de/osm/data}"

STYLE_DIR="$REPO/style/Style - Default-Van"
ARGS_FILE="$REPO/mkgmap-roadquest.args"
TOOLS="$WORK/tools"
SPLIT="$WORK/split"

mkdir -p "$WORK" "$TOOLS" "$SPLIT" "$(dirname "$OUT")"

echo "::group::fetch tools (mkgmap-$MKGMAP_VER, splitter-$SPLITTER_VER)"
fetch_tool() {  # name version -> $TOOLS/<name>.jar
  local name="$1" ver="$2" jar="$TOOLS/$1.jar"
  if [ ! -f "$jar" ]; then
    local zip="$TOOLS/$name-$ver.zip"
    wget -q -O "$zip" "https://www.mkgmap.org.uk/download/$name-$ver.zip"
    unzip -q -o "$zip" -d "$TOOLS"
    cp "$TOOLS/$name-$ver/$name.jar" "$jar"
  fi
  echo "$jar"
}
MKGMAP_JAR="$(fetch_tool mkgmap "$MKGMAP_VER")"
SPLITTER_JAR="$(fetch_tool splitter "$SPLITTER_VER")"
echo "::endgroup::"

echo "::group::download PBF(s)"
IFS=',' read -ra URLS <<< "$PBF_URLS"
pbfs=()
for u in "${URLS[@]}"; do
  f="$WORK/$(basename "$u")"
  echo "  $u"
  wget -q -O "$f" "$u"
  pbfs+=("$f")
done
if [ "${#pbfs[@]}" -gt 1 ]; then
  echo "  merging ${#pbfs[@]} extracts"
  osmium merge "${pbfs[@]}" -o "$WORK/merged.osm.pbf" -O
  SRC="$WORK/merged.osm.pbf"
else
  SRC="${pbfs[0]}"
fi
echo "::endgroup::"

echo "::group::preprocess fuel/EV areas"
"$REPO/preprocess-fuel-areas.sh" "$SRC" "$WORK/with-fuel.osm.pbf"
SRC="$WORK/with-fuel.osm.pbf"
echo "::endgroup::"

echo "::group::optional sea/bounds"
mkgmap_extra=()
case "$SEA_SOURCE" in
  generate-sea) mkgmap_extra+=("--generate-sea=multipolygon,polygons,land-tag=natural=background,floodblocker") ;;
  precomp)
    wget -q -O "$WORK/sea.zip" "$MIRROR/sea-latest.zip"
    mkdir -p "$WORK/sea" && unzip -q -o "$WORK/sea.zip" -d "$WORK/sea"
    [ -d "$WORK/sea/sea" ] && mv "$WORK/sea/sea/"* "$WORK/sea/" || true
    mkgmap_extra+=("--precomp-sea=$WORK/sea") ;;
  none) : ;;
esac
if [ "$BOUNDS_SOURCE" = "precomp" ]; then
  wget -q -O "$WORK/bounds.zip" "$MIRROR/bounds-latest.zip"
  mkdir -p "$WORK/bounds" && unzip -q -o "$WORK/bounds.zip" -d "$WORK/bounds"
  mkgmap_extra+=("--bounds=$WORK/bounds")
fi
echo "::endgroup::"

echo "::group::splitter"
rm -rf "$SPLIT" && mkdir -p "$SPLIT"
( cd "$SPLIT" && java "-Xmx$MEM" -jar "$SPLITTER_JAR" \
    --max-nodes="$MAXNODES" --mapid=23400001 --output-dir="$SPLIT" "$SRC" )
echo "::endgroup::"

echo "::group::mkgmap"
( cd "$SPLIT" && java "-Xmx$MEM" -jar "$MKGMAP_JAR" \
    -c "$ARGS_FILE" \
    --style-file="$STYLE_DIR" \
    --output-dir="$(dirname "$OUT")" \
    "${mkgmap_extra[@]}" \
    -c "$SPLIT/template.args" )
echo "::endgroup::"

# mkgmap writes gmapsupp.img into the output dir; ensure the requested name.
if [ "$(dirname "$OUT")/gmapsupp.img" != "$OUT" ]; then
  mv "$(dirname "$OUT")/gmapsupp.img" "$OUT"
fi
echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
