# CHARACTER-CONTRACT.md — Wall Run + Ledge Traverse + Chained Flow: Industrial Facade Becomes Playground (P-C4)

## Overview
Capsule owns physics (`CharacterBody3D.move_and_slide`), Skeleton3D + AnimationTree owns pose (in-place). No slide-teleport. Every capsule move is readable via the skeleton you see. WallRun (0.80s @4.5 along wall tangent, no height gain, lateral dist 0.35-0.45 wall >=2.2 len >=3.5 yaw <35) / Shimmy (0.85s @0.60 lateral, hands 5cm analytic 2-bone IK, ledge len >=2.0) / Drop2Hang (0.45s) plus Chain Vault 0.6-0.95 -> WallRun 0.60s -> LedgeGrab -> Shimmy 2m -> ClimbUp 0.70s gated by stamina 22/s + 8/s block 10/8. Crouch (1.3m beam, 1.25 capsule, 1.2 m/s) / Slide (0.9m pipe, 1.00 capsule, 0.90s @6.0 committed) retained with stamina gate (slide 18/s block 15, vault 8 mantle 12 climb 10). Vault (0.6-0.95m) / Mantle (0.9-1.2m) / Hang (1.6-2.2m + 0.70s ClimbUp) now with analytic 2-bone IK 4cm. Capsule reuses one RID with 0.18s lerp, 19 clips total.

## Skeleton
- Factory: `components/animation/skeleton_factory.gd` `SkeletonFactory.build_survivor_skeleton() -> Skeleton3D`
- Bones (10): `root/hips/spine_upper/head/l_thigh/l_shin/r_thigh/r_shin/l_upper_arm/r_upper_arm`
- Rest pose: hips `y 0.86`, spine_upper `0.95` matching `HumanoidModel` pivots, foot at ~0.02 above ground, scale 1.2 via model attachment.
- Primitive meshes from `HumanoidModel` are attached via `BoneAttachment3D` per limb (no GLB). `attach_model(skeleton, model_root)` reparents mesh children.
- `bone_names() -> PackedStringArray` for diagnostics.
- `capsule_heights() -> Dictionary` returns `{"stand":1.7,"crouch":1.25,"slide":1.00}` for contract docs.
- One `Skeleton3D+AnimationTree` per survivor/zombie, ACTIVE-only.

## Animation Library
- `components/animation/locomotion_library.gd` `LocomotionLibrary.build_library() -> AnimationLibrary`
- 19 in-place clips: `Idle 1.2s loop breathe`, `Walk 0.70s`, `Run 0.52s`, `Sprint 0.42s`, `TurnL90 0.55s`, `TurnR90 0.55s`, `Turn180 0.80s`, `Vault 0.55s`, `Mantle 0.85s`, `LedgeHang 1.2s loop`, `ClimbUp 0.70s`, `CrouchIdle 1.2s loop (hips -8 deg, knees 42 deg, breathe)`, `CrouchWalk 0.70s loop @1.2 (shortened stride 18 deg, knees bent 42)`, `Slide 0.90s (hips low, legs extended 68 deg, arms trailing 28 deg, torso 12 deg lean)`, `StandUp 0.35s (hips rise 0.18, knees straighten)`, `WallRunL 0.80s loop (torso lean -12 deg, legs pump laterally, arms reaching)`, `WallRunR 0.80s loop (mirrored +12 deg)`, `Shimmy 0.85s loop @0.60 (hands alternating -118 deg, hips close)`, `Drop2Hang 0.45s (hips drop 0.35, arms -68 to -118 deg)`
- Each clip animates `Skeleton3D` bone rotations only (no `:position` track; root `Vector3.ZERO` stays <0.005). Walk/Run/Sprint stride frequency `lerp(6.2,11,clamp(speed/6.4))` loops. Turn clips rotate `hips`+`spine_upper` yaw. Vault/Mantle/Hang/ClimbUp/CrouchIdle/CrouchWalk/Slide/StandUp are rotation-only in-place, root <0.005.
- No `Skeleton3D:position` track, 0 `could not resolve track Skeleton3D:` warnings after deferred `AnimationPlayer.root_node = get_path_to(skeleton)` fix.

