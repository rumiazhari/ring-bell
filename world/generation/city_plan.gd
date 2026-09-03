class_name CityPlan
extends RefCounted
## Deterministic organic city morphology plan.
##
## The city is generated in this order:
##   landmarks/gates/crossings -> primary routes -> secondary connectors
##   -> local streets/alleys -> irregular Voronoi-like blocks -> parcels
##   -> BuildingSpec dictionaries.
##
## This is deliberately NOT a Cartesian street grid.  The road graph is a
## seeded, curved network whose nodes are city places; blocks are clipped
## cells around a deterministic Poisson-like set of sites.  Buildings remain
## Rect2-compatible because the universal city assembler currently consumes
## rectangular footprints.  Their footprints are kept inside the irregular
## block polygons and retain the full BuildingSpec ->
## UniversalBuildingAssembler -> BuildingBuilder path.
##
## PLAN LAYER ONLY: no scene-tree access, no mutable global RNG, and no
## generation decisions in chunk builders.

const DISTRICT_HISTORIC := &"historic"
const DISTRICT_INNER := &"inner_city"
const DISTRICT_OUTER := &"outer"

# Retained vocabulary for older probes and save readers. These values are not
# used to place the organic road network.
const DISTRICT_CELL := 128
const GRID_BASE_SPACING := 88
const GRID_JITTER := 18
const AVENUE_CHANCE := 0.18
const NARROW_HALF := Vector2(4.2, 5.6)
const AVENUE_HALF := Vector2(6.6, 8.4)
const PASSAGE_HALF := Vector2(1.8, 2.5)
const PASSAGE_CLEAR := 0.6
const WALL_PALETTES := 8
const ROOF_PALETTES := 5
const DOOR_W := 1.5

const _CITY_BOUNDARY_SIDES := 32
const _CITY_SITE_CANDIDATES := 1200
const _CITY_MAX_SITES := 230
const _CITY_EDGE_EPS := 0.001
const _CITY_ROAD_BLOCK_CLEARANCE := 2.4
const _CITY_MIN_SPLIT_BLOCK_AREA := 70.0

# Kept as compatibility storage for old callers that clear CityPlan caches.
# No morphology code reads these as a street lattice.
var _line_pos_cache := [{}, {}]
var _cell_cache: Dictionary = {}
var _building_cache: Dictionary = {}

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan

var _support_ready := false
var _generated := false
var _city_nodes: Array[Dictionary] = []
var _city_node_by_id: Dictionary = {}
var _city_edges: Array[Dictionary] = []
var _city_edge_ids: Dictionary = {}
var _landmarks: Array[Dictionary] = []
var _landmark_by_id: Dictionary = {}
var _blocks: Array[Dictionary] = []
var _block_by_cell: Dictionary = {}
var _all_buildings: Array[Dictionary] = []
var _building_by_id: Dictionary = {}


func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed


# -----------------------------------------------------------------------------
# Deterministic helpers

func _u(domain: String, parts: Array = []) -> float:
	var all_parts: Array = [seed_used, WorldSeed.str_hash(domain)]
	all_parts.append_array(parts)
	return float(WorldSeed.combine(all_parts) % 1000003) / 1000003.0


func _rng(domain: String, parts: Array = []) -> RandomNumberGenerator:
	var all_parts: Array = [seed_used, WorldSeed.str_hash(domain)]
	all_parts.append_array(parts)
	var out := RandomNumberGenerator.new()
	out.seed = WorldSeed.combine(all_parts)
	return out


static func _dict_id_cmp(a: Dictionary, b: Dictionary) -> bool:
	return str(a.get("id", "")) < str(b.get("id", ""))


static func _surface_region_cmp(a: Dictionary, b: Dictionary) -> bool:
	var aa := float(a.get("area_m2", 0.0))
	var ba := float(b.get("area_m2", 0.0))
	if not is_equal_approx(aa, ba):
		return aa > ba
	var ap: Vector2 = a.get("center", Vector2.ZERO) as Vector2
	var bp: Vector2 = b.get("center", Vector2.ZERO) as Vector2
	if not is_equal_approx(ap.x, bp.x):
		return ap.x < bp.x
	return ap.y < bp.y


static func _crossing_cmp(a: Dictionary, b: Dictionary) -> bool:
	var ap: Vector2 = a.get("center", Vector2.ZERO) as Vector2
	var bp: Vector2 = b.get("center", Vector2.ZERO) as Vector2
	var da := ap.length_squared()
	var db := bp.length_squared()
	if not is_equal_approx(da, db):
		return da < db
	return str(a.get("id", "")) < str(b.get("id", ""))


static func _site_record_cmp(a: Dictionary, b: Dictionary) -> bool:
	var ap: Vector2 = a["p"] as Vector2
	var bp: Vector2 = b["p"] as Vector2
	if not is_equal_approx(ap.x, bp.x):
		return ap.x < bp.x
	if not is_equal_approx(ap.y, bp.y):
		return ap.y < bp.y
	return int(a["index"]) < int(b["index"])


static func _cell_cmp(a: Vector2i, b: Vector2i) -> bool:
	return a.x < b.x if a.x != b.x else a.y < b.y


func _ensure_support_plans() -> void:
	if _support_ready:
		return
	terrain = TerrainPlan.new(seed_used)
	hydrology = HydrologyPlan.new(seed_used)
	geology = GeologyPlan.new(seed_used)
	biome = BiomePlan.new(seed_used, terrain, hydrology, geology)
	settlement = SettlementPlan.new(seed_used, terrain, hydrology, geology, biome)
	_support_ready = true


func _ensure_generated() -> void:
	if _generated:
		return
	_ensure_support_plans()
	_generate_landmarks()
	_generate_city_roads()
	_generate_city_blocks()
	_generated = true


# -----------------------------------------------------------------------------
# Compatibility-facing district/road helpers

func district_at_point(p: Vector2) -> StringName:
	var radius := p.length()
	if radius < WorldConstants.CITY_HISTORIC_RADIUS_M:
		return DISTRICT_HISTORIC
	if radius < WorldConstants.CITY_DENSE_RADIUS_M:
		return DISTRICT_INNER
	return DISTRICT_OUTER


func _dc(p: Vector2) -> int:
	var cell := Vector2i(floori(p.x / float(DISTRICT_CELL)),
			floori(p.y / float(DISTRICT_CELL)))
	return WorldSeed.combine([seed_used, cell.x, cell.y])


func _snap_to_road(p: Vector2) -> Vector2:
	return nearest_city_road_point(p)


func _generate_landmarks() -> void:
	_landmarks.clear()
	_landmark_by_id.clear()
	_city_nodes.clear()
	_city_node_by_id.clear()
	# The market is a fixed civic datum, not a random spawn cluster.
	_add_landmark("market_square", Vector2.ZERO, &"market_square", 34.0)

	var phase := (_u("city_landmark_phase") - 0.5) * 0.38
	var civic_dir := Vector2(cos(phase - 1.05), sin(phase - 1.05))
	var station_dir := Vector2(cos(phase + 0.38), sin(phase + 0.38))
	var castle_dir := Vector2(cos(phase + 2.05), sin(phase + 2.05))
	_add_landmark("civic_square", civic_dir * lerpf(145.0, 205.0,
			_u("city_civic_radius")), &"civic_square", 30.0)
	_add_landmark("rail_station", station_dir * lerpf(360.0, 470.0,
			_u("city_station_radius")), &"station", 24.0)
	_add_landmark("castle_hill", castle_dir * lerpf(180.0, 270.0,
			_u("city_castle_radius")), &"castle_hill", 22.0)

	# Reuse the existing deterministic gate plan.  The city road graph, rather
	# than a line-index lookup, is the authority for routes to these gates.
	for gate: Dictionary in settlement.city_gates():
		var gp: Vector2 = gate.get("center", Vector2.ZERO) as Vector2
		if gp.length() <= WorldConstants.CITY_MATERIALIZATION_RADIUS_M + 80.0:
			_add_landmark(String(gate["id"]), gp, &"city_gate",
				float(gate.get("radius", WorldConstants.SETTLEMENT_GATE_RADIUS)))

	# River crossings are hydrology candidates, not arbitrary roads over water.
	# Select the closest few to the historic city, then keep their actual
	# crossing metadata so bridge edges can be audited.
	var cross_rect := Rect2(Vector2(-1200.0, -1200.0), Vector2(2400.0, 2400.0))
	var crossings: Array[Dictionary] = hydrology.crossing_candidates(cross_rect)
	crossings.sort_custom(_crossing_cmp)
	var kept_crossings := 0
	for crossing: Dictionary in crossings:
		var cp: Vector2 = crossing.get("center", Vector2.ZERO) as Vector2
		if cp.length() > WorldConstants.CITY_BLOCK_RADIUS_M + 90.0:
			continue
		var cross_id := "crossing_%s" % String(crossing.get("id", ""))
		_add_landmark(cross_id, cp, &"river_crossing",
			float(crossing.get("width", 42.0)) * 0.5,
			{"crossing_id": str(crossing.get("id", "")),
				"water_id": str(crossing.get("water_id", "river_main")),
				"axis": crossing.get("axis", Vector2(1, 0)) as Vector2})
		kept_crossings += 1
		if kept_crossings >= 3:
			break
	# A seed can have no legal hydrology candidate in this tight window.  Keep
	# the route vocabulary alive with a deterministic river point; it is only
	# used when it really lies on the river and still remains inside the city.
	if kept_crossings == 0:
		var fallback_cross := Vector2(hydrology.river_center_x_at(0.0), 0.0)
		if fallback_cross.length() < WorldConstants.CITY_BLOCK_RADIUS_M:
			_add_landmark("crossing_fallback", fallback_cross, &"river_crossing", 21.0,
				{"crossing_id": "crossing_fallback", "water_id": "river_main",
					"axis": Vector2(1, 0)})

	# Primary graph nodes are explicit and stable.  Include all landmarks,
	# gates, and crossings in the node table before generating edges.
	for lm: Dictionary in _landmarks:
		var kind: StringName = lm.get("kind", &"place") as StringName
		_add_city_node(String(lm["id"]), lm["center"] as Vector2, kind,
			String(lm.get("id", "")))


func _add_landmark(id: String, center: Vector2, kind: StringName,
		radius: float, metadata: Dictionary = {}) -> void:
	if _landmark_by_id.has(id):
		return
	var lm := {
		"id": id,
		"center": center,
		"position": center,
		"kind": kind,
		"radius": radius,
	}
	for key in metadata.keys():
		lm[key] = metadata[key]
	_landmarks.append(lm)
	_landmark_by_id[id] = lm


func _add_city_node(id: String, center: Vector2, kind: StringName,
		landmark_id: String = "") -> void:
	if _city_node_by_id.has(id):
		return
	var node := {
		"id": id,
		"center": center,
		"position": center,
		"kind": kind,
		"landmark_id": landmark_id,
		"degree": 0,
	}
	if _landmark_by_id.has(landmark_id):
		var landmark: Dictionary = _landmark_by_id[landmark_id]
		for key in ["crossing_id", "water_id", "axis"]:
			if landmark.has(key):
				node[key] = landmark[key]
	_city_nodes.append(node)
	_city_node_by_id[id] = node


func _node_position(id: String) -> Vector2:
	var node: Dictionary = _city_node_by_id.get(id, {}) as Dictionary
	return node.get("center", Vector2.ZERO) as Vector2


# -----------------------------------------------------------------------------
# Curved hierarchical road graph

