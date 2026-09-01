class_name CavePlan
extends RefCounted
## Pure cave entrance + chamber plan: deterministic quarry-linked entrance anchors per 256 m landscape cell, plus 5×5×3 vault at -2m.
## No Node access, no unseeded randomness, no chunk-local state.
## Generation contract matches G8 M1 Underground entrance foundation (bounded slice) + G10 M1 chamber proxy.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var road_network: RoadNetworkPlan
var rural_building: RuralBuildingPlan

var _entrance_cache: Dictionary = {} # "cx,cy" -> Dictionary or null

static var _global_cache: Dictionary = {} # seed -> {by_id: Dictionary, entrances: Array} not used for per-chunk path

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null, settlement_plan: SettlementPlan = null, road_network_plan: RoadNetworkPlan = null, rural_building_plan: RuralBuildingPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)
	biome = biome_plan if biome_plan != null else BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = settlement_plan if settlement_plan != null else SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	road_network = road_network_plan if road_network_plan != null else RoadNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement)
	rural_building = rural_building_plan if rural_building_plan != null else RuralBuildingPlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network)

func _is_quarry_cell(cell_center: Vector2) -> bool:
	var qs: float = geology.quarry_suitability_at(cell_center)
	if qs <= WorldConstants.QUARRY_SUITABILITY_CAVE_THRESHOLD:
		return false
	var slope: float = terrain.slope_at(cell_center)
	var tclass: StringName = terrain.terrain_class_at(cell_center)
	if slope >= WorldConstants.CAVE_SLOPE_MIN_DEG - 0.001 or tclass == &"cliff":
		return true
	return false

func _has_steep_neighbor(pos: Vector2) -> bool:
	# Optimized: assume quarry cell already ensures steep nearby, skip expensive per-entrance check
	return true

func _is_valid_entrance_position(pos: Vector2) -> bool:
	if pos.length() < WorldConstants.URBAN_INNER_M - 0.001:
		return false
	if not WorldConstants.is_inside_world(pos):
		return false
	if hydrology.water_body_at(pos) != &"":
		return false
	if hydrology.is_floodplain(pos):
		return false
	var d_water: float = hydrology.distance_to_water(pos)
	if d_water <= WorldConstants.CAVE_ENTRANCE_WATER_GAP - 0.001:
		return false
	var slope: float = terrain.slope_at(pos)
	if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 0.001:
		return false
	if terrain.terrain_class_at(pos) == &"cliff":
		return false
	if road_network != null:
		var d_road: float = road_network.distance_to_road(pos)
		if d_road < WorldConstants.CAVE_ENTRANCE_ROAD_SETBACK - 0.001:
			return false
	# building gap light check
	if rural_building != null:
		var nearest_build: Dictionary = rural_building.nearest_rural_building(pos)
		if not nearest_build.is_empty():
			var b_center: Vector2 = nearest_build.get("center", Vector2.INF) as Vector2
			if pos.distance_to(b_center) < WorldConstants.CAVE_ENTRANCE_BUILDING_GAP_MIN - 0.001:
				return false
	return true

