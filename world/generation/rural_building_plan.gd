class_name RuralBuildingPlan
extends RefCounted
## Pure rural building plan: deterministic low-rise shelters clustered around settlement anchors.
## No Node access, no unseeded randomness, no chunk-local state.
## Generation contract matches SPEC-C005 P4.2 + SPEC-C006 P4.3 interiors.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var road_network: RoadNetworkPlan

var _buildings: Array[Dictionary] = []
var _by_settlement: Dictionary = {} # settlement_id -> Array[Dictionary]
var _by_id: Dictionary = {} # building.id -> Dictionary
var _wells: Array[Dictionary] = []
var _wells_by_settlement: Dictionary = {} # settlement_id -> Array[Dictionary]
var _wells_by_id: Dictionary = {}
var _forage: Array[Dictionary] = []
var _forage_by_id: Dictionary = {}
var _workbenches: Array[Dictionary] = []
var _workbenches_by_settlement: Dictionary = {} # settlement_id -> Array[Dictionary]
var _workbenches_by_id: Dictionary = {} # workbench.id -> Dictionary
var _workbench_by_building: Dictionary = {} # building.id -> Dictionary
var _granaries: Array[Dictionary] = []
var _granaries_by_settlement: Dictionary = {} # settlement_id -> Array[Dictionary]
var _granaries_by_id: Dictionary = {} # granary.id -> Dictionary
var _granary_by_building: Dictionary = {} # building.id -> Dictionary
# Player-facing settlement composition is still derived from the existing
# settlement/building plan. These arrays contain only authored presentation
# anchors; they do not introduce a new biome or simulation system.
var _settlement_paths: Array[Dictionary] = []
var _settlement_yards: Array[Dictionary] = []
var _settlement_fences: Array[Dictionary] = []
var _settlement_clutter: Array[Dictionary] = []
var _settlement_trees: Array[Dictionary] = []

static var _cache: Dictionary = {} # seed -> all deterministic rural manifests plus direct settlement dressing arrays

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

static func _sample_coherent_with_seed(p: Vector2, domain: StringName, cell_size: float, seed: int) -> float:
	return WorldSeed.sample_coherent(p, domain, cell_size, seed)

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null, settlement_plan: SettlementPlan = null, road_network_plan: RoadNetworkPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)
	biome = biome_plan if biome_plan != null else BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = settlement_plan if settlement_plan != null else SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	road_network = road_network_plan if road_network_plan != null else RoadNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement)
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		_buildings = (cached.get("buildings", []) as Array[Dictionary]).duplicate()
		var bs: Dictionary = cached.get("by_settlement", {}) as Dictionary
		_by_settlement = {}
		for k in bs.keys():
			_by_settlement[k] = (bs[k] as Array[Dictionary]).duplicate()
		_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()
		_wells = (cached.get("wells", []) as Array[Dictionary]).duplicate()
		var wbs: Dictionary = cached.get("wells_by_settlement", {}) as Dictionary
		_wells_by_settlement = {}
		for k in wbs.keys():
			_wells_by_settlement[k] = (wbs[k] as Array[Dictionary]).duplicate()
		_wells_by_id = (cached.get("wells_by_id", {}) as Dictionary).duplicate()
		_forage = (cached.get("forage", []) as Array[Dictionary]).duplicate()
		_forage_by_id = (cached.get("forage_by_id", {}) as Dictionary).duplicate()
		_workbenches = (cached.get("workbenches", []) as Array[Dictionary]).duplicate()
		var wbs2: Dictionary = cached.get("workbenches_by_settlement", {}) as Dictionary
		_workbenches_by_settlement = {}
		for k in wbs2.keys():
			_workbenches_by_settlement[k] = (wbs2[k] as Array[Dictionary]).duplicate()
		_workbenches_by_id = (cached.get("workbenches_by_id", {}) as Dictionary).duplicate()
		_workbench_by_building = (cached.get("workbench_by_building", {}) as Dictionary).duplicate()
		_granaries = (cached.get("granaries", []) as Array[Dictionary]).duplicate()
		var gbs: Dictionary = cached.get("granaries_by_settlement", {}) as Dictionary
		_granaries_by_settlement = {}
		for k in gbs.keys():
			_granaries_by_settlement[k] = (gbs[k] as Array[Dictionary]).duplicate()
		_granaries_by_id = (cached.get("granaries_by_id", {}) as Dictionary).duplicate()
		_granary_by_building = (cached.get("granary_by_building", {}) as Dictionary).duplicate()
		_settlement_paths = (cached.get("settlement_paths", []) as Array[Dictionary]).duplicate()
		_settlement_yards = (cached.get("settlement_yards", []) as Array[Dictionary]).duplicate()
		_settlement_fences = (cached.get("settlement_fences", []) as Array[Dictionary]).duplicate()
		_settlement_clutter = (cached.get("settlement_clutter", []) as Array[Dictionary]).duplicate()
		_settlement_trees = (cached.get("settlement_trees", []) as Array[Dictionary]).duplicate()
		# Invalidate stale cache without hearth (SPEC-C008): hearth derived from furniture must exist
		var stale := false
		if _buildings.size() > 0:
			var first: Dictionary = _buildings[0] as Dictionary
			if first.has("interior"):
				var inter: Dictionary = first["interior"] as Dictionary
				if not inter.has("hearth"):
					stale = true
		if not stale:
			# also invalidate if workbenches missing for existing village barns
			if _workbenches.is_empty() and _buildings.size() > 0:
				var has_village_barn := false
				for b in _buildings:
					if String(b.get("settlement_kind", "")) == "village" and (String(b.get("kind","")) == "barn" or String(b.get("kind","")) == "stable"):
						has_village_barn = true
						break
				if has_village_barn:
					stale = true
		if not stale:
			# also invalidate if granaries missing for existing village barns (P5.4)
			if _granaries.is_empty() and _buildings.size() > 0:
				var has_village_barn2 := false
				for b in _buildings:
					if String(b.get("settlement_kind", "")) == "village" and (String(b.get("kind","")) == "barn" or String(b.get("kind","")) == "stable"):
						has_village_barn2 = true
						break
				if has_village_barn2:
					stale = true
		if not stale:
			# G8 M4: invalidate if village with 5-6 buildings has only one barn/stable (second barn missing)
			var needs_second_barn := false
			var has_second_barn := false
			# Check any village where count >=5 and we expect second barn
			# We need _by_settlement to test, but at this point _by_settlement is loaded from cache
			# So scan _by_settlement
			for sid in _by_settlement.keys():
				var arr: Array[Dictionary] = _by_settlement[sid] as Array[Dictionary]
				if arr.size() >= 5:
					var kind0: StringName = arr[0].get("settlement_kind", &"") as StringName
					if kind0 == &"village":
						needs_second_barn = true
						var barn_cnt := 0
						for b in arr:
							var k: StringName = b.get("kind", &"") as StringName
							if k == &"barn" or k == &"stable":
								barn_cnt += 1
						if barn_cnt >= 2:
							has_second_barn = true
						break
			if needs_second_barn and not has_second_barn:
					stale = true
			if not stale:
				# Invalidate stale hamlet composition missing house+barn guarantee (recovery port)
				var hamlet_stale := false
				for sid in _by_settlement.keys():
					var arr2: Array[Dictionary] = _by_settlement[sid] as Array[Dictionary]
					if arr2.size() >= 2:
						var k0: StringName = arr2[0].get("settlement_kind", &"") as StringName
						if k0 == &"hamlet":
							var has_house_hamlet := false
							var has_barn_hamlet := false
							for b in arr2:
								var kk: StringName = b.get("kind", &"") as StringName
								if kk == &"barn" or kk == &"stable":
									has_barn_hamlet = true
								if kk == &"cottage" or kk == &"village_house" or kk == &"farmhouse":
									has_house_hamlet = true
							if not has_house_hamlet or not has_barn_hamlet:
								hamlet_stale = true
								break
				if hamlet_stale:
					stale = true
			if not stale:
				return
		# stale: fall through to regeneration
		_cache.erase(seed_used)
	_generate()
	# deep copy into cache
	var bs_copy := {}
	for k in _by_settlement.keys():
		bs_copy[k] = (_by_settlement[k] as Array[Dictionary]).duplicate()
	var wbs_copy := {}
	for k in _wells_by_settlement.keys():
		wbs_copy[k] = (_wells_by_settlement[k] as Array[Dictionary]).duplicate()
	var wbs_copy2 := {}
	for k in _workbenches_by_settlement.keys():
		wbs_copy2[k] = (_workbenches_by_settlement[k] as Array[Dictionary]).duplicate()
	var gbs_copy := {}
	for k in _granaries_by_settlement.keys():
		gbs_copy[k] = (_granaries_by_settlement[k] as Array[Dictionary]).duplicate()
	_cache[seed_used] = {"buildings": _buildings.duplicate(), "by_settlement": bs_copy, "by_id": _by_id.duplicate(), "wells": _wells.duplicate(), "wells_by_settlement": wbs_copy, "wells_by_id": _wells_by_id.duplicate(), "forage": _forage.duplicate(), "forage_by_id": _forage_by_id.duplicate(), "workbenches": _workbenches.duplicate(), "workbenches_by_settlement": wbs_copy2, "workbenches_by_id": _workbenches_by_id.duplicate(), "workbench_by_building": _workbench_by_building.duplicate(), "granaries": _granaries.duplicate(), "granaries_by_settlement": gbs_copy, "granaries_by_id": _granaries_by_id.duplicate(), "granary_by_building": _granary_by_building.duplicate(), "settlement_paths": _settlement_paths.duplicate(), "settlement_yards": _settlement_yards.duplicate(), "settlement_fences": _settlement_fences.duplicate(), "settlement_clutter": _settlement_clutter.duplicate(), "settlement_trees": _settlement_trees.duplicate()}

func _hash_id(s: String) -> int:
	return WorldSeed.str_hash(s)

static func _dict_id_cmp(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id", "")) < String(b.get("id", ""))

func _footprint_for_kind(kind_building: StringName, id_hash: int, k: int) -> Vector2:
	var r_x: float = _unit_float_with_seed("rural_building_fp_x", [id_hash, k], seed_used)
	var r_y: float = _unit_float_with_seed("rural_building_fp_y", [id_hash, k], seed_used)
	match kind_building:
		&"village_house":
			return Vector2(lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_VILLAGE_MIN.x, WorldConstants.RURAL_BUILDING_FOOTPRINT_VILLAGE_MAX.x, r_x),
				lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_VILLAGE_MIN.y, WorldConstants.RURAL_BUILDING_FOOTPRINT_VILLAGE_MAX.y, r_y))
		&"cottage", &"farmhouse":
			# cottage/farmhouse share 7-9 x 8-11
			return Vector2(lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_COTTAGE_MIN.x, WorldConstants.RURAL_BUILDING_FOOTPRINT_COTTAGE_MAX.x, r_x),
				lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_COTTAGE_MIN.y, WorldConstants.RURAL_BUILDING_FOOTPRINT_COTTAGE_MAX.y, r_y))
		&"barn", &"stable":
			return Vector2(lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_BARN_MIN.x, WorldConstants.RURAL_BUILDING_FOOTPRINT_BARN_MAX.x, r_x),
				lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_BARN_MIN.y, WorldConstants.RURAL_BUILDING_FOOTPRINT_BARN_MAX.y, r_y))
		&"shed":
			return Vector2(lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_SHED_MIN.x, WorldConstants.RURAL_BUILDING_FOOTPRINT_SHED_MAX.x, r_x),
				lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_SHED_MIN.y, WorldConstants.RURAL_BUILDING_FOOTPRINT_SHED_MAX.y, r_y))
		_:
			return Vector2(lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_MIN.x, WorldConstants.RURAL_BUILDING_FOOTPRINT_MAX.x, r_x),
				lerpf(WorldConstants.RURAL_BUILDING_FOOTPRINT_MIN.y, WorldConstants.RURAL_BUILDING_FOOTPRINT_MAX.y, r_y))

func _choose_building_kind(settlement_kind: StringName, id_hash: int, k: int, count: int) -> StringName:
	var r_kind: float = _unit_float_with_seed("rural_building", [id_hash, k, 99], seed_used)
	# Deterministic distribution per settlement kind
	match settlement_kind:
		&"village":
			var r_v: float = _unit_float_with_seed("rural_building", [id_hash, 100], seed_used)
			var num_vh: int = 2 + (1 if r_v > 0.5 else 0) # 2 or 3
			num_vh = mini(num_vh, count - 1) # ensure at least 1 for barn
			# G8 M4: villages with 5-6 buildings get second barn/stable for roof bridge prototype
			var has_second_barn := count >= 5
			if has_second_barn:
				num_vh = mini(num_vh, count - 2) # reserve 2 for barns
			if k < num_vh:
				return &"village_house"
			elif k == num_vh:
				return &"barn"
			elif has_second_barn and k == num_vh + 1:
				var r2: float = _unit_float_with_seed("rural_building", [id_hash, 101], seed_used)
				return &"stable" if r2 > 0.5 else &"barn"
			else:
				return &"cottage"
		&"hamlet":
			# A hamlet always has one dwelling and one agricultural utility
			# building. This is a composition guarantee, not a new category.
			if k == 1:
				return &"barn"
			if count >= 3 and k == 2:
				return &"stable" if _unit_float_with_seed("rural_building", [id_hash, 103], seed_used) > 0.3 else &"barn"
			return &"cottage" if r_kind < 0.55 else &"village_house"
		&"farmstead":
			if count == 1:
				return &"farmhouse"
			else:
				if k == 0:
					return &"farmhouse"
				else:
					return &"barn" if _unit_float_with_seed("rural_building", [id_hash, 104], seed_used) > 0.4 else &"stable"
		&"isolated_farm":
			return &"farmhouse" if _unit_float_with_seed("rural_building", [id_hash, 105], seed_used) > 0.4 else &"barn"
		_:
			return &"farmhouse" if k == 0 else &"barn"

