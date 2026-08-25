# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 0
UPDATED: 2026-08-26 (JST, cron run)

## Current goal
(none — work the backlog top-down; choose freely within freedom scope)

## Backlog
1. Fix the --walkthrough suite failures (known-failing since foundation pass).
   Probe: debug/walkthrough_probe.gd — run
   `python tools/run_suite.py --walkthrough 400`; gate for this item is that
   suite green (+ citytest/smoke stay green).
2. Phase B polish: irregular alleys + passages through blocks (intra-block
   cuts). Gate: citytest + smoke + cityruntime.
3. Phase E: split parkour into actors/traversal/parkour_controller.gd +
   geometry-query detector (probes, no trigger volumes); sprint/jump/vault/
   mantle/ledge grab/climb/fall damage on generated buildings.
   Gate: citytest + smoke + cityruntime + havoctest.
4. Phase D: semantic building use -> room layouts (residential/retail first),
   furniture placement by room semantics + wall alignment.
   Gate: citytest + smoke + cityruntime.

## Log
- iter 0 (2026-08-26): landed pending foundation fix set (13 files,
  ~1.8k lines: building-generation fixes, door/debris/camera work, streaming
  hardening, expanded test probes world_test/city_runtime_test/havoc_test/
  walkthrough_probe). Landing gate: citytest, smoke, cityruntime, havoctest
  ALL green ("finished with 0 failure(s)" each). Harness installed at
  tools/run_suite.py (logs tools/out_<flag>.txt, gitignored).
  Known-failing: --walkthrough (3 failures) = backlog #1.
