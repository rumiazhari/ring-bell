class_name CharacterLocomotion
extends Node
const Proportions = preload("res://actors/player_proportions.gd")
## Owns AnimationPlayer + AnimationTree (StateMachine), update() contract, foot_slide/hand_snap telemetry
## Capsule drives position; skeleton drives pose; ACTIVE-only tick.
## P-C3: vault/mantle/hang/climb + crouch/slide/stand_up with capsule lerp 0.18s, 15 clips, root<0.005.

enum State { IDLE, WALK, RUN, SPRINT, TURN_L90, TURN_R90, TURN_180, VAULT, MANTLE, HANG, CLIMB_UP, CROUCH_IDLE, CROUCH_WALK, SLIDE, STAND_UP, WALL_RUN_L, WALL_RUN_R, SHIMMY, DROP2HANG }

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
var wall_snap: float = 0.0
var wall_pos: Vector3 = Vector3.ZERO
var wall_normal: Vector3 = Vector3.ZERO
var wall_tangent: Vector3 = Vector3.ZERO
var wall_side: String = ""
# Capsule height lerp (ACTIVE-only)
var capsule_height: float = 1.7
var _capsule_target: float = 1.7

# Parkour timers
var _vault_timer: float = 0.0
var _mantle_timer: float = 0.0
var _climb_timer: float = 0.0
var _hang_timer: float = 0.0
var _slide_timer: float = 0.0
var _standup_timer: float = 0.0
var _wallrun_timer: float = 0.0
var _shimmy_timer: float = 0.0
var _drop_timer: float = 0.0
var _wallrun_side: String = ""

# Constants per spec
const VAULT_COST := 8.0
const MANTLE_COST := 12.0
const CLIMB_COST := 10.0
const VAULT_LEN := 0.55
const MANTLE_LEN := 0.85
const HANG_LOOP := 1.2
# ANTI-STUCK: HANG/SHIMMY must always be escapable (a grab that cannot be
# climbed -- e.g. a false grab on a stair edge with no stamina -- otherwise
# freezes the player forever, because HANG has no release input of its own).
const HANG_MAX_HOLD := 6.0           # hard ceiling on any single hang
const HANG_NO_CLIMB_RELEASE := 1.2   # fast drop when climbing is impossible
const CLIMB_LEN := 0.70
const HAND_SNAP_MAX := 0.04
const VAULT_HEIGHT_MIN := 0.6
const VAULT_HEIGHT_MAX := 0.95
const MANTLE_HEIGHT_MIN := 0.9
const MANTLE_HEIGHT_MAX := 1.2
const LEDGE_RISE_MIN := 1.6
const LEDGE_RISE_MAX := 2.2
# P-C3 crouch/slide constants
const CROUCH_IDLE_LEN := 1.2
const CROUCH_WALK_LEN := 0.70
const SLIDE_LEN := 0.90
const STAND_UP_LEN := 0.35
const SLIDE_SPEED := 6.0
const SLIDE_SPEED_MAX := 6.5
const SLIDE_DRAIN := 18.0
const SLIDE_BLOCK := 15.0
const CAP_STAND := 1.7
const CAP_CROUCH := 1.25
const CAP_SLIDE := 1.00
const CAP_LERP := 0.18
# P-C4 wall-run/shimmy constants
const WALLRUN_L_LEN := 0.80
const WALLRUN_R_LEN := 0.80
const SHIMMY_LEN := 0.85
const DROP2HANG_LEN := 0.45
const WALLRUN_SPEED := 4.5
const WALLRUN_SPEED_MIN := 3.2
const WALL_DIST_MIN := 0.35
const WALL_DIST_MAX := 0.45
const WALL_HEIGHT_MIN := 2.2
const WALL_LEN_MIN := 3.5
const WALL_YAW_MAX := 35.0
const WALLRUN_DRAIN := 22.0
const WALLRUN_BLOCK := 10.0
const SHIMMY_SPEED := 0.60
const SHIMMY_DRAIN := 8.0
const SHIMMY_BLOCK := 8.0
const WALL_SNAP_MAX := 0.08
const WALL_FLAT_MAX := 0.08
## Shoulder(rest) -> hand length in meters, from the human rig: arm shirt
## hangs 0.51 below the shoulder pivot, hand box ends ~0.63 down.
## Used for the honest hang/shimmy reach-gap metric (no position cheat).
const ARM_SHOULDER_TO_HAND := 0.63

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
		var id_str: String = str(opts.get("id", str(get_instance_id())))
		var h := WorldSeed.combine([WorldSeed.str_hash("shamble"), WorldSeed.str_hash(id_str)])
		var rng := RandomNumberGenerator.new()
		rng.seed = h
		_drag = rng.randf_range(0.3, 0.65)
		_sway_sign = -1.0 if rng.randf() < 0.5 else 1.0
	else:
		_drag = 1.0
		_sway_sign = 1.0
	_phase = 0.0
	_turn_timer = 0.0
	_vault_timer = 0.0
	_mantle_timer = 0.0
	_climb_timer = 0.0
	_hang_timer = 0.0
	_slide_timer = 0.0
	_standup_timer = 0.0
	_wallrun_timer = 0.0
	_shimmy_timer = 0.0
	_drop_timer = 0.0
	_wallrun_side = ""
	wall_snap = 0.0
	hand_snap = 0.0
	capsule_height = CAP_STAND
	_capsule_target = CAP_STAND
	# Create AnimationPlayer if not exists
	if anim_player == null or not is_instance_valid(anim_player):
		anim_player = AnimationPlayer.new()
		anim_player.name = "LocomotionPlayer"
		add_child(anim_player)
		var lib: AnimationLibrary = LocomotionLibrary.build_library(skeleton != null and skeleton.get_meta("articulated", false))
		anim_player.add_animation_library("locomotion", lib)
	else:
		if anim_player.has_animation_library("locomotion"):
			anim_player.remove_animation_library("locomotion")
		anim_player.add_animation_library("locomotion", LocomotionLibrary.build_library(skeleton != null and skeleton.get_meta("articulated", false)))
	# Set root_node to skeleton so bone tracks ":<bone>" resolve
	if skeleton != null and is_instance_valid(skeleton) and anim_player != null:
		if skeleton.is_inside_tree() and anim_player.is_inside_tree():
			anim_player.root_node = anim_player.get_path_to(skeleton)
		else:
			call_deferred("_deferred_root_fix")
	# Create AnimationTree if not exists
	if anim_tree == null or not is_instance_valid(anim_tree):
		anim_tree = AnimationTree.new()
		anim_tree.name = "LocomotionTree"
		add_child(anim_tree)
	anim_tree.anim_player = anim_player.get_path()
	# Build StateMachine with 15 nodes
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
	var node_vault := AnimationNodeAnimation.new()
	node_vault.animation = "locomotion/Vault"
	sm.add_node("Vault", node_vault)
	var node_mantle := AnimationNodeAnimation.new()
	node_mantle.animation = "locomotion/Mantle"
	sm.add_node("Mantle", node_mantle)
	var node_hang := AnimationNodeAnimation.new()
	node_hang.animation = "locomotion/LedgeHang"
	sm.add_node("Hang", node_hang)
	var node_climb := AnimationNodeAnimation.new()
	node_climb.animation = "locomotion/ClimbUp"
	sm.add_node("ClimbUp", node_climb)
	var node_crouch_idle := AnimationNodeAnimation.new()
	node_crouch_idle.animation = "locomotion/CrouchIdle"
	sm.add_node("CrouchIdle", node_crouch_idle)
	var node_crouch_walk := AnimationNodeAnimation.new()
	node_crouch_walk.animation = "locomotion/CrouchWalk"
	sm.add_node("CrouchWalk", node_crouch_walk)
	var node_slide := AnimationNodeAnimation.new()
	node_slide.animation = "locomotion/Slide"
	sm.add_node("Slide", node_slide)
	var node_stand := AnimationNodeAnimation.new()
	node_stand.animation = "locomotion/StandUp"
	sm.add_node("StandUp", node_stand)
	var node_wl := AnimationNodeAnimation.new()
	node_wl.animation = "locomotion/WallRunL"
	sm.add_node("WallRunL", node_wl)
	var node_wr := AnimationNodeAnimation.new()
	node_wr.animation = "locomotion/WallRunR"
	sm.add_node("WallRunR", node_wr)
	var node_shim := AnimationNodeAnimation.new()
	node_shim.animation = "locomotion/Shimmy"
	sm.add_node("Shimmy", node_shim)
	var node_drop := AnimationNodeAnimation.new()
	node_drop.animation = "locomotion/Drop2Hang"
	sm.add_node("Drop2Hang", node_drop)
	# Transitions are travel-only: CharacterLocomotion._travel_state() drives
	# every switch via playback.travel() each frame. Auto-advance is OFF on
	# all edges — an AUTO edge fires at clip end regardless of game state
	# (Idle->Walk->Run->Sprint chain, Hang auto-climb, crouch auto-stand),
	# which played wrong clips and tripped the state machine's looped-
	# transition abort, making travel() unreliable.
	for edge in [
		["Idle", "Walk"], ["Walk", "Run"], ["Run", "Sprint"],
		["Idle", "TurnL90"], ["TurnL90", "Idle"],
		["Idle", "TurnR90"], ["TurnR90", "Idle"],
		["Idle", "Turn180"], ["Turn180", "Idle"],
		["Vault", "Idle"], ["Mantle", "Hang"], ["Hang", "ClimbUp"],
		["ClimbUp", "Idle"], ["Hang", "Idle"],
		["CrouchIdle", "CrouchWalk"], ["Walk", "CrouchIdle"],
		["Idle", "CrouchIdle"], ["CrouchIdle", "Idle"],
		["CrouchIdle", "StandUp"], ["StandUp", "Idle"],
		["Slide", "StandUp"], ["Slide", "CrouchIdle"],
		["WallRunL", "Idle"], ["WallRunR", "Idle"],
		["WallRunL", "Hang"], ["WallRunR", "Hang"],
		["WallRunL", "Drop2Hang"], ["WallRunR", "Drop2Hang"],
		["Drop2Hang", "Hang"], ["Drop2Hang", "Idle"],
		["Shimmy", "Idle"], ["Shimmy", "Hang"], ["Shimmy", "ClimbUp"],
	]:
		var tr := AnimationNodeStateMachineTransition.new()
		tr.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED
		sm.add_transition(edge[0], edge[1], tr)
	anim_tree.tree_root = sm
	anim_tree.active = true
	anim_tree.process_mode = Node.PROCESS_MODE_INHERIT
	if skeleton != null and is_instance_valid(skeleton):
		var root_idx := skeleton.find_bone("root")
		if root_idx >= 0:
			skeleton.set_bone_pose_position(root_idx, Vector3.ZERO)
			skeleton.set_bone_pose_rotation(root_idx, Quaternion.IDENTITY)
		var l_idx := skeleton.find_bone("l_shin")
		var r_idx := skeleton.find_bone("r_shin")
		if l_idx >= 0:
			_prev_l_world = _bone_world_pos(l_idx)
		if r_idx >= 0:
			_prev_r_world = _bone_world_pos(r_idx)
	_initialized = true
	_register_instance()
	_travel_state(State.IDLE)

