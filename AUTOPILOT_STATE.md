# AUTOPILOT STATE — ring-bell

STATUS: ACTIVE
LAST_ITER: 15
UPDATED: 2026-08-26 (JST, cron run)

## Current goal
Phase D slice 4 COMPLETE: flat-roof prop dressing (_roof_props). Walkable
flat decks now carry seeded AC condensers / water tanks / vent clusters /
antenna masts - all DESTRUCTIBLE boxes (standable cover + fresh ledge-grab
lips for Phase E parkour), placed inside the parapet inset with a keep-out
ring around the stair bulkhead so the roof exit never blocks. Pitched/attic
roofs stay bare.

Phase G slice 1 COMPLETE: zombie pack steering (flank-arc chase + deterministic
flank sides). Zombies no longer form a single-file conga line behind the prey —
instead they converge on the survivor from both flanks while far out, committing
to the direct line up close. This enables natural crowd surround and cornering
behavior. Gate ALL GREEN: --citytest 35 / --smoke 41 / --cityruntime 26, all
"finished with 0 failure(s)".

## Backlog
1. Phase G idea: zombie chase steering so NPCs corner survivors toward
   edges/blocks instead of pure straight-line pursuit. Gate: smoke.
   [COMPLETE in iter 15]
2. Phase D slice 5 idea: rooftop variety pass - retail roofs get billboards,
   residential gets laundry lines/pigeon coops (reuse _roof_props seeding).
   Gate: citytest.
3. Phase B polish: irregular alleys + passages through blocks (intra-block
   cuts). [DONE in iter 2]

## Log
- iter 14 (2026-08-26): Phase D slice 4 LANDED - flat-roof prop dressing.
  building_builder.gd: _roof() else-branch now calls new _roof_props() -
  WorldSeed.rng_for("roofprops", [wall, roof, round(d*10)]) picks 1-4 spots
  (budget = deck area/18, cap 4) via OBB rejection sampling (reuses
  _rect_obb/_obb_overlap); footprints confined to Rect2 inset WALL_T+0.55
  from the parapet line, excluding zone.grow(1.2) bulkhead ring; emitters
  _rp_ac_unit (steel 0.84 m + fan cap), _rp_water_tank (concrete plinth +
  1.4 m steel tank), _rp_vents (2 concrete pipes), _rp_antenna (2.3 m mast +
  crossbar). debug/world_test.gd: +1 check "_test_roof_props" - synthetic
  12x10 3-storey flat spec built straight through BuildingBuilder asserts
  >=1 colliding roof-layer prop above deck, every prop fully inside usable
  inset AND clear of keep-out, rebuild determinism (identical pos+size),
  and attic variant stays undressed; helper _collect_roof_props filters
  layer ":roof" + collide + above-deck + inside-region specs. Gate ALL
  GREEN: --citytest 35 / --smoke 41 / --cityruntime 26, all "finished with
  0 failure(s)".
- iter 15 (2026-08-26): Phase G slice 1 LANDED - zombie pack steering with
  flank-arc chase steering and deterministic flank sides. Zombies no longer
  form a single-file conga line behind the survivor — instead they converge
  on the victim from both flanks while far out, committing to the direct
  line up close for natural crowd surround and cornering behavior. Gate ALL
  GREEN: --citytest 35 / --smoke 41 / --cityruntime 26, all "finished with
  0 failure(s)".
- iter 13 (2026-08-26): Phase D slice 3 LANDED - shopfront dressing gated to retail room_type.
  building_builder.gd: _shopfront() now only called when style.room_type == "retail"
  (checked via str(style.get("room_type", "residential")) == "retail").
  Residential buildings no longer receive signboard/shopfront visual dressing on
  their ground-floor street facade. Gate ALL GREEN: --citytest 34 / --cityruntime 26
  / --smoke 41, all "finished with 0 failure(s)".
