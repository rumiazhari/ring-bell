class_name IllustratedCommoner
extends RefCounted
const Proportions = preload("res://actors/player_proportions.gd")
## Authored profiles and facial surfaces; all positions match the existing rig.
## Every visible part is an ArrayMesh, directly beneath its attachment pivot.

static func fabric_texture() -> ImageTexture:
	var image := Image.create(128, 128, false, Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var grain := sin(float(x * 127 + y * 311)) * 0.016
			var brush := sin(x * 0.18 + sin(y * 0.08)) * 0.022
			var weave := 0.018 if (x + y) % 4 == 0 else 0.0
			var tone := 0.96 + grain + brush - weave
			image.set_pixel(x, y, Color(tone, tone, tone))
	return ImageTexture.create_from_image(image)


static func material(color: String, metal := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color)
	m.roughness = 0.48 if metal else 0.94
	m.metallic = 0.65 if metal else 0.0
	m.vertex_color_use_as_albedo = true
	return m


static func surface(parent: Node3D, label: String, vertices: PackedVector3Array,
		indices: PackedInt32Array, mat: Material, colors := PackedColorArray()) -> MeshInstance3D:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		var n := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		normals[a] += n
		normals[b] += n
		normals[c] += n
	for i in normals.size():
		normals[i] = normals[i].normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var uv := PackedVector2Array()
	for vertex in vertices:
		uv.append(Vector2(vertex.x * 4.0, vertex.y * 4.0))
	arrays[Mesh.ARRAY_TEX_UV] = uv
	# Godot front faces use clockwise winding; normals above use outward cross products.
	var clockwise := indices.duplicate()
	for i in range(0, clockwise.size(), 3):
		var old := clockwise[i + 1]
		clockwise[i + 1] = clockwise[i + 2]
		clockwise[i + 2] = old
	arrays[Mesh.ARRAY_INDEX] = clockwise
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var part := MeshInstance3D.new()
	part.name = label
	part.set_meta("authored_part", label)
	part.mesh = mesh
	part.material_override = mat
	parent.add_child(part)
	return part


## Sections: (height, half width, half depth, forward offset), bottom to top.
static func loft(parent: Node3D, label: String, sections: Array, mat: Material,
		segments := 24) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var colors := PackedColorArray()
	for r in sections.size():
		var s: Vector4 = sections[r]
		for c in segments:
			var a := TAU * c / segments
			vertices.append(Vector3(cos(a) * s.y, s.x, sin(a) * s.z + s.w))
			var tone := 0.94 + 0.06 * sin(a)
			colors.append(Color(tone, tone, tone, 1.0))
			if r > 0:
				var p := (r - 1) * segments + c
				var q := (r - 1) * segments + (c + 1) % segments
				indices.append_array(PackedInt32Array([p, p + segments, q + segments, p, q + segments, q]))
	return surface(parent, label, vertices, indices, mat, colors)


static func ribbon(parent: Node3D, label: String, points: Array, width: float, mat: Material) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in points.size():
		var tangent: Vector3 = points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]
		var side := tangent.cross(Vector3.FORWARD).normalized() * width * 0.5
		vertices.append(points[i] - side)
		vertices.append(points[i] + side)
		if i > 0:
			var a := (i - 1) * 2
			indices.append_array(PackedInt32Array([a, a + 2, a + 3, a, a + 3, a + 1]))
	var m := mat.duplicate() as StandardMaterial3D
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return surface(parent, label, vertices, indices, m)


## Front-facing elliptical inset, used for eyes and small worn metal closures.
static func inset(parent: Node3D, label: String, center: Vector3, size: Vector2, mat: Material) -> MeshInstance3D:
	var vertices := PackedVector3Array([center + Vector3(0, 0, 0.002)])
	var indices := PackedInt32Array()
	for i in 24:
		var a := TAU * i / 24.0
		vertices.append(center + Vector3(cos(a) * size.x, sin(a) * size.y, 0))
		indices.append_array(PackedInt32Array([0, i + 1, (i + 1) % 24 + 1]))
	return surface(parent, label, vertices, indices, mat)


