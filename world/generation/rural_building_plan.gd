class_name RuralBuildingPlan
extends RefCounted
## Pure rural building plan: deterministic low-rise shelters clustered around settlement anchors.
## No Node access, no unseeded randomness, no chunk-local state.
## Generation contract matches SPEC-C005 P4.2-RURAL-FABRIC.

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

static var _cache: Dictionary = {} # seed -> {buildings: Array, by_settlement: Dictionary, by_id: Dictionary}

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
		return
	_generate()
	# deep copy into cache
	var bs_copy := {}
	for k in _by_settlement.keys():
		bs_copy[k] = (_by_settlement[k] as Array[Dictionary]).duplicate()
	_cache[seed_used] = {"buildings": _buildings.duplicate(), "by_settlement": bs_copy, "by_id": _by_id.duplicate()}

func _hash_id(s: String) -> int:
	return WorldSeed.str_hash(s)

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
			# village 4-6 mixed: village_house 2-3, barn 1, cottage 1-2
			# Compute num village_house
			var r_v: float = _unit_float_with_seed("rural_building", [id_hash, 100], seed_used)
			var num_vh: int = 2 + (1 if r_v > 0.5 else 0) # 2 or 3
			num_vh = mini(num_vh, count - 1) # ensure at least 1 for barn
			if k < num_vh:
				return &"village_house"
			elif k == num_vh:
				return &"barn"
			else:
				return &"cottage"
		&"hamlet":
			# hamlet 2-3: 1-2 cottage/village_house, 0-1 barn/stable
			if count == 2:
				var has_barn: bool = _unit_float_with_seed("rural_building", [id_hash, 102], seed_used) > 0.5
				if has_barn:
					return &"barn" if k == 1 else (&"cottage" if r_kind > 0.5 else &"village_house")
				else:
					return &"cottage" if k == 0 else &"village_house" if r_kind > 0.5 else &"cottage"
			else: # count 3
				if k < 2:
					return &"cottage" if k == 0 else &"village_house" if r_kind > 0.45 else &"cottage"
				else:
					# third is barn/stable 70% barn
					return &"barn" if _unit_float_with_seed("rural_building", [id_hash, 103], seed_used) > 0.3 else &"stable"
		&"farmstead":
			if count == 1:
				return &"farmhouse"
			else:
				if k == 0:
					return &"farmhouse"
				else:
					return &"barn" if _unit_float_with_seed("rural_building", [id_hash, 104], seed_used) > 0.4 else &"stable"
		&"isolated_farm":
			# 1 building: farmhouse 60% else barn
			return &"farmhouse" if _unit_float_with_seed("rural_building", [id_hash, 105], seed_used) > 0.4 else &"barn"
		_:
			# fallback treat as farmstead
			return &"farmhouse" if k == 0 else &"barn"

func _target_count(settlement_kind: StringName, id_hash: int) -> int:
	match settlement_kind:
		&"village":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 4 + int(floor(r * 3.0)) # 4,5,6
		&"hamlet":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 2 + int(floor(r * 2.0)) # 2,3 (r=0.99 -> 2+1=3, r=0.1 ->2)
		&"farmstead":
			var r: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 1 + int(floor(r * 2.0)) # 1,2
		&"isolated_farm":
			return 1
		_:
			# town -> treat as village
			var r2: float = _unit_float_with_seed("rural_building_count", [id_hash], seed_used)
			return 4 + int(floor(r2 * 3.0))

func _nearest_road_tangent(p: Vector2) -> Vector2:
	# Find nearest road segment edge tangent via road_segments_in small rect
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
			# Ensure quantized to cardinal set
			# Wrap to -PI..PI
			q = wrapf(q, -PI, PI)
			# Map PI -> PI, -PI -> PI? Keep PI
			if is_equal_approx(absf(q), PI):
				q = PI
			return q
	# quantized random
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
	# Cardinal yaw: swap if 90 deg
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint

func _aabb_for(center: Vector2, footprint: Vector2, yaw: float) -> Rect2:
	var eff := _effective_footprint(footprint, yaw)
	return Rect2(center - eff * 0.5, eff)

