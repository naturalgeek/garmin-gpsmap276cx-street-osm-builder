#!/usr/bin/env bash
# Copyright (C) 2026 Marco Meile
# Licensed under the GNU General Public License v3.0 or later.
#
# Produces a van-driver variant of Petrovsk's Roadquest style by copying
# it and INJECTING van POI emit rules into the points file. Roadquest is
# already lean (~12 POI rules); this just ADDS the categories we want
# without dropping anything Roadquest emits today.
#
# Uses standard Garmin type codes throughout so the no-TYP firmware
# rendering path produces stock Garmin icons for each POI category.
#
# Usage: patch-style-roadquest-van.sh <src-style-dir> <dst-style-dir>

set -euo pipefail

SRC="${1:?src style dir required}"
DST="${2:?dst style dir required}"

[[ -d "$SRC" ]] || { echo "ERROR: src style dir not found: $SRC" >&2; exit 1; }
[[ -f "$SRC/points" ]] || { echo "ERROR: src/points not found: $SRC/points" >&2; exit 1; }

rm -rf "$DST"
cp -R "$SRC" "$DST"

python3 - "$DST" <<'PY'
import sys, pathlib

dst = pathlib.Path(sys.argv[1])
points_path = dst / "points"

with open(points_path, encoding='utf-8') as f:
    text = f.read()

van_block = """
#=======================================================================================
# VAN-DRIVER POI ADDITIONS (injected by patch-style-roadquest-van.sh)
# Uses standard Garmin type codes so the no-TYP firmware rendering produces
# stock Garmin icons. Filter: only emit shops with name or brand (chain stores).
#=======================================================================================

# Drop nameless+brandless shops (chain stores almost all have name/brand)
shop = * & !(name = *) & !(brand = *)  { delete shop }

# Drop shop subtypes with no useful chain-store presence
shop ~ '(art|atv|bag|beauty|bed|beverages|bookmaker|carpet|charity|copyshop|dairy|fabric|florist|gift|hairdresser|hearing_aids|houseware|interior_decoration|jewelry|massage|medical_supply|motorcycle_repair|music|musical_instrument|paint|second_hand|stationery|tea|tobacco|travel_agency|video|video_games)'  { delete shop }

# Fuel & EV (Fuel Service Find category)
amenity = fuel              [0x2f01 resolution 23]
amenity = charging_station  [0x2f1c resolution 23]

# Auto Services
amenity = car_rental        [0x2f02 resolution 23]
amenity = taxi              [0x2f0d resolution 23]
amenity = motorcycle        [0x2f07 resolution 24]

# Bank/ATM
amenity = atm               [0x2f19 resolution 24]

# Lodging
tourism = motel             [0x2b09 resolution 23]
tourism = guest_house       [0x2b02 resolution 24]
tourism = hostel            [0x2b08 resolution 24]
tourism = apartment         [0x2b0a resolution 24]
tourism = chalet            [0x6418 resolution 24]
tourism = alpine_hut        [0x6416 resolution 22]
tourism = wilderness_hut    [0x6417 resolution 24]

# Recreation (Camping)
tourism = camp_site         [0x5a01 resolution 22]
tourism = caravan_site      [0x5a02 resolution 22]
amenity = sanitary_dump_station  [0x5a02 resolution 24]

# Community / Emergency
amenity = police            [0x3001 resolution 23]
amenity = fire_station      [0x3008 resolution 23]
amenity = clinic            [0x300a resolution 24]
amenity = border_control    [0x3006 resolution 20]
barrier  = border_control   [0x3006 resolution 20]

# Transportation
amenity = ferry_terminal    [0x5903 resolution 23]
aeroway = aerodrome         [0x6402 resolution 22]

# Van utilities (low priority but useful)
amenity = toilets           [0x2f1d resolution 24]
amenity = shower            [0x2f1d resolution 24]
amenity = drinking_water    [0x5000 resolution 24]

# Shopping (chain stores — brand or name filter applies above)
shop = supermarket          [0x2e09 resolution 24]
shop = department_store     [0x2e01 resolution 24]
shop = mall                 [0x2e01 resolution 24]
shop = electronics          [0x2e0c resolution 24]
shop = doityourself         [0x2e0c resolution 24]
shop = hardware             [0x2e0c resolution 24]
shop = clothes              [0x2e0c resolution 24]
shop = sports               [0x2e0c resolution 24]
shop = appliance            [0x2e0c resolution 24]
shop = bakery               [0x2e0c resolution 24]
shop = convenience          [0x2e0c resolution 24]
shop = kiosk                [0x2e0c resolution 24]
shop = furniture            [0x2e09 resolution 24]
shop = garden_centre        [0x2e08 resolution 24]
shop = books                [0x2e0c resolution 24]
shop = shoes                [0x2e0c resolution 24]
shop = optician             [0x2e14 resolution 24]
shop = mobile_phone         [0x2e0c resolution 24]
shop = computer             [0x2e0c resolution 24]
shop = chemist              [0x2e0d resolution 24]
shop = toys                 [0x2e0c resolution 24]
shop = bicycle              [0x2e0c resolution 24]
shop = butcher              [0x2e0e resolution 24]
shop = deli                 [0x2e0a resolution 24]
shop = variety_store        [0x2e0c resolution 24]
shop = pet                  [0x2e11 resolution 24]
shop = outdoor              [0x2e0c resolution 24]
shop = coffee               [0x2e0c resolution 24]
shop = hifi                 [0x2e0c resolution 24]
shop = ticket               [0x2e0c resolution 24]
shop = car                  [0x2f07 resolution 24]
shop = car_dealer           [0x2f07 resolution 24]
shop = car_repair           [0x2f03 resolution 24]
shop = car_parts            [0x2f07 resolution 24]
#=======================================================================================
"""