func _target_count(settlement_kind: StringName, id_hash: int) -> int:
	match settlement_kind:
		&"village":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 4 + int(floor(r * 3.0)) # 4,5,6
		&"hamlet":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 2 + int(floor(r * 2.0)) # 2,3
		&"farmstead":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 1 + int(floor(r * 2.0)) # 1,2
		&"isolated_farm":
			return 1
		_:
			var r2: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 4 + int(floor(r2 * 3.0))

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
			var t := (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d := p.distance_to(proj)
			if d < best_dist:
				best_dist = d
				best_tangent = ab
	return best_tangent

func _yaw_for(p: Vector2, id_hash: int, k: int) -> float:
	var dr: float = road_network.distance_to_road(p) if road_network != null else INF
	if dr < 36.0:
		var tang := _nearest_road_tangent(p)
		if tang.length_squared() > 1e-6:
			var ang := atan2(tang.y, tang.x)
			var q: float = round(ang / (PI * 0.5)) * (PI * 0.5)
			q = wrapf(q, -PI, PI)
			if is_equal_approx(absf(q), PI):
				q = PI
			return q
	var rf: float = _unit_float_with_seed("rural_building_yaw", [id_hash, k], seed_used)
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

func _effective_footprint(footprint: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint

func _aabb_for(center: Vector2, footprint: Vector2, yaw: float) -> Rect2:
	var eff := _effective_footprint(footprint, yaw)
	return Rect2(center - eff * 0.5, eff)

func _aabb_gap(a: Rect2, b: Rect2) -> float:
	# minimal edge gap between two axis-aligned rects; 0 if touching/overlapping, negative if overlapping? Use 0 for overlap, positive gap otherwise
	var dx: float = maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy: float = maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	if dx == 0.0 and dy == 0.0:
		# check overlap: if interiors overlap, gap is negative minimal penetration but we return 0 for now
		# compute penetration for overlapping case
		var overlap_x: float = minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
		var overlap_y: float = minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
		if overlap_x > 0 and overlap_y > 0:
			return -minf(overlap_x, overlap_y)
		return 0.0
	if dx > 0.0 and dy > 0.0:
		return sqrt(dx*dx + dy*dy)
	return maxf(dx, dy)

func _door_for_building(center: Vector2, footprint: Vector2, yaw: float, settlement_center: Vector2, id_hash: int, k: int) -> Dictionary:
	var eff := _effective_footprint(footprint, yaw)
	var hx_local: float = footprint.x * 0.5
	var hz_local: float = footprint.y * 0.5
	var cos_y := cos(yaw)
	var sin_y := sin(yaw)
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
	var target_dir: Vector2
	var use_road := dist_road < 22.0
	if use_road:
		var nearest := _nearest_road_point(center)
		if nearest != Vector2.INF:
			target_dir = (nearest - center)
			if target_dir.length_squared() < 1e-6:
				target_dir = settlement_center - center
		else:
			target_dir = settlement_center - center
	else:
		target_dir = settlement_center - center
	if target_dir.length_squared() < 1e-6:
		var r_sel: float = _unit_float_with_seed("rural_building", [id_hash, k, 77], seed_used)
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
	var rect := Rect2(p - Vector2(40, 40), Vector2(80, 80))
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
			var t := (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d := p.distance_squared_to(proj)
			if d < best_dist:
				best_dist = d
				best_pt = proj
	return best_pt

func _palette_color(kind: StringName, id_hash: int, k: int) -> Color:
	var r: float = _unit_float_with_seed("rural_building_palette", [id_hash, k], seed_used)
	match kind:
		&"village_house":
			if r < 0.45:
				return Color("ddd0c0")
			elif r < 0.75:
				return Color("b07a5a")
			else:
				return Color("7a5a3a")
		&"cottage", &"farmhouse":
			if r < 0.6:
				return Color("ddd0c0")
			elif r < 0.85:
				return Color("b07a5a")
			else:
				return Color("7a5a3a")
		&"barn", &"stable":
			if r < 0.5:
				return Color("7a5a3a")
			elif r < 0.8:
				return Color("b07a5a")
			else:
				return Color("ddd0c0")
		&"shed":
			return Color("7a5a3a") if r < 0.7 else Color("5a5a5a")
		_:
			return Color("ddd0c0")

func _roof_color(kind: StringName, id_hash: int, k: int) -> Color:
	# Red clay tile is the stable Czech rural cue. Keep sheds/weathered
	# utilities on the grey variant, but never let a house become an
	# indistinguishable grey platform because of a random roof roll.
	if kind == &"shed":
		return Color("5a5a5a")
	return Color("9a4030")

# --- Interior generation ---

func _generate_partition_wall(building: Dictionary, id_hash: int) -> Array[Dictionary]:
	var kind: StringName = building["kind"] as StringName
	var footprint: Vector2 = building["footprint"] as Vector2
	# Only village_house, cottage, farmhouse and large enough
	if not (kind == &"village_house" or kind == &"cottage" or kind == &"farmhouse"):
		return [] as Array[Dictionary]
	if footprint.x < 7.5 or footprint.y < 9.0:
		# also check swapped for yaw? footprint is original, but effective after yaw same product; check min dimension
		if minf(footprint.x, footprint.y) < 7.5 or maxf(footprint.x, footprint.y) < 9.0:
			return [] as Array[Dictionary]
	var r_present: float = _unit_float_with_seed("rural_interior_wall", [id_hash, 0], seed_used)
	if r_present <= 0.30:
		return [] as Array[Dictionary]
	# Build wall
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	var door_pos: Vector2 = building["door_pos"] as Vector2
	var hx: float = footprint.x * 0.5
	var hz: float = footprint.y * 0.5
	var is_long_x: bool = footprint.x >= footprint.y
	var long_half: float = hx if is_long_x else hz
	var short_half: float = hz if is_long_x else hx
	var thickness: float = WorldConstants.RURAL_INTERIOR_WALL_THICKNESS
	# add small variation 0.14-0.16
	var r_thick: float = _unit_float_with_seed("rural_interior_wall", [id_hash, 10], seed_used)
	thickness = lerpf(0.14, 0.16, r_thick)
	var r_len_frac: float = _unit_float_with_seed("rural_interior_wall", [id_hash, 1], seed_used)
	var length: float = lerpf(WorldConstants.RURAL_INTERIOR_WALL_LENGTH_FRACTION_MIN, WorldConstants.RURAL_INTERIOR_WALL_LENGTH_FRACTION_MAX, r_len_frac) * minf(footprint.x, footprint.y) - 0.4
	length = clampf(length, 2.0, minf(footprint.x, footprint.y) - 1.0)
	var r_gap: float = _unit_float_with_seed("rural_interior_wall_gap", [id_hash, 0], seed_used)
	var gap: float = lerpf(0.90, 1.10, r_gap)
	var r_gap_choice: float = _unit_float_with_seed("rural_interior_wall_gap", [id_hash, 1], seed_used)
	var gap_side: int = int(floor(r_gap_choice * 3.0)) % 3 # 0 left, 1 centre, 2 right
	# For centre we treat as left for single segment but keep gap value
	# Long position central 0.38-0.62
	var r_long: float = _unit_float_with_seed("rural_interior_wall", [id_hash, 2], seed_used)
	var frac_long: float = lerpf(0.38, 0.62, r_long)
	var long_center_local: float = -long_half + frac_long * (2.0 * long_half)
	# Short centre to leave gap G at chosen side
	var short_center_local: float = 0.0
	if gap_side == 0:
		# gap at negative side (left)
		short_center_local = -short_half + gap + length * 0.5
	elif gap_side == 2:
		short_center_local = short_half - gap - length * 0.5
	else:
		# centre: place centrally, gap will be both sides = (2*short_half - length)/2 ; ensure within 0.90-1.10? we keep centrally but gap variable not used
		short_center_local = 0.0
		# recompute gap as actual distance to nearest side for reporting
		gap = (2.0 * short_half - length) * 0.5
		gap = clampf(gap, 0.90, 1.10)
	var wall_local_pos: Vector2
	var wall_size_local: Vector2
	if is_long_x:
		# long is X, wall runs along Z (short axis)
		wall_local_pos = Vector2(long_center_local, short_center_local)
		wall_size_local = Vector2(thickness, length)
	else:
		wall_local_pos = Vector2(short_center_local, long_center_local)
		wall_size_local = Vector2(length, thickness)
	# Transform to world
	var wall_world_pos: Vector2 = _local_to_world(center, yaw, wall_local_pos)
	var wall_world_yaw: float = yaw # axis-aligned
	# Compute world aabb for wall (oriented cardinal, so axis-aligned after rotation)
	var eff_wall := wall_size_local
	if is_equal_approx(absf(yaw), PI*0.5) or is_equal_approx(absf(yaw), PI*1.5):
		eff_wall = Vector2(wall_size_local.y, wall_size_local.x)
	var wall_aabb := Rect2(wall_world_pos - eff_wall*0.5, eff_wall)
	var building_aabb: Rect2 = building["aabb"] as Rect2
	# Check inset 0.5
	var inset_aabb := Rect2(building_aabb.position + Vector2(0.5,0.5), building_aabb.size - Vector2(1.0,1.0))
	if not inset_aabb.has_point(wall_aabb.position) or not inset_aabb.has_point(wall_aabb.end):
		# try to clamp inside inset
		return [] as Array[Dictionary]
	# Door swing 1.0 check
	if wall_world_pos.distance_to(door_pos) < 1.0 + maxf(wall_size_local.x, wall_size_local.y)*0.5:
		# also check aabb vs door circle
		var door_rect := Rect2(door_pos - Vector2(1.0,1.0), Vector2(2.0,2.0))
		if wall_aabb.intersects(door_rect):
			return [] as Array[Dictionary]
	# Gap already set
	var wall_dict: Dictionary = {
		"pos": wall_world_pos,
		"local_pos": wall_local_pos,
		"size": Vector3(wall_size_local.x, 2.4, wall_size_local.y), # height ~2.4 for interior wall
		"yaw": wall_world_yaw,
		"thickness": thickness,
		"length": length,
		"gap": gap,
		"gap_side": gap_side,
		"aabb": wall_aabb,
		"long_center": long_center_local,
		"short_center": short_center_local,
	}
	return [wall_dict] as Array[Dictionary]

func _local_to_world(center: Vector2, yaw: float, local: Vector2) -> Vector2:
	var cos_y := cos(yaw)
	var sin_y := sin(yaw)
	return center + Vector2(local.x * cos_y - local.y * sin_y, local.x * sin_y + local.y * cos_y)

func _world_to_local(center: Vector2, yaw: float, world: Vector2) -> Vector2:
	var rel := world - center
	var cos_y := cos(-yaw)
	var sin_y := sin(-yaw)
	return Vector2(rel.x * cos_y - rel.y * sin_y, rel.x * sin_y + rel.y * cos_y)

func _generate_furniture(building: Dictionary, walls: Array[Dictionary], id_hash: int) -> Array[Dictionary]:
	var kind_building: StringName = building["kind"] as StringName
	var target_count: int = 0
	var r_cnt: float = _unit_float_with_seed("rural_furniture", [id_hash, 0], seed_used)
	match kind_building:
		&"village_house":
			target_count = 2 if r_cnt < 0.5 else 3
		&"cottage", &"farmhouse":
			target_count = 1 if r_cnt < 0.5 else 2
		&"barn", &"stable", &"shed":
			target_count = 0 if r_cnt < 0.5 else 1
		_:
			target_count = 1 if r_cnt < 0.5 else 2
	if target_count <= 0 and kind_building != &"barn" and kind_building != &"stable":
		return [] as Array[Dictionary]
	if target_count <= 0:
		target_count = 1
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	var door_pos: Vector2 = building["door_pos"] as Vector2
	var hx: float = footprint.x * 0.5
	var hz: float = footprint.y * 0.5
	var has_wall: bool = walls.size() > 0
	var wall_dict: Dictionary = {} if not has_wall else walls[0] as Dictionary
	var furniture: Array[Dictionary] = [] as Array[Dictionary]
	# Robust deterministic furniture pass. The older wall-relative solver could
	# reject every candidate after comparing world-space and local-space AABBs;
	# this pass keeps furniture in the room, clear of the door and partition,
	# and guarantees an inhabited interior for every enterable rural house.
	var robust_target: int = 2 if kind_building == &"village_house" or kind_building == &"cottage" or kind_building == &"farmhouse" else 1
	if kind_building == &"village_house" and r_cnt > 0.45:
		robust_target = 3
	if kind_building == &"barn" or kind_building == &"stable":
		robust_target = 2
	var door_local_robust: Vector2 = _world_to_local(center, yaw, door_pos)
	var candidate_locals: Array[Vector2] = [
		Vector2(-hx + 1.15, -hz + 1.05), Vector2(hx - 1.15, -hz + 1.05),
		Vector2(-hx + 1.15, hz - 1.05), Vector2(hx - 1.15, hz - 1.05), Vector2(0.0, 0.0)
	]
	var candidate_kinds: Array[StringName] = [&"bed", &"shelf", &"table", &"stove", &"shelf"]
	for ci in candidate_locals.size():
		if furniture.size() >= robust_target:
			break
		var local_candidate: Vector2 = candidate_locals[ci]
		if absf(local_candidate.x) > hx - 0.75 or absf(local_candidate.y) > hz - 0.75:
			continue
		if local_candidate.distance_to(door_local_robust) < 1.45:
			continue
		var world_candidate: Vector2 = _local_to_world(center, yaw, local_candidate)
		var blocked_by_partition: bool = false
		for wall in walls:
			var wall_aabb: Rect2 = wall.get("aabb", Rect2()) as Rect2
			if wall_aabb.grow(0.65).has_point(world_candidate):
				blocked_by_partition = true
				break
		if blocked_by_partition:
			continue
		var furniture_kind: StringName = candidate_kinds[ci]
		if (kind_building == &"barn" or kind_building == &"stable") and furniture_kind == &"bed":
			furniture_kind = &"shelf"
		var furniture_size: Vector3 = Vector3(1.8, 0.5, 0.9) if furniture_kind == &"bed" else (Vector3(1.2, 0.4, 0.6) if furniture_kind == &"shelf" else (Vector3(1.0, 0.9, 0.75) if furniture_kind == &"table" else Vector3(0.8, 0.8, 0.9)))
		var furniture_aabb := Rect2(world_candidate - Vector2(furniture_size.x, furniture_size.z) * 0.5, Vector2(furniture_size.x, furniture_size.z))
		var clear: bool = true
		for other in furniture:
			var other_aabb: Rect2 = other.get("aabb", Rect2()) as Rect2
			if _aabb_gap(furniture_aabb, other_aabb) < 0.9 - 1e-6:
				clear = false
				break
		if not clear:
			continue
		furniture.append({
			"kind": furniture_kind,
			"pos": world_candidate,
			"local_pos": local_candidate,
			"yaw": yaw,
			"size": furniture_size,
			"aabb": furniture_aabb,
		})
	if furniture.is_empty():
		var fallback_local := Vector2(0.0, 0.0)
		var fallback_world: Vector2 = _local_to_world(center, yaw, fallback_local)
		furniture.append({"kind": &"table", "pos": fallback_world, "local_pos": fallback_local, "yaw": yaw, "size": Vector3(1.0, 0.9, 0.75), "aabb": Rect2(fallback_world - Vector2(0.5, 0.375), Vector2(1.0, 0.75))})
	return furniture
	# Legacy randomized wall solver retained below for historical reference;
	# the deterministic robust pass above is the active path.

	var allowed: Array[StringName] = []
	if kind_building == &"barn" or kind_building == &"stable" or kind_building == &"shed":
		allowed = [&"shelf", &"table"] as Array[StringName]
	else:
		allowed = WorldConstants.RURAL_FURNITURE_VOCAB.duplicate()
	for i in target_count:
		var r_kind: float = _unit_float_with_seed("rural_furniture", [id_hash, i+1], seed_used)
		var idx_kind: int = int(floor(r_kind * float(allowed.size()))) % allowed.size()
		var f_kind: StringName = allowed[idx_kind]
		var f_size: Vector3
		match f_kind:
			&"bed":
				f_size = Vector3(1.9, 0.5, 0.9)
			&"shelf":
				f_size = Vector3(1.2, 0.4, 1.1)
			&"table":
				f_size = Vector3(1.0, 1.0, 0.75)
			&"stove":
				f_size = Vector3(0.8, 0.8, 0.9)
			_:
				f_size = Vector3(1.0, 1.0, 0.75)
		# Choose wall among 4 exterior + interior if present
		var num_walls: int = 5 if has_wall else 4
		var r_wall: float = _unit_float_with_seed("rural_furniture", [id_hash, i+10], seed_used)
		var wall_idx: int = int(floor(r_wall * float(num_walls))) % num_walls
		# wall_idx 0..3 exterior (0:+X east,1:-X west,2:+Z north,3:-Z south), 4 interior
		var placed := false
		var attempts := 0
		while attempts < 6 and not placed:
			# choose offset along wall
			var r_off: float = _unit_float_with_seed("rural_furniture", [id_hash, i+20+attempts], seed_used)
			var wall_local_normal: Vector2 = Vector2.ZERO
			var wall_pos_local: Vector2 = Vector2.ZERO
			var wall_length_local: float = 0.0
			var wall_is_vertical: bool = false # wall orientation along Z or X?
			if wall_idx < 4:
				# exterior walls
				match wall_idx:
					0: # +X east
						wall_local_normal = Vector2(1,0)
						wall_pos_local = Vector2(hx, 0)
						wall_length_local = footprint.y
						wall_is_vertical = false # wall runs along Z, furniture depth along -X
					1: # -X west
						wall_local_normal = Vector2(-1,0)
						wall_pos_local = Vector2(-hx, 0)
						wall_length_local = footprint.y
						wall_is_vertical = false
					2: # +Z north
						wall_local_normal = Vector2(0,1)
						wall_pos_local = Vector2(0, hz)
						wall_length_local = footprint.x
						wall_is_vertical = true
					3: # -Z south
						wall_local_normal = Vector2(0,-1)
						wall_pos_local = Vector2(0, -hz)
						wall_length_local = footprint.x
						wall_is_vertical = true
			else:
				# interior wall
				var wpos: Vector2 = wall_dict.get("local_pos", Vector2.ZERO) as Vector2
				var wsize: Vector2 = Vector2(float(wall_dict.get("thickness",0.15)), float(wall_dict.get("length", 4.0)))
				# Determine interior wall orientation: if footprint.x >= footprint.y long X => wall runs along Z at x=long_center
				var is_long_x: bool = footprint.x >= footprint.y
				if is_long_x:
					# wall runs along Z, normal ±X
					# choose side deterministically: even i -> +X side, odd -> -X side
					var side: float = 1.0 if (i %2==0) else -1.0
					wall_local_normal = Vector2(side, 0)
					wall_pos_local = wpos + Vector2(side * (wsize.x*0.5), 0)
					wall_length_local = wsize.y
					wall_is_vertical = false
				else:
					var side: float = 1.0 if (i %2==0) else -1.0
					wall_local_normal = Vector2(0, side)
					wall_pos_local = wpos + Vector2(0, side * (wsize.y*0.5))
					wall_length_local = wsize.x
					wall_is_vertical = true
			# Determine furniture footprint along wall vs depth
			var f_len: float = f_size.x # along wall
			var f_dep: float = f_size.z # depth outward from wall
			# For wall vertical (runs along X), along wall is X
			# Compute available offset range along wall length
			var half_wall_len: float = wall_length_local *0.5
			var min_off: float = -half_wall_len + 0.35 + f_len*0.5
			var max_off: float = half_wall_len - 0.35 - f_len*0.5
			if min_off > max_off:
				attempts += 1
				continue
			var off: float = lerpf(min_off, max_off, r_off)
			var local_pos: Vector2
			if wall_idx <4:
				match wall_idx:
					0: # east wall +X, interior is negative X
						local_pos = Vector2(hx - 0.15 - f_dep*0.5, off)
					1: # west -X
						local_pos = Vector2(-hx + 0.15 + f_dep*0.5, off)
					2: # north +Z
						local_pos = Vector2(off, hz - 0.15 - f_dep*0.5)
					3: # south -Z
						local_pos = Vector2(off, -hz + 0.15 + f_dep*0.5)
			else:
				# interior wall offset
				var wpos2: Vector2 = wall_dict.get("local_pos", Vector2.ZERO) as Vector2
				var is_long_x2: bool = footprint.x >= footprint.y
				if is_long_x2:
					# interior wall at x = wpos.x, runs along Z
					var side: float = 1.0 if (i %2==0) else -1.0
					# local pos offset along Z (wall length)
					local_pos = Vector2(wpos2.x + side*(0.15+f_dep*0.5), off)
					# off is along Z? But wpos already has Z centre, wall length along Z, off along Z relative to wpos.z
					local_pos.y = wpos2.y + off
				else:
					var side: float = 1.0 if (i %2==0) else -1.0
					local_pos = Vector2(off, wpos2.y + side*(0.15+f_dep*0.5))
					local_pos.x = wpos2.x + off
			var world_pos: Vector2 = _local_to_world(center, yaw, local_pos)
			# Check door swing 1.0
			if world_pos.distance_to(door_pos) < 1.0 + maxf(f_len,f_dep)*0.5:
				attempts += 1
				continue
			# Check doorway gap not overlapping (if has wall)
			if has_wall:
				var wpos_gap: Vector2 = wall_dict.get("local_pos", Vector2.ZERO) as Vector2
				var w_aabb: Rect2 = wall_dict.get("aabb", Rect2()) as Rect2
				# doorway gap aabb approx: gap region between wall end and building side wall
				var gap_side: int = int(wall_dict.get("gap_side",0))
				var gap: float = float(wall_dict.get("gap",0.95))
				var wall_len: float = float(wall_dict.get("length",4.0))
				var short_half: float = minf(hx,hz)
				# gap region is near wall end at + or - short direction
				# For is_long_x wall runs along Z, gap at Z end
				# Define gap rect world approx around wall end + gap/2 towards building wall
				# Simplify check: distance from furniture pos to wall gap center <1.0?
				var gap_center_local: Vector2
				if footprint.x >= footprint.y:
					# wall along Z, gap at Z end
					var gap_z: float = 0.0
					if gap_side == 0:
						gap_z = -short_half + gap*0.5
					elif gap_side == 2:
						gap_z = short_half - gap*0.5
					else:
						# centre gap not defined, skip
						gap_z = 0.0
					gap_center_local = Vector2(wpos_gap.x, gap_z)
				else:
					var gap_x: float = 0.0
					if gap_side == 0:
						gap_x = -short_half + gap*0.5
					elif gap_side == 2:
						gap_x = short_half - gap*0.5
					else:
						gap_x = 0.0
					gap_center_local = Vector2(gap_x, wpos_gap.y)
				var gap_world: Vector2 = _local_to_world(center, yaw, gap_center_local)
				if world_pos.distance_to(gap_world) < 0.9 + maxf(f_len,f_dep)*0.5:
					# furniture too close to doorway gap
					if gap_side !=1:
						attempts +=1
						continue
			# Check spacing from other furniture >=0.9
			var ok_spacing := true
			for other in furniture:
				var op: Vector2 = other["pos"] as Vector2
				var osize: Vector3 = other["size"] as Vector3
				var gap_needed: float = 0.9 + (maxf(f_len,f_dep)+maxf(osize.x,osize.z))*0.5 *0.0 # we approximate center distance
				# Use aabb gap: if furniture aabbs gap <0.9 -> fail
				var aabb1: Rect2 = Rect2(world_pos - Vector2(f_len,f_dep)*0.5, Vector2(f_len,f_dep))
				var aabb2: Rect2 = Rect2(op - Vector2(osize.x,osize.z)*0.5, Vector2(osize.x,osize.z))
				var gap_ab: float = _aabb_gap(aabb1, aabb2)
				if gap_ab < 0.9 - 1e-6:
					ok_spacing = false
					break
			if not ok_spacing:
				attempts +=1
				continue
			# Check inside inset 0.5 and 0.7 from walls? Furniture already inset 0.15, but ensure not too close to opposite walls <0.7? Spec says furniture >=0.7 from crate but that's later.
			# Ensure furniture aabb inside building inset 0.5 (we already placed inset 0.15, but need to ensure not overlapping building edge beyond inset 0.5)
			var f_aabb_local := Rect2(local_pos - Vector2(f_len,f_dep)*0.5, Vector2(f_len,f_dep))
			var building_inset_local := Rect2(Vector2(-hx+0.5, -hz+0.5), Vector2(footprint.x-1.0, footprint.y-1.0))
			if not building_inset_local.has_point(f_aabb_local.position) or not building_inset_local.has_point(f_aabb_local.end):
				attempts+=1
				continue
			# All checks passed
			var world_yaw: float = yaw
			# furniture yaw same as building, but if against east/west wall, yaw maybe building yaw (already axis-aligned)
			# For bed along wall, orientation should be along wall, but we keep building yaw
			var f_dict: Dictionary = {
				"kind": f_kind,
				"pos": world_pos,
				"local_pos": local_pos,
				"yaw": world_yaw,
				"size": f_size,
				"aabb": Rect2(world_pos - Vector2(f_len,f_dep)*0.5, Vector2(f_len,f_dep)),
			}
			furniture.append(f_dict)
			placed = true
			break
		if not placed:
			# drop this furniture if cannot place without conflict
			continue
	return furniture

func _generate_crate_for_building(building: Dictionary, walls: Array[Dictionary], furniture: Array[Dictionary], id_hash: int) -> Dictionary:
	# Determine if this building should have crate - caller decides presence; this function generates position+contents for a building that should have crate
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	var door_pos: Vector2 = building["door_pos"] as Vector2
	var kind_building: StringName = building["kind"] as StringName
	var settlement_kind: StringName = building["settlement_kind"] as StringName
	var has_wall: bool = walls.size()>0
	var hx: float = footprint.x*0.5
	var hz: float = footprint.y*0.5
	# Determine room rects
	var rooms: Array[Rect2] = []
	if not has_wall:
		var inset_rect_local := Rect2(Vector2(-hx+0.5, -hz+0.5), Vector2(footprint.x-1.0, footprint.y-1.0))
		# transform to world? Keep local for placement then convert
		rooms.append(inset_rect_local)
	else:
		var w: Dictionary = walls[0] as Dictionary
		var wpos: Vector2 = w.get("local_pos", Vector2.ZERO) as Vector2
		var wthick: float = float(w.get("thickness",0.15))
		var wlen: float = float(w.get("length",4.0))
		var is_long_x: bool = footprint.x >= footprint.y
		if is_long_x:
			# wall at x = wpos.x, thickness along X
			var left_rect := Rect2(Vector2(-hx+0.5, -hz+0.5), Vector2((wpos.x - wthick*0.5) - (-hx+0.5), footprint.y-1.0))
			var right_rect := Rect2(Vector2(wpos.x + wthick*0.5, -hz+0.5), Vector2((hx-0.5) - (wpos.x + wthick*0.5), footprint.y-1.0))
			# Only add if width >0.5
			if left_rect.size.x > 1.0 and left_rect.size.y > 1.0:
				rooms.append(left_rect)
			if right_rect.size.x > 1.0 and right_rect.size.y > 1.0:
				rooms.append(right_rect)
		else:
			var bottom_rect := Rect2(Vector2(-hx+0.5, -hz+0.5), Vector2(footprint.x-1.0, (wpos.y - wthick*0.5) - (-hz+0.5)))
			var top_rect := Rect2(Vector2(-hx+0.5, wpos.y + wthick*0.5), Vector2(footprint.x-1.0, (hz-0.5) - (wpos.y + wthick*0.5)))
			if bottom_rect.size.x >1.0 and bottom_rect.size.y>1.0:
				rooms.append(bottom_rect)
			if top_rect.size.x>1.0 and top_rect.size.y>1.0:
				rooms.append(top_rect)
	if rooms.is_empty():
		return {}
	# Choose larger room
	var chosen_rect: Rect2 = rooms[0]
	var max_area: float = rooms[0].size.x * rooms[0].size.y
	for i in range(1, rooms.size()):
		var a: float = rooms[i].size.x * rooms[i].size.y
		if a > max_area:
			max_area = a
			chosen_rect = rooms[i]
	# If no partition, we already have inset rect; but spec says against far wall opposite door when no partition
	# For has_wall false, chosen_rect is whole inset; we will favor far wall
	# Determine allowable crate center region inside chosen_rect with 0.70+0.5 from walls
	var crate_half: float = 0.5
	var inset_crate: float = 0.70 + crate_half
	var allowable := Rect2(chosen_rect.position + Vector2(inset_crate, inset_crate), chosen_rect.size - Vector2(inset_crate*2, inset_crate*2))
	if allowable.size.x < 0.2 or allowable.size.y < 0.2:
		# fallback shrunken
		allowable = Rect2(chosen_rect.get_center() - Vector2(0.2,0.2), Vector2(0.4,0.4))
	# Deterministic position within allowable
	var r_x: float = _unit_float_with_seed("rural_crate", [id_hash, 0], seed_used)
	var r_y: float = _unit_float_with_seed("rural_crate", [id_hash, 1], seed_used)
	# For no wall, bias towards far wall opposite door
	if not has_wall:
		# Determine far wall direction
		var door_local: Vector2 = _world_to_local(center, yaw, door_pos)
		# far wall is opposite sign along same axis as door
		# door at east (+hx) => far at west (-hx)
		# We will bias r towards far side: e.g., if door east, crate X near west (low)
		# Map r_x to position, but adjust to be near far wall: instead of uniform, push towards far edge
		var door_is_east: bool = door_local.x > hx*0.5
		var door_is_west: bool = door_local.x < -hx*0.5
		var door_is_north: bool = door_local.y > hz*0.5
		var door_is_south: bool = door_local.y < -hz*0.5
		# Bias: if door east, crate near west => r_x small; we can invert r
		if door_is_east:
			r_x = 1.0 - r_x*0.5 # bias to low side
		elif door_is_west:
			r_x = 0.5 + r_x*0.5
		if door_is_north:
			r_y = 1.0 - r_y*0.5
		elif door_is_south:
			r_y = 0.5 + r_y*0.5
	var local_crate: Vector2 = Vector2(lerpf(allowable.position.x + crate_half, allowable.end.x - crate_half, r_x), lerpf(allowable.position.y + crate_half, allowable.end.y - crate_half, r_y))
	# Need to convert local to world: but allowable is already local coordinates (since rooms defined local)
	# So local_crate is local pos
	var world_crate: Vector2 = _local_to_world(center, yaw, local_crate)
	# Check distances: at least 1.20 from door_pos, 0.70 from walls (already), 0.90 from furniture and wall
	var tries: int = 0
	while tries < 5:
		var dist_door: float = world_crate.distance_to(door_pos)
		if dist_door < 1.20:
			# nudge away from door: move towards far side
			var dir: Vector2 = (world_crate - door_pos).normalized()
			if dir.length_squared() < 1e-6:
				dir = Vector2(1,0)
			world_crate += dir * 0.5
			local_crate = _world_to_local(center, yaw, world_crate)
			# clamp to allowable
			local_crate.x = clampf(local_crate.x, allowable.position.x + crate_half, allowable.end.x - crate_half)
			local_crate.y = clampf(local_crate.y, allowable.position.y + crate_half, allowable.end.y - crate_half)
			world_crate = _local_to_world(center, yaw, local_crate)
			tries+=1
			continue
		var ok_furn := true
		for f in furniture:
			var fp: Vector2 = f["pos"] as Vector2
			if world_crate.distance_to(fp) < 0.90 + crate_half + maxf(float((f["size"] as Vector3).x), float((f["size"] as Vector3).z))*0.5:
				ok_furn = false
				break
		if not ok_furn:
			# nudge
			var r2x: float = _unit_float_with_seed("rural_crate", [id_hash, 2+tries], seed_used)
			var r2y: float = _unit_float_with_seed("rural_crate", [id_hash, 3+tries], seed_used)
			local_crate = Vector2(lerpf(allowable.position.x + crate_half, allowable.end.x - crate_half, r2x), lerpf(allowable.position.y + crate_half, allowable.end.y - crate_half, r2y))
			world_crate = _local_to_world(center, yaw, local_crate)
			tries+=1
			continue
		if has_wall:
			var wall_aabb: Rect2 = walls[0].get("aabb", Rect2()) as Rect2
			# distance from crate to wall aabb edge <0.90?
			var crate_aabb := Rect2(world_crate - Vector2(crate_half, crate_half), Vector2(1.0,1.0))
			var gap: float = _aabb_gap(crate_aabb, wall_aabb)
			if gap < 0.90 - 1e-6 and gap >=0:
				# too close to wall (but crate should be in room separated by wall, gap should be at least wall thickness plus? For room on one side, crate is on one side, wall is boundary, gap is distance to wall: for crate in larger room, distance to wall should be at least 0.70? Actually partition wall is room boundary, crate 0.90 from it is already via allowable inset? We already inset from wall by 0.70, but spec says 0.90 from wall. We inset 0.70, but need 0.90. So we should have inset 0.90.
				# If crate is in chosen room, its distance to partition wall should be >=0.90 . Our allowable already ensures 0.70+0.5=1.20 from building walls but for partition wall we used room rect which already excludes wall thickness but not 0.90. So check.
				tries+=1
				continue
		break
	# Generate contents
	var is_village: bool = settlement_kind == &"village"
	var r_cnt: float = _unit_float_with_seed("rural_crate", [id_hash, 100], seed_used)
	var target_items: int = 1
	if is_village:
		target_items = 1 + int(floor(r_cnt * 4.0)) # 1-4
		target_items = clampi(target_items, 1, 4)
	else:
		target_items = 1 + int(floor(r_cnt * 2.0)) # 1-2
		target_items = clampi(target_items, 1, 2)
	var contents: Dictionary = {}
	for k in target_items:
		var r_item: float = _unit_float_with_seed("rural_crate_contents", [id_hash, k], seed_used)
		var item_id: StringName
		if r_item < 0.40:
			item_id = &"canned_food"
		elif r_item < 0.65:
			item_id = &"water_bottle"
		elif r_item < 0.85:
			item_id = &"bandage"
		else:
			item_id = &"antibiotics"
		contents[item_id] = int(contents.get(item_id, 0)) + 1
	var bid: String = building["id"] as String
	var crate_id: String = "rural_crate_%s" % bid
	var crate_dict: Dictionary = {
		"id": crate_id,
		"building_id": bid,
		"pos": world_crate,
		"local_pos": local_crate,
		"yaw": yaw,
		"contents": contents,
		"kind": &"rural_crate",
		"aabb": Rect2(world_crate - Vector2(0.5,0.5), Vector2(1.0,1.0)),
	}
	return crate_dict

func _target_well_count(skind: StringName, id_hash: int) -> int:
	match skind:
		&"village":
			var r: float = _unit_float_with_seed("rural_well", [id_hash, 0], seed_used)
			return 1 if r < 0.6 else 2
		&"hamlet":
			return 1
		&"farmstead":
			var r2: float = _unit_float_with_seed("rural_well", [id_hash, 0], seed_used)
			return 1 if r2 > 0.45 else 0
		&"isolated_farm":
			var r3: float = _unit_float_with_seed("rural_well", [id_hash, 0], seed_used)
			return 1 if r3 > 0.65 else 0
		_:
			var r4: float = _unit_float_with_seed("rural_well", [id_hash, 0], seed_used)
			return 1 if r4 < 0.6 else 2

func _is_valid_well_position(p: Vector2, settlement_kind: StringName, existing_wells: Array[Dictionary], settlement_buildings: Array[Dictionary]) -> bool:
	var tclass: StringName = terrain.terrain_class_at(p)
	if tclass == &"cliff":
		return false
	var slope: float = terrain.slope_at(p)
	if settlement_kind == &"village":
		if slope >= 14.0 - 1e-6:
			return false
	else:
		if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
			return false
	if hydrology.water_body_at(p) != &"":
		return false
	if hydrology.is_floodplain(p):
		return false
	if hydrology.distance_to_water(p) <= WorldConstants.BANK_W + 2.0 + 1e-6:
		return false
	var d_road: float = road_network.distance_to_road(p) if road_network != null else INF
	if d_road < WorldConstants.RURAL_WELL_ROAD_SETBACK - 1e-6:
		return false
	if p.length() < WorldConstants.URBAN_INNER_M - 0.5:
		# allow gate well exception later, but base gate check
		var gates: Array[Dictionary] = settlement.city_gates()
		var is_gate_well := false
		for g in gates:
			var gc: Vector2 = g["center"] as Vector2
			if p.distance_to(gc) < 140.0 and p.length() >= WorldConstants.URBAN_INNER_M - 20.0 and p.length() < WorldConstants.URBAN_INNER_M + 70.0:
				is_gate_well = true
				break
		if not is_gate_well:
			return false
	# building gap 8
	var well_aabb := Rect2(p - Vector2(WorldConstants.RURAL_WELL_RADIUS, WorldConstants.RURAL_WELL_RADIUS), Vector2(WorldConstants.RURAL_WELL_RADIUS*2, WorldConstants.RURAL_WELL_RADIUS*2))
	for b in settlement_buildings:
		var baabb: Rect2 = b["aabb"] as Rect2
		var gap: float = _aabb_gap(well_aabb, baabb)
		if gap < WorldConstants.RURAL_WELL_BUILDING_GAP_MIN - 1e-6:
			return false
	# also check all buildings globally for safety? spec says >=8 from any rural building of that settlement, we do that; but spec also says >=8 from any building generally. We'll check settlement buildings only for perf; global check will happen in forage vs building but well vs building globally also? Use settlement buildings.
	# well-well spacing 6
	for w in existing_wells:
		var wpos: Vector2 = w["pos"] as Vector2
		if p.distance_to(wpos) < WorldConstants.RURAL_WELL_SPACING_MIN - 1e-6:
			return false
	# is_bridge check
	if road_network != null:
		var rect2 := Rect2(p - Vector2(30,30), Vector2(60,60))
		var segs: Array[Dictionary] = road_network.road_segments_in(rect2)
		for seg in segs:
			if bool(seg.get("is_bridge", false)):
				var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
				for i in range(poly.size()-1):
					var a2: Vector2 = poly[i]
					var b2: Vector2 = poly[i+1]
					var ab2 := b2 - a2
					var len2b := ab2.length_squared()
					if len2b < 1e-6:
						continue
					var t2 := (p - a2).dot(ab2) / len2b
					t2 = clampf(t2, 0.0, 1.0)
					var proj2 := a2 + ab2 * t2
					var w_road: float = float(seg.get("width", WorldConstants.ROAD_WIDTH_TRACK))
					if p.distance_to(proj2) < w_road * 0.5 + 2.0 and hydrology.water_body_at(proj2) != &"":
						return false
	return true

func _generate_wells() -> void:
	_wells.clear()
	_wells_by_settlement.clear()
	_wells_by_id.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var gates: Array[Dictionary] = settlement.city_gates()
	var gate_wells_used: Dictionary = {}
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var s_center: Vector2 = s["center"] as Vector2
		var s_radius: float = float(s["radius"])
		var id_hash: int = _hash_id(sid)
		var target: int = _target_well_count(skind, id_hash)
		if not _wells_by_settlement.has(sid):
			_wells_by_settlement[sid] = [] as Array[Dictionary]
		var settlement_buildings: Array[Dictionary] = _by_settlement.get(sid, []) as Array[Dictionary]
		var placed_wells: Array[Dictionary] = []
		for k in target:
			var wid: String = "rural_well_%s_%d" % [sid, k]
			var w_hash: int = _hash_id(wid)
			var found := false
			var well_dict: Dictionary = {}
			for attempt in 12:
				var r_rad: float = _unit_float_with_seed("rural_well_radius", [id_hash, k, attempt], seed_used)
				var rad: float = lerpf(0.35, 0.65, r_rad) * s_radius
				var r_ang: float = _unit_float_with_seed("rural_well_angle", [id_hash, k, attempt], seed_used)
				var ang: float = r_ang * TAU
				if attempt > 0:
					var nudge_r: float = _unit_float_with_seed("rural_well_nudge", [id_hash, k, attempt], seed_used)
					var nudge_a: float = _unit_float_with_seed("rural_well_nudge", [id_hash, k, attempt+10], seed_used)
					rad += (nudge_r - 0.5) * 10.0
					ang += (nudge_a - 0.5) * 0.6
					rad = clampf(rad, 8.0, s_radius * 0.95)
				var cand: Vector2 = s_center + Vector2(cos(ang), sin(ang)) * rad
				# gate exception
				var is_inside_urban: bool = cand.length() < WorldConstants.URBAN_INNER_M - 0.5
				if is_inside_urban:
					var nearest_gate_dist := INF
					var nearest_gate_id := ""
					for g in gates:
						var gc: Vector2 = g["center"] as Vector2
						var d := cand.distance_to(gc)
						if d < nearest_gate_dist:
							nearest_gate_dist = d
							nearest_gate_id = String(g["id"])
					if nearest_gate_dist < 140.0 and not gate_wells_used.has(nearest_gate_id) and cand.length() >= WorldConstants.URBAN_INNER_M - 20.0 and cand.length() < WorldConstants.URBAN_INNER_M + 70.0:
						# allow gate well
						pass
					else:
						continue
				if not _is_valid_well_position(cand, skind, placed_wells, settlement_buildings):
					continue
				well_dict = {
					"id": wid,
					"kind": &"village_well",
					"center": cand,
					"pos": cand,
					"position": Vector3(cand.x, terrain.height_at(cand)+0.01, cand.y),
					"yaw": 0.0,
					"settlement_id": sid,
					"settlement_kind": skind,
					"radius": WorldConstants.RURAL_WELL_RADIUS,
					"height": WorldConstants.RURAL_WELL_HEIGHT,
					"color": WorldConstants.RURAL_WELL_COLOR_WALL,
					"roof_color": WorldConstants.RURAL_WELL_COLOR_WATER,
				}
				found = true
				break
			if found:
				_wells.append(well_dict)
				(_wells_by_settlement[sid] as Array[Dictionary]).append(well_dict)
				_wells_by_id[wid] = well_dict
				placed_wells.append(well_dict)
				# gate tracking
				if well_dict["pos"] is Vector2 and Vector2(well_dict["pos"]).length() < WorldConstants.URBAN_INNER_M + 70.0:
					for g in gates:
						var gc: Vector2 = g["center"] as Vector2
						if Vector2(well_dict["pos"]).distance_to(gc) < 140.0:
							gate_wells_used[String(g["id"])] = true
							break
			else:
				# hamlet strict guarantee fallback at settlement_center + (8,0) vetted 12 attempts with wider search
				if skind == &"hamlet" and placed_wells.size() == 0:
					for att2 in 12:
						var fb: Vector2
						if att2 == 0:
							fb = s_center + Vector2(12, 0)
						elif att2 == 1:
							fb = s_center + Vector2(-12, 0)
						elif att2 == 2:
							fb = s_center + Vector2(0, 12)
						elif att2 == 3:
							fb = s_center + Vector2(0, -12)
						else:
							var nr: float = _unit_float_with_seed("rural_well_nudge", [id_hash, k, 100+att2], seed_used)
							var na: float = _unit_float_with_seed("rural_well_nudge", [id_hash, k, 110+att2], seed_used)
							var rad2: float = lerpf(10.0, s_radius * 0.85, nr)
							var ang2: float = na * TAU
							fb = s_center + Vector2(cos(ang2), sin(ang2)) * rad2
						if _is_valid_well_position(fb, skind, placed_wells, settlement_buildings):
							var wid2: String = "rural_well_%s_%d" % [sid, k]
							var wd2: Dictionary = {
								"id": wid2,
								"kind": &"village_well",
								"center": fb,
								"pos": fb,
								"position": Vector3(fb.x, terrain.height_at(fb)+0.01, fb.y),
								"yaw": 0.0,
								"settlement_id": sid,
								"settlement_kind": skind,
								"radius": WorldConstants.RURAL_WELL_RADIUS,
								"height": WorldConstants.RURAL_WELL_HEIGHT,
								"color": WorldConstants.RURAL_WELL_COLOR_WALL,
								"roof_color": WorldConstants.RURAL_WELL_COLOR_WATER,
							}
							_wells.append(wd2)
							(_wells_by_settlement[sid] as Array[Dictionary]).append(wd2)
							_wells_by_id[wid2] = wd2
							placed_wells.append(wd2)
							break

func _forage_target_count(skind: StringName, id_hash: int) -> int:
	match skind:
		&"village":
			var r: float = _unit_float_with_seed("rural_forage", [id_hash, 0], seed_used)
			if r < 0.33:
				return 3
			elif r < 0.66:
				return 4
			else:
				return 5
		&"hamlet":
			var r2: float = _unit_float_with_seed("rural_forage", [id_hash, 0], seed_used)
			return 2 if r2 < 0.5 else 3
		&"farmstead":
			var r3: float = _unit_float_with_seed("rural_forage", [id_hash, 0], seed_used)
			return 1 if r3 < 0.5 else 2
		&"isolated_farm":
			return 1
		_:
			var r4: float = _unit_float_with_seed("rural_forage", [id_hash, 0], seed_used)
			return 2 if r4 < 0.5 else 3

func _is_valid_forage_position(p: Vector2, existing_forage: Array[Dictionary]) -> bool:
	var tclass: StringName = terrain.terrain_class_at(p)
	if tclass == &"cliff":
		return false
	var b: StringName = biome.biome_at(p)
	if not WorldConstants.RURAL_FORAGE_ALLOW_BIOMES.has(b):
		return false
	var slope: float = terrain.slope_at(p)
	if b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard":
		if slope >= WorldConstants.PASTURE_MAX_SLOPE_DEG - 1e-6:
			return false
	else:
		if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
			return false
	if hydrology.water_body_at(p) != &"":
		return false
	if hydrology.is_floodplain(p):
		return false
	if hydrology.distance_to_water(p) <= WorldConstants.BANK_W + 2.0 + 1e-6:
		return false
	var d_road: float = road_network.distance_to_road(p) if road_network != null else INF
	if d_road < WorldConstants.RURAL_FORAGE_ROAD_SETBACK - 1e-6:
		return false
	if p.length() < WorldConstants.URBAN_INNER_M - 0.5:
		return false
	# building gap 6
	for bld in _buildings:
		var baabb: Rect2 = bld["aabb"] as Rect2
		var forage_aabb := Rect2(p - Vector2(0.4,0.4), Vector2(0.8,0.8))
		var gap: float = _aabb_gap(forage_aabb, baabb)
		if gap < WorldConstants.RURAL_FORAGE_BUILDING_GAP_MIN - 1e-6:
			return false
	# well gap 6
	for w in _wells:
		var wpos: Vector2 = w["pos"] as Vector2
		if p.distance_to(wpos) < WorldConstants.RURAL_FORAGE_WELL_GAP_MIN - 1e-6:
			return false
	# forage-forage 4 within existing settlement vicinity? we check global existing forage 4
	for f in existing_forage:
		var fpos: Vector2 = f["pos"] as Vector2
		if p.distance_to(fpos) < WorldConstants.RURAL_FORAGE_SPACING_MIN - 1e-6:
			return false
	# is_bridge
	if road_network != null:
		var rect2 := Rect2(p - Vector2(30,30), Vector2(60,60))
		var segs: Array[Dictionary] = road_network.road_segments_in(rect2)
		for seg in segs:
			if bool(seg.get("is_bridge", false)):
				var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
				for i in range(poly.size()-1):
					var a2: Vector2 = poly[i]
					var b2: Vector2 = poly[i+1]
					var ab2 := b2 - a2
					var len2b := ab2.length_squared()
					if len2b < 1e-6:
						continue
					var t2 := (p - a2).dot(ab2) / len2b
					t2 = clampf(t2, 0.0, 1.0)
					var proj2 := a2 + ab2 * t2
					var w_road: float = float(seg.get("width", WorldConstants.ROAD_WIDTH_TRACK))
					if p.distance_to(proj2) < w_road * 0.5 + 2.0 and hydrology.water_body_at(proj2) != &"":
						return false
	return true

func _generate_forage() -> void:
	_forage.clear()
	_forage_by_id.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var global_forage: Array[Dictionary] = []
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var s_center: Vector2 = s["center"] as Vector2
		var id_hash: int = _hash_id(sid)
		var target: int = _forage_target_count(skind, id_hash)
		# cap per vicinity already target 2-5, but also spec per hamlet 2-3 etc handled
		var placed: Array[Dictionary] = []
		var attempts_total := 0
		var k := 0
		while k < target and attempts_total < target * 12:
			attempts_total += 1
			var r_ang: float = _unit_float_with_seed("rural_forage", [id_hash, k, attempts_total], seed_used)
			var ang: float = r_ang * TAU
			var r_rad: float = _unit_float_with_seed("rural_forage", [id_hash, k, attempts_total+100], seed_used)
			var rad: float = lerpf(12.0, WorldConstants.RURAL_FORAGE_VICINITY_M, r_rad)
			var cand: Vector2 = s_center + Vector2(cos(ang), sin(ang)) * rad
			# jitter +-3
			var jx: float = _unit_float_with_seed("rural_forage", [id_hash, k, attempts_total+200], seed_used)
			var jy: float = _unit_float_with_seed("rural_forage", [id_hash, k, attempts_total+300], seed_used)
			cand += Vector2((jx-0.5)*6.0, (jy-0.5)*6.0)
			if not _is_valid_forage_position(cand, global_forage):
				continue
			# also check per settlement vicinity cap not needed because target already capped; but enforce 4 per chunk later at manifest
			var fid: String = "rural_forage_%s_%d" % [sid, k]
			# ensure unique if duplicate
			if _forage_by_id.has(fid):
				fid = "%s_%d" % [fid, attempts_total]
			var r_kind: float = _unit_float_with_seed("rural_forage_kind", [id_hash, k], seed_used)
			var kind: StringName = WorldConstants.RURAL_FORAGE_VOCAB[0]
			# Distinct weighted partition 45/30/25 without duplicate (SPEC-C008 §1)
			if r_kind < 0.45:
				kind = WorldConstants.RURAL_FORAGE_VOCAB[0] # bush_berry 45%
			elif r_kind < 0.75:
				kind = WorldConstants.RURAL_FORAGE_VOCAB[1] if WorldConstants.RURAL_FORAGE_VOCAB.size() >1 else WorldConstants.RURAL_FORAGE_VOCAB[0] # mushroom_cluster 30%
			else:
				kind = WorldConstants.RURAL_FORAGE_VOCAB[2] if WorldConstants.RURAL_FORAGE_VOCAB.size()>2 else WorldConstants.RURAL_FORAGE_VOCAB[0] # herb_patch 25%
			# contents weighted ItemDB
			var r_item: float = _unit_float_with_seed("rural_forage_kind", [id_hash, k, 99], seed_used)
			var item_id: StringName
			if r_item < 0.40:
				item_id = &"canned_food"
			elif r_item < 0.65:
				item_id = &"water_bottle"
			elif r_item < 0.85:
				item_id = &"bandage"
			else:
				item_id = &"antibiotics"
			var contents: Dictionary = {item_id: 1}
			var dict: Dictionary = {
				"id": fid,
				"pos": cand,
				"center": cand,
				"position": Vector3(cand.x, terrain.height_at(cand)+0.01, cand.y),
				"yaw": 0.0,
				"kind": kind,
				"settlement_id": sid,
				"settlement_kind": skind,
				"distance_to_settlement": cand.distance_to(s_center),
				"contents": contents,
			}
			_forage.append(dict)
			_forage_by_id[fid] = dict
			global_forage.append(dict)
			placed.append(dict)
			k += 1
	# Sort forage by id
	_forage.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))

func _layout_slot_center(settlement_center: Vector2, settlement_radius: float, settlement_kind: StringName, slot: int, id_hash: int) -> Vector2:
	var road_point: Vector2 = _nearest_road_point(settlement_center)
	var approach: Vector2 = Vector2.ZERO
	if road_point.is_finite() and road_point.distance_to(settlement_center) > 0.5:
		approach = (road_point - settlement_center).normalized()
	if approach.length_squared() < 0.001:
		var fallback_angle: float = _unit_float_with_seed("settlement_front", [id_hash], seed_used) * TAU
		approach = Vector2(cos(fallback_angle), sin(fallback_angle))
	var away: Vector2 = -approach
	var side: Vector2 = Vector2(-approach.y, approach.x)
	var depth: float = 14.0
	var cross: float = 0.0
	if settlement_kind == &"hamlet":
		# House and barn face the same common lane; an optional stable sits
		# behind them. The common remains open toward the road.
		match slot:
			0:
				depth = 14.0; cross = -11.0
			1:
				depth = 14.0; cross = 11.0
			_:
				depth = 23.0; cross = 0.0
	elif settlement_kind == &"village":
		match slot:
			0:
				depth = 17.0; cross = -14.0
			1:
				depth = 17.0; cross = 14.0
			2:
				depth = 5.0; cross = -18.0
			3:
				depth = 5.0; cross = 18.0
			4:
				depth = 31.0; cross = -10.0
			_:
				depth = 31.0; cross = 10.0
	else:
		depth = 13.0 + float(slot) * 9.0
		cross = 0.0 if slot == 0 else (-7.0 if slot % 2 == 0 else 7.0)
	var jitter_depth: float = (_unit_float_with_seed("settlement_slot_jitter", [id_hash, slot, 0], seed_used) - 0.5) * 2.2
	var jitter_cross: float = (_unit_float_with_seed("settlement_slot_jitter", [id_hash, slot, 1], seed_used) - 0.5) * 2.0
	var local: Vector2 = away * (depth + jitter_depth) + side * (cross + jitter_cross)
	var max_radius: float = maxf(10.0, settlement_radius * 0.90)
	if local.length() > max_radius:
		local = local.normalized() * max_radius
	return settlement_center + local

func _generate() -> void:
	_buildings.clear()
	_by_settlement.clear()
	_by_id.clear()
	_wells.clear()
	_wells_by_settlement.clear()
	_wells_by_id.clear()
	_forage.clear()
	_forage_by_id.clear()
	_workbenches.clear()
	_workbenches_by_settlement.clear()
	_workbenches_by_id.clear()
	_workbench_by_building.clear()
	_granaries.clear()
	_granaries_by_settlement.clear()
	_granaries_by_id.clear()
	_granary_by_building.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var gate_barns_used: Dictionary = {}
	var gates: Array[Dictionary] = settlement.city_gates()
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var s_center: Vector2 = s["center"] as Vector2
		var s_radius: float = float(s["radius"])
		var id_hash: int = _hash_id(sid)
		var target_count: int = _target_count(skind, id_hash)
		if not _by_settlement.has(sid):
			_by_settlement[sid] = [] as Array[Dictionary]
		var placed: Array[Dictionary] = []
		for k in target_count:
			var kind_building: StringName = _choose_building_kind(skind, id_hash, k, target_count)
			var footprint: Vector2 = _footprint_for_kind(kind_building, id_hash, k)
			var floors: int = 1
			if kind_building == &"village_house":
				if skind == &"village":
					var rf: float = _unit_float_with_seed("rural_building_yaw", [id_hash, k, 11], seed_used)
					floors = 2 if rf > 0.55 else 1
				else:
					floors = 1
			var height: float = WorldConstants.RURAL_BUILDING_HEIGHT_SINGLE + float(maxi(0, floors - 1)) * WorldConstants.RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA
			var slot_center: Vector2 = _layout_slot_center(s_center, s_radius, skind, k, id_hash)
			var radius: float = slot_center.distance_to(s_center)
			var base_angle: float = atan2(slot_center.y - s_center.y, slot_center.x - s_center.x)
			var success := false
			var building_dict: Dictionary = {}
			for attempt in 24:
				var cur_radius: float = radius
				var cur_angle: float = base_angle
				if attempt > 0:
					var nudge_r: float = _unit_float_with_seed("rural_building_nudge", [id_hash, k, attempt], seed_used)
					var nudge_a: float = _unit_float_with_seed("rural_building_nudge", [id_hash, k, attempt + 100], seed_used)
					cur_radius = radius + (nudge_r - 0.5) * 12.0
					cur_angle = base_angle + (nudge_a - 0.5) * 1.0
					cur_radius = clampf(cur_radius, WorldConstants.RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE + 2.0, s_radius * 0.95)
				var cand_center: Vector2 = s_center + Vector2(cos(cur_angle), sin(cur_angle)) * cur_radius
				# G8 M4: for village second barn, bias to be 17-23 from first barn to guarantee 8-14 gap bridge
				var is_second_barn := false
				if skind == &"village" and target_count >= 5:
					var r_v2: float = _unit_float_with_seed("rural_building", [id_hash, 100], seed_used)
					var num_vh2: int = 2 + (1 if r_v2 > 0.5 else 0)
					num_vh2 = mini(num_vh2, target_count - 2)
					if k == num_vh2 + 1 and placed.size() > 0:
						is_second_barn = true
				if is_second_barn and placed.size() > 0:
					var first_barn: Dictionary = placed[placed.size() - 1] as Dictionary
					var first_c: Vector2 = first_barn.get("center", s_center) as Vector2
					var r_ang2: float = _unit_float_with_seed("rural_building", [id_hash, k, attempt, 77], seed_used)
					var ang2: float = r_ang2 * TAU
					var r_dist2: float = _unit_float_with_seed("rural_building", [id_hash, k, attempt, 78], seed_used)
					var dist2: float = lerpf(17.0, 23.0, r_dist2)
					# jitter attempt varies dist slightly
					if attempt > 0:
						dist2 += (float(attempt) - 2.0) * 0.6
						dist2 = clampf(dist2, 17.0, 23.0)
					cand_center = first_c + Vector2(cos(ang2), sin(ang2)) * dist2
					# ensure still within settlement radius; if outside, clamp toward center
					if cand_center.distance_to(s_center) > s_radius * 0.95:
						var dir_to_center := (s_center - first_c).normalized()
						if dir_to_center.length_squared() < 1e-6:
							dir_to_center = Vector2(1,0)
						cand_center = first_c + dir_to_center * 17.0
				var yaw: float = _yaw_for(cand_center, id_hash, k)
				var aabb: Rect2 = _aabb_for(cand_center, footprint, yaw)
				var is_inside_urban: bool = cand_center.length() < WorldConstants.URBAN_INNER_M - 0.5
				var allow_gate_barn := false
				if is_inside_urban:
					if kind_building == &"barn" and cand_center.length() >= WorldConstants.URBAN_INNER_M - 20.0 and cand_center.length() < WorldConstants.URBAN_INNER_M + 70.0:
						var nearest_gate_dist := INF
						var nearest_gate_id := ""
						for g in gates:
							var gc: Vector2 = g["center"] as Vector2
							var d := cand_center.distance_to(gc)
							if d < nearest_gate_dist:
								nearest_gate_dist = d
								nearest_gate_id = String(g["id"])
						if nearest_gate_dist < 140.0 and not gate_barns_used.has(nearest_gate_id):
							allow_gate_barn = true
					if not allow_gate_barn:
						continue
				if cand_center.distance_to(s_center) < WorldConstants.RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE - 1e-6:
					continue
				var t_class: StringName = terrain.terrain_class_at(cand_center)
				if t_class == &"cliff":
					continue
				var slope: float = terrain.slope_at(cand_center)
				if kind_building == &"village_house":
					if slope >= 14.0 - 1e-6:
						continue
				else:
					if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
						continue
				var body: StringName = hydrology.water_body_at(cand_center)
				if body != &"":
					continue
				if hydrology.is_floodplain(cand_center):
					continue
				var dist_water: float = hydrology.distance_to_water(cand_center)
				if dist_water <= WorldConstants.BANK_W + 2.0 + 1e-6:
					continue
				var corners_ok := true
				var eff := _effective_footprint(footprint, yaw)
				var hx2: float = eff.x * 0.5
				var hz2: float = eff.y * 0.5
				var cos_y2 := cos(yaw)
				var sin_y2 := sin(yaw)
				var corner_offsets: Array[Vector2] = []
				corner_offsets.append(Vector2(hx2, hz2))
				corner_offsets.append(Vector2(-hx2, hz2))
				corner_offsets.append(Vector2(-hx2, -hz2))
				corner_offsets.append(Vector2(hx2, -hz2))
				for off in corner_offsets:
					var wx2: float = off.x * cos_y2 - off.y * sin_y2
					var wz2: float = off.x * sin_y2 + off.y * cos_y2
					var q: Vector2 = cand_center + Vector2(wx2, wz2)
					if hydrology.water_body_at(q) != &"" or hydrology.is_floodplain(q) or hydrology.distance_to_water(q) <= WorldConstants.BANK_W + 2.0 + 1e-6:
						corners_ok = false
						break
					if terrain.terrain_class_at(q) == &"cliff":
						corners_ok = false
						break
					var s2: float = terrain.slope_at(q)
					if kind_building == &"village_house":
						if s2 >= 14.0 - 1e-6:
							corners_ok = false
							break
					else:
						if s2 >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
							corners_ok = false
							break
				if not corners_ok:
					continue
				var road_ok: bool = true
				if road_network != null:
					var d_road: float = road_network.distance_to_road(cand_center)
					var w_road: float = road_network.road_width_at(cand_center)
					if w_road <= 0.0:
						w_road = WorldConstants.ROAD_WIDTH_TRACK
					var required: float = WorldConstants.RURAL_BUILDING_ROAD_SETBACK
					if d_road < required - 1e-6:
						road_ok = false
					if road_ok and d_road < w_road * 0.5 + 4.0 + 1e-6:
						var rect2 := Rect2(cand_center - Vector2(30,30), Vector2(60,60))
						var segs2: Array[Dictionary] = road_network.road_segments_in(rect2)
						for seg in segs2:
							if bool(seg.get("is_bridge", false)):
								var poly2: PackedVector2Array = seg["polyline"] as PackedVector2Array
								for i in range(poly2.size()-1):
									var a2: Vector2 = poly2[i]
									var b2: Vector2 = poly2[i+1]
									var ab2 := b2 - a2
									var len2b := ab2.length_squared()
									if len2b < 1e-6:
										continue
									var t2 := (cand_center - a2).dot(ab2) / len2b
									t2 = clampf(t2, 0.0, 1.0)
									var proj2 := a2 + ab2 * t2
									if cand_center.distance_to(proj2) < w_road * 0.5 + 4.0 and hydrology.water_body_at(proj2) != &"":
										road_ok = false
										break
							if not road_ok:
								break
				if not road_ok:
					continue
				var spacing_ok := true
				for pb in placed:
					var pb_aabb: Rect2 = pb["aabb"] as Rect2
					var gap: float = _aabb_gap(aabb, pb_aabb)
					if gap < WorldConstants.RURAL_BUILDING_SPACING_MIN - 1e-6:
						spacing_ok = false
						break
					var pc: Vector2 = pb["center"] as Vector2
					if cand_center.distance_to(pc) < WorldConstants.RURAL_BUILDING_SPACING_MIN - 1e-6:
						spacing_ok = false
						break
				if not spacing_ok:
					continue
				var door_info: Dictionary = _door_for_building(cand_center, footprint, yaw, s_center, id_hash, k)
				var door_pos: Vector2 = door_info["pos"] as Vector2
				var door_yaw: float = float(door_info["yaw"])
				var col: Color = _palette_color(kind_building, id_hash, k)
				var roof_col: Color = _roof_color(kind_building, id_hash, k)
				var slope_deg2: float = terrain.slope_at(cand_center)
				var dist_water2: float = hydrology.distance_to_water(cand_center)
				var dist_road2: float = road_network.distance_to_road(cand_center) if road_network != null else INF
				var strata: StringName = geology.strata_at(cand_center)
				var tile := Vector2i(floori(cand_center.x / WorldConstants.LANDSCAPE_CELL_M), floori(cand_center.y / WorldConstants.LANDSCAPE_CELL_M))
				var bid: String = "rural_%s_%d" % [sid, k]
				building_dict = {
					"id": bid,
					"kind": kind_building,
					"center": cand_center,
					"footprint": footprint,
					"yaw": yaw,
					"height": height,
					"floors": floors,
					"settlement_id": sid,
					"settlement_kind": skind,
					"door_pos": door_pos,
					"door_yaw": door_yaw,
					"slope_deg": slope_deg2,
					"dist_to_water": dist_water2,
					"dist_to_road": dist_road2,
					"strata": strata,
					"tile": tile,
					"aabb": aabb,
					"color": col,
					"roof_color": roof_col,
					"allow_gate_barn": allow_gate_barn,
					"gate_id": "" if not allow_gate_barn else _nearest_gate_id(cand_center, gates),
				}
				success = true
				if allow_gate_barn:
					var gid: String = building_dict["gate_id"] as String
					if gid != "":
						gate_barns_used[gid] = true
				break
			if success and not building_dict.is_empty():
				# Enrich with interior before appending (walls/furniture+hearth)
				var b_id_hash: int = _hash_id(building_dict["id"] as String)
				var walls: Array[Dictionary] = _generate_partition_wall(building_dict, b_id_hash)
				for wall in walls:
					wall["building_id"] = building_dict["id"]
				var furn: Array[Dictionary] = _generate_furniture(building_dict, walls, b_id_hash)
				for furniture in furn:
					furniture["building_id"] = building_dict["id"]
				var hearth: Dictionary = _build_hearth(furn, building_dict)
				# Temporarily crate empty, will fill after settlement loop for hamlet/farmstead logic
				var interior: Dictionary = {"walls": walls, "furniture": furn, "crate": {}, "hearth": hearth}
				building_dict["interior"] = interior
				_buildings.append(building_dict)
				(_by_settlement[sid] as Array[Dictionary]).append(building_dict)
				_by_id[building_dict["id"] as String] = building_dict
				placed.append(building_dict)
			else:
				continue
		# Post settlement interior crate assignment and hamlet strict補填
		var placed_arr: Array[Dictionary] = _by_settlement[sid] as Array[Dictionary]
		# Ensure hamlet at least 2 buildings if target was 2-3 but dropped to 1 -> try to补 one more with relaxed attempts
		if (skind == &"hamlet" and placed_arr.size() == 1 and target_count >= 2) or (skind == &"village" and placed_arr.size() < 4):
			# attempt one more building with extra attempts and relaxed spacing? we try again with k = target_count (extra index)
			var k_extra: int = target_count
			var kind_extra: StringName = _choose_building_kind(skind, id_hash, k_extra, target_count)
			var fp_extra: Vector2 = _footprint_for_kind(kind_extra, id_hash, k_extra)
			var placed_extra_success := false
			for attempt2 in 10:
				var r_rad2: float = _unit_float_with_seed("rural_building_radius", [id_hash, k_extra+100+attempt2], seed_used)
				var rad2: float = lerpf(0.28,0.82, r_rad2)*s_radius
				var r_ang2: float = _unit_float_with_seed("rural_building_angle", [id_hash, k_extra+100+attempt2], seed_used)
				var ang2: float = r_ang2*TAU
				var cand2: Vector2 = s_center + Vector2(cos(ang2), sin(ang2))*rad2
				var yaw2: float = _yaw_for(cand2, id_hash, k_extra)
				var aabb2: Rect2 = _aabb_for(cand2, fp_extra, yaw2)
				# quick checks similar
				if cand2.distance_to(s_center) < WorldConstants.RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE -1e-6:
					continue
				if terrain.terrain_class_at(cand2)==&"cliff": continue
				var slope2:float=terrain.slope_at(cand2)
				if kind_extra==&"village_house" and slope2>=14: continue
				if kind_extra!=&"village_house" and slope2>=WorldConstants.BUILDABLE_MAX_SLOPE_DEG: continue
				if hydrology.water_body_at(cand2)!=&"": continue
				if hydrology.is_floodplain(cand2): continue
				if hydrology.distance_to_water(cand2) <= WorldConstants.BANK_W+2: continue
				if road_network.distance_to_road(cand2) < WorldConstants.RURAL_BUILDING_ROAD_SETBACK: continue
				var spacing_ok2:=true
				for pb in placed_arr:
					if _aabb_gap(aabb2, pb["aabb"] as Rect2) < WorldConstants.RURAL_BUILDING_SPACING_MIN -1e-6:
						spacing_ok2=false
						break
				if not spacing_ok2: continue
				var door2:Dictionary=_door_for_building(cand2, fp_extra, yaw2, s_center, id_hash, k_extra)
				var floors2:int=1
				var height2:float=WorldConstants.RURAL_BUILDING_HEIGHT_SINGLE+float(maxi(0, floors2-1))*WorldConstants.RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA
				var col2:Color=_palette_color(kind_extra, id_hash, k_extra)
				var roof2:Color=_roof_color(kind_extra, id_hash, k_extra)
				var bid2:String="rural_%s_%d_extra" % [sid, k_extra]
				# ensure unique id
				if _by_id.has(bid2):
					bid2 += "_%d" % attempt2
				var bdict2:Dictionary={
					"id": bid2,
					"kind": kind_extra,
					"center": cand2,
					"footprint": fp_extra,
					"yaw": yaw2,
					"height": height2,
					"floors": floors2,
					"settlement_id": sid,
					"settlement_kind": skind,
					"door_pos": door2["pos"] as Vector2,
					"door_yaw": float(door2["yaw"]),
					"slope_deg": slope2,
					"dist_to_water": hydrology.distance_to_water(cand2),
					"dist_to_road": road_network.distance_to_road(cand2),
					"strata": geology.strata_at(cand2),
					"tile": Vector2i(floori(cand2.x/WorldConstants.LANDSCAPE_CELL_M), floori(cand2.y/WorldConstants.LANDSCAPE_CELL_M)),
					"aabb": aabb2,
					"color": col2,
					"roof_color": roof2,
					"allow_gate_barn": false,
					"gate_id": "",
				}
				var idh2:int=_hash_id(bid2)
				var walls2:Array[Dictionary]=_generate_partition_wall(bdict2, idh2)
				for wall2 in walls2:
					wall2["building_id"] = bdict2["id"]
				var furn2:Array[Dictionary]=_generate_furniture(bdict2, walls2, idh2)
				for furniture2 in furn2:
					furniture2["building_id"] = bdict2["id"]
				var hearth2:Dictionary=_build_hearth(furn2, bdict2)
				bdict2["interior"]={"walls":walls2,"furniture":furn2,"crate":{},"hearth":hearth2}
				_buildings.append(bdict2)
				_by_id[bid2]=bdict2
				placed_arr.append(bdict2)
				placed_extra_success=true
				break
		# Now crate assignment per settlement
		# Refresh placed_arr
		placed_arr = _by_settlement[sid] as Array[Dictionary]
		if placed_arr.is_empty():
			continue
		if skind == &"hamlet":
			# exactly 1 crate per hamlet
			var r_choice:float=_unit_float_with_seed("rural_crate", [id_hash, 200], seed_used)
			var idx:int=int(floor(r_choice*float(placed_arr.size()))) % placed_arr.size()
			for i in placed_arr.size():
				var b:Dictionary=placed_arr[i]
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				var walls:Array[Dictionary]=[]
				var furn:Array[Dictionary]=[]
				if b.has("interior"):
					var inter:Dictionary=b["interior"] as Dictionary
					walls=inter.get("walls", []) as Array[Dictionary]
					furn=inter.get("furniture", []) as Array[Dictionary]
				var crate:Dictionary={}
				if i==idx:
					crate=_generate_crate_for_building(b, walls, furn, bhash)
				# update building dict interior crate + hearth (reuse furniture anchors)
				var hearth_h:Dictionary=_build_hearth(furn, b)
				var new_inter:Dictionary={"walls":walls,"furniture":furn,"crate":crate,"hearth":hearth_h}
				b["interior"]=new_inter
				# update global structures
				_by_id[bid]=b
				# also update _buildings entry
				for gi in _buildings.size():
					if String(_buildings[gi].get("id",""))==bid:
						_buildings[gi]=b
						break
				placed_arr[i]=b
			_by_settlement[sid]=placed_arr
		elif skind == &"farmstead" or skind == &"isolated_farm":
			# exactly 1 crate in first building
			for i in placed_arr.size():
				var b:Dictionary=placed_arr[i]
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				var walls:Array[Dictionary]=[]
				var furn:Array[Dictionary]=[]
				if b.has("interior"):
					var inter:Dictionary=b["interior"] as Dictionary
					walls=inter.get("walls", []) as Array[Dictionary]
					furn=inter.get("furniture", []) as Array[Dictionary]
				var crate:Dictionary={}
				if i==0:
					crate=_generate_crate_for_building(b, walls, furn, bhash)
				var hearth_f:Dictionary=_build_hearth(furn, b)
				var new_inter:Dictionary={"walls":walls,"furniture":furn,"crate":crate,"hearth":hearth_f}
				b["interior"]=new_inter
				_by_id[bid]=b
				for gi in _buildings.size():
					if String(_buildings[gi].get("id",""))==bid:
						_buildings[gi]=b
						break
				placed_arr[i]=b
			_by_settlement[sid]=placed_arr
		elif skind == &"village":
			# per building 35% chance, cap 3 per village
			var candidates: Array[Dictionary]=[]
			for b in placed_arr:
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				var should:bool=_unit_float_with_seed("rural_crate", [bhash, 0], seed_used) > 0.65
				if should:
					candidates.append(b)
			if candidates.size()>3:
				# keep 3 with smallest r
				candidates.sort_custom(func(a:Dictionary,b:Dictionary)->bool:
					var ha:int=_hash_id(a["id"] as String)
					var hb:int=_hash_id(b["id"] as String)
					var ra:float=_unit_float_with_seed("rural_crate", [ha, 0], seed_used)
					var rb:float=_unit_float_with_seed("rural_crate", [hb, 0], seed_used)
					return ra < rb
				)
				candidates=candidates.slice(0,3)
			var cand_ids:Dictionary={}
			for c in candidates:
				cand_ids[String(c["id"])]=true
			for i in placed_arr.size():
				var b:Dictionary=placed_arr[i]
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				var walls:Array[Dictionary]=[]
				var furn:Array[Dictionary]=[]
				if b.has("interior"):
					var inter:Dictionary=b["interior"] as Dictionary
					walls=inter.get("walls", []) as Array[Dictionary]
					furn=inter.get("furniture", []) as Array[Dictionary]
				var crate:Dictionary={}
				if cand_ids.has(bid):
					crate=_generate_crate_for_building(b, walls, furn, bhash)
				var hearth_v:Dictionary=_build_hearth(furn, b)
				var new_inter:Dictionary={"walls":walls,"furniture":furn,"crate":crate,"hearth":hearth_v}
				b["interior"]=new_inter
				_by_id[bid]=b
				for gi in _buildings.size():
					if String(_buildings[gi].get("id",""))==bid:
						_buildings[gi]=b
						break
				placed_arr[i]=b
			_by_settlement[sid]=placed_arr
		else:
			# town fallback treat as village
			var candidates2: Array[Dictionary]=[]
			for b in placed_arr:
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				if _unit_float_with_seed("rural_crate", [bhash, 0], seed_used) >0.65:
					candidates2.append(b)
			if candidates2.size()>3:
				candidates2=candidates2.slice(0,3)
			var cand_ids2:Dictionary={}
			for c in candidates2:
				cand_ids2[String(c["id"])]=true
			for i in placed_arr.size():
				var b:Dictionary=placed_arr[i]
				var bid:String=b["id"] as String
				var bhash:int=_hash_id(bid)
				var walls:Array[Dictionary]=[]
				var furn:Array[Dictionary]=[]
				if b.has("interior"):
					var inter:Dictionary=b["interior"] as Dictionary
					walls=inter.get("walls", []) as Array[Dictionary]
					furn=inter.get("furniture", []) as Array[Dictionary]
				var crate:Dictionary={}
				if cand_ids2.has(bid):
					crate=_generate_crate_for_building(b, walls, furn, bhash)
				var hearth_t:Dictionary=_build_hearth(furn, b)
				b["interior"]={"walls":walls,"furniture":furn,"crate":crate,"hearth":hearth_t}
				_by_id[bid]=b
				for gi in _buildings.size():
					if String(_buildings[gi].get("id",""))==bid:
						_buildings[gi]=b
						break
				placed_arr[i]=b
			_by_settlement[sid]=placed_arr
	# Generate wells and forage after buildings (deterministic, additive)
	_generate_wells()
	_generate_forage()
	_generate_workbenches()
	_generate_granaries()
	_generate_settlement_dressing()
	# Sort buildings by id
	_buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	for sid in _by_settlement.keys():
		var arr: Array[Dictionary] = _by_settlement[sid] as Array[Dictionary]
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"])
		)
		_by_settlement[sid] = arr


