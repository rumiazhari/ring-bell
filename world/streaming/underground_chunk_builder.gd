class_name UndergroundChunkBuilder
extends RefCounted
## Pure underground cave entrance chunk manifest + main-thread materialization for G8 M1.
## Each 64m chunk carries at most one cave entrance (0 if dry), 24 verts / 12 tris, 0 collider (Area3D only, ACTIVE-only portal).
## Manifest deterministic byte-identical shuffled including negative coords, center ownership, 256 landscape cell capped.

const CHUNK_M := 64.0
const COL_CAVE := Color("5a4a3a")

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
	# query cave entrances owned by this chunk (center inside rect)
	var raw: Array[Dictionary] = world_plan.cave_entrances_in(rect) if world_plan != null and world_plan.has_method("cave_entrances_in") else [] as Array[Dictionary]
	# enforce per-chunk cap 1 (keep smallest id)
	raw.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	if raw.size() > WorldConstants.CAVE_ENTRANCE_MAX_PER_CHUNK:
		raw = raw.slice(0, WorldConstants.CAVE_ENTRANCE_MAX_PER_CHUNK)
	var has_cave: bool = raw.size() > 0
	var cave_entrances: Array[Dictionary] = raw
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
		# box center at terrain+0.01 + height*0.5
		var center: Vector3 = Vector3(pos.x, h + WorldConstants.CAVE_ENTRANCE_LIFT_M + WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5, pos.y)
		var box_size: Vector3 = WorldConstants.CAVE_ENTRANCE_SIZE
		# For oriented box, we keep axis-aligned (yaw does not rotate mesh in M1 slice; portal yaw stored for future use, but mesh stays cardinal for batching)
		# Could apply yaw to box rotation later via portal node rotation; mesh stays at pos with same orientation?
		_add_box(verts, normals, colors, indices, center, box_size, COL_CAVE)
		cave_vertices += 24
		cave_triangles += 12
	# enforce caps
	if cave_vertices > WorldConstants.MAX_CAVE_VERTS_PER_CHUNK:
		cave_vertices = WorldConstants.MAX_CAVE_VERTS_PER_CHUNK
	if cave_triangles > WorldConstants.MAX_CAVE_TRIS_PER_CHUNK:
		cave_triangles = WorldConstants.MAX_CAVE_TRIS_PER_CHUNK
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	# ensure deterministic ordering of entrances
	cave_entrances.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"cave_entrances": cave_entrances,
		"cave_vertices": cave_vertices,
		"cave_triangles": cave_triangles,
		"cave_colliders": 0,
		"has_cave": has_cave,
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
	var cave_entrances: Array = manifest.get("cave_entrances", []) as Array
	var existing: Node = parent.get_node_or_null(NodePath("Cave_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if not has_cave or cave_entrances.is_empty():
		var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
		return {
			"cave_vertices": 0,
			"cave_triangles": 0,
			"cave_colliders": 0,
			"has_cave": false,
			"cave_entrances": 0,
			"cave_gen_ms": float(manifest.get("cave_gen_ms", 0.0)),
			"cave_mat_ms": mat_ms_empty,
		}
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
	for ent in cave_entrances:
		var d: Dictionary = ent as Dictionary
		var pos: Vector2 = d.get("pos", Vector2.ZERO) as Vector2
		var yaw: float = float(d.get("yaw", 0.0))
		var id: String = String(d.get("id", "cave_entrance"))
		# compute height again for portal position (same as mesh center but portal position at base)
		var world_h: float = 0.0
		# Use parent world_plan? We don't have it; use mesh center Y - half height + lift offset already, but for portal we can reuse same center offset
		# The builder already used surface_height; here we just place portal at mesh center (approx)
		# Use verts center if available else compute from manifest
		var center_y: float = 0.0
		if verts.size() > 0:
			# approximate from first vertex y0? Use average
			center_y = verts[0].y + WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5
			# verts[0] is bottom, so center is y0 + half
			# Actually verts bottom y = h+0.01, top = h+0.01+2.2, center = h+0.01+1.1
			# So portal center same as mesh center
			center_y = verts[0].y + WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5
		var portal := CavePortal.new()
		portal.name = "CavePortal_%s" % id
		portal.cave_id = id
		# position at same as mesh center but portal's shape is centered at its own origin; we set portal position to mesh center (so shape at 0)
		# CavePortal's shape is at (0, height*0.5) relative, so we need position at terrain+0.01
		var base_y: float = 0.0
		if verts.size() > 0:
			base_y = verts[0].y
		else:
			base_y = 0.0
		portal.position = Vector3(pos.x, base_y, pos.y)
		portal.rotation.y = yaw
		portal.discovered = bool(d.get("discovered", false))
		cave_node.add_child(portal)
		if portal.has_method("_update_prompt"):
			portal.call("_update_prompt")
		portal_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"cave_vertices": verts.size(),
		"cave_triangles": indices.size() / 3,
		"cave_colliders": 0,
		"has_cave": has_cave,
		"cave_entrances": portal_count,
		"cave_gen_ms": float(manifest.get("cave_gen_ms", 0.0)),
		"cave_mat_ms": mat_ms,
	}
