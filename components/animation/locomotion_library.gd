class_name LocomotionLibrary
extends RefCounted
## Procedurally creates 19 in-place Animation resources at runtime: Idle, Walk, Run, Sprint, TurnL90, TurnR90, Turn180, Vault, Mantle, LedgeHang, ClimbUp, CrouchIdle, CrouchWalk, Slide, StandUp, WallRunL, WallRunR, Shimmy, Drop2Hang
## Each clip animates Skeleton3D bone rotations only (no Skeleton3D translation tracks; root bone position stays Vector3.ZERO)
## Walk/Run/Sprint stride frequency maps to lerp(WALK_FREQ 6.2, RUN_FREQ 11, clamp(speed/RUN_SPEED_REF 6.4)) and loops seamlessly.

static func build_library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	lib.add_animation("Idle", _build_idle())
	lib.add_animation("Walk", _build_walk())
	lib.add_animation("Run", _build_run())
	lib.add_animation("Sprint", _build_sprint())
	lib.add_animation("TurnL90", _build_turn_l90())
	lib.add_animation("TurnR90", _build_turn_r90())
	lib.add_animation("Turn180", _build_turn_180())
	lib.add_animation("Vault", _build_vault())
	lib.add_animation("Mantle", _build_mantle())
	lib.add_animation("LedgeHang", _build_ledge_hang())
	lib.add_animation("ClimbUp", _build_climb_up())
	lib.add_animation("CrouchIdle", _build_crouch_idle())
	lib.add_animation("CrouchWalk", _build_crouch_walk())
	lib.add_animation("Slide", _build_slide())
	lib.add_animation("StandUp", _build_stand_up())
	lib.add_animation("WallRunL", _build_wallrun_l())
	lib.add_animation("WallRunR", _build_wallrun_r())
	lib.add_animation("Shimmy", _build_shimmy())
	lib.add_animation("Drop2Hang", _build_drop2hang())
	return lib

static func _track_path(bone: String) -> StringName:
	# Tracks animate Skeleton3D bone rotation via subpath when AnimationPlayer.root_node == Skeleton3D.
	# Godot 4 skeleton bone path is ":<bone_name>" (bone subpath) with TYPE_ROTATION_3D.
	return StringName(":%s" % bone)

static func _add_rotation_track(anim: Animation, bone: String, keys: Array) -> void:
	# keys: Array of [time, Quaternion] pairs
	var path := _track_path(bone)
	var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(idx, NodePath(path))
	for kv in keys:
		var t: float = float(kv[0])
		var q: Quaternion = kv[1] as Quaternion
		anim.rotation_track_insert_key(idx, t, q)

static func _quat_from_euler_deg(x_deg: float, y_deg: float, z_deg: float) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(x_deg), deg_to_rad(y_deg), deg_to_rad(z_deg)))

static func _build_idle() -> Animation:
	var anim := Animation.new()
	anim.length = 1.2
	anim.loop_mode = Animation.LOOP_LINEAR
	# breathe: spine_upper pitch 2 deg sinusoidal, arms small sway
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(0, 0, 0)],
		[0.6, _quat_from_euler_deg(2.2, 0, 0)],
		[1.2, _quat_from_euler_deg(0, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(1, 0, 0)],
		[0.6, _quat_from_euler_deg(-1, 0, 0)],
		[1.2, _quat_from_euler_deg(1, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-1, 0, 0)],
		[0.6, _quat_from_euler_deg(1, 0, 0)],
		[1.2, _quat_from_euler_deg(-1, 0, 0)],
	])
	# keep legs static but with tiny idle
	_add_rotation_track(anim, "l_thigh", [[0.0, Quaternion.IDENTITY], [1.2, Quaternion.IDENTITY]])
	_add_rotation_track(anim, "r_thigh", [[0.0, Quaternion.IDENTITY], [1.2, Quaternion.IDENTITY]])
	_add_rotation_track(anim, "hips", [[0.0, Quaternion.IDENTITY], [1.2, Quaternion.IDENTITY]])
	return anim

