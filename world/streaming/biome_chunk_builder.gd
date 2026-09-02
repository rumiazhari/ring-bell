class_name BiomeChunkBuilder
extends RefCounted
## Pure biome manifest + main-thread materialization for P3.1 rural mosaic + P5.1 field parcels
## + G10-P1 forest vegetation rebuild: typed vegetation groups with distinct lit meshes,
## forest composition clustering, forest floor understory, and restrained countryside dressing.
## 9x9 samples per 64 m chunk (8 m spacing), world-space shared edges matching terrain/water,
## overlay mesh + typed MultiMeshes by vegetation class (beech/oak/birch/spruce/sapling/bush/grass/log/hedgerow etc)
## + at most one collider per chunk (ACTIVE-only) plus tilled parcels.
## Overlay lift 0.03 m above terrain; tilled lift 0.04 m (field) + forest floor 0.02.
## Budgets: 81 verts / <=128 tris overlay, <=96/64 tilled per chunk, <=56 trees + 36 understory + 16 countryside <=96 total vegetation per dense forest interior chunk.

const RESOLUTION := 9
const SPACING := 8.0
const CHUNK_M := 64.0
const ForestArt = preload("res://art/forest_art.gd")
const RuralArt = preload("res://art/rural_art.gd")

# All dressing follows WorldPlan.surface_height_at(); this builder owns no
# local urban mask or terrain transform.

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

static func _is_forest_biome(b: StringName) -> bool:
	return b == &"deciduous_forest" or b == &"mixed_upland_forest"

static func _species_for_position(p: Vector2, biome: StringName, seed_used: int) -> StringName:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("forest_species"), int(p.x*10), int(p.y*10)]) % 1000003) / 1000003.0
	if biome == &"mixed_upland_forest":
		if r < 0.35:
			return &"spruce"
		elif r < 0.60:
			return &"beech"
		elif r < 0.80:
			return &"oak"
		else:
			return &"birch"
	else: # deciduous
		if r < 0.38:
			return &"beech"
		elif r < 0.68:
			return &"oak"
		elif r < 0.88:
			return &"birch"
		else:
			return &"spruce"

static func _variant_for_pos(p: Vector2, seed_used: int, domain: String) -> int:
	return int(WorldSeed.combine([seed_used, WorldSeed.str_hash(domain), int(p.x*7), int(p.y*7)]) % 2)

static func _scale_for_pos(p: Vector2, seed_used: int) -> float:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("forest_scale"), int(p.x*13), int(p.y*13)]) % 1000003) / 1000003.0
	return lerpf(WorldConstants.TREE_SCALE_MIN, WorldConstants.TREE_SCALE_MAX, r)

static func _yaw_for_pos(p: Vector2, seed_used: int) -> float:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("forest_yaw"), int(p.x*11), int(p.y*11)]) % 1000003) / 1000003.0
	return r * TAU

static func _is_clearing(p: Vector2, seed_used: int) -> bool:
	var v: float = WorldSeed.sample_coherent(p, &"forest_clearing", 48.0, seed_used)
	return v > (1.0 - WorldConstants.FOREST_CLEARING_PROBABILITY) # 0.93

static func _distance_to_nearest(positions: Array[Vector2], p: Vector2) -> float:
	var best := INF
	for q in positions:
		var d: float = q.distance_to(p)
		if d < best:
			best = d
	return best

