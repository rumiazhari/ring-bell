class_name HumanoidModel
extends RefCounted
## Procedural low-poly human bodies built from primitive meshes, with REAL
## JOINT PIVOTS so HumanoidAnimator can swing limbs for walk/run/air/idle/
## attack poses.
##
## Two flavors:
##   build_human()  - living humans; female variant wears a skirt and has
##                    narrower shoulders + longer hair (the player is one).
##   build_zombie() - bloody rotten corpses-that-walk: rotten skin tones,
##                    torn clothing, blood spatter, occasional missing arm,
##                    hunched posture, per-instance seeded variation.
##
## Hierarchy (origin at FEET, local +Z = facing):
##   root
##   ├─ l_leg / r_leg pivots (hip joints, y≈0.86)
##   └─ upper pivot (waist, y≈0.95) -> torso/head/hair + arm pivots
##
## Meta exposed on root:
##   "anim_limbs": {l_arm, r_arm, l_leg, r_leg, upper} pivot nodes
##   "shirt_material" / "skin_material" / "all_materials" for retinting.

const BLOOD := Color(0.42, 0.05, 0.04)
const BLOOD_DARK := Color(0.28, 0.03, 0.03)

# Bodies sized UP to match the old 0.35r/1.7h capsule bulk.
const HUMAN_SCALE := 1.2
const ZOMBIE_SCALE_MIN := 1.1
const ZOMBIE_SCALE_MAX := 1.24

const ZOMBIE_SKINS := [
	Color("7d8a63"), Color("6f7c58"), Color("8b9070"),
	Color("75705e"), Color("93987f"),
]
const ZOMBIE_SHIRTS := [
	Color("4a4438"), Color("3d4a52"), Color("54423a"),
	Color("42503c"), Color("5a5248"),
]
const ZOMBIE_PANTS := [
	Color("33383c"), Color("40372e"), Color("2f3a32"),
]
const HUMAN_HAIRS := [
	Color("2a2018"), Color("4a3520"), Color("6e5233"),
	Color("8a8078"), Color("1c1a18"), Color("93643c"),
]


static func _mat(color: Color, roughness := 0.95) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat


static func _part(root: Node3D, mesh: Mesh, pos: Vector3,
		material: StandardMaterial3D, rot_deg := Vector3.ZERO) \
		-> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = material
	root.add_child(mi)
	return mi


static func _box(root: Node3D, size: Vector3, pos: Vector3,
		material: StandardMaterial3D, rot_deg := Vector3.ZERO) \
		-> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _part(root, box, pos, material, rot_deg)


static func _capsule(radius: float, height: float) -> CapsuleMesh:
	var capsule := CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = height
	return capsule


