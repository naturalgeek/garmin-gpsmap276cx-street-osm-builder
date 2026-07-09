#!/usr/bin/env bash
#
# preprocess-fuel-areas.sh — make fuel & EV-charging visible at the 120m zoom.
#
# The GPSMAP 276Cx firmware culls POI *point* icons at the 120m level; only
# area *polygons* render there. Garmin's commercial maps store fuel as areas,
# which is why "ARAL" shows at 120m on City Navigator. Our OSM data has most
# stations as nodes, so they only appear at 80m. This step synthesises a tiny
# area-square around every amenity=fuel / amenity=charging_station node so the
# station also shows at 120m (with its brand/name label).
#
# The original nodes are kept, so Find->POI search and the 80m fuel icon are
# unchanged; the squares are tagged `x_fuelmark` (not `amenity=fuel`) and never
# enter the search index. The style renders `x_fuelmark=*` at `resolution 23-23`
# (the 120m level only) — see `style/Style - Default-Van/polygons`.
#
# Requires: osmium-tool, python3.
# Usage:    ./preprocess-fuel-areas.sh <input.osm.pbf> <output.osm.pbf>
#
set -euo pipefail

IN="${1:?usage: preprocess-fuel-areas.sh <input.osm.pbf> <output.osm.pbf>}"
OUT="${2:?usage: preprocess-fuel-areas.sh <input.osm.pbf> <output.osm.pbf>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[fuel-areas] filtering fuel/charging nodes from $IN"
osmium tags-filter "$IN" \
    n/amenity=fuel n/amenity=charging_station \
    -o "$TMP/nodes.osm.pbf" -O
osmium cat "$TMP/nodes.osm.pbf" -o "$TMP/nodes.osm" -O

echo "[fuel-areas] generating area-squares"
python3 "$HERE/fuel-nodes-to-squares.py" "$TMP/nodes.osm" "$TMP/squares.osm"
osmium cat "$TMP/squares.osm" -o "$TMP/squares.osm.pbf" -O

echo "[fuel-areas] merging squares into extract -> $OUT"
osmium merge "$IN" "$TMP/squares.osm.pbf" -o "$OUT" -O

echo "[fuel-areas] done. Split $OUT (splitter) then build with mkgmap as usual."