func _is_valid_workbench_position(p: Vector2, building: Dictionary, existing_workbenches: Array[Dictionary]) -> bool:
	var tclass: StringName = terrain.terrain_class_at(p)
	if tclass == &"cliff":
		return false
	var slope: float = terrain.slope_at(p)
	var kind_b: StringName = building["kind"] as StringName
	if kind_b == &"village_house":
		if slope >= 14.0 - 1e-6:
			return false
	else:
		if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
			if slope >= 22.0 - 1e-6:
				return false
	if hydrology.water_body_at(p) != &"":
		return false
	if hydrology.is_floodplain(p):
		return false
	if hydrology.distance_to_water(p) <= WorldConstants.BANK_W + 2.0 + 1e-6:
		return false
	if p.length() < WorldConstants.URBAN_INNER_M - 0.5:
		return false
	var d_road: float = road_network.distance_to_road(p) if road_network != null else INF
	if d_road < WorldConstants.RURAL_WORKBENCH_ROAD_SETBACK - 1e-6:
		return false
	var wb_aabb := Rect2(p - Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z)*0.5, Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z))
	# Hardened P5.4: explicit aabb_gap <8 -> false without intersects gate; host building excluded (gap negative)
	for b in _buildings:
		if String(b["id"]) == String(building["id"]):
			continue
		var baabb: Rect2 = b["aabb"] as Rect2
		if _aabb_gap(wb_aabb, baabb) < 8.0 - 1e-6:
			return false
	# well gap 6
	for w in _wells:
		var wpos: Vector2 = w["pos"] as Vector2
		if p.distance_to(wpos) < WorldConstants.RURAL_WORKBENCH_WELL_GAP_MIN - 1e-6:
			return false
		var waabb := Rect2(wpos - Vector2(0.9,0.9), Vector2(1.8,1.8))
		if _aabb_gap(wb_aabb, waabb) < 6.0 - 1e-6 and _aabb_gap(wb_aabb, waabb) >= 0:
			return false
	# forage gap 6
	for f in _forage:
		var fpos: Vector2 = f["pos"] as Vector2
		if p.distance_to(fpos) < WorldConstants.RURAL_WORKBENCH_FORAGE_GAP_MIN - 1e-6:
			return false
	# workbench-workbench spacing 8
	for wb in existing_workbenches:
		var opos: Vector2 = wb["pos"] as Vector2
		if p.distance_to(opos) < WorldConstants.RURAL_WORKBENCH_SPACING_MIN - 1e-6:
			return false
		var oaabb: Rect2 = wb["aabb"] as Rect2
		if _aabb_gap(wb_aabb, oaabb) < 8.0 - 1e-6:
			return false
	# is_bridge check
	if road_network != null:
		var rect2 := Rect2(p - Vector2(30,30), Vector2(60,60))
		var segs: Array[Dictionary] = road_network.road_segments_in(rect2)
		for seg in segs:
			if bool(seg.get("is_bridge", false)):
				var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
				for i in range(poly.size()-1):
					var a2: Vector2 = poly[i]
					var b2: Vector2 = poly[i+1]
					var ab2 := b2 - a2
					var len2b := ab2.length_squared()
					if len2b < 1e-6:
						continue
					var t2 := (p - a2).dot(ab2) / len2b
					t2 = clampf(t2, 0.0, 1.0)
					var proj2 := a2 + ab2 * t2
					var w_road: float = float(seg.get("width", WorldConstants.ROAD_WIDTH_TRACK))
					if p.distance_to(proj2) < w_road * 0.5 + 2.0 and hydrology.water_body_at(proj2) != &"":
						return false
	# terrain variance 0.8 across aabb corners
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	# check height variance across workbench aabb corners
	var wb_size := WorldConstants.RURAL_WORKBENCH_SIZE
	var hx := wb_size.x *0.5
	var hz := wb_size.z *0.5
	var corners: Array[Vector2] = [p+Vector2(hx,hz), p+Vector2(-hx,hz), p+Vector2(-hx,-hz), p+Vector2(hx,-hz)]
	var h0: float = terrain.height_at(corners[0])
	var h1: float = terrain.height_at(corners[1])
	var h2: float = terrain.height_at(corners[2])
	var h3: float = terrain.height_at(corners[3])
	var h_min := minf(minf(h0,h1), minf(h2,h3))
	var h_max := maxf(maxf(h0,h1), maxf(h2,h3))
	if h_max - h_min > 0.8 + 1e-6:
		return false
	# also check building inset 0.5 and furniture gaps and door swing - caller ensures
	return true

