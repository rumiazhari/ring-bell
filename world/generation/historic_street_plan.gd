class_name HistoricStreetPlan
extends RefCounted
## Planar historic streets inside a finite transition boundary. Site spacing
## expresses settlement accretion; the streets are shared cell boundaries,
## and UrbanBlockPlan independently recovers their actual enclosed faces.
const BlockPlan = preload("res://world/generation/urban_block_plan.gd")
const RADIUS := 340.0
const SITE_CAP := 58

static func unit(seed: int, domain: String, parts: Array = []) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(domain)] + parts) % 1000003) / 1000003.0

static func generate(seed: int, outer_edges: Array, landmarks: Array) -> Dictionary:
	var boundary := PackedVector2Array()
	for i in 16:
		var angle := TAU * float(i) / 16.0
		var radius := RADIUS + 9.0 * sin(angle * 3.0 + unit(seed, "historic_extent") * TAU)
		boundary.append(Vector2(cos(angle), sin(angle)) * radius)
	var sites: Array[Vector2] = []
	var site_landmarks := {}
	for lm: Dictionary in landmarks:
		if str(lm.kind) in ["market_square", "civic_square"] and (lm.center as Vector2).length() < 280.0:
			site_landmarks[sites.size()] = str(lm.id)
			sites.append(lm.center)
	var angle := unit(seed, "historic_grain") * TAU
	var axis := Vector2(cos(angle), sin(angle))
	var cross_axis := Vector2(-axis.y, axis.x)
	# Anisotropic distance encourages elongated plots/blocks without an X/Z
	# grid. Accepted sites have variable exclusion radii and a seed-wide grain.
	for i in 1600:
		if sites.size() >= SITE_CAP:
			break
		var theta := unit(seed, "historic_site_angle", [i]) * TAU
		var radius := sqrt(unit(seed, "historic_site_radius", [i])) * (RADIUS - 12.0)
		var p := Vector2(cos(theta), sin(theta)) * radius
		var separation := lerpf(48.0, 72.0, unit(seed, "historic_site_spacing", [i]))
		var valid := true
		for old in sites:
			var delta := p - old
			var metric := Vector2(delta.dot(axis) * 1.25, delta.dot(cross_axis) * 0.8)
			if metric.length() < separation:
				valid = false
				break
		if valid:
			sites.append(p)
	var edges: Array[Dictionary] = []
	var edge_ids := {}
	var public_spaces: Array[Dictionary] = []
	for i in sites.size():
		var poly := boundary.duplicate()
		var sp := Vector2(sites[i].dot(axis) * 1.25, sites[i].dot(cross_axis) * 0.8)
		for j in sites.size():
			if i == j:
				continue
			var op := Vector2(sites[j].dot(axis) * 1.25, sites[j].dot(cross_axis) * 0.8)
			var delta := op - sp
			var normal := axis * delta.x * 1.25 + cross_axis * delta.y * 0.8
			poly = clip_halfplane(poly, normal, (op.length_squared() - sp.length_squared()) * 0.5)
			if poly.size() < 3:
				break
		if site_landmarks.has(i):
			public_spaces.append({"id": site_landmarks[i], "polygon": poly, "center": sites[i],
				"kind": &"market_square" if site_landmarks[i] == "market_square" else &"church_forecourt"})
		for k in poly.size():
			var a := poly[k].snapped(Vector2.ONE * 0.001)
			var b := poly[(k + 1) % poly.size()].snapped(Vector2.ONE * 0.001)
			if a.distance_to(b) < 1.0:
				continue
			var id := edge_id(a, b)
			if edge_ids.has(id):
				continue
			edge_ids[id] = true
			var roll := unit(seed, "historic_street_class", [WorldSeed.str_hash(id)])
			var width: float
			var hierarchy: StringName
			if roll < 0.30:
				width = lerpf(3.5, 5.5, roll / 0.30)
				hierarchy = &"alley"
			elif roll < 0.75:
				width = lerpf(5.5, 8.0, (roll - 0.30) / 0.45)
				hierarchy = &"local"
			elif roll < 0.95:
				width = lerpf(8.0, 11.0, (roll - 0.75) / 0.20)
				hierarchy = &"secondary"
			else:
				width = lerpf(12.0, 16.0, (roll - 0.95) / 0.05)
				hierarchy = &"primary"
			var ab := b - a
			var perp := Vector2(-ab.y, ab.x).normalized()
			var bend := (unit(seed, "historic_street_bend", [WorldSeed.str_hash(id)]) - 0.5) * minf(2.6, ab.length() * 0.045)
			edges.append(road(id, PackedVector2Array([a, (a + b) * 0.5 + perp * bend, b]), width, hierarchy))
		if not site_landmarks.has(i) and unit(seed, "historic_blind_lane", [i]) < 0.24:
			var best := 0
			for k in poly.size():
				if poly[k].distance_to(poly[(k + 1) % poly.size()]) > poly[best].distance_to(poly[(best + 1) % poly.size()]):
					best = k
			var a := poly[best].snapped(Vector2.ONE * 0.001)
			var b := poly[(best + 1) % poly.size()].snapped(Vector2.ONE * 0.001)
			var source_id := edge_id(a, b)
			var start := (a + b) * 0.5
			for existing: Dictionary in edges:
				if existing.id == source_id:
					start = existing.polyline[1]
					break
			var end := start.move_toward(sites[i], minf(18.0, start.distance_to(sites[i]) * 0.55))
			if start.distance_to(end) >= 7.0:
				edges.append(road("historic_blind_%d" % i, PackedVector2Array([start, end]), 3.8, &"alley"))
	# Keep the exterior of every existing route, split at the exact transition
	# polygon. The planarizer joins these boundary endpoints to the perimeter.
	for original: Dictionary in outer_edges:
		var line: PackedVector2Array = original.polyline
		var run := PackedVector2Array()
		var run_index := 0
		for i in range(line.size() - 1):
			var a := line[i]
			var b := line[i + 1]
			var cuts: Array[float] = [0.0, 1.0]
			for k in boundary.size():
				var hit: Variant = Geometry2D.segment_intersects_segment(a, b, boundary[k], boundary[(k + 1) % boundary.size()])
				if hit != null:
					cuts.append(a.distance_to(hit) / maxf(a.distance_to(b), 0.001))
			cuts.sort()
			for k in range(cuts.size() - 1):
				var p := a.lerp(b, cuts[k])
				var q := a.lerp(b, cuts[k + 1])
				if p.distance_to(q) < 0.01:
					continue
				if Geometry2D.is_point_in_polygon((p + q) * 0.5, boundary):
					if run.size() >= 2:
						append_run(edges, original, run, run_index)
						run_index += 1
					run = PackedVector2Array()
					continue
				if run.is_empty():
					run.append(p)
				run.append(q)
		if run.size() >= 2:
			append_run(edges, original, run, run_index)
	edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	return {"edges": edges, "public_spaces": public_spaces, "boundary": boundary}

