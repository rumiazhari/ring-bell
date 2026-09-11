# Q1 — buildings / interior / camera: entrance + stair unblock (continuation doc)

Status (2026-09-12): **recon in progress. Nothing implemented for Q1 yet.**
Base: `copilot/worldgen-fix` HEAD. Locked user decisions live in
`2026-09-12-buildings-interior-camera-continuation.md` (door-width table, HARD-CUT
camera-side-only cutaway, `floor_i == n` = ROOF/EXTERIOR). They are binding here and are
not repeated in full.

## Why Q1 is first

Two measured defects block verification of Q2 (parkour) and Q3 (interiors): the automated
walker cannot get past the ground floor of a building, and doors do not physically open.
Every route test for parkour and every interior traversal test is downstream of these two.

## Measured evidence (real runs, not inference)

`python tools/run_suite.py --walkthrough 240 --rendered` (≈85 s, windowed, log
`tools/out_walkthrough.txt`):

```
PASS  approached closed entrance        PASS  closed door blocks passage
PASS  door reports OPEN                 PASS  camera tracks the vertical climb
FAIL  walked door -> stairwell without teleport   (at (162.5698, 3.956354, 87.91067))
FAIL  climbed all 5 storeys to deck     (y=3.96 want 15.50)
FAIL  descended to ground floor         (final y=3.96)
FAIL  walked out of the building        ((162.4641, 3.956354, 87.83964))
STALL waypoint 1/19 pos=(164.0717, 3.956354, 88.9781) tgt=(163.1993, 15.5, 93.24276)
DIAG  pos=(164.0717, 3.956354, 88.9781) target=(172.162, 19.47541, 81.59757)
      floor=true floor_normal=(0.0, 1.0, 0.0) vel=(0.967192, 0.0, 0.967192)
      rays 0.2/0.5/0.9 + capsule ALL hit StaticBody3D#983883090391
      normal=(-0.558109, 0.0, 0.829767) owner=@CollisionShape3D@31417@(163.462, 4.500412, 87.97939)
```

Two facts from those numbers matter:
- The blocking surface has a **horizontal** normal (`y = 0.0`) that is **diagonal in XZ**
  (`(-0.558, 0, 0.829)`) ⇒ an angled wall/rail, not a slab, not a stair ramp (a ramp would
  have a non-zero Y component). The capsule hits it at three heights and with its own
  cast ⇒ a solid vertical face across the path.
- The walker is stalled on **storey 1** (`y = 3.96`, `fh ≈ 3.1`) with the next route
  waypoint on the **roof deck** (`y = 15.5`, 5 storeys) ⇒ it climbed one storey, then the
  route to the stairwell/upper flight is blocked.

`python tools/run_suite.py --cityruntime 300 --rendered` (log `tools/out_cityruntime.txt`):

```
PASS  door entities exist              PASS  closed leaf blocks doorway ray
PASS  door closes via API              PASS  stair probe reaches upper floor
PASS  camera rig found                 PASS  interior presentation <= 9 m
PASS  faded_facades sector matches live view direction
FAIL  door opens via API
FAIL  open leaf reaches swing angle range     (leaf=2.6deg target=95.0deg)
FAIL  open doorway physically passable (no RID exclusion)
FAIL  open leaf still collidable at swung position   (<null>)
```

`--buildingcontracttest`: **116/373**, 302 failures (baseline, unchanged by the perf work).
Residual bands: `entrance width 2.60 outside human scale` (~130, **in scope** per the user),
`grounding violated: ground_y 0.00 vs surface N` (~80), unregistered `:court` structural
geometry (migration), and the validator's own check named
`solid geometry behind rural door rejected` (PASSes ⇒ the validator can already detect that
case in rural houses).

## Proven so far (with file:line)

- **Door swing is "complete" at 2.6°.** `world/buildings/door.gd:244-255` `_target_angle()`
  returns `signf(n_lz * side) * deg_to_rad(manifest.get("open_angle", 95.0))` ⇒ ±1.658 rad
  for the default 95°. The leaf reached exactly 2.6° = 0.045 rad, i.e. it did **not** stop
  short of its target — the swing is physically jammed.
