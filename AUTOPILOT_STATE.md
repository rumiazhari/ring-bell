# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 17
UPDATED: 2026-08-27 (JST, cron run)

## Current goal
Phase D slice 6 COMPLETE: rooftop clutter pass. Flat roofs now carry
HVAC duct runs (linear galvanized chases with steel stands) lining the
parapet walkway, solar thermal panels (dark glass absorber on two steel
legs) on residential roofs, and satellite dishes (concrete footplate +
steel pedestal + stacked plates + feed arm) on retail roofs. All new props
are DESTRUCTIBLE boxes — standable cover that doubles as fresh
ledge-grab lips for Phase E parkour. Selection driven by
style.room_type from CityPlan's BuildingSpec; deterministic
WorldSeed.rng_for("roofprops", [wall, roof, d*10]) seeding extended with
kind pool filtering (shared 0-4 | retail-only 7 | residential-only 5/6).

## This iteration
[autopilot] iter 17: Phase D slice 6 -- rooftop clutter pass (HVAC ducts,
solar panels, satellite dishes). citytest + smoke green (0 failures);
rooftop clutter unit test added and passing (deterministic rects within
usable inset, clear of keep-out, byte-identical across rebuilds).

## Backlog
1. Phase D slice 5 COMPLETE: rooftop variety pass - retail roofs get
   billboards, residential gets laundry lines/pigeon coops (reuse
   _roof_props seeding). [COMPLETE in iter 17]
2. [New] Phase E idea: parkour ledge-grab lip validation — ensure all
   new destructible boxes' ledge-grab geometry satisfies the Phase E
   parkour test suite. Gate: --smoke.
3. Phase F idea: inter-roof prop spacing optimization — prevent
   overlapping destructible boxes at dense roof packing. Gate: --citytest.