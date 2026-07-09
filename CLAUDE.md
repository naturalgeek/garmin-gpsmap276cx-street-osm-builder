# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Builds a routable Garmin `gmapsupp.img` for the **GPSMAP 276Cx**, optimised for fast on-device search (the device CPU is weak; the MDR search index is the primary bottleneck). The output is sideloaded to the device's `Garmin/gmapsupp.img`.

## The winning architecture: build *without* a TYP file

The single most important design decision. Confirmed working 2026-05-31 — full notes in [`memory/architecture_no_typ.md`](memory/architecture_no_typ.md).

- The 276Cx's firmware contains a **hardcoded rendering table** for standard Garmin type codes (the table Garmin City Navigator uses).
- When a map is loaded **without** a bundled `.typ` for its family-id, the device falls back to that firmware table → free stock-Garmin look, no TYP work.
- Garmin's commercial `.img` files **do not contain road styling** (an analysis of `D6159130A.img` / CN Europe NTU 2021 confirmed the embedded TYP is a label-only dictionary, all `[_line]`/`[_polygon]`/`[_point]` headers zero). The styling lives in firmware. Extraction is a dead end.
- This means: the style file used by mkgmap MUST emit **standard Garmin type codes** (0x01–0x14 roads, 0x2a–0x6f POIs, 0x32 sea, 0x3c lake, etc.). Don't use styles that emit extended codes (Jbm does; **don't** use Jbm with NO_TYP).

The active style is **Petrovsk's Roadquest** (CC-BY-SA 2.0, https://wiki.openstreetmap.org/wiki/User:Petrovsk/My_Garmin_map_styles) — small, clean, standard-codes-only.

## File map

**Active (the final architecture):**

| File | Role |
|---|---|
| `build-germany-roadquest.sh` | Whole-Germany build script. Stages Roadquest style + (optional) applies the van patcher + skips TYP bundling when `NO_TYP=1`. |
| `mkgmap-roadquest.args` | mkgmap option set — all the index/speed tunings (code-page=1252, road-name-pois, housenumbers, polygon-size-limits, etc.). |
| `patch-style-roadquest-van.sh` | Adds van POI emit rules (charging, atm, camping, taxi, fire/police, ferry, chain stores with name/brand filter) to a copy of Roadquest's `points` file. |
| `LICENSE` | GPL v3 — the licence the whole repo is published under. |

**Legacy / reference (kept for history, not the active path):**

| File | Why it exists |
|---|---|
| `build-germany-jbm.sh` + `mkgmap.args` + `patch-style-van.sh` | First architecture. Used the Jbm OSM-Mapnik style with a complex POI declutter patcher. Worked but slower (~13 min compile, 111 MB MDR) and Jbm's extended type codes break under no-TYP. |
| `build-germany-frikart.sh` + `mkgmap-frikart.args` | Frikart attempt — abandoned: user didn't like the style on-device. |
| `build-germany-hcmap.sh` + `mkgmap-hcmap.args` | Petrovsk HC-Map attempt — abandoned: rendered cycleways as green halos around every street in dense German OSM data. |

**Memory** (under `.claude/projects/.../memory/` for the harness, accessible across sessions):

- `architecture_no_typ.md` — the key design insight, must-read
- `build_invariants.md` — non-obvious gotchas (TYP binding, code page, mirror URL, OOM thresholds)
- `project_goal.md` — what the user is optimising for (search speed on weak device)
- `environment.md` — local + remote build host facts
- `feedback_pii.md` — name OK in copyright, email NOT

## Build commands

The whole-Germany PBF is ~4.8 GB and needs ~25 GB free disk + ~24 GB RAM. That typically exceeds a laptop, so builds run on a remote build host (`root@<BUILD_HOST>`, e.g. Ubuntu, 16 CPU, 30 GB RAM, 575 GB disk). The scripts work on either host; just match the env vars.

### Final / production build (Roadquest + no TYP + van POIs)

