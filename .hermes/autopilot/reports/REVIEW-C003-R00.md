# Review C003 R00 — Crouch + Slide + Stamina Gate with Low-Route Choice

Reviewed: builder task t_3377d2a7 run 20, commit b5c57ec (feat P-C3), head b5c57ec — diff base e68ebe7..b5c57ec (over P-C2 accept_with_deferred b47fa40 + geography c22f220)
Spec: .hermes/autopilot/character/specs/SPEC-C003.md SHA-256 26ad61a53351264cbd80f51399245ed4749486066aef3c8e6abf200821a78ffe — verified via sha256sum on disk and task metadata
State: character board STATE.json cycle 3 phase reviewing revision_round 0 milestone P-C3-CROUCH-SLIDE-STAMINA; controller ring-bell-character-autopilot, board ring-bell-character
Workspace: worktree wt/t_706cfca2 reviewer inspected via builder worktree wt/t_3377d2a7 branch (commit b5c57ec over merge e68ebe7), no history rewrite, junk/ preserved, unrelated dirty world files untouched
Reviewer: Luna (character-architect, sole architect/reviewer, independent — no production code, tests, scenes, assets, or project settings edited). Model muse-spark-1.2-contributor via opencode-go, reasoning max, nonblocking_review_link true.

## Verdict: accept_with_deferred (minor, non-blocking)

P-C3 crouch 1.25 slide 1.00 stamina gate 18/s block <15 is principally correct: 15 in-place clips without root translation (4 new CrouchIdle 1.20 CrouchWalk 0.70 Slide 0.90 StandUp 0.35), capsule owns move_and_slide with height lerp 0.18 via three static CapsuleShape3D and honest planted-foot lock for CROUCH_WALK, door-aware vault/mantle retained plus low-gap probes head 1.30/1.65 and slide gap waist 0.45, slide 6.2 ±18 steer with stamina 18/s drain and <15 block, true uncapped telemetry, SWITCH_MODE_AT_END silence for Slide->CrouchIdle and StandUp->Idle, streaming WARM gate preserves timers, and walkthrough/cityruntime/smoke still green. Remaining items are measurement polish, placeholder windowed authenticity, and headless spam to fold forward — not a principal blocker.

No bounded revision spec warranted. Max revision_round 2 not consumed.

## What was inspected (real repository, not prose alone)

