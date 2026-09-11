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
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="1400" viewBox="-450 -450 900 900"><rect x="-450" y="-450" width="900" height="900" fill="#343c40"/>'
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
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var length := a.distance_to(b)
			perimeter += length
			var samples := maxi(1, ceili(length / 0.5))
			for j in samples:
				var point := a.lerp(b, (float(j) + 0.5) / samples)
				var distance := INF
				for outline: PackedVector2Array in outlines:
					for k in outline.size():
						distance = minf(distance, point.distance_to(Geometry2D.get_closest_point_to_segment(point, outline[k], outline[(k + 1) % outline.size()])))
				if distance <= 0.75:
					occupied_boundary += length / samples
		for plot: Dictionary in block.get("plots", []):
			frontage += float(plot.frontage_m)
			widths.append(float(plot.frontage_m))
		for spec: Dictionary in block.buildings:
			svg += svg_polygon(CityPlan._lot_corners(spec.rect, spec.yaw), "#9b604e")
			occupied += (spec.rect as Rect2).get_area()
			var manifest := InteriorPlan.build_for_building(spec)
			if not InteriorPlan.validate(manifest).is_empty():
				disconnected += 1
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
				if str(spec.wing_role) == "front":
					counts.append(float(count))
					principal.append(biggest)
	var raster := Image.new()
	print("[PragueGameplayTest] actual street elevations / block perimeter = ", occupied_boundary / maxf(perimeter, 1.0))
	raster.load_svg_from_string(svg + "</svg>")
	raster.save_png("res://.hermes/autopilot/reports/prague-gameplay-pass/plan-%d.png" % seed)
	print("[PragueGameplayTest] seed=%d generation_and_measure_ms=%d occupied_rooms=%d area_p10/50/90=%s room_count_p10/50/90=%s principal_p50=%.2f tiny_share=%.3f door_degree_gt2=%d invalid_interiors=%d footprint=%.3f frontage=%.3f frontage_width_p10/50/90=%s" % [seed, Time.get_ticks_msec() - started, rooms_total, percentiles(areas), percentiles(counts), percentile(principal, 0.5), float(tiny) / maxi(1, rooms_total), excessive_degree, disconnected, occupied / maxf(land, 1.0), frontage / maxf(perimeter, 1.0), percentiles(widths)])
	check(percentile(areas, 0.5) >= 15.0, "occupied room median >=15m2")
	check(percentile(principal, 0.5) >= 22.0, "principal room median >=22m2")
	check(float(tiny) / maxi(1, rooms_total) <= 0.05, "occupied rooms below8m2 <=5%")
	check(excessive_degree == 0, "ordinary rooms have at most two connections")
	check(disconnected == 0, "all interiors satisfy geometry and connectivity contract")
	check(occupied / maxf(land, 1.0) >= 0.55, "historic building coverage >=55%")
	check(occupied_boundary / maxf(perimeter, 1.0) >= 0.85, "historic street frontage >=85%")

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
