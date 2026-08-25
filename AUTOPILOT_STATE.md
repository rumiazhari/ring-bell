# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 7
UPDATED: 2026-08-26 (JST, cron run)

## Current goal
Phase E slice 3 COMPLETE: ledge-grab detection + climb-up. While falling
alongside a wall whose graspable top is within arm reach (0.9-2.1 m above
feet), a downward probe finds the ledge lip and the survivor grabs + climbs.
Extends actors/traversal/parkour_controller.gd (_try_ledge_grab, called from
process_traversal before move_and_slide when airborne). Resetting _peak_y on
grab means the arrested fall does not charge fall damage. Gate ALL GREEN.

## Backlog
1. Phase F: wire ledge-grab into PlayerController HUD cue + a "mantle onto
   rooftop" follow-through when the ledge is a building cornice. Gate: smoke + citytest.
2. Phase B polish: irregular alleys + passages through blocks (intra-block
   cuts). [DONE in iter 2]
3. Phase D: semantic building use -> room layouts (residential/retail first),
   furniture placement by room semantics + wall alignment.
   Gate: citytest + smoke + cityruntime.

## Log
- iter 7 (2026-08-26): Phase E slice 3 LANDED - ledge-grab detection + climb-up.
  New _try_ledge_grab() in parkour_controller.gd: while airborne and descending,
  two lateral chest-height (1.2 m) forward rays confirm a broad wall, then a
  downward probe (0.45 m inset) finds the ledge lip; if the top sits 0.9-2.1 m
  above the feet and the surface normal is up, the survivor pays 4 stamina and
  gets a ballistic climb boost (sqrt(2*g*(rise+0.35)), clamped 4.5-9.5) plus a
  1.35x forward nudge. _peak_y is reset so the arrested fall deals NO fall
  damage. 0.9 s cooldown prevents re-grab jitter. Added 5 deterministic checks
  to debug/smoke_test.gd (suspended PlayerController; isolated 3x2.4 m ledge box
  + tall-wall negative control at +600 m in empty space with a local floor):
  grab fires, survivor mounts the ledge top, no fall damage, tall wall does NOT
  grab, survivor lands on ground. Gate ALL GREEN: --smoke 27 / --citytest 34 /
  --cityruntime 26 / --havoctest 21, all "finished with 0 failure(s)".
- iter 6 (2026-08-26): Phase E slice 2 LANDED - automatic vault/mantle via
  knee/waist/head ray casts. New process_traversal() in parkour_controller.gd
  fires before move_and_slide() in Survivor._physics_process. Three horizontal
  probes at 0.5/1.0/1.6 m from feet, 1.0 m ahead: knee hit + waist clear =
  vault (y+=4.5, xz*=1.3); knee+waist hit + head clear = mantle (y+=6.0,
  xz*=1.2). Gate ALL GREEN: --smoke 22 / --citytest 34 / --cityruntime 26 /
  --havoctest 21 / --walkthrough 16, all "finished with 0 failure(s)".
- iter 5 (2026-08-26): Phase E slice 1 LANDED - jump + fall damage.
  New actors/traversal/parkour_controller.gd (ParkourController node,
  preloaded via const PARKOUR_SCRIPT in survivor.gd - a fresh class_name is
  NOT in the headless global-class cache until an editor rescan, which broke
  the first attempt with "Could not find type ParkourController"; preload is
  deterministic). Survivor owns/wires/ticks it; PlayerController reads new
  `jump` action (SPACE); `attack` rebinding dropped SPACE (mouse-only) so
  space never double-triggers melee+jump. Jump costs 6 stamina, apex ~1.14 m;
  falls beyond 3.5 m safe height deal 9 dmg/m (havoc knockback max rise
  ~2.25 m stays safe). Quarantined a second crashed-run WIP set (broken
  input_setup helpers, undeclared _parkour, dropped needs.load_state) to
  junk/phaseE-wip-crashed-run2/ per no-delete policy. Gate ALL GREEN:
  --smoke 22 / --citytest 34 / --walkthrough 16 / --havoctest 21 /
  --cityruntime 26, all "finished with 0 failure(s)".
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
- iter 3 (2026-08-26): landed the probe-hardening set left uncommitted by an
  interrupted run: havoc_test observer-healer (_process keeps player alive
  through blast/rocket tests, no more freed-reference script errors),
  walkthrough_probe wall-follow fallback when boxed in + exit route re-derived
  as exact reverse of entry (valid for any door edge) + climb radius 0.9 ->
  1.1 + GEO debug line. Verified fresh on this tree: walkthrough 16/16, havoc
  21, citytest 34, smoke 22 - all "finished with 0 failure(s)". override.cfg
  (local Godot seed pin) gitignored.
- iter 2 (2026-08-26): added intra-block pedestrian passages (alleys). Gate:
  --citytest + --smoke green. 183 blocks pierced across two seeds; alley floor
  rendered as distinct cobble strip. Backlog #2 complete.
- iter 1 (2026-08-26): FIXED walkthrough failures (backlog #1 from iter 0).
  Root cause: full-length inner handrails on stair switchbacks clipped bodies
  rounding the opposite lane (lane gap ~1.1 m < capsule width). Change in
  world/generation/building_builder.gd `_staircase`: handrails now only on
  the OUTER edge of each lane, still stopping RAIL_SETBACK short of flight
  ends. Gate: --walkthrough 16/16 PASS (first time green), --citytest 34
  PASS, --smoke 22 PASS.
- iter 0 (2026-08-26): landed pending foundation fix set (13 files, ~1.8k
  lines). Landing gate: citytest, smoke, cityruntime, havoctest ALL green.
  Harness installed at tools/run_suite.py (logs tools/out_<flag>.txt).
