# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 3
UPDATED: 2026-08-26 (JST, cron run)

## Current goal
Backlog #2 (Phase E): split parkour into actors/traversal/parkour_controller.gd
+ geometry-query detector (probes, no trigger volumes). Gate: citytest + smoke
+ cityruntime + havoctest.

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
- iter 2 (2026-08-26): added intra-block pedestrian passages (alleys). Gate:
  --citytest + --smoke green. 183 blocks pierced across two seeds; alley floor
  rendered as distinct cobble strip. Backlog #1 complete.
- iter 3 (2026-08-26): landed the probe-hardening set left uncommitted by an
  interrupted run: havoc_test observer-healer (_process keeps player alive
  through blast/rocket tests, no more freed-reference script errors),
  walkthrough_probe wall-follow fallback when boxed in + exit route re-derived
  as exact reverse of entry (valid for any door edge) + climb radius 0.9 -> 1.1
  + GEO debug line. Verified fresh on this tree: walkthrough 16/16, havoc 21,
  citytest 34, smoke 22 - all "finished with 0 failure(s)". override.cfg
  (local Godot seed pin) gitignored.
- iter 4 (2026-08-26): QUARANTINED the interrupted Phase-E parkour WIP.
  The half-finished edit left player_controller.gd with TWO setup()
  overloads (GDScript has none -> global parse error that blocked EVERY
  suite: "Could not parse global class PlayerController"), plus
  parkour_controller.gd typed _survivor as Node3D while dereferencing
  .velocity/.facing/.health, a call to nonexistent is_on_ground(), jump
  input duplicated between controller and ParkourController.tick(), and
  input_setup.gd having removed camera_rotate_left/right actions still
  referenced by follow_camera.gd. Moved WIP intact to junk/phaseE-parkour-wip/
  (per no-delete policy); reverted player_controller.gd, input_setup.gd,
  main.gd to HEAD. Tree is green again - suites re-verified after revert.
  PHASE E RESTART NOTES: single setup(survivor, hud); ParkourController must
  hold a typed Survivor reference (not Node3D) or use has_method/get(); one
  owner for jump input (either controller or tick(), not both); keep
  camera_rotate_* actions in InputMap; add jump action WITHOUT removing
  existing ones. Gate unchanged: citytest+smoke+cityruntime+havoctest.