class_name LevelBuilder
extends RefCounted
## Builds the Prototype 0 test block from code.
##
## Deterministic layout (no randomness): ground, two crossing roads, one
## accessible apartment building, one convenience store, props and boundary.
## Everything is simple boxes/capsules - gameplay architecture comes first.
##
## Returns a Dictionary:
##   buildings: Array of {"name": String, "rect": Rect2 (XZ footprint),
##                        "roof_nodes": Array[Node]} for roof hiding,
##   crates:    Array[FoodCrate] spawned containers.

const DOOR_WIDTH := 2.0
const WALL_THICKNESS := 0.35

const GROUND_HALF := 50.0


static func build(root: Node3D) -> Dictionary:
	var 	result := {"buildings": [], "crates": []}
	_build_ground(root)
	_build_roads(root)

	var apartment_info := _build_apartment(root)
	result["buildings"].append(apartment_info)
	result["crates"].append_array(apartment_info.get("crates", []))

	var store_info := _build_store(root)
	result["buildings"].append(store_info)
	result["crates"].append_array(store_info.get("crates", []))

	_build_park(root)
	_build_props(root)
	_build_boundary(root)
	return result


# --- Ground / roads ---------------------------------------------------------

static func _build_ground(root: Node3D) -> void:
	# One big slab; top face sits exactly at y = 0.
	add_box(root, "Ground", Vector3(0, -0.5, 0),
			Vector3(GROUND_HALF * 2.0, 1.0, GROUND_HALF * 2.0), Color(0.23, 0.25, 0.22))


static func _build_roads(root: Node3D) -> void:
	var road_color := Color(0.16, 0.17, 0.19)
	var road_width := 9.0
	add_box(root, "RoadNS", Vector3(0, 0.02, 0),
			Vector3(road_width, 0.04, GROUND_HALF * 1.8), road_color, {"collide": false})
	add_box(root, "RoadEW", Vector3(0, 0.02, 0),
			Vector3(GROUND_HALF * 1.8, 0.04, road_width), road_color, {"collide": false})
	# Center line dashes (decorative).
	for i in range(-4, 5):
		if i == 0:
			continue
		add_box(root, "DashNS%d" % i, Vector3(0, 0.05, i * 10.0),
				Vector3(0.25, 0.02, 4.0), Color(0.75, 0.72, 0.5), {"collide": false})
		add_box(root, "DashEW%d" % i, Vector3(i * 10.0, 0.05, 0),
				Vector3(4.0, 0.02, 0.25), Color(0.75, 0.72, 0.5), {"collide": false})


# --- Buildings --------------------------------------------------------------

## cfg keys: name, center(Vector2 XZ), size(Vector2 w,d), height,
##           door_side ("N"/"S"/"E"/"W"), wall_color, floor_color
static func _build_building(root: Node3D, cfg: Dictionary) -> Dictionary:
	var center: Vector2 = cfg["center"]
	var size: Vector2 = cfg["size"]
	var height: float = cfg["height"]
	var half := size * 0.5

	# Interior floor.
	add_box(root, "%s_Floor" % cfg["name"],
			Vector3(center.x, 0.03, center.y),
			Vector3(size.x, 0.06, size.y), cfg.get("floor_color", Color(0.45, 0.38, 0.3)),
			{"collide": false})

	_sides(root, cfg)

	# Roof slab (group "roof" so main.gd can hide it when the player is inside).
	var roof := add_box(root, "%s_Roof" % cfg["name"],
			Vector3(center.x, height + 0.15, center.y),
			Vector3(size.x + 0.5, 0.3, size.y + 0.5),
			cfg.get("roof_color", Color(0.35, 0.33, 0.32)))
	roof.add_to_group(&"roof")

	return {
		"name": cfg["name"],
		"rect": Rect2(center - half, size),
		"roof_nodes": [roof],
	}


