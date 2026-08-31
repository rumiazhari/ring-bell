class_name BiomePlan
extends RefCounted
## Pure Czech rural mosaic biome classification.
## Reads TerrainPlan height/slope/class + HydrologyPlan distance/floodplain + GeologyPlan strata/suitability
## plus deterministic moisture/temperature fields via WorldSeed.sample_coherent.
## No Node access, no unseeded randomness, no chunk-local state.
## Extended P5.1: deterministic field-parcel cultivation per 256 m landscape cell.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var settlement_ref: SettlementPlan
var road_network_ref: RoadNetworkPlan
var rural_building_ref: RuralBuildingPlan
var _road_proximity_cache: Dictionary = {}
var _cell_road_cache: Dictionary = {}

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)

func set_world_refs(settlement: SettlementPlan, road_network: RoadNetworkPlan, rural_building: RuralBuildingPlan) -> void:
	settlement_ref = settlement
	road_network_ref = road_network
	rural_building_ref = rural_building

func moisture_at(p: Vector2) -> float:
	var v := WorldSeed.sample_coherent_signed(Vector2(p.x * 0.6, p.y * 0.6), &"biome_moisture", WorldConstants.BIOME_MOISTURE_CELL, seed_used)
	return clampf((v + 1.0) * 0.5, 0.0, 1.0)

func temperature_at(p: Vector2) -> float:
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
		&"industrial_corridor":
			# contaminated ground palette 7a6a6a with slag dark 5e5850 via jitter handled in builder; base here is mid
			var dens := WorldSeed.sample_coherent(p, &"industrial_corridor_density", WorldConstants.INDUSTRIAL_CORRIDOR_DENSITY_CELL, seed_used)
			var t := clampf((dens - 0.48) / 0.32, 0.0, 1.0)
			return WorldConstants.COL_INDUSTRIAL_CORRIDOR.lerp(WorldConstants.COL_INDUSTRIAL_DARK, t * 0.5)
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

func is_industrial(p: Vector2) -> bool:
	return biome_at(p) == &"industrial_corridor"

func biome_at(p: Vector2) -> StringName:
	var water_body: StringName = hydrology.water_body_at(p)
	if water_body != &"":
		return &"river_floodplain"
	var is_fp: bool = hydrology.is_floodplain(p)
	var half: float = hydrology.river_half_width_at(p.y)
	var dist_to_center: float = absf(p.x - hydrology.river_center_x_at(p.y))
	if dist_to_center <= half + WorldConstants.BANK_W:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			return &"river_floodplain"
	if is_fp:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			return &"river_floodplain"
	var outer_flood := half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W
	var d_water: float = hydrology.distance_to_water(p)
	if d_water > WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W and d_water <= WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W + 16.0:
		if terrain.slope_at(p) < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and terrain.terrain_class_at(p) != &"cliff":
			if moisture_at(p) > WorldConstants.BIOME_MOISTURE_WET_MEADOW_THRESHOLD:
				return &"wet_meadow"
	if p.length() < WorldConstants.URBAN_INNER_M:
		return &"urban_basin"
	var qsuit: float = geology.quarry_suitability_at(p)
	var slope_deg: float = terrain.slope_at(p)
	var tclass: StringName = terrain.terrain_class_at(p)
	var h: float = terrain.height_at(p)
	var strata: StringName = geology.strata_at(p)
	if qsuit > WorldConstants.QUARRY_SUITABILITY_THRESHOLD and (slope_deg >= WorldConstants.QUARRY_SLOPE_MIN_DEG or tclass == &"cliff" or (strata == &"limestone" and h >= 15.0)):
		if water_body == &"" and not hydrology.is_floodplain(p):
			return &"rocky_quarry"
	# Industrial corridor: gentle road-adjacent quarry geology, contaminated ground palette
	if road_network_ref != null and p.length() >= WorldConstants.URBAN_INNER_M:
		var _ind_strata_ok: bool = strata == &"limestone" or strata == &"sandstone" or strata == &"granite_like"
		if _ind_strata_ok and qsuit > WorldConstants.INDUSTRIAL_QUARRY_SUITABILITY_MIN:
			if tclass != &"cliff" and slope_deg < WorldConstants.INDUSTRIAL_SLOPE_MAX_DEG:
				if water_body == &"" and not hydrology.is_floodplain(p) and d_water > WorldConstants.BANK_W + 2.0:
					var _ind_dens: float = WorldSeed.sample_coherent(p, &"industrial_corridor_density", WorldConstants.INDUSTRIAL_CORRIDOR_DENSITY_CELL, seed_used)
					if _ind_dens > WorldConstants.INDUSTRIAL_CORRIDOR_DENSITY_THRESHOLD:
						# Fast cell-level road presence gate to avoid per-sample distance scan where no road within 80 expanded
						var _cell_coord := Vector2i(floori(p.x / WorldConstants.LANDSCAPE_CELL_M), floori(p.y / WorldConstants.LANDSCAPE_CELL_M))
						var _cell_has_road: bool
						if _cell_road_cache.has(_cell_coord):
							_cell_has_road = bool(_cell_road_cache[_cell_coord])
						else:
							var _cell_origin := Vector2(_cell_coord) * WorldConstants.LANDSCAPE_CELL_M
							var _cell_rect := Rect2(_cell_origin, Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M))
							var _expanded := _cell_rect.grow(WorldConstants.INDUSTRIAL_ROAD_DISTANCE_MAX)
							_cell_has_road = not road_network_ref.road_segments_in(_expanded).is_empty()
							_cell_road_cache[_cell_coord] = _cell_has_road
						if _cell_has_road:
							if road_network_ref.distance_to_road(p) < WorldConstants.INDUSTRIAL_ROAD_DISTANCE_MAX - 0.001:
								return &"industrial_corridor"
	var moist := moisture_at(p)
	var temp := temperature_at(p)
	var fertility := geology.fertility_at(p)
	var forest_field: float = WorldSeed.sample_coherent(p, &"biome_forest_field", WorldConstants.BIOME_FOREST_FIELD_CELL, seed_used)
	var landscape: float = WorldSeed.sample_coherent(p, &"biome", WorldConstants.LANDSCAPE_CELL_M, seed_used)
	var blended_forest := forest_field * 0.7 + landscape * 0.3
	var is_upland: bool = h >= WorldConstants.TERRAIN_UPLAND_HEIGHT_M or tclass == &"upland"
	var is_suitable_for_forest: bool = slope_deg < WorldConstants.CLIFF_SLOPE_DEG
	if blended_forest > WorldConstants.BIOME_FOREST_FIELD_THRESHOLD and is_suitable_for_forest:
		if is_upland:
			return &"mixed_upland_forest"
		else:
			return &"deciduous_forest"
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
	if blended_forest > 0.45 and is_suitable_for_forest:
		if is_upland:
			return &"mixed_upland_forest"
		else:
			return &"deciduous_forest"
	else:
		if slope_deg < WorldConstants.ARABLE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_ARABLE_MIN and not would_be_forest:
			return &"arable_field"
		if slope_deg < WorldConstants.PASTURE_MAX_SLOPE_DEG and fertility > WorldConstants.BIOME_FERTILITY_PASTURE_MIN and not would_be_forest:
			var orchard_n2: float = WorldSeed.sample_coherent(p, &"biome_orchard", WorldConstants.BIOME_ORCHARD_CELL, seed_used)
			if orchard_n2 > 0.5:
				return &"pasture"
			else:
				return &"arable_field"
		if is_suitable_for_forest:
			if is_upland:
				return &"mixed_upland_forest"
			else:
				return &"deciduous_forest"
		return &"deciduous_forest"

