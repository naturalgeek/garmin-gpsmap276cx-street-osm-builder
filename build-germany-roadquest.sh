#!/usr/bin/env bash
# Copyright (C) 2026 Marco Meile
# Licensed under the GNU General Public License v3.0 or later.
#
# Build a routable Garmin gmapsupp.img for a GPSMAP 276Cx using
# Petrovsk's Roadquest mkgmap style + precompiled TYP (CC-BY-SA 2.0
# from https://wiki.openstreetmap.org/wiki/User:Petrovsk/My_Garmin_map_styles).
# No Van declutter patcher — Roadquest is already lean (~12 POI emit rules).
# Carries over all index/speed tunings from build-germany-jbm.sh.

set -euo pipefail

: "${WORK:=$HOME/garmin-de}"
: "${MEM:=12g}"
: "${MAXNODES:=2400000}"
: "${CODE_PAGE:=1252}"
: "${PBF_URL:=https://download.geofabrik.de/europe/germany-latest.osm.pbf}"
: "${SEA_SOURCE:=precomp}"
: "${BOUNDS_SOURCE:=precomp}"
: "${MAPNAME:=23400001}"
# Path to the precompiled roadquest.typ (downloaded from Petrovsk's Google Drive)
: "${ROADQUEST_TYP:=/root/roadquest-staging/roadquest.typ}"
# Roadquest style staging dir (must contain points, polygons, lines, options, info)
: "${ROADQUEST_STAGING:=/root/roadquest-staging/roadquest}"
# NO_TYP=1 skips bundling roadquest.typ: device falls back to firmware-default
# rendering (Garmin City Navigator look). Style codes must be standard.
: "${NO_TYP:=0}"
# VAN_PATCH=1 applies patch-style-roadquest-van.sh to add van POI categories
# (charging, atm, camping, ferry, taxi, hospital extras, chain stores, etc.).
: "${VAN_PATCH:=0}"

MKGMAP_URL="https://www.mkgmap.org.uk/download/mkgmap-r4924.zip"
SPLITTER_URL="https://www.mkgmap.org.uk/download/splitter-r654.zip"
# NB: www.thkukuk.de, NOT osm.thkukuk.de (broken TLS on that host).
SEA_URL="https://www.thkukuk.de/osm/data/sea-latest.zip"
BOUNDS_URL="https://www.thkukuk.de/osm/data/bounds-latest.zip"

ARGS_FILE_SRC="$(cd "$(dirname "$0")" && pwd)/mkgmap-roadquest.args"

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

# 2. Stage Roadquest style + TYP
STYLE_DIR_NAME='Style - Roadquest'
STYLE_PATH="$WORK/style/$STYLE_DIR_NAME"
if [[ ! -d "$STYLE_PATH" ]]; then
    log "Staging Roadquest style from $ROADQUEST_STAGING"
    mkdir -p "$STYLE_PATH"
    for f in points polygons lines options info version; do
        if [[ -f "$ROADQUEST_STAGING/$f" ]]; then
            cp "$ROADQUEST_STAGING/$f" "$STYLE_PATH/"
        fi
    done
fi
[[ -f "$STYLE_PATH/points" ]] || { echo "ERROR: Roadquest style missing $STYLE_PATH/points" >&2; exit 1; }
if [[ "$NO_TYP" != "1" ]]; then
    [[ -f "$ROADQUEST_TYP" ]] || { echo "ERROR: Roadquest TYP missing at $ROADQUEST_TYP" >&2; exit 1; }
fi
log "Style: $STYLE_PATH"
[[ "$NO_TYP" == "1" ]] && log "TYP:   (none — firmware-default rendering)" || log "TYP:   $ROADQUEST_TYP"

# Optional van-POI patch: produces a Roadquest-van style with extra POI emit rules
if [[ "$VAN_PATCH" == "1" ]]; then
    PATCHER="$(cd "$(dirname "$0")" && pwd)/patch-style-roadquest-van.sh"
    STYLE_VAN_NAME="Style - Roadquest-van"
    STYLE_VAN_PATH="$WORK/style/$STYLE_VAN_NAME"
    if [[ -x "$PATCHER" ]]; then
        log "Applying Roadquest-van patcher"
        "$PATCHER" "$STYLE_PATH" "$STYLE_VAN_PATH"
        STYLE_PATH="$STYLE_VAN_PATH"
    else
        echo "WARN: $PATCHER not found — proceeding with unpatched Roadquest" >&2
    fi
fi

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

# 7. mkgmap compile — use precompiled Roadquest TYP directly
log "mkgmap compile (Roadquest)"
BOUNDS_OPT=""
if [[ -d "$BOUNDS_DIR" ]] && find "$BOUNDS_DIR" -maxdepth 1 -name 'bounds_*.bnd' -print -quit | grep -q .; then
    BOUNDS_OPT="--bounds=$BOUNDS_DIR"
fi

cd "$WORK/out"
find "$WORK/out" -maxdepth 1 -type f \( -name 'gmapsupp.img' -o -name 'osmmap.img' -o -name '*.tdb' -o -name '*.mdx' -o -name '23*.img' -o -name 'ovm_*.img' -o -name 'osmmap_mdr.img' \) -delete 2>/dev/null || true

TYP_ARG=""
[[ "$NO_TYP" == "1" ]] || TYP_ARG="$ROADQUEST_TYP"

java -Xmx"$MEM" -jar "$MKGMAP_JAR" \
    -c "$ARGS_FILE_SRC" \
    --style-file="$STYLE_PATH" \
    $BOUNDS_OPT \
    $SEA_OPT \
    --mapname="$MAPNAME" \
    --output-dir="$WORK/out" \
    -c "$WORK/split/template.args" \
    $TYP_ARG

log "Done"
ls -lh "$WORK/out/gmapsupp.img" 2>/dev/null || { echo "ERROR: gmapsupp.img not produced" >&2; exit 1; }
echo "Output: $WORK/out/gmapsupp.img"
