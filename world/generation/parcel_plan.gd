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
		var count := maxi(1, roundi(length / 11.0))
		# Frontages vary per plot instead of tiling the edge uniformly: historic
		# Prague runs from narrow ~6 m houses to ~15 m corner properties, and the
		# weighted span split is what produces that spread along one street wall.
		var weights: Array[float] = []
		var weight_sum := 0.0
		for i in count:
			var weight := lerpf(0.62, 1.35, Streets.unit(seed, "historic_plot_width", [WorldSeed.str_hash("%s_plot_%d_%d" % [block.id, edge, i])]))
			weights.append(weight)
			weight_sum += weight
		var cursor := 0.0
		for i in count:
			var id := "%s_plot_%d_%d" % [block.id, edge, i]
			var span := length * weights[i] / weight_sum
			var width := minf(15.0, span - 0.18)
			var center_t := cursor + span * 0.5
			cursor += span
			stats["candidates"] = int(stats["candidates"]) + 1
			if width < 9.0:
				stats["narrow_candidates"] = int(stats["narrow_candidates"]) + 1
			if width < 6.0:
				stats["skipped_too_narrow"] = int(stats["skipped_too_narrow"]) + 1
				continue
			var front := a + tangent * center_t + inward * 0.12
			var target := lerpf(27.0, 45.0, Streets.unit(seed, "historic_plot_depth", [WorldSeed.str_hash(id)]))
			# A narrow street house is shallower as well as narrower: a 7 m x 45 m
			# sliver cannot sit inside a convex block face, and Prague's narrow
			# houses are not deeper than their wide neighbours.
			var max_depth := clampf(width * 3.0, 12.0, 45.0)
			var lot := Rect2()
			for depth in [minf(target, max_depth), minf(target * 0.85, max_depth),
					minf(25.0, max_depth), minf(17.0, max_depth), minf(12.0, max_depth)]:
				var center := front + inward * float(depth) * 0.5
				var candidate := Rect2(center - Vector2(width, depth) * 0.5, Vector2(width, depth))
				var corners := CityPlan._lot_corners(candidate, yaw)
				var intersection := Geometry2D.intersect_polygons(corners, polygon)
				var inside_area := 0.0
				for piece: PackedVector2Array in intersection:
					inside_area += absf(CityPlan._polygon_area(piece))
				if absf(inside_area - width * float(depth)) > 0.03:
					stats["failed_fit"] = int(stats["failed_fit"]) + 1
					continue
				var overlaps := false
				for previous: Dictionary in result:
					if CityPlan._lots_overlap(candidate, yaw, previous.rect, previous.yaw, 0.03):
						overlaps = true
						break
				if not overlaps:
					lot = candidate
					break
				stats["failed_overlap"] = int(stats["failed_overlap"]) + 1
			if lot.size == Vector2.ZERO:
				continue
			stats["allocated"] = int(stats["allocated"]) + 1
			if width < 9.0:
				stats["narrow_allocated"] = int(stats["narrow_allocated"]) + 1
			var plot := {"id": id, "block_id": block.id, "rect": lot, "yaw": yaw,
				"polygon": CityPlan._lot_corners(lot, yaw), "frontage_m": width,
				"depth_m": lot.size.y, "frontage_center": front,
				"owner_chunk": WorldSeed.chunk_coord(lot.get_center().x, lot.get_center().y)}
			plot.merge(compound(plot, seed))
			result.append(plot)
	return result

static func compound(plot: Dictionary, seed: int) -> Dictionary:
	var id := str(plot.id)
	var w: float = plot.frontage_m
	var d: float = plot.depth_m
	var roll := Streets.unit(seed, "historic_compound_form", [WorldSeed.str_hash(id)])
	var court_roll := Streets.unit(seed, "historic_court", [WorldSeed.str_hash(id)])
	var front_depth := minf(10.2, d)
	var wings: Array[Dictionary] = [{"id": id + "_front", "role": &"front",
		"local_rect": Rect2(0, 0, w, front_depth), "door_edge": 0}]
	var form := &"I"
	var rear_depth := 0.0
	var side_width := 0.0
	var second_width := 0.0
	# Courtyards are the Prague norm, not a universal: a minority of plots are
	# built solid, which is also what keeps some blocks impermeable (spec 5, 6).
	var has_court := d - front_depth >= 4.0 and court_roll >= 0.18
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
