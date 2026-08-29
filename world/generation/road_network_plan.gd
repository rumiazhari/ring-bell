class_name RoadNetworkPlan
extends RefCounted
## Pure hierarchical road network: MST + sparse loops, hydrology-constrained.
## Reads TerrainPlan, HydrologyPlan, BiomePlan, GeologyPlan, SettlementPlan.
## No Node access, no unseeded randomness, no chunk-local state.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var _nodes: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _graph_cache: Dictionary = {}
var _generated: bool = false

static var _graph_static_cache: Dictionary = {} # seed -> {nodes, edges}

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null, settlement_plan: SettlementPlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)
	biome = biome_plan if biome_plan != null else BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = settlement_plan if settlement_plan != null else SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	if _graph_static_cache.has(seed_used):
		var cached: Dictionary = _graph_static_cache[seed_used] as Dictionary
		_nodes = (cached.get("nodes", []) as Array[Dictionary]).duplicate()
		_edges = (cached.get("edges", []) as Array[Dictionary]).duplicate()
		_graph_cache = {"nodes": _nodes.duplicate(), "edges": _edges.duplicate()}
		_generated = true
		return
	_generate_graph()

func _generate_graph() -> void:
	if _generated:
		return
	_generated = true
	var t_gen_start := Time.get_ticks_msec()
	var anchors: Array[Dictionary] = settlement.settlement_anchors()
	var gates: Array[Dictionary] = settlement.city_gates()
	# Build crossing nodes
	var crossing_nodes: Array[Dictionary] = []
	var world_rect := Rect2(Vector2(WorldConstants.WORLD_MIN_M, WorldConstants.WORLD_MIN_M), Vector2(WorldConstants.WORLD_SIZE_M, WorldConstants.WORLD_SIZE_M))
	var all_crossings: Array[Dictionary] = hydrology.crossing_candidates(world_rect)
	var t_cross := Time.get_ticks_msec()
	# Filter by proximity 480 to any settlement or gate
	var gate_centers: Array[Vector2] = []
	for g in gates:
		gate_centers.append(g["center"] as Vector2)
	var anchor_centers: Array[Vector2] = []
	for a in anchors:
		anchor_centers.append(a["center"] as Vector2)
	var kept_crossings: Array[Dictionary] = []
	for c in all_crossings:
		var c_center: Vector2 = c["center"] as Vector2
		var min_d := INF
		for p in anchor_centers:
			var d := c_center.distance_to(p)
			if d < min_d:
				min_d = d
		for p in gate_centers:
			var d := c_center.distance_to(p)
			if d < min_d:
				min_d = d
		if min_d <= 480.0:
			kept_crossings.append(c)
	# Limit to maybe 10 strongest by proximity or center.y sorted for determinism
	kept_crossings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da := INF; var db := INF
		for p in anchor_centers:
			da = minf(da, (a["center"] as Vector2).distance_to(p))
			db = minf(db, (b["center"] as Vector2).distance_to(p))
		if not is_equal_approx(da, db):
			return da < db
		return String(a["id"]) < String(b["id"])
	)
	if kept_crossings.size() > 9:
		kept_crossings = kept_crossings.slice(0, 9)
	var t_filter := Time.get_ticks_msec()
	for c in kept_crossings:
		var cid: String = "crossing_%s" % String(c["id"])
		crossing_nodes.append({
			"id": cid,
			"center": c["center"] as Vector2,
			"position": c["center"] as Vector2,
			"kind": &"crossing",
			"radius": 12.0,
			"width": float(c["width"]),
			"water_id": String(c["water_id"]),
			"crossing_id": String(c["id"]),
			"axis": c["axis"] as Vector2,
		})
	# Build nodes list
	_nodes.clear()
	for a in anchors:
		_nodes.append({
			"id": String(a["id"]),
			"center": a["center"] as Vector2,
			"position": a["center"] as Vector2,
			"kind": a["kind"] as StringName,
			"radius": float(a["radius"]),
		})
	for g in gates:
		_nodes.append({
			"id": String(g["id"]),
			"center": g["center"] as Vector2,
			"position": g["center"] as Vector2,
			"kind": &"city_gate",
			"radius": float(g["radius"]),
			"angle": float(g["angle"]),
		})
	for cn in crossing_nodes:
		_nodes.append(cn)
	# If nodes empty (should not), add dummy
	if _nodes.is_empty():
		return
	# Build all pair edges (limited by dist <5000) with fast 5-sample penalties
	var edge_candidates: Array[Dictionary] = []
	for i in _nodes.size():
		for j in range(i+1, _nodes.size()):
			var na: Dictionary = _nodes[i]
			var nb: Dictionary = _nodes[j]
			var ka: StringName = na["kind"] as StringName
			var kb: StringName = nb["kind"] as StringName
			if ka == &"crossing" and kb == &"crossing":
				continue
			var a: Vector2 = na["center"] as Vector2
			var b: Vector2 = nb["center"] as Vector2
			var dist: float = a.distance_to(b)
			if dist < 1e-3 or dist > 10000.0:
				continue
			var slope_pen: float = _slope_penalty(a, b)
			var water_pen: float = _water_penalty(a, b, crossing_nodes)
			var forest_pen: float = _forest_penalty(a, b)
			var weight: float = dist * (1.0 + 0.25 * slope_pen + 0.30 * water_pen + 0.10 * forest_pen)
			var edge_id: String = "edge_%s_%s" % [String(na["id"]), String(nb["id"])]
			if String(na["id"]) > String(nb["id"]):
				edge_id = "edge_%s_%s" % [String(nb["id"]), String(na["id"])]
			edge_candidates.append({
				"id": edge_id,
				"a": String(na["id"]),
				"b": String(nb["id"]),
				"a_center": a,
				"b_center": b,
				"a_kind": ka,
				"b_kind": kb,
				"dist": dist,
				"weight": weight,
				"slope_pen": slope_pen,
				"water_pen": water_pen,
				"forest_pen": forest_pen,
			})
	# Stable sort by weight then id
	edge_candidates.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if not is_equal_approx(float(x["weight"]), float(y["weight"])):
			return float(x["weight"]) < float(y["weight"])
		return String(x["id"]) < String(y["id"])
	)
	# Kruskal MST
	var parent := {}
	for n in _nodes:
		parent[String(n["id"])] = String(n["id"])
	# iterative find with path compression
	var mst_edges: Array[Dictionary] = []
	for cand in edge_candidates:
		var a_id: String = String(cand["a"])
		var b_id: String = String(cand["b"])
		# find root of a
		var ra: String = a_id
		while parent[ra] != ra:
			ra = parent[ra]
		# path compression for a
		var cur_a: String = a_id
		while parent[cur_a] != ra:
			var nxt: String = parent[cur_a]
			parent[cur_a] = ra
			cur_a = nxt
		# find root of b
		var rb: String = b_id
		while parent[rb] != rb:
			rb = parent[rb]
		var cur_b: String = b_id
		while parent[cur_b] != rb:
			var nxt2: String = parent[cur_b]
			parent[cur_b] = rb
			cur_b = nxt2
		if ra != rb:
			# union
			parent[ra] = rb
			mst_edges.append(cand)
			if mst_edges.size() >= _nodes.size() - 1:
				break
	# If graph disconnected (due to pruning), keep as is but we need to ensure every village/hamlet connected to gate; our MST should already connect all that are reachable
	# Add extra loops 1-3
	var extra_edges: Array[Dictionary] = []
	# Build adjacency for current MST for path length queries
	var adj := {}
	for n in _nodes:
		adj[String(n["id"])] = []
	for e in mst_edges:
		var aid: String = String(e["a"])
		var bid: String = String(e["b"])
		adj[aid].append({"to": bid, "dist": float(e["dist"]), "edge": e})
		adj[bid].append({"to": aid, "dist": float(e["dist"]), "edge": e})
	# For each non-MST candidate sorted by weight, check if it shortens detour >22%
	for cand in edge_candidates:
		if mst_edges.has(cand):
			continue
		if extra_edges.size() >= 8:
			break
		var aid: String = String(cand["a"])
		var bid: String = String(cand["b"])
		# Find shortest path distance in MST between aid and bid via BFS/Dijkstra (since weights are dist, use Dijkstra)
		var path_len := _shortest_path_len(adj, aid, bid)
		if path_len == INF or path_len <= 0.0:
			continue
		var direct: float = float(cand["dist"])
		# If direct shortens detour by >10% (instead of 22) to increase density
		if direct < path_len * 0.90:
			# Also check water penalty: if this extra edge would cross water outside corridor without bridge, skip
			var a: Vector2 = cand["a_center"] as Vector2
			var b: Vector2 = cand["b_center"] as Vector2
			var water_cross := _segment_crosses_water_outside_corridor(a, b, crossing_nodes)
			if water_cross:
				# check if near crossing? already penalized, but for extra edge we require not outside corridor
				continue
			extra_edges.append(cand)
			# add to adj for subsequent extra checks
			adj[aid].append({"to": bid, "dist": direct, "edge": cand})
			adj[bid].append({"to": aid, "dist": direct, "edge": cand})
	# Combine mst + extra
	var final_edge_candidates: Array[Dictionary] = []
	final_edge_candidates.append_array(mst_edges)
	final_edge_candidates.append_array(extra_edges)
	# Now generate geometry for each final edge and assign hierarchy
	_edges.clear()
	for cand in final_edge_candidates:
		var a: Vector2 = cand["a_center"] as Vector2
		var b: Vector2 = cand["b_center"] as Vector2
		var aid: String = String(cand["a"])
		var bid: String = String(cand["b"])
		var ka: StringName = cand["a_kind"] as StringName
		var kb: StringName = cand["b_kind"] as StringName
		# Determine hierarchy
		var hier: StringName = &"track"
		var is_gate_a: bool = ka == &"city_gate"
		var is_gate_b: bool = kb == &"city_gate"
		var is_village_a: bool = ka == &"village"
		var is_village_b: bool = kb == &"village"
		var is_hamlet_a: bool = ka == &"hamlet"
		var is_hamlet_b: bool = kb == &"hamlet"
		var is_crossing_a: bool = ka == &"crossing"
		var is_crossing_b: bool = kb == &"crossing"
		if (is_gate_a or is_gate_b):
			var other_kind: StringName = kb if is_gate_a else ka
			if other_kind == &"village" or other_kind == &"crossing":
				hier = &"primary"
			elif other_kind == &"hamlet":
				hier = &"secondary"
			else:
				hier = &"track"
		elif (is_village_a and is_hamlet_b) or (is_village_b and is_hamlet_a) or (is_village_a and is_village_b):
			hier = &"secondary"
		elif (ka == &"hamlet" and kb == &"farmstead") or (ka == &"farmstead" and kb == &"hamlet") or (ka == &"farmstead" and kb == &"farmstead") or (ka == &"isolated_farm" or kb == &"isolated_farm"):
			hier = &"track"
		elif is_crossing_a or is_crossing_b:
			# edge involving crossing and village/hamlet etc: determine by other
			var other2: StringName = kb if is_crossing_a else ka
			if other2 == &"village" or other2 == &"city_gate":
				hier = &"primary"
			elif other2 == &"hamlet":
				hier = &"secondary"
			else:
				hier = &"track"
		else:
			hier = &"track"
		# Width
		var width: float = 3.5
		match hier:
			&"primary":
				width = WorldConstants.ROAD_WIDTH_PRIMARY
			&"secondary":
				width = WorldConstants.ROAD_WIDTH_SECONDARY
			&"track":
				width = WorldConstants.ROAD_WIDTH_TRACK
		# Generate polyline
		var edge_id: String = String(cand["id"])
		var poly := _generate_polyline(a, b, edge_id)
		if poly.size() < 2:
			continue
		# Check water crossing outside corridor: if poly crosses water outside corridor, drop edge (rather than cutting water)
		var crosses_outside := false
		var is_bridge := false
		var bridge_water_id := ""
		var bridge_crossing_id := ""
		# Sample every 2nd point plus endpoints for efficiency; river width 38-50 ensures detection
		var sample_step := maxi(1, poly.size() / 12)
		for idx in range(0, poly.size(), sample_step):
			var pt: Vector2 = poly[idx]
			var body: StringName = hydrology.water_body_at(pt)
			if body != &"":
				# Check near crossing
				var near := false
				for cn in crossing_nodes:
					var c_center: Vector2 = cn["center"] as Vector2
					var c_width: float = float(cn["width"])
					if pt.distance_to(c_center) < c_width * 0.5 + 40.0:
						near = true
						bridge_water_id = String(cn["water_id"])
						bridge_crossing_id = String(cn["crossing_id"])
						break
				if not near:
					# Check if hydrology distance indicates water crossing: distance_to_water <0 for inside, but we already have body != ""
					# So this is outside crossing corridor
					crosses_outside = true
					break
				else:
					is_bridge = true
		# Also check last point if not sampled
		if not crosses_outside and not is_bridge and poly.size() > 0:
			var last_pt: Vector2 = poly[poly.size()-1]
			if hydrology.water_body_at(last_pt) != &"":
				var near_last := false
				for cn in crossing_nodes:
					if last_pt.distance_to(cn["center"] as Vector2) < float(cn["width"]) * 0.5 + 40.0:
						near_last = true
						bridge_water_id = String(cn["water_id"])
						bridge_crossing_id = String(cn["crossing_id"])
						break
				if not near_last:
					crosses_outside = true
				else:
					is_bridge = true
		if crosses_outside:
			# Try to see if edge is between two crossings? Should not; but drop
			# If edge is bridge-eligible (is_bridge) we keep, else drop
			# For outside, drop edge
			continue
		# Also slope check: any subsegment average slope >= CLIFF_SLOPE_DEG -> drop/reroute via nearby crossing within 420 else drop
		var slope_violation := false
		for i in range(0, poly.size()-1, 2):
			var p0: Vector2 = poly[i]
			var p1: Vector2 = poly[mini(i+1, poly.size()-1)]
			var midp := (p0 + p1) * 0.5
			var slope: float = terrain.slope_at(midp)
			if slope >= WorldConstants.CLIFF_SLOPE_DEG - 1e-6:
				slope_violation = true
				break
		if slope_violation:
			# Try reroute: if there is crossing within 420 of mid, we could reroute, but for now drop edge if no crossing near
			var mid_edge := (a + b) * 0.5
			var near_crossing_for_reroute := false
			for cn in crossing_nodes:
				if mid_edge.distance_to(cn["center"] as Vector2) < 420.0:
					near_crossing_for_reroute = true
					break
			if not near_crossing_for_reroute:
				# Check if edge is essential for connectivity: if we drop, graph may disconnect but we already penalized cliffs so maybe okay to drop
				continue
			else:
				# For now, keep but mark; future reroute would split via crossing, but we keep original
				pass
		var length: float = 0.0
		for i in range(poly.size()-1):
			length += poly[i].distance_to(poly[i+1])
		# Bridge specifics: if is_bridge, deck length = water width + 2*4, deck width = road width +0.6 (handled in builder)
		_edges.append({
			"id": edge_id,
			"a": aid,
			"b": bid,
			"hierarchy": hier,
			"width": width,
			"length": length,
			"polyline": poly,
			"is_bridge": is_bridge,
			"water_id": bridge_water_id,
			"crossing_id": bridge_crossing_id,
			"a_center": a,
			"b_center": b,
		})
	# Final graph cache
	_edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_bridge: bool = bool(a["is_bridge"])
		var b_bridge: bool = bool(b["is_bridge"])
		if a_bridge != b_bridge:
			return a_bridge and not b_bridge
		var a_primary: bool = String(a["hierarchy"]) == "primary"
		var b_primary: bool = String(b["hierarchy"]) == "primary"
		if a_primary != b_primary:
			return a_primary and not b_primary
		return float(a["length"]) > float(b["length"])
	)
	_graph_cache = {"nodes": _nodes.duplicate(), "edges": _edges.duplicate()}
	_graph_static_cache[seed_used] = {"nodes": _nodes.duplicate(), "edges": _edges.duplicate()}
	var t_end := Time.get_ticks_msec()
	# Only print for first generation per seed to avoid spam
	if _graph_static_cache.size() <= 5:
		print("[RoadGen] seed %d total %d ms nodes %d edges %d (cross %d filter %d)" % [seed_used, t_end - t_gen_start, _nodes.size(), _edges.size(), t_cross - t_gen_start, t_filter - t_cross])

