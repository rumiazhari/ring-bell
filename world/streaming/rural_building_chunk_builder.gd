class_name RuralBuildingChunkBuilder
extends RefCounted
## Pure rural building chunk manifest + main-thread materialization for P4.2/P4.3.
## Each 64m chunk carries at most one rural collider (0 if dry), verts <=400 (typical <=240) tris <=300 (typical <=180), ACTIVE-only physics.
## P4.3 adds interior partition walls + furniture proxies batched into same mesh + FoodCrate leaves.

const CHUNK_M := 64.0
const COL_PLASTER := Color("ddd0c0")
const COL_BRICK := Color("b07a5a")
const COL_TIMBER := Color("7a5a3a")
const COL_ROOF_RED := Color("8a3a2a")
const COL_ROOF_GREY := Color("5a5a5a")
const COL_WALL_DARK_FACTOR := 0.88
const COL_FURNITURE_BED := Color("9e8b6a")
const COL_FURNITURE_SHELF := Color("6b5a4a")
const COL_FURNITURE_TABLE := Color("7a6a5a")
const COL_FURNITURE_STOVE := Color("4a4a4a")

static func _effective_footprint(footprint: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint

static func _add_box(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, size: Vector3, col: Color) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var x0: float = center.x - hx
	var x1: float = center.x + hx
	var y0: float = center.y - hy
	var y1: float = center.y + hy
	var z0: float = center.z - hz
	var z1: float = center.z + hz
	var corners: Array[Vector3] = [
		Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1),
		Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)
	]
	var faces: Array[Dictionary] = [
		{"idx": [0,1,2,3], "normal": Vector3.DOWN, "color": col},
		{"idx": [4,7,6,5], "normal": Vector3.UP, "color": col},
		{"idx": [0,4,5,1], "normal": Vector3(0,0,-1), "color": col},
		{"idx": [2,6,7,3], "normal": Vector3(0,0,1), "color": col},
		{"idx": [1,5,6,2], "normal": Vector3(1,0,0), "color": col},
		{"idx": [3,7,4,0], "normal": Vector3(-1,0,0), "color": col},
	]
	var base_idx: int = verts.size()
	for f in faces:
		var idxs: Array = f["idx"] as Array
		var n: Vector3 = f["normal"] as Vector3
		var c: Color = f["color"] as Color
		var face_verts: Array[Vector3] = [corners[idxs[0]], corners[idxs[1]], corners[idxs[2]], corners[idxs[3]]]
		for v in face_verts:
			verts.append(v)
			normals.append(n)
			colors.append(c)
		var b0: int = base_idx
		indices.append(b0); indices.append(b0+1); indices.append(b0+2)
		indices.append(b0); indices.append(b0+2); indices.append(b0+3)
		base_idx +=4