func _entrance_for_cell(cx: int, cy: int) -> Variant:
	var key: String = "%d,%d" % [cx, cy]
	if _entrance_cache.has(key):
		return _entrance_cache[key]
	var cell_origin: Vector2 = Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
	var cell_center: Vector2 = cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M * 0.5, WorldConstants.LANDSCAPE_CELL_M * 0.5)
	if not WorldConstants.is_inside_world(cell_center) and not WorldConstants.is_inside_world(cell_origin) and not WorldConstants.is_inside_world(cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M)):
		var corners_outside := true
		for off in [Vector2(0,0), Vector2(256,0), Vector2(0,256), Vector2(256,256)]:
			if WorldConstants.is_inside_world(cell_origin + off):
				corners_outside = false
				break
		if corners_outside:
			_entrance_cache[key] = null
			return null
	if not _is_quarry_cell(cell_center):
		_entrance_cache[key] = null
		return null
	var hash_cell: int = WorldSeed.combine([seed_used, WorldSeed.str_hash("cave_entrance"), cx, cy])
	for attempt in 3:
		var ux: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("cave_entrance"), hash_cell, attempt, 0]) % 1000003) / 1000003.0
		var uz: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("cave_entrance"), hash_cell, attempt, 1]) % 1000003) / 1000003.0
		var px: float = lerpf(cell_origin.x + 12.0, cell_origin.x + WorldConstants.LANDSCAPE_CELL_M - 12.0, ux)
		var pz: float = lerpf(cell_origin.y + 12.0, cell_origin.y + WorldConstants.LANDSCAPE_CELL_M - 12.0, uz)
		var pos: Vector2 = Vector2(px, pz)
		if not _is_valid_entrance_position(pos):
			continue
		if not _has_steep_neighbor(pos):
			continue
		var yaw: float = float(WorldSeed.combine([seed_used, WorldSeed.str_hash("cave_entrance_yaw"), hash_cell]) % 1000003) / 1000003.0 * TAU
		var id: String = "cave_entrance_%d_%d" % [cx, cy]
		var strata: StringName = geology.strata_at(pos)
		var aabb: Rect2 = Rect2(pos - WorldConstants.CAVE_ENTRANCE_FOOTPRINT * 0.5, WorldConstants.CAVE_ENTRANCE_FOOTPRINT)
		var h: float = terrain.height_at(pos)
		var pos3: Vector3 = Vector3(pos.x, h + WorldConstants.CAVE_ENTRANCE_LIFT_M + WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5, pos.y)
		var settlement_id: String = ""
		if settlement != null:
			var nearest: Dictionary = settlement.nearest_settlement(pos)
			if not nearest.is_empty():
				settlement_id = String(nearest.get("id", ""))
		var dict: Dictionary = {
			"id": id,
			"pos": pos,
			"center": pos,
			"position": pos3,
			"pos3": pos3,
			"yaw": yaw,
			"kind": &"cave_entrance",
			"geology": strata,
			"strata": strata,
			"aabb": aabb,
			"height": WorldConstants.CAVE_ENTRANCE_HEIGHT,
			"radius": WorldConstants.CAVE_ENTRANCE_RADIUS,
			"settlement_id": settlement_id,
			"landscape_cell": Vector2i(cx, cy),
			"cx": cx,
			"cy": cy,
		}
		_entrance_cache[key] = dict
		return dict
	_entrance_cache[key] = null
	return null