func _slope_penalty(a: Vector2, b: Vector2) -> float:
	var mid := (a + b) * 0.5
	var slope: float = terrain.slope_at(mid)
	return clampf((slope - 8.0) / 14.0, 0.0, 1.0)

func _forest_penalty(a: Vector2, b: Vector2) -> float:
	var mid := (a + b) * 0.5
	return 1.0 if biome.is_forest(mid) else 0.0

func _water_penalty(a: Vector2, b: Vector2, crossing_nodes: Array[Dictionary]) -> float:
	var mid := (a + b) * 0.5
	var crosses := hydrology.water_body_at(mid) != &"" or hydrology.distance_to_water(mid) < -0.5
	if not crosses:
		return 0.0
	# Check if near crossing corridor
	for cn in crossing_nodes:
		var c_center: Vector2 = cn["center"] as Vector2
		# Distance from center to segment a-b
		var seg_dist := _point_to_segment_distance(c_center, a, b)
		var c_width: float = float(cn["width"])
		if seg_dist < c_width * 0.5 + 60.0:
			return 0.15 # small penalty if near crossing
	return 5.0 # large penalty

func _point_to_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var ap := p - a
	var t: float = ap.dot(ab) / maxf(ab.length_squared(), 1e-6)
	t = clampf(t, 0.0, 1.0)
	var proj := a + ab * t
	return p.distance_to(proj)

