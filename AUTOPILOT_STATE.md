# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 30
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 30: Phase P facade cornices + pilasters — horizontal stone cornice bands
at each storey junction (grabbable ledge, CORN_H 0.18, CORN_PROJ 0.26) +
segmented vertical pilaster pillar strips per storey (PIL_W 0.32, PIL_PROJ
0.24, PIL_SPACING 3.2), both stone/concrete, colliding, tagged
"cornice"/"pilaster", deterministic per (side, building), gated to historic
multi-storey + long facade (CORN_MIN_SIDE/PIL_MIN_SIDE 6.0, CORN_PROB 0.62,
PIL_PROB 0.58). MeshBatcher stamps vox_tag cornice/pilaster for parkour,
citytest gained `_test_cornices_pilasters` (protrusion, material, thickness,
determinism, 3 negative gates).

## This iteration
[autopilot] iter 30: Phase P facade cornices + pilasters — BuildingBuilder grows horizontal stone cornice bands at each storey junction (CORN_H 0.18, CORN_PROJ 0.26, concrete, tagged "cornice") + segmented vertical pilaster pillar strips per storey (PIL_W 0.32, PIL_PROJ 0.24, concrete, tagged "pilaster") on historic multi-storey long facades; deterministic per (side, building), gated to historic + multi-storey + long facade. MeshBatcher now carries vox_tag cornice/pilaster. citytest + smoke green (0 failures); 1 new assertion passes ("facade cornices + pilasters: stone ledge bands + pillar strips on historic multi-storey facades").
[autopilot] iter 29: Phase O construction scaffold — CityPlan emits district + plaza_adjacent (historic + plaza-ring check), BuildingBuilder grows a full-height steel cage + wood plank decks (tagged "scaffold", SCAFF_PROJ 1.0, SCAFF_W 3.4) on one shuffled long facade of plaza-adjacent historic buildings; planks at each storey provide mid-height AC traversal. MeshBatcher now carries vox_tag scaffold. citytest + smoke green (0 failures); 1 new assertion passes ("construction scaffolding: steel cage + plank decks on plaza-adjacent historic facades").
[autopilot] iter 28: Phase N awning->balcony chain — BuildingBuilder now
hosts balconies on the street wall at f>=1 (same BAL_PROB, enabling
stacked awning->balcony generation); smoke fixture proves the balcony lip
(steel, vox_tag balcony, top 3.75) is grabbable from a fall alongside the
stack and that the 2.3->3.75 rise (1.45) sits comfortably inside the
LEDGE_TOP_MIN/REACH window, confirming ground->first-floor chaining needs
no height tuning. citytest + smoke green (0 failures); 5 new assertions
pass ("balcony grab triggered during fall", "chain height delta within
grab window", etc.).
[autopilot] iter 27: Phase M awning-grab classification in the parkour
controller (vox_tag meta from MeshBatcher, awning_grabs counter, gentler
AWNING_DRIVE_SPEED follow-through); smoke fixture mimics real iter-26
awning geometry. citytest + smoke green (0 failures); 5 new/extended
assertions pass ("awning grab classified as awning", "survivor mounted
awning deck", etc.).
[autopilot] iter 26: Phase L street awnings — sloped canopy deck from the
ground-floor street facade + steel front lip (grabbable parkour ledge);
deterministic, gated to street wall + AWN_MIN_SIDE, tagged "awning".
citytest + smoke green (0 failures); new `_test_awnings` assertion passes.

[autopilot] iter 24: Phase J bulkhead roof-access ladder — a vertical run of destructible
steel rungs on the hut's +Z face climbing from just above the deck up to the
Phase H rim top, so the serviced plant-room roof (Phase H rim + Phase I hatch)
is actually CLIMBABLE rather than a mantle-only target. Rungs tagged "bhladder",
deterministic, gated to stair buildings. Added `--citytest` assertion
`_test_bulkhead_ladder` (>=4 ascending steel "bhladder" rungs, footprints
inside the cap zone, bottom near deck + top at cap, deterministic, non-stair
buildings grow none).

[autopilot] iter 23: Phase I bulkhead plant-room details — steel hatch lid
+ 2 vent louvers on the cap surface (above doorway lane, inside the Phase
H rim), tagged "bhplant", gated to stairs. citytest + smoke green
(0 failures); new `_test_bulkhead_plant` assertion passes.

[autopilot] iter 22: Phase H bulkhead roof-exit rim railing — 4-segment
steel rail (0.45 m) around the hut cap, fully above the doorway lane
(exit path untouched), hut roof becomes a grabbable parkour lip; rim
tagged "bhexit", gated to stair buildings. citytest + smoke green (0
failures); new `_test_bulkhead_rails` assertion passes.

[autopilot] iter 21: Phase G rooftop water tower on large retail flat decks
(area >= 90 m^2, no attic) — four legs + tank + rim cap + ladder rungs,
seeded, clear of the bulkhead keep-out ring; tower boxes tagged "tower",
destructible steel. citytest + smoke green (0 failures); new tower
assertion passes.

[autopilot] iter 20: Phase F bulkhead keep-out clearance — ring grown by
PROP_CLEARANCE via new BULKHEAD_RING const; props/HVAC never clip the
roof-exit lane. citytest + smoke green (0 failures); strengthened citytest
assertion passes.

[autopilot] iter 19: Phase F inter-roof prop spacing optimization —
PROP_CLEARANCE 0.35 m buffer between adjacent roof props (HVAC duct +
scatter) via padded `_rect_obb`; prevents overlapping destructible boxes
at dense roof packing. citytest + smoke green (0 failures).

## Backlog
1. Phase D slice 5 COMPLETE: rooftop variety pass - retail roofs get
   billboards, residential gets laundry lines/pigeon coops (reuse
   _roof_props seeding). [COMPLETE in iter 17]
2. [Done] Phase E idea: parkour ledge-grab lip validation — all new
   destructible boxes' ledge-grab geometry satisfies the Phase E parkour
   test suite. Gate: --smoke. [COMPLETE in iter 18/19]
3. [Done] Phase F idea: inter-roof prop spacing optimization — prevent
   overlapping destructible boxes at dense roof packing. Gate: --citytest.
   [COMPLETE in iter 19]
4. [Done] Phase F idea: extend PROP_CLEARANCE to the stair bulkhead
   keep-out ring so roof props never clip the roof-exit lane. Gate:
   --citytest. [COMPLETE in iter 20]
5. [Done] Phase G idea: rooftop water tower landmark on the largest retail
   flat decks (tall standable tank on legs = fresh vantage + ledge lips).
   Gate: --citytest. [COMPLETE in iter 21]
6. [Done] Phase H idea: rooftop access railings on the stair bulkhead
   roof exit — steel rim around the hut cap (reads as landmark + grabbable
   parkour lip, sits above the doorway lane). Gate: --citytest.
   [COMPLETE in iter 22]
7. [Done] Phase I idea: roof-exit hatch lid / vents on the bulkhead cap so
   the hut roof reads as a serviced plant room (small destructible steel
   details on the cap, gated to the bulkhead cap zone). Gate: --citytest.
   [COMPLETE in iter 23]
8. [Done] Phase J idea: rooftop access ladder from the deck to the bulkhead
   cap rim — a steel rung ladder (destructible "bhladder") so the
   plant-room roof is actually climbable, not just a mantle target.
   Gate: --citytest. [COMPLETE in iter 24]
9. [Done] Phase K idea: facade balconies — AC-style cantilevered concrete
   decks + steel railing lip (grabbable parkour ledge) on upper storeys,
   deterministic, gated to multi-storey, tagged "balcony". Directly serves
   the Prague directive's named "balconies" parkour feature. Gate: --citytest.
   [COMPLETE in iter 25]
10. [Done] Phase M idea: awning-led low-mantle traversal — the street canopy
   deck (AWN_DECK_Y) becomes a grabbable entry perch feeding ledge/awning
   chaining on the ground floor; the Phase-E parkour controller now treats
   "awning" boxes as their own soft-structure grab class (vox_tag meta,
   awning_grabs counter, AWNING_DRIVE_SPEED follow-through). Gate: --smoke.
   [COMPLETE in iter 27]
11. [Done] Phase N idea: awning->balcony chain reach audit - verify (smoke
    fixture) that from a standable awning deck (2.3 m) a jump-grab can
    catch the first balcony deck of a 2-storey facade, making ground->
    first-floor traversal a real AC-style chain; tune AWN_DECK_Y/BAL
    heights only if the gap is unreachable. Gate: --smoke.
    [COMPLETE in iter 28] rise 1.45 inside 0.9-2.1, no tuning needed.
12. [Done] Phase O idea: construction scaffold on plaza-adjacent historic facades
    — steel pole cage + plank decks (standable) tagged "scaffold",
    deterministic, gated to plaza adjacency; adds mid-height AC
    scaffolding traversal. Gate: --citytest. [COMPLETE in iter 29]
13. [Done] Phase P idea: facade cornices + pilasters — horizontal stone cornice
    bands + vertical pilaster strips (grabbable ledge network) on historic
    multi-storey facades, tagged "cornice"/"pilaster", deterministic,
    gated to historic multi-storey + long facade; completes the AC
    "ledges/pillars" parkour vocabulary. Gate: --citytest.
    [COMPLETE in iter 30]
14. Phase Q idea: post-apoc facade decay pass — graffiti/decal layers, rust
    streaks, overgrowth/moss on historic cornices/pilasters, broken windows
    variant; visual-only, deterministic, gated to historic district; brings
    the Prague core out of white-dummy into the directive's eerie decayed
    aesthetic. Gate: --citytest (determinism + gating).

## ⭐ USER DIRECTIVE (2026-08-26 evening) — PRAGUE ASSASSIN-CITY PIVOT
Supersedes current goal priorities after the in-flight Phase E slice lands:

1. ONE handcrafted great map (no multi-seed requirement): a Prague-style
   European historic core done to Assassin's-Creed standard.
2. REALISTIC ARCHITECTURE & SCALE: apartments with bedrooms/dining/kitchens/
   toilets; offices with office interiors; shops, grocery stores, malls,
   workshops, schools, universities — each building type with logical interior
   layout, and TOILETS/logical service rooms in every building. Human-scale
   floor heights (~3 m), believable room dimensions.
3. SPATIAL PARKOUR MECHANICS like AC: ledges, fences, gates, pillars, awnings,
   balconies, scaffolding, rooftops — the city is climbable as a traversal
   space, integrated with the Phase-E parkour controller.
4. POST-APOC EUROPEAN AESTHETIC — NO MORE WHITE-DUMMY LOOK: proper textures,
   shading/shadow/light systems, bloom, reflections, water rendering. Eerie
   horror zombie-apocalypse mood: decayed facades, graffiti, rust, overgrowth.
5. LIGHT AS GAMEPLAY: night is genuinely dark; lanterns/flashlights/fire/torch
   matter for visibility — light/darkness becomes a survival mechanic.
Keep gates green (citytest/smoke/cityruntime/havoctest/walkthrough).