func _generate_city_roads() -> void:
	_city_edges.clear()
	_city_edge_ids.clear()
	var hub := "market_square"
	# Historic pocket ring FIRST: pockets anchor distributed entry so radials
	# never need to terminate at the exact central node (P2B-FIX starburst).
	_add_historic_core_fabric(hub)
	# Only the civic square keeps a direct primary to the market. Castle and
	# station merge into the pocket ring via connector secondaries.
	if _city_node_by_id.has("civic_square"):
		_add_route_between(hub, "civic_square", &"primary",
			"city_primary_civic_square")
	for landmark_id in ["rail_station", "castle_hill"]:
		if _city_node_by_id.has(landmark_id):
			var pocket := _nearest_node_of_kind(
				_node_position(landmark_id), &"historic_pocket")
			if pocket != "":
				_add_route_between(pocket, landmark_id, &"secondary",
					"city_connector_%s" % landmark_id)
			else:
				_add_route_between(hub, landmark_id, &"primary",
					"city_primary_%s" % landmark_id)
	# Gate arterials terminate at the nearest inner landmark (civic / station
	# / castle), never directly at the market. Curvature stays per-edge.
	var gate_ids: Array[String] = []
	for lm: Dictionary in _landmarks:
		if lm.get("kind", &"") == &"city_gate":
			gate_ids.append(String(lm["id"]))
	gate_ids.sort()
	for gate_id: String in gate_ids:
		var anchor := _nearest_inner_connector(_node_position(gate_id))
		if anchor == "":
			anchor = hub
		_add_route_between(anchor, gate_id, &"primary",
			"city_primary_%s" % gate_id)

	# Routes to actual river crossing nodes are primary bridge approaches.  A
	# crossing is connected to the closest gate as well, which creates the
	# bridge-side T/Y choices visible from the aerial view.
	var crossing_ids: Array[String] = []
	for lm2: Dictionary in _landmarks:
		if lm2.get("kind", &"") == &"river_crossing":
			crossing_ids.append(String(lm2["id"]))
	crossing_ids.sort()
	for crossing_id: String in crossing_ids:
		var approach := _nearest_inner_connector(_node_position(crossing_id))
		if approach == "":
			approach = _nearest_node_of_kind(
				_node_position(crossing_id), &"historic_pocket")
		if approach != "" and approach != crossing_id:
			_add_route_between(approach, crossing_id, &"primary",
				"city_bridge_approach_%s" % crossing_id, true)
		var nearest_gate := _nearest_node_of_kind(_node_position(crossing_id), &"city_gate")
		if nearest_gate != "":
			_add_route_between(crossing_id, nearest_gate, &"primary",
				"city_bridge_gate_%s" % crossing_id, true)

	# Historic pocket ring already built above; neighborhood connectors below
	# attach radials to the primary spine through inner nodes, not the hub.

	# Add irregular neighborhood nodes and secondary connectors.  Their angles
	# are sampled from independent domains rather than indexed X/Z lines.
	var neighborhood_ids: Array[String] = []
	var neighborhood_count := 28
	for i in neighborhood_count:
		var angle := TAU * (float(i) / float(neighborhood_count))
		angle += (_u("city_neighborhood_angle", [i]) - 0.5) * 0.46
		angle += (_u("city_neighborhood_phase") - 0.5) * 0.22
		var radius := lerpf(150.0, 820.0, sqrt(_u("city_neighborhood_radius", [i])))
		var p := Vector2(cos(angle), sin(angle)) * radius
		p = _nearest_valid_city_point(p, 3)
		if p == Vector2.INF:
			continue
		var id := "neighborhood_%02d" % i
		_add_city_node(id, p, &"neighborhood")
		neighborhood_ids.append(id)
		var anchor := _nearest_primary_node(p)
		if anchor != "" and anchor != id:
			_add_route_between(anchor, id, &"secondary", "city_secondary_%s" % id)
	# A subset of neighboring neighborhood nodes gets a cross-connector.  The
	# graph remains connected through the anchor edges above.
	neighborhood_ids.sort()
	for i in range(neighborhood_ids.size()):
		if _u("city_secondary_loop", [i]) > 0.62:
			continue
		var a_id: String = neighborhood_ids[i]
		var best_id := ""
		var best_d := INF
		for j in range(i + 1, neighborhood_ids.size()):
			var b_id: String = neighborhood_ids[j]
			var d: float = _node_position(a_id).distance_to(_node_position(b_id))
			if d < best_d:
				best_d = d
				best_id = b_id
		if best_id != "" and best_d < 430.0:
			_add_route_between(a_id, best_id, &"secondary",
				"city_secondary_loop_%s_%s" % [a_id, best_id])

	# Local branches and narrow alleys make the inner fabric finer without
	# manufacturing a city-wide grid.  Branches terminate at pocket places and
	# can be joined to a nearby neighborhood node to form T/Y junctions.
	for i in range(neighborhood_ids.size()):
		var parent_id: String = neighborhood_ids[i]
		var parent_p := _node_position(parent_id)
		var branch_count := 2 + int(floor(_u("city_local_count", [i]) * 4.0))
		var base_angle := _u("city_local_phase", [i]) * TAU
		for k in branch_count:
			var a := base_angle + float(k) * TAU / float(branch_count)
			a += (_u("city_local_angle", [i, k]) - 0.5) * 0.55
			var length := lerpf(32.0, 92.0, _u("city_local_length", [i, k]))
			var end_p := parent_p + Vector2(cos(a), sin(a)) * length
			end_p = _nearest_valid_city_point(end_p, 2)
			if end_p == Vector2.INF:
				continue
			var end_id := "local_%02d_%d" % [i, k]
			_add_city_node(end_id, end_p, &"local_pocket")
			var hierarchy: StringName = &"alley" if _u("city_alley_roll", [i, k]) < 0.34 else &"local"
			_add_route_between(parent_id, end_id, hierarchy,
				"city_%s_%s" % [hierarchy, end_id])

	# P2B-FIX middle-ring connectors: distributed secondary meters in the
	# dense band. They replace the road length lost when hub radials were
	# shortened to inner connectors — splitting blocks and fronting lots
	# without touching the hub. Deterministic, capped, admission-checked.
	var midring_ids: Array[String] = []
	for nid in neighborhood_ids:
		if _node_position(nid).length() <= 720.0:
			midring_ids.append(nid)
	midring_ids.sort()
	var midring_added := 0
	for i in midring_ids.size():
		if midring_added >= 14:
			break
		if _u("city_midring_link", [i]) > 0.55:
			continue
		var a_id: String = midring_ids[i]
		var best_id := ""
		var best_d := 500.0
		var candidates: Array[String] = []
		for n in _city_nodes:
			var cand := String(n["id"])
			var kind := String(n.get("kind", ""))
			if kind == "historic_pocket" or cand == "civic_square" \
					or cand == "rail_station" or cand == "castle_hill":
				candidates.append(cand)
		for j in range(i + 1, midring_ids.size()):
			candidates.append(midring_ids[j])
		for cand in candidates:
			if cand == a_id or _have_direct_edge(a_id, cand):
				continue
			var d := _node_position(a_id).distance_to(_node_position(cand))
			if d < best_d or (is_equal_approx(d, best_d) and cand < best_id):
				best_d = d
				best_id = cand
		if best_id != "":
			_add_route_between(a_id, best_id, &"secondary",
				"city_midring_%s_%s" % [a_id, best_id])
			midring_added += 1

	# P2B-FIX void infill: dense-band ground far from every road gets a short
	# secondary stub so it becomes street-bounded blocks, never a mega-face.
	_add_void_infill()

	# Recovery is deterministic and only engages for a component that could not
	# reach the primary spine because of a river/slope rejection. It preserves
	# the normal candidate-based route first, then uses a marked bridge edge.
	_ensure_connected_city_graph()
	# Stable ordering is part of the chunk manifest contract.
	_city_edges.sort_custom(_dict_id_cmp)
	for node: Dictionary in _city_nodes:
		node["degree"] = 0
	for edge: Dictionary in _city_edges:
		var an: Dictionary = _city_node_by_id.get(String(edge["a"]), {}) as Dictionary
		var bn: Dictionary = _city_node_by_id.get(String(edge["b"]), {}) as Dictionary
		an["degree"] = int(an.get("degree", 0)) + 1
		bn["degree"] = int(bn.get("degree", 0)) + 1
		_city_node_by_id[String(edge["a"])] = an
		_city_node_by_id[String(edge["b"])] = bn


func _add_historic_core_fabric(hub_id: String) -> void:
	var pocket_ids: Array[String] = []
	var pocket_count := 12
	for i in pocket_count:
		var angle := TAU * float(i) / float(pocket_count)
		angle += (_u("city_core_pocket_angle", [i]) - 0.5) * 0.24
		angle += (_u("city_core_pocket_phase") - 0.5) * 0.12
		var radius := lerpf(72.0, 268.0, _u("city_core_pocket_radius", [i]))
		var point := Vector2(cos(angle), sin(angle)) * radius
		point = _nearest_valid_city_point(point, 5)
		if point == Vector2.INF:
			continue
		var pocket_id := "historic_pocket_%02d" % i
		_add_city_node(pocket_id, point, &"historic_pocket")
		pocket_ids.append(pocket_id)

	if pocket_ids.size() < 2:
		return
	for i in pocket_ids.size():
		var pocket_id: String = pocket_ids[i]
		# P2B-FIX: only every fourth pocket touches the market directly; the
		# rest join through the ring. Caps hub degree, keeps the core meshed.
		if i % 4 == 0:
			_add_route_between(hub_id, pocket_id, &"local",
				"city_historic_spoke_%02d" % i)
		else:
			# Skip-one alley chord: dense winding lanes in the outer core band
			# (stays ~0.87r from center, never crosses the market square).
			var chord_id: String = pocket_ids[(i + 2) % pocket_ids.size()]
			_add_route_between(pocket_id, chord_id, &"alley",
				"city_historic_chord_%02d" % i)
		var next_id: String = pocket_ids[(i + 1) % pocket_ids.size()]
		var ring_hierarchy: StringName = &"local"
		if i % 3 == 0:
			ring_hierarchy = &"alley"
		_add_route_between(pocket_id, next_id, ring_hierarchy,
			"city_historic_ring_%02d" % i)


func _ensure_connected_city_graph() -> void:
	if _city_nodes.is_empty():
		return
	var connected := _reachable_city_nodes("market_square")
	for node: Dictionary in _city_nodes:
		var node_id := str(node["id"])
		if connected.has(node_id):
			continue
		var nearest_id := ""
		var nearest_d := INF
		for connected_id: String in connected.keys():
			var d := _node_position(node_id).distance_to(_node_position(connected_id))
			if d < nearest_d or (is_equal_approx(d, nearest_d) and connected_id < nearest_id):
				nearest_d = d
				nearest_id = connected_id
		if nearest_id == "":
			continue
		var before := _city_edges.size()
		_add_route_between(node_id, nearest_id, &"secondary",
				"city_recovery_%s_%s" % [node_id, nearest_id])
		if _city_edges.size() == before:
			_add_route_between(node_id, nearest_id, &"secondary",
				"city_recovery_bridge_%s_%s" % [node_id, nearest_id], true)
		connected = _reachable_city_nodes("market_square")


func _reachable_city_nodes(root_id: String) -> Dictionary:
	var out := {}
	if not _city_node_by_id.has(root_id):
		return out
	var adjacency: Dictionary = {}
	for node: Dictionary in _city_nodes:
		adjacency[str(node["id"])] = []
	for edge: Dictionary in _city_edges:
		var a_id := str(edge["a"])
		var b_id := str(edge["b"])
		(adjacency[a_id] as Array).append(b_id)
		(adjacency[b_id] as Array).append(a_id)
	var queue: Array[String] = [root_id]
	out[root_id] = true
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for next_variant in adjacency.get(current, []) as Array:
			var next_id := str(next_variant)
			if out.has(next_id):
				continue
			out[next_id] = true
			queue.append(next_id)
	return out


func _nearest_node_of_kind(p: Vector2, kind: StringName) -> String:
	var best := ""
	var best_d := INF
	for node: Dictionary in _city_nodes:
		if node.get("kind", &"") != kind:
			continue
		var d: float = p.distance_to(node.get("center", Vector2.ZERO) as Vector2)
		if d < best_d or (is_equal_approx(d, best_d)
				and String(node["id"]) < best):
			best_d = d
			best = String(node["id"])
	return best


## Nearest of the three inner-connector landmarks (civic / station /
## castle), deterministic with id tie-break. Returns "" when none exists.
## P2B-FIX: gate arterials and bridge approaches terminate here, not at hub.
func _nearest_inner_connector(p: Vector2) -> String:
	var best := ""
	var best_d := INF
	for candidate in ["civic_square", "castle_hill", "rail_station"]:
		if not _city_node_by_id.has(candidate):
			continue
		var d := p.distance_to(_node_position(candidate))
		if d < best_d or (is_equal_approx(d, best_d) and candidate < best):
			best_d = d
			best = candidate
	return best


