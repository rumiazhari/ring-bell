class_name UrbanBlockPlan
extends RefCounted
## Bounded faces of a planar street graph. Crossings are real graph vertices;
## dead ends remain streets but cannot manufacture an independent block.
## Input and output contain only world-coordinate plan data.

const SNAP := 0.001

static func build(edges: Array) -> Dictionary:
	var segments: Array[Dictionary] = []
	var ordered := edges.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.id) < str(b.id))
	for edge: Dictionary in ordered:
		var line: PackedVector2Array = edge["polyline"]
		for i in range(line.size() - 1):
			if line[i].distance_to(line[i + 1]) < SNAP:
				continue
			segments.append({"a": line[i], "b": line[i + 1], "cuts": [0.0, 1.0],
				"road_id": str(edge["id"]), "width": float(edge["width"])})
	# Spatial broad phase avoids quadratic intersection work across the city.
	var bins := {}
	var pairs := {}
	for i in segments.size():
		var s: Dictionary = segments[i]
		var lo: Vector2 = (s.a as Vector2).min(s.b)
		var hi: Vector2 = (s.a as Vector2).max(s.b)
		for x in range(floori(lo.x / 64.0), floori(hi.x / 64.0) + 1):
			for z in range(floori(lo.y / 64.0), floori(hi.y / 64.0) + 1):
				var key := Vector2i(x, z)
				for j: int in bins.get(key, []):
					var pair := Vector2i(j, i)
					if pairs.has(pair):
						continue
					pairs[pair] = true
					_intersect(segments[j], s)
				bins.get_or_add(key, []).append(i)
	var points: Array[Vector2] = []
	var point_ids := {}
	var links := {}
	var adjacency := {}
	for s: Dictionary in segments:
		s.cuts.sort()
		for i in range(s.cuts.size() - 1):
			var a := _vertex((s.a as Vector2).lerp(s.b, s.cuts[i]), points, point_ids)
			var b := _vertex((s.a as Vector2).lerp(s.b, s.cuts[i + 1]), points, point_ids)
			if a == b:
				continue
			var key := Vector2i(mini(a, b), maxi(a, b))
			if links.has(key):
				continue
			links[key] = {"width": s.width, "road_id": s.road_id}
			adjacency.get_or_add(a, []).append(b)
			adjacency.get_or_add(b, []).append(a)
	for a: int in adjacency:
		var origin: Vector2 = points[a]
		adjacency[a].sort_custom(func(b: int, c: int) -> bool:
			return (points[b] - origin).angle() < (points[c] - origin).angle())
	var visited := {}
	var faces: Array[Dictionary] = []
	for a: int in adjacency:
		for b: int in adjacency[a]:
			if visited.has(Vector2i(a, b)):
				continue
			var start := Vector2i(a, b)
			var step := start
			var polygon := PackedVector2Array()
			var boundary: Array[Dictionary] = []
			var closed := false
			for guard in links.size() * 2 + 1:
				if visited.has(step):
					closed = step == start
					break
				visited[step] = true
				polygon.append(points[step.x])
				boundary.append(links[Vector2i(mini(step.x, step.y), maxi(step.x, step.y))])
				var neighbors: Array = adjacency[step.y]
				var incoming := neighbors.find(step.x)
				step = Vector2i(step.y, neighbors[posmod(incoming - 1, neighbors.size())])
			# Positive winding is a bounded face; negative is the exterior walk.
			if closed and signed_area(polygon) > 70.0:
				polygon = clean_polygon(without_spurs(polygon))
				faces.append({"polygon": polygon, "boundary": boundary,
					"area_m2": signed_area(polygon)})
	return {"points": points, "adjacency": adjacency, "links": links, "faces": faces}

static func without_spurs(poly: PackedVector2Array) -> PackedVector2Array:
	var result := poly.duplicate()
	var changed := true
	while changed and result.size() >= 3:
		changed = false
		for i in result.size():
			var before := posmod(i - 1, result.size())
			var after := (i + 1) % result.size()
			if result[before].distance_squared_to(result[after]) < SNAP * SNAP:
				result.remove_at(i)
				result.remove_at(i % result.size())
				changed = true
				break
	return result

