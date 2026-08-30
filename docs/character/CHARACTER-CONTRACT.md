# CHARACTER-CONTRACT.md — Vault + Mantle + Ledge Hang with Hands-on-Facade (P-C2)

## Overview
Capsule owns physics (`CharacterBody3D.move_and_slide`), Skeleton3D + AnimationTree owns pose (in-place). No slide-teleport. Every capsule move is readable via the skeleton you see. Vault (0.6-0.95m) / Mantle (0.9-1.2m) / Hang (1.6-2.2m + 0.70s ClimbUp) turn low walls into readable choice with 4cm hand IK and stamina gate.

## Skeleton
- Factory: `components/animation/skeleton_factory.gd` `SkeletonFactory.build_survivor_skeleton() -> Skeleton3D`
- Bones (10): `root/hips/spine_upper/head/l_thigh/l_shin/r_thigh/r_shin/l_upper_arm/r_upper_arm`
- Rest pose: hips `y 0.86`, spine_upper `0.95` matching `HumanoidModel` pivots, foot at ~0.02 above ground, scale 1.2 via model attachment.
- Primitive meshes from `HumanoidModel` are attached via `BoneAttachment3D` per limb (no GLB). `attach_model(skeleton, model_root)` reparents mesh children.
- `bone_names() -> PackedStringArray` for diagnostics.
- One `Skeleton3D+AnimationTree` per survivor/zombie, ACTIVE-only.

## Animation Library
- `components/animation/locomotion_library.gd` `LocomotionLibrary.build_library() -> AnimationLibrary`
- 11 in-place clips: `Idle 1.2s loop breathe`, `Walk 0.70s`, `Run 0.52s`, `Sprint 0.42s`, `TurnL90 0.55s`, `TurnR90 0.55s`, `Turn180 0.80s`, `Vault 0.55s`, `Mantle 0.85s`, `LedgeHang 1.2s loop`, `ClimbUp 0.70s`
- Each clip animates `Skeleton3D` bone rotations only (no `:position` track; root `Vector3.ZERO` stays <0.005). Walk/Run/Sprint stride frequency `lerp(6.2,11,clamp(speed/6.4))` loops seamlessly. Turn clips rotate `hips`+`spine_upper` yaw. Vault/Mantle/Hang/ClimbUp are rotation-only in-place, root <0.005.
- No `Skeleton3D:position` track, 0 `could not resolve track Skeleton3D:` warnings after deferred `AnimationPlayer.root_node = get_path_to(skeleton)` fix.

## Locomotion
- `components/animation/character_locomotion.gd` `CharacterLocomotion extends Node` owns `AnimationPlayer` + `AnimationTree` (`AnimationNodeStateMachine` with 11 nodes + auto transitions for all states).
- Interface:
  ```
  enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180, VAULT, MANTLE, HANG, CLIMB_UP }
  var state: State
  var blend: float        # 0..1 walk->sprint via clamp((speed-0.2)/5.3,0,1)
  var strafe: float       # -1..1
  var slope_deg: float
  var foot_slide: float   # m/s planted foot world velocity xz (scaled 0.015) avg <0.12 (<0.15 during vault window) spike <0.18 <6 frames, hang 0
  var hand_snap: float    # m distance from l/r_upper_arm bone world pos to ledge_pos+normal*0.06 +-0.22 lateral, <=0.04 during HANG via 2-bone IK
  var stamina: float      # 0-100, deduct 8 vault /12 mantle /10 climb, block if <cost
  var ledge_pos: Vector3
  var ledge_normal: Vector3
  func setup(skeleton, model_root, opts={}) -> void   # opts shamble:true + id for deterministic zombie sway
  func update(p: Dictionary, delta: float) -> void
  # p keys: speed, strafe, slope_deg, yaw_delta, is_airborne, move_dir, facing, stamina, vault_probe, mantle_probe, ledge_probe, jump_pressed
  signal state_changed(new_state)
  ```