- **ANSWERED (A): there is no hinge motor.** Grepping `world/buildings/door.gd` shows no
  `FLAG_USE_MOTOR` and no `PARAM_MOTOR_*`, despite the stale doc comment at `:13` claiming
  "open()/close() drive the hinge MOTOR". The drive is direct velocity control:
  `door.gd:299-300` sets `_leaf.angular_velocity = Vector3(0, clampf(err * 30.0 * _sign_flip,
  -24.0, 24.0), 0)`, and the hinge only limits (`:120-124`). `_drive_to()` (`:167-177`) clears
  `_leaf.freeze`; `DRIVE_TICKS_LIMIT := 90` (~1.5 s) bounds the attempt.
  ⇒ A leaf that stops at 2.6° is **blocked by contact**, which then triggers the stall path
  (`:283-296`: reverse once, then give up) and `_force_settle()` (`:310-312`) freezes it
  half-open. That simultaneously explains all three door FAILs: `door opens via API`,
  `open leaf reaches swing angle range (leaf=2.6deg target=95.0deg)` and
  `open doorway physically passable`. **So the door defect is a CLEARANCE defect in
  generation, not a physics-wiring defect — do not go looking for motor params.**
- **The swing-clearance rule exists but is only applied to props.** `world/streaming/chunk_builder.gd:1300`
  says "Colliding props must never spawn inside a door's swing arc" and `:1456` provides
  `True when p sits inside any door's swing clearance`; the contract validator checks
  apertures (`world/generation/building_contract_validator.gd:310-357`, "solid geometry behind
  door/window") and `debug/prague_props_test.gd:241,387` audits furniture-vs-swing. **No
  equivalent rule is applied to structural facade geometry** (pilasters, plinths, cornices,
  jambs, the wall return beside the doorway) — that is the leading systemic hypothesis for
  the jam. Note the validator's aperture check currently does NOT flag city doors (the city
  failure bands are entrance width + grounding), which suggests it tests a narrow cell behind
  the door rather than the full swing arc.
- **Partitions do NOT cut through the stairwell.** Hypothesis falsified by reading
  `world/generation/building_builder.gd:3680-3705` `interior_partition_visible()`: it returns
  false when a partition rect intersects the stair zone (`:3689`), any entry aisle (`:3691-3693`)
  or the ground-floor entry box (`:3694-3704`). The `aisles` / `corridor` locals computed at
  `:3468-3502` inside `_emit_interior_partitions()` are **vestigial** (the filter recomputes
  them from `spec`). Do not re-chase "partition blocks the stairs" without new evidence;
  instead check dimension/space agreement (below).
- **Stairs are a deliberate, documented system** (`building_builder.gd:5-13, 29-47, 256-302`):
  `LANE_W 1.25`, `LAND 1.25`, `STAIR_MARGIN_X 0.5`, switchback ramp + landings + guard rails,
  storey slabs cut by `_slab_with_hole(...)` (`:366-374`), gated by `has_stairs_for(fp, fh, n)`
  (`:264`). Entry-side → opposite-stair-zone mapping is documented at `:269-288` and echoed by
  `stair_zone_world(spec)` (`:292`).
- **The walker is not naive**: `debug/walkthrough_probe.gd` (683 lines) has wall-following
  (`:468`), a clear-direction filter that rejects WALL/RAIL (`:515-523`), radius-aware arrival
  tolerances (`:413-421`), and its own comment at `:488` says an unreached waypoint means
  **"the generator must be repaired"**. Its stair route is derived from the *same* constants
  via `_stair_path(zone, fh, n)` (`:359-392`), consuming `BuildingBuilder.stair_zone_world()`.
  So a stall is a legitimate generation finding, not just a probe limitation.
- **Two stair probes disagree**: `city_runtime_test.gd:252` `_stair_probe_reaches_floor` PASSes
  while the walkthrough stalls on a different building chosen by `_pick_building`
  (`walkthrough_probe.gd:259-278`, which requires `has_stairs_for(...)`). ⇒ likely a
  **per-building / per-door-edge** geometry case, not a global stair failure. Test across
  many buildings and all four `door_edge` values before concluding.

## Open questions (next model: answer these, in this order)

A. **Is the hinge motor ever enabled?** (`FLAG_USE_MOTOR`, `PARAM_MOTOR_*` in
   `world/buildings/door.gd`.) Cheapest decisive check; explains the 2.6° stop.
B. **Does the swing have room?** Take the failing door's manifest and test for solid geometry
   inside the leaf's sweep. The contract validator already has a case for exactly this
   (`solid geometry behind rural door`), so reuse its predicate rather than writing a new one.
C. **Why is every city entrance 2.60 m?** Find the derivation (likely a single constant or a
   `DOOR_W` default) and replace it with the locked kind-based table:
   residential/historic single 1.0-1.1 (default 1.05), service/interior 0.9-1.0,
   retail 1.1-1.3, intentional double/grand/industrial 1.6-1.8 — with aperture, leaf, frame,
   collision and capsule clearance all from the one contract.