static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var rect := Rect2(origin, size)
	var center := origin + size * 0.5
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
	var raw_buildings: Array[Dictionary] = []
	if not suppress:
		raw_buildings = world_plan.rural_buildings_in(rect)
	var owned: Array[Dictionary] = []
	for b in raw_buildings:
		var b_center: Vector2 = b["center"] as Vector2
		if rect.has_point(b_center):
			if b_center.length() < WorldConstants.URBAN_INNER_M - 0.5:
				if not bool(b.get("allow_gate_barn", false)):
					continue
			owned.append(b)
	if owned.size() > WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK:
		owned = owned.slice(0, WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK)
	owned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	var has_rural: bool = owned.size() > 0
	var door_manifests: Array[Dictionary] = []
	for b in owned:
		var bid: String = String(b["id"])
		var dpos: Vector2 = b["door_pos"] as Vector2
		var dyaw: float = float(b["door_yaw"])
		var normal := Vector2(cos(dyaw), sin(dyaw))
		var edge: int = 0
		if absf(normal.x) > absf(normal.y):
			edge = 1 if normal.x > 0 else 3
		else:
			edge = 0 if normal.y > 0 else 2
		var wall_yaw: float = 0.0 if edge == 0 or edge == 2 else PI * 0.5
		var hid: int = WorldSeed.str_hash(bid)
		var hinge_r: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_building_palette"), hid]) % 1000003) / 1000003.0
		var hinge_left: bool = hinge_r < 0.5
		var ground_y: float = world_plan.terrain_height_at(dpos) + 0.01
		var door_width: float = 1.0
		var door_height: float = 2.1
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
	if door_manifests.size() > WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK:
		door_manifests = door_manifests.slice(0, WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK)
	# Interior walls & furniture & crates
	var interior_walls: Array[Dictionary] = []
	var furniture_anchors: Array[Dictionary] = []
	var crate_manifests: Array[Dictionary] = []
	for b in owned:
		var bid: String = String(b["id"])
		var interior: Dictionary = b.get("interior", {}) as Dictionary
		if interior.is_empty():
			continue
		var walls: Array = interior.get("walls", []) as Array
		for w in walls:
			var wd: Dictionary = w as Dictionary
			interior_walls.append(wd)
		var furn: Array = interior.get("furniture", []) as Array
		for f in furn:
			var fd: Dictionary = f as Dictionary
			furniture_anchors.append(fd)
		var crate: Dictionary = interior.get("crate", {}) as Dictionary
		if not crate.is_empty():
			# build crate manifest with world position height
			var cpos2: Vector2 = crate.get("pos", Vector2.ZERO) as Vector2
			var cyaw: float = float(crate.get("yaw", 0.0))
			var contents: Dictionary = crate.get("contents", {}) as Dictionary
			var ground: float = world_plan.terrain_height_at(cpos2) + 0.01
			var pos3: Vector3 = Vector3(cpos2.x, ground+0.45, cpos2.y)
			var cm: Dictionary = {
				"id": crate.get("id", "rural_crate_%s" % bid),
				"building_id": bid,
				"pos": cpos2,
				"position": pos3,
				"yaw": cyaw,
				"contents": contents,
				"kind": &"rural_crate",
				"aabb": crate.get("aabb", Rect2(cpos2 - Vector2(0.5,0.5), Vector2(1,1))),
			}
			crate_manifests.append(cm)
	# Enforce per chunk caps
	# Furniture cap 6 per village chunk else 4
	var has_village := false
	for b in owned:
		if String(b["settlement_kind"]) == "village":
			has_village = true
			break
	var furn_cap: int = WorldConstants.RURAL_FURNITURE_MAX_PER_VILLAGE_CHUNK if has_village else 4
	# also cap by WorldConstants.RURAL_FURNITURE_CAP_PER_CHUNK
	furn_cap = mini(furn_cap, WorldConstants.RURAL_FURNITURE_CAP_PER_CHUNK)
	if furniture_anchors.size() > furn_cap:
		# deterministic sort by pos string
		furniture_anchors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("kind","")) < String(b.get("kind","")) or (String(a.get("kind",""))==String(b.get("kind","")) and Vector2(a.get("pos",Vector2.ZERO)).x < Vector2(b.get("pos",Vector2.ZERO)).x)
		)
		furniture_anchors = furniture_anchors.slice(0, furn_cap)
	# Crate cap 3
	if crate_manifests.size() > WorldConstants.RURAL_CRATE_MAX_PER_CHUNK:
		crate_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"])
		)
		crate_manifests = crate_manifests.slice(0, WorldConstants.RURAL_CRATE_MAX_PER_CHUNK)
	crate_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	interior_walls.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Vector2(a.get("pos",Vector2.ZERO)).x < Vector2(b.get("pos",Vector2.ZERO)).x
	)
	# Generate batched mesh geometry
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var vert_count := 0
	var tri_count := 0
	var aabbs: Array[Rect2] = []
	var building_colors: Array[Color] = []
	# For collider we need separate verts for shell+wall only
	var collider_verts := PackedVector3Array()
	var collider_indices := PackedInt32Array()
	var collider_offset := 0
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
		var faces: Array[Dictionary] = [
			{"idx": [0,1,2,3], "normal": Vector3.DOWN, "color": wall_col},
			{"idx": [4,7,6,5], "normal": Vector3.UP, "color": roof_col},
			{"idx": [0,4,5,1], "normal": Vector3(0,0,-1), "color": wall_col},
			{"idx": [2,6,7,3], "normal": Vector3(0,0,1), "color": wall_col},
			{"idx": [1,5,6,2], "normal": Vector3(1,0,0), "color": wall_col},
			{"idx": [3,7,4,0], "normal": Vector3(-1,0,0), "color": wall_col},
		]
		var base_idx: int = verts.size()
		var collider_base: int = collider_verts.size()
		for f in faces:
			var idxs: Array = f["idx"] as Array
			var n: Vector3 = f["normal"] as Vector3
			var col: Color = f["color"] as Color
			var face_verts: Array[Vector3] = [corners[idxs[0]], corners[idxs[1]], corners[idxs[2]], corners[idxs[3]]]
			for v in face_verts:
				verts.append(v)
				normals.append(n)
				colors.append(col)
				collider_verts.append(v)
			var b0: int = base_idx
			indices.append(b0); indices.append(b0+1); indices.append(b0+2)
			indices.append(b0); indices.append(b0+2); indices.append(b0+3)
			var c0: int = collider_base
			collider_indices.append(c0); collider_indices.append(c0+1); collider_indices.append(c0+2)
			collider_indices.append(c0); collider_indices.append(c0+2); collider_indices.append(c0+3)
			base_idx +=4
			collider_base +=4
		vert_count +=24
		tri_count +=12
		aabbs.append(b["aabb"] as Rect2)
		building_colors.append(wall_col)
	# Interior walls
	var interior_vertices := 0
	var interior_triangles := 0
	for w in interior_walls:
		var wpos: Vector2 = w.get("pos", Vector2.ZERO) as Vector2
		var wsize: Vector3 = w.get("size", Vector3(0.15,2.4,4.0)) as Vector3
		var wyaw: float = float(w.get("yaw", 0.0))
		# Determine wall color darker plaster
		var base_col: Color = COL_PLASTER
		# Try to find building color for wall's building? Use darkened
		var dark_col: Color = Color(base_col.r*COL_WALL_DARK_FACTOR, base_col.g*COL_WALL_DARK_FACTOR, base_col.b*COL_WALL_DARK_FACTOR)
		# ground height at wall pos
		var ground_w: float = world_plan.terrain_height_at(wpos) + 0.01
		var wall_center: Vector3 = Vector3(wpos.x, ground_w + wsize.y*0.5, wpos.y)
		var w_verts_before: int = verts.size()
		_add_box(verts, normals, colors, indices, wall_center, wsize, dark_col)
		# also add to collider with dummy arrays
		var dummy_n := PackedVector3Array()
		var dummy_c := PackedColorArray()
		var dummy_idx := PackedInt32Array()
		# we need to generate collider box separately: reuse _add_box but throw away its normals
		var c_verts_before: int = collider_verts.size()
		_add_box(collider_verts, dummy_n, dummy_c, collider_indices, wall_center, wsize, dark_col)
		interior_vertices +=24
		interior_triangles +=12
	# Furniture proxies (visual only, not in collider)
	for f in furniture_anchors:
		var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
		var fsize: Vector3 = f.get("size", Vector3(1.0,0.5,0.9)) as Vector3
		var fkind: StringName = f.get("kind", &"shelf") as StringName
		var fcol: Color
		match fkind:
			&"bed":
				fcol = COL_FURNITURE_BED
			&"shelf":
				fcol = COL_FURNITURE_SHELF
			&"table":
				fcol = COL_FURNITURE_TABLE
			&"stove":
				fcol = COL_FURNITURE_STOVE
			_:
				fcol = COL_FURNITURE_SHELF
		var ground_f: float = world_plan.terrain_height_at(fpos) + 0.01
		var f_center: Vector3 = Vector3(fpos.x, ground_f + fsize.y*0.5, fpos.y)
		_add_box(verts, normals, colors, indices, f_center, fsize, fcol)
		interior_vertices +=24
		interior_triangles +=12
	# Enforce budget: if verts >400, drop furniture iteratively
	while verts.size() > WorldConstants.MAX_RURAL_VERTS_PER_CHUNK and furniture_anchors.size() >0:
		# remove last furniture
		# For simplicity, we already added, so need to recalc: remove last furniture box (24 verts = 24*? each box 24 verts, 6 faces*4)
		# Remove last 24 verts and 36 indices (12 tris *3)
		verts.resize(verts.size()-24)
		normals.resize(normals.size()-24)
		colors.resize(colors.size()-24)
		indices.resize(indices.size()-36)
		furniture_anchors = furniture_anchors.slice(0, furniture_anchors.size()-1)
		interior_vertices -=24
		interior_triangles -=12
	var total_verts: int = verts.size()
	var total_tris: int = indices.size() / 3
	var colliders: int = 1 if has_rural else 0
	var rural_doors: int = door_manifests.size()
	var rural_crates: int = crate_manifests.size()
	var rural_furniture: int = furniture_anchors.size()
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	door_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"rural_buildings": owned,
		"door_manifests": door_manifests,
		"interior_walls": interior_walls,
		"furniture_anchors": furniture_anchors,
		"crate_manifests": crate_manifests,
		"rural_vertices": total_verts,
		"rural_triangles": total_tris,
		"rural_colliders": colliders,
		"rural_doors": rural_doors,
		"rural_crates": rural_crates,
		"rural_furniture": rural_furniture,
		"interior_vertices": interior_vertices,
		"interior_triangles": interior_triangles,
		"has_rural": has_rural,
		"rural_gen_ms": gen_ms,
		"rural_mat_ms": 0.0,
		"aabbs": aabbs,
		"colors": colors,
		"verts": verts,
		"normals": normals,
		"indices": indices,
		"collider_verts": collider_verts,
		"collider_indices": collider_indices,
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
			"rural_crates": 0,
			"rural_furniture": 0,
			"rural_buildings": 0,
			"has_rural": false,
			"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
			"rural_mat_ms": mat_ms_empty,
		}
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	var collider_verts: PackedVector3Array = manifest.get("collider_verts", verts) as PackedVector3Array
	var collider_indices: PackedInt32Array = manifest.get("collider_indices", indices) as PackedInt32Array
	var door_manifests: Array = manifest.get("door_manifests", []) as Array
	var crate_manifests: Array = manifest.get("crate_manifests", []) as Array
	var rural_node := Node3D.new()
	rural_node.name = "Rural_%d_%d" % [coord.x, coord.y]
	parent.add_child(rural_node)
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
	var body := StaticBody3D.new()
	body.name = "RuralBody"
	body.collision_layer = 1
	body.collision_mask = 0
	rural_node.add_child(body)
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	var faces := PackedVector3Array()
	# Use collider verts/indices for physics
	var c_verts: PackedVector3Array = collider_verts
	var c_indices: PackedInt32Array = collider_indices
	faces.resize(c_indices.size())
	for idx in c_indices.size():
		var vi: int = c_indices[idx]
		if vi >= 0 and vi < c_verts.size():
			faces[idx] = c_verts[vi]
	concave.data = faces
	var coll := CollisionShape3D.new()
	coll.shape = concave
	body.add_child(coll)
	var door_count := 0
	for dm in door_manifests:
		var d: Dictionary = dm as Dictionary
		var door := Door.new()
		door.name = String(d["id"])
		door.setup(d)
		rural_node.add_child(door)
		door_count += 1
	var crate_count := 0
	for cm in crate_manifests:
		var c: Dictionary = cm as Dictionary
		var crate := FoodCrate.new()
		crate.name = String(c["id"])
		# position
		var pos3: Vector3 = c.get("position", Vector3.ZERO) as Vector3
		crate.position = pos3
		crate.rotation.y = float(c.get("yaw", 0.0))
		var contents: Dictionary = c.get("contents", {}) as Dictionary
		# contents keys are StringName -> int, need to ensure StringName
		var conv: Dictionary = {}
		for k in contents.keys():
			conv[StringName(str(k))] = int(contents[k])
		crate.contents = conv
		# Ensure prompt update after _ready? _ready will call _update_prompt, but contents set after _ready may not update. Call load_state
		# Use load_state to set contents and update prompt
		# Need to defer until after _ready? We can set contents before add_child, then _ready will use it. So set before add.
		# Actually we already set contents before add, but crate.contents was empty at _ready. So we need to call _update_prompt after.
		rural_node.add_child(crate)
		# After _ready, update prompt
		if crate.has_method("_update_prompt"):
			crate.call("_update_prompt")
		else:
			# fallback call via load_state
			crate.load_state(conv)
		crate_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"rural_vertices": verts.size(),
		"rural_triangles": indices.size() / 3,
		"rural_colliders": 1,
		"rural_doors": door_count,
		"rural_crates": crate_count,
		"rural_furniture": int(manifest.get("rural_furniture", 0)),
		"rural_buildings": int((manifest.get("rural_buildings", []) as Array).size()),
		"has_rural": true,
		"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
		"rural_mat_ms": mat_ms,
	}
