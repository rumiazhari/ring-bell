class_name BiomeChunkBuilder
extends RefCounted
## Pure biome manifest + main-thread materialization for P3.1 rural mosaic.
## 9x9 samples per 64 m chunk (8 m spacing), world-space shared edges matching terrain/water,
## one overlay mesh + at most one MultiMesh + at most one collider per chunk (ACTIVE-only).
## Overlay lift 0.03 m above terrain to avoid z-fighting without extra depth bias.
## Budgets: 81 verts / <=128 tris per chunk, <=48 forest or <=12 field + <=6 quarry instances per chunk (global <=48), <=1 collider.
## Urban inner flat emits urban_basin with 0 instances; water samples are floodplain/wet_meadow not forest/field.

const RESOLUTION := 9
const SPACING := 8.0
const CHUNK_M := 64.0

static func _urban_factor(p: Vector2) -> float:
	var d := p.length()
	if d <= WorldConstants.URBAN_INNER_M:
		return 0.0
	if d >= WorldConstants.URBAN_OUTER_M:
		return 1.0
	return (d - WorldConstants.URBAN_INNER_M) / (WorldConstants.URBAN_OUTER_M - WorldConstants.URBAN_INNER_M)

static func _masked_height(world_plan: WorldPlan, p: Vector2) -> float:
	var h: float = world_plan.terrain_height_at(p)
	var t := _urban_factor(p)
	var s := t * t * (3.0 - 2.0 * t)
	return lerpf(0.0, h, s)

