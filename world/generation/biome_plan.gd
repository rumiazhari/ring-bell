class_name BiomePlan
extends RefCounted
## Pure Czech rural mosaic biome classification.
## Reads TerrainPlan height/slope/class + HydrologyPlan distance/floodplain + GeologyPlan strata/suitability
## plus deterministic moisture/temperature fields via WorldSeed.sample_coherent.
## No Node access, no unseeded randomness, no chunk-local state.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)

func moisture_at(p: Vector2) -> float:
	var v := WorldSeed.sample_coherent_signed(Vector2(p.x * 0.6, p.y * 0.6), &"biome_moisture", WorldConstants.BIOME_MOISTURE_CELL, seed_used)
	return clampf((v + 1.0) * 0.5, 0.0, 1.0)

func temperature_at(p: Vector2) -> float:
	# spec: temperature = sample_coherent(Vector2(p.x*0.45, p.y*0.45), "biome_temp", 520) 0..1
	return clampf(WorldSeed.sample_coherent(Vector2(p.x * 0.45, p.y * 0.45), &"biome_temp", WorldConstants.BIOME_TEMP_CELL, seed_used), 0.0, 1.0)

func biome_density_at(p: Vector2) -> float:
	return clampf(WorldSeed.sample_coherent(p, &"biome_density", WorldConstants.BIOME_DENSITY_CELL, seed_used), 0.0, 1.0)

func surface_tint_at(p: Vector2) -> Color:
	var b := biome_at(p)
	match b:
		&"urban_basin":
			return Color(0.58, 0.58, 0.56)
		&"river_floodplain":
			return Color(0.70, 0.68, 0.55)
		&"wet_meadow":
			return Color(0.45, 0.60, 0.38)
		&"arable_field":
			return Color(0.62, 0.55, 0.32)
		&"pasture":
			return Color(0.52, 0.68, 0.42)
		&"orchard":
			return Color(0.55, 0.62, 0.35)
		&"pasture_orchard":
			return Color(0.54, 0.65, 0.38)
		&"deciduous_forest":
			return Color(0.28, 0.38, 0.22)
		&"mixed_upland_forest":
			return Color(0.22, 0.30, 0.18)
		&"rocky_quarry":
			return Color(0.56, 0.56, 0.55)
		_:
			return Color(0.52, 0.62, 0.40)

func biome_id_at(p: Vector2) -> String:
	var b := biome_at(p)
	var cx := floori(p.x / WorldConstants.LANDSCAPE_CELL_M)
	var cy := floori(p.y / WorldConstants.LANDSCAPE_CELL_M)
	return "biome_%d_%d_%s" % [cx, cy, String(b)]

func is_forest(p: Vector2) -> bool:
	var b := biome_at(p)
	return b == &"deciduous_forest" or b == &"mixed_upland_forest"

func is_field(p: Vector2) -> bool:
	var b := biome_at(p)
	return b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard" or b == &"orchard"

func is_floodplain(p: Vector2) -> bool:
	var b := biome_at(p)
	return b == &"river_floodplain" or b == &"wet_meadow"

func is_quarry(p: Vector2) -> bool:
	return biome_at(p) == &"rocky_quarry"