## Locomotion
- `components/animation/character_locomotion.gd` `CharacterLocomotion extends Node` owns `AnimationPlayer` + `AnimationTree` (`AnimationNodeStateMachine` with 19 nodes + auto transitions for all states).
- Interface:
  ```
  enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180, VAULT, MANTLE, HANG, CLIMB_UP, CROUCH_IDLE, CROUCH_WALK, SLIDE, STAND_UP, WALL_RUN_L, WALL_RUN_R, SHIMMY, DROP2HANG }
  var state: State
  var blend: float        # 0..1 walk->sprint via clamp((speed-0.2)/5.3,0,1)
  var strafe: float       # -1..1
  var slope_deg: float
  var foot_slide: float   # m/s planted foot world velocity xz (scaled 0.015) avg <0.12 (<0.15 during slide/vault window) spike <0.18 <6 frames, hang 0
  var hand_snap: float    # m distance from l/r_upper_arm bone world pos to ledge_pos+normal*0.06 +-0.22 lateral, <=0.04 during HANG via 2-bone IK
  var stamina: float      # 0-100, deduct 8 vault /12 mantle /10 climb / ~16 slide (18/s*0.90), block if <cost (slide block 15)
  var capsule_height: float  # 1.70 stand / 1.25 crouch / 1.00 slide, lerps with CAP_LERP 0.18s linear max_diff/CAP_LERP
  var ledge_pos: Vector3
  var ledge_normal: Vector3
  const CROUCH_IDLE_LEN 1.2, CROUCH_WALK_LEN 0.70, SLIDE_LEN 0.90, STAND_UP_LEN 0.35, SLIDE_SPEED 6.0/6.5, SLIDE_DRAIN 18.0, SLIDE_BLOCK 15.0, CAP_STAND 1.7/CAP_CROUCH 1.25/CAP_SLIDE 1.00/CAP_LERP 0.18
  func setup(skeleton, model_root, opts={}) -> void   # opts shamble:true + id for deterministic zombie sway
  func update(p: Dictionary, delta: float) -> void
  # p keys: speed, strafe, slope_deg, yaw_delta, is_airborne, move_dir, facing, stamina, vault_probe, mantle_probe, ledge_probe, jump_pressed, crouch_held, crouch_pressed, sprint_held, headroom_clear
  signal state_changed(new_state)
  ```