```bash
# On the build host (typically the remote server):
env PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf \
    BOUNDS_SOURCE=precomp \
    SEA_SOURCE=precomp \
    MAXNODES=2400000 \
    MEM=24g \
    NO_TYP=1 \
    VAN_PATCH=1 \
    ./build-germany-roadquest.sh
```

Result: `~/garmin-de/out/gmapsupp.img` (~1.8 GB, 25 MB MDR). ~6 min if splitter cache exists; ~14 min cold.

### Build in a detached screen (survives ssh disconnect)

```bash
screen -dmS gbuild bash -c '
  cd /root/garmin-build &&
  env PBF_URL=https://download.geofabrik.de/europe/germany-latest.osm.pbf \
      BOUNDS_SOURCE=precomp SEA_SOURCE=precomp MAXNODES=2400000 \
      MEM=24g NO_TYP=1 VAN_PATCH=1 \
      ./build-germany-roadquest.sh 2>&1 | tee -a /root/build.log
  echo === BUILD COMPLETE ===; exec bash
'
# Reattach: screen -r gbuild
# Detach without killing: Ctrl-A D
```

### Build a smaller region first (Berlin = ~50 MB PBF, ~30 s build)

```bash
PBF_URL=https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf \
  ./build-germany-roadquest.sh
```

### Pull the output back to local for sideload

```bash
rsync -avh --progress root@<BUILD_HOST>:/root/garmin-de/out/gmapsupp.img \
  /Users/silicium/garmin-de/out/germany-final.img
```

Then copy as `gmapsupp.img` to `<SD card>/Garmin/` on the device.

## Important env vars (build-germany-roadquest.sh)