# --- Field Parcel Cultivation P5.1 ---

func _hash_cell(cx: int, cy: int) -> int:
	return WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), cx, cy])

func _is_arable_family(b: StringName) -> bool:
	return b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard" or b == &"orchard"

func _max_slope_for_biome(b: StringName) -> float:
	if b == &"arable_field":
		return WorldConstants.ARABLE_MAX_SLOPE_DEG
	return WorldConstants.PASTURE_MAX_SLOPE_DEG

func _is_village_adjacent(cell_center: Vector2) -> bool:
	if settlement_ref == null:
		return false
	var anchors: Array[Dictionary] = settlement_ref.settlement_anchors()
	for a in anchors:
		if StringName(str(a.get("kind", ""))) != &"village":
			continue
		var c: Vector2 = a.get("center", Vector2.ZERO) as Vector2
		var r: float = float(a.get("radius", 48.0))
		var dist := cell_center.distance_to(c)
		if dist <= r * 1.4:
			return true
	return false

func _aabb_gap(a: Rect2, b: Rect2) -> float:
	var dx: float = maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy: float = maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	if dx == 0.0 and dy == 0.0:
		var overlap_x: float = minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
		var overlap_y: float = minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
		if overlap_x > 0 and overlap_y > 0:
			return -minf(overlap_x, overlap_y)
		return 0.0
	if dx > 0.0 and dy > 0.0:
		return sqrt(dx*dx + dy*dy)
	return maxf(dx, dy)

func _crop_kind_for(hash_cell: int, k: int) -> StringName:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel_crop"), hash_cell, k]) % 1000003) / 1000003.0
	if r < 0.35:
		return &"wheat"
	elif r < 0.65:
		return &"barley"
	elif r < 0.85:
		return &"potato"
	else:
		return &"beet"

func _planted_day_for(hash_cell: int, k: int) -> int:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), hash_cell, k, 777]) % 1000003) / 1000003.0
	return int(floor(r * 7.0))

func _yaw_for(parcel_center: Vector2, hash_cell: int, k: int) -> float:
	if road_network_ref != null:
		var dr: float = road_network_ref.distance_to_road(parcel_center)
		if dr < 40.0:
			var tang := _nearest_road_tangent(parcel_center)
			if tang.length_squared() > 1e-6:
				var ang := atan2(tang.y, tang.x)
				var q: float = round(ang / (PI * 0.5)) * (PI * 0.5)
				q = wrapf(q, -PI, PI)
				if is_equal_approx(absf(q), PI):
					q = PI
				return q
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel_yaw"), hash_cell, k]) % 1000003) / 1000003.0
	var idx: int = int(floor(r * 4.0)) % 4
	match idx:
		0:
			return 0.0
		1:
			return PI * 0.5
		2:
			return PI
		3:
			return -PI * 0.5
		_:
			return 0.0

