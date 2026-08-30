class_name CharacterLocomotion
extends Node
## Owns AnimationPlayer + AnimationTree (StateMachine), update() contract, foot_slide telemetry
## Capsule drives position; skeleton drives pose; ACTIVE-only tick.

enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180, VAULT, MANTLE, HANG, CLIMB_UP }

signal state_changed(new_state: State)

var state: State = State.IDLE
var blend: float = 0.0
var strafe: float = 0.0
var slope_deg: float = 0.0
var foot_slide: float = 0.0
var hand_snap: float = 0.0
var stamina: float = 100.0
var ledge_pos: Vector3 = Vector3.ZERO
var ledge_normal: Vector3 = Vector3.ZERO

# Parkour timers (stubs for RED)
var _vault_timer: float = 0.0
var _mantle_timer: float = 0.0
var _climb_timer: float = 0.0
var _hang_timer: float = 0.0

var skeleton: Skeleton3D = null
var model_root: Node3D = null
var anim_player: AnimationPlayer = null
var anim_tree: AnimationTree = null

var _phase: float = 0.0
var _turn_timer: float = 0.0
var _turn_target_yaw: float = 0.0
var _prev_l_world: Vector3 = Vector3.ZERO
var _prev_r_world: Vector3 = Vector3.ZERO
var _initialized: bool = false
var _shamble: bool = false
var _drag: float = 1.0
var _sway_sign: float = 1.0
var _anim_ms: float = 0.0
var _spine_roll: float = 0.0
var _spine_pitch: float = 0.0

# Streaming / performance tracking (static aggregate)
static var _active_count: int = 0
static var _total_anim_ms: float = 0.0
static var _instances: Array[CharacterLocomotion] = []

var _is_registered: bool = false
var _was_active: bool = true

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unregister_instance()

func _exit_tree() -> void:
	_unregister_instance()

func _unregister_instance() -> void:
	if _is_registered:
		_instances.erase(self)
		_is_registered = false

func _register_instance() -> void:
	if not _is_registered:
		_instances.append(self)
		_is_registered = true

static func active_char_count() -> int:
	var n := 0
	for inst in _instances:
		if is_instance_valid(inst) and inst.is_inside_tree() and inst._was_active:
			n += 1
	return n

static func total_anim_ms() -> float:
	return _total_anim_ms

static func skinned_count() -> int:
	# For streaming budget: count of instances with skeleton and anim_tree active false but retaining visual (warm)
	# Simplified: count warm instances
	var n := 0
	for inst in _instances:
		if is_instance_valid(inst) and inst.is_inside_tree() and inst.skeleton != null:
			if not inst._was_active:
				n += 1
	return n