## Faces inherit duplicate and collinear vertices from polygon clipping, which
## leaves hairline edges (half of the perimeter on real plans). Consumers that
## walk a block perimeter - plot allocation, road subtraction, contracts - need a
## ring of real corners, so drop vertices that are duplicates or that lie within
## `collinear` of the line between their neighbours. Same rule as the parcel
## simplifier, applied to the traced face itself.
static func clean_polygon(poly: PackedVector2Array, min_edge := 0.05, collinear := 0.02) -> PackedVector2Array:
	var out := poly.duplicate()
	var changed := true
	while changed and out.size() > 3:
		changed = false
		for i in out.size():
			var a := out[posmod(i - 1, out.size())]
			var b := out[(i + 1) % out.size()]
			var span := a.distance_to(b)
			if out[i].distance_to(a) < min_edge or span < min_edge:
				out.remove_at(i)
				changed = true
				break
			if absf((out[i] - a).cross(b - a)) / span < collinear:
				out.remove_at(i)
				changed = true
				break
	return out

static func _vertex(p: Vector2, points: Array[Vector2], ids: Dictionary) -> int:
	var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
	if not ids.has(key):
		ids[key] = points.size()
		points.append(Vector2(key) * SNAP)
	return int(ids[key])

static func _intersect(a: Dictionary, b: Dictionary) -> void:
	var r: Vector2 = a.b - a.a
	var s: Vector2 = b.b - b.a
	var qp: Vector2 = b.a - a.a
	var den := r.cross(s)
	if absf(den) < 0.000001:
		# Collinear overlaps must split at endpoints too.
		if absf(qp.cross(r)) > 0.0001:
			return
		for p: Vector2 in [b.a, b.b]:
			var t := (p - (a.a as Vector2)).dot(r) / r.length_squared()
			if t > 0.0 and t < 1.0:
				a.cuts.append(t)
		for p: Vector2 in [a.a, a.b]:
			var t := (p - (b.a as Vector2)).dot(s) / s.length_squared()
			if t > 0.0 and t < 1.0:
				b.cuts.append(t)
		return
	var t := qp.cross(s) / den
	var u := qp.cross(r) / den
	if t >= -0.000001 and t <= 1.000001 and u >= -0.000001 and u <= 1.000001:
		a.cuts.append(clampf(t, 0.0, 1.0))
		b.cuts.append(clampf(u, 0.0, 1.0))

static func signed_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		area += poly[i].cross(poly[(i + 1) % poly.size()])
	return area * 0.5

static func graph_manifest(edges: Array) -> Dictionary:
	var planar := build(edges)
	var sources := {}
	for edge: Dictionary in edges:
		sources[str(edge.id)] = edge
	var points: Array = planar.points
	var adjacency: Dictionary = planar.adjacency
	var links: Dictionary = planar.links
	var nodes: Array[Dictionary] = []
	var roads: Array[Dictionary] = []
	var visited := {}
	# Keep intersections/endpoints and source-road boundaries; collapse only
	# tessellation vertices so a 12 m renderer sample is not a street segment.
	var terminals := {}
	for a: int in adjacency:
		var ns: Array = adjacency[a]
		if ns.size() != 2 or _link(links, a, ns[0]).road_id != _link(links, a, ns[1]).road_id:
			terminals[a] = true
	for a: int in terminals:
		nodes.append({"id": "street_node_%d" % a, "center": points[a], "position": points[a],
			"kind": &"junction", "degree": adjacency[a].size(), "landmark_id": ""})
		for b: int in adjacency[a]:
			if visited.has(Vector2i(mini(a, b), maxi(a, b))):
				continue
			var line := PackedVector2Array([points[a]])
			var previous := a
			var current := b
			for guard in links.size() + 1:
				visited[Vector2i(mini(previous, current), maxi(previous, current))] = true
				line.append(points[current])
				if terminals.has(current):
					break
				var ns: Array = adjacency[current]
				var next: int = ns[1] if int(ns[0]) == previous else ns[0]
				previous = current
				current = next
			var source: Dictionary = sources[str(_link(links, a, b).road_id)]
			var road := source.duplicate(true)
			road.id = "%s_j%d_%d" % [source.id, a, current]
			road.a = "street_node_%d" % a
			road.b = "street_node_%d" % current
			road.a_center = line[0]
			road.b_center = line[-1]
			road.polyline = line
			road.length = 0.0
			for i in range(line.size() - 1):
				road.length += line[i].distance_to(line[i + 1])
			roads.append(road)
	return {"nodes": nodes, "edges": roads}

static func _link(links: Dictionary, a: int, b: int) -> Dictionary:
	return links[Vector2i(mini(a, b), maxi(a, b))]