# Inject before the first "place=city" emit rule (start of emit block)
marker = "place=city [0x0400"
if marker in text:
    text = text.replace(marker, van_block + "\n" + marker, 1)
else:
    sys.stderr.write(f"WARN: marker not found in {points_path}; appending block at end instead\n")
    text = text + "\n" + van_block

# Search-speed tuning: drop place=hamlet emission. Germany has ~85k hamlets,
# many auto-imported without name tags — they bloat the MDR cities index
# AND show as nameless "point" entries in Find→Cities. The nearest village
# is what users actually search for; hamlets are essentially noise.
hamlet_old = "place=hamlet [0x1100 resolution 23]"
hamlet_new = "#place=hamlet [0x1100 resolution 23]  # dropped for MDR speed (van patcher)"
if hamlet_old in text:
    text = text.replace(hamlet_old, hamlet_new, 1)
    print("  dropped place=hamlet emission")

# Fix: Roadquest doesn't set mkgmap:label1/mkgmap:city on place rules, so cities
# go into the MDR with empty name fields — device shows them as "point" and
# alphabetical search can't find them. Also drop unnamed places entirely.
place_fixes = [
    ("place=city & name=* { set mkgmap:label1='${name}'; set mkgmap:city='${name}' } [0x0400 resolution 17]",
     "place=city & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0400 resolution 17]"),
    ("place=town & name=* { set mkgmap:label1='${name}'; set mkgmap:city='${name}' } [0x0800 resolution 18]",
     "place=town & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0800 resolution 18]"),
    ("place=village & name=* { set mkgmap:label1='${name}'; set mkgmap:city='${name}' } [0x0900 resolution 20]",
     "place=village & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0900 resolution 20]"),
    ("place=city [0x0400 resolution 17]",
     "place=city & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0400 resolution 17]"),
    ("place=town [0x0800 resolution 18]",
     "place=town & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0800 resolution 18]"),
    ("place=village [0x0900 resolution 20]",
     "place=village & name=* { name '${name}'; set mkgmap:city='${name}' } [0x0900 resolution 20]"),
]
for old, new in place_fixes:
    if old in text:
        text = text.replace(old, new, 1)
        print(f"  patched: {old.split(' [')[0]}")

with open(points_path, 'w', encoding='utf-8') as f:
    f.write(text)
print(f"Patched: {points_path}  (van POI block injected)")
PY
