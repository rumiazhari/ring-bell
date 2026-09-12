class_name CityPlan
extends RefCounted
const HistoricFacades = preload("res://world/generation/historic_facade_plan.gd")
const HistoricStreets = preload("res://world/generation/historic_street_plan.gd")
const UrbanBlocks = preload("res://world/generation/urban_block_plan.gd")
const HistoricParcels = preload("res://world/generation/parcel_plan.gd")
const HistoricRoofs = preload("res://world/generation/roof_plan.gd")
var _historic: Dictionary = {}
var _planar_graph: Dictionary = {}
## Deterministic organic city morphology plan.
##
## Set CityPlan.debug_profiling = true before construction to print one
## interior-fill diagnostic line per generation (probe use only).
static var debug_profiling := false
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
const DOOR_W := WorldConstants.DOOR_W_PERSON    # one authority: DOOR_KIND_W

const _CITY_BOUNDARY_SIDES := 32
const _CITY_SITE_CANDIDATES := 1200
const _CITY_MAX_SITES := 300
const _CITY_EDGE_EPS := 0.001
const _CITY_ROAD_BLOCK_CLEARANCE := 2.4
const _CITY_MIN_SPLIT_BLOCK_AREA := 70.0
# InteriorPlan receives the same raw lot-face openness that the independent
# Prague audit derives from all accepted lots. Keep this spatial probe cheap and
# deterministic: one 0.8 m sample per face, indexed in 8 m cells.
const _INTERIOR_FACE_PROBE_M := 0.8
const _INTERIOR_FACE_GRID_M := 8.0
const _INTERIOR_FACE_GROW_M := 1.0

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
var _city_edge_bounds: Array[Rect2] = []   # cached per-edge AABBs
var _generating := false   # re-entrancy guard for the instrumented wrapper
var _prof_interior_tries := 0
var _prof_interior_no_fit := 0
var _prof_interior_land := 0
var _prof_interior_passage := 0
var _prof_interior_road := 0
var _prof_interior_overlap := 0
var _prof_interior_placed := 0
var _city_nodes: Array[Dictionary] = []
var _city_node_by_id: Dictionary = {}
var _city_edges: Array[Dictionary] = []
var _city_edge_ids: Dictionary = {}
var _landmarks: Array[Dictionary] = []
var _landmark_by_id: Dictionary = {}
var _blocks: Array[Dictionary] = []
var _street_garden_cache: Array[Dictionary] = []
var _street_gardens_cached := false
var _block_by_cell: Dictionary = {}
var _all_buildings: Array[Dictionary] = []
var _placement_bins: Dictionary = {}
var _placement_indexed_count := 0
var _building_by_id: Dictionary = {}
var _building_query_bins: Dictionary = {}
var _building_query_count := -1
var _road_query_bins: Dictionary = {}
var _road_query_edge_count := -1


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
	# PERF INSTRUMENT (2026-09-10): full-city generation measured ~85 s for one
	# call. Chunk streaming calls this lazily, so a single slow generation stalls
	# the ring past its 60 s regeneration wait ("owner chunk never returned").
	# Report every generation so the number of times it happens is visible.
	var _gen_t0 := Time.get_ticks_usec()
	if _generated or _generating:
		return
	_generating = true
	_ensure_generated_body()
	_generating = false
	var _gen_ms := float(Time.get_ticks_usec() - _gen_t0) / 1000.0
	if _gen_ms >= 500.0:
		print("[CityPlan] GENERATED in %.0f ms (seed %d)" % [_gen_ms, seed_used])


func _ensure_generated_body() -> void:
	var _p0 := Time.get_ticks_usec()
	_ensure_support_plans()
	var _p1 := Time.get_ticks_usec()
	_generate_landmarks()
	var _p2 := Time.get_ticks_usec()
	_generate_city_roads()
	_historic = HistoricStreets.generate(seed_used, _city_edges, _landmarks)
	_city_edges = _historic.edges
	_city_edge_bounds.clear()
	_road_query_bins.clear()
	_road_query_edge_count = -1
	var _p3 := Time.get_ticks_usec()
	_generate_city_blocks()
	var _p4 := Time.get_ticks_usec()
	_generated = true
	if float(_p4 - _p0) / 1000.0 >= 500.0:
		print("[CityPlan]   phases support=%.0f landmarks=%.0f roads=%.0f blocks=%.0f ms" % [
			float(_p1 - _p0) / 1000.0, float(_p2 - _p1) / 1000.0,
			float(_p3 - _p2) / 1000.0, float(_p4 - _p3) / 1000.0])


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
	_road_query_bins.clear()
	_road_query_edge_count = -1
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

	# P2B-DENSE splitter alleys: cut narrow Prague lanes through roadless
	# macro faces before connectivity and road-split, so every dense face
	# gains real street frontage instead of houses facing nothing.
	_add_dense_face_splitters()

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
## mark unserved ground; cluster centroids join streets on opposing sides.
## Capped, deterministic, admission-checked like all
## routes (recovery backstops rejections).
func _add_void_infill() -> void:
	var pts: Array[Vector2] = []
	var gx := -560.0
	while gx <= 560.0:
		var gz := -560.0
		while gz <= 560.0:
			var p := Vector2(gx, gz)
			if p.length() < 560.0 and _is_valid_city_land(p) \
					and not _city_road_within_raw(p, 55.0, true):
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
			var hierarchy: StringName = &"alley" if snapped.length() < WorldConstants.CITY_HISTORIC_RADIUS_M else &"local"
			var opposite_id := _nearest_splitter_anchor(snapped, id, best_id)
			_add_route_between(best_id, id, hierarchy,
				"city_infill_%s" % id)
			if opposite_id != "":
				_add_route_between(id, opposite_id, hierarchy,
					"city_infill_%s_out" % id)


## P2B-DENSE splitter alleys. Macro Voronoi cells that no street crosses become
## huge roadless faces no parcel can front (probe: valid land, near_road≈0).
## This cuts a narrow Prague alley through each such face BEFORE connectivity
## and road-split, so both halves gain street frontage. Detection mirrors the
## site/Voronoi acceptance in _generate_city_blocks read-only (no _blocks
## mutation, deterministic _u domains only); minor drift vs the real cells
## is harmless (an extra lane still fronts lots). Capped and deterministic.
func _add_dense_face_splitters() -> void:
	var faces := _roadless_macro_faces()
	faces.sort_custom(_dict_id_cmp)
	var added := 0
	for face in faces:
		if added >= 24:
			break
		var center: Vector2 = face.get("center", Vector2.ZERO) as Vector2
		var snapped := _nearest_valid_city_point(center, 5)
		if snapped == Vector2.INF:
			continue
		var sid := "splitter_%s" % str(face.get("id", "xx"))
		_add_city_node(sid, snapped, &"splitter_pocket")
		var first := _nearest_splitter_anchor(snapped, sid)
		if first == "":
			continue
		_add_route_between(sid, first, &"alley", "city_splitter_%s_a" % sid)
		var second := _nearest_splitter_anchor(snapped, sid, first)
		if second != "":
			_add_route_between(sid, second, &"alley", "city_splitter_%s_b" % sid)
		added += 1


func _nearest_splitter_anchor(p: Vector2, self_id: String, exclude := "") -> String:
	var best := ""
	var best_d := INF
	for n in _city_nodes:
		var nid := String(n["id"])
		if nid == self_id or nid == exclude or nid == "market_square":
			continue
		# The second arm must cross the face rather than double back toward
		# a second nearby node on the same street. Stable distance/ID ordering
		# below still chooses the shortest eligible connection.
		if exclude != "":
			var first_direction := (_node_position(exclude) - p).normalized()
			var candidate_direction := (_node_position(nid) - p).normalized()
			if first_direction.dot(candidate_direction) > -0.25:
				continue
		var d := p.distance_to(_node_position(nid))
		if d < best_d or (is_equal_approx(d, best_d) and nid < best):
			best_d = d
			best = nid
	return best


## Read-only mirror of the macro site/Voronoi acceptance for splitter
## detection. Returns faces ≥6000 m² inside the dense band whose heart is
## ≥25 m from every road ribbon. Never mutates plan state.
func _roadless_macro_faces() -> Array[Dictionary]:
	var sites: Array[Vector2] = []
	for id in ["market_square", "civic_square", "rail_station", "castle_hill"]:
		if not _city_node_by_id.has(id):
			continue
		var p: Vector2 = _node_position(id)
		if _is_valid_city_land(p):
			sites.append(p)
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
		if _city_road_within_raw(p, 11.0):
			continue
		var normalized_r := clampf(radius / WorldConstants.CITY_BLOCK_RADIUS_M, 0.0, 1.0)
		var min_spacing := lerpf(40.0, 88.0, normalized_r)
		var too_close := false
		for existing: Vector2 in sites:
			if p.distance_to(existing) < min_spacing:
				too_close = true
				break
		if too_close:
			continue
		sites.append(p)
	var site_records: Array[Dictionary] = []
	for i in sites.size():
		site_records.append({"index": i, "p": sites[i]})
	site_records.sort_custom(_site_record_cmp)
	var ordered_sites: Array[Vector2] = []
	for rec: Dictionary in site_records:
		ordered_sites.append(rec["p"] as Vector2)
	var out: Array[Dictionary] = []
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
		if site.length() >= 600.0:
			continue
		var district: StringName = DISTRICT_HISTORIC
		if site.length() >= WorldConstants.CITY_HISTORIC_RADIUS_M:
			district = DISTRICT_INNER if site.length() < WorldConstants.CITY_DENSE_RADIUS_M else DISTRICT_OUTER
		if district == DISTRICT_OUTER:
			continue
		if absf(_polygon_area(poly)) < 6000.0:
			continue
		var center := _polygon_centroid(poly)
		if _city_road_within_raw(center, 25.0):
			continue
		out.append({"id": "city_block_%04d" % i, "center": center})
	return out