static func append_run(edges: Array[Dictionary], original: Dictionary, line: PackedVector2Array, index: int) -> void:
	var edge := original.duplicate(true)
	edge.id = "%s_ext_%d" % [original.id, index]
	edge.polyline = line
	edge.a_center = line[0]
	edge.b_center = line[-1]
	edge.length = 0.0
	for i in range(line.size() - 1):
		edge.length += line[i].distance_to(line[i + 1])
	edges.append(edge)

static func edge_id(a: Vector2, b: Vector2) -> String:
	var aa := "%d_%d" % [roundi(a.x * 1000.0), roundi(a.y * 1000.0)]
	var bb := "%d_%d" % [roundi(b.x * 1000.0), roundi(b.y * 1000.0)]
	return "historic_%s__%s" % [aa, bb] if aa < bb else "historic_%s__%s" % [bb, aa]

static func road(id: String, line: PackedVector2Array, width: float, hierarchy: StringName) -> Dictionary:
	return {"id": id, "a": id + "a", "b": id + "b", "polyline": line,
		"a_center": line[0], "b_center": line[-1], "length": line[0].distance_to(line[-1]),
		"width": width, "hierarchy": hierarchy, "is_bridge": false,
		"water_id": "", "crossing_id": "", "max_slope_deg": 0.0,
		"river_clearance_m": 100.0, "influence": &"historic_fabric", "influences": [&"historic_fabric"],
		"surface": &"cobble" if hierarchy == &"alley" else &"stone_setts", "shared_surface": true}

static func clip_halfplane(poly: PackedVector2Array, normal: Vector2, limit: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var da := a.dot(normal) - limit
		var db := b.dot(normal) - limit
		if da <= 0.00001:
			out.append(a)
		if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
			out.append(a.lerp(b, da / (da - db)))
	return out