## A joint pivot: animator swings this node; the limb mesh hangs below it.
static func _joint(parent: Node3D, joint_pos: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = joint_pos
	parent.add_child(pivot)
	return pivot


static func _store_limbs(root: Node3D, upper: Node3D,
		l_arm: Node3D, r_arm: Node3D, l_leg: Node3D, r_leg: Node3D) -> void:
	root.set_meta("anim_limbs", {
		"upper": upper, "l_arm": l_arm, "r_arm": r_arm,
		"l_leg": l_leg, "r_leg": r_leg,
	})


# --- Living humans -----------------------------------------------------------

## cfg keys: female(bool), skin, shirt, pants, hair, boots(Color).
static func build_human(cfg: Dictionary) -> Node3D:
	var female := bool(cfg.get("female", false))
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var skin: Color = cfg.get("skin", Color(0.87, 0.7, 0.58))
	var shirt_c: Color = cfg.get("shirt", Color(0.5, 0.55, 0.62))
	var pants_c: Color = cfg.get("pants", Color(0.28, 0.3, 0.34))
	var hair_c: Color = cfg.get("hair",
			HUMAN_HAIRS[rng.randi_range(0, HUMAN_HAIRS.size() - 1)])

	var skin_m := _mat(skin)
	var shirt_m := _mat(shirt_c)
	var pants_m := _mat(pants_c)
	var hair_m := _mat(hair_c)
	var boot_m := _mat(cfg.get("boots", Color("3a2f26")))
	var skirt_m := _mat(shirt_c.darkened(0.12))
	var leg_skin_m := _mat(skin.lightened(0.1))

	var root := Node3D.new()
	root.name = "Model"
	root.set_meta("shirt_material", shirt_m)
	root.set_meta("skin_material", skin_m)
	root.set_meta("all_materials",
			[skin_m, shirt_m, pants_m, hair_m, boot_m, skirt_m] as Array)

	var shoulder := 0.19 if female else 0.23   # half-width

	# --- Legs (hip pivots at y 0.86). ---
	var l_leg := _joint(root, Vector3(-0.11, 0.86, 0))
	var r_leg := _joint(root, Vector3(0.11, 0.86, 0))
	for side in [-1.0, 1.0]:
		var leg: Node3D = l_leg if side < 0 else r_leg
		if female:
			_box(leg, Vector3(0.12, 0.5, 0.14), Vector3(0, -0.25, 0),
					leg_skin_m)
			_box(leg, Vector3(0.14, 0.08, 0.24), Vector3(0, -0.47, 0.04),
					boot_m)
		else:
			_box(leg, Vector3(0.16, 0.84, 0.18), Vector3(0, -0.42, 0),
					pants_m)
			_box(leg, Vector3(0.14, 0.08, 0.24), Vector3(0, -0.82, 0.04),
					boot_m)

	if female:
		# Skirt: real cloth sim (verlet ring grid pinned at the waist).
		var skirt := SkirtCloth.new()
		skirt.setup(0.19, 0.46, 0.58, 10, 4, skirt_m)
		root.add_child(skirt)

	# --- Upper body pivot (waist) so runs lean and idles breathe. ---
	var upper := _joint(root, Vector3(0, 0.95, 0))

	# Torso, neck, head.
	_box(upper, Vector3(shoulder * 2.0, 0.54, 0.23),
			Vector3(0, 0.29, 0), shirt_m)
	_part(upper, _capsule(0.06, 0.15), Vector3(0, 0.61, 0), skin_m)
	_part(upper, _capsule(0.125, 0.29), Vector3(0, 0.78, 0.005), skin_m)
	# Nose bump doubles as the facing cue (+Z).
	_box(upper, Vector3(0.05, 0.065, 0.07),
			Vector3(0, 0.78, 0.125), _mat(skin.darkened(0.08)))
	for side in [-1.0, 1.0]:
		_box(upper, Vector3(0.05, 0.02, 0.02),
				Vector3(side * 0.055, 0.82, 0.118), hair_m)

	# Hair.
	if female:
		_box(upper, Vector3(0.28, 0.26, 0.28),
				Vector3(0, 0.85, -0.02), hair_m)
		_box(upper, Vector3(0.24, 0.38, 0.11),
				Vector3(0, 0.64, -0.13), hair_m)
	else:
		_box(upper, Vector3(0.27, 0.13, 0.275),
				Vector3(0, 0.89, -0.01), hair_m)

	# --- Arms (shoulder pivots on the upper body). ---
	var l_arm := _joint(upper, Vector3(-(shoulder + 0.06), 0.51, 0))
	var r_arm := _joint(upper, Vector3(shoulder + 0.06, 0.51, 0))
	for arm: Node3D in [l_arm, r_arm]:
		_box(arm, Vector3(0.11, 0.5, 0.13), Vector3(0, -0.26, 0), shirt_m)
		_box(arm, Vector3(0.095, 0.15, 0.11), Vector3(0, -0.56, 0), skin_m)

	_store_limbs(root, upper, l_arm, r_arm, l_leg, r_leg)
	root.scale = Vector3.ONE * HUMAN_SCALE
	return root


# --- Zombies -----------------------------------------------------------------

static func build_zombie(rng: RandomNumberGenerator) -> Node3D:
	var skin_c: Color = ZOMBIE_SKINS[rng.randi_range(0, ZOMBIE_SKINS.size() - 1)]
	var shirt_c: Color = ZOMBIE_SHIRTS[rng.randi_range(
			0, ZOMBIE_SHIRTS.size() - 1)]
	var pants_c: Color = ZOMBIE_PANTS[rng.randi_range(
			0, ZOMBIE_PANTS.size() - 1)]

	var skin_m := _mat(skin_c)
	var shirt_m := _mat(shirt_c.darkened(rng.randf() * 0.15))
	var pants_m := _mat(pants_c)
	var blood_m := _mat(BLOOD, 0.6)
	var wound_m := _mat(BLOOD_DARK, 0.5)

	var root := Node3D.new()
	root.name = "Model"
	root.set_meta("shirt_material", shirt_m)
	root.set_meta("skin_material", skin_m)
	root.set_meta("all_materials",
			[skin_m, shirt_m, pants_m, blood_m, wound_m] as Array)

	# Legs (one may drag crooked).
	var l_leg := _joint(root, Vector3(-0.11, 0.86, 0))
	var r_leg := _joint(root, Vector3(0.11, 0.86, 0))
	var leg_tilt := rng.randf_range(-7.0, 7.0)
	_box(l_leg, Vector3(0.16, 0.84, 0.18), Vector3(0, -0.42, 0), pants_m,
			Vector3(leg_tilt, 0, 0))
	_box(r_leg, Vector3(0.16, 0.82, 0.18), Vector3(0, -0.41, 0), pants_m,
			Vector3(-leg_tilt, 0, 0))

	# Hunched upper body leaning toward +Z (the shamble silhouette).
	var upper := _joint(root, Vector3(0, 0.95, 0))
	upper.rotation_degrees.x = 12.0 + rng.randf() * 8.0

	_box(upper, Vector3(0.46, 0.56, 0.26), Vector3(0, 0.29, 0), shirt_m)
	# Exposed abdominal wound.
	_box(upper, Vector3(0.18, 0.22, 0.03),
			Vector3(rng.randf_range(-0.09, 0.09), 0.24, 0.135), wound_m)
	# Head tilted rotten, patchy scalp.
	var head_y := 0.76
	var head := _joint(upper, Vector3(0, head_y, 0.02))
	head.rotation_degrees.z = rng.randf_range(-12.0, 12.0)
	_part(head, _capsule(0.125, 0.29), Vector3.ZERO, skin_m)
	_box(head, Vector3(0.05, 0.065, 0.07), Vector3(0, 0, 0.115),
			_mat(skin_c.darkened(0.15)))
	if rng.randf() < 0.7:
		_box(head, Vector3(0.21, 0.07, 0.21),
				Vector3(rng.randf_range(-0.03, 0.03), 0.13, 0),
				_mat(Color("2a2620").darkened(rng.randf() * 0.3)))

	# Arms - sometimes one is GONE at the shoulder (stump capped with blood).
	var missing_side := 0.0
	if rng.randf() < 0.22:
		missing_side = -1.0 if rng.randf() < 0.5 else 1.0
		_box(upper, Vector3(0.11, 0.1, 0.11),
				Vector3(missing_side * 0.26, 0.5, 0), wound_m)
	var l_arm := _joint(upper, Vector3(-0.29, 0.49, 0))
	var r_arm := _joint(upper, Vector3(0.29, 0.49, 0))
	var droop := rng.randf_range(4.0, 10.0)
	if missing_side > -0.5:
		_box(l_arm, Vector3(0.11, 0.5, 0.13), Vector3(0, -0.26, 0), shirt_m,
				Vector3(droop, 0, 0))
		_box(l_arm, Vector3(0.095, 0.14, 0.11), Vector3(0, -0.55, 0), skin_m)
	if missing_side < 0.5:
		_box(r_arm, Vector3(0.11, 0.5, 0.13), Vector3(0, -0.26, 0), shirt_m,
				Vector3(droop * 0.6, 0, 0))
		_box(r_arm, Vector3(0.095, 0.14, 0.11), Vector3(0, -0.55, 0), skin_m)

	# Blood spatter: thin dark-red slabs slapped over torso/head/limbs.
	var patches := 4 + rng.randi_range(0, 4)
	for i in patches:
		var on_head := rng.randf() < 0.25
		var pos: Vector3
		if on_head:
			pos = Vector3(
					rng.randf_range(-0.11, 0.11),
					rng.randf_range(head_y - 0.1, head_y + 0.1),
					0.13 if rng.randf() < 0.5 else -0.13)
		else:
			pos = Vector3(
					rng.randf_range(-0.21, 0.21),
					rng.randf_range(0.08, 0.5),
					rng.randf_range(-0.14, 0.14))
		var size := Vector3(
				rng.randf_range(0.05, 0.17),
				rng.randf_range(0.06, 0.22),
				0.02)
		_box(upper, size, pos, blood_m if rng.randf() < 0.7 else wound_m)

	_store_limbs(root, upper, l_arm, r_arm, l_leg, r_leg)
	var s := rng.randf_range(ZOMBIE_SCALE_MIN, ZOMBIE_SCALE_MAX)
	root.scale = Vector3.ONE * s
	return root


## Recursively collect every MeshInstance3D under `root` - used for death
## tinting now that bodies are multi-part instead of one capsule.
static func collect_meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(collect_meshes(child))
	return out
