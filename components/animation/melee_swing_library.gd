class_name MeleeSwingLibrary
extends RefCounted
## Procedural multi-directional melee swing clips.
##
## Eight direction-authored attack animations. Same authoring contract as
## LocomotionLibrary: rotation tracks only (never position), no root bone track,
## explicit key times, LOOP_NONE.
##
## Rig signs were verified empirically with debug/melee_axis_probe.gd
## (`--meleeprobe`), not assumed:
##   arm  X+  = swing FORWARD (X+150 = overhead-forward), X- = back
##   arm  Z+  = abduct toward the character's RIGHT -- identical for BOTH arms
##              (the rig does not mirror arm bones, so a symmetric pose uses
##              +Z on the right arm and -Z on the left)
##   arm  Y   = twist
##   forearm X+ = elbow curl (hand toward the shoulder)
##   spine_upper X- = lean FORWARD, Y+ = right shoulder swings FORWARD
##   hips Y+ = hips rotate with the right side forward
##
## Aim space for direction resolution: local -Z is forward, +X is the
## character's right, so `atan2(aim.x, -aim.z)` gives 0 deg straight ahead,
## +90 deg to the right, -90 deg to the left.

## Canonical direction ids (also the clip names).
const CLIPS: Array[StringName] = [
	&"SlashR", &"SlashL", &"Chop", &"Thrust", &"DiagR", &"DiagL",
	&"Smash", &"Sweep",
]

const LIB_NAME := &"melee"

## Bones every swing drives. Forearms are appended only for articulated rigs.
const BASE_BONES: Array[String] = ["hips", "spine_upper", "r_upper_arm", "l_upper_arm"]
const FORE_BONES: Array[String] = ["r_forearm", "l_forearm"]
const THIGH_BONES: Array[String] = ["l_thigh", "r_thigh"]