static func _build_walk() -> Animation:
	var anim := Animation.new()
	anim.length = 0.70
	anim.loop_mode = Animation.LOOP_LINEAR
	var amp := 24.0
	# legs swing
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(amp, 0, 0)],
		[0.35, _quat_from_euler_deg(-amp, 0, 0)],
		[0.70, _quat_from_euler_deg(amp, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-amp, 0, 0)],
		[0.35, _quat_from_euler_deg(amp, 0, 0)],
		[0.70, _quat_from_euler_deg(-amp, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.35, _quat_from_euler_deg(-5, 0, 0)],
		[0.70, _quat_from_euler_deg(10, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-5, 0, 0)],
		[0.35, _quat_from_euler_deg(10, 0, 0)],
		[0.70, _quat_from_euler_deg(-5, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.35, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.70, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.35, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.70, _quat_from_euler_deg(amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(4, 0, 0)],
		[0.35, _quat_from_euler_deg(4, 0, 0)],
		[0.70, _quat_from_euler_deg(4, 0, 0)],
	])
	_add_rotation_track(anim, "hips", [[0.0, Quaternion.IDENTITY], [0.70, Quaternion.IDENTITY]])
	return anim

static func _build_run() -> Animation:
	var anim := Animation.new()
	anim.length = 0.52
	anim.loop_mode = Animation.LOOP_LINEAR
	var amp := 38.0
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(amp, 0, 0)],
		[0.26, _quat_from_euler_deg(-amp, 0, 0)],
		[0.52, _quat_from_euler_deg(amp, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-amp, 0, 0)],
		[0.26, _quat_from_euler_deg(amp, 0, 0)],
		[0.52, _quat_from_euler_deg(-amp, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(20, 0, 0)],
		[0.26, _quat_from_euler_deg(-10, 0, 0)],
		[0.52, _quat_from_euler_deg(20, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-10, 0, 0)],
		[0.26, _quat_from_euler_deg(20, 0, 0)],
		[0.52, _quat_from_euler_deg(-10, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.26, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.52, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.26, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.52, _quat_from_euler_deg(amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.52, _quat_from_euler_deg(10, 0, 0)],
	])
	_add_rotation_track(anim, "hips", [[0.0, Quaternion.IDENTITY], [0.52, Quaternion.IDENTITY]])
	return anim

static func _build_sprint() -> Animation:
	var anim := Animation.new()
	anim.length = 0.42
	anim.loop_mode = Animation.LOOP_LINEAR
	var amp := 46.0
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(amp, 0, 0)],
		[0.21, _quat_from_euler_deg(-amp, 0, 0)],
		[0.42, _quat_from_euler_deg(amp, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-amp, 0, 0)],
		[0.21, _quat_from_euler_deg(amp, 0, 0)],
		[0.42, _quat_from_euler_deg(-amp, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(24, 0, 0)],
		[0.21, _quat_from_euler_deg(-12, 0, 0)],
		[0.42, _quat_from_euler_deg(24, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-12, 0, 0)],
		[0.21, _quat_from_euler_deg(24, 0, 0)],
		[0.42, _quat_from_euler_deg(-12, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.21, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.42, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(amp * 0.8, 0, 0)],
		[0.21, _quat_from_euler_deg(-amp * 0.8, 0, 0)],
		[0.42, _quat_from_euler_deg(amp * 0.8, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(14, 0, 0)],
		[0.42, _quat_from_euler_deg(14, 0, 0)],
	])
	_add_rotation_track(anim, "hips", [[0.0, Quaternion.IDENTITY], [0.42, Quaternion.IDENTITY]])
	return anim

static func _build_turn_l90() -> Animation:
	var anim := Animation.new()
	anim.length = 0.55
	anim.loop_mode = Animation.LOOP_NONE
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.55, _quat_from_euler_deg(0, -90, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, Quaternion.IDENTITY],
		[0.275, _quat_from_euler_deg(0, -45, 0)],
		[0.55, _quat_from_euler_deg(0, -90, 0)],
	])
	# feet step in place during turn
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(15, 0, 0)],
		[0.275, _quat_from_euler_deg(-10, 0, 0)],
		[0.55, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-15, 0, 0)],
		[0.275, _quat_from_euler_deg(10, 0, 0)],
		[0.55, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [[0.0, Quaternion.IDENTITY], [0.55, Quaternion.IDENTITY]])
	_add_rotation_track(anim, "r_shin", [[0.0, Quaternion.IDENTITY], [0.55, Quaternion.IDENTITY]])
	return anim

