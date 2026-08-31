class_name VerticalChunkBuilder
extends RefCounted
## Pure vertical bridge chunk manifest + main-thread materialization for G8 M4.
## Each 64m chunk carries at most one roof bridge (0 if dry), 24 verts / 12 tris, 0 collider (Area3D only, ACTIVE-only).
## Manifest deterministic byte-identical shuffled including negative coords, center ownership, 256 landscape cell capped.

const CHUNK_M := 64.0
const COL_VERTICAL := Color("8b7f6e")
const COL_VERTICAL_DARK := Color("6b5a4a")

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
	var raw: Array[Dictionary] = world_plan.vertical_bridges_in(rect) if world_plan != null and world_plan.has_method("vertical_bridges_in") else [] as Array[Dictionary]
	raw.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	if raw.size() > WorldConstants.VERTICAL_BRIDGE_MAX_PER_CHUNK:
		raw = raw.slice(0, WorldConstants.VERTICAL_BRIDGE_MAX_PER_CHUNK)
	var has_vertical: bool = raw.size() > 0
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var v_count: int = 0
	var t_count: int = 0
	for br in raw:
		var mid: Vector2 = br.get("pos", Vector2.ZERO) as Vector2
		var yaw: float = float(br.get("yaw", 0.0))
		var span: float = float(br.get("span", WorldConstants.VERTICAL_BRIDGE_SPAN_MIN))
		var width: float = float(br.get("width", WorldConstants.VERTICAL_BRIDGE_WIDTH))
		var thickness: float = float(br.get("thickness", WorldConstants.VERTICAL_BRIDGE_THICKNESS))
		if span < WorldConstants.VERTICAL_BRIDGE_SPAN_MIN - 0.01:
			span = WorldConstants.VERTICAL_BRIDGE_SPAN_MIN
		if span > WorldConstants.VERTICAL_BRIDGE_SPAN_MAX + 0.01:
			span = clampf(span, WorldConstants.VERTICAL_BRIDGE_SPAN_MIN, WorldConstants.VERTICAL_BRIDGE_SPAN_MAX)
		var ledge_y: float = float(br.get("ledge_y", 0.0))
		# Center at mid.x, ledge_y - thickness*0.5, mid.y (z)
		var center: Vector3 = Vector3(mid.x, ledge_y - thickness * 0.5, mid.y)
		var box_size: Vector3
		if is_equal_approx(absf(yaw), PI * 0.5):
			box_size = Vector3(width, thickness, span)
		else:
			box_size = Vector3(span, thickness, width)
		# For non-cardinal? Keep axis-aligned for M4 (cardinal)
		_add_box(verts, normals, colors, indices, center, box_size, COL_VERTICAL)
		v_count += 24
		t_count += 12
	if v_count > WorldConstants.MAX_VERTICAL_VERTS_PER_CHUNK:
		v_count = WorldConstants.MAX_VERTICAL_VERTS_PER_CHUNK
	if t_count > WorldConstants.MAX_VERTICAL_TRIS_PER_CHUNK:
		t_count = WorldConstants.MAX_VERTICAL_TRIS_PER_CHUNK
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	raw.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id","")) < String(b.get("id","")))
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"vertical_bridges": raw,
		"vertical_vertices": v_count,
		"vertical_triangles": t_count,
		"vertical_colliders": 0,
		"has_vertical": has_vertical,
		"vertical_gen_ms": gen_ms,
		"verts": verts,
		"normals": normals,
		"colors": colors,
		"indices": indices,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO) as Vector2i
	var has_vertical: bool = bool(manifest.get("has_vertical", false))
	var bridges: Array = manifest.get("vertical_bridges", []) as Array
	var existing: Node = parent.get_node_or_null(NodePath("Vertical_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if not has_vertical or bridges.is_empty():
		var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
		return {
			"vertical_vertices": 0,
			"vertical_triangles": 0,
			"vertical_colliders": 0,
			"has_vertical": false,
			"vertical_bridges": 0,
			"vertical_gen_ms": float(manifest.get("vertical_gen_ms", 0.0)),
			"vertical_mat_ms": mat_ms_empty,
		}
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	var vert_node := Node3D.new()
	vert_node.name = "Vertical_%d_%d" % [coord.x, coord.y]
	parent.add_child(vert_node)
	vert_node.add_to_group(&"vertical_chunk")
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
	mi.name = "VerticalMesh"
	mi.mesh = mesh
	vert_node.add_child(mi)
	var bridge_count: int = 0
	for br in bridges:
		var d: Dictionary = br as Dictionary
		var mid: Vector2 = d.get("pos", Vector2.ZERO) as Vector2
		var yaw: float = float(d.get("yaw", 0.0))
		var span: float = float(d.get("span", WorldConstants.VERTICAL_BRIDGE_SPAN_MIN))
		var width: float = float(d.get("width", WorldConstants.VERTICAL_BRIDGE_WIDTH))
		var ledge_y: float = float(d.get("ledge_y", 0.0))
		var id: String = String(d.get("id", "vertical_bridge"))
		var VBScript = load("res://world/vertical_bridge.gd")
		var vb = VBScript.new()
		vb.name = "VerticalBridge_%s" % id
		vb.bridge_id = id
		vb.building_a_id = String(d.get("building_a_id", ""))
		vb.building_b_id = String(d.get("building_b_id", ""))
		vb.settlement_id = String(d.get("settlement_id", ""))
		vb.span = span
		vb.width = width
		# Position at mid, ledge_y - thickness*0.5 is mesh center, but Area's position at mid/ledge_y - thickness*0.5? For Area, we set position at mid, y = ledge_y - thickness*0.5 (center of plank)
		# However VerticalBridge's CollisionShape is at (0,0,0) centered, so set Area position to mesh center
		var thickness: float = WorldConstants.VERTICAL_BRIDGE_THICKNESS
		vb.position = Vector3(mid.x, ledge_y - thickness * 0.5, mid.y)
		vb.rotation.y = yaw
		# Store original data for setup
		vb.setup(d)
		vert_node.add_child(vb)
		# Ensure prompt
		if vb.has_method("_update_prompt"):
			vb.call("_update_prompt")
		bridge_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"vertical_vertices": verts.size(),
		"vertical_triangles": indices.size() / 3,
		"vertical_colliders": 0,
		"has_vertical": has_vertical,
		"vertical_bridges": bridge_count,
		"vertical_gen_ms": float(manifest.get("vertical_gen_ms", 0.0)),
		"vertical_mat_ms": mat_ms,
	}
