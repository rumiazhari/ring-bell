# SPEC-C001 — Skeleton-Driven In-Place Core Locomotion

Status: ARCHITECT-READY FOR CONTROLLER AUTHORIZATION
Milestone ID: `P-C1-LOCOMOTION-CORE`
Owner: `character-architect` (architecture/design/review); `character-builder` (implementation/QA)
State revision: 0
Controller: `ring-bell-character-autopilot`
Cycle: 1

## Player-facing objective

On the Hungarian plain (streamed CITY default at spawn) the ordinary survivor
moves with a skeleton you see driving every step you feel — no slide-teleport.
Capsule owns physics (`CharacterBody3D.move_and_slide`), skeleton owns pose
(`Skeleton3D` + `AnimationTree` StateMachine, `in-place` clips only).
From Idle the character blends Walk / Run / Sprint by xz speed `0 → 5.5 m/s`,
strafes left/right while facing forward, turns in place `90°/180°` when
stationary yaw exceeds threshold, and adapts to slope `0–22°` without floating
or foot skate. `F3` shows `state + blend + speed + slope + foot_slide` and
animation cost. The same core drives zombies (shamble variant) but the player
is the proof.

This is the next bounded milestone because every later joy depends on it:
parkour vault/mantle/ledge (Arc 2) must trigger from honest capsule query while
locomotion pose reads; interaction door push/pull (Arc 3) needs capsule+pose
sync; combat shove/aim (Arc 4) needs upper-body layering. Without readable
locomotion, vertical civilization, survival, and exploration have no tactile
foundation. This slice unlocks all of them while staying ACTIVE-only budgeted.

This slice is deliberately thin: no combat, no interaction, no traversal
parkour beyond the existing `parkour_controller.gd` (which stays untouched), no
biome/terrain/hydrology edits, no world generation changes.

## Current baseline and constraints

Inspected canonical checkout `C:/Vibe Code project/Godot Project/ring-bell`
at Git head `023070d` (P3.1 biome streaming, `GENERATOR_VERSION` 2). Worktree
`wt/t_1b367205` shares state; character board `STATE.json` is `cycle 1`,
`phase architecting`, `deferred_findings []`.

Existing evidence:
- `actors/survivor/survivor.gd`: `CharacterBody3D`, capsule `r 0.35 h 1.7`,
  `floor_max_angle 46°`, `floor_snap_length 0.3`, `WALK 3.6 RUN 6.4 ACCEL 12`,
  gravity `18`, `move_and_slide()` in `_physics_process`, facing via
  `Visual.rotation.y`, `parkour.process_traversal()` before slide,
  `_animator.set_motion(speed, airborne)` after slide.
- `actors/humanoid_animator.gd`: procedural pivot swings, `WALK_FREQ 6.2`
  `RUN_FREQ 11`, no Skeleton3D, no AnimationTree, no strafe/turn_in_place,
  no slope handling, no `in-place` guarantee verified. Headless suites pass
  (`--cityruntime` green at head) but foot slide not measured, no F3 blend.
- `actors/humanoid_model.gd`: `HumanoidModel.build_human()` returns Node3D
  with pivot dictionary `anim_limbs` (upper/l_arm/r_arm/l_leg/r_leg) and
  `BoxMesh/CapsuleMesh` primitives, scale `1.2`, skirt cloth for female.
  No `Skeleton3D`, no `BoneAttachment3D`, no skinned mesh.
- `actors/zombie/zombie.gd`: same `HumanoidAnimator` with `shamble true`,
  capsule `0.35/1.7`, wander/chase states.
- `world/generation/world_constants.gd`: `BUILDABLE_MAX_SLOPE_DEG 22`,
  `CLIFF_SLOPE_DEG 35`, `CHUNK_SIZE_M 64`, `FRAME_BUDGET_MS 12`.
  Character may READ `LAND/LANE_W/flight_run/ramp_height_at` and
  `WorldSeed.GENERATOR_VERSION` and `ChunkManager` ACTIVE counts only.
- `world/streaming/chunk_manager.gd`: ACTIVE ring `<=1` (3x3=9), WARM `<=2`,
  `debug_lines()` exposes `active`/`warm`; character streaming budgets must
  respect ACTIVE-only physics.