func _workbench_pos_for_building(building: Dictionary, attempt: int) -> Vector2:
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	var interior: Dictionary = building.get("interior", {}) as Dictionary
	var furniture: Array = interior.get("furniture", []) as Array
	# try reuse shelf/table anchor if exists
	for f in furniture:
		var fk: StringName = f.get("kind", &"") as StringName
		if fk == &"shelf" or fk == &"table":
			var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
			# Workbench size 1.2x0.9x0.6 ; furniture shelf is 1.2x0.4x1.1, table 1.0x1.0x0.75 ; use furniture pos directly
			if attempt == 0:
				return fpos
	# fallback: building center inset 0.7 from wall toward interior (like hearth but deterministic)
	var hx: float = footprint.x *0.5
	var hz: float = footprint.y *0.5
	# choose wall opposite door (far wall) like crate: use deterministic jitter
	var bid_hash: int = _hash_id(String(building["id"]))
	var r_off: float = _unit_float_with_seed("rural_workbench", [bid_hash, attempt], seed_used)
	var r_off2: float = _unit_float_with_seed("rural_workbench", [bid_hash, attempt+10], seed_used)
	# inset position 0.7 from each wall
	var inset := 0.7 + WorldConstants.RURAL_WORKBENCH_SIZE.x*0.5 + 0.15
	var inset_z := 0.7 + WorldConstants.RURAL_WORKBENCH_SIZE.z*0.5 + 0.15
	var local_x: float = lerpf(-hx + inset, hx - inset, r_off)
	var local_z: float = lerpf(-hz + inset_z, hz - inset_z, r_off2)
	# clamp
	local_x = clampf(local_x, -hx + inset, hx - inset)
	local_z = clampf(local_z, -hz + inset_z, hz - inset_z)
	var local := Vector2(local_x, local_z)
	return _local_to_world(center, yaw, local)