func _segment_crosses_water_outside_corridor(a: Vector2, b: Vector2, crossing_nodes: Array[Dictionary]) -> bool:
	var steps := int(a.distance_to(b) / 32.0) + 1
	for i in steps:
		var t := float(i) / float(steps-1) if steps >1 else 0.0
		var p := a.lerp(b, t)
		if hydrology.water_body_at(p) != &"":
			var near := false
			for cn in crossing_nodes:
				if p.distance_to(cn["center"] as Vector2) < float(cn["width"]) * 0.5 + 40.0:
					near = true
					break
			if not near:
				return true
	return false

func _shortest_path_len(adj: Dictionary, start: String, goal: String) -> float:
	if start == goal:
		return 0.0
	var dist := {}
	var visited := {}
	for k in adj.keys():
		dist[k] = INF
	dist[start] = 0.0
	# simple Dijkstra with array (small graph)
	var queue: Array[String] = [start]
	while not queue.is_empty():
		# pick min dist
		var u: String = queue[0]
		var best := INF
		for cand in queue:
			if dist[cand] < best:
				best = dist[cand]
				u = cand
		queue.erase(u)
		if visited.has(u):
			continue
		visited[u] = true
		if u == goal:
			break
		for edge in adj.get(u, []):
			var v: String = String(edge["to"])
			var w: float = float(edge["dist"])
			var nd: float = dist[u] + w
			if nd < dist.get(v, INF) - 1e-6:
				dist[v] = nd
				if not queue.has(v):
					queue.append(v)
	return dist.get(goal, INF)