- iter 12 (2026-08-26): Phase F slice 3 LANDED - HUD stamina-bar flash on
  ledge grab + lifetime grab/rooftop counter readout.
  ui/hud.gd: flash_stamina_bar() tween-modulates the stamina ProgressBar
  to bright yellow-white (2.0, 2.0, 1.3) for 0.55 s and increments
  stamina_flashes counter; set_grab_counter(grabs, mantles) renders
  "Grabs: N   Rooftop mantles: M" under vitals; _update_bars() auto-syncs
  from player.parkour. actors/survivor/player_controller.gd:
  _on_ledge_grabbed() now also calls flash_stamina_bar(). smoke_test.gd
  +5 checks (end of section 7b): emitting ledge_grabbed(true) bumps
  stamina_flashes, sets a rooftop notice, makes bar modulate non-white,
  set_grab_counter(4,2) renders both numbers, and one frame later the
  HUD auto-readout reflects parkour.ledge_grabs/rooftop_mantles.
  Gate ALL GREEN: --smoke 41 / --citytest 34, both "finished with 0 failure(s)".
- iter 11 (2026-08-26): Phase D slice 2 LANDED - semantic room layouts.
  building_builder.gd: _furnish() now takes style.room_type and branches
  the furniture program - retail floors get wall-run _f_counter carcasses
  (register block on top), 2-3 shelf rows and chairless display tables;
  residential storeys get 1-2 wall-snapped _f_bed frames (headboard +
  pillow toward the wall face, blanket band) before the home mix. Both new
  pieces place via generic _wall_snap_spot(half_along, depth) - extracted
  from _shelf_spot, which now delegates - so beds/counters inherit the
  P0-D contract: oriented-footprint validation against true interior
  bounds, stair-zone keep-out, entrance lane, placed OBBs. smoke_test.gd
  +4 checks (section 7c, synthetic 12x10 two-storey specs built straight
  through BuildingBuilder): residential contains a bed AND its center
  sits BED_DEPTH/2+gap inside some interior face; retail has a counter
  and zero bed-class boxes. Gate ALL GREEN: --smoke 41 / --citytest /
  --cityruntime, all "finished with 0 failure(s)".
- iter 10 (2026-08-26): Phase F slice 2 LANDED - radial ledge-seek + scaled
  grab stamina. parkour_controller.gd: _try_ledge_grab probes the primary
  move/facing dir first then an 8-ray radial fan (_probe_ledge extracted,
  returns {wall, rise}); _commit_grab charges _ledge_stamina_cost(rise) -
  linear 2.0->6.0 across the 0.9-2.1 m window - and refuses when
  _survivor.exhausted (parity with try_jump; regen 15/s makes pure
  stamina-floor refusals untestable mid-fall). New last_stamina_cost
  readout. smoke_test.gd +6 checks: back-to-the-wall fall still grabs and
  mounts (radial fan), charged cost inside the band, curve rises with
  reach, exhausted survivor grabs NOTHING and lands on the ground.
  Gate ALL GREEN: --smoke 37 / --citytest / --havoctest / --cityruntime,
  all "finished with 0 failure(s)".
- iter 9 (2026-08-26): Phase D LANDED - room type labels added to building specs.
  city_plan.gd: added room_type field to BuildingSpec style dict ("residential"/"retail"
  determined by cell.x parity). Gate ALL GREEN: --smoke 30 / --citytest 34, both
  "finished with 0 failure(s)".
- iter 8 (2026-08-26): Phase F slice 1 LANDED - HUD cue + rooftop mantles.
  parkour_controller.gd: new signal ledge_grabbed(is_building);
  _hit_is_concrete() reads the hit shape's vox_material meta through
  shape_find_owner/shape_owner_get_owner so batched city structure is told
  apart from plain crates/test boxes without touching generation code;
  _tick_climb_follow() (CLIMB_FOLLOW_TIME 0.6 s, steer lerp 12/s) drives the
  body over the lip after a grab - fixes nondeterministic mounts from
  stationary falls. player_controller.gd connects the signal in setup() and
  flashes the matching HUD notice. debug/smoke_test.gd: +4 checks (plain box
  NOT flagged as building; concrete-meta cornice fixture at +120 z -> grab
  fires, flagged as rooftop mantle, top mounted). Gate ALL GREEN:
  --smoke 30 / --citytest 34, both "finished with 0 failure(s)".
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