func _generate_workbenches() -> void:
	_workbenches.clear()
	_workbenches_by_settlement.clear()
	_workbenches_by_id.clear()
	_workbench_by_building.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var global_wb: Array[Dictionary] = []
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var s_center: Vector2 = s["center"] as Vector2
		var id_hash: int = _hash_id(sid)
		var buildings: Array[Dictionary] = _by_settlement.get(sid, []) as Array[Dictionary]
		if buildings.is_empty():
			continue
		# filter barn/stable
		var barn_buildings: Array[Dictionary] = []
		for b in buildings:
			var k: StringName = b["kind"] as StringName
			if k == &"barn" or k == &"stable":
				barn_buildings.append(b)
		if barn_buildings.is_empty():
			continue
		# sort barn by id_hash smallest
		barn_buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _hash_id(String(a["id"])) < _hash_id(String(b["id"])))
		var target := 0
		if skind == &"village":
			target = 1
		elif skind == &"hamlet":
			var roll: float = _unit_float_with_seed("rural_workbench_hamlet_roll", [id_hash], seed_used)
			target = 1 if roll > 0.5 else 0
		else:
			target = 0
		if target == 0:
			continue
		# pick first barn_by_hash
		var host: Dictionary = barn_buildings[0]
		var bid: String = String(host["id"])
		# Hardened P5.4: urban suppression via wb_pos.length() not host center; host already outside 350 except gate barn, but wb_pos check is atomic in _is_valid_workbench_position
		# (removed host.center.length() gate; rely on candidate p.length() <350 in _is_valid_workbench_position)
		# try 4 attempts with jitter 1.2 as spec
		var found := false
		var wb_pos: Vector2 = Vector2.ZERO
		var wb_yaw: float = float(host["yaw"])
		var wb_aabb: Rect2 = Rect2()
		var final_pos: Vector2 = Vector2.ZERO
		for attempt in 4:
			var cand: Vector2 = _workbench_pos_for_building(host, attempt)
			# Hardened P5.4: urban check via wb_pos.length() <350, not host.center
			if cand.length() < WorldConstants.URBAN_INNER_M - 0.5:
				continue
			# apply jitter 1.2 * unit_float for attempt>0
			if attempt > 0:
				var jx: float = _unit_float_with_seed("rural_workbench", [_hash_id(bid), attempt], seed_used)
				var jy: float = _unit_float_with_seed("rural_workbench", [_hash_id(bid), attempt+100], seed_used)
				cand += Vector2((jx-0.5)*1.2, (jy-0.5)*1.2)
			# check inside building aabb inset 0.5
			var building_aabb: Rect2 = host["aabb"] as Rect2
			var inset_aabb := Rect2(building_aabb.position + Vector2(0.5,0.5), building_aabb.size - Vector2(1.0,1.0))
			var cand_aabb := Rect2(cand - Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z)*0.5, Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z))
			if not inset_aabb.has_point(cand_aabb.position) or not inset_aabb.has_point(cand_aabb.end):
				continue
			# check >=0.9 from other furniture
			var interior: Dictionary = host.get("interior", {}) as Dictionary
			var furn: Array = interior.get("furniture", []) as Array
			var ok_furn := true
			for f in furn:
				var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
				var fsize: Vector3 = f.get("size", Vector3(1,1,1)) as Vector3
				var faabb: Rect2 = f.get("aabb", Rect2(fpos - Vector2(fsize.x,fsize.z)*0.5, Vector2(fsize.x,fsize.z))) as Rect2
				# if this furniture is the host shelf/table we reuse, skip check for that one (distance 0)
				if cand.distance_to(fpos) < 0.1:
					continue
				var gap: float = _aabb_gap(cand_aabb, faabb)
				if gap < 0.9 - 1e-6:
					ok_furn = false
					break
			if not ok_furn:
				continue
			# check >=1.0 from door swing
			var door_pos: Vector2 = host["door_pos"] as Vector2
			if cand.distance_to(door_pos) < 1.0 + maxf(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z)*0.5:
				var door_rect := Rect2(door_pos - Vector2(1.0,1.0), Vector2(2.0,2.0))
				if cand_aabb.intersects(door_rect):
					continue
				if cand.distance_to(door_pos) < 1.0:
					continue
			# now validate geographic gates and spacing
			if not _is_valid_workbench_position(cand, host, global_wb):
				continue
			wb_pos = cand
			wb_aabb = cand_aabb
			found = true
			break
		if not found:
			continue
		var wbid: String = "rural_workbench_%s" % sid
		# hamlet with >1 not needed but handle
		var sid_count: int = int(_workbenches_by_settlement.get(sid, [] as Array[Dictionary]).size())
		if sid_count >0:
			wbid = "rural_workbench_%s_%d" % [sid, sid_count]
		var terrain_h: float = terrain.height_at(wb_pos) + WorldConstants.WORKBENCH_LIFT_M
		var pos3 := Vector3(wb_pos.x, terrain_h, wb_pos.y)
		var wb_dict: Dictionary = {
			"id": wbid,
			"workbench_id": wbid,
			"center": wb_pos,
			"pos": wb_pos,
			"position": pos3,
			"pos3": pos3,
			"aabb": wb_aabb,
			"building_id": bid,
			"settlement_id": sid,
			"settlement_kind": skind,
			"building_kind": host["kind"] as StringName,
			"yaw": wb_yaw,
			"size": WorldConstants.RURAL_WORKBENCH_SIZE,
		}
		_workbenches.append(wb_dict)
		if not _workbenches_by_settlement.has(sid):
			_workbenches_by_settlement[sid] = [] as Array[Dictionary]
		(_workbenches_by_settlement[sid] as Array[Dictionary]).append(wb_dict)
		_workbenches_by_id[wbid] = wb_dict
		_workbench_by_building[bid] = wb_dict
		global_wb.append(wb_dict)
	# sort
	_workbenches.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for sid in _workbenches_by_settlement.keys():
		var arr: Array[Dictionary] = _workbenches_by_settlement[sid] as Array[Dictionary]
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		_workbenches_by_settlement[sid] = arr

