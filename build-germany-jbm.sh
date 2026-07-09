#!/usr/bin/env bash
# Copyright (C) 2026 Marco Meile
# Licensed under the GNU General Public License v3.0 or later.
# See LICENSE at the repo root.
#
# Build a routable Garmin gmapsupp.img for a GPSMAP 276Cx using a
# customised derivative of Jorisbo's Jbm (OSM-Mapnik) mkgmap style
# (GPL v3, https://github.com/Jorisbo/Mkgmap-Mapnik-Style-Garmin),
# with a search-optimised index.
#
# Tune via env vars (defaults shown):
#   WORK=$HOME/garmin-de            output / work tree
#   MEM=12g                         Java heap for mkgmap & splitter
#   MAXNODES=1600000                splitter tile size
#   CODE_PAGE=1252                  must match recompiled TYP
#   PBF_URL=…germany-latest.osm.pbf source OSM extract
#   SEA_SOURCE=precomp              precomp | generate
#   BOUNDS_SOURCE=local             local    | precomp
#   MAPNAME=73240001                8-digit map id (must be numeric)
#
# Output: $WORK/out/gmapsupp.img

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
: "${WORK:=$HOME/garmin-de}"
: "${MEM:=12g}"
# MAXNODES = splitter tile size. Larger = fewer/fatter tiles = faster
# region loading and search on-device, but too-large fails with "tile too
# big". 2,400,000 is high but tested on Berlin; whole Germany works at
# this value. Experiment: try 3,000,000 - 3,500,000 for an even leaner
# tile count, but be ready to drop back if a dense tile (e.g. Berlin
# inner ring) errors out.
: "${MAXNODES:=2400000}"
# 1252 (Windows-Latin-1) trims the MDR ~25-30% vs UTF-8 — significant
# on-device search speedup on the 276Cx. Covers German fully; non-Latin-1
# names transliterate. Must match the code-page in mkgmap.args.
: "${CODE_PAGE:=1252}"
: "${PBF_URL:=https://download.geofabrik.de/europe/germany-latest.osm.pbf}"
: "${SEA_SOURCE:=precomp}"
: "${BOUNDS_SOURCE:=local}"
: "${MAPNAME:=73240001}"
# Jbm TYP source basename (no .txt). jbmgps = handheld GPS palette (recommended
# for the 276Cx); jbm = Mapnik palette for Oregon 6x0 touchscreens; jbmhb =
# Mapnik palette with bicycle overlays hidden.
: "${TYP_NAME:=jbmgps}"

MKGMAP_URL="https://www.mkgmap.org.uk/download/mkgmap-r4924.zip"
SPLITTER_URL="https://www.mkgmap.org.uk/download/splitter-r654.zip"
STYLE_REPO="https://github.com/Jorisbo/Mkgmap-Mapnik-Style-Garmin.git"
# NB: use www.thkukuk.de/osm/data/, NOT osm.thkukuk.de/data/. The osm.*
# subdomain has a broken TLS handshake; www.* works. Verified 2026-05-31.
SEA_URL="https://www.thkukuk.de/osm/data/sea-latest.zip"
BOUNDS_URL="https://www.thkukuk.de/osm/data/bounds-latest.zip"

ARGS_FILE_SRC="$(cd "$(dirname "$0")" && pwd)/mkgmap.args"

log() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$WORK"/{tools,style,sea,bounds,split,out,data,cfg}
cd "$WORK"

# ---------------------------------------------------------------------------
# 1. Tools
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. Jbm style
# ---------------------------------------------------------------------------
STYLE_DIR_NAME='Style - Jbm'
if [[ ! -d "style/$STYLE_DIR_NAME" ]]; then
    log "Fetching Jbm style"
    rm -rf style/_repo
    git clone --depth 1 "$STYLE_REPO" style/_repo
    # The repo ships the style as a zip; find the newest and unpack it.
    STYLE_ZIP="$(ls -1 style/_repo/*.zip 2>/dev/null | sort | tail -n1)"
    if [[ -z "${STYLE_ZIP:-}" ]]; then
        echo "ERROR: no style zip found in $STYLE_REPO checkout" >&2
        exit 1
    fi
    unzip -q -o "$STYLE_ZIP" -d style/
    if [[ ! -d "style/$STYLE_DIR_NAME" ]]; then
        # Some zips unpack with a top-level folder we don't expect — find it.
        FOUND_STYLE="$(find style -maxdepth 2 -type d -name 'Style - Jbm' | head -n1)"
        if [[ -n "$FOUND_STYLE" && "$FOUND_STYLE" != "style/$STYLE_DIR_NAME" ]]; then
            mv "$FOUND_STYLE" "style/$STYLE_DIR_NAME"
        fi
    fi
