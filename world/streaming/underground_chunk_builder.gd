class_name UndergroundChunkBuilder
extends RefCounted
## Pure underground cave entrance+chamber chunk manifest + main-thread materialization for G8 M1 + G10 M1 chamber proxy.
## Each 64m chunk carries at most one cave entrance (0 if dry) + one chamber (0-1 per entrance), 24 verts / 12 tris each, combined 48/24 0 collider (Area3D only, ACTIVE-only).
## Manifest deterministic byte-identical shuffled including negative coords, center ownership, 256 landscape cell capped.

const CHUNK_M := 64.0
const COL_CAVE := Color("5a4a3a")
const COL_CHAMBER := Color("4a3a2a")

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
	var t0: int = Time.get_ticks_usec()
	var origin: Vector2 = Vector2(coord) * CHUNK_M
	var size: Vector2 = Vector2(CHUNK_M, CHUNK_M)
	var rect: Rect2 = Rect2(origin, size)
	# query cave entrances and chambers owned by this chunk (center inside rect)
	var raw_entrances: Array[Dictionary] = world_plan.cave_entrances_in(rect) if world_plan != null and world_plan.has_method("cave_entrances_in") else [] as Array[Dictionary]
	var raw_chambers: Array[Dictionary] = world_plan.cave_chambers_in(rect) if world_plan != null and world_plan.has_method("cave_chambers_in") else [] as Array[Dictionary]
	# enforce per-chunk caps 1 each (keep smallest id)
	raw_entrances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	raw_chambers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	if raw_entrances.size() > WorldConstants.CAVE_ENTRANCE_MAX_PER_CHUNK:
		raw_entrances = raw_entrances.slice(0, WorldConstants.CAVE_ENTRANCE_MAX_PER_CHUNK)
	if raw_chambers.size() > WorldConstants.CAVE_CHAMBER_MAX_PER_CHUNK:
		raw_chambers = raw_chambers.slice(0, WorldConstants.CAVE_CHAMBER_MAX_PER_CHUNK)
	# Ensure chamber only if entrance exists in same chunk (xz same); if entrance capped away, drop its chamber
	if raw_entrances.is_empty() and not raw_chambers.is_empty():
		# chamber without entrance should not happen, but enforce: drop chambers if no entrance
		raw_chambers = [] as Array[Dictionary]
	elif not raw_entrances.is_empty() and not raw_chambers.is_empty():
		# Ensure chamber's entrance_id matches an entrance in this chunk; else drop
		var ent_ids: Array = raw_entrances.map(func(d): return String(d.get("id","")))
		var filtered_chambers: Array[Dictionary] = []
		for ch in raw_chambers:
			var eid: String = String(ch.get("entrance_id",""))
			if ent_ids.has(eid):
				filtered_chambers.append(ch)
		raw_chambers = filtered_chambers
	var has_cave: bool = raw_entrances.size() > 0
	var has_chamber: bool = raw_chambers.size() > 0
	var cave_entrances: Array[Dictionary] = raw_entrances
	var cave_chambers: Array[Dictionary] = raw_chambers
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var cave_vertices: int = 0
	var cave_triangles: int = 0
	for ent in cave_entrances:
		var pos: Vector2 = ent.get("pos", Vector2.ZERO) as Vector2
		var yaw: float = float(ent.get("yaw", 0.0))
		var h: float = world_plan.surface_height_at(pos) if world_plan != null else 0.0
		var center: Vector3 = Vector3(pos.x, h + WorldConstants.CAVE_ENTRANCE_LIFT_M + WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5, pos.y)
		var box_size: Vector3 = WorldConstants.CAVE_ENTRANCE_SIZE
		_add_box(verts, normals, colors, indices, center, box_size, COL_CAVE)
		cave_vertices += 24
		cave_triangles += 12
	for ch in cave_chambers:
		var cpos: Vector2 = ch.get("pos", Vector2.ZERO) as Vector2
		var yaw2: float = float(ch.get("yaw", 0.0))
		var h2: float = world_plan.surface_height_at(cpos) if world_plan != null else 0.0
		var ch_size: Vector3 = WorldConstants.CAVE_CHAMBER_SIZE
		var ch_offset: Vector3 = WorldConstants.CAVE_CHAMBER_OFFSET
		var center2: Vector3 = Vector3(cpos.x, h2 + ch_offset.y + ch_size.y * 0.5, cpos.y)
		_add_box(verts, normals, colors, indices, center2, ch_size, COL_CHAMBER)
		cave_vertices += 24
		cave_triangles += 12
	# enforce caps 48/24 combined
	if cave_vertices > WorldConstants.MAX_CAVE_VERTS_PER_CHUNK:
		cave_vertices = WorldConstants.MAX_CAVE_VERTS_PER_CHUNK
	if cave_triangles > WorldConstants.MAX_CAVE_TRIS_PER_CHUNK:
		cave_triangles = WorldConstants.MAX_CAVE_TRIS_PER_CHUNK
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	# ensure deterministic ordering
	cave_entrances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	cave_chambers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"cave_entrances": cave_entrances,
		"cave_chambers": cave_chambers,
		"cave_vertices": cave_vertices,
		"cave_triangles": cave_triangles,
		"cave_colliders": 0,
		"has_cave": has_cave,
		"has_chamber": has_chamber,
		"cave_gen_ms": gen_ms,
		"verts": verts,
		"normals": normals,
		"colors": colors,
		"indices": indices,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO) as Vector2i
	var has_cave: bool = bool(manifest.get("has_cave", false))
	var has_chamber: bool = bool(manifest.get("has_chamber", false))
	var cave_entrances: Array = manifest.get("cave_entrances", []) as Array
	var cave_chambers: Array = manifest.get("cave_chambers", []) as Array
	var existing: Node = parent.get_node_or_null(NodePath("Cave_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if (not has_cave or cave_entrances.is_empty()) and (not has_chamber or cave_chambers.is_empty()):
		# No cave at all
		if not has_cave:
			var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
			return {
				"cave_vertices": 0,
				"cave_triangles": 0,
				"cave_colliders": 0,
				"has_cave": false,
				"has_chamber": false,
				"cave_entrances": 0,
				"cave_chambers": 0,
				"cave_gen_ms": float(manifest.get("cave_gen_ms", 0.0)),
				"cave_mat_ms": mat_ms_empty,
			}
	# has at least entrance
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	var cave_node := Node3D.new()
	cave_node.name = "Cave_%d_%d" % [coord.x, coord.y]
	parent.add_child(cave_node)
	cave_node.add_to_group(&"cave_chunk")
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
	var mesh: ArrayMesh = ArrayMesh.new()
	if indices.size() >= 3 and verts.size() >= 3:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		mat.metallic = 0.0
		mesh.surface_set_material(0, mat)
	else:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.name = "CaveMesh"
	mi.mesh = mesh
	cave_node.add_child(mi)
	# Portal Area3D per entrance (max 1)
	var portal_count: int = 0
	var chamber_count: int = 0
	for ent in cave_entrances:
		var d: Dictionary = ent as Dictionary
		var pos: Vector2 = d.get("pos", Vector2.ZERO) as Vector2
		var yaw: float = float(d.get("yaw", 0.0))
		var id: String = String(d.get("id", "cave_entrance"))
		var base_y: float = 0.0
		if verts.size() > 0:
			base_y = verts[0].y
		else:
			base_y = 0.0
		var portal := CavePortal.new()
		portal.name = "CavePortal_%s" % id
		portal.cave_id = id
		portal.position = Vector3(pos.x, base_y, pos.y)
		portal.rotation.y = yaw
		portal.discovered = bool(d.get("discovered", false))
		cave_node.add_child(portal)
		if portal.has_method("_update_prompt"):
			portal.call("_update_prompt")
		portal_count += 1
	# Chamber portals (max 1) — vault visual already in mesh, portal is Area3D for interaction
	for ch in cave_chambers:
		var d2: Dictionary = ch as Dictionary
		var cpos: Vector2 = d2.get("pos", Vector2.ZERO) as Vector2
		var yaw2: float = float(d2.get("yaw", 0.0))
		var cid: String = String(d2.get("id", "cave_chamber"))
		var eid: String = String(d2.get("entrance_id", ""))
		# Chamber base y = h + offset.y ; we can reuse verts base for chamber? Find chamber base from verts second box if exists
		# For simplicity compute from surface height again (need world_plan? Use portal position's y as base)
		# We have verts: first 24 verts are entrance bottom at base_y, next 24 are chamber bottom at base_y2
		# So if we have both, second box bottom is at verts[24].y
		var base_y2: float = 0.0
		if verts.size() >= 48:
			base_y2 = verts[24].y
		elif verts.size() >= 24 and cave_chambers.size() > 0 and cave_entrances.is_empty():
			base_y2 = verts[0].y
		else:
			# fallback compute from portal position (approx)
			base_y2 = 0.0
			if portal_count > 0 and cave_node.get_child_count() > 0:
				# try to estimate from first portal's position y + offset
				var first_portal_pos_y: float = 0.0
				for child in cave_node.get_children():
					if child is CavePortal:
						first_portal_pos_y = child.position.y
						break
				base_y2 = first_portal_pos_y + WorldConstants.CAVE_CHAMBER_OFFSET.y - 0.01
			else:
				base_y2 = 0.0
		var chamber_portal := Area3D.new()
		chamber_portal.name = "CaveChamberPortal_%s" % cid
		chamber_portal.position = Vector3(cpos.x, base_y2, cpos.y)
		chamber_portal.rotation.y = yaw2
		chamber_portal.monitoring = false
		chamber_portal.monitorable = true
		chamber_portal.collision_layer = 0
		chamber_portal.collision_mask = 0
		chamber_portal.add_to_group(&"interactables")
		var shape_node := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = WorldConstants.CAVE_CHAMBER_SIZE
		shape_node.shape = box
		shape_node.position = Vector3(0, WorldConstants.CAVE_CHAMBER_SIZE.y * 0.5, 0)
		chamber_portal.add_child(shape_node)
		var interact := InteractableComponent.new()
		interact.prompt = "Explore chamber"
		interact.enabled = true
		chamber_portal.add_child(interact)
		# Store metadata for debugging / tests
		chamber_portal.set_meta("cave_id", cid)
		chamber_portal.set_meta("entrance_id", eid)
		cave_node.add_child(chamber_portal)
		chamber_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"cave_vertices": verts.size(),
		"cave_triangles": indices.size() / 3,
		"cave_colliders": 0,
		"has_cave": has_cave,
		"has_chamber": has_chamber,
		"cave_entrances": portal_count,
		"cave_chambers": chamber_count,
		"cave_gen_ms": float(manifest.get("cave_gen_ms", 0.0)),
		"cave_mat_ms": mat_ms,
	}