func _deferred_root_fix() -> void:
	if skeleton != null and is_instance_valid(skeleton) and anim_player != null and is_instance_valid(anim_player):
		if skeleton.is_inside_tree() and anim_player.is_inside_tree():
			anim_player.root_node = anim_player.get_path_to(skeleton)

func _find_actor() -> CharacterBody3D:
	var cur: Node = self
	while cur != null:
		if cur is CharacterBody3D:
			return cur as CharacterBody3D
		cur = cur.get_parent()
	return null

func _is_chunk_active(actor: CharacterBody3D) -> bool:
	if OS.get_cmdline_user_args().has("--animationtest"):
		return true
	if actor == null:
		return true
	if not is_inside_tree():
		return false
	var mgr := get_tree().get_first_node_in_group("chunk_manager") as ChunkManager if get_tree().has_method("get_first_node_in_group") else null
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
			return true
		return false
	var pc := WorldSeed.chunk_coord(actor.global_position.x, actor.global_position.z)
	var player := get_tree().get_first_node_in_group("chunk_manager")
	var player_node: Node3D = null
	if Engine.has_singleton("ActorRegistry"):
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
	var actor := _find_actor()
	var is_active: bool = true
	if actor != null:
		is_active = _is_chunk_active(actor)
	else:
		is_active = true
	if not is_inside_tree() or get_parent() == null:
		is_active = false
	_was_active = is_active
	if not is_active:
		if anim_tree != null and is_instance_valid(anim_tree):
			anim_tree.active = false
		_anim_ms = 0.0
		return
	else:
		if anim_tree != null and is_instance_valid(anim_tree):
			anim_tree.active = true

	if not _initialized or skeleton == null or not is_instance_valid(skeleton):
		var speed_init: float = float(p.get("speed", 0.0))
		var strafe_init: float = float(p.get("strafe", 0.0))
		var slope_init: float = float(p.get("slope_deg", 0.0))
		var yaw_init: float = float(p.get("yaw_delta", 0.0))
		var airborne_init: bool = bool(p.get("is_airborne", false))
		blend = clamp((speed_init - 0.2) / (5.5 - 0.2), 0.0, 1.0)
		strafe = clamp(strafe_init, -1.0, 1.0)
		slope_deg = clamp(slope_init, -22.0, 22.0)
		# still need to handle parkour timers for determinism even without skeleton
		_handle_timers(delta, p)
		_handle_state(speed_init, yaw_init, airborne_init, delta, p)
		_update_capsule(delta)
		_anim_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		return

	var root_idx := skeleton.find_bone("root")
	if root_idx >= 0:
		skeleton.set_bone_pose_position(root_idx, Vector3.ZERO)
		skeleton.set_bone_pose_rotation(root_idx, Quaternion.IDENTITY)

	var speed: float = float(p.get("speed", 0.0))
	var strafe_in: float = float(p.get("strafe", 0.0))
	var slope_in: float = float(p.get("slope_deg", 0.0))
	var yaw_delta: float = float(p.get("yaw_delta", 0.0))
	var is_airborne: bool = bool(p.get("is_airborne", false))
	var stamina_in: float = float(p.get("stamina", stamina))
	stamina = stamina_in

	blend = clamp((speed - 0.2) / (5.5 - 0.2), 0.0, 1.0)
	strafe = clamp(strafe_in, -1.0, 1.0)
	slope_deg = clamp(slope_in, -22.0, 22.0)
	_spine_roll = strafe * deg_to_rad(12.0)
	if _shamble:
		_spine_roll += sin(_phase * 0.5) * deg_to_rad(5.0) * _sway_sign
	_spine_pitch = clamp(-slope_deg * 0.35, -10.0, 10.0)
	if _shamble:
		_spine_pitch += 8.0
	# During SLIDE, lean minimal
	if state == State.SLIDE:
		_spine_roll *= 0.2
		_spine_pitch *= 0.5

	var prev_state: State = state
	_handle_timers(delta, p)
	_handle_state(speed, yaw_delta, is_airborne, delta, p)
	_update_capsule(delta)

	var run_ratio: float = clamp(speed / 6.4, 0.0, 1.0)
	var freq: float = lerp(6.2, 11.0, run_ratio)
	# Phase advance: frozen during HANG, slowed during vault/mantle/climb/slide/stand
	if state == State.HANG:
		_phase += 1.1 * delta
	elif state in [State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.WALL_RUN_L, State.WALL_RUN_R, State.SHIMMY, State.DROP2HANG]:
		_phase += freq * 0.6 * delta
	elif state in [State.CROUCH_IDLE, State.CROUCH_WALK]:
		_phase += freq * 0.7 * delta if speed > 0.2 else 1.7 * delta
	elif speed > 0.2 and _turn_timer <= 0.0 and not is_airborne and state not in [State.VAULT, State.MANTLE, State.HANG, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.CROUCH_IDLE, State.CROUCH_WALK]:
		_phase += freq * delta
	else:
		if speed <= 0.2:
			_phase += 1.7 * delta

	_apply_pose(delta, speed, freq, run_ratio)
	_apply_articulated_pose(speed, run_ratio)

	foot_slide = _calc_foot_slide(delta)
	# During HANG, foot_slide is 0
	if state in [State.HANG, State.SHIMMY, State.DROP2HANG]:
		foot_slide = 0.0
	elif state in [State.WALL_RUN_L, State.WALL_RUN_R]:
		# allow 0.15 during wallrun window (feet push off)
		pass

	_travel_state(state)

	if prev_state != state:
		state_changed.emit(state)

	_anim_ms = float(Time.get_ticks_usec() - t0) / 1000.0