func _is_valid_granary_position(p: Vector2, building: Dictionary, existing_granaries: Array[Dictionary]) -> bool:
	var tclass: StringName = terrain.terrain_class_at(p)
	if tclass == &"cliff":
		return false
	var slope: float = terrain.slope_at(p)
	if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 1e-6:
		if slope >= 22.0 - 1e-6:
			return false
	if hydrology.water_body_at(p) != &"":
		return false
	if hydrology.is_floodplain(p):
		return false
	if hydrology.distance_to_water(p) <= WorldConstants.BANK_W + 2.0 + 1e-6:
		return false
	if p.length() < WorldConstants.URBAN_INNER_M - 0.5:
		return false
	var d_road: float = road_network.distance_to_road(p) if road_network != null else INF
	if d_road < WorldConstants.RURAL_GRANARY_ROAD_SETBACK - 1e-6:
		return false
	var g_aabb := Rect2(p - Vector2(WorldConstants.RURAL_GRANARY_SIZE.x, WorldConstants.RURAL_GRANARY_SIZE.z)*0.5, Vector2(WorldConstants.RURAL_GRANARY_SIZE.x, WorldConstants.RURAL_GRANARY_SIZE.z))
	# Hardened: explicit aabb_gap <8 -> false without intersects gate
	for b in _buildings:
		if String(b["id"]) == String(building["id"]):
			continue
		var baabb: Rect2 = b["aabb"] as Rect2
		if _aabb_gap(g_aabb, baabb) < 8.0 - 1e-6:
			return false
	for w in _wells:
		var wpos: Vector2 = w["pos"] as Vector2
		if p.distance_to(wpos) < WorldConstants.RURAL_GRANARY_WELL_GAP_MIN - 1e-6:
			return false
		var waabb := Rect2(wpos - Vector2(0.9,0.9), Vector2(1.8,1.8))
		if _aabb_gap(g_aabb, waabb) < 6.0 - 1e-6 and _aabb_gap(g_aabb, waabb) >= 0:
			return false
	for f in _forage:
		var fpos: Vector2 = f["pos"] as Vector2
		if p.distance_to(fpos) < WorldConstants.RURAL_GRANARY_FORAGE_GAP_MIN - 1e-6:
			return false
	for wb in _workbenches:
		var opos: Vector2 = wb["pos"] as Vector2
		if p.distance_to(opos) < WorldConstants.RURAL_GRANARY_WORKBENCH_GAP_MIN - 1e-6:
			return false
		var oaabb: Rect2 = wb["aabb"] as Rect2
		if _aabb_gap(g_aabb, oaabb) < WorldConstants.RURAL_GRANARY_WORKBENCH_GAP_MIN - 1e-6:
			return false
	for gr in existing_granaries:
		var opos: Vector2 = gr["pos"] as Vector2
		if p.distance_to(opos) < WorldConstants.RURAL_GRANARY_SPACING_MIN - 1e-6:
			return false
		var oaabb: Rect2 = gr["aabb"] as Rect2
		if _aabb_gap(g_aabb, oaabb) < WorldConstants.RURAL_GRANARY_SPACING_MIN - 1e-6:
			return false
	if road_network != null:
		var rect2 := Rect2(p - Vector2(30,30), Vector2(60,60))
		var segs: Array[Dictionary] = road_network.road_segments_in(rect2)
		for seg in segs:
			if bool(seg.get("is_bridge", false)):
				var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
				for i in range(poly.size()-1):
					var a2: Vector2 = poly[i]
					var b2: Vector2 = poly[i+1]
					var ab2 := b2 - a2
					var len2b := ab2.length_squared()
					if len2b < 1e-6:
						continue
					var t2 := (p - a2).dot(ab2) / len2b
					t2 = clampf(t2, 0.0, 1.0)
					var proj2 := a2 + ab2 * t2
					var w_road: float = float(seg.get("width", WorldConstants.ROAD_WIDTH_TRACK))
					if p.distance_to(proj2) < w_road * 0.5 + 2.0 and hydrology.water_body_at(proj2) != &"":
						return false
	var hb_x: float = WorldConstants.RURAL_GRANARY_SIZE.x *0.5
	var hb_z: float = WorldConstants.RURAL_GRANARY_SIZE.z *0.5
	var corners: Array[Vector2] = [p+Vector2(hb_x,hb_z), p+Vector2(-hb_x,hb_z), p+Vector2(-hb_x,-hb_z), p+Vector2(hb_x,-hb_z)]
	var h0: float = terrain.height_at(corners[0])
	var h1: float = terrain.height_at(corners[1])
	var h2: float = terrain.height_at(corners[2])
	var h3: float = terrain.height_at(corners[3])
	var h_min := minf(minf(h0,h1), minf(h2,h3))
	var h_max := maxf(maxf(h0,h1), maxf(h2,h3))
	if h_max - h_min > 0.8 + 1e-6:
		return false
	return true