## Per-clip definition. `entry` is the aim angle (deg) the swing naturally
## covers from the character's own frame, `tol` how wide that coverage is.
## Poses are authored as windup / strike / follow; every clip settles to rest.
const DEFS := {
	&"SlashR": {
		"length": 0.46, "hit": 0.42, "entry": 60.0, "tol": 45.0,
		"heavy": false, "label": "Right to left",
		"wind": {
			"spine_upper": Vector3(-4, -26, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(-12, 0, 62), "r_forearm": Vector3(34, 0, 0),
			"l_upper_arm": Vector3(10, 0, -16),
		},
		"strike": {
			"spine_upper": Vector3(2, 30, 0), "hips": Vector3(0, 16, 0),
			"r_upper_arm": Vector3(56, 0, -34), "r_forearm": Vector3(10, 0, 0),
			"l_upper_arm": Vector3(2, 0, 26),
		},
		"follow": {
			"spine_upper": Vector3(6, 40, 0), "hips": Vector3(0, 22, 0),
			"r_upper_arm": Vector3(46, 0, -58), "r_forearm": Vector3(26, 0, 0),
			"l_upper_arm": Vector3(-4, 0, 34),
		},
	},
	&"SlashL": {
		"length": 0.46, "hit": 0.42, "entry": -60.0, "tol": 45.0,
		"heavy": false, "label": "Left to right",
		"wind": {
			"spine_upper": Vector3(-4, 26, 0), "hips": Vector3(0, 14, 0),
			"l_upper_arm": Vector3(-12, 0, -62), "l_forearm": Vector3(34, 0, 0),
			"r_upper_arm": Vector3(10, 0, 16),
		},
		"strike": {
			"spine_upper": Vector3(2, -30, 0), "hips": Vector3(0, -16, 0),
			"l_upper_arm": Vector3(56, 0, 34), "l_forearm": Vector3(10, 0, 0),
			"r_upper_arm": Vector3(2, 0, -26),
		},
		"follow": {
			"spine_upper": Vector3(6, -40, 0), "hips": Vector3(0, -22, 0),
			"l_upper_arm": Vector3(46, 0, 58), "l_forearm": Vector3(26, 0, 0),
			"r_upper_arm": Vector3(-4, 0, -34),
		},
	},
	&"Chop": {
		"length": 0.55, "hit": 0.40, "entry": 0.0, "tol": 24.0,
		"heavy": false, "label": "Overhead chop",
		"wind": {
			"spine_upper": Vector3(-18, -6, 0), "hips": Vector3(-6, -4, 0),
			"r_upper_arm": Vector3(152, 0, 12), "r_forearm": Vector3(48, 0, 0),
			"l_upper_arm": Vector3(142, 0, -12),
		},
		"strike": {
			"spine_upper": Vector3(16, 4, 0), "hips": Vector3(6, 2, 0),
			"r_upper_arm": Vector3(38, 0, 2), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(22, 0, -6),
		},
		"follow": {
			"spine_upper": Vector3(22, 6, 0), "hips": Vector3(8, 2, 0),
			"r_upper_arm": Vector3(16, 0, -2), "r_forearm": Vector3(18, 0, 0),
			"l_upper_arm": Vector3(6, 0, -4),
		},
	},
	&"Thrust": {
		"length": 0.50, "hit": 0.38, "entry": 0.0, "tol": 20.0,
		"heavy": false, "label": "Forward thrust",
		"wind": {
			"spine_upper": Vector3(-6, -20, 0), "hips": Vector3(0, -10, 0),
			"r_upper_arm": Vector3(-26, 0, 10), "r_forearm": Vector3(92, 0, 0),
			"l_upper_arm": Vector3(14, 0, -10),
		},
		"strike": {
			"spine_upper": Vector3(-10, 16, 0), "hips": Vector3(0, 12, 0),
			"r_upper_arm": Vector3(84, 0, -4), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(-10, 0, 16),
		},
		"follow": {
			"spine_upper": Vector3(-6, 20, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(80, 0, -6), "r_forearm": Vector3(12, 0, 0),
			"l_upper_arm": Vector3(-12, 0, 20),
		},
	},
	&"DiagR": {
		"length": 0.50, "hit": 0.40, "entry": 28.0, "tol": 22.0,
		"heavy": false, "label": "High right to low left",
		"wind": {
			"spine_upper": Vector3(-12, -20, 0), "hips": Vector3(-4, -10, 0),
			"r_upper_arm": Vector3(128, 0, 48), "r_forearm": Vector3(40, 0, 0),
			"l_upper_arm": Vector3(24, 0, -18),
		},
		"strike": {
			"spine_upper": Vector3(6, 26, 0), "hips": Vector3(4, 14, 0),
			"r_upper_arm": Vector3(46, 0, -34), "r_forearm": Vector3(8, 0, 0),
			"l_upper_arm": Vector3(4, 0, 20),
		},
		"follow": {
			"spine_upper": Vector3(10, 32, 0), "hips": Vector3(6, 18, 0),
			"r_upper_arm": Vector3(18, 0, -48), "r_forearm": Vector3(20, 0, 0),
			"l_upper_arm": Vector3(-2, 0, 26),
		},
	},
	&"DiagL": {
		"length": 0.50, "hit": 0.40, "entry": -28.0, "tol": 22.0,
		"heavy": false, "label": "High left to low right",
		"wind": {
			"spine_upper": Vector3(-12, 20, 0), "hips": Vector3(-4, 10, 0),
			"l_upper_arm": Vector3(128, 0, -48), "l_forearm": Vector3(40, 0, 0),
			"r_upper_arm": Vector3(24, 0, 18),
		},
		"strike": {
			"spine_upper": Vector3(6, -26, 0), "hips": Vector3(4, -14, 0),
			"l_upper_arm": Vector3(46, 0, 34), "l_forearm": Vector3(8, 0, 0),
			"r_upper_arm": Vector3(4, 0, -20),
		},
		"follow": {
			"spine_upper": Vector3(10, -32, 0), "hips": Vector3(6, -18, 0),
			"l_upper_arm": Vector3(18, 0, 48), "l_forearm": Vector3(20, 0, 0),
			"r_upper_arm": Vector3(-2, 0, -26),
		},
	},
	&"Smash": {
		"length": 1.05, "hit": 0.46, "entry": 0.0, "tol": 26.0,
		"heavy": true, "label": "Two-handed overhead smash",
		"wind": {
			"spine_upper": Vector3(-24, 0, 0), "hips": Vector3(-10, 0, 0),
			"r_upper_arm": Vector3(158, 0, 14), "r_forearm": Vector3(56, 0, 0),
			"l_upper_arm": Vector3(152, 0, -14), "l_forearm": Vector3(52, 0, 0),
			"l_thigh": Vector3(10, 0, 0), "r_thigh": Vector3(10, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(26, 0, 0), "hips": Vector3(10, 0, 0),
			"r_upper_arm": Vector3(32, 0, 4), "r_forearm": Vector3(4, 0, 0),
			"l_upper_arm": Vector3(26, 0, -4), "l_forearm": Vector3(4, 0, 0),
			"l_thigh": Vector3(20, 0, 0), "r_thigh": Vector3(20, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(30, 0, 0), "hips": Vector3(12, 0, 0),
			"r_upper_arm": Vector3(10, 0, 0), "r_forearm": Vector3(22, 0, 0),
			"l_upper_arm": Vector3(8, 0, 0), "l_forearm": Vector3(20, 0, 0),
			"l_thigh": Vector3(14, 0, 0), "r_thigh": Vector3(14, 0, 0),
		},
	},
	&"Sweep": {
		"length": 0.80, "hit": 0.46, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Wide horizontal sweep",
		"wind": {
			"spine_upper": Vector3(-8, -54, 0), "hips": Vector3(0, -24, 0),
			"r_upper_arm": Vector3(24, 0, 78), "r_forearm": Vector3(30, 0, 0),
			"l_upper_arm": Vector3(16, 0, -34),
		},
		"strike": {
			"spine_upper": Vector3(4, 62, 0), "hips": Vector3(0, 26, 0),
			"r_upper_arm": Vector3(26, 0, -66), "r_forearm": Vector3(14, 0, 0),
			"l_upper_arm": Vector3(10, 0, -52),
		},
		"follow": {
			"spine_upper": Vector3(8, 78, 0), "hips": Vector3(0, 34, 0),
			"r_upper_arm": Vector3(14, 0, -84), "r_forearm": Vector3(28, 0, 0),
			"l_upper_arm": Vector3(2, 0, -60),
		},
	},
}


static func build_library(articulated := true) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip in CLIPS:
		lib.add_animation(clip, build_clip(clip, articulated))
	return lib


static func build_clip(clip: StringName, articulated := true) -> Animation:
	var def: Dictionary = DEFS[clip]
	var length := float(def["length"])
	var hit := float(def["hit"])
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_NONE
	anim.set_meta(&"hit_frac", hit)
	anim.set_meta(&"heavy", bool(def.get("heavy", false)))
	anim.set_meta(&"entry_angle", float(def.get("entry", 0.0)))
	anim.set_meta(&"tolerance", float(def.get("tol", 0.0)))
	anim.set_meta(&"direction_label", String(def.get("label", "")))
	anim.set_meta(&"direction", clip)

	# Key times: rest -> windup -> strike (hit) -> follow -> settle at rest.
	var t_wind := hit * 0.5
	var t_strike := hit
	var t_follow := hit + (1.0 - hit) * 0.5
	var bones: Array[String] = BASE_BONES.duplicate()
	if articulated:
		bones.append_array(FORE_BONES)
	# Thigh keys are authored only for the heavy, grounded swings.
	for b in THIGH_BONES:
		if def["wind"].has(b) or def["strike"].has(b) or def["follow"].has(b):
			bones.append(b)

	for bone in bones:
		var keys: Array = [
			[0.0 * length, Vector3.ZERO],
			[t_wind * length, _pose(def["wind"], bone)],
			[t_strike * length, _pose(def["strike"], bone)],
			[t_follow * length, _pose(def["follow"], bone)],
			[1.0 * length, Vector3.ZERO],
		]
		_add_rotation_track(anim, bone, keys)
	return anim


## Rig-facing correction. Every pose number above is written in the rig's own
## bone axes, and this rig's TRUE front is +Z: actors/humanoid_model.gd authors
## the nose -- "Nose bump doubles as the facing cue (+Z)" -- at z=+0.125 and the
## face panel at +Z, and survivor.gd turns the visual root with
## atan2(facing.x, facing.z), which aims that nose along `facing`.
##
## The DEFS tables were authored against debug/melee_axis_probe.gd, which tags a
## hand direction "FORWARD" when `d.z < -0.35` -- the character's BACK. The
## author's whole mental model of the rig is therefore turned 180 degrees about
## Y, and every X (fwd/back) and Z (side) sign written from it is mirrored.
## Measured, not guessed: debug/melee_swing_direction_probe.gd
## (--meleedirprobe) reported 7 of 8 clips sending the blade AWAY from the aim
## (SlashL dot=-1.00, DiagL -0.99, SlashR +0.69 on a noisy sample, Thrust -0.88).
##
## A 180 degree turn about Y conjugates a rotation as
##   R_y(pi) . R . R_y(pi)^-1  =>  Rx(t)->Rx(-t), Ry(t)->Ry(t), Rz(t)->Rz(-t)
## so X and Z flip and the authored Y twist survives untouched. Correcting in
## this one accessor (instead of re-typing eight pose tables) keeps the DEFS
## numbers readable exactly as authored, and it is the single place to revert.
static func _pose(dict: Dictionary, bone: String) -> Vector3:
	var v: Vector3 = dict.get(bone, Vector3.ZERO) as Vector3
	return Vector3(-v.x, v.y, -v.z)


static func _add_rotation_track(anim: Animation, bone: String,
		keys: Array) -> void:
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, NodePath(":%s" % bone))
	for k in keys:
		anim.track_insert_key(t, float(k[0]), _quat_from_euler_deg(k[1] as Vector3))


static func _quat_from_euler_deg(deg: Vector3) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y),
			deg_to_rad(deg.z)))


