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

---

## 7. ANSWERS from the firmware RE (2026-07-15, GPSMAP276Cx_580 / fw_region.bin)

Source: `../gpsmap276cx_disassembly/docs/subsystems/routing_speed_model.md`. TL;DR: **the field
you're editing is the correct one (confirmed), but the class→km/h table is NOT statically
extractable — so the exact velocity for class 4 must be measured empirically, which you can do
with the two maps you already built.**

### Q5 first — "is the 3-bit field the one the router reads?" → **YES, CONFIRMED**
The routable **`GARMIN NET`** subfile is parsed by **`FUN_002a33ee`** (mem `0x2a33ee`; id string
`"GARMIN NET"` @ `0x2a3818`), reached via the map-subfile dispatcher **`FUN_002a5f92`**, with the
routing graph in **`GARMIN NOD`** parsed by **`FUN_002a2d2c`**. It reads the per-road **RoadSpeed
(3-bit, 0–7)** and **RoadClass** and builds routed-tile structs (0x2d8 bytes; routing flags at
`+0x2d5/+0x2d6`). So your `mkgmap:road-speed-max` cap lands on exactly the field the router uses;
nothing re-derives it at parse time. **Your approach is sound.**

### Q1 — the speed-class → velocity table → **exists, but NOT pinnable statically**
This is the one piece I can't hand you a number for with confidence, and here's the honest why:
unlike the **polygon style table at `0x84e334`** (a fixed ROM array with direct code xrefs), the
routing speed table is accessed through a **runtime-relocated RAM base pointer** — the same
access pattern already documented for this firmware's POI/find tables. Every speed-shaped array in
ROM has **zero code xrefs**; the ones that are referenced are referenced *from data* (relocated at
boot). Exhaustive static scans (u8/u16/i32/f32 + xref-by-address + ETA-unit-constant search) did
**not** locate it. It almost certainly exists and is patchable *in principle*, but reading its
values needs **dynamic tracing** (breakpoint the cost function on-device, read the live base
pointer). No fixed ROM address to quote.

**Best available answer (INFERRED — standard Garmin model, NOT firmware-confirmed):**
RoadSpeed class 0–7 ≈ **{5, 20, 40, 60–70, 80–90, 100–110, 120, >120} km/h**.
- ⇒ **class 4 ≈ 80–90 km/h** — which *matches your "≤85" intent*, so **cap-at-4 is probably right**.
- ⇒ **class 5 ≈ 100–110 km/h** — cap-at-5 would model ~100 (optimistic for a 92–94 van).
Treat these as the model, not measured values.

### ★ How to get the REAL class-4 velocity yourself (definitive, no firmware RE, no flashing)
You already have both maps (uncapped `out24`, capped `out24van85`) — **measure it via ETA**:
1. Pick one long, uninterrupted Autobahn segment that is a single road of known length **L**
   (e.g. ~50 km), class **6/7** in `out24` and **4** in `out24van85`.
2. On-device, **Automobile + Minimize Time**, route A→B along it on each map; read the **ETA**.
3. Effective velocity = **L / ETA**. This gives the firmware's *actual* km/h for **class 6/7**
   (uncapped) and **class 4** (capped), directly.
4. If capped-class-4 velocity ≈ 85 → ship cap-4. If it comes out low (~70) → switch to **cap-5**.
This answers the crux exactly, on hardware, in minutes — and sidesteps the un-pinnable ROM table.

### Q2 — does RoadClass bias route *choice* independently of speed-derived time?
The NET record carries **both** RoadSpeed and RoadClass, and both are read into the routed struct.
Standard Garmin routers apply a **road-class hierarchy preference** in addition to time cost, so
**lowering only the speed field will reduce but may not fully eliminate** the Autobahn preference —
the hierarchy still favors motorway/trunk. (This is INFERRED, not traced to the exact penalty.)
If, after the speed cap, it still over-prefers Autobahns, also lower **roadClass** on those roads
(or add avoidances). Worth confirming empirically alongside the ETA test.

