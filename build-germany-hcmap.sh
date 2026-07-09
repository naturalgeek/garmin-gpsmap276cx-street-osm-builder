#!/usr/bin/env bash
# Copyright (C) 2026 Marco Meile
# Licensed under the GNU General Public License v3.0 or later.
#
# Build a routable Garmin gmapsupp.img for a GPSMAP 276Cx using
# Petrovsk's HC-Map mkgmap style + precompiled TYP (CC-BY-SA 2.0
# from https://wiki.openstreetmap.org/wiki/User:Petrovsk/My_Garmin_map_styles).
# No Van declutter patcher — HC-Map is already lean (~12 POI emit rules).
# Carries over all index/speed tunings from build-germany-jbm.sh.

set -euo pipefail

: "${WORK:=$HOME/garmin-de}"
: "${MEM:=12g}"
: "${MAXNODES:=2400000}"
: "${CODE_PAGE:=1252}"
: "${PBF_URL:=https://download.geofabrik.de/europe/germany-latest.osm.pbf}"
: "${SEA_SOURCE:=precomp}"
: "${BOUNDS_SOURCE:=precomp}"
: "${MAPNAME:=30000001}"
# Path to the precompiled hc-map.typ (downloaded from Petrovsk's Google Drive)
: "${HCMAP_TYP:=/root/hc-map-staging/hc-map.typ}"
# HC-Map style staging dir (must contain points, polygons, lines, options, info)
: "${HCMAP_STAGING:=/root/hc-map-staging/hc-map}"

MKGMAP_URL="https://www.mkgmap.org.uk/download/mkgmap-r4924.zip"
SPLITTER_URL="https://www.mkgmap.org.uk/download/splitter-r654.zip"
# NB: www.thkukuk.de, NOT osm.thkukuk.de (broken TLS on that host).
SEA_URL="https://www.thkukuk.de/osm/data/sea-latest.zip"
BOUNDS_URL="https://www.thkukuk.de/osm/data/bounds-latest.zip"

ARGS_FILE_SRC="$(cd "$(dirname "$0")" && pwd)/mkgmap-hcmap.args"

log() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$WORK"/{tools,style,sea,bounds,split,out,data,cfg}
cd "$WORK"

# 1. Tools
if [[ ! -f tools/mkgmap-r4924/mkgmap.jar ]]; then
    log "Downloading mkgmap-r4924"
    curl -fL "$MKGMAP_URL" -o /tmp/mkgmap.zip
    unzip -q -o /tmp/mkgmap.zip -d tools/
fi
MKGMAP_JAR="$WORK/tools/mkgmap-r4924/mkgmap.jar"
if [[ ! -f tools/splitter-r654/splitter.jar ]]; then
    log "Downloading splitter-r654"
    curl -fL "$SPLITTER_URL" -o /tmp/splitter.zip
    unzip -q -o /tmp/splitter.zip -d tools/
fi
SPLITTER_JAR="$WORK/tools/splitter-r654/splitter.jar"

# 2. Stage HC-Map style + TYP
STYLE_DIR_NAME='Style - HC-Map'
STYLE_PATH="$WORK/style/$STYLE_DIR_NAME"
if [[ ! -d "$STYLE_PATH" ]]; then
    log "Staging HC-Map style from $HCMAP_STAGING"
    mkdir -p "$STYLE_PATH"
    for f in points polygons lines options info version; do
        if [[ -f "$HCMAP_STAGING/$f" ]]; then
            cp "$HCMAP_STAGING/$f" "$STYLE_PATH/"
        fi
    done
fi
[[ -f "$STYLE_PATH/points" ]] || { echo "ERROR: HC-Map style missing $STYLE_PATH/points" >&2; exit 1; }
[[ -f "$HCMAP_TYP" ]] || { echo "ERROR: HC-Map TYP missing at $HCMAP_TYP" >&2; exit 1; }
log "Style: $STYLE_PATH"
log "TYP:   $HCMAP_TYP"

# 3. PBF
PBF_NAME="$(basename "$PBF_URL")"
PBF="$WORK/data/$PBF_NAME"
if [[ ! -f "$PBF" ]]; then
    log "Downloading PBF: $PBF_URL"
    curl -fL "$PBF_URL" -o "$PBF"
fi

# 4. Sea
SEA_OPT=""
if [[ "$SEA_SOURCE" == "precomp" ]]; then
    if [[ ! -f sea/.ok ]]; then
        log "Downloading precompiled sea"
        if curl -fL "$SEA_URL" -o /tmp/sea.zip; then
            unzip -q -o /tmp/sea.zip -d sea/
            if [[ -d sea/sea ]]; then mv sea/sea/* sea/; rmdir sea/sea; fi
            touch sea/.ok
        else
            echo "WARN: sea mirror failed — generating sea"
            SEA_SOURCE=generate
        fi
    fi
fi
if [[ "$SEA_SOURCE" == "precomp" ]]; then
    SEA_OPT="--precomp-sea=$WORK/sea"
else
    SEA_OPT="--generate-sea=extend-sea-sectors,land-tag=natural=background,close-gaps=6000,floodblocker"
fi

# 5. Bounds
BOUNDS_DIR="$WORK/bounds"
if [[ "$BOUNDS_SOURCE" == "precomp" ]]; then
    if [[ ! -f bounds/.ok ]]; then
        log "Downloading precompiled bounds"
        curl -fL "$BOUNDS_URL" -o /tmp/bounds.zip
        unzip -q -o /tmp/bounds.zip -d bounds/
        touch bounds/.ok
    fi
elif [[ "$BOUNDS_SOURCE" == "none" ]]; then
    if [[ ! -f bounds/.ok ]]; then
        log "Skipping bounds (admin lookups degraded)"
        touch bounds/.ok
    fi
fi

# 6. Split (use cached if available)
if [[ ! -f split/.ok ]]; then
    log "Splitting (MAXNODES=$MAXNODES, MEM=$MEM)"
    rm -f split/*.osm.pbf split/template.args 2>/dev/null || true
    java -Xmx"$MEM" -jar "$SPLITTER_JAR" --max-nodes="$MAXNODES" --output-dir="$WORK/split" --mapid="$MAPNAME" "$PBF"
    touch split/.ok
fi

# 7. mkgmap compile — use precompiled HC-Map TYP directly
log "mkgmap compile (HC-Map)"
BOUNDS_OPT=""
if [[ -d "$BOUNDS_DIR" ]] && find "$BOUNDS_DIR" -maxdepth 1 -name 'bounds_*.bnd' -print -quit | grep -q .; then
    BOUNDS_OPT="--bounds=$BOUNDS_DIR"
fi

cd "$WORK/out"
find "$WORK/out" -maxdepth 1 -type f \( -name 'gmapsupp.img' -o -name 'osmmap.img' -o -name '*.tdb' -o -name '*.mdx' -o -name '30*.img' -o -name 'ovm_*.img' -o -name 'osmmap_mdr.img' \) -delete 2>/dev/null || true

java -Xmx"$MEM" -jar "$MKGMAP_JAR" \
    -c "$ARGS_FILE_SRC" \
    --style-file="$STYLE_PATH" \
    $BOUNDS_OPT \
    $SEA_OPT \
    --mapname="$MAPNAME" \
    --output-dir="$WORK/out" \
    -c "$WORK/split/template.args" \
    "$HCMAP_TYP"

log "Done"
ls -lh "$WORK/out/gmapsupp.img" 2>/dev/null || { echo "ERROR: gmapsupp.img not produced" >&2; exit 1; }
echo "Output: $WORK/out/gmapsupp.img"