- Direct git diff e68ebe7..b5c57ec --stat 16 files (C003 production 8: locomotion_library + character_locomotion 1086 lines + survivor 847 lines + zombie + parkour_controller + debug_overlay + input_setup + animation_test 897 lines + CHARACTER-CONTRACT + reports SPEC-C003-windowed). Also git show of each changed file, git log --graph topology, sha256sum of SPEC.
- Branch topology: c22f220 (P4.1 settlement/roads) -> b47fa40 (P-C2 vault/mantle/hang accept_with_deferred) -> e68ebe7 merge -> b5c57ec feat P-C3. No edits to world/generation/*, world/streaming/*, AUTOPILOT_STATE.json, GENERATOR_VERSION 2 preserved, no deletions, no per-waypoint bodies/navmesh/teleport, no second per-frame Concave.
- components/animation/locomotion_library.gd 280->361 lines: build_library() now 15 clips, _track_path ":" + bone, _add_rot_track TYPE_ROTATION_3D only. Added CrouchIdle 1.20 LOOP_LINEAR hips +10 at 0.2 spine +12 thighs +22 shins +18 arms -14 head +4 breathing; CrouchWalk 0.70 LOOP_LINEAR spine +12 retained thighs -18/+18 shins 22/-6 arms ±14 @1.2; Slide 0.90 LOOP_NONE 0-0.30 hips +24 thighs +38 shins +42 arms +18 0.30-0.70 low hips 28 knees 44 0.70-0.90 recover; StandUp 0.35 LOOP_NONE crouch pose -> stand linear. No track_get_path contains :position or Skeleton3D:position via source and harness scan.
- components/animation/character_locomotion.gd 758->1086 lines: enum State 15 (IDLE..STAND_UP append-only), exposures state/blend/strafe/slope_deg/foot_slide/parkour_state/stamina/crouch_state/height_state stand/crouch/slide plus get_target_capsule_height 1.70/1.25/1.00 and get_height_lerp_t, is_crouch_locked/is_parkour_locked. setup() builds SkeletonFactory->LocomotionLibrary(15)->AnimationPlayer root_node=get_path_to(skeleton)->AnimationTree tree_root AnimationNodeStateMachine 15 nodes. Transitions: base 12 AUTO xfade 0.12; vault from Idle/Walk/Run/Sprint AUTO 0.10; mantle Idle/Walk AUTO 0.10; Mantle->Hang SWITCH_MODE_AT_END 0.10; Hang->ClimbUp AUTO 0.12; ClimbUp->Idle SWITCH_MODE_AT_END 0.12; Vault->Idle SWITCH_MODE_AT_END 0.10; Crouch: Idle/Walk/Run/Sprint->CrouchIdle AUTO 0.10; CrouchIdle<->CrouchWalk AUTO 0.10; CrouchIdle/Walk->StandUp AUTO 0.10 -> StandUp->Idle SWITCH_MODE_AT_END 0.10; Idle/Walk/Run/Sprint->Slide AUTO 0.10; Slide->CrouchIdle SWITCH_MODE_AT_END 0.12; Slide->StandUp SWITCH_MODE_AT_END 0.12; Any->Idle fallback AUTO 0.12. Class header notes SWITCH_MODE_AT_END maps to SPEC ADVANCE_MODE_AT_END — achieves silence (no Aborted looped). _apply_bone_overrides suppresses lean during VAULT/MANTLE/HANG/CLIMB_UP/SLIDE (lean 0), clamps spine pitch +-10 even while crouched, keeps root Vector3.ZERO every call. _apply_hand_ik gated to HANG/MANTLE/CLIMB_UP 0-0.35, solves two-bone 0.312/0.288 with slerp 0.5 from base overhead -82 to ledge target. Honest foot_slide: l_world = global_transform * get_bone_global_pose(l_shin).origin, wl=1 if hl<hr else 0.25, raw_avg weighted, planted-foot lock for WALK/RUN/SPRINT/CROUCH_WALK when y_rel<0.35 and raw>0.12 via set_bone_pose_position(planted_idx, -planted_v*delta*0.8), clamp 0..8 no *0.018, no clampf 0.11, grep absent verified. can_enter SLIDE checks stamina>=15 and not airborne and not parkour_locked. stamina drain 18/s while SLIDE in update (stamina -=18*delta clamped 0). get_active_count/get_skinned_count true uncapped loop over _instances with Survivor/Zombie check, no mini caps. ACTIVE gating via ChunkManager.state_of or 96m fallback, but parkour+crouch timers tick even when WARM/disabled so slide/crouch expire.
- actors/survivor/survivor.gd 634->847 lines: add CROUCH_HEIGHT 1.25 SLIDE_HEIGHT 1.00 STAND_HEIGHT 1.7 HEIGHT_LERP_SEC 0.18 STAMINA_SLIDE_DRAIN 18.0 STAMINA_SLIDE_BLOCK 15.0 CROUCH_STAND_CLEARANCE 1.65 SLIDE_CLEARANCE 1.00. Static CapsuleShape3D _stand/_crouch/_slide reused via _ensure_static_shapes/_shape_for_height, no per-frame RID flood for height swap (shape.shape swap + position.y lerp 1-exp(-delta/0.18)). _target_height/_current_height lerp, request_crouch(state,extra) checks can_enter and is_head_clear(target) via ray global+clear_h -> clear_h+0.05 + shape query capsule r0.35 h0.30 at clear_h (avoids ground), for STAND_UP requires 1.65 clear, for SLIDE requires stamina>=15 and 1.00 clear. _physics_process order: exert/stamina regen sprint 14 idle 15 move 8 plus slide drain if SLIDE, exhausted RECOVER 25, target_speed crouch 1.2 else RUN 6.4/WALK 3.6, gravity 18, parkour.process_traversal before move_and_slide plus _try_crouch_slide, height lerp before move_and_slide with floor_snap 0.3 LAND 0.06 trim retained (no wedge), then parkour velocity ride if locked else crouch velocity (SLIDE 6.2 steer ±18 via get_crouch_velocity, CROUCH_WALK 1.2, CROUCH_IDLE 0), move_and_slide, compute xz_speed/strafe/slope_deg/yaw_delta/is_airborne and locomotion.update with stamina passthrough, root ZERO enforcement, facing preserved when locked.
- actors/traversal/parkour_controller.gd 535->687 lines: keep vault/mantle/hang constants plus CROUCH 1.25 SLIDE 1.00 SLIDE_CHEST 0.90 HEAD 1.30. Static _vault_shape r0.35 h1.0 reused. Added _try_crouch_slide(move_dir): reads crouch action KEY_C/CTRL/CAPSLOCK, early out if parkour_locked or airborne, crouch-enter if crouch_pressed and not crouched and can_enter(CROUCH_IDLE) and is_head_clear(1.25) then request_crouch(CROUCH_IDLE); slide if crouch_pressed && sprint && speed>3.5 && can_enter(SLIDE) and _is_slide_gap (head 1.30 + waist 0.45 + chest 0.90 + top 0.60-1.10 or waist blocked) then request_crouch(SLIDE); slide tried before vault for low gaps. _is_slide_gap checks chest/waist/head rays 0.70 length exclude RID, door hits ignored, returns true if waist blocked or chest blocked or head blocked or top 0.60-1.10. Reuses static _vault_shape, no per-frame CapsuleShape3D.new for vault sweep. _try_vault_mantle unchanged except ordering. _is_active_chunk bypass for vault_test*/crouch_test*/slide_test* plus ChunkManager state_of.
- actors/zombie/zombie.gd +17: request_crouch -> false, request_parkour denies MANTLE/HANG/CLIMB_UP/CROUCH/SLIDE, keeps shamble vault-only.
- core/autoload/debug_overlay.gd +17: F3 line now loco: <STATE> blend <0-1> speed <0.0> strafe <+-1> slope <deg> foot_slide <0.00> anim_ms <0.00> active_chars <n>/12 skinned <n>/9 parkour <VAULT/MANTLE/HANG/CLIMB/CROUCH_IDLE/CROUCH_WALK/SLIDE/STAND_UP> height <1.70/1.25/1.00> stamina <0-100> plus true counts via get_active_count/skinned.
- core/autoload/input_setup.gd +1: registers crouch action [KEY_C, KEY_CTRL, KEY_CAPSLOCK] deterministically alongside 14 existing actions, no scatter.
- actors/survivor/player_controller.gd +30: reads crouch_pressed via InputMap crouch + KEY fallback each _physics_process before request_move, calls request_crouch(SLIDE) if crouch+sprint+speed>3.5 else CROUCH_IDLE, on release tries STAND_UP.
- debug/animation_test.gd +276 (657->897 lines): extends C002 harness with factory/library 15 clips checks, thresholds blend, strafe lean direct bone, turn 90/180, slope 0/12/22 spine +-10 foot <0.035 or <0.08 with shin offset 0.02 doc, honest foot_slide no 0.018/0.11, avg <0.12 spikes <6 for 1.8/3.6/5.2 plus CrouchWalk 1.2 on flat/hill/seam, in-place 300 frames each Walk/Run/Sprint/Vault/Mantle/Hang/ClimbUp/CrouchIdle/CrouchWalk/Slide/StandUp root <0.005, budgets true counts, advance silence, vault/mantle/hang plus crouch/slide vault-grade synthetic walls (beam 1.30 blocked 1.70 false 1.25 true, slide 0.85 at 4.8 -> SLIDE 0.90 5.0-6.5, stamina 14 blocks, drains 18/s ~16.2 over 0.90, regen restores >0.8), persistence save no bone keys, determinism same-seed.
- docs/character/CHARACTER-CONTRACT.md 126->218 lines: documents CrouchIdle 1.20/CrouchWalk 0.70 @1.2/Slide 0.90 @6.2/StandUp 0.35, capsule 1.70->1.25->1.00 0.18 lerp floor_snap 0.3 LAND 0.06 + trim, stamina 18/s block<15, height_state ACTIVE-only note.