## True when a direct edge already joins the pair (either direction).
func _have_direct_edge(a_id: String, b_id: String) -> bool:
	for edge: Dictionary in _city_edges:
		var ea := String(edge.get("a", ""))
		var eb := String(edge.get("b", ""))
		if (ea == a_id and eb == b_id) or (ea == b_id and eb == a_id):
			return true
	return false


## P2B-FIX void infill. Grid-sampled dense-band points far from every road
## mark unserved ground; cluster centroids become stub nodes joined to the
## nearest existing node. Capped, deterministic, admission-checked like all
## routes (recovery backstops rejections).
func _add_void_infill() -> void:
	var pts: Array[Vector2] = []
	var gx := -560.0
	while gx <= 560.0:
		var gz := -560.0
		while gz <= 560.0:
			var p := Vector2(gx, gz)
			if p.length() < 560.0 and _is_valid_city_land(p) \
					and _distance_to_city_road_raw(p) > 55.0:
				pts.append(p)
			gz += 64.0
		gx += 64.0
	# Deepest voids first: the unserved heart of a mega-face claims its own
	# cluster instead of being shadowed by a far edge point. Distances are
	# precomputed once (the comparator runs O(n log n) times).
	var scored: Array = []
	for p in pts:
		scored.append([_distance_to_city_road_raw(p), p.x, p.y])
	scored.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] > b[0] if not is_equal_approx(a[0], b[0]) \
			else (a[1] < b[1] if not is_equal_approx(a[1], b[1]) \
				else a[2] < b[2]))
	var clusters: Array[Vector2] = []
	for entry in scored:
		var p := Vector2(entry[1], entry[2])
		var covered := false
		for c in clusters:
			if p.distance_to(c) < 120.0:
				covered = true
				break
		if not covered:
			clusters.append(p)
		if clusters.size() >= 12:
			break
	for i in clusters.size():
		var id := "infill_%02d" % i
		var snapped := _nearest_valid_city_point(clusters[i], 3)
		if snapped == Vector2.INF:
			continue
		_add_city_node(id, snapped, &"local_pocket")
		var best_id := ""
		var best_d := INF
		for n in _city_nodes:
			var nid := String(n["id"])
			# P2B-FIX: never hang infill stubs on the market — hub degree is
			# capped and recovery remains the only last-resort path to it.
			if nid == id or nid == "market_square":
				continue
			var d := snapped.distance_to(_node_position(nid))
			if d < best_d or (is_equal_approx(d, best_d) and nid < best_id):
				best_d = d
				best_id = nid
		if best_id != "":
			_add_route_between(best_id, id, &"secondary",
				"city_infill_%s" % id)


func _nearest_primary_node(p: Vector2) -> String:
	var best := "market_square"
	var best_d := p.distance_to(_node_position(best))
	for edge: Dictionary in _city_edges:
		if edge.get("hierarchy", &"") != &"primary":
			continue
		for id in [String(edge["a"]), String(edge["b"])]:
			var d := p.distance_to(_node_position(id))
			if d < best_d:
				best_d = d
				best = id
	return best


func _add_route_between(a_id: String, b_id: String, hierarchy: StringName,
		base_id: String, force_bridge := false) -> void:
	if a_id == b_id or not _city_node_by_id.has(a_id) or not _city_node_by_id.has(b_id):
		return
	var direct_id := base_id
	if _city_edge_ids.has(direct_id):
		return
	var a := _node_position(a_id)
	var b := _node_position(b_id)
	var poly := _curve_between(a, b, base_id, hierarchy)
	var water_info := _water_crossing_info(poly)
	if water_info["water"] and not force_bridge and not bool(water_info["near_crossing"]):
		var crossing_id: String = String(water_info.get("crossing_id", ""))
		if crossing_id != "" and crossing_id != a_id and crossing_id != b_id:
			_add_route_between(a_id, crossing_id, hierarchy, base_id + "_a", true)
			_add_route_between(crossing_id, b_id, hierarchy, base_id + "_b", true)
		return
	if poly.size() < 2:
		return
	var is_bridge: bool = force_bridge and bool(water_info["water"])
	if not is_bridge and bool(water_info["water"]):
		# A non-crossing local road never cuts the river.  It is allowed to end
		# on a dry bank, but not to continue through water.
		return
	var length := 0.0
	for i in range(poly.size() - 1):
		length += poly[i].distance_to(poly[i + 1])
	var width := _city_road_width(hierarchy)
	var influence := _route_influence(poly)
	var edge := {
		"id": direct_id,
		"a": a_id,
		"b": b_id,
		"hierarchy": hierarchy,
		"width": width,
		"length": length,
		"polyline": poly,
		"is_bridge": is_bridge,
		"water_id": String(water_info.get("water_id", "")),
		"crossing_id": String(water_info.get("crossing_id", "")),
		"a_center": a,
		"b_center": b,
		"influence": influence["primary"],
		"influences": influence["tags"],
		"max_slope_deg": influence["max_slope_deg"],
		"river_clearance_m": influence["river_clearance_m"],
	}
	_city_edges.append(edge)
	_city_edge_ids[direct_id] = true


func _city_road_width(hierarchy: StringName) -> float:
	match hierarchy:
		&"primary": return WorldConstants.CITY_ROAD_WIDTH_PRIMARY
		&"secondary": return WorldConstants.CITY_ROAD_WIDTH_SECONDARY
		&"local": return WorldConstants.CITY_ROAD_WIDTH_LOCAL
		&"alley": return WorldConstants.CITY_ROAD_WIDTH_ALLEY
	return WorldConstants.CITY_ROAD_WIDTH_LOCAL


func _curve_between(a: Vector2, b: Vector2, edge_id: String,
		hierarchy: StringName) -> PackedVector2Array:
	var ab := b - a
	var length := ab.length()
	if length < 0.01:
		return PackedVector2Array([a, b])
	var perp := Vector2(-ab.y, ab.x).normalized()
	var curve_domain := "city_curve_%s" % String(hierarchy)
	var signed := _u(curve_domain, [WorldSeed.str_hash(edge_id)]) * 2.0 - 1.0
	var max_bend := 0.0
	match hierarchy:
		&"primary": max_bend = clampf(length * 0.085, 10.0, 38.0)
		&"secondary": max_bend = clampf(length * 0.12, 6.0, 28.0)
		&"local": max_bend = clampf(length * 0.16, 3.0, 15.0)
		_: max_bend = clampf(length * 0.20, 2.0, 10.0)
	var control := (a + b) * 0.5 + perp * signed * max_bend
	# Terrain and river are continuous influences, not post-generation labels.
	# Approximate the local height gradient and river tangent deterministically;
	# the route bows around steep ground and follows a bank before it crosses.
	var mid := (a + b) * 0.5
	var sample := 14.0
	var gx := terrain.height_at(mid + Vector2(sample, 0.0)) - terrain.height_at(mid - Vector2(sample, 0.0))
	var gz := terrain.height_at(mid + Vector2(0.0, sample)) - terrain.height_at(mid - Vector2(0.0, sample))
	var gradient := Vector2(gx, gz)
	var slope_factor := clampf(gradient.length() / (sample * 2.0), 0.0, 1.0)
	if gradient.length_squared() > 1e-5:
		control -= gradient.normalized() * slope_factor * 14.0
	var river_x0 := hydrology.river_center_x_at(mid.y - 24.0)
	var river_x1 := hydrology.river_center_x_at(mid.y + 24.0)
	var river_tangent := Vector2(river_x1 - river_x0, 48.0).normalized()
	var river_proximity := clampf(150.0 / maxf(hydrology.distance_to_water(mid), 24.0) - 0.25, 0.0, 1.0)
	control += river_tangent * river_proximity * 9.0
	var samples := clampi(int(length / WorldConstants.CITY_ROAD_SAMPLE_M) + 2, 3, 28)
	var out := PackedVector2Array()
	out.resize(samples)
	for i in samples:
		var t := float(i) / float(samples - 1)
		var u := 1.0 - t
		out[i] = u * u * a + 2.0 * u * t * control + t * t * b
	return out


func _water_crossing_info(poly: PackedVector2Array) -> Dictionary:
	var info := {
		"water": false,
		"near_crossing": false,
		"crossing_id": "",
		"water_id": "",
		"distance": INF,
	}
	var crossing_nodes: Array[Dictionary] = []
	for node: Dictionary in _city_nodes:
		if node.get("kind", &"") == &"river_crossing":
			crossing_nodes.append(node)
	for pt: Vector2 in poly:
		var body: StringName = hydrology.water_body_at(pt)
		if body == &"":
			continue
		info["water"] = true
		info["water_id"] = hydrology.water_body_id_at(pt)
		for node: Dictionary in crossing_nodes:
			var cp: Vector2 = node["center"] as Vector2
			var d := pt.distance_to(cp)
			if d < float(node.get("radius", 22.0)) + 74.0 and d < float(info["distance"]):
				info["near_crossing"] = true
				info["distance"] = d
				info["crossing_id"] = String(node["id"])
	return info


func _route_influence(poly: PackedVector2Array) -> Dictionary:
	var max_slope := 0.0
	var min_river_clearance := INF
	for p: Vector2 in poly:
		max_slope = maxf(max_slope, terrain.slope_at(p))
		min_river_clearance = minf(min_river_clearance, hydrology.distance_to_water(p))
	var tags: Array[StringName] = []
	if min_river_clearance < 150.0:
		tags.append(&"river")
	if max_slope > 8.0:
		tags.append(&"terrain_slope")
	if tags.is_empty():
		tags.append(&"landmark")
	var primary: StringName = tags[0]
	return {
		"primary": primary,
		"tags": tags,
		"max_slope_deg": max_slope,
		"river_clearance_m": min_river_clearance,
	}


func _nearest_valid_city_point(p: Vector2, attempts: int) -> Vector2:
	var candidates: Array[Vector2] = [p]
	for i in attempts:
		var angle := TAU * _u("city_point_retry_angle", [roundi(p.x), roundi(p.y), i])
		var radius := 18.0 + 22.0 * _u("city_point_retry_radius", [roundi(p.x), roundi(p.y), i])
		candidates.append(p + Vector2(cos(angle), sin(angle)) * radius)
	for candidate: Vector2 in candidates:
		if not _is_valid_city_land(candidate):
			continue
		return candidate
	return Vector2.INF


func _is_valid_city_land(p: Vector2) -> bool:
	if p.length() > WorldConstants.CITY_BLOCK_RADIUS_M - 12.0:
		return false
	if hydrology.water_body_at(p) != &"" or hydrology.is_floodplain(p):
		return false
	if biome.is_quarry(p):
		return false
	return terrain.slope_at(p) < 31.0


# -----------------------------------------------------------------------------
# Irregular block cells and parcels

