class_name FringePlan
extends RefCounted
## Pure deterministic city-fringe composition system.
## Generates gradually expanding urban fabric 300-1200 m deformed by roads, terrain, water, noise.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var road_network: RoadNetworkPlan
var city_plan: CityPlan

var _buildings: Array[Dictionary] = []
var _by_id: Dictionary = {}
var _landmarks: Array[Dictionary] = []
var _by_landmark: Dictionary = {}
var _walls: Array[Dictionary] = []
var _yards: Array[Dictionary] = []
var _trees: Array[Dictionary] = []

static var _cache: Dictionary = {}
var _generated: bool = false

func _ensure_generated() -> void:
	if _generated:
		return
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		var cb: Array = cached.get("buildings", []) as Array
		if cb.size() == 0:
			# Stale empty cache from stub generation — regenerate
			pass # _cache.erase removed to avoid race
		else:
			_buildings = (cached.get("buildings", []) as Array).duplicate()
			_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()
			_landmarks = (cached.get("landmarks", []) as Array).duplicate()
			_by_landmark = (cached.get("by_landmark", {}) as Dictionary).duplicate()
			_walls = (cached.get("walls", []) as Array).duplicate()
			_yards = (cached.get("yards", []) as Array).duplicate()
			_trees = (cached.get("trees", []) as Array).duplicate()
			_generated = true
			return
	_generate()
	_generated = true
	var bylm_copy := {}
	for k in _by_landmark.keys():
		bylm_copy[k] = (_by_landmark[k] as Dictionary).duplicate()
	_cache[seed_used] = {"buildings": _buildings.duplicate(), "by_id": _by_id.duplicate(), "landmarks": _landmarks.duplicate(), "by_landmark": bylm_copy, "walls": _walls.duplicate(), "yards": _yards.duplicate(), "trees": _trees.duplicate()}
 # seed -> {buildings, by_id, landmarks, walls, yards, trees}

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

static func _sample_coherent_with_seed(p: Vector2, domain: StringName, cell_size: float, seed: int) -> float:
	return WorldSeed.sample_coherent(p, domain, cell_size, seed)

static func _sample_coherent_signed_with_seed(p: Vector2, domain: StringName, cell_size: float, seed: int) -> float:
	return WorldSeed.sample_coherent_signed(p, domain, cell_size, seed)

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null, settlement_plan: SettlementPlan = null, road_network_plan: RoadNetworkPlan = null, city_plan_ref: CityPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)
	biome = biome_plan if biome_plan != null else BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = settlement_plan if settlement_plan != null else SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	road_network = road_network_plan if road_network_plan != null else RoadNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement)
	city_plan = city_plan_ref if city_plan_ref != null else CityPlan.new()
	# Ensure deterministic seed_used matches CityPlan's seed? CityPlan uses WorldSeed.get_world_seed() internally but we use same seed
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		var cb2: Array = cached.get("buildings", []) as Array
		if cb2.size() == 0:
			pass # _cache.erase removed to avoid race
		else:
			_buildings = (cached.get("buildings", []) as Array).duplicate()
			_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()
			_landmarks = (cached.get("landmarks", []) as Array).duplicate()
			_by_landmark = (cached.get("by_landmark", {}) as Dictionary).duplicate()
			_walls = (cached.get("walls", []) as Array).duplicate()
			_yards = (cached.get("yards", []) as Array).duplicate()
			_trees = (cached.get("trees", []) as Array).duplicate()
			_generated = true
			return
	# Defer heavy generation until first query (lazy) to keep WorldPlan construction cheap for tests not needing fringe
	_generated = false
	var bylm_copy := {}
	for k in _by_landmark.keys():
		bylm_copy[k] = (_by_landmark[k] as Dictionary).duplicate()
	_cache[seed_used] = {"buildings": _buildings.duplicate(), "by_id": _by_id.duplicate(), "landmarks": _landmarks.duplicate(), "by_landmark": bylm_copy, "walls": _walls.duplicate(), "yards": _yards.duplicate(), "trees": _trees.duplicate()}

# --- Density deformation ---
func fringe_density_at(p: Vector2) -> float:
	var d: float = p.length()
	if d < 220.0:
		return 0.0
	if d > WorldConstants.FRINGE_MAX_M:
		return 0.0
	# Base radial: high near 300, tapers to 0 near 1200
	var t: float = clampf((d - WorldConstants.FRINGE_INNER_START_M) / (WorldConstants.FRINGE_PERI_END_M - WorldConstants.FRINGE_INNER_START_M), 0.0, 1.0)
	# Smoothstep S-curve
	var s: float = t * t * (3.0 - 2.0 * t)
	var base: float = 1.0 - s
	# Boost inner band slightly: plateau 300-400 = 1, then curve
	if d < WorldConstants.FRINGE_INNER_END_M:
		base = lerpf(1.0, base, clampf((d - 340.0) / 210.0, 0.0, 1.0))
	# Road proximity factor
	var dr: float = road_network.distance_to_road(p)
	var road_mix: float = clampf(1.0 - dr / WorldConstants.FRINGE_ROAD_INFLUENCE_M, 0.0, 1.0)
	var hier: StringName = road_network.road_hierarchy_at(p)
	var hier_bonus: float = 0.0
	match hier:
		&"primary":
			hier_bonus = 0.35
		&"secondary":
			hier_bonus = 0.18
		&"track":
			hier_bonus = 0.0
		_:
			hier_bonus = 0.0
	var road_factor: float = 0.62 + 0.55 * road_mix + hier_bonus * road_mix
	road_factor = clampf(road_factor, 0.45, 1.45)
	# Slope factor
	var slope: float = terrain.slope_at(p)
	var slope_factor: float = 1.0
	if slope >= WorldConstants.FRINGE_SLOPE_MAX_DEG_OUTER:
		slope_factor = 0.0
	elif slope >= 16.0:
		slope_factor = clampf((WorldConstants.FRINGE_SLOPE_MAX_DEG_OUTER - slope) / 6.0, 0.0, 1.0) * 0.7 + 0.1
	elif slope >= 12.0:
		slope_factor = 0.75 + (16.0 - slope) / 16.0 * 0.25
	else:
		slope_factor = 1.0
	# Water factor
	var dist_water: float = hydrology.distance_to_water(p)
	var is_fp: bool = hydrology.is_floodplain(p)
	var body: StringName = hydrology.water_body_at(p)
	var water_factor: float = 1.0
	if body != &"" or is_fp:
		water_factor = 0.0
	elif dist_water <= WorldConstants.FRINGE_WATER_GAP:
		water_factor = 0.0
	elif dist_water <= WorldConstants.FRINGE_WATER_GAP + 8.0:
		water_factor = (dist_water - WorldConstants.FRINGE_WATER_GAP) / 8.0 * 0.4
	elif dist_water <= WorldConstants.FRINGE_WATER_GAP + 26.0:
		water_factor = 0.4 + (dist_water - WorldConstants.FRINGE_WATER_GAP - 8.0) / 18.0 * 0.6
	else:
		water_factor = 1.0
	# Coherent noise deformation: fingers
	var n1: float = _sample_coherent_signed_with_seed(p, &"fringe_deform", WorldConstants.FRINGE_DENSITY_NOISE_CELL, seed_used)
	var n2: float = _sample_coherent_with_seed(p * 0.7 + Vector2(400, -200), &"fringe_density", WorldConstants.FRINGE_DENSITY_NOISE_CELL * 1.6, seed_used)
	var deform: float = n1 * WorldConstants.FRINGE_DENSITY_NOISE_AMPL
	# Second noise adds industrial corridor bias along primary roads: enhance where near primary
	if hier == &"primary" and road_mix > 0.4:
		deform += (n2 - 0.5) * 0.12 + 0.08
	else:
		deform += (n2 - 0.5) * 0.10
	var density: float = base * road_factor * slope_factor * water_factor * (1.0 + deform)
	# Ensure industrial corridors slightly higher
	if biome.is_industrial(p) and d > 400.0 and d < 950.0 and dr < 70.0:
		density *= 1.18
	density = clampf(density, 0.0, 1.0)
	# Slight boost for hill-side avoidance: upland forest reduces? Let forest reduce peri density but not inner (urban cuts through)
	var b: StringName = biome.biome_at(p)
	if b == &"deciduous_forest" or b == &"mixed_upland_forest":
		if d > 700.0:
			density *= 0.65
		elif d > 500.0:
			density *= 0.85
	return density

