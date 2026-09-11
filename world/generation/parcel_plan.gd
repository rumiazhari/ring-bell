class_name ParcelPlan
extends RefCounted
const Streets = preload("res://world/generation/historic_street_plan.gd")
## Persistent plots are allocated before wings. Entire plot envelopes reserve
## land, including the court, so later infill cannot build over their access.

## Plan-layer allocation counters, for harnesses only (same idea as
## CityPlan.debug_profiling): how many plot candidates each stage drops, so a
## morphology run can show WHY the frontage distribution looks the way it does.
static var stats := {"candidates": 0, "narrow_candidates": 0, "narrow_allocated": 0,
	"skipped_too_narrow": 0, "failed_fit": 0, "failed_overlap": 0, "allocated": 0}

static func reset_stats() -> void:
	for key: String in stats:
		stats[key] = 0

static func for_block(block: Dictionary, seed: int) -> Array[Dictionary]:
	var polygon: PackedVector2Array = simplify(block.polygon)
	var result: Array[Dictionary] = []
	for edge in polygon.size():
		var a := polygon[edge]
		var b := polygon[(edge + 1) % polygon.size()]
		var length := a.distance_to(b)
		if length < 9.2:
			continue
		var tangent := (b - a).normalized()
		var inward := Vector2(-tangent.y, tangent.x)
		if not Geometry2D.is_point_in_polygon((a + b) * 0.5 + inward, polygon):
			inward = -inward
		var yaw := atan2(tangent.y, tangent.x)
		var count := maxi(1, roundi(length / 11.5))
		# Frontages vary per plot instead of tiling the edge uniformly: historic
		# Prague runs from narrow ~6 m houses to ~15 m corner properties, and the
		# weighted span split is what produces that spread along one street wall.
		var weights: Array[float] = []
		var weight_sum := 0.0
		for i in count:
			var weight := lerpf(0.62, 1.35, Streets.unit(seed, "historic_plot_width", [WorldSeed.str_hash("%s_plot_%d_%d" % [block.id, edge, i])]))
			if Streets.unit(seed, "historic_merged_plot", [WorldSeed.str_hash(str(block.id)), edge, i]) > 0.9:
				weight *= 1.7
			weights.append(weight)
			weight_sum += weight
		var cursor := 0.0
		for i in count:
			var id := "%s_plot_%d_%d" % [block.id, edge, i]
			var span := length * weights[i] / weight_sum
			var width := minf(23.0, span - 0.18)
			var center_t := cursor + span * 0.5
			cursor += span
			stats["candidates"] = int(stats["candidates"]) + 1
			if width < 9.0:
				stats["narrow_candidates"] = int(stats["narrow_candidates"]) + 1
			if width < 6.0:
				stats["skipped_too_narrow"] = int(stats["skipped_too_narrow"]) + 1
				continue
			var front := a + tangent * center_t + inward * 0.12
			var target := lerpf(13.0, 16.0, Streets.unit(seed, "historic_plot_depth", [WorldSeed.str_hash(id)]))
			var lot := fit_frontage(front, tangent, inward, width, target, polygon, result)
			if lot.size == Vector2.ZERO:
				continue
			width = lot.size.x
			stats["allocated"] = int(stats["allocated"]) + 1
			if width < 9.0:
				stats["narrow_allocated"] = int(stats["narrow_allocated"]) + 1
			var plot := {"id": id, "block_id": block.id, "rect": lot, "yaw": yaw,
				"polygon": CityPlan._lot_corners(lot, yaw), "frontage_m": width,
				"depth_m": lot.size.y, "frontage_center": front,
				"owner_chunk": WorldSeed.chunk_coord(lot.get_center().x, lot.get_center().y)}
			result.append(plot)
	for plot: Dictionary in result:
		var original: Rect2 = plot.rect
		var direction := Vector2(-sin(float(plot.yaw)), cos(float(plot.yaw)))
		var target := lerpf(25.0, 42.0, Streets.unit(seed, "historic_plot_rear", [WorldSeed.str_hash(plot.id)]))
		for depth in [target, 25.0, 22.0, 20.0, 18.0, 16.0, original.size.y]:
			if float(depth) < original.size.y:
				continue
			var center: Vector2 = plot.frontage_center + direction * float(depth) * 0.5
			var candidate := Rect2(center - Vector2(original.size.x, depth) * 0.5, Vector2(original.size.x, depth))
			var area := 0.0
			for piece: PackedVector2Array in Geometry2D.intersect_polygons(CityPlan._lot_corners(candidate, plot.yaw), polygon):
				area += absf(CityPlan._polygon_area(piece))
			if absf(area - candidate.get_area()) > 0.03:
				continue
			var overlaps := false
			for other: Dictionary in result:
				if other.id != plot.id and CityPlan._lots_overlap(candidate, plot.yaw, other.rect, other.yaw, 0.03):
					overlaps = true
					break
			if not overlaps:
				plot.rect = candidate
				plot.depth_m = float(depth)
				plot.polygon = CityPlan._lot_corners(candidate, plot.yaw)
				plot.owner_chunk = WorldSeed.chunk_coord(center.x, center.y)
				break
		plot.merge(compound(plot, seed))
	return result

