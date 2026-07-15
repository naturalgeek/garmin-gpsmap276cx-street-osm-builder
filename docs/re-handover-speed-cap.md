# RE handover — vehicle speed cap (85 km/h van) and how the 276Cx router uses it

**Audience:** firmware reverse engineer for the GPSMAP 276Cx.
**Goal of this note:** explain *exactly* what we changed in the map data, and list
the specific firmware questions that would let us calibrate it correctly.

We have **not** changed anything on the device. The change is 100% in the
compiled `gmapsupp.img`. We need the RE to tell us how the firmware router
*interprets* one field so we can pick the right value.

---

## 1. Background (one paragraph)

Custom OSM-derived map for the 276Cx, built with **mkgmap r4924**, no TYP
(firmware renders standard type codes). The vehicle is a **speed-limited van**:
absolute max ~94 km/h, realistic sustained highway ~92, typical cruising 85.
We want on-device routing — both **ETA** and **fastest-route choice** — to reflect
that ceiling instead of assuming Autobahn speeds (100–130). We did this by
lowering the per-road **speed class** in the map. Whether our chosen cap value is
right depends on how the firmware maps that class to an actual velocity — hence
this handover.

---

## 2. What we changed (map-data level, exact)

For **every routable road**, we clamp the Garmin **road speed class** to a
maximum of **4**.

- The Garmin `.img` routing data stores, per routable road, a **3-bit speed
  class (values 0–7)** and a **road class (0–4)**. These live in the routing
  subfiles: **NET** (road definitions) and **NOD** (routing graph). mkgmap emits
  them from the style (mkgmap's `RoadDef`: `roadSpeed` 0–7, `roadClass` 0–4).
- In the mkgmap style we set the internal tag `mkgmap:road-speed-max = 4` in the
  finalizer, which makes mkgmap **clamp the final speed class to ≤ 4**. Concretely
  the style rule (in `style/Style - Default-Van/inc/speedcap`) is:

  ```
  highway=* & mkgmap:road-speed-max > 4 { set mkgmap:road-speed-max = 4 }
  highway=* & mkgmap:road-speed-max!=* { set mkgmap:road-speed-max = 4 }
  ```

- Net effect on the data: the **only** thing that physically differs from the
  normal map is that 3-bit speed field on fast roads. Roads that were class
  **5/6/7** (fast rural / trunk / motorway / unlimited Autobahn) become **4**.
  Roads already ≤ 4 are unchanged. Geometry, road class, names, everything else
  is identical.

### How a road gets its class in the first place (full chain)

OSM `maxspeed` → (our style `inc/roadspeed`) → mkgmap speed class, then our cap:

| OSM maxspeed | mkgmap speed class | after our cap `min(class,4)` |
|---|---|---|
| ≤10 km/h | 0 | 0 |
| ≤25 | 1 | 1 |
| ≤45 | 2 | 2 |
| ≤60 | 3 | 3 |
| ≤85 | 4 | 4 |
| ≤100 | 5 | **4** |
| ≤120 | 6 | **4** |
| >120 / unlimited | 7 | **4** |

So "class 4" in our world nominally means "a road limited to ≤85 km/h."

---

## 3. Two maps provided for a direct data diff

Same tiles, same geometry, **only the speed field differs** — ideal for isolating
the field and then tracing its use in firmware:

- **Uncapped:** `root@<BUILD_HOST>:/root/germany-build/out24/gmapsupp.img`
- **Capped (VAN85):** `root@<BUILD_HOST>:/root/germany-build/out24van85/gmapsupp.img`
- Both: family-id **234**, product-id 1, whole Germany, 192 tiles.

Pick any Autobahn road present in both; its speed-class field should read
**6 or 7 in `out24`** and **4 in `out24van85`**. (We can extract the raw NET/NOD
bytes for a specific road on request.)

---

## 4. What we need from the firmware RE

1. **The speed-class → velocity table.** The router almost certainly maps each of
   the 8 speed classes (0–7) to an assumed velocity (km/h or an internal unit)
   to compute per-segment travel time for the "Faster Time" calculation.
   - Where is this table in ROM? (Analogous to the polygon style table you found
     at `0x84e334`.)
   - **What velocity does class 4 map to? And class 5?** This is the crux: if
     class 4 ≈ 85 km/h, our cap is exactly right. If class 4 is much lower (e.g.
     ~70), ETAs will be too pessimistic and we should cap at **5** instead.
2. **Route preference vs. time.** Does the router use **road class** (the
   hierarchy: motorway > trunk > … ) to bias route *choice* independently of the
   speed-derived travel time? i.e. will lowering only the speed field actually
   stop it over-preferring Autobahns, or does the road-class/hierarchy penalty
   also need adjusting?
3. **Travel-time formula.** How is a segment's time computed — `length /
   velocity(speedClass)` plus turn/road-class/junction penalties? Any global
   multipliers?
4. **Vehicle profile & settings interaction.** Does the on-device **vehicle
   profile** (Automobile/Truck/…) or the **Faster Time vs Shorter Distance**
   setting change how the speed field is interpreted or weighted?
5. **Where the field is read.** The routine(s) that read the per-road speed class
   out of NET/NOD during route search (so we can confirm the 3-bit field is the
   one we think it is, and that nothing else overrides it).

---

## 5. Why this matters for our choice

Speed is stored as a **discrete 0–7 class**, so we can't encode "exactly 85." Our
two realistic options are:

- **Cap at class 4** — models fast roads as "≤85"; matches the van's *typical* 85
  and gives conservative ETAs. (What we shipped.)
- **Cap at class 5** — models them as "≤100"; matches the van's *max* 92–94 but
  ETAs run optimistic.

Knowing the firmware's actual km/h for classes 4 and 5 lets us pick correctly
instead of guessing. Changing the cap is a one-character edit + rebuild.

---

## 6. Reference (our side)

- Style: `style/Style - Default-Van/` (mkgmap style, standard type codes, no TYP).
- Cap rule: `style/Style - Default-Van/inc/speedcap` (included by `lines`
  finalize), generated by `ci/build-map.sh` when `VAN85=<class>` is set.
- Speed-class assignment: `style/Style - Default-Van/inc/roadspeed`.
- mkgmap encoding: `RoadDef.roadSpeed` (0–7) / `roadClass` (0–4) → NET/NOD.
