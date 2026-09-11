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
		if length < 6.8:
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
			if cursor >= length - 6.0:
				break
			var id := "%s_plot_%d_%d" % [block.id, edge, i]
			var span := length * weights[i] / weight_sum
			var width := minf(23.0, span - 0.18)
			# The street wall is laid out as a walk along the edge: each house
			# starts where the previous one ended. A house the fitter has to
			# narrow therefore leaves no hole in the frontage, which is what
			# keeps the wall closed; the width variety still comes from the
			# weighted spans.
			var center_t := clampf(cursor + width * 0.5, 0.0, maxf(length - 0.09, 0.0))
			stats["candidates"] = int(stats["candidates"]) + 1
			if width < 9.0:
				stats["narrow_candidates"] = int(stats["narrow_candidates"]) + 1
			if width < 6.0:
				stats["skipped_too_narrow"] = int(stats["skipped_too_narrow"]) + 1
				cursor += span
				continue
			var front := a + tangent * center_t + inward * 0.12
			var target := lerpf(13.0, 16.0, Streets.unit(seed, "historic_plot_depth", [WorldSeed.str_hash(id)]))
			var lot := fit_frontage(front, tangent, inward, width, target, polygon, result)
			if lot.size == Vector2.ZERO:
				cursor += span
				continue
			width = lot.size.x
			cursor = center_t + width * 0.5 + 0.18
			stats["allocated"] = int(stats["allocated"]) + 1
			if width < 9.0:
				stats["narrow_allocated"] = int(stats["narrow_allocated"]) + 1
			var plot := {"id": id, "block_id": block.id, "rect": lot, "yaw": yaw,
				"polygon": CityPlan._lot_corners(lot, yaw), "frontage_m": width,
				"depth_m": lot.size.y, "frontage_center": front,
				"owner_chunk": WorldSeed.chunk_coord(lot.get_center().x, lot.get_center().y)}
			result.append(plot)
	seal_street_frontage(str(block.id), polygon, result, seed)
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

## Street-wall continuity. The bay allocator can still leave an 8-15 m hole in a
## street wall - a bay whose fit failed, a plot whose frontage the fitter
## widened, an edge shorter than a full bay. Blank street wall is the most
## visible Prague defect and the one the density target is really about, so
## after the main pass every uncovered run of buildable boundary gets its own
## house, at the shallowest depth that still fits.
static func seal_street_frontage(block_id: String, polygon: PackedVector2Array, result: Array[Dictionary], seed: int) -> void:
	for edge in polygon.size():
		var a := polygon[edge]
		var b := polygon[(edge + 1) % polygon.size()]
		var length := a.distance_to(b)
		if length < 4.0:
			continue
		var tangent := (b - a).normalized()
		var inward := Vector2(-tangent.y, tangent.x)
		if not Geometry2D.is_point_in_polygon((a + b) * 0.5 + inward, polygon):
			inward = -inward
		var samples := maxi(2, ceili(length / 0.5))
		var step := length / float(samples)
		var covered: Array[bool] = []
		for i in samples:
			covered.append(_frontage_covered(a + tangent * (step * (float(i) + 0.5)), result))
		var run_start := -1
		for i in samples + 1:
			var solid := i < samples and covered[i]
			if not solid:
				if run_start < 0:
					run_start = i
			elif run_start >= 0:
				_fill_frontage_gap(block_id, edge, polygon, result, seed, a, tangent, inward, step, run_start, i)
				run_start = -1

## True when an allocated plot still presents a wall on this boundary point.
static func _frontage_covered(p: Vector2, result: Array[Dictionary]) -> bool:
	for plot: Dictionary in result:
		var rect: Rect2 = plot.rect
		var local := (p - rect.get_center()).rotated(-float(plot.yaw))
		if absf(local.x) <= rect.size.x * 0.5 + 0.7 and absf(local.y) <= rect.size.y * 0.5 + 0.7:
			return true
	return false

