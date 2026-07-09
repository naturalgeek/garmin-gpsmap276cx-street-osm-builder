#!/usr/bin/env bash
# Copyright (C) 2026 Marco Meile
# Licensed under the GNU General Public License v3.0 or later.
# See LICENSE at the repo root.
#
# Produces a derivative of the Jbm OSM-Mapnik mkgmap style by Jorisbo
# (Joris Boomsma, <jorisbo@hotmail.com>), originally licensed GPL v3.
# Upstream: https://github.com/Jorisbo/Mkgmap-Mapnik-Style-Garmin
#
# Modifications applied to the points file:
#   - Inject a van-driver keep-list filter that deletes the primary tag
#     on POI nodes not in the keep-list.
#   - Retag amenity=charging_station from 0x2a13 to 0x2f1c (Auto Services / Alt Fuel).
#   - Retag shop=supermarket from 0x3000 to 0x2e09 (Shopping).
#   - Add an emit rule for amenity=sanitary_dump_station -> 0x5a02 (Recreation).
#   - Uncomment the border_control emit rule (Community / 0x3006).
#
# Modifications applied to the polygons + lines files:
#   - Drop names from water polygons (natural=water/wetland/bay/spring,
#     waterway=riverbank, landuse=basin/reservoir) and waterway lines.
#     Map still renders water; just no lake/river labels cluttering it.
#
# Modifications applied to the jbmgps TYP source:
#   - Bump LineWidth on road types 0x01-0x0b for chunkier, more legible
#     roads at driving zoom on the 276Cx's small display.
#
# Usage: patch-style-van.sh <src-style-dir> <dst-style-dir>

set -euo pipefail

SRC="${1:?src style dir required}"
DST="${2:?dst style dir required}"

[[ -d "$SRC" ]] || { echo "ERROR: src style dir not found: $SRC" >&2; exit 1; }
[[ -f "$SRC/points" ]] || { echo "ERROR: src/points not found: $SRC/points" >&2; exit 1; }

rm -rf "$DST"
cp -R "$SRC" "$DST"

python3 - "$DST" <<'PY'
import sys, pathlib, re

dst = pathlib.Path(sys.argv[1])
points_path = dst / "points"
polygons_path = dst / "polygons"
lines_path = dst / "lines"

# -------- POINTS: keep-list filter + retags + border_control uncomment --------
with open(points_path, encoding='utf-8') as f:
    text = f.read()

filter_block = """
#=======================================================================================
# VAN-DRIVER POI FILTER (injected by patch-style-van.sh)
# Per filtered category, delete the primary tag on POI nodes whose value is
# NOT in the keep-list; subsequent emit rules in this file then see no
# primary tag and naturally produce no POI for dropped categories.
# Routing-relevant per-node tags (barriers, level crossings) are preserved.
#=======================================================================================

# Drop nameless+brandless shops (chain stores almost all have name and/or brand)
shop = * & !(name = *) & !(brand = *)  { delete shop }

# Drop shop subtypes with no meaningful chain-store presence in Germany
shop ~ '(art|atv|bag|beauty|bed|beverages|bookmaker|carpet|charity|copyshop|dairy|fabric|florist|gift|hairdresser|hearing_aids|houseware|interior_decoration|jewelry|massage|medical_supply|motorcycle_repair|music|musical_instrument|paint|second_hand|stationery|tea|tobacco|travel_agency|video|video_games)'  { delete shop }

# Explicit emit rules for chain-store subtypes Jbm has no specific rule for
# (Saturn=electronics, OBI=doityourself, H&M=clothes, Decathlon=sports, ...).
# Use the generic shop icon (0x2e0c) — distinct icons need TYP work later.
shop = electronics    [0x2e0c resolution 24]
shop = doityourself   [0x2e0c resolution 24]
shop = hardware       [0x2e0c resolution 24]
shop = clothes        [0x2e0c resolution 24]
shop = sports         [0x2e0c resolution 24]
shop = appliance      [0x2e0c resolution 24]
shop = bakery         [0x2e0c resolution 24]
shop = convenience    [0x2e0c resolution 24]
shop = kiosk          [0x2e0c resolution 24]

# Retag EV charging from 0x2a13 (Food & Drink) to 0x2f1c (Auto Services / Alt Fuel)
amenity = charging_station  [0x2f1c resolution 24]
# Retag supermarket from 0x3000 (Community) to 0x2e09 (Shopping)
shop = supermarket          [0x2e09 resolution 24]
# Custom rule for van sanitary dump (Jbm has no rule)
amenity = sanitary_dump_station  [0x5a02 resolution 24]

# Selective keeps: delete the primary tag when value is NOT in the keep-list.
amenity = * & !(amenity ~ '(fuel|charging_station|parking|parking_entrance|hospital|clinic|police|fire_station|border_control|atm|toilets|shower|drinking_water|sanitary_dump_station|ferry_terminal|taxi)')  { delete amenity }
tourism = * & !(tourism ~ '(camp_site|caravan_site|hotel|motel|guest_house|hostel|apartment|chalet|alpine_hut|wilderness_hut)')   { delete tourism }
highway = * & !(highway ~ '(services|rest_area|motorway_junction)')                                                                { delete highway }
railway = * & !(railway ~ '(station|level_crossing)')                                                                              { delete railway }
aeroway = * & !(aeroway = aerodrome)                                                                                               { delete aeroway }
barrier = * & !(barrier ~ '(border_control|toll_booth|gate|lift_gate|bollard|cattle_grid|kissing_gate|stile|cycle_barrier|bus_trap|full-height_turnstile)')  { delete barrier }

# Unconditional drops (shops handled above, not dropped here)
leisure = *           { delete leisure }
historic = *          { delete historic }
man_made = *          { delete man_made }
office = *            { delete office }
military = *          { delete military }
public_transport = *  { delete public_transport }
power = *             { delete power }
natural = peak        { delete natural }
#=======================================================================================
"""