func _nearest_road_tangent(p: Vector2) -> Vector2:
	if road_network_ref == null:
		return Vector2.ZERO
	var rect := Rect2(p - Vector2(60, 60), Vector2(120, 120))
	var segs: Array[Dictionary] = road_network_ref.road_segments_in(rect)
	if segs.is_empty():
		return Vector2.ZERO
	var best_dist := INF
	var best_tangent := Vector2.ZERO
	for seg in segs:
		var poly: PackedVector2Array = seg.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 < 1e-6:
				continue
			var t := (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d := p.distance_to(proj)
			if d < best_dist:
				best_dist = d
				best_tangent = ab
	return best_tangent

func _contents_for_crop(crop: StringName) -> Dictionary:
	match crop:
		&"wheat":
			return {&"wheat_grain": 1}
		&"barley":
			return {&"barley_grain": 1}
		&"potato":
			return {&"bandage": 1}
		&"beet":
			return {&"antibiotics": 1}
		_:
			return {&"wheat_grain": 1}

func _is_grown(planted_day: int) -> bool:
	var cur_day: int = 1
	if Engine.has_singleton("GameClock"):
		cur_day = Engine.get_singleton("GameClock").get_day()
	else:
		cur_day = 1
	return cur_day >= planted_day + WorldConstants.CROP_GROW_DAYS

static func _dict_id_cmp(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id","")) < String(b.get("id",""))

func field_parcels_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return out
	var cx_min := floori(rect.position.x / WorldConstants.LANDSCAPE_CELL_M)
	var cx_max := floori((rect.position.x + rect.size.x - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	var cy_min := floori(rect.position.y / WorldConstants.LANDSCAPE_CELL_M)
	var cy_max := floori((rect.position.y + rect.size.y - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	for cx in range(cx_min, cx_max + 1):
		for cy in range(cy_min, cy_max + 1):
			var cell_parcels: Array[Dictionary] = _parcels_for_cell(cx, cy)
			for parc in cell_parcels:
				var center: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
				if rect.has_point(center):
					out.append(parc)
	out.sort_custom(_dict_id_cmp)
	return out

func field_parcels() -> Array[Dictionary]:
	var world_rect := Rect2(Vector2(WorldConstants.WORLD_MIN_M, WorldConstants.WORLD_MIN_M), Vector2(WorldConstants.WORLD_SIZE_M, WorldConstants.WORLD_SIZE_M))
	return field_parcels_in(world_rect)

func nearest_field_parcel(p: Vector2) -> Dictionary:
	var search_rect := Rect2(p - Vector2(512, 512), Vector2(1024, 1024))
	var candidates: Array[Dictionary] = field_parcels_in(search_rect)
	if candidates.is_empty():
		# fallback to larger search
		candidates = field_parcels_in(Rect2(p - Vector2(1500,1500), Vector2(3000,3000)))
		if candidates.is_empty():
			return {}
	var best: Dictionary = {}
	var best_d := INF
	for parc in candidates:
		var c: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
		var d := p.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = parc
	return best

func crop_patch_for_parcel(parcel_id: String) -> Dictionary:
	var all: Array[Dictionary] = field_parcels()
	for parc in all:
		if String(parc.get("id", "")) == parcel_id:
			var pos: Vector2 = parc.get("pos", Vector2.ZERO) as Vector2
			var aabb: Rect2 = parc.get("aabb", Rect2()) as Rect2
			var center: Vector2 = parc.get("center", pos) as Vector2
			var crop: StringName = parc.get("crop_kind", &"wheat") as StringName
			var planted: int = int(parc.get("planted_day", 0))
			var yaw: float = float(parc.get("yaw", 0.0))
			var contents: Dictionary = _contents_for_crop(crop)
			var cur_day: int = 1
			if Engine.has_singleton("GameClock"):
				cur_day = Engine.get_singleton("GameClock").get_day()
			var is_grown: bool = cur_day >= planted + WorldConstants.CROP_GROW_DAYS
			var h: float = terrain.height_at(center) + WorldConstants.FIELD_PARCEL_LIFT_M + 0.01
			var world_pos := Vector3(center.x, h, center.y)
			return {
				"id": "crop_%s" % parcel_id,
				"parcel_id": parcel_id,
				"pos": center,
				"position": world_pos,
				"aabb": aabb,
				"crop_kind": crop,
				"kind": crop,
				"contents": contents,
				"planted_day": planted,
				"yaw": yaw,
				"is_grown": is_grown,
				"depleted": false,
			}
	return {}

func _parcels_for_cell(cx: int, cy: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cell_origin := Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
	var cell_center := cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M * 0.5, WorldConstants.LANDSCAPE_CELL_M * 0.5)
	var cell_rect := Rect2(cell_origin, Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M))
	# Urban inner exclusion: if cell_center inside 350, no parcels
	if cell_center.length() < WorldConstants.URBAN_INNER_M:
		return out
	if not WorldConstants.is_inside_world(cell_center):
		return out
	# Check majority biome at center
	var b_center: StringName = biome_at(cell_center)
	if not _is_arable_family(b_center):
		return out
	var density: float = WorldSeed.sample_coherent(cell_center, &"field_parcel_density", WorldConstants.LANDSCAPE_CELL_M, seed_used)
	if density < WorldConstants.FIELD_DENSITY_MIN:
		return out
	var base: int = int(floor(density * 3.0))
	var village_adj: bool = _is_village_adjacent(cell_center)
	if village_adj:
		base += 1
	base = clampi(base, 0, WorldConstants.FIELD_PARCEL_MAX_PER_LANDSCAPE_CELL)
	if base <= 0:
		return out
	var hash_cell: int = _hash_cell(cx, cy)
	var placed: Array[Dictionary] = []
	for k in base:
		var parcel: Dictionary = {}
		var found := false
		for attempt in 12:
			var rx: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), hash_cell, k, attempt, 0]) % 1000003) / 1000003.0
			var rz: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), hash_cell, k, attempt, 1]) % 1000003) / 1000003.0
			var rw: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), hash_cell, k, attempt, 2]) % 1000003) / 1000003.0
			var rh: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("field_parcel"), hash_cell, k, attempt, 3]) % 1000003) / 1000003.0
			var size := Vector2(lerpf(WorldConstants.FIELD_PARCEL_SIZE_MIN.x, WorldConstants.FIELD_PARCEL_SIZE_MAX.x, rw), lerpf(WorldConstants.FIELD_PARCEL_SIZE_MIN.y, WorldConstants.FIELD_PARCEL_SIZE_MAX.y, rh))
			var cx_pos: float = lerpf(cell_origin.x + size.x * 0.5 + 2.0, cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - size.x * 0.5 - 2.0, rx)
			var cy_pos: float = lerpf(cell_origin.y + size.y * 0.5 + 2.0, cell_origin.y + WorldConstants.LANDSCAPE_CELL_M - size.y * 0.5 - 2.0, rz)
			# If cell minus inset smaller than size, clamp via size/2+2 logic may invert; handle
			if cx_pos != clampf(cx_pos, cell_origin.x + size.x * 0.5 + 2.0, cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - size.x * 0.5 - 2.0):
				continue
			var pos := Vector2(cx_pos, cy_pos)
			var aabb := Rect2(pos - size * 0.5, size)
			# Validate aabb fully inside cell with inset
			if aabb.position.x < cell_origin.x + 1.9 or aabb.end.x > cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - 1.9:
				continue
			if aabb.position.y < cell_origin.y + 1.9 or aabb.end.y > cell_origin.y + WorldConstants.LANDSCAPE_CELL_M - 1.9:
				continue
			# Center ownership is automatically inside cell because pos inside inset
			# Urban inner check per parcel
			if pos.length() < WorldConstants.URBAN_INNER_M:
				continue
			# Biome at center must be arable family
			var b_at: StringName = biome_at(pos)
			if not _is_arable_family(b_at):
				continue
			var slope: float = terrain.slope_at(pos)
			var max_slope: float = _max_slope_for_biome(b_at)
			if slope >= max_slope + 0.001:
				continue
			if terrain.terrain_class_at(pos) == &"cliff":
				continue
			if hydrology.water_body_at(pos) != &"":
				continue
			if hydrology.is_floodplain(pos):
				continue
			var d_water: float = hydrology.distance_to_water(pos)
			if d_water <= WorldConstants.BANK_W + 2.0:
				continue
			if road_network_ref != null:
				var d_road: float = road_network_ref.distance_to_road(pos)
				if d_road < WorldConstants.FIELD_PARCEL_ROAD_SETBACK - 0.001:
					continue
				# check is_bridge via crossing candidates near pos
				var near_bridge := false
				var cand_rect := Rect2(pos - Vector2(16,16), Vector2(32,32))
				var cands: Array[Dictionary] = hydrology.crossing_candidates(cand_rect)
				for cand in cands:
					if bool(cand.get("is_bridge", false)):
						var cp: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
						if pos.distance_to(cp) < 16.0:
							near_bridge = true
							break
					# also check RoadNetwork is_bridge flag via road segments
				if near_bridge:
					continue
				if d_road < 3.0:
					# also check bridge via road graph? use road hierarchy
					var hier: StringName = road_network_ref.road_hierarchy_at(pos)
					if hier == &"primary" and d_road < 1.5:
						continue
			# Height variance across aabb corners
			var corners: Array[Vector2] = [aabb.position, Vector2(aabb.end.x, aabb.position.y), Vector2(aabb.position.x, aabb.end.y), aabb.end, pos]
			var min_h := INF
			var max_h := -INF
			for c in corners:
				var h: float = terrain.height_at(c)
				min_h = minf(min_h, h)
				max_h = maxf(max_h, h)
			if max_h - min_h > WorldConstants.FIELD_PARCEL_HEIGHT_VARIANCE_MAX + 0.001:
				continue
			# Spacing from existing placed parcels in same cell
			var gap_ok := true
			for other in placed:
				var other_aabb: Rect2 = other.get("aabb", Rect2()) as Rect2
				var gap: float = _aabb_gap(aabb, other_aabb)
				if gap < WorldConstants.FIELD_PARCEL_AABB_GAP - 0.001:
					gap_ok = false
					break
			if not gap_ok:
				continue
			# Gap from rural buildings
			if rural_building_ref != null:
				var bld_rect := Rect2(pos - Vector2(32,32), Vector2(64,64))
				var blds: Array[Dictionary] = rural_building_ref.rural_buildings_in(bld_rect)
				var bld_ok := true
				for bld in blds:
					var bld_aabb: Rect2 = bld.get("aabb", Rect2()) as Rect2
					if bld_aabb.size == Vector2.ZERO:
						var bld_center_v: Vector2 = bld.get("center", Vector2.ZERO) as Vector2
						var bld_fp: Vector2 = bld.get("footprint", Vector2(8,8)) as Vector2
						var bld_yaw_v: float = float(bld.get("yaw", 0.0))
						var eff := bld_fp
						if is_equal_approx(absf(bld_yaw_v), PI*0.5):
							eff = Vector2(bld_fp.y, bld_fp.x)
						bld_aabb = Rect2(bld_center_v - eff*0.5, eff)
					var gap2: float = _aabb_gap(aabb, bld_aabb)
					if gap2 < WorldConstants.FIELD_PARCEL_BUILDING_GAP - 0.001:
						bld_ok = false
						break
				if not bld_ok:
					continue
				# Gap from wells/forage
				var well_rect := Rect2(pos - Vector2(20,20), Vector2(40,40))
				var wells: Array[Dictionary] = rural_building_ref.rural_wells_in(well_rect)
				var forage: Array[Dictionary] = rural_building_ref.rural_forage_patches_in(well_rect)
				var wf_ok := true
				for w in wells:
					var wp: Vector2 = w.get("pos", w.get("center", Vector2.ZERO)) as Vector2
					if pos.distance_to(wp) < WorldConstants.FIELD_PARCEL_WELL_FORAGE_GAP - 0.001:
						wf_ok = false
						break
				if not wf_ok:
					continue
				for f in forage:
					var fp: Vector2 = f.get("pos", f.get("center", Vector2.ZERO)) as Vector2
					if pos.distance_to(fp) < WorldConstants.FIELD_PARCEL_WELL_FORAGE_GAP - 0.001:
						wf_ok = false
						break
				if not wf_ok:
					continue
			var yaw: float = _yaw_for(pos, hash_cell, k)
			var crop: StringName = _crop_kind_for(hash_cell, k)
			var planted: int = _planted_day_for(hash_cell, k)
			var contents: Dictionary = _contents_for_crop(crop)
			var cur_day: int = 1
			if Engine.has_singleton("GameClock"):
				cur_day = Engine.get_singleton("GameClock").get_day()
			var is_grown: bool = cur_day >= planted + WorldConstants.CROP_GROW_DAYS
			var growth_stage: StringName = &"harvestable" if is_grown else (&"growing" if cur_day == planted + 1 else &"planted")
			var landscape_cell := Vector2i(cx, cy)
			var macro_cell := Vector2i(floori(pos.x / WorldConstants.MACRO_CELL_M), floori(pos.y / WorldConstants.MACRO_CELL_M))
			var settlement_id := ""
			if settlement_ref != null:
				var nearest: Dictionary = settlement_ref.nearest_settlement(pos)
				if not nearest.is_empty():
					settlement_id = String(nearest.get("id", ""))
			var pid: String = "field_parcel_%d_%d_%d" % [cx, cy, k]
			parcel = {
				"id": pid,
				"parcel_id": pid,
				"center": pos,
				"pos": pos,
				"aabb": aabb,
				"biome": b_at,
				"landscape_cell": landscape_cell,
				"macro_cell": macro_cell,
				"crop_kind": crop,
				"kind": crop,
				"size": size,
				"yaw": yaw,
				"settlement_id": settlement_id,
				"planted_day": planted,
				"growth_stage": growth_stage,
				"is_grown": is_grown,
				"contents": contents,
			}
			found = true
			break
		if found:
			placed.append(parcel)
	# Ensure deterministic order by id
	placed.sort_custom(_dict_id_cmp)
	return placed