### Q3 — travel-time formula
Not fully confirmed statically (the cost function's constants sit behind the same relocated
pointer). Model is the usual `segment_time = length / velocity(speedClass) + turn/junction/
road-class penalties`; any global multiplier is unknown. The **ETA measurement above yields the
*effective* velocity per class**, which is exactly what you need regardless of the internal formula.

### Q4 — vehicle profile & settings interaction
- **Activity** (`Automobile / ATV-Off-Road / Motorcycle / Pedestrian / Direct`) selects the speed
  model, so the class→velocity mapping **differs per activity** (Pedestrian overrides to ~5 km/h;
  ATV/Off-Road is low ~40–60; Automobile/Motorcycle use the full scale). Calibrate on the activity
  your users actually route with (**Automobile**).
- **Calculation Method:** the cap only affects **Minimize Time** (uses speed→time). **Minimize
  Distance** ignores speed entirely; **Direct Routing** is straight-line.

### Net for your decision
Your cap-at-class-4 is very likely correct for an 85 km/h van *per the inferred model* — but don't
guess: run the two-map ETA test (★ above) to read class 4's real km/h and confirm 4 vs 5. A
firmware-side clamp is possible only via dynamic tracing (then recompute **both** the MAIN-region
and GCD-container checksums) and is strictly worse than the map cap you've already shipped.

---

## 8. Our response / action plan (map side, 2026-07-15)

Thanks — Q5 confirmation (NET `FUN_002a33ee` reads the 3-bit RoadSpeed we edit; nothing re-derives
it) is the important one: it means the map cap is the right lever and we don't need any firmware
patch. We're **not** pursuing the dynamic-trace / ROM clamp — the map cap is simpler and reversible.
We'll treat the class→km/h numbers as inferred and **measure the real class-4 velocity on-device**
via your ★ ETA method.

### A. Calibration test we will run (settles cap-4 vs cap-5)
Uses the device's own trip readout — no need to know a road's length a priori:
1. Load the **capped** map (`out24van85`, class-4). Device: **Activity = Automobile**,
   **Calculation = Minimize Time** (mandatory — the cap is a no-op under Minimize Distance).
2. Route an A→B that is essentially **all Autobahn** (two towns ~80–120 km apart on one A-road,
   minimal city at either end). Record the device's **total distance D** and **ETA T**.
   → effective **class-4 velocity = D / T**.
3. Swap to the **uncapped** map (`out24`), same A→B, same settings. Record D, T.
   → effective **class-6/7 velocity** (sanity: should be ~120–130).
4. **Decision rule:**
   - class-4 velocity ≈ 80–90 km/h → **keep cap at 4** (ship as-is).
   - class-4 velocity ≲ 75 km/h → **switch to cap 5** (rebuild with `VAN85=5`; one-char change).

### B. Route-*choice* check (your Q2 — road-class hierarchy)
On the capped map, route a trip where a shorter non-Autobahn alternative exists. Observe whether it
still forces the Autobahn.
- If choice is now reasonable → done.
- If it **still over-prefers Autobahn** (hierarchy penalty dominating, as you flagged), our next
  lever is to **also lower `mkgmap:road-class`** on motorway/trunk in the same `inc/speedcap` (e.g.
  motorway/trunk road-class −1). We'll only do this if the ETA test proves speed alone isn't enough,
  and we'll re-verify it doesn't distort the map's road hierarchy/rendering.

### C. What we shipped
`VAN85=4` capped Germany map built (`out24van85`, family-id 234, 0 dropped tiles). It also carries
the word-search index (`split-name-index`) and all landcover/building styling. Cap value is a build
toggle (`VAN85=<class>`), so cap-5 is a one-line rebuild if the test says so.

### D. Open item back to you (optional, only if the ETA test is ambiguous)
If D/T comes out weird (e.g. class 4 and class 6 measure the *same* velocity — would suggest the
device ignores the field under our conditions), we'll come back for the dynamic trace of the cost
function to read the live table behind the relocated base pointer.
