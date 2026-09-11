extends Node
const ParcelPlan = preload("res://world/generation/parcel_plan.gd")
## Actual room geometry and street-wall coverage, independent of archetype labels.
var failures := 0

func _ready() -> void:
	for seed: int in [19041207, 19041208, 19041209]:
		measure(seed)
		if OS.get_cmdline_user_args().has("--single"):
			break
	print("[PragueGameplayTest] finished with %d failure(s)" % failures)
	get_tree().quit(failures)

func measure(seed: int) -> void:
	var started := Time.get_ticks_msec()
	var city := CityPlan.new(seed)
	ParcelPlan.reset_stats()
	var blocks := city.city_blocks()
	print("[PragueGameplayTest] allocation ", ParcelPlan.stats)
	var areas: Array[float] = []
	var counts: Array[float] = []
	var principal: Array[float] = []
	var occupied := 0.0
	var land := 0.0
	var frontage := 0.0
	var perimeter := 0.0
	var occupied_boundary := 0.0
	var tiny := 0
	var excessive_degree := 0
	var disconnected := 0
	var rooms_total := 0
	var widths: Array[float] = []
	var floor_rooms: Array[float] = []
	var floors_seen := 0
	var combat_floors := 0
	var hall_widths: Array[float] = []
	var street_len := 0.0
	var street_built := 0.0
	var party_len := 0.0
	var void_len := 0.0
	var blank_run := 0.0
	var blank_start := Vector2.ZERO
	var blank_lines: Array[String] = []
	var blanks_gt15 := 0
	var internal_blank := 0.0
	var boundary_blank := 0.0
	var garden_len := 0.0
	var step_lots := 0
	var cafe_lots := 0
	var step_shop_lots := 0
	var tavern_wings := 0
	var bad_reports: Array[String] = []
	var street_wings := 0
	var facade_wings := 0
	var facade_differs := 0
	var shopfronts := 0
	var shopfront_wings := 0
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="1400" viewBox="-450 -450 900 900"><rect x="-450" y="-450" width="900" height="900" fill="#343c40"/>'
	var built_polys: Array[PackedVector2Array] = []
	var built_boxes: Array[Rect2] = []
	for block: Dictionary in blocks:
		if bool(block.get("historic_compound", false)) and block.kind == &"built":
			var other: PackedVector2Array = block.polygon
			built_polys.append(other)
			built_boxes.append(poly_bounds(other))
	var garden_polys: Array[PackedVector2Array] = []
	var garden_regions := 0
	var garden_area := 0.0
	var residual_gardens := 0
	var residual_area := 0.0
	for block: Dictionary in blocks:
		for region_variant in block.get("courtyard_regions", []) as Array:
			var region: Dictionary = region_variant as Dictionary
			var region_kind := StringName(region.get("kind", &""))
			var access := StringName(region.get("access_kind", &""))
			if region_kind == &"garden" and access == &"block_residual":
				residual_gardens += 1
				residual_area += float(region.get("area_m2", 0.0))
				continue
			if region_kind != &"garden" or access != &"street_garden":
				continue
			garden_polys.append(region.get("polygon", PackedVector2Array()) as PackedVector2Array)
			garden_area += float(region.get("area_m2", 0.0))
			garden_regions += 1
	for block: Dictionary in blocks:
		if not bool(block.get("historic_compound", false)) or block.kind != &"built":
			continue
		var poly: PackedVector2Array = block.polygon
		# Count street-facing end walls at corners too. Summing only each
		# plot's named front omits those real, materialized street elevations.
		var outlines: Array[PackedVector2Array] = []
		for spec: Dictionary in block.buildings:
			outlines.append(CityPlan._lot_corners(spec.rect, spec.yaw))
		svg += svg_polygon(poly, "#d6cebc")
		land += absf(CityPlan._polygon_area(poly))
		# Only block boundary that faces a buildable street counts toward the
		# frontage bar. Party walls between abutting blocks and open-ground edges
		# are not buildable frontage, so they must not dilute the ratio - and the
		# residual open-ground class is itself measured against the 5 % target.
		var centroid := Vector2.ZERO
		for point: Vector2 in poly:
			centroid += point
		centroid /= maxf(float(poly.size()), 1.0)
		var roads := city.city_road_segments_in(poly_bounds(poly).grow(14.0))
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var length := a.distance_to(b)
			perimeter += length
			var middle := a.lerp(b, 0.5)
			var outward := middle - centroid
			outward = outward.normalized() if outward.length() > 0.05 else Vector2.RIGHT
			var edge_class := classify_edge(middle + outward * 1.2, city, roads, built_polys, built_boxes)
			var samples := maxi(1, ceili(length / 0.5))
			var step := length / float(samples)
			var covered := 0.0
			for j in samples:
				var point := a.lerp(b, (float(j) + 0.5) / samples)
				var distance := INF
				for outline: PackedVector2Array in outlines:
					for k in outline.size():
						distance = minf(distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[k], outline[(k + 1) % outline.size()])))
				if distance <= 0.75:
					occupied_boundary += step
					covered += step
					if blank_run > 15.0:
						blanks_gt15 += 1
					if blank_run > 6.0 and blank_start != Vector2.ZERO:
						blank_lines.append(frontage_line(blank_start, point))
					blank_run = 0.0
					blank_start = Vector2.ZERO
				elif edge_class == "street":
					if _in_garden(point, garden_polys):
						# Ground the plan published as a garden is an intentional
						# use, not a blank wall: a gap may become a building OR a
						# garden/courtyard/service yard. It is still counted as
						# unbuilt frontage in the coverage ratio.
						garden_len += step
						if blank_run > 15.0:
							blanks_gt15 += 1
						blank_run = 0.0
						blank_start = Vector2.ZERO
					else:
						# Where does the missing frontage live? An edge with
						# historic fabric across the street is an internal street
						# whose wall is broken; an edge with nothing historic
						# opposite is the core boundary, where this grammar hands
						# over to the generic fringe.
						var far := point + (middle - centroid).normalized() * 18.0
						var across := false
						for k in built_boxes.size():
							if built_boxes[k].has_point(far) and Geometry2D.is_point_in_polygon(far, built_polys[k]):
								across = true
								break
						if across:
							internal_blank += step
						else:
							boundary_blank += step
						if blank_run == 0.0:
							blank_start = point
						blank_run += step
			if edge_class == "street":
				street_len += length
				street_built += covered
			elif edge_class == "party":
				party_len += length
			else:
				void_len += length
		if blank_run > 15.0:
			blanks_gt15 += 1
		if blank_run > 6.0 and blank_start != Vector2.ZERO:
			blank_lines.append(frontage_line(blank_start, poly[0]))
		blank_run = 0.0
		blank_start = Vector2.ZERO
		for plot: Dictionary in block.get("plots", []):
			frontage += float(plot.frontage_m)
			widths.append(float(plot.frontage_m))
		for spec: Dictionary in block.buildings:
			# Orange: a house laid by the stepped wedge fill. Red-ish: one of them
			# that carries a cafe/restaurant venue. Both are the new irregular
			# infill, so they have to be visible on the plan.
			var lot_color := "#9b604e"
			if str(spec.id).contains("_step_"):
				lot_color = "#c8452f" if str(spec.use) == "tavern" else "#d98b3a"
			svg += svg_polygon(CityPlan._lot_corners(spec.rect, spec.yaw), lot_color)
			if str(spec.id).contains("_step_"):
				step_lots += 1
				if str(spec.use) == "tavern":
					cafe_lots += 1
				elif str(spec.use) == "retail":
					step_shop_lots += 1
			if str(spec.use) == "tavern":
				tavern_wings += 1
			occupied += (spec.rect as Rect2).get_area()
			var manifest := InteriorPlan.build_for_building(spec)
			var problems := InteriorPlan.validate(manifest)
			if not problems.is_empty():
				disconnected += 1
				if bad_reports.size() < 4:
					bad_reports.append("id=%s rect=%.1fx%.1f floors=%d use=%s :: %s" % [
						str(spec.id), (spec.rect as Rect2).size.x, (spec.rect as Rect2).size.y,
						int(spec.get("floors", 0)), str(spec.get("use", "")), str(problems)])
			if str(spec.get("wing_role", "")) == "front":
				# Phase 4 proof: the openings the shell builds are the ones derived
				# from this building's REAL room boundaries and ground-floor use,
				# not the legacy evenly-spaced fallback.
				street_wings += 1
				if spec.has("facade_plan"):
					facade_wings += 1
					var ground: Array = spec.facade_plan[0]
					var here := 0
					for side_openings: Array in ground:
						for opening: Dictionary in side_openings:
							if str(opening.get("kind", "")) == "shopfront":
								here += 1
					shopfronts += here
					if here > 0:
						shopfront_wings += 1
					var bare := spec.duplicate()
					bare.erase("facade_plan")
					var planned: Array = BuildingSpec.city_window_openings((spec.rect as Rect2).size.x, false, spec, 0, 0)
					var legacy: Array = BuildingSpec.city_window_openings((spec.rect as Rect2).size.x, false, bare, 0, 0)
					if str(planned) != str(legacy):
						facade_differs += 1
			for floor_plan: Dictionary in manifest.floors:
				var count := 0
				var biggest := 0.0
				var degree := {}
				for door: Dictionary in floor_plan.doors:
					for key: String in [str(door.room_a), str(door.room_b)]:
						degree[key] = int(degree.get(key, 0)) + 1
				for room: Dictionary in floor_plan.rooms:
					if str(room.kind) in ["stair_hall", "landing", "hall"] or bool(room.service):
						continue
					var area := (room.rect as Rect2).get_area()
					areas.append(area)
					biggest = maxf(biggest, area)
					count += 1
					rooms_total += 1
					if area < 8.0:
						tiny += 1
					if int(degree.get(str(room.id), 0)) > 2:
						excessive_degree += 1
				var manoeuvre := false
				for room: Dictionary in floor_plan.rooms:
					if (room.rect as Rect2).get_area() >= 18.0 and int(degree.get(str(room.id), 0)) <= 2 \
							and not bool(room.service) and str(room.kind) not in ["stair_hall", "landing"]:
						manoeuvre = true
				for room: Dictionary in floor_plan.rooms:
					if str(room.kind) == "stair_hall":
						hall_widths.append((room.rect as Rect2).size.x)
				if str(spec.wing_role) == "front":
					floor_rooms.append(float(count))
					floors_seen += 1
					if manoeuvre:
						combat_floors += 1
					counts.append(float(count))
					principal.append(biggest)
	var raster := Image.new()
	# Diagnostic only: this legacy ratio divides covered street wall by the WHOLE
	# block perimeter, including party walls and non-buildable boundary, so it can
	# never reach the bar even on a perfect street wall. The graded bar is
	# "buildable street frontage" above, measured against street-facing boundary.
	print("[PragueGameplayTest] actual street elevations / block perimeter = ", occupied_boundary / maxf(perimeter, 1.0))
	# Gardens last, so the block fill cannot paint over the very thing this
	# diagram exists to show. They never overlap a building, so drawing them on
	# top of the fabric costs nothing and makes the planted ground visible.
	for garden_poly: PackedVector2Array in garden_polys:
		svg += svg_polygon(garden_poly, "#5cc24a")
	svg += "\n".join(blank_lines)
	raster.load_svg_from_string(svg + "</svg>")
	raster.save_png("res://.hermes/autopilot/reports/prague-gameplay-pass/plan-%d.png" % seed)
	print("[PragueGameplayTest] seed=%d generation_and_measure_ms=%d occupied_rooms=%d area_p10/50/90=%s room_count_p10/50/90=%s principal_p50=%.2f tiny_share=%.3f door_degree_gt2=%d invalid_interiors=%d footprint=%.3f frontage=%.3f frontage_width_p10/50/90=%s floor_rooms_p50=%.2f combat_floors=%d/%d hall_p50=%.2f street_frontage=%.3f party=%.3f void=%.3f blanks_gt15=%d street_wings=%d facade=%d differs=%d shopfronts=%d blank_internal=%.0fm blank_boundary=%.0fm step_lots=%d gardens=%d garden_area=%.0fm2 garden_frontage=%.0fm residual_gardens=%d residual_area=%.0fm2 cafe_lots=%d step_shop_lots=%d seal_gardened=%d seal_unfilled=%d tavern_wings=%d" % [seed, Time.get_ticks_msec() - started, rooms_total, percentiles(areas), percentiles(counts), percentile(principal, 0.5), float(tiny) / maxi(1, rooms_total), excessive_degree, disconnected, occupied / maxf(land, 1.0), frontage / maxf(perimeter, 1.0), percentiles(widths), percentile(floor_rooms, 0.5), combat_floors, floors_seen, percentile(hall_widths, 0.5), street_built / maxf(street_len, 1.0), party_len / maxf(perimeter, 1.0), void_len / maxf(perimeter, 1.0), blanks_gt15, street_wings, facade_wings, facade_differs, shopfronts, internal_blank, boundary_blank, step_lots, garden_regions, garden_area, garden_len, residual_gardens, residual_area, cafe_lots, step_shop_lots, int(ParcelPlan.stats.get("seal_gardened", 0)), int(ParcelPlan.stats.get("seal_unfilled", 0)), tavern_wings])
	for line: String in bad_reports:
		print("[PragueGameplayTest] invalid interior: %s" % line)
	check(percentile(areas, 0.5) >= 15.0, "occupied room median >=15m2")
	check(percentile(areas, 0.5) <= 30.0, "occupied room median <=30m2")
	check(percentile(areas, 0.9) <= 45.0, "occupied room p90 <=45m2")
	check(percentile(principal, 0.5) >= 22.0, "principal room median >=22m2")
	check(percentile(principal, 0.5) <= 40.0, "principal room median <=40m2")
	check(percentile(floor_rooms, 0.5) >= 2.0 and percentile(floor_rooms, 0.5) <= 4.0, "typical floor has 2..4 substantial rooms")
	check(combat_floors * 10 >= floors_seen * 9, "90% of normal floors hold an 18m2 manoeuvre room")
	check(percentile(hall_widths, 0.5) >= 1.5 and percentile(hall_widths, 0.5) <= 2.0, "stair halls 1.5..2.0m")
	check(float(tiny) / maxi(1, rooms_total) <= 0.05, "occupied rooms below8m2 <=5%")
	check(excessive_degree == 0, "ordinary rooms have at most two connections")
	check(disconnected == 0, "all interiors satisfy geometry and connectivity contract")
	check(occupied / maxf(land, 1.0) >= 0.55, "historic building coverage >=55%")
	check(occupied / maxf(land, 1.0) <= 0.75, "historic building coverage <=75%")
	check(street_built / maxf(street_len, 1.0) >= 0.85, "buildable street frontage >=85%")
	check(void_len / maxf(perimeter, 1.0) <= 0.05, "unclassified residual void <=5%")
	check(blanks_gt15 == 0, "no blank frontage run longer than 15m")
	check(facade_wings * 10 >= street_wings * 9, "90% of historic street wings carry a room-derived facade plan")
	check(facade_differs * 10 >= facade_wings * 9, "planned openings replace the legacy spacing rule")
	check(shopfront_wings * 4 >= facade_wings, "a quarter of street wings have ground-floor shopfronts")