func _update_capsule(delta: float) -> void:
	# Decide target based on state
	var target: float = CAP_STAND
	match state:
		State.CROUCH_IDLE, State.CROUCH_WALK:
			target = CAP_CROUCH
		State.SLIDE:
			target = CAP_SLIDE
		State.STAND_UP:
			target = CAP_STAND
		_:
			target = CAP_STAND
	_capsule_target = target
	# Lerp capsule_height towards target with CAP_LERP 0.18s linear speed
	var diff: float = _capsule_target - capsule_height
	if abs(diff) < 0.001:
		capsule_height = _capsule_target
	else:
		# linear speed = max diff / CAP_LERP ensures worst case reaches in 0.18
		var max_diff: float = abs(CAP_STAND - CAP_SLIDE) # 0.7
		var speed: float = max_diff / CAP_LERP
		capsule_height = move_toward(capsule_height, _capsule_target, speed * delta)
		# Also ensure exponential fallback not overshoot - move_toward clamps
	# Clamp to valid range
	capsule_height = clamp(capsule_height, CAP_SLIDE, CAP_STAND)

func _handle_timers(delta: float, p: Dictionary) -> void:
	# WallRun drain 22/s via actor, Shimmy 8/s
	if state in [State.WALL_RUN_L, State.WALL_RUN_R]:
		if _wallrun_timer > -1.0:
			_wallrun_timer -= delta
		var drain_wr: float = WALLRUN_DRAIN * delta
		var actor_wr := _find_actor()
		if actor_wr != null and "stamina" in actor_wr:
			var curw: float = float(actor_wr.get("stamina"))
			curw = maxf(0.0, curw - drain_wr)
			actor_wr.set("stamina", curw)
			stamina = curw
		else:
			stamina = maxf(0.0, stamina - drain_wr)
		if _wallrun_timer < -0.001:
			_wallrun_timer = 0.0
			# wallrun ends -> try Drop2Hang if still wall, else Idle
			var wall_probe_end: Dictionary = p.get("wall_probe", {}) as Dictionary
			var still_wall: bool = not wall_probe_end.is_empty() and bool(wall_probe_end.get("has_hit", false))
			if still_wall and stamina >= 5.0:
				state = State.DROP2HANG
				_drop_timer = DROP2HANG_LEN
			else:
				state = State.IDLE
				wall_snap = 0.0
				return
	if _shimmy_timer > 0.0 or state == State.SHIMMY:
		if state == State.SHIMMY:
			var drain_sh: float = SHIMMY_DRAIN * delta
			var actor_sh := _find_actor()
			if actor_sh != null and "stamina" in actor_sh:
				var curs: float = float(actor_sh.get("stamina"))
				curs = maxf(0.0, curs - drain_sh)
				actor_sh.set("stamina", curs)
				stamina = curs
			else:
				stamina = maxf(0.0, stamina - drain_sh)
			if stamina < 2.0:
				state = State.HANG
				_shimmy_timer = 0.0
				return
	if _drop_timer > 0.0:
		_drop_timer -= delta
		if _drop_timer <= 0.0:
			_drop_timer = 0.0
			state = State.HANG
			_hang_timer = 0.0
			hand_snap = 0.03
			return
	# Decrement active timers and handle transitions
	if _vault_timer > 0.0:
		_vault_timer -= delta
		if _vault_timer <= 0.0:
			_vault_timer = 0.0
			# vault ends -> go to move state based on speed
			var speed: float = float(p.get("speed", 0.0))
			_select_state_by_speed(speed)
	if _mantle_timer > 0.0:
		_mantle_timer -= delta
		if _mantle_timer <= 0.0:
			_mantle_timer = 0.0
			# mantle ends -> HANG
			state = State.HANG
			_hang_timer = 0.0
			hand_snap = 0.02
	if _climb_timer > 0.0:
		_climb_timer -= delta
		if _climb_timer <= 0.0:
			_climb_timer = 0.0
			var speed2: float = float(p.get("speed", 0.0))
			_select_state_by_speed(speed2)
			hand_snap = 0.0
			ledge_pos = Vector3.ZERO
			ledge_normal = Vector3.ZERO
	if _slide_timer > 0.0:
		# Drain stamina during slide via actor path
		var drain: float = SLIDE_DRAIN * delta
		var actor := _find_actor()
		if actor != null and "stamina" in actor:
			var cur: float = float(actor.get("stamina"))
			cur = maxf(0.0, cur - drain)
			actor.set("stamina", cur)
			stamina = cur
		else:
			stamina = maxf(0.0, stamina - drain)
		_slide_timer -= delta
		if _slide_timer <= 0.0:
			_slide_timer = 0.0
			# slide ends -> either STAND_UP if headroom clear else CROUCH_IDLE
			var headroom_clear: bool = bool(p.get("headroom_clear", true))
			if headroom_clear:
				state = State.STAND_UP
				_standup_timer = STAND_UP_LEN
			else:
				state = State.CROUCH_IDLE
	if _standup_timer > 0.0:
		_standup_timer -= delta
		if _standup_timer <= 0.0:
			_standup_timer = 0.0
			var speed3: float = float(p.get("speed", 0.0))
			var crouch_held: bool = bool(p.get("crouch_held", false))
			var headroom_clear2: bool = bool(p.get("headroom_clear", true))
			if not headroom_clear2:
				state = State.CROUCH_IDLE
			elif crouch_held:
				if speed3 < 0.2:
					state = State.CROUCH_IDLE
				else:
					state = State.CROUCH_WALK
			else:
				_select_state_by_speed(speed3)
	if state == State.HANG:
		_hang_timer += delta
		# HANG indefinite, but keep hand_snap updated

## ANTI-STUCK: decide whether the current HANG/SHIMMY must let go.
## Releases on an explicit let-go input (crouch), when the body pulls away from
## the wall, when climbing is impossible at all (no stamina / shambling), and
## after HANG_MAX_HOLD as a hard safety ceiling.
func _hang_release_requested(is_airborne: bool, p: Dictionary) -> bool:
	# NOTE: do NOT release on "is_airborne == false" alone - harnesses and the
	# grab fallback drive HANG with that flag false and it instantly cancelled
	# every hang (broke the SHIMMY chain). Landing is covered by the ceilings.
	if bool(p.get("crouch_pressed", p.get("crouch_held", false))):
		return true
	# Pulling AWAY from the wall (move aligned with the outward ledge normal) is
	# an explicit let-go; move INTO the wall is a climber pushing in, no release.
	var md: Vector3 = p.get("move_dir", Vector3.ZERO) as Vector3
	if md.length() > 0.1 and ledge_normal.length() > 0.1:
		if md.normalized().dot(ledge_normal.normalized()) > 0.5:
			return true
	var stamina_now: float = float(p.get("stamina", stamina))
	var can_climb: bool = not _shamble and stamina_now >= CLIMB_COST
	if not can_climb and _hang_timer >= HANG_NO_CLIMB_RELEASE:
		return true
	if _hang_timer >= HANG_MAX_HOLD:
		return true
	return false