func _generate_polyline(a: Vector2, b: Vector2, edge_id: String) -> PackedVector2Array:
	var mid_base := (a + b) * 0.5
	var ab := b - a
	var length: float = ab.length()
	if length < 1e-3:
		var arr := PackedVector2Array()
		arr.append(a)
		arr.append(b)
		return arr
	var perp := Vector2(-ab.y, ab.x).normalized()
	var offset_scale: float = clampf(length * 0.08, 6.0, 28.0)
	# Deterministic offset via sample_coherent_signed at mid_base with seed
	var off1: float = WorldSeed.sample_coherent_signed(mid_base, &"road_mid", 300.0, seed_used) * offset_scale
	# second nudge
	var off2: float = WorldSeed.sample_coherent(mid_base + Vector2(77, 77), &"road_mid", 300.0, seed_used) * 4.0 - 2.0
	var mid := mid_base + perp * (off1 + off2 * 0.25)
	var n: int = maxi(2, int(length / WorldConstants.ROAD_SMOOTH_SAMPLE_M) + 2)
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var t: float = float(i) / float(n-1)
		var u: float = 1.0 - t
		var pt := u*u*a + 2.0*u*t*mid + t*t*b
		out[i] = pt
	return out

# --- Public queries ---

func road_graph() -> Dictionary:
	return {"nodes": _nodes.duplicate(), "edges": _edges.duplicate()}