static func _has_near_building(world_plan: WorldPlan, p: Vector2, min_dist: float) -> bool:
	if world_plan.rural_building == null:
		return false
	var rect := Rect2(p - Vector2(min_dist, min_dist), Vector2(min_dist*2, min_dist*2))
	var blds: Array[Dictionary] = world_plan.rural_building.rural_buildings_in(rect)
	for b in blds:
		var c: Vector2 = b.get("center", Vector2.ZERO) as Vector2
		if p.distance_to(c) < min_dist:
			return true
		var aabb: Rect2 = b.get("aabb", Rect2()) as Rect2
		if aabb.has_point(p) or aabb.grow(min_dist*0.5).has_point(p):
			return true
	return false

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
	var has_industrial := false
	var is_wet_margin := false
	var wet_count := 0
	for j in RESOLUTION:
		for i in RESOLUTION:
			var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
			var idx := j * RESOLUTION + i
			var b: StringName = world_plan.biome_at(p)
			biome_ids[idx] = b
			material_ids[idx] = b
			class_ids[idx] = world_plan.surface_class_at(p)
			var col: Color = world_plan.surface_tint_at(p)
			if b == &"industrial_corridor":
				has_industrial = true
				var ind_dens: float = WorldSeed.sample_coherent(p, &"industrial_corridor_density", WorldConstants.INDUSTRIAL_CORRIDOR_DENSITY_CELL, world_plan.seed_used)
				var t_ind: float = clampf((ind_dens - 0.48) / 0.32, 0.0, 1.0)
				col = WorldConstants.COL_INDUSTRIAL_CORRIDOR.lerp(WorldConstants.COL_INDUSTRIAL_DARK, t_ind * 0.7)
				var jitter: float = (ind_dens - 0.5) * WorldConstants.INDUSTRIAL_PALETTE_VARIANT * 1.0
				col.r = clampf(col.r + jitter, 0.0, 1.0)
				col.g = clampf(col.g + jitter, 0.0, 1.0)
				col.b = clampf(col.b + jitter, 0.0, 1.0)
			elif _is_forest_biome(b):
				# Forest cells carry a darker, broken-up floor tint beneath the
				# batched leaf patches so the biome never reads as empty flat terrain.
				var floor_mix: float = WorldSeed.sample_coherent(p, &"forest_floor_tint", 14.0, world_plan.seed_used)
				var floor_micro: float = WorldSeed.sample_coherent(p, &"forest_floor_micro", 7.0, world_plan.seed_used)
				var floor_col: Color = Color("3e5b2d").lerp(Color("705334"), clampf(floor_mix, 0.0, 1.0) * 0.60)
				col = col.lerp(floor_col, 0.54)
				col = col.lightened((floor_micro - 0.5) * 0.16)
			colors[idx] = col
			heights[idx] = world_plan.surface_height_at(p) + WorldConstants.BIOME_OVERLAY_LIFT_M
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
			indices[k] = b; k += 1
			indices[k] = d; k += 1
			indices[k] = a; k += 1
			indices[k] = d; k += 1
			indices[k] = c; k += 1
	var vertex_count := RESOLUTION * RESOLUTION
	var tri_count := (RESOLUTION - 1) * (RESOLUTION - 1) * 2
	# Typed vegetation groups — genuinely distinct meshes per class, batched by type via MultiMesh
	var veg_typed: Dictionary = {}
	veg_typed[&"beech"] = []
	veg_typed[&"oak"] = []
	veg_typed[&"birch"] = []
	veg_typed[&"spruce"] = []
	veg_typed[&"sapling"] = []
	veg_typed[&"bush"] = []
	veg_typed[&"grass"] = []
	veg_typed[&"log"] = []
	veg_typed[&"leaf_litter"] = []
	veg_typed[&"stone"] = []
	veg_typed[&"dead_branch"] = []
	veg_typed[&"hedgerow"] = []
	veg_typed[&"roadside_shrub"] = []
	veg_typed[&"solitary_oak"] = []
	veg_typed[&"quarry_stone"] = []
	veg_typed[&"slag"] = []
	veg_typed[&"orchard_canopy"] = []
	# Legacy flat list for compatibility (sum of all)
	var instances: Array[Transform3D] = []
	var instance_count := 0
	var center := origin + size * 0.5
	var composition: Dictionary = world_plan.chunk_composition(coord)
	var is_urban_core: bool = bool(composition.get("city_materialized", false))
	var quarry_feature: Dictionary = world_plan.quarry_feature_at(center)
	var _placed_positions: Array[Vector2] = [] # for spacing checks (forest trees)
	var _placed_understory: Array[Vector2] = []
	if not is_urban_core:
		var forest_samples := 0
		var deciduous_samples := 0
		var mixed_samples := 0
		for j in RESOLUTION:
			for i in RESOLUTION:
				var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
				var idx := j * RESOLUTION + i
				var b: StringName = biome_ids[idx]
				if b == &"deciduous_forest" or b == &"mixed_upland_forest":
					forest_samples += 1
					if b == &"deciduous_forest":
						deciduous_samples += 1
					else:
						mixed_samples += 1
		var is_dense_interior: bool = forest_samples >= 35
		var is_forest_edge: bool = forest_samples >= 12 and forest_samples < 35
		var is_sparse: bool = forest_samples > 0 and forest_samples < 12
		var is_forest_dominant: bool = is_dense_interior # legacy alias
		# Determine target budgets per composition
		var target_trees := 0
		var target_saplings := 0
		var target_bush := 0
		var target_grass := 0
		var target_log := 0
		var target_leaf_litter := 0
		var target_stone := 0
		var target_dead_branch := 0
		var target_countryside := 0
		if is_dense_interior:
			target_trees = 40
			target_saplings = 10
			target_bush = 20
			target_grass = 12
			target_log = 2
			target_leaf_litter = 6
			target_stone = 2
			target_dead_branch = 2
		elif is_forest_edge:
			target_trees = 20
			target_saplings = 6
			target_bush = 9
			target_grass = 9
			target_log = 1
			target_leaf_litter = 5
			target_stone = 2
			target_dead_branch = 1
		elif is_sparse:
			target_trees = 8
			target_saplings = 3
			target_bush = 5
			target_grass = 5
			target_log = 0
			target_leaf_litter = 2
			target_stone = 1
			target_dead_branch = 0
		else:
			# No forest — countryside restrained vegetation
			if has_field or is_wet_margin or forest_samples == 0:
				target_countryside = 8
		# Modulate by density_avg and coherent density
		var dens_sum_forest := 0.0
		var dens_cnt_forest := 0
		for j in RESOLUTION:
			for i in RESOLUTION:
				var p := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
				if _is_forest_biome(biome_ids[j*RESOLUTION+i]):
					dens_sum_forest += world_plan.biome_density_at(p)
					dens_cnt_forest += 1
		var density_avg_forest: float = dens_sum_forest / float(maxi(1, dens_cnt_forest))
		if is_dense_interior and density_avg_forest > 0.72:
			target_trees = mini(target_trees + 4, WorldConstants.MAX_FOREST_TREES_PER_CHUNK)
			target_bush = mini(target_bush + 2, WorldConstants.MAX_FOREST_BUSH_PER_CHUNK)
		# Forest composition: generate trees via clustered Poisson with spacing and edge/clearing handling
		if forest_samples > 0:
			# Build list of candidate positions via jittered grid + noise
			# Use finer 4m effective spacing: iterate 2x per original cell with offset
			var candidates: Array[Vector2] = []
			var candidate_biomes: Array[StringName] = []
			for j in RESOLUTION:
				for i in RESOLUTION:
					var p_base := origin + Vector2(float(i) * SPACING, float(j) * SPACING)
					var b: StringName = biome_ids[j*RESOLUTION+i]
					if not _is_forest_biome(b):
						continue
					if _is_clearing(p_base, world_plan.seed_used):
						continue
					# density gate per sample
					var dens: float = world_plan.biome_density_at(p_base)
					if dens <= WorldConstants.BIOME_DENSITY_FOREST_MIN - 0.02:
						continue
					# A second, smaller coherent field creates irregular stands and
					# natural gaps instead of a uniformly filled lattice.
					var cluster_value: float = WorldSeed.sample_coherent(p_base, &"forest_cluster", 36.0, world_plan.seed_used)
					if is_dense_interior and cluster_value < 0.30:
						continue
					if is_forest_edge and cluster_value < 0.22:
						continue
					# Add jittered positions: 1 primary + up to 1 secondary offset for dense interior
					var jitter_count := 1
					if is_dense_interior and dens > 0.65:
						jitter_count = 2
					for jc in jitter_count:
						var hsh := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest"), coord.x, coord.y, i, j, jc])
						var rng := RandomNumberGenerator.new()
						rng.seed = hsh
						var jx: float = rng.randf_range(-2.2, 2.2) if jc==0 else rng.randf_range(-3.4, 3.4)
						var jz: float = rng.randf_range(-2.2, 2.2) if jc==0 else rng.randf_range(-3.4, 3.4)
						var p := p_base + Vector2(jx, jz)
						# Clamp to chunk
						if p.x < origin.x + 1.0 or p.x >= origin.x + CHUNK_M - 1.0 or p.y < origin.y + 1.0 or p.y >= origin.y + CHUNK_M - 1.0:
							continue
						# Validate gates
						if world_plan.water_body_at(p) != &"" or world_plan.hydrology.is_floodplain(p):
							continue
						if world_plan.surface_class_at(p) == &"cliff":
							continue
						if world_plan.distance_to_road(p) < 4.5:
							continue
						if world_plan.surface_slope_at(p) >= 28.0:
							continue
						if _has_near_building(world_plan, p, 5.0):
							continue
						if p.length() < WorldConstants.URBAN_INNER_M:
							continue
						# Edge falloff: if near non-forest biome, reduce probability (sparser edge)
						var is_edge_pos: bool = false
						for dj in [-1,0,1]:
							for di in [-1,0,1]:
								var ni: int = i+di
								var nj: int = j+dj
								if ni <0 or ni >= RESOLUTION or nj <0 or nj >= RESOLUTION:
									continue
								var nb: StringName = biome_ids[nj*RESOLUTION+ni]
								if not _is_forest_biome(nb):
									is_edge_pos = true
						if is_edge_pos:
							var edge_r: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_edge"), int(p.x), int(p.y)]) % 1000003)/1000003.0
							if edge_r > 0.58:
								continue
						candidates.append(p)
						candidate_biomes.append(b)
			# Sort candidates deterministically by hash for stable selection
			# Use id ordering via hash combine
			var indexed: Array[Dictionary] = []
			for idx in candidates.size():
				var p: Vector2 = candidates[idx]
				var h: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_order"), int(p.x*100), int(p.y*100)])
				var cluster_value: float = WorldSeed.sample_coherent(p, &"forest_cluster", 36.0, world_plan.seed_used)
				var cluster_priority: int = int((1.0 - cluster_value) * 1000000.0)
				indexed.append({"p": p, "b": candidate_biomes[idx], "h": h, "cluster_priority": cluster_priority})
			indexed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["cluster_priority"]) < int(b["cluster_priority"]) if int(a["cluster_priority"]) != int(b["cluster_priority"]) else int(a["h"]) < int(b["h"]))
			var tree_added := 0
			var sapling_added := 0
			for entry in indexed:
				if tree_added >= target_trees and sapling_added >= target_saplings:
					break
				var p: Vector2 = entry["p"] as Vector2
				var b: StringName = entry["b"] as StringName
				# Spacing check against placed trees
				var too_close := false
				for q in _placed_positions:
					if p.distance_squared_to(q) < WorldConstants.FOREST_TREE_MIN_SPACING * WorldConstants.FOREST_TREE_MIN_SPACING - 0.01:
						too_close = true
						break
				if too_close:
					continue
				# Determine if sapling (young near edges/openings)
				var is_edge_tree: bool = false
				var edge_dens: float = WorldSeed.sample_coherent(p, &"forest_density", 32.0, world_plan.seed_used)
				if edge_dens < 0.38:
					is_edge_tree = true
				var decide_sapling: bool = is_edge_tree and sapling_added < target_saplings and tree_added > 2
				var species: StringName = _species_for_position(p, b, world_plan.seed_used)
				var scale: float = _scale_for_pos(p, world_plan.seed_used)
				var yaw: float = _yaw_for_pos(p, world_plan.seed_used)
				# Natural vertical proportions: scale Y slightly taller for spruce/birch
				var scale_vec := Vector3(scale, scale, scale)
				if species == &"spruce":
					scale_vec = Vector3(scale*0.92, scale*1.08, scale*0.92)
				elif species == &"birch":
					scale_vec = Vector3(scale*0.88, scale*1.12, scale*0.88)
				elif species == &"oak":
					scale_vec = Vector3(scale*1.06, scale*0.96, scale*1.06)
				var y: float = world_plan.surface_height_at(p)
				var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(scale_vec), Vector3(p.x, y, p.y))
				if decide_sapling:
					# Sapling uses smaller scale 0.45-0.65 and distinct mesh
					var sap_scale: float = lerpf(0.42, 0.68, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_sapling"), int(p.x*7), int(p.y*7)]) % 1000003)/1000003.0)
					var sap_yaw: float = _yaw_for_pos(p + Vector2(7, -3), world_plan.seed_used)
					var sap_xf := Transform3D(Basis(Vector3.UP, sap_yaw).scaled(Vector3(sap_scale, sap_scale, sap_scale)), Vector3(p.x, y, p.y))
					(veg_typed[&"sapling"] as Array).append(sap_xf)
					instances.append(sap_xf)
					_placed_positions.append(p)
					sapling_added += 1
				else:
					if species == &"beech":
						(veg_typed[&"beech"] as Array).append(xf)
					elif species == &"oak":
						(veg_typed[&"oak"] as Array).append(xf)
					elif species == &"birch":
						(veg_typed[&"birch"] as Array).append(xf)
					elif species == &"spruce":
						(veg_typed[&"spruce"] as Array).append(xf)
					else:
						(veg_typed[&"beech"] as Array).append(xf)
					instances.append(xf)
					_placed_positions.append(p)
					tree_added += 1
			# Understory: bushes and grasses and logs within forest
			# Bushes: scatter around tree clusters, irregular spacing
			var bush_target := target_bush
			var grass_target := target_grass
			var log_target := target_log
			# Generate bush candidates from tree-adjacent offsets plus independent noise points
			var bush_candidates: Array[Vector2] = []
			for q in _placed_positions:
				var h1: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_bush"), int(q.x*9), int(q.y*9), 0])
				var rng_b := RandomNumberGenerator.new(); rng_b.seed = h1
				if rng_b.randf() < 0.42 and bush_candidates.size() < bush_target * 3:
					var ang: float = rng_b.randf() * TAU
					var dist: float = rng_b.randf_range(1.4, 3.2)
					var bp: Vector2 = q + Vector2(cos(ang), sin(ang)) * dist
					if bp.x < origin.x+0.8 or bp.x >= origin.x+CHUNK_M-0.8 or bp.y < origin.y+0.8 or bp.y >= origin.y+CHUNK_M-0.8:
						continue
					if world_plan.water_body_at(bp) != &"" or world_plan.hydrology.is_floodplain(bp):
						continue
					if world_plan.distance_to_road(bp) < 3.0:
						continue
					if _has_near_building(world_plan, bp, 3.5):
						continue
					var b_at: StringName = world_plan.biome_at(bp)
					if not _is_forest_biome(b_at):
						continue
					if _is_clearing(bp, world_plan.seed_used) and rng_b.randf() > 0.55:
						continue
					bush_candidates.append(bp)
			# Add independent random bush points
			var extra_bush_attempts := bush_target * 2
			for n in extra_bush_attempts:
				if bush_candidates.size() >= bush_target * 2:
					break
				var h2: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_bush"), coord.x, coord.y, n, 77])
				var rng2 := RandomNumberGenerator.new(); rng2.seed = h2
				var bx: float = origin.x + rng2.randf_range(3.0, CHUNK_M-3.0)
				var bz: float = origin.y + rng2.randf_range(3.0, CHUNK_M-3.0)
				var bp2 := Vector2(bx, bz)
				if world_plan.water_body_at(bp2) != &"" or world_plan.hydrology.is_floodplain(bp2):
					continue
				var b_at2: StringName = world_plan.biome_at(bp2)
				if not _is_forest_biome(b_at2):
					continue
				if world_plan.distance_to_road(bp2) < 3.2 or _has_near_building(world_plan, bp2, 3.5):
					continue
				if world_plan.biome_density_at(bp2) < 0.42:
					continue
				bush_candidates.append(bp2)
			# Place bushes with spacing
			var bush_placed := 0
			for bp in bush_candidates:
				if bush_placed >= bush_target:
					break
				if _distance_to_nearest(_placed_understory, bp) < WorldConstants.FOREST_UNDERSTORY_MIN_SPACING - 0.01:
					continue
				# also avoid too close to trees (<1.2 causes intersection)
				if _distance_to_nearest(_placed_positions, bp) < 1.4:
					continue
				var bs: float = lerpf(WorldConstants.BUSH_SIZE_MIN, WorldConstants.BUSH_SIZE_MAX, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_bush"), int(bp.x*11), int(bp.y*11)]) % 1000003)/1000003.0)
				var byaw: float = _yaw_for_pos(bp + Vector2(13, 7), world_plan.seed_used)
				var y: float = world_plan.surface_height_at(bp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var xf := Transform3D(Basis(Vector3.UP, byaw).scaled(Vector3(bs, bs, bs)), Vector3(bp.x, y, bp.y))
				(veg_typed[&"bush"] as Array).append(xf)
				instances.append(xf)
				_placed_understory.append(bp)
				bush_placed += 1
			# Grass clumps: similar but more numerous, smaller spacing, lower
			var grass_candidates: Array[Vector2] = []
			for q in _placed_positions:
				if grass_candidates.size() >= grass_target * 3:
					break
				var hg: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_grass"), int(q.x*13), int(q.y*13)])
				var rng_g := RandomNumberGenerator.new(); rng_g.seed = hg
				if rng_g.randf() < 0.38:
					var ang: float = rng_g.randf() * TAU
					var dist: float = rng_g.randf_range(0.9, 2.8)
					var gp: Vector2 = q + Vector2(cos(ang), sin(ang)) * dist
					if gp.x < origin.x+0.6 or gp.x >= origin.x+CHUNK_M-0.6 or gp.y < origin.y+0.6 or gp.y >= origin.y+CHUNK_M-0.6:
						continue
					if world_plan.water_body_at(gp) != &"":
						continue
					var b_at: StringName = world_plan.biome_at(gp)
					if not _is_forest_biome(b_at):
						continue
					grass_candidates.append(gp)
			for n in grass_target * 3:
				if grass_candidates.size() >= grass_target * 3:
					break
				var h3: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_grass"), coord.x, coord.y, n, 91])
				var rng3 := RandomNumberGenerator.new(); rng3.seed = h3
				var gx: float = origin.x + rng3.randf_range(2.0, CHUNK_M-2.0)
				var gz: float = origin.y + rng3.randf_range(2.0, CHUNK_M-2.0)
				var gp2 := Vector2(gx, gz)
				var b_at3: StringName = world_plan.biome_at(gp2)
				if not _is_forest_biome(b_at3):
					continue
				if world_plan.water_body_at(gp2) != &"" or world_plan.distance_to_road(gp2) < 2.8:
					continue
				grass_candidates.append(gp2)
			var grass_placed := 0
			for gp in grass_candidates:
				if grass_placed >= grass_target:
					break
				if _distance_to_nearest(_placed_understory, gp) < 1.1:
					continue
				var gscale: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_grass"), int(gp.x*17), int(gp.y*17)]) % 1000003)/1000003.0
				gscale = lerpf(0.85, 1.22, gscale)
				var gyaw: float = _yaw_for_pos(gp + Vector2(5, -11), world_plan.seed_used)
				var y: float = world_plan.surface_height_at(gp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var xf := Transform3D(Basis(Vector3.UP, gyaw).scaled(Vector3(gscale, gscale, gscale)), Vector3(gp.x, y, gp.y))
				(veg_typed[&"grass"] as Array).append(xf)
				instances.append(xf)
				_placed_understory.append(gp)
				grass_placed += 1
			# Fallen logs / deadwood inside dense forest
			var log_added := 0
			for n in log_target:
				var hl: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_log"), coord.x, coord.y, n])
				var rngl := RandomNumberGenerator.new(); rngl.seed = hl
				var lp: Vector2
				if not _placed_positions.is_empty():
					var log_anchor: Vector2 = _placed_positions[(n * 5) % _placed_positions.size()]
					lp = log_anchor + Vector2(rngl.randf_range(-3.5, 3.5), rngl.randf_range(-3.5, 3.5))
				else:
					lp = Vector2(origin.x + rngl.randf_range(4.0, CHUNK_M-4.0), origin.y + rngl.randf_range(4.0, CHUNK_M-4.0))
				lp.x = clampf(lp.x, origin.x + 2.0, origin.x + CHUNK_M - 2.0)
				lp.y = clampf(lp.y, origin.y + 2.0, origin.y + CHUNK_M - 2.0)
				var b_at: StringName = world_plan.biome_at(lp)
				if not _is_forest_biome(b_at):
					continue
				if world_plan.water_body_at(lp) != &"" or world_plan.distance_to_road(lp) < 4.0:
					continue
				if _has_near_building(world_plan, lp, 4.0):
					continue
				if _distance_to_nearest(_placed_positions, lp) < 2.0:
					continue
				var lyaw: float = rngl.randf() * TAU
				var lscale: float = rngl.randf_range(0.85, 1.15)
				var ly: float = world_plan.surface_height_at(lp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var xf := Transform3D(Basis(Vector3.UP, lyaw).scaled(Vector3(lscale, lscale, lscale)), Vector3(lp.x, ly, lp.y))
				(veg_typed[&"log"] as Array).append(xf)
				instances.append(xf)
				log_added += 1
				_placed_understory.append(lp)
			# Forest floor layer: visible leaf-litter patches, stones, and dead branches
			# are batched as typed meshes so the biome plane is never the only floor.
			var floor_positions: Array[Vector2] = []
			for n in target_leaf_litter:
				if instances.size() >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
				var hf: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_floor_litter"), coord.x, coord.y, n])
				var rngf := RandomNumberGenerator.new()
				rngf.seed = hf
				var fp: Vector2
				if not _placed_positions.is_empty():
					var tree_anchor: Vector2 = _placed_positions[(n * 3) % _placed_positions.size()]
					fp = tree_anchor + Vector2(rngf.randf_range(-2.0, 2.0), rngf.randf_range(-2.0, 2.0))
				else:
					fp = Vector2(origin.x + rngf.randf_range(3.0, CHUNK_M - 3.0), origin.y + rngf.randf_range(3.0, CHUNK_M - 3.0))
				if not _is_forest_biome(world_plan.biome_at(fp)) or world_plan.water_body_at(fp) != &"":
					continue
				if world_plan.distance_to_road(fp) < 3.2 or _has_near_building(world_plan, fp, 3.5):
					continue
				if _distance_to_nearest(floor_positions, fp) < 2.4:
					continue
				var litter_scale: float = rngf.randf_range(0.85, 1.35)
				var litter_y: float = world_plan.surface_height_at(fp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var litter_xf := Transform3D(Basis(Vector3.UP, rngf.randf_range(0.0, TAU)).scaled(Vector3(litter_scale, litter_scale, litter_scale)), Vector3(fp.x, litter_y, fp.y))
				(veg_typed[&"leaf_litter"] as Array).append(litter_xf)
				instances.append(litter_xf)
				floor_positions.append(fp)
			for n in target_stone:
				if instances.size() >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
				var hs: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_floor_stone"), coord.x, coord.y, n])
				var rngs := RandomNumberGenerator.new()
				rngs.seed = hs
				var sp := Vector2(origin.x + rngs.randf_range(3.0, CHUNK_M - 3.0), origin.y + rngs.randf_range(3.0, CHUNK_M - 3.0))
				if not _is_forest_biome(world_plan.biome_at(sp)) or world_plan.water_body_at(sp) != &"":
					continue
				if _distance_to_nearest(floor_positions, sp) < 1.4:
					continue
				var stone_y: float = world_plan.surface_height_at(sp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var stone_scale: float = rngs.randf_range(1.25, 1.80)
				var stone_xf := Transform3D(Basis(Vector3.UP, rngs.randf_range(0.0, TAU)).scaled(Vector3(stone_scale, stone_scale, stone_scale)), Vector3(sp.x, stone_y, sp.y))
				(veg_typed[&"stone"] as Array).append(stone_xf)
				instances.append(stone_xf)
				floor_positions.append(sp)
			for n in target_dead_branch:
				if instances.size() >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
				var hb: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_floor_branch"), coord.x, coord.y, n])
				var rngb := RandomNumberGenerator.new()
				rngb.seed = hb
				var bp := Vector2(origin.x + rngb.randf_range(3.0, CHUNK_M - 3.0), origin.y + rngb.randf_range(3.0, CHUNK_M - 3.0))
				if not _is_forest_biome(world_plan.biome_at(bp)) or world_plan.water_body_at(bp) != &"":
					continue
				if _distance_to_nearest(floor_positions, bp) < 1.3:
					continue
				var branch_y: float = world_plan.surface_height_at(bp) + WorldConstants.FOREST_UNDERSTORY_LIFT_M
				var branch_scale: float = rngb.randf_range(0.85, 1.20)
				var branch_xf := Transform3D(Basis(Vector3.UP, rngb.randf_range(0.0, TAU)).scaled(Vector3(branch_scale, branch_scale, branch_scale)), Vector3(bp.x, branch_y, bp.y))
				(veg_typed[&"dead_branch"] as Array).append(branch_xf)
				instances.append(branch_xf)
				floor_positions.append(bp)
		# Countryside and roadside dressing is also allowed beside a road through
		# woodland; the road exclusion gates below keep it off the travel ribbon.
		var near_road_woodland: bool = world_plan.distance_to_road(center) < 40.0
		var chunk_has_road: bool = false
		if world_plan.road_network != null:
			chunk_has_road = not world_plan.road_network.road_segments_in(Rect2(origin - Vector2.ONE * 24.0, size + Vector2.ONE * 48.0)).is_empty()
		if forest_samples == 0 or is_sparse or near_road_woodland or chunk_has_road:
			# Roadside shrubs/grass along roads
			if world_plan.road_network != null:
				var road_rect := Rect2(origin - Vector2.ONE * 24.0, size + Vector2.ONE * 48.0)
				var segs: Array[Dictionary] = world_plan.road_network.road_segments_in(road_rect)
				var road_veg_added := 0
				var road_veg_cap := mini(8, WorldConstants.MAX_COUNTRYSIDE_VEG_PER_CHUNK)
				for seg in segs:
					if road_veg_added >= road_veg_cap:
						break
					var poly: PackedVector2Array = seg.get("polyline_clipped", seg.get("polyline", PackedVector2Array())) as PackedVector2Array
					if poly.size() < 2:
						continue
					var total_len := 0.0
					for i in range(poly.size()-1):
						total_len += poly[i].distance_to(poly[i+1])
					if total_len < 6.0:
						continue
					var samples: int = int(total_len / WorldConstants.COUNTRYSIDE_ROADSIDE_INTERVAL)
					samples = clampi(samples, 1, 3)
					for si in samples:
						if road_veg_added >= road_veg_cap:
							break
						var t: float = float(si + 1) / float(samples + 1)
						# interpolate along poly
						var target_dist := t * total_len
						var acc := 0.0
						var pos: Vector2 = poly[0]
						var dir := Vector2(1,0)
						for pi in range(poly.size()-1):
							var a: Vector2 = poly[pi]
							var b: Vector2 = poly[pi+1]
							var seg_len: float = a.distance_to(b)
							if acc + seg_len >= target_dist - 0.001:
								var lt: float = (target_dist - acc) / maxf(0.001, seg_len)
								pos = a.lerp(b, lt)
								dir = (b - a).normalized()
								break
							acc += seg_len
						if not Rect2(origin, size).has_point(pos):
							# try offset point
							var perp := Vector2(-dir.y, dir.x)
							var off_pos: Vector2 = pos + perp * 4.2
							if not Rect2(origin, size).has_point(off_pos):
								off_pos = pos - perp * 4.2
								if not Rect2(origin, size).has_point(off_pos):
									continue
								pos = off_pos
							else:
								pos = off_pos
						else:
							var perp2 := Vector2(-dir.y, dir.x)
							var side: float = 1.0 if (road_veg_added % 2) == 0 else -1.0
							pos = pos + perp2 * (3.8 + float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_roadside"), int(pos.x*3), int(pos.y*3)]) % 1000)/1000.0*1.0) * side
							if not Rect2(origin, size).has_point(pos):
								continue
						if world_plan.water_body_at(pos) != &"" or world_plan.hydrology.is_floodplain(pos):
							continue
						var b_at: StringName = world_plan.biome_at(pos)
						if b_at == &"urban_basin" or b_at == &"rocky_quarry":
							continue
						if _has_near_building(world_plan, pos, 4.0):
							continue
						if world_plan.biome_at(pos) == &"arable_field" and _is_forest_biome(world_plan.biome_at(pos)):
							continue
						# place roadside shrub (bush variant)
						var rsh: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_roadside"), int(pos.x*7), int(pos.y*7)])
						var is_shrub: bool = road_veg_added == 0 or (rsh % 3) != 0
						var y: float = world_plan.surface_height_at(pos) + 0.01
						var syaw: float = float(rsh % 1000)/1000.0 * TAU
						var sscale: float = 1.12 + float(rsh % 500)/500.0*0.46
						var xf: Transform3D
						if is_shrub:
							xf = Transform3D(Basis(Vector3.UP, syaw).scaled(Vector3(sscale, sscale, sscale)), Vector3(pos.x, y+0.18, pos.y))
							(veg_typed[&"roadside_shrub"] as Array).append(xf)
						else:
							# small grass clump roadside
							xf = Transform3D(Basis(Vector3.UP, syaw).scaled(Vector3(sscale*0.9, sscale*0.9, sscale*0.9)), Vector3(pos.x, y+0.02, pos.y))
							(veg_typed[&"grass"] as Array).append(xf)
						instances.append(xf)
						road_veg_added += 1
			# Hedgerow / field-edge shrubs near field parcels (restrained)
			if has_field:
				# Field hedgerow already via parcels (2 per parcel) — add restrained field-edge solitary shrubs
				var field_rect := Rect2(origin, size)
				var parcels: Array[Dictionary] = world_plan.field_parcels_in(field_rect)
				var hedgerow_added_for_field := 0
				var field_edge_grass_added := 0
				for parc in parcels:
					if hedgerow_added_for_field >= 6:
						break
					var pc: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
					var psz: Vector2 = parc.get("size", Vector2(32,24)) as Vector2
					var pyaw: float = float(parc.get("yaw", 0.0))
					var is_long: bool = is_equal_approx(absf(pyaw), PI*0.5)
					var hx: float = psz.x*0.5 if not is_long else psz.y*0.5
					var hz: float = psz.y*0.5 if not is_long else psz.x*0.5
					var edges: Array[Vector2] = [Vector2(pc.x+hx, pc.y), Vector2(pc.x-hx, pc.y), Vector2(pc.x, pc.y+hz), Vector2(pc.x, pc.y-hz)]
					for ep in edges:
						if hedgerow_added_for_field >= 4:
							break
						if not Rect2(origin, size).has_point(ep):
							continue
						if world_plan.distance_to_road(ep) < 2.5 or _has_near_building(world_plan, ep, 4.0):
							continue
						var h: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_hedge"), int(ep.x), int(ep.y)])
						if (h % 1000) / 1000.0 > 0.70:
							continue
						var hy: float = world_plan.surface_height_at(ep) + 0.02
						var hyaw: float = pyaw + (0.0 if (h %2==0) else PI*0.5)
						var hscale: float = 0.85 + float(h % 400)/400.0*0.3
						var xf := Transform3D(Basis(Vector3.UP, hyaw).scaled(Vector3(2.40*hscale, 2.00*hscale, 0.85*hscale)), Vector3(ep.x, hy+0.22, ep.y))
						(veg_typed[&"hedgerow"] as Array).append(xf)
						instances.append(xf)
						hedgerow_added_for_field += 1
						if field_edge_grass_added < 4 and instances.size() < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
							var inward: Vector2 = (pc - ep).normalized()
							var gp: Vector2 = ep + inward * 2.2
							if Rect2(origin, size).has_point(gp) and world_plan.water_body_at(gp) == "":
								var gy: float = world_plan.surface_height_at(gp) + 0.04
								var gh: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_edge_grass"), int(gp.x), int(gp.y)])
								var gs: float = 0.92 + float(absi(gh) % 30) / 100.0
								var gxf := Transform3D(Basis(Vector3.UP, float(absi(gh / 17) % 1000) / 1000.0 * TAU).scaled(Vector3(gs, gs, gs)), Vector3(gp.x, gy, gp.y))
								(veg_typed[&"grass"] as Array).append(gxf)
								instances.append(gxf)
								field_edge_grass_added += 1
				# Fill the remaining field verge slots even when a hedge segment was
				# rejected by its deterministic visibility roll.
				for parc2 in parcels:
					if field_edge_grass_added >= 6:
						break
					var pc2: Vector2 = parc2.get("center", Vector2.ZERO) as Vector2
					var psz2: Vector2 = parc2.get("size", Vector2(32, 24)) as Vector2
					var pyaw2: float = float(parc2.get("yaw", 0.0))
					var long2: bool = is_equal_approx(absf(pyaw2), PI * 0.5)
					var hx2: float = psz2.x * 0.5 if not long2 else psz2.y * 0.5
					var hz2: float = psz2.y * 0.5 if not long2 else psz2.x * 0.5
					var edge_points2: Array[Vector2] = [Vector2(pc2.x + hx2, pc2.y), Vector2(pc2.x - hx2, pc2.y), Vector2(pc2.x, pc2.y + hz2), Vector2(pc2.x, pc2.y - hz2)]
					for ep2 in edge_points2:
						if field_edge_grass_added >= 6:
							break
						var inward2: Vector2 = (pc2 - ep2).normalized()
						var gp2: Vector2 = ep2 + inward2 * 2.2
						if not Rect2(origin, size).has_point(gp2) or world_plan.water_body_at(gp2) != &"":
							continue
						if world_plan.distance_to_road(gp2) < 2.5 or _has_near_building(world_plan, gp2, 4.0):
							continue
						var gh2: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_verge_grass"), int(gp2.x), int(gp2.y)])
						var gs2: float = 0.96 + float(absi(gh2) % 34) / 100.0
						var gxf2 := Transform3D(Basis(Vector3.UP, float(absi(gh2 / 17) % 1000) / 1000.0 * TAU).scaled(Vector3(gs2, gs2, gs2)), Vector3(gp2.x, world_plan.surface_height_at(gp2) + 0.04, gp2.y))
						(veg_typed[&"grass"] as Array).append(gxf2)
						instances.append(gxf2)
						field_edge_grass_added += 1
				# Add a small deterministic field-floor scatter pass. It is restricted to
			# open-field samples so the pasture remains open but never visually blank.
			var field_fill_added: int = 0
			var field_fill_y: float = world_plan.surface_height_at(origin + Vector2(CHUNK_M * 0.5, CHUNK_M * 0.5)) + 0.04
			for fn in 20:
				if field_fill_added >= 12 or instances.size() >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
				var fseed: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_floor_grass"), coord.x, coord.y, fn])
				var frng := RandomNumberGenerator.new()
				frng.seed = fseed
				var fp: Vector2 = Vector2(origin.x + frng.randf_range(3.5, CHUNK_M - 3.5), origin.y + frng.randf_range(3.5, CHUNK_M - 3.5))
				if _distance_to_nearest(_placed_understory, fp) < 2.4:
					continue
				var fy: float = field_fill_y
				var fscale: float = frng.randf_range(1.60, 2.20)
				var fgxf := Transform3D(Basis(Vector3.UP, frng.randf_range(0.0, TAU)).scaled(Vector3(fscale, fscale, fscale)), Vector3(fp.x, fy, fp.y))
				(veg_typed[&"grass"] as Array).append(fgxf)
				instances.append(fgxf)
				field_fill_added += 1
			# A few low field bushes break up the near pasture while keeping the
			# countryside visibly open and avoiding buildings, roads, and water.
			var field_bush_added: int = 0
			for bn in 8:
				if field_bush_added >= 4 or instances.size() >= WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
					break
				var bseed: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_floor_bush"), coord.x, coord.y, bn])
				var brng := RandomNumberGenerator.new()
				brng.seed = bseed
				var bp_field: Vector2 = Vector2(origin.x + brng.randf_range(4.0, CHUNK_M - 4.0), origin.y + brng.randf_range(4.0, CHUNK_M - 4.0))
				if _distance_to_nearest(_placed_understory, bp_field) < 2.2:
					continue
				var by_field: float = field_fill_y + WorldConstants.FOREST_UNDERSTORY_LIFT_M - 0.04
				var bs_field: float = brng.randf_range(1.80, 2.50)
				var bxf_field := Transform3D(Basis(Vector3.UP, brng.randf_range(0.0, TAU)).scaled(Vector3(bs_field, bs_field, bs_field)), Vector3(bp_field.x, by_field, bp_field.y))
				(veg_typed[&"bush"] as Array).append(bxf_field)
				instances.append(bxf_field)
				_placed_understory.append(bp_field)
				field_bush_added += 1
		# Solitary mature trees in open countryside (sparse)
			var solitary_chance: float = WorldConstants.COUNTRYSIDE_SOLITARY_CHANCE
			var solitary_hash: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_solitary"), coord.x, coord.y])
			var solitary_roll: float = float(solitary_hash % 1000003)/1000003.0
			if solitary_roll < solitary_chance and forest_samples == 0 and not has_quarry:
				var sx: float = origin.x + float((solitary_hash % 480)/480.0)*(CHUNK_M-8.0)+4.0
				var sz: float = origin.y + float(((solitary_hash/480)%480)/480.0)*(CHUNK_M-8.0)+4.0
				var sp := Vector2(sx, sz)
				if sp.length() >= WorldConstants.URBAN_INNER_M and world_plan.water_body_at(sp)==&"" and not world_plan.hydrology.is_floodplain(sp):
					var b_at: StringName = world_plan.biome_at(sp)
					if b_at == &"pasture" or b_at == &"pasture_orchard" or b_at == &"arable_field" or b_at == &"orchard":
						if world_plan.distance_to_road(sp) >= 4.0 and not _has_near_building(world_plan, sp, 7.0):
							var syaw2: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_solitary"), int(sp.x), int(sp.y), 1]) % 1000003)/1000003.0 * TAU
							var sscale2: float = lerpf(1.50, 1.82, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_solitary"), int(sp.x*2), int(sp.y*2)]) % 1000003)/1000003.0)
							var sy: float = world_plan.surface_height_at(sp)
							var xf2 := Transform3D(Basis(Vector3.UP, syaw2).scaled(Vector3(sscale2, sscale2, sscale2)), Vector3(sp.x, sy, sp.y))
							(veg_typed[&"solitary_oak"] as Array).append(xf2)
							instances.append(xf2)
			# River margin shrubs
			if is_wet_margin and wet_count > 0:
				var wet_added := 0
				for n in 4:
					if wet_added >= 3:
						break
					var hw: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("countryside_wet"), coord.x, coord.y, n])
					var wx: float = origin.x + float(hw % 640)/640.0*(CHUNK_M-6.0)+3.0
					var wz: float = origin.y + float((hw/640)%640)/640.0*(CHUNK_M-6.0)+3.0
					var wp := Vector2(wx, wz)
					if world_plan.distance_to_water(wp) > 26.0 or world_plan.distance_to_water(wp) < 4.0:
						continue
					if world_plan.water_body_at(wp) != &"":
						continue
					var b_at: StringName = world_plan.biome_at(wp)
					if b_at == &"urban_basin":
						continue
					if not Rect2(origin, size).has_point(wp):
						continue
					var wy: float = world_plan.surface_height_at(wp) + 0.02
					var wyaw: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_yaw"), int(wp.x*5), int(wp.y*5)]) % 1000003)/1000003.0*TAU
					var wscale: float = 0.72 + float(hw % 300)/300.0*0.32
					var xf := Transform3D(Basis(Vector3.UP, wyaw).scaled(Vector3(wscale, wscale, wscale)), Vector3(wp.x, wy+0.22, wp.y))
					(veg_typed[&"bush"] as Array).append(xf)
					instances.append(xf)
					wet_added += 1
		# Quarry stones and industrial slag (kept but now typed distinct from forest vegetation)
		if has_quarry and instances.size() < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var qsuit_center: float = world_plan.quarry_suitability_at(center)
			if qsuit_center > WorldConstants.QUARRY_SUITABILITY_THRESHOLD or has_quarry:
				var hq := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_quarry"), coord.x, coord.y])
				var rngq := RandomNumberGenerator.new()
				rngq.seed = hq
				var qcount: int = int(rngq.randi_range(2, 6))
				var remaining := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instances.size()
				qcount = mini(qcount, WorldConstants.BIOME_INSTANCE_CAP_QUARRY)
				qcount = mini(qcount, remaining)
				for n in qcount:
					var qh := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("biome_quarry"), coord.x, coord.y, n])
					var rngn := RandomNumberGenerator.new()
					rngn.seed = qh
					var qx: float = origin.x + rngn.randf_range(4.0, CHUNK_M - 4.0)
					var qz: float = origin.y + rngn.randf_range(4.0, CHUNK_M - 4.0)
					var qy: float = world_plan.surface_height_at(Vector2(qx, qz))
					var qs: float = rngn.randf_range(0.6, 1.0)
					var qxf := Transform3D(Basis.IDENTITY.scaled(Vector3(qs, qs * 0.7, qs)), Vector3(qx, qy + qs * 0.35, qz))
					(veg_typed[&"quarry_stone"] as Array).append(qxf)
					instances.append(qxf)
		if has_industrial and instances.size() < WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var remaining_ind := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instances.size()
			var icount: int = mini(WorldConstants.MAX_INDUSTRIAL_INSTANCES, remaining_ind)
			var ind_samples := 0
			for j in RESOLUTION:
				for i in RESOLUTION:
					if biome_ids[j * RESOLUTION + i] == &"industrial_corridor":
						ind_samples += 1
			if ind_samples >= 3:
				for n in icount:
					var ih := WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("industrial_corridor"), coord.x, coord.y, n])
					var rngi := RandomNumberGenerator.new()
					rngi.seed = ih
					var ix: float = origin.x + rngi.randf_range(4.0, CHUNK_M - 4.0)
					var iz: float = origin.y + rngi.randf_range(4.0, CHUNK_M - 4.0)
					var iy: float = world_plan.surface_height_at(Vector2(ix, iz))
					var s: float = rngi.randf_range(0.6, 1.0)
					var xf_ind := Transform3D(Basis.IDENTITY.scaled(Vector3(0.6 * s, 0.4 * s, 0.6 * s)), Vector3(ix, iy + 0.2 * s, iz))
					(veg_typed[&"slag"] as Array).append(xf_ind)
					instances.append(xf_ind)
		# Enforce global cap 96
		if instances.size() > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
			var overflow := instances.size() - WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK
			# Trim from countryside first, then understory grass
			var to_remove := overflow
			var trim_order: Array[StringName] = [&"roadside_shrub", &"grass", &"bush", &"dead_branch", &"stone", &"leaf_litter", &"hedgerow", &"solitary_oak", &"log", &"sapling", &"spruce", &"birch", &"oak", &"beech"]
			for kind in trim_order:
				if to_remove <= 0:
					break
				var arr: Array = veg_typed[kind] as Array
				if arr.is_empty():
					continue
				var remove_n: int = mini(to_remove, arr.size())
				arr.resize(arr.size() - remove_n)
				to_remove -= remove_n
			# Rebuild flat instances from typed
			instances.clear()
			for kind in veg_typed.keys():
				var arr: Array = veg_typed[kind] as Array
				instances.append_array(arr)
	if is_urban_core:
		for kind in veg_typed.keys():
			(veg_typed[kind] as Array).clear()
		instances.clear()
		has_forest = false
		has_field = false
		has_quarry = false
		has_industrial = false
	var biome_colliders := 0
	if has_forest or has_quarry:
		if instances.size() > 0 or (veg_typed[&"beech"] as Array).size() >0:
			biome_colliders = 1
		else:
			biome_colliders = 0
	else:
		biome_colliders = 0
	if has_forest == false and has_quarry == false:
		biome_colliders = 0
	if has_industrial and not has_forest and not has_quarry:
		biome_colliders = 0
	# --- Field parcel generation (P5.1) ---
	var chunk_rect := Rect2(origin, size)
	var field_parcels_raw: Array[Dictionary] = []
	if not is_urban_core:
		field_parcels_raw = world_plan.field_parcels_in(chunk_rect)
	if field_parcels_raw.size() > WorldConstants.FIELD_PARCEL_MAX_PER_CHUNK:
		field_parcels_raw.resize(WorldConstants.FIELD_PARCEL_MAX_PER_CHUNK)
	var field_parcel_manifests: Array[Dictionary] = []
	var field_vertices := 0
	var field_triangles := 0
	var field_crop_manifests: Array[Dictionary] = []
	var hedgerow_added := 0
	var remaining_instances := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instances.size()
	var hedgerow_cap := mini(WorldConstants.FIELD_HEDGEROW_MAX_PER_CHUNK, maxi(0, remaining_instances))
	# hedgerow is per parcel perimeter: generate hedgerow instances along edges (now typed as hedgerow)
	for parc in field_parcels_raw:
		var pid: String = String(parc.get("id", ""))
		var p_center: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
		var p_aabb: Rect2 = parc.get("aabb", Rect2()) as Rect2
		var p_crop: StringName = parc.get("crop_kind", &"wheat") as StringName
		var p_planted: int = int(parc.get("planted_day", 0))
		var p_yaw: float = float(parc.get("yaw", 0.0))
		var p_size: Vector2 = parc.get("size", Vector2(32,24)) as Vector2
		field_vertices += 4
		field_triangles += 2
		var contents: Dictionary = parc.get("contents", {}) as Dictionary
		if contents.is_empty():
			match p_crop:
				&"wheat":
					contents = {&"wheat_grain": 1}
				&"barley":
					contents = {&"barley_grain": 1}
				&"potato":
					contents = {&"bandage": 1}
				&"beet":
					contents = {&"antibiotics": 1}
				_:
					contents = {&"wheat_grain": 1}
		var cur_day: int = 1
		if GameClock != null:
			cur_day = GameClock.get_day()
		var is_grown: bool = cur_day >= p_planted + WorldConstants.CROP_GROW_DAYS
		var growth_stage: StringName = &"harvestable" if is_grown else (&"growing" if cur_day == p_planted + 1 else &"planted")
		var h_tilled: float = world_plan.surface_height_at(p_center) + WorldConstants.FIELD_PARCEL_LIFT_M
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
		if hedgerow_added < hedgerow_cap:
			var hedges_to_add := mini(2, hedgerow_cap - hedgerow_added)
			for hi in hedges_to_add:
				var is_long_side := hi % 2 == 0
				var hx: float
				var hz: float
				var hed_yaw: float
				if is_long_side:
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
				var hedge_y: float = world_plan.surface_height_at(Vector2(hx, hz)) + 0.0
				var hedge_h: float = lerpf(WorldConstants.HEDGEROW_TRUE_HEIGHT_MIN, WorldConstants.HEDGEROW_TRUE_HEIGHT_MAX, float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("field_parcel"), WorldSeed.combine([int(hx), int(hz)]), hi]) % 1000003) / 1000003.0)
				var scale_v := Vector3(WorldConstants.HEDGEROW_TRUE_LENGTH, hedge_h, WorldConstants.HEDGEROW_TRUE_WIDTH)
				hedge_y += hedge_h * 0.5
				var basis := Basis(Vector3.UP, hed_yaw).scaled(scale_v)
				var xf := Transform3D(basis, Vector3(hx, hedge_y, hz))
				(veg_typed[&"hedgerow"] as Array).append(xf)
				instances.append(xf)
				hedgerow_added += 1
				if hedgerow_added >= hedgerow_cap:
					break
	if field_vertices > WorldConstants.MAX_FIELD_VERTS_PER_CHUNK:
		field_vertices = WorldConstants.MAX_FIELD_VERTS_PER_CHUNK
	if field_triangles > WorldConstants.MAX_FIELD_TRIS_PER_CHUNK:
		field_triangles = WorldConstants.MAX_FIELD_TRIS_PER_CHUNK
	if instances.size() > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		var overflow := instances.size() - WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK
		if overflow > 0 and hedgerow_added > 0:
			var to_remove := mini(overflow, hedgerow_added)
			# Remove from hedgerow typed
			var arr: Array = veg_typed[&"hedgerow"] as Array
			arr.resize(maxi(0, arr.size() - to_remove))
			instances.resize(instances.size() - to_remove)
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
	var remaining_for_orchard := WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK - instances.size()
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
		var h_fruit: float = world_plan.surface_height_at(p_center_o) + WorldConstants.ORCHARD_PARCEL_LIFT_M + 0.01
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
				var hedge_y_o: float = world_plan.surface_height_at(Vector2(hx_o, hz_o)) + hedge_h_o * 0.5
				var scale_v_o := Vector3(WorldConstants.HEDGEROW_TRUE_LENGTH, hedge_h_o, WorldConstants.HEDGEROW_TRUE_WIDTH)
				var basis_o := Basis(Vector3.UP, hed_yaw_o).scaled(scale_v_o)
				var xf_o := Transform3D(basis_o, Vector3(hx_o, hedge_y_o, hz_o))
				(veg_typed[&"hedgerow"] as Array).append(xf_o)
				instances.append(xf_o)
				orchard_hedgerow_added += 1
				if orchard_hedgerow_added >= orchard_hedgerow_cap:
					break
		if orchard_instances_added < orchard_canopy_cap:
			var remaining_canopy := orchard_canopy_cap - orchard_instances_added
			var trees_to_add := mini(int(p_tree_instances.size()), remaining_canopy)
			for ti in trees_to_add:
				var tpos: Vector3 = p_tree_instances[ti] as Vector3
				var canopy_y: float = world_plan.surface_height_at(Vector2(tpos.x, tpos.z)) + WorldConstants.ORCHARD_PARCEL_LIFT_M + 1.4
				var scale_canopy := Vector3(1.4, 1.0, 1.4)
				var xf_c := Transform3D(Basis.IDENTITY.scaled(scale_canopy), Vector3(tpos.x, canopy_y, tpos.z))
				(veg_typed[&"orchard_canopy"] as Array).append(xf_c)
				instances.append(xf_c)
				orchard_instances_added += 1
				if orchard_instances_added >= orchard_canopy_cap:
					break
		if orchard_hedgerow_added >= orchard_hedgerow_cap and orchard_instances_added >= orchard_canopy_cap:
			if orchard_parcel_manifests.size() >= orchard_parcels_raw.size():
				break
	if orchard_vertices > WorldConstants.MAX_ORCHARD_VERTS_PER_CHUNK:
		orchard_vertices = WorldConstants.MAX_ORCHARD_VERTS_PER_CHUNK
	if orchard_triangles > WorldConstants.MAX_ORCHARD_TRIS_PER_CHUNK:
		orchard_triangles = WorldConstants.MAX_ORCHARD_TRIS_PER_CHUNK
	if instances.size() > WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK:
		var overflow_o := instances.size() - WorldConstants.MAX_BIOME_INSTANCES_PER_CHUNK
		if overflow_o > 0:
			var to_remove_o := mini(overflow_o, orchard_instances_added + orchard_hedgerow_added)
			if to_remove_o > 0:
				# Prefer trimming orchard hedgerow/canopy last
				var arr_h: Array = veg_typed[&"hedgerow"] as Array
				var remove_hedge := mini(to_remove_o, orchard_hedgerow_added)
				if remove_hedge > 0:
					arr_h.resize(maxi(0, arr_h.size() - remove_hedge))
					orchard_hedgerow_added -= remove_hedge
					to_remove_o -= remove_hedge
				if to_remove_o > 0:
					var arr_c: Array = veg_typed[&"orchard_canopy"] as Array
					arr_c.resize(maxi(0, arr_c.size() - to_remove_o))
					orchard_instances_added -= to_remove_o
				# Rebuild flat
				instances.clear()
				for kind in veg_typed.keys():
					instances.append_array(veg_typed[kind] as Array)
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
	# Count typed for telemetry
	var typed_counts: Dictionary = {}
	var total_typed := 0
	for kind in veg_typed.keys():
		var c: int = (veg_typed[kind] as Array).size()
		typed_counts[kind] = c
		total_typed += c
	var floor_biomes: Array = []
	for biome_value in biome_ids:
		floor_biomes.append(biome_value)
	var forest_floor_data: Dictionary = _build_forest_floor_data(world_plan, coord, origin, heights, floor_biomes)
	return {
		"coord": coord,
		"origin": origin,
		"seed_used": world_plan.seed_used,
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
		"instance_count": instances.size(),
		"instances": instances,
		"vegetation_typed": veg_typed,
		"vegetation_counts": typed_counts,
		"forest_beech": int(typed_counts.get(&"beech", 0)),
		"forest_oak": int(typed_counts.get(&"oak", 0)),
		"forest_birch": int(typed_counts.get(&"birch", 0)),
		"forest_spruce": int(typed_counts.get(&"spruce", 0)),
		"forest_sapling": int(typed_counts.get(&"sapling", 0)),
		"forest_bush": int(typed_counts.get(&"bush", 0)),
		"forest_grass": int(typed_counts.get(&"grass", 0)),
		"forest_log": int(typed_counts.get(&"log", 0)),
		"hedgerow_count": int(typed_counts.get(&"hedgerow", 0)),
		"countryside_shrub": int(typed_counts.get(&"roadside_shrub", 0)),
		"solitary_count": int(typed_counts.get(&"solitary_oak", 0)),
		"has_forest": has_forest,
		"has_field": has_field,
		"has_quarry": has_quarry,
		"has_industrial": has_industrial,
		"quarry_feature": bool(quarry_feature.get("inside", false)),
		"quarry_feature_id": quarry_feature.get("id", ""),
		"quarry_excavation_depth": float(quarry_feature.get("depth", 0.0)),
		"quarry_spoil_center": quarry_feature.get("spoil_center", Vector2.ZERO),
		"is_wet_margin": is_wet_margin,
		"biome_vertices": vertex_count,
		"biome_triangles": tri_count,
		"biome_colliders": biome_colliders,
		"biome_nodes": 0,
		"biome_instances": instances.size(),
		"forest_floor_vertices": forest_floor_data.get("vertices", PackedVector3Array()),
		"forest_floor_normals": forest_floor_data.get("normals", PackedVector3Array()),
		"forest_floor_colors": forest_floor_data.get("colors", PackedColorArray()),
		"forest_floor_indices": forest_floor_data.get("indices", PackedInt32Array()),
		"forest_floor_triangles": int(forest_floor_data.get("triangles", 0)),
		"forest_floor_cells": int(forest_floor_data.get("forest_candidates", 0)),
		"forest_floor_skipped": int(forest_floor_data.get("skipped_surface", 0)),
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

static func _build_forest_floor_data(world_plan: WorldPlan, coord: Vector2i, origin: Vector2, heights: PackedFloat32Array, biomes: Array) -> Dictionary:
	var floor_verts := PackedVector3Array()
	var floor_normals := PackedVector3Array()
	var floor_colors := PackedColorArray()
	var floor_indices := PackedInt32Array()
	var cells_checked := 0
	var forest_candidate_cells := 0
	var skipped_surface_cells := 0
	# mesh per chunk, not one node per patch, so the carpet adds floor fullness
	# without changing the vegetation instance budget.
	for j in range(RESOLUTION - 1):
		for i in range(RESOLUTION - 1):
			cells_checked += 1
			var c0: int = j * RESOLUTION + i
			var c1: int = c0 + 1
			var c2: int = c0 + RESOLUTION + 1
			var c3: int = c0 + RESOLUTION
			var forest_corners := 0
			for ci in [c0, c1, c2, c3]:
				if ci < biomes.size():
					var biome_label: String = str(biomes[ci])
					if biome_label == "deciduous_forest" or biome_label == "mixed_upland_forest":
						forest_corners += 1
			if forest_corners < 3:
				continue
			forest_candidate_cells += 1
			var center_p := origin + Vector2((float(i) + 0.5) * SPACING, (float(j) + 0.5) * SPACING)
			if world_plan.water_body_at(center_p) != &"" or world_plan.distance_to_road(center_p) < 4.0 or _has_near_building(world_plan, center_p, 4.0):
				continue
			var h0: float = heights[c0] if c0 < heights.size() else 0.0
			var h1: float = heights[c1] if c1 < heights.size() else h0
			var h2: float = heights[c2] if c2 < heights.size() else h0
			var h3: float = heights[c3] if c3 < heights.size() else h0
			var floor_lift: float = WorldConstants.FOREST_FLOOR_LIFT_M + 0.06
			var jitter_hash: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_floor_carpet"), coord.x, coord.y, i, j])
			var jx: float = float((absi(jitter_hash) % 17) - 8) * 0.08
			var jz: float = float((absi(jitter_hash / 17) % 17) - 8) * 0.08
			var center_h: float = (h0 + h1 + h2 + h3) * 0.25 + floor_lift + 0.015
			# Batched leaf/grass scatter: three broad, low irregular clusters per cell.
			for scatter_idx in 3:
				var scatter_hash: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("forest_floor_scatter"), coord.x, coord.y, i, j, scatter_idx])
				var sx: float = float((absi(scatter_hash) % 61) - 30) * 0.10
				var sz: float = float((absi(scatter_hash / 61) % 61) - 30) * 0.10
				var sr: float = 1.85 + float(absi(scatter_hash / 37) % 55) * 0.028
				var scatter_center := Vector3(center_p.x + sx, center_h + 0.14, center_p.y + sz)
				var scatter_start: int = floor_verts.size()
				floor_verts.append(scatter_center)
				for side_idx in 4:
					var scatter_angle: float = TAU * float(side_idx) / 4.0 + float(absi(scatter_hash / 19) % 100) * 0.01
					var edge_y: float = center_h + 0.025 + float(side_idx % 2) * 0.012
					floor_verts.append(Vector3(scatter_center.x + cos(scatter_angle) * sr, edge_y, scatter_center.z + sin(scatter_angle) * sr * 0.72))
				for side_idx in 5:
					floor_normals.append(Vector3.UP)
				var scatter_green := Color("4f7134")
				var scatter_brown := Color("865c36")
				var scatter_col: Color = scatter_brown if (scatter_hash + scatter_idx) % 3 == 0 else scatter_green
				floor_colors.append(scatter_col)
				for side_idx in 4:
					floor_colors.append(scatter_col if side_idx % 2 == 0 else scatter_col.lightened(0.12))
				for side_idx in 4:
					var scatter_next: int = (side_idx + 1) % 4
					floor_indices.append(scatter_start); floor_indices.append(scatter_start + 1 + side_idx); floor_indices.append(scatter_start + 1 + scatter_next)
				# A few short upright blades make the mound read as leaf/fern
				# cover instead of a painted polygon, without forming a carpet.
				for blade_idx in 3:
					var blade_hash: int = WorldSeed.combine([scatter_hash, blade_idx, 901])
					var blade_angle: float = TAU * float(blade_idx) / 3.0 + float(absi(blade_hash) % 100) * 0.01
					var blade_radius: float = 0.42 + float(absi(blade_hash / 11) % 38) * 0.018
					var blade_height: float = 0.28 + float(absi(blade_hash / 23) % 32) * 0.012
					var blade_base := scatter_center + Vector3(cos(blade_angle) * blade_radius, 0.035, sin(blade_angle) * blade_radius * 0.72)
					var blade_tip := blade_base + Vector3(cos(blade_angle) * 0.22, blade_height, sin(blade_angle) * 0.22)
					var blade_side := Vector3(-sin(blade_angle), 0.0, cos(blade_angle)) * 0.13
					var blade_start: int = floor_verts.size()
					floor_verts.append(blade_base - blade_side)
					floor_verts.append(blade_base + blade_side)
					floor_verts.append(blade_tip)
					floor_normals.append(Vector3.UP); floor_normals.append(Vector3.UP); floor_normals.append(Vector3.UP)
					var blade_col := Color("719142") if blade_idx % 2 == 0 else Color("8d7544")
					floor_colors.append(blade_col); floor_colors.append(blade_col.lightened(0.08)); floor_colors.append(blade_col)
					floor_indices.append(blade_start); floor_indices.append(blade_start + 1); floor_indices.append(blade_start + 2)
	if floor_verts.is_empty():
		# Defensive fallback for a forest manifest whose StringName values came
		# through a typed-array boundary differently. It still uses the real
		# terrain heights and only activates when a forest label is present.
		var forest_seen := false
		for biome_value in biomes:
			if str(biome_value).find("forest") >= 0:
				forest_seen = true
				break
		if forest_seen:
			var h0: float = heights[0] if heights.size() > 0 else 0.0
			var h1: float = heights[RESOLUTION - 1] if heights.size() > RESOLUTION - 1 else h0
			var h2: float = heights[(RESOLUTION - 1) * RESOLUTION + RESOLUTION - 1] if heights.size() > (RESOLUTION - 1) * RESOLUTION + RESOLUTION - 1 else h0
			var h3: float = heights[(RESOLUTION - 1) * RESOLUTION] if heights.size() > (RESOLUTION - 1) * RESOLUTION else h0
			var lift: float = WorldConstants.FOREST_FLOOR_LIFT_M + 0.06
			var start: int = floor_verts.size()
			floor_verts.append(Vector3(origin.x, h0 + lift, origin.y))
			floor_verts.append(Vector3(origin.x + CHUNK_M, h1 + lift, origin.y))
			floor_verts.append(Vector3(origin.x + CHUNK_M, h2 + lift, origin.y + CHUNK_M))
			floor_verts.append(Vector3(origin.x, h3 + lift, origin.y + CHUNK_M))
			var center_h: float = (h0 + h1 + h2 + h3) * 0.25 + lift + 0.015
			floor_verts.append(Vector3(origin.x + CHUNK_M * 0.5, center_h, origin.y + CHUNK_M * 0.5))
			for k in 5:
				floor_normals.append(Vector3.UP)
			var base_col := Color("315426").lerp(Color("6f5630"), 0.30)
			floor_colors.append(base_col); floor_colors.append(base_col.lightened(0.12)); floor_colors.append(base_col); floor_colors.append(base_col.lightened(0.12)); floor_colors.append(base_col)
			floor_indices.append(start); floor_indices.append(start + 1); floor_indices.append(start + 4)
			floor_indices.append(start + 1); floor_indices.append(start + 2); floor_indices.append(start + 4)
			floor_indices.append(start + 2); floor_indices.append(start + 3); floor_indices.append(start + 4)
			floor_indices.append(start + 3); floor_indices.append(start); floor_indices.append(start + 4)
			forest_candidate_cells = 1
	return {"vertices": floor_verts, "normals": floor_normals, "colors": floor_colors, "indices": floor_indices, "triangles": floor_indices.size() / 3, "cells_checked": cells_checked, "forest_candidates": forest_candidate_cells, "skipped_surface": skipped_surface_cells}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO)
	var origin: Vector2 = manifest.get("origin", Vector2.ZERO)
	var heights: PackedFloat32Array = manifest.get("heights", PackedFloat32Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray())
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array())
	var forest_floor_verts: PackedVector3Array = manifest.get("forest_floor_vertices", PackedVector3Array())
	var forest_floor_normals: PackedVector3Array = manifest.get("forest_floor_normals", PackedVector3Array())
	var forest_floor_colors: PackedColorArray = manifest.get("forest_floor_colors", PackedColorArray())
	var forest_floor_indices: PackedInt32Array = manifest.get("forest_floor_indices", PackedInt32Array())
	var biome_colliders: int = int(manifest.get("biome_colliders", 0))
	var instance_count: int = int(manifest.get("instance_count", 0))
	var instances: Array = manifest.get("instances", [])
	var veg_typed: Dictionary = manifest.get("vegetation_typed", {})
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
	var all_verts := PackedVector3Array()
	var all_colors := PackedColorArray()
	var all_indices := PackedInt32Array()
	all_verts = overlay_verts.duplicate()
	all_colors = colors.duplicate()
	all_indices = indices.duplicate()
	var base_idx := overlay_verts.size()
	for parc in field_parcel_manifests:
		var pd: Dictionary = parc as Dictionary
		var p_center: Vector2 = pd.get("center", Vector2.ZERO) as Vector2
		var p_size: Vector2 = pd.get("size", Vector2(32,24)) as Vector2
		var p_crop: StringName = pd.get("crop_kind", &"wheat") as StringName
		var p_yaw: float = float(pd.get("yaw", 0.0))
		var col: Color = _tilled_color(p_crop)
		var h: float = 0.0
		if heights.size() > 0:
			var ix := clampi(int(round((p_center.x - origin.x) / SPACING)), 0, RESOLUTION-1)
			var jz := clampi(int(round((p_center.y - origin.y) / SPACING)), 0, RESOLUTION-1)
			var idx_c := jz * RESOLUTION + ix
			if idx_c < heights.size():
				h = heights[idx_c] - WorldConstants.BIOME_OVERLAY_LIFT_M + WorldConstants.FIELD_PARCEL_LIFT_M
			else:
				h = 0.0 + WorldConstants.FIELD_PARCEL_LIFT_M
		else:
			h = WorldConstants.FIELD_PARCEL_LIFT_M
		var hx := p_size.x * 0.5
		var hz := p_size.y * 0.5
		var corners: Array[Vector3] = []
		if is_equal_approx(absf(p_yaw), PI*0.5):
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
		all_indices.append(start)
		all_indices.append(start + 1)
		all_indices.append(start + 2)
		all_indices.append(start)
		all_indices.append(start + 2)
		all_indices.append(start + 3)
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
	mat.metallic = 0.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "BiomeMesh"
	mi.mesh = mesh
	biome_node.add_child(mi)
	# A single chunk-level forest-floor scatter mesh supplies raised mottled cover
	# underneath the typed plants without creating per-patch scene nodes.
	if not forest_floor_verts.is_empty() and not forest_floor_indices.is_empty():
		var floor_arrays := []
		floor_arrays.resize(Mesh.ARRAY_MAX)
		floor_arrays[Mesh.ARRAY_VERTEX] = forest_floor_verts
		floor_arrays[Mesh.ARRAY_NORMAL] = forest_floor_normals
		floor_arrays[Mesh.ARRAY_COLOR] = forest_floor_colors
		floor_arrays[Mesh.ARRAY_INDEX] = forest_floor_indices
		var floor_mesh := ArrayMesh.new()
		floor_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, floor_arrays)
		var floor_mat := StandardMaterial3D.new()
		floor_mat.vertex_color_use_as_albedo = true
		floor_mat.roughness = 1.0
		floor_mat.metallic = 0.0
		floor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		floor_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		floor_mesh.surface_set_material(0, floor_mat)
		var floor_instance := MeshInstance3D.new()
		floor_instance.name = "ForestFloorScatter"
		floor_instance.mesh = floor_mesh
		floor_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		biome_node.add_child(floor_instance)
	# Typed MultiMeshes for vegetation — each type has genuinely distinct mesh/silhouette via ForestArt
	var multimesh_created := 0
	var typed_kinds: Array[StringName] = [&"beech", &"oak", &"birch", &"spruce", &"sapling", &"bush", &"grass", &"log", &"leaf_litter", &"stone", &"dead_branch", &"hedgerow", &"roadside_shrub", &"solitary_oak", &"quarry_stone", &"slag", &"orchard_canopy"]
	var kind_mesh_map: Dictionary = {
		&"beech": ForestArt.get_mesh(&"beech", 0),
		&"oak": ForestArt.get_mesh(&"oak", 0),
		&"birch": ForestArt.get_mesh(&"birch", 0),
		&"spruce": ForestArt.get_mesh(&"spruce", 0),
		&"sapling": ForestArt.get_mesh(&"sapling", 0),
		&"bush": ForestArt.get_mesh(&"bush", 0),
		&"grass": ForestArt.get_mesh(&"grass", 0),
		&"log": ForestArt.get_mesh(&"log", 0),
		&"leaf_litter": ForestArt.get_mesh(&"leaf_litter", 0),
		&"stone": ForestArt.get_mesh(&"stone", 0),
		&"dead_branch": ForestArt.get_mesh(&"dead_branch", 0),
	}
	# Hedgerow uses its own elongated, multi-lobe mesh so field edges read as
	# a horizontal leafy boundary rather than a stretched round bush.
	var hedge_mesh := ForestArt.get_mesh(&"hedgerow", 0)
	# Quarry stone and slag use simple BoxMesh with distinct colors but lit (not considered placeholder forest)
	var quarry_box := BoxMesh.new()
	quarry_box.size = Vector3(1,1,1)
	var quarry_mat := StandardMaterial3D.new()
	quarry_mat.vertex_color_use_as_albedo = true
	quarry_mat.albedo_color = Color("6e6e6e")
	quarry_mat.roughness = 0.95
	quarry_box.material = quarry_mat
	var slag_box := BoxMesh.new()
	slag_box.size = Vector3(1,1,1)
	var slag_mat := StandardMaterial3D.new()
	slag_mat.vertex_color_use_as_albedo = true
	slag_mat.albedo_color = Color("5a7a3a")
	slag_mat.roughness = 0.9
	slag_box.material = slag_mat
	# Split each typed group into deterministic variant MultiMeshes. This keeps
	# silhouettes genuinely different while retaining one shared mesh per variant.
	var manifest_seed: int = int(manifest.get("seed_used", 0))
	for kind in typed_kinds:
		var arr: Array = []
		if veg_typed.has(kind):
			arr = veg_typed[kind] as Array
		if arr.is_empty():
			continue
		for variant in 2:
			var variant_arr: Array = []
			for n in arr.size():
				var candidate: Transform3D = arr[n] as Transform3D
				var variant_hash: int = WorldSeed.combine([manifest_seed, WorldSeed.str_hash("vegetation_variant"), int(candidate.origin.x * 10.0), int(candidate.origin.z * 10.0), n])
				if absi(variant_hash) % 2 == variant:
					variant_arr.append(candidate)
			if variant_arr.is_empty():
				continue
			var mm_instance := MultiMeshInstance3D.new()
			mm_instance.name = "BiomeMM_%s_%d" % [String(kind), variant]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.instance_count = variant_arr.size()
			var mesh_to_use: Mesh
			if kind_mesh_map.has(kind):
				mesh_to_use = ForestArt.get_mesh(kind, variant)
			elif kind == &"hedgerow":
				mesh_to_use = ForestArt.get_mesh(&"hedgerow", variant)
			elif kind == &"roadside_shrub":
				mesh_to_use = ForestArt.get_mesh(&"bush", variant)
			elif kind == &"solitary_oak":
				mesh_to_use = ForestArt.get_mesh(&"oak", variant)
			elif kind == &"quarry_stone":
				mesh_to_use = quarry_box
			elif kind == &"slag":
				mesh_to_use = slag_box
			elif kind == &"orchard_canopy":
				mesh_to_use = ForestArt.get_mesh(&"bush", variant)
			else:
				mesh_to_use = ForestArt.get_mesh(&"beech", variant)
			multimesh.mesh = mesh_to_use
			for n in variant_arr.size():
				multimesh.set_instance_transform(n, variant_arr[n] as Transform3D)
			mm_instance.multimesh = multimesh
			if kind == &"grass" or kind == &"bush" or kind == &"hedgerow" or kind == &"leaf_litter":
				mm_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			else:
				mm_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			biome_node.add_child(mm_instance)
			multimesh_created += 1
	# Fallback: if veg_typed empty but legacy instances exist (e.g., from old save), create one generic fallback (never visible normally)
	if multimesh_created == 0 and instance_count > 0 and not instances.is_empty() and veg_typed.is_empty():
		var mm_instance2 := MultiMeshInstance3D.new()
		mm_instance2.name = "BiomeMultimesh"
		var multimesh2 := MultiMesh.new()
		multimesh2.transform_format = MultiMesh.TRANSFORM_3D
		multimesh2.instance_count = instance_count
		var box := BoxMesh.new()
		box.size = Vector3(1, 1, 1)
		var box_mat2 := StandardMaterial3D.new()
		box_mat2.vertex_color_use_as_albedo = true
		box_mat2.albedo_color = Color("5a7a3a")
		box_mat2.roughness = 0.9
		box.material = box_mat2
		multimesh2.mesh = box
		for n in instance_count:
			var xf: Transform3D = instances[n] as Transform3D
			multimesh2.set_instance_transform(n, xf)
		mm_instance2.multimesh = multimesh2
		biome_node.add_child(mm_instance2)
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
			# Find first typed instance
			for kind in veg_typed.keys():
				var arr: Array = veg_typed[kind] as Array
				if not arr.is_empty():
					base_pos = (arr[0] as Transform3D).origin
					break
			if base_pos == Vector3.ZERO:
				base_pos = Vector3(origin.x + CHUNK_M * 0.5, 0.0, origin.y + CHUNK_M * 0.5)
		if base_pos.y == 0.0:
			base_pos.y = 0.6
		box_shape.size = Vector3(0.6, 1.2, 0.6)
		var coll := CollisionShape3D.new()
		coll.shape = box_shape
		coll.position = base_pos
		body.add_child(coll)
		collider_created = 1
	var crops_created := 0
	for cdata in field_crop_manifests:
		var cd: Dictionary = cdata as Dictionary
		var patch := CropPatch.new()
		patch.name = String(cd.get("id", "crop_unknown"))
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
		biome_node.add_child(patch)
		patch.position = pos3
		if cd.has("yaw"):
			patch.rotation.y = float(cd["yaw"])
		crops_created += 1
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
		"forest_floor_vertices": forest_floor_verts.size(),
		"forest_floor_triangles": int(forest_floor_indices.size() / 3),
		"forest_floor_cells": int(manifest.get("forest_floor_cells", 0)),
		"forest_floor_skipped": int(manifest.get("forest_floor_skipped", 0)),
		"vegetation_counts": manifest.get("vegetation_counts", {}),
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