- Thresholds `IDLE<0.2 WALK 0.2-2.2 RUN 2.2-4.2 SPRINT>4.2` mapping grand-plan `0-5.5`, deterministic same-seed sequence regardless of tick order including yaw/strafe/slope.
- Blend maps across `0-5.5` via `(speed-0.2)/5.3`.
- Strafe via `Add2` lean `±12° roll` at `|strafe|=1` while forward blend unchanged.
- Slope via spine pitch `-slope*0.35` limited `±10°`.
- Turn triggers when `abs(yaw_delta)>60°` (90) or `>140°` (180) while `speed<0.2` and not airborne; plays turn clip 0.55/0.80s with no capsule translation.
- Vault: probe `height 0.6-0.95` at 0.9m ahead (knee hit waist clear) triggers `VAULT 0.55s` locked, consumes 8 stamina, root <0.005, capsule sweep finds no penetration.
- Mantle: probe `height 0.9-1.2` (knee+waist hit head clear) triggers `MANTLE 0.85s` then `HANG 1.2s loop` with hands 4cm IK, consumes 12 stamina.
- Ledge Hang: rise `1.6-2.2` with downward lip finds `HANG` with `hand_snap <=0.04` freezing `velocity.xz<0.01`, indefinite until `jump_pressed` or forward triggers `CLIMB_UP 0.70s` costing 10 stamina ending in IDLE/WALK with foot_slide <0.12 and capsule on ledge top (no global_position write).
- HANG uses 2-bone IK: target `ledge_pos+ledge_normal*0.06 +-0.22` lateral, moves `l_upper_arm/r_upper_arm` via `skeleton.global_transform.affine_inverse()` to within 4cm, `hand_snap` is worst distance.
- Foot slide measured as foot bone world velocity xz scaled 0.015; <0.12 avg, spike <0.18 <6 frames, allow <0.15 during locked vault window because feet leave ground; hang foot_slide 0.
- Shamble overlay for zombies: deterministic per `persistent_id` via `WorldSeed` hash for `drag 0.3-0.65` and `sway_sign`, `spine +8°` pitch, `arm -70°` reach. Zombies may VAULT low rails (0.6-0.95) automatically when blocked, but never MANTLE/HANG/CLIMB_UP.
- ACTIVE-only: `AnimationTree.active=false` when chunk WARM/cold while retaining visual including HANG frozen pose without pop; at most one `Skeleton3D+AnimationTree` per survivor/zombie; `animation_ms <=2.0` aggregate via `Time.get_ticks_usec()`.
- Stamina drain: vault 8, mantle 12, climb 10 deducted on commit; block if stamina < cost. Hang idle does not drain. `exhausted` latched per Survivor flag respected.

## Bridge
- `actors/survivor/survivor.gd` `_setup_body()` creates `Visual -> Skeleton3D` via factory, `Locomotion` child of Visual, attaches `HumanoidModel` via `BoneAttachment3D`, gates `HumanoidAnimator.set_process(false)` when skeleton exists. Setup is `call_deferred` after both inside tree to silence `could not resolve track` warnings. `_physics_process` after `move_and_slide()` computes `xz_speed`, `strafe`, `slope_deg` (floor normal or `WorldPlan.height_at` read-only), `yaw_delta` (wrap target-facing with 15° deadzone) plus `stamina`, `jump_pressed` (`Input.is_action_just_pressed("jump")`), and probe dicts from `parkour.get_vault_probe()/get_mantle_probe()/get_ledge_probe()`. Calls `locomotion.update` with stamina-aware gate. Enforces `root <0.005` every frame and during `HANG` verifies `velocity.xz.length()<0.01` and `global_position` not drifting. Respect lock: while `locomotion.state in [VAULT,MANTLE,HANG,CLIMB_UP,TURN_*]`, `request_move()` direction is queued but not applied until lock ends; `HANG` sets `velocity = Vector3.ZERO`. Exposes `get_locomotion_state()/get_hand_snap()/get_vault_state()/get_stamina()/get_locomotion()`. `save_state/load_state` gain no bone keys (stamina preserved, locomotion reconstructs IDLE then next update corrects).
- `actors/zombie/zombie.gd` mirrors with `shamble:true` via deterministic `WorldSeed` hash. Zombies may `VAULT` low rails automatically when `move_dir` blocked (ray at knee 0.5), but never `MANTLE/HANG/CLIMB_UP` (probe returns empty or state disabled). Deterministic per `persistent_id`.
- `actors/traversal/parkour_controller.gd` owns vault/mantle/ledge probe geometry (knee 0.5 / waist 1.0 / head 1.6 at 0.9m, chest 1.2 with 0.18 offset, reach 0.62, down probe 0.9-2.1, rise 1.6-2.2, hysteresis 0.05) + stamina gate + capsule sweep + `ledge_grabbed` signal. No `global_position` write; vault/mantle arcs via state lock (old instant `velocity.y = VAULT_UPWARD_BOOST` gated behind `if locomotion==null` fallback). `vox_tag` classification for awning etc preserved. P-C2 adds `get_vault_probe()/get_mantle_probe()/get_ledge_probe()` for locomotion, reuse balcony/awning/cornice/parapet boxes and `vox_tag`.

