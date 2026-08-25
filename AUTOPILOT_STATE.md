# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 1
UPDATED: 2026-08-26 (JST, cron run)

## Current goal
(none — work the backlog top-down; choose freely within freedom scope)

## Backlog
1. Phase B polish: irregular alleys + passages through blocks (intra-block
   cuts). Gate: citytest + smoke + cityruntime.
2. Phase E: split parkour into actors/traversal/parkour_controller.gd +
   geometry-query detector (probes, no trigger volumes); sprint/jump/vault/
   mantle/ledge grab/climb/fall damage on generated buildings.
   Gate: citytest + smoke + cityruntime + havoctest.
3. Phase D: semantic building use -> room layouts (residential/retail first),
   furniture placement by room semantics + wall alignment.
   Gate: citytest + smoke + cityruntime.

## Log
- iter 1 (2026-08-26): FIXED walkthrough failures (backlog #1 from iter 0).
  Root cause: full-length inner handrails on stair switchbacks clipped bodies
  rounding the opposite lane (lane gap ~1.1 m < capsule width). Change in
  world/generation/building_builder.gd `_staircase`: handrails now only on
  the OUTER edge of each lane (inner sides face adjacent solid landings, no
  rail needed), still stopping RAIL_SETBACK short of flight ends.
  Gate: --walkthrough 16/16 PASS (0 failures, first time green),
  --citytest 34 PASS (0 failures; cosmetic exit 3221225477 as documented),
  --smoke 22 PASS (exit 0).
- iter 0 (2026-08-26): landed pending foundation fix set (13 files,
  ~1.8k lines: building-generation fixes, door/debris/camera work, streaming
  hardening, expanded test probes world_test/city_runtime_test/havoc_test/
  walkthrough_probe). Landing gate: citytest, smoke, cityruntime, havoctest
  ALL green ("finished with 0 failure(s)" each). Harness installed at
  tools/run_suite.py (logs tools/out_<flag>.txt, gitignored).