# --- Orchard Parcel Cultivation P5.2 ---

func _is_orchard_family(b: StringName) -> bool:
	return b == &"orchard" or b == &"pasture_orchard"

func _orchard_hash_cell(cx: int, cy: int) -> int:
	return WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), cx, cy])

func _is_orchard_village_adjacent(cell_center: Vector2) -> bool:
	if settlement_ref == null:
		return false
	var anchors: Array[Dictionary] = settlement_ref.settlement_anchors()
	for a in anchors:
		if StringName(str(a.get("kind", ""))) != &"village":
			continue
		var c: Vector2 = a.get("center", Vector2.ZERO) as Vector2
		var r: float = float(a.get("radius", 48.0))
		var dist := cell_center.distance_to(c)
		if dist <= r * 1.35:
			return true
	return false

func _fruit_kind_for(hash_cell: int, k: int) -> StringName:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel_fruit"), hash_cell, k]) % 1000003) / 1000003.0
	if r < 0.40:
		return &"apple"
	elif r < 0.70:
		return &"plum"
	elif r < 0.85:
		return &"pear"
	else:
		return &"cherry"

func _orchard_planted_day_for(hash_cell: int, k: int) -> int:
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, 999]) % 1000003) / 1000003.0
	return int(floor(r * 7.0))