- Thresholds `IDLE<0.2 WALK 0.2-2.2 RUN 2.2-4.2 SPRINT>4.2` mapping grand-plan `0-5.5`, deterministic same-seed sequence regardless of tick order including yaw/strafe/slope/crouch_held/sprint_held interleaving.
- Blend maps across `0-5.5` via `(speed-0.2)/5.3`.
- Strafe via Add2 lean `±12° roll` at `|strafe|=1` while forward blend unchanged; during SLIDE lean minimal 0.2 factor.
- Slope via spine pitch `-slope*0.35` limited `±10°`.
- Turn triggers when `abs(yaw_delta)>60°` (90) or `>140°` (180) while `speed<0.2` and not airborne; plays turn clip 0.55/0.80s with no capsule translation.
- Vault: probe `height 0.6-0.95` at 0.9m ahead (knee hit waist clear) triggers `VAULT 0.55s` locked, consumes 8 stamina via actor path, root <0.005, capsule sweep finds no penetration.
- Mantle: probe `height 0.9-1.2` (knee+waist hit head clear) triggers `MANTLE 0.85s` then `HANG 1.2s loop` with hands 4cm IK, consumes 12 stamina via actor.
- Ledge Hang: rise `1.6-2.2` with downward lip finds `HANG` with `hand_snap <=0.04` freezing `velocity.xz<0.01`, indefinite until `jump_pressed` or forward triggers `CLIMB_UP 0.70s` costing 10 stamina ending in IDLE/WALK.
- Crouch: `crouch_held true` + speed 0.0 => `CROUCH_IDLE 1.2s loop` with capsule 1.25, `crouch_held true` + speed 1.2 => `CROUCH_WALK 0.70s @1.2` with capsule 1.25; `crouch_held false` while in crouch checks `headroom_clear` (upward sphere 0.25 at +1.55) => `STAND_UP 0.35s` to 1.70 when clear else stays `CROUCH_IDLE` 1.25.
- Slide: `sprint_held && crouch_pressed && speed>3.0 && stamina>=15 && not _shamble && not is_airborne` => `SLIDE 0.90s` locked at `velocity = facing*6.0-6.5`, capsule 1.00 +-0.03 frozen for entire 0.90s (no cancel, no request_move override), stamina drains 18/s via actor path (~16), then either `STAND_UP 0.35s` when headroom clear ending in IDLE/WALK with capsule 1.70 or remains `CROUCH_IDLE` 1.25 when blocked.
- WallRun: probe lateral dist 0.35-0.45 at y 1.2 length 0.45 wall_height >=2.2 via 3 vertical rays, length >=3.5 via 2 horizontal, flat variance <0.08, yaw <35, speed >=3.2, triggers `WALL_RUN_L/R 0.80s` locked along `wall_tangent*4.5` with `y<0.08` and `wall_snap <=0.08` light brush, drain 22/s block 10, capsule sweep PhysicsShapeQueryParameters3D finds no penetration, no global_position write
- Shimmy: `ledge len >=2.0` when `HANG/SHIMMY` and `strafe !=0` triggers `SHIMMY 0.85s` translating `0.60 +-0.1` laterally with analytic hand_snap `<=0.05` every frame via `solve_two_bone` law-of-cos, drain 8/s block 8, `wall_snap` brush, then `jump` -> `CLIMB_UP 0.70s`
- Drop2Hang: wallrun ends via `Drop2Hang 0.45s` to `HANG` if still wall else `IDLE`, shimmy to `HANG` if probe lost
- Analytic IK: `solve_two_bone(shoulder, elbow_rest, hand_rest, target) -> {elbow,hand,hand_snap}` law-of-cos with l1 0.28 l2 0.27, HANG kept 4cm now analytic, SHIMMY 5cm
- Headroom: upward `PhysicsShapeQueryParameters3D` sphere 0.25m at `global_position + (0,1.55,0)` blocks STAND_UP and keeps CROUCH_IDLE 1.25, open doorway still clear without RID exclusion.
- Capsule lerp: `capsule_height` lerps to target via `move_toward(cur, target, max_diff/CAP_LERP * delta)` where `max_diff 0.7` => speed 3.889, reaches within 0.20s +-0.03 verified via `locomotion.capsule_height` and `CollisionShape3D.shape.height`. One `CapsuleShape3D` RID per actor reused (no per-frame new Capsule).
- HANG uses 2-bone IK: target `ledge_pos+ledge_normal*0.06 +-0.22` lateral, moves `l_upper_arm/r_upper_arm` via `skeleton.global_transform.affine_inverse()` to within 4cm.
- Foot slide measured as foot bone world velocity xz scaled 0.015; <0.12 avg, spike <0.18 <6 frames, allow <0.15 during locked slide/vault window because feet leave ground; hang 0. CrouchWalk also <0.12.
- Shamble overlay for zombies: deterministic per `persistent_id` via `WorldSeed` hash for `drag 0.3-0.65` and `sway_sign`, `spine +8°` pitch, `arm -70°` reach. Zombies may VAULT low rails (0.6-0.95) automatically when blocked cost-free, but never CROUCH/SLIDE/STAND_UP/MANTLE/HANG/CLIMB_UP.
- ACTIVE-only: `AnimationTree.active=false` when chunk WARM/cold while retaining visual including CROUCH_IDLE/SLIDE frozen pose and vault/mantle without pop; at most one `Skeleton3D+AnimationTree` per survivor/zombie; `animation_ms <=2.0` aggregate via `Time.get_ticks_usec()`.
- Stamina unified: single `Survivor.stamina` authoritative, `locomotion.stamina` mirrors it, deduct via `actor.set("stamina", cur-cost)` directly for vault/mantle/climb and drain during slide, block second slide when <15.