func _generate_city_blocks() -> void:
	_blocks.clear()
	_block_by_cell.clear()
	_all_buildings.clear()
	_building_by_id.clear()
	_building_cache.clear()
	var sites: Array[Vector2] = []
	# Civic sites are inserted first, giving the central city a stable market
	# square and several smaller squares without a random open clearing.
	for id in ["market_square", "civic_square", "rail_station", "castle_hill"]:
		if not _city_node_by_id.has(id):
			continue
		var p: Vector2 = _node_position(id)
		if _is_valid_city_land(p):
			sites.append(p)
	# Deterministic Poisson-like site acceptance.  This produces irregular
	# spacing and avoids a repeated square perimeter while remaining cheap and
	# order-independent for any chunk query.
	for i in _CITY_SITE_CANDIDATES:
		if sites.size() >= _CITY_MAX_SITES:
			break
		var angle := _u("city_block_site_angle", [i]) * TAU
		var radius := 36.0 + sqrt(_u("city_block_site_radius", [i])) \
				* (WorldConstants.CITY_BLOCK_RADIUS_M - 42.0)
		var p := Vector2(cos(angle), sin(angle)) * radius
		if not _is_valid_city_land(p):
			continue
		if _near_rural_settlement(p):
			continue
		# Sites stay clear of the actual road ribbon; their Voronoi boundaries
		# then read as street fronts instead of streets through buildings.
		if _distance_to_city_road_raw(p) < 11.0:
			continue
		var normalized_r := clampf(radius / WorldConstants.CITY_BLOCK_RADIUS_M, 0.0, 1.0)
		var min_spacing := lerpf(48.0, 96.0, normalized_r)
		var too_close := false
		for existing: Vector2 in sites:
			if p.distance_to(existing) < min_spacing:
				too_close = true
				break
		if too_close:
			continue
		sites.append(p)
	# Stable site order makes block ids independent from query order.
	var site_records: Array[Dictionary] = []
	for i in sites.size():
		site_records.append({"index": i, "p": sites[i]})
	site_records.sort_custom(_site_record_cmp)
	var ordered_sites: Array[Vector2] = []
	for rec: Dictionary in site_records:
		ordered_sites.append(rec["p"] as Vector2)

	for i in ordered_sites.size():
		var site: Vector2 = ordered_sites[i]
		var poly := _city_boundary_polygon()
		for j in ordered_sites.size():
			if i == j:
				continue
			var other: Vector2 = ordered_sites[j]
			var normal := other - site
			if normal.length_squared() < 1e-6:
				continue
			var limit := (other.length_squared() - site.length_squared()) * 0.5
			poly = _clip_polygon_halfplane(poly, normal, limit)
			if poly.size() < 3:
				break
		if poly.size() < 3:
			continue
		var block := _make_block(i, site, poly)
		_blocks.append(block)
	# Macro Voronoi cells are useful in the outer districts, but they are too
	# large to describe historic street fronts. In the built core, subtract the
	# actual road ribbons and promote the resulting land faces to block cells.
	# This keeps the irregular macro boundary while making roads the block
	# partition authority rather than merely drawing roads over unrelated cells.
	_blocks = _split_city_blocks_by_roads(_blocks)

	_blocks.sort_custom(_dict_id_cmp)
	_block_by_cell.clear()
	for block: Dictionary in _blocks:
		_block_by_cell[block["cell"]] = block
	# Generate parcels only after all cells exist, so global overlap checks can
	# reject a pathological axis-aligned Rect2 that would cross a cell border.
	for block: Dictionary in _blocks:
		var buildings: Array = _buildings_for_block(block)
		block["buildings"] = buildings
		for spec: Dictionary in buildings:
			_all_buildings.append(spec)
			_building_by_id[String(spec["id"])] = spec
		_block_by_cell[block["cell"]] = block
	_append_global_road_frontage_fill()
	_all_buildings.sort_custom(_dict_id_cmp)
	_finalize_block_fabric()


## G10-P2B-FIX2: finalize the parcel surface contract after every frontage
## candidate has been considered. A built block owns only its road-side lots
## plus residual courtyard/garden regions; a dense empty face is explicitly a
## park rather than a falsely paved block. No scene mutation or RNG occurs here.
func _finalize_block_fabric() -> void:
	for block in _blocks:
		if (block.get("kind", &"built") as StringName) != &"built":
			continue
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		var buildings: Array = block.get("buildings", []) as Array
		var block_area := absf(_polygon_area(block.get("polygon",
			PackedVector2Array()) as PackedVector2Array))
		var occupied := 0.0
		var frontage_count := 0
		var corner_count := 0
		for spec_variant in buildings:
			var spec: Dictionary = spec_variant as Dictionary
			var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
			occupied += lot.size.x * lot.size.y
			if str(spec.get("frontage_role", "street")) == "corner":
				corner_count += 1
			else:
				frontage_count += 1
		block["occupied_area_m2"] = occupied
		block["frontage_buildings"] = frontage_count
		block["corner_buildings"] = corner_count
		block["courtyard_regions"] = []
		block["courtyard_area_m2"] = 0.0
		if buildings.is_empty():
			# Do not relabel every valid dense face as a park. Large/invalid
			# faces are intentional open space; smaller valid faces receive a
			# bounded garden region owned by this block instead of exposing the
			# terrain fallback as an unexplained gray plate.
			var invalid := not _is_valid_city_land(center)
			var intentional_park := block_area >= WorldConstants.CITY_EMPTY_DENSE_BLOCK_MAX_AREA_M2 \
					or (invalid and block_area >= 4000.0)
			if intentional_park:
				block["kind"] = &"park"
				block["void_reason"] = &"oversized_or_invalid_open_face"
				_block_by_cell[block["cell"]] = block
				continue
			var empty_regions: Array[Dictionary] = _courtyard_regions_for_block(block)
			if empty_regions.is_empty():
				block["kind"] = &"park"
				block["void_reason"] = &"small_open_face"
			else:
				block["courtyard_regions"] = empty_regions
				block["void_reason"] = &"bounded_block_garden"
				for region: Dictionary in empty_regions:
					block["courtyard_area_m2"] += float(region.get("area_m2", 0.0))
			_block_by_cell[block["cell"]] = block
			continue
		var regions: Array[Dictionary] = _courtyard_regions_for_block(block)
		block["courtyard_regions"] = regions
		for region: Dictionary in regions:
			block["courtyard_area_m2"] += float(region.get("area_m2", 0.0))
		_block_by_cell[block["cell"]] = block


## Derive one shared rear-court/garden surface from the owning block face.
## Tiny residual fragments are rejected so they cannot become detached-looking
## procedural shards.
func _courtyard_regions_for_block(block: Dictionary) -> Array[Dictionary]:
	var source: PackedVector2Array = block.get("polygon",
		PackedVector2Array()) as PackedVector2Array
	var source_area := absf(_polygon_area(source))
	if source.size() < 3 or source_area < WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
		return []
	# The building footprints already own the structural area. A single inset
	# of the same road-derived face is the cheap, stable representation of its
	# shared rear court; subtracting every rotated footprint with Geometry2D here
	# made plan generation quadratic and stalled the full contract suite.
	var inset_scale := 0.72 if source_area > WorldConstants.CITY_COURTYARD_MAX_SURFACE_AREA_M2 else 0.88
	var display_piece := _inset_polygon(source, inset_scale)
	var area := absf(_polygon_area(display_piece))
	if area < WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
		return []
	var buildings: Array = block.get("buildings", []) as Array
	var region_kind: StringName = &"courtyard" if buildings.size() >= 2 else &"garden"
	return [{
		"kind": region_kind,
		"polygon": display_piece,
		"area_m2": area,
		"center": _polygon_centroid(display_piece),
	}]


static func _inset_polygon(poly: PackedVector2Array, scale: float) -> PackedVector2Array:
	var center := _polygon_centroid(poly)
	var out := PackedVector2Array()
	for p: Vector2 in poly:
		out.append(center.lerp(p, clampf(scale, 0.55, 1.0)))
	return out


## P2B-FIX: historic fragments must be big enough to host real street walls.
## Slivers below this render as shredded pavement teeth.
func _min_split_area_for(piece: PackedVector2Array) -> float:
	if _polygon_centroid(piece).length() < WorldConstants.CITY_HISTORIC_RADIUS_M:
		return 150.0
	return _CITY_MIN_SPLIT_BLOCK_AREA


func _is_dense_block_source(source: Dictionary) -> bool:
	return (source.get("district", DISTRICT_OUTER) as StringName) != DISTRICT_OUTER


