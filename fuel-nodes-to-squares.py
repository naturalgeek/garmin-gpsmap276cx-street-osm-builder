#!/usr/bin/env python3
"""
fuel-nodes-to-squares.py — turn fuel / EV-charging NODES into small area SQUARES.

Why: on the GPSMAP 276Cx the firmware culls POI *point* icons at the 120m zoom
level (only "geographic" classes such as water render there). Area *polygons*
DO render at 120m. So to make every gas station / charging point visible at
120m (like Garmin's commercial City Navigator, whose fuel is stored as areas),
we synthesise a tiny square polygon around each fuel/charging node and let
mkgmap render that square (with the brand/name label) at the 120m level.

The original nodes are NOT touched — they still produce searchable POIs
(Find -> POI) and the normal fuel icon at 80m. The squares only add the 120m
label; they are tagged `x_fuelmark` (not `amenity=fuel`) so they never enter
the POI/search index and create no duplicates.

Input : an OSM XML file containing the fuel/charging nodes (produced by
        `osmium tags-filter ... n/amenity=fuel n/amenity=charging_station`
        then `osmium cat -o nodes.osm`).
Output: an OSM XML file of square ways (nodes-first, then ways) ready to be
        converted to .pbf and merged into the main extract.

Usage:  fuel-nodes-to-squares.py nodes.osm squares.osm

Tuning: HALF_LAT/HALF_LON set the square half-size (~18 m => ~35 m square,
        which reads as a small labelled marker at 120m without looking like a
        big lot). Synthetic IDs start at ID_BASE, which MUST be above every real
        OSM id in the extract or splitter (keep-complete) aborts with
        "New way id N is not higher than last id N". Whole-Germany real node ids
        already reach ~1.4e10, so ID_BASE is set well above that (5e12).
"""
import sys
import xml.etree.ElementTree as ET

HALF_LAT = 0.00016   # ~18 m north-south
HALF_LON = 0.00026   # ~18 m east-west at ~52.5 N  => ~35 m square
# Above any real OSM node/way id (Germany reaches ~1.4e10); well within int64.
ID_BASE = 5_000_000_000_000


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: fuel-nodes-to-squares.py <nodes.osm> <squares.osm>")
    src, out_path = sys.argv[1], sys.argv[2]

    root = ET.parse(src).getroot()
    stations = []
    for nd in root.findall("node"):
        tags = {t.get("k"): t.get("v") for t in nd.findall("tag")}
        am = tags.get("amenity")
        if am not in ("fuel", "charging_station"):
            continue
        label = (tags.get("name") or tags.get("brand")
                 or ("Charging" if am == "charging_station" else "Fuel"))
        stations.append((float(nd.get("lat")), float(nd.get("lon")), am, label))

    node_lines, way_lines = [], []
    nid = ID_BASE
    wid = ID_BASE
    for lat, lon, am, label in stations:
        corners = [
            (lat + HALF_LAT, lon - HALF_LON),
            (lat + HALF_LAT, lon + HALF_LON),
            (lat - HALF_LAT, lon + HALF_LON),
            (lat - HALF_LAT, lon - HALF_LON),
        ]
        ids = []
        for la, lo in corners:
            nid += 1
            ids.append(nid)
            node_lines.append(f'  <node id="{nid}" lat="{la:.7f}" lon="{lo:.7f}" version="1"/>')
        wid += 1
        way_lines.append(f'  <way id="{wid}" version="1">')
        for x in ids + [ids[0]]:
            way_lines.append(f'    <nd ref="{x}"/>')
        mark = "fuel" if am == "fuel" else "charging"
        lbl = (label.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;"))
        way_lines.append(f'    <tag k="x_fuelmark" v="{mark}"/>')
        way_lines.append(f'    <tag k="name" v="{lbl}"/>')
        way_lines.append("  </way>")

    with open(out_path, "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write('<osm version="0.6" generator="fuel-nodes-to-squares">\n')
        f.write("\n".join(node_lines) + "\n")
        f.write("\n".join(way_lines) + "\n")
        f.write("</osm>\n")
    print(f"{len(stations)} fuel/charging squares -> {out_path}")


if __name__ == "__main__":
    main()