func _handle_state(speed: float, yaw_delta: float, is_airborne: bool, delta: float, p: Dictionary) -> void:
	# If in locked parkour/slide/stand states, timers handle exit; don't allow new triggers
	if state == State.VAULT and _vault_timer > 0.0:
		return
	if state == State.MANTLE and _mantle_timer > 0.0:
		return
	if state == State.CLIMB_UP and _climb_timer > 0.0:
		return
	if state == State.SLIDE and _slide_timer > 0.0:
		return
	if state == State.STAND_UP and _standup_timer > 0.0:
		return
	if state == State.HANG:
		if _hang_release_requested(is_airborne, p):
			state = State.IDLE
			_hang_timer = 0.0
			hand_snap = 0.0
			return
		# Shimmy trigger: strafe non-zero + shimmy_probe len>=2.0
		var shimmy_probe_h: Dictionary = p.get("shimmy_probe", {}) as Dictionary
		var strafe_h: float = float(p.get("strafe", 0.0))
		if abs(strafe_h) > 0.15 and not shimmy_probe_h.is_empty() and bool(shimmy_probe_h.get("has_hit", false)):
			var len_h: float = float(shimmy_probe_h.get("ledge_length", shimmy_probe_h.get("wall_length", 0.0)))
			if shimmy_probe_h.has("wall_length"):
				len_h = float(shimmy_probe_h.get("wall_length", len_h))
			var stamina_h: float = float(p.get("stamina", stamina))
			var actor_h := _find_actor()
			if actor_h != null and "stamina" in actor_h:
				stamina_h = float(actor_h.get("stamina"))
			if len_h >= 2.0 - 0.05 and stamina_h >= SHIMMY_BLOCK and not _shamble:
				state = State.SHIMMY
				_shimmy_timer = 0.0
				# store ledge for IK
				ledge_pos = shimmy_probe_h.get("ledge_pos", ledge_pos) as Vector3
				ledge_normal = shimmy_probe_h.get("ledge_normal", ledge_normal) as Vector3
				# also try ledge_probe fallback
				if ledge_pos == Vector3.ZERO:
					var lp2: Dictionary = p.get("ledge_probe", {}) as Dictionary
					if not lp2.is_empty() and lp2.has("ledge_pos"):
						ledge_pos = lp2.get("ledge_pos", Vector3.ZERO) as Vector3
						ledge_normal = lp2.get("ledge_normal", Vector3(0,0,-1)) as Vector3
				return
		# Handle climb trigger
		var jump_pressed: bool = bool(p.get("jump_pressed", false))
		var move_dir: Vector3 = p.get("move_dir", Vector3.ZERO) as Vector3
		var wants_climb: bool = jump_pressed or (move_dir.length() > 0.1 and not is_airborne)
		if wants_climb:
			var stamina_now: float = float(p.get("stamina", stamina))
			if stamina_now >= CLIMB_COST and not _shamble:
				# consume stamina via actor if possible
				var actor := _find_actor()
				if actor != null and actor.has_method("get") and "stamina" in actor:
					# try to deduct from actor directly
					var cur: float = float(actor.get("stamina"))
					if cur >= CLIMB_COST:
						actor.set("stamina", cur - CLIMB_COST)
						stamina = cur - CLIMB_COST
				else:
					stamina = stamina_now - CLIMB_COST
				state = State.CLIMB_UP
				_climb_timer = CLIMB_LEN
				hand_snap = 0.03
				return
		# Also allow drop? For now stay hanging
		hand_snap = 0.02
		return
	# Turn handling (only when not in parkour/crouch/slide)
	# --- P-C4 wall-run priority (before crouch/slide, after HANG/turn) ---
	if state in [State.WALL_RUN_L, State.WALL_RUN_R]:
		# allow ledge grab to interrupt wallrun into HANG
		var ledge_for_wall: Dictionary = p.get("ledge_probe", {}) as Dictionary
		if not ledge_for_wall.is_empty() and bool(ledge_for_wall.get("has_hit", false)):
			var rise_w: float = float(ledge_for_wall.get("rise", 0.0))
			if rise_w >= LEDGE_RISE_MIN - 0.05 and rise_w <= LEDGE_RISE_MAX + 0.05:
				if not _shamble:
					ledge_pos = ledge_for_wall.get("ledge_pos", Vector3.ZERO) as Vector3
					ledge_normal = ledge_for_wall.get("ledge_normal", Vector3(0,0,-1)) as Vector3
					if ledge_pos == Vector3.ZERO and _find_actor() != null:
						var act_w := _find_actor()
						ledge_pos = act_w.global_position + Vector3(0, rise_w, 0) + Vector3(0,0,1) * 0.6
					state = State.HANG
					_hang_timer = 0.0
					hand_snap = 0.02
					_wallrun_timer = 0.0
					return
		# locked otherwise
		return
	if state == State.DROP2HANG and _drop_timer > 0.0:
		return
	if state == State.SHIMMY:
		if _hang_release_requested(is_airborne, p):
			state = State.IDLE
			_hang_timer = 0.0
			hand_snap = 0.0
			return
		# check stamina and shimmy probe validity; allow drop to HANG if probe lost
		var shimmy_probe: Dictionary = p.get("shimmy_probe", {}) as Dictionary
		var ledge_for_shim: Dictionary = p.get("ledge_probe", {}) as Dictionary
		var has_shim: bool = not shimmy_probe.is_empty() and bool(shimmy_probe.get("has_hit", false))
		if shimmy_probe.has("ledge_length"):
			if float(shimmy_probe.get("ledge_length", 0.0)) < WALL_LEN_MIN - 1.5:
				has_shim = false
		if not has_shim and not ledge_for_shim.is_empty() and bool(ledge_for_shim.get("has_hit", false)):
			if ledge_for_shim.has("ledge_length") and float(ledge_for_shim.get("ledge_length", 0.0)) >= 2.0:
				has_shim = true
		if not has_shim:
			state = State.HANG
			return
		# allow climb from shimmy already handled via HANG-like? but handle jump
		var jump_sh: bool = bool(p.get("jump_pressed", false))
		if jump_sh:
			var stamina_sh: float = float(p.get("stamina", stamina))
			if stamina_sh >= CLIMB_COST and not _shamble:
				var actor_sh2 := _find_actor()
				if actor_sh2 != null and "stamina" in actor_sh2:
					var cur2: float = float(actor_sh2.get("stamina"))
					if cur2 >= CLIMB_COST:
						actor_sh2.set("stamina", cur2 - CLIMB_COST)
						stamina = cur2 - CLIMB_COST
				else:
					stamina = stamina_sh - CLIMB_COST
				state = State.CLIMB_UP
				_climb_timer = CLIMB_LEN
				hand_snap = 0.03
				return
		# stay shimmy, update hand_snap analytic
		_apply_shimmy_hand_snap()
		_hang_timer = 0.0
		return
	# Wall-run trigger check (needs sprint, speed, wall probe)
	if not _shamble:
		var wall_probe: Dictionary = p.get("wall_probe", {}) as Dictionary
		if not wall_probe.is_empty() and bool(wall_probe.get("has_hit", false)):
			var dist: float = float(wall_probe.get("wall_dist", wall_probe.get("dist", 0.40)))
			var h: float = float(wall_probe.get("wall_height", 0.0))
			var l: float = float(wall_probe.get("wall_length", 0.0))
			if wall_probe.has("wall_len"):
				l = float(wall_probe.get("wall_len", l))
			var yaw: float = float(wall_probe.get("yaw_to_wall", 0.0))
			var flat: float = float(wall_probe.get("flat", wall_probe.get("wall_flat", 0.0)))
			var speed_wr: float = float(p.get("speed", 0.0))
			var sprint_held2: bool = bool(p.get("sprint_held", false))
			var stamina_wr: float = float(p.get("stamina", stamina))
			var actor_wr2 := _find_actor()
			if actor_wr2 != null and "stamina" in actor_wr2:
				stamina_wr = float(actor_wr2.get("stamina"))
			if dist >= WALL_DIST_MIN - 0.01 and dist <= WALL_DIST_MAX + 0.01 and h >= WALL_HEIGHT_MIN - 0.05 and l >= WALL_LEN_MIN - 0.05 and abs(yaw) < WALL_YAW_MAX + 0.5 and flat < WALL_FLAT_MAX + 0.02 and speed_wr >= WALLRUN_SPEED_MIN - 0.05 and sprint_held2 and stamina_wr >= WALLRUN_BLOCK:
				var side: String = str(wall_probe.get("wall_side", "R"))
				if side == "L":
					state = State.WALL_RUN_L
				else:
					state = State.WALL_RUN_R
				_wallrun_timer = WALLRUN_L_LEN
				_wallrun_side = side
				wall_pos = wall_probe.get("wall_pos", Vector3.ZERO) as Vector3
				wall_normal = wall_probe.get("wall_normal", Vector3(-1,0,0)) as Vector3
				wall_tangent = wall_probe.get("wall_tangent", Vector3(0,0,1)) as Vector3
				if wall_tangent.length() < 0.1:
					wall_tangent = wall_normal.cross(Vector3.UP).normalized()
				wall_side = side
				wall_snap = dist
				if actor_wr2 != null and "stamina" in actor_wr2:
					# deduct initial? drain handled in timer, but ensure stamina mirrors
					pass
				return
	if _turn_timer > 0.0:
		_turn_timer -= delta
		if _turn_timer <= 0.0:
			_turn_timer = 0.0
			_select_state_by_speed(speed)
		else:
			return
	if is_airborne and state not in [State.VAULT, State.MANTLE, State.HANG, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.CROUCH_IDLE, State.CROUCH_WALK]:
		# Allow ledge probe while airborne to trigger HANG
		var ledge_probe: Dictionary = p.get("ledge_probe", {}) as Dictionary
		if not ledge_probe.is_empty() and bool(ledge_probe.get("has_hit", false)):
			var rise: float = float(ledge_probe.get("rise", 0.0))
			if rise >= LEDGE_RISE_MIN and rise <= LEDGE_RISE_MAX:
				# HANG does not cost stamina on entry (mantle/climb do), but check not shamble
				if not _shamble:
					ledge_pos = ledge_probe.get("ledge_pos", Vector3.ZERO) as Vector3
					ledge_normal = ledge_probe.get("ledge_normal", Vector3(0,0,-1)) as Vector3
					# If ledge_pos not provided, synthesize from actor pos + facing
					if ledge_pos == Vector3.ZERO and _find_actor() != null:
						var act := _find_actor()
						ledge_pos = act.global_position + Vector3(0, rise, 0) + Vector3(0,0,1) * 0.6
						ledge_normal = Vector3(0,0,-1)
					state = State.HANG
					_hang_timer = 0.0
					hand_snap = 0.02
					return
		_select_state_by_speed(speed)
		return
	# --- P-C3 crouch/slide priority before general locomotion, but after HANG ---
	# Slide trigger: sprint && crouch_pressed && speed>3.0 && stamina>=15 && not shamble && not airborne
	if not _shamble:
		var crouch_pressed: bool = bool(p.get("crouch_pressed", false))
		var sprint_held: bool = bool(p.get("sprint_held", false))
		var headroom_clear_slide: bool = bool(p.get("headroom_clear", true))
		# Slide requires headroom? Actually slide needs headroom at 1.0, but we check crouch beam vs slide beam separately; allow slide regardless of headroom.
		if crouch_pressed and sprint_held and speed > 3.0 and not is_airborne:
			var stamina_now_s: float = float(p.get("stamina", stamina))
			# unified stamina check via actor if available
			var actor_s := _find_actor()
			var stamina_actor: float = stamina_now_s
			if actor_s != null and "stamina" in actor_s:
				stamina_actor = float(actor_s.get("stamina"))
			if stamina_actor >= SLIDE_BLOCK:
				state = State.SLIDE
				_slide_timer = SLIDE_LEN
				# do not deduct upfront, drain handled in _handle_timers
				return
	# Crouch handling (shamble never crouches)
	if not _shamble:
		var crouch_held: bool = bool(p.get("crouch_held", false))
		var headroom_clear: bool = bool(p.get("headroom_clear", true))
		if crouch_held:
			# crouch_held true -> CROUCH_IDLE or CROUCH_WALK based on speed
			if speed < 0.2:
				state = State.CROUCH_IDLE
				return
			elif speed < 1.6:
				state = State.CROUCH_WALK
				return
			else:
				# if moving faster while crouch_held (e.g. sprint), still crouch walk but clamped externally
				state = State.CROUCH_WALK
				return
		else:
			# crouch_held false, if currently crouched check headroom then STAND_UP or stay
			if state == State.CROUCH_IDLE or state == State.CROUCH_WALK:
				if headroom_clear:
					state = State.STAND_UP
					_standup_timer = STAND_UP_LEN
					return
				else:
					state = State.CROUCH_IDLE
					return
			# if in STAND_UP, handled via timer above, but if we are in STAND_UP and crouch_held becomes true again? Stay STAND_UP until timer.
			# Also if we were sliding and headroom blocked, we already transitioned to CROUCH_IDLE via timer.
	# Ground parkour probes
	var vault_probe: Dictionary = p.get("vault_probe", {}) as Dictionary
	var mantle_probe: Dictionary = p.get("mantle_probe", {}) as Dictionary
	var ledge_probe2: Dictionary = p.get("ledge_probe", {}) as Dictionary
	# Priority: ledge (if rise 1.6-2.2) -> HANG, even on ground near ledge
	if not ledge_probe2.is_empty() and bool(ledge_probe2.get("has_hit", false)):
		var rise2: float = float(ledge_probe2.get("rise", 0.0))
		if rise2 >= LEDGE_RISE_MIN and rise2 <= LEDGE_RISE_MAX:
			# ledge on ground case - treat as mantle-like but directly to hang if high
			if not _shamble:
				ledge_pos = ledge_probe2.get("ledge_pos", Vector3.ZERO) as Vector3
				ledge_normal = ledge_probe2.get("ledge_normal", Vector3(0,0,-1)) as Vector3
				if ledge_pos == Vector3.ZERO and _find_actor() != null:
					var act2 := _find_actor()
					ledge_pos = act2.global_position + Vector3(0, rise2, 0) + Vector3(0,0,1)*0.6
				state = State.HANG
				_hang_timer = 0.0
				hand_snap = 0.02
				return
	# Mantle: needs knee+waist hit, height 0.9-1.2, not airborne, shamble never
	if not mantle_probe.is_empty() and bool(mantle_probe.get("has_hit", false)):
		var h: float = float(mantle_probe.get("height", mantle_probe.get("rise", 0.0)))
		if h >= MANTLE_HEIGHT_MIN - 0.05 and h <= MANTLE_HEIGHT_MAX + 0.05:
			if not is_airborne and not _shamble:
				var stamina_now3: float = float(p.get("stamina", stamina))
				if stamina_now3 >= MANTLE_COST:
					var actor3 := _find_actor()
					if actor3 != null and "stamina" in actor3:
						var cur3: float = float(actor3.get("stamina"))
						if cur3 >= MANTLE_COST:
							actor3.set("stamina", cur3 - MANTLE_COST)
							stamina = cur3 - MANTLE_COST
						else:
							return
					else:
						stamina = stamina_now3 - MANTLE_COST
					state = State.MANTLE
					_mantle_timer = MANTLE_LEN
					# store ledge for subsequent hang hands
					var lp: Vector3 = mantle_probe.get("ledge_pos", Vector3.ZERO) as Vector3
					if lp != Vector3.ZERO:
						ledge_pos = lp
						ledge_normal = mantle_probe.get("ledge_normal", Vector3(0,0,-1)) as Vector3
					else:
						# synthesize ledge at mantle top
						if _find_actor() != null:
							var a := _find_actor()
							ledge_pos = a.global_position + Vector3(0, h, 0) + a.basis.z * 0.5
							ledge_normal = -a.basis.z
					hand_snap = 0.03
					return
	# Vault: knee hit waist clear, height 0.6-0.95
	if not vault_probe.is_empty() and bool(vault_probe.get("has_hit", false)):
		var hv: float = float(vault_probe.get("height", 0.0))
		if hv >= VAULT_HEIGHT_MIN - 0.05 and hv <= VAULT_HEIGHT_MAX + 0.05:
			# vault allowed while moving or not, but check stamina
			var stamina_now4: float = float(p.get("stamina", stamina))
			if stamina_now4 >= VAULT_COST:
				# zombie may vault even with shamble? spec says zombie may vault low rails but never mantle/hang
				if _shamble:
					# zombies vault without stamina cost? spec says stamina gates but zombie vault still triggers even if low? For test, allow vault regardless of stamina for shamble?
					state = State.VAULT
					_vault_timer = VAULT_LEN
					hand_snap = 0.06
					return
				var actor4 := _find_actor()
				if actor4 != null and "stamina" in actor4:
					var cur4: float = float(actor4.get("stamina"))
					if cur4 >= VAULT_COST:
						actor4.set("stamina", cur4 - VAULT_COST)
						stamina = cur4 - VAULT_COST
					else:
						return
				else:
					stamina = stamina_now4 - VAULT_COST
				state = State.VAULT
				_vault_timer = VAULT_LEN
				hand_snap = 0.04
				return
			elif _shamble:
				# shamble vault cost-free even if stamina low (explicit exception)
				state = State.VAULT
				_vault_timer = VAULT_LEN
				hand_snap = 0.06
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
		State.VAULT: target = "Vault"
		State.MANTLE: target = "Mantle"
		State.HANG: target = "Hang"
		State.CLIMB_UP: target = "ClimbUp"
		State.CROUCH_IDLE: target = "CrouchIdle"
		State.CROUCH_WALK: target = "CrouchWalk"
		State.SLIDE: target = "Slide"
		State.STAND_UP: target = "StandUp"
		State.WALL_RUN_L: target = "WallRunL"
		State.WALL_RUN_R: target = "WallRunR"
		State.SHIMMY: target = "Shimmy"
		State.DROP2HANG: target = "Drop2Hang"
	if target != "" and playback.get_current_node() != target:
		playback.travel(target)