func fringe_type_at(p: Vector2) -> StringName:
	var dens: float = fringe_density_at(p)
	if dens >= WorldConstants.FRINGE_INNER_DENSITY_THRESHOLD:
		return &"inner_fringe"
	elif dens >= WorldConstants.FRINGE_OUTER_DENSITY_THRESHOLD:
		return &"outer_fringe"
	elif dens >= WorldConstants.FRINGE_PERI_DENSITY_THRESHOLD:
		return &"peri_urban"
	else:
		return &"rural"

# --- Helpers ---
func _effective_footprint(fp: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(fp.y, fp.x)
	return fp

func _aabb_for(center: Vector2, fp: Vector2, yaw: float) -> Rect2:
	var eff := _effective_footprint(fp, yaw)
	return Rect2(center - eff * 0.5, eff)

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

func _nearest_road_tangent(p: Vector2) -> Vector2:
	if road_network == null:
		return Vector2.ZERO
	var rect := Rect2(p - Vector2(60, 60), Vector2(120, 120))
	var segs: Array[Dictionary] = road_network.road_segments_in(rect)
	if segs.is_empty():
		return Vector2.ZERO
	var best_dist := INF
	var best_tangent := Vector2.ZERO
	for seg in segs:
		var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
		if poly.size() < 2:
			continue
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 < 1e-6:
				continue
			var t: float = (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d: float = p.distance_to(proj)
			if d < best_dist:
				best_dist = d
				best_tangent = ab
	return best_tangent

func _yaw_for(p: Vector2, id_hash: int, k: int, fringe_type: StringName) -> float:
	var dr: float = road_network.distance_to_road(p) if road_network != null else INF
	if dr < 44.0:
		var tang := _nearest_road_tangent(p)
		if tang.length_squared() > 1e-6:
			var ang: float = atan2(tang.y, tang.x)
			var q: float = round(ang / (PI * 0.5)) * (PI * 0.5)
			q = wrapf(q, -PI, PI)
			if is_equal_approx(absf(q), PI):
				q = PI
			# Slight jitter for variety inner vs outer
			var jit: float = _unit_float_with_seed("fringe_yaw", [id_hash, k, 99], seed_used) * 0.12 - 0.06
			if fringe_type == &"inner_fringe":
				# Keep strict for row frontage
				return q
			else:
				return q + jit
	var rf: float = _unit_float_with_seed("fringe_yaw", [id_hash, k], seed_used)
	var idx: int = int(floor(rf * 4.0)) % 4
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

func _footprint_for_arch(arch: StringName, id_hash: int, k: int) -> Vector2:
	var r_x: float = _unit_float_with_seed("fringe_fp_x", [id_hash, k], seed_used)
	var r_y: float = _unit_float_with_seed("fringe_fp_y", [id_hash, k], seed_used)
	var pair: Array = WorldConstants.FRINGE_ARCHETYPE_FOOTPRINTS.get(arch, [Vector2(7,8), Vector2(10,12)]) as Array
	var minv: Vector2 = pair[0] as Vector2
	var maxv: Vector2 = pair[1] as Vector2
	return Vector2(lerpf(minv.x, maxv.x, r_x), lerpf(minv.y, maxv.y, r_y))

func _floors_for_arch(arch: StringName, id_hash: int, k: int) -> int:
	var range_v: Vector2i = WorldConstants.FRINGE_ARCHETYPE_FLOORS.get(arch, Vector2i(1,2)) as Vector2i
	if range_v.x == range_v.y:
		return range_v.x
	var r: float = _unit_float_with_seed("fringe_arch", [id_hash, k, 77], seed_used)
	return range_v.x + int(floor(r * float(range_v.y - range_v.x + 1))) - (1 if r > 0.98 else 0)

func _choose_arch(fringe_type: StringName, road_hier: StringName, dist_to_road: float, id_hash: int, k: int, density: float) -> StringName:
	var r: float = _unit_float_with_seed("fringe_arch", [id_hash, k], seed_used)
	# Adjust weights per type + road influence
	var weights: Dictionary = {}
	match fringe_type:
		&"inner_fringe":
			weights = {
				&"worker_row_house": 0.30,
				&"small_tenement": 0.25,
				&"detached_cottage": 0.10,
				&"workshop": 0.14,
				&"warehouse": 0.05,
				&"small_factory": 0.03,
				&"industrial_shed": 0.02,
				&"courtyard_house": 0.05,
				&"roadside_inn": 0.04,
				&"utility_building": 0.02,
			}
			if road_hier == &"primary" and dist_to_road < 30.0:
				# Industrial bias along primary in inner fringe
				weights[&"warehouse"] = 0.08
				weights[&"small_factory"] = 0.05
				weights[&"workshop"] = 0.18
				weights[&"detached_cottage"] = 0.05
		&"outer_fringe":
			weights = {
				&"worker_row_house": 0.14,
				&"small_tenement": 0.08,
				&"detached_cottage": 0.24,
				&"workshop": 0.16,
				&"warehouse": 0.12,
				&"small_factory": 0.08,
				&"industrial_shed": 0.08,
				&"courtyard_house": 0.04,
				&"roadside_inn": 0.03,
				&"utility_building": 0.03,
			}
			if road_hier == &"primary":
				weights[&"small_factory"] = 0.11
				weights[&"warehouse"] = 0.15
		&"peri_urban":
			weights = {
				&"worker_row_house": 0.05,
				&"small_tenement": 0.02,
				&"detached_cottage": 0.30,
				&"workshop": 0.10,
				&"warehouse": 0.05,
				&"small_factory": 0.05,
				&"industrial_shed": 0.10,
				&"courtyard_house": 0.05,
				&"roadside_inn": 0.10,
				&"utility_building": 0.18,
			}
			if road_hier == &"track" and dist_to_road < 22.0:
				weights[&"detached_cottage"] = 0.36
				weights[&"utility_building"] = 0.20
		_:
			weights = {&"detached_cottage": 1.0}
	var acc: float = 0.0
	# Normalize
	var total: float = 0.0
	for w in weights.values():
		total += float(w)
	var target: float = r * total
	for arch in WorldConstants.FRINGE_ARCHETYPES:
		var w: float = float(weights.get(arch, 0.0))
		acc += w
		if target <= acc + 1e-6:
			return arch
	return &"detached_cottage"

func _palette_for_arch(arch: StringName, id_hash: int, k: int) -> Dictionary:
	var r: float = _unit_float_with_seed("fringe_palette", [id_hash, k], seed_used)
	var wall := Color("d8cfc0")
	var roof := Color("a34a30")
	match arch:
		&"worker_row_house":
			if r < 0.45:
				wall = Color("ddd0c0")
			elif r < 0.75:
				wall = Color("c9a86b")
			else:
				wall = Color("a8b39a")
			roof = Color("a34a30") if r < 0.75 else Color("6e5550")
		&"small_tenement":
			if r < 0.35:
				wall = Color("d8cfc0")
			elif r < 0.68:
				wall = Color("c4938a")
			else:
				wall = Color("a9b6bb")
			roof = Color("8f4630")
		&"detached_cottage":
			if r < 0.60:
				wall = Color("ddd0c0")
			elif r < 0.84:
				wall = Color("b07a5a")
			else:
				wall = Color("7a5a3a")
			roof = Color("a34a30")
		&"workshop":
			wall = Color("b07a5a") if r < 0.55 else Color("a8a098")
			roof = Color("6e5550") if r < 0.60 else Color("5a5a5a")
		&"warehouse":
			wall = Color("9e968a") if r < 0.60 else Color("7a7a78")
			roof = Color("6e5550")
		&"small_factory":
			wall = Color("8a3a2a") if r < 0.45 else Color("7a6a6a")
			if r < 0.50:
				wall = Color("8b3a2a")
			roof = Color("5a5a5a") if r < 0.65 else Color("6e5550")
		&"industrial_shed":
			wall = Color("7a7a78") if r < 0.60 else Color("6b6f73")
			roof = Color("5a5a5a")
		&"courtyard_house":
			if r < 0.50:
				wall = Color("ddd0c0")
			elif r < 0.78:
				wall = Color("c9a86b")
			else:
				wall = Color("b3aca1")
			roof = Color("a34a30")
		&"roadside_inn":
			wall = Color("c9a86b") if r < 0.55 else Color("d8cfc0")
			roof = Color("a34a30")
		&"utility_building":
			wall = Color("7a5a3a") if r < 0.60 else Color("6b4b32")
			roof = Color("5a5a5a")
		_:
			wall = Color("ddd0c0")
			roof = Color("a34a30")
	return {"wall": wall, "roof": roof}

func _door_for_building(center: Vector2, footprint: Vector2, yaw: float, road_pos: Vector2, settlement_center: Vector2, id_hash: int, k: int) -> Dictionary:
	var hx_local: float = footprint.x * 0.5
	var hz_local: float = footprint.y * 0.5
	var cos_y: float = cos(yaw)
	var sin_y: float = sin(yaw)
	var lx_arr: Array[float] = [hx_local, -hx_local, 0.0, 0.0]
	var lz_arr: Array[float] = [0.0, 0.0, hz_local, -hz_local]
	var nx_arr: Array[float] = [1.0, -1.0, 0.0, 0.0]
	var nz_arr: Array[float] = [0.0, 0.0, 1.0, -1.0]
	var edges: Array[Dictionary] = []
	for ei in 4:
		var lx: float = lx_arr[ei]
		var lz: float = lz_arr[ei]
		var wx: float = lx * cos_y - lz * sin_y
		var wz: float = lx * sin_y + lz * cos_y
		var edge_center := center + Vector2(wx, wz)
		var nx: float = nx_arr[ei]
		var nz: float = nz_arr[ei]
		var nwx: float = nx * cos_y - nz * sin_y
		var nwz: float = nx * sin_y + nz * cos_y
		var normal := Vector2(nwx, nwz).normalized()
		edges.append({"center": edge_center, "normal": normal})
	var dist_road: float = road_network.distance_to_road(center) if road_network != null else INF
	var use_road: bool = dist_road < 26.0
	var target_dir: Vector2
	if use_road and road_pos != Vector2.INF:
		target_dir = (road_pos - center)
		if target_dir.length_squared() < 1e-6:
			target_dir = settlement_center - center
	else:
		target_dir = settlement_center - center
	if target_dir.length_squared() < 1e-6:
		var r_sel: float = _unit_float_with_seed("fringe_palette", [id_hash, k, 88], seed_used)
		var idx2: int = int(floor(r_sel * 4.0)) % 4
		var chosen: Dictionary = edges[idx2]
		var door_pos: Vector2 = chosen["center"] as Vector2
		var door_normal: Vector2 = chosen["normal"] as Vector2
		var door_yaw: float = atan2(door_normal.y, door_normal.x)
		return {"pos": door_pos, "yaw": door_yaw, "edge_idx": idx2, "faces_road": use_road}
	target_dir = target_dir.normalized()
	var best_dot := -INF
	var best_idx := 0
	for ei in edges.size():
		var n: Vector2 = edges[ei]["normal"] as Vector2
		var d: float = n.dot(target_dir)
		if d > best_dot:
			best_dot = d
			best_idx = ei
	var best_edge: Dictionary = edges[best_idx]
	var door_pos2: Vector2 = best_edge["center"] as Vector2
	var door_normal2: Vector2 = best_edge["normal"] as Vector2
	var door_yaw2: float = atan2(door_normal2.y, door_normal2.x)
	return {"pos": door_pos2, "yaw": door_yaw2, "edge_idx": best_idx, "faces_road": use_road}

func _nearest_road_point(p: Vector2) -> Vector2:
	if road_network == null:
		return Vector2.INF
	var rect := Rect2(p - Vector2(50, 50), Vector2(100, 100))
	var segs: Array[Dictionary] = road_network.road_segments_in(rect)
	if segs.is_empty():
		return Vector2.INF
	var best_dist := INF
	var best_pt := Vector2.INF
	for seg in segs:
		var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i+1]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 < 1e-6:
				continue
			var t: float = (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d: float = p.distance_squared_to(proj)
			if d < best_dist:
				best_dist = d
				best_pt = proj
	return best_pt

func _road_sample_along_segment(seg: Dictionary, t: float) -> Dictionary:
	var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
	if poly.size() < 2:
		return {"pos": poly[0] if poly.size()>0 else Vector2.ZERO, "tangent": Vector2(1,0)}
	var total_len: float = 0.0
	var seg_lens: Array[float] = []
	for i in range(poly.size()-1):
		var l: float = poly[i].distance_to(poly[i+1])
		seg_lens.append(l)
		total_len += l
	if total_len < 1e-4:
		return {"pos": poly[0], "tangent": (poly[1]-poly[0]).normalized()}
	var target: float = t * total_len
	var acc: float = 0.0
	for i in seg_lens.size():
		var l: float = seg_lens[i]
		if acc + l >= target - 1e-4:
			var rem: float = target - acc
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i+1]
			var ab := b - a
			var pos: Vector2 = a + ab.normalized() * rem if ab.length_squared() > 1e-6 else a
			var tang: Vector2 = ab.normalized() if ab.length_squared() > 1e-6 else Vector2(1,0)
			return {"pos": pos, "tangent": tang}
		acc += l
	return {"pos": poly[poly.size()-1], "tangent": (poly[poly.size()-1]-poly[poly.size()-2]).normalized()}

# --- Generation ---
func _generate() -> void:
	_buildings.clear()
	_by_id.clear()
	_landmarks.clear()
	_by_landmark.clear()
	_walls.clear()
	_yards.clear()
	_trees.clear()
	var all_fringe_buildings: Array[Dictionary] = []
	var all_walls: Array[Dictionary] = []
	var all_yards: Array[Dictionary] = []
	var all_trees: Array[Dictionary] = []
	var cell_min: int = -32 # 8192/256=32
	var cell_max: int = 32
	var hash_to_cell: Dictionary = {}
	# First pass: collect candidate building positions per cell
	for cx in range(cell_min, cell_max):
		for cy in range(cell_min, cell_max):
			var cell_origin := Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
			var cell_center := cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M * 0.5, WorldConstants.LANDSCAPE_CELL_M * 0.5)
			var cell_rect := Rect2(cell_origin, Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M))
			if not WorldConstants.is_inside_world(cell_center):
				continue
			var d_center: float = cell_center.length()
			if d_center < 220.0 or d_center > WorldConstants.FRINGE_MAX_M + 180.0:
				continue
			var dens_center: float = fringe_density_at(cell_center)
			if dens_center < WorldConstants.FRINGE_PERI_DENSITY_THRESHOLD - 0.02:
				continue
			# Also skip cells that are deep inside forest/upland where slope high and no road
			# but fringe_density already handles
			var fringe_type_center: StringName = fringe_type_at(cell_center)
			var count_needed: int = 0
			var r_cnt: float = _unit_float_with_seed("fringe_density", [cx, cy], seed_used)
			match fringe_type_center:
				&"inner_fringe":
					count_needed = 3 + int(floor(r_cnt * 5.0)) # 3-7
					count_needed = clampi(count_needed, 3, 7)
				&"outer_fringe":
					count_needed = 2 + int(floor(r_cnt * 3.0)) # 2-4
					count_needed = clampi(count_needed, 2, 4)
				&"peri_urban":
					count_needed = 1 + int(floor(r_cnt * 2.0)) # 1-2
					count_needed = clampi(count_needed, 1, 2)
				_:
					continue
			# If cell has no road within 90 and is peri, reduce to 0-1
			var dr_cell: float = road_network.distance_to_road(cell_center)
			if dr_cell > 90.0 and fringe_type_center == &"peri_urban":
				if r_cnt < 0.55:
					count_needed = maxi(0, count_needed - 1)
			if count_needed <= 0:
				continue
			# Get road segments in and around cell for frontage
			var expanded_rect := cell_rect.grow(48.0)
			var road_segs: Array[Dictionary] = road_network.road_segments_in(expanded_rect)
			# Deterministic sort
			road_segs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
			var id_hash_base: int = WorldSeed.combine([seed_used, WorldSeed.str_hash("fringe_density"), cx, cy])
			hash_to_cell[id_hash_base] = Vector2i(cx, cy)
			# Track placed in this cell for intra-cell spacing
			var placed_in_cell: Array[Dictionary] = []
			for k in count_needed:
				var attempt_ok := false
				var building: Dictionary = {}
				for attempt in 8:
					var arch: StringName = &"detached_cottage"
					var footprint: Vector2 = Vector2(8,10)
					var yaw: float = 0.0
					var center: Vector2 = Vector2.ZERO
					# Sample arch
					var hier_at_center: StringName = road_network.road_hierarchy_at(cell_center)
					var dr_for_arch: float = dr_cell
					# If road segs exist, pick one deterministically
					var seg_for_sample: Dictionary = {}
					var use_road_sample := false
					if not road_segs.is_empty():
						var idx: int = (id_hash_base + k + attempt * 11) % road_segs.size()
						seg_for_sample = road_segs[idx]
						use_road_sample = true
					var t_along: float = _unit_float_with_seed("fringe_fp_x", [id_hash_base, k, attempt, 0], seed_used)
					var side_choice: float = _unit_float_with_seed("fringe_fp_y", [id_hash_base, k, attempt, 1], seed_used)
					var offset_jitter: float = _unit_float_with_seed("fringe_yaw", [id_hash_base, k, attempt, 2], seed_used) * 1.0 - 0.5
					# Determine a sample point along road or cell jitter if no road
					var sample_pos: Vector2 = Vector2.ZERO
					var sample_tangent: Vector2 = Vector2.ZERO
					if use_road_sample:
						var samp: Dictionary = _road_sample_along_segment(seg_for_sample, t_along)
						sample_pos = samp["pos"] as Vector2
						sample_tangent = samp["tangent"] as Vector2
						# Clamp sample_pos to be within cell_rect expanded? For peri we allow up to grow 48, but final center must be inside world
						# Choose side offset
						var perp := Vector2(-sample_tangent.y, sample_tangent.x).normalized()
						if perp.length_squared() < 1e-6:
							perp = Vector2(0,1)
						var side_sign: float = 1.0 if side_choice < 0.5 else -1.0
						# Width of road segment
						var seg_width: float = float(seg_for_sample.get("width", 5.0))
						var f_type_tmp: StringName = fringe_type_at(sample_pos)
						var base_setback: float = WorldConstants.FRINGE_ROAD_SETBACK_INNER
						match f_type_tmp:
							&"outer_fringe":
								base_setback = WorldConstants.FRINGE_ROAD_SETBACK_OUTER
							&"peri_urban":
								base_setback = WorldConstants.FRINGE_ROAD_SETBACK_PERI
							_:
								base_setback = WorldConstants.FRINGE_ROAD_SETBACK_INNER
						# Determine arch and footprint first to know depth
						# Need density for arch selection at this sample pos? Use fringe_density at sample_pos
						var dens_at_sample: float = fringe_density_at(sample_pos)
						var ftype_at_sample: StringName = fringe_type_at(sample_pos)
						var hier_at_sample: StringName = seg_for_sample.get("hierarchy", &"track") as StringName
						var dr_at_sample: float = road_network.distance_to_road(sample_pos)
						arch = _choose_arch(ftype_at_sample, hier_at_sample, dr_at_sample, id_hash_base, k + attempt * 7, dens_at_sample)
						footprint = _footprint_for_arch(arch, id_hash_base, k + attempt * 13)
						# Estimate yaw: align to road
						yaw = _yaw_for(sample_pos, id_hash_base, k, ftype_at_sample)
						var eff := _effective_footprint(footprint, yaw)
						# Offset includes road half width + setback + half footprint depth perpendicular + small jitter
						var lateral_offset: float = seg_width * 0.5 + base_setback + eff.y * 0.5 + offset_jitter
						# For inner row houses, reduce lateral gap to make tighter frontage: subtract 0.8
						if arch == &"worker_row_house" and ftype_at_sample == &"inner_fringe":
							lateral_offset -= 0.6
						center = sample_pos + perp * side_sign * lateral_offset
					else:
						# No road: place in cell with polar jitter around center (for inner dense blocks off road but still near)
						var rx: float = _unit_float_with_seed("fringe_fp_x", [id_hash_base, k, attempt, 3], seed_used)
						var ry: float = _unit_float_with_seed("fringe_fp_y", [id_hash_base, k, attempt, 4], seed_used)
						var offset := Vector2(lerpf(-WorldConstants.LANDSCAPE_CELL_M*0.38, WorldConstants.LANDSCAPE_CELL_M*0.38, rx), lerpf(-WorldConstants.LANDSCAPE_CELL_M*0.38, WorldConstants.LANDSCAPE_CELL_M*0.38, ry))
						center = cell_center + offset
						var ftype_at_c: StringName = fringe_type_at(center)
						var dens_c: float = fringe_density_at(center)
						arch = _choose_arch(ftype_at_c, &"track", 999.0, id_hash_base, k + attempt * 7, dens_c)
						footprint = _footprint_for_arch(arch, id_hash_base, k + attempt * 13)
						yaw = _yaw_for(center, id_hash_base, k, ftype_at_c)
					# Validate center is inside world and fringe annulus
					if not WorldConstants.is_inside_world(center):
						continue
					var d_len: float = center.length()
					if d_len < 250.0 or d_len > WorldConstants.FRINGE_MAX_M:
						continue
					# Slope / water gates
					var ftype_check: StringName = fringe_type_at(center)
					var slope: float = terrain.slope_at(center)
					var slope_max: float = WorldConstants.FRINGE_SLOPE_MAX_DEG_INNER
					match ftype_check:
						&"outer_fringe":
							slope_max = WorldConstants.FRINGE_SLOPE_MAX_DEG_OUTER
						&"peri_urban":
							slope_max = WorldConstants.FRINGE_SLOPE_MAX_DEG_PERI
					if slope >= slope_max + 0.5:
						continue
					if terrain.terrain_class_at(center) == &"cliff":
						continue
					var body: StringName = hydrology.water_body_at(center)
					if body != &"":
						continue
					if hydrology.is_floodplain(center):
						continue
					var dist_w: float = hydrology.distance_to_water(center)
					if dist_w <= WorldConstants.FRINGE_WATER_GAP + 0.5:
						continue
					var dist_r: float = road_network.distance_to_road(center)
					# For buildings that were placed via road offset, dist_r should be ~setback+eff.y*0.5, which passes setback check below
					# Apply road setback minimum: use building's actual aabb edge distance? Approximate via center distance
					var setback_needed: float = WorldConstants.FRINGE_ROAD_SETBACK_INNER
					match ftype_check:
						&"outer_fringe":
							setback_needed = WorldConstants.FRINGE_ROAD_SETBACK_OUTER - 0.5 # allow 0.5 tolerance
						&"peri_urban":
							setback_needed = WorldConstants.FRINGE_ROAD_SETBACK_PERI - 0.5
					# If near bridge, need extra check is_bridge via hydrology? Road setback includes bridge decks water already excluded, but also check not on bridge
					var is_on_bridge := false
					# Check road segments for bridge overlap: if any bridge segment poly within 8m and over water
					var check_rect := Rect2(center - Vector2(12,12), Vector2(24,24))
					var segs_check: Array[Dictionary] = road_network.road_segments_in(check_rect)
					for seg in segs_check:
						if bool(seg.get("is_bridge", false)):
							var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
							for i in range(poly.size()-1):
								var a: Vector2 = poly[i]
								var bb: Vector2 = poly[i+1]
								var ab := bb - a
								var len2: float = ab.length_squared()
								if len2 < 1e-6: continue
								var t: float = (center - a).dot(ab) / len2
								t = clampf(t, 0.0, 1.0)
								var proj := a + ab * t
								if center.distance_to(proj) < float(seg.get("width", 7.0))*0.5 + 2.5 and hydrology.water_body_at(proj) != &"":
									is_on_bridge = true
									break
							if is_on_bridge: break
					if is_on_bridge:
						continue
					# Aabb for this candidate
					var aabb := _aabb_for(center, footprint, yaw)
					# No overlap with rural buildings (settlement clustered)
					var overlaps_rural := false
					# Rural building plan check via world? We have no direct rural world here but we can query via road_network's settlement? Instead use generic distance to rural settlement? We'll check via a coarse check: if center within 80 of any hamlet center and rural buildings likely, we check via internal rural building spacing: use settlement anchors distance? Simpler: check against already placed fringe but also against rural via querying WorldPlan later? For now check against fringe only and city. Rural overlap will be checked later via FringePlan post-filter using WorldPlan.rural_buildings_in? But we don't have world_plan here directly? We have settlement. We can approximate by ensuring distance to nearest settlement center > settlement radius+10 if that settlement is village/hamlet with high rural density? But spec says fringe buildings must avoid overlaps but become progressively separated farther outward; rural buildings are outside fringe? Overlap possible near peri where rural hamlets meet fringe. We'll enforce minimum 12m from any settlement center that has rural buildings? Instead check via _aabb_gap with rural buildings via generating rural building list? We can lazily skip this and catch in second pass via global dedup with rural. For now enforce gap to settlement center: if nearest settlement distance < settlement.radius + 8 and that settlement is village/hamlet, reduce chance? We'll just enforce building not inside settlement bounds.
					var nearest_sett: Dictionary = settlement.nearest_settlement(center)
					if not nearest_sett.is_empty():
						var s_center: Vector2 = nearest_sett["center"] as Vector2
						var s_radius: float = float(nearest_sett.get("radius", 30.0))
						var s_kind: StringName = nearest_sett["kind"] as StringName
						var dist_to_sett: float = center.distance_to(s_center)
						if s_kind == &"village" or s_kind == &"hamlet":
							# If inside village/hamlet bounds expanded 10, skip (let rural handle)
							if dist_to_sett < s_radius + 9.0:
								# allow but with 50% chance skip to avoid clutter? Use deterministic skip via hash
								var skip_r: float = _unit_float_with_seed("fringe_secondary", [id_hash_base, k, attempt, 9], seed_used)
								if skip_r < 0.68:
									continue
					# No overlap with city blocks: check CityPlan buildings_in_rect
					var city_overlaps := false
					var city_rect := Rect2(center - Vector2(26,26), Vector2(52,52))
					var city_builds: Array = city_plan.buildings_in_rect(city_rect)
					for cb in city_builds:
						var cr: Rect2 = cb["rect"] as Rect2
						if aabb.grow(1.0).intersects(cr):
							city_overlaps = true
							break
					if city_overlaps:
						continue
					# Gap to already placed fringe in this cell and global
					var gap_needed: float = WorldConstants.FRINGE_BUILDING_GAP_INNER
					match ftype_check:
						&"outer_fringe":
							gap_needed = WorldConstants.FRINGE_BUILDING_GAP_OUTER
						&"peri_urban":
							gap_needed = WorldConstants.FRINGE_BUILDING_GAP_PERI
					var overlaps_fringe := false
					for placed in placed_in_cell:
						var paabb: Rect2 = placed["aabb"] as Rect2
						if _aabb_gap(aabb, paabb) < gap_needed - 0.01:
							overlaps_fringe = true
							break
					if overlaps_fringe:
						continue
					for placed in all_fringe_buildings:
						var paabb2: Rect2 = placed["aabb"] as Rect2
						# Quick distance cull: if centers >80 apart skip
						if center.distance_to(placed["center"] as Vector2) > 80.0:
							continue
						if _aabb_gap(aabb, paabb2) < gap_needed - 0.01:
							overlaps_fringe = true
							break
					if overlaps_fringe:
						continue
					# Height variance check across aabb corners (flatness)
					var corners: Array[Vector2] = [aabb.position, Vector2(aabb.end.x, aabb.position.y), Vector2(aabb.position.x, aabb.end.y), aabb.end, center]
					var min_h: float = INF
					var max_h: float = -INF
					for c in corners:
						var h: float = terrain.height_at(c)
						min_h = minf(min_h, h)
						max_h = maxf(max_h, h)
					if max_h - min_h > 1.2:
						continue
					# Floors and door
					var floors: int = _floors_for_arch(arch, id_hash_base, k)
					var floor_h: float = float(WorldConstants.FRINGE_ARCHETYPE_FLOOR_H.get(arch, 3.0))
					# Workshops/industrial adjust floor_h slightly via palette jitter
					floors = clampi(floors, 1, 4)
					# Ensure has_stairs condition not needed for fringe (single storey ok)
					var height: float = floors * floor_h
					# Door facing road
					var road_pt: Vector2 = _nearest_road_point(center)
					var sett_center: Vector2 = Vector2.ZERO
					if not nearest_sett.is_empty():
						sett_center = nearest_sett["center"] as Vector2
					else:
						sett_center = cell_center
					var door_info: Dictionary = _door_for_building(center, footprint, yaw, road_pt, sett_center, id_hash_base, k)
					var door_pos: Vector2 = door_info["pos"] as Vector2
					var door_yaw: float = float(door_info["yaw"])
					var palette: Dictionary = _palette_for_arch(arch, id_hash_base, k)
					var build_id: String = "fringe_%d_%d_%d" % [cx, cy, k]
					building = {
						"id": build_id,
						"center": center,
						"pos": center,
						"footprint": footprint,
						"yaw": yaw,
						"aabb": aabb,
						"arch": arch,
						"kind": arch,
						"floors": floors,
						"floor_h": floor_h,
						"height": height,
						"door_pos": door_pos,
						"door_yaw": door_yaw,
						"door_edge": int(door_info.get("edge_idx", 0)),
						"faces_road": bool(door_info.get("faces_road", false)),
						"fringe_type": ftype_check,
						"dist_to_road": dist_r,
						"dist_to_water": dist_w,
						"slope_deg": slope,
						"density": fringe_density_at(center),
						"wall_color": palette["wall"],
						"roof_color": palette["roof"],
						"cell": Vector2i(cx, cy),
						"cell_center": cell_center,
						"landmark_id": "",
					}
					attempt_ok = true
					break
				if attempt_ok and not building.is_empty():
					placed_in_cell.append(building)
					all_fringe_buildings.append(building)
			# End for k buildings in cell
	# Second pass: Landmark sparse placement
	var landmark_candidates: Array[Dictionary] = []
	for cx in range(cell_min, cell_max):
		for cy in range(cell_min, cell_max):
			var cell_origin2 := Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
			var cell_center2 := cell_origin2 + Vector2(128,128)
			if not WorldConstants.is_inside_world(cell_center2):
				continue
			var d2: float = cell_center2.length()
			if d2 < WorldConstants.FRINGE_OUTER_START_M - 50.0 or d2 > WorldConstants.FRINGE_PERI_END_M:
				continue
			var dens2: float = fringe_density_at(cell_center2)
			if dens2 < WorldConstants.FRINGE_LANDMARK_DENSITY_THRESHOLD:
				continue
			var dist_road2: float = road_network.distance_to_road(cell_center2)
			if dist_road2 > 48.0:
				continue
			var slope2: float = terrain.slope_at(cell_center2)
			if slope2 >= 18.0:
				continue
			if hydrology.water_body_at(cell_center2) != &"" or hydrology.is_floodplain(cell_center2):
				continue
			var dist_w2: float = hydrology.distance_to_water(cell_center2)
			if dist_w2 <= WorldConstants.FRINGE_WATER_GAP + 2.0:
				continue
			var roll: float = _unit_float_with_seed("fringe_landmark", [cx, cy], seed_used)
			if roll >= WorldConstants.FRINGE_LANDMARK_CHANCE:
				continue
			# Also avoid near settlement village centers dense (market garden exception)
			var nearest: Dictionary = settlement.nearest_settlement(cell_center2)
			if not nearest.is_empty():
				var s_c: Vector2 = nearest["center"] as Vector2
				var s_r: float = float(nearest.get("radius", 30.0))
				if cell_center2.distance_to(s_c) < s_r + 6.0:
					continue
			landmark_candidates.append({"cx": cx, "cy": cy, "center": cell_center2, "dens": dens2, "roll": roll})
	# Greedy spacing 180
	landmark_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["dens"]) != float(b["dens"]):
			return float(a["dens"]) > float(b["dens"])
		return _unit_float_with_seed("fringe_landmark", [int(a["cx"]), int(a["cy"])], seed_used) < _unit_float_with_seed("fringe_landmark", [int(b["cx"]), int(b["cy"])], seed_used)
	)
	var accepted_landmarks: Array[Dictionary] = []
	for cand in landmark_candidates:
		var c: Vector2 = cand["center"] as Vector2
		var too_close := false
		for acc in accepted_landmarks:
			var ac: Vector2 = acc["center"] as Vector2
			if c.distance_to(ac) < WorldConstants.FRINGE_LANDMARK_SPACING_MIN - 1e-3:
				too_close = true
				break
		if too_close:
			continue
		# Also avoid too close to major city core? Already distance gate
		var lm_roll_kind: float = _unit_float_with_seed("fringe_landmark_kind", [int(cand["cx"]), int(cand["cy"])], seed_used)
		var kind_idx: int = int(floor(lm_roll_kind * float(WorldConstants.FRINGE_LANDMARK_VOCAB.size()))) % WorldConstants.FRINGE_LANDMARK_VOCAB.size()
		var lm_kind: StringName = WorldConstants.FRINGE_LANDMARK_VOCAB[kind_idx]
		# Industrial kinds bias near primary roads / industrial biome
		var nearest_hier: StringName = road_network.road_hierarchy_at(c)
		var is_industrial_biome: bool = biome.is_industrial(c)
		if lm_kind == &"factory_compound" or lm_kind == &"warehouse_yard" or lm_kind == &"industrial_chimney":
			if nearest_hier != &"primary" and not is_industrial_biome:
				# Re-roll to more rural landmark with 60% chance
				var reroll: float = _unit_float_with_seed("fringe_landmark_kind", [int(cand["cx"]), int(cand["cy"]), 1], seed_used)
				if reroll < 0.60:
					# pick from rural subset
					var rural_subset: Array[StringName] = [&"mill", &"brick_wall_lot", &"worker_court", &"market_garden", &"roadside_landmark_inn"]
					var r2: float = _unit_float_with_seed("fringe_landmark_kind", [int(cand["cx"]), int(cand["cy"]), 2], seed_used)
					var idx2: int = int(floor(r2 * float(rural_subset.size()))) % rural_subset.size()
					lm_kind = rural_subset[idx2]
		var lm_id: String = "fringe_lm_%d_%d" % [int(cand["cx"]), int(cand["cy"])]
		var lm_dict: Dictionary = {
			"id": lm_id,
			"center": c,
			"kind": lm_kind,
			"cell": Vector2i(int(cand["cx"]), int(cand["cy"])),
			"dens": float(cand["dens"]),
			"aabb": Rect2(c - Vector2(18,14), Vector2(36,28)),
			"yaw": _unit_float_with_seed("fringe_landmark_kind", [int(cand["cx"]), int(cand["cy"]), 9], seed_used) * TAU,
		}
		accepted_landmarks.append(lm_dict)
		if accepted_landmarks.size() >= 40:
			break
	# For each landmark, inject associated buildings / walls / yards
	for lm in accepted_landmarks:
		var lm_center: Vector2 = lm["center"] as Vector2
		var lm_kind: StringName = lm["kind"] as StringName
		var lm_id: String = lm["id"] as String
		var lm_cell: Vector2i = lm["cell"] as Vector2i
		var lm_hash: int = WorldSeed.combine([seed_used, WorldSeed.str_hash("fringe_landmark"), lm_cell.x, lm_cell.y])
		match lm_kind:
			&"factory_compound", &"mill", &"large_workshop":
				# Generate 1 factory + 1-2 warehouses around yard
				var factory_arch: StringName = &"small_factory" if lm_kind == &"factory_compound" else &"workshop"
				if lm_kind == &"mill":
					factory_arch = &"warehouse"
				var f_fp: Vector2 = _footprint_for_arch(factory_arch, lm_hash, 0)
				# Ensure factory size at least 16
				f_fp = Vector2(maxf(f_fp.x, 16.0), maxf(f_fp.y, 14.0))
				var f_yaw: float = _yaw_for(lm_center, lm_hash, 0, &"outer_fringe")
				var f_center: Vector2 = lm_center + Vector2(_unit_float_with_seed("fringe_wall", [lm_hash, 0], seed_used)*6.0-3.0, _unit_float_with_seed("fringe_wall", [lm_hash, 1], seed_used)*6.0-3.0)
				# Validate not overlapping water etc quickly? Use coarse check: if fails, skip this landmark's factory (but keep landmark marker for wall)
				var f_aabb := _aabb_for(f_center, f_fp, f_yaw)
				var f_ok: bool = true
				if hydrology.water_body_at(f_center) != &"" or hydrology.is_floodplain(f_center):
					f_ok = false
				if terrain.slope_at(f_center) >= 18.0 or terrain.terrain_class_at(f_center) == &"cliff":
					f_ok = false
				if f_ok:
					var f_floors: int = 2 if lm_kind == &"factory_compound" else 1
					var f_floor_h: float = float(WorldConstants.FRINGE_ARCHETYPE_FLOOR_H.get(factory_arch, 4.0))
					var palette_f: Dictionary = _palette_for_arch(factory_arch, lm_hash, 0)
					var road_pt_f: Vector2 = _nearest_road_point(f_center)
					var nearest_sett_f: Dictionary = settlement.nearest_settlement(f_center)
					var sett_c_f: Vector2 = nearest_sett_f.get("center", lm_center) as Vector2
					var door_f: Dictionary = _door_for_building(f_center, f_fp, f_yaw, road_pt_f, sett_c_f, lm_hash, 0)
					var bdict_f: Dictionary = {
						"id": "%s_b0" % lm_id,
						"center": f_center,
						"pos": f_center,
						"footprint": f_fp,
						"yaw": f_yaw,
						"aabb": f_aabb,
						"arch": factory_arch,
						"kind": factory_arch,
						"floors": f_floors,
						"floor_h": f_floor_h,
						"height": float(f_floors) * f_floor_h,
						"door_pos": door_f["pos"] as Vector2,
						"door_yaw": float(door_f["yaw"]),
						"door_edge": int(door_f.get("edge_idx",0)),
						"faces_road": bool(door_f.get("faces_road", false)),
						"fringe_type": &"outer_fringe",
						"dist_to_road": road_network.distance_to_road(f_center),
						"dist_to_water": hydrology.distance_to_water(f_center),
						"slope_deg": terrain.slope_at(f_center),
						"density": 0.9,
						"wall_color": palette_f["wall"],
						"roof_color": palette_f["roof"],
						"cell": lm_cell,
						"cell_center": lm_center,
						"landmark_id": lm_id,
						"is_landmark_building": true,
					}
					# Check gap to existing fringe
					var gap_ok_f: bool = true
					for existing in all_fringe_buildings:
						if f_center.distance_to(existing["center"] as Vector2) < 60.0:
							if _aabb_gap(f_aabb, existing["aabb"] as Rect2) < 4.0:
								gap_ok_f = false
								break
					if gap_ok_f:
						all_fringe_buildings.append(bdict_f)
						# Add brick wall enclosure around compound: rect 36x28 centered at lm_center
						var wall_rect := Rect2(lm_center - Vector2(18,14), Vector2(36,28))
						all_walls.append({"id": "%s_wall" % lm_id, "rect": wall_rect, "center": lm_center, "kind": &"brick_wall", "height": WorldConstants.FRINGE_WALL_HEIGHT, "landmark_id": lm_id})
						# Chimney near factory
						var chim_pos: Vector2 = f_center + Vector2( f_fp.x*0.35, f_fp.y*0.2).rotated(f_yaw)
						all_walls.append({"id": "%s_chimney" % lm_id, "pos": chim_pos, "height": WorldConstants.FRINGE_CHIMNEY_HEIGHT, "kind": &"chimney", "landmark_id": lm_id, "radius": 0.9})
				# Also add 1 warehouse nearby if factory succeeded
				if f_ok and all_fringe_buildings.has(all_fringe_buildings[-1] if not all_fringe_buildings.is_empty() else {}):
					var w_arch: StringName = &"warehouse"
					var w_hash: int = lm_hash + 101
					var w_fp: Vector2 = _footprint_for_arch(w_arch, w_hash, 1)
					var w_yaw: float = _yaw_for(lm_center + Vector2(12, -8), w_hash, 1, &"outer_fringe")
					var w_center: Vector2 = lm_center + Vector2(14.0, -10.0).rotated(_unit_float_with_seed("fringe_yaw", [w_hash,1], seed_used)*TAU*0.1)
					var w_aabb := _aabb_for(w_center, w_fp, w_yaw)
					var w_ok: bool = true
					if hydrology.water_body_at(w_center) != &"" or hydrology.is_floodplain(w_center):
						w_ok = false
					if terrain.slope_at(w_center) >= 18.0:
						w_ok = false
					if w_ok:
						var w_floors: int = 1
						var w_floor_h: float = 4.2
						var pal_w: Dictionary = _palette_for_arch(w_arch, w_hash, 1)
						var road_pt_w: Vector2 = _nearest_road_point(w_center)
						var door_w: Dictionary = _door_for_building(w_center, w_fp, w_yaw, road_pt_w, lm_center, w_hash, 1)
						var bdict_w: Dictionary = {
							"id": "%s_b1" % lm_id,
							"center": w_center,
							"pos": w_center,
							"footprint": w_fp,
							"yaw": w_yaw,
							"aabb": w_aabb,
							"arch": w_arch,
							"kind": w_arch,
							"floors": w_floors,
							"floor_h": w_floor_h,
							"height": w_floor_h,
							"door_pos": door_w["pos"] as Vector2,
							"door_yaw": float(door_w["yaw"]),
							"door_edge": int(door_w.get("edge_idx",0)),
							"faces_road": bool(door_w.get("faces_road", false)),
							"fringe_type": &"outer_fringe",
							"dist_to_road": road_network.distance_to_road(w_center),
							"dist_to_water": hydrology.distance_to_water(w_center),
							"slope_deg": terrain.slope_at(w_center),
							"density": 0.9,
							"wall_color": pal_w["wall"],
							"roof_color": pal_w["roof"],
							"cell": lm_cell,
							"cell_center": lm_center,
							"landmark_id": lm_id,
							"is_landmark_building": true,
						}
						var gap_ok_w: bool = true
						for existing in all_fringe_buildings:
							if w_center.distance_to(existing["center"] as Vector2) < 44.0:
								if _aabb_gap(w_aabb, existing["aabb"] as Rect2) < 4.0 and String(existing["id"]) != "%s_b0" % lm_id:
									gap_ok_w = false
									break
						if gap_ok_w:
							all_fringe_buildings.append(bdict_w)
			&"warehouse_yard", &"brick_wall_lot":
				var rect := Rect2(lm_center - Vector2(16,12), Vector2(32,24))
				all_walls.append({"id": "%s_wall" % lm_id, "rect": rect, "center": lm_center, "kind": &"brick_wall", "height": 2.0, "landmark_id": lm_id})
				# 1 warehouse inside
				var w_arch2: StringName = &"warehouse"
				var w_fp2: Vector2 = Vector2(15,13)
				var w_yaw2: float = _yaw_for(lm_center, lm_hash, 2, &"outer_fringe")
				var w_center2: Vector2 = lm_center + Vector2(2,0)
				var w_aabb2 := _aabb_for(w_center2, w_fp2, w_yaw2)
				var pal2: Dictionary = _palette_for_arch(w_arch2, lm_hash, 2)
				var road_pt2: Vector2 = _nearest_road_point(w_center2)
				var door2: Dictionary = _door_for_building(w_center2, w_fp2, w_yaw2, road_pt2, lm_center, lm_hash, 2)
				var bdict2: Dictionary = {
					"id": "%s_b0" % lm_id,
					"center": w_center2,
					"pos": w_center2,
					"footprint": w_fp2,
					"yaw": w_yaw2,
					"aabb": w_aabb2,
					"arch": w_arch2,
					"kind": w_arch2,
					"floors": 1,
					"floor_h": 4.2,
					"height": 4.2,
					"door_pos": door2["pos"] as Vector2,
					"door_yaw": float(door2["yaw"]),
					"door_edge": int(door2.get("edge_idx",0)),
					"faces_road": bool(door2.get("faces_road", false)),
					"fringe_type": &"outer_fringe",
					"dist_to_road": road_network.distance_to_road(w_center2),
					"dist_to_water": hydrology.distance_to_water(w_center2),
					"slope_deg": terrain.slope_at(w_center2),
					"density": 0.8,
					"wall_color": pal2["wall"],
					"roof_color": pal2["roof"],
					"cell": lm_cell,
					"cell_center": lm_center,
					"landmark_id": lm_id,
					"is_landmark_building": true,
				}
				var gap_ok2: bool = true
				for existing in all_fringe_buildings:
					if w_center2.distance_to(existing["center"] as Vector2) < 50.0 and _aabb_gap(w_aabb2, existing["aabb"] as Rect2) < 4.0:
						gap_ok2 = false
						break
				if gap_ok2 and hydrology.water_body_at(w_center2) == &"" and not hydrology.is_floodplain(w_center2):
					all_fringe_buildings.append(bdict2)
			&"industrial_chimney":
				var chim_pos3: Vector2 = lm_center
				all_walls.append({"id": "%s_chimney" % lm_id, "pos": chim_pos3, "height": WorldConstants.FRINGE_CHIMNEY_HEIGHT, "kind": &"chimney", "landmark_id": lm_id, "radius": 1.0})
				var wall_rect3 := Rect2(lm_center - Vector2(10,10), Vector2(20,20))
				all_walls.append({"id": "%s_wall" % lm_id, "rect": wall_rect3, "center": lm_center, "kind": &"brick_wall", "height": 1.6, "landmark_id": lm_id})
			&"worker_court":
				# Dense court: 4 row houses in U
				for i in 4:
					var off := Vector2(cos(float(i)*TAU/4.0), sin(float(i)*TAU/4.0)) * 10.0
					var c: Vector2 = lm_center + off
					if hydrology.water_body_at(c) != &"" or hydrology.is_floodplain(c):
						continue
					if terrain.slope_at(c) >= 18.0:
						continue
					var arch_c: StringName = &"worker_row_house"
					var fp_c: Vector2 = _footprint_for_arch(arch_c, lm_hash + i*17, i)
					var yaw_c: float = _yaw_for(c, lm_hash + i*13, i, &"inner_fringe")
					var aabb_c := _aabb_for(c, fp_c, yaw_c)
					var pal_c: Dictionary = _palette_for_arch(arch_c, lm_hash + i*7, i)
					var road_pt_c: Vector2 = _nearest_road_point(c)
					var door_c: Dictionary = _door_for_building(c, fp_c, yaw_c, road_pt_c, lm_center, lm_hash + i*11, i)
					var bdict_c: Dictionary = {
						"id": "%s_c%d" % [lm_id, i],
						"center": c,
						"pos": c,
						"footprint": fp_c,
						"yaw": yaw_c,
						"aabb": aabb_c,
						"arch": arch_c,
						"kind": arch_c,
						"floors": 2,
						"floor_h": 3.05,
						"height": 6.1,
						"door_pos": door_c["pos"] as Vector2,
						"door_yaw": float(door_c["yaw"]),
						"door_edge": int(door_c.get("edge_idx",0)),
						"faces_road": bool(door_c.get("faces_road", false)),
						"fringe_type": &"inner_fringe",
						"dist_to_road": road_network.distance_to_road(c),
						"dist_to_water": hydrology.distance_to_water(c),
						"slope_deg": terrain.slope_at(c),
						"density": 0.95,
						"wall_color": pal_c["wall"],
						"roof_color": pal_c["roof"],
						"cell": lm_cell,
						"cell_center": lm_center,
						"landmark_id": lm_id,
						"is_landmark_building": true,
					}
					var gap_ok_c: bool = true
					for existing in all_fringe_buildings:
						if c.distance_to(existing["center"] as Vector2) < 30.0 and _aabb_gap(aabb_c, existing["aabb"] as Rect2) < 1.5:
							gap_ok_c = false
							break
					if gap_ok_c:
						all_fringe_buildings.append(bdict_c)
				var wall_rect_c := Rect2(lm_center - Vector2(14,14), Vector2(28,28))
				all_walls.append({"id": "%s_wall" % lm_id, "rect": wall_rect_c, "center": lm_center, "kind": &"brick_wall", "height": 1.8, "landmark_id": lm_id})
			&"market_garden", &"cemetery_edge":
				var yard_rect := Rect2(lm_center - Vector2(18,14), Vector2(36,28))
				all_yards.append({"id": "%s_yard" % lm_id, "rect": yard_rect, "center": lm_center, "kind": lm_kind, "landmark_id": lm_id})
				var wall_garden := Rect2(lm_center - Vector2(18,14), Vector2(36,1.0))
				# For cemetery, wall higher
				var h_wall: float = 2.2 if lm_kind == &"cemetery_edge" else 1.2
				all_walls.append({"id": "%s_wall" % lm_id, "rect": yard_rect, "center": lm_center, "kind": &"fence" if lm_kind == &"market_garden" else &"brick_wall", "height": h_wall, "landmark_id": lm_id})
			&"roadside_landmark_inn", &"mill":
				var arch_m: StringName = &"roadside_inn" if lm_kind == &"roadside_landmark_inn" else &"workshop"
				var fp_m: Vector2 = _footprint_for_arch(arch_m, lm_hash, 0)
				var yaw_m: float = _yaw_for(lm_center, lm_hash, 0, &"outer_fringe")
				var aabb_m := _aabb_for(lm_center, fp_m, yaw_m)
				var pal_m: Dictionary = _palette_for_arch(arch_m, lm_hash, 0)
				var road_pt_m: Vector2 = _nearest_road_point(lm_center)
				var door_m: Dictionary = _door_for_building(lm_center, fp_m, yaw_m, road_pt_m, lm_center, lm_hash, 0)
				var bdict_m: Dictionary = {
					"id": "%s_b0" % lm_id,
					"center": lm_center,
					"pos": lm_center,
					"footprint": fp_m,
					"yaw": yaw_m,
					"aabb": aabb_m,
					"arch": arch_m,
					"kind": arch_m,
					"floors": 2,
					"floor_h": 3.15,
					"height": 6.3,
					"door_pos": door_m["pos"] as Vector2,
					"door_yaw": float(door_m["yaw"]),
					"door_edge": int(door_m.get("edge_idx",0)),
					"faces_road": bool(door_m.get("faces_road", false)),
					"fringe_type": &"outer_fringe",
					"dist_to_road": road_network.distance_to_road(lm_center),
					"dist_to_water": hydrology.distance_to_water(lm_center),
					"slope_deg": terrain.slope_at(lm_center),
					"density": 0.85,
					"wall_color": pal_m["wall"],
					"roof_color": pal_m["roof"],
					"cell": lm_cell,
					"cell_center": lm_center,
					"landmark_id": lm_id,
					"is_landmark_building": true,
				}
				var gap_ok_m: bool = true
				for existing in all_fringe_buildings:
					if lm_center.distance_to(existing["center"] as Vector2) < 40.0 and _aabb_gap(aabb_m, existing["aabb"] as Rect2) < 4.0:
						gap_ok_m = false
						break
				if gap_ok_m and hydrology.water_body_at(lm_center) == &"" and not hydrology.is_floodplain(lm_center):
					all_fringe_buildings.append(bdict_m)
					if lm_kind == &"roadside_landmark_inn":
						all_yards.append({"id": "%s_yard" % lm_id, "rect": Rect2(lm_center - Vector2(8,6), Vector2(16,12)), "center": lm_center, "kind": &"inn_yard", "landmark_id": lm_id})
			_:
				var wall_rect_def := Rect2(lm_center - Vector2(12,10), Vector2(24,20))
				all_walls.append({"id": "%s_wall" % lm_id, "rect": wall_rect_def, "center": lm_center, "kind": &"fence", "height": 1.2, "landmark_id": lm_id})
	# Yard generation for regular fringe buildings (not landmark): create small yard behind row/cottage
	for b in all_fringe_buildings:
		if String(b.get("landmark_id","")) != "":
			continue
		var arch: StringName = b["arch"] as StringName
		if arch == &"worker_row_house" or arch == &"detached_cottage" or arch == &"courtyard_house" or arch == &"roadside_inn":
			var center: Vector2 = b["center"] as Vector2
			var footprint: Vector2 = b["footprint"] as Vector2
			var yaw: float = float(b["yaw"])
			var id: String = String(b["id"])
			var eff := _effective_footprint(footprint, yaw)
			var door_pos: Vector2 = b["door_pos"] as Vector2
			var to_door: Vector2 = door_pos - center
			var back_dir: Vector2 = -to_door.normalized() if to_door.length_squared() > 1e-6 else Vector2(0,1)
			if back_dir.length_squared() < 1e-6:
				back_dir = Vector2(0,1)
			var yard_center: Vector2 = center + back_dir * (eff.y*0.5 + 4.0)
			var yard_size := Vector2(eff.x * 0.9, 6.0)
			# Check not overlapping water or steep
			if hydrology.water_body_at(yard_center) != &"" or hydrology.is_floodplain(yard_center):
				continue
			if terrain.slope_at(yard_center) >= 20.0:
				continue
			var yard_rect := Rect2(yard_center - yard_size*0.5, yard_size)
			# Avoid overlapping other yards/walls?
			all_yards.append({"id": "yard_%s" % id, "rect": yard_rect, "center": yard_center, "kind": &"residential_yard", "building_id": id})
			# Fence around yard: generate wall entries as 4 segments? For chunk builder we expand to walls array as fence segments
			# Add fence wall dict as yard enclosure
			all_walls.append({"id": "fence_%s" % id, "rect": yard_rect, "center": yard_center, "kind": &"fence", "height": 1.3, "building_id": id})
	# Tree scattering near fringe yards/buildings but respecting clearances
	# Deterministic per cell: add 2-5 trees near yards
	for yard in all_yards:
		var yc: Vector2 = yard["center"] as Vector2
		var yid: String = String(yard["id"])
		var hash_y: int = WorldSeed.str_hash(yid)
		var n_tree: int = 2 + int(_unit_float_with_seed("fringe_yard", [hash_y, 0], seed_used) * 3.0) # 2-4
		for t in n_tree:
			var ang: float = _unit_float_with_seed("fringe_yard", [hash_y, t, 1], seed_used) * TAU
			var rad: float = lerpf(4.5, 9.5, _unit_float_with_seed("fringe_yard", [hash_y, t, 2], seed_used))
			var tpos: Vector2 = yc + Vector2(cos(ang), sin(ang)) * rad
			if not WorldConstants.is_inside_world(tpos):
				continue
			if hydrology.water_body_at(tpos) != &"" or hydrology.is_floodplain(tpos):
				continue
			if terrain.slope_at(tpos) >= 22.0 or terrain.terrain_class_at(tpos) == &"cliff":
				continue
			if road_network.distance_to_road(tpos) < WorldConstants.FRINGE_TREE_ROAD_CLEARANCE:
				continue
			var too_close := false
			for ex_tree in all_trees:
				if tpos.distance_to(ex_tree["pos"] as Vector2) < WorldConstants.FRINGE_TREE_MIN_SPACING:
					too_close = true
					break
			if too_close:
				continue
			# Check building clearance
			for b in all_fringe_buildings:
				if tpos.distance_to(b["center"] as Vector2) < WorldConstants.FRINGE_TREE_BUILDING_CLEARANCE + maxf(float(b["footprint"].x), float(b["footprint"].y))*0.4:
					# But yard trees should be near yard; allow 4m clearance from building edge not center? Use aabb gap
					var baabb: Rect2 = b["aabb"] as Rect2
					# Convert tree pos to rect gap: if inside expanded building rect 4m, skip
					if baabb.grow(4.0).has_point(tpos):
						too_close = true
						break
			if too_close:
				continue
			var kind_r: float = _unit_float_with_seed("fringe_yard", [hash_y, t, 3], seed_used)
			var tkind: StringName = &"beech"
			if kind_r < 0.33:
				tkind = &"birch"
			elif kind_r < 0.66:
				tkind = &"pine"
			else:
				tkind = &"beech"
			all_trees.append({"id": "fringe_tree_%s_%d" % [yid, t], "pos": tpos, "kind": tkind, "yard_id": yid})
			if all_trees.size() > 8000:
				break
	# Final sort buildings by id for determinism
	all_fringe_buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	_buildings = all_fringe_buildings
	for b in _buildings:
		_by_id[String(b["id"])] = b
	_landmarks = accepted_landmarks
	for lm in _landmarks:
		_by_landmark[String(lm["id"])] = lm
	_walls = all_walls
	_yards = all_yards
	_trees = all_trees