## Bridge
- `actors/survivor/survivor.gd` `_setup_body()` creates `Visual -> Skeleton3D` via factory, `Locomotion` child of Visual, attaches `HumanoidModel` via `BoneAttachment3D`, gates `HumanoidAnimator.set_process(false)` when skeleton exists. Stores `CollisionShape3D` ref `_capsule_shape/_capsule` for height lerp (`shape.position.y = height*0.5`). Setup is `call_deferred` after both inside tree to silence `could not resolve track` warnings. `_physics_process` after `move_and_slide()` computes `xz_speed`, `strafe`, `slope_deg` (floor normal or `WorldPlan.height_at` read-only), `yaw_delta` (wrap target-facing with 15° deadzone) plus `stamina`, `wall_probe` (from `parkour.get_wall_probe()`), `shimmy_probe`, `jump_pressed` (`Input.is_action_just_pressed("jump")`), `crouch_held` (`Input.is_action_pressed("crouch")` default Ctrl + meta fallback), `crouch_pressed` (`is_action_just_pressed("crouch")` + meta), `sprint_held` (`_wants_sprint`), `headroom_clear` via upward sphere 0.25 at +1.55, and probe dicts from `parkour.get_vault_probe()/get_mantle_probe()/get_ledge_probe()`. Calls `locomotion.update` with unified stamina gate. Handles `capsule lerp` via `_update_capsule(delta)` reading `locomotion.capsule_height`. Respect lock: while `locomotion.state in [VAULT,MANTLE,HANG,CLIMB_UP,SLIDE,STAND_UP,TURN_*]`, `request_move()` direction is queued but not applied until lock ends; `SLIDE` sets `velocity = facing*6.0` regardless of stick, `CROUCH_WALK` clamps `target_speed` to 1.2, `STAND_UP` damps velocity, `HANG` sets `velocity = Vector3.ZERO`. Enforces `root <0.005` every frame and during `HANG` verifies `velocity.xz<0.01`. Exposes `get_locomotion_state()/get_hand_snap()/get_vault_state()/get_stamina()/get_locomotion()/get_capsule_height()/get_capsule_shape()/set_crouch(bool)`. `save_state/load_state` gain no bone keys (stamina preserved, locomotion reconstructs IDLE then next update corrects, capsule resets to 1.70).
- `actors/zombie/zombie.gd` mirrors with `shamble:true` via deterministic `WorldSeed` hash. Zombies may `VAULT` low rails automatically when `move_dir` blocked (ray at knee 0.5) cost-free, but never `CROUCH_*/SLIDE/STAND_UP/MANTLE/HANG/CLIMB_UP` (probe returns empty or state disabled via `_shamble` guard). Capsule height 1.70 only (no crouch/slide), but still reuses one RID via `_update_capsule`.
- `actors/traversal/parkour_controller.gd` owns vault/mantle/ledge probe geometry (knee 0.5 / waist 1.0 / head 1.6 at 0.9m, chest 1.2 with 0.18 offset, reach 0.62, down probe 0.9-2.1, rise 1.6-2.2, hysteresis 0.05) + stamina gate + capsule sweep + `ledge_grabbed` signal. No `global_position` write; vault/mantle arcs via state lock (old instant `velocity.y = VAULT_UPWARD_BOOST` gated behind `if locomotion==null` fallback). `vox_tag` classification for awning etc preserved. P-C3 adds headroom helper via `Survivor._check_headroom_clear()` (sphere 0.25 at +1.55) for locomotion, reuse balcony/awning/cornice/parapet boxes and `vox_tag`.

## Streaming & Budgets
- `ChunkManager` 3x3 ACTIVE (9 chunks), WARM 5x5, `UNLOAD_RADIUS=3`. Character budgets `active_chars≤12` `skinned≤9` `anim_ms≤2.0` (tightened from ≤50 proxy, documented realistic 38 in city) - warm disables `AnimationTree.active` without pop including CROUCH_IDLE/SLIDE/WALL_RUN/SHIMMY frozen pose, `t_anim_ms` aggregate via `Time.get_ticks_usec()`, at most one wall Shape per chunk ACTIVE-only, no per-frame RID flood.
- `GENERATOR_VERSION` stays `2`; no `WorldPlan` mutation; `WorldConstants.BUILDABLE_MAX_SLOPE_DEG 22` authoritative.
- Capsule lerp 0.18s reuses `CapsuleShape3D.height` property on same RID (verified `get_rid()` stable across 60 frames toggles, no per-frame RID flood); logs contain 0 `Element limit reached` RID floods.
- No per-frame `RID`/`Concave` per character (capsule height reuse, hands IK reuses bone poses); crouch/slide/hang do not add new RID/Concave per character.
- `MAX_MATERIALIZATIONS_PER_FRAME 1` with early `_collect_finished_jobs` and freed-Zombie guard preserved.

