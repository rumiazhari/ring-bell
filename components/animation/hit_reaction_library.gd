class_name HitReactionLibrary
extends RefCounted
## Per-actor-type hit reactions: one rotation-only one-shot clip per
## (actor kind x impact family), authored exactly like the swing clips
## (MeleeSwingLibrary) so they register on the same AnimationPlayer and obey the
## same pose-authority latch.
##
## The two kinds react DIFFERENTLY on purpose, not just for longer:
##   human    - a trained body. The hit snaps a limb, the torso folds/twists
##              around the blow, and the actor recovers its footing (clip
##              settles back to rest).
##   shambler - a rotten body. The whole torso reels, the hips twist further,
##              the arms flail wide, and the reel lasts roughly twice as long,
##              so a crowd of zombies hit by the same swing is visually legible
##              as a crowd, not as one animation played N times.
##
## Impact families (three) collapse the five weapon classes onto three readable
## physical events - see MeleeTypes.impact().

const LIB_NAME := &"hit"

const KIND_HUMAN := &"human"
const KIND_SHAMBLER := &"shambler"
const KINDS: Array[StringName] = [KIND_HUMAN, KIND_SHAMBLER]

## Impact families.
const SLASH := &"slash"          # a blade or axe edge travelling across the body
const CRUSH := &"crush"          # blunt force: the body folds around the blow
const PIERCE := &"pierce"        # a point driven in: the body is thrown back
const IMPACTS: Array[StringName] = [SLASH, CRUSH, PIERCE]

## Bones every reaction touches (SkeletonFactory rig). Forearms only exist on
## the articulated rig, so they are gated exactly like MeleeSwingLibrary does.
const BASE_BONES: Array[String] = [
	"hips", "spine_upper", "head", "l_upper_arm", "r_upper_arm",
	"l_thigh", "r_thigh",
]
const FORE_BONES: Array[String] = ["l_forearm", "r_forearm"]

