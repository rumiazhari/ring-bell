# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 21
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 21: Phase G rooftop water-tower landmark. Added `_tower_landmark`
to BuildingBuilder, gated to the LARGEST RETAIL flat decks (area >=
TOWER_MIN_AREA = 90 m^2, no pitched attic shell): a tall standable steel
tank on four legs + rim cap + ladder rungs, seeded by the deck rect and
kept clear of the stair bulkhead keep-out ring. Tower boxes carry
owner_tag "tower" and are destructible steel (collide = fresh vantage and
ledge-grab lip). New helpers `is_retail_deck`, `usable_roof_rect`,
`keepout_roof`. Added `--citytest` assertion `_test_roof_tower`
(placement-bounded, stands >3.4 m above deck, deterministic, gated so
small retail + residential decks grow none).

## This iteration
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
6. [Next] Phase H idea: rooftop access railings / hatch lips on the stair
   bulkhead roof exit so the exit reads as a deliberate landmark and gives
   one more parkour lip. Gate: --citytest.