| Var | Default | Notes |
|---|---|---|
| `PBF_URL` | germany-latest | Any Geofabrik extract works. |
| `WORK` | `$HOME/garmin-de` | Caches downloads here. |
| `MEM` | `12g` | mkgmap + splitter heap. Use 24g on the server. |
| `MAXNODES` | `2400000` | Splitter tile size. 2.4M tested for whole Germany. |
| `CODE_PAGE` | `1252` | Windows-Latin-1; ~25–30 % smaller MDR than UTF-8. |
| `BOUNDS_SOURCE` | `local` | `precomp` (fast), `local` (needs ≥40 GB RAM for whole Germany — OOM'd at 28 GB), `none` (skips admin lookups). |
| `SEA_SOURCE` | `precomp` | Fallback to `generate-sea` if mirror unreachable. |
| `NO_TYP` | `0` | **Set to 1 for the production architecture** — device firmware renders. |
| `VAN_PATCH` | `0` | Set to 1 to inject van POI categories (charging, atm, camping, etc.). |
| `TYP_NAME` | `OSM_TYP_ID981` | Ignored when `NO_TYP=1`. |
| `ROADQUEST_STAGING` | `/root/roadquest-staging/roadquest` | Where Roadquest style files were unzipped. |

## Critical gotchas

These have all bitten us before. Don't re-trip:

1. **thkukuk mirror URL** — use `https://www.thkukuk.de/osm/data/`, NOT `https://osm.thkukuk.de/data/`. The `osm.*` subdomain has broken TLS. Sea zip nests files inside a `sea/` directory; flatten after unzip (the script handles this).
2. **No `pkill -f <literal_string>` in SSH command bodies** — pkill matches the SSH bash's own command line and self-kills (exit 255). Use `pkill -f '[B]oundaryPreprocessor'` (regex char class) or kill by PID.
3. **Whole-Germany `BoundaryPreprocessor` needs > 28 GB heap** — on a 30 GB box it OOMs. Use `BOUNDS_SOURCE=precomp` (downloads ~2 GB pre-built bounds) or `BOUNDS_SOURCE=none` (loses some admin autofill but works).
4. **Splitter cache invalidates per `MAPNAME` prefix** — changing the mapid prefix triggers a re-split (~8 min). Keep mapname stable across iterations to reuse the split cache.
5. **Disabling a map in 276Cx Map Setup does NOT exclude it from search.** Only physically moving the .img out of `Garmin/` excludes it. The stock worldwide basemap lives in protected internal flash and can't be moved — its (outdated) entries will always appear in search results.
6. **276Cx scale → mkgmap level mapping** (empirical): 120m scale renders level 1 (res 22). 80m and tighter all render level 0 (res 24) as a single bucket — no firmware lever to differentiate "80m" from "5m". POIs at res 24 appear identically across the whole zoom range.
7. **Don't use Jbm with `NO_TYP=1`** — Jbm emits extended Garmin type codes (0x680a, 0x6612, 0x6418, …) that firmware doesn't recognise. Result: missing rendering / generic icons. Stick to Roadquest or another standard-codes style.
8. **TYP source files include Polish characters / curly quotes** — if you ever DO recompile a TYP for code-page 1252, run iconv with `//TRANSLIT` (see legacy `build-germany-jbm.sh`). Currently not relevant under `NO_TYP=1`.
9. **VAN_PATCH=1 env var sometimes doesn't propagate through screen+bash -c** — workaround that works reliably: pre-apply the patcher manually (`patch-style-roadquest-van.sh <src> <dst>`), then rename the dst over the source so the build script picks it up via its default `STYLE_DIR_NAME='Style - Roadquest'`.
10. **"Cities called 'point'" symptom** on the 276Cx = nameless `place=hamlet` entries being indexed. Germany OSM has ~85k hamlets, of which ~30-40k have no `name` tag (auto-imported Ortsteile etc.). The van patcher's hamlet drop fixes this AND speeds search materially.

## Current iteration state (2026-05-31)

V3b is the latest build attempt. Changes vs V2:

- `road-name-pois` disabled (no MDR shrinkage — turned out it wasn't the bloater)
- `place=hamlet` emission commented out via the van patcher (kills ~85k entries + the "point" garbage from unnamed ones)
- Same van POI keep-list (charging, atm, camping, ferry, taxi, fire/police/clinic, supermarkets + chain stores, etc.)

**V4 idea, queued if V3b still feels slow**: ALSO drop `place=city` and `place=town` from our map. The user verified the 276Cx stock worldwide basemap already covers major cities (e.g. Wittstock, a town) — let the basemap handle them while our map handles only `place=village` and below. Risk: basemap is years old, so OSM-only post-basemap cities would be missed entirely. Verify by searching a few mid-tier towns in the basemap first.

## Reference: the place hierarchy decision tree

OSM `place=*` values, by what to do in our map:

| Tag | Count DE | Typical example | V3b: emit? | V4 plan |
|---|---:|---|---|---|
| city | ~80 | Berlin, München | ✓ yes | drop (basemap covers) |
| town | ~3,500 | Wittstock (pop 14k) | ✓ yes | drop (basemap covers) |
| village | ~105,000 | Warberg (pop 941) | ✓ yes | keep |
| hamlet | ~85,000 | (often unnamed) | ❌ dropped V3b | dropped |
| suburb | ~5,000 | (city districts) | ✓ yes | keep |
| isolated_dwelling | small | individual farms | (not emitted by Roadquest) | n/a |

## Licensing

- Repo is **GPL v3** (`LICENSE` at root).
- Build output is GPL v3 (style derived from Petrovsk's CC-BY-SA Roadquest — attribute Petrovsk in any redistribution).
- Map data is OSM (ODbL) — already attributed via `copyright-message` in `mkgmap-roadquest.args`.
- User's name (Marco Meile) is OK in copyright headers; user's email **NOT** — see `memory/feedback_pii.md`.

## Tools used

| Tool | Where | Why |
|---|---|---|
| **mkgmap-r4924** | Auto-downloaded by build script | Compiles OSM → Garmin .img |
| **splitter-r654** | Auto-downloaded | Splits Germany PBF into tiles |
| **gmt v0.8.220** (gmaptool.eu) | Installed at `/usr/local/bin/gmt` on remote | Garmin .img inspection / sub-file extraction |
| `screen` + `nohup` | apt-installed | Long builds (1–2 h) survive ssh disconnect |