## Axis convention matches the swing clips: Vector3 euler degrees per bone,
## +X folds forward, +Y twists the torso to the actor's right, +Z abducts the
## left arm / adducts the right.
const DEFS := {
	KIND_HUMAN: {
		SLASH: {
			"length": 0.34, "hit": 0.35, "label": "Cut across the body",
			"jerk": {
				"spine_upper": Vector3(-6, 22, -4), "hips": Vector3(0, 10, 0),
				"head": Vector3(-4, 14, 0),
				"l_upper_arm": Vector3(14, 0, -30), "r_upper_arm": Vector3(-10, 0, 26),
				"l_forearm": Vector3(26, 0, 0), "r_forearm": Vector3(18, 0, 0),
				"l_thigh": Vector3(0, 0, -5), "r_thigh": Vector3(0, 0, 5),
			},
			"peak": {
				"spine_upper": Vector3(-12, 34, -8), "hips": Vector3(0, 16, -3),
				"head": Vector3(-8, 22, 0),
				"l_upper_arm": Vector3(22, 0, -44), "r_upper_arm": Vector3(-18, 0, 40),
				"l_forearm": Vector3(38, 0, 0), "r_forearm": Vector3(30, 0, 0),
				"l_thigh": Vector3(0, 0, -9), "r_thigh": Vector3(0, 0, 9),
			},
			"recover": {
				"spine_upper": Vector3(-4, 12, -2), "hips": Vector3(0, 6, 0),
				"head": Vector3(-2, 8, 0),
				"l_upper_arm": Vector3(8, 0, -16), "r_upper_arm": Vector3(-6, 0, 14),
				"l_forearm": Vector3(14, 0, 0), "r_forearm": Vector3(10, 0, 0),
				"l_thigh": Vector3(0, 0, -3), "r_thigh": Vector3(0, 0, 3),
			},
		},
		CRUSH: {
			"length": 0.42, "hit": 0.30, "label": "Folds around the blow",
			"jerk": {
				"spine_upper": Vector3(12, 0, 0), "hips": Vector3(5, 0, 0),
				"head": Vector3(9, 0, 0),
				"l_upper_arm": Vector3(20, 0, 14), "r_upper_arm": Vector3(20, 0, -14),
				"l_forearm": Vector3(30, 0, 0), "r_forearm": Vector3(30, 0, 0),
				"l_thigh": Vector3(5, 0, 0), "r_thigh": Vector3(5, 0, 0),
			},
			"peak": {
				"spine_upper": Vector3(26, 0, 0), "hips": Vector3(12, 0, 0),
				"head": Vector3(18, 0, 0),
				"l_upper_arm": Vector3(34, 0, 22), "r_upper_arm": Vector3(34, 0, -22),
				"l_forearm": Vector3(52, 0, 0), "r_forearm": Vector3(52, 0, 0),
				"l_thigh": Vector3(12, 0, 0), "r_thigh": Vector3(12, 0, 0),
			},
			"recover": {
				"spine_upper": Vector3(10, 0, 0), "hips": Vector3(4, 0, 0),
				"head": Vector3(6, 0, 0),
				"l_upper_arm": Vector3(14, 0, 9), "r_upper_arm": Vector3(14, 0, -9),
				"l_forearm": Vector3(22, 0, 0), "r_forearm": Vector3(22, 0, 0),
				"l_thigh": Vector3(5, 0, 0), "r_thigh": Vector3(5, 0, 0),
			},
		},
		PIERCE: {
			"length": 0.30, "hit": 0.24, "label": "Thrown back off the point",
			"jerk": {
				"spine_upper": Vector3(-16, 0, 0), "hips": Vector3(-6, 0, 0),
				"head": Vector3(-12, 0, 0),
				"l_upper_arm": Vector3(-22, 0, -26), "r_upper_arm": Vector3(-22, 0, 26),
				"l_forearm": Vector3(14, 0, 0), "r_forearm": Vector3(14, 0, 0),
				"l_thigh": Vector3(-4, 0, 0), "r_thigh": Vector3(-4, 0, 0),
			},
			"peak": {
				"spine_upper": Vector3(-28, 0, 2), "hips": Vector3(-11, 0, 0),
				"head": Vector3(-20, 0, 0),
				"l_upper_arm": Vector3(-34, 0, -40), "r_upper_arm": Vector3(-34, 0, 40),
				"l_forearm": Vector3(22, 0, 0), "r_forearm": Vector3(22, 0, 0),
				"l_thigh": Vector3(-8, 0, 0), "r_thigh": Vector3(-8, 0, 0),
			},
			"recover": {
				"spine_upper": Vector3(-10, 0, 0), "hips": Vector3(-4, 0, 0),
				"head": Vector3(-7, 0, 0),
				"l_upper_arm": Vector3(-13, 0, -15), "r_upper_arm": Vector3(-13, 0, 15),
				"l_forearm": Vector3(10, 0, 0), "r_forearm": Vector3(10, 0, 0),
				"l_thigh": Vector3(-3, 0, 0), "r_thigh": Vector3(-3, 0, 0),
			},
		},
	},
	KIND_SHAMBLER: {
		SLASH: {
			"length": 0.58, "hit": 0.42, "label": "Reels sideways",
			"jerk": {
				"spine_upper": Vector3(-8, 34, -8), "hips": Vector3(0, 20, 0),
				"head": Vector3(-6, 24, 6),
				"l_upper_arm": Vector3(10, 0, -48), "r_upper_arm": Vector3(-14, 0, 44),
				"l_forearm": Vector3(30, 0, 0), "r_forearm": Vector3(30, 0, 0),
				"l_thigh": Vector3(0, 0, -10), "r_thigh": Vector3(0, 0, 10),
			},
			"peak": {
				"spine_upper": Vector3(-16, 50, -12), "hips": Vector3(0, 30, -6),
				"head": Vector3(-10, 34, 8),
				"l_upper_arm": Vector3(18, 0, -64), "r_upper_arm": Vector3(-24, 0, 58),
				"l_forearm": Vector3(44, 0, 0), "r_forearm": Vector3(44, 0, 0),
				"l_thigh": Vector3(0, 0, -16), "r_thigh": Vector3(0, 0, 16),
			},
			"recover": {
				"spine_upper": Vector3(-6, 20, -4), "hips": Vector3(0, 12, -2),
				"head": Vector3(-4, 14, 3),
				"l_upper_arm": Vector3(7, 0, -26), "r_upper_arm": Vector3(-9, 0, 24),
				"l_forearm": Vector3(18, 0, 0), "r_forearm": Vector3(18, 0, 0),
				"l_thigh": Vector3(0, 0, -6), "r_thigh": Vector3(0, 0, 6),
			},
		},
		CRUSH: {
			"length": 0.66, "hit": 0.36, "label": "Doubles over, arms dangling",
			"jerk": {
				"spine_upper": Vector3(20, 0, 0), "hips": Vector3(8, 0, 0),
				"head": Vector3(14, 0, 0),
				"l_upper_arm": Vector3(28, 0, 10), "r_upper_arm": Vector3(28, 0, -10),
				"l_forearm": Vector3(42, 0, 0), "r_forearm": Vector3(42, 0, 0),
				"l_thigh": Vector3(10, 0, 0), "r_thigh": Vector3(10, 0, 0),
			},
			"peak": {
				"spine_upper": Vector3(40, 0, 0), "hips": Vector3(20, 0, 0),
				"head": Vector3(28, 0, 0),
				"l_upper_arm": Vector3(50, 0, 16), "r_upper_arm": Vector3(50, 0, -16),
				"l_forearm": Vector3(72, 0, 0), "r_forearm": Vector3(72, 0, 0),
				"l_thigh": Vector3(22, 0, 0), "r_thigh": Vector3(22, 0, 0),
			},
			"recover": {
				"spine_upper": Vector3(16, 0, 0), "hips": Vector3(8, 0, 0),
				"head": Vector3(11, 0, 0),
				"l_upper_arm": Vector3(20, 0, 6), "r_upper_arm": Vector3(20, 0, -6),
				"l_forearm": Vector3(30, 0, 0), "r_forearm": Vector3(30, 0, 0),
				"l_thigh": Vector3(9, 0, 0), "r_thigh": Vector3(9, 0, 0),
			},
		},
		PIERCE: {
			"length": 0.52, "hit": 0.30, "label": "Bent back, arms flung wide",
			"jerk": {
				"spine_upper": Vector3(-22, 0, 0), "hips": Vector3(-10, 0, 0),
				"head": Vector3(-18, 0, 0),
				"l_upper_arm": Vector3(-28, 0, -40), "r_upper_arm": Vector3(-28, 0, 40),
				"l_forearm": Vector3(20, 0, 0), "r_forearm": Vector3(20, 0, 0),
				"l_thigh": Vector3(-6, 0, 0), "r_thigh": Vector3(-6, 0, 0),
			},
			"peak": {
				"spine_upper": Vector3(-38, 0, 3), "hips": Vector3(-18, 0, 0),
				"head": Vector3(-30, 0, 0),
				"l_upper_arm": Vector3(-44, 0, -62), "r_upper_arm": Vector3(-44, 0, 62),
				"l_forearm": Vector3(32, 0, 0), "r_forearm": Vector3(32, 0, 0),
				"l_thigh": Vector3(-12, 0, 0), "r_thigh": Vector3(-12, 0, 0),
			},
			"recover": {
				"spine_upper": Vector3(-14, 0, 1), "hips": Vector3(-7, 0, 0),
				"head": Vector3(-11, 0, 0),
				"l_upper_arm": Vector3(-17, 0, -24), "r_upper_arm": Vector3(-17, 0, 24),
				"l_forearm": Vector3(12, 0, 0), "r_forearm": Vector3(12, 0, 0),
				"l_thigh": Vector3(-5, 0, 0), "r_thigh": Vector3(-5, 0, 0),
			},
		},
	},
}