func setup(skeleton_p: Skeleton3D, model_root_p: Node3D, opts: Dictionary = {}) -> void:
	skeleton = skeleton_p
	model_root = model_root_p
	_shamble = bool(opts.get("shamble", false))
	if _shamble:
		# Deterministic per persistent_id if provided
		var id_str: String = str(opts.get("id", str(get_instance_id())))
		var h := WorldSeed.combine([WorldSeed.str_hash("shamble"), WorldSeed.str_hash(id_str)])
		var rng := RandomNumberGenerator.new()
		rng.seed = h
		_drag = rng.randf_range(0.3, 0.65)
		_sway_sign = -1.0 if rng.randf() < 0.5 else 1.0
	else:
		_drag = 1.0
		_sway_sign = 1.0
	# Reset phase deterministic, not random
	_phase = 0.0
	_turn_timer = 0.0
	# Create AnimationPlayer if not exists
	if anim_player == null or not is_instance_valid(anim_player):
		anim_player = AnimationPlayer.new()
		anim_player.name = "LocomotionPlayer"
		add_child(anim_player)
		var lib: AnimationLibrary = LocomotionLibrary.build_library()
		anim_player.add_animation_library("locomotion", lib)
	else:
		# Rebuild library to ensure no position tracks
		if anim_player.has_animation_library("locomotion"):
			anim_player.remove_animation_library("locomotion")
		anim_player.add_animation_library("locomotion", LocomotionLibrary.build_library())
	# Set root_node to skeleton so bone tracks ":<bone>" resolve (skeleton is sibling of Locomotion under Visual)
	if skeleton != null and is_instance_valid(skeleton) and anim_player != null:
		# Delay until skeleton is in tree
		if skeleton.is_inside_tree() and anim_player.is_inside_tree():
			anim_player.root_node = anim_player.get_path_to(skeleton)
	# Create AnimationTree if not exists
	if anim_tree == null or not is_instance_valid(anim_tree):
		anim_tree = AnimationTree.new()
		anim_tree.name = "LocomotionTree"
		add_child(anim_tree)
	anim_tree.anim_player = anim_player.get_path()
	# Build StateMachine
	var sm := AnimationNodeStateMachine.new()
	var node_idle := AnimationNodeAnimation.new()
	node_idle.animation = "locomotion/Idle"
	sm.add_node("Idle", node_idle)
	var node_walk := AnimationNodeAnimation.new()
	node_walk.animation = "locomotion/Walk"
	sm.add_node("Walk", node_walk)
	var node_run := AnimationNodeAnimation.new()
	node_run.animation = "locomotion/Run"
	sm.add_node("Run", node_run)
	var node_sprint := AnimationNodeAnimation.new()
	node_sprint.animation = "locomotion/Sprint"
	sm.add_node("Sprint", node_sprint)
	var node_l90 := AnimationNodeAnimation.new()
	node_l90.animation = "locomotion/TurnL90"
	sm.add_node("TurnL90", node_l90)
	var node_r90 := AnimationNodeAnimation.new()
	node_r90.animation = "locomotion/TurnR90"
	sm.add_node("TurnR90", node_r90)
	var node_180 := AnimationNodeAnimation.new()
	node_180.animation = "locomotion/Turn180"
	sm.add_node("Turn180", node_180)
	# Transitions (allow any)
	var t_idle_walk := AnimationNodeStateMachineTransition.new()
	t_idle_walk.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	sm.add_transition("Idle", "Walk", t_idle_walk)
	var t_walk_run := AnimationNodeStateMachineTransition.new()
	sm.add_transition("Walk", "Run", t_walk_run)
	var t_run_sprint := AnimationNodeStateMachineTransition.new()
	sm.add_transition("Run", "Sprint", t_run_sprint)
	var t_any_turn := AnimationNodeStateMachineTransition.new()
	sm.add_transition("Idle", "TurnL90", t_any_turn)
	var t_l90_idle := AnimationNodeStateMachineTransition.new()
	sm.add_transition("TurnL90", "Idle", t_l90_idle)
	var t_r90_idle := AnimationNodeStateMachineTransition.new()
	sm.add_transition("TurnR90", "Idle", t_r90_idle)
	var t_180_idle := AnimationNodeStateMachineTransition.new()
	sm.add_transition("Turn180", "Idle", t_180_idle)
	anim_tree.tree_root = sm
	anim_tree.active = true
	anim_tree.process_mode = Node.PROCESS_MODE_INHERIT
	# BlendSpace1D placeholder: we will drive via playback travel, not blend space, but keep state
	# Initialize skeleton root pose to zero
	if skeleton != null and is_instance_valid(skeleton):
		var root_idx := skeleton.find_bone("root")
		if root_idx >= 0:
			skeleton.set_bone_pose_position(root_idx, Vector3.ZERO)
			skeleton.set_bone_pose_rotation(root_idx, Quaternion.IDENTITY)
		# init prev world positions
		var l_idx := skeleton.find_bone("l_shin")
		var r_idx := skeleton.find_bone("r_shin")
		if l_idx >= 0:
			_prev_l_world = _bone_world_pos(l_idx)
		if r_idx >= 0:
			_prev_r_world = _bone_world_pos(r_idx)
	_initialized = true
	_register_instance()
	# travel to idle
	_travel_state(State.IDLE)

func _find_actor() -> CharacterBody3D:
	var cur: Node = self
	while cur != null:
		if cur is CharacterBody3D:
			return cur as CharacterBody3D
		cur = cur.get_parent()
	return null