D. **Does the walker's stair path agree with the emitted stairwell?** Compare
   `_zone_rect(fp.size, fh, door_edge)` (used for the slab hole and the partition filter),
   `stair_zone_world(spec)` (used by the probe) and the geometry actually emitted, in the
   same coordinate space, for the building `_pick_building` selects. The DIAG collider
   `(163.462, 4.500412, 87.97939)` with normal `(-0.558, 0, 0.829)` is the place to look —
   dump every collider within ~2 m of it together with its owning node name and layer tags.
E. **Is the 2.6° / stall case ruin-tier or decay dependent?** ~40 % of buildings are RUINED
   and ruin adds boarded windows/rubble (`building_builder.gd:380-395`). If the failing
   building is ruined, rubble may be the obstruction — check before changing stair geometry.

## Test commands and baselines (do not regress these)

```
cd "C:/Vibe Code project/Godot Project/ring-bell"
python tools/run_suite.py --cityruntime 300 --rendered     # tools/out_cityruntime.txt
python tools/run_suite.py --walkthrough 240 --rendered     # tools/out_walkthrough.txt
python tools/run_suite.py --buildingcontracttest 420       # 116/373, 302 failures
python tools/run_suite.py --sitecontracttest 420           # 43/44
python tools/run_suite.py --perftest 400 --rendered        # tools/out_perftest.txt
```
`argv[2]` (timeout seconds) is **required**; a missing arg raises
`ValueError: invalid literal for int()`. `--cityruntime`/`--walkthrough`/`--perftest` are
windowed (`--rendered`); `--buildingcontracttest`/`--sitecontracttest` are headless.
Performance baseline: **79 FPS / 12.7 ms** frame on the streamed city (was 5 FPS before
`101c85c`). Failure-signature baseline for regression A/B: the 10 `FAIL` lines of
cityruntime+walkthrough, previously diffed to an **empty symmetric difference** against
pre-perf `609fd50`.

## Regression protocol used for the perf work — reuse it

Reverting only the changed files to a known commit, running the tests, then restoring with
`git restore --source=HEAD` (plus a `git status --porcelain` proof) let the failure sets be
compared line-by-line instead of argued about. Do the same for any Q1 change: the claim to
defend is **"identical FAIL set"**, not "looks fine".

## Files to inspect for Q1 (user-mandated list, with what was already read)

Read so far: `world/buildings/door.gd` (hinge wiring :104-135, `_target_angle` :244-255,
`_physics_process` :258-300), `world/generation/building_builder.gd` (:360-400 slabs+hole,
:3464-3545 partition emitter, :3680-3705 partition filter, :3450-3460 entry aisles),
`debug/walkthrough_probe.gd` (:359-392 stair path, :407-500 follower/STALL),
`debug/city_runtime_test.gd` (:142-201 door checks, :251-252 stair probe).
Still to read: `world/generation/interior_plan.gd`, `historic_interior_plan.gd`,
`building_archetype.gd` (archetype rules), `building_spec.gd`, `city_plan.gd`,
`roof_plan.gd`, `world/streaming/chunk_builder.gd`, `world/interior_probe.gd`,
`world/main.gd` (interior/cutaway driver), `world/streaming/mesh_batcher.gd` (`reveal_*`),
`camera/follow_camera.gd`.

## Constraint reminders carried forward

- Fix **systemic** generation rules, never one showcase building.
- Do not globally disable collision to make a door passable.
- Cutaway: HARD CUT, camera-side obstructing pieces only; hidden visuals keep collision and
  shadows; never `visible = false` for structure (it also drops it from the shadow pass).
- Preserve performance (79 FPS baseline), destruction, streaming and parkour compatibility.
- Commit and push each completed task; report the commit hash and genuine remaining limits.
- File deletions: never delete — move to `junk/` inside the project.


## INSTRUMENTED FINDING (2026-09-12) -- the stall is NOT the door

Probe: `debug/walkthrough_probe.gd` now calls `_dump_stair_blockers()` on a failed
climb (chest-height ray fan + shape owners) and its own `_route_diagnostics()` fires
on every stall. Run: `python tools/run_suite.py --walkthrough 240 --rendered`.
Engine output lands in `tools/out_walkthrough.txt` (NOT only the suite stdout).

Building under test: `historic_block_48_plot_9_1_front`
- local rect  x 162.0743..169.7350, z 77.73881..94.36776   (S 7.6607 x 16.6290)
- door edge 0 == the min-z facade; local door mid (165.9046, 77.73882)
- stair zone  local x 162.5743..165.0743, z 86.77182..93.86780  (2.5 x 7.0959)
- lane_w 163.20, lane_e 164.45, z_n 86.77, z_s 93.87, floor_h 3.10, floors 5
- world ground (pad) y == 3.975412  (derived, matches route frame exactly)