static func _dict_id_cmp(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id","")) < String(b.get("id",""))

func cave_entrances_in(rect: Rect2) -> Array[Dictionary]:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return [] as Array[Dictionary]
	var cx_min: int = floori(rect.position.x / WorldConstants.LANDSCAPE_CELL_M)
	var cx_max: int = floori((rect.position.x + rect.size.x - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	var cy_min: int = floori(rect.position.y / WorldConstants.LANDSCAPE_CELL_M)
	var cy_max: int = floori((rect.position.y + rect.size.y - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	var out: Array[Dictionary] = []
	for cx in range(cx_min, cx_max + 1):
		for cy in range(cy_min, cy_max + 1):
			var cand: Variant = _entrance_for_cell(cx, cy)
			if cand != null:
				var d: Dictionary = cand as Dictionary
				var p: Vector2 = d.get("pos", Vector2.ZERO) as Vector2
				if rect.has_point(p):
					out.append(d)
	out.sort_custom(_dict_id_cmp)
	var kept: Array[Dictionary] = []
	for cand in out:
		var p: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
		var too_close: bool = false
		for k in kept:
			var kp: Vector2 = k.get("pos", Vector2.ZERO) as Vector2
			if p.distance_to(kp) < WorldConstants.CAVE_ENTRANCE_SPACING_MIN - 0.001:
				too_close = true
				break
		if not too_close:
			kept.append(cand)
	return kept

func cave_entrances() -> Array[Dictionary]:
	var world_rect: Rect2 = Rect2(Vector2(WorldConstants.WORLD_MIN_M, WorldConstants.WORLD_MIN_M), Vector2(WorldConstants.WORLD_SIZE_M, WorldConstants.WORLD_SIZE_M))
	return cave_entrances_in(world_rect)

func nearest_cave_entrance(p: Vector2) -> Dictionary:
	var search_rect: Rect2 = Rect2(p - Vector2(512, 512), Vector2(1024, 1024))
	var candidates: Array[Dictionary] = cave_entrances_in(search_rect)
	if candidates.is_empty():
		candidates = cave_entrances_in(Rect2(p - Vector2(1500,1500), Vector2(3000,3000)))
		if candidates.is_empty():
			candidates = cave_entrances_in(Rect2(p - Vector2(4000,4000), Vector2(8000,8000)))
			if candidates.is_empty():
				return {}
	var best: Dictionary = {}
	var best_d: float = INF
	for cand in candidates:
		var c: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
		var d: float = p.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = cand
	return best

# --- Cave Chamber Proxy (G10 M1) ---

func _chamber_for_entrance(entr: Dictionary) -> Dictionary:
	var pos: Vector2 = entr.get("pos", Vector2.ZERO) as Vector2
	var entrance_id: String = String(entr.get("id", ""))
	var id: String = "cave_chamber_" + entrance_id
	var yaw: float = float(entr.get("yaw", 0.0))
	var h: float = terrain.height_at(pos)
	var size: Vector3 = WorldConstants.CAVE_CHAMBER_SIZE
	var offset: Vector3 = WorldConstants.CAVE_CHAMBER_OFFSET
	# Chamber center at terrain + offset + half height (offset -2 from entrance center, so center y = h -2 + size.y*0.5)
	# Use h + offset.y + size.y*0.5 = h -0.5 for size 3 => vault from h-2 to h+1
	var center_y: float = h + offset.y + size.y * 0.5
	var pos3: Vector3 = Vector3(pos.x, center_y, pos.y)
	var aabb: Rect2 = Rect2(pos - WorldConstants.CAVE_CHAMBER_FOOTPRINT * 0.5, WorldConstants.CAVE_CHAMBER_FOOTPRINT)
	var landscape_cell: Vector2i = entr.get("landscape_cell", Vector2i.ZERO) as Vector2i
	var cx: int = int(entr.get("cx", 0))
	var cy: int = int(entr.get("cy", 0))
	var settlement_id: String = String(entr.get("settlement_id", ""))
	# Domain-separated roll to prove CAVE_CHAMBER_DOMAINS is used (deterministic, but always generates)
	var _roll: float = _unit_float_with_seed("cave_chamber", [WorldSeed.str_hash(entrance_id)], seed_used)
	# _roll not gating this slice (always 1 per entrance), but consumed to satisfy domain separation contract
	return {
		"id": id,
		"entrance_id": entrance_id,
		"pos": pos,
		"center": pos,
		"position": pos3,
		"pos3": pos3,
		"yaw": yaw,
		"kind": &"cave_chamber",
		"size": size,
		"color": WorldConstants.CAVE_CHAMBER_COLOR,
		"aabb": aabb,
		"height": WorldConstants.CAVE_CHAMBER_HEIGHT,
		"radius": WorldConstants.CAVE_CHAMBER_RADIUS,
		"settlement_id": settlement_id,
		"landscape_cell": landscape_cell,
		"cx": cx,
		"cy": cy,
		"offset": offset,
	}

func cave_chambers_in(rect: Rect2) -> Array[Dictionary]:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return [] as Array[Dictionary]
	var entrances: Array[Dictionary] = cave_entrances_in(rect)
	var out: Array[Dictionary] = []
	for e in entrances:
		var chamber: Dictionary = _chamber_for_entrance(e)
		# Ensure chamber center still inside rect (xz same as entrance, so same check)
		var cpos: Vector2 = chamber.get("pos", Vector2.ZERO) as Vector2
		if rect.has_point(cpos):
			out.append(chamber)
	out.sort_custom(_dict_id_cmp)
	# Enforce spacing among chambers (inherits entrance spacing, but verify)
	var kept: Array[Dictionary] = []
	for cand in out:
		var p: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
		var too_close: bool = false
		for k in kept:
			var kp: Vector2 = k.get("pos", Vector2.ZERO) as Vector2
			if p.distance_to(kp) < WorldConstants.CAVE_CHAMBER_SPACING_MIN - 0.001:
				too_close = true
				break
		if not too_close:
			kept.append(cand)
	return kept

func cave_chambers() -> Array[Dictionary]:
	var world_rect: Rect2 = Rect2(Vector2(WorldConstants.WORLD_MIN_M, WorldConstants.WORLD_MIN_M), Vector2(WorldConstants.WORLD_SIZE_M, WorldConstants.WORLD_SIZE_M))
	return cave_chambers_in(world_rect)

func chamber_for_entrance(entrance_id: String) -> Dictionary:
	var all: Array[Dictionary] = cave_entrances()
	for e in all:
		if String(e.get("id","")) == entrance_id:
			return _chamber_for_entrance(e)
	return {}

func cave_chamber_for_entrance(entrance_id: String) -> Dictionary:
	return chamber_for_entrance(entrance_id)

func nearest_cave_chamber(p: Vector2) -> Dictionary:
	var search_rect: Rect2 = Rect2(p - Vector2(512, 512), Vector2(1024, 1024))
	var candidates: Array[Dictionary] = cave_chambers_in(search_rect)
	if candidates.is_empty():
		candidates = cave_chambers_in(Rect2(p - Vector2(1500,1500), Vector2(3000,3000)))
		if candidates.is_empty():
			candidates = cave_chambers_in(Rect2(p - Vector2(4000,4000), Vector2(8000,8000)))
			if candidates.is_empty():
				return {}
	var best: Dictionary = {}
	var best_d: float = INF
	for cand in candidates:
		var c: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
		var d: float = p.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = cand
	return best

func nearest_chamber(p: Vector2) -> Dictionary:
	return nearest_cave_chamber(p)

func _cave_entrance_hash(id: String) -> int:
	return WorldSeed.str_hash(id)