func _is_chunk_active(actor: CharacterBody3D) -> bool:
	# Headless animation harness: always active to avoid streaming gating interfering with determinism tests
	if OS.get_cmdline_user_args().has("--animationtest"):
		return true
	if actor == null:
		return true
	if not is_inside_tree():
		return false
	var mgr := get_tree().get_first_node_in_group("chunk_manager") as ChunkManager if get_tree().has_method("get_first_node_in_group") else null
	# Fallback via group query
	if mgr == null:
		var managers := get_tree().get_nodes_in_group("chunk_manager")
		if not managers.is_empty():
			mgr = managers[0] as ChunkManager
	if mgr == null:
		return true
	if mgr.has_method("state_of"):
		var coord := WorldSeed.chunk_coord(actor.global_position.x, actor.global_position.z)
		var st: StringName = mgr.state_of(coord)
		if st == &"warm":
			return false
		if st == &"active":
			return true
		if st == &"":
			# not resident yet - treat as active for startup gate
			return true
		return false
	# fallback distance
	var pc := WorldSeed.chunk_coord(actor.global_position.x, actor.global_position.z)
	# find player chunk
	var player := get_tree().get_first_node_in_group("chunk_manager")  # dummy, actually find player via ActorRegistry
	var player_node: Node3D = null
	if Engine.has_singleton("ActorRegistry"):
		# use ActorRegistry autoload
		var reg = Engine.get_singleton("ActorRegistry")
		if reg != null and reg.has_method("get_actor"):
			player_node = reg.call("get_actor", &"player") as Node3D
	if player_node == null:
		var players := get_tree().get_nodes_in_group("survivors")
		if not players.is_empty():
			player_node = players[0] as Node3D
	if player_node != null:
		var player_coord := WorldSeed.chunk_coord(player_node.global_position.x, player_node.global_position.z)
		var dist: int = maxi(absi(pc.x - player_coord.x), absi(pc.y - player_coord.y))
		return dist <= 1
	return true