static func face_point(x: float, y: float, lift := 0.0) -> Vector3:
	var t2 := pow(x / (0.099 * (1.0 + minf(y, 0.0) * 2.1)), 2) + pow(y / 0.137, 2)
	var z := 0.078 + 0.050 * (1.0 - t2)
	z += 0.036 * exp(-pow(x / 0.016, 2) - pow((y + 0.014) / 0.025, 2))
	z += 0.013 * exp(-pow(x / 0.014, 2) - pow((y - 0.015) / 0.052, 2))
	return Vector3(x, 0.785 + y, z + lift)


static func face(parent: Node3D, skin: Material, ink: Material) -> void:
	# The radial boundary narrows at the jaw. Relief supplies brow, cheeks and nose.
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var colors := PackedColorArray()
	for r in 13:
		var t := float(r) / 12.0
		for c in 48:
			var angle := TAU * c / 48.0
			var y := sin(angle) * 0.137 * t
			var x := cos(angle) * 0.099 * t * (1.0 + minf(y, 0.0) * 2.1)
			vertices.append(face_point(x, y))
			var blush := exp(-pow((absf(x) - 0.060) / 0.024, 2) - pow((y + 0.020) / 0.025, 2))
			colors.append(Color(1.0, 0.98 - blush * 0.085, 0.95 - blush * 0.06))
			if r > 0:
				var a := (r - 1) * 48 + c
				var b := (r - 1) * 48 + (c + 1) % 48
				indices.append_array(PackedInt32Array([a, a + 48, b + 48, a, b + 48, b]))
	surface(parent, "SculptedFace", vertices, indices, skin, colors)
	# Gentle expression, small irises and explicit upper eyelids.
	var sclera := material("d9ccc0")
	var iris := material("635e4a")
	var lips := material("ae7771")
	for side in [-1.0, 1.0]:
		var x: float = side * 0.044
		inset(parent, "Eye", face_point(x, 0.026, 0.004), Vector2(0.019, 0.007), sclera)
		inset(parent, "Iris", face_point(x, 0.026, 0.007), Vector2(0.006, 0.006), iris)
		inset(parent, "Pupil", face_point(x, 0.026, 0.010), Vector2(0.0026, 0.004), ink)
		var lid: Array = []
		var brow: Array = []
		for i in 9:
			var t := i / 8.0
			lid.append(face_point(x - 0.020 + t * 0.040, 0.026 + sin(t * PI) * 0.007, 0.006))
			brow.append(face_point(x - 0.020 + t * 0.040, 0.051 + sin(t * PI) * 0.006, 0.004))
		ribbon(parent, "UpperLid", lid, 0.002, ink)
		ribbon(parent, "Brow", brow, 0.003, ink)
		ribbon(parent, "Nostril", [face_point(side * 0.009, -0.025, 0.003), face_point(side * 0.016, -0.024, 0.003)], 0.0015, lips)
	var mouth: Array = []
	for i in 13:
		var x := -0.022 + i / 12.0 * 0.044
		mouth.append(face_point(x, -0.050 + 0.002 * cos(x * 140.0), 0.003))
	ribbon(parent, "Lips", mouth, 0.004, lips)



static func hood(parent: Node3D, mat: Material, seam: Material) -> void:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	# Rings around face opening, then wrapping over the skull toward the nape.
	var rings := [Vector3(0.102, 0.142, 0.087), Vector3(0.117, 0.161, 0.065), Vector3(0.132, 0.174, 0.015), Vector3(0.123, 0.162, -0.072), Vector3(0.083, 0.116, -0.131), Vector3(0.001, 0.001, -0.155)]
	for r in rings.size():
		for c in 48:
			var a := TAU * c / 48.0
			var ring: Vector3 = rings[r]
			var fold := 0.003 * sin(a * 5.0 + r * 0.4)
			vertices.append(Vector3(cos(a) * (ring.x + fold) * (1.0 + minf(sin(a) * 0.142, 0.0) * 2.1 if r < 2 else 1.0), 0.785 + sin(a) * ring.y, ring.z))
			var tone := 0.94 + 0.06 * cos(a * 5.0 + r * 0.4)
			colors.append(Color(tone, tone, tone))
			if r > 0:
				var p := (r - 1) * 48 + c
				var q := (r - 1) * 48 + (c + 1) % 48
				indices.append_array(PackedInt32Array([p, p + 48, q + 48, p, q + 48, q]))
	surface(parent, "WrappedHijab", vertices, indices, mat, colors)
	var edge: Array = []
	for i in 49:
		var a := TAU * i / 48.0
		edge.append(Vector3(cos(a) * 0.103 * (1.0 + minf(sin(a) * 0.143, 0.0) * 2.1), 0.785 + sin(a) * 0.143, 0.089))
	ribbon(parent, "HijabBoundEdge", edge, 0.006, seam)


