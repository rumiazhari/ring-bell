# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 23
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 23: Phase I bulkhead plant-room details. On stair buildings only, the
bulkhead cap (already BH_CAP_OVERHANG overhang + Phase H "bhexit" rim)
now grows a serviced-plant-room set on the cap surface: a steel access
hatch lid (0.95 m) + two galvanized vent louvers (0.5 x 0.25 m), all
destructible steel tagged "bhplant", resting ON cap_top (above the
doorway lane, inside the railed enclosure). Reads as a real mechanical
room rather than a bare lid; adds extra carveable cover + small standable
lips. Added `--citytest` assertion `_test_bulkhead_plant` (exactly 3
colliding steel "bhplant" boxes on the cap, footprint inside the cap
zone, deterministic, non-stair building grows none).

## This iteration
[autopilot] iter 23: Phase I bulkhead plant-room details — steel hatch lid
+ 2 vent louvers on the cap surface (above doorway lane, inside the Phase
H rim), tagged "bhplant", gated to stair buildings. citytest + smoke green
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
8. [Next] Phase J idea: rooftop access ladder from the deck to the bulkhead
   cap rim — a steel rung ladder (destructible "bhplant") so the
   plant-room roof is actually climbable, not just a mantle target.
   Gate: --citytest.