func _split_city_blocks_by_roads(source_blocks: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for source_index in source_blocks.size():
		var source: Dictionary = source_blocks[source_index]
		var source_kind: StringName = source.get("kind", &"built") as StringName
		var source_site: Vector2 = source.get("site", Vector2.ZERO) as Vector2
		# Parks/plazas and the looser outer ring remain macro cells. Built
		# historic/inner cells are split only by actual generated road ribbons.
		if source_kind != &"built" or source_site.length() >= 600.0:
			out.append(source)
			continue
		var pieces := _road_subtracted_pieces(source)
		if pieces.size() <= 1:
			out.append(source)
			continue
		var kept := 0
		for piece_index in pieces.size():
			var piece: PackedVector2Array = pieces[piece_index]
			if _polygon_area(piece) < _min_split_area_for(piece):
				continue
			var child := _make_split_block(source, source_index, piece_index, piece)
			if child.is_empty():
				continue
			out.append(child)
			kept += 1
		if kept == 0:
			var source_area := absf(_polygon_area(source.get("polygon",
				PackedVector2Array()) as PackedVector2Array))
			var source_center: Vector2 = source.get("center",
				Vector2.ZERO) as Vector2
			if not _is_dense_block_source(source):
				out.append(source)
			elif source_area >= 1200.0 and _is_valid_city_land(source_center):
				# P2B-FIX refined: big VALID crossed faces keep their
				# individually-validated lots (_lot_clear_of_city_roads rejects
				# overlaps per parcel). Only shredded small faces stay dropped.
				out.append(source)
			# Else: shredded dense face stays dropped — no pavement teeth.
	return out


func _road_subtracted_pieces(source: Dictionary) -> Array[PackedVector2Array]:
	var original: PackedVector2Array = source.get("polygon", PackedVector2Array()) as PackedVector2Array
	var pieces: Array[PackedVector2Array] = [original]
	var bounds: Rect2 = source.get("bounds", source.get("rect", Rect2())) as Rect2
	for edge: Dictionary in _city_edges:
		var width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		var road_poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if not _polyline_bounds(road_poly).intersects(bounds.grow(width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE)):
			continue
		for segment_i in range(road_poly.size() - 1):
			var a: Vector2 = road_poly[segment_i]
			var b: Vector2 = road_poly[segment_i + 1]
			if a.distance_to(b) < 2.0:
				continue
			if not bounds.grow(width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE).intersects(
					Rect2(a, Vector2.ZERO).expand(b)):
				continue
			var strip := _road_strip_polygon(a, b,
					width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE)
			var next: Array[PackedVector2Array] = []
			for subject: PackedVector2Array in pieces:
				var clipped: Array = Geometry2D.clip_polygons(subject, strip)
				for variant in clipped:
					var result: PackedVector2Array = variant as PackedVector2Array
					if _polygon_area(result) >= _min_split_area_for(result):
						next.append(result)
			pieces = next
			if pieces.is_empty():
				return pieces
	return pieces


func _make_split_block(source: Dictionary, source_index: int,
		piece_index: int, poly: PackedVector2Array) -> Dictionary:
	if poly.size() < 3:
		return {}
	var bounds := _polygon_bounds(poly)
	var rect := _safe_block_rect(poly, bounds)
	var center := _polygon_centroid(poly)
	# P2B-FIX: historic slivers that cannot host a 5.4 m frontage lot are
	# rejected here, not rendered as pavement teeth.
	var min_side := 6.0 if center.length() < WorldConstants.CITY_HISTORIC_RADIUS_M else 4.0
	if rect.size.x < min_side or rect.size.y < min_side:
		return {}
	var radius := center.length()
	var district: StringName = DISTRICT_HISTORIC
	if radius >= WorldConstants.CITY_HISTORIC_RADIUS_M:
		district = DISTRICT_INNER if radius < WorldConstants.CITY_DENSE_RADIUS_M else DISTRICT_OUTER
	var block := source.duplicate(true)
	block["id"] = "%s_r%02d" % [str(source.get("id", "city_block")), piece_index]
	block["cell"] = Vector2i(source_index * 1024 + piece_index,
			-source_index * 1024 - piece_index - 1)
	block["site"] = center
	block["center"] = center
	block["rect"] = rect
	block["bounds"] = bounds
	block["polygon"] = poly
	block["district"] = district
	block["road_derived"] = true
	block["passage"] = {}
	block["buildings"] = []
	if block.get("kind", &"built") == &"built" and rect.size.x > 30.0 and rect.size.y > 30.0:
		block["passage"] = _passage_for_block(block, source_index * 1024 + piece_index)
	return block


func _road_strip_polygon(a: Vector2, b: Vector2, half_width: float) -> PackedVector2Array:
	var delta := b - a
	if delta.length_squared() < 1e-6:
		return PackedVector2Array()
	var tangent := delta.normalized()
	var normal := Vector2(-tangent.y, tangent.x) * half_width
	var extension := tangent * 1.0
	var aa := a - extension
	var bb := b + extension
	return PackedVector2Array([aa - normal, bb - normal, bb + normal, aa + normal])


func _polyline_bounds(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for p: Vector2 in poly:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


func _polygon_bounds(poly: PackedVector2Array) -> Rect2:
	return _polyline_bounds(poly)


func _append_global_road_frontage_fill() -> void:
	# A bounded second frontage pass closes the gaps left when an axis-aligned
	# contract rectangle cannot fit a diagonal Voronoi edge. It is still
	# road-driven, block-owned, deterministic, and uses the normal city builder.
	var caps: Array[int] = [170, 340, 45]
	var added: Array[int] = [0, 0, 0]
	for edge_i in _city_edges.size():
		var edge: Dictionary = _city_edges[edge_i]
		var hierarchy: StringName = edge.get("hierarchy", &"local") as StringName
		if hierarchy == &"alley":
			continue
		var road_width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		var road_poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		for segment_i in range(road_poly.size() - 1):
			var a: Vector2 = road_poly[segment_i]
			var b: Vector2 = road_poly[segment_i + 1]
			var delta := b - a
			var segment_len := delta.length()
			if segment_len < 4.0:
				continue
			var tangent := delta / segment_len
			var normal := Vector2(-tangent.y, tangent.x)
			var pieces := clampi(int(ceil(segment_len / 7.0)), 1, 6)
			for piece in pieces:
				var road_mid := a.lerp(b, (float(piece) + 0.5) / float(pieces))
				var radius := road_mid.length()
				var band := 0 if radius < WorldConstants.CITY_HISTORIC_RADIUS_M else (1 if radius < 600.0 else 2)
				if radius >= WorldConstants.CITY_BLOCK_RADIUS_M - 12.0 or added[band] >= caps[band]:
					continue
				var frontage := 6.4 if band == 0 else (7.4 if band == 1 else 8.0)
				var depth_min := 14.0 if band == 0 else (15.0 if band == 1 else 10.0)
				var depth_max := 22.0 if band == 0 else (23.0 if band == 1 else 15.5)
				var depth := lerpf(depth_min, depth_max,
						_u("city_global_frontage_depth", [edge_i, segment_i, piece]))
				var width_low := 0.90 if band == 0 else (0.87 if band == 1 else 0.72)
				var width_high := 0.99 if band == 0 else (0.98 if band == 1 else 0.90)
				var frontage_width := segment_len / float(pieces) * lerpf(
						width_low, width_high,
						_u("city_global_frontage_width", [edge_i, segment_i, piece]))
				var min_frontage := 4.8 if band == 0 else 5.4
				frontage_width = clampf(frontage_width, min_frontage, 11.0)
				var footprint := Vector2(frontage_width, depth)
				var yaw := atan2(tangent.y, tangent.x)
				for side_i in 2:
					if added[band] >= caps[band]:
						break
					var side := -1.0 if side_i == 0 else 1.0
					var center := road_mid + normal * side * (road_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 0.15 + depth * 0.5)
					var block := _block_containing_point(center)
					if block.is_empty() or block.get("kind", &"") == &"park":
						continue
					var lot := _fit_frontage_lot(center, footprint, yaw, block["polygon"] as PackedVector2Array)
					if lot.size.x <= 0.0 or lot.size.y <= 0.0:
						# A road-frontage lot that cannot fit inside its actual
						# road-derived face is rejected. Never restore a raw rectangle:
						# that creates detached buildings and corrupts block ownership.
						continue
					if lot.size.x <= 0.0 or lot.size.y <= 0.0 or not _city_lot_has_valid_land(lot, yaw):
						continue
					if not _is_valid_city_land(center) or _near_rural_settlement(center):
						continue
					var passage: Dictionary = block.get("passage", {}) as Dictionary
					if not passage.is_empty() and _lots_overlap(lot, yaw,
							passage["rect"] as Rect2, 0.0, 0.25):
						continue
					if _distance_to_city_road_raw(center) < 5.0 or not _lot_clear_of_city_roads(lot, yaw):
						continue
					if _city_lot_overlaps_existing(lot, yaw):
						continue
					var door_edge := _door_edge_for_front(center, normal * side, lot, yaw)
					var block_buildings: Array = block.get("buildings", []) as Array
					var spec := _make_city_spec(block, lot, door_edge,
							4000 + edge_i * 64 + segment_i * 2 + side_i,
							block_buildings.size(), radius, yaw)
					spec["frontage_role"] = &"corner" if _is_corner_frontage(road_mid) else &"street"
					spec["frontage_edge_id"] = str(edge.get("id", ""))
					spec["frontage_center"] = road_mid
					block_buildings.append(spec)
					block["buildings"] = block_buildings
					_all_buildings.append(spec)
					_building_by_id[String(spec["id"])] = spec
					added[band] += 1


func _block_containing_point(p: Vector2) -> Dictionary:
	for block: Dictionary in _blocks:
		if _polygon_contains(block.get("polygon", PackedVector2Array()) as PackedVector2Array, p):
			return block
	return {}


func _fit_frontage_lot(center: Vector2, footprint: Vector2, yaw: float,
		poly: PackedVector2Array) -> Rect2:
	# Preserve the road-facing width first. The old uniform shrink reduced the
	# facade whenever a deep lot met an oblique block edge, creating avoidable
	# gaps along otherwise usable frontages. Depth yields before frontage width.
	var frontage_trial := footprint.x
	var depth_trial := footprint.y
	for _i in 10:
		var trial := Vector2(frontage_trial, depth_trial)
		var lot := Rect2(center - trial * 0.5, trial)
		if _lot_inside_polygon(lot, yaw, poly):
			return lot
		if depth_trial > 8.0:
			depth_trial *= 0.84
		else:
			frontage_trial *= 0.92
		if frontage_trial < 4.8 or depth_trial < 5.5:
			break
	return Rect2()


func _city_lot_has_valid_land(lot: Rect2, yaw := 0.0) -> bool:
	if lot.size.x <= 0.0 or lot.size.y <= 0.0:
		return false
	for p: Vector2 in _lot_corners(lot, yaw):
		if not _is_valid_city_land(p):
			return false
	return true


func _city_lot_overlaps_existing(lot: Rect2, yaw := 0.0) -> bool:
	for spec: Dictionary in _all_buildings:
		if _lots_overlap(lot, yaw, spec["rect"] as Rect2,
				float(spec.get("yaw", 0.0)), 0.22):
			return true
	return false


## A frontage segment is a corner candidate when it is close to a real
## multi-way road node. The lot remains subject to the ordinary polygon and
## road-clearance checks; this only labels/weights the building role.
func _is_corner_frontage(p: Vector2) -> bool:
	for node: Dictionary in _city_nodes:
		if int(node.get("degree", 0)) < 3:
			continue
		var center: Vector2 = node.get("center", Vector2.ZERO) as Vector2
		if p.distance_to(center) <= 16.0:
			return true
	return false


func _city_boundary_polygon() -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in _CITY_BOUNDARY_SIDES:
		var angle := TAU * float(i) / float(_CITY_BOUNDARY_SIDES)
		out.append(Vector2(cos(angle), sin(angle)) * WorldConstants.CITY_BLOCK_RADIUS_M)
	return out


func _safe_block_rect(poly: PackedVector2Array, bounds: Rect2) -> Rect2:
	var center := _polygon_centroid(poly)
	var half := Vector2(minf(bounds.size.x * 0.23, 30.0),
			minf(bounds.size.y * 0.23, 30.0))
	for _i in 18:
		var rect := Rect2(center - half, half * 2.0)
		if _rect_inside_polygon(rect, poly):
			return rect
		half *= 0.86
	return Rect2(center - half, half * 2.0)


func _make_block(index: int, site: Vector2, poly: PackedVector2Array) -> Dictionary:
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for p: Vector2 in poly:
		min_x = minf(min_x, p.x)
		min_z = minf(min_z, p.y)
		max_x = maxf(max_x, p.x)
		max_z = maxf(max_z, p.y)
	var bounds := Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))
	var rect := _safe_block_rect(poly, bounds)
	var radius := site.length()
	var kind: StringName = &"built"
	var nearby_square := false
	for lm: Dictionary in _landmarks:
		var lk: StringName = lm.get("kind", &"") as StringName
		if lk == &"market_square" or lk == &"civic_square" or lk == &"station":
			if site.distance_to(lm["center"] as Vector2) < 62.0:
				nearby_square = true
				break
	if nearby_square or (radius < 90.0 and index == 0):
		kind = &"plaza"
	elif _u("city_block_kind", [index]) < 0.10:
		kind = &"park"
	var district: StringName = DISTRICT_HISTORIC
	if radius >= WorldConstants.CITY_HISTORIC_RADIUS_M:
		district = DISTRICT_INNER if radius < WorldConstants.CITY_DENSE_RADIUS_M else DISTRICT_OUTER
	var block := {
		"id": "city_block_%04d" % index,
		"cell": Vector2i(index, -index - 1),
		"site": site,
		"center": _polygon_centroid(poly),
		"rect": rect,
		"bounds": bounds,
		"polygon": poly,
		"kind": kind,
		"district": district,
		"passage": {},
		"buildings": [],
	}
	if kind == &"built" and rect.size.x > 30.0 and rect.size.y > 30.0:
		block["passage"] = _passage_for_block(block, index)
	return block


func _passage_for_block(block: Dictionary, index: int) -> Dictionary:
	var br: Rect2 = block["rect"] as Rect2
	var chance := 0.34
	if block.get("district", DISTRICT_OUTER) == DISTRICT_HISTORIC:
		chance = 0.58
	elif block.get("district", DISTRICT_OUTER) == DISTRICT_INNER:
		chance = 0.46
	if _u("city_alley_presence", [index]) >= chance:
		return {}
	var axis := 0 if _u("city_alley_axis", [index]) < 0.5 else 1
	var width := lerpf(WorldConstants.CITY_ALLEY_WIDTH * 1.65,
			WorldConstants.CITY_ALLEY_WIDTH * 2.45, _u("city_alley_width", [index]))
	if axis == 0:
		var x := lerpf(br.position.x + width, br.end.x - width,
				_u("city_alley_position", [index]))
		return {"axis": 0, "half": width * 0.5,
			"rect": Rect2(x - width * 0.5, br.position.y, width, br.size.y),
			"kind": &"historic_alley"}
	var z := lerpf(br.position.y + width, br.end.y - width,
			_u("city_alley_position", [index]))
	return {"axis": 1, "half": width * 0.5,
		"rect": Rect2(br.position.x, z - width * 0.5, br.size.x, width),
		"kind": &"historic_alley"}