func _door_for_building(center: Vector2, footprint: Vector2, yaw: float, settlement_center: Vector2, id_hash: int, k: int) -> Dictionary:
	var eff := _effective_footprint(footprint, yaw)
	var hx: float = eff.x * 0.5
	var hz: float = eff.y * 0.5
	# For cardinal yaw, edge centers world offsets - use ORIGINAL footprint halves for local
	var hx_local: float = footprint.x * 0.5
	var hz_local: float = footprint.y * 0.5
	var cos_y := cos(yaw)
	var sin_y := sin(yaw)
	# Compute edge centers and normals
	# Edge +X local (hx,0)
	# Edge -X (-hx,0)
	# Edge +Z (0,hz)
	# Edge -Z (0,-hz)
	var edges: Array[Dictionary] = []
	# helper to transform local to world
	# local (lx,lz) -> world (lx*cos - lz*sin, lx*sin + lz*cos)
	var lx_arr: Array[float] = [hx_local, -hx_local, 0.0, 0.0]
	var lz_arr: Array[float] = [0.0, 0.0, hz_local, -hz_local]
	var nx_arr: Array[float] = [1.0, -1.0, 0.0, 0.0]
	var nz_arr: Array[float] = [0.0, 0.0, 1.0, -1.0]
	for ei in 4:
		var lx: float = lx_arr[ei]
		var lz: float = lz_arr[ei]
		var wx: float = lx * cos_y - lz * sin_y
		var wz: float = lx * sin_y + lz * cos_y
		var edge_center := center + Vector2(wx, wz)
		# normal local (nx,nz) -> world
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
		# find nearest road point
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
		# if building at settlement center, choose deterministic edge via hash
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
	var r: float = _unit_float_with_seed("rural_building_palette", [id_hash, k + 100], seed_used)
	# 0..1
	if r < 0.6:
		return Color("8a3a2a")
	else:
		return Color("5a5a5a")

func _generate() -> void:
	_buildings.clear()
	_by_settlement.clear()
	_by_id.clear()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	# For gate barn exception tracking
	var gate_barns_used: Dictionary = {} # gate_id -> bool
	var gates: Array[Dictionary] = settlement.city_gates()
	for s in anchors:
		var sid: String = String(s["id"])
		var skind: StringName = s["kind"] as StringName
		var s_center: Vector2 = s["center"] as Vector2
		var s_radius: float = float(s["radius"])
		var id_hash: int = _hash_id(sid)
		var target_count: int = _target_count(skind, id_hash)
		# Initialize per-settlement list
		if not _by_settlement.has(sid):
			_by_settlement[sid] = [] as Array[Dictionary]
		var placed: Array[Dictionary] = []
		for k in target_count:
			var kind_building: StringName = _choose_building_kind(skind, id_hash, k, target_count)
			var footprint: Vector2 = _footprint_for_kind(kind_building, id_hash, k)
			# Floors and height
			var floors: int = 1
			if kind_building == &"village_house":
				# hamlet houses 1 only, village 1-2
				if skind == &"village":
					var rf: float = _unit_float_with_seed("rural_building_yaw", [id_hash, k, 11], seed_used)
					floors = 2 if rf > 0.55 else 1
				else:
					floors = 1
			var height: float = WorldConstants.RURAL_BUILDING_HEIGHT_SINGLE + float(floors) * WorldConstants.RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA
			# base polar
			var r_rad: float = _unit_float_with_seed("rural_building_radius", [id_hash, k], seed_used)
			var radius: float = lerpf(0.28, 0.82, r_rad) * s_radius
			var r_ang: float = _unit_float_with_seed("rural_building_angle", [id_hash, k], seed_used)
			var base_angle: float = r_ang * TAU
			# yaw for this building (use candidate center approximated as s_center+polar for yaw decision? Need candidate center first)
			# We'll compute yaw after we have candidate center; but footprint needs yaw for aabb. So we can compute yaw lazily per attempt.
			var success := false
			var building_dict: Dictionary = {}
			for attempt in 5:
				var cur_radius: float = radius
				var cur_angle: float = base_angle
				if attempt > 0:
					var nudge_r: float = _unit_float_with_seed("rural_building_nudge", [id_hash, k, attempt], seed_used)
					var nudge_a: float = _unit_float_with_seed("rural_building_nudge", [id_hash, k, attempt + 100], seed_used)
					cur_radius = radius + (nudge_r - 0.5) * 12.0
					cur_angle = base_angle + (nudge_a - 0.5) * 1.0
					# clamp radius to avoid negative or extreme
					cur_radius = clampf(cur_radius, WorldConstants.RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE + 2.0, s_radius * 0.95)
				var cand_center: Vector2 = s_center + Vector2(cos(cur_angle), sin(cur_angle)) * cur_radius
				# Compute yaw for cand
				var yaw: float = _yaw_for(cand_center, id_hash, k)
				var aabb: Rect2 = _aabb_for(cand_center, footprint, yaw)
				# Validate gate urban exception before heavy checks
				var is_inside_urban: bool = cand_center.length() < WorldConstants.URBAN_INNER_M - 0.5
				var allow_gate_barn := false
				if is_inside_urban:
					# check if this is barn and near gate and within gate barn band
					if kind_building == &"barn" and cand_center.length() >= WorldConstants.URBAN_INNER_M - 20.0 and cand_center.length() < WorldConstants.URBAN_INNER_M + 70.0:
						# find nearest gate
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
						continue # reject inside urban
				# Check inner clearance
				if cand_center.distance_to(s_center) < WorldConstants.RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE - 1e-6:
					continue
				# Terrain checks
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
				# Hydrology checks
				var body: StringName = hydrology.water_body_at(cand_center)
				if body != &"":
					continue
				if hydrology.is_floodplain(cand_center):
					continue
				var dist_water: float = hydrology.distance_to_water(cand_center)
				if dist_water <= WorldConstants.BANK_W + 2.0 + 1e-6:
					continue
				# Check footprint corners also avoid water/flood/cliff to ensure entire building not overlapping
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
				# Road setback
				var road_ok: bool = true
				if road_network != null:
					var d_road: float = road_network.distance_to_road(cand_center)
					var w_road: float = road_network.road_width_at(cand_center)
					if w_road <= 0.0:
						w_road = WorldConstants.ROAD_WIDTH_TRACK
					var required: float = WorldConstants.RURAL_BUILDING_ROAD_SETBACK
					if k == 0:
						required = 2.5
					if d_road < required - 1e-6:
						road_ok = false
					# Also check never on bridge: if candidate over water bridge deck, already rejected via water, but also check is_bridge proximity?
					# If nearest road segment is bridge and candidate within width*0.5+2.5 of its centerline over water, reject
					# Use nearest road point distance < width*0.5+2.5 and that segment is_bridge true
					if road_ok and d_road < w_road * 0.5 + 2.5 + 1e-6:
						# find nearest segment's is_bridge
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
									if cand_center.distance_to(proj2) < w_road * 0.5 + 2.5 and hydrology.water_body_at(proj2) != &"":
										road_ok = false
										break
							if not road_ok:
								break
				if not road_ok:
					continue
				# Spacing from previously placed in same settlement
				var spacing_ok := true
				for pb in placed:
					var pc: Vector2 = pb["center"] as Vector2
					if cand_center.distance_to(pc) < WorldConstants.RURAL_BUILDING_SPACING_MIN - 1e-6:
						spacing_ok = false
						break
					# also check aabb spacing? spec says >=8 m spaced via aabb, but center distance >=8 ensures for small footprints 8-14, aabb spacing approximated.
					# Could also check footprint separation but center distance is simpler and stricter.
				if not spacing_ok:
					continue
				# All gates passed
				# Compute door, colors, etc.
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
				_buildings.append(building_dict)
				(_by_settlement[sid] as Array[Dictionary]).append(building_dict)
				_by_id[building_dict["id"] as String] = building_dict
				placed.append(building_dict)
			else:
				# building dropped after 5 attempts (keeps spacing contract)
				continue
	# Sort buildings by id for deterministic order independent of settlement loop order?
	_buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	# Also sort by_settlement arrays by id
	for sid in _by_settlement.keys():
		var arr: Array[Dictionary] = _by_settlement[sid] as Array[Dictionary]
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"])
		)
		_by_settlement[sid] = arr

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