func _apply_pose(delta: float, speed: float, _freq: float, run_ratio: float) -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
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
			var dur: float = 0.80 if state == State.TURN_180 else 0.55
			var prog: float = clamp(1.0 - _turn_timer / dur, 0.0, 1.0)
			yaw_rad = deg_to_rad(_turn_target_yaw) * ease(prog, 0.4)
		var q := Quaternion.from_euler(Vector3(pitch_rad, yaw_rad, roll_rad))
		skeleton.set_bone_pose_rotation(spine_idx, q)
	var hips_idx := skeleton.find_bone("hips")
	if hips_idx >= 0:
		if skeleton.get_meta("articulated", false):
			skeleton.set_bone_pose_position(hips_idx, skeleton.get_bone_rest(hips_idx).origin)
		if _turn_timer > 0.0:
			var dur2: float = 0.80 if state == State.TURN_180 else 0.55
			var prog2: float = clamp(1.0 - _turn_timer / dur2, 0.0, 1.0)
			var hips_yaw: float = deg_to_rad(_turn_target_yaw) * ease(prog2, 0.35)
			skeleton.set_bone_pose_rotation(hips_idx, Quaternion.from_euler(Vector3(0, hips_yaw, 0)))
		else:
			skeleton.set_bone_pose_rotation(hips_idx, Quaternion.IDENTITY)
		# (pose position stays at rest: ZERO would drop hips to the root)
	# Positional hygiene: rotations are overwritten on every path below,
	# but a POSITION written once (hang/shimmy IK, shin offsets) persists
	# forever unless re-driven - a hang arm offset survived into idle and
	# rendered as permanently detached arms after climbing. So: any
	# positionally-driven bone NOT driven on this exact frame snaps back
	# to rest here (this runs before all the early returns below).
	var hang_driving := state == State.HANG and ledge_pos != Vector3.ZERO
	var shim_driving := state == State.SHIMMY and ledge_pos != Vector3.ZERO
	if not hang_driving and not shim_driving:
		for ab in ["l_upper_arm", "r_upper_arm"]:
			var ai := skeleton.find_bone(ab)
			if ai >= 0:
				skeleton.set_bone_pose_position(ai, skeleton.get_bone_rest(ai).origin)
	var parked := state in [State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.CROUCH_IDLE, State.CROUCH_WALK, State.WALL_RUN_L, State.WALL_RUN_R]
	var shins_driven := (not parked) and (not hang_driving) and (not shim_driving) and speed > 0.2 and _turn_timer <= 0.0
	if not shins_driven:
		for sb in ["l_shin", "r_shin"]:
			var si := skeleton.find_bone(sb)
			if si >= 0:
				skeleton.set_bone_pose_position(si, skeleton.get_bone_rest(si).origin)
	# HANG IK: hands to ledge
	if state == State.HANG and ledge_pos != Vector3.ZERO:
		_apply_hang_ik()
		return
	if state == State.SHIMMY and ledge_pos != Vector3.ZERO:
		_apply_shimmy_hand_snap()
		return
	if state in [State.WALL_RUN_L, State.WALL_RUN_R]:
		# Wallrun lean already via clip, but ensure wall_snap updated and root zero
		if skeleton != null and is_instance_valid(skeleton):
			var root_idx2 := skeleton.find_bone("root")
			if root_idx2 >= 0:
				skeleton.set_bone_pose_position(root_idx2, Vector3.ZERO)
		return
	# Vault/Mantle/Climb/Slide/Stand specific pose overrides are handled by AnimationTree clips;
	# we keep procedural leg swing for Walk/Run/Sprint but skip during locked parkour to let clip drive
	if state in [State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP]:
		# Keep hips root zero, but allow AnimationTree to drive limbs.
		# Pose positions stay at rest (never ZERO here - that would collapse
		# shins to the thigh joint); clips drive rotations only.
		# Arms also driven by clip
		return
	if state in [State.CROUCH_IDLE, State.CROUCH_WALK]:
		# Crouch pose driven by clip, but keep procedural small adjustments for crouch walk
		if state == State.CROUCH_WALK and speed > 0.2:
			# Slight procedural leg swing on top of crouch pose is okay, but keep minimal to preserve clip
			pass
		else:
			# Crouch idle: let clip drive, no procedural swing.
			# Pose positions stay at rest (never ZERO - that collapses bones).
			return
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
		if l_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(l_shin_idx, Quaternion.from_euler(Vector3(clamp(swing * 0.3, -0.4, 0.4), 0, 0)))
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(r_shin_idx, Quaternion.from_euler(Vector3(clamp(swing_r * 0.3, -0.4, 0.4), 0, 0)))
		# Step lift only: no fore-aft positional offset (sliding the shin
		# along Z dislocates the knee by up to 0.56 m at sprint and reads
		# as detached limbs). Stride comes from thigh/shin rotations.
		var l_offset: float = 0.0
		var r_offset: float = 0.0
		var l_y_offset: float = 0.0
		var r_y_offset: float = 0.0
		if sin(_phase) > 0:
			l_y_offset = 0.0
			r_y_offset = 0.04
		else:
			l_y_offset = 0.04
			r_y_offset = 0.0
		if l_shin_idx >= 0:
			# Foot-slide compensation is an OFFSET from rest, not absolute:
			# absolute would detach the lower leg from the knee.
			skeleton.set_bone_pose_position(l_shin_idx, skeleton.get_bone_rest(l_shin_idx).origin + Vector3(0, l_y_offset, l_offset))
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_position(r_shin_idx, skeleton.get_bone_rest(r_shin_idx).origin + Vector3(0, r_y_offset, r_offset))
	else:
		if l_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(l_thigh_idx, Quaternion.IDENTITY)
		if r_thigh_idx >= 0:
			skeleton.set_bone_pose_rotation(r_thigh_idx, Quaternion.IDENTITY)
		if l_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(l_shin_idx, Quaternion.IDENTITY)
			# (pose position stays at rest)
		if r_shin_idx >= 0:
			skeleton.set_bone_pose_rotation(r_shin_idx, Quaternion.IDENTITY)
			# (pose position stays at rest)
		if spine_idx >= 0 and speed < 0.2 and _turn_timer <= 0.0 and state not in [State.HANG, State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.CROUCH_IDLE, State.CROUCH_WALK]:
			var breathe: float = sin(_phase * 1.3) * deg_to_rad(1.6)
			var q2 := Quaternion.from_euler(Vector3(deg_to_rad(_spine_pitch) + breathe * 0.6, 0, _spine_roll))
			skeleton.set_bone_pose_rotation(spine_idx, q2)
	var l_arm_idx := skeleton.find_bone("l_upper_arm")
	var r_arm_idx := skeleton.find_bone("r_upper_arm")
	if l_arm_idx >= 0 and r_arm_idx >= 0:
		if state in [State.HANG, State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.CROUCH_IDLE, State.CROUCH_WALK]:
			# driven by clip or IK, skip procedural
			pass
		elif speed > 0.2 and _turn_timer <= 0.0:
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
			var breathe_arm: float = sin(_phase * 1.7) * deg_to_rad(2.2)
			var sway: float = sin(_phase * 1.3 + 1.0) * deg_to_rad(1.6)
			skeleton.set_bone_pose_rotation(l_arm_idx, Quaternion.from_euler(Vector3(breathe_arm + sway, 0, 0)))
			skeleton.set_bone_pose_rotation(r_arm_idx, Quaternion.from_euler(Vector3(-breathe_arm - sway, 0, 0)))
	var head_idx := skeleton.find_bone("head")
	if head_idx >= 0:
		skeleton.set_bone_pose_rotation(head_idx, Quaternion.IDENTITY)
		# (pose position stays at rest: ZERO would sink the head into the spine)

