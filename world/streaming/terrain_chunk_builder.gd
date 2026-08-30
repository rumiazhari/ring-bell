class_name TerrainChunkBuilder
extends RefCounted
## Pure terrain manifest + main-thread materialization for SPEC-003.
## 17x17 samples per 64m chunk (4m spacing), world-space shared edges,
## one coarse collision per chunk, semantic material mapping.

const RESOLUTION := 17
const SPACING := 4.0
const CHUNK_M := 64.0

# Urban compatibility: protect current Prague basin city at origin.
const URBAN_INNER_M := 350.0
const URBAN_OUTER_M := 600.0

const COL_ALUVIAL := Color("8b8d7a")
const COL_MEADOW := Color("6f8f5a")
const COL_UPLAND := Color("7fa06a")
const COL_ROCK := Color("7a7a7a")

static func _urban_factor(p: Vector2) -> float:
	var d := p.length()
	if d <= URBAN_INNER_M:
		return 0.0
	if d >= URBAN_OUTER_M:
		return 1.0
	return (d - URBAN_INNER_M) / (URBAN_OUTER_M - URBAN_INNER_M)

static func _apply_urban(height: float, p: Vector2) -> float:
	var t := _urban_factor(p)
	var s := t * t * (3.0 - 2.0 * t)
	return lerpf(0.0, height, s)

static func _color_for_material(m: StringName) -> Color:
	match m:
		&"alluvial_soil": return COL_ALUVIAL
		&"meadow_soil": return COL_MEADOW
		&"upland_grass": return COL_UPLAND
		&"rock": return COL_ROCK
		_: return COL_MEADOW

static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var heights := PackedFloat32Array()
	heights.resize(RESOLUTION * RESOLUTION)
	var normals: Array[Vector3] = []
	normals.resize(RESOLUTION * RESOLUTION)
	var material_ids: Array[StringName] = []
	material_ids.resize(RESOLUTION * RESOLUTION)
	var class_ids: Array[StringName] = []
	class_ids.resize(RESOLUTION * RESOLUTION)
	var colors := PackedColorArray()
	colors.resize(RESOLUTION * RESOLUTION)
	for j in RESOLUTION:
		for i in RESOLUTION:
			var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
			var raw_h := world_plan.terrain_height_at(p)
			var h := _apply_urban(raw_h, p)
			var idx := j * RESOLUTION + i
			heights[idx] = h
			var e := 0.5
			var hx1 := _apply_urban(world_plan.terrain_height_at(p + Vector2(e, 0)), p + Vector2(e, 0))
			var hx0 := _apply_urban(world_plan.terrain_height_at(p - Vector2(e, 0)), p - Vector2(e, 0))
			var hz1 := _apply_urban(world_plan.terrain_height_at(p + Vector2(0, e)), p + Vector2(0, e))
			var hz0 := _apply_urban(world_plan.terrain_height_at(p - Vector2(0, e)), p - Vector2(0, e))
			var dx := (hx1 - hx0) / (2.0 * e)
			var dz := (hz1 - hz0) / (2.0 * e)
			var n := Vector3(-dx, 1.0, -dz)
			var len := n.length()
			if len < 1e-6 or not n.is_finite():
				n = Vector3.UP
			else:
				n = n / len
			normals[idx] = n
			var slope := rad_to_deg(acos(clampf(n.dot(Vector3.UP), -1.0, 1.0)))
			var cls: StringName
			if slope >= WorldConstants.CLIFF_SLOPE_DEG:
				cls = &"cliff"
			elif h >= WorldConstants.TERRAIN_UPLAND_HEIGHT_M:
				cls = &"upland"
			elif h >= WorldConstants.TERRAIN_ROLLING_HEIGHT_M:
				cls = &"rolling_hill"
			else:
				cls = &"basin"
			class_ids[idx] = cls
			var mat: StringName
			match cls:
				&"cliff": mat = &"rock"
				&"upland": mat = &"upland_grass"
				&"rolling_hill": mat = &"meadow_soil"
				_: mat = &"alluvial_soil"
			material_ids[idx] = mat
			colors[idx] = _color_for_material(mat)
	var indices := PackedInt32Array()
	indices.resize((RESOLUTION - 1) * (RESOLUTION - 1) * 6)
	var k := 0
	for j in RESOLUTION - 1:
		for i in RESOLUTION - 1:
			var a := j * RESOLUTION + i
			var b := j * RESOLUTION + i + 1
			var c := (j + 1) * RESOLUTION + i
			var d := (j + 1) * RESOLUTION + i + 1
			indices[k] = a; k += 1
			indices[k] = d; k += 1
			indices[k] = b; k += 1
			indices[k] = a; k += 1
			indices[k] = c; k += 1
			indices[k] = d; k += 1
	var compatibility_mode := "urban_flat_inner_%.0f_outer_%.0f" % [URBAN_INNER_M, URBAN_OUTER_M]
	var gen_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var vertex_count := RESOLUTION * RESOLUTION
	var tri_count := (RESOLUTION - 1) * (RESOLUTION - 1) * 2
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"resolution": RESOLUTION,
		"heights": heights,
		"normals": normals,
		"material_ids": material_ids,
		"class_ids": class_ids,
		"colors": colors,
		"indices": indices,
		"compatibility_mode": compatibility_mode,
		"terrain_vertices": vertex_count,
		"terrain_triangles": tri_count,
		"terrain_colliders": 1,
		"terrain_material_samples": vertex_count,
		"terrain_gen_ms": gen_ms,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO)
	var origin: Vector2 = manifest.get("origin", Vector2.ZERO)
	var heights: PackedFloat32Array = manifest.get("heights", PackedFloat32Array())
	var normals: Array = manifest.get("normals", [])
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray())
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array())
	var existing := parent.get_node_or_null(NodePath("Terrain_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	var terrain_node := Node3D.new()
	terrain_node.name = "Terrain_%d_%d" % [coord.x, coord.y]
	parent.add_child(terrain_node)
	var verts := PackedVector3Array()
	verts.resize(RESOLUTION * RESOLUTION)
	var norms := PackedVector3Array()
	norms.resize(RESOLUTION * RESOLUTION)
	for j in RESOLUTION:
		for i in RESOLUTION:
			var idx := j * RESOLUTION + i
			var x := origin.x + float(i) * SPACING
			var z := origin.y + float(j) * SPACING
			var y: float = heights[idx] if idx < heights.size() else 0.0
			verts[idx] = Vector3(x, y, z)
			var n: Vector3 = normals[idx] if idx < normals.size() else Vector3.UP
			norms[idx] = n
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	terrain_node.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	terrain_node.add_child(body)
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for idx in indices.size():
		faces[idx] = verts[indices[idx]]
	concave.data = faces
	var coll := CollisionShape3D.new()
	coll.shape = concave
	body.add_child(coll)
	var mat_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"terrain_vertices": verts.size(),
		"terrain_triangles": indices.size() / 3,
		"terrain_colliders": 1,
		"terrain_material_samples": colors.size(),
		"terrain_gen_ms": float(manifest.get("terrain_gen_ms", 0.0)),
		"terrain_mat_ms": mat_ms,
		"terrain_nodes": 1,
	}