func _granary_pos_for_building(building: Dictionary, attempt: int) -> Vector2:
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var center: Vector2 = building["center"] as Vector2
	var interior: Dictionary = building.get("interior", {}) as Dictionary
	var furniture: Array = interior.get("furniture", []) as Array
	# Try reuse second furniture anchor (table/shelf not occupied by workbench)
	var wb: Dictionary = _workbench_by_building.get(String(building["id"]), {}) as Dictionary
	var wb_pos: Vector2 = wb.get("pos", Vector2.INF) as Vector2
	for f in furniture:
		var fk: StringName = f.get("kind", &"") as StringName
		if fk == &"table" or fk == &"shelf":
			var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
			if wb_pos != Vector2.INF and fpos.distance_to(wb_pos) < 0.1:
				continue
			if attempt == 0:
				return fpos
	# fallback inset
	var hx: float = footprint.x *0.5
	var hz: float = footprint.y *0.5
	var bid_hash: int = _hash_id(String(building["id"]))
	var r_off: float = _unit_float_with_seed("rural_granary", [bid_hash, attempt], seed_used)
	var r_off2: float = _unit_float_with_seed("rural_granary", [bid_hash, attempt+10], seed_used)
	var inset := 0.7 + WorldConstants.RURAL_GRANARY_SIZE.x*0.5 + 0.15
	var inset_z := 0.7 + WorldConstants.RURAL_GRANARY_SIZE.z*0.5 + 0.15
	var local_x: float = lerpf(-hx + inset, hx - inset, r_off)
	var local_z: float = lerpf(-hz + inset_z, hz - inset_z, r_off2)
	local_x = clampf(local_x, -hx + inset, hx - inset)
	local_z = clampf(local_z, -hz + inset_z, hz - inset_z)
	var local := Vector2(local_x, local_z)
	return _local_to_world(center, yaw, local)

func _generate_granaries() -> void:
	_granaries.clear()
	_granaries_by_settlement.clear()
	_granaries_by_id.clear()
	_granary_by_building.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var global_gr: Array[Dictionary] = []
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var id_hash: int = _hash_id(sid)
		var buildings: Array[Dictionary] = _by_settlement.get(sid, []) as Array[Dictionary]
		if buildings.is_empty():
			continue
		var barn_buildings: Array[Dictionary] = []
		for b in buildings:
			var k: StringName = b["kind"] as StringName
			if k == &"barn" or k == &"stable":
				barn_buildings.append(b)
		if barn_buildings.is_empty():
			continue
		barn_buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _hash_id(String(a["id"])) < _hash_id(String(b["id"])))
		var target := 0
		if skind == &"village":
			target = 1
		elif skind == &"hamlet":
			var roll: float = _unit_float_with_seed("rural_granary_hamlet_roll", [id_hash], seed_used)
			target = 1 if roll > 0.70 else 0
		else:
			target = 0
		if target == 0:
			continue
		var host: Dictionary = {}
		if skind == &"village" and barn_buildings.size() >= 2:
			host = barn_buildings[1]
		else:
			host = barn_buildings[0]
		var bid: String = String(host["id"])
		var found := false
		var g_pos: Vector2 = Vector2.ZERO
		var g_aabb: Rect2 = Rect2()
		var g_yaw: float = float(host["yaw"])
		for attempt in 4:
			var cand: Vector2 = _granary_pos_for_building(host, attempt)
			if attempt > 0:
				var jx: float = _unit_float_with_seed("rural_granary", [_hash_id(bid), attempt], seed_used)
				var jy: float = _unit_float_with_seed("rural_granary", [_hash_id(bid), attempt+100], seed_used)
				cand += Vector2((jx-0.5)*1.2, (jy-0.5)*1.2)
			if cand.length() < WorldConstants.URBAN_INNER_M - 0.5:
				continue
			var building_aabb: Rect2 = host["aabb"] as Rect2
			var inset_aabb := Rect2(building_aabb.position + Vector2(0.5,0.5), building_aabb.size - Vector2(1.0,1.0))
			var cand_aabb := Rect2(cand - Vector2(WorldConstants.RURAL_GRANARY_SIZE.x, WorldConstants.RURAL_GRANARY_SIZE.z)*0.5, Vector2(WorldConstants.RURAL_GRANARY_SIZE.x, WorldConstants.RURAL_GRANARY_SIZE.z))
			if not inset_aabb.has_point(cand_aabb.position) or not inset_aabb.has_point(cand_aabb.end):
				continue
			var interior: Dictionary = host.get("interior", {}) as Dictionary
			var furn: Array = interior.get("furniture", []) as Array
			var ok_furn := true
			for f in furn:
				var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
				var fsize: Vector3 = f.get("size", Vector3(1,1,1)) as Vector3
				var faabb: Rect2 = f.get("aabb", Rect2(fpos - Vector2(fsize.x,fsize.z)*0.5, Vector2(fsize.x,fsize.z))) as Rect2
				if cand.distance_to(fpos) < 0.1:
					continue
				var gap: float = _aabb_gap(cand_aabb, faabb)
				if gap < WorldConstants.RURAL_GRANARY_FURNITURE_GAP_MIN - 1e-6:
					ok_furn = false
					break
			if not ok_furn:
				continue
			var door_pos: Vector2 = host["door_pos"] as Vector2
			if cand.distance_to(door_pos) < WorldConstants.RURAL_GRANARY_DOOR_SWING_GAP + maxf(WorldConstants.RURAL_GRANARY_SIZE.x, WorldConstants.RURAL_GRANARY_SIZE.z)*0.5:
				var door_rect := Rect2(door_pos - Vector2(1.0,1.0), Vector2(2.0,2.0))
				if cand_aabb.intersects(door_rect):
					continue
				if cand.distance_to(door_pos) < WorldConstants.RURAL_GRANARY_DOOR_SWING_GAP:
					continue
			# workbench aabb gap >=0.9 and >=1.0 from workbench
			var wb: Dictionary = _workbench_by_building.get(bid, {}) as Dictionary
			if not wb.is_empty():
				var wpos: Vector2 = wb.get("pos", Vector2.INF) as Vector2
				if cand.distance_to(wpos) < WorldConstants.RURAL_GRANARY_WORKBENCH_GAP_MIN - 1e-6:
					continue
				var waabb: Rect2 = wb.get("aabb", Rect2()) as Rect2
				if not waabb.has_area():
					waabb = Rect2(wpos - Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z)*0.5, Vector2(WorldConstants.RURAL_WORKBENCH_SIZE.x, WorldConstants.RURAL_WORKBENCH_SIZE.z))
				if _aabb_gap(cand_aabb, waabb) < WorldConstants.RURAL_GRANARY_WORKBENCH_GAP_MIN - 1e-6:
					continue
			if not _is_valid_granary_position(cand, host, global_gr):
				continue
			g_pos = cand
			g_aabb = cand_aabb
			found = true
			break
		if not found:
			continue
		var gid: String = "rural_granary_%s" % sid
		var sid_count: int = int(_granaries_by_settlement.get(sid, [] as Array[Dictionary]).size())
		if sid_count > 0:
			gid = "rural_granary_%s_%d" % [sid, sid_count]
		var terrain_h: float = terrain.height_at(g_pos) + WorldConstants.GRANARY_LIFT_M
		var pos3 := Vector3(g_pos.x, terrain_h, g_pos.y)
		var g_dict: Dictionary = {
			"id": gid,
			"granary_id": gid,
			"center": g_pos,
			"pos": g_pos,
			"position": pos3,
			"pos3": pos3,
			"aabb": g_aabb,
			"building_id": bid,
			"settlement_id": sid,
			"settlement_kind": skind,
			"building_kind": host["kind"] as StringName,
			"yaw": g_yaw,
			"size": WorldConstants.RURAL_GRANARY_SIZE,
			"capacity": WorldConstants.RURAL_GRANARY_CAPACITY,
		}
		_granaries.append(g_dict)
		if not _granaries_by_settlement.has(sid):
			_granaries_by_settlement[sid] = [] as Array[Dictionary]
		(_granaries_by_settlement[sid] as Array[Dictionary]).append(g_dict)
		_granaries_by_id[gid] = g_dict
		_granary_by_building[bid] = g_dict
		global_gr.append(g_dict)
	_granaries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for sid in _granaries_by_settlement.keys():
		var arr: Array[Dictionary] = _granaries_by_settlement[sid] as Array[Dictionary]
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		_granaries_by_settlement[sid] = arr

func _build_hearth(furniture: Array[Dictionary], building: Dictionary) -> Dictionary:
	# Deterministic hearth reusing furniture anchors where kind==stove/bed (SPEC-C008 §1)
	var hearth: Dictionary = {}
	for f in furniture:
		var k: StringName = f.get("kind", &"") as StringName
		if k == &"stove" or k == &"bed":
			var bid: String = String(building.get("id", ""))
			var kind_str: String = String(k)
			var hid: String = "rural_%s_%s" % [kind_str, bid]
			# pos/yaw/size copied from furniture anchor, inherits its >=0.9/1.0 gates
			hearth[k] = {
				"id": hid,
				"building_id": bid,
				"kind": k,
				"pos": f.get("pos", Vector2.ZERO),
				"interior_pos": f.get("local_pos", Vector2.ZERO),
				"yaw": f.get("yaw", 0.0),
				"size": f.get("size", Vector3(0.8,0.8,0.9)),
				"settlement_id": building.get("settlement_id", ""),
				"aabb": f.get("aabb", Rect2()),
			}
	return hearth

func _nearest_gate_id(p: Vector2, gates: Array[Dictionary]) -> String:
	var best := ""
	var best_d := INF
	for g in gates:
		var gc: Vector2 = g["center"] as Vector2
		var d := p.distance_to(gc)
		if d < best_d:
			best_d = d
			best = String(g["id"])
	return best

# --- Player-facing settlement composition ----------------------------------
# These helpers turn already-generated settlement anchors/buildings into a
# coherent place: a shared green, paths to the existing road, boundary fences,
# practical clutter, and irregular edge trees. They are pure data derivation;
# materialization remains the only code allowed to create scene nodes.

func _point_near_building(p: Vector2, buildings: Array[Dictionary], gap: float) -> bool:
	for b in buildings:
		var aabb: Rect2 = b.get("aabb", Rect2()) as Rect2
		if aabb.grow(gap).has_point(p):
			return true
	return false

func _point_near_path(p: Vector2, paths: Array[Dictionary], clearance: float) -> bool:
	for path in paths:
		var a: Vector2 = path.get("a", Vector2.ZERO) as Vector2
		var b: Vector2 = path.get("b", Vector2.ZERO) as Vector2
		var d: Vector2 = b - a
		var len2: float = d.length_squared()
		if len2 < 0.0001:
			continue
		var t: float = clampf((p - a).dot(d) / len2, 0.0, 1.0)
		if p.distance_to(a + d * t) < clearance:
			return true
	return false

func _segment_touches_rect(a: Vector2, b: Vector2, rect: Rect2, pad: float) -> bool:
	var expanded: Rect2 = rect.grow(pad)
	for i in 25:
		var t: float = float(i) / 24.0
		if expanded.has_point(a.lerp(b, t)):
			return true
	return false

func _dressing_basis(center: Vector2, id_hash: int) -> Dictionary:
	var road_point: Vector2 = _nearest_road_point(center)
	var toward_road: Vector2 = Vector2.ZERO
	var tangent: Vector2 = _nearest_road_tangent(center)
	if road_point.is_finite() and road_point.distance_to(center) > 0.5:
		toward_road = (road_point - center).normalized()
	if toward_road.length_squared() < 0.001 and tangent.length_squared() > 0.001:
		toward_road = tangent.normalized()
	if toward_road.length_squared() < 0.001:
		var angle: float = _unit_float_with_seed("settlement_front", [id_hash], seed_used) * TAU
		toward_road = Vector2(cos(angle), sin(angle))
	return {"road_point": road_point, "toward_road": toward_road, "side": Vector2(-toward_road.y, toward_road.x)}

func _append_settlement_path(sid: String, index: int, a: Vector2, b: Vector2, width: float, kind: StringName) -> Dictionary:
	var path: Dictionary = {
		"id": "settlement_path_%s_%02d" % [sid, index],
		"settlement_id": sid,
		"a": a,
		"b": b,
		"width": width,
		"kind": kind,
	}
	_settlement_paths.append(path)
	return path

func _append_settlement_clutter(sid: String, index: int, kind: StringName, pos: Vector2, scale: float, yaw: float, building_id: String = "") -> void:
	_settlement_clutter.append({
		"id": "settlement_clutter_%s_%02d" % [sid, index],
		"settlement_id": sid,
		"building_id": building_id,
		"kind": kind,
		"pos": pos,
		"scale": scale,
		"yaw": yaw,
	})