marker = "include 'inc/address';"
if marker not in text:
    sys.stderr.write("ERROR: address-include marker not found in points file\n")
    sys.exit(1)
text = text.replace(marker, marker + "\n" + filter_block, 1)

# Uncomment border_control emit rule
old = "#amenity = border_control | barrier = border_control"
new = "amenity = border_control | barrier = border_control"
if old in text:
    text = text.replace(old, new, 1)
else:
    sys.stderr.write("WARN: border_control rule not found to uncomment\n")

with open(points_path, 'w', encoding='utf-8') as f:
    f.write(text)
print(f"Patched: {points_path}")

# -------- POLYGONS: drop water names --------
water_poly_block = """
#=======================================================================================
# VAN: drop names from water polygons (lake/river labels not wanted on 276Cx).
#=======================================================================================
natural ~ '(water|wetland|bay|spring|coastline)'   { delete name }
landuse ~ '(basin|reservoir)'                       { delete name }
waterway = riverbank                                 { delete name }
water = *                                            { delete name }
#=======================================================================================
"""
with open(polygons_path, encoding='utf-8') as f:
    ptext = f.read()
poly_marker = "include 'inc/address';"
if poly_marker in ptext:
    ptext = ptext.replace(poly_marker, poly_marker + "\n" + water_poly_block, 1)
    with open(polygons_path, 'w', encoding='utf-8') as f:
        f.write(ptext)
    print(f"Patched: {polygons_path} (water name drops)")
else:
    sys.stderr.write(f"WARN: insertion marker not found in {polygons_path}\n")

# -------- LINES: drop waterway names --------
water_line_block = """
#=======================================================================================
# VAN: drop names from waterway lines (river/stream/canal labels not wanted).
#=======================================================================================
waterway = *                                         { delete name }
#=======================================================================================
"""
with open(lines_path, encoding='utf-8') as f:
    ltext = f.read()
# Insert after the shared cache_area_size block (the >=25000000 line is the last)
line_marker = "set jbmareasize = 14"
idx = ltext.find(line_marker)
if idx >= 0:
    eol = ltext.find("\n", idx) + 1
    ltext = ltext[:eol] + water_line_block + ltext[eol:]
    with open(lines_path, 'w', encoding='utf-8') as f:
        f.write(ltext)
    print(f"Patched: {lines_path} (waterway name drops)")
else:
    sys.stderr.write(f"WARN: insertion marker not found in {lines_path}\n")

# -------- TYP: bump road LineWidth values for chunkier streets --------
# Affects rendering only — no impact on data, routing, or compile correctness.
# Tune values here if streets still look wrong on the device.
ROAD_WIDTHS = {
    "0x01": 12,  # motorway        (was 8)
    "0x02": 11,  # primary         (was 8)
    "0x03": 10,  # secondary       (was 8)
    "0x04": 10,  # arterial/trunk  (was 8)
    "0x05": 9,   # collector       (was 8)
    "0x06": 8,   # residential     (was 7)
    "0x07": 4,   # alley/driveway  (was 3)
    "0x08": 6,   # low-speed ramp  (was 5)
    "0x09": 6,   # high-speed ramp (was 5)
    "0x0b": 7,   # major connector (was 5)
}

for typ_basename in ("jbm", "jbmgps", "jbmhb"):
    typ_path = dst / f"{typ_basename}.txt"
    if not typ_path.exists():
        continue
    with open(typ_path, encoding='utf-8') as f:
        ttext = f.read()
    parts = re.split(r'(\[_line\])', ttext)
    bumped = 0
    for i, part in enumerate(parts):
        if part == '[_line]' and i + 1 < len(parts):
            body = parts[i + 1]
            tm = re.search(r'^type=(0x[0-9a-fA-F]+)', body, re.MULTILINE)
            if tm:
                t = tm.group(1).lower()
                if t in ROAD_WIDTHS:
                    new_w = ROAD_WIDTHS[t]
                    body_new, n_sub = re.subn(
                        r'^LineWidth=\d+',
                        f'LineWidth={new_w}',
                        body, count=1, flags=re.MULTILINE
                    )
                    if n_sub:
                        bumped += 1
                        parts[i + 1] = body_new
    if bumped > 0:
        with open(typ_path, 'w', encoding='utf-8') as f:
            f.write(''.join(parts))
        print(f"Patched: {typ_path} ({bumped} road LineWidth values bumped)")

print("All style patches applied")
PY
