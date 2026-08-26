# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 25
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 25: Phase K facade balconies — AC-style cantilevered concrete decks
protruding from upper-storey facades (f>=1, non-entrance, long facades only),
each capped by a steel railing lip (BAL_RAIL_H = 0.5 m) that doubles as a
grabbable parkour ledge. Deterministic per (floor, side, building) via
WorldSeed; boxes tagged "balcony" (standable concrete deck + steel lip).
Added `--citytest` assertion `_test_balconies` (>=1 "balcony" box on a
multi-storey building, above ground/inside footprint band, gated to
multi-storey, byte-identical rebuild, single-storey grows none).

## This iteration
[autopilot] iter 25: Phase K facade balconies — cantilevered concrete decks
+ steel railing lip (grabbable parkour ledge) on upper-storey facades,
deterministic, gated to multi-storey, tagged "balcony". citytest + smoke +
cityruntime green (0 failures); new `_test_balconies` assertion passes.

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
