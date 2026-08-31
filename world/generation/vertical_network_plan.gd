class_name VerticalNetworkPlan
extends RefCounted
## Pure vertical survivor network plan: deterministic roof bridges between barn/stable per 256 m cell.
var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var road_network: RoadNetworkPlan
var rural_building: RuralBuildingPlan
var _bridge_cache: Dictionary = {}
var _all_bridges_cache: Array[Dictionary] = []
var _all_built := false
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
func _effective_footprint(footprint: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint
func _aabb_for(center: Vector2, footprint: Vector2, yaw: float) -> Rect2:
	var eff := _effective_footprint(footprint, yaw)
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
func _is_valid_anchor_position(pos: Vector2) -> bool:
	if pos.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS - 0.001:
		return false
	if not WorldConstants.is_inside_world(pos):
		return false
	if hydrology.water_body_at(pos) != &"":
		return false
	if hydrology.is_floodplain(pos):
		return false
	if hydrology.distance_to_water(pos) <= WorldConstants.VERTICAL_BRIDGE_WATER_GAP - 0.001:
		return false
	var slope: float = terrain.slope_at(pos)
	if slope >= WorldConstants.VERTICAL_BRIDGE_SLOPE_MAX_DEG - 0.001:
		return false
	if terrain.terrain_class_at(pos) == &"cliff":
		return false
	if road_network != null:
		var d_road: float = road_network.distance_to_road(pos)
		if d_road < WorldConstants.VERTICAL_BRIDGE_ROAD_SETBACK - 0.001:
			return false
		var rect2 := Rect2(pos - Vector2(30,30), Vector2(60,60))
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
					var t2 := (pos - a2).dot(ab2) / len2b
					t2 = clampf(t2, 0.0, 1.0)
					var proj2 := a2 + ab2 * t2
					var w_road: float = float(seg.get("width", WorldConstants.ROAD_WIDTH_TRACK))
					if pos.distance_to(proj2) < w_road * 0.5 + 2.0 and hydrology.water_body_at(proj2) != &"":
						return false
	return true
func _anchor_for_building(building: Dictionary, direction_to_other: Vector2) -> Vector2:
	var center: Vector2 = building["center"] as Vector2
	var footprint: Vector2 = building["footprint"] as Vector2
	var yaw: float = float(building["yaw"])
	var eff := _effective_footprint(footprint, yaw)
	var hx: float = eff.x * 0.5
	var hz: float = eff.y * 0.5
	var dir := direction_to_other
	if dir.length_squared() < 1e-6:
		return center
	var adx: float = absf(dir.x)
	var ady: float = absf(dir.y)
	var edge_center: Vector2
	if adx > ady:
		if dir.x > 0:
			edge_center = center + Vector2(hx, 0)
			return edge_center - Vector2(1.0, 0)
		else:
			edge_center = center + Vector2(-hx, 0)
			return edge_center + Vector2(1.0, 0)
	else:
		if dir.y > 0:
			edge_center = center + Vector2(0, hz)
			return edge_center - Vector2(0, 1.0)
		else:
			edge_center = center + Vector2(0, -hz)
			return edge_center + Vector2(0, 1.0)
func _bridge_for_cell(cx: int, cy: int) -> Variant:
	var key: String = "%d,%d" % [cx, cy]
	if _bridge_cache.has(key):
		return _bridge_cache[key]
	var cell_origin: Vector2 = Vector2(float(cx) * WorldConstants.LANDSCAPE_CELL_M, float(cy) * WorldConstants.LANDSCAPE_CELL_M)
	var cell_center: Vector2 = cell_origin + Vector2(WorldConstants.LANDSCAPE_CELL_M * 0.5, WorldConstants.LANDSCAPE_CELL_M * 0.5)
	if cell_center.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS - 30.0 and cell_origin.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS:
		if cell_center.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS:
			_bridge_cache[key] = null
			return null
	var inside_world := false
	for off in [Vector2(0,0), Vector2(256,0), Vector2(0,256), Vector2(256,256)]:
		if WorldConstants.is_inside_world(cell_origin + off):
			inside_world = true
			break
	if not inside_world:
		_bridge_cache[key] = null
		return null
	var cell_rect: Rect2 = Rect2(cell_origin, Vector2(WorldConstants.LANDSCAPE_CELL_M, WorldConstants.LANDSCAPE_CELL_M))
	var expanded: Rect2 = cell_rect.grow(30.0)
	var barns: Array[Dictionary] = []
	var all_buildings_in_expanded: Array[Dictionary] = rural_building.rural_buildings_in(expanded) if rural_building != null else [] as Array[Dictionary]
	for b in all_buildings_in_expanded:
		var kind: StringName = b["kind"] as StringName
		if kind == &"barn" or kind == &"stable":
			barns.append(b)
	var by_settlement: Dictionary = {}
	for b in barns:
		var sid: String = String(b["settlement_id"])
		if not by_settlement.has(sid):
			by_settlement[sid] = [] as Array[Dictionary]
		(by_settlement[sid] as Array[Dictionary]).append(b)
	var hash_cell: int = WorldSeed.combine([seed_used, WorldSeed.str_hash("vertical_bridge"), cx, cy])
	var best_candidate: Variant = null
	var sids: Array = by_settlement.keys()
	sids.sort()
	for sid in sids:
		var arr: Array[Dictionary] = by_settlement[sid] as Array[Dictionary]
		if arr.size() < 2:
			continue
		arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		for i in arr.size():
			for j in range(i+1, arr.size()):
				var b_a: Dictionary = arr[i]
				var b_b: Dictionary = arr[j]
				var ca: Vector2 = b_a["center"] as Vector2
				var cb: Vector2 = b_b["center"] as Vector2
				var aabb_a: Rect2 = b_a["aabb"] as Rect2
				var aabb_b: Rect2 = b_b["aabb"] as Rect2
				var gap: float = _aabb_gap(aabb_a, aabb_b)
				if gap < -0.01:
					continue
				var dir_ab: Vector2 = cb - ca
				var dir_ba: Vector2 = ca - cb
				var anchor_a: Vector2 = _anchor_for_building(b_a, dir_ab)
				var anchor_b: Vector2 = _anchor_for_building(b_b, dir_ba)
				var span: float = anchor_a.distance_to(anchor_b)
				if span < WorldConstants.VERTICAL_BRIDGE_SPAN_MIN - 0.05 or span > WorldConstants.VERTICAL_BRIDGE_SPAN_MAX + 0.05:
					continue
				var mid: Vector2 = (anchor_a + anchor_b) * 0.5
				if not cell_rect.has_point(mid):
					continue
				if mid.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS - 0.001 or anchor_a.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS - 0.001 or anchor_b.length() < WorldConstants.VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS - 0.001:
					continue
				var attempts_pass := false
				var chosen_yaw: float = 0.0
				var chosen_ledge_y: float = 0.0
				var chosen_aabb: Rect2 = Rect2()
				var chosen_anchors: Array[Vector3] = []
				var chosen_mid_jittered: Vector2 = mid
				for attempt in 6:
					var jitter: Vector2 = Vector2.ZERO
					if attempt > 0:
						var jx: float = _unit_float_with_seed("vertical_bridge", [hash_cell, attempt, 0], seed_used)
						var jy: float = _unit_float_with_seed("vertical_bridge", [hash_cell, attempt, 1], seed_used)
						jitter = Vector2((jx - 0.5) * 2.5, (jy - 0.5) * 2.5)
					var aa: Vector2 = anchor_a + jitter
					var ab: Vector2 = anchor_b + jitter
					var mid_j: Vector2 = (aa + ab) * 0.5
					if not cell_rect.has_point(mid_j):
						continue
					if not _is_valid_anchor_position(aa) or not _is_valid_anchor_position(ab) or not _is_valid_anchor_position(mid_j):
						continue
					var inside_building := false
					for b in all_buildings_in_expanded:
						var baabb: Rect2 = b["aabb"] as Rect2
						if baabb.has_point(mid_j):
							inside_building = true
							break
					if inside_building:
						continue
					var dir_span: Vector2 = ab - aa
					var angle: float = atan2(dir_span.y, dir_span.x)
					var yaw_q: float = round(angle / (PI * 0.5)) * (PI * 0.5)
					yaw_q = wrapf(yaw_q, -PI, PI)
					if is_equal_approx(absf(yaw_q), PI):
						yaw_q = PI
					var h_a: float = terrain.height_at(ca)
					var h_b: float = terrain.height_at(cb)
					var height_a: float = float(b_a.get("height", WorldConstants.RURAL_BUILDING_HEIGHT_SINGLE + WorldConstants.RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA))
					var height_b: float = float(b_b.get("height", WorldConstants.RURAL_BUILDING_HEIGHT_SINGLE + WorldConstants.RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA))
					var ledge_a: float = h_a + height_a + WorldConstants.VERTICAL_BRIDGE_HEIGHT_OFFSET
					var ledge_b: float = h_b + height_b + WorldConstants.VERTICAL_BRIDGE_HEIGHT_OFFSET
					var height_var: float = absf(ledge_a - ledge_b)
					if height_var >= 0.9 + 0.02:
						continue
					var ledge_y: float = (ledge_a + ledge_b) * 0.5
					var p1: Vector2 = aa.lerp(ab, 0.25)
					var p2: Vector2 = aa.lerp(ab, 0.5)
					var p3: Vector2 = aa.lerp(ab, 0.75)
					var clearance_ok := true
					for pp in [p1, p2, p3]:
						var th: float = terrain.height_at(pp)
						if ledge_y - th <= 0.6 + 0.001:
							clearance_ok = false
							break
					if not clearance_ok:
						continue
					var bridge_aabb: Rect2
					var span_len: float = aa.distance_to(ab)
					var bridge_w: float = WorldConstants.VERTICAL_BRIDGE_WIDTH
					if is_equal_approx(absf(yaw_q), PI * 0.5):
						bridge_aabb = Rect2(mid_j - Vector2(bridge_w, span_len)*0.5, Vector2(bridge_w, span_len))
					else:
						bridge_aabb = Rect2(mid_j - Vector2(span_len, bridge_w)*0.5, Vector2(span_len, bridge_w))
					var building_gap_ok := true
					for ob in all_buildings_in_expanded:
						var oid: String = String(ob["id"])
						if oid == String(b_a["id"]) or oid == String(b_b["id"]):
							continue
						var obaabb: Rect2 = ob["aabb"] as Rect2
						var gap2: float = _aabb_gap(bridge_aabb, obaabb)
						if gap2 < WorldConstants.VERTICAL_BRIDGE_BUILDING_GAP_MIN - 0.01 and gap2 >= 0:
							building_gap_ok = false
							break
						if gap2 < 0:
							building_gap_ok = false
							break
					if not building_gap_ok:
						continue
					var well_forage_ok := true
					if rural_building != null:
						var wells: Array[Dictionary] = rural_building.rural_wells_in(expanded) if rural_building.has_method("rural_wells_in") else [] as Array[Dictionary]
						for ww in wells:
							var wpos: Vector2 = ww["pos"] as Vector2
							if mid_j.distance_to(wpos) < 8.0 - 0.01 or aa.distance_to(wpos) < 8.0 - 0.01 or ab.distance_to(wpos) < 8.0 - 0.01:
								well_forage_ok = false
								break
						if not well_forage_ok:
							continue
						var forage: Array[Dictionary] = rural_building.rural_forage_patches_in(expanded) if rural_building.has_method("rural_forage_patches_in") else [] as Array[Dictionary]
						for ff in forage:
							var fpos: Vector2 = ff["pos"] as Vector2
							if mid_j.distance_to(fpos) < 8.0 - 0.01 or aa.distance_to(fpos) < 8.0 - 0.01 or ab.distance_to(fpos) < 8.0 - 0.01:
								well_forage_ok = false
								break
						if not well_forage_ok:
							continue
					chosen_yaw = yaw_q
					chosen_ledge_y = ledge_y
					chosen_aabb = bridge_aabb
					chosen_mid_jittered = mid_j
					chosen_anchors = [Vector3(aa.x, ledge_y, aa.y), Vector3(ab.x, ledge_y, ab.y)]
					attempts_pass = true
					break
				if not attempts_pass:
					continue
				var bridge_id: String = "vertical_bridge_%d_%d_0" % [cx, cy]
				var ledge_y_final: float = chosen_ledge_y
				var yaw_final: float = chosen_yaw
				var aabb_final: Rect2 = chosen_aabb
				var mid_final: Vector2 = chosen_mid_jittered
				var span_final: float = chosen_anchors[0].distance_to(chosen_anchors[1])
				var dict: Dictionary = {
					"id": bridge_id,
					"pos": mid_final,
					"center": mid_final,
					"mid": mid_final,
					"aabb": aabb_final,
					"yaw": yaw_final,
					"span": span_final,
					"width": WorldConstants.VERTICAL_BRIDGE_WIDTH,
					"height": WorldConstants.VERTICAL_BRIDGE_THICKNESS,
					"thickness": WorldConstants.VERTICAL_BRIDGE_THICKNESS,
					"kind": &"roof_bridge",
					"building_a_id": String(b_a["id"]),
					"building_b_id": String(b_b["id"]),
					"settlement_id": String(b_a["settlement_id"]),
					"ledge_y": ledge_y_final,
					"anchors": chosen_anchors,
					"building_a": b_a,
					"building_b": b_b,
					"landscape_cell": Vector2i(cx, cy),
					"cx": cx,
					"cy": cy,
				}
				best_candidate = dict
				break
		if best_candidate != null:
			_bridge_cache[key] = best_candidate
			return best_candidate
	_bridge_cache[key] = null
	return null
static func _dict_id_cmp(a: Dictionary, b: Dictionary) -> bool:
	return String(a.get("id","")) < String(b.get("id",""))
func _ensure_all_bridges() -> void:
	if _all_built:
		return
	_all_bridges_cache.clear()
	var cmin: int = floori(WorldConstants.WORLD_MIN_M / WorldConstants.LANDSCAPE_CELL_M)
	var cmax: int = floori((WorldConstants.WORLD_MAX_M - 0.001) / WorldConstants.LANDSCAPE_CELL_M)
	var raw: Array[Dictionary] = []
	for cx in range(cmin, cmax+1):
		for cy in range(cmin, cmax+1):
			var cand: Variant = _bridge_for_cell(cx, cy)
			if cand != null:
				raw.append(cand as Dictionary)
	raw.sort_custom(_dict_id_cmp)
	var kept: Array[Dictionary] = []
	for cand in raw:
		var p: Vector2 = cand.get("pos", Vector2.ZERO) as Vector2
		var too_close := false
		for k in kept:
			var kp: Vector2 = k.get("pos", Vector2.ZERO) as Vector2
			if p.distance_to(kp) < WorldConstants.VERTICAL_BRIDGE_SPACING_MIN - 0.001:
				too_close = true
				break
		if not too_close:
			kept.append(cand)
	_all_bridges_cache = kept
	_all_built = true
func vertical_bridges() -> Array[Dictionary]:
	_ensure_all_bridges()
	return _all_bridges_cache.duplicate()
func vertical_bridges_in(rect: Rect2) -> Array[Dictionary]:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return [] as Array[Dictionary]
	_ensure_all_bridges()
	var out: Array[Dictionary] = []
	for b in _all_bridges_cache:
		var p: Vector2 = b.get("pos", Vector2.ZERO) as Vector2
		if rect.has_point(p):
			out.append(b)
	out.sort_custom(_dict_id_cmp)
	return out
func nearest_vertical_bridge(p: Vector2) -> Dictionary:
	_ensure_all_bridges()
	if _all_bridges_cache.is_empty():
		return {}
	var best: Dictionary = {}
	var best_d: float = INF
	for b in _all_bridges_cache:
		var c: Vector2 = b.get("pos", Vector2.ZERO) as Vector2
		var d: float = p.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = b
	return best
func clear_cache() -> void:
	_bridge_cache.clear()
	_all_bridges_cache.clear()
	_all_built = false