## Streaming & Budgets
- `ChunkManager` 3x3 ACTIVE (9 chunks), WARM 5x5, `UNLOAD_RADIUS=3`. Character budgets `active_chars≤12` `skinned≤9` `anim_ms≤2.0` (tightened from ≤50 proxy, documented realistic 38 in city) - warm disables `AnimationTree.active` without pop, `t_anim_ms` aggregate via `Time.get_ticks_usec()`.
- `GENERATOR_VERSION` stays `2`; no `WorldPlan` mutation; `WorldConstants.BUILDABLE_MAX_SLOPE_DEG 22` authoritative.
- No per-frame `RID`/`Concave` per character (hands IK reuses bone poses, not `RID`); logs contain 0 `Element limit reached` RID floods.
- `MAX_MATERIALIZATIONS_PER_FRAME 1` with early `_collect_finished_jobs` and freed-Zombie guard preserved.

## Telemetry
- `core/autoload/debug_overlay.gd` F3 line: `loco: <STATE> blend <0.00-1.00> speed <0.0> strafe <±1.0> slope <deg> foot_slide <0.03> vault <0/1> mantle <0/1> hang <0/1> hand_snap <cm> stamina <0-100> anim_ms <ms> active_chars <n>/12 skinned <n>/9` via `CharacterLocomotion` static counters and `Survivor.stamina`.
- `debug/animation_test.gd` headless harness ` --animationtest` covers determinism, thresholds, strafe, yaw turn, slope, foot_slide <12cm/s on flat/hill/seam, in-place 300 frames across Walk/Run/Sprint/Vault/Mantle/ClimbUp with `global_position` delta `cos<5 len<2%` on flat with floor, vault 0.75 triggers VAULT 0.55 locked, mantle 1.1 triggers MANTLE 0.85 then HANG 1.2 loop with hands <=4cm IK, ledge 1.9 triggers HANG with hand_snap <=0.04 freezing velocity.xz<0.01, stamina gate 8/12/10, zombie vault only, streaming, persistence. Also asserts no `Skeleton3D:position` track and 0 `could not resolve track Skeleton3D:` warnings.

## Persistence
- `SaveManager.save_state()` contains no `bone/pose/anim/ledge` keys; `load_state` reconstructs `IDLE` with stamina preserved and next update with vault probe re-triggers correctly.
- `GENERATOR_VERSION` stays `2`; no city/biome topology change.

## Out of Scope
- No crouch/slide (P-C3), no wall-run/shimmy/chain (P-C4), no combat, no interaction beyond vault/mantle/hang traversal, no terrain/hydro/biome/road/rural world generation edits, no `WorldConstants` edit beyond reading `BUILDABLE_MAX_SLOPE_DEG`, no `MultiMesh` distant impostor, no foot IK yet (deferred).

## File Ownership (corrected per deferred 7)
- Owns `actors/survivor/*`, `actors/zombie/*`, `components/animation/*`, `art/character/*`, `art/animations/*`, `docs/character/*`, `debug/animation_test.gd`
- Reads `world/generation/world_constants.gd` (`BUILDABLE_MAX_SLOPE_DEG 22`, `LAND/LANE_W/flight_run/ramp_height_at`, `CHUNK_SIZE_M 64`, `FRAME_BUDGET_MS 12`), `world/streaming/chunk_manager.gd` ACTIVE counts, `WorldSeed.GENERATOR_VERSION` (never bumps)
- **Ancillary spec-authorized edits (not a violation):** `world/main.gd` (route `--animationtest`), `tools/run_suite.py` (add flag), `core/autoload/debug_overlay.gd` (F3 line)
- Never writes `world/generation/*`, `world/streaming/*`, geography `AUTOPILOT_STATE.json`, `WORLD-CONTRACT.md` terrain/hydro/biome sections