# --- Queries -----------------------------------------------------------------

static func kind_for(is_zombie: bool) -> StringName:
	return KIND_SHAMBLER if is_zombie else KIND_HUMAN


static func has(kind: StringName, impact: StringName) -> bool:
	return DEFS.has(kind) and (DEFS[kind] as Dictionary).has(impact)


static func clip_name(kind: StringName, impact: StringName) -> StringName:
	return StringName("hit_%s_%s" % [kind, impact])


static func clip_path(kind: StringName, impact: StringName) -> String:
	return "%s/%s" % [LIB_NAME, clip_name(kind, impact)]


static func clip_length(kind: StringName, impact: StringName) -> float:
	return float((DEFS.get(kind, {}) as Dictionary).get(impact, {}).get("length", 0.4))


static func label(kind: StringName, impact: StringName) -> String:
	return String((DEFS.get(kind, {}) as Dictionary).get(impact, {}).get("label", ""))


## Impact family for a weapon class (blade/axe -> slash, blunt/fist -> crush,
## polearm -> pierce). Unknown classes fold onto crush, the most generic read.
static func impact_for(melee_type: StringName) -> StringName:
	return MeleeTypes.impact(melee_type)


## A heavier blow snaps faster. force is the hit's damage normalised around a
## 20-damage reference blow (see MeleeCombat).
static func speed_scale(force: float) -> float:
	return clampf(1.0 + (force - 1.0) * 0.18, 0.90, 1.35)


# --- Build -------------------------------------------------------------------

static func build_library(kind: StringName, articulated := true) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for impact in IMPACTS:
		if has(kind, impact):
			lib.add_animation(clip_name(kind, impact), build_clip(kind, impact, articulated))
	return lib


static func build_clip(kind: StringName, impact: StringName, articulated := true) -> Animation:
	var def: Dictionary = (DEFS[kind] as Dictionary)[impact]
	var length := float(def["length"])
	var hit := float(def["hit"])
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_NONE
	anim.set_meta(&"hit_frac", hit)
	anim.set_meta(&"impact", impact)
	anim.set_meta(&"kind", kind)
	anim.set_meta(&"label", String(def.get("label", "")))

	# rest -> jerk -> peak (the hit reads here) -> recover -> rest.
	var t_jerk := hit * 0.5
	var t_peak := hit
	var t_recover := hit + (1.0 - hit) * 0.6
	var bones: Array[String] = BASE_BONES.duplicate()
	if articulated:
		bones.append_array(FORE_BONES)

	for bone in bones:
		var keys: Array = [
			[0.0, Vector3.ZERO],
			[t_jerk * length, _pose(def["jerk"], bone)],
			[t_peak * length, _pose(def["peak"], bone)],
			[t_recover * length, _pose(def["recover"], bone)],
			[1.0 * length, Vector3.ZERO],
		]
		_add_rotation_track(anim, bone, keys)
	return anim


static func _pose(dict: Dictionary, bone: String) -> Vector3:
	return dict.get(bone, Vector3.ZERO) as Vector3


static func _add_rotation_track(anim: Animation, bone: String, keys: Array) -> void:
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, NodePath(":%s" % bone))
	for k in keys:
		anim.track_insert_key(t, float(k[0]), _quat_from_euler_deg(k[1] as Vector3))


static func _quat_from_euler_deg(deg: Vector3) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y),
			deg_to_rad(deg.z)))