func _generate_settlement_dressing() -> void:
	_settlement_paths.clear()
	_settlement_yards.clear()
	_settlement_fences.clear()
	_settlement_clutter.clear()
	_settlement_trees.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	for anchor in anchors:
		var sid: String = String(anchor.get("id", ""))
		var skind: StringName = anchor.get("kind", &"hamlet") as StringName
		if skind != &"hamlet" and skind != &"village" and skind != &"farmstead" and skind != &"isolated_farm":
			continue
		var center: Vector2 = anchor.get("center", Vector2.ZERO) as Vector2
		var radius: float = float(anchor.get("radius", 28.0))
		var id_hash: int = _hash_id(sid)
		var buildings: Array[Dictionary] = (_by_settlement.get(sid, []) as Array[Dictionary]).duplicate()
		buildings.sort_custom(_dict_id_cmp)
		if buildings.is_empty():
			continue
		var basis: Dictionary = _dressing_basis(center, id_hash)
		var road_point: Vector2 = basis["road_point"] as Vector2
		var toward_road: Vector2 = basis["toward_road"] as Vector2
		var side: Vector2 = basis["side"] as Vector2
		var has_road: bool = road_point.is_finite() and road_point.distance_to(center) > 0.5
		# The green is intentionally open. Wells and workstations generated by
		# the existing resource plans remain separate functional nodes around it.
		var yard_radius: float = WorldConstants.RURAL_YARD_RADIUS_HAMLET if skind == &"hamlet" else (WorldConstants.RURAL_YARD_RADIUS_VILLAGE if skind == &"village" else 5.5)
		_settlement_yards.append({
			"id": "settlement_yard_%s" % sid,
			"settlement_id": sid,
			"center": center,
			"radius": yard_radius,
			"kind": &"village_green" if skind == &"village" else &"common_yard",
		})
		var path_index: int = 0
		if has_road:
			_append_settlement_path(sid, path_index, road_point, center, WorldConstants.RURAL_PATH_MAIN_WIDTH if skind == &"village" else WorldConstants.RURAL_PATH_HAMLET_WIDTH, &"cart_track")
			path_index += 1
		# Every door gets a short footpath to the common space. This is what
		# makes the radial building cluster read as one settlement rather than
		# unrelated random props.
		for b in buildings:
			var door_pos: Vector2 = b.get("door_pos", b.get("center", center)) as Vector2
			var join: Vector2 = center
			var to_center: Vector2 = center - door_pos
			if to_center.length_squared() > 0.001:
				join = center - to_center.normalized() * minf(yard_radius * 0.72, to_center.length() * 0.35)
			_append_settlement_path(sid, path_index, door_pos, join, WorldConstants.RURAL_PATH_FOOT_WIDTH if skind == &"village" else WorldConstants.RURAL_PATH_FOOT_HAMLET_WIDTH, &"footpath")
			path_index += 1
		# A small deterministic fence enclosure sits on the far side of the
		# common, leaving the approach and all door paths open. Segment angles
		# are jittered, so the boundary never exposes a polygon/grid pattern.
		var fence_count: int = WorldConstants.RURAL_FENCE_MAX_PER_VILLAGE if skind == &"village" else (WorldConstants.RURAL_FENCE_MAX_PER_HAMLET if skind == &"hamlet" else 5)
		var fence_radius: float = radius * 0.92
		var fence_points: Array[Vector2] = []
		for fi in fence_count + 1:
			var fr: float = _unit_float_with_seed("settlement_fence_radius", [id_hash, fi], seed_used)
			var jitter: float = (_unit_float_with_seed("settlement_fence_angle", [id_hash, fi], seed_used) - 0.5) * 0.20
			var angle: float = atan2((-toward_road).y, (-toward_road).x) - 1.20 + float(fi) * 2.40 / float(fence_count) + jitter
			var point_radius: float = fence_radius * (0.88 + fr * 0.12)
			fence_points.append(center + Vector2(cos(angle), sin(angle)) * point_radius)
		for fi in fence_count:
			var fa: Vector2 = fence_points[fi]
			var fb: Vector2 = fence_points[fi + 1]
			var mid: Vector2 = (fa + fb) * 0.5
			if _point_near_path(mid, _settlement_paths, 2.2) or _point_near_building(mid, buildings, 2.0):
				continue
			_settlement_fences.append({
				"id": "settlement_fence_%s_%02d" % [sid, fi],
				"settlement_id": sid,
				"a": fa,
				"b": fb,
				"height": lerpf(WorldConstants.RURAL_FENCE_HEIGHT_MIN, WorldConstants.RURAL_FENCE_HEIGHT_MAX, _unit_float_with_seed("settlement_fence_height", [id_hash, fi], seed_used)),
				"kind": &"yard_fence",
			})
		# Leave a real gate at the road approach. It is a visual cue and a
		# navigable opening, not an opaque wall across the track.
		var gate_pos: Vector2 = center + toward_road * fence_radius
		if has_road:
			gate_pos = center.lerp(road_point, 0.48)
		_append_settlement_clutter(sid, 80, &"signpost", gate_pos, 0.9, atan2(toward_road.y, toward_road.x))
		# Work yards are legible through purposeful clutter. Positions are
		# derived from each existing building, never free-floating world noise.
		var clutter_index: int = 0
		for b in buildings:
			var bid: String = String(b.get("id", ""))
			var bcenter: Vector2 = b.get("center", center) as Vector2
			var outward: Vector2 = (bcenter - center).normalized()
			if outward.length_squared() < 0.001:
				outward = toward_road
			var door: Vector2 = b.get("door_pos", bcenter) as Vector2
			var door_out: Vector2 = (door - bcenter).normalized()
			if door_out.length_squared() < 0.001:
				door_out = outward
			var kind_b: StringName = b.get("kind", &"cottage") as StringName
			var prop_pos: Vector2 = door + door_out * 1.8 + side * ((_unit_float_with_seed("settlement_clutter_side", [id_hash, clutter_index], seed_used) - 0.5) * 1.4)
			if not _point_near_building(prop_pos, buildings, 0.4) and not _point_near_path(prop_pos, _settlement_paths, 1.0):
				_append_settlement_clutter(sid, clutter_index, &"barrel", prop_pos, 0.85, _unit_float_with_seed("settlement_clutter_yaw", [id_hash, clutter_index], seed_used) * TAU, bid)
				clutter_index += 1
			if kind_b == &"barn" or kind_b == &"stable":
				var yard_pos: Vector2 = bcenter + side * 3.0 - outward * 2.0
				if not _point_near_building(yard_pos, buildings, 0.5):
					_append_settlement_clutter(sid, clutter_index, &"cart", yard_pos, 0.9, atan2(toward_road.y, toward_road.x), bid)
					clutter_index += 1
				var wood_pos: Vector2 = bcenter - outward * 3.2 + side * 2.0
				if not _point_near_building(wood_pos, buildings, 0.6):
					_append_settlement_clutter(sid, clutter_index, &"wood_pile", wood_pos, 0.85, 0.0, bid)
					clutter_index += 1
			else:
				var tool_pos: Vector2 = bcenter - outward * 2.6 + side * 1.5
				if not _point_near_building(tool_pos, buildings, 0.5):
					_append_settlement_clutter(sid, clutter_index, &"tool_rack", tool_pos, 0.72, atan2(door_out.y, door_out.x), bid)
					clutter_index += 1
		# Even a heavily rejected doorway prop should not leave the common
		# visually empty. These deterministic common-yard pieces are placed
		# only when the building-derived clutter did not find enough room.
		var minimum_clutter: int = 6 if skind == &"village" else (4 if skind == &"hamlet" else 2)
		var fallback_clutter_positions: Array[Vector2] = [
			center + side * 3.8 - toward_road * 1.5,
			center - side * 3.8 - toward_road * 1.5,
			center + side * 2.8 + toward_road * 2.3,
			center - side * 2.8 + toward_road * 2.3,
			center - toward_road * 4.5,
			center - toward_road * 6.0 + side * 1.8,
		]
		var fallback_kinds: Array[StringName] = [&"barrel", &"hay_stack", &"wood_pile", &"barrel", &"signpost", &"tool_rack"]
		for fi in fallback_clutter_positions.size():
			if clutter_index >= minimum_clutter:
				break
			var fallback_pos: Vector2 = fallback_clutter_positions[fi]
			if not WorldConstants.is_inside_world(fallback_pos) or _point_near_building(fallback_pos, buildings, 0.25):
				continue
			_append_settlement_clutter(sid, 90 + fi, fallback_kinds[fi], fallback_pos, 0.72 + float(fi % 2) * 0.12, _unit_float_with_seed("settlement_fallback_clutter_yaw", [id_hash, fi], seed_used) * TAU)
			clutter_index += 1
		# Irregular boundary trees provide scale and a readable edge without
		# competing with existing forest generation. The rejection checks are
		# the exclusion zones for doors, buildings, roads and paths.
		var tree_target: int = WorldConstants.RURAL_SETTLEMENT_TREES_VILLAGE if skind == &"village" else (WorldConstants.RURAL_SETTLEMENT_TREES_HAMLET if skind == &"hamlet" else 5)
		var local_trees: Array[Vector2] = []
		for ti in tree_target * 2:
			if local_trees.size() >= tree_target:
				break
			var tr: float = _unit_float_with_seed("settlement_tree_radius", [id_hash, ti], seed_used)
			var ta: float = _unit_float_with_seed("settlement_tree_angle", [id_hash, ti], seed_used) * TAU + float(ti) * 0.37
			var tree_pos: Vector2 = center + Vector2(cos(ta), sin(ta)) * (radius * (1.10 + tr * 0.42))
			if not WorldConstants.is_inside_world(tree_pos) or tree_pos.length() < WorldConstants.URBAN_INNER_M + 2.0:
				continue
			if terrain.terrain_class_at(tree_pos) == &"cliff" or terrain.slope_at(tree_pos) >= 30.0:
				continue
			if hydrology.water_body_at(tree_pos) != &"" or hydrology.is_floodplain(tree_pos):
				continue
			if road_network != null and road_network.distance_to_road(tree_pos) < WorldConstants.RURAL_SETTLEMENT_TREE_ROAD_CLEARANCE:
				continue
			if _point_near_building(tree_pos, buildings, WorldConstants.RURAL_SETTLEMENT_TREE_BUILDING_CLEARANCE) or _point_near_path(tree_pos, _settlement_paths, WorldConstants.RURAL_SETTLEMENT_TREE_PATH_CLEARANCE):
				continue
			var spaced: bool = true
			for other_tree in local_trees:
				if tree_pos.distance_to(other_tree) < WorldConstants.RURAL_SETTLEMENT_TREE_MIN_SPACING:
					spaced = false
					break
			if not spaced:
				continue
			local_trees.append(tree_pos)
			var species_roll: float = _unit_float_with_seed("settlement_tree_species", [id_hash, ti], seed_used)
			var species: StringName = &"birch" if species_roll < 0.28 else (&"beech" if species_roll < 0.70 else &"pine")
			_settlement_trees.append({
				"id": "settlement_tree_%s_%02d" % [sid, local_trees.size() - 1],
				"settlement_id": sid,
				"pos": tree_pos,
				"kind": species,
				"scale": 0.82 + _unit_float_with_seed("settlement_tree_scale", [id_hash, ti], seed_used) * 0.48,
				"yaw": _unit_float_with_seed("settlement_tree_yaw", [id_hash, ti], seed_used) * TAU,
			})
	# Stable ordering is part of the manifest contract and makes streamed
	# chunk materialization independent of query order.
	_settlement_paths.sort_custom(_dict_id_cmp)
	_settlement_yards.sort_custom(_dict_id_cmp)
	_settlement_fences.sort_custom(_dict_id_cmp)
	_settlement_clutter.sort_custom(_dict_id_cmp)
	_settlement_trees.sort_custom(_dict_id_cmp)

func settlement_paths() -> Array[Dictionary]:
	return _settlement_paths.duplicate()

func settlement_paths_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for path in _settlement_paths:
		var a: Vector2 = path.get("a", Vector2.ZERO) as Vector2
		var b: Vector2 = path.get("b", Vector2.ZERO) as Vector2
		var width: float = float(path.get("width", 1.5))
		if _segment_touches_rect(a, b, rect, width * 0.5 + 0.1):
			out.append(path)
	return out

func settlement_yards() -> Array[Dictionary]:
	return _settlement_yards.duplicate()

func settlement_yards_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for yard in _settlement_yards:
		var center: Vector2 = yard.get("center", Vector2.ZERO) as Vector2
		if rect.grow(float(yard.get("radius", 6.0)) + 0.1).has_point(center):
			out.append(yard)
	return out

func settlement_fences() -> Array[Dictionary]:
	return _settlement_fences.duplicate()

func settlement_fences_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for fence in _settlement_fences:
		var a: Vector2 = fence.get("a", Vector2.ZERO) as Vector2
		var b: Vector2 = fence.get("b", Vector2.ZERO) as Vector2
		if _segment_touches_rect(a, b, rect, 1.0):
			out.append(fence)
	return out

func settlement_clutter() -> Array[Dictionary]:
	return _settlement_clutter.duplicate()

func settlement_clutter_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for prop in _settlement_clutter:
		var pos: Vector2 = prop.get("pos", Vector2.ZERO) as Vector2
		if rect.grow(2.0).has_point(pos):
			out.append(prop)
	return out

func settlement_trees() -> Array[Dictionary]:
	return _settlement_trees.duplicate()

func settlement_trees_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for tree in _settlement_trees:
		var pos: Vector2 = tree.get("pos", Vector2.ZERO) as Vector2
		if rect.grow(2.0).has_point(pos):
			out.append(tree)
	return out


func rural_buildings() -> Array[Dictionary]:
	return _buildings.duplicate()

func rural_buildings_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var grown: Rect2 = rect.grow(32.0)
	for b in _buildings:
		var aabb: Rect2 = b["aabb"] as Rect2
		var center: Vector2 = b["center"] as Vector2
		if aabb.intersects(rect) or grown.has_point(center):
			out.append(b)
	return out

func nearest_rural_building(p: Vector2) -> Dictionary:
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

func rural_building_at(p: Vector2) -> Dictionary:
	var body: StringName = hydrology.water_body_at(p)
	if body != &"":
		return {}
	for b in _buildings:
		var aabb: Rect2 = b["aabb"] as Rect2
		if not aabb.has_point(p):
			continue
		var center: Vector2 = b["center"] as Vector2
		var footprint: Vector2 = b["footprint"] as Vector2
		var yaw: float = float(b["yaw"])
		var eff := _effective_footprint(footprint, yaw)
		var rel := p - center
		var cos_y := cos(-yaw)
		var sin_y := sin(-yaw)
		var lx: float = rel.x * cos_y - rel.y * sin_y
		var lz: float = rel.x * sin_y + rel.y * cos_y
		var inside_x: bool = absf(lx) <= eff.x * 0.5 - 0.5
		var inside_z: bool = absf(lz) <= eff.y * 0.5 - 0.5
		if inside_x and inside_z:
			var mid := (p + center) * 0.5
			if hydrology.water_body_at(mid) != &"":
				continue
			return b
		var dist: float = p.distance_to(center)
		if dist < footprint.length() * 0.4:
			var mid2 := (p + center) * 0.5
			if hydrology.water_body_at(mid2) != &"":
				continue
			return b
	return {}

func settlement_buildings(settlement_id: String) -> Array[Dictionary]:
	if _by_settlement.has(settlement_id):
		return (_by_settlement[settlement_id] as Array[Dictionary]).duplicate()
	return [] as Array[Dictionary]

func buildings_in(rect: Rect2) -> Array[Dictionary]:
	return rural_buildings_in(rect)

func interior_walls_for(building_id: String) -> Array[Dictionary]:
	if _by_id.has(building_id):
		var b:Dictionary=_by_id[building_id] as Dictionary
		if b.has("interior"):
			return (b["interior"] as Dictionary).get("walls", []) as Array[Dictionary]
	return [] as Array[Dictionary]

func furniture_for(building_id: String) -> Array[Dictionary]:
	if _by_id.has(building_id):
		var b:Dictionary=_by_id[building_id] as Dictionary
		if b.has("interior"):
			return (b["interior"] as Dictionary).get("furniture", []) as Array[Dictionary]
	return [] as Array[Dictionary]

func crate_for(building_id: String) -> Dictionary:
	if _by_id.has(building_id):
		var b:Dictionary=_by_id[building_id] as Dictionary
		if b.has("interior"):
			return (b["interior"] as Dictionary).get("crate", {}) as Dictionary
	return {}

func rural_wells() -> Array[Dictionary]:
	return _wells.duplicate()

func rural_wells_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for w in _wells:
		var c: Vector2 = w["center"] as Vector2
		if rect.has_point(c):
			out.append(w)
	return out

func nearest_rural_well(p: Vector2) -> Dictionary:
	if _wells.is_empty():
		return {}
	var best: Dictionary = _wells[0]
	var best_d2: float = p.distance_squared_to(best["center"] as Vector2)
	for i in range(1, _wells.size()):
		var w: Dictionary = _wells[i]
		var d2: float = p.distance_squared_to(w["center"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = w
		elif is_equal_approx(d2, best_d2):
			if String(w["id"]) < String(best["id"]):
				best = w
	return best

func rural_forage_patches() -> Array[Dictionary]:
	return _forage.duplicate()

func rural_forage_patches_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for f in _forage:
		var c: Vector2 = f["pos"] as Vector2
		if rect.has_point(c):
			out.append(f)
	return out

func nearest_rural_forage(p: Vector2) -> Dictionary:
	if _forage.is_empty():
		return {}
	var best: Dictionary = _forage[0]
	var best_d2: float = p.distance_squared_to(best["pos"] as Vector2)
	for i in range(1, _forage.size()):
		var f: Dictionary = _forage[i]
		var d2: float = p.distance_squared_to(f["pos"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = f
		elif is_equal_approx(d2, best_d2):
			if String(f["id"]) < String(best["id"]):
				best = f
	return best

func wells_for_settlement(settlement_id: String) -> Array[Dictionary]:
	if _wells_by_settlement.has(settlement_id):
		return (_wells_by_settlement[settlement_id] as Array[Dictionary]).duplicate()
	return [] as Array[Dictionary]

func forage_for_settlement(settlement_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for f in _forage:
		if String(f.get("settlement_id","")) == settlement_id:
			out.append(f)
	return out

func rural_hearths_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in _buildings:
		var interior: Dictionary = b.get("interior", {}) as Dictionary
		var hearth: Dictionary = interior.get("hearth", {}) as Dictionary
		for kind in hearth.keys():
			var h: Dictionary = hearth[kind] as Dictionary
			var pos: Vector2 = h.get("pos", Vector2.ZERO) as Vector2
			if rect.has_point(pos):
				# enrich with building center check for ownership? but query is clipped by hearth pos
				out.append(h)
	# Also include direct fallback: if hearth dict empty, derive from furniture where kind==stove/bed (backward compat)
	# Already covered via _build_hearth so not needed
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func nearest_rural_hearth(p: Vector2, kind: StringName = &"") -> Dictionary:
	var candidates: Array[Dictionary] = []
	for b in _buildings:
		var interior: Dictionary = b.get("interior", {}) as Dictionary
		var hearth: Dictionary = interior.get("hearth", {}) as Dictionary
		for k in hearth.keys():
			var h: Dictionary = hearth[k] as Dictionary
			if kind != &"" and StringName(str(h.get("kind", &""))) != kind:
				continue
			candidates.append(h)
	if candidates.is_empty():
		return {}
	var best: Dictionary = candidates[0]
	var best_d2: float = p.distance_squared_to(best["pos"] as Vector2)
	for i in range(1, candidates.size()):
		var h: Dictionary = candidates[i]
		var d2: float = p.distance_squared_to(h["pos"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = h
		elif is_equal_approx(d2, best_d2):
			if String(h["id"]) < String(best["id"]):
				best = h
	return best

func rural_workbenches() -> Array[Dictionary]:
	return _workbenches.duplicate()

func rural_workbenches_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for w in _workbenches:
		var c: Vector2 = w["center"] as Vector2
		if rect.has_point(c):
			out.append(w)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func nearest_rural_workbench(p: Vector2) -> Dictionary:
	if _workbenches.is_empty():
		return {}
	var best: Dictionary = _workbenches[0]
	var best_d2: float = p.distance_squared_to(best["center"] as Vector2)
	for i in range(1, _workbenches.size()):
		var w: Dictionary = _workbenches[i]
		var d2: float = p.distance_squared_to(w["center"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = w
		elif is_equal_approx(d2, best_d2):
			if String(w["id"]) < String(best["id"]):
				best = w
	return best

func workbench_for_building(building_id: String) -> Dictionary:
	if _workbench_by_building.has(building_id):
		return _workbench_by_building[building_id] as Dictionary
	return {}

func workbenches_for_settlement(settlement_id: String) -> Array[Dictionary]:
	if _workbenches_by_settlement.has(settlement_id):
		return (_workbenches_by_settlement[settlement_id] as Array[Dictionary]).duplicate()
	return [] as Array[Dictionary]

func rural_granaries() -> Array[Dictionary]:
	return _granaries.duplicate()

func rural_granaries_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g in _granaries:
		var c: Vector2 = g["center"] as Vector2
		if rect.has_point(c):
			out.append(g)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func nearest_rural_granary(p: Vector2) -> Dictionary:
	if _granaries.is_empty():
		return {}
	var best: Dictionary = _granaries[0]
	var best_d2: float = p.distance_squared_to(best["center"] as Vector2)
	for i in range(1, _granaries.size()):
		var g: Dictionary = _granaries[i]
		var d2: float = p.distance_squared_to(g["center"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = g
		elif is_equal_approx(d2, best_d2):
			if String(g["id"]) < String(best["id"]):
				best = g
	return best

func granary_for_building(building_id: String) -> Dictionary:
	if _granary_by_building.has(building_id):
		return _granary_by_building[building_id] as Dictionary
	return {}

func granaries_for_settlement(settlement_id: String) -> Array[Dictionary]:
	if _granaries_by_settlement.has(settlement_id):
		return (_granaries_by_settlement[settlement_id] as Array[Dictionary]).duplicate()
	return [] as Array[Dictionary]

func hearths_for_settlement(settlement_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in _buildings:
		if String(b.get("settlement_id","")) != settlement_id:
			continue
		var interior: Dictionary = b.get("interior", {}) as Dictionary
		var hearth: Dictionary = interior.get("hearth", {}) as Dictionary
		for k in hearth.keys():
			out.append(hearth[k] as Dictionary)
	return out