func road_segments_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _edges:
		var poly: PackedVector2Array = e["polyline"] as PackedVector2Array
		var clipped := _clip_polyline_to_rect(poly, rect)
		if clipped.size() < 2:
			continue
		var center := (clipped[0] + clipped[clipped.size()-1]) * 0.5
		# Also compute midpoint for generic center
		var seg_dict: Dictionary = {
			"id": e["id"],
			"a": e["a"],
			"b": e["b"],
			"hierarchy": e["hierarchy"],
			"width": float(e["width"]),
			"length": float(e["length"]),
			"polyline": poly,
			"polyline_clipped": clipped,
			"is_bridge": bool(e["is_bridge"]),
			"water_id": String(e["water_id"]),
			"crossing_id": String(e["crossing_id"]),
			"center": center,
			"has_bridge": bool(e["is_bridge"]),
		}
		out.append(seg_dict)
	# For deterministic shuffled test: order by id
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	return out

func _clip_polyline_to_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	if poly.size() < 2:
		return PackedVector2Array()
	var result := PackedVector2Array()
	# Use segment clipping per edge segment
	for i in range(poly.size()-1):
		var p0: Vector2 = poly[i]
		var p1: Vector2 = poly[i+1]
		var clipped_seg := _clip_segment_to_rect(p0, p1, rect)
		if clipped_seg.size() == 2:
			var c0: Vector2 = clipped_seg[0]
			var c1: Vector2 = clipped_seg[1]
			if result.is_empty():
				result.append(c0)
				result.append(c1)
			else:
				# Avoid duplicate points
				if result[result.size()-1].is_equal_approx(c0):
					result.append(c1)
				else:
					# disjoint segments (polyline may have gap outside rect, but we treat as separate? For road chunk we want contiguous clipped portion; if gap, start new? But for simplicity append with gap
					# If last point not equal to c0, we have a gap, but road is continuous outside rect, so the clipped should be discontinuous outside rect, but we keep both pieces as separate? However chunk builder expects one polyline_clipped per edge that is contiguous inside rect. If polyline leaves and re-enters, it would be two pieces, but roads shouldn't zigzag that much.
					# We'll append c0 and c1 as new segment, merging if needed
					result.append(c0)
					result.append(c1)
	return result