func _orchard_yaw_for(parcel_center: Vector2, hash_cell: int, k: int) -> float:
	if road_network_ref != null:
		var dr: float = road_network_ref.distance_to_road(parcel_center)
		if dr < 40.0:
			var tang := _nearest_road_tangent(parcel_center)
			if tang.length_squared() > 1e-6:
				var ang := atan2(tang.y, tang.x)
				var q: float = round(ang / (PI * 0.5)) * (PI * 0.5)
				q = wrapf(q, -PI, PI)
				if is_equal_approx(absf(q), PI):
					q = PI
				return q
	var r: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel_yaw"), hash_cell, k]) % 1000003) / 1000003.0
	var idx: int = int(floor(r * 4.0)) % 4
	match idx:
		0:
			return 0.0
		1:
			return PI * 0.5
		2:
			return PI
		3:
			return -PI * 0.5
		_:
			return 0.0

func _contents_for_fruit(fruit: StringName) -> Dictionary:
	match fruit:
		&"apple":
			return {&"apple": 1}
		&"plum":
			return {&"plum": 1}
		&"pear":
			return {&"pear": 1}
		&"cherry":
			return {&"cherry": 1}
		_:
			return {&"apple": 1}

func _is_grown_orchard(planted_day: int) -> bool:
	var cur_day: int = 1
	if Engine.has_singleton("GameClock"):
		cur_day = Engine.get_singleton("GameClock").get_day()
	return cur_day >= planted_day + WorldConstants.FRUIT_GROW_DAYS