static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var biome_ids: Array[StringName] = []
	biome_ids.resize(RESOLUTION * RESOLUTION)
	var material_ids: Array[StringName] = []
	material_ids.resize(RESOLUTION * RESOLUTION)
	var class_ids: Array[StringName] = []
	class_ids.resize(RESOLUTION * RESOLUTION)
	var colors := PackedColorArray()
	colors.resize(RESOLUTION * RESOLUTION)
	var heights := PackedFloat32Array()
	heights.resize(RESOLUTION * RESOLUTION)
	var has_forest := false
	var has_field := false
	var has_quarry := false
	var is_wet_margin := false
	var wet_count := 0
	# For instance generation, collect sampling data
	for j in RESOLUTION:
		for i in RESOLUTION:
			var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
			var idx := j * RESOLUTION + i
			var b: StringName = world_plan.biome_at(p)
			biome_ids[idx] = b
			# material/class proxies: reuse biome as material, class as terrain class for debug
			material_ids[idx] = b
			class_ids[idx] = world_plan.terrain_class_at(p)
			colors[idx] = world_plan.surface_tint_at(p)
			heights[idx] = _masked_height(world_plan, p) + WorldConstants.BIOME_OVERLAY_LIFT_M
			if b == &"deciduous_forest" or b == &"mixed_upland_forest":
				has_forest = true
			if b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard" or b == &"orchard":
				has_field = true
			if b == &"rocky_quarry":
				has_quarry = true
			if b == &"river_floodplain" or b == &"wet_meadow":
				is_wet_margin = true
				if world_plan.water_body_at(p) != &"":
					wet_count += 1
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
	var vertex_count := RESOLUTION * RESOLUTION
	var tri_count := (RESOLUTION - 1) * (RESOLUTION - 1) * 2
	# Instance generation deterministic per chunk
	var instances: Array[Transform3D] = []
	var instance_count := 0
	# Urban core check: if center within URBAN_INNER_M, force 0 instances (spec: urban_basin 0 instances)
	var center := origin + size * 0.5
	var is_urban_core: bool = center.length() < WorldConstants.URBAN_INNER_M
	# Also if is_urban_core, has_forest etc may be true due to fringe, but we still zero instances
	# Actually spec says interior URBAN_INNER_M 350 flat yields urban_basin with is_wet_margin=false and instance_count=0
	# Our biome_at already returns urban_basin for points inside 350, but center <350 ensures chunk is interior, we zero instances
	if not is_urban_core:
		# Forest instances
		var forest_samples := 0
		for j in RESOLUTION:
			for i in RESOLUTION:
				var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
				var idx := j * RESOLUTION + i
				var b: StringName = biome_ids[idx]
				if b == &"deciduous_forest" or b == &"mixed_upland_forest":
					forest_samples += 1
		var is_forest_dominant: bool = forest_samples >= 35 # >~43% of 81 indicates dominant
		var forest_cap := 0
		if is_forest_dominant:
			forest_cap = WorldConstants.BIOME_INSTANCE_CAP_FOREST
		elif forest_samples > 0:
			forest_cap = 12 # transitional
		else:
			forest_cap = 0
		var forest_added := 0
		for j in RESOLUTION:
			for i in RESOLUTION:
				if forest_added >= forest_cap:
					break
				var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
				var idx := j * RESOLUTION + i
				var b: StringName = biome_ids[idx]
				if b != &"deciduous_forest" and b != &"mixed_upland_forest":
					continue
				if world_plan.water_body_at(p) != &"" or world_plan.hydrology.is_floodplain(p):
					continue
				var dens: float = world_plan.biome_density_at(p)
				if dens <= WorldConstants.BIOME_DENSITY_FOREST_MIN:
					continue
				# Deterministic transform: hash via combine
				var hsh := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_tree"), coord.x, coord.y, i, j])
				var rng := RandomNumberGenerator.new()
				rng.seed = hsh
				var yaw: float = rng.randf() * TAU
				var scale: float = rng.randf_range(0.9, 1.15)
				var y: float = _masked_height(world_plan, p)
				var x: float = origin.x + float(i) * SPACING + rng.randf_range(-0.8, 0.8)
				var z: float = origin.y + float(j) * SPACING + rng.randf_range(-0.8, 0.8)
				# Clip to chunk rect ownership via footprint center: only emit if center inside chunk rect
				if x < origin.x or x >= origin.x + CHUNK_M or z < origin.y or z >= origin.y + CHUNK_M:
					# clamp to inside
					x = clampf(x, origin.x + 0.1, origin.x + CHUNK_M - 0.1)
					z = clampf(z, origin.y + 0.1, origin.y + CHUNK_M - 0.1)
				var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), Vector3(x, y, z))
				instances.append(xf)
				forest_added += 1
			if forest_added >= forest_cap:
				break
		instance_count = instances.size()
		# Field hedgerow instances (if field present and not forest dominant)
		if has_field and instance_count < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var field_cap := WorldConstants.BIOME_INSTANCE_CAP_FIELD
			var field_added := 0
			for j in RESOLUTION:
				for i in RESOLUTION:
					if field_added >= field_cap:
						break
					if instance_count >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
						break
					var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
					var idx := j * RESOLUTION + i
					var b: StringName = biome_ids[idx]
					if b != &"arable_field" and b != &"pasture" and b != &"pasture_orchard" and b != &"orchard":
						continue
					var edge_v: float = WorldSeed.sample_coherent(p, &"biome_field_edge", WorldConstants.BIOME_FIELD_EDGE_CELL, world_plan.seed_used)
					if edge_v < 0.62:
						continue
					var hsh2 := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_field_edge"), coord.x, coord.y, i, j, 1])
					var rng2 := RandomNumberGenerator.new()
					rng2.seed = hsh2
					var hx: float = origin.x + float(i) * SPACING + rng2.randf_range(-1.0, 1.0)
					var hz: float = origin.y + float(j) * SPACING + rng2.randf_range(-1.0, 1.0)
					if hx < origin.x or hx >= origin.x + CHUNK_M or hz < origin.y or hz >= origin.y + CHUNK_M:
						hx = clampf(hx, origin.x + 0.1, origin.x + CHUNK_M - 0.1)
						hz = clampf(hz, origin.y + 0.1, origin.y + CHUNK_M - 0.1)
					var hy: float = _masked_height(world_plan, Vector2(hx, hz))
					var fh: float = rng2.randf_range(0.45, 0.75)
					var scale_v := Vector3(2.0, fh, 0.4) # hedgerow box length 2m, height 0.45-0.75
					var yaw_f: float = 0.0 # aligned to world axes, no rotation
					# Use scale as basis scale
					var xf2 := Transform3D(Basis.IDENTITY.scaled(scale_v), Vector3(hx, hy + fh * 0.5, hz))
					instances.append(xf2)
					field_added += 1
					instance_count += 1
				if field_added >= field_cap or instance_count >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
		# Quarry instances: 2-6 per quarry chunk
		if has_quarry and instance_count < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var qsuit_center: float = world_plan.quarry_suitability_at(center)
			if qsuit_center > WorldConstants.QUARRY_SUITABILITY_THRESHOLD or has_quarry:
				var hq := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_quarry"), coord.x, coord.y])
				var rngq := RandomNumberGenerator.new()
				rngq.seed = hq
				var qcount: int = int(rngq.randi_range(2, 6))
				# Ensure capped by budget
				var remaining := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instance_count
				qcount = mini(qcount, WorldConstants.BIOME_INSTANCE_CAP_QUARRY)
				qcount = mini(qcount, remaining)
				for n in qcount:
					var qh := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_quarry"), coord.x, coord.y, n])
					var rngn := RandomNumberGenerator.new()
					rngn.seed = qh
					var qx: float = origin.x + rngn.randf_range(4.0, CHUNK_M - 4.0)
					var qz: float = origin.y + rngn.randf_range(4.0, CHUNK_M - 4.0)
					var qy: float = _masked_height(world_plan, Vector2(qx, qz))
					var qs: float = rngn.randf_range(0.6, 1.0)
					var qxf := Transform3D(Basis.IDENTITY.scaled(Vector3(qs, qs * 0.7, qs)), Vector3(qx, qy + qs * 0.35, qz))
					instances.append(qxf)
				instance_count = instances.size()
	# Global cap enforcement <=48
	if instance_count > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		instances.resize(WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK)
		instance_count = instances.size()
	# Urban core forces zero
	if is_urban_core:
		instances.clear()
		instance_count = 0
		has_forest = false
		has_field = false
		has_quarry = false
	# Collision budget: at most one biome collider per chunk (0 if no forest/quarry proxies)
	var biome_colliders := 0
	if has_forest or has_quarry:
		if instance_count > 0:
			biome_colliders = 1
		else:
			# Even if has_forest flag but no instances due to density threshold, still 0
			biome_colliders = 0
	else:
		biome_colliders = 0
	# Field-only should have 0 collider per spec
	if has_forest == false and has_quarry == false:
		biome_colliders = 0
	var gen_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var density_avg := 0.0
	# average density for forest samples
	var dens_sum := 0.0
	var dens_cnt := 0
	for j in RESOLUTION:
		for i in RESOLUTION:
			var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
			var b: StringName = biome_ids[j * RESOLUTION + i]
			if b == &"deciduous_forest" or b == &"mixed_upland_forest":
				dens_sum += world_plan.biome_density_at(p)
				dens_cnt += 1
	if dens_cnt > 0:
		density_avg = dens_sum / float(dens_cnt)
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"resolution": RESOLUTION,
		"biome_ids": biome_ids,
		"material_ids": material_ids,
		"class_ids": class_ids,
		"colors": colors,
		"heights": heights,
		"indices": indices,
		"biome_gen_ms": gen_ms,
		"density": density_avg,
		"instance_count": instance_count,
		"instances": instances,
		"has_forest": has_forest,
		"has_field": has_field,
		"has_quarry": has_quarry,
		"is_wet_margin": is_wet_margin,
		"biome_vertices": vertex_count,
		"biome_triangles": tri_count,
		"biome_colliders": biome_colliders,
		"biome_nodes": 0,
		"biome_instances": instance_count,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO)
	var origin: Vector2 = manifest.get("origin", Vector2.ZERO)
	var heights: PackedFloat32Array = manifest.get("heights", PackedFloat32Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray())
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array())
	var biome_colliders: int = int(manifest.get("biome_colliders", 0))
	var instance_count: int = int(manifest.get("instance_count", 0))
	var instances: Array = manifest.get("instances", [])
	var existing := parent.get_node_or_null(NodePath("Biome_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	var biome_node := Node3D.new()
	biome_node.name = "Biome_%d_%d" % [coord.x, coord.y]
	parent.add_child(biome_node)
	# Build overlay mesh even if zero instances (urban still has tint)
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
			norms[idx] = Vector3.UP
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
	mi.name = "BiomeMesh"
	mi.mesh = mesh
	biome_node.add_child(mi)
	# MultiMesh for instances
	var multimesh_created := 0
	if instance_count > 0 and not instances.is_empty():
		var mm_instance := MultiMeshInstance3D.new()
		mm_instance.name = "BiomeMultimesh"
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.instance_count = instance_count
		# Use a simple BoxMesh as proxy; vertex-colored via material? Keep simple.
		var box := BoxMesh.new()
		box.size = Vector3(1, 1, 1)
		var box_mat := StandardMaterial3D.new()
		box_mat.vertex_color_use_as_albedo = false
		box_mat.albedo_color = Color(0.3, 0.45, 0.25)
		box.material = box_mat
		multimesh.mesh = box
		for n in instance_count:
			var xf: Transform3D = instances[n] as Transform3D
			multimesh.set_instance_transform(n, xf)
		mm_instance.multimesh = multimesh
		biome_node.add_child(mm_instance)
		multimesh_created = 1
	# Collider: at most one per chunk (sparse aggregated, budgeted choice)
	# Use a single BoxShape per chunk instead of per-instance Concave to keep
	# physics cost low (9 active biome max -> 9 boxes, not 9*48 concave faces).
	# Detailed per-tree collision remains a later milestone; this satisfies
	# the 1-collider ACTIVE-only budget with minimal RID/collision cost.
	var collider_created := 0
	if biome_colliders == 1 and instance_count > 0:
		var body := StaticBody3D.new()
		body.name = "BiomeBody"
		body.collision_layer = 1
		body.collision_mask = 0
		biome_node.add_child(body)
		var box_shape := BoxShape3D.new()
		# Representative trunk/boulder size; placed at first instance or chunk center
		var base_pos: Vector3 = Vector3.ZERO
		if not instances.is_empty():
			base_pos = (instances[0] as Transform3D).origin
		else:
			base_pos = Vector3(origin.x + CHUNK_M * 0.5, 0.0, origin.y + CHUNK_M * 0.5)
		# Ensure Y at terrain height
		if base_pos.y == 0.0:
			base_pos.y = 0.6
		box_shape.size = Vector3(0.6, 1.2, 0.6)
		var coll := CollisionShape3D.new()
		coll.shape = box_shape
		coll.position = base_pos
		body.add_child(coll)
		collider_created = 1
	var mat_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var verts_n := verts.size()
	var tris_n := indices.size() / 3
	return {
		"biome_vertices": verts_n,
		"biome_triangles": tris_n,
		"biome_colliders": collider_created,
		"biome_instances": instance_count,
		"biome_gen_ms": float(manifest.get("biome_gen_ms", 0.0)),
		"biome_mat_ms": mat_ms,
		"biome_nodes": 1 + multimesh_created + collider_created,
		"biome_multimesh": multimesh_created,
	}