static func _build_turn_r90() -> Animation:
	var anim := Animation.new()
	anim.length = 0.55
	anim.loop_mode = Animation.LOOP_NONE
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.55, _quat_from_euler_deg(0, 90, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, Quaternion.IDENTITY],
		[0.275, _quat_from_euler_deg(0, 45, 0)],
		[0.55, _quat_from_euler_deg(0, 90, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(-15, 0, 0)],
		[0.275, _quat_from_euler_deg(10, 0, 0)],
		[0.55, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(15, 0, 0)],
		[0.275, _quat_from_euler_deg(-10, 0, 0)],
		[0.55, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [[0.0, Quaternion.IDENTITY], [0.55, Quaternion.IDENTITY]])
	_add_rotation_track(anim, "r_shin", [[0.0, Quaternion.IDENTITY], [0.55, Quaternion.IDENTITY]])
	return anim

static func _build_turn_180() -> Animation:
	var anim := Animation.new()
	anim.length = 0.80
	anim.loop_mode = Animation.LOOP_NONE
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.40, _quat_from_euler_deg(0, 90, 0)],
		[0.80, _quat_from_euler_deg(0, 180, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, Quaternion.IDENTITY],
		[0.40, _quat_from_euler_deg(0, 90, 0)],
		[0.80, _quat_from_euler_deg(0, 180, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(20, 0, 0)],
		[0.20, _quat_from_euler_deg(-15, 0, 0)],
		[0.40, _quat_from_euler_deg(20, 0, 0)],
		[0.60, _quat_from_euler_deg(-15, 0, 0)],
		[0.80, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-15, 0, 0)],
		[0.20, _quat_from_euler_deg(20, 0, 0)],
		[0.40, _quat_from_euler_deg(-15, 0, 0)],
		[0.60, _quat_from_euler_deg(20, 0, 0)],
		[0.80, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [[0.0, Quaternion.IDENTITY], [0.80, Quaternion.IDENTITY]])
	_add_rotation_track(anim, "r_shin", [[0.0, Quaternion.IDENTITY], [0.80, Quaternion.IDENTITY]])
	return anim

static func _build_vault() -> Animation:
	var anim := Animation.new()
	anim.length = 0.55
	anim.loop_mode = Animation.LOOP_NONE
	# Vault: hips rise, torso lean forward, legs tuck, arms brace
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.15, _quat_from_euler_deg(-12, 0, 0)],
		[0.35, _quat_from_euler_deg(8, 0, 0)],
		[0.55, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(4, 0, 0)],
		[0.18, _quat_from_euler_deg(22, 0, 0)],
		[0.35, _quat_from_euler_deg(-6, 0, 0)],
		[0.55, _quat_from_euler_deg(4, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.15, _quat_from_euler_deg(42, 0, 0)],
		[0.30, _quat_from_euler_deg(-18, 0, 0)],
		[0.55, _quat_from_euler_deg(18, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-18, 0, 0)],
		[0.15, _quat_from_euler_deg(-42, 0, 0)],
		[0.30, _quat_from_euler_deg(18, 0, 0)],
		[0.55, _quat_from_euler_deg(-18, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.15, _quat_from_euler_deg(52, 0, 0)],
		[0.30, _quat_from_euler_deg(-8, 0, 0)],
		[0.55, _quat_from_euler_deg(10, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-5, 0, 0)],
		[0.15, _quat_from_euler_deg(-52, 0, 0)],
		[0.30, _quat_from_euler_deg(8, 0, 0)],
		[0.55, _quat_from_euler_deg(-5, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-18, 0, 0)],
		[0.15, _quat_from_euler_deg(-68, 0, 0)],
		[0.35, _quat_from_euler_deg(22, 0, 0)],
		[0.55, _quat_from_euler_deg(-18, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.15, _quat_from_euler_deg(68, 0, 0)],
		[0.35, _quat_from_euler_deg(-22, 0, 0)],
		[0.55, _quat_from_euler_deg(18, 0, 0)],
	])
	return anim

static func _build_mantle() -> Animation:
	var anim := Animation.new()
	anim.length = 0.85
	anim.loop_mode = Animation.LOOP_NONE
	# Mantle: hands reach, hip to 0.95 then plant, chest over wall
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.25, _quat_from_euler_deg(-18, 0, 0)],
		[0.55, _quat_from_euler_deg(12, 0, 0)],
		[0.85, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(6, 0, 0)],
		[0.25, _quat_from_euler_deg(28, 0, 0)],
		[0.55, _quat_from_euler_deg(-8, 0, 0)],
		[0.85, _quat_from_euler_deg(6, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(22, 0, 0)],
		[0.25, _quat_from_euler_deg(48, 0, 0)],
		[0.55, _quat_from_euler_deg(-22, 0, 0)],
		[0.85, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-22, 0, 0)],
		[0.25, _quat_from_euler_deg(-42, 0, 0)],
		[0.55, _quat_from_euler_deg(22, 0, 0)],
		[0.85, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.25, _quat_from_euler_deg(58, 0, 0)],
		[0.55, _quat_from_euler_deg(-10, 0, 0)],
		[0.85, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-8, 0, 0)],
		[0.25, _quat_from_euler_deg(-58, 0, 0)],
		[0.55, _quat_from_euler_deg(10, 0, 0)],
		[0.85, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-24, 0, 0)],
		[0.20, _quat_from_euler_deg(-112, 0, 0)],
		[0.55, _quat_from_euler_deg(-42, 0, 0)],
		[0.85, _quat_from_euler_deg(-24, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(24, 0, 0)],
		[0.20, _quat_from_euler_deg(112, 0, 0)],
		[0.55, _quat_from_euler_deg(42, 0, 0)],
		[0.85, _quat_from_euler_deg(24, 0, 0)],
	])
	return anim

