# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 22
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 22: Phase H bulkhead roof-exit rim railing. Extended `_roof`'s stair
bulkhead block: the hut cap (now BH_CAP_OVERHANG = 0.3 m overhang) gets a
4-segment steel rim railing (BH_RAIL_H = 0.45 m, BH_RAIL_T = 0.08 m,
RAIL_COLOR steel, owner_tag "bhexit"). Every rim member sits strictly
ABOVE the bulkhead wall top (total_h + bh_h) so the walk-through doorway
lane stays geometrically untouched — the exit still reads as a deliberate
landmark and the hut roof becomes a grabbable parkour lip (one more
mantle to a fresh vantage). Gated to stair buildings only (no rim on
non-stair decks). Added `--citytest` assertion `_test_bulkhead_rails`
(>=4 colliding steel "bhexit" boxes above doorway lane, footprint inside
the cap zone, deterministic, non-stair building grows none).

## This iteration
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
7. [Next] Phase I idea: roof-exit hatch lid / vents on the bulkhead cap so
   the hut roof reads as a serviced plant room (small destructible steel
   details on the cap, gated to the bulkhead cap zone). Gate: --citytest.
