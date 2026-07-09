# Routable OSM Germany map for the Garmin GPSMAP 276Cx

Build a routable Germany Garmin `gmapsupp.img` from current OpenStreetMap data, **optimised for fast on-device search** on the GPSMAP 276Cx (an old transflective handheld with a weak CPU where the MDR search index becomes the bottleneck).

The output looks visually identical to Garmin City Navigator on this device: the build ships **no TYP file**, and the device firmware renders standard Garmin type codes from its built-in lookup table — the same one it uses for the factory map.

## What you get

- Whole-Germany routable `gmapsupp.img` (~1.8 GB)
- Tight 25 MB MDR search index (code-page 1252 + targeted tunings)
- Street + house-number address search
- Streets indexed as searchable POIs (`road-name-pois`)
- Curated POI set sensible for road-going vans: fuel, EV charging, parking, camping/caravan, hospital/police/fire, ATMs, ferry, taxi, supermarkets and other chain stores (filtered to those with `name` or `brand`)
- Visual styling matches stock Garmin (no TYP — firmware-default rendering)

## Quick start

```bash
# Requires: bash, java 11+, curl, unzip, rsync, screen (optional), python3.
# Disk ~25 GB free, RAM 24 GB+ recommended for whole-Germany.

git clone https://github.com/<owner>/garmin-gpsmap276cx-street-osm-builder
cd garmin-gpsmap276cx-street-osm-builder

# Download and unzip Petrovsk's Roadquest style + TYP from
# https://wiki.openstreetmap.org/wiki/User:Petrovsk/My_Garmin_map_styles
# (TYP isn't strictly required when NO_TYP=1, but the style rule files are).
mkdir -p /tmp/roadquest-staging
# … fetch roadquest.zip, unzip into /tmp/roadquest-staging/ so you get
# /tmp/roadquest-staging/roadquest/{points,polygons,lines,options,info,version}

# Build (production architecture: no TYP, van POIs, all speed tunings)
env ROADQUEST_STAGING=/tmp/roadquest-staging/roadquest \
    NO_TYP=1 \
    VAN_PATCH=1 \
    MEM=24g \
    BOUNDS_SOURCE=precomp \
    ./build-germany-roadquest.sh

# Output:
ls -lh ~/garmin-de/out/gmapsupp.img
```

Copy `~/garmin-de/out/gmapsupp.img` to `<SD card>/Garmin/gmapsupp.img` on the 276Cx (back up any existing file first).

## Architecture, in one paragraph

OpenStreetMap data (Geofabrik Germany PBF) → `splitter` chops it into 2.4 M-node tiles → `mkgmap` compiles each tile with Petrovsk's Roadquest style (small, standard-Garmin-codes-only). A small Python patcher (`patch-style-roadquest-van.sh`) optionally injects van-oriented POI emit rules (charging stations, ATMs, campsites, chain stores, etc.). The final `gmapsupp.img` is assembled **without a bundled TYP** — the 276Cx's firmware then renders every type code using its built-in rendering table (the same one Garmin City Navigator uses). All mkgmap index/speed tunings (code-page 1252 for ~30 % smaller MDR, `road-name-pois`, `housenumbers`, `polygon-size-limits`, precompiled admin bounds for fast city-narrow address search, etc.) are in `mkgmap-roadquest.args`.

## Why "no TYP"

We chased custom TYPs for a long time (Jbm, Frikart, HC-Map, Roadquest's own TYP) trying to match the stock Garmin driving look. None nailed it. We then extracted the embedded TYP from a real Garmin City Navigator `.img` and found it contained **only a POI label dictionary** — zero styling. Garmin's road colours, line widths, font styles are hardcoded in the *device firmware*, not in any map file. The shortest path to "looks like the Garmin factory map" turned out to be: don't ship a TYP at all. The firmware does the rest.

(Caveat: the style file must emit *standard* Garmin type codes the firmware knows. Roadquest does; Jbm doesn't.)

## File map

| File | What it does |
|---|---|
| `build-germany-roadquest.sh` | The production build script. |
| `mkgmap-roadquest.args` | mkgmap option set: code-page, index, route, housenumbers, polygon-size-limits, etc. |
| `patch-style-roadquest-van.sh` | Adds van POI emit rules to a copy of Roadquest's `points` file. |
| `build-germany-jbm.sh` + `mkgmap.args` + `patch-style-van.sh` | **Legacy** earlier architecture using Jbm. Kept for reference; not the active path. |
| `build-germany-frikart.sh`, `build-germany-hcmap.sh`, … | **Legacy** abandoned attempts. Kept for traceability. |
| `LICENSE` | GPL v3. |

`CLAUDE.md` has more detail on env vars, the build flow, and gotchas, written for future agent sessions.

## Attribution

- **Map data**: © OpenStreetMap contributors, licensed under [ODbL](https://www.openstreetmap.org/copyright). Geofabrik Germany extract used as source.
- **Style rules**: derived from [Petrovsk's Roadquest](https://wiki.openstreetmap.org/wiki/User:Petrovsk/My_Garmin_map_styles), CC-BY-SA 2.0.
- **mkgmap + splitter**: by Steve Ratcliffe and contributors, https://www.mkgmap.org.uk/ (GPL v2).
- **gmaptool (gmt)**: by AP, https://www.gmaptool.eu/ (CC-BY-SA), used only for inspection of upstream Garmin `.img` files.
- Build-pipeline patches and the no-TYP architecture write-up: this repo.

## Licence

GPL v3 — see [LICENSE](LICENSE). The build output is GPL v3 (style is CC-BY-SA which is one-way compatible). If you redistribute the output `gmapsupp.img`, credit Petrovsk and attach this notice.

## Caveats

- Tested on a Garmin GPSMAP 276Cx. The "no-TYP firmware fallback" relies on the device having its own type-code rendering table — Garmin handhelds Colorado/Oregon/Dakota generation onwards do. Older devices may not.
- Disabling a map via 276Cx Map Setup does NOT exclude it from search; only physically removing the file from the `Garmin/` directory does. The stock worldwide basemap lives in protected flash and can't be moved.
- `BoundaryPreprocessor` on whole-Germany needs > 28 GB of JVM heap (OOMs at 28). Use `BOUNDS_SOURCE=precomp` (recommended), or accept some address-autofill degradation with `BOUNDS_SOURCE=none`.
- The thkukuk precompiled-bounds/sea mirror has working URLs at `https://www.thkukuk.de/osm/data/`, NOT the `osm.thkukuk.de` subdomain (broken TLS).
- This is a personal project against one specific device; PRs welcome but the visual/POI choices are tuned to one user's preferences.