Both stalls, same place:
- `STALL waypoint 1/5  pos=(162.4641, 3.956354, 87.83964)`
- `STALL waypoint 1/19 pos=(164.0716, 3.956354, 88.97807)`

Player local y = -0.0191 => the capsule is standing on the GROUND FLOOR pad, not on a
stair and not on an upper slab. Earlier "it climbed flight A" readings were wrong: the
world y 3.956 is the pad height, not storey 1.

The blocker (identical in every ray direction and in the capsule query):
- collider is a **StaticBody3D**, i.e. NOT the door leaf (the leaf is a frozen
  RigidBody3D) -- so the open door is not what blocks the route.
- two boxes, world (163.462, 4.500412, 87.97939) and (165.0715, 4.500412, 90.08119):
  ~2.65 m apart, shape centres **0.54 m above the pad** (a ~1.08 m tall pair),
  face normals 124.05 deg and 34.05 deg, i.e. PERPENDICULAR to each other.
- `capsule=` returns THREE shape overlaps of that same body => the walker's capsule is
  **physically embedded inside static geometry**, so `move_and_slide()` cannot resolve
  the motion: it is wedged, not merely obstructed.

Conclusion: the entrance->stairwell circulation path on the ground floor is blocked by
static geometry roughly 0.2 m from the walker, spanning about the stair zone's width.
The 5- and 19-waypoint routes both die at their first inside-step, so this is a
circulation-blocking defect, not a stair-climbing defect.

Next decisive step: make the emitters self-identifying (tag emitted static collision
with its source rule) so the log names the exact emitter instead of a bare
`CollisionShape3D`, then fix that rule systemically. Do NOT re-chase "partition through
the stairwell" -- `interior_partition_visible` (building_builder.gd:3680-3705) already
filters the stair zone, entry aisles and entry box.

## ROOT CAUSE (2026-09-12, measured) -- an f0 half-wall run blocks door -> stair

Instrumentation now names the emitter instead of inferring it: MeshBatcher records the
active layer key on every emitted collider (`src_layer` meta, mesh_batcher.gd ~430/~951)
and the walkthrough probe prints it plus the BoxShape3D size.

Blocking geometry on `historic_block_48_plot_9_1_front` (fp 7.6607 x 16.629, door_edge 0,
fh 3.10, n 5; stair zone local x 162.574..165.074, z 86.772..93.868):
  A: box (5.017, 1.05, 0.18), centre local (165.13, 83.00) -- runs along local x
  B: box (0.18, 1.05, 1.69),  centre local (162.61, 82.14) -- return along local z
  both `src_layer = historic_block_48_plot_9_1_front:f0`, height exactly 1.05 m.

A half-height run 5.02 m long with an L-return at the west wall bisects the ground floor
at local z 83.0: 5.26 m inside the entrance (door mid local z 77.739) and 3.77 m short of
the stair zone. The entrance opens into the north half, the stairwell sits in the south
half, and a 1.72 m capsule can never cross a 1.05 m wall -- the walker wedges with its
capsule reporting 3 shape overlaps of that same StaticBody3D.

Not a partition: `interior_partition_visible` (building_builder.gd:3696) has exactly ONE
consumer (:3528), and adding the entry-axis keep-out below moved the stall from waypoint
1/5 to 4/5 without moving this geometry at all. Dimensions implicate the plan-driven
fixture path: 0.18 == WorldConstants.CITY_INTERIOR_WALL_T == interior_plan.gd:30
WALL_T_INTERIOR, and 1.05 is the wall-run/shelf member height (building_builder.gd:2388+,
:2780). `_emit_room_furniture` (:3743, called from :3591) stretches wall-hugging items
along the wall and does NOT consult the entrance/stair keep-out that the legacy scatter
path applies at :2478.

FIX LANDED (provisional): `_entry_aisles` (:3450) now also reserves the door's own inward
axis (capsule width + clearance) plus a lateral leg to the landing centre, not just the
old dog-leg. Measured effect: route reaches waypoints 1/5..3/5 where it previously died at
1/5. The 4/5 stall is the fixture above and is still open.

NEXT: apply the same keep-out to plan-driven furniture/boards in
`_emit_interior_partitions` / `_emit_room_furniture`, then fix the door control law
(never latches OPEN; stall/reverse at -90.1 deg with hit=none).
