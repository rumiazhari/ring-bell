extends Node
## Independent geometry audit of the published city plan. Nothing here reuses
## the generator's own "is this lot valid" predicates: it takes the finished
## footprints and asks four questions of them.
##
##   1. do two neighbouring buildings interpenetrate (exact convex clip)?
##   2. does any footprint corner sit outside the block it was placed in?
##   3. does any footprint corner sit inside a road surface (clipping the street)?
##   4. is each frontage building square to the street it was told to face?
##
## Plus a bare-ground sweep of every block boundary, so "no blank space" is
## measured on the same pass as the geometry.
##
## Exit code is the failure count, so tools/run_suite.py can gate on it.
var failures := 0


func _ready() -> void:
	for seed_value: int in [19041207, 19041208, 19041209]:
		audit(seed_value)
		if OS.get_cmdline_user_args().has("--single"):
			break
	print("[PragueAlignmentTest] finished with %d failure(s)" % failures)
	get_tree().quit(failures)


func audit(seed_value: int) -> void:
	var started := Time.get_ticks_msec()
	var city := CityPlan.new(seed_value)
	var blocks := city.city_blocks()
	var lots := 0
	var overlap_pairs := 0
	var worst_overlap := 0.0
	var overlap_at := Vector2.ZERO
	var overlap_samples: Array[String] = []
	var outside_lots := 0
	var worst_outside := 0.0
	var outside_at := Vector2.ZERO
	var outside_samples: Array[String] = []
	var road_lots := 0
	var worst_road := 0.0
	var road_at := Vector2.ZERO
	var road_samples: Array[String] = []
	var frontage_checked := 0
	var angled := 0
	var angles: Array[float] = []
	var angle_samples: Array[String] = []
	var blank_runs := 0
	var gardens := 0
	var blank_total := 0.0
	var longest_blank := 0.0
	var blank_lines: Array[String] = []
	var magenta: Array[PackedVector2Array] = []
	var cyan: Array[PackedVector2Array] = []
	var orange: Array[PackedVector2Array] = []
	var yellow: Array[PackedVector2Array] = []
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="1400" viewBox="-450 -450 900 900"><rect x="-450" y="-450" width="900" height="900" fill="#2f3639"/>'
	for block: Dictionary in blocks:
		if not bool(block.get("historic_compound", false)) or block.kind != &"built":
			continue
		var poly: PackedVector2Array = block.polygon
		if poly.size() < 3:
			continue
		var specs: Array = block.get("buildings", []) as Array
		var outlines: Array[PackedVector2Array] = []
		var boxes: Array[Rect2] = []
		var yaws: Array[float] = []
		var grid := {}
		for spec: Dictionary in specs:
			var corners := CityPlan._lot_corners(spec["rect"] as Rect2, float(spec.get("yaw", 0.0)))
			outlines.append(corners)
			yaws.append(float(spec.get("yaw", 0.0)))
			var box := poly_bounds(corners)
			boxes.append(box)
			grid_add(grid, outlines.size() - 1, box.grow(2.0), 8.0)
		# A planted street garden is fabric, not bare ground: it belongs in the
		# same grid as the footprints, or the sweep below reports it as blank.
		var garden_shapes: Array[PackedVector2Array] = []
		for region_variant in block.get("courtyard_regions", []) as Array:
			var region: Dictionary = region_variant as Dictionary
			if StringName(region.get("kind", &"")) != &"garden":
				continue
			var garden: PackedVector2Array = region.get("polygon", PackedVector2Array()) as PackedVector2Array
			if garden.size() < 3:
				continue
			gardens += 1
			var garden_box := poly_bounds(garden)
			boxes.append(garden_box)
			grid_add(grid, boxes.size() - 1, garden_box.grow(2.0), 8.0)
			garden_shapes.append(garden)
		lots += outlines.size()
		svg += svg_polygon(poly, "#3d464a")

		# Paint the carriageways the way the generator stripes them, because
		# "is this house standing on the road" only means anything measured
		# against pavement that is actually drawn.
		var roads := city.city_road_segments_in(poly_bounds(poly).grow(18.0))
		var pavement: Array[PackedVector2Array] = []
		for road_variant in roads:
			var road: Dictionary = road_variant as Dictionary
			var road_line: PackedVector2Array = road.get("polyline_clipped", road.get("polyline", PackedVector2Array())) as PackedVector2Array
			var road_half := float(road.get("width", 6.0)) * 0.5
			for k in range(road_line.size() - 1):
				var quad: PackedVector2Array = city._road_strip_polygon(road_line[k], road_line[k + 1], road_half)
				if quad.size() < 3:
					continue
				pavement.append(quad)
				svg += svg_polygon(quad, "#6f777c")
		# Ground, then pavement, then the planted strips, then the houses: each
		# layer would otherwise hide the one this audit exists to show.
		for garden_shape: PackedVector2Array in garden_shapes:
			svg += svg_polygon(garden_shape, "#4f9c46")
		for i in outlines.size():
			svg += svg_line(outlines[i], "#8a6a52", 0.9, false)

		# 1. Interpenetration. Bounds first, then exact convex clip; abutting
		# terraced lots share an edge and clip to zero area, which is correct.
		for i in outlines.size():
			for j in range(i + 1, outlines.size()):
				if not boxes[i].intersects(boxes[j]):
					continue
				var shared := clip_convex(outlines[i], outlines[j])
				if shared.size() < 3:
					continue
				var area := poly_area(shared)
				if area < 0.5:
					continue
				overlap_pairs += 1
				if area > worst_overlap:
					worst_overlap = area
					overlap_at = boxes[i].get_center()
				if overlap_samples.size() < 12:
					overlap_samples.append("%.1fm2 at (%.0f,%.0f)" % [area, overlap_at.x, overlap_at.y])
				if magenta.size() < 400:
					magenta.append(outlines[i])
					magenta.append(outlines[j])

		# 2. Footprint outside its own block.
		for i in outlines.size():
			var worst := 0.0
			for corner: Vector2 in outlines[i]:
				if Geometry2D.is_point_in_polygon(corner, poly):
					continue
				worst = maxf(worst, poly_edge_distance(corner, poly))
			if worst <= 0.35:
				continue
			outside_lots += 1
			if worst > worst_outside:
				worst_outside = worst
				outside_at = boxes[i].get_center()
			if outside_samples.size() < 12:
				outside_samples.append("%.2fm past the block edge at (%.0f,%.0f)" % [worst, outside_at.x, outside_at.y])
			if cyan.size() < 400:
				cyan.append(outlines[i])

		# 3. Clipping the street: a corner standing on the pavement as it is
		# actually painted. Distance to the centreline over-counts at a junction,
		# where no strip is drawn in the mouth of the bend, so the test is made
		# against the same strip rectangles the generator uses for block
		# subtraction — and the result is drawn, so it can be seen and judged.
		for i in outlines.size():
			var worst := 0.0
			var worst_corner := Vector2.ZERO
			for corner: Vector2 in outlines[i]:
				for quad: PackedVector2Array in pavement:
					if not quad_bounds(quad).has_point(corner):
						continue
					if not Geometry2D.is_point_in_polygon(corner, quad):
						continue
					var depth := INF
					for k in quad.size():
						depth = minf(depth, corner.distance_to(Geometry2D.get_closest_point_to_segment(corner, quad[k], quad[(k + 1) % quad.size()])))
					if depth <= worst:
						continue
					worst = depth
					worst_corner = corner
			if worst <= 0.05:
				continue
			road_lots += 1
			if worst > worst_road:
				worst_road = worst
				road_at = worst_corner
			if road_samples.size() < 12:
				road_samples.append("%.2fm inside the pavement at (%.0f,%.0f) id=%s" % [worst, worst_corner.x, worst_corner.y, str(specs[i].get("id", "?"))])
			if orange.size() < 400:
				orange.append(outlines[i])

		# 4. Squareness to the street it opens onto. A wing 20m inside the block
		# is not a frontage, so this judges the face that carries the door: the
		# door edge of the footprint against the nearest carriageway to that
		# edge's midpoint.
		var segment_list: Array[PackedVector2Array] = []
		for road_variant in roads:
			var surface := road_surface(road_variant as Dictionary)
			for segment_variant in surface["segments"]:
				segment_list.append(segment_variant as PackedVector2Array)
		if not segment_list.is_empty():
			for i in outlines.size():
				var spec: Dictionary = specs[i] as Dictionary
				var corners: PackedVector2Array = outlines[i]
				if corners.size() < 4:
					continue
				var door_edge := clampi(int(spec.get("door_edge", 0)), 0, 3)
				var face := (corners[door_edge] + corners[(door_edge + 1) % 4]) * 0.5
				var best := INF
				var best_segment := PackedVector2Array()
				for segment: PackedVector2Array in segment_list:
					var d := face.distance_to(Geometry2D.get_closest_point_to_segment(face, segment[0], segment[1]))
					if d < best:
						best = d
						best_segment = segment
				if best_segment.size() < 2 or best > 8.0:
					continue
				frontage_checked += 1
				var street_yaw := atan2((best_segment[1] - best_segment[0]).y, (best_segment[1] - best_segment[0]).x)
				var diff := absf(rad_to_deg(angle_difference(yaws[i], street_yaw)))
				diff = minf(diff, 180.0 - diff)
				angles.append(diff)
				if diff > 15.0:
					angled += 1
					if angle_samples.size() < 12:
						angle_samples.append("%.1f deg off a street %.1fm from its door face at (%.0f,%.0f) id=%s" % [diff, best, face.x, face.y, str(spec.get("id", "?"))])
					if yellow.size() < 400:
						yellow.append(outlines[i])

		# 5. Bare ground along the boundary: a station only counts as covered if
		# some footprint is within 1.6 m. AABB distance is a lower bound on the
		# true distance, so this can under-report blank ground, never invent it.
		var run := 0.0
		var run_start := Vector2.ZERO
		var run_end := Vector2.ZERO
		for i in poly.size():
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % poly.size()]
			var length := a.distance_to(b)
			if length < 0.05:
				continue
			var samples := maxi(1, ceili(length / 0.5))
			for s in samples:
				var point := a.lerp(b, (float(s) + 0.5) / float(samples))
				if nearest_lot_distance(point, grid, 8.0, boxes) <= 1.6:
					if run > 0.0:
						blank_total += run
						blank_runs += 1 if run > 15.0 else 0
						longest_blank = maxf(longest_blank, run)
						if run > 15.0 and blank_lines.size() < 300:
							blank_lines.append(svg_line(PackedVector2Array([run_start, run_end]), "#ff2d2d", 3.0, false))
					run = 0.0
				else:
					if run == 0.0:
						run_start = point
					run += length / float(samples)
					run_end = point
		if run > 0.0:
			blank_total += run
			blank_runs += 1 if run > 15.0 else 0
			longest_blank = maxf(longest_blank, run)
			if run > 15.0 and blank_lines.size() < 300:
				blank_lines.append(svg_line(PackedVector2Array([run_start, run_end]), "#ff2d2d", 3.0, false))
	for poly_variant in magenta:
		svg += svg_polygon(poly_variant as PackedVector2Array, "#ff00d0")
	for poly_variant in cyan:
		svg += svg_polygon(poly_variant as PackedVector2Array, "#39d0ff")
	for poly_variant in orange:
		svg += svg_polygon(poly_variant as PackedVector2Array, "#ff9b2d")
	for poly_variant in yellow:
		svg += svg_polygon(poly_variant as PackedVector2Array, "#ffe14a")
	svg += "\n".join(blank_lines)
	var raster := Image.new()
	raster.load_svg_from_string(svg + "</svg>")
	raster.save_png("res://.hermes/autopilot/reports/prague-gameplay-pass/geometry-%d.png" % seed_value)
	var ms := Time.get_ticks_msec() - started
	angles.sort()
	print("[PragueAlignmentTest] seed=%d lots=%d gardens=%d overlaps=%d worst_overlap=%.2fm2 lots_outside_block=%d worst=%0.2fm lots_in_street=%d worst=%0.2fm squareness_checked=%d angle_p50=%.1f p90=%.1f max=%.1f angled_gt15=%d blank_runs_gt15=%d blank_frontage=%.0fm longest=%.0fm ms=%d" % [
		seed_value, lots, gardens, overlap_pairs, worst_overlap, outside_lots, worst_outside,
		road_lots, worst_road, frontage_checked, percentile(angles, 0.5), percentile(angles, 0.9),
		percentile(angles, 1.0), angled, blank_runs, blank_total, longest_blank, ms])
	for line: String in overlap_samples:
		print("[PragueAlignmentTest]   overlap: ", line)
	for line: String in outside_samples:
		print("[PragueAlignmentTest]   outside: ", line)
	for line: String in road_samples:
		print("[PragueAlignmentTest]   street:  ", line)
	for line: String in angle_samples:
		print("[PragueAlignmentTest]   angle:   ", line)
	check(overlap_pairs == 0, "no two buildings interpenetrate")
	check(outside_lots == 0, "every footprint sits inside its block polygon")
	check(road_lots == 0, "no footprint clips a road surface")
	check(angled == 0, "every frontage is square to the street within 15 deg")
	check(blank_runs == 0, "no bare ground run longer than 15m on a block boundary")