# --- Direction resolution ----------------------------------------------------

static func entry_angle(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("entry", 0.0))


static func tolerance(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("tol", 0.0))


static func is_heavy(clip: StringName) -> bool:
	return bool(DEFS.get(clip, {}).get("heavy", false))


static func clip_length(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("length", 0.4))


static func hit_frac(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("hit", 0.4))


static func hit_time(clip: StringName) -> float:
	return clip_length(clip) * hit_frac(clip)


static func direction_label(clip: StringName) -> String:
	return String(DEFS.get(clip, {}).get("label", ""))


## Aim direction in the character's own frame -> swing id.
## `available` is the weapon's ordered swing pool; earlier entries win ties.
##
## Selection is two-pass so that the wide fallback swing never swallows the
## directional moves:
##   1. the *most specific* clip that actually covers the aim (narrowest
##      tolerance wins, then the closest entry). A 180 deg Sweep covers every
##      aim, so it can only win where no aimed swing reaches.
##   2. if nothing covers the aim, the least out-of-reach swing wins, and the
##      widest arc breaks that tie.
## With `prefer_heavy` the pool is narrowed to heavy swings when it has any,
## which is how RMB turns a light weapon into a committed two-handed blow.
static func direction_for(aim_local: Vector3, available: Array,
		prefer_heavy := false) -> StringName:
	var pool: Array = available
	if prefer_heavy:
		var heavy_pool: Array = []
		for c in available:
			if is_heavy(c as StringName):
				heavy_pool.append(c)
		if not heavy_pool.is_empty():
			pool = heavy_pool
	if pool.is_empty():
		return &"Thrust"
	var aim_deg := 0.0
	if aim_local.length_squared() > 0.000001:
		aim_deg = rad_to_deg(atan2(aim_local.x, -aim_local.z))

	# Pass 1: the tightest authored swing that covers this aim.
	var best: StringName = pool[0] as StringName
	var best_tol := INF
	var best_delta := INF
	var covered := false
	for c in pool:
		var clip := c as StringName
		var tol := tolerance(clip)
		var delta := _delta_deg(clip, aim_deg)
		if delta > tol:
			continue
		if not covered or tol < best_tol - 0.0001 \
				or (absf(tol - best_tol) <= 0.0001 and delta < best_delta - 0.0001):
			covered = true
			best_tol = tol
			best_delta = delta
			best = clip
	if covered:
		return best

	# Pass 2: nothing covers the aim, so take the least out-of-reach swing and
	# let the widest arc win a tie.
	best = pool[0] as StringName
	var best_cost := INF
	var best_wide := -1.0
	for c in pool:
		var clip := c as StringName
		var tol := tolerance(clip)
		var cost := _delta_deg(clip, aim_deg) - tol
		if cost < best_cost - 0.0001 \
				or (absf(cost - best_cost) <= 0.0001 and tol > best_wide):
			best_cost = cost
			best_wide = tol
			best = clip
	return best


## Shortest angle between a clip's entry direction and the aim, in degrees.
static func _delta_deg(clip: StringName, aim_deg: float) -> float:
	return absf(rad_to_deg(angle_difference(
			deg_to_rad(entry_angle(clip)), deg_to_rad(aim_deg))))