static func _sides(root: Node3D, cfg: Dictionary) -> void:
	var center: Vector2 = cfg["center"]
	var size: Vector2 = cfg["size"]
	var height: float = cfg["height"]
	var half := size * 0.5
	var color: Color = cfg.get("wall_color", Color(0.55, 0.52, 0.48))

	var sides := {
		"N": [Vector2(center.x - half.x, center.y - half.y),
				Vector2(center.x + half.x, center.y - half.y)],
		"S": [Vector2(center.x - half.x, center.y + half.y),
				Vector2(center.x + half.x, center.y + half.y)],
		"W": [Vector2(center.x - half.x, center.y - half.y),
				Vector2(center.x - half.x, center.y + half.y)],
		"E": [Vector2(center.x + half.x, center.y - half.y),
				Vector2(center.x + half.x, center.y + half.y)],
	}
	for side: String in sides:
		var pts: Array = sides[side]
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		if side == cfg.get("door_side", ""):
			var length := a.distance_to(b)
			var t0 := 0.5 - DOOR_WIDTH / (2.0 * length)
			var t1 := 0.5 + DOOR_WIDTH / (2.0 * length)
			var p0 := a.lerp(b, t0)
			var p1 := a.lerp(b, t1)
			_wall_segment(root, "%s_Wall%s_a" % [cfg["name"], side], a, p0, height, color)
			_wall_segment(root, "%s_Wall%s_b" % [cfg["name"], side], p1, b, height, color)
			# Lintel band above the doorway so the entrance reads clearly.
			var horizontal := absf(b.x - a.x) > absf(b.y - a.y)
			add_box(root, "%s_Lintel%s" % [cfg["name"], side],
					Vector3((p0.x + p1.x) * 0.5, height - 0.3, (p0.y + p1.y) * 0.5),
					Vector3(DOOR_WIDTH if horizontal else WALL_THICKNESS,
							0.6,
							WALL_THICKNESS if horizontal else DOOR_WIDTH),
					color)
		else:
			_wall_segment(root, "%s_Wall%s" % [cfg["name"], side], a, b, height, color)


## Wall segment between two XZ points, full height.
static func _wall_segment(root: Node3D, box_name: String, from_p: Vector2, to_p: Vector2,
		height: float, color: Color) -> void:
	var length := from_p.distance_to(to_p)
	if length <= 0.05:
		return
	var mid := (from_p + to_p) * 0.5
	var size := Vector3(length, height, WALL_THICKNESS) \
			if absf(to_p.x - from_p.x) > absf(to_p.y - from_p.y) \
			else Vector3(WALL_THICKNESS, height, length)
	add_box(root, box_name, Vector3(mid.x, height * 0.5, mid.y), size, color)


static func _build_apartment(root: Node3D) -> Dictionary:
	var cfg := {
		"name": "Apartment",
		"center": Vector2(-16.0, -14.0),
		"size": Vector2(12.0, 9.0),
		"height": 3.2,
		"door_side": "E",
		"wall_color": Color(0.58, 0.55, 0.5),
		"floor_color": Color(0.42, 0.33, 0.24),
		"roof_color": Color(0.3, 0.29, 0.28),
	}
	var info := _build_building(root, cfg)

	# Furniture: bed, table, shelf.
	add_box(root, "Bed", Vector3(-20.2, 0.3, -11.2), Vector3(1.8, 0.5, 2.4),
			Color(0.7, 0.68, 0.62))
	add_box(root, "Table", Vector3(-13.0, 0.4, -14.0), Vector3(1.6, 0.8, 1.0),
			Color(0.5, 0.36, 0.22))
	add_box(root, "Shelf", Vector3(-21.2, 1.0, -17.0), Vector3(0.6, 2.0, 2.2),
			Color(0.45, 0.34, 0.26))

	# Pantry crate: shared food source NPCs can also loot.
	var pantry := FoodCrate.new()
	pantry.name = "Crate_ApartmentPantry"
	pantry.position = Vector3(-19.5, 0.45, -17.0)
	pantry.contents = {&"canned_food": 3, &"water_bottle": 3, &"antibiotics": 1}
	root.add_child(pantry)
	info["crates"] = [pantry]
	return info


static func _build_store(root: Node3D) -> Dictionary:
	var cfg := {
		"name": "Store",
		"center": Vector2(15.0, 12.0),
		"size": Vector2(11.0, 8.0),
		"height": 3.4,
		"door_side": "W",
		"wall_color": Color(0.62, 0.64, 0.66),
		"floor_color": Color(0.5, 0.52, 0.55),
		"roof_color": Color(0.34, 0.35, 0.37),
	}
	var info := _build_building(root, cfg)

	# Shelf rows and checkout counter.
	for i in range(2):
		add_box(root, "ShelfRow%d" % i, Vector3(14.0 + i * 3.0, 0.9, 9.5),
				Vector3(5.0, 1.8, 0.8), Color(0.55, 0.57, 0.6))
	add_box(root, "Counter", Vector3(12.0, 0.55, 13.5), Vector3(3.0, 1.1, 0.9),
			Color(0.45, 0.4, 0.36))

	# Main storage crate behind the counter.
	var storage := FoodCrate.new()
	storage.name = "Crate_StoreStorage"
	storage.position = Vector3(17.5, 0.45, 14.5)
	storage.contents = {&"canned_food": 5, &"water_bottle": 4, &"bandage": 2}
	root.add_child(storage)
	info["crates"] = [storage]

	# Sign so the building reads as a shop from above.
	add_box(root, "StoreSign", Vector3(9.4, 3.0, 12.0),
			Vector3(0.3, 0.9, 5.0), Color(0.75, 0.25, 0.2), {"collide": false})

	return info