static func _build_ledge_hang() -> Animation:
	var anim := Animation.new()
	anim.length = 1.2
	anim.loop_mode = Animation.LOOP_LINEAR
	# Hang idle: arms overhead gripping ledge, slight sway, legs dangling
	_add_rotation_track(anim, "hips", [
		[0.0, Quaternion.IDENTITY],
		[0.6, _quat_from_euler_deg(2, 0, 1.5)],
		[1.2, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(-4, 0, 0)],
		[0.6, _quat_from_euler_deg(-6, 0, 0)],
		[1.2, _quat_from_euler_deg(-4, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.6, _quat_from_euler_deg(14, 0, 0)],
		[1.2, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.6, _quat_from_euler_deg(10, 0, 0)],
		[1.2, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.6, _quat_from_euler_deg(10, 0, 0)],
		[1.2, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.6, _quat_from_euler_deg(6, 0, 0)],
		[1.2, _quat_from_euler_deg(8, 0, 0)],
	])
	# Arms overhead: ~ -120 deg X (up)
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-118, 0, -8)],
		[0.6, _quat_from_euler_deg(-122, 0, -8)],
		[1.2, _quat_from_euler_deg(-118, 0, -8)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-118, 0, 8)],
		[0.6, _quat_from_euler_deg(-122, 0, 8)],
		[1.2, _quat_from_euler_deg(-118, 0, 8)],
	])
	return anim

static func _build_climb_up() -> Animation:
	var anim := Animation.new()
	anim.length = 0.70
	anim.loop_mode = Animation.LOOP_NONE
	# ClimbUp: pull from hang to stand, hips rise, arms pull
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-6, 0, 0)],
		[0.25, _quat_from_euler_deg(-22, 0, 0)],
		[0.50, _quat_from_euler_deg(10, 0, 0)],
		[0.70, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(-8, 0, 0)],
		[0.25, _quat_from_euler_deg(-26, 0, 0)],
		[0.50, _quat_from_euler_deg(12, 0, 0)],
		[0.70, _quat_from_euler_deg(4, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(14, 0, 0)],
		[0.20, _quat_from_euler_deg(42, 0, 0)],
		[0.40, _quat_from_euler_deg(-20, 0, 0)],
		[0.70, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(14, 0, 0)],
		[0.20, _quat_from_euler_deg(-38, 0, 0)],
		[0.40, _quat_from_euler_deg(24, 0, 0)],
		[0.70, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.25, _quat_from_euler_deg(42, 0, 0)],
		[0.70, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.25, _quat_from_euler_deg(-42, 0, 0)],
		[0.70, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-122, 0, -8)],
		[0.20, _quat_from_euler_deg(-78, 0, -8)],
		[0.40, _quat_from_euler_deg(18, 0, 0)],
		[0.70, _quat_from_euler_deg(-8, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-122, 0, 8)],
		[0.20, _quat_from_euler_deg(-78, 0, 8)],
		[0.40, _quat_from_euler_deg(18, 0, 0)],
		[0.70, _quat_from_euler_deg(-8, 0, 0)],
	])
	return anim

