extends Node
## Focused terrain determinism harness -- --terraintest

var failures := 0

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[TerrainTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[TerrainTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[TerrainTest] PASS: %s" % label)
	else:
		failures += 1
		if detail != "":
			print("[TerrainTest] FAIL: %s -- %s" % [label, detail])
		else:
			print("[TerrainTest] FAIL: %s" % label)

func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	var alt_a := canonical + 1234567
	var alt_b := canonical + 7654321

	# Use explicit-seed instances so we don't mutate global seed mid-test
	var tp := TerrainPlan.new(canonical)
	var tp_alt_a := TerrainPlan.new(alt_a)
	var tp_alt_b := TerrainPlan.new(alt_b)
	var wp := WorldPlan.new(canonical)
	var tp2 := TerrainPlan.new(canonical)

	# Coordinate sets
	var origin := Vector2.ZERO
	var neg := Vector2(-512.3, -768.7)
	var pos_far := Vector2(3000.0, -2100.0)
	var boundary_inside := Vector2(8191.0, 0.0)
	var boundary_outside := Vector2(8192.0, 0.0)
	var boundary_margin := Vector2(8185.0, 8185.0)
	var chunk_seams: Array[Vector2] = []
	for base in [Vector2(64, 64), Vector2(-64, 128), Vector2(256, 256), Vector2(-256, -256)]:
		chunk_seams.append(base)
		chunk_seams.append(base + Vector2(0.5, 0))
		chunk_seams.append(base + Vector2(-0.5, 0))
	var landscape_seams: Array[Vector2] = [Vector2(256, 0), Vector2(0, 256), Vector2(-256, 512), Vector2(512, -256)]

	# 1. Same-seed equality under forward/reverse/randomized query order
	var pts: Array[Vector2] = [origin, neg, pos_far, boundary_inside, Vector2(100, 200), Vector2(-33, 77), Vector2(1024, 1024)]
	var rev: Array[Vector2] = pts.duplicate()
	rev.reverse()
	var shuffled: Array[Vector2] = [pts[3], pts[0], pts[5], pts[1], pts[4], pts[2], pts[6]]
	for p in pts:
		var h1 := tp.height_at(p)
		var h2 := tp2.height_at(p)
		_check("same-seed height %s" % p, is_equal_approx(h1, h2), "%f vs %f" % [h1, h2])
		_check("same-seed slope %s" % p, is_equal_approx(tp.slope_at(p), tp2.slope_at(p)), str(p))
		_check("same-seed normal %s" % p, tp.normal_at(p).is_equal_approx(tp2.normal_at(p)), str(p))
		_check("same-seed class %s" % p, tp.terrain_class_at(p) == tp2.terrain_class_at(p), "%s vs %s" % [tp.terrain_class_at(p), tp2.terrain_class_at(p)])
		_check("same-seed material %s" % p, tp.surface_material_at(p) == tp2.surface_material_at(p), str(p))
		_check("same-seed buildable %s" % p, tp.is_buildable(p, Vector2(10, 10)) == tp2.is_buildable(p, Vector2(10, 10)), str(p))
	# profile order independence
	var rect := Rect2(-10, -10, 20, 20)
	var prof1 := tp.terrain_profile(rect, 5.0)
	var prof2 := tp2.terrain_profile(rect, 5.0)
	var prof_equal := prof1.size() == prof2.size()
	if prof_equal:
		for i in prof1.size():
			if not is_equal_approx(prof1[i], prof2[i]):
				prof_equal = false
				break
	_check("same-seed profile equality", prof_equal, "%d vs %d" % [prof1.size(), prof2.size()])
	# query order should not affect any point (exercise forward then reverse on same instance)
	for p in rev:
		_check("order-independent height %s" % p, is_equal_approx(tp.height_at(p), tp2.height_at(p)), str(p))
	for p in shuffled:
		_check("shuffled height %s" % p, is_equal_approx(tp.height_at(p), tp2.height_at(p)), str(p))

	# 2. Alternate seeds produce material heightfield difference, same vocab & boundary rules
	var diff_count_a := 0
	var diff_count_b := 0
	for p in pts:
		if not is_equal_approx(tp.height_at(p), tp_alt_a.height_at(p)):
			diff_count_a += 1
		if not is_equal_approx(tp.height_at(p), tp_alt_b.height_at(p)):
			diff_count_b += 1
		# vocab check for alt_a
		_check("alt-a class vocab %s" % p, WorldConstants.TERRAIN_CLASSES.has(tp_alt_a.terrain_class_at(p)), str(tp_alt_a.terrain_class_at(p)))
		_check("alt-a material vocab %s" % p, WorldConstants.SURFACE_MATERIALS.has(tp_alt_a.surface_material_at(p)), str(tp_alt_a.surface_material_at(p)))
		# vocab check for alt_b
		_check("alt-b class vocab %s" % p, WorldConstants.TERRAIN_CLASSES.has(tp_alt_b.terrain_class_at(p)), str(tp_alt_b.terrain_class_at(p)))
		_check("alt-b material vocab %s" % p, WorldConstants.SURFACE_MATERIALS.has(tp_alt_b.surface_material_at(p)), str(tp_alt_b.surface_material_at(p)))
	_check("alternate seed A height variation", diff_count_a >= 3, "diff %d/%d" % [diff_count_a, pts.size()])
	_check("alternate seed B height variation", diff_count_b >= 3, "diff %d/%d" % [diff_count_b, pts.size()])
	# boundary rules same for both alt seeds
	_check("alt-a outside not buildable", not tp_alt_a.is_buildable(boundary_outside, Vector2(10, 10)), str(boundary_outside))
	_check("alt-b outside not buildable", not tp_alt_b.is_buildable(boundary_outside, Vector2(10, 10)), str(boundary_outside))
	_check("alt-a boundary inside finite", is_finite(tp_alt_a.height_at(boundary_inside)), str(tp_alt_a.height_at(boundary_inside)))
	_check("alt-b boundary inside finite", is_finite(tp_alt_b.height_at(boundary_inside)), str(tp_alt_b.height_at(boundary_inside)))
	# alt_b also has valid origin basin buildable (or at least finite)
	_check("alt-b origin finite", is_finite(tp_alt_b.height_at(origin)), str(tp_alt_b.height_at(origin)))

	# 3. Finite, normalized, slope limits, continuity
	for p in pts + chunk_seams + landscape_seams:
		var h := tp.height_at(p)
		_check("finite height %s" % p, is_finite(h), str(h))
		var n := tp.normal_at(p)
		_check("finite normal %s" % p, n.is_finite(), str(n))
		_check("normalized normal %s" % p, absf(n.length() - 1.0) < WorldConstants.NORMAL_TOLERANCE, "len=%f" % n.length())
		var slope := tp.slope_at(p)
		_check("finite slope %s" % p, is_finite(slope), str(slope))
		_check("slope range %s" % p, slope >= 0.0 and slope <= 90.0, str(slope))
	_check("slope agrees with normal at origin", absf(tp.slope_at(origin) - rad_to_deg(acos(clampf(tp.normal_at(origin).dot(Vector3.UP), -1, 1)))) < 0.01, "")
	# continuity across seams: sample epsilon across boundary
	for base in chunk_seams:
		var a := tp.height_at(base - Vector2(0.01, 0))
		var b := tp.height_at(base + Vector2(0.01, 0))
		_check("64m seam continuity near %s" % base, absf(a - b) < 0.5, "%f vs %f diff %f" % [a, b, absf(a - b)])
	for base in landscape_seams:
		var a := tp.height_at(base - Vector2(0.01, 0))
		var b := tp.height_at(base + Vector2(0.01, 0))
		_check("256m seam continuity near %s" % base, absf(a - b) < 0.5, "%f vs %f diff %f" % [a, b, absf(a - b)])
	# exact lattice sample continuity: p exactly on cell boundary
	var cell_p := Vector2(64, 0)
	_check("exact chunk boundary finite", is_finite(tp.height_at(cell_p)), str(tp.height_at(cell_p)))
	_check("negative coord finite", is_finite(tp.height_at(neg)), str(neg))

	# 4. Deterministic class/material thresholds and buildability
	_check("origin basin buildable 10x10", tp.is_buildable(origin, Vector2(10, 10)), "origin %s class %s slope %f" % [origin, tp.terrain_class_at(origin), tp.slope_at(origin)])
	_check("outside boundary not buildable", not tp.is_buildable(boundary_outside, Vector2(10, 10)), str(boundary_outside))
	_check("footprint crossing boundary not buildable", not tp.is_buildable(boundary_margin, Vector2(20, 20)), str(boundary_margin))
	# deterministic cliff search: dense scan to guarantee cliff found
	var steep_point := Vector2.INF
	var cliff_point := Vector2.INF
	# coarse grid plus refined search around high-slope areas
	for x in range(-4000, 4001, 400):
		for y in range(-4000, 4001, 400):
			var q := Vector2(x, y)
			var s := tp.slope_at(q)
			if s > WorldConstants.BUILDABLE_MAX_SLOPE_DEG + 5.0 and steep_point == Vector2.INF:
				steep_point = q
			if tp.terrain_class_at(q) == &"cliff" and cliff_point == Vector2.INF:
				cliff_point = q
			if steep_point != Vector2.INF and cliff_point != Vector2.INF:
				break
		if steep_point != Vector2.INF and cliff_point != Vector2.INF:
			break
	# if not found, denser 100m grid
	if steep_point == Vector2.INF or cliff_point == Vector2.INF:
		for x in range(-3000, 3001, 200):
			for y in range(-3000, 3001, 200):
				var q := Vector2(x + 37.0, y - 19.0)
				if steep_point == Vector2.INF and tp.slope_at(q) > WorldConstants.BUILDABLE_MAX_SLOPE_DEG + 2.0:
					steep_point = q
				if cliff_point == Vector2.INF and tp.terrain_class_at(q) == &"cliff":
					cliff_point = q
				if steep_point != Vector2.INF and cliff_point != Vector2.INF:
					break
			if steep_point != Vector2.INF and cliff_point != Vector2.INF:
				break
	# assertions: must have found both
	_check("deterministic steep point found", steep_point != Vector2.INF, "no steep point in dense scan")
	_check("deterministic cliff point found", cliff_point != Vector2.INF, "no cliff in dense scan")
	if steep_point != Vector2.INF:
		_check("steep point not buildable %s" % steep_point, not tp.is_buildable(steep_point, Vector2(10, 10)), "slope %f" % tp.slope_at(steep_point))
		_check("steep allows with allow_cliff/high max_slope %s" % steep_point, tp.is_buildable(steep_point, Vector2(10, 10), {"max_slope_deg": 90.0, "allow_cliff": true}), str(steep_point))
	if cliff_point != Vector2.INF:
		_check("cliff class slope >= threshold %s" % cliff_point, tp.slope_at(cliff_point) >= WorldConstants.CLIFF_SLOPE_DEG - 0.01, "slope %f" % tp.slope_at(cliff_point))
		_check("cliff material is rock %s" % cliff_point, tp.surface_material_at(cliff_point) == &"rock", str(tp.surface_material_at(cliff_point)))
		_check("cliff not buildable by default %s" % cliff_point, not tp.is_buildable(cliff_point, Vector2(10, 10)), "slope %f" % tp.slope_at(cliff_point))
		_check("cliff buildable with allow_cliff %s" % cliff_point, tp.is_buildable(cliff_point, Vector2(10, 10), {"allow_cliff": true, "max_slope_deg": 90.0}), str(cliff_point))
	# constraints override
	_check("max_slope override respected", not tp.is_buildable(origin, Vector2(10, 10), {"max_slope_deg": -1.0}), "should reject with -1 deg")
	# class/material vocab for canonical
	for p in pts:
		_check("class vocab %s" % p, WorldConstants.TERRAIN_CLASSES.has(tp.terrain_class_at(p)), str(tp.terrain_class_at(p)))
		_check("material vocab %s" % p, WorldConstants.SURFACE_MATERIALS.has(tp.surface_material_at(p)), str(tp.surface_material_at(p)))

	# 5. WorldPlan forwarding
	for p in pts:
		_check("WorldPlan height matches %s" % p, is_equal_approx(wp.terrain_height_at(p), tp.height_at(p)), "%f vs %f" % [wp.terrain_height_at(p), tp.height_at(p)])
		_check("WorldPlan slope matches %s" % p, is_equal_approx(wp.terrain_slope_at(p), tp.slope_at(p)), str(p))
		_check("WorldPlan class matches %s" % p, wp.terrain_class_at(p) == tp.terrain_class_at(p), str(p))
		var wp_mat: StringName = wp.terrain_surface_material_at(p)
		var tp_mat: StringName = tp.surface_material_at(p)
		var wp_h: float = wp.surface_height_at(p)
		var tp_h: float = tp.height_at(p)
		var wp_c: StringName = wp.surface_class_at(p)
		var tp_c: StringName = tp.terrain_class_at(p)
		_check("WorldPlan material matches %s" % p, wp_mat == tp_mat, "%s vs %s | wp_h %.2f tp_h %.2f wp_c %s tp_c %s" % [wp_mat, tp_mat, wp_h, tp_h, wp_c, tp_c])
		_check("WorldPlan buildable matches %s" % p, wp.is_buildable(p, Vector2(10,10)) == tp.is_buildable(p, Vector2(10,10)), str(p))

	# 6. No mutation of CityPlan manifests — same instance before/after + fresh canonical
	var plan_same := CityPlan.new()
	var digest_same_before := _city_digest(plan_same)
	# exercise terrain heavily
	for p in pts + chunk_seams:
		_tp_exercise(tp, p)
		_tp_exercise(tp_alt_a, p)
		_tp_exercise(tp_alt_b, p)
	var digest_same_after := _city_digest(plan_same)
	_check("CityPlan same-instance unchanged after terrain queries", digest_same_before == digest_same_after, "%d vs %d" % [digest_same_before, digest_same_after])
	var plan_fresh := CityPlan.new()
	var digest_fresh := _city_digest(plan_fresh)
	_check("CityPlan fresh canonical matches", digest_same_before == digest_fresh, "%d vs %d" % [digest_same_before, digest_fresh])

	# 7. terrain_profile edge cases
	_check("profile empty on bad step", tp.terrain_profile(Rect2(0,0,10,10), 0).is_empty(), "")
	_check("profile empty on zero rect", tp.terrain_profile(Rect2(0,0,0,0), 5.0).is_empty(), "")
	var prof := tp.terrain_profile(Rect2(0,0,10,10), 5.0)
	_check("profile size 3x3 step 5 rect 10", prof.size() == 9, str(prof.size()))
	# row-major deterministic: first element == height at rect origin
	_check("profile row-major origin", is_equal_approx(prof[0], tp.height_at(Vector2(0,0))), "%f vs %f" % [prof[0], tp.height_at(Vector2.ZERO)])
	# WorldSeed explicit-seed helper
	var s1 := WorldSeed.sample_coherent_with_seed(Vector2(10, 20), &"terrain", 64.0, canonical)
	var s2 := WorldSeed.sample_coherent(Vector2(10, 20), &"terrain", 64.0, canonical)
	_check("explicit-seed sampler matches", is_equal_approx(s1, s2), "%f vs %f" % [s1, s2])

	# Summary digests
	var h_origin := tp.height_at(origin)
	var h_far := tp.height_at(pos_far)
	print("[TerrainTest] SUMMARY origin_h=%.2f far_h=%.2f origin_class=%s far_class=%s" % [h_origin, h_far, tp.terrain_class_at(origin), tp.terrain_class_at(pos_far)])

func _tp_exercise(tp: TerrainPlan, p: Vector2) -> void:
	_tp_exercise_inner(tp, p)

func _tp_exercise_inner(tp: TerrainPlan, p: Vector2) -> void:
	var _h := tp.height_at(p)
	var _s := tp.slope_at(p)
	var _n := tp.normal_at(p)
	var _c := tp.terrain_class_at(p)
	var _m := tp.surface_material_at(p)
	var _b := tp.is_buildable(p, Vector2(12, 12))
	var _pr := tp.terrain_profile(Rect2(p.x - 5, p.y - 5, 10, 10), 5.0)

func _city_digest(plan: CityPlan) -> int:
	var h := 0
	for cell in plan.cells_in_rect(Rect2(-128, -128, 256, 256)):
		var b: Dictionary = plan.cell_block(cell)
		h = int(WorldSeed.combine([h, hash(b["id"]), hash(str(b["kind"]))]))
		for spec in plan.buildings_in_rect(Rect2(cell.x * 64, cell.y * 64, 64, 64)):
			h = int(WorldSeed.combine([h, hash(spec["id"])]))
	return h

func is_finite(v: float) -> bool:
	return not is_nan(v) and not is_inf(v)
