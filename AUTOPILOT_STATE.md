# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 20
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 20: Phase F bulkhead keep-out clearance. Extracted `BULKHEAD_RING` const
(1.2 m) and grew the stair-bulkhead keep-out ring by `PROP_CLEARANCE`
(0.35 m) in `_roof_props`, so both freestanding scatter props AND the HVAC
duct run keep a 0.35 m gap from the roof-exit lane boundary instead of
stopping flush against it. Strengthened `_test_roof_props` with a
clearance-buffer assertion (`keepout.grow(PROP_CLEARANCE)`). Deterministic;
same-seed rebuilds identical.

## This iteration
[autopilot] iter 20: Phase F bulkhead keep-out clearance — ring grown by
PROP_CLEARANCE via new BULKHEAD_RING const; props/HVAC never clip the
roof-exit lane. citytest + smoke green (0 failures); strengthened citytest
assertion passes.

[autopilot] iter 19: Phase F inter-roof prop spacing optimization —
PROP_CLEARANCE 0.35 m buffer between adjacent roof props (HVAC duct + scatter)
via padded `_rect_obb`; prevents overlapping destructible boxes at dense
roof packing. citytest + smoke green (0 failures).

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
5. [Next] Phase G idea: rooftop water tower landmark on the largest retail
   flat decks (tall standable tank on legs = fresh vantage + ledge lips).
   Gate: --citytest.