static func fit_frontage(front: Vector2, tangent: Vector2, inward: Vector2,
		width: float, target: float, polygon: PackedVector2Array, reserved: Array[Dictionary]) -> Rect2:
	var yaw := atan2(tangent.y, tangent.x)
	# At crooked party walls a modest width adjustment can retain a house;
	# discarding the entire bay used to leave a 10-15m hole in the street.
	for reduction in [0.0, 0.6, 1.2, 2.0, 3.0, 4.0]:
		var fitted_width := width - float(reduction)
		if fitted_width < 6.0:
			continue
		for depth in [target, 12.0, 10.0]:
			var center := front + inward * float(depth) * 0.5
			var candidate := Rect2(center - Vector2(fitted_width, depth) * 0.5, Vector2(fitted_width, depth))
			var area := 0.0
			for piece: PackedVector2Array in Geometry2D.intersect_polygons(CityPlan._lot_corners(candidate, yaw), polygon):
				area += absf(CityPlan._polygon_area(piece))
			if absf(area - candidate.get_area()) > 0.03:
				stats["failed_fit"] = int(stats["failed_fit"]) + 1
				continue
			var overlap := false
			for previous: Dictionary in reserved:
				if CityPlan._lots_overlap(candidate, yaw, previous.rect, previous.yaw, 0.03):
					overlap = true
					break
			if not overlap:
				return candidate
			stats["failed_overlap"] = int(stats["failed_overlap"]) + 1
	return Rect2()

