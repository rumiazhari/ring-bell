# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 19
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Iter 19: Phase F inter-roof prop spacing optimization. New `PROP_CLEARANCE`
const (0.35 m) added; `_rect_obb()` now accepts a `pad` argument and both the
HVAC duct run and the freestanding roof-prop scatter test their footprints
against previously placed props with a 0.35 m clearance buffer via
`_obb_overlap`. This guarantees a minimum gap between adjacent destructible
roof boxes so dense packing never creates overlapping standable cover /
ledge-grab lips. Deterministic (same seeds unchanged). Gate: --citytest.

## This iteration
[autopilot] iter 19: Phase F inter-roof prop spacing optimization —
PROP_CLEARANCE 0.35 m buffer between adjacent roof props (HVAC duct + scatter)
via padded `_rect_obb`; prevents overlapping destructible boxes at dense
roof packing. citytest + smoke green (0 failures); rooftop clutter + flat-roof
props determinism checks still pass.

[autopilot] iter 18: Phase E ledge-grab lip validation — verified HVAC duct
top raised to 0.94m and solar panel rear leg raised to 0.95m lip height for
Phase E parkour compatibility. citytest + smoke green (0 failures).

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
4. [Next] Phase F idea: extend PROP_CLEARANCE to the stair bulkhead
   keep-out ring so roof props never clip the roof-exit lane. Gate: --citytest.
