class_name BiomeChunkBuilder
extends RefCounted
## Pure biome manifest + main-thread materialization for P3.1 rural mosaic + P5.1 field parcels.
## 9x9 samples per 64 m chunk (8 m spacing), world-space shared edges matching terrain/water,
## one overlay mesh + at most one MultiMesh + at most one collider per chunk (ACTIVE-only) plus tilled parcels.
## Overlay lift 0.03 m above terrain; tilled lift 0.02 m.
## Budgets: 81 verts / <=128 tris overlay, <=96/64 tilled per chunk, <=48 instances total, <=1 collider, <=4 parcels, <=4 CropPatch, hedgerow <=8 of 48.

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

static func _tilled_color(crop: StringName) -> Color:
	match crop:
		&"wheat":
			return WorldConstants.COL_FIELD_WHEAT
		&"barley":
			return WorldConstants.COL_FIELD_BARLEY
		&"potato":
			return WorldConstants.COL_FIELD_POTATO
		&"beet":
			return WorldConstants.COL_FIELD_BEET
		_:
			return WorldConstants.COL_FIELD_WHEAT

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
	for j in RESOLUTION:
		for i in RESOLUTION:
			var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
			var idx := j * RESOLUTION + i
			var b: StringName = world_plan.biome_at(p)
			biome_ids[idx] = b
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
	var instances: Array[Transform3D] = []
	var instance_count := 0
	var center := origin + size * 0.5
	var is_urban_core: bool = center.length() < WorldConstants.URBAN_INNER_M
	if not is_urban_core:
		var forest_samples := 0
		for j in RESOLUTION:
			for i in RESOLUTION:
				var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
				var idx := j * RESOLUTION + i
				var b: StringName = biome_ids[idx]
				if b == &"deciduous_forest" or b == &"mixed_upland_forest":
					forest_samples += 1
		var is_forest_dominant: bool = forest_samples >= 35
		var forest_cap := 0
		if is_forest_dominant:
			forest_cap = WorldConstants.BIOME_INSTANCE_CAP_FOREST
		elif forest_samples > 0:
			forest_cap = 12
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
				var hsh := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_tree"), coord.x, coord.y, i, j])
				var rng := RandomNumberGenerator.new()
				rng.seed = hsh
				var yaw: float = rng.randf() * TAU
				var scale: float = rng.randf_range(0.9, 1.15)
				var y: float = _masked_height(world_plan, p)
				var x: float = origin.x + float(i) * SPACING + rng.randf_range(-0.8, 0.8)
				var z: float = origin.y + float(j) * SPACING + rng.randf_range(-0.8, 0.8)
				if x < origin.x or x >= origin.x + CHUNK_M or z < origin.y or z >= origin.y + CHUNK_M:
					x = clampf(x, origin.x + 0.1, origin.x + CHUNK_M - 0.1)
					z = clampf(z, origin.y + 0.1, origin.y + CHUNK_M - 0.1)
				var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), Vector3(x, y, z))
				instances.append(xf)
				forest_added += 1
			if forest_added >= forest_cap:
				break
		instance_count = instances.size()
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
					var scale_v := Vector3(2.0, fh, 0.4)
					var xf2 := Transform3D(Basis.IDENTITY.scaled(scale_v), Vector3(hx, hy + fh * 0.5, hz))
					instances.append(xf2)
					field_added += 1
					instance_count += 1
				if field_added >= field_cap or instance_count >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
		if has_quarry and instance_count < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var qsuit_center: float = world_plan.quarry_suitability_at(center)
			if qsuit_center > WorldConstants.QUARRY_SUITABILITY_THRESHOLD or has_quarry:
				var hq := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_quarry"), coord.x, coord.y])
				var rngq := RandomNumberGenerator.new()
				rngq.seed = hq
				var qcount: int = int(rngq.randi_range(2, 6))
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
	if instance_count > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		instances.resize(WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK)
		instance_count = instances.size()
	if is_urban_core:
		instances.clear()
		instance_count = 0
		has_forest = false
		has_field = false
		has_quarry = false
	var biome_colliders := 0
	if has_forest or has_quarry:
		if instance_count > 0:
			biome_colliders = 1
		else:
			biome_colliders = 0
	else:
		biome_colliders = 0
	if has_forest == false and has_quarry == false:
		biome_colliders = 0
	# --- Field parcel generation (P5.1) ---
	var chunk_rect := Rect2(origin, size)
	var field_parcels_raw: Array[Dictionary] = []
	if not is_urban_core:
		# field parcels suppressed inside urban flat (350) already via is_urban_core; also need explicit check for center <350 already handled via biome plan's urban inner skip
		field_parcels_raw = world_plan.field_parcels_in(chunk_rect)
	# field parcels are already center-owned, so all in raw are owned by this chunk
	# enforce per-chunk cap <=4
	if field_parcels_raw.size() > WorldConstants.FIELD_PARCEL_MAX_PER_CHUNK:
		field_parcels_raw.resize(WorldConstants.FIELD_PARCEL_MAX_PER_CHUNK)
	var field_parcel_manifests: Array[Dictionary] = []
	var field_vertices := 0
	var field_triangles := 0
	var field_crop_manifests: Array[Dictionary] = []
	var hedgerow_added := 0
	# Hedgerow cap: at most FIELD_HEDGEROW_MAX_PER_CHUNK of 48, field parcels contribute
	var remaining_instances := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instance_count
	var hedgerow_cap := mini(WorldConstants.FIELD_HEDGEROW_MAX_PER_CHUNK, remaining_instances)
	# hedgerow is per parcel perimeter: generate hedgerow boxes along edges
	for parc in field_parcels_raw:
		var pid: String = String(parc.get("id", ""))
		var p_center: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
		var p_aabb: Rect2 = parc.get("aabb", Rect2()) as Rect2
		var p_crop: StringName = parc.get("crop_kind", &"wheat") as StringName
		var p_planted: int = int(parc.get("planted_day", 0))
		var p_yaw: float = float(parc.get("yaw", 0.0))
		var p_size: Vector2 = parc.get("size", Vector2(32,24)) as Vector2
		# field vertices/triangles for tilled quad (4 verts, 2 tris per parcel)
		field_vertices += 4
		field_triangles += 2
		# contents for crop
		var contents: Dictionary = parc.get("contents", {}) as Dictionary
		if contents.is_empty():
			match p_crop:
				&"wheat":
					contents = {&"canned_food": 1}
				&"barley":
					contents = {&"water_bottle": 1}
				&"potato":
					contents = {&"bandage": 1}
				&"beet":
					contents = {&"antibiotics": 1}
				_:
					contents = {&"canned_food": 1}
		var cur_day: int = 1
		if GameClock != null:
			cur_day = GameClock.get_day()
		var is_grown: bool = cur_day >= p_planted + WorldConstants.CROP_GROW_DAYS
		var growth_stage: StringName = &"harvestable" if is_grown else (&"growing" if cur_day == p_planted + 1 else &"planted")
		var h_tilled: float = _masked_height(world_plan, p_center) + WorldConstants.FIELD_PARCEL_LIFT_M
		var tilled_manifest := {
			"id": pid,
			"parcel_id": pid,
			"center": p_center,
			"pos": p_center,
			"aabb": p_aabb,
			"biome": parc.get("biome", &"arable_field"),
			"crop_kind": p_crop,
			"kind": p_crop,
			"size": p_size,
			"yaw": p_yaw,
			"planted_day": p_planted,
			"growth_stage": growth_stage,
			"is_grown": is_grown,
			"contents": contents,
			"landscape_cell": parc.get("landscape_cell", Vector2i.ZERO),
			"macro_cell": parc.get("macro_cell", Vector2i.ZERO),
			"settlement_id": parc.get("settlement_id", ""),
		}
		field_parcel_manifests.append(tilled_manifest)
		var crop_id: String = "crop_%s" % pid
		var crop_pos := Vector3(p_center.x, h_tilled + 0.01, p_center.y)
		var crop_manifest := {
			"id": crop_id,
			"parcel_id": pid,
			"pos": p_center,
			"position": crop_pos,
			"aabb": p_aabb,
			"crop_kind": p_crop,
			"kind": p_crop,
			"contents": contents,
			"planted_day": p_planted,
			"yaw": p_yaw,
			"is_grown": is_grown,
			"growth_stage": growth_stage,
		}
		field_crop_manifests.append(crop_manifest)
		# Hedgerow instances along parcel border (2 per parcel, capped)
		if hedgerow_added < hedgerow_cap:
			var hedges_to_add := mini(2, hedgerow_cap - hedgerow_added)
			# Generate along long edges of parcel
			for hi in hedges_to_add:
				var is_long_side := hi % 2 == 0
				var hx: float
				var hz: float
				var hed_yaw: float
				if is_long_side:
					# long side: along X if yaw 0, else along Z
					if is_equal_approx(absf(p_yaw), PI*0.5):
						hx = p_center.x
						hz = p_center.y + (p_size.y * 0.5 - 0.2) * (1 if hi==0 else -1)
						hed_yaw = p_yaw
					else:
						hx = p_center.x + (p_size.x * 0.5 - 0.2) * (1 if hi==0 else -1)
						hz = p_center.y
						hed_yaw = p_yaw
				else:
					if is_equal_approx(absf(p_yaw), PI*0.5):
						hx = p_center.x + (p_size.x * 0.5 - 0.2) * (1 if hi==0 else -1)
						hz = p_center.y
						hed_yaw = p_yaw
					else:
						hx = p_center.x
						hz = p_center.y + (p_size.y * 0.5 - 0.2) * (1 if hi==0 else -1)
						hed_yaw = p_yaw
				var hedge_y: float = _masked_height(world_plan, Vector2(hx, hz)) + 0.0
				var hedge_h: float = lerpf(WorldConstants.HEDGEROW_TRUE_HEIGHT_MIN, WorldConstants.HEDGEROW_TRUE_HEIGHT_MAX, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_parcel"), WorldSeed.combine([int(hx), int(hz)]), hi]) % 1000003) / 1000003.0)
				# True-mesh hedgerow BoxMesh 2.0x0.45-0.75x0.4 not stretched
				var scale_v := Vector3(WorldConstants.HEDGEROW_TRUE_LENGTH, hedge_h, WorldConstants.HEDGEROW_TRUE_WIDTH)
				hedge_y += hedge_h * 0.5
				var basis := Basis(Vector3.UP, hed_yaw).scaled(scale_v)
				var xf := Transform3D(basis, Vector3(hx, hedge_y, hz))
				instances.append(xf)
				hedgerow_added += 1
				instance_count += 1
				if hedgerow_added >= hedgerow_cap:
					break
	# enforce field caps again after hedgerow
	if field_vertices > WorldConstants.MAX_FIELD_VERTS_PER_CHUNK:
		field_vertices = WorldConstants.MAX_FIELD_VERTS_PER_CHUNK
	if field_triangles > WorldConstants.MAX_FIELD_TRIS_PER_CHUNK:
		field_triangles = WorldConstants.MAX_FIELD_TRIS_PER_CHUNK
	if instance_count > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		# Trim hedgerow if overflow
		var overflow := instance_count - WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK
		if overflow > 0 and hedgerow_added > 0:
			var to_remove := mini(overflow, hedgerow_added)
			instances.resize(instances.size() - to_remove)
			instance_count = instances.size()
			hedgerow_added -= to_remove
	var gen_ms := float(Time.get_ticks_usec() - t0) / 1000.0

# --- Orchard parcel generation P5.2 ---
	var orchard_parcels_raw: Array[Dictionary] = []
	if not is_urban_core:
		orchard_parcels_raw = world_plan.orchard_parcels_in(chunk_rect)
	if orchard_parcels_raw.size() > WorldConstants.ORCHARD_PARCEL_MAX_PER_CHUNK:
		orchard_parcels_raw.resize(WorldConstants.ORCHARD_PARCEL_MAX_PER_CHUNK)
	var orchard_parcel_manifests: Array[Dictionary] = []
	var orchard_vertices := 0
	var orchard_triangles := 0
	var fruit_patch_manifests: Array[Dictionary] = []
	var orchard_hedgerow_added := 0
	var orchard_instances_added := 0
	var remaining_for_orchard := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instance_count
	var orchard_hedgerow_cap := mini(WorldConstants.ORCHARD_HEDGEROW_MAX_PER_CHUNK, maxi(0, remaining_for_orchard))
	var orchard_canopy_cap := mini(WorldConstants.MAX_ORCHARD_INSTANCES_PER_CHUNK, maxi(0, remaining_for_orchard - orchard_hedgerow_cap))
	for parc in orchard_parcels_raw:
		var pid_o: String = String(parc.get("id", ""))
		var p_center_o: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
		var p_aabb_o: Rect2 = parc.get("aabb", Rect2()) as Rect2
		var p_fruit: StringName = parc.get("fruit_kind", &"apple") as StringName
		var p_planted_o: int = int(parc.get("planted_day", 0))
		var p_yaw_o: float = float(parc.get("yaw", 0.0))
		var p_size_o: Vector2 = parc.get("size", Vector2(32,24)) as Vector2
		var p_tree_instances: Array = parc.get("tree_instances", []) as Array
		var cur_day_o: int = 1
		if GameClock != null:
			cur_day_o = GameClock.get_day()
		var is_grown_o: bool = cur_day_o >= p_planted_o + WorldConstants.FRUIT_GROW_DAYS
		var growth_stage_o: StringName = &"harvestable" if is_grown_o else (&"growing" if cur_day_o == p_planted_o + 1 else &"planted")
		var contents_o: Dictionary = parc.get("contents", {}) as Dictionary
		if contents_o.is_empty():
			match p_fruit:
				&"apple":
					contents_o = {&"apple": 1}
				&"plum":
					contents_o = {&"plum": 1}
				&"pear":
					contents_o = {&"pear": 1}
				&"cherry":
					contents_o = {&"cherry": 1}
				_:
					contents_o = {&"apple": 1}
		var orchard_manifest := {
			"id": pid_o,
			"parcel_id": pid_o,
			"center": p_center_o,
			"pos": p_center_o,
			"aabb": p_aabb_o,
			"biome": parc.get("biome", &"orchard"),
			"fruit_kind": p_fruit,
			"kind": p_fruit,
			"size": p_size_o,
			"yaw": p_yaw_o,
			"planted_day": p_planted_o,
			"growth_stage": growth_stage_o,
			"is_grown": is_grown_o,
			"contents": contents_o,
			"landscape_cell": parc.get("landscape_cell", Vector2i.ZERO),
			"macro_cell": parc.get("macro_cell", Vector2i.ZERO),
			"settlement_id": parc.get("settlement_id", ""),
			"tree_instances": p_tree_instances,
			"tree_rows": parc.get("tree_rows", 3),
			"trees_per_row": parc.get("trees_per_row", 3),
		}
		orchard_parcel_manifests.append(orchard_manifest)
		var fruit_id_o: String = "fruit_%s" % pid_o
		var h_fruit: float = _masked_height(world_plan, p_center_o) + WorldConstants.ORCHARD_PARCEL_LIFT_M + 0.01
		var fruit_pos := Vector3(p_center_o.x, h_fruit, p_center_o.y)
		var fruit_manifest := {
			"id": fruit_id_o,
			"parcel_id": pid_o,
			"pos": p_center_o,
			"position": fruit_pos,
			"aabb": p_aabb_o,
			"fruit_kind": p_fruit,
			"kind": p_fruit,
			"contents": contents_o,
			"planted_day": p_planted_o,
			"yaw": p_yaw_o,
			"is_grown": is_grown_o,
			"growth_stage": growth_stage_o,
		}
		fruit_patch_manifests.append(fruit_manifest)
		if orchard_hedgerow_added < orchard_hedgerow_cap:
			var orch_hedges_to_add := mini(2, orchard_hedgerow_cap - orchard_hedgerow_added)
			for hi in orch_hedges_to_add:
				var is_long_o := hi % 2 == 0
				var hx_o: float
				var hz_o: float
				var hed_yaw_o: float
				if is_long_o:
					if is_equal_approx(absf(p_yaw_o), PI*0.5):
						hx_o = p_center_o.x
						hz_o = p_center_o.y + (p_size_o.y * 0.5 - 0.2) * (1 if hi==0 else -1)
						hed_yaw_o = p_yaw_o
					else:
						hx_o = p_center_o.x + (p_size_o.x * 0.5 - 0.2) * (1 if hi==0 else -1)
						hz_o = p_center_o.y
						hed_yaw_o = p_yaw_o
				else:
					if is_equal_approx(absf(p_yaw_o), PI*0.5):
						hx_o = p_center_o.x + (p_size_o.x * 0.5 - 0.2) * (1 if hi==0 else -1)
						hz_o = p_center_o.y
						hed_yaw_o = p_yaw_o
					else:
						hx_o = p_center_o.x
						hz_o = p_center_o.y + (p_size_o.y * 0.5 - 0.2) * (1 if hi==0 else -1)
						hed_yaw_o = p_yaw_o
				var hedge_h_o: float = lerpf(WorldConstants.HEDGEROW_TRUE_HEIGHT_MIN, WorldConstants.HEDGEROW_TRUE_HEIGHT_MAX, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("orchard_parcel"), WorldSeed.combine([int(hx_o), int(hz_o)]), hi]) % 1000003) / 1000003.0)
				var hedge_y_o: float = _masked_height(world_plan, Vector2(hx_o, hz_o)) + hedge_h_o * 0.5
				var scale_v_o := Vector3(WorldConstants.HEDGEROW_TRUE_LENGTH, hedge_h_o, WorldConstants.HEDGEROW_TRUE_WIDTH)
				var basis_o := Basis(Vector3.UP, hed_yaw_o).scaled(scale_v_o)
				var xf_o := Transform3D(basis_o, Vector3(hx_o, hedge_y_o, hz_o))
				instances.append(xf_o)
				orchard_hedgerow_added += 1
				instance_count += 1
				if orchard_hedgerow_added >= orchard_hedgerow_cap:
					break
		if orchard_instances_added < orchard_canopy_cap:
			var remaining_canopy := orchard_canopy_cap - orchard_instances_added
			var trees_to_add := mini(int(p_tree_instances.size()), remaining_canopy)
			for ti in trees_to_add:
				var tpos: Vector3 = p_tree_instances[ti] as Vector3
				var canopy_y: float = tpos.y + 1.4
				var scale_canopy := Vector3(1.4, 1.0, 1.4)
				var xf_c := Transform3D(Basis.IDENTITY.scaled(scale_canopy), Vector3(tpos.x, canopy_y, tpos.z))
				instances.append(xf_c)
				orchard_instances_added += 1
				instance_count += 1
				if orchard_instances_added >= orchard_canopy_cap:
					break
		if orchard_hedgerow_added >= orchard_hedgerow_cap and orchard_instances_added >= orchard_canopy_cap:
			if orchard_parcel_manifests.size() >= orchard_parcels_raw.size():
				break
	if orchard_vertices > WorldConstants.MAX_ORCHARD_VERTS_PER_CHUNK:
		orchard_vertices = WorldConstants.MAX_ORCHARD_VERTS_PER_CHUNK
	if orchard_triangles > WorldConstants.MAX_ORCHARD_TRIS_PER_CHUNK:
		orchard_triangles = WorldConstants.MAX_ORCHARD_TRIS_PER_CHUNK
	if instance_count > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		var overflow_o := instance_count - WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK
		if overflow_o > 0:
			var to_remove_o := mini(overflow_o, orchard_instances_added + orchard_hedgerow_added)
			if to_remove_o > 0:
				instances.resize(instances.size() - to_remove_o)
				instance_count = instances.size()
				if to_remove_o <= orchard_instances_added:
					orchard_instances_added -= to_remove_o
				else:
					var rem := to_remove_o - orchard_instances_added
					orchard_instances_added = 0
					orchard_hedgerow_added = maxi(0, orchard_hedgerow_added - rem)
	var density_avg := 0.0
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
		"field_parcels": field_parcel_manifests.size(),
		"field_parcel_manifests": field_parcel_manifests,
		"field_parcel_count": field_parcel_manifests.size(),
		"field_crops": field_crop_manifests.size(),
		"field_crop_patches": field_crop_manifests.size(),
		"field_crop_manifests": field_crop_manifests,
		"field_vertices": field_vertices,
		"field_triangles": field_triangles,
		"field_hedgerow": hedgerow_added,
		"field_hedgerow_count": hedgerow_added,
		"orchard_parcels": orchard_parcel_manifests.size(),
		"orchard_parcel_manifests": orchard_parcel_manifests,
		"orchard_parcel_count": orchard_parcel_manifests.size(),
		"fruit_patches": fruit_patch_manifests.size(),
		"fruit_patch_manifests": fruit_patch_manifests,
		"fruit_patch_count": fruit_patch_manifests.size(),
		"orchard_vertices": orchard_vertices,
		"orchard_triangles": orchard_triangles,
		"orchard_hedgerow": orchard_hedgerow_added,
		"orchard_hedgerow_count": orchard_hedgerow_added,
		"orchard_instances": orchard_instances_added,
		"orchard_instance_count": orchard_instances_added,
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
	var field_parcel_manifests: Array = manifest.get("field_parcel_manifests", [])
	var field_crop_manifests: Array = manifest.get("field_crop_manifests", [])
	var field_vertices: int = int(manifest.get("field_vertices", 0))
	var field_triangles: int = int(manifest.get("field_triangles", 0))
	var orchard_parcel_manifests: Array = manifest.get("orchard_parcel_manifests", [])
	var fruit_patch_manifests: Array = manifest.get("fruit_patch_manifests", [])
	var orchard_vertices: int = int(manifest.get("orchard_vertices", 0))
	var orchard_triangles: int = int(manifest.get("orchard_triangles", 0))
	var existing := parent.get_node_or_null(NodePath("Biome_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.queue_free()
	var biome_node := Node3D.new()
	biome_node.name = "Biome_%d_%d" % [coord.x, coord.y]
	parent.add_child(biome_node)
	# Build overlay mesh (81) + tilled quads (field)
	var overlay_verts := PackedVector3Array()
	overlay_verts.resize(RESOLUTION * RESOLUTION)
	var overlay_norms := PackedVector3Array()
	overlay_norms.resize(RESOLUTION * RESOLUTION)
	for j in RESOLUTION:
		for i in RESOLUTION:
			var idx := j * RESOLUTION + i
			var x := origin.x + float(i) * SPACING
			var z := origin.y + float(j) * SPACING
			var y: float = heights[idx] if idx < heights.size() else 0.0
			overlay_verts[idx] = Vector3(x, y, z)
			overlay_norms[idx] = Vector3.UP
	# If field parcels present, create combined mesh with tilled quads
	var all_verts := PackedVector3Array()
	var all_colors := PackedColorArray()
	var all_indices := PackedInt32Array()
	all_verts = overlay_verts.duplicate()
	all_colors = colors.duplicate()
	all_indices = indices.duplicate()
	var base_idx := overlay_verts.size()
	# Add tilled quad vertices per parcel
	for parc in field_parcel_manifests:
		var pd: Dictionary = parc as Dictionary
		var p_center: Vector2 = pd.get("center", Vector2.ZERO) as Vector2
		var p_size: Vector2 = pd.get("size", Vector2(32,24)) as Vector2
		var p_crop: StringName = pd.get("crop_kind", &"wheat") as StringName
		var p_yaw: float = float(pd.get("yaw", 0.0))
		var col: Color = _tilled_color(p_crop)
		var h: float = 0.0
		if heights.size() > 0:
			# approximate height at center from overlay heights (nearest)
			var ix := clampi(int(round((p_center.x - origin.x) / SPACING)), 0, RESOLUTION-1)
			var jz := clampi(int(round((p_center.y - origin.y) / SPACING)), 0, RESOLUTION-1)
			var idx_c := jz * RESOLUTION + ix
			if idx_c < heights.size():
				h = heights[idx_c] - WorldConstants.BIOME_OVERLAY_LIFT_M + WorldConstants.FIELD_PARCEL_LIFT_M
			else:
				h = 0.0 + WorldConstants.FIELD_PARCEL_LIFT_M
		else:
			h = WorldConstants.FIELD_PARCEL_LIFT_M
		# Quad corners axis-aligned with yaw (cardinal only)
		var hx := p_size.x * 0.5
		var hz := p_size.y * 0.5
		var corners: Array[Vector3] = []
		if is_equal_approx(absf(p_yaw), PI*0.5):
			# swap
			hx = p_size.y * 0.5
			hz = p_size.x * 0.5
		corners.append(Vector3(p_center.x - hx, h, p_center.y - hz))
		corners.append(Vector3(p_center.x + hx, h, p_center.y - hz))
		corners.append(Vector3(p_center.x + hx, h, p_center.y + hz))
		corners.append(Vector3(p_center.x - hx, h, p_center.y + hz))
		var start := all_verts.size()
		for c in corners:
			all_verts.append(c)
			all_colors.append(col)
		# two triangles
		all_indices.append(start)
		all_indices.append(start + 1)
		all_indices.append(start + 2)
		all_indices.append(start)
		all_indices.append(start + 2)
		all_indices.append(start + 3)
	# Build mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_verts
	var norms := PackedVector3Array()
	norms.resize(all_verts.size())
	for i in all_verts.size():
		norms[i] = Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = norms
	if not all_colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = all_colors
	arrays[Mesh.ARRAY_INDEX] = all_indices
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
	# MultiMesh for instances (forest + field edge + hedgerow)
	var multimesh_created := 0
	if instance_count > 0 and not instances.is_empty():
		var mm_instance := MultiMeshInstance3D.new()
		mm_instance.name = "BiomeMultimesh"
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.instance_count = instance_count
		var box := BoxMesh.new()
		box.size = Vector3(1, 1, 1)
		var box_mat := StandardMaterial3D.new()
		box_mat.vertex_color_use_as_albedo = true
		box_mat.albedo_color = Color("5a7a3a")
		box.material = box_mat
		multimesh.mesh = box
		for n in instance_count:
			var xf: Transform3D = instances[n] as Transform3D
			multimesh.set_instance_transform(n, xf)
		mm_instance.multimesh = multimesh
		biome_node.add_child(mm_instance)
		multimesh_created = 1
	var collider_created := 0
	if biome_colliders == 1 and instance_count > 0:
		var body := StaticBody3D.new()
		body.name = "BiomeBody"
		body.collision_layer = 1
		body.collision_mask = 0
		biome_node.add_child(body)
		var box_shape := BoxShape3D.new()
		var base_pos: Vector3 = Vector3.ZERO
		if not instances.is_empty():
			base_pos = (instances[0] as Transform3D).origin
		else:
			base_pos = Vector3(origin.x + CHUNK_M * 0.5, 0.0, origin.y + CHUNK_M * 0.5)
		if base_pos.y == 0.0:
			base_pos.y = 0.6
		box_shape.size = Vector3(0.6, 1.2, 0.6)
		var coll := CollisionShape3D.new()
		coll.shape = box_shape
		coll.position = base_pos
		body.add_child(coll)
		collider_created = 1
	# CropPatch Area3D leaves (ACTIVE-only monitorable, no collider counted)
	var crops_created := 0
	for cdata in field_crop_manifests:
		var cd: Dictionary = cdata as Dictionary
		var patch := CropPatch.new()
		patch.name = String(cd.get("id", "crop_unknown"))
		# Setup will be called after adding to tree? Set data then add
		patch.crop_id = String(cd.get("id", ""))
		patch.parcel_id = String(cd.get("parcel_id", ""))
		var ck: StringName = StringName(str(cd.get("crop_kind", cd.get("kind", "wheat"))))
		patch.crop_kind = ck
		patch.planted_day = int(cd.get("planted_day", 0))
		var cont: Dictionary = cd.get("contents", {}) as Dictionary
		patch.contents.clear()
		for kk in cont.keys():
			patch.contents[StringName(str(kk))] = int(cont[kk])
		var pos3: Vector3 = cd.get("position", Vector3.ZERO) as Vector3
		# Ensure position's y is at terrain + lift; pos3 already has correct y from manifest
		biome_node.add_child(patch)
		patch.position = pos3
		if cd.has("yaw"):
			patch.rotation.y = float(cd["yaw"])
		# initial depleted false; will be patched by ChunkManager if saved
		crops_created += 1
	# FruitPatch Area3D leaves (ACTIVE-only monitorable, no collider counted)
	var fruits_created := 0
	for fdata in fruit_patch_manifests:
		var fd: Dictionary = fdata as Dictionary
		var fpatch := FruitPatch.new()
		fpatch.name = String(fd.get("id", "fruit_unknown"))
		fpatch.fruit_id = String(fd.get("id", ""))
		fpatch.parcel_id = String(fd.get("parcel_id", ""))
		var fk: StringName = StringName(str(fd.get("fruit_kind", fd.get("kind", "apple"))))
		fpatch.fruit_kind = fk
		fpatch.planted_day = int(fd.get("planted_day", 0))
		var fcont: Dictionary = fd.get("contents", {}) as Dictionary
		fpatch.contents.clear()
		for kk in fcont.keys():
			fpatch.contents[StringName(str(kk))] = int(fcont[kk])
		var fpos3: Vector3 = fd.get("position", Vector3.ZERO) as Vector3
		biome_node.add_child(fpatch)
		fpatch.position = fpos3
		if fd.has("yaw"):
			fpatch.rotation.y = float(fd["yaw"])
		fruits_created += 1
	var mat_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var verts_n := all_verts.size()
	var tris_n := all_indices.size() / 3
	return {
		"biome_vertices": verts_n,
		"biome_triangles": tris_n,
		"biome_colliders": collider_created,
		"biome_instances": instance_count,
		"biome_gen_ms": float(manifest.get("biome_gen_ms", 0.0)),
		"biome_mat_ms": mat_ms,
		"biome_nodes": 1 + multimesh_created + collider_created,
		"biome_multimesh": multimesh_created,
		"field_parcels": int(field_parcel_manifests.size()),
		"field_crops": crops_created,
		"field_vertices": field_vertices,
		"field_triangles": field_triangles,
		"field_hedgerow": int(manifest.get("field_hedgerow", 0)),
		"orchard_parcels": int(orchard_parcel_manifests.size()),
		"fruit_patches": fruits_created,
		"orchard_vertices": orchard_vertices,
		"orchard_triangles": orchard_triangles,
		"orchard_hedgerow": int(manifest.get("orchard_hedgerow", 0)),
		"orchard_instances": int(manifest.get("orchard_instances", 0)),
	}