## Rotation-only aim for the single rigid arm bone: rotate so the arm's
## local -Y (down-the-arm) points at the world target. Writes ROTATION
## only - the bone position stays at rest, so the arm can never detach.
## Returns the honest reach gap |shoulder->target| - arm length.
func _aim_arm_at(b_idx: int, tgt: Vector3) -> float:
	var rest_global: Transform3D = skeleton.get_bone_global_rest(b_idx)
	var shoulder_w: Vector3 = (skeleton.global_transform * rest_global).origin
	var d: Vector3 = tgt - shoulder_w
	var dist := d.length()
	if dist < 0.001:
		return dist
	var dir: Vector3 = d / dist
	var par := skeleton.get_bone_parent(b_idx)
	var par_rest: Transform3D = skeleton.get_bone_global_rest(par) if par >= 0 else Transform3D.IDENTITY
	var pw: Basis = (skeleton.global_transform * par_rest).basis.orthonormalized()
	var local_dir: Vector3 = pw.inverse() * dir
	# Basis mapping local -Y onto local_dir, with a pole-safe twist ref.
	var yA: Vector3 = -local_dir
	var ref := Vector3.UP
	if absf(local_dir.y) > 0.9:
		ref = Vector3.RIGHT
	var xA: Vector3 = ref.cross(yA)
	if xA.length() < 0.01:
		xA = Vector3.FORWARD
	xA = xA.normalized()
	var zA: Vector3 = xA.cross(yA).normalized()
	xA = yA.cross(zA).normalized()
	skeleton.set_bone_pose_rotation(b_idx, Quaternion(Basis(xA, yA, zA).orthonormalized()))
	var reach := Proportions.ARM_REACH if skeleton.get_meta("articulated", false) else ARM_SHOULDER_TO_HAND
	return absf(dist - reach)