func _clip_segment_to_rect(p0: Vector2, p1: Vector2, rect: Rect2) -> PackedVector2Array:
	var inside0 := rect.has_point(p0)
	var inside1 := rect.has_point(p1)
	if inside0 and inside1:
		var arr := PackedVector2Array()
		arr.append(p0)
		arr.append(p1)
		return arr
	# Liang-Barsky
	var dx := p1.x - p0.x
	var dy := p1.y - p0.y
	var t0: float = 0.0
	var t1: float = 1.0
	var x_min := rect.position.x
	var y_min := rect.position.y
	var x_max := rect.end.x
	var y_max := rect.end.y
	var p_vals := [-dx, dx, -dy, dy]
	var q_vals := [p0.x - x_min, x_max - p0.x, p0.y - y_min, y_max - p0.y]
	for k in 4:
		var pk: float = p_vals[k]
		var qk: float = q_vals[k]
		if is_equal_approx(pk, 0.0):
			if qk < 0.0:
				return PackedVector2Array() # parallel outside
		else:
			var t: float = qk / pk
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
	var c0 := p0 + Vector2(dx, dy) * t0
	var c1 := p0 + Vector2(dx, dy) * t1
	var arr2 := PackedVector2Array()
	arr2.append(c0)
	arr2.append(c1)
	return arr2