## Telemetry
- `core/autoload/debug_overlay.gd` F3 line: `loco: <STATE> blend <0.00-1.00> speed <0.0> strafe <±1.0> slope <deg> foot_slide <0.03> crouch <0/1> slide <0/1> vault <0/1> mantle <0/1> hang <0/1> hand_snap <cm> stamina <0-100> caps_h <1.70/1.25/1.00> anim_ms <ms> active_chars <n>/12 skinned <n>/9` via `CharacterLocomotion` static counters, `Survivor.stamina`, `capsule_height`.
- `debug/animation_test.gd` headless harness `--animationtest` covers determinism (including crouch_held/sprint_held interleaving), thresholds (5 probes 0,0.5,2.0,4.0,5.5 plus crouch_held true => CROUCH_IDLE 1.25 / CROUCH_WALK 1.2 and sprint+camou pressed => SLIDE 0.90 locked), strafe, yaw turn, slope, foot_slide <12cm on flat/hill/seam + root <0.005, in_place 300 frames across Walk/Run/Sprint/Vault/Mantle/ClimbUp/CrouchWalk/Slide/StandUp with `global_position` delta `cos<5 len<2%` on flat with floor, capsule lerp 0.18 reaches within 0.20, capsule RID stable, synthetic crouch/slide/vault beams via capsule sweep, stamina unified via actor path slide ~16 deduct block second slide, zombie vault cost-free never crouch/slide, headroom block stays crouched, streaming, persistence (save excludes bone/pose/anim/ledge/capsule, load reconstructs IDLE then next update with crouch_held true re-triggers CROUCH_IDLE with capsule lerping to 1.25). Also asserts no `Skeleton3D:position` track and 0 `could not resolve track Skeleton3D:` warnings and 19 clips with correct lengths.

## Persistence
- `SaveManager.save_state()` contains no `bone/pose/anim/ledge/capsule` keys; `load_state` reconstructs `IDLE` with stamina preserved and next update with `crouch_held true` re-triggers `CROUCH_IDLE` with `capsule_height` lerping to 1.25 and correctly remains crouched if headroom blocked vs `STAND_UP` to 1.70 when clear; after `SLIDE` save at 0.45s load reconstructs IDLE and next `crouch_pressed+sprint` re-triggers correctly.
- `GENERATOR_VERSION` stays `2`; no city/biome topology change.

## Out of Scope
- No wall-run/shimmy/chain (P-C4), no combat beyond vault/mantle/hang/crouch/slide traversal, no terrain/hydro/biome/road/rural world generation edits, no `WorldConstants` edit beyond reading `BUILDABLE_MAX_SLOPE_DEG`, no `MultiMesh` distant impostor, no foot IK yet (deferred).

## File Ownership (corrected per deferred 7)
- Owns `actors/survivor/*`, `actors/zombie/*`, `components/animation/*`, `art/character/*`, `art/animations/*`, `docs/character/*`, `debug/animation_test.gd`
- Reads `world/generation/world_constants.gd` (`BUILDABLE_MAX_SLOPE_DEG 22`, `LAND/LANE_W/flight_run/ramp_height_at`, `CHUNK_SIZE_M 64`, `FRAME_BUDGET_MS 12`), `world/streaming/chunk_manager.gd` ACTIVE counts, `WorldSeed.GENERATOR_VERSION` (never bumps)
- **Ancillary spec-authorized edits (not a violation):** `world/main.gd` (route `--animationtest`), `tools/run_suite.py` (add flag), `core/autoload/debug_overlay.gd` (F3 line)
- Never writes `world/generation/*`, `world/streaming/*`, geography `AUTOPILOT_STATE.json`, `WORLD-CONTRACT.md` terrain/hydro/biome sections
