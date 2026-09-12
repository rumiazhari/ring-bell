class_name MeleeWeaponModels
extends RefCounted
## Procedural Victorian-steampunk melee weapon meshes.
##
## Every weapon in the game is built from primitives (see actors/humanoid_model.gd
## for the same approach on bodies), so these follow the house rules: no imported
## assets, deterministic geometry, shared material palette, no randomness.
##
## Convention: each weapon is authored along +Z with its grip at the origin.
## The blade/head extends to +Z, the pommel to -Z, so a hand attachment only has
## to rotate the root once (see MeleeCombat.hand_attach).
##
## Visual language (matches the city palette):
##   brass fittings, blued steel edges, cast iron bodies, oak hafts,
##   leather wraps, rivets, valve wheels and brass pressure gauges.

const BRASS := Color(0.72, 0.55, 0.22)
const BRASS_DARK := Color(0.42, 0.31, 0.12)
const BRASS_BRIGHT := Color(0.86, 0.70, 0.32)
const COPPER := Color(0.63, 0.34, 0.21)
const BLUED_STEEL := Color(0.20, 0.22, 0.27)
const POLISHED_STEEL := Color(0.62, 0.65, 0.70)
const CAST_IRON := Color(0.15, 0.15, 0.16)
const OAK := Color(0.34, 0.22, 0.10)
const MAHOGANY := Color(0.26, 0.13, 0.07)
const LEATHER := Color(0.19, 0.12, 0.07)
const DIAL_FACE := Color(0.87, 0.85, 0.72)
const LENS := Color(0.72, 0.78, 0.74)
## Warm gaslight: the one self-lit material in the set.
const GAS_FLAME := Color(1.0, 0.70, 0.32)
const LAMP_GLASS := Color(1.0, 0.80, 0.48)

## Model id -> builder. Keep in sync with MeleeTypes / ItemDB "model" fields.
const MODELS: Array[StringName] = [
	&"fists", &"kitchen_knife", &"cane_sabre", &"pipe",
	&"pipe_wrench", &"boarding_axe", &"boiler_lance",
]

static var _mat_cache: Dictionary = {}


# --- Palette -----------------------------------------------------------------

static func _mat(albedo: Color, metallic: float, roughness: float,
		emission: Color = Color(0, 0, 0, 0)) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f|%s" % [albedo.to_html(), metallic, roughness,
			emission.to_html()]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	if emission.a > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = 1.4
	_mat_cache[key] = m
	return m


static func brass() -> StandardMaterial3D:
	return _mat(BRASS, 0.90, 0.28)


static func brass_bright() -> StandardMaterial3D:
	return _mat(BRASS_BRIGHT, 0.95, 0.18)


static func blued() -> StandardMaterial3D:
	return _mat(BLUED_STEEL, 0.90, 0.30)


static func steel() -> StandardMaterial3D:
	return _mat(POLISHED_STEEL, 0.95, 0.18)


static func iron() -> StandardMaterial3D:
	return _mat(CAST_IRON, 0.75, 0.55)


static func oak() -> StandardMaterial3D:
	return _mat(OAK, 0.0, 0.85)


static func mahogany() -> StandardMaterial3D:
	return _mat(MAHOGANY, 0.0, 0.70)


static func leather() -> StandardMaterial3D:
	return _mat(LEATHER, 0.0, 0.92)


static func gauge_face() -> StandardMaterial3D:
	return _mat(DIAL_FACE, 0.05, 0.38)


static func gauge_lens() -> StandardMaterial3D:
	return _mat(LENS, 0.10, 0.10)


## Lit lamp glass. Emissive so a weapon still reads as a *steam* tool in an
## unlit street: this is the only self-lit material in the set.
static func gas_flame() -> StandardMaterial3D:
	return _mat(LAMP_GLASS, 0.0, 0.22, GAS_FLAME)


# --- Primitive helpers -------------------------------------------------------