func check(condition: bool, label: String) -> void:
	if condition:
		return
	failures += 1
	print("[PragueAlignmentTest] FAIL ", label)


func percentile(sorted_values: Array[float], q: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index := clampi(int(round(q * float(sorted_values.size() - 1))), 0, sorted_values.size() - 1)
	return sorted_values[index]


## The generator's own clearance rule, re-implemented here without its spatial
## broad phase. When this disagrees with _lot_clear_of_city_roads, the broad
## phase dropped a segment and the disagreement is a real bug rather than a
## difference of measurement.
func direct_clear(city: CityPlan, lot: Rect2, yaw: float) -> bool:
	var corners := CityPlan._lot_corners(lot, yaw)
	for edge_variant in city._city_edges:
		var edge: Dictionary = edge_variant as Dictionary
		var half_width := float(edge.get("width", 6.0)) * 0.5 + (0.25 if bool(edge.get("shared_surface", false)) else 0.8)
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		for i in range(poly.size() - 1):
			for corner: Vector2 in corners:
				if corner.distance_to(Geometry2D.get_closest_point_to_segment(corner, poly[i], poly[i + 1])) < half_width:
					return false
	return true


## Probe the generator's road broad phase from the outside: how many binned
## segments sit near this corner, and does any of them actually catch it? A
## corner that the full scan calls illegal while the bins say "nothing near"
## means the bins are short-ranged or stale, not that the rule disagrees.
func bin_probe(city: CityPlan, corner: Vector2) -> String:
	var binned := 0
	var near := 0
	var caught := false
	var seen := {}
	var cx := floori(corner.x / 64.0)
	var cz := floori(corner.y / 64.0)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for segment_variant in city._road_query_bins.get(Vector2i(cx + dx, cz + dz), []):
				var segment: Dictionary = segment_variant as Dictionary
				if seen.has(segment["id"]):
					continue
				seen[segment["id"]] = true
				binned += 1
				if not (segment["bounds"] as Rect2).has_point(corner):
					continue
				near += 1
				if corner.distance_to(Geometry2D.get_closest_point_to_segment(corner, segment["a"] as Vector2, segment["b"] as Vector2)) < float(segment["half"]):
					caught = true
	return "bins=%d binned=%d near=%d catches=%s" % [city._road_query_bins.size(), binned, near, str(caught)]


## The shared-surface branch is the only filter that can continue past a real
## catch, so reproduce it exactly for this corner and report the winding and
## overlap area it produces.
func strip_probe(city: CityPlan, corner: Vector2, lot: Rect2, yaw: float) -> String:
	var best := INF
	var best_segment := {}
	var cx := floori(corner.x / 64.0)
	var cz := floori(corner.y / 64.0)
	var seen := {}
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for segment_variant in city._road_query_bins.get(Vector2i(cx + dx, cz + dz), []):
				var segment: Dictionary = segment_variant as Dictionary
				if seen.has(segment["id"]):
					continue
				seen[segment["id"]] = true
				var d := corner.distance_to(Geometry2D.get_closest_point_to_segment(corner, segment["a"] as Vector2, segment["b"] as Vector2))
				if d < best:
					best = d
					best_segment = segment
	if best_segment.is_empty():
		return "strip: no segment"
	var lot_corners := CityPlan._lot_corners(lot, yaw)
	var strip: PackedVector2Array = city._road_strip_polygon(best_segment["a"] as Vector2, best_segment["b"] as Vector2, float(best_segment["half"]))
	var overlap := 0.0
	for piece: PackedVector2Array in Geometry2D.intersect_polygons(lot_corners, strip):
		overlap += absf(CityPlan._polygon_area(piece))
	return "strip: dist=%.2f half=%.2f shared=%s lot_signed_area=%.1f strip_points=%d strip_signed_area=%.1f godot_overlap=%.2fm2" % [
		best, float(best_segment["half"]), str(best_segment["shared"]), CityPlan._polygon_area(lot_corners),
		strip.size(), CityPlan._polygon_area(strip), overlap]


func quad_bounds(quad: PackedVector2Array) -> Rect2:
	var bounds := Rect2(quad[0], Vector2.ZERO)
	for point: Vector2 in quad:
		bounds = bounds.expand(point)
	return bounds


func road_surface(road: Dictionary) -> Dictionary:
	var poly: PackedVector2Array = road.get("polyline_clipped", road.get("polyline", PackedVector2Array())) as PackedVector2Array
	var segments: Array[PackedVector2Array] = []
	var bounds := Rect2()
	for i in range(poly.size() - 1):
		segments.append(PackedVector2Array([poly[i], poly[i + 1]]))
		bounds = bounds.merge(Rect2(poly[i], Vector2.ZERO)).merge(Rect2(poly[i + 1], Vector2.ZERO))
	return {"segments": segments, "bounds": bounds,
		"half": float(road.get("width", 6.0)) * 0.5}


func nearest_lot_distance(point: Vector2, grid: Dictionary, cell: float, boxes: Array[Rect2]) -> float:
	var origin := Vector2i(floori(point.x / cell), floori(point.y / cell))
	var best := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(origin.x + dx, origin.y + dy)
			if not grid.has(key):
				continue
			for index: int in grid[key] as Array:
				var box: Rect2 = boxes[index]
				var closest := Vector2(clampf(point.x, box.position.x, box.end.x), clampf(point.y, box.position.y, box.end.y))
				best = minf(best, point.distance_to(closest))
	return best


func grid_add(grid: Dictionary, index: int, box: Rect2, cell: float) -> void:
	for x in range(floori(box.position.x / cell), floori(box.end.x / cell) + 1):
		for y in range(floori(box.position.y / cell), floori(box.end.y / cell) + 1):
			var key := Vector2i(x, y)
			if not grid.has(key):
				grid[key] = Array([], TYPE_INT, "", null)
			(grid[key] as Array).append(index)


func poly_bounds(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var box := Rect2(poly[0], Vector2.ZERO)
	for point: Vector2 in poly:
		box = box.expand(point)
	return box


func poly_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var total := 0.0
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		total += a.cross(b)
	return absf(total) * 0.5


func signed_area(poly: PackedVector2Array) -> float:
	var total := 0.0
	for i in poly.size():
		total += poly[i].cross(poly[(i + 1) % poly.size()])
	return total * 0.5


## Sutherland-Hodgman clip of a convex subject against a convex clipper. Any
## winding is accepted; a shared party wall clips to zero area, an overlap to
## the real interpenetrating area.
func clip_convex(subject: PackedVector2Array, clipper: PackedVector2Array) -> PackedVector2Array:
	if subject.size() < 3 or clipper.size() < 3:
		return PackedVector2Array()
	var ring := clipper.duplicate()
	if signed_area(ring) < 0.0:
		ring.reverse()
	var out := subject.duplicate()
	for i in ring.size():
		if out.is_empty():
			break
		var a: Vector2 = ring[i]
		var b: Vector2 = ring[(i + 1) % ring.size()]
		var input := out.duplicate()
		out = PackedVector2Array()
		for j in input.size():
			var current: Vector2 = input[j]
			var previous: Vector2 = input[(j + input.size() - 1) % input.size()]
			var current_inside := (b - a).cross(current - a) >= 0.0
			var previous_inside := (b - a).cross(previous - a) >= 0.0
			if current_inside:
				if not previous_inside:
					out.append(line_intersection(previous, current, a, b))
				out.append(current)
			elif previous_inside:
				out.append(line_intersection(previous, current, a, b))
	return out


func line_intersection(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> Vector2:
	var d1 := p2 - p1
	var d2 := p4 - p3
	var denominator := d1.cross(d2)
	if absf(denominator) < 0.0000001:
		return p2
	return p1 + d1 * ((p3 - p1).cross(d2) / denominator)


func poly_edge_distance(point: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		best = minf(best, point.distance_to(Geometry2D.get_closest_point_to_segment(point, a, b)))
	return best


func svg_line(poly: PackedVector2Array, color: String, width: float, closed := true) -> String:
	var points := PackedStringArray()
	for point: Vector2 in poly:
		points.append("%.1f,%.1f" % [point.x, point.y])
	var tag := "polygon" if closed else "polyline"
	if not closed:
		var tail := PackedStringArray()
		for point: Vector2 in poly:
			tail.append("%.1f,%.1f" % [point.x, point.y])
		return '<%s points="%s" fill="none" stroke="%s" stroke-width="%.1f"/>' % [tag, ",".join(tail), color, width]
	return '<%s points="%s" fill="none" stroke="%s" stroke-width="%.1f"/>' % [tag, ",".join(points), color, width]


func svg_polygon(poly: PackedVector2Array, color: String) -> String:
	var points := PackedStringArray()
	for point: Vector2 in poly:
		points.append("%.1f,%.1f" % [point.x, point.y])
	return '<polygon points="%s" fill="%s" fill-opacity="0.55" stroke="none"/>' % [",".join(points), color]