static func build(cfg: Dictionary) -> Node3D:
	var wool := material("465553")
	var vest := material("635e50")
	wool.albedo_texture = fabric_texture()
	vest.albedo_texture = wool.albedo_texture
	var scarf := material("b6aa91")
	scarf.albedo_texture = wool.albedo_texture
	var binding := material("786c57")
	var leather := material("4a3429")
	var brass := material("a88b52", true)
	var skin := material("f0d5c4")
	skin.albedo_color = cfg.get("skin", Color("f0d5c4"))
	var ink := material("493a35")
	var root := Node3D.new()
	root.name = "Model"
	root.set_meta("shirt_material", wool)
	root.set_meta("skin_material", skin)
	root.set_meta("all_materials", [wool, vest, scarf, binding, leather, brass, skin, ink])
	root.set_meta("authored_commoner", true)
	var upper := HumanoidModel._joint(root, Vector3(0, Proportions.SPINE_Y, 0))
	var left_leg := HumanoidModel._joint(root, Vector3(-0.11, Proportions.HIP_Y, 0))
	var right_leg := HumanoidModel._joint(root, Vector3(0.11, Proportions.HIP_Y, 0))
	var left_arm := HumanoidModel._joint(upper, Vector3(-Proportions.SHOULDER_HALF_WIDTH, Proportions.SHOULDER_Y - Proportions.SPINE_Y, 0))
	var right_arm := HumanoidModel._joint(upper, Vector3(Proportions.SHOULDER_HALF_WIDTH, Proportions.SHOULDER_Y - Proportions.SPINE_Y, 0))
	var left_forearm := HumanoidModel._joint(left_arm, Vector3(0, -Proportions.UPPER_ARM, 0))
	var right_forearm := HumanoidModel._joint(right_arm, Vector3(0, -Proportions.UPPER_ARM, 0))
	var left_calf := HumanoidModel._joint(left_leg, Vector3(0, -Proportions.THIGH_LENGTH, 0))
	var right_calf := HumanoidModel._joint(right_leg, Vector3(0, -Proportions.THIGH_LENGTH, 0))
	# Shaped shoulders, chest, natural waist and overlapping peplum; no cylinder.
	loft(upper, "TailoredGamis", [Vector4(-0.13, 0.229, 0.143, 0), Vector4(-0.07, 0.222, 0.137, 0), Vector4(0.05, 0.183, 0.119, 0), Vector4(0.19, 0.190, 0.132, 0.008), Vector4(0.35, 0.218, 0.149, 0.003), Vector4(0.47, 0.216, 0.119, -0.003), Vector4(0.54, 0.143, 0.093, 0), Vector4(0.57, 0.08, 0.070, 0)], wool)
	# Quiet waistcoat panel rather than a corset; seams follow the shaped bodice.
	for side in [-1.0, 1.0]:
		ribbon(upper, "BodiceSeam", [Vector3(side * 0.12, -0.075, 0.126), Vector3(side * 0.082, 0.06, 0.112), Vector3(side * 0.105, 0.25, 0.137), Vector3(side * 0.14, 0.43, 0.101)], 0.010, binding)
	ribbon(upper, "ButtonPlacket", [Vector3(0, -0.07, 0.141), Vector3(0, 0.07, 0.128), Vector3(0, 0.27, 0.157), Vector3(0, 0.50, 0.112)], 0.030, vest)
	for i in 5:
		var y := 0.04 + i * 0.085
		inset(upper, "BrassButton", Vector3(0, y, 0.151 if y > 0.16 else 0.136), Vector2(0.006, 0.007), brass)
	loft(upper, "LeatherBelt", [Vector4(-0.060, 0.216, 0.143, 0), Vector4(-0.023, 0.205, 0.139, 0)], leather)
	ribbon(upper, "BeltBuckle", [Vector3(-0.025, -0.058, 0.147), Vector3(-0.025, -0.022, 0.147), Vector3(0.025, -0.022, 0.147), Vector3(0.025, -0.058, 0.147), Vector3(-0.025, -0.058, 0.147)], 0.006, brass)
	var chain: Array = []
	for i in 20:
		var t := i / 19.0
		chain.append(Vector3(0.02 + t * 0.15, 0.05 - sin(t * PI) * 0.047, 0.143 - t * 0.025))
	ribbon(upper, "WatchChain", chain, 0.003, brass)
	var pouch := loft(upper, "WorkPouch", [Vector4(-0.25, 0.045, 0.023, 0), Vector4(-0.23, 0.065, 0.034, 0), Vector4(-0.08, 0.065, 0.030, 0), Vector4(-0.06, 0.055, 0.023, 0)], leather, 16)
	pouch.position = Vector3(0.22, 0, 0.06)
	inset(upper, "PouchClasp", Vector3(0.22, -0.10, 0.094), Vector2(0.007, 0.009), brass)
	loft(upper, "ScarfNeckWrap", [Vector4(0.51, 0.105, 0.083, -0.01), Vector4(0.56, 0.113, 0.085, -0.01), Vector4(0.63, 0.095, 0.074, -0.02), Vector4(0.69, 0.090, 0.070, -0.02)], scarf)
	var head_start := upper.get_child_count()
	loft(upper, "JawAndTemples", [Vector4(0.651, 0.012, 0.010, 0.064), Vector4(0.674, 0.047, 0.042, 0.044), Vector4(0.730, 0.084, 0.065, 0.022), Vector4(0.815, 0.095, 0.070, 0.005), Vector4(0.884, 0.075, 0.062, 0.010), Vector4(0.921, 0.001, 0.001, 0.016)], skin, 32)
	hood(upper, scarf, binding)
	face(upper, skin, ink)
	for i in range(head_start, upper.get_child_count()):
		var head_part := upper.get_child(i) as Node3D
		head_part.scale = Proportions.HEAD_SCALE
		head_part.position.y = Proportions.HEAD_CENTER - Proportions.SPINE_Y - 0.785 * Proportions.HEAD_SCALE.y
		head_part.set_meta("anatomical_head", true)
	loft(upper, "KhimarUnderlayer", [Vector4(0.20, 0.22, 0.165, 0), Vector4(0.32, 0.25, 0.170, 0), Vector4(0.45, 0.24, 0.145, 0), Vector4(0.58, 0.115, 0.095, 0), Vector4(0.65, 0.10, 0.080, 0)], scarf)
	var veil := SkirtCloth.new()
	veil.name = "HijabDrape"
	veil.setup(0.108, 0.325, 0.42, 24, 7, scarf)
	veil.oval = Vector2(1.0, 0.78)
	veil.gather = 0.009
	veil.bending = 0.15
	veil.trim_start = 0.98
	veil.trim_color = Color("b4aa96")
	veil.position = Vector3(0, 0.67, -0.025)
	upper.add_child(veil)
	var skirt := SkirtCloth.new()
	skirt.name = "CoatHem"
	skirt.setup(0.225, 0.295, 0.36, 24, 6, wool)
	skirt.oval = Vector2(1.0, 0.84)
	skirt.gather = 0.012
	skirt.bending = 0.30
	skirt.trim_start = 0.86
	skirt.trim_color = Color("aca89c")
	root.add_child(skirt)
	for arm in [left_arm, right_arm]:
		loft(arm, "GatheredShoulder", [Vector4(0.0, 0.078, 0.071, 0), Vector4(0.025, 0.069, 0.063, 0), Vector4(0.045, 0.050, 0.045, 0), Vector4(0.065, 0.001, 0.001, 0)], wool, 12)
		var sleeve := SkirtCloth.new()
		sleeve.name = "GamisSleeve"
		sleeve.setup(0.078, 0.048, Proportions.UPPER_ARM + Proportions.FOREARM, 12, 6, wool)
		sleeve.profile = PackedFloat32Array([0.078, 0.087, 0.081, 0.071, 0.060, 0.053, 0.048])
		sleeve.oval = Vector2(1, 0.91)
		sleeve.gather = 0.006
		sleeve.bending = 0.20
		sleeve.pin_hem = true
		sleeve.hem_bone = "l_forearm" if arm == left_arm else "r_forearm"
		sleeve.hem_offset = Vector3(0, -Proportions.FOREARM, 0)
		sleeve.position = Vector3.ZERO
		arm.add_child(sleeve)
		loft(arm, "ButtonedCuff", [Vector4(-0.515, 0.057, 0.052, 0), Vector4(-0.49, 0.050, 0.0456, 0)], vest, 12)
		inset(arm, "CuffButton", Vector3(0, -0.49, 0.059), Vector2(0.004, 0.004), brass)
		loft(arm, "Hand", [Vector4(-0.605, 0.025, 0.019, 0.008), Vector4(-0.59, 0.030, 0.022, 0.005), Vector4(-0.57, 0.037, 0.024, 0), Vector4(-0.535, 0.031, 0.023, 0), Vector4(-0.51, 0.025, 0.021, 0)], leather, 20)
		var thumb := loft(arm, "Thumb", [Vector4(-0.601, 0.005, 0.008, 0.006), Vector4(-0.58, 0.012, 0.013, 0), Vector4(-0.55, 0.015, 0.016, -0.002)], leather, 12)
		thumb.position.x = -0.032 if arm == left_arm else 0.032
		for finger in 4:
			var tip := -0.648 + absf(finger - 1.4) * 0.009
			var finger_mesh := loft(arm, "Finger", [Vector4(tip, 0.002, 0.002, 0.011), Vector4(tip + 0.006, 0.007, 0.008, 0.010), Vector4(-0.594, 0.008, 0.010, 0.008)], leather, 10)
			finger_mesh.position.x = -0.025 + finger * 0.016

		var forearm: Node3D = left_forearm if arm == left_arm else right_forearm
		for part in arm.get_children():
			if part is MeshInstance3D and String(part.name).begins_with("GamisSleeve") == false and String(part.name) != "GatheredShoulder":
				arm.remove_child(part)
				# Old mesh wrist=-.51 and fingertips=-.648; fit locally before reparenting.
				var hand_scale := Proportions.HAND / 0.138
				part.scale.y = hand_scale
				part.position.y = -Proportions.FOREARM + 0.51 * hand_scale
				part.scale.x = 0.88
				part.scale.z = 0.90
				forearm.add_child(part)
	for leg in [left_leg, right_leg]:
		var calf: Node3D = left_calf if leg == left_leg else right_calf
		var joint = load("res://actors/garment_joint.gd").new()
		joint.name = "SewnTrouserKnee"
		joint.upper_bone = "l_thigh" if leg == left_leg else "r_thigh"
		joint.lower_bone = "l_calf" if leg == left_leg else "r_calf"
		joint.material_override = vest
		calf.add_child(joint)
		loft(leg, "RoomyTrouserThigh", [Vector4(-0.42, 0.087, 0.090, 0), Vector4(-0.34, 0.105, 0.112, 0), Vector4(-0.12, 0.115, 0.118, 0), Vector4(0, 0.102, 0.107, 0)], vest, 24)
		loft(calf, "RoomyTrouserCalf", [Vector4(-0.35, 0.062, 0.066, 0), Vector4(-0.25, 0.090, 0.098, 0), Vector4(-0.10, 0.103, 0.108, 0), Vector4(0.015, 0.088, 0.091, 0)], vest, 24)
		loft(calf, "LeatherBoot", [Vector4(-0.47, 0.065, 0.116, 0.040), Vector4(-0.44, 0.068, 0.120, 0.040), Vector4(-0.39, 0.062, 0.105, 0.030), Vector4(-0.30, 0.051, 0.064, 0.008), Vector4(-0.17, 0.057, 0.058, 0)], leather, 24)
		loft(calf, "BootSole", [Vector4(-0.49, 0.068, 0.123, 0.04), Vector4(-0.465, 0.068, 0.123, 0.04)], ink, 24)
		for i in 3:
			ribbon(calf, "BootLace", [Vector3(-0.033, -0.24 - i * 0.028, 0.061), Vector3(0.033, -0.256 - i * 0.028, 0.068)], 0.003, binding)
	# Working backpack with shoulder straps; no decorative gear clutter.
	var pack := loft(upper, "Backpack", [Vector4(-0.01, 0.12, 0.068, 0), Vector4(0.03, 0.16, 0.09, 0), Vector4(0.36, 0.16, 0.09, 0), Vector4(0.44, 0.12, 0.06, 0), Vector4(0.46, 0.005, 0.005, 0)], leather, 24)
	pack.position.z = -0.245
	ribbon(upper, "BackpackFlap", [Vector3(-0.13, 0.35, -0.338), Vector3(-0.08, 0.29, -0.343), Vector3(0.0, 0.27, -0.344), Vector3(0.08, 0.29, -0.343), Vector3(0.13, 0.35, -0.338)], 0.06, binding)
	var pack_clasp := inset(upper, "PackBuckle", Vector3(0, 0.28, 0.349), Vector2(0.012, 0.017), brass)
	pack_clasp.rotation.y = PI
	for side in [-1.0, 1.0]:
		ribbon(upper, "PackStrap", [Vector3(side * 0.14, 0.02, 0.12), Vector3(side * 0.16, 0.28, 0.13), Vector3(side * 0.15, 0.49, 0.06), Vector3(side * 0.13, 0.53, -0.12), Vector3(side * 0.12, 0.38, -0.31)], 0.028, leather)
	var red := material("913b3c")
	red.albedo_texture = wool.albedo_texture
	loft(upper, "RedNeckVeil", [Vector4(0.585, 0.155, 0.145, -0.012), Vector4(0.622, 0.158, 0.146, -0.012), Vector4(0.658, 0.152, 0.142, -0.014)], red)
	var tail := SkirtCloth.new()
	tail.name = "RedVeilTail"
	tail.setup(0.07, 0.09, 0.51, 7, 8, red)
	tail.open_panel = true
	tail.bending = 0.12
	tail.gather = 0.012
	ribbon(upper, "RedScarfOverShoulder", [Vector3(0.055, 0.625, -0.11), Vector3(0.055, 0.595, -0.18), Vector3(0.055, 0.55, -0.29), Vector3(0.055, 0.48, -0.365)], 0.14, red)
	tail.position = Vector3(0.055, 0.48, -0.365)
	upper.add_child(tail)

	# Authored torso coordinates were for the old elongated torso. Bake the fit
	# into static vertices and cloth rest dimensions; attachment transforms stay unit scale.
	for part in upper.get_children():
		if part is MeshInstance3D and not part.get_meta("anatomical_head", false):
			_fit_torso_part(part)
	HumanoidModel._store_limbs(root, upper, left_arm, right_arm, left_leg, right_leg)
	var limbs: Dictionary = root.get_meta("anim_limbs")
	limbs["l_forearm"] = left_forearm
	limbs["r_forearm"] = right_forearm
	limbs["l_calf"] = left_calf
	limbs["r_calf"] = right_calf
	return root


static func _fit_torso_part(part: MeshInstance3D) -> void:
	var fit := Vector3(0.88, 0.80, 0.92)
	var lift := 0.0
	if String(part.name) in ["LeatherBelt", "BeltBuckle", "WorkPouch", "PouchClasp", "WatchChain"]:
		lift = 0.10 # natural waist at 1.05m, distinct from hip articulation at .90m
	if String(part.name) in ["RedNeckVeil", "RedScarfOverShoulder", "RedVeilTail"]:
		lift = -0.04
	part.position = part.position * fit + Vector3.UP * lift
	if part is SkirtCloth:
		part.length *= fit.y
		part.radius_top *= fit.x
		part.radius_hem *= fit.x
		part.oval.y *= fit.z / fit.x
		return
	var arrays := part.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in vertices.size():
		vertices[i] *= fit
		normals[i] = (normals[i] / fit).normalized()
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	var fitted := ArrayMesh.new()
	fitted.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	part.mesh = fitted