func _orchard_canopy_color(fruit: StringName) -> Color:
	match fruit:
		&"apple":
			return WorldConstants.COL_ORCHARD_APPLE
		&"plum":
			return WorldConstants.COL_ORCHARD_PLUM
		&"pear":
			return WorldConstants.COL_ORCHARD_PEAR
		&"cherry":
			return WorldConstants.COL_ORCHARD_CHERRY
		_:
			return WorldConstants.COL_ORCHARD_APPLE

func _orchard_tree_instances_for(parcel: Dictionary) -> Array[Vector3]:
	var instances: Array[Vector3] = []
	var center: Vector2 = parcel.get("center", Vector2.ZERO) as Vector2
	var size: Vector2 = parcel.get("size", Vector2(32, 24)) as Vector2
	var yaw: float = float(parcel.get("yaw", 0.0))
	var hash_cell: int = int(parcel.get("_hash_cell", 0))
	var k_idx: int = int(parcel.get("_k_idx", 0))
	var tree_rows: int = 3 if size.x < 40.0 else 4
	var trees_per_row: int
	if size.y < 30.0:
		trees_per_row = 3
	else:
		var rr: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k_idx, 888]) % 1000003) / 1000003.0
		trees_per_row = 4 if rr < 0.5 else 5
	var spacing_x := WorldConstants.ORCHARD_TREE_SPACING
	var spacing_z := WorldConstants.ORCHARD_ROW_SPACING
	for r in tree_rows:
		for c in trees_per_row:
			var jitter_x: float = (float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k_idx, r, c, 0]) % 1000003) / 1000003.0 - 0.5) * 1.2
			var jitter_z: float = (float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k_idx, r, c, 1]) % 1000003) / 1000003.0 - 0.5) * 1.2
			var off_x := (float(c) - float(trees_per_row - 1) * 0.5) * spacing_x + jitter_x
			var off_z := (float(r) - float(tree_rows - 1) * 0.5) * spacing_z + jitter_z
			var vec := Vector2(off_x, off_z)
			if not is_equal_approx(yaw, 0.0):
				vec = vec.rotated(yaw)
			var pos2 := center + vec
			var h: float = terrain.height_at(pos2) + WorldConstants.ORCHARD_PARCEL_LIFT_M
			instances.append(Vector3(pos2.x, h, pos2.y))
	return instances