# --- Park / props / boundary ------------------------------------------------

static func _build_park(root: Node3D) -> void:
	add_box(root, "ParkGrass", Vector3(-20, 0.01, 18),
			Vector3(14, 0.05, 10), Color(0.24, 0.36, 0.2), {"collide": false})
	for offset: Vector2 in [Vector2(-24, 16), Vector2(-17, 21), Vector2(-22, 20)]:
		add_box(root, "TreeTrunk_%s_%s" % [offset.x, offset.y],
				Vector3(offset.x, 1.1, offset.y), Vector3(0.4, 2.2, 0.4),
				Color(0.35, 0.25, 0.15))
		add_box(root, "TreeTop_%s_%s" % [offset.x, offset.y],
				Vector3(offset.x, 2.8, offset.y), Vector3(2.0, 1.6, 2.0),
				Color(0.2, 0.42, 0.18))


static func _build_props(root: Node3D) -> void:
	# Wrecked cars on the roads.
	var cars := [
		[Vector3(-4, 0.5, 6), Color(0.5, 0.2, 0.18)],
		[Vector3(3.5, 0.5, -9), Color(0.2, 0.3, 0.45)],
		[Vector3(14, 0.5, -2), Color(0.6, 0.6, 0.58)],
		[Vector3(-9, 0.5, 20), Color(0.35, 0.35, 0.3)],
	]
	for i in cars.size():
		var car: Array = cars[i]
		add_box(root, "Car%d" % i, car[0], Vector3(2.0, 1.0, 4.2), car[1])
		add_box(root, "CarRoof%d" % i, car[0] + Vector3(0, 0.85, 0),
				Vector3(1.6, 0.7, 2.2), car[1].darkened(0.2))

	# Street lamps with real lights (DayNightController toggles them at night).
	for pos: Vector3 in [Vector3(5, 0, 5), Vector3(-5, 0, -5), Vector3(5, 0, -5), Vector3(-5, 0, 5)]:
		add_box(root, "LampPost_%s_%s" % [pos.x, pos.z],
				pos + Vector3(0, 2.2, 0), Vector3(0.18, 4.4, 0.18), Color(0.3, 0.3, 0.32))
		var lamp_head := add_box(root, "LampHead_%s_%s" % [pos.x, pos.z],
				pos + Vector3(0, 4.4, 0), Vector3(0.5, 0.2, 0.5),
				Color(1.0, 0.95, 0.8), {"collide": false})
		lamp_head.add_to_group(&"lamp_heads")

		var light := OmniLight3D.new()
		light.name = "LampLight_%s_%s" % [pos.x, pos.z]
		light.position = pos + Vector3(0, 4.1, 0)
		light.omni_range = 9.0
		light.light_energy = 2.2
		light.visible = false
		light.add_to_group(&"streetlamp")
		root.add_child(light)


static func _build_boundary(root: Node3D) -> void:
	# Visible low barrier marking the prototype block edge.
	var c := Color(0.4, 0.4, 0.42)
	var half := GROUND_HALF - 2.0
	add_box(root, "BoundaryN", Vector3(0, 0.5, -half), Vector3(half * 2, 1.0, 0.6), c)
	add_box(root, "BoundaryS", Vector3(0, 0.5, half), Vector3(half * 2, 1.0, 0.6), c)
	add_box(root, "BoundaryW", Vector3(-half, 0.5, 0), Vector3(0.6, 1.0, half * 2), c)
	add_box(root, "BoundaryE", Vector3(half, 0.5, 0), Vector3(0.6, 1.0, half * 2), c)


# --- Box helper ---------------------------------------------------------------

## Creates a colored box. opts: collide(bool)=true. Returns the MeshInstance3D.
static func add_box(root: Node, box_name: String, pos: Vector3, size: Vector3,
		color: Color, opts := {}) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = box_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_instance.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mesh_instance.material_override = mat
	mesh_instance.position = pos
	root.add_child(mesh_instance)

	if bool(opts.get("collide", true)):
		var body := StaticBody3D.new()
		body.name = box_name + "_Body"
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)
		mesh_instance.add_child(body)
	return mesh_instance