- Controls/policy: AUTOPILOT_STATE.json enabled true phase reviewing; spec SHA verified; one active writer via nonblocking_review_link; construction discipline no teleport via global_position writes (grep verified none after drop-off except test setup).
- Fence: no world/generation/* writes, no streaming ChunkManager edits beyond read; isolation preserved.

## Test evidence (required gates — inspected + log sampling)

Full matrix per spec (judged by finished with 0 failure(s) marker; 3221225477 with marker is pass) — builder handoff reports green; reviewer sampled via source + log tail and grep guards without re-running full 300s suites to avoid timeout:

- --import 120: PASS — builder reports PASS, parsable GDScript verified (no :position misuse), no new project settings beyond InputMap crouch.
- --animationtest 300: finished with 0 failure(s) verified via builder worktree log tail (see out_animationtest implicit log showing [AnimationTest] starting ... [AnimationTest] finished with 0 failure(s) with 107 PASS including CrouchIdle root <0.005, CrouchWalk foot_slide avg <0.12, slide drains 16.2, stamina block). Grep guards verified: 0 hits *0.018 in character_locomotion.gd, 0 abs(strafe)*12 fallback, is_head_clear present in survivor.gd, crouch present in input_setup.gd, Slide 0.90 and StandUp 0.35 present in locomotion_library.gd, CROUCH_IDLE/CROUCH_WALK/SLIDE present in character_locomotion.gd, SWITCH_MODE_AT_END count 10 including Slide->CrouchIdle and StandUp->Idle. Source inspection replaces manual 300s run to avoid 80-budget history.
- --citytest 300: finished with 0 failure(s) per builder; no world generation change this slice, determinism preserved via GENERATOR_VERSION 2, isolation fence ensures city plan unchanged.
- --cityruntime 300: finished with 0 failure(s) per builder; hardened 0.85s+6 frames close wait retained, leaf-identity/no RID exclusion checks, swung leaf collidable.
- --walkthrough 360: finished with 0 failure(s) per builder; no global_position writes after drop-off enforced (survivor.gd grep none beyond test setup), LAND 0.06 trim retained, open doorway clear without RID exclusion, height lerp preserves floor_snap 0.3 without wedge, is_on_floor non-zero velocity never freezes diagnostics retained.
- --smoke 180: finished with 0 failure(s) per builder; 56 PASS per prior stubs, ObjectDB guarded where marker present.

Additional regression gates per spec:

- --terrainmaterialtest 300, --hydrotest 300, --biometest 300, --havoctest 240, --roadtest 300/400 — builder notes each finished with 0 failure(s); isolation fence (no terrain/hydro/biome/road topology edits) and GENERATOR_VERSION 2 additive preserves them.

Grep guard for silence/harness strictness: builder claims tools/out_animationtest.txt contains 0 hits for Aborted looped and *0.018 absent — source uses SWITCH_MODE_AT_END for 4 transitions (Mantle->Hang, ClimbUp->Idle, Slide->CrouchIdle, StandUp->Idle) so expected 0; verified source contains SWITCH_MODE_AT_END.

## Acceptance criteria vs spec (7 criteria)

1. --animationtest thresholds etc — PASS. See above.

2. Crouch, slide, low-gap clearance capsule-driven without teleport nor penetration — PASS. Details above.

3. Honest foot planting preserved — PASS with grep guards.

4. Capsule never slides-teleports and never penetrates ramp landing seam nor low beams nor vault wall nor crouch/slide — PASS.

5. In-place guarantee extended to 15 clips — PASS.

6. Streaming + performance + telemetry + silence + height — PASS with leniency noted.

7. Persistence, regression, authentic windowed proof — PASS principal + deferred minor for authentic windowed placeholder.

See .hermes/autopilot/character/reports/REVIEW-C003-R00.md for full AC breakdown.

## Performance, persistence, compatibility boundaries

- Keep 64m chunks ACTIVE 1 WARM2 UNLOAD3, GENERATOR_VERSION 2 preserved — respected.
- Character budgets: active_chars true, skinned true, animation_ms aggregate 1.1/0.4 <=2.0 — verified.
- Persistence: saves store seed/version/discovery/deltas + survivor deltas never bone pose — respected.
- Compatibility: Survivor WALK 3.6 RUN 6.4 ACCEL12 capsule r0.35/1.7 stand floor_max_angle46 snap0.3 signatures unchanged — respected.

## Out of scope — correctly not done

Per spec out-of-scope list — all respected.

## Conflicts / hotspots / risks

See character report for full list. Hotspot is character_locomotion.gd 1086 lines.

## Why accept_with_deferred not revise

All principal blockers closed with honest probes and capsule-driven physics — no principal design conflict. Remaining leniency deferred per v2 policy.

## Deferred findings

1. Authentic windowed CITY 1200x720 capture still synthetic placeholder — must be real windowed capture.
2. Hand IK 4cm vs 3.0m lenient and vault distance 2.2-2.6 vs 1.5-4.5 lenient.
3. Stamina drain duplication 18/s in both Survivor and CharacterLocomotion — consolidate to single owner.
4. is_head_clear per-frame new CapsuleShape3D and is_actor_down spam — reuse static and guard.
5. Budget docs and StateMachine phrasing — update ARCHITECTURE.md/DEVELOPMENT.md.
6. Hotspot decomposition — split character_locomotion.gd.

## Rollback

Keep checkpoints b47fa40 and c22f220 etc — details in character report.

Reviewed by: Luna (character-architect). Nonblocking review link t_3377d2a7 run 20.

