extends Node
## One-off P2B-DENSE diagnostic: why do large dense faces stay near-empty?
## godot --headless --path . -- --g10p2b-denseprobe
## Read-only against CityPlan(19041207); prints per-face facts, no scene edits.

func _ready() -> void:
	CityPlan.debug_profiling = true
	var plan := CityPlan.new(19041207)
	var edges: Array = (plan.road_graph().get("edges", []) as Array)
	CityPlan.debug_profiling = false
	print("[DenseProbe] edges=", edges.size())
	var shown := 0
	var buckets := {"<3k": 0, "3-6k": 0, "6-10k": 0, "10k+": 0}
	var bucket_area := {"<3k": 0.0, "3-6k": 0.0, "6-10k": 0.0, "10k+": 0.0}
	for block in plan.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if center.length() >= 600.0:
			continue
		if str(block.get("kind", "")) != "built":
			continue
		var poly: PackedVector2Array = block.get("polygon",
				PackedVector2Array()) as PackedVector2Array
		var area := absf(CityPlan._polygon_area(poly))
		var buildings: Array = block.get("buildings", []) as Array
		var occupied := 0.0
		for spec_variant in buildings:
			var lot: Rect2 = (spec_variant as Dictionary).get("rect", Rect2()) as Rect2
			occupied += lot.size.x * lot.size.y
		var residual := maxf(area - occupied, 0.0)
		var courtyard := float(block.get("courtyard_area_m2", 0.0))
		if residual > area * 0.55 and courtyard < residual * 0.70:
			var key := "<3k" if area < 3000.0 else ("3-6k" if area < 6000.0 \
					else ("6-10k" if area < 10000.0 else "10k+"))
			buckets[key] = int(buckets[key]) + 1
			bucket_area[key] = float(bucket_area[key]) + residual
	print("[DenseProbe] underfilled_histogram counts=", buckets,
			" residual_m2=", bucket_area)
	for block in plan.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if center.length() >= 600.0:
			continue
		if str(block.get("kind", &"built")) != "built":
			continue
		var poly: PackedVector2Array = block.get("polygon",
				PackedVector2Array()) as PackedVector2Array
		var area := absf(CityPlan._polygon_area(poly))
		var buildings: Array = block.get("buildings", []) as Array
		if area < 6000.0 or buildings.size() >= 6:
			continue
		var bounds: Rect2 = block.get("bounds", Rect2()) as Rect2
		var total := 0
		var inside := 0
		var valid := 0
		var near_road := 0
		for gx in range(9):
			for gz in range(9):
				var p := bounds.position + Vector2(
						bounds.size.x * float(gx) / 8.0,
						bounds.size.y * float(gz) / 8.0)
				total += 1
				if not plan._polygon_contains(poly, p):
					continue
				inside += 1
				if plan._is_valid_city_land(p):
					valid += 1
				if plan._distance_to_city_road_raw(p) < 12.0:
					near_road += 1
		var passage: Dictionary = block.get("passage", {}) as Dictionary
		print("[DenseProbe] id=", block.get("id", "?"), " area=", snappedf(area, 1.0),
				" n_build=", buildings.size(),
				" district=", str(block.get("district", "?")),
				" grid_inside=", inside, "/", total,
				" valid=", valid,
				" near_road=", near_road,
				" passage=", (not passage.is_empty()),
				" road_conn=", bool(passage.get("road_connected", false)),
				" bounds_n=", poly.size())
		shown += 1
		if shown >= 14:
			break
	print("[DenseProbe] done faces_shown=", shown)
	get_tree().quit(0)