# --- Public queries ---

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
	# Check aabb contains p and oriented footprint contains p within 0.5m inset
	for b in _buildings:
		var aabb: Rect2 = b["aabb"] as Rect2
		if not aabb.has_point(p):
			continue
		var center: Vector2 = b["center"] as Vector2
		var footprint: Vector2 = b["footprint"] as Vector2
		var yaw: float = float(b["yaw"])
		var eff := _effective_footprint(footprint, yaw)
		# oriented containment: transform p into local building space
		var rel := p - center
		var cos_y := cos(-yaw)
		var sin_y := sin(-yaw)
		var lx: float = rel.x * cos_y - rel.y * sin_y
		var lz: float = rel.x * sin_y + rel.y * cos_y
		var inside_x: bool = absf(lx) <= eff.x * 0.5 - 0.5
		var inside_z: bool = absf(lz) <= eff.y * 0.5 - 0.5
		if inside_x and inside_z:
			# also check center distance < footprint.length()*0.4 and not separated by water/road trench heuristic
			var mid := (p + center) * 0.5
			if hydrology.water_body_at(mid) != &"":
				continue
			return b
		# fallback: center distance check
		var dist: float = p.distance_to(center)
		if dist < footprint.length() * 0.4:
			var mid2 := (p + center) * 0.5
			if hydrology.water_body_at(mid2) != &"":
				continue
			# need also check not separated by road trench? approximate via distance_to_road not needed
			return b
	return {}

func settlement_buildings(settlement_id: String) -> Array[Dictionary]:
	if _by_settlement.has(settlement_id):
		return (_by_settlement[settlement_id] as Array[Dictionary]).duplicate()
	return [] as Array[Dictionary]

func buildings_in(rect: Rect2) -> Array[Dictionary]:
	return rural_buildings_in(rect)
