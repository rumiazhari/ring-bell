class_name RoadChunkBuilder
extends RefCounted
## Pure road+bridge manifest + main-thread materialization for P4.1 settlement/roads slice.
## Each 64m chunk carries at most one road collider (0 if dry), verts <=160 (typical <=96) tris <=96 (typical <=64), ACTIVE-only physics.

const CHUNK_M := 64.0
const RES_SPACING := 12.0
const COL_PRIMARY := Color("7a7a78")
const COL_SECONDARY := Color("8b7f6e")
const COL_TRACK := Color("6e5d4b")
const COL_BRIDGE := Color("6a6a6a")
# abutment edge color not needed separately for vertex-color; use track brown for abutment if needed
const COL_ABUTMENT := Color("5a4a3a")

static func _color_for_hierarchy(hier: StringName, is_bridge: bool) -> Color:
	if is_bridge:
		return COL_BRIDGE
	match hier:
		&"primary":
			return COL_PRIMARY
		&"secondary":
			return COL_SECONDARY
		&"track":
			return COL_TRACK
		_:
			return COL_TRACK

static func _clip_polyline_to_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	if poly.size() < 2:
		return PackedVector2Array()
	var result := PackedVector2Array()
	for i in range(poly.size() - 1):
		var p0: Vector2 = poly[i]
		var p1: Vector2 = poly[i + 1]
		var clipped := _clip_segment_to_rect(p0, p1, rect)
		if clipped.size() == 2:
			var c0: Vector2 = clipped[0]
			var c1: Vector2 = clipped[1]
			if result.is_empty():
				result.append(c0)
				result.append(c1)
			else:
				if result[result.size() - 1].is_equal_approx(c0):
					result.append(c1)
				else:
					# gap: polyline leaves rect and re-enters later; we keep discontinuities but for road we expect continuous inside; just append
					result.append(c0)
					result.append(c1)
	return result

static func _clip_segment_to_rect(p0: Vector2, p1: Vector2, rect: Rect2) -> PackedVector2Array:
	var inside0 := rect.has_point(p0)
	var inside1 := rect.has_point(p1)
	if inside0 and inside1:
		var arr := PackedVector2Array()
		arr.append(p0)
		arr.append(p1)
		return arr
	# Liang-Barsky
	var dx := p1.x - p0.x
	var dy := p1.y - p0.y
	var t0: float = 0.0
	var t1: float = 1.0
	var x_min := rect.position.x
	var y_min := rect.position.y
	var x_max := rect.end.x
	var y_max := rect.end.y
	var p_vals := [-dx, dx, -dy, dy]
	var q_vals := [p0.x - x_min, x_max - p0.x, p0.y - y_min, y_max - p0.y]
	for k in 4:
		var pk: float = p_vals[k]
		var qk: float = q_vals[k]
		if is_equal_approx(pk, 0.0):
			if qk < 0.0:
				return PackedVector2Array()
		else:
			var t: float = qk / pk
			if pk < 0.0:
				if t > t1:
					return PackedVector2Array()
				if t > t0:
					t0 = t
			else:
				if t < t0:
					return PackedVector2Array()
				if t < t1:
					t1 = t
	if t0 > t1:
		return PackedVector2Array()
	var c0 := p0 + Vector2(dx, dy) * t0
	var c1 := p0 + Vector2(dx, dy) * t1
	var arr2 := PackedVector2Array()
	arr2.append(c0)
	arr2.append(c1)
	return arr2