static func _fill_frontage_gap(block_id: String, edge: int, polygon: PackedVector2Array, result: Array[Dictionary],
		seed: int, a: Vector2, tangent: Vector2, inward: Vector2, step: float, first: int, last: int) -> void:
	var gap := float(last - first) * step
	var count := 0
	var span := 0.0
	var width := 0.0
	if gap >= 3.2:
		count = maxi(1, roundi(gap / 11.5))
		span = gap / float(count)
		width = minf(23.0, span - 0.18)
		if width < 5.9 and count > 1:
			count = 1
			span = gap
			width = minf(23.0, gap - 0.18)
	var yaw := atan2(tangent.y, tangent.x)
	var filled := false
	for i in count:
		var id := "%s_seal_%d_%d" % [block_id, edge, first + i]
		var center_t := step * (float(first) + span * (float(i) + 0.5))
		var front := a + tangent * center_t + inward * 0.12
		var roll := Streets.unit(seed, "historic_seal_depth", [WorldSeed.str_hash(id)])
		for depth in [lerpf(12.0, 16.0, roll), 12.0, 10.0, 8.0, 6.5]:
			var lot := fit_frontage(front, tangent, inward, width, float(depth), polygon, result)
			if lot.size == Vector2.ZERO:
				continue
			result.append({"id": id, "block_id": block_id, "rect": lot, "yaw": yaw,
				"polygon": CityPlan._lot_corners(lot, yaw), "frontage_m": lot.size.x,
				"depth_m": lot.size.y, "frontage_center": front,
				"owner_chunk": WorldSeed.chunk_coord(lot.get_center().x, lot.get_center().y)})
			stats["seal_filled"] = int(stats.get("seal_filled", 0)) + 1
			stats["allocated"] = int(stats["allocated"]) + 1
			filled = true
			break
	if not filled:
		if gap < 3.2:
			stats["seal_gap_short"] = int(stats.get("seal_gap_short", 0)) + 1
		# A blank wall is the defect. Where no new plot fits - a corner sliver, a
		# gap narrower than a house, a spot where the block is too shallow - the
		# neighbouring house on the same street line takes the frontage instead.
		if _absorb_frontage_gap(polygon, result, a, tangent, inward, step, first, last):
			stats["seal_widened"] = int(stats.get("seal_widened", 0)) + 1
		else:
			stats["seal_unfilled"] = int(stats.get("seal_unfilled", 0)) + 1

## Street-wall closure by widening an existing house, which is how a real street
## wall stays continuous: plots merge and the survivor's frontage grows.
static func _absorb_frontage_gap(polygon: PackedVector2Array, result: Array[Dictionary],
		a: Vector2, tangent: Vector2, inward: Vector2, step: float, first: int, last: int) -> bool:
	var yaw := atan2(tangent.y, tangent.x)
	var gap_lo := step * float(first)
	var gap_hi := step * float(last)
	var best := -1
	var best_cost := INF
	var best_width := 0.0
	var best_center := 0.0
	var best_offset := 0.0
	for i in result.size():
		var plot: Dictionary = result[i]
		if absf(wrapf(float(plot.yaw) - yaw, -PI, PI)) > 0.05:
			continue
		var rect: Rect2 = plot.rect
		var local := (rect.get_center() - a).rotated(-yaw)
		var lo := local.x - rect.size.x * 0.5
		var hi := local.x + rect.size.x * 0.5
		var widen_lo := lo
		var widen_hi := hi
		var cost := INF
		if absf(hi - gap_lo) <= 1.6:
			cost = absf(hi - gap_lo)
			widen_hi = maxf(hi, gap_hi)
		elif absf(lo - gap_hi) <= 1.6:
			cost = absf(lo - gap_hi)
			widen_lo = minf(lo, gap_lo)
		else:
			continue
		var merged_width := widen_hi - widen_lo
		if merged_width > 34.0 or merged_width <= rect.size.x or cost >= best_cost:
			continue
		best_cost = cost
		best = i
		best_width = merged_width
		best_center = (widen_lo + widen_hi) * 0.5
		best_offset = maxf(local.y - rect.size.y * 0.5, 0.06)
	if best < 0:
		return false
	var depth: float = (result[best].rect as Rect2).size.y
	var others: Array[Dictionary] = []
	for k in result.size():
		if k != best:
			others.append(result[k])
	var front := a + tangent * best_center + inward * best_offset
	var lot := fit_frontage(front, tangent, inward, best_width, depth, polygon, others)
	if lot.size == Vector2.ZERO:
		return false
	result[best].rect = lot
	result[best].polygon = CityPlan._lot_corners(lot, yaw)
	result[best].frontage_m = lot.size.x
	result[best].frontage_center = front
	return true

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
	var front_depth := minf(lerpf(14.5, 17.5, roll), d)
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
	if has_court and d >= 21.0 and roll >= 0.24:
		rear_depth = clampf(d - front_depth - 4.4, 4.2, 9.8)
		wings.append({"id": id + "_rear", "role": &"rear", "local_rect": Rect2(0, d - rear_depth, w, rear_depth), "door_edge": 0})
		form = &"front_rear"
	# A side wing is 3.0 m wide, so it needs >=4.2 m of court depth to clear the
	# contract footprint minimum (12 m2); a shallower court takes no side wing.
	if has_court and d - front_depth - rear_depth >= 4.2 and w >= 8.6 and roll >= 0.16:
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
