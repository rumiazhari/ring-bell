class_name PavementPlan
extends RefCounted
## Pure world-space junction geometry; no random state or scene objects.

static func surfaces(edges: Array[Dictionary], buildings: Array, query: Rect2) -> Array[PackedVector2Array]:
	var streets := edges.duplicate()
	streets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var houses := buildings.duplicate()
	houses.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var patches: Array[PackedVector2Array] = []
	var cutters: Array[Dictionary] = []
	for edge in streets:
		var line: PackedVector2Array = edge.get("polyline", edge.get("polyline_clipped", PackedVector2Array()))
		for i in range(line.size() - 1):
			var width := float(edge.get("width", 5.0)) * 0.5
			var road := CityPlan._road_strip_polygon(line[i], line[i + 1], width)
			if road.size() < 3:
				continue
			cutters.append({"polygon": road, "bounds": bounds(road)})
			patches.append(CityPlan._road_strip_polygon(line[i], line[i + 1], width + (0.25 if bool(edge.get("shared_surface", false)) else WorldConstants.CITY_SIDEWALK_DEPTH_M)))
	for connector in connectors(streets, query):
		patches.append_array(connector.polygons)
	for spec: Dictionary in houses:
		patches.append_array(building_contact_polygons(spec))
		var footprint := CityPlan._lot_corners(spec.rect, float(spec.get("yaw", 0.0)))
		cutters.append({"polygon": footprint, "bounds": bounds(footprint)})
	var result: Array[PackedVector2Array] = []
	var chunk := CityPlan._rect_polygon(query)
	for patch in patches:
		if not bounds(patch).intersects(query):
			continue
		var pieces: Array[PackedVector2Array] = []
		for clipped in Geometry2D.intersect_polygons(patch, chunk):
			pieces.append(clipped)
		var patch_bounds := bounds(patch).intersection(query)
		for cutter in cutters:
			if (cutter.bounds as Rect2).intersects(patch_bounds):
				pieces = subtract(pieces, cutter.polygon)
				if pieces.is_empty():
					break
		result.append_array(pieces)
	return result


static func bounds(polygon: PackedVector2Array) -> Rect2:
	if polygon.is_empty():
		return Rect2()
	var result := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon:
		result = result.expand(point)
	return result

static func connectors(edges: Array[Dictionary], query: Rect2) -> Array[Dictionary]:
	var nodes: Dictionary = {}
	var segments: Array[Dictionary] = []
	var halo := query.grow(24.0)
	var ordered := edges.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	for edge in ordered:
		var line: PackedVector2Array = edge.get("polyline", edge.get("polyline_clipped", PackedVector2Array()))
		for i in range(line.size() - 1):
			var a := line[i]
			var z := line[i + 1]
			if a.distance_to(z) < 0.02 or CityPlan._clip_segment_to_rect(a, z, halo).size() != 2:
				continue
			var width := float(edge.get("width", 5.0))
			segments.append({"a": a, "z": z, "width": width})
			if halo.has_point(a):
				_add_arm(nodes, a, z - a, width)
			if halo.has_point(z):
				_add_arm(nodes, z, a - z, width)
	for i in segments.size():
		var first := segments[i]
		for j in range(i + 1, segments.size()):
			var second := segments[j]
			var crossing: Variant = Geometry2D.segment_intersects_segment(first.a, first.z, second.a, second.z)
			if crossing == null or not halo.has_point(crossing):
				continue
			for segment in [first, second]:
				_add_arm(nodes, crossing, segment.a - crossing, segment.width)
				_add_arm(nodes, crossing, segment.z - crossing, segment.width)
	var result: Array[Dictionary] = []
	var keys := nodes.keys()
	keys.sort()
	for key in keys:
		var node: Dictionary = nodes[key]
		var arms: Array[Dictionary] = node.arms
		if arms.size() < 2:
			continue
		arms.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a.direction as Vector2).angle() < (b.direction as Vector2).angle())
		result.append({"id": "pavement_%s" % key, "center": node.center,
			"kind": "connector_%dway" % arms.size(), "arms": arms,
			"polygons": connector_polygons(node.center, arms)})
	return result


static func _add_arm(nodes: Dictionary, point: Vector2, direction: Vector2, width: float) -> void:
	if direction.length_squared() < 0.0001:
		return
	var center := point.snapped(Vector2(0.001, 0.001))
	var key := "%d_%d" % [roundi(center.x * 1000.0), roundi(center.y * 1000.0)]
	if not nodes.has(key):
		var arms: Array[Dictionary] = []
		nodes[key] = {"center": center, "arms": arms}
	var unit := direction.normalized()
	for arm: Dictionary in nodes[key].arms:
		if (arm.direction as Vector2).dot(unit) > 0.999:
			arm.width = maxf(float(arm.width), width)
			return
	nodes[key].arms.append({"direction": unit, "width": width})


static func connector_polygons(center: Vector2, arms: Array[Dictionary]) -> Array[PackedVector2Array]:
	var points := PackedVector2Array()
	var reach := 10.0
	for arm in arms:
		reach = maxf(reach, float(arm.width) * 0.5 + WorldConstants.CITY_SIDEWALK_DEPTH_M * 2.0)
	for arm in arms:
		var direction: Vector2 = arm.direction
		var side := Vector2(-direction.y, direction.x) * (float(arm.width) * 0.5 + WorldConstants.CITY_SIDEWALK_DEPTH_M)
		points.append(center + direction * reach + side)
		points.append(center + direction * reach - side)
		points.append(center + side)
		points.append(center - side)
	var pieces: Array[PackedVector2Array] = [Geometry2D.convex_hull(points)]
	for arm in arms:
		var ribbon := CityPlan._road_strip_polygon(center - (arm.direction as Vector2) * 0.05,
			center + (arm.direction as Vector2) * (reach + 2.0), float(arm.width) * 0.5)
		pieces = subtract(pieces, ribbon)
	return pieces


static func subtract(pieces: Array[PackedVector2Array], cutter: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for piece in pieces:
		for remainder in CityPlan._subtract_road_ribbon(piece, cutter):
			if CityPlan._polygon_area(remainder) > 0.01:
				result.append(remainder)
	return result


static func building_contact_polygons(spec: Dictionary) -> Array[PackedVector2Array]:
	var rect: Rect2 = spec.get("rect", Rect2())
	var yaw := float(spec.get("yaw", 0.0))
	var outer: Array[PackedVector2Array] = [CityPlan._lot_corners(rect.grow(0.8), yaw)]
	var result := subtract(outer, CityPlan._lot_corners(rect, yaw))
	if not spec.has("frontage_center"):
		return result
	var side := int(spec.get("door_edge", 0))
	var corners := CityPlan._lot_corners(rect, yaw)
	var a := corners[side]
	var z := corners[(side + 1) % 4]
	var front := (a + z) * 0.5
	var outward := (front - rect.get_center()).normalized()
	var distance := clampf(((spec.frontage_center as Vector2) - front).dot(outward), 0.8, 16.0)
	result.append(PackedVector2Array([a, z, z + outward * distance, a + outward * distance]))
	return result