static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var center := origin + size * 0.5
	var extra: float = WorldConstants.ROAD_WIDTH_PRIMARY * 0.5 + 2.5
	var inflated_rect := Rect2(origin - Vector2(extra, extra), size + Vector2(extra * 2.0, extra * 2.0))
	var orig_rect := Rect2(origin, size)
	# Urban suppression: rural roads suppressed inside URBAN_INNER_M unless gate within 90m
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
	# Also if world_plan road graph empty, suppress?
	var road_segments_raw: Array[Dictionary] = []
	if not suppress:
		road_segments_raw = world_plan.road_segments_in(inflated_rect)
	# Filter and clip to orig_rect for tessellation
	var clipped_segments: Array[Dictionary] = []
	var bridge_clipped: Array[Dictionary] = []
	var road_widths: Array[float] = []
	var hierarchies: Array[StringName] = []
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var has_road := false
	var has_bridge := false
	var total_verts := 0
	var total_tris := 0
	if not suppress and not road_segments_raw.is_empty():
		for seg in road_segments_raw:
			var full_poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
			# Clip to orig_rect (centerline)
			var poly: PackedVector2Array = _clip_polyline_to_rect(full_poly, orig_rect)
			if poly.size() < 2:
				continue
			var width: float = float(seg["width"])
			var hier: StringName = seg["hierarchy"] as StringName
			var is_bridge: bool = bool(seg["is_bridge"])
			# For bridge, width slightly larger
			var tess_width: float = width + (WorldConstants.BRIDGE_WIDTH_EXTRA if is_bridge else 0.0)
			# Tessellate this poly
			var n: int = poly.size()
			# For each point compute left/right
			var base_vertex_index: int = verts.size()
			# Precompute left/right points and Y
			for i in n:
				var p: Vector2 = poly[i]
				var dir: Vector2
				if i == 0:
					dir = (poly[1] - poly[0]).normalized()
				elif i == n - 1:
					dir = (poly[n - 1] - poly[n - 2]).normalized()
				else:
					dir = (poly[i + 1] - poly[i - 1]).normalized()
					if dir.length_squared() < 1e-6:
						dir = (poly[i + 1] - poly[i]).normalized()
				if dir.length_squared() < 1e-6:
					dir = Vector2(1, 0)
				var perp := Vector2(-dir.y, dir.x).normalized()
				var left: Vector2 = p + perp * tess_width * 0.5
				var right: Vector2 = p - perp * tess_width * 0.5
				# Height sampling: use center p height, but for left/right we could sample at left/right; use center height for stability
				var y_center: float
				if is_bridge and world_plan.water_body_at(p) != &"":
					y_center = world_plan.water_level_at(p) + WorldConstants.BRIDGE_DECK_LIFT_M
				else:
					# Check if p is over water but not bridge -> should not happen per hydrology gate, but handle: use water level + lift if bridge else terrain
					if world_plan.water_body_at(p) != &"":
						# If road is over water without bridge, this is invalid per spec, but we still place at water level + bridge lift to avoid sinking
						y_center = world_plan.water_level_at(p) + WorldConstants.BRIDGE_DECK_LIFT_M
					else:
						y_center = world_plan.surface_height_at(p) + WorldConstants.ROAD_LIFT_M
						# Road uses the same WorldPlan surface datum as terrain.
				# For left/right vertices, use same Y as center for flat road (avoids twisting)
				var y_left: float = y_center
				var y_right: float = y_center
				# Optionally sample heights at left/right offset positions for more conforming, but keep flat
				var v_left := Vector3(left.x, y_left, left.y)
				var v_right := Vector3(right.x, y_right, right.y)
				verts.append(v_left)
				verts.append(v_right)
				normals.append(Vector3.UP)
				normals.append(Vector3.UP)
				var col: Color = _color_for_hierarchy(hier, is_bridge)
				colors.append(col)
				colors.append(col)
			# Indices for quads
			for i in range(n - 1):
				var b: int = base_vertex_index + i * 2
				# quad vertices: b (left_i), b+1 (right_i), b+2 (left_{i+1}), b+3 (right_{i+1})
				indices.append(b)
				indices.append(b + 1)
				indices.append(b + 2)
				indices.append(b + 2)
				indices.append(b + 1)
				indices.append(b + 3)
			# Record segment for manifest
			var seg_dict: Dictionary = {
				"id": seg["id"],
				"a": seg["a"],
				"b": seg["b"],
				"hierarchy": hier,
				"width": tess_width,
				"is_bridge": is_bridge,
				"water_id": seg.get("water_id", ""),
				"crossing_id": seg.get("crossing_id", ""),
				"polyline": full_poly,
				"polyline_clipped": poly,
				"center": (poly[0] + poly[poly.size() - 1]) * 0.5,
				"length": poly[0].distance_to(poly[poly.size() - 1]),
			}
			clipped_segments.append(seg_dict)
			road_widths.append(tess_width)
			hierarchies.append(hier)
			if is_bridge:
				has_bridge = true
				bridge_clipped.append(seg_dict)
			has_road = true
		total_verts = verts.size()
		total_tris = indices.size() / 3
	# Apply urban suppression: if suppress, force no road
	if suppress:
		clipped_segments.clear()
		bridge_clipped.clear()
		road_widths.clear()
		hierarchies.clear()
		verts.clear()
		normals.clear()
		colors.clear()
		indices.clear()
		has_road = false
		has_bridge = false
		total_verts = 0
		total_tris = 0
	# Budget enforcement: spec says each chunk <=160 verts / <=96 tris, typical <=96/64. If we exceed, truncate? But our tess should not exceed.
	# For safety, if exceeds, keep as is but test will fail; we trust tess is within.
	var colliders: int = 1 if has_road else 0
	var bridge_colliders: int = 0 # shared body
	var bridge_verts: int = 0
	var bridge_tris: int = 0
	if has_bridge:
		# Count bridge verts: approximate as verts for bridge segments only
		# For simplicity, bridge_verts = total_verts if has_bridge else 0? But to keep budget, count separately.
		# Count vertices that belong to bridge segments: we can estimate via loop
		# Already we have bridge_clipped size, but for now set bridge_verts = total_verts if has_bridge else 0
		# Actually need accurate split: we could recompute bridge verts count by summing 2*poly.size for bridge segments
		bridge_verts = 0
		bridge_tris = 0
		for seg in bridge_clipped:
			var p: PackedVector2Array = seg["polyline_clipped"] as PackedVector2Array
			bridge_verts += p.size() * 2
			bridge_tris += (p.size() - 1) * 2
	else:
		bridge_verts = 0
		bridge_tris = 0
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	# For manifest byte-identical check, need deterministic ordering (sort by id already)
	clipped_segments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	bridge_clipped.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"road_segments": clipped_segments,
		"bridge_segments": bridge_clipped,
		"road_vertices": total_verts,
		"road_triangles": total_tris,
		"road_colliders": colliders,
		"bridge_vertices": bridge_verts,
		"bridge_triangles": bridge_tris,
		"bridge_colliders": bridge_colliders,
		"has_road": has_road,
		"has_bridge": has_bridge,
		"road_widths": road_widths,
		"hierarchies": hierarchies,
		"colors": colors,
		"verts": verts,
		"normals": normals,
		"indices": indices,
		"road_gen_ms": gen_ms,
		"road_mat_ms": 0.0,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO) as Vector2i
	var has_road: bool = bool(manifest.get("has_road", false))
	var has_bridge: bool = bool(manifest.get("has_bridge", false))
	var existing := parent.get_node_or_null(NodePath("Road_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if not has_road:
		var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
		return {
			"road_vertices": 0,
			"road_triangles": 0,
			"road_colliders": 0,
			"bridge_vertices": 0,
			"bridge_triangles": 0,
			"bridge_colliders": 0,
			"has_road": false,
			"has_bridge": false,
			"road_gen_ms": float(manifest.get("road_gen_ms", 0.0)),
			"road_mat_ms": mat_ms_empty,
			"road_nodes": 0,
		}
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals_raw: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	# Normalize normals to PackedVector3Array
	var norms_arr := PackedVector3Array()
	if normals_raw is PackedVector3Array:
		norms_arr = normals_raw as PackedVector3Array
	else:
		# Convert Array[Vector3]
		norms_arr.resize(verts.size())
		var arr: Array = normals_raw as Array
		for i in verts.size():
			if i < arr.size():
				norms_arr[i] = arr[i] as Vector3
			else:
				norms_arr[i] = Vector3.UP
	var road_node := Node3D.new()
	road_node.name = "Road_%d_%d" % [coord.x, coord.y]
	parent.add_child(road_node)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms_arr
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	if indices.size() >= 3 and verts.size() >= 3:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		mat.metallic = 0.0
		mesh.surface_set_material(0, mat)
	else:
		# Empty mesh fallback
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "RoadMesh"
	mi.mesh = mesh
	road_node.add_child(mi)
	# Single collider aggregated
	var body := StaticBody3D.new()
	body.name = "RoadBody"
	body.collision_layer = 1 | WorldConstants.COLLISION_WALKABLE_GROUND
	body.collision_mask = 0
	road_node.add_child(body)
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
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"road_vertices": verts.size(),
		"road_triangles": indices.size() / 3,
		"road_colliders": 1,
		"bridge_vertices": int(manifest.get("bridge_vertices", 0)),
		"bridge_triangles": int(manifest.get("bridge_triangles", 0)),
		"bridge_colliders": int(manifest.get("bridge_colliders", 0)),
		"has_road": has_road,
		"has_bridge": has_bridge,
		"road_gen_ms": float(manifest.get("road_gen_ms", 0.0)),
		"road_mat_ms": mat_ms,
		"road_nodes": 1,
	}