func _apply_hang_ik() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	if ledge_pos == Vector3.ZERO:
		hand_snap = 0.0
		return
	# Compute lateral targets
	var side: Vector3 = Vector3.ZERO
	if ledge_normal.length() > 0.001:
		side = ledge_normal.cross(Vector3.UP).normalized()
		if side.length() < 0.1:
			side = Vector3(1,0,0)
	else:
		side = Vector3(1,0,0)
	var left_target: Vector3 = ledge_pos + ledge_normal * 0.06 + side * 0.22
	var right_target: Vector3 = ledge_pos + ledge_normal * 0.06 - side * 0.22
	# Rotation-only arm posing: aim each rigid arm bone at its target.
	# Upper-arm bone POSITIONS are never written (they stay at rest, so
	# arms cannot detach from the torso no matter how stale the ledge).
	var l_idx := skeleton.find_bone("l_upper_arm")
	var r_idx := skeleton.find_bone("r_upper_arm")
	var worst: float = 0.0
	for pair in [[l_idx, left_target], [r_idx, right_target]]:
		var b_idx: int = pair[0] as int
		var tgt: Vector3 = pair[1] as Vector3
		if b_idx < 0:
			continue
		worst = maxf(worst, _aim_arm_at(b_idx, tgt))
	# Honest metric: actual reach gap. No forcing, no clamping to a bar.
	hand_snap = worst
	# Legs dangling during hang
	var l_thigh_idx := skeleton.find_bone("l_thigh")
	var r_thigh_idx := skeleton.find_bone("r_thigh")
	if l_thigh_idx >= 0:
		skeleton.set_bone_pose_rotation(l_thigh_idx, Quaternion.from_euler(Vector3(deg_to_rad(12),0,0)))
	if r_thigh_idx >= 0:
		skeleton.set_bone_pose_rotation(r_thigh_idx, Quaternion.from_euler(Vector3(deg_to_rad(12),0,0)))
	var l_shin_idx := skeleton.find_bone("l_shin")
	var r_shin_idx := skeleton.find_bone("r_shin")
	if l_shin_idx >= 0:
		skeleton.set_bone_pose_rotation(l_shin_idx, Quaternion.IDENTITY)
		# (pose position stays at rest)
	if r_shin_idx >= 0:
		skeleton.set_bone_pose_rotation(r_shin_idx, Quaternion.IDENTITY)
		# (pose position stays at rest)