## Share of face-grid samples inside the polygon that are valid city land.
## Faces below ~40% valid are hillsides/water margins: Prague parks, not
## parcels. Pure geometry + land queries; no plan mutation.
func _valid_land_fraction(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 1.0
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for p: Vector2 in poly:
		min_x = minf(min_x, p.x)
		min_z = minf(min_z, p.y)
		max_x = maxf(max_x, p.x)
		max_z = maxf(max_z, p.y)
	var origin := Vector2(min_x, min_z)
	var size := Vector2(max_x - min_x, max_z - min_z)
	var inside := 0
	var valid := 0
	for gx in range(5):
		for gz in range(5):
			var p := origin + Vector2(size.x * float(gx) / 4.0,
					size.y * float(gz) / 4.0)
			if not _polygon_contains(poly, p):
				continue
			inside += 1
			if _is_valid_city_land(p):
				valid += 1
	if inside == 0:
		return 1.0
	return float(valid) / float(inside)


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
	var _b_sites := Time.get_ticks_usec()
	_blocks.clear()
	_block_by_cell.clear()
	_all_buildings.clear()
	_placement_bins.clear()
	_placement_indexed_count = 0
	_building_by_id.clear()
	_building_query_bins.clear()
	_building_query_count = -1
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
		if _city_road_within_raw(p, 11.0):
			continue
		var normalized_r := clampf(radius / WorldConstants.CITY_BLOCK_RADIUS_M, 0.0, 1.0)
		var min_spacing := lerpf(40.0, 88.0, normalized_r)
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
	var _b0 := Time.get_ticks_usec()
	_blocks = _split_city_blocks_by_roads(_blocks)
	_replace_historic_blocks()
	var _b1 := Time.get_ticks_usec()

	_blocks.sort_custom(_dict_id_cmp)
	_block_by_cell.clear()
	var seen_cells: Dictionary = {}
	for block: Dictionary in _blocks:
		var cell: Vector2i = block["cell"] as Vector2i
		assert(not seen_cells.has(cell),
				"duplicate city block cell key: " + str(cell))
		seen_cells[cell] = true
		_block_by_cell[cell] = block
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
	var _b2 := Time.get_ticks_usec()
	_fill_block_interiors()
	var _b3 := Time.get_ticks_usec()
	_guarantee_dense_block_minimum()
	var _b4 := Time.get_ticks_usec()
	_all_buildings.sort_custom(_dict_id_cmp)
	_finalize_block_fabric()
	# The complete lot set is available only after every deterministic frontage
	# pass. Publish adjacency before any consumer builds an interior again.
	_attach_historic_open_faces()
	var _b5 := Time.get_ticks_usec()
	if float(_b5 - _b0) / 1000.0 >= 400.0:
		print("[CityPlan]     BLOCKS sites_loop=%.0f split=%.0f frontage=%.0f interiors=%.0f dense_min=%.0f finalize=%.0f ms" % [
			float(_b0 - _b_sites) / 1000.0, float(_b1 - _b0) / 1000.0, float(_b2 - _b1) / 1000.0,
			float(_b3 - _b2) / 1000.0, float(_b4 - _b3) / 1000.0, float(_b5 - _b4) / 1000.0])


## G10-P2B-FIX2: finalize the parcel surface contract after every frontage
## candidate has been considered. A built block owns only its road-side lots
## plus residual courtyard/garden regions; a dense empty face is explicitly a
## park rather than a falsely paved block. No scene mutation or RNG occurs here.
func _replace_historic_blocks() -> void:
	var boundary: PackedVector2Array = _historic.boundary
	var exterior: Array[Dictionary] = []
	for block: Dictionary in _blocks:
		var polygon: PackedVector2Array = block.polygon
		if not _polygon_bounds(polygon).intersects(_polygon_bounds(boundary)):
			exterior.append(block)
			continue
		var pieces := Geometry2D.clip_polygons(polygon, boundary)
		var piece_i := 0
		for piece: PackedVector2Array in pieces:
			if Geometry2D.is_polygon_clockwise(piece) or _polygon_area(piece) < 70.0:
				continue
			var copy := block.duplicate(true)
			copy.polygon = piece
			copy.bounds = _polygon_bounds(piece)
			copy.rect = _safe_block_rect(piece, copy.bounds)
			copy.site = (copy.rect as Rect2).get_center()
			copy.center = copy.site
			copy.id = str(block.id) + "_outer%d" % piece_i
			copy.cell = Vector2i(100000 + exterior.size(), -100000 - exterior.size())
			copy.passage = {}
			exterior.append(copy)
			piece_i += 1
	var graph := UrbanBlocks.build(_city_edges)
	var index := 0
	for face: Dictionary in graph.faces:
		var polygon: PackedVector2Array = face.polygon
		var center := _polygon_centroid(polygon)
		if not Geometry2D.is_point_in_polygon(center, boundary):
			continue
		var source := {"polygon": polygon, "bounds": _polygon_bounds(polygon)}
		for raw_piece: PackedVector2Array in _road_subtracted_pieces(source):
			# Clipping leaves duplicate/collinear vertices: clean the ring before it
			# becomes a block, or every perimeter walk sees hairline edges.
			var piece := UrbanBlocks.clean_polygon(raw_piece)
			if piece.size() < 3 or _polygon_area(piece) < 110.0:
				continue
			var block := _make_block(200000 + index, _polygon_centroid(piece), piece)
			block.id = "historic_block_%d" % index
			block.cell = Vector2i(200000 + index, 200000 + index)
			block.district = DISTRICT_HISTORIC
			block.kind = &"built"
			block.historic_compound = true
			block.road_derived = true
			block.passage = {}
			for space: Dictionary in _historic.public_spaces:
				if Geometry2D.is_point_in_polygon(space.center, polygon):
					block.kind = &"plaza"
					block.public_space = space
					break
			exterior.append(block)
			index += 1
	_blocks = exterior

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
		block["residual_area_m2"] = maxf(block_area - occupied, 0.0)
		block["unresolved_void_area_m2"] = 0.0
		block["enclosure_sides"] = 0
		block["courtyard_access"] = false
		if buildings.is_empty():
			# A valid empty built face is not a courtyard: it has no enclosing
			# fabric. Invalid terrain stays open only as a designed park so no
			# dense face reads as an unexplained empty lot.
			var invalid := not _is_valid_city_land(center)
			if invalid:
				block["kind"] = &"park"
				block["void_reason"] = &"invalid_terrain_open_face"
			else:
				block["void_reason"] = &"unbuilt_valid_face"
			_block_by_cell[block["cell"]] = block
			continue
		# A mostly-unbuildable face with only a few houses is a hillside or
		# water margin, not a city block: villa-in-park reads honestly (its
		# buildings keep ids, frontage, and rendering; only the ground goes
		# green) while the void metrics stop blaming rock and river.
		if block_area > 6000.0 and center.length() < 600.0 \
				and buildings.size() < 6 \
				and _valid_land_fraction(block.get("polygon",
					PackedVector2Array()) as PackedVector2Array) < 0.4:
			block["kind"] = &"park"
			block["void_reason"] = &"invalid_majority_designed_park"
			_block_by_cell[block["cell"]] = block
			continue
		var regions: Array[Dictionary] = _courtyard_regions_for_block(block)
		block["courtyard_regions"] = regions
		for region: Dictionary in regions:
			block["courtyard_area_m2"] += float(region.get("area_m2", 0.0))
			block["enclosure_sides"] = maxi(int(block["enclosure_sides"]), int(region.get("enclosure_sides", 0)))
			block["courtyard_access"] = bool(block["courtyard_access"]) or bool(region.get("access", false))
		var residual := float(block["residual_area_m2"])
		if residual > 0.0 and block["courtyard_area_m2"] < residual * 0.70:
			block["unresolved_void_area_m2"] = residual - block["courtyard_area_m2"]
			block["void_reason"] = &"underfilled_repack_required"
		else:
			block["void_reason"] = &"bounded_enclosed_courtyard" if not regions.is_empty() else &"bounded_backyard"
		_block_by_cell[block["cell"]] = block
## Publish lot-face openness to historic BuildingSpecs after the complete lot set
## exists. This is the generation-side counterpart of the independent audit's
## 0.8 m far-side probe; the raw edge order remains N, E, S, W.
func _attach_historic_open_faces() -> void:
	var boxes: Array[Rect2] = []
	var polygons: Array[PackedVector2Array] = []
	var grid: Dictionary = {}
	for spec_variant in _all_buildings:
		var spec: Dictionary = spec_variant as Dictionary
		var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
		var poly: PackedVector2Array = _lot_corners(rect, float(spec.get("yaw", 0.0)))
		var box: Rect2 = _polygon_bounds(poly)
		var index := polygons.size()
		polygons.append(poly)
		boxes.append(box)
		var expanded := box.grow(_INTERIOR_FACE_GROW_M)
		var x0 := int(floor(expanded.position.x / _INTERIOR_FACE_GRID_M))
		var x1 := int(floor(expanded.end.x / _INTERIOR_FACE_GRID_M))
		var y0 := int(floor(expanded.position.y / _INTERIOR_FACE_GRID_M))
		var y1 := int(floor(expanded.end.y / _INTERIOR_FACE_GRID_M))
		for cx in range(x0, x1 + 1):
			for cy in range(y0, y1 + 1):
				var key := Vector2i(cx, cy)
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(index)
	for spec_i in _all_buildings.size():
		var spec: Dictionary = _all_buildings[spec_i]
		if not spec.has("compound_id"):
			continue
		var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
		var corners: PackedVector2Array = polygons[spec_i]
		var center := rect.get_center()
		var open_faces: Array[bool] = [true, true, true, true]
		for edge_i in 4:
			var mid := (corners[edge_i] + corners[(edge_i + 1) % 4]) * 0.5
			var outward := mid - center
			if outward.length_squared() < 1e-6:
				continue
			var probe := mid + outward.normalized() * _INTERIOR_FACE_PROBE_M
			var key := Vector2i(int(floor(probe.x / _INTERIOR_FACE_GRID_M)),
				int(floor(probe.y / _INTERIOR_FACE_GRID_M)))
			for other_i: int in grid.get(key, []) as Array:
				if boxes[other_i].has_point(probe) and Geometry2D.is_point_in_polygon(probe, polygons[other_i]):
					open_faces[edge_i] = false
					break
		spec["open_faces"] = open_faces
		# Facade openings are another consumer of room kinds; rebuild them after
		# adjacency has reclassified any windowless cells as service.
		spec["facade_plan"] = HistoricFacades.for_wing(spec)


## Derive one shared rear-court/garden surface from the owning block face.
## Tiny residual fragments are rejected so they cannot become detached-looking
## procedural shards.
## Ground the lot fitter could not build on, published as planted gardens. This
## runs before the enclosed-courtyard rules, and deliberately so: a wedge between
## two houses has no passage and encloses nothing, so it would be dropped on its
## way to the courtyard test even though it is exactly the blank the city must
## not have.
func _street_gardens_for_block(block: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var buildings: Array = block.get("buildings", []) as Array
	for garden_variant in block.get("frontage_gardens", []) as Array:
		var garden: PackedVector2Array = garden_variant as PackedVector2Array
		if garden.size() < 3:
			continue
		var garden_area := absf(_polygon_area(garden))
		if garden_area < 3.0:
			continue
		var garden_center := _polygon_centroid(garden)
		out.append({
			"kind": &"garden",
			"polygon": garden,
			"area_m2": garden_area,
			"center": garden_center,
			"enclosed": false,
			"access": true,
			"access_kind": &"street_garden",
			"enclosure_sides": _courtyard_enclosure_sides(garden_center, buildings),
		})
	return out


func _courtyard_regions_for_block(block: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = _street_gardens_for_block(block)
	out.append_array(_courtyard_regions_inner(block))
	return out


func _courtyard_regions_inner(block: Dictionary) -> Array[Dictionary]:
	var source: PackedVector2Array = block.get("polygon",
		PackedVector2Array()) as PackedVector2Array
	var source_area := absf(_polygon_area(source))
	var buildings: Array = block.get("buildings", []) as Array
	if source.size() < 3 or source_area < WorldConstants.CITY_COURTYARD_MIN_AREA_M2 \
			or buildings.size() < 3:
		return []
	var occupied := 0.0
	# A courtyard lies behind its enclosing frontage buildings. Starting
	# subtraction at the block boundary also includes every exterior setback;
	# fully inset lots become polygon holes and the unchanged outer contour
	# was then mistaken for an oversized courtyard. Bound the rear space by
	# the enclosing building centres before subtracting their actual footprints.
	var centres := PackedVector2Array()
	for spec: Dictionary in buildings:
		centres.append((spec["rect"] as Rect2).get_center())
	var enclosure := Geometry2D.convex_hull(centres)
	if enclosure.size() < 4:
		return []
	var residuals: Array[PackedVector2Array] = Geometry2D.intersect_polygons(source, enclosure)
	for spec_variant in buildings:
		var spec: Dictionary = spec_variant as Dictionary
		var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
		var yaw := float(spec.get("yaw", 0.0))
		occupied += lot.size.x * lot.size.y
		var next: Array[PackedVector2Array] = []
		for subject: PackedVector2Array in residuals:
			for clipped_variant in Geometry2D.clip_polygons(subject, _lot_corners(lot, yaw)):
				var component: PackedVector2Array = clipped_variant as PackedVector2Array
				if component.size() >= 3 and _polygon_area(component) >= WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
					next.append(component)
		residuals = next
		if residuals.is_empty():
			break
	var max_courtyard := minf(WorldConstants.CITY_COURTYARD_MAX_SURFACE_AREA_M2, occupied * 0.85)
	if max_courtyard < WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
		return []
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	if passage.is_empty() or not bool(passage.get("road_connected", false)):
		return []
	var access_poly: PackedVector2Array = passage.get("polygon",
			PackedVector2Array()) as PackedVector2Array
	if access_poly.size() < 3:
		return []
	var out: Array[Dictionary] = []
	for component in residuals:
		var area := absf(_polygon_area(component))
		if area < WorldConstants.CITY_COURTYARD_MIN_AREA_M2 or area > max_courtyard:
			continue
		if Geometry2D.intersect_polygons(component, access_poly).is_empty():
			continue
		var center := _polygon_centroid(component)
		var enclosure_sides := _courtyard_enclosure_sides(center, buildings)
		if enclosure_sides < 3:
			continue
		# Clipping may return hole contours. A renderable courtyard polygon
		# must itself be empty ground, never a contour covering another house.
		var clear := true
		for spec: Dictionary in buildings:
			for overlap in Geometry2D.intersect_polygons(component,
				_lot_corners(spec["rect"], float(spec.get("yaw", 0.0)))):
				if _polygon_area(overlap) > 0.01:
					clear = false
		if not clear:
			continue
		out.append({
			"kind": &"courtyard" if buildings.size() >= 4 else &"garden",
			"polygon": component,
			"area_m2": area,
			"center": center,
			"enclosed": true,
			"access": true,
			"access_kind": passage.get("kind", &"historic_alley"),
			"enclosure_sides": enclosure_sides,
		})
	out.sort_custom(_surface_region_cmp)
	if out.size() > WorldConstants.CITY_COURTYARD_MAX_REGIONS_PER_BLOCK:
		out.resize(WorldConstants.CITY_COURTYARD_MAX_REGIONS_PER_BLOCK)
	# Whatever the lot fitter could not turn into a house does not have to read as
	# bare city. Ground that still touches the block boundary is published as a
	# garden surface, which is the second half of the anti-blank rule: every gap
	# becomes a building, a party wall, or an intentional garden.
	# Ground the lot fitter could not build on still owes the player something: the
	# strips left along the street line are published as planted gardens (see
	# _street_gardens_for_block), and the ground left inside the block as residual
	# courts, so no part of the core reads as bare void.
	out.append_array(_street_garden_regions(source, buildings))
	return out


## Leftover ground of a block that still reaches its own boundary, published as a
## garden. The rear-court pass above only keeps enclosed courts reached by a
## passage, so a gap in the street wall with nothing behind it stayed bare. A
## garden is the honest use for ground too shallow or too wedged for a house, and
## the chunk renderer already draws a `garden` region as planted ground.
func _street_garden_regions(source: PackedVector2Array, buildings: Array) -> Array[Dictionary]:
	var free: Array[PackedVector2Array] = [source]
	for spec_variant in buildings:
		var spec: Dictionary = spec_variant as Dictionary
		var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
		var yaw := float(spec.get("yaw", 0.0))
		var next: Array[PackedVector2Array] = []
		for subject: PackedVector2Array in free:
			for clipped_variant in Geometry2D.clip_polygons(subject, _lot_corners(lot, yaw)):
				var component: PackedVector2Array = clipped_variant as PackedVector2Array
				if component.size() >= 3:
					next.append(component)
		free = next
		if free.is_empty():
			return []
	var min_area := WorldConstants.CITY_COURTYARD_MIN_AREA_M2 * 0.36
	var out: Array[Dictionary] = []
	for component: PackedVector2Array in free:
		var area := absf(_polygon_area(component))
		if area < min_area:
			continue
		if not _polygon_touches_boundary(component, source):
			continue
		var center := _polygon_centroid(component)
		var enclosure := _courtyard_enclosure_sides(center, buildings)
		# A court, not open country: the residual must be bounded by houses on
		# three sides and remain pocket-sized, otherwise this is not a courtyard
		# but simply land the fabric never reached.
		if enclosure < 3 or area > 600.0:
			continue
		out.append({
			"kind": &"garden",
			"polygon": component,
			"area_m2": area,
			"center": center,
			"enclosed": enclosure >= 2,
			"access": true,
			"access_kind": &"block_residual",
			"enclosure_sides": enclosure,
		})
	out.sort_custom(_surface_region_cmp)
	return out


## Every courtyard/garden region a rect touches, of ALL access kinds.
##
## `garden_regions_in_rect()` below returns only the `street_garden` subset, so
## a caller that wants the real yards behind the street wall (the site envelope
## layer, G10-P2C) has to ask here — a plot's yard is usually a plain courtyard,
## not a street garden.
func courtyard_regions_in_rect(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for block: Dictionary in _blocks:
		for region_variant in block.get("courtyard_regions", []) as Array:
			var region: Dictionary = region_variant as Dictionary
			var poly: PackedVector2Array = region.get("polygon", PackedVector2Array()) as PackedVector2Array
			if poly.size() < 3:
				continue
			var box := Rect2(poly[0], Vector2.ZERO)
			for corner: Vector2 in poly:
				box = box.expand(corner)
			if not rect.intersects(box):
				continue
			out.append(region)
	return out


## Street-garden regions intersecting `rect`, for the chunk renderer's planting
## pass. These are the strips the lot fitter could not build on; the renderer
## plants them so a gap in the street wall reads as a garden, not as bare city.
func garden_regions_in_rect(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _street_gardens_cached:
		_street_gardens_cached = true
		for block: Dictionary in _blocks:
			for region_variant in block.get("courtyard_regions", []) as Array:
				var region: Dictionary = region_variant as Dictionary
				if StringName(region.get("access_kind", &"")) == &"street_garden":
					_street_garden_cache.append(region)
	for region: Dictionary in _street_garden_cache:
		var poly: PackedVector2Array = region.get("polygon", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 3:
			continue
		var box := Rect2(poly[0], Vector2.ZERO)
		for corner: Vector2 in poly:
			box = box.expand(corner)
		if not rect.intersects(box):
			continue
		out.append(region)
	return out


## True when any vertex of `component` lies on the block boundary, which is what
## makes the leftover visible from the public realm instead of a sealed pocket.
func _polygon_touches_boundary(component: PackedVector2Array, source: PackedVector2Array) -> bool:
	for vertex: Vector2 in component:
		for i in source.size():
			if _point_segment_distance(vertex, source[i],
					source[(i + 1) % source.size()]) <= 1.5:
				return true
	return false


func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq <= 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _courtyard_enclosure_sides(center: Vector2, buildings: Array) -> int:
	var sides := 0
	for direction: Vector2 in [Vector2(0.0, -1.0), Vector2.RIGHT,
			Vector2(0.0, 1.0), Vector2.LEFT]:
		var found := false
		for step in range(2, 38, 2):
			var probe := center + direction * float(step)
			for spec_variant in buildings:
				var spec: Dictionary = spec_variant as Dictionary
				if _polygon_contains(_lot_corners(spec.get("rect", Rect2()) as Rect2,
						float(spec.get("yaw", 0.0))), probe):
					found = true
					break
			if found:
				break
		if found:
			sides += 1
	return sides


static func _rect_polygon(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)])


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


## P2B-DENSE civic designation. Faces ≥12000 m² inside the dense band that no
## parcel fabric can fill become squares (historic: fountain/market) or green
## lungs (inner: grass/trees) via chunk_builder — never blank lots. Applied to
## road-split pieces and unsplit macro faces alike; pure query, no mutation.
func _civic_kind_for(center: Vector2, poly: PackedVector2Array) -> StringName:
	# Size alone is never a civic purpose. The old >6000 m² rule turned
	# ordinary developable faces into enormous parks and plazas.
	for landmark: Dictionary in _landmarks:
		if landmark.get("kind", &"") not in [&"market_square", &"civic_square", &"station"]:
			continue
		var radius := float(landmark.get("radius", 30.0))
		if center.distance_to(landmark["center"]) <= radius \
				and _polygon_area(poly) <= PI * radius * radius * 2.0:
			return &"plaza"
	return &""


func _split_city_blocks_by_roads(source_blocks: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for source_index in source_blocks.size():
		var source: Dictionary = source_blocks[source_index]
		var source_kind: StringName = source.get("kind", &"built") as StringName
		var source_site: Vector2 = source.get("site", Vector2.ZERO) as Vector2
		# Parks/plazas and the looser outer ring remain macro cells. Built
		# historic/inner cells are split only by actual generated road ribbons.
		if source_kind != &"built" or source_site.length() >= WorldConstants.CITY_DENSE_RADIUS_M:
			out.append(source)
			continue
		var pieces := _road_subtracted_pieces(source)
		var source_area := absf(_polygon_area(source.get("polygon",
			PackedVector2Array()) as PackedVector2Array))
		if pieces.is_empty():
			# The actual road ribbons consumed this face. Do not restore the
			# original macro polygon as a false built block.
			continue
		if pieces.size() == 1 and absf(_polygon_area(pieces[0]) - source_area) <= 0.5:
			var civic := _civic_kind_for(source.get("center", Vector2.ZERO) as Vector2, pieces[0])
			if civic != &"":
				source["kind"] = civic
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
		# If every resulting component is below the contract minimum, the
		# crossed face is intentionally left open rather than resurrecting a
		# giant source polygon that the roads already partitioned.
	return out


func _road_subtracted_pieces(source: Dictionary) -> Array[PackedVector2Array]:
	var original: PackedVector2Array = source.get("polygon", PackedVector2Array()) as PackedVector2Array
	var pieces: Array[PackedVector2Array] = [original]
	var bounds: Rect2 = source.get("bounds", source.get("rect", Rect2())) as Rect2
	for edge: Dictionary in _city_edges:
		var width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		var clearance := 0.25 if bool(edge.get("shared_surface", false)) else _CITY_ROAD_BLOCK_CLEARANCE
		var road_poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if not _polyline_bounds(road_poly).intersects(bounds.grow(width * 0.5 + clearance)):
			continue
		for segment_i in range(road_poly.size() - 1):
			var a: Vector2 = road_poly[segment_i]
			var b: Vector2 = road_poly[segment_i + 1]
			if a.distance_to(b) < 2.0:
				continue
			if not bounds.grow(width * 0.5 + clearance).intersects(
					Rect2(a, Vector2.ZERO).expand(b)):
				continue
			var strip := _road_strip_polygon(a, b,
					width * 0.5 + clearance)
			var next: Array[PackedVector2Array] = []
			for subject: PackedVector2Array in pieces:
				var clipped: Array = _subtract_road_ribbon(subject, strip)
				for variant in clipped:
					var result: PackedVector2Array = variant as PackedVector2Array
					# Preserve components until every road ribbon has been
					# subtracted. Filtering by the final block minimum here can
					# discard all large-face survivors mid-pass and trigger the
					# source-face fallback above. Tiny numerical slivers are the
					# only components discarded early.
					if result.size() >= 3 and _polygon_area(result) >= 4.0:
						next.append(result)
			pieces = next
			if pieces.is_empty():
				return pieces
	return pieces


static func _subtract_road_ribbon(subject: PackedVector2Array, ribbon: PackedVector2Array) -> Array[PackedVector2Array]:
	var clipped := Geometry2D.clip_polygons(subject, ribbon)
	if clipped.size() < 2:
		return clipped
	var first_winding := Geometry2D.is_polygon_clockwise(clipped[0])
	var has_hole := false
	for piece in clipped:
		if Geometry2D.is_polygon_clockwise(piece) != first_winding:
			has_hole = true
	if not has_hole:
		return clipped
	# clip_polygons returns hole contours as separate, oppositely wound
	# paths. They are not buildable blocks. Split the subject through the
	# ribbon first, so each subtraction opens onto a boundary and produces
	# ordinary hole-free faces. This preserves area instead of filling holes
	# or resurrecting an uncut source block around an interior street segment.
	var center := (ribbon[0] + ribbon[2]) * 0.5
	var axis := (ribbon[1] - ribbon[0]).normalized()
	var normal := Vector2(-axis.y, axis.x)
	var bounds := _bounds_of_polygon(subject)
	var reach := (bounds.size.length() + bounds.get_center().distance_to(center) + 10.0) * 2.0
	var out: Array[PackedVector2Array] = []
	for side in [-1.0, 1.0]:
		var far: Vector2 = normal * reach * float(side)
		var half := PackedVector2Array([center - axis * reach, center + axis * reach,
			center + axis * reach + far, center - axis * reach + far])
		for part in Geometry2D.intersect_polygons(subject, half):
			for remainder in Geometry2D.clip_polygons(part, ribbon):
				if _polygon_area(remainder) > 0.001:
					out.append(remainder)
	return out


func _make_split_block(source: Dictionary, source_index: int,
		piece_index: int, poly: PackedVector2Array) -> Dictionary:
	if poly.size() < 3:
		return {}
	var bounds := _polygon_bounds(poly)
	var rect := _safe_block_rect(poly, bounds)
	var center := rect.get_center()
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
	# Ordinary source cells use (index, -index-1). Reserve the opposite
	# sign quadrant for road-derived children so a split key cannot overwrite
	# a source cell or another source lookup during deterministic indexing.
	block["cell"] = Vector2i(-source_index - 1, piece_index)
	block["site"] = center
	block["center"] = center
	block["rect"] = rect
	block["bounds"] = bounds
	block["polygon"] = poly
	block["district"] = district
	block["road_derived"] = true
	block["passage"] = {}
	block["buildings"] = []
	if block.get("kind", &"built") == &"built" and absf(_polygon_area(poly)) >= 900.0:
		# A concave road-split face can have a narrow safe centre even when
		# its actual road boundary is long enough for an intentional passage.
		block["passage"] = _passage_for_block(block, source_index * 1024 + piece_index)
	var civic := _civic_kind_for(center, poly)
	if civic != &"":
		block["kind"] = civic
	return block


static func _road_strip_polygon(a: Vector2, b: Vector2, half_width: float) -> PackedVector2Array:
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
	# Deficit-first by coverage density: edges with the fewest parcels per
	# metre fill first, so the budget closes whole-street gaps instead of
	# thickening already-fronted edges. A single far-away parcel must not
	# mark an edge done. Order is stable (density ascending, edge id tiebreak
	# via stable sort on pre-sorted indices).
	var _specs_per_edge := {}
	for _spec_variant in _all_buildings:
		var _eid := str((_spec_variant as Dictionary).get("frontage_edge_id", ""))
		if _eid != "":
			_specs_per_edge[_eid] = int(_specs_per_edge.get(_eid, 0)) + 1
	var _density_order: Array = []
	for _edge_i in _city_edges.size():
		var _epoly: PackedVector2Array = (_city_edges[_edge_i] as Dictionary).get(
				"polyline", PackedVector2Array()) as PackedVector2Array
		var _elen := 0.0
		for _si in range(_epoly.size() - 1):
			_elen += _epoly[_si].distance_to(_epoly[_si + 1])
		var _eid2 := str((_city_edges[_edge_i] as Dictionary).get("id", ""))
		var _dens := float(int(_specs_per_edge.get(_eid2, 0))) / maxf(_elen, 1.0)
		_density_order.append([_dens, _edge_i])
	_density_order.sort_custom(func(a: Array, b: Array) -> bool:
			return a[0] < b[0] if not is_equal_approx(a[0], b[0]) \
					else a[1] < b[1])
	var _fill_order: Array[int] = []
	for _entry in _density_order:
		_fill_order.append(int((_entry as Array)[1]))
	var caps: Array[int] = [650, 900, 180]
	var added: Array[int] = [0, 0, 0]
	for edge_i in _fill_order:
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
			var pieces := clampi(int(ceil(segment_len / 13.0)), 1, 6)
			for piece in pieces:
				var road_mid := a.lerp(b, (float(piece) + 0.5) / float(pieces))
				var radius := road_mid.length()
				var band := 0 if radius < WorldConstants.CITY_HISTORIC_RADIUS_M else (1 if radius < 600.0 else 2)
				if radius >= WorldConstants.CITY_BLOCK_RADIUS_M - 12.0 or added[band] >= caps[band]:
					continue
				var frontage := 13.0
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
				frontage_width = clampf(frontage_width, maxf(min_frontage, 10.0), 16.0)
				var footprint := Vector2(frontage_width, depth)
				var yaw := atan2(tangent.y, tangent.x)
				for side_i in 2:
					if added[band] >= caps[band]:
						break
					var side := -1.0 if side_i == 0 else 1.0
					var center := road_mid + normal * side * (road_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 0.15 + depth * 0.5)
					var block := _block_containing_point(center)
					if block.is_empty() or block.get("kind", &"") == &"plaza" or bool(block.get("historic_compound", false)):
						continue
					var lot := _fit_frontage_lot(center, footprint, yaw, block["polygon"] as PackedVector2Array, normal * side)
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
					if _lot_overlaps_passage(lot, yaw, passage):
						continue
					if _city_road_within_raw(center, 5.0) or not _lot_clear_of_city_roads(lot, yaw):
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


static func _bounds_of_polygon(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for p: Vector2 in poly:
		min_x = minf(min_x, p.x)
		min_z = minf(min_z, p.y)
		max_x = maxf(max_x, p.x)
		max_z = maxf(max_z, p.y)
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))


## P2B-DENSE interior fill. Road-anchored passes leave block hearts empty no
## matter the budget (V2: +225 buildings, area voids barely moved). This grids
## the residual interior of large underfilled dense faces with
## courtyard-perimeter houses. Interior lots carry role "interior" and no road
## edge id (honest: they do not front streets); they count as occupied area,
## raise enclosure so real courtyards validate, and render through the normal
## assembler. Deterministic row-major grid, own token band, own budget.
func _fill_block_interiors() -> void:
	_prof_interior_tries = 0
	_prof_interior_no_fit = 0
	_prof_interior_land = 0
	_prof_interior_passage = 0
	_prof_interior_road = 0
	_prof_interior_overlap = 0
	_prof_interior_placed = 0
	var bi := 0
	for block in _blocks:
		if bool(block.get("historic_compound", false)):
			continue
		if (block.get("kind", &"built") as StringName) != &"built":
			bi += 1
			continue
		var district: StringName = block.get("district", DISTRICT_OUTER) as StringName
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if district == DISTRICT_OUTER or center.length() >= 600.0:
			bi += 1
			continue
		var poly: PackedVector2Array = block.get("polygon",
				PackedVector2Array()) as PackedVector2Array
		if poly.size() < 3:
			bi += 1
			continue
		var block_buildings: Array = block.get("buildings", []) as Array
		var occupied := 0.0
		for spec_variant in block_buildings:
			var lot0: Rect2 = (spec_variant as Dictionary).get("rect", Rect2()) as Rect2
			occupied += lot0.size.x * lot0.size.y
		var area := absf(_polygon_area(poly))
		if area < 2000.0 or (area - occupied) <= area * 0.35:
			bi += 1
			continue
		var yaw := 0.0
		if not block_buildings.is_empty():
			yaw = float((block_buildings[0] as Dictionary).get("yaw", 0.0))
		var passage: Dictionary = block.get("passage", {}) as Dictionary
		var radius := center.length()
		var placed := 0
		var bounds := _bounds_of_polygon(poly)
		var gx := bounds.position.x + 4.125
		while gx < bounds.end.x - 3.5:
			if placed >= 26:
				break
			var gz := bounds.position.y + 4.125
			while gz < bounds.end.y - 3.5:
				if placed >= 26:
					break
				var c := Vector2(gx, gz)
				if not _polygon_contains(poly, c) \
						or not _is_valid_city_land(c):
					gz += 8.25
					continue
				var w := lerpf(5.2, 7.5,
						_u("city_interior_width", [bi, placed]))
				var d := lerpf(8.0, 11.5,
						_u("city_interior_depth", [bi, placed]))
				var yaw_used := yaw
				var lot := Rect2()
				for yaw_try in [yaw, yaw + PI * 0.5]:
					lot = _fit_frontage_lot(c, Vector2(w, d), yaw_try, poly)
					if lot.size.x > 0.0 and lot.size.y > 0.0:
						yaw_used = yaw_try
						break
				if debug_profiling:
					_prof_interior_tries += 1
					if lot.size.x <= 0.0 or lot.size.y <= 0.0:
						_prof_interior_no_fit += 1
					elif not _lot_inside_polygon(lot, yaw_used, poly):
						_prof_interior_no_fit += 1
					elif not _city_lot_has_valid_land(lot, yaw_used) \
							or _near_rural_settlement(c):
						_prof_interior_land += 1
					elif _lot_overlaps_passage(lot, yaw_used, passage):
						_prof_interior_passage += 1
					elif _city_road_within_raw(c, 5.0) \
							or not _lot_clear_of_city_roads(lot, yaw_used):
						_prof_interior_road += 1
					elif _city_lot_overlaps_existing(lot, yaw_used):
						_prof_interior_overlap += 1
					else:
						_prof_interior_placed += 1
				if lot.size.x <= 0.0 or lot.size.y <= 0.0:
					gz += 8.25
					continue
				if lot.size.x < 4.0 or lot.size.y < 4.0:
					gz += 8.25
					continue
				if _lot_inside_polygon(lot, yaw_used, poly) \
						and _city_lot_has_valid_land(lot, yaw_used) \
						and not _near_rural_settlement(c) \
						and not _lot_overlaps_passage(lot, yaw_used, passage) \
						and not _city_road_within_raw(c, 5.0) \
						and _lot_clear_of_city_roads(lot, yaw_used) \
						and not _city_lot_overlaps_existing(lot, yaw_used):
					var outward := c - center
					if outward.length_squared() < 1e-6:
						outward = Vector2.RIGHT
					else:
						outward = outward.normalized()
					var door_edge := _door_edge_for_front(c, outward, lot, yaw_used)
					var spec := _make_city_spec(block, lot, door_edge,
							8000 + bi * 40 + placed,
							block_buildings.size(), radius, yaw_used)
					spec["frontage_role"] = &"interior"
					block_buildings.append(spec)
					block["buildings"] = block_buildings
					_all_buildings.append(spec)
					_building_by_id[String(spec["id"])] = spec
					placed += 1
				gz += 8.25
			gx += 8.25
		bi += 1
	if debug_profiling:
		print("[CityPlan] interiors tries=%d placed~%d nofit=%d land=%d passage=%d road=%d overlap=%d" \
				% [_prof_interior_tries, _prof_interior_placed,
				_prof_interior_no_fit, _prof_interior_land,
				_prof_interior_passage, _prof_interior_road,
				_prof_interior_overlap])


## P2B-DENSE: no valid dense face stays an unexplained empty lot. After all
## frontage passes, any built block inside the dense test band that is still
## empty either becomes an intentional park (invalid terrain) or receives
## force-placed narrow parcels along its road-nearest boundary. Deterministic
## and block-owned; new randomness uses fresh domains only.
func _guarantee_dense_block_minimum() -> void:
	var bi := 0
	for block in _blocks:
		if bool(block.get("historic_compound", false)):
			continue
		var district: StringName = block.get("district", DISTRICT_OUTER) as StringName
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if (block.get("kind", &"built") as StringName) != &"built":
			bi += 1
			continue
		if district == DISTRICT_OUTER or center.length() >= 600.0:
			bi += 1
			continue
		var buildings: Array = block.get("buildings", []) as Array
		if not buildings.is_empty():
			bi += 1
			continue
		var poly: PackedVector2Array = block.get("polygon",
				PackedVector2Array()) as PackedVector2Array
		if not _is_valid_city_land(center) or _valid_land_fraction(poly) < 0.4:
			block["kind"] = &"park"
			block["void_reason"] = &"invalid_terrain_designed_park"
			_block_by_cell[block["cell"]] = block
			bi += 1
			continue
		var placed := _force_boundary_parcels(block, poly, center, bi)
		if placed == 0:
			# A failed parcel fit is a development defect, not a designed park.
			# Retain it in density diagnostics instead of concealing blank space.
			block["void_reason"] = &"unplaceable_frontage"
			_block_by_cell[block["cell"]] = block
		bi += 1


## Narrow-parcel fallback for a single empty dense face. Walks the owning
## boundary like the primary pass but accepts Prague-narrow 4.0 m houses at
## shallow 8-12 m depths. Every lot still clears the normal polygon, land,
## road-clearance, and overlap gates and carries honest road frontage.
func _force_boundary_parcels(block: Dictionary, poly: PackedVector2Array,
		center: Vector2, bi: int) -> int:
	if poly.size() < 3:
		return 0
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	var placed := 0
	var radius := center.length()
	for boundary_i in poly.size():
		if placed >= 4:
			break
		var a: Vector2 = poly[boundary_i]
		var z: Vector2 = poly[(boundary_i + 1) % poly.size()]
		var blen := a.distance_to(z)
		if blen < 4.0:
			continue
		var edge_mid := (a + z) * 0.5
		var nearest_edge_i := -1
		var nearest_distance := INF
		var nearest_width := WorldConstants.CITY_ROAD_WIDTH_LOCAL
		var nearest_point := edge_mid
		for road_i in _city_edges.size():
			var road_edge: Dictionary = _city_edges[road_i]
			var road_poly: PackedVector2Array = road_edge.get("polyline",
					PackedVector2Array()) as PackedVector2Array
			var road_point := _nearest_point_on_polyline(edge_mid, road_poly)
			if road_point == Vector2.INF:
				continue
			var d := edge_mid.distance_to(road_point)
			if d < nearest_distance:
				nearest_distance = d
				nearest_edge_i = road_i
				nearest_point = road_point
				nearest_width = float(road_edge.get("width",
						WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		if nearest_edge_i < 0 or nearest_distance > nearest_width * 0.5 \
				+ _CITY_ROAD_BLOCK_CLEARANCE + 6.0:
			continue
		var tangent := (z - a).normalized()
		var inward := Vector2(-tangent.y, tangent.x)
		if not _polygon_contains(poly, edge_mid + inward * 1.0):
			inward = -inward
		if not _polygon_contains(poly, edge_mid + inward * 1.0):
			continue
		var width := clampf(blen * 0.85, 4.0, 8.0)
		var depth := lerpf(8.0, 12.0,
				_u("city_guarantee_depth", [bi, boundary_i]))
		var yaw := atan2(tangent.y, tangent.x)
		var lot := Rect2()
		for inset in [0.18, 0.55, 0.92, 1.4]:
			var c := edge_mid + inward * (float(inset) + depth * 0.5)
			lot = _fit_frontage_lot(c, Vector2(width, depth), yaw, poly, inward)
			if lot.size.x > 0.0 and lot.size.y > 0.0:
				break
		if lot.size.x <= 0.0 or lot.size.y <= 0.0:
			continue
		if lot.size.x < 4.0 or lot.size.y < 4.0:
			continue
		if not _city_lot_has_valid_land(lot, yaw) \
				or _near_rural_settlement(lot.get_center()):
			continue
		if _lot_overlaps_passage(lot, yaw, passage):
			continue
		if not _lot_clear_of_city_roads(lot, yaw):
			continue
		if _city_lot_overlaps_existing(lot, yaw):
			continue
		var block_buildings: Array = block.get("buildings", []) as Array
		var door_edge := _door_edge_for_front(lot.get_center(), inward, lot, yaw)
		var spec := _make_city_spec(block, lot, door_edge,
				7000 + bi * 32 + placed, block_buildings.size(), radius, yaw)
		spec["frontage_role"] = &"corner" if _is_corner_frontage(edge_mid) else &"street"
		spec["frontage_edge_id"] = str((_city_edges[nearest_edge_i] as Dictionary).get("id", ""))
		spec["frontage_center"] = nearest_point
		block_buildings.append(spec)
		block["buildings"] = block_buildings
		_all_buildings.append(spec)
		_building_by_id[String(spec["id"])] = spec
		placed += 1
	return placed


func _block_containing_point(p: Vector2) -> Dictionary:
	for block: Dictionary in _blocks:
		var bounds: Rect2 = block.get("bounds", block.get("rect", Rect2()))
		if not bounds.grow(0.001).has_point(p):
			continue
		if _polygon_contains(block.get("polygon", PackedVector2Array()) as PackedVector2Array, p):
			return block
	return {}


func _fit_frontage_lot(center: Vector2, footprint: Vector2, yaw: float,
		poly: PackedVector2Array, inward := Vector2.ZERO) -> Rect2:
	# Preserve the road-facing width first. The old uniform shrink reduced the
	# facade whenever a deep lot met an oblique block edge, creating avoidable
	# gaps along otherwise usable frontages. Depth yields before frontage width,
	# and it may yield all the way to CITY_LOT_FIT_MIN_DEPTH_M: stopping at 14 m
	# returned no lot at all for a block shallower than that.
	footprint = footprint.max(Vector2(WorldConstants.CITY_LOT_FIT_MIN_FRONTAGE_M, WorldConstants.CITY_LOT_FIT_MIN_DEPTH_M))
	var frontage_trial := footprint.x
	var depth_trial := footprint.y
	for _i in 16:
		var trial := Vector2(frontage_trial, depth_trial)
		# When depth yields to a skewed rear boundary, preserve the street
		# facade instead of shrinking around the original footprint center.
		# Centered shrink silently moved entrances several metres off frontage.
		var trial_center := center - inward * (footprint.y - depth_trial) * 0.5
		var lot := Rect2(trial_center - trial * 0.5, trial)
		if _lot_inside_polygon(lot, yaw, poly):
			return lot
		if depth_trial > WorldConstants.CITY_LOT_FIT_MIN_DEPTH_M:
			depth_trial = maxf(WorldConstants.CITY_LOT_FIT_MIN_DEPTH_M, depth_trial * 0.84)
		else:
			frontage_trial *= 0.92
		if frontage_trial < WorldConstants.CITY_LOT_FIT_MIN_FRONTAGE_M:
			break
	return Rect2()


func _city_lot_has_valid_land(lot: Rect2, yaw := 0.0, min_frontage := 10.0) -> bool:
	# min_frontage is a district parameter: the generic city fabric assumes a
	# 10 m lot, while a historic-core plot is allowed down to 6 m (spec item 3),
	# which is still wide enough for the 4.7 m stair minimum. The depth floor is
	# the district lot standard, NOT the fitter's yield floor: the fitter may
	# return a shallower parcel for a shallow block, and this gate rejects it.
	if lot.size.x < min_frontage or lot.size.y < WorldConstants.CITY_LOT_MIN_DEPTH_M:
		return false
	for p: Vector2 in _lot_corners(lot, yaw):
		if not _is_valid_city_land(p):
			return false
	return true


func _city_lot_overlaps_existing(lot: Rect2, yaw := 0.0) -> bool:
	# Accepted footprints are append-only during placement. Index each once;
	# candidates still use the unchanged exact SAT predicate and margin.
	while _placement_indexed_count < _all_buildings.size():
		var spec := _all_buildings[_placement_indexed_count]
		var bounds := _oriented_rect_bounds(spec["rect"], float(spec.get("yaw", 0.0))).grow(0.22)
		for x in range(floori(bounds.position.x / 32.0), floori(bounds.end.x / 32.0) + 1):
			for z in range(floori(bounds.position.y / 32.0), floori(bounds.end.y / 32.0) + 1):
				var key := Vector2i(x, z)
				var bucket: Array = _placement_bins.get(key, []) as Array
				bucket.append(spec)
				_placement_bins[key] = bucket
		_placement_indexed_count += 1
	var query := _oriented_rect_bounds(lot, yaw).grow(0.22)
	for x in range(floori(query.position.x / 32.0), floori(query.end.x / 32.0) + 1):
		for z in range(floori(query.position.y / 32.0), floori(query.end.y / 32.0) + 1):
			for spec: Dictionary in _placement_bins.get(Vector2i(x, z), []):
				if _lots_overlap(lot, yaw, spec["rect"] as Rect2,
						float(spec.get("yaw", 0.0)), 0.22):
					return true
	return false


func _lot_overlaps_passage(lot: Rect2, yaw: float,
		passage: Dictionary) -> bool:
	if passage.is_empty():
		return false
	var passage_poly: PackedVector2Array = passage.get("polygon",
			PackedVector2Array()) as PackedVector2Array
	if passage_poly.size() < 3:
		return _lots_overlap(lot, yaw, passage.get("rect", Rect2()) as Rect2,
				0.0, 0.25)
	for intersection_variant in Geometry2D.intersect_polygons(
				_lot_corners(lot, yaw, 0.25), passage_poly):
		var intersection: PackedVector2Array = intersection_variant as PackedVector2Array
		if _polygon_area(intersection) > 0.25:
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
	if not _polygon_contains(poly, center):
		# Road cuts can leave a U-shaped face whose centroid is in the road
		# or another block. Shrinking around that point can never fit. Choose
		# a deterministic interior point from the largest real triangle.
		var triangles := Geometry2D.triangulate_polygon(poly)
		var largest := -1.0
		for i in range(0, triangles.size(), 3):
			var a := poly[triangles[i]]
			var b := poly[triangles[i + 1]]
			var c := poly[triangles[i + 2]]
			var area := absf((b - a).cross(c - a))
			if area > largest:
				largest = area
				center = (a + b + c) / 3.0
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
			var civic_radius := float(lm.get("radius", 30.0))
			if site.distance_to(lm["center"] as Vector2) < civic_radius \
					and _polygon_area(poly) <= PI * civic_radius * civic_radius * 2.0:
				nearby_square = true
				break
	if nearby_square or (radius < 90.0 and index == 0):
		kind = &"plaza"
	elif _u("city_block_kind", [index]) < (0.025 if radius < WorldConstants.CITY_HISTORIC_RADIUS_M else 0.05 if radius < WorldConstants.CITY_DENSE_RADIUS_M else 0.10):
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
	var poly: PackedVector2Array = block.get("polygon",
			PackedVector2Array()) as PackedVector2Array
	if poly.size() < 3:
		return {}
	var chance := 0.46
	if block.get("district", DISTRICT_OUTER) == DISTRICT_HISTORIC:
		chance = 0.72
	elif block.get("district", DISTRICT_OUTER) == DISTRICT_INNER:
		chance = 0.60
	var block_area := absf(_polygon_area(poly))
	var district: StringName = block.get("district", DISTRICT_OUTER) as StringName
	# A normal perimeter block also needs access to its rear court. Requiring
	# 3000 m² excluded most historic faces (typically 1000–2000 m²), leaving
	# their enclosed rear ground inaccessible even where frontage fitted.
	var needs_dense_access := block_area >= 900.0 and district != DISTRICT_OUTER
	if _u("city_alley_presence", [index]) >= chance and not needs_dense_access:
		return {}
	# Choose the nearest point on a REAL road edge, then route a short,
	# deterministic corridor toward the interior of this exact block polygon.
	# The corridor is clipped before it is recorded, so an alley can never be
	# a detached axis-aligned strip outside its owning face.
	var target := _polygon_centroid(poly)
	if not _polygon_contains(poly, target):
		var block_rect: Rect2 = block.get("rect", Rect2()) as Rect2
		if _polygon_contains(poly, block_rect.get_center()):
			target = block_rect.get_center()
		else:
			return {}
	var nearest_point := Vector2.INF
	var nearest_d2 := INF
	var nearest_width := WorldConstants.CITY_ROAD_WIDTH_LOCAL
	var nearest_edge_id := ""
	for edge: Dictionary in _city_edges:
		var road_poly: PackedVector2Array = edge.get("polyline",
				PackedVector2Array()) as PackedVector2Array
		if road_poly.size() < 2:
			continue
		for segment_i in range(road_poly.size() - 1):
			var a: Vector2 = road_poly[segment_i]
			var z: Vector2 = road_poly[segment_i + 1]
			var delta := z - a
			var len2 := delta.length_squared()
			if len2 < 1e-6:
				continue
			var t := clampf((target - a).dot(delta) / len2, 0.0, 1.0)
			var q := a + delta * t
			var d2 := target.distance_squared_to(q)
			if d2 < nearest_d2:
				nearest_d2 = d2
				nearest_point = q
				nearest_width = float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
				nearest_edge_id = str(edge.get("id", ""))
	if nearest_point == Vector2.INF:
		return {}
	# The nearest road to a block centroid is not necessarily the road that
	# bounds that block. Require the selected point to sit beside the actual
	# polygon boundary so "road_connected" cannot describe a detached strip.
	var boundary_distance := INF
	for boundary_i in poly.size():
		var boundary := PackedVector2Array([
			poly[boundary_i], poly[(boundary_i + 1) % poly.size()],
		])
		boundary_distance = minf(boundary_distance,
				_distance_to_polyline(nearest_point, boundary))
	if boundary_distance > nearest_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 1.0:
		# The centroid-nearest road may be across a different face. Recover
		# the closest actual road-boundary pair before rejecting a large dense
		# face; this keeps the passage road-connected without adding a road.
		var boundary_access := _nearest_road_to_boundary(poly, target)
		if boundary_access.is_empty():
			return {}
		nearest_point = boundary_access["road_point"] as Vector2
		nearest_width = float(boundary_access["road_width"])
		nearest_edge_id = str(boundary_access["road_edge_id"])
	var inward_delta := target - nearest_point
	if inward_delta.length_squared() < 100.0:
		return {}
	var inward := inward_delta.normalized()
	var start := Vector2.INF
	for step_i in range(1, 161):
		var candidate := nearest_point + inward * float(step_i) * 0.5
		if _polygon_contains(poly, candidate):
			start = candidate
			break
	if start == Vector2.INF or start.distance_to(target) < 8.0:
		return {}
	var passage_width := lerpf(WorldConstants.CITY_ALLEY_WIDTH * 1.65,
		WorldConstants.CITY_ALLEY_WIDTH * 2.45,
		_u("city_alley_width", [index]))
	var direction := (target - start).normalized()
	var side := Vector2(-direction.y, direction.x) * passage_width * 0.5
	var extension := direction * 0.8
	var raw := PackedVector2Array([
		start - extension - side,
		target + extension - side,
		target + extension + side,
		start - extension + side,
	])
	var best := PackedVector2Array()
	var best_area := 0.0
	for clipped_variant in Geometry2D.intersect_polygons(raw, poly):
		var clipped: PackedVector2Array = clipped_variant as PackedVector2Array
		var area := absf(_polygon_area(clipped))
		if clipped.size() >= 3 and area > best_area:
			best = clipped
			best_area = area
	if best.size() < 3 or best_area < 6.0:
		return {}
	var axis := 0 if absf(direction.x) >= absf(direction.y) else 1
	return {
		"axis": axis,
		"half": passage_width * 0.5,
		"rect": _polygon_bounds(best),
		"polygon": best,
		"kind": &"historic_alley",
		"road_connected": true,
		"road_edge_id": nearest_edge_id,
		"road_point": nearest_point,
		"entry_point": start,
		"direction": direction,
		"width": passage_width,
		"road_width": nearest_width,
		"access_kind": &"road_connected_alley",
	}


func _nearest_road_to_boundary(poly: PackedVector2Array, target: Vector2) -> Dictionary:
	if poly.size() < 2:
		return {}
	var best_score := INF
	var best: Dictionary = {}
	# Sampling endpoints and three interior points handles long straight faces
	# while keeping fallback work bounded; the returned road point is projected
	# onto the real generated edge, never invented from the block bounds.
	for boundary_i in poly.size():
		var a: Vector2 = poly[boundary_i]
		var z: Vector2 = poly[(boundary_i + 1) % poly.size()]
		if a.distance_to(z) < 2.0:
			continue
		for sample_t in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var boundary_point: Vector2 = a.lerp(z, float(sample_t))
			for edge_i in _city_edges.size():
				var edge: Dictionary = _city_edges[edge_i]
				if bool(edge.get("is_bridge", false)):
					continue
				var road_poly: PackedVector2Array = edge.get("polyline",
						PackedVector2Array()) as PackedVector2Array
				var road_point := _nearest_point_on_polyline(boundary_point, road_poly)
				if road_point == Vector2.INF:
					continue
				var road_width := float(edge.get("width",
						WorldConstants.CITY_ROAD_WIDTH_LOCAL))
				var distance := boundary_point.distance_to(road_point)
				if distance > road_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 1.0:
					continue
				# Prefer an entry near the block centre, then the tightest
				# boundary/road connection for deterministic tie-breaking.
				var score := boundary_point.distance_squared_to(target) \
						+ distance * distance * 4.0
				if score >= best_score:
					continue
				best_score = score
				best = {
					"road_point": road_point,
					"road_width": road_width,
					"road_edge_id": str(edge.get("id", "")),
					"boundary_point": boundary_point,
				}
	return best


func _buildings_for_block(block: Dictionary) -> Array[Dictionary]:
	if bool(block.get("historic_compound", false)):
		return _historic_buildings_for_block(block)
	var result: Array[Dictionary] = []
	var poly: PackedVector2Array = block.get("polygon") as PackedVector2Array
	var site: Vector2 = block.get("site") as Vector2
	var radius := site.length()
	var district: StringName = block.get("district") as StringName
	if block["kind"] == &"park":
		# Designed green heart, framed by a street wall: perimeter houses
		# face outward (honest road frontage for samples) while the interior
		# stays grass and trees. No interior fill — the green must hold.
		if radius < WorldConstants.CITY_DENSE_RADIUS_M:
			_append_boundary_frontage_lots(result, block, poly, radius, 10)
		return result
	var frontage := 13.0
	var max_buildings := 9
	if district == DISTRICT_HISTORIC:
		frontage = 13.0
		max_buildings = 26
	elif district == DISTRICT_INNER:
		frontage = 13.0
		max_buildings = 24
	if block["kind"] == &"plaza":
		frontage = 13.0
		max_buildings = 16
	elif district != DISTRICT_OUTER:
		var perimeter := 0.0
		for i in poly.size():
			perimeter += poly[i].distance_to(poly[(i + 1) % poly.size()])
		# Long irregular faces need capacity for all street sides, rather
		# than exhausting a fixed budget on the first boundary encountered.
		max_buildings = clampi(ceili(perimeter / (frontage + 0.5)), max_buildings, 64)
	# Boundary walk is the primary pass for irregular road-derived faces: it
	# follows the actual owning polygon and cannot jump into a block centre.
	if block["kind"] == &"built" and radius < WorldConstants.CITY_DENSE_RADIUS_M:
		_append_boundary_frontage_lots(result, block, poly, radius, max_buildings)
	if block["kind"] == &"built" and result.size() < max_buildings:
		_append_road_frontage_lots(result, block, poly, radius, frontage, max_buildings)
	if block["kind"] == &"built" and result.size() < max_buildings \
			and district != DISTRICT_OUTER:
		_append_road_intersection_lots(result, block, poly, radius, frontage,
				max_buildings)
	if block["kind"] == &"built" and result.size() < max_buildings \
			and district != DISTRICT_OUTER \
			and absf(_polygon_area(poly)) >= 900.0:
		_append_passage_side_lots(result, block, poly, radius, max_buildings)
	# Every accepted parcel in this function is produced against an actual
	# road frontage. Polygon-edge, corner, and site-centre fallbacks are
	# intentionally absent: a valid irregular block is not permission to place
	# a detached building away from a street.
	return result


func _historic_buildings_for_block(block: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	block["plots"] = []
	if block.kind == &"plaza":
		return result
	var plots := HistoricParcels.for_block(block, seed_used)
	for plot: Dictionary in plots:
		# Historic shallow exceptions are real houses; the generic 14m depth
		# gate previously discarded half the already reserved frontage plots.
		var valid := true
		for point: Vector2 in plot.polygon:
			valid = valid and _is_valid_city_land(point)
		if not valid or not _lot_clear_of_city_roads(plot.rect, plot.yaw):
			var reason := "land_rejected" if not valid else "road_rejected"
			HistoricParcels.stats[reason] = int(HistoricParcels.stats.get(reason, 0)) + 1
			continue
		var low := INF
		var high := -INF
		for point: Vector2 in plot.polygon:
			var y := WorldPlan.urban_base_height_at(terrain, point)
			low = minf(low, y)
			high = maxf(high, y)
		var front_y := WorldPlan.urban_base_height_at(terrain, plot.frontage_center)
		plot.ground_y = high + 0.08 if high - low > 0.18 else front_y
		if float(plot.ground_y) - front_y > 3.5:
			HistoricParcels.stats["relief_rejected"] = int(HistoricParcels.stats.get("relief_rejected", 0)) + 1
			continue # A bounded entrance ramp cannot serve this terrain relief.
		block.plots.append(plot)
		var grain := Vector2i(floori((plot.frontage_center as Vector2).x / 90.0), floori((plot.frontage_center as Vector2).y / 90.0))
		var base_floors := 3 + int(_u("historic_height_neighborhood", [grain.x, grain.y]) * 3.0)
		var floors := clampi(base_floors + (1 if _u("historic_height_variation", [WorldSeed.str_hash(plot.id)]) > 0.82 else 0), 3, 6)
		for wi in plot.wings.size():
			var wing: Dictionary = plot.wings[wi]
			var local: Rect2 = wing.local_rect
			var center := _rotate_plan_point((plot.rect as Rect2).get_center(), (plot.rect as Rect2).position + local.get_center(), plot.yaw)
			var rect := Rect2(center - local.size * 0.5, local.size)
			var spec := _make_city_spec(block, rect, wing.door_edge, 0, wi, center.length(), plot.yaw)
			spec.id = str(wing.id)
			spec.seed_used = seed_used
			spec.plot_id = str(plot.id)
			spec.compound_id = str(plot.id)
			spec.owner_chunk = plot.owner_chunk
			spec.compound_rect = plot.rect
			spec.planned_ground_y = plot.ground_y
			spec.wing_role = wing.role
			spec.historical_layer = plot.historical_layer if wi == 0 else &"later_rear_extension"
			# A wing too small to hold a stair is a single-storey service extension,
			# not a multi-storey wing nobody can climb: the plan and the interior
			# grammar must agree on the storey count.
			var wing_floors := floors if wi == 0 else (maxi(2, floors - 1) if wing.role == &"rear" else 1)
			if not BuildingBuilder.has_stairs_for(rect.size, 3.1, wing_floors):
				wing_floors = 1
			spec.floors = wing_floors
			spec.archetype = "merged_house" if float(plot.frontage_m) > 15.0 else ("courtyard_tenement" if plot.wings.size() >= 3 else "narrow_townhouse")
			spec.floor_h = 3.1
			spec.circulation = {"kind": &"stairs" if int(spec.floors) > 1 else &"none"}
			spec.frontage_role = &"street" if wi == 0 else &"courtyard"
			spec.frontage_center = plot.frontage_center
			# A historic house is not one use (spec 8): the street wing carries the
			# ground-floor program, courtyard annexes carry service programs, and
			# the upper floors hold apartments or offices above both.
			var ground_roll := _u("historic_ground_use", [WorldSeed.str_hash(plot.id)])
			var street_use := "retail" if ground_roll < 0.32 else ("tavern" if ground_roll < 0.52 else ("workshop" if ground_roll < 0.72 else ("storage" if ground_roll < 0.88 else "caretaker")))
			# A house laid by the stepped frontage fill carries its own venue.
			# Those are the small houses wedged into an irregular face, which is
			# exactly where a city keeps its cafe, restaurant and corner shop, so
			# the plan honours the venue instead of rolling a service use over it.
			var venue := str(plot.get("venue", ""))
			if wi == 0 and not venue.is_empty():
				street_use = venue
			spec.use = street_use if wi == 0 else ("workshop" if _u("historic_annex_use", [WorldSeed.str_hash(plot.id), wi]) < 0.35 else "storage")
			spec.floor_uses = [spec.use]
			for fi in range(1, int(spec.floors)):
				spec.floor_uses.append("office" if _u("historic_upper_use", [WorldSeed.str_hash(plot.id), fi]) < 0.18 else "residential")
			if wi == 0 and spec.archetype == "narrow_townhouse":
				spec.archetype = {"retail": "merchant_house", "workshop": "artisan_house", "tavern": "tavern_inn"}.get(str(spec.use), "narrow_townhouse")
			spec.style.room_type = spec.use
			spec.style.attic = true
			spec.style.roof_plan = HistoricRoofs.for_wing(spec)
			spec.extra_door_edges = [2] if wi == 0 and not plot.passages.is_empty() else []
			# Locked decision 2: door widths are kind-based and come from the
			# one table in WorldConstants. The carriage passage is the only
			# "grand" opening; every later wing/back door is a service door.
			var entry_kind: StringName = WorldConstants.door_kind_for_entrance(
					str(spec.use), not plot.passages.is_empty(),
					float(plot.frontage_m), wi > 0)
			spec.door_w = WorldConstants.door_kind_width(entry_kind)
			spec.door_h = WorldConstants.door_kind_height(entry_kind)
			spec.facade_plan = HistoricFacades.for_wing(spec)
			spec.doors = []
			var door_edges: Array = [int(wing.door_edge)] + spec.extra_door_edges
			for de: int in door_edges:
				var door := _door_manifest(spec.id, rect, de, seed_used)
				# The aperture pass in BuildingBuilder cuts every wing door at
				# spec.door_w, so both leaves must read the same value: a
				# passage house has the grand opening at each end of the
				# carriage way, never a wide hole behind a narrow leaf.
				door.width = spec.door_w
				door.height = spec.door_h
				door.id = "%s_door_%d" % [spec.id, de]
				var dp: Vector3 = door.position
				var rotated := _rotate_plan_point(center, Vector2(dp.x, dp.z), plot.yaw)
				door.position = Vector3(rotated.x, 0, rotated.y)
				door.yaw = float(door.yaw) - float(plot.yaw)
				spec.doors.append(door)
			result.append(spec)
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
	var rear_candidates: Array[Dictionary] = []
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
			var pieces := _frontage_piece_count(segment_len, 5.4, minf(frontage + 1.0, 11.0))
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
						16.0 if dense_frontage else 16.0)
				if dense_frontage:
					frontage_width = minf(16.0, segment_len / float(pieces) - 0.5)
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
					var lot := _fit_frontage_lot(center, footprint, yaw, poly, normal * side)
					if lot.size.x <= 0.0 or lot.size.y <= 0.0:
						continue
					if not _is_valid_city_land(center) or _near_rural_settlement(center):
						continue
					# The fitter preserves the frontage and may yield depth; the
					# accepted lot standard is enforced here, like every other
					# placement path, so a yielded sliver never becomes a building.
					if not _city_lot_has_valid_land(lot, yaw):
						continue
					if _lot_overlaps_passage(lot, yaw, passage):
						continue
					if _city_road_within_raw(center, 5.0) or not _lot_clear_of_city_roads(lot, yaw):
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
					if dense_frontage:
						rear_candidates.append({
							"edge_i": edge_i, "segment_i": segment_i,
							"piece": piece, "side_i": side_i,
							"road_width": road_width, "normal": normal,
							"side": side, "road_mid": road_mid,
							"frontage_width": frontage_width,
							"front_depth": depth, "yaw": yaw,
						})
	# Only use a second shallow row when the frontage pass could not fill its
	# bounded building budget. This reserves no street-wall capacity and every
	# candidate remains a validated full BuildingSpec.
	if dense_frontage and result.size() < max_buildings:
		var rear_chance := 0.88 if district == DISTRICT_HISTORIC else 0.78
		for candidate_i in rear_candidates.size():
			if result.size() >= max_buildings:
				break
			if _u("city_rear_frontage_presence", [candidate_i,
					int(block.get("cell", Vector2i.ZERO).x),
					int(block.get("cell", Vector2i.ZERO).y)]) >= rear_chance:
				continue
			var candidate: Dictionary = rear_candidates[candidate_i]
			_append_rear_frontage_lot(result, block, poly, passage, radius,
					int(candidate["edge_i"]), int(candidate["segment_i"]),
					int(candidate["piece"]), int(candidate["side_i"]),
					float(candidate["road_width"]), candidate["normal"] as Vector2,
					float(candidate["side"]), candidate["road_mid"] as Vector2,
					float(candidate["frontage_width"]), float(candidate["front_depth"]),
					float(candidate["yaw"]), max_buildings)


func _append_road_intersection_lots(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, radius: float, frontage: float,
		max_buildings: int) -> void:
	# Recover frontage from the actual intersection between a road ribbon and
	# this block face. Unlike a whole-segment midpoint guess, this still finds
	# the short road interval owned by a concave or road-split component.
	var district: StringName = block.get("district", DISTRICT_INNER) as StringName
	var dense_frontage := district == DISTRICT_HISTORIC or district == DISTRICT_INNER
	var depth_min := 13.5 if district == DISTRICT_HISTORIC else 14.0
	var depth_max := 22.0
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	for edge_i in _city_edges.size():
		if result.size() >= max_buildings:
			return
		var edge: Dictionary = _city_edges[edge_i]
		var road_width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		var road_poly: PackedVector2Array = edge.get("polyline",
				PackedVector2Array()) as PackedVector2Array
		for segment_i in range(road_poly.size() - 1):
			if result.size() >= max_buildings:
				return
			var a: Vector2 = road_poly[segment_i]
			var z: Vector2 = road_poly[segment_i + 1]
			var delta := z - a
			var segment_len := delta.length()
			if segment_len < 4.0:
				continue
			var tangent := delta / segment_len
			var road_strip := _road_strip_polygon(a, z,
					road_width * 0.5 + _CITY_ROAD_BLOCK_CLEARANCE + 0.8)
			var near_regions: Array = Geometry2D.intersect_polygons(poly, road_strip)
			for region_i in near_regions.size():
				if result.size() >= max_buildings:
					return
				var region: PackedVector2Array = near_regions[region_i] as PackedVector2Array
				if region.size() < 3:
					continue
				var min_t := 1.0
				var max_t := 0.0
				for p: Vector2 in region:
					var t := clampf((p - a).dot(tangent) / segment_len, 0.0, 1.0)
					min_t = minf(min_t, t)
					max_t = maxf(max_t, t)
				var owned_len := (max_t - min_t) * segment_len
				if owned_len < 4.8:
					continue
				var pieces := clampi(int(floor(owned_len / maxf(frontage + 1.4, 5.5))), 1, 6)
				var width_low := 0.90 if dense_frontage else 0.72
				var width_high := 0.995 if dense_frontage else 0.90
				var frontage_width := owned_len / float(pieces) * lerpf(width_low,
						width_high, _u("city_intersection_frontage_width",
							[edge_i, segment_i, region_i]))
				frontage_width = clampf(frontage_width,
						5.4 if dense_frontage else 4.8,
						16.0 if dense_frontage else 16.0)
				var region_center := _polygon_centroid(region)
				for piece in pieces:
					if result.size() >= max_buildings:
						return
					var t := lerpf(min_t, max_t,
							(float(piece) + 0.5) / float(pieces))
					var road_mid := a + delta * t
					var inward_delta := (block.get("center", region_center) as Vector2) - road_mid
					if inward_delta.length_squared() < 1e-6:
						inward_delta = region_center - road_mid
					if inward_delta.length_squared() < 1e-6:
						continue
					var inward := inward_delta.normalized()
					if not _polygon_contains(poly, road_mid + inward * 1.0):
						inward = -inward
					if not _polygon_contains(poly, road_mid + inward * 1.0):
						continue
					var depth := lerpf(depth_min, depth_max,
							_u("city_intersection_frontage_depth",
							[edge_i, segment_i, region_i, piece]))
					var center := road_mid + inward * (road_width * 0.5
							+ _CITY_ROAD_BLOCK_CLEARANCE + 0.15 + depth * 0.5)
					var yaw := atan2(tangent.y, tangent.x)
					var lot := _fit_frontage_lot(center,
							Vector2(frontage_width, depth), yaw, poly)
					if lot.size.x <= 0.0 or lot.size.y <= 0.0:
						continue
					if not _city_lot_has_valid_land(lot, yaw) \
							or _near_rural_settlement(lot.get_center()):
						continue
					if _lot_overlaps_passage(lot, yaw, passage):
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
					var door_edge := _door_edge_for_front(center, inward, lot, yaw)
					var spec := _make_city_spec(block, lot, door_edge,
							6000 + edge_i * 64 + segment_i * 8 + region_i * 2 + piece,
							result.size(), radius, yaw)
					spec["frontage_role"] = &"corner" if _is_corner_frontage(road_mid) else &"street"
					spec["frontage_edge_id"] = str(edge.get("id", ""))
					spec["frontage_center"] = road_mid
					result.append(spec)


func _append_passage_side_lots(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, radius: float, max_buildings: int) -> void:
	var passage: Dictionary = block.get("passage", {}) as Dictionary
	if passage.is_empty() or not bool(passage.get("road_connected", false)):
		return
	var entry: Vector2 = passage.get("entry_point", Vector2.INF) as Vector2
	var direction: Vector2 = passage.get("direction", Vector2.ZERO) as Vector2
	if entry == Vector2.INF or direction.length_squared() < 1e-6:
		return
	direction = direction.normalized()
	var tangent := Vector2(-direction.y, direction.x)
	var passage_width := float(passage.get("width", float(passage.get("half", 1.8)) * 2.0))
	if passage_width <= 0.1:
		return
	var district: StringName = block.get("district", DISTRICT_INNER) as StringName
	var frontage_width := 13.0
	var depth_min := 13.5 if district == DISTRICT_HISTORIC else 14.0
	var depth_max := 20.5 if district == DISTRICT_HISTORIC else 19.0
	var passage_frontage_id := "passage:%s" % str(block.get("id", "city_block"))
	var passage_poly: PackedVector2Array = passage.get("polygon", PackedVector2Array()) as PackedVector2Array
	var passage_length := 0.0
	for point in passage_poly:
		passage_length = maxf(passage_length, (point - entry).dot(direction))
	var row_count := mini(_frontage_piece_count(passage_length, 5.4, frontage_width), 12)
	if row_count == 0:
		return
	var row_step := passage_length / float(row_count)
	frontage_width = minf(frontage_width, row_step - 0.5)
	for row in row_count:
		if result.size() >= max_buildings:
			return
		var depth := lerpf(depth_min, depth_max,
			_u("city_passage_side_depth", [int(block.get("cell", Vector2i.ZERO).x),
				int(block.get("cell", Vector2i.ZERO).y), row]))
		var inward_offset := (float(row) + 0.5) * row_step
		# The passage centreline is the frontage datum for both side lots.
		# It is intentionally distinct from the road point that created the
		# passage, so these lots cannot be attributed to the main road edge.
		var passage_frontage_center := entry + direction * inward_offset
		for side_i in 2:
			if result.size() >= max_buildings:
				return
			var side := -1.0 if side_i == 0 else 1.0
			var lateral := side * (passage_width * 0.5 + 0.45 + depth * 0.5)
			var center := entry + direction * inward_offset + tangent * lateral
			var yaw := atan2(direction.y, direction.x)
			var lot := _fit_frontage_lot(center,
				Vector2(frontage_width, depth), yaw, poly, tangent * side)
			if lot.size.x <= 0.0 or lot.size.y <= 0.0:
				continue
			if not _city_lot_has_valid_land(lot, yaw) \
					or _near_rural_settlement(lot.get_center()):
				continue
			if _lot_overlaps_passage(lot, yaw, passage):
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
			var spec := _make_city_spec(block, lot,
					2 if side < 0.0 else 0,
					7000 + row * 4 + side_i, result.size(), radius, yaw)
			spec["frontage_role"] = &"passage"
			spec["frontage_edge_id"] = passage_frontage_id
			spec["frontage_center"] = passage_frontage_center
			result.append(spec)


static func _frontage_piece_count(length: float, min_width: float, max_width: float) -> int:
	if length < min_width + 0.5:
		return 0
	var count := clampi(ceili(length / (max_width + 0.5)), 1, 64)
	while count > 1 and length / float(count) < min_width + 0.5:
		count -= 1
	return count


func _append_boundary_frontage_lots(result: Array[Dictionary], block: Dictionary,
		poly: PackedVector2Array, radius: float, max_buildings: int) -> void:
	# A road ribbon can split a concave cell into a face whose centroid no
	# longer provides a valid rectangle center. Walk the actual face boundary
	# instead: only edges close to a generated road may seed a parcel, and the
	# inward normal is proved against the owning polygon before placement.
	if poly.size() < 3:
		return
	var district: StringName = block.get("district", DISTRICT_INNER) as StringName
	var min_width := 10.0
	var max_width := 16.0
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
		var pieces := _frontage_piece_count(boundary_len, min_width, max_width)
		for piece in pieces:
			if result.size() >= max_buildings:
				return
			var t := (float(piece) + 0.5) / float(pieces)
			var edge_mid := a.lerp(z, t)
			var nearest_edge_i := -1
			var nearest_distance := INF
			var nearest_width := WorldConstants.CITY_ROAD_WIDTH_LOCAL
			var nearest_point := edge_mid
			for road_i in _city_edges.size():
				var road_edge: Dictionary = _city_edges[road_i]
				var road_poly: PackedVector2Array = road_edge.get("polyline",
						PackedVector2Array()) as PackedVector2Array
				var road_point := _nearest_point_on_polyline(edge_mid, road_poly)
				if road_point == Vector2.INF:
					continue
				var distance := edge_mid.distance_to(road_point)
				if distance < nearest_distance:
					nearest_distance = distance
					nearest_edge_i = road_i
					nearest_point = road_point
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
			var frontage_width := minf(boundary_len / float(pieces) - 0.5, max_width)
			var depth := lerpf(depth_min, depth_max,
					_u("city_boundary_frontage_depth", [nearest_edge_i, boundary_i, piece]))
			var yaw := atan2(tangent.y, tangent.x)
			var lot := Rect2()
			for inset in [0.18, 0.55, 0.92]:
				var center := edge_mid + inward * (float(inset) + depth * 0.5)
				lot = _fit_frontage_lot(center, Vector2(frontage_width, depth), yaw, poly, inward)
				if lot.size.x > 0.0 and lot.size.y > 0.0:
					break
			if lot.size.x <= 0.0 or lot.size.y <= 0.0:
				# Shallow-lot fallback: full-depth parcels spill on small or
				# sharply curved faces; a half-depth house still fronts truly.
				for inset in [0.18, 0.55]:
					var shallow_center := edge_mid + inward * (float(inset) + depth * 0.275)
					lot = _fit_frontage_lot(shallow_center,
							Vector2(frontage_width, depth * 0.55), yaw, poly, inward)
					if lot.size.x > 0.0 and lot.size.y > 0.0:
						break
			if lot.size.x <= 0.0 or lot.size.y <= 0.0:
				continue
			if not _city_lot_has_valid_land(lot, yaw) or _near_rural_settlement(lot.get_center()):
				continue
			if _lot_overlaps_passage(lot, yaw, passage):
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
			# Boundary frontage is inset from the road ribbon. Store the
			# corresponding road point, not the inset polygon edge, so physical
			# frontage telemetry measures the same frontage the player sees.
			spec["frontage_center"] = nearest_point
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
	if _lot_overlaps_passage(lot, yaw, passage):
		return
	if _city_road_within_raw(center, 5.0) or not _lot_clear_of_city_roads(lot, yaw):
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
	# Conservative spatial broad phase; the final oriented intersection
	# predicate is unchanged. Rebuild only when the macro graph changes.
	if _road_query_edge_count != _city_edges.size():
		_road_query_bins.clear()
		var segment_id := 0
		for edge: Dictionary in _city_edges:
			var half_width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL)) * 0.5 + (0.25 if bool(edge.get("shared_surface", false)) else 0.8)
			var poly: PackedVector2Array = edge["polyline"]
			for i in range(poly.size() - 1):
				var segment_bounds := Rect2(poly[i], Vector2.ZERO).expand(poly[i + 1]).grow(half_width * 1.415 + 0.001)
				var segment := {"id": segment_id, "a": poly[i], "b": poly[i + 1], "half": half_width, "bounds": segment_bounds,
					"shared": bool(edge.get("shared_surface", false))}
				segment_id += 1
				for x in range(floori(segment_bounds.position.x / 64.0), floori(segment_bounds.end.x / 64.0) + 1):
					for z in range(floori(segment_bounds.position.y / 64.0), floori(segment_bounds.end.y / 64.0) + 1):
						var key := Vector2i(x, z)
						if not _road_query_bins.has(key):
							_road_query_bins[key] = []
						_road_query_bins[key].append(segment)
		_road_query_edge_count = _city_edges.size()
	var bounds := _oriented_rect_bounds(lot, yaw)
	var seen := {}
	for x in range(floori(bounds.position.x / 64.0), floori(bounds.end.x / 64.0) + 1):
		for z in range(floori(bounds.position.y / 64.0), floori(bounds.end.y / 64.0) + 1):
			for segment: Dictionary in _road_query_bins.get(Vector2i(x, z), []):
				if seen.has(segment.id):
					continue
				seen[segment.id] = true
				if (segment.bounds as Rect2).intersects(bounds, true) and _segment_intersects_oriented_lot(segment.a, segment.b, lot, yaw, segment.half):
					if bool(segment.shared):
						# The expanded-rectangle broad phase is not an exact road
						# collision test at oblique bends. Match block subtraction.
						var collision := false
						for overlap: PackedVector2Array in Geometry2D.intersect_polygons(_lot_corners(lot, yaw), _road_strip_polygon(segment.a, segment.b, segment.half)):
							if absf(_polygon_area(overlap)) > 0.01:
								collision = true
								break
						if not collision:
							continue
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
	if lot.size.x >= 9.0 and lot.size.y >= 12.0:
		var program_roll := rng.randf()
		if program_roll < 0.45:
			use = ["office", "workshop", "police", "hospital", "government"][rng.randi_range(0, 4)]
	var arch: StringName = &"shop_house" if use == "retail" else (&"tenement" if floors >= 4 else &"house")
	var spec := {
		"id": id,
		"seed_used": seed_used,
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
	var door := _door_manifest(id, lot, door_edge, seed_used)
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
	# Rotation-invariant broad phase. Distant parcels cannot overlap their
	# enclosing circles; avoid allocating corners and axes for every pair in
	# the city. The original separating-axis test remains authoritative nearby.
	var radius_a := (a.size * 0.5 + Vector2(margin, margin)).length()
	var radius_b := (b.size * 0.5 + Vector2(margin, margin)).length()
	if a.get_center().distance_squared_to(b.get_center()) > pow(radius_a + radius_b, 2):
		return false
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


static func _segment_intersects_oriented_lot(a: Vector2, b: Vector2, lot: Rect2,
		yaw: float, extra: float) -> bool:
	var center := lot.get_center()
	var local_a := _rotate_plan_point(center, a, -yaw) - center
	var local_b := _rotate_plan_point(center, b, -yaw) - center
	var half := lot.size * 0.5 + Vector2(extra, extra)
	return _clip_segment_to_rect(local_a, local_b,
			Rect2(-half, half * 2.0)).size() == 2


static func _spec_world_bounds(spec: Dictionary) -> Rect2:
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

func city_plots() -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for block: Dictionary in _blocks:
		for plot: Dictionary in block.get("plots", []):
			out.append(plot.duplicate(true))
	return out

func plots_owned_by(coord: Vector2i) -> Array[Dictionary]:
	_ensure_generated()
	var out: Array[Dictionary] = []
	for block: Dictionary in _blocks:
		for plot: Dictionary in block.get("plots", []):
			if plot.owner_chunk == coord:
				out.append(plot.duplicate(true))
	return out


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
	out._historic = _historic.duplicate(true)
	out._planar_graph = _planar_graph.duplicate(true)
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
	if not _historic.is_empty():
		if _planar_graph.is_empty():
			_planar_graph = UrbanBlocks.graph_manifest(_city_edges)
		return _planar_graph.duplicate(true)
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


## True when the nearest city road is within `limit` of p.
##
## PERF (2026-09-10): the block site-acceptance and lot-placement loops only
## ever need a THRESHOLD from this query, but they called
## _distance_to_city_road_raw(), which walks every point of every road edge to
## build a global minimum. At 1,200 site candidates x the whole network, twice,
## that measured ~49 s of CityPlan generation for the canonical seed - and plan
## generation is lazy, so that stall landed inside chunk streaming and surfaced
## as "owner chunk never returned" in the 60 s persistence gate.
##
## This predicate returns the same answer cheaper: far edges are rejected on a
## cached bounding box (O(1) each) and only edges that could be close enough
## have their polyline points examined, exiting on the first hit. Passing
## inclusive=true gives "d <= limit", so callers that need "d > limit" or
## "d >= limit" stay exactly equivalent.
func _city_road_within_raw(p: Vector2, limit: float, inclusive := false) -> bool:
	_ensure_city_edge_bounds()
	var limit2 := limit * limit
	for i in _city_edges.size():
		var b: Rect2 = _city_edge_bounds[i]
		# Distance from p to the edge's bounding box (0 when inside it).
		var dx := maxf(maxf(b.position.x - p.x, 0.0), p.x - b.position.x - b.size.x)
		var dy := maxf(maxf(b.position.y - p.y, 0.0), p.y - b.position.y - b.size.y)
		if dx * dx + dy * dy > limit2:
			continue
		var poly: PackedVector2Array = _city_edges[i]["polyline"] as PackedVector2Array
		var d := _distance_to_polyline(p, poly)
		if inclusive:
			if d <= limit:
				return true
		elif d < limit:
			return true
	return false


## Bounding boxes of every city road edge polyline, cached against the edge
## list. Rebuilt only when the network itself changes.
func _ensure_city_edge_bounds() -> void:
	if _city_edge_bounds.size() == _city_edges.size():
		return
	_city_edge_bounds.clear()
	for edge: Dictionary in _city_edges:
		var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
		if poly.is_empty():
			_city_edge_bounds.append(Rect2())
			continue
		var lo := poly[0]
		var hi := poly[0]
		for q: Vector2 in poly:
			lo.x = minf(lo.x, q.x)
			lo.y = minf(lo.y, q.y)
			hi.x = maxf(hi.x, q.x)
			hi.y = maxf(hi.y, q.y)
		_city_edge_bounds.append(Rect2(lo, hi - lo))


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
	# Index immutable world-space footprints once per private plan. Queries
	# retain the exact AABB predicate and stable ordering used by the scan.
	if _building_query_count != _all_buildings.size():
		_building_query_bins.clear()
		for i in _all_buildings.size():
			var bounds := _spec_world_bounds(_all_buildings[i])
			for x in range(floori(bounds.position.x / 64.0), floori(bounds.end.x / 64.0) + 1):
				for z in range(floori(bounds.position.y / 64.0), floori(bounds.end.y / 64.0) + 1):
					var key := Vector2i(x, z)
					if not _building_query_bins.has(key):
						_building_query_bins[key] = []
					_building_query_bins[key].append(i)
		_building_query_count = _all_buildings.size()
	var out: Array[Dictionary] = []
	var seen := {}
	var query_cell_count := (floori(rect.end.x / 64.0) - floori(rect.position.x / 64.0) + 1) \
		* (floori(rect.end.y / 64.0) - floori(rect.position.y / 64.0) + 1)
	if query_cell_count > maxi(16, _all_buildings.size()):
		for spec: Dictionary in _all_buildings:
			if _spec_world_bounds(spec).intersects(rect):
				out.append(spec)
		out.sort_custom(_dict_id_cmp)
		return out
	for x in range(floori(rect.position.x / 64.0), floori(rect.end.x / 64.0) + 1):
		for z in range(floori(rect.position.y / 64.0), floori(rect.end.y / 64.0) + 1):
			for i: int in _building_query_bins.get(Vector2i(x, z), []):
				if seen.has(i):
					continue
				seen[i] = true
				var spec: Dictionary = _all_buildings[i]
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
		var compound_a := str(buildings[i].get("compound_id", ""))
		# A historic compound is not one detached building per plot: its wings share
		# party walls and its service wings are genuinely narrow, so the generic
		# fabric rules (4 m minimum side, 0.15 m separation between buildings) do
		# not describe it. Compound wings are held to the building contract
		# minimums instead: a real side, a real area, and no true overlap.
		if compound_a != "":
			if a.size.x < WorldConstants.CONTRACT_MIN_FOOTPRINT_SIDE_M \
					or a.size.y < WorldConstants.CONTRACT_MIN_FOOTPRINT_SIDE_M \
					or a.get_area() < WorldConstants.CONTRACT_MIN_FOOTPRINT_AREA_M2:
				errors.append("invalid tiny compound wing %s (%.1f x %.1f)"
					% [buildings[i].get("id", ""), a.size.x, a.size.y])
		elif a.size.x < 4.0 or a.size.y < 4.0:
			errors.append("invalid tiny building %s" % buildings[i].get("id", ""))
		for j in range(i + 1, buildings.size()):
			var b: Rect2 = buildings[j].get("rect", Rect2()) as Rect2
			var compound_b := str(buildings[j].get("compound_id", ""))
			var margin := 0.15
			if compound_a != "" and compound_b != "":
				# Compound wings may share party walls, and neighbouring plots keep
				# their own 0.18 m gap (already guaranteed by the parcel allocator
				# at a 0.03 m margin). What must never happen is a real overlap.
				margin = -0.02
			if _lots_overlap(a, float(buildings[i].get("yaw", 0.0)), b,
					float(buildings[j].get("yaw", 0.0)), margin):
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
static func _door_manifest(building_id: String, lot: Rect2, edge: int, explicit_seed: Variant = null) -> Dictionary:
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
	# Instance plans must not inherit the currently selected world's hinge
	# roll when a different seed is inspected or regenerated beside them.
	var door_seed: int = WorldSeed.get_world_seed() if explicit_seed == null else int(explicit_seed)
	var hinge_left := float(WorldSeed.combine([door_seed, WorldSeed.str_hash("hinge"),
		WorldSeed.str_hash(building_id)]) % 1000003) / 1000003.0 < 0.5
	return {
		"id": "%s_door_0" % building_id,
		"building_id": building_id,
		"position": Vector3(mid.x, 0.0, mid.y),
		"yaw": yaw,
		"edge": edge,
		"width": DOOR_W,
		"height": WorldConstants.DOOR_H_PERSON,
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
	var nearest := _nearest_point_on_polyline(p, poly)
	if nearest == Vector2.INF:
		return INF
	return p.distance_to(nearest)


static func _nearest_point_on_polyline(p: Vector2, poly: PackedVector2Array) -> Vector2:
	if poly.size() < 2:
		return Vector2.INF
	var best := Vector2.INF
	var best_d2 := INF
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