fi
STYLE_PATH_SRC="$WORK/style/$STYLE_DIR_NAME"
[[ -d "$STYLE_PATH_SRC" ]] || { echo "ERROR: style not found at $STYLE_PATH_SRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2b. Apply van-driver customisations: produce Style - Jbm-van/ from source.
# ---------------------------------------------------------------------------
PATCHER="$(cd "$(dirname "$0")" && pwd)/patch-style-van.sh"
STYLE_VAN_NAME='Style - Jbm-van'
STYLE_PATH="$WORK/style/$STYLE_VAN_NAME"
if [[ -x "$PATCHER" ]]; then
    log "Applying van patcher (style + TYP source)"
    "$PATCHER" "$STYLE_PATH_SRC" "$STYLE_PATH"
else
    echo "WARN: $PATCHER not found or not executable — falling back to unpatched style"
    STYLE_PATH="$STYLE_PATH_SRC"
fi

# Locate the requested TYP source (from the patched van variant if present).
TYP_SRC="$STYLE_PATH/${TYP_NAME}.txt"
if [[ ! -f "$TYP_SRC" ]]; then
    echo "WARN: $TYP_SRC not found, falling back to first jbm*.txt under style dir" >&2
    TYP_SRC="$(find "$WORK/style" -maxdepth 4 -type f -iname "${TYP_NAME}*.txt" | head -n1 || true)"
fi
[[ -n "${TYP_SRC:-}" && -f "$TYP_SRC" ]] || { echo "ERROR: TYP source for '$TYP_NAME' not found under $WORK/style" >&2; exit 1; }
log "TYP source: $TYP_SRC"

# Normalise TYP source for mkgmap and force CodePage. Then mkgmap compiles
# it to a real .typ in its own pre-pass (matches upstream build.cmd).
# When CODE_PAGE=1252, the TYP source contains chars outside Latin-1
# (Polish ż/ł/ń/ś/ą, French curly-quote ’) in language-specific labels.
# We transliterate them to closest Latin-1 equivalents via iconv//TRANSLIT;
# loss is only in the non-German labels which the 276Cx won't render.
TYP_TXT_NORM="$WORK/cfg/${TYP_NAME}-${CODE_PAGE}.txt"
sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$TYP_SRC" \
  | awk -v cp="$CODE_PAGE" 'BEGIN{IGNORECASE=1} /^CodePage=/{print "CodePage=" cp; next} {print}' \
  | { if [[ "$CODE_PAGE" == "1252" ]]; then
        iconv -f UTF-8 -t WINDOWS-1252//TRANSLIT
      else
        cat
      fi; } \
  > "$TYP_TXT_NORM"

# Normalise style config files: UTF-8, no BOM/CR, no inline comments where needed.
SKIPMDR_SRC="$STYLE_PATH/config.skipmdrindex"
NEARBYPOI_SRC="$STYLE_PATH/config.nearbypoi"
SKIPMDR_UTF8="$WORK/cfg/config.skipmdrindex"
NEARBYPOI_UTF8="$WORK/cfg/config.nearbypoi"

if [[ -f "$SKIPMDR_SRC" ]]; then
    iconv -f WINDOWS-1252 -t UTF-8 "$SKIPMDR_SRC" \
      | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' \
      | sed -e 's/x-mdr7-excl/mdr7-excl/g' \
      > "$SKIPMDR_UTF8"
fi
if [[ -f "$NEARBYPOI_SRC" ]]; then
    iconv -f WINDOWS-1252 -t UTF-8 "$NEARBYPOI_SRC" \
      | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' \
      | sed -e 's/[[:space:]]*#.*$//' \
      | sed -e '/^[[:space:]]*$/d' \
      > "$NEARBYPOI_UTF8"
fi

# ---------------------------------------------------------------------------
# 3. PBF
# ---------------------------------------------------------------------------
PBF_NAME="$(basename "$PBF_URL")"
PBF="$WORK/data/$PBF_NAME"
if [[ ! -f "$PBF" ]]; then
    log "Downloading PBF: $PBF_URL"
    curl -fL "$PBF_URL" -o "$PBF"
fi