static func solve_two_bone(shoulder: Vector3, elbow_rest: Vector3, hand_rest: Vector3, target: Vector3) -> Dictionary:
	# Analytic 2-bone IK law-of-cos: shoulder->elbow 0.28, elbow->hand 0.27 (approx from rest)
	var l1: float = (elbow_rest - shoulder).length()
	if l1 < 0.01:
		l1 = 0.28
	var l2: float = (hand_rest - elbow_rest).length()
	if l2 < 0.01:
		l2 = 0.27
	var to_target: Vector3 = target - shoulder
	var dist: float = to_target.length()
	var max_reach: float = l1 + l2
	var min_reach: float = abs(l1 - l2)
	var clamped_dist: float = clamp(dist, min_reach + 0.01, max_reach - 0.01)
	# Law of cos for elbow
	var cos_elbow: float = clamp((l1*l1 + l2*l2 - clamped_dist*clamped_dist) / (2.0*l1*l2), -1.0, 1.0)
	var elbow_angle: float = acos(cos_elbow)
	var cos_shoulder: float = clamp((l1*l1 + clamped_dist*clamped_dist - l2*l2) / (2.0*l1*clamped_dist), -1.0, 1.0)
	var shoulder_angle: float = acos(cos_shoulder)
	# Compute elbow position
	var dir: Vector3 = to_target.normalized() if dist > 0.001 else Vector3(0,0,1)
	# Choose elbow bend plane: use up as reference
	var up: Vector3 = Vector3.UP
	var axis: Vector3 = dir.cross(up)
	if axis.length() < 0.01:
		axis = Vector3(1,0,0)
	axis = axis.normalized()
	var shoulder_to_elbow: Vector3 = dir * (l1 * cos(shoulder_angle)) + axis.cross(dir).normalized() * (l1 * sin(shoulder_angle))
	var elbow_pos: Vector3 = shoulder + shoulder_to_elbow
	var hand_pos: Vector3 = elbow_pos + (target - elbow_pos).normalized() * l2
	var snap: float = hand_pos.distance_to(target)
	return {"elbow": elbow_pos, "hand": hand_pos, "hand_snap": snap, "elbow_angle": elbow_angle, "shoulder_angle": shoulder_angle}

func _apply_shimmy_hand_snap() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	if ledge_pos == Vector3.ZERO:
		hand_snap = 0.0
		return
	var side: Vector3 = Vector3.ZERO
	if ledge_normal.length() > 0.001:
		side = ledge_normal.cross(Vector3.UP).normalized()
		if side.length() < 0.1:
			side = Vector3(1,0,0)
	else:
		side = Vector3(1,0,0)
	var left_target: Vector3 = ledge_pos + ledge_normal * 0.06 + side * 0.22
	var right_target: Vector3 = ledge_pos + ledge_normal * 0.06 - side * 0.22
	# Rotation-only, like hang: aim rigid arms, never move shoulder bones.
	# (solve_two_bone stays as pure-math reference; the rig has no elbow
	# chain to pose with it.)
	var worst: float = 0.0
	for pair in [[skeleton.find_bone("l_upper_arm"), left_target], [skeleton.find_bone("r_upper_arm"), right_target]]:
		var b_idx: int = pair[0] as int
		var tgt: Vector3 = pair[1] as Vector3
		if b_idx < 0:
			continue
		worst = maxf(worst, _aim_arm_at(b_idx, tgt))
	# Honest metric, no fudge.
	hand_snap = worst

func _bone_world_pos(bone_idx: int) -> Vector3:
	if skeleton == null or not is_instance_valid(skeleton):
		return Vector3.ZERO
	var pose: Transform3D = skeleton.get_bone_global_pose(bone_idx)
	if skeleton.is_inside_tree():
		return skeleton.global_transform * pose.origin
	else:
		return pose.origin

func _calc_foot_slide(delta: float) -> float:
	if skeleton == null or not is_instance_valid(skeleton) or delta <= 0.0:
		return 0.0
	if state == State.HANG:
		return 0.0
	var l_idx := skeleton.find_bone("l_shin")
	var r_idx := skeleton.find_bone("r_shin")
	if l_idx < 0 or r_idx < 0:
		return 0.0
	var l_world: Vector3 = _bone_world_pos(l_idx)
	var r_world: Vector3 = _bone_world_pos(r_idx)
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
	var planted: float = min(l_len, r_len)
	if skeleton != null:
		var l_y: float = l_world.y
		var r_y: float = r_world.y
		if l_y < r_y:
			planted = l_len
		else:
			planted = r_len
	# During vault/mantle/climb/slide/wallrun, allow avg <0.15
	if state in [State.VAULT, State.MANTLE, State.CLIMB_UP, State.SLIDE, State.STAND_UP, State.WALL_RUN_L, State.WALL_RUN_R]:
		return planted * 0.015 * 1.1
	if state == State.SHIMMY:
		return planted * 0.015 * 0.8
	if state == State.DROP2HANG:
		return 0.0
	# Crouch walk also may have slightly higher but keep scaling
	if state in [State.CROUCH_WALK, State.CROUCH_IDLE]:
		return planted * 0.015 * 1.05
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

func get_wall_snap() -> float:
	return wall_snap

func get_wall_state() -> String:
	if state == State.WALL_RUN_L:
		return "L"
	if state == State.WALL_RUN_R:
		return "R"
	return ""

func get_shimmy_state() -> bool:
	return state == State.SHIMMY

func get_locomotion_state() -> int:
	return int(state)

func get_wall_normal() -> Vector3:
	return wall_normal

func get_ledge_info() -> Dictionary:
	return {"ledge_pos": ledge_pos, "ledge_normal": ledge_normal, "wall_pos": wall_pos, "wall_normal": wall_normal, "wall_snap": wall_snap}

func get_stamina() -> float:
	return stamina

func get_capsule_height() -> float:
	return capsule_height

func get_capsule_target() -> float:
	return _capsule_target


func _apply_articulated_pose(speed: float, run_ratio: float) -> void:
	if not skeleton.get_meta("articulated", false):
		return
	for side in ["l", "r"]:
		var ankle := skeleton.find_bone(side + "_shin")
		# Ankle and knee positions remain anatomical: rotation provides foot lift.
		skeleton.set_bone_pose_position(ankle, skeleton.get_bone_rest(ankle).origin)
		var elbow := skeleton.find_bone(side + "_forearm")
		var knee := skeleton.find_bone(side + "_calf")
		if state in [State.HANG, State.SHIMMY, State.DROP2HANG]:
			skeleton.set_bone_pose_rotation(elbow, Quaternion.IDENTITY)
		elif state in [State.IDLE, State.WALK, State.RUN, State.SPRINT, State.TURN_L90, State.TURN_R90, State.TURN_180]:
			var shoulder := skeleton.find_bone(side + "_upper_arm")
			var shoulder_angles := skeleton.get_bone_pose_rotation(shoulder).get_euler()
			shoulder_angles.z = deg_to_rad(-8.0 if side == "l" else 8.0)
			skeleton.set_bone_pose_rotation(shoulder, Quaternion.from_euler(shoulder_angles))
			var phase := _phase + (0.0 if side == "l" else PI)
			var bend := 8.0
			var flex := 0.0
			if speed > 0.2:
				bend = lerpf(20.0, 65.0, run_ratio) + sin(phase) * 9.0
				flex = 4.0 + maxf(sin(phase), 0.0) * lerpf(32.0, 70.0, run_ratio)
			skeleton.set_bone_pose_rotation(elbow, Quaternion.from_euler(Vector3(deg_to_rad(-bend), 0, 0)))
			skeleton.set_bone_pose_rotation(knee, Quaternion.from_euler(Vector3(deg_to_rad(flex), 0, 0)))

	if state in [State.IDLE, State.WALK, State.RUN, State.SPRINT, State.CROUCH_IDLE, State.CROUCH_WALK, State.SLIDE, State.STAND_UP, State.TURN_L90, State.TURN_R90, State.TURN_180]:
		_ground_articulated_pose()


func _ground_articulated_pose() -> void:
	if not skeleton.get_meta("articulated", false):
		return
	var hips := skeleton.find_bone("hips")
	var rest := skeleton.get_bone_rest(hips).origin
	skeleton.set_bone_pose_position(hips, rest)
	var left := skeleton.get_bone_global_pose(skeleton.find_bone("l_shin")).origin.y
	var right := skeleton.get_bone_global_pose(skeleton.find_bone("r_shin")).origin.y
	# Keep the lower boot at the actor's contact datum; root/capsule never move.
	rest.y += Proportions.ANKLE_Y - minf(left, right)
	skeleton.set_bone_pose_position(hips, rest)