static func compound(plot: Dictionary, seed: int) -> Dictionary:
	var id := str(plot.id)
	var w: float = plot.frontage_m
	var d: float = plot.depth_m
	var roll := Streets.unit(seed, "historic_compound_form", [WorldSeed.str_hash(id)])
	var court_roll := Streets.unit(seed, "historic_court", [WorldSeed.str_hash(id)])
	var front_depth := minf(lerpf(13.0, 16.0, roll), d)
	if d >= 14.0 and court_roll >= 0.18:
		front_depth = minf(front_depth, d - 4.2)
	var wings: Array[Dictionary] = [{"id": id + "_front", "role": &"front",
		"local_rect": Rect2(0, 0, w, front_depth), "door_edge": 0}]
	var form := &"I"
	var rear_depth := 0.0
	var side_width := 0.0
	var second_width := 0.0
	# Courtyards are the Prague norm, not a universal: a minority of plots are
	# built solid, which is also what keeps some blocks impermeable (spec 5, 6).
	var has_court := d - front_depth >= 4.0 and court_roll >= 0.18
	if not has_court:
		front_depth = d
		wings[0].local_rect = Rect2(0, 0, w, d)
	if has_court and d >= 28.0 and roll >= 0.32:
		rear_depth = 9.8
		wings.append({"id": id + "_rear", "role": &"rear", "local_rect": Rect2(0, d - rear_depth, w, rear_depth), "door_edge": 0})
		form = &"front_rear"
	if has_court and d - front_depth - rear_depth >= 5.0 and w >= 9.7 and roll >= 0.16:
		side_width = 3.0
		wings.append({"id": id + "_side", "role": &"side", "local_rect": Rect2(0, front_depth, side_width, d - front_depth - rear_depth), "door_edge": 1})
		form = &"courtyard_house" if rear_depth > 0.0 else &"L"
		if w >= 10.2 and roll > 0.72:
			second_width = 3.0
			wings.append({"id": id + "_side2", "role": &"side", "local_rect": Rect2(w - second_width, front_depth, second_width, d - front_depth - rear_depth), "door_edge": 3})
			form = &"U"
	var court := Rect2(side_width, front_depth, w - side_width - second_width, d - front_depth - rear_depth)
	var courtyards: Array[Dictionary] = []
	var passages: Array[Dictionary] = []
	if has_court:
		courtyards.append({"id": id + "_court", "local_rect": court, "plot_id": id,
			"area_m2": court.get_area(), "use": &"service" if roll < 0.5 else &"social",
			"surface": &"courtyard_paving", "access": true})
		# Access varies: most courts are entered from the street through a covered
		# carriage passage, some are served from the rear lane instead, and a
		# minority carry a second link. A court is never left unreachable.
		var from_street := court_roll >= 0.42
		var access_width := lerpf(1.5, 2.6, court_roll)
		var access := {"id": id + "_entry_passage", "plot_id": id, "wing_id": id + "_front",
			"kind": &"street_courtyard" if from_street else &"rear_lane_courtyard",
			"covered": from_street, "width": access_width, "court_id": id + "_court"}
		if from_street:
			access.local_rect = Rect2(w * 0.5 - access_width * 0.5, 0.0, access_width, front_depth)
		else:
			var lane_depth := rear_depth if rear_depth > 0.0 else minf(4.0, court.size.y)
			access.local_rect = Rect2(w * 0.5 - access_width * 0.5, d - lane_depth, access_width, lane_depth)
		passages.append(access)
		if court_roll >= 0.78:
			var link_width := 1.4
			passages.append({"id": id + "_court_link", "plot_id": id, "wing_id": id + "_side",
				"kind": &"court_link", "covered": false, "width": link_width, "court_id": id + "_court",
				"local_rect": Rect2(0.0, front_depth, link_width, maxf(court.size.y, 1.0))})
	var layer := &"medieval_core" if roll < 0.65 else &"rebuilt_front"
	var cellars: Array[Dictionary] = [{"id": id + "_cellar", "plot_id": id,
		"wing_id": id + "_front", "kind": &"vaulted_cellar" if roll < 0.55 else &"storage_cellar",
		"local_rect": Rect2(0.5, 0.5, w - 1.0, front_depth - 1.0),
		"floor_y": -2.8, "headroom": 2.3, "materialized": false, "connection_policy": &"reserved_stair"}]
	return {"form": form, "wings": wings, "courtyards": courtyards, "passages": passages,
		"cellars": cellars, "historical_layer": layer}

static func simplify(poly: PackedVector2Array) -> PackedVector2Array:
	var out := poly.duplicate()
	var changed := true
	while changed and out.size() > 3:
		changed = false
		for i in out.size():
			var a := out[posmod(i - 1, out.size())]
			var b := out[(i + 1) % out.size()]
			if a.distance_to(b) < 0.01 or absf((out[i] - a).cross(b - a)) / a.distance_to(b) < 0.02:
				out.remove_at(i)
				changed = true
				break
	return out