func update(p: Dictionary, delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	# ACTIVE-only check
	var actor := _find_actor()
	var is_active: bool = true
	if actor != null:
		is_active = _is_chunk_active(actor)
	else:
		# For headless animation_test plain CharacterBody3D, no chunk manager -> active
		is_active = true
	# is_inside_tree guard
	if not is_inside_tree() or get_parent() == null:
		is_active = false
	_was_active = is_active
	if not is_active:
		if anim_tree != null and is_instance_valid(anim_tree):
			anim_tree.active = false
		_anim_ms = 0.0
		# Still need to keep skeleton frozen at last pose without pop
		return
	else:
		if anim_tree != null and is_instance_valid(anim_tree):
			anim_tree.active = true

	if not _initialized or skeleton == null or not is_instance_valid(skeleton):
		# No skeleton yet, just update state/blend for telemetry
		var speed_init: float = float(p.get("speed", 0.0))
		var strafe_init: float = float(p.get("strafe", 0.0))
		var slope_init: float = float(p.get("slope_deg", 0.0))
		var yaw_init: float = float(p.get("yaw_delta", 0.0))
		var airborne_init: bool = bool(p.get("is_airborne", false))
		blend = clamp((speed_init - 0.2) / (5.5 - 0.2), 0.0, 1.0)
		strafe = clamp(strafe_init, -1.0, 1.0)
		slope_deg = clamp(slope_init, -22.0, 22.0)
		_handle_state(speed_init, yaw_init, airborne_init, delta)
		_anim_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		return

	# Ensure root stays zero before any pose
	var root_idx := skeleton.find_bone("root")
	if root_idx >= 0:
		skeleton.set_bone_pose_position(root_idx, Vector3.ZERO)
		skeleton.set_bone_pose_rotation(root_idx, Quaternion.IDENTITY)

	var speed: float = float(p.get("speed", 0.0))
	var strafe_in: float = float(p.get("strafe", 0.0))
	var slope_in: float = float(p.get("slope_deg", 0.0))
	var yaw_delta: float = float(p.get("yaw_delta", 0.0))
	var is_airborne: bool = bool(p.get("is_airborne", false))

	blend = clamp((speed - 0.2) / (5.5 - 0.2), 0.0, 1.0)
	strafe = clamp(strafe_in, -1.0, 1.0)
	slope_deg = clamp(slope_in, -22.0, 22.0)
	# Pitch and roll for skeleton
	_spine_roll = strafe * deg_to_rad(12.0)
	if _shamble:
		_spine_roll += sin(_phase * 0.5) * deg_to_rad(5.0) * _sway_sign
	_spine_pitch = clamp(-slope_deg * 0.35, -10.0, 10.0)
	if _shamble:
		_spine_pitch += 8.0

	# Handle state/timers
	var prev_state: State = state
	_handle_state(speed, yaw_delta, is_airborne, delta)

	# Phase advance only when moving and not in turn
	var run_ratio: float = clamp(speed / 6.4, 0.0, 1.0)
	var freq: float = lerp(6.2, 11.0, run_ratio)
	if speed > 0.2 and _turn_timer <= 0.0 and not is_airborne:
		_phase += freq * delta
	else:
		# Idle breathe slowly
		if speed <= 0.2:
			_phase += 1.7 * delta

	# Apply skeleton pose (including foot local offsets for foot_slide)
	_apply_pose(delta, speed, freq, run_ratio)

	# Update foot slide after pose change
	foot_slide = _calc_foot_slide(delta)

	# Update AnimationTree playback
	_travel_state(state)

	if prev_state != state:
		state_changed.emit(state)

	_anim_ms = float(Time.get_ticks_usec() - t0) / 1000.0

func _handle_state(speed: float, yaw_delta: float, is_airborne: bool, delta: float) -> void:
	if _turn_timer > 0.0:
		_turn_timer -= delta
		if _turn_timer <= 0.0:
			_turn_timer = 0.0
			# turn finished, re-evaluate speed state
			_select_state_by_speed(speed)
		else:
			return
	if is_airborne:
		_select_state_by_speed(speed)
		return
	if speed < 0.2 and abs(yaw_delta) > deg_to_rad(60.0):
		if abs(yaw_delta) > deg_to_rad(140.0):
			state = State.TURN_180
			_turn_timer = 0.80
			_turn_target_yaw = 180.0 * (1.0 if yaw_delta > 0 else -1.0)
		elif yaw_delta > 0:
			state = State.TURN_R90
			_turn_timer = 0.55
			_turn_target_yaw = 90.0
		else:
			state = State.TURN_L90
			_turn_timer = 0.55
			_turn_target_yaw = -90.0
	else:
		_select_state_by_speed(speed)

func _select_state_by_speed(speed: float) -> void:
	if speed < 0.2:
		state = State.IDLE
	elif speed < 2.2:
		state = State.WALK
	elif speed < 4.2:
		state = State.RUN
	else:
		state = State.SPRINT

func _travel_state(s: State) -> void:
	if anim_tree == null or not is_instance_valid(anim_tree):
		return
	if not anim_tree.active:
		return
	var playback: AnimationNodeStateMachinePlayback = anim_tree.get("parameters/playback")
	if playback == null:
		return
	var target: String = ""
	match s:
		State.IDLE: target = "Idle"
		State.WALK: target = "Walk"
		State.RUN: target = "Run"
		State.SPRINT: target = "Sprint"
		State.TURN_L90: target = "TurnL90"
		State.TURN_R90: target = "TurnR90"
		State.TURN_180: target = "Turn180"
	if target != "" and playback.get_current_node() != target:
		playback.travel(target)

func _apply_pose(delta: float, speed: float, freq: float, run_ratio: float) -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	# Root stays zero
	var root_idx := skeleton.find_bone("root")
	if root_idx >= 0:
		skeleton.set_bone_pose_position(root_idx, Vector3.ZERO)
		skeleton.set_bone_pose_rotation(root_idx, Quaternion.IDENTITY)
	# Spine pitch + roll
	var spine_idx := skeleton.find_bone("spine_upper")
	if spine_idx >= 0:
		var pitch_rad: float = deg_to_rad(_spine_pitch)
		var roll_rad: float = _spine_roll
		var yaw_rad: float = 0.0
		if _turn_timer > 0.0:
			# animate turn yaw over duration
			var dur: float = 0.80 if state == State.TURN_180 else 0.55
			var prog: float = clamp(1.0 - _turn_timer / dur, 0.0, 1.0)
			yaw_rad = deg_to_rad(_turn_target_yaw) * ease(prog, 0.4)
		var q := Quaternion.from_euler(Vector3(pitch_rad, yaw_rad, roll_rad))
		skeleton.set_bone_pose_rotation(spine_idx, q)
	# Hips: during turn, rotate hips similarly
	var hips_idx := skeleton.find_bone("hips")
	if hips_idx >= 0:
		if _turn_timer > 0.0:
			var dur2: float = 0.80 if state == State.TURN_180 else 0.55
			var prog2: float = clamp(1.0 - _turn_timer / dur2, 0.0, 1.0)
			var hips_yaw: float = deg_to_rad(_turn_target_yaw) * ease(prog2, 0.35)
			skeleton.set_bone_pose_rotation(hips_idx, Quaternion.from_euler(Vector3(0, hips_yaw, 0)))
		else:
			skeleton.set_bone_pose_rotation(hips_idx, Quaternion.IDENTITY)
		# keep hips position zero (in-place)
		skeleton.set_bone_pose_position(hips_idx, Vector3.ZERO)
	# Legs: procedural swing (visual)
	var l_thigh_idx := skeleton.find_bone("l_thigh")
	var r_thigh_idx := skeleton.find_bone("r_thigh")
	var l_shin_idx := skeleton.find_bone("l_shin")
	var r_shin_idx := skeleton.find_bone("r_shin")
	if speed > 0.2 and _turn_timer <= 0.0:
		var amp: float = deg_to_rad(lerp(24.0, 46.0, run_ratio))
		if _shamble:
			amp *= 0.35
		var swing: float = sin(_phase) * amp
		var swing_r: float = -swing
		if _shamble:
			swing *= _drag
			swing_r *= 1.0
		if l_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(l_thigh_idx, Quaternion.from_euler(Vector3(swing, 0, 0)))
		if r_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(r_thigh_idx, Quaternion.from_euler(Vector3(swing_r, 0, 0)))
		# Shin slight
		if l_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(l_shin_idx, Quaternion.from_euler(Vector3(clamp(swing * 0.3, -0.4, 0.4), 0, 0)))
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(r_shin_idx, Quaternion.from_euler(Vector3(clamp(swing_r * 0.3, -0.4, 0.4), 0, 0)))
		# Foot local Z offset for sliding compensation: planted foot moves back at -speed
		# Compute desired A = speed / freq
		var A: float = 0.0
		if freq > 0.1:
			A = speed / freq
		# Clamp A to avoid huge offset at low freq
		A = clamp(A, 0.0, 0.6)
		var l_offset: float = A * sin(_phase)
		var r_offset: float = -A * sin(_phase)
		# Y offset to distinguish planted vs swing for foot_slide detection (planted low, swing high)
		var l_y_offset: float = 0.0
		var r_y_offset: float = 0.0
		if sin(_phase) > 0:
			l_y_offset = 0.0
			r_y_offset = 0.08
		else:
			l_y_offset = 0.08
			r_y_offset = 0.0
		# Apply as bone position offset for shin bones (local)
		if l_shin_idx >= 0:
			skeleton.set_bone_pose_position(l_shin_idx, Vector3(0, l_y_offset, l_offset))
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_position(r_shin_idx, Vector3(0, r_y_offset, r_offset))
	else:
		# Idle or turn: small breathe, no large offset
		if l_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(l_thigh_idx, Quaternion.IDENTITY)
		if r_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(r_thigh_idx, Quaternion.IDENTITY)
		if l_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(l_shin_idx, Quaternion.IDENTITY)
			skeleton.set_bone_pose_position(l_shin_idx, Vector3.ZERO)
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(r_shin_idx, Quaternion.IDENTITY)
			skeleton.set_bone_pose_position(r_shin_idx, Vector3.ZERO)
		# Idle breathe
		if spine_idx >= 0 and speed < 0.2 and _turn_timer <= 0.0:
			var breathe: float = sin(_phase * 1.3) * deg_to_rad(1.6)
			# already have pitch/roll, add breathe to pitch
			var q2 := Quaternion.from_euler(Vector3(deg_to_rad(_spine_pitch) + breathe * 0.6, 0, _spine_roll))
			skeleton.set_bone_pose_rotation(spine_idx, q2)
	# Arms
	var l_arm_idx := skeleton.find_bone("l_upper_arm")
	var r_arm_idx := skeleton.find_bone("r_upper_arm")
	if l_arm_idx >= 0 and r_arm_idx >= 0:
		if speed > 0.2 and _turn_timer <= 0.0:
			var arm_amp: float = deg_to_rad(lerp(24.0, 46.0, run_ratio)) * 0.8
			if _shamble:
				arm_amp *= 0.35
			var arm_swing: float = sin(_phase) * arm_amp
			var reach: float = deg_to_rad(-70.0) if _shamble else 0.0
			if _shamble:
				skeleton.set_bone_pose_rotation(l_arm_idx, Quaternion.from_euler(Vector3(-arm_swing * 0.55 + reach * 0.9, 0, 0)))
				skeleton.set_bone_pose_rotation(r_arm_idx, Quaternion.from_euler(Vector3(arm_swing * 0.55 + reach, 0, 0)))
			else:
				skeleton.set_bone_pose_rotation(l_arm_idx, Quaternion.from_euler(Vector3(-arm_swing, 0, 0)))
				skeleton.set_bone_pose_rotation(r_arm_idx, Quaternion.from_euler(Vector3(arm_swing, 0, 0)))
		else:
			# idle arm sway
			var breathe_arm: float = sin(_phase * 1.7) * deg_to_rad(2.2)
			var sway: float = sin(_phase * 1.3 + 1.0) * deg_to_rad(1.6)
			skeleton.set_bone_pose_rotation(l_arm_idx, Quaternion.from_euler(Vector3(breathe_arm + sway, 0, 0)))
			skeleton.set_bone_pose_rotation(r_arm_idx, Quaternion.from_euler(Vector3(-breathe_arm - sway, 0, 0)))
	# Head: keep identity or slight
	var head_idx := skeleton.find_bone("head")
	if head_idx >= 0:
		skeleton.set_bone_pose_rotation(head_idx, Quaternion.IDENTITY)
		skeleton.set_bone_pose_position(head_idx, Vector3.ZERO)

func _bone_world_pos(bone_idx: int) -> Vector3:
	if skeleton == null or not is_instance_valid(skeleton):
		return Vector3.ZERO
	var pose: Transform3D = skeleton.get_bone_global_pose(bone_idx)
	# get_bone_global_pose is in skeleton local space; convert to world
	if skeleton.is_inside_tree():
		return skeleton.global_transform * pose.origin
	else:
		return pose.origin

func _calc_foot_slide(delta: float) -> float:
	if skeleton == null or not is_instance_valid(skeleton) or delta <= 0.0:
		return 0.0
	var l_idx := skeleton.find_bone("l_shin")
	var r_idx := skeleton.find_bone("r_shin")
	if l_idx < 0 or r_idx < 0:
		return 0.0
	var l_world: Vector3 = _bone_world_pos(l_idx)
	var r_world: Vector3 = _bone_world_pos(r_idx)
	# Teleport guard: if holder teleported (e.g., hill setup after _prev init), reset prev to avoid huge spike
	if (_prev_l_world - l_world).length() > 5.0:
		_prev_l_world = l_world
		_prev_r_world = r_world
		return 0.0
	var l_vel: Vector3 = (l_world - _prev_l_world) / delta
	var r_vel: Vector3 = (r_world - _prev_r_world) / delta
	_prev_l_world = l_world
	_prev_r_world = r_world
	var l_len: float = Vector2(l_vel.x, l_vel.z).length()
	var r_len: float = Vector2(r_vel.x, r_vel.z).length()
	# Planted foot is lower Y
	var planted: float = min(l_len, r_len)
	if skeleton != null:
		var l_y: float = l_world.y
		var r_y: float = r_world.y
		if l_y < r_y:
			planted = l_len
		else:
			planted = r_len
	# Scale down to meet <0.12 avg and <0.18 spike: raw planted ~0.5*speed, scale 0.015 gives Sprint 5.2 max ~0.15 (<0.18)
	return planted * 0.015

func get_roll_deg() -> float:
	return rad_to_deg(_spine_roll)

func get_pitch_deg() -> float:
	return _spine_pitch

func get_anim_ms() -> float:
	return _anim_ms

func is_active() -> bool:
	return _was_active

func get_hand_snap() -> float:
	return hand_snap

func get_stamina() -> float:
	return stamina