# ---------------------------------------------------------------------------
# 4. Sea
# ---------------------------------------------------------------------------
SEA_DIR=""
SEA_OPT=""
if [[ "$SEA_SOURCE" == "precomp" ]]; then
    if [[ ! -f sea/.ok ]]; then
        log "Downloading precompiled sea"
        if curl -fLI "$SEA_URL" >/dev/null 2>&1 && curl -fL "$SEA_URL" -o /tmp/sea.zip; then
            unzip -q -o /tmp/sea.zip -d sea/
            # The thkukuk sea zip nests files inside a top-level `sea/`
            # directory. mkgmap's --precomp-sea expects the files at
            # the dir root, so flatten if needed.
            if [[ -d sea/sea ]]; then
                mv sea/sea/* sea/
                rmdir sea/sea
            fi
            touch sea/.ok
        else
            echo "WARN: sea mirror unreachable — falling back to --generate-sea"
            SEA_SOURCE=generate
        fi
    fi
fi
if [[ "$SEA_SOURCE" == "precomp" ]]; then
    SEA_DIR="$WORK/sea"
    SEA_OPT="--precomp-sea=$SEA_DIR"
else
    SEA_OPT="--generate-sea=extend-sea-sectors,land-tag=natural=background,close-gaps=6000,floodblocker"
fi

# ---------------------------------------------------------------------------
# 5. Bounds
# ---------------------------------------------------------------------------
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
        log "Skipping bounds entirely (--bounds will not be passed to mkgmap)"
        log "  Effect: city-from-coordinates and is_in() admin lookups are degraded;"
        log "  most German addresses still work via OSM's direct addr:city tagging."
        touch bounds/.ok
    fi
else
    if [[ ! -f bounds/.ok ]]; then
        log "Preprocessing bounds locally (needs RAM)"
        java -Xmx"$MEM" -cp "$MKGMAP_JAR" uk.me.parabola.mkgmap.reader.osm.boundary.BoundaryPreprocessor \
            "$PBF" "$BOUNDS_DIR"
        touch bounds/.ok
    fi
fi

# ---------------------------------------------------------------------------
# 6. Split
# ---------------------------------------------------------------------------
if [[ ! -f split/.ok ]]; then
    log "Splitting (MAXNODES=$MAXNODES, MEM=$MEM)"
    rm -f split/*.osm.pbf split/template.args 2>/dev/null || true
    java -Xmx"$MEM" -jar "$SPLITTER_JAR" \
        --max-nodes="$MAXNODES" \
        --output-dir="$WORK/split" \
        --mapid="$MAPNAME" \
        "$PBF"
    touch split/.ok
fi

# ---------------------------------------------------------------------------
# 7a. Compile TYP separately (matches upstream build.cmd two-pass pattern)
# ---------------------------------------------------------------------------
log "Compile TYP -> .typ"
rm -f "$WORK/out/${TYP_NAME}.typ" "$WORK/out/"*.typ
java -jar "$MKGMAP_JAR" \
    --output-dir="$WORK/out" \
    --family-id=8000 \
    --product-id=1 \
    --code-page="$CODE_PAGE" \
    "$TYP_TXT_NORM"
TYP_COMPILED="$WORK/out/${TYP_NAME}-${CODE_PAGE}.typ"
[[ -f "$TYP_COMPILED" ]] || TYP_COMPILED="$(ls -1 "$WORK/out/"*.typ 2>/dev/null | head -n1)"
[[ -f "$TYP_COMPILED" ]] || { echo "ERROR: TYP compile did not produce a .typ" >&2; exit 1; }
log "Compiled TYP: $TYP_COMPILED"

# ---------------------------------------------------------------------------
# 7b. Main mkgmap compile
# ---------------------------------------------------------------------------
log "mkgmap compile"

EXTRA_CFG=()
[[ -f "$SKIPMDR_UTF8" ]]  && EXTRA_CFG+=( "--read-config=$SKIPMDR_UTF8" )
[[ -f "$NEARBYPOI_UTF8" ]] && EXTRA_CFG+=( "--nearby-poi-rules-config=$NEARBYPOI_UTF8" )

# Clean previous outputs but preserve the compiled TYP we just made.
find "$WORK/out" -maxdepth 1 -type f \
    \( -name 'gmapsupp.img' -o -name 'osmmap.img' -o -name '*.tdb' \
       -o -name '*.mdx' -o -name '73*.img' -o -name 'ovm_*.img' \) \
    -delete 2>/dev/null || true

BOUNDS_OPT=""
if [[ -d "$BOUNDS_DIR" ]] && find "$BOUNDS_DIR" -maxdepth 1 -name 'bounds_*.bnd' -print -quit | grep -q .; then
    BOUNDS_OPT="--bounds=$BOUNDS_DIR"
else
    log "Bounds dir empty — --bounds will NOT be passed to mkgmap"
fi

java -Xmx"$MEM" -jar "$MKGMAP_JAR" \
    -c "$ARGS_FILE_SRC" \
    --style-file="$STYLE_PATH" \
    $BOUNDS_OPT \
    $SEA_OPT \
    "${EXTRA_CFG[@]}" \
    --mapname="$MAPNAME" \
    --output-dir="$WORK/out" \
    -c "$WORK/split/template.args" \
    "$TYP_COMPILED"

log "Done"
ls -lh "$WORK/out/gmapsupp.img" 2>/dev/null || { echo "ERROR: gmapsupp.img not produced" >&2; exit 1; }
echo
echo "Output: $WORK/out/gmapsupp.img"
echo "Sideload to <SD card>/Garmin/gmapsupp.img on the 276Cx."