func frontage_line(a: Vector2, b: Vector2) -> String:
	return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#ff2d2d" stroke-width="3"/>' % [a.x, a.y, b.x, b.y]

func _in_garden(point: Vector2, garden_polys: Array[PackedVector2Array]) -> bool:
	# A garden strip behind a set-back facade is often barely a metre deep, so a
	# point-in-polygon test 1 m inside the line misses it. Proximity to the garden
	# surface is what makes the frontage an intentional use, not bare ground.
	for poly: PackedVector2Array in garden_polys:
		if poly.size() < 3:
			continue
		var near := Geometry2D.get_closest_point_to_segment(point, poly[poly.size() - 1], poly[0])
		var best := point.distance_to(near)
		for i in poly.size() - 1:
			near = Geometry2D.get_closest_point_to_segment(point, poly[i], poly[i + 1])
			best = minf(best, point.distance_to(near))
		if best <= 1.6:
			return true
		if Geometry2D.is_point_in_polygon(point, poly):
			return true
	return false

func poly_bounds(poly: PackedVector2Array) -> Rect2:
	var box := Rect2(poly[0], Vector2.ZERO)
	for point: Vector2 in poly:
		box = box.expand(point)
	return box

func polyline_distance(p: Vector2, line: PackedVector2Array) -> float:
	var best := INF
	for i in maxi(0, line.size() - 1):
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, line[i], line[i + 1])))
	return best

func classify_edge(probe: Vector2, city: CityPlan, roads: Array, polys: Array[PackedVector2Array], boxes: Array[Rect2]) -> String:
	for i in polys.size():
		if boxes[i].has_point(probe) and Geometry2D.is_point_in_polygon(probe, polys[i]):
			return "party"
	for road: Dictionary in roads:
		if polyline_distance(probe, road["polyline"] as PackedVector2Array) <= 8.0:
			return "street"
	return "void"

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		print("[PragueGameplayTest] FAIL " + message)

func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	values.sort()
	return values[mini(values.size() - 1, int(values.size() * fraction))]

func percentiles(values: Array[float]) -> Array:
	return [snappedf(percentile(values, 0.1), 0.01), snappedf(percentile(values, 0.5), 0.01), snappedf(percentile(values, 0.9), 0.01)]

func svg_polygon(poly: PackedVector2Array, color: String) -> String:
	var points := ""
	for p: Vector2 in poly:
		points += "%f,%f " % [p.x, p.y]
	return '<polygon points="%s" fill="%s" stroke="#333333" stroke-width="0.25"/>' % [points, color]