# --- Public queries ---
func fringe_buildings() -> Array[Dictionary]:
	_ensure_generated()
	return _buildings.duplicate()

func fringe_buildings_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	var grown := rect.grow(2.0)
	for b in _buildings:
		var aabb: Rect2 = b["aabb"] as Rect2
		var c: Vector2 = b["center"] as Vector2
		if aabb.intersects(rect) or grown.has_point(c):
			out.append(b)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func nearest_fringe_building(p: Vector2) -> Dictionary:
	_ensure_generated()
	if _buildings.is_empty():
		return {}
	var best: Dictionary = _buildings[0]
	var best_d2: float = p.distance_squared_to(best["center"] as Vector2)
	for i in range(1, _buildings.size()):
		var b: Dictionary = _buildings[i]
		var d2: float = p.distance_squared_to(b["center"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = b
		elif is_equal_approx(d2, best_d2):
			if String(b["id"]) < String(best["id"]):
				best = b
	return best

func fringe_building_at(p: Vector2) -> Dictionary:
	_ensure_generated()
	for b in _buildings:
		var aabb: Rect2 = b["aabb"] as Rect2
		if aabb.has_point(p):
			return b
	return {}

func building_for_id(bid: String) -> Dictionary:
	_ensure_generated()
	return _by_id.get(bid, {}) as Dictionary

func landmarks() -> Array[Dictionary]:
	_ensure_generated()
	return _landmarks.duplicate()

func landmarks_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for lm in _landmarks:
		var aabb: Rect2 = lm["aabb"] as Rect2
		var c: Vector2 = lm["center"] as Vector2
		if aabb.intersects(rect) or rect.has_point(c):
			out.append(lm)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func walls_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for w in _walls:
		if w.has("rect"):
			var r: Rect2 = w["rect"] as Rect2
			if r.intersects(rect):
				out.append(w)
		elif w.has("pos"):
			var p: Vector2 = w["pos"] as Vector2
			if rect.has_point(p):
				out.append(w)
	return out

func yards_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for y in _yards:
		var r: Rect2 = y["rect"] as Rect2
		if r.intersects(rect):
			out.append(y)
	return out

func trees_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for t in _trees:
		var p: Vector2 = t["pos"] as Vector2
		if rect.has_point(p):
			out.append(t)
	return out
