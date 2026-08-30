# CHARACTER-CONTRACT.md — Skeleton-Driven In-Place Core Locomotion (P-C1)

## Overview
Capsule owns physics (`CharacterBody3D.move_and_slide`), Skeleton3D + AnimationTree owns pose (in-place). No slide-teleport. Every capsule move is readable via the skeleton you see.

## Skeleton
- Factory: `components/animation/skeleton_factory.gd` `SkeletonFactory.build_survivor_skeleton() -> Skeleton3D`
- Bones (10): `root/hips/spine_upper/head/l_thigh/l_shin/r_thigh/r_shin/l_upper_arm/r_upper_arm`
- Rest pose: hips `y 0.86`, spine_upper `0.95` matching `HumanoidModel` pivots, foot at ~0.02 above ground, scale 1.2 via model attachment.
- Primitive meshes from `HumanoidModel` are attached via `BoneAttachment3D` per limb (no GLB). `attach_model(skeleton, model_root)` reparents mesh children.
- `bone_names() -> PackedStringArray` for diagnostics.

## Animation Library
- `components/animation/locomotion_library.gd` `LocomotionLibrary.build_library() -> AnimationLibrary`
- 7 in-place clips: `Idle 1.2s loop breathe`, `Walk 0.70s`, `Run 0.52s`, `Sprint 0.42s`, `TurnL90 0.55s`, `TurnR90 0.55s`, `Turn180 0.80s`
- Each clip animates `Skeleton3D` bone rotations only (no `:position` track; root `Vector3.ZERO`). Walk/Run/Sprint stride frequency `lerp(6.2,11,clamp(speed/6.4))` loops seamlessly. Turn clips rotate `hips`+`spine_upper` yaw.

## Locomotion
- `components/animation/character_locomotion.gd` `CharacterLocomotion extends Node` owns `AnimationPlayer` + `AnimationTree` (`AnimationNodeStateMachine` with 7 nodes + auto transitions).
- Interface:
  ```
  enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180 }
  var state: State
  var blend: float        # 0..1 walk->sprint via clamp((speed-0.2)/5.3,0,1)
  var strafe: float       # -1..1
  var slope_deg: float
  var foot_slide: float   # m/s planted foot world velocity xz
  func setup(skeleton, model_root, opts={}) -> void
  func update(p: Dictionary, delta: float) -> void
  # p keys: speed, strafe, slope_deg, yaw_delta, is_airborne, move_dir, facing
  signal state_changed(new_state)
  ```
- Thresholds `IDLE<0.2 WALK 0.2-2.2 RUN 2.2-4.2 SPRINT>4.2` mapping grand-plan `0-5.5`, deterministic same-seed sequence.
- Blend maps across `0-5.5` via `(speed-0.2)/5.3`.
- Strafe via `Add2` lean `±12° roll` at `|strafe|=1` while forward blend unchanged.
- Slope via spine pitch `-slope*0.35` limited `±10°`.
- Turn triggers when `abs(yaw_delta)>60°` (90) or `>140°` (180) while `speed<0.2` and not airborne; plays turn clip 0.55/0.80s with no capsule translation.
- Foot slide measured as `foot_bone_world_velocity.xz.length()` via `Skeleton3D.get_bone_global_pose` averaged planted foot; <0.12 avg, spike <0.18 <6 frames in turn. Root bone `origin.length()<0.005` every frame.
- Shamble overlay for zombies: deterministic per `persistent_id` via `WorldSeed` hash for `drag 0.3-0.65` and `sway_sign`, `spine +8°` pitch, `arm -70°` reach.
- ACTIVE-only: `AnimationTree.active=false` when chunk WARM/cold while retaining visual; no new per-frame RID/Concave per character; at most one `Skeleton3D+AnimationTree` per survivor/zombie.
- Performance: `active_chars<=12` in `3x3` ACTIVE, `skinned/warm<=9`, `animation_ms<=2.0` aggregate (measured `t_anim_ms` via `Time.get_ticks_usec()` around `update`).

## Bridge
- `actors/survivor/survivor.gd` `_setup_body()` creates `Visual -> Skeleton3D` via factory, `Locomotion` child of Visual, attaches `HumanoidModel` via `BoneAttachment3D`, gates `HumanoidAnimator.set_process(false)` when skeleton exists. `_physics_process` after `move_and_slide()` computes `xz_speed`, `strafe`, `slope_deg` (floor normal or `WorldPlan.height_at` read-only), `yaw_delta` (wrap target-facing with 15° deadzone) and calls `locomotion.update`. Enforces `skeleton.get_bone_pose_position(root).length()<0.005`. Exposes `get_locomotion_state()/get_locomotion_blend()/get_foot_slide()/get_skeleton()/get_locomotion()`. `save_state/load_state` gain no bone keys (seed/version/discovery only).
- `actors/zombie/zombie.gd` mirrors with `shamble:true` via deterministic `WorldSeed` hash.
- `SAVE` excludes `bone/pose/anim`; `load_state` reconstructs `IDLE` then next `update()` corrects to material speed.

## Streaming & Budgets
- `ChunkManager` 3x3 ACTIVE (9 chunks), WARM 5x5, `UNLOAD_RADIUS=3`. Character budgets `active_chars≤12` `skinned≤9` `anim_ms≤2.0`. Warm disables `AnimationTree.active` without pop.
- `GENERATOR_VERSION` stays `2`; no `WorldPlan` mutation; `WorldConstants.BUILDABLE_MAX_SLOPE_DEG 22` authoritative.

## Telemetry
- `core/autoload/debug_overlay.gd` F3 line: `loco: <STATE> blend <0.00-1.00> speed <0.0> strafe <±1.0> slope <deg> foot_slide <cm/s> anim_ms <ms> active_chars <n>/12 skinned <n>/9` via `CharacterLocomotion` static counters.
- `debug/animation_test.gd` headless harness ` --animationtest` covers determinism, thresholds, strafe, yaw turn, slope, foot_slide <12cm/s on flat/hill/seam, in-place, streaming, persistence.

## Out of Scope
- No combat/interaction/parkour vault beyond existing `parkour_controller.gd`; no terrain/hydro/biome/world generation edits; no `MultiMesh` impostor; no IK.

## File Ownership
- Owns `actors/survivor/*`, `actors/zombie/*`, `components/animation/*`, `art/character/*`, `art/animations/*`, `docs/character/*`, `debug/animation_test.gd`; reads `world/generation/world_constants.gd`, `world/streaming/chunk_manager.gd` (ACTIVE counts), `WorldSeed.GENERATOR_VERSION` (never bumps).