func _buildings_for_block(block: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if block["kind"] == &"park":
		return result
	var poly: PackedVector2Array = block["polygon"] as PackedVector2Array
	var site: Vector2 = block["site"] as Vector2
	var radius := site.length()
	var district: StringName = block["district"] as StringName
	var frontage := 8.0
	var max_buildings := 7
	if district == DISTRICT_HISTORIC:
		frontage = 6.4
		max_buildings = 18
	elif district == DISTRICT_INNER:
		frontage = 7.4
		max_buildings = 16
	if block["kind"] == &"plaza":
		frontage = 5.6
		max_buildings = 16
	# Boundary walk is the primary pass for irregular road-derived faces: it
	# follows the actual owning polygon and cannot jump into a block centre.
	if block["kind"] == &"built" and radius < WorldConstants.CITY_DENSE_RADIUS_M:
		_append_boundary_frontage_lots(result, block, poly, radius, max_buildings)
	if block["kind"] == &"built" and result.size() < max_buildings:
		_append_road_frontage_lots(result, block, poly, radius, frontage, max_buildings)
	# Every accepted parcel in this function is produced against an actual
	# road frontage. Polygon-edge, corner, and site-centre fallbacks are
	# intentionally absent: a valid irregular block is not permission to place
	# a detached building away from a street.
	return result


func _append_road_frontage_lots(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, radius: float, frontage: float,
		max_buildings: int) -> void:
	var bounds: Rect2 = block.get("bounds", block.get("rect", Rect2())) as Rect2
	var district: StringName = block.get("district", DISTRICT_OUTER) as StringName
	var dense_frontage := district == DISTRICT_HISTORIC or district == DISTRICT_INNER
	var depth_min := 10.0
	var depth_max := 15.5
	if district == DISTRICT_HISTORIC:
		depth_min = 13.5
		depth_max = 22.0
	elif district == DISTRICT_INNER:
		depth_min = 14.0
		depth_max = 22.0
	if block.get("kind", &"built") == &"plaza":
		depth_min = 8.0
		depth_max = 13.0
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	for edge_i in _city_edges.size():
		if result.size() >= max_buildings:
			return
		var edge: Dictionary = _city_edges[edge_i]
		var road_width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		var road_poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		for segment_i in range(road_poly.size() - 1):
			if result.size() >= max_buildings:
				return
			var a: Vector2 = road_poly[segment_i]
			var b: Vector2 = road_poly[segment_i + 1]
			var delta := b - a
			var segment_len := delta.length()
			if segment_len < 4.0:
				continue
			var mid := (a + b) * 0.5
			if not bounds.grow(52.0).has_point(mid):
				continue
			var tangent := delta / segment_len
			var normal := Vector2(-tangent.y, tangent.x)
			var pieces := clampi(int(floor(segment_len / maxf(frontage + 1.4, 5.5))), 1, 6)
			for piece in pieces:
				if result.size() >= max_buildings:
					return
				var t := (float(piece) + 0.5) / float(pieces)
				var road_mid := a.lerp(b, t)
				var width_roll := _u("city_road_frontage_width", [edge_i, segment_i, piece])
				var width_low := 0.90 if district == DISTRICT_HISTORIC else (0.87 if district == DISTRICT_INNER else 0.72)
				var width_high := 0.995 if district == DISTRICT_HISTORIC else (0.985 if district == DISTRICT_INNER else 0.90)
				var frontage_width := segment_len / float(pieces) * lerpf(
						width_low, width_high, width_roll)
				frontage_width = clampf(frontage_width,
						4.8 if block.get("kind", &"") == &"plaza" else 5.4,
						11.0 if dense_frontage else 12.0)
				if dense_frontage:
					frontage_width = minf(frontage_width,
							segment_len / float(pieces) - WorldConstants.CITY_FRONTAGE_GAP_MAX_M)
				if frontage_width < 5.4:
					continue
				var depth := lerpf(depth_min, depth_max,
						_u("city_road_frontage_depth", [edge_i, segment_i, piece]))
				var footprint := Vector2(frontage_width, depth)
				var yaw := atan2(tangent.y, tangent.x)
				for side_i in 2:
					if result.size() >= max_buildings:
						return
					var side := -1.0 if side_i == 0 else 1.0
					var center := road_mid + normal * side * (road_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 0.15 + depth * 0.5)
					var lot := _fit_frontage_lot(center, footprint, yaw, poly)
					if lot.size.x <= 0.0 or lot.size.y <= 0.0:
						continue
					if not _is_valid_city_land(center) or _near_rural_settlement(center):
						continue
					if not passage.is_empty() and _lots_overlap(lot, yaw,
							passage["rect"] as Rect2, 0.0, 0.25):
						continue
					if _distance_to_city_road_raw(center) < 5.0 or not _lot_clear_of_city_roads(lot, yaw):
						continue
					var duplicate := false
					for existing: Dictionary in result:
						if _lots_overlap(lot, yaw, existing["rect"] as Rect2,
								float(existing.get("yaw", 0.0)), 0.22):
							duplicate = true
							break
					if duplicate:
						continue
					var door_edge := _door_edge_for_front(center, normal * side, lot, yaw)
					var token := 1000 + edge_i * 16 + segment_i * 2 + side_i
					var spec := _make_city_spec(block, lot, door_edge, token,
							result.size(), radius, yaw)
					spec["frontage_role"] = &"corner" if _is_corner_frontage(road_mid) else &"street"
					spec["frontage_edge_id"] = str(edge.get("id", ""))
					spec["frontage_center"] = road_mid
					result.append(spec)


func _append_boundary_frontage_lots(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, radius: float, max_buildings: int) -> void:
	# A road ribbon can split a concave cell into a face whose centroid no
	# longer provides a valid rectangle center. Walk the actual face boundary
	# instead: only edges close to a generated road may seed a parcel, and the
	# inward normal is proved against the owning polygon before placement.
	if poly.size() < 3:
		return
	var district: StringName = block.get("district", DISTRICT_INNER) as StringName
	var min_width := 4.8 if district == DISTRICT_HISTORIC else 5.4
	var max_width := 8.8 if district == DISTRICT_HISTORIC else 10.0
	var depth_min := 14.0 if district == DISTRICT_HISTORIC else 15.0
	var depth_max := 22.0 if district == DISTRICT_HISTORIC else 23.0
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	for boundary_i in poly.size():
		if result.size() >= max_buildings:
			return
		var a: Vector2 = poly[boundary_i]
		var z: Vector2 = poly[(boundary_i + 1) % poly.size()]
		var boundary_delta := z - a
		var boundary_len := boundary_delta.length()
		if boundary_len < 5.0:
			continue
		var pieces := clampi(int(floor(boundary_len / maxf(min_width + 1.0, 5.5))), 1, 4)
		for piece in pieces:
			if result.size() >= max_buildings:
				return
			var t := (float(piece) + 0.5) / float(pieces)
			var edge_mid := a.lerp(z, t)
			var nearest_edge_i := -1
			var nearest_distance := INF
			var nearest_width := WorldConstants.CITY_ROAD_WIDTH_LOCAL
			for road_i in _city_edges.size():
				var road_edge: Dictionary = _city_edges[road_i]
				var road_poly: PackedVector2Array = road_edge.get("polyline",
						PackedVector2Array()) as PackedVector2Array
				var distance := _distance_to_polyline(edge_mid, road_poly)
				if distance < nearest_distance:
					nearest_distance = distance
					nearest_edge_i = road_i
					nearest_width = float(road_edge.get("width",
							WorldConstants.CITY_ROAD_WIDTH_LOCAL))
			if nearest_edge_i < 0 or nearest_distance > nearest_width * 0.5 \
					+ _CITY_ROAD_BLOCK_CLEARANCE + 0.8:
				continue
			var tangent := boundary_delta.normalized()
			var inward := Vector2(-tangent.y, tangent.x)
			if not _polygon_contains(poly, edge_mid + inward * 1.0):
				inward = -inward
			if not _polygon_contains(poly, edge_mid + inward * 1.0):
				continue
			var frontage_width := clampf(boundary_len / float(pieces) * 0.90,
					min_width, max_width)
			var depth := lerpf(depth_min, depth_max,
					_u("city_boundary_frontage_depth", [nearest_edge_i, boundary_i, piece]))
			var yaw := atan2(tangent.y, tangent.x)
			var lot := Rect2()
			for inset in [0.18, 0.55, 0.92]:
				var center := edge_mid + inward * (float(inset) + depth * 0.5)
				lot = _fit_frontage_lot(center, Vector2(frontage_width, depth), yaw, poly)
				if lot.size.x > 0.0 and lot.size.y > 0.0:
					break
			if lot.size.x <= 0.0 or lot.size.y <= 0.0:
				continue
			if not _city_lot_has_valid_land(lot, yaw) or _near_rural_settlement(lot.get_center()):
				continue
			if not passage.is_empty() and _lots_overlap(lot, yaw,
					passage["rect"] as Rect2, 0.0, 0.25):
				continue
			if not _lot_clear_of_city_roads(lot, yaw):
				continue
			var duplicate := false
			for existing: Dictionary in result:
				if _lots_overlap(lot, yaw, existing["rect"] as Rect2,
						float(existing.get("yaw", 0.0)), 0.22):
					duplicate = true
					break
			if duplicate or _city_lot_overlaps_existing(lot, yaw):
				continue
			var door_edge := _door_edge_for_front(lot.get_center(), inward, lot, yaw)
			var spec := _make_city_spec(block, lot, door_edge,
					5000 + nearest_edge_i * 8 + boundary_i,
					result.size(), radius, yaw)
			spec["frontage_role"] = &"corner" if _is_corner_frontage(edge_mid) else &"street"
			spec["frontage_edge_id"] = str(_city_edges[nearest_edge_i].get("id", ""))
			spec["frontage_center"] = edge_mid
			result.append(spec)


func _append_rear_frontage_lot(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, passage: Dictionary, radius: float,
		edge_i: int, segment_i: int, piece: int, side_i: int,
		road_width: float, normal: Vector2, side: float, road_mid: Vector2,
		frontage_width: float, front_depth: float, yaw: float,
		max_buildings: int) -> void:
	if result.size() >= max_buildings:
		return
	var district: StringName = block.get("district", DISTRICT_INNER) as StringName
	var rear_depth_min := 9.5 if district == DISTRICT_HISTORIC else 10.5
	var rear_depth_max := 13.5 if district == DISTRICT_HISTORIC else 15.5
	var rear_depth := lerpf(rear_depth_min, rear_depth_max,
			_u("city_rear_frontage_depth", [edge_i, segment_i, piece, side_i]))
	var rear_width := clampf(frontage_width * lerpf(0.82, 0.96,
			_u("city_rear_frontage_width", [edge_i, segment_i, piece, side_i])), 5.2, 10.0)
	var rear_gap := 3.0 if district == DISTRICT_HISTORIC else 4.0
	var center := road_mid + normal * side * (road_width * 0.5 + 1.35
			+ front_depth + rear_gap + rear_depth * 0.5)
	var footprint := Vector2(rear_width, rear_depth)
	var lot := Rect2(center - footprint * 0.5, footprint)
	if not _lot_inside_polygon(lot, yaw, poly):
		return
	if not _city_lot_has_valid_land(lot, yaw) or _near_rural_settlement(center):
		return
	if not passage.is_empty() and _lots_overlap(lot, yaw,
			passage["rect"] as Rect2, 0.0, 0.25):
		return
	if _distance_to_city_road_raw(center) < 5.0 or not _lot_clear_of_city_roads(lot, yaw):
		return
	for existing: Dictionary in result:
		if _lots_overlap(lot, yaw, existing["rect"] as Rect2,
				float(existing.get("yaw", 0.0)), 0.22):
			return
	if _city_lot_overlaps_existing(lot, yaw):
		return
	var door_edge := _door_edge_for_front(center, normal * side, lot, yaw)
	var token := 2000 + edge_i * 64 + segment_i * 4 + piece * 2 + side_i
	result.append(_make_city_spec(block, lot, door_edge, token,
			result.size(), radius, yaw))


func _lot_clear_of_city_roads(lot: Rect2, yaw := 0.0) -> bool:
	# Most parcels are well away from a road. A conservative centre-distance
	# bound avoids walking every polyline for those lots; only near-road lots use
	# an exact segment-vs-oriented-rectangle test.
	var max_road_half := WorldConstants.CITY_ROAD_WIDTH_PRIMARY * 0.5 + 0.8
	if _distance_to_city_road_raw(lot.get_center()) > lot.size.length() * 0.5 + max_road_half:
		return true
	for edge: Dictionary in _city_edges:
		var half_width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL)) * 0.5 + 0.8
		var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
		for i in range(poly.size() - 1):
			if _segment_intersects_oriented_lot(poly[i], poly[i + 1], lot, yaw, half_width):
				return false
	return true