- Isolation fence (GRAND_PLAN § Isolation): may edit `actors/survivor/*`,
  `actors/zombie/*`, `components/animation/*`, `art/character/*`,
  `art/animations/*`, `docs/character/*`, `debug/animation_test.gd`;
  read-only `world/generation/world_constants.gd`,
  `world/streaming/chunk_manager.gd`, `WorldSeed.GENERATOR_VERSION`;
  never write `world/generation/*`, `world/streaming/*`,
  `AUTOPILOT_STATE.json` (geography), `WORLD-CONTRACT.md` terrain/hydro/biome.

Headless baselines (`python tools/run_suite.py --<flag>` judged by
`finished with 0 failure(s)`):
- `--citytest`, `--terrainmaterialtest`, `--hydrotest`, `--biometest`,
  `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each green at
  `023070d` per out logs. Save deltas exclude generated geometry.

## Gameplay value

Improves at least four pillars in one thin slice while preserving budgets:

- **Tactile game feel** — capsule-driven `in-place` eliminates slide-teleport;
  StateMachine blend reads at every speed; F3 state+blend+slope makes motion
  legible.
- **Agency and meaningful choice** — strafe and turn_in_place let the player
  adjust facing without committing to translation (peeking corridors, aligning
  door approaches); slope 0–22° keeps hill routes readable vs cliff.
- **Exploration and discovery** — Hungarian plain becomes a honest test field:
  player can measure foot slide on flat, hill, and ramp landing seam, choose
  to traverse slope vs detour.
- **Performance and stability foundation** — Skeleton3D + AnimationTree introduced
  with ACTIVE-only budgets: `active characters ≤12` in `3×3`, `skinned meshes
  ≤9` warm, `animation ms ≤2 ms`; no world generation cost, save deltas remain
  seed/version/discovery only.

## Scope

### 1. Skeleton + AnimationTree foundation (in-place, ACTIVE-only)

Create/extend under `components/animation/` and `art/`:

- `components/animation/skeleton_factory.gd` — `class_name SkeletonFactory`,
  `static func build_survivor_skeleton() -> Skeleton3D` creates a `Skeleton3D`
  with 9 bones: `root/hips/spine_upper/head/l_thigh/l_shin/r_thigh/r_shin/
  l_upper_arm/r_upper_arm` (hip at `y 0.86`, upper at `0.95` matching current
  pivots). Rest pose matches `HumanoidModel` proportions scaled `1.2`.
  Primitive meshes from `HumanoidModel` are attached via `BoneAttachment3D`
  per limb (no imported GLB required this slice). Provides
  `func attach_model(skeleton: Skeleton3D, model_root: Node3D) -> void`
  and `func bone_names() -> PackedStringArray`.

- `components/animation/locomotion_library.gd` — `class_name LocomotionLibrary`,
  `static func build_library() -> AnimationLibrary` procedurally creates 7
  `in-place` `Animation` resources at runtime: `Idle` (1.2 s loop, breathe),
  `Walk` (0.70 s), `Run` (0.52 s), `Sprint` (0.42 s), `TurnL90` (0.55 s),
  `TurnR90` (0.55 s), `Turn180` (0.80 s). Each clip animates `Skeleton3D`
  bone rotations only (no `Skeleton3D` translation tracks; root bone `position`
  stays `Vector3.ZERO`). Walk/Run/Sprint stride frequency maps to
  `lerp(WALK_FREQ 6.2, RUN_FREQ 11, clamp(speed/RUN_SPEED_REF 6.4))` and loop
  seamlessly. Turn clips rotate `spine_upper`+`hips` yaw `90/180` while feet
  step in place.

- `components/animation/character_locomotion.gd` — `class_name CharacterLocomotion
  extends Node`, owns `AnimationPlayer` + `AnimationTree` (`tree_root:
  AnimationNodeStateMachine`). Exposes:
  ```
  enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180 }
  var state: State
  var blend: float        # 0..1 walk→sprint
  var strafe: float       # -1 left .. +1 right
  var slope_deg: float
  var foot_slide: float   # cm/s computed
  func setup(skeleton: Skeleton3D, model_root: Node3D) -> void
  func update(p: Dictionary, delta: float) -> void
    # p keys: speed:float, strafe:float, slope_deg:float, yaw_delta:float,
    #         is_airborne:bool, move_dir:Vector3, facing:Vector3
  signal state_changed(new_state: State)
  ```
  `update()` selects state by speed thresholds (`IDLE <0.2, WALK 0.2–2.2,
  RUN 2.2–4.2, SPRINT >4.2` mapping to grand-plan `0–5.5`), blends
  `blend = clamp((speed-0.2)/(5.5-0.2),0,1)` into StateMachine
  `BlendSpace1D`, applies strafe via `Add2` lean (`±12°` roll at `|strafe|=1`),
  slope via spine pitch (`-slope*0.35` limited `±10°`), and triggers turn
  animation when `abs(yaw_delta) >60°` (90) or `>140°` (180) while
  `speed <0.2` and not airborne. After update it computes `foot_slide`
  as `foot_bone_world_velocity.xz.length()` measured from previous to current
  bone global positions (via `Skeleton3D.get_bone_global_pose`), averaged over
  two feet. When airborne, holds `air` weight and suppresses turn.

Ownership: `SkeletonFactory` owns rest pose; `LocomotionLibrary` owns clips;
`CharacterLocomotion` owns `AnimationTree` lifecycle and telemetry. No
`world/generation/*` touched.

### 2. Survivor and zombie bridge (capsule drives, skeleton follows)

Extend `actors/survivor/survivor.gd` and `actors/zombie/zombie.gd` minimally:

- In `_setup_body()` replace/extend visual setup: keep `Visual` Node3D, but
  under it create `Skeleton3D` via `SkeletonFactory`, then `AnimationPlayer`
  (with library from `LocomotionLibrary`) + `AnimationTree`
  (`active true, process_mode inherit`), then attach `HumanoidModel` meshes
  via `BoneAttachment3D`. Preserve existing capsule shape/positions.
  `HumanoidAnimator` remains as fallback for headless dummy renderer but
  `CharacterLocomotion` becomes authoritative when `Skeleton3D` exists;
  remove `HumanoidAnimator.set_motion` path or gate it behind
  `if skeleton==null`.

- Wire per frame in `_physics_process(delta)` after `move_and_slide()`:
  compute `xz_speed = Vector2(velocity.x,velocity.z).length()`,
  `strafe = facing.cross(move_dir).y` (signed lateral), `slope_deg` from
  `get_floor_normal()` angle or from `TerrainPlan` sampled height delta when
  `is_on_floor()` (read-only via `WorldPlan.height_at` if available, else
  floor normal), `yaw_delta = wrapf(target_yaw - facing_yaw, -PI, PI)`.
  Call `locomotion.update({speed:xz_speed, strafe:strafe, slope_deg:slope_deg,
  yaw_delta:yaw_delta, is_airborne:!is_on_floor(), move_dir:_move_dir,
  facing:facing}, delta)`. Verify `global_position` delta equals
  `move_and_slide` displacement, not animation root displacement (assert
  `skeleton.get_bone_global_pose(0).origin.length() <0.005` per frame).

- Zombie variant: `Survivor` vs `Zombie` both instantiate same
  `CharacterLocomotion` but zombie `setup(..., {"shamble":true})` applies
  shamble overlay: `spine pitch +8°`, `arm reach -70°`, `drag 0.3–0.65`
  multiplied into Walk/Run clips via `AnimationTree` `Blend2` offset.
  Deterministic per `persistent_id` seed for `drag/sway_sign`.

Streaming: `Survivor` and `Zombie` register `locomotion` processing only when
`is_inside_tree() and get_parent()!=null` and chunk `ACTIVE` (check
`ChunkManager.is_active_chunk(coord)` if available, else distance). When
chunk WARM/cold, `AnimationTree.active=false` and skeleton frozen at last
pose, resuming without pop (`advance_on_update`).

### 3. Hungarian plain test field and slope contract

Use existing streamed CITY Hungarian plain (`URBAN_INNER_M 350` flat, outer
`600` transition, hills beyond) — no new terrain. Span `slope_deg 0–22`
via flat spawn (0°) plus north walk 600–900 m east of river corridor beyond
hills, plus ramp seam at stair `LAND` landings inside generated buildings.
Character must not float on `terrain_height+0.03` overlay nor penetrate ramp
underside notch (trim rule retained: landing slab extends `0.06` under flights,
ramp collider trim `thickness*tan(angle)` per end, walkable top flush).

### 4. Telemetry, persistence, and compatibility

- Extend `core/autoload/debug_overlay.gd` F3 line (or `ChunkManager.debug_lines`
  passthrough) to show: `loco: <STATE> blend <0.00–1.00> speed <0.0>
  strafe <±1.0> slope <deg> foot_slide <cm/s> anim_ms <ms> active_chars
  <n>/12 skinned <n>/9`. `anim_ms` measured per `_process` via
  `Time.get_ticks_usec()` around `locomotion.update`.

- `SaveManager`/`WorldState`: store only survivor `position/facing/health/
  needs/inventory/stamina` plus `WorldSeed` seed/version — never store
  `AnimationTree` parameters, bone poses, or vertex data. On `load_state`,
  `locomotion` reconstructs `IDLE` then next `update()` corrects state.

- Compatibility: keep `Survivor.WALK_SPEED/ RUN_SPEED /ACCELERATION` constants
  as authoritative speed mapping; map grand-plan `0–5.5` to those via blend.
  `GENERATOR_VERSION` stays `2`; no `WorldPlan` mutation.

### 5. Headless harness

Create `debug/animation_test.gd` (`class_name AnimationTest extends Node`)
driven by `world/main.gd` when `OS.get_cmdline_user_args().has("--animationtest")`.
Registers as `AnimationTest` child, runs deterministically headless without window:
steps locomotion through scripted input sequences (see Acceptance §1) on a plain
`CharacterBody3D` with `Skeleton3D+AnimationTree` and reports PASS/FAIL per
subsection plus `finished with N failure(s)`. No scene/window needed.

## System ownership and interfaces

| System | Owns | Required invariant |
|---|---|---|
| `WorldSeed` | `GENERATOR_VERSION`, `sample_coherent*` domains | No new unseeded animation randomness; `skeleton` variation seeded by `persistent_id` hash only. |
| `WorldConstants` | `BUILDABLE_MAX_SLOPE_DEG 22`, `FRAME_BUDGET_MS 12` | Import, never duplicate; slope gate uses authoritative constant. |
| `WorldPlan/TerrainPlan` | `height_at` read-only for slope sampling | Locomotion reads only; never writes or caches height. |
| `ChunkManager` | ACTIVE/WARM counts, `debug_lines()` | Animation budget reads active counts; disables warm skeleton updates. |
| `SkeletonFactory` | `Skeleton3D` bone hierarchy + `BoneAttachment3D` | Rest pose at origin, root bone never translates. |
| `LocomotionLibrary` | 7 `in-place` `Animation` resources | No root translation tracks; loops seamless. |
| `CharacterLocomotion` | `AnimationPlayer`+`AnimationTree` StateMachine, `update()` contract, `foot_slide` telemetry | Capsule drives position; skeleton drives pose; ACTIVE-only tick. |
| `Survivor`/`Zombie` | Capsule `0.35/1.7`, `move_and_slide`, `request_move()` | `global_position` delta == physics displacement; `Visual` yaw follows `facing`. |
| `HumanoidModel` | Primitive `BoxMesh/CapsuleMesh` primitives | Attached via bone, not pivot-only; `collect_meshes` still works for death tint. |
| `DebugOverlay` | F3 locomotion line + animation ms | Shows state/blend/speed/strafe/slope/foot_slide/anim_ms. |
| `debug/animation_test.gd` | Headless locomotion proofs | Prints `finished with N failure(s)` marker; zero is pass. |
| `SaveManager/WorldState` | `seed/version/discovery/deltas` + survivor deltas | Never persists `bone pose`/`AnimationTree` graph; reload starts IDLE. |

Public interfaces remain compatible: `Survivor.request_move(dir,sprint)` and
`Survivor.stop_moving()` unchanged; `Survivor.save_state/load_state` gain no
animation keys; `PlayerController` keeps camera-relative input.

## Construction sequence

### Phase 0 — Reproduce and protect the failures (RED)

1. Preserve unrelated dirty work and `junk/` history; do not reset checkout.
2. Run `python tools/run_suite.py --import 120` and capture marker baseline.
3. Add behavioral assertions FIRST to `debug/animation_test.gd` and
   `components/animation/*` stubs that currently FAIL: state threshold table
   (0, 0.5, 2.0, 4.5, 5.5), strafe ±1 lean, yaw 90/180 turn trigger while
   `speed<0.2`, slope 0–22 no-float, foot_slide <0.12 on flat/hill/seam,
   in-place root bone `<0.005` translation, ACTIVE≤12 / skinned≤9 / ms≤2.
   Run `godot --headless --path . -- --animationtest` and confirm failing
   harness reports `finished with N failure(s) N>0` before production code.

### Phase 1 — Skeleton + library + StateMachine

1. Implement `components/animation/skeleton_factory.gd` (9 bones, rest pose).
2. Implement `components/animation/locomotion_library.gd` (7 in-place clips).
3. Implement `components/animation/character_locomotion.gd` (StateMachine,
   thresholds, blend, strafe Add2, slope pitch, turn trigger, foot_slide calc,
   airborne hold).
4. Extend `world/main.gd` to route `--animationtest` to `debug/animation_test.gd`
   and add `--animationtest` handling to `tools/run_suite.py` (log
   `out_animationtest.txt`, marker grep). Keep existing harness flags.
5. Run harness per clip in isolation (Idle, Walk, Run, Sprint loops) — green.

### Phase 2 — Bridge to capsule and zombie shamble

1. Extend `actors/survivor/survivor.gd` `_setup_body()` + `_physics_process()`
   to instantiate skeleton/tree, compute `speed/strafe/slope/yaw_delta`,
   call `locomotion.update`, verify `global_position` in-place invariant,
   expose `get_locomotion_state()` for overlay.
2. Mirror bridge in `actors/zombie/zombie.gd` with shamble overlay.
3. Gate `AnimationTree.active` by ACTIVE chunk (or parent distance fallback)
   and by `is_inside_tree()`.
4. Extend `core/autoload/debug_overlay.gd` F3 line to show locomotion state.
5. Run harness per movement bucket (still, strafe, turn, slope, seam) — green.

### Phase 3 — Persistence, regression, evidence closeout

1. Prove save exclusion: `SaveManager.save_state()` payload has no
   `bone/pose/anim` keys; after `load_state` skeleton resumes Idle correctly.
2. Run full required matrix (see below) and judge by explicit
   `finished with 0 failure(s)` marker (`3221225477` with marker is pass).
3. Windowed CITY proof (see below) capture PNG+log.
4. Commit coherent units (factory, library, locomotion, survivor/zombie bridge,
   overlay, harness, run_suite wiring, docs) without rewriting history; request
   independent Luna review with changed paths, commit IDs, outputs, proof, and
   residual risk. Do not edit `AUTOPILOT_STATE.json`.

## Explicit acceptance criteria

1. `--animationtest` finishes with `finished with 0 failure(s)`. In particular:
   same-seed locomotion state sequence deterministic regardless of tick order;
   thresholds `IDLE<0.2, WALK 0.2–2.2, RUN 2.2–4.2, SPRINT>4.2` (blend
   `0→1` across `0–5.5`) hold for 5 probe speeds `{0,0.5,2.0,4.0,5.5}`;
   `strafe ±1` produces `|roll|≥8°` lean while forward blend unchanged;
   `yaw_delta 90/180` while `speed<0.2` triggers `TURN_L90/R90/180` and no
   capsule translation; `slope 0–22°` keeps foot within `3 cm` of ground and
   spine pitch within `±10°`.

2. Foot slide ` <12 cm/s` on Hungarian plain proven headless: scripted
   `request_move()` Walk (`1.8`), Run (`3.6`), Sprint (`5.2`) each 4 s on flat
   (`slope 0°`), hill (`slope≈12°` at `x~700,z~700` rural), and ramp landing
   seam (inside qualifying building stair zone) — averaged `foot_slide`
   (both feet world velocity) `<0.12 m/s`; instantaneous spike `<0.18` for
   <6 frames during turn.

3. Capsule never slides-teleports and never penetrates ramp landing seam:
   during `--walkthrough` the full route (closed door → E open → entry →
   stairwell → 5 storeys roof → descend → exit → close) finishes with
   `finished with 0 failure(s)` with **no** `global_position` writes after
   initial resident-wait drop-off; `is_on_floor()` true with non-zero
   `velocity` never freezes position frame-over-frame (wedge check via ray
   ladder + capsule sweep diagnostics); walkable top remains flush
   (`LAND` slab under flights, ramp trim retained); open doorway still
   `clear without RID exclusion` and swung leaf remains collidable as in
   `--cityruntime`.

4. In-place guarantee: for 300 frames of Walk/Run/Sprint headless,
   `Skeleton3D` root bone translation `origin.length() <0.005 m` every frame
   and `global_position` displacement equals `move_and_slide` integration
   (measured `global_position` delta vs `velocity*delta` projection
   `cos<5°` and length error `<2%`); no `Animation` contains
   `Skeleton3D:position` track.

5. Streaming + performance budgets honored: `ChunkManager` `3x3` ACTIVE around
   spawn + rural hill claims `active_chars ≤12`, `skinned/warm ≤9`,
   `animation_ms ≤2.0 ms` aggregate across all ACTIVE `CharacterLocomotion`
   ticks (measured `t_anim_ms` in `debug_lines()`); warm chunks disable
   `AnimationTree` (`active false`) while retaining visual; no new per-frame
   `RID` or `Concave` per character; at most one `Skeleton3D+AnimationTree`
   per survivor/zombie.

6. Persistence & regression preserved: `SaveManager.save_state()` contains no
   `bone/pose/anim` keys; `load_state` after save reconstructs `IDLE` and next
   `update()` corrects to material speed; `--citytest`,
   `--terrainmaterialtest`, `--hydrotest`, `--biometest`, `--cityruntime`,
   `--walkthrough`, `--havoctest`, `--smoke` each still finish with
   `finished with 0 failure(s)` (window `3221225477` with marker is pass;
   faint `ObjectDB !is_inside_tree()` after `queue_free` guarded with
   `is_instance_valid+is_inside_tree()`).

7. Ordinary windowed player-facing proof archived: normal windowed CITY run
   (1200×720, not `--shot`) shows WASD Idle→Walk→Run→Sprint with visible
   skeleton limb swing, `F3` overlay `state+blend+speed+strafe+slope+
   foot_slide+anim_ms`; strafe A/D while facing north shows lateral lean
   without turning; tap Q/E or mouse yaw >90° while stationary triggers
   turn-in-place animation without sliding; walk onto `12°` hill shows lean
   and feet staying near ground; climb building stairs 2 storeys shows capsule
   staying on landing seam without wedge; PNG+log stored under
   `.hermes/autopilot/character/reports/SPEC-C001-windowed.*` or `junk/` and
   referenced in handoff; `docs/character/CHARACTER-CONTRACT.md` documents
   skeleton/in-place/budgets.

## Required automated verification

From canonical root `C:/Vibe Code project/Godot Project/ring-bell` run via
`python tools/run_suite.py --<flag> <timeout_s>` and judge by the printed
`finished with 0 failure(s)` marker (not exit code):

```text
python tools/run_suite.py --import 120
python tools/run_suite.py --animationtest 300
python tools/run_suite.py --citytest 300
python tools/run_suite.py --cityruntime 300
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --smoke 180
```

Every command must produce `finished with 0 failure(s)`. `tools/run_suite.py`
must be extended to handle `--animationtest` (file `out_animationtest.txt`,
same marker logic). Long runs redirect to file so timeout still yields tail.

## Ordinary player-facing proof

Run default CITY windowed (1200×720). Spawn at plaza (F3 on). With WASD:
Idle (no input) shows breathe; forward shows Walk→Run→Sprint blend as speed
rises; A/D strafe while holding W shows lateral lean without yaw. Release all
keys, then yaw 90° via Q/E or mouse: character plays Turn90 without sliding.
Walk east 200 m to hill `~12°` and observe slope lean and feet not floating.
Approach qualifying building (`int floors>=2`, `BuildingBuilder.has_stairs_for`
true) — closed door stops capsule; press E, leaf swings and stays collidable,
walk through aperture, cross entry corridor, climb 2 storeys, reverse and leave,
close door — it blocks again. Throughout, F3 overlay shows `loco:` state,
`blend`, `foot_slide<0.12`, `anim_ms≤2`. If failure, retain PNG/log with
`global_position`, `WorldSeed` and `velocity`. Headless `--shot` PNG insufficient
(dummy renderer).

## Performance, persistence, and compatibility boundaries

- Keep `64 m` chunks, ACTIVE `≤1` (3×3=9) WARM `≤2` (5×5) UNLOAD `3`, one
  terrain collider/chunk, one water collider/wet chunk, one biome collider/
  biome chunk, `GENERATOR_VERSION 2`. No new chunk size or hysteresis.
- Character budgets: `active_chars ≤12` in `3×3`, `skinned meshes ≤9` warm,
  `AnimationTree` per ACTIVE character, `AnimationTree.active=false` when
  WARM/cold; `animation_ms ≤2.0` aggregate; no per-character `RID` flood.
- Persistence: saves store `seed/version/discovery/deltas` + survivor
  `position/facing/health/needs/inventory/stamina`; never store `bone pose`
  or `AnimationTree` graph. `GENERATOR_VERSION` stays `2`; no city/biome
  topology change.
- Compatibility: keep `Survivor.WALK_SPEED 3.6 RUN_SPEED 6.4 ACCELERATION 12`,
  capsule `0.35/1.7`, `floor_max_angle 46°`; public `request_move/stop_moving`
  signatures unchanged; `HumanoidModel.collect_meshes` still works for death
  tint via BoneAttachment meshes.
- No new autoload, project setting, or `WORLD-CONTRACT.md`
  terrain/hydro/biome edit. `docs/character/CHARACTER-CONTRACT.md` is the
  only new contract this cycle documenting skeleton/in-place/budgets.
- Prefer in-place clip edits; do not add per-waypoint bodies, navmesh, or
  second invisible blocker for doors.

## Out of scope and escalation

- No terrain/hydrology/biome/geology/road/bridge/lake/underground world
  generation or `WorldConstants` edit beyond reading `BUILDABLE_MAX_SLOPE_DEG`.
- No combat (`Shove/Pistol Aim/Fire/Reload`), horde AI beyond shamble overlay,
  no interaction (`DoorPush/Pull`, `Crate/PickUp/Carry`), no vault/mantle/ledge
  parkour beyond existing `parkour_controller.gd` which stays untouched.
- No two-bone IK feet-on-terrain, no toon outline shader, no modular asset
  import (`art/character` stays procedural BoxMesh this slice), no
  `MultiMeshInstance3D` distant impostor.
- No broad `HumanoidAnimator` rewrite beyond gating; no teleport volumes or
  `global_position` writes after drop-off to fake locomotion.
- If repo contradicts an interface (e.g., `world/main.gd` cannot route
  `--animationtest`), stop and report exact path/conflict instead of inventing
  a second milestone. Principal blocker gets ≤2 bounded revisions; third loop
  becomes recovery cycle.

## Rollback and recovery

Keep pre-candidate checkpoint `023070d` and all unrelated user changes intact.
Builder commits atomically: factory, library, locomotion, survivor/zombie
bridge, overlay, harness, run_suite wiring, docs. If candidate fails review,
revert/ quarantine only its implementation commits, move generated artifacts
under `junk/` rather than deleting, and restore controller via Kanban outcome
with exact failure logs. Rollback must reproduce honest baselines:
`--citytest`/`--cityruntime`/`--walkthrough` green, no skeleton yet,
`HumanoidAnimator` procedural still green. Do not mark a failure as accepted
because rollback exists.