func orchard_parcels_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return out
	var cx_min := floori(rect.position.x / WorldConstants.LANDSCAPE_CELL_M)
	var cx_max := floori((rect.position.x + rect.size.x - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	var cy_min := floori(rect.position.y / WorldConstants.LANDSCAPE_CELL_M)
	var cy_max := floori((rect.position.y + rect.size.y - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	for cx in range(cx_min, cx_max + 1):
		for cy in range(cy_min, cy_max + 1):
			var cell_parcels: Array[Dictionary] = _orchard_parcels_for_cell(cx, cy)
			for parc in cell_parcels:
				var center: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
				if rect.has_point(center):
					out.append(parc)
	out.sort_custom(_dict_id_cmp)
	return out

func orchard_parcels() -> Array[Dictionary]:
	var world_rect := Rect2(Vector2(WorldConstants.WORLD_MIN_M, WorldConstants.WORLD_MIN_M), Vector2(WorldConstants.WORLD_SIZE_M, WorldConstants.WORLD_SIZE_M))
	return orchard_parcels_in(world_rect)

func nearest_orchard_parcel(p: Vector2) -> Dictionary:
	var search_rect := Rect2(p - Vector2(512, 512), Vector2(1024, 1024))
	var candidates: Array[Dictionary] = orchard_parcels_in(search_rect)
	if candidates.is_empty():
		candidates = orchard_parcels_in(Rect2(p - Vector2(1500,1500), Vector2(3000,3000)))
		if candidates.is_empty():
			return {}
	var best: Dictionary = {}
	var best_d := INF
	for parc in candidates:
		var c: Vector2 = parc.get("center", Vector2.ZERO) as Vector2
		var d := p.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = parc
	return best

func fruit_patch_for_parcel(parcel_id: String) -> Dictionary:
	var all: Array[Dictionary] = orchard_parcels()
	for parc in all:
		if String(parc.get("id", "")) == parcel_id:
			var pos: Vector2 = parc.get("pos", Vector2.ZERO) as Vector2
			var center: Vector2 = parc.get("center", pos) as Vector2
			var aabb: Rect2 = parc.get("aabb", Rect2()) as Rect2
			var fruit: StringName = parc.get("fruit_kind", &"apple") as StringName
			var planted: int = int(parc.get("planted_day", 0))
			var yaw: float = float(parc.get("yaw", 0.0))
			var contents: Dictionary = _contents_for_fruit(fruit)
			var cur_day: int = 1
			if Engine.has_singleton("GameClock"):
				cur_day = Engine.get_singleton("GameClock").get_day()
			var is_grown: bool = cur_day >= planted + WorldConstants.FRUIT_GROW_DAYS
			var h: float = terrain.height_at(center) + WorldConstants.ORCHARD_PARCEL_LIFT_M + 0.01
			var world_pos := Vector3(center.x, h, center.y)
			return {
				"id": "fruit_%s" % parcel_id,
				"parcel_id": parcel_id,
				"pos": center,
				"position": world_pos,
				"aabb": aabb,
				"fruit_kind": fruit,
				"kind": fruit,
				"contents": contents,
				"planted_day": planted,
				"yaw": yaw,
				"is_grown": is_grown,
				"depleted": false,
			}
	return {}

func _orchard_parcels_for_cell(cx: int, cy: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var cell_origin := Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
	var cell_center := cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M * 0.5, WorldConstants.LANDSCAPE_CELL_M * 0.5)
	var cell_rect := Rect2(cell_origin, Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M))
	if cell_center.length() < WorldConstants.URBAN_INNER_M:
		return out
	if not WorldConstants.is_inside_world(cell_center):
		return out
	var b_center: StringName = biome_at(cell_center)
	if not _is_orchard_family(b_center):
		return out
	var density: float = WorldSeed.sample_coherent(cell_center, &"orchard_parcel_density", WorldConstants.LANDSCAPE_CELL_M, seed_used)
	if density < WorldConstants.ORCHARD_DENSITY_MIN:
		return out
	var base: int = int(floor(clampf(density, 0.0, 1.0) * 2.0))
	var village_adj: bool = _is_orchard_village_adjacent(cell_center)
	if village_adj:
		base += 1
	base = clampi(base, 0, WorldConstants.ORCHARD_PARCEL_MAX_PER_LANDSCAPE_CELL)
	if base <= 0:
		return out
	var hash_cell: int = _orchard_hash_cell(cx, cy)
	var placed: Array[Dictionary] = []
	var field_for_cell: Array[Dictionary] = _parcels_for_cell(cx, cy)
	for k in base:
		var parcel: Dictionary = {}
		var found := false
		for attempt in 12:
			var rx: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, attempt, 0]) % 1000003) / 1000003.0
			var rz: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, attempt, 1]) % 1000003) / 1000003.0
			var rw: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, attempt, 2]) % 1000003) / 1000003.0
			var rh: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, attempt, 3]) % 1000003) / 1000003.0
			var size := Vector2(lerpf(WorldConstants.ORCHARD_PARCEL_SIZE_MIN.x, WorldConstants.ORCHARD_PARCEL_SIZE_MAX.x, rw), lerpf(WorldConstants.ORCHARD_PARCEL_SIZE_MIN.y, WorldConstants.ORCHARD_PARCEL_SIZE_MAX.y, rh))
			var cx_pos: float = lerpf(cell_origin.x + size.x * 0.5 + 2.0, cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - size.x * 0.5 - 2.0, rx)
			var cy_pos: float = lerpf(cell_origin.y + size.y * 0.5 + 2.0, cell_origin.y + WorldConstants.LANDSCAPE_CELL_M - size.y * 0.5 - 2.0, rz)
			if cx_pos != clampf(cx_pos, cell_origin.x + size.x * 0.5 + 2.0, cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - size.x * 0.5 - 2.0):
				continue
			var pos := Vector2(cx_pos, cy_pos)
			var aabb := Rect2(pos - size * 0.5, size)
			if aabb.position.x < cell_origin.x + 1.9 or aabb.end.x > cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - 1.9:
				continue
			if aabb.position.y < cell_origin.y + 1.9 or aabb.end.y > cell_origin.y + WorldConstants.LANDSCAPE_CELL_M - 1.9:
				continue
			if pos.length() < WorldConstants.URBAN_INNER_M:
				continue
			var b_at: StringName = biome_at(pos)
			if not _is_orchard_family(b_at):
				continue
			var slope: float = terrain.slope_at(pos)
			if slope >= WorldConstants.ORCHARD_MAX_SLOPE_DEG + 0.001:
				continue
			if terrain.terrain_class_at(pos) == &"cliff":
				continue
			if hydrology.water_body_at(pos) != &"":
				continue
			if hydrology.is_floodplain(pos):
				continue
			var d_water: float = hydrology.distance_to_water(pos)
			if d_water <= WorldConstants.BANK_W + 2.0:
				continue
			if road_network_ref != null:
				var d_road: float = road_network_ref.distance_to_road(pos)
				if d_road < WorldConstants.ORCHARD_PARCEL_ROAD_SETBACK - 0.001:
					continue
				var near_bridge := false
				var cand_rect := Rect2(pos - Vector2(16,16), Vector2(32,32))
				var cands: Array[Dictionary] = hydrology.crossing_candidates(cand_rect)
				for cand in cands:
					if bool(cand.get("is_bridge", false)):
						var cp: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
						if pos.distance_to(cp) < 16.0:
							near_bridge = true
							break
				if near_bridge:
					continue
			var corners: Array[Vector2] = [aabb.position, Vector2(aabb.end.x, aabb.position.y), Vector2(aabb.position.x, aabb.end.y), aabb.end, pos]
			var min_h := INF
			var max_h := -INF
			for c in corners:
				var h: float = terrain.height_at(c)
				min_h = minf(min_h, h)
				max_h = maxf(max_h, h)
			if max_h - min_h > WorldConstants.ORCHARD_PARCEL_HEIGHT_VARIANCE_MAX + 0.001:
				continue
			var gap_ok := true
			for other in placed:
				var other_aabb: Rect2 = other.get("aabb", Rect2()) as Rect2
				var gap: float = _aabb_gap(aabb, other_aabb)
				if gap < WorldConstants.ORCHARD_PARCEL_AABB_GAP - 0.001:
					gap_ok = false
					break
			if not gap_ok:
				continue
			for fparc in field_for_cell:
				var f_aabb: Rect2 = fparc.get("aabb", Rect2()) as Rect2
				var gap2: float = _aabb_gap(aabb, f_aabb)
				if gap2 < WorldConstants.ORCHARD_PARCEL_AABB_GAP - 0.001:
					gap_ok = false
					break
			if not gap_ok:
				continue
			if rural_building_ref != null:
				var bld_rect := Rect2(pos - Vector2(32,32), Vector2(64,64))
				var blds: Array[Dictionary] = rural_building_ref.rural_buildings_in(bld_rect)
				var bld_ok := true
				for bld in blds:
					var bld_aabb: Rect2 = bld.get("aabb", Rect2()) as Rect2
					if bld_aabb.size == Vector2.ZERO:
						var bld_center_v: Vector2 = bld.get("center", Vector2.ZERO) as Vector2
						var bld_fp: Vector2 = bld.get("footprint", Vector2(8,8)) as Vector2
						var bld_yaw_v: float = float(bld.get("yaw", 0.0))
						var eff := bld_fp
						if is_equal_approx(absf(bld_yaw_v), PI*0.5):
							eff = Vector2(bld_fp.y, bld_fp.x)
						bld_aabb = Rect2(bld_center_v - eff*0.5, eff)
					var gap3: float = _aabb_gap(aabb, bld_aabb)
					if gap3 < WorldConstants.ORCHARD_PARCEL_BUILDING_GAP - 0.001:
						bld_ok = false
						break
				if not bld_ok:
					continue
				var well_rect := Rect2(pos - Vector2(20,20), Vector2(40,40))
				var wells: Array[Dictionary] = rural_building_ref.rural_wells_in(well_rect)
				var forage: Array[Dictionary] = rural_building_ref.rural_forage_patches_in(well_rect)
				var wf_ok := true
				for w in wells:
					var wp: Vector2 = w.get("pos", w.get("center", Vector2.ZERO)) as Vector2
					if pos.distance_to(wp) < WorldConstants.ORCHARD_WELL_FORAGE_GAP - 0.001:
						wf_ok = false
						break
				if not wf_ok:
					continue
				for f in forage:
					var fp: Vector2 = f.get("pos", f.get("center", Vector2.ZERO)) as Vector2
					if pos.distance_to(fp) < WorldConstants.ORCHARD_WELL_FORAGE_GAP - 0.001:
						wf_ok = false
						break
				if not wf_ok:
					continue
			var yaw: float = _orchard_yaw_for(pos, hash_cell, k)
			var fruit: StringName = _fruit_kind_for(hash_cell, k)
			var planted: int = _orchard_planted_day_for(hash_cell, k)
			var contents: Dictionary = _contents_for_fruit(fruit)
			var cur_day: int = 1
			if Engine.has_singleton("GameClock"):
				cur_day = Engine.get_singleton("GameClock").get_day()
			var is_grown: bool = cur_day >= planted + WorldConstants.FRUIT_GROW_DAYS
			var growth_stage: StringName = &"harvestable" if is_grown else (&"growing" if cur_day == planted + 1 else &"planted")
			var landscape_cell := Vector2i(cx, cy)
			var macro_cell := Vector2i(floori(pos.x / WorldConstants.MACRO_CELL_M), floori(pos.y / WorldConstants.MACRO_CELL_M))
			var settlement_id := ""
			if settlement_ref != null:
				var nearest: Dictionary = settlement_ref.nearest_settlement(pos)
				if not nearest.is_empty():
					settlement_id = String(nearest.get("id", ""))
			var pid: String = "orchard_parcel_%d_%d_%d" % [cx, cy, k]
			parcel = {
				"id": pid,
				"parcel_id": pid,
				"center": pos,
				"pos": pos,
				"aabb": aabb,
				"biome": b_at,
				"landscape_cell": landscape_cell,
				"macro_cell": macro_cell,
				"fruit_kind": fruit,
				"kind": fruit,
				"size": size,
				"yaw": yaw,
				"settlement_id": settlement_id,
				"planted_day": planted,
				"growth_stage": growth_stage,
				"is_grown": is_grown,
				"contents": contents,
				"_hash_cell": hash_cell,
				"_k_idx": k,
			}
			var tree_instances: Array[Vector3] = _orchard_tree_instances_for(parcel)
			parcel["tree_instances"] = tree_instances
			parcel["tree_rows"] = 3 if size.x < 40.0 else 4
			if size.y < 30.0:
				parcel["trees_per_row"] = 3
			else:
				var rr2: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("orchard_parcel"), hash_cell, k, 888]) % 1000003) / 1000003.0
				parcel["trees_per_row"] = 4 if rr2 < 0.5 else 5
			found = true
			break
		if found:
			placed.append(parcel)
	placed.sort_custom(_dict_id_cmp)
	return placed