func _make_city_spec(block: Dictionary, lot: Rect2, door_edge: int,
		edge_i: int, k: int, radius: float, yaw := 0.0) -> Dictionary:
	var cell: Vector2i = block["cell"] as Vector2i
	var edge_tag: String = ["N", "E", "S", "W"][clampi(door_edge, 0, 3)]
	var id := "b_%d_%d_%s%02d" % [cell.x, cell.y, edge_tag, edge_i * 16 + k]
	var district: StringName = block["district"] as StringName
	var rng := _rng("city_parcel", [cell.x, cell.y, edge_i, k])
	var floors := 2
	var floor_h := snappedf(rng.randf_range(2.9, 3.25), 0.05)
	if district == DISTRICT_HISTORIC:
		floors = rng.randi_range(4, 7)
	elif district == DISTRICT_INNER:
		floors = rng.randi_range(2, 5)
	else:
		floors = rng.randi_range(1, 3)
	if floors >= 2 and not BuildingBuilder.has_stairs_for(lot.size, floor_h, floors):
		floors = 1
	var use := "retail" if rng.randf() < (0.38 if radius < 420.0 else 0.18) else "residential"
	var arch: StringName = &"shop_house" if use == "retail" else (&"tenement" if floors >= 4 else &"house")
	var spec := {
		"id": id,
		"rect": lot,
		"yaw": yaw,
		"world_bounds": _oriented_rect_bounds(lot, yaw),
		"floors": floors,
		"floor_h": floor_h,
		"door_edge": door_edge,
		"district": district,
		"plaza_adjacent": block["kind"] == &"plaza",
		"use": use,
		"quality": WorldConstants.BUILDING_QUALITY_FULL_BUILDING,
		"archetype": arch,
		"circulation": {"kind": &"stairs" if floors >= 2 else &"none"},
		"ground_y": 0.0,
		"style": {
			"wall": rng.randi_range(0, WALL_PALETTES - 1),
			"roof": rng.randi_range(0, ROOF_PALETTES - 1),
			"balcony": rng.randf() < 0.50,
			"attic": rng.randf() < 0.65,
			"room_type": use,
		},
		"doors": [],
		"block_id": block["id"],
		"front_edge": edge_i,
	}
	var door := _door_manifest(id, lot, door_edge)
	if not is_zero_approx(yaw):
		var door_pos: Vector3 = door.get("position", Vector3.ZERO) as Vector3
		var rotated_pos := _rotate_plan_point(lot.get_center(),
				Vector2(door_pos.x, door_pos.z), yaw)
		door["position"] = Vector3(rotated_pos.x, door_pos.y, rotated_pos.y)
		door["yaw"] = float(door.get("yaw", 0.0)) - yaw
	spec["doors"] = [door]
	return spec


func _door_edge_for_front(center: Vector2, inward: Vector2, lot: Rect2,
		yaw := 0.0) -> int:
	# Prefer the nearest actual city road. If a block edge is not near a road,
	# use its outward normal so the door still faces the street front.
	var road_p := _nearest_city_road_point_raw(center)
	var outward := -inward
	if road_p != Vector2.INF and center.distance_to(road_p) < 42.0:
		var to_road := (road_p - center).normalized()
		if to_road.length_squared() > 1e-6:
			outward = to_road
	var local_outward := _rotate_plan_vector(outward, -yaw)
	if absf(local_outward.x) >= absf(local_outward.y):
		return 1 if local_outward.x > 0.0 else 3
	return 2 if local_outward.y > 0.0 else 0


func _near_rural_settlement(p: Vector2) -> bool:
	if settlement == null:
		return false
	for anchor: Dictionary in settlement.settlement_anchors():
		var c: Vector2 = anchor.get("center", Vector2.ZERO) as Vector2
		var radius: float = float(anchor.get("radius", 30.0))
		if p.distance_to(c) < radius + 24.0:
			return true
	return false


static func _polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(area) * 0.5


static func _rotate_plan_vector(v: Vector2, yaw: float) -> Vector2:
	var c := cos(yaw)
	var s := sin(yaw)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)


static func _rotate_plan_point(center: Vector2, p: Vector2, yaw: float) -> Vector2:
	return center + _rotate_plan_vector(p - center, yaw)


static func _lot_corners(rect: Rect2, yaw := 0.0,
		extra := 0.0) -> PackedVector2Array:
	var center := rect.get_center()
	var half := rect.size * 0.5 + Vector2(extra, extra)
	var along := _rotate_plan_vector(Vector2(half.x, 0.0), yaw)
	var across := _rotate_plan_vector(Vector2(0.0, half.y), yaw)
	return PackedVector2Array([
		center - along - across,
		center + along - across,
		center + along + across,
		center - along + across,
	])


static func _oriented_rect_bounds(rect: Rect2, yaw := 0.0) -> Rect2:
	var corners := _lot_corners(rect, yaw)
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for p: Vector2 in corners:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


func _lot_inside_polygon(rect: Rect2, yaw: float,
		poly: PackedVector2Array) -> bool:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	for p: Vector2 in _lot_corners(rect, yaw):
		if not _polygon_contains(poly, p):
			return false
	return _polygon_contains(poly, rect.get_center())


static func _lots_overlap(a: Rect2, a_yaw: float, b: Rect2,
		b_yaw: float, margin := 0.0) -> bool:
	var a_corners := _lot_corners(a, a_yaw, margin)
	var b_corners := _lot_corners(b, b_yaw, margin)
	var axes: Array[Vector2] = [
		_rotate_plan_vector(Vector2.RIGHT, a_yaw),
		_rotate_plan_vector(Vector2.DOWN, a_yaw),
		_rotate_plan_vector(Vector2.RIGHT, b_yaw),
		_rotate_plan_vector(Vector2.DOWN, b_yaw),
	]
	for axis: Vector2 in axes:
		var a_min := INF
		var a_max := -INF
		var b_min := INF
		var b_max := -INF
		for p: Vector2 in a_corners:
			var projection := p.dot(axis)
			a_min = minf(a_min, projection)
			a_max = maxf(a_max, projection)
		for p: Vector2 in b_corners:
			var projection := p.dot(axis)
			b_min = minf(b_min, projection)
			b_max = maxf(b_max, projection)
		if a_max <= b_min or b_max <= a_min:
			return false
	return true


func _segment_intersects_oriented_lot(a: Vector2, b: Vector2, lot: Rect2,
		yaw: float, extra: float) -> bool:
	var center := lot.get_center()
	var local_a := _rotate_plan_point(center, a, -yaw) - center
	var local_b := _rotate_plan_point(center, b, -yaw) - center
	var half := lot.size * 0.5 + Vector2(extra, extra)
	return _clip_segment_to_rect(local_a, local_b,
			Rect2(-half, half * 2.0)).size() == 2


func _spec_world_bounds(spec: Dictionary) -> Rect2:
	if spec.has("world_bounds"):
		return spec["world_bounds"] as Rect2
	return _oriented_rect_bounds(spec.get("rect", Rect2()) as Rect2,
			float(spec.get("yaw", 0.0)))


func _rect_inside_polygon(rect: Rect2, poly: PackedVector2Array) -> bool:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	for p in [rect.position, Vector2(rect.end.x, rect.position.y),
			Vector2(rect.position.x, rect.end.y), rect.end, rect.get_center()]:
		if not _polygon_contains(poly, p):
			return false
	return true