static func _add(parent: Node3D, mesh: Mesh, mat: Material, part: String,
		pos: Vector3, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi


## Cylinder/cone along +Z (Godot cylinders are Y-axis, so rotate 90 about X).
static func _rod(parent: Node3D, mat: Material, part: String, z: float,
		length: float, radius: float, segments := 12,
		end_radius := -1.0) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.height = length
	cyl.bottom_radius = radius
	cyl.top_radius = end_radius if end_radius >= 0.0 else radius
	cyl.radial_segments = segments
	cyl.rings = 1
	return _add(parent, cyl, mat, part, Vector3(0, 0, z), Vector3(90, 0, 0))


static func _box(parent: Node3D, mat: Material, part: String, pos: Vector3,
		size: Vector3, rot_deg := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return _add(parent, b, mat, part, pos, rot_deg)


static func _sphere(parent: Node3D, mat: Material, part: String, pos: Vector3,
		radius: float, segments := 10) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	s.radial_segments = segments
	s.rings = maxi(3, segments / 2)
	return _add(parent, s, mat, part, pos)


static func _ring(parent: Node3D, mat: Material, part: String, z: float,
		outer: float, inner: float, rot_deg := Vector3(90, 0, 0)) -> MeshInstance3D:
	var t := TorusMesh.new()
	t.outer_radius = outer
	t.inner_radius = inner
	t.rings = 10
	t.ring_segments = 6
	return _add(parent, t, mat, part, Vector3(0, 0, z), rot_deg)


## Evenly spaced rivets around the barrel at z - deterministic, no randf.
static func _rivets(parent: Node3D, z: float, radius: float, count: int,
		scale := 1.0, mat: Material = null) -> void:
	var m: Material = mat if mat != null else brass_bright()
	var r := radius * 0.16 * scale
	for i in count:
		var a := TAU * float(i) / float(count)
		_sphere(parent, m, "Rivet%d" % i,
				Vector3(cos(a) * radius, sin(a) * radius, z), r, 6)


## Brass valve wheel: signature steampunk fitting used as guard/pommel.
static func _valve_wheel(parent: Node3D, part: String, z: float,
		radius: float, spokes := 5, roll_deg := 0.0) -> Node3D:
	var wheel := Node3D.new()
	wheel.name = part
	wheel.position = Vector3(0, 0, z)
	wheel.rotation_degrees = Vector3(0, 0, roll_deg)
	parent.add_child(wheel)
	_ring(wheel, brass(), "Rim", 0.0, radius, radius * 0.78)
	_sphere(wheel, brass_bright(), "Hub", Vector3.ZERO, radius * 0.22, 8)
	for i in spokes:
		var a := TAU * float(i) / float(spokes)
		var mid := Vector3(cos(a), sin(a), 0.0) * radius * 0.5
		var spoke := _box(wheel, brass(), "Spoke%d" % i, mid,
				Vector3(radius * 0.10, radius, radius * 0.08))
		spoke.rotation_degrees = Vector3(0, 0, rad_to_deg(a) - 90.0)
	return wheel


## Brass pressure gauge with dial face, lens and needle.
static func _gauge(parent: Node3D, part: String, pos: Vector3,
		radius: float, rot_deg := Vector3.ZERO, needle_deg := 40.0) -> Node3D:
	var g := Node3D.new()
	g.name = part
	g.position = pos
	g.rotation_degrees = rot_deg
	parent.add_child(g)
	var case := CylinderMesh.new()
	case.height = radius * 0.45
	case.bottom_radius = radius
	case.top_radius = radius
	case.radial_segments = 14
	_add(g, case, brass(), "Case", Vector3.ZERO, Vector3(90, 0, 0))
	var face := CylinderMesh.new()
	face.height = radius * 0.10
	face.bottom_radius = radius * 0.82
	face.top_radius = radius * 0.82
	face.radial_segments = 14
	_add(g, face, gauge_face(), "Face", Vector3(0, 0, -radius * 0.28), Vector3(90, 0, 0))
	var lens_mesh := CylinderMesh.new()
	lens_mesh.height = radius * 0.06
	lens_mesh.bottom_radius = radius * 0.80
	lens_mesh.top_radius = radius * 0.80
	lens_mesh.radial_segments = 12
	var lens_mi := _add(g, lens_mesh, gauge_lens(), "Lens",
			Vector3(0, 0, -radius * 0.34), Vector3(90, 0, 0))
	lens_mi.transparency = 0.35
	var needle := _box(g, iron(), "Needle",
			Vector3(0, 0, -radius * 0.40), Vector3(radius * 0.10, radius * 1.35, 0.004))
	needle.rotation_degrees = Vector3(0, 0, needle_deg)
	return g


## Hanging glass lamp: brass cage, lit glass, brass cap. The signature
## Victorian street-fitting that keeps the kit reading steampunk under gaslight.
static func _lamp(parent: Node3D, part: String, pos: Vector3, radius: float,
		rot_deg := Vector3.ZERO) -> Node3D:
	var lamp := Node3D.new()
	lamp.name = part
	lamp.position = pos
	lamp.rotation_degrees = rot_deg
	parent.add_child(lamp)
	_sphere(lamp, gas_flame(), "Glass", Vector3.ZERO, radius, 10)
	_ring(lamp, brass(), "CageTop", radius * 0.72, radius * 1.06, radius * 0.86)
	_ring(lamp, brass(), "CageBottom", -radius * 0.72, radius * 1.06, radius * 0.86)
	_sphere(lamp, brass_bright(), "Cap", Vector3(0, radius * 0.86, 0), radius * 0.30, 6)
	return lamp


## Leather grip wrap: stacked bands, reads as a wound strip at game distance.
static func _wrap(parent: Node3D, z0: float, z1: float, radius: float,
		bands := 6) -> void:
	var span := z1 - z0
	for i in bands:
		var z := z0 + span * (float(i) + 0.5) / float(bands)
		_rod(parent, leather(), "Wrap%d" % i, z, span / float(bands) * 0.86,
				radius, 10)


# --- Builders ----------------------------------------------------------------

static func build(model_id: StringName) -> Node3D:
	var root := Node3D.new()
	root.name = "MeleeWeapon"
	root.set_meta(&"model", model_id)
	match model_id:
		&"cane_sabre":
			_build_cane_sabre(root)
		&"pipe_wrench":
			_build_pipe_wrench(root)
		&"boarding_axe":
			_build_boarding_axe(root)
		&"boiler_lance":
			_build_boiler_lance(root)
		&"pipe":
			_build_steel_pipe(root)
		&"kitchen_knife":
			_build_kitchen_knife(root)
		_:
			_build_fists(root)
	return root


## A gentleman's walking cane with a hidden brass-bladed sabre.
static func _build_cane_sabre(root: Node3D) -> void:
	# Oak shaft doubles as the scabbard; handle and ferrule in brass.
	_rod(root, oak(), "Shaft", 0.02, 0.66, 0.018, 12)
	_rod(root, brass(), "Collar", 0.36, 0.05, 0.022, 12)
	_rod(root, brass(), "HandleCollar", -0.30, 0.055, 0.023, 12)
	_sphere(root, brass(), "Pommel", Vector3(0, 0, -0.335), 0.024, 10)
	_wrap(root, -0.27, -0.06, 0.0205, 7)
	_rivets(root, -0.30, 0.026, 3, 1.0)
	# Guard plate where blade leaves sheath.
	_box(root, brass(), "Guard", Vector3(0, 0, 0.385), Vector3(0.072, 0.014, 0.030))
	_box(root, brass_dark_mat(), "GuardLip", Vector3(0, 0, 0.400),
			Vector3(0.052, 0.010, 0.014))
	# Blued blade + fuller groove + tapered point.
	_box(root, blued(), "Blade", Vector3(0, 0, 0.60), Vector3(0.013, 0.034, 0.40))
	_box(root, _mat(Color(0.13, 0.15, 0.19), 0.9, 0.45), "Fuller",
			Vector3(0, 0, 0.60), Vector3(0.0155, 0.012, 0.34))
	_rod(root, blued(), "BladeTip", 0.845, 0.09, 0.017, 4, 0.0)
	# Gas-lamp pommel: a sword cane a gentleman can find in the dark.
	_lamp(root, "PommelLamp", Vector3(0, 0, -0.380), 0.028)
	root.set_meta(&"length", 0.90)
	root.set_meta(&"grip_z", -0.30)
	root.set_meta(&"tip_z", 0.89)


static func brass_dark_mat() -> StandardMaterial3D:
	return _mat(BRASS_DARK, 0.85, 0.40)


## Steamfitter's adjustable pipe wrench: iron jaw, brass valve-wheel pommel,
## pressure gauge bolted to the cheek.
static func _build_pipe_wrench(root: Node3D) -> void:
	_rod(root, oak(), "Haft", -0.20, 0.40, 0.021, 10)
	_wrap(root, -0.38, -0.10, 0.0235, 7)
	_rod(root, brass(), "ButtCap", -0.415, 0.05, 0.026, 12)
	_valve_wheel(root, "PommelWheel", -0.45, 0.052, 5)
	# Head: cast iron body with a sliding upper jaw and adjuster screw.
	_box(root, iron(), "HeadBody", Vector3(0, 0, 0.055), Vector3(0.056, 0.078, 0.155))
	_box(root, iron(), "UpperJaw", Vector3(0, 0.030, 0.125), Vector3(0.092, 0.030, 0.105))
	_box(root, blued(), "JawTooth0", Vector3(0, 0.0455, 0.078), Vector3(0.086, 0.010, 0.014))
	_box(root, blued(), "JawTooth1", Vector3(0, 0.0455, 0.104), Vector3(0.086, 0.010, 0.014))
	_box(root, blued(), "JawTooth2", Vector3(0, 0.0455, 0.130), Vector3(0.086, 0.010, 0.014))
	_rod(root, brass(), "AdjusterScrew", 0.02, 0.11, 0.013, 8)
	_ring(root, brass(), "KnurlRing", 0.055, 0.030, 0.020, Vector3(0, 0, 0))
	_box(root, brass(), "Collar", Vector3(0, 0, -0.005), Vector3(0.040, 0.058, 0.030))
	_rivets(root, 0.030, 0.032, 4, 1.0)
	_gauge(root, "Gauge", Vector3(0.036, 0.010, 0.020), 0.032,
			Vector3(0, 90, 0), 55.0)
	root.set_meta(&"length", 0.72)
	root.set_meta(&"grip_z", -0.40)
	root.set_meta(&"tip_z", 0.19)


## Boarding axe: oak haft, steel bit with brass rivets, small brass gear
## ornament and a spike poll.
static func _build_boarding_axe(root: Node3D) -> void:
	_rod(root, mahogany(), "Haft", -0.05, 0.66, 0.019, 10)
	_wrap(root, -0.30, -0.02, 0.0215, 8)
	_rod(root, brass(), "ButtCap", -0.375, 0.05, 0.024, 12)
	_ring(root, brass(), "LanyardRing", -0.405, 0.020, 0.012)
	# Axe head: triangular prism reads as a wedge bit at game distance.
	var bit := CylinderMesh.new()
	bit.height = 0.30
	bit.bottom_radius = 0.115
	bit.top_radius = 0.020
	bit.radial_segments = 3
	_add(root, bit, blued(), "AxeBit", Vector3(0, 0.055, 0.185),
			Vector3(90, 90, 0))
	_box(root, iron(), "Cheek", Vector3(0, 0.010, 0.215), Vector3(0.030, 0.115, 0.070))
	_box(root, brass(), "CheekBand", Vector3(0, 0.010, 0.255),
			Vector3(0.034, 0.100, 0.012))
	_rivets(root, 0.235, 0.070, 3, 1.0)
	# Brass gear ornament (teeth = short boxes around a hub).
	var gear := _rod(root, brass(), "GearHub", 0.145, 0.016, 0.030, 12)
	gear.rotation_degrees = Vector3(90, 0, 0)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var t := _box(root, brass_dark_mat(), "GearTooth%d" % i,
				Vector3(cos(a) * 0.036, sin(a) * 0.036, 0.145),
				Vector3(0.014, 0.014, 0.014))
		t.rotation_degrees = Vector3(0, 0, rad_to_deg(a))
	# Spike poll behind the head.
	_rod(root, steel(), "PollSpike", 0.095, 0.09, 0.020, 6, 0.0)
	_sphere(root, brass(), "HeadCap", Vector3(0, 0, 0.345), 0.022, 8)
	# Miner's lamp on a bracket off the haft, lit for the boarding deck.
	_box(root, brass(), "LampBracket", Vector3(0.030, 0, -0.21), Vector3(0.058, 0.010, 0.010))
	_lamp(root, "HaftLamp", Vector3(0.058, 0, -0.21), 0.030)
	root.set_meta(&"length", 0.80)
	root.set_meta(&"grip_z", -0.30)
	root.set_meta(&"tip_z", 0.35)


## Boiler lance: long steam pipe with valve-wheel guard, gauge and vented spike.
static func _build_boiler_lance(root: Node3D) -> void:
	_rod(root, steel(), "Pipe", 0.36, 1.42, 0.020, 10)
	_rod(root, brass(), "ButtCap", -0.365, 0.06, 0.024, 12)
	_wrap(root, -0.32, -0.02, 0.0225, 8)
	for z in [-0.30, -0.05, 0.30, 0.62, 0.95]:
		_rod(root, brass(), "Band%d" % int(z * 100.0), z, 0.030, 0.0245, 12)
	_valve_wheel(root, "GuardWheel", 0.44, 0.080, 6)
	# Boiler-lamp above the guard: the lance doubles as a work light.
	_lamp(root, "GuardLamp", Vector3(0, 0.082, 0.44), 0.034)
	_gauge(root, "Gauge", Vector3(0.030, 0.014, 0.16), 0.030,
			Vector3(0, 90, 0), 35.0)
	_rivets(root, 0.78, 0.026, 4, 1.0)
	# Vented spike tip: taper + four vent slots + gear collar.
	_rod(root, brass(), "TipCollar", 1.10, 0.05, 0.026, 12)
	for i in 4:
		var a := TAU * float(i) / 4.0
		_add(root, _box_mesh(Vector3(0.008, 0.010, 0.13)), iron(),
				"Vent%d" % i, Vector3(cos(a) * 0.014, sin(a) * 0.014, 1.20))
	_rod(root, blued(), "SpikeTip", 1.28, 0.22, 0.020, 6, 0.0)
	root.set_meta(&"length", 1.42)
	root.set_meta(&"grip_z", -0.32)
	root.set_meta(&"tip_z", 1.38)


static func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## The starting improvised weapon: a length of steam pipe with brass bands.
static func _build_steel_pipe(root: Node3D) -> void:
	_rod(root, steel(), "Pipe", 0.06, 0.60, 0.027, 10)
	_rod(root, brass(), "BandA", -0.10, 0.032, 0.030, 12)
	_rod(root, brass(), "BandB", 0.24, 0.032, 0.030, 12)
	_wrap(root, -0.30, -0.14, 0.0295, 6)
	_valve_wheel(root, "EndWheel", 0.38, 0.062, 5)
	_rivets(root, 0.24, 0.030, 4, 1.0)
	_rod(root, brass(), "Collars", 0.36, 0.030, 0.030, 12)
	root.set_meta(&"length", 0.72)
	root.set_meta(&"grip_z", -0.22)
	root.set_meta(&"tip_z", 0.42)


## Kitchen knife: thin steel blade, brass bolster, riveted wooden handle.
static func _build_kitchen_knife(root: Node3D) -> void:
	_box(root, mahogany(), "Handle", Vector3(0, 0, -0.085), Vector3(0.024, 0.030, 0.13))
	_rivets(root, -0.060, 0.019, 3, 1.1, brass())
	_box(root, brass(), "Bolster", Vector3(0, 0, -0.016), Vector3(0.028, 0.034, 0.018))
	_box(root, steel(), "Blade", Vector3(0, 0, 0.085), Vector3(0.006, 0.036, 0.175))
	_rod(root, steel(), "BladeTip", 0.196, 0.07, 0.014, 4, 0.0)
	root.set_meta(&"length", 0.30)
	root.set_meta(&"grip_z", -0.15)
	root.set_meta(&"tip_z", 0.23)


## Bare hands: no mesh, but the same node contract so MeleeCombat is uniform.
static func _build_fists(root: Node3D) -> void:
	root.set_meta(&"length", 0.0)
	root.set_meta(&"grip_z", 0.0)
	root.set_meta(&"tip_z", 0.0)
	root.set_meta(&"bare", true)


# --- Introspection (used by tests + capture tooling) -------------------------

static func part_count(root: Node3D) -> int:
	var n := 0
	for c in root.get_children():
		if c is MeshInstance3D:
			n += 1
		elif c is Node3D:
			n += 1 + part_count(c)
	return n


static func triangle_count(root: Node3D) -> int:
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		var mi := node as MeshInstance3D
		if mi != null and mi.mesh != null:
			n += mi.mesh.get_faces().size() / 3
	return n


## World-space length of the weapon along its own +Z, for reach checks.
static func model_length(model_id: StringName) -> float:
	var root := build(model_id)
	var l := float(root.get_meta(&"length", 0.0))
	for c in root.get_children():
		c.queue_free()
	root.queue_free()
	return l