func road_hierarchy_at(p: Vector2) -> StringName:
	var best_hier: StringName = &""
	var best_dist := INF
	var best_width: float = 0.0
	for e in _edges:
		var poly: PackedVector2Array = e["polyline"] as PackedVector2Array
		var w: float = float(e["width"])
		var d: float = _distance_to_polyline(p, poly)
		if d < best_dist:
			best_dist = d
			best_hier = e["hierarchy"] as StringName
			best_width = w
	if best_dist == INF:
		return &""
	if best_dist > best_width * 0.6 + 1.2:
		return &""
	return best_hier

func distance_to_road(p: Vector2) -> float:
	var best := INF
	for e in _edges:
		var poly: PackedVector2Array = e["polyline"] as PackedVector2Array
		var d: float = _distance_to_polyline(p, poly)
		if d < best:
			best = d
	return best

func nearest_crossing(p: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for e in _edges:
		if bool(e["is_bridge"]):
			var center: Vector2 = (e["a_center"] as Vector2 + e["b_center"] as Vector2) * 0.5
			# Use polyline midpoint instead? Use edge center
			var d: float = p.distance_to(center)
			if d < best_d:
				best_d = d
				best = {
					"id": String(e["crossing_id"]),
					"center": center,
					"width": float(e["width"]),
					"water_id": String(e["water_id"]),
					"axis": Vector2(1,0),
				}
	# Also consider crossing nodes directly
	for n in _nodes:
		if String(n["kind"]) == "crossing":
			var c: Vector2 = n["center"] as Vector2
			var d := p.distance_to(c)
			if d < best_d:
				best_d = d
				best = {
					"id": String(n["crossing_id"]),
					"center": c,
					"width": float(n["width"]),
					"water_id": String(n["water_id"]),
					"axis": n.get("axis", Vector2(1,0)) as Vector2,
				}
	return best

func road_width_at(p: Vector2) -> float:
	var best_w: float = 0.0
	var best_d := INF
	var best_hier: StringName = &""
	for e in _edges:
		var poly: PackedVector2Array = e["polyline"] as PackedVector2Array
		var w: float = float(e["width"])
		var d: float = _distance_to_polyline(p, poly)
		if d < best_d:
			best_d = d
			best_w = w
			best_hier = e["hierarchy"] as StringName
	if best_d == INF:
		return 0.0
	if best_d > best_w * 0.6 + 1.2:
		return 0.0
	return best_w

func _distance_to_polyline(p: Vector2, poly: PackedVector2Array) -> float:
	if poly.size() < 2:
		return INF
	var best := INF
	for i in range(poly.size()-1):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[i+1]
		var d: float = _point_to_segment_distance(p, a, b)
		if d < best:
			best = d
	return best