func _polygon_contains(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	var n := poly.size()
	if n < 3:
		return false
	var j := n - 1
	for i in n:
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[j]
		var crosses := ((a.y > p.y) != (b.y > p.y))
		if crosses:
			var x_at_y := (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
			if p.x < x_at_y:
				inside = not inside
		j = i
	return inside


static func _polygon_signed_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return area * 0.5


static func _polygon_centroid(poly: PackedVector2Array) -> Vector2:
	var signed := _polygon_signed_area(poly)
	if absf(signed) < 1e-5:
		var avg := Vector2.ZERO
		for p: Vector2 in poly:
			avg += p
		return avg / maxf(float(poly.size()), 1.0)
	var c := Vector2.ZERO
	for i in poly.size():
		var j := (i + 1) % poly.size()
		var cross := poly[i].x * poly[j].y - poly[j].x * poly[i].y
		c += (poly[i] + poly[j]) * cross
	return c / (6.0 * signed)


func _clip_polygon_halfplane(poly: PackedVector2Array, normal: Vector2,
		limit: float) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var out := PackedVector2Array()
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		var da := normal.dot(a) - limit
		var db := normal.dot(b) - limit
		var inside_a := da <= _CITY_EDGE_EPS
		var inside_b := db <= _CITY_EDGE_EPS
		if inside_a:
			out.append(a)
		if inside_a != inside_b:
			var denom := da - db
			if absf(denom) > 1e-9:
				var t := da / denom
				out.append(a.lerp(b, t))
	return out


# -----------------------------------------------------------------------------
# Public city morphology queries

func city_landmarks() -> Array[Dictionary]:
	_ensure_generated()
	return _landmarks.duplicate(true)


func city_landmarks_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for lm: Dictionary in _landmarks:
		if rect.grow(float(lm.get("radius", 0.0))).has_point(lm["center"] as Vector2):
			out.append(lm)
	out.sort_custom(_dict_id_cmp)
	return out


func city_nodes() -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for node: Dictionary in _city_nodes:
		out.append(node.duplicate(true))
	out.sort_custom(_dict_id_cmp)
	return out


func city_blocks() -> Array[Dictionary]:
	_ensure_generated()
	return _blocks.duplicate(true)


func city_buildings() -> Array[Dictionary]:
	_ensure_generated()
	return _all_buildings.duplicate(true)


## Make an isolated read-only worker snapshot. The runtime stream launches
## several workers concurrently, so sharing the live CityPlan object is unsafe
## even though the generated arrays are logically immutable.
func clone_generated() -> CityPlan:
	_ensure_generated()
	var out := CityPlan.new(seed_used)
	out._support_ready = true
	out._generated = true
	out._line_pos_cache = _line_pos_cache.duplicate(true)
	out._cell_cache = _cell_cache.duplicate(true)
	out._building_cache = _building_cache.duplicate(true)
	out._city_nodes = _city_nodes.duplicate(true)
	out._city_edges = _city_edges.duplicate(true)
	out._city_edge_ids = _city_edge_ids.duplicate(true)
	out._landmarks = _landmarks.duplicate(true)
	out._blocks = _blocks.duplicate(true)
	out._all_buildings = _all_buildings.duplicate(true)
	out._city_node_by_id = {}
	for node: Dictionary in out._city_nodes:
		out._city_node_by_id[str(node.get("id", ""))] = node
	out._landmark_by_id = {}
	for landmark: Dictionary in out._landmarks:
		out._landmark_by_id[str(landmark.get("id", ""))] = landmark
	out._block_by_cell = {}
	for block: Dictionary in out._blocks:
		out._block_by_cell[block.get("cell", Vector2i.ZERO) as Vector2i] = block
	out._building_by_id = {}
	for spec: Dictionary in out._all_buildings:
		out._building_by_id[str(spec.get("id", ""))] = spec
	return out


func city_blocks_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for block: Dictionary in _blocks:
		var bounds: Rect2 = block.get("bounds", block["rect"]) as Rect2
		if bounds.intersects(rect):
			out.append(block)
	out.sort_custom(_dict_id_cmp)
	return out


func city_extent() -> Dictionary:
	_ensure_generated()
	var actual_block_radius := 0.0
	var actual_building_radius := 0.0
	var actual_road_radius := 0.0
	for block: Dictionary in _blocks:
		var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
		for p: Vector2 in poly:
			actual_block_radius = maxf(actual_block_radius, p.length())
	for spec: Dictionary in _all_buildings:
		actual_building_radius = maxf(actual_building_radius,
				(spec["rect"] as Rect2).get_center().length())
	for edge: Dictionary in _city_edges:
		for p: Vector2 in edge["polyline"] as PackedVector2Array:
			actual_road_radius = maxf(actual_road_radius, p.length())
	return {
		"dense_radius_m": WorldConstants.CITY_DENSE_RADIUS_M,
		"block_radius_m": WorldConstants.CITY_BLOCK_RADIUS_M,
		"materialization_radius_m": WorldConstants.CITY_MATERIALIZATION_RADIUS_M,
		"influence_radius_m": WorldConstants.CITY_INFLUENCE_RADIUS_M,
		"actual_block_radius_m": actual_block_radius,
		"actual_building_radius_m": actual_building_radius,
		"actual_road_radius_m": actual_road_radius,
	}


func road_graph() -> Dictionary:
	_ensure_generated()
	var nodes: Array[Dictionary] = []
	for node: Dictionary in _city_nodes:
		nodes.append(node.duplicate(true))
	var edges: Array[Dictionary] = []
	for edge: Dictionary in _city_edges:
		edges.append(edge.duplicate(true))
	nodes.sort_custom(_dict_id_cmp)
	edges.sort_custom(_dict_id_cmp)
	return {"nodes": nodes, "edges": edges}


func city_road_graph() -> Dictionary:
	return road_graph()


func city_road_segments_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for edge: Dictionary in _city_edges:
		var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
		var clipped := _clip_polyline_to_rect(poly, rect.grow(float(edge["width"]) * 0.5 + 1.5))
		if clipped.size() < 2:
			continue
		var seg := edge.duplicate(true)
		seg["polyline_clipped"] = clipped
		seg["center"] = (clipped[0] + clipped[clipped.size() - 1]) * 0.5
		out.append(seg)
	out.sort_custom(_dict_id_cmp)
	return out


func city_roads_in(rect: Rect2) -> Array[Dictionary]:
	return city_road_segments_in(rect)


func road_segments_in(rect: Rect2) -> Array[Dictionary]:
	return city_road_segments_in(rect)


func road_hierarchy_at(p: Vector2) -> StringName:
	_ensure_generated()
	var best := INF
	var hierarchy: StringName = &""
	for edge: Dictionary in _city_edges:
		var d := _distance_to_polyline(p, edge["polyline"] as PackedVector2Array)
		if d < best:
			best = d
			hierarchy = edge["hierarchy"] as StringName
	if hierarchy == &"":
		return &""
	var width := _city_road_width(hierarchy)
	return hierarchy if best <= width * 0.65 + 1.2 else &""


func city_road_hierarchy_at(p: Vector2) -> StringName:
	return road_hierarchy_at(p)


func distance_to_city_road(p: Vector2) -> float:
	_ensure_generated()
	return _distance_to_city_road_raw(p)


func _distance_to_city_road_raw(p: Vector2) -> float:
	var best := INF
	for edge: Dictionary in _city_edges:
		best = minf(best, _distance_to_polyline(p, edge["polyline"] as PackedVector2Array))
	return best


func distance_to_road(p: Vector2) -> float:
	return distance_to_city_road(p)


func nearest_city_road_point(p: Vector2) -> Vector2:
	_ensure_generated()
	return _nearest_city_road_point_raw(p)


func _nearest_city_road_point_raw(p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_d2 := INF
	for edge: Dictionary in _city_edges:
		var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 < 1e-8:
				continue
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var q := a + ab * t
			var d2 := p.distance_squared_to(q)
			if d2 < best_d2:
				best_d2 = d2
				best = q
	return best


func sample_road_position(near: Vector2, min_distance: float,
		max_distance: float, rng: RandomNumberGenerator,
		tries := 24) -> Vector2:
	_ensure_generated()
	var rect := Rect2(near - Vector2(max_distance, max_distance),
			Vector2(max_distance, max_distance) * 2.0)
	var segments: Array[Dictionary] = city_road_segments_in(rect)
	if segments.is_empty():
		return Vector2.INF
	for _i in tries:
		var seg: Dictionary = segments[rng.randi_range(0, segments.size() - 1)]
		var poly: PackedVector2Array = seg["polyline_clipped"] as PackedVector2Array
		if poly.size() < 2:
			continue
		var idx := rng.randi_range(0, poly.size() - 2)
		var t := rng.randf()
		var p := poly[idx].lerp(poly[idx + 1], t)
		var d := near.distance_to(p)
		if d >= min_distance and d <= max_distance:
			return p
	var fallback := nearest_city_road_point(near)
	if fallback != Vector2.INF:
		var d_fallback := near.distance_to(fallback)
		if d_fallback >= min_distance and d_fallback <= max_distance:
			return fallback
	return Vector2.INF


func find_spawn_point() -> Vector2:
	_ensure_generated()
	# Choose a genuine historic street beside the market quarter, preferring a
	# locally populated view over an empty road junction. The search set is
	# fixed and deterministic; the selected point is always snapped to this
	# city's generated road graph.
	var candidates: Array[Vector2] = [
		Vector2.ZERO, Vector2(-160.0, -120.0), Vector2(-120.0, -160.0),
		Vector2(120.0, -120.0), Vector2(-160.0, 80.0), Vector2(160.0, 80.0),
		Vector2(190.0, -110.0),
	]
	var best := Vector2.ZERO
	var best_score := -1
	var best_radius := INF
	for candidate: Vector2 in candidates:
		var q := nearest_city_road_point(candidate)
		if q == Vector2.INF or q.length() > 280.0:
			continue
		var score := buildings_in_rect(Rect2(q - Vector2(90.0, 90.0), Vector2(180.0, 180.0))).size()
		var radius := q.length()
		if score > best_score or (score == best_score and radius < best_radius):
			best_score = score
			best_radius = radius
			best = q
	return best


func cells_in_rect(rect: Rect2) -> Array[Vector2i]:
	_ensure_generated()
	var out: Array[Vector2i] = []
	for block: Dictionary in _blocks:
		var bounds: Rect2 = block.get("bounds", block["rect"]) as Rect2
		if bounds.intersects(rect):
			out.append(block["cell"] as Vector2i)
	out.sort_custom(_cell_cmp)
	return out


func cell_block(cell: Vector2i) -> Dictionary:
	_ensure_generated()
	return _block_by_cell.get(cell, {
		"id": "city_block_missing_%d_%d" % [cell.x, cell.y],
		"cell": cell,
		"center": Vector2.ZERO,
		"rect": Rect2(),
		"polygon": PackedVector2Array(),
		"kind": &"park",
		"district": DISTRICT_OUTER,
		"passage": {},
		"buildings": [],
	}) as Dictionary


func buildings_in_rect(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for spec: Dictionary in _all_buildings:
		if _spec_world_bounds(spec).intersects(rect):
			out.append(spec)
	out.sort_custom(_dict_id_cmp)
	return out


func building_by_id(id: String) -> Dictionary:
	_ensure_generated()
	return _building_by_id.get(id, {}) as Dictionary


func validate_area(rect: Rect2) -> Array[String]:
	_ensure_generated()
	var errors: Array[String] = []
	for block: Dictionary in city_blocks_in(rect):
		errors.append_array(validate_buildings(block.get("buildings", []) as Array))
	return errors


static func validate_buildings(buildings: Array) -> Array[String]:
	var errors: Array[String] = []
	for i in buildings.size():
		var a: Rect2 = buildings[i].get("rect", Rect2()) as Rect2
		if a.size.x < 4.0 or a.size.y < 4.0:
			errors.append("invalid tiny building %s" % buildings[i].get("id", ""))
		for j in range(i + 1, buildings.size()):
			var b: Rect2 = buildings[j].get("rect", Rect2()) as Rect2
			if _lots_overlap(a, float(buildings[i].get("yaw", 0.0)), b,
					float(buildings[j].get("yaw", 0.0)), 0.15):
				errors.append("%s overlaps %s" % [buildings[i].get("id", ""),
					buildings[j].get("id", "")])
	return errors


# -----------------------------------------------------------------------------
# Compatibility helpers for older plan/build tests.  These no longer describe
# a global street lattice; they expose safe neutral values or block lookups.

func line_pos(_axis: int, _i: int) -> float:
	# Legacy spawn fallback is intentionally the market junction origin. It is
	# a real city node, not a fabricated Cartesian line, and cannot recurse into
	# find_spawn_point().
	return 0.0


func line_half_width(_axis: int, _i: int) -> float:
	return 0.0


func lines_in_range(axis: int, from_p: float, to_p: float) -> Array[int]:
	_ensure_generated()
	var out: Array[int] = []
	var primary_index := 0
	for edge: Dictionary in _city_edges:
		if edge.get("hierarchy", &"") != &"primary":
			continue
		var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
		var found := false
		for p: Vector2 in poly:
			var value := p.x if axis == 0 else p.y
			if value >= from_p - 8.0 and value <= to_p + 8.0:
				found = true
				break
		if found:
			out.append(primary_index)
		primary_index += 1
	return out


func is_avenue(_axis: int, i: int) -> bool:
	# Compatibility probes use this name to find an arterial-bearing chunk;
	# the actual width/hierarchy comes from the city road edge dictionary.
	return i >= 0


func _cell_lower(v: float) -> int:
	return floori(v / float(DISTRICT_CELL))


func _cell_upper(v: float) -> int:
	return ceili(v / float(DISTRICT_CELL))


static func spec_id(cell: Vector2i, edge: int, k: int) -> String:
	var edge_tag: String = ["N", "E", "S", "W"][clampi(edge, 0, 3)]
	return "b_%d_%d_%s%02d" % [cell.x, cell.y, edge_tag, k]


## Compatibility wrapper for legacy city callers. New city parcels still use
## this exact door grammar before UniversalBuildingAssembler consumes them.
static func _door_manifest(building_id: String, lot: Rect2, edge: int) -> Dictionary:
	var mid := lot.get_center()
	var yaw := 0.0
	match edge:
		0: mid.y = lot.position.y
		1: yaw = PI * 0.5
		2: mid.y = lot.end.y
		_: yaw = PI * 0.5
	match edge:
		1: mid.x = lot.end.x
		3: mid.x = lot.position.x
	var hinge_left := WorldSeed.unit_float("hinge", [WorldSeed.str_hash(building_id)]) < 0.5
	return {
		"id": "%s_door_0" % building_id,
		"building_id": building_id,
		"position": Vector3(mid.x, 0.0, mid.y),
		"yaw": yaw,
		"edge": edge,
		"width": DOOR_W,
		"height": 2.25,
		"hinge": "left" if hinge_left else "right",
		"locked": false,
		"open_angle": 95.0,
		"swing": -1.0 if edge == 0 or edge == 3 else 1.0,
	}


func _rect_for_cell(cell: Vector2i) -> Rect2:
	return cell_block(cell).get("rect", Rect2()) as Rect2


func _kind_for_cell(cell: Vector2i) -> StringName:
	return cell_block(cell).get("kind", &"park") as StringName


func _is_plaza_adjacent(cell: Vector2i) -> bool:
	var block := cell_block(cell)
	var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
	for other: Dictionary in _blocks:
		if other.get("kind", &"") != &"plaza":
			continue
		if center.distance_to(other.get("center", Vector2.ZERO) as Vector2) < 110.0:
			return true
	return false


func _inside_obstacle(p: Vector2) -> bool:
	for spec: Dictionary in buildings_in_rect(Rect2(p - Vector2(1.0, 1.0), Vector2(2.0, 2.0))):
		if (spec["rect"] as Rect2).has_point(p):
			return true
	return false


# -----------------------------------------------------------------------------
# Polyline helpers

static func _distance_to_polyline(p: Vector2, poly: PackedVector2Array) -> float:
	if poly.size() < 2:
		return INF
	var best := INF
	for i in range(poly.size() - 1):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 < 1e-8:
			continue
		var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


static func _clip_polyline_to_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	if poly.size() < 2:
		return PackedVector2Array()
	var result := PackedVector2Array()
	for i in range(poly.size() - 1):
		var clipped := _clip_segment_to_rect(poly[i], poly[i + 1], rect)
		if clipped.size() != 2:
			continue
		if result.is_empty():
			result.append(clipped[0])
			result.append(clipped[1])
		elif result[result.size() - 1].is_equal_approx(clipped[0]):
			result.append(clipped[1])
		else:
			result.append(clipped[0])
			result.append(clipped[1])
	return result


static func _clip_segment_to_rect(p0: Vector2, p1: Vector2,
		rect: Rect2) -> PackedVector2Array:
	var dx := p1.x - p0.x
	var dy := p1.y - p0.y
	var t0 := 0.0
	var t1 := 1.0
	var p_values := [-dx, dx, -dy, dy]
	var q_values := [p0.x - rect.position.x, rect.end.x - p0.x,
			p0.y - rect.position.y, rect.end.y - p0.y]
	for k in 4:
		var pk: float = p_values[k]
		var qk: float = q_values[k]
		if is_equal_approx(pk, 0.0):
			if qk < 0.0:
				return PackedVector2Array()
			continue
		var t := qk / pk
		if pk < 0.0:
			if t > t1:
				return PackedVector2Array()
			if t > t0:
				t0 = t
		else:
			if t < t0:
				return PackedVector2Array()
			if t < t1:
				t1 = t
	if t0 > t1:
		return PackedVector2Array()
	return PackedVector2Array([p0 + Vector2(dx, dy) * t0,
		p0 + Vector2(dx, dy) * t1])
