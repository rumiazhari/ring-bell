class_name RuralBuildingChunkBuilder
extends RefCounted
## Pure rural building chunk manifest + main-thread materialization for P4.2.
## Each 64m chunk carries at most one rural collider (0 if dry), verts <=320 (typical <=192) tris <=240 (typical <=144), ACTIVE-only physics.

const CHUNK_M := 64.0
const COL_PLASTER := Color("ddd0c0")
const COL_BRICK := Color("b07a5a")
const COL_TIMBER := Color("7a5a3a")
const COL_ROOF_RED := Color("8a3a2a")
const COL_ROOF_GREY := Color("5a5a5a")

static func _effective_footprint(footprint: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint

static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var rect := Rect2(origin, size)
	var center := origin + size * 0.5
	# Urban suppression: rural buildings suppressed inside URBAN_INNER_M unless gate within 90m (gate barn exception)
	var suppress := false
	if origin.length() < WorldConstants.URBAN_INNER_M:
		var gate_near := false
		var gates: Array[Dictionary] = world_plan.city_gates()
		for g in gates:
			var gc: Vector2 = g["center"] as Vector2
			if center.distance_to(gc) < 90.0 or origin.distance_to(gc) < 90.0:
				gate_near = true
				break
		if not gate_near:
			suppress = true
	# Also if rect center inside urban and not gate barn, we still suppress but need to check per-building gate barn flag later
	var raw_buildings: Array[Dictionary] = []
	if not suppress:
		raw_buildings = world_plan.rural_buildings_in(rect)
	# Filter to ownership by footprint center inside chunk rect
	var owned: Array[Dictionary] = []
	for b in raw_buildings:
		var b_center: Vector2 = b["center"] as Vector2
		if rect.has_point(b_center):
			# also check gate barn exception for inside-urban center: if building is gate barn allow even if chunk suppressed? But chunk suppressed already false if gate_near
			# For non-suppressed chunk, also ensure building not inside urban unless gate barn
			if b_center.length() < WorldConstants.URBAN_INNER_M - 0.5:
				if not bool(b.get("allow_gate_barn", false)):
					continue
			owned.append(b)
	# If suppress, owned remains empty
	# Clip to max per chunk 6 (spec)
	if owned.size() > WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK:
		owned = owned.slice(0, WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK)
	# Sort owned by id for determinism
	owned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	var has_rural: bool = owned.size() > 0
	var door_manifests: Array[Dictionary] = []
	# Generate door manifests
	for b in owned:
		var bid: String = String(b["id"])
		var dpos: Vector2 = b["door_pos"] as Vector2
		var dyaw: float = float(b["door_yaw"])
		# Determine world normal to map to edge N/E/S/W for hinge swing
		# We have door_yaw as normal angle; compute wall yaw and edge
		# Our door_yaw from plan is normal angle; convert to wall orientation: wall runs perpendicular to normal
		# For axis-aligned, normal is cardinal; wall yaw = 0 if normal north/south else PI/2
		# Recompute normal from door_yaw
		var normal := Vector2(cos(dyaw), sin(dyaw))
		var edge: int = 0
		# Map normal to cardinal N/E/S/W
		if absf(normal.x) > absf(normal.y):
			edge = 1 if normal.x > 0 else 3 # E vs W
		else:
			edge = 0 if normal.y > 0 else 2 # N vs S
		var wall_yaw: float = 0.0 if edge == 0 or edge == 2 else PI * 0.5
		# Hinge side deterministic via palette domain with building hash
		var hinge_left: bool = fmod(float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_building"), WorldSeed.str_hash(bid)]) % 1000), 2.0) < 1.0
		# Alternative use unit_float
		var hid: int = WorldSeed.str_hash(bid)
		var hinge_r: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_building_palette"), hid]) % 1000003) / 1000003.0
		hinge_left = hinge_r < 0.5
		# Position for door manifest: hinge point is door_pos (edge midpoint). Door.gd will offset by half width.
		# Need terrain height at door_pos for Y
		var ground_y: float = world_plan.terrain_height_at(dpos) + 0.01
		var door_width: float = 1.0
		var door_height: float = 2.1
		# For barn maybe slightly larger 1.2x2.2? Keep 1.0
		if String(b["kind"]) == "barn" or String(b["kind"]) == "stable":
			door_width = 1.2
			door_height = 2.2
		var dm: Dictionary = {
			"id": "rural_door_%s_0" % bid,
			"building_id": bid,
			"position": Vector3(dpos.x, ground_y, dpos.y),
			"yaw": wall_yaw,
			"edge": edge,
			"width": door_width,
			"height": door_height,
			"hinge": "left" if hinge_left else "right",
			"locked": false,
			"open_angle": 95.0,
			"swing": -1.0 if edge == 0 or edge == 3 else 1.0,
			"kind": &"rural_house",
			"door_pos": dpos,
			"door_yaw": wall_yaw,
		}
		door_manifests.append(dm)
	# Enforce max doors 6 per village chunk (already limited by owned size)
	if door_manifests.size() > WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK:
		door_manifests = door_manifests.slice(0, WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK)
		# Also trim owned to match? Keep owned as is but door count limited; but owned buildings still meshes, doors trimmed. However spec expects doors <=6 per village chunk, we enforce.
	# Generate batched mesh geometry
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var vert_count := 0
	var tri_count := 0
	var aabbs: Array[Rect2] = []
	var building_colors: Array[Color] = []
	for b in owned:
		var b_center: Vector2 = b["center"] as Vector2
		var footprint: Vector2 = b["footprint"] as Vector2
		var yaw: float = float(b["yaw"])
		var height: float = float(b["height"])
		var wall_col: Color = b.get("color", COL_PLASTER) as Color
		var roof_col: Color = b.get("roof_color", COL_ROOF_RED) as Color
		var ground: float = world_plan.terrain_height_at(b_center) + 0.01
		var eff: Vector2 = _effective_footprint(footprint, yaw)
		var hx: float = eff.x * 0.5
		var hz: float = eff.y * 0.5
		# 8 corners
		var x0: float = b_center.x - hx
		var x1: float = b_center.x + hx
		var z0: float = b_center.y - hz
		var z1: float = b_center.y + hz
		var y0: float = ground
		var y1: float = ground + height
		var corners: Array[Vector3] = [
			Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1),
			Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)
		]
		# Faces: each face 4 verts with face normal
		# Define faces as arrays of corner indices for each quad (winding CCW outward)
		var faces: Array[Dictionary] = [
			{"idx": [0,1,2,3], "normal": Vector3.DOWN, "color": wall_col}, # bottom
			{"idx": [4,7,6,5], "normal": Vector3.UP, "color": roof_col}, # top (roof)
			{"idx": [0,4,5,1], "normal": Vector3(0,0,-1), "color": wall_col}, # front -Z
			{"idx": [2,6,7,3], "normal": Vector3(0,0,1), "color": wall_col}, # back +Z
			{"idx": [1,5,6,2], "normal": Vector3(1,0,0), "color": wall_col}, # right +X
			{"idx": [3,7,4,0], "normal": Vector3(-1,0,0), "color": wall_col}, # left -X
		]
		var base_idx: int = verts.size()
		# For box we will emit 6 faces each with 4 verts (24 verts) and 2 tris per face (12 tris total)
		for f in faces:
			var idxs: Array = f["idx"] as Array
			var n: Vector3 = f["normal"] as Vector3
			var col: Color = f["color"] as Color
			var face_verts: Array[Vector3] = [corners[idxs[0]], corners[idxs[1]], corners[idxs[2]], corners[idxs[3]]]
			for v in face_verts:
				verts.append(v)
				normals.append(n)
				colors.append(col)
			# two triangles: 0-1-2, 0-2-3 (relative to face base)
			var b0: int = base_idx
			indices.append(b0); indices.append(b0+1); indices.append(b0+2)
			indices.append(b0); indices.append(b0+2); indices.append(b0+3)
			base_idx += 4
		vert_count += 24
		tri_count += 12
		aabbs.append(b["aabb"] as Rect2)
		building_colors.append(wall_col)
	# Budgets: each chunk aggregated
	var total_verts: int = verts.size()
	var total_tris: int = indices.size() / 3
	var colliders: int = 1 if has_rural else 0
	var rural_doors: int = door_manifests.size()
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	# Ensure byte-identical shuffled: sort door_manifests by id already, verts order deterministic via owned sorted, so identical regardless of build order
	door_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"rural_buildings": owned,
		"door_manifests": door_manifests,
		"rural_vertices": total_verts,
		"rural_triangles": total_tris,
		"rural_colliders": colliders,
		"rural_doors": rural_doors,
		"has_rural": has_rural,
		"rural_gen_ms": gen_ms,
		"rural_mat_ms": 0.0,
		"aabbs": aabbs,
		"colors": colors,
		"verts": verts,
		"normals": normals,
		"indices": indices,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO) as Vector2i
	var has_rural: bool = bool(manifest.get("has_rural", false))
	var existing := parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if not has_rural:
		var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
		return {
			"rural_vertices": 0,
			"rural_triangles": 0,
			"rural_colliders": 0,
			"rural_doors": 0,
			"rural_buildings": 0,
			"has_rural": false,
			"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
			"rural_mat_ms": mat_ms_empty,
		}
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	var door_manifests: Array = manifest.get("door_manifests", []) as Array
	var rural_node := Node3D.new()
	rural_node.name = "Rural_%d_%d" % [coord.x, coord.y]
	parent.add_child(rural_node)
	# Mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var norms_arr := PackedVector3Array()
	if normals is PackedVector3Array:
		norms_arr = normals as PackedVector3Array
	else:
		norms_arr.resize(verts.size())
		var arr: Array = normals as Array
		for i in verts.size():
			if i < arr.size():
				norms_arr[i] = arr[i] as Vector3
			else:
				norms_arr[i] = Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = norms_arr
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if indices.size() >= 3 and verts.size() >= 3:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		mat.metallic = 0.0
		mesh.surface_set_material(0, mat)
	else:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "RuralMesh"
	mi.mesh = mesh
	rural_node.add_child(mi)
	# Single collider aggregated
	var body := StaticBody3D.new()
	body.name = "RuralBody"
	body.collision_layer = 1
	body.collision_mask = 0
	rural_node.add_child(body)
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for idx in indices.size():
		var vi: int = indices[idx]
		if vi >= 0 and vi < verts.size():
			faces[idx] = verts[vi]
	concave.data = faces
	var coll := CollisionShape3D.new()
	coll.shape = concave
	body.add_child(coll)
	# Door leaves per building
	var door_count := 0
	for dm in door_manifests:
		var d: Dictionary = dm as Dictionary
		var door := Door.new()
		door.name = String(d["id"])
		door.setup(d)
		rural_node.add_child(door)
		door_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"rural_vertices": verts.size(),
		"rural_triangles": indices.size() / 3,
		"rural_colliders": 1,
		"rural_doors": door_count,
		"rural_buildings": int((manifest.get("rural_buildings", []) as Array).size()),
		"has_rural": true,
		"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
		"rural_mat_ms": mat_ms,
	}
