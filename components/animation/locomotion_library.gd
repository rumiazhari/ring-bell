class_name LocomotionLibrary
extends RefCounted
## Procedurally creates 7 in-place Animation resources at runtime: Idle, Walk, Run, Sprint, TurnL90, TurnR90, Turn180
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