static func _build_crouch_idle() -> Animation:
	var anim := Animation.new()
	anim.length = 1.2
	anim.loop_mode = Animation.LOOP_LINEAR
	# CrouchIdle: hips low, knees bent ~42 deg, breathe while crouched
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-8, 0, 0)],
		[0.6, _quat_from_euler_deg(-10, 0, 0)],
		[1.2, _quat_from_euler_deg(-8, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.6, _quat_from_euler_deg(14, 0, 0)],
		[1.2, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(42, 0, 0)],
		[0.6, _quat_from_euler_deg(44, 0, 0)],
		[1.2, _quat_from_euler_deg(42, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(42, 0, 0)],
		[0.6, _quat_from_euler_deg(44, 0, 0)],
		[1.2, _quat_from_euler_deg(42, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(38, 0, 0)],
		[0.6, _quat_from_euler_deg(40, 0, 0)],
		[1.2, _quat_from_euler_deg(38, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(38, 0, 0)],
		[0.6, _quat_from_euler_deg(40, 0, 0)],
		[1.2, _quat_from_euler_deg(38, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.6, _quat_from_euler_deg(10, 0, 0)],
		[1.2, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.6, _quat_from_euler_deg(10, 0, 0)],
		[1.2, _quat_from_euler_deg(8, 0, 0)],
	])
	return anim

static func _build_crouch_walk() -> Animation:
	var anim := Animation.new()
	anim.length = 0.70
	anim.loop_mode = Animation.LOOP_LINEAR
	var amp := 18.0
	# CrouchWalk: shortened stride, knees bent, hips low
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-8, 0, 0)],
		[0.70, _quat_from_euler_deg(-8, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(14, 0, 0)],
		[0.70, _quat_from_euler_deg(14, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(42 + amp, 0, 0)],
		[0.35, _quat_from_euler_deg(42 - amp, 0, 0)],
		[0.70, _quat_from_euler_deg(42 + amp, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(42 - amp, 0, 0)],
		[0.35, _quat_from_euler_deg(42 + amp, 0, 0)],
		[0.70, _quat_from_euler_deg(42 - amp, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(42, 0, 0)],
		[0.35, _quat_from_euler_deg(22, 0, 0)],
		[0.70, _quat_from_euler_deg(42, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(22, 0, 0)],
		[0.35, _quat_from_euler_deg(42, 0, 0)],
		[0.70, _quat_from_euler_deg(22, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-amp*0.6, 0, 0)],
		[0.35, _quat_from_euler_deg(amp*0.6, 0, 0)],
		[0.70, _quat_from_euler_deg(-amp*0.6, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(amp*0.6, 0, 0)],
		[0.35, _quat_from_euler_deg(-amp*0.6, 0, 0)],
		[0.70, _quat_from_euler_deg(amp*0.6, 0, 0)],
	])
	return anim

static func _build_slide() -> Animation:
	var anim := Animation.new()
	anim.length = 0.90
	anim.loop_mode = Animation.LOOP_NONE
	# Slide: hips low, legs extended forward, arms trailing, torso ~12 deg lean
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-6, 0, 0)],
		[0.45, _quat_from_euler_deg(-10, 0, 0)],
		[0.90, _quat_from_euler_deg(-6, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.45, _quat_from_euler_deg(14, 0, 0)],
		[0.90, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(22, 0, 0)],
		[0.30, _quat_from_euler_deg(68, 0, 0)],
		[0.60, _quat_from_euler_deg(48, 0, 0)],
		[0.90, _quat_from_euler_deg(22, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(22, 0, 0)],
		[0.30, _quat_from_euler_deg(48, 0, 0)],
		[0.60, _quat_from_euler_deg(68, 0, 0)],
		[0.90, _quat_from_euler_deg(22, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.45, _quat_from_euler_deg(8, 0, 0)],
		[0.90, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.45, _quat_from_euler_deg(8, 0, 0)],
		[0.90, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(28, 0, 0)],
		[0.45, _quat_from_euler_deg(32, 0, 0)],
		[0.90, _quat_from_euler_deg(28, 0, 0)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(28, 0, 0)],
		[0.45, _quat_from_euler_deg(32, 0, 0)],
		[0.90, _quat_from_euler_deg(28, 0, 0)],
	])
	return anim

static func _build_stand_up() -> Animation:
	var anim := Animation.new()
	anim.length = 0.35
	anim.loop_mode = Animation.LOOP_NONE
	# StandUp: hips rise 0.18 to stand, knees straighten
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-8, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.35, _quat_from_euler_deg(4, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(42, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(42, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(38, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(38, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.35, Quaternion.IDENTITY],
	])
	return anim

static func _build_wallrun_l() -> Animation:
	var anim := Animation.new()
	anim.length = 0.80
	anim.loop_mode = Animation.LOOP_LINEAR
	# WallRunL: torso lean toward wall ~12 deg, legs pump laterally, arms reaching for wall
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(0, 0, -12)],
		[0.40, _quat_from_euler_deg(0, 0, -12)],
		[0.80, _quat_from_euler_deg(0, 0, -12)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(4, 0, -12)],
		[0.40, _quat_from_euler_deg(6, 0, -12)],
		[0.80, _quat_from_euler_deg(4, 0, -12)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(32, 0, 0)],
		[0.20, _quat_from_euler_deg(-28, 0, 0)],
		[0.40, _quat_from_euler_deg(32, 0, 0)],
		[0.60, _quat_from_euler_deg(-28, 0, 0)],
		[0.80, _quat_from_euler_deg(32, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(-28, 0, 0)],
		[0.20, _quat_from_euler_deg(32, 0, 0)],
		[0.40, _quat_from_euler_deg(-28, 0, 0)],
		[0.60, _quat_from_euler_deg(32, 0, 0)],
		[0.80, _quat_from_euler_deg(-28, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.20, _quat_from_euler_deg(-12, 0, 0)],
		[0.40, _quat_from_euler_deg(18, 0, 0)],
		[0.60, _quat_from_euler_deg(-12, 0, 0)],
		[0.80, _quat_from_euler_deg(18, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(-12, 0, 0)],
		[0.20, _quat_from_euler_deg(18, 0, 0)],
		[0.40, _quat_from_euler_deg(-12, 0, 0)],
		[0.60, _quat_from_euler_deg(18, 0, 0)],
		[0.80, _quat_from_euler_deg(-12, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-42, 0, -18)],
		[0.40, _quat_from_euler_deg(-48, 0, -18)],
		[0.80, _quat_from_euler_deg(-42, 0, -18)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-38, 0, -12)],
		[0.40, _quat_from_euler_deg(-42, 0, -12)],
		[0.80, _quat_from_euler_deg(-38, 0, -12)],
	])
	return anim

static func _build_wallrun_r() -> Animation:
	var anim := Animation.new()
	anim.length = 0.80
	anim.loop_mode = Animation.LOOP_LINEAR
	# WallRunR: mirrored lean
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(0, 0, 12)],
		[0.40, _quat_from_euler_deg(0, 0, 12)],
		[0.80, _quat_from_euler_deg(0, 0, 12)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(4, 0, 12)],
		[0.40, _quat_from_euler_deg(6, 0, 12)],
		[0.80, _quat_from_euler_deg(4, 0, 12)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(-28, 0, 0)],
		[0.20, _quat_from_euler_deg(32, 0, 0)],
		[0.40, _quat_from_euler_deg(-28, 0, 0)],
		[0.60, _quat_from_euler_deg(32, 0, 0)],
		[0.80, _quat_from_euler_deg(-28, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(32, 0, 0)],
		[0.20, _quat_from_euler_deg(-28, 0, 0)],
		[0.40, _quat_from_euler_deg(32, 0, 0)],
		[0.60, _quat_from_euler_deg(-28, 0, 0)],
		[0.80, _quat_from_euler_deg(32, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(-12, 0, 0)],
		[0.20, _quat_from_euler_deg(18, 0, 0)],
		[0.40, _quat_from_euler_deg(-12, 0, 0)],
		[0.60, _quat_from_euler_deg(18, 0, 0)],
		[0.80, _quat_from_euler_deg(-12, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.20, _quat_from_euler_deg(-12, 0, 0)],
		[0.40, _quat_from_euler_deg(18, 0, 0)],
		[0.60, _quat_from_euler_deg(-12, 0, 0)],
		[0.80, _quat_from_euler_deg(18, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-38, 0, 12)],
		[0.40, _quat_from_euler_deg(-42, 0, 12)],
		[0.80, _quat_from_euler_deg(-38, 0, 12)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-42, 0, 18)],
		[0.40, _quat_from_euler_deg(-48, 0, 18)],
		[0.80, _quat_from_euler_deg(-42, 0, 18)],
	])
	return anim

static func _build_shimmy() -> Animation:
	var anim := Animation.new()
	anim.length = 0.85
	anim.loop_mode = Animation.LOOP_LINEAR
	# Shimmy: hands reaching forward alternating, hips close to wall, lateral 0.60 m/s
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(-4, 0, 0)],
		[0.425, _quat_from_euler_deg(-6, 0, 0)],
		[0.85, _quat_from_euler_deg(-4, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(-2, 0, 0)],
		[0.425, _quat_from_euler_deg(-4, 0, 0)],
		[0.85, _quat_from_euler_deg(-2, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.425, _quat_from_euler_deg(12, 0, 0)],
		[0.85, _quat_from_euler_deg(10, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(10, 0, 0)],
		[0.425, _quat_from_euler_deg(8, 0, 0)],
		[0.85, _quat_from_euler_deg(10, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.425, _quat_from_euler_deg(6, 0, 0)],
		[0.85, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.425, _quat_from_euler_deg(10, 0, 0)],
		[0.85, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-118, 0, -10)],
		[0.212, _quat_from_euler_deg(-122, 0, -10)],
		[0.425, _quat_from_euler_deg(-118, 0, -10)],
		[0.637, _quat_from_euler_deg(-110, 0, -10)],
		[0.85, _quat_from_euler_deg(-118, 0, -10)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-110, 0, 10)],
		[0.212, _quat_from_euler_deg(-118, 0, 10)],
		[0.425, _quat_from_euler_deg(-118, 0, 10)],
		[0.637, _quat_from_euler_deg(-122, 0, 10)],
		[0.85, _quat_from_euler_deg(-110, 0, 10)],
	])
	return anim

static func _build_drop2hang() -> Animation:
	var anim := Animation.new()
	anim.length = 0.45
	anim.loop_mode = Animation.LOOP_NONE
	# Drop2Hang: release wall-run into hanging pose, hips drop 0.35
	_add_rotation_track(anim, "hips", [
		[0.0, _quat_from_euler_deg(6, 0, 0)],
		[0.20, _quat_from_euler_deg(-12, 0, 0)],
		[0.45, _quat_from_euler_deg(-6, 0, 0)],
	])
	_add_rotation_track(anim, "spine_upper", [
		[0.0, _quat_from_euler_deg(8, 0, 0)],
		[0.20, _quat_from_euler_deg(-4, 0, 0)],
		[0.45, _quat_from_euler_deg(-8, 0, 0)],
	])
	_add_rotation_track(anim, "l_thigh", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.45, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "r_thigh", [
		[0.0, _quat_from_euler_deg(18, 0, 0)],
		[0.45, _quat_from_euler_deg(12, 0, 0)],
	])
	_add_rotation_track(anim, "l_shin", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.45, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "r_shin", [
		[0.0, _quat_from_euler_deg(12, 0, 0)],
		[0.45, _quat_from_euler_deg(8, 0, 0)],
	])
	_add_rotation_track(anim, "l_upper_arm", [
		[0.0, _quat_from_euler_deg(-68, 0, -8)],
		[0.20, _quat_from_euler_deg(-96, 0, -8)],
		[0.45, _quat_from_euler_deg(-118, 0, -8)],
	])
	_add_rotation_track(anim, "r_upper_arm", [
		[0.0, _quat_from_euler_deg(-68, 0, 8)],
		[0.20, _quat_from_euler_deg(-96, 0, 8)],
		[0.45, _quat_from_euler_deg(-118, 0, 8)],
	])
	return anim