func biome_at(p: Vector2) -> StringName:
	# Micro rules override macro noise where geography forces identity
	# Hydrology water check first (world-space shared edge)
	var water_body: StringName = hydrology.water_body_at(p)
	if water_body != &"":
		# water-covered samples are floodplain tint, not forest/field
		return &"river_floodplain"
	# Floodplain and bank
	var is_fp: bool = hydrology.is_floodplain(p)
	var half: float = hydrology.river_half_width_at(p.y)
	var dist_to_center: float = absf(p.x - hydrology.river_center_x_at(p.y))
	# Also consider tributary distance? is_floodplain already handles tribs
	# Bank band
	if dist_to_center <= half + WorldConstants.BANK_W:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			return &"river_floodplain"
	if is_fp:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			return &"river_floodplain"
	# Wet meadow 0-16 outside floodplain where moisture >0.62 and slope < BUILDABLE_MAX and not cliff
	var outer_flood := half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W
	# For tributaries, outer_flood not accurate; but is_floodplain already handles trib floodplain.
	# Wet meadow band outside floodplain: use distance_to_water for trib-aware check
	var d_water: float = hydrology.distance_to_water(p)
	# d_water is signed distance to nearest water edge (negative inside, 0 at bank edge)
	# Floodplain is d in (BANK_W, BANK+FLOOD] -> for wet meadow we want BANK+FLOOD < d <= BANK+FLOOD+16
	if d_water > WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W and d_water <= WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W + 16.0:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			if moisture_at(p) > WorldConstants.BIOME_MOISTURE_WET_MEADOW_THRESHOLD:
				return &"wet_meadow"
	# Urban basin
	if p.length() < WorldConstants.URBAN_INNER_M:
		return &"urban_basin"
	# Quarry sparse deterministic patches
	var qsuit: float = geology.quarry_suitability_at(p)
	var slope_deg: float = terrain.slope_at(p)
	var tclass: StringName = terrain.terrain_class_at(p)
	var h: float = terrain.height_at(p)
	var strata: StringName = geology.strata_at(p)
	if qsuit > WorldConstants.QUARRY_SUITABILITY_THRESHOLD and (slope_deg >= WorldConstants.QUARRY_SLOPE_MIN_DEG or tclass == &"cliff" or (strata == &"limestone" and h >= 15.0)):
		if water_body == &"" and not hydrology.is_floodplain(p):
			return &"rocky_quarry"
	# Macro Czech mosaic: deterministic moisture/temperature + geology fertility + elevation/slope gate
	var moist := moisture_at(p)
	var temp := temperature_at(p) # currently not directly gating but available for future
	var fertility := geology.fertility_at(p)
	var forest_field: float = WorldSeed.sample_coherent(p, &"biome_forest_field", WorldConstants.BIOME_FOREST_FIELD_CELL, seed_used)
	var landscape: float = WorldSeed.sample_coherent(p, &"biome", WorldConstants.LANDSCAPE_CELL_M, seed_used)
	var blended_forest := forest_field * 0.7 + landscape * 0.3
	var is_upland: bool = h >= WorldConstants.TERRAIN_UPLAND_HEIGHT_M or tclass == &"upland"
	var is_suitable_for_forest: bool = slope_deg < WorldConstants.CLIFF_SLOPE_DEG
	# Also forest not inside floodplain/water already handled
	if blended_forest > WorldConstants.BIOME_FOREST_FIELD_THRESHOLD and is_suitable_for_forest:
		# Outside floodplain check already passed (no early return for floodplain means not floodplain)
		if is_upland:
			return &"mixed_upland_forest"
		else:
			return &"deciduous_forest"
	# Gentle slope arable/pasture
	var would_be_forest: bool = blended_forest > WorldConstants.BIOME_FOREST_FIELD_THRESHOLD and is_suitable_for_forest
	if slope_deg < WorldConstants.ARABLE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_ARABLE_MIN:
		if water_body == &"" and not hydrology.is_floodplain(p) and not would_be_forest:
			return &"arable_field"
	if slope_deg < WorldConstants.PASTURE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_PASTURE_MIN:
		if tclass == &"rolling_hill" or tclass == &"basin" or tclass == &"upland":
			if water_body == &"" and not hydrology.is_floodplain(p) and not would_be_forest:
				var orchard_n: float = WorldSeed.sample_coherent(p, &"biome_orchard", WorldConstants.BIOME_ORCHARD_CELL, seed_used)
				if orchard_n > WorldConstants.BIOME_ORCHARD_THRESHOLD:
					return &"orchard"
				elif orchard_n > 0.45:
					return &"pasture_orchard"
				else:
					return &"pasture"
	# Fallback: ensure contiguous parcels >= landscape cell where rural
	# Use blended_forest to decide forest vs field fallback but respecting slope and fertility gates
	if blended_forest > 0.45 and is_suitable_for_forest:
		if is_upland:
			return &"mixed_upland_forest"
		else:
			return &"deciduous_forest"
	else:
		# field fallback only if fertility sufficient
		if slope_deg < WorldConstants.ARABLE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_ARABLE_MIN and not would_be_forest:
			return &"arable_field"
		if slope_deg < WorldConstants.PASTURE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_PASTURE_MIN and not would_be_forest:
			var orchard_n2: float = WorldSeed.sample_coherent(p, &"biome_orchard", WorldConstants.BIOME_ORCHARD_CELL, seed_used)
			if orchard_n2 > 0.5:
				return &"pasture"
			else:
				return &"arable_field"
		# low fertility gentle slope -> forest is safer than field (field requires fertility)
		if is_suitable_for_forest:
			if is_upland:
				return &"mixed_upland_forest"
			else:
				return &"deciduous_forest"
		# steep not suitable for forest? fallback to field only if moderate fertility allowed, otherwise forest even on steep? but steep forest already excluded via is_suitable_for_forest (slope <35). If not suitable, check quarry already handled, so remaining cliff case -> quarry fallback (but quarry already) -> return pasture as last resort but ensure fertility check? For cliff we should have returned quarry earlier, so this is rare. Return forest as safe default.
		return &"deciduous_forest"
