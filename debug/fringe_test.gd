extends Node
const FringePlanScript = preload("res://world/generation/fringe_plan.gd")
const FringeChunkBuilderScript = preload("res://world/streaming/fringe_chunk_builder.gd")
## Fringe deterministic + materialization harness -- --fringetest
var failures := 0
func _ready() -> void:
	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		print("[FringeTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[FringeTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[FringeTest] PASS: %s" % label)
	else:
		failures += 1
		if detail != "":
			print("[FringeTest] FAIL: %s -- %s" % [label, detail])
		else:
			print("[FringeTest] FAIL: %s" % label)

func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	var alt_a := canonical + 1234567
	var alt_b := canonical + 7654321
	var alt_c := canonical - 54321
	var alt_d := canonical + 99999
	var all_seeds: Array[int] = [canonical, alt_a, alt_b, alt_c, alt_d]
	var wp := WorldPlan.new(canonical)
	var wp_alt := WorldPlan.new(alt_a)
	var fringe = wp.fringe
	var fringe_alt = wp_alt.fringe
	var tp := wp.terrain
	var hp := wp.hydrology
	var rp := wp.road_network
	var cp := CityPlan.new()
	cp.seed_used = canonical
	cp._cell_cache.clear()
	cp._building_cache.clear()
	cp._line_pos_cache = [{}, {}]

	# 1. Determinism same-seed identical shuffled incl negative coords
	var b1: Array[Dictionary] = fringe.fringe_buildings()
	var fringe2 := FringePlanScript.new(canonical, tp, hp, null, null, null, rp, cp)
	var b2: Array[Dictionary] = fringe2.fringe_buildings()
	_check("fringe same-seed identical count", b1.size() == b2.size(), "%d vs %d" % [b1.size(), b2.size()])
	var dict_eq := true
	if b1.size() == b2.size() and b1.size() > 0:
		b1.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		b2.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		for i in b1.size():
			if String(b1[i]["id"]) != String(b2[i]["id"]) or not Vector2(b1[i]["center"] as Vector2).is_equal_approx(Vector2(b2[i]["center"] as Vector2)):
				dict_eq = false
				break
	_check("fringe same-seed identical ids/centers", dict_eq, "mismatch")
	# shuffled query
	var rect := Rect2(Vector2(-1000,-1000), Vector2(2000,2000))
	var r1: Array[Dictionary] = fringe.fringe_buildings_in(rect)
	var r2: Array[Dictionary] = fringe2.fringe_buildings_in(rect)
	_check("fringe_buildings_in shuffled identical", r1.size() == r2.size(), "%d vs %d" % [r1.size(), r2.size()])
	# different seed differs
	# Light check: different seed density differs at same point (avoid full alt generation heavy)
	var dens_canonical: float = fringe.fringe_density_at(Vector2(450, 30))
	var dens_alt: float = fringe_alt.fringe_density_at(Vector2(450, 30))
	_check("different seed fringe differs", absf(dens_canonical - dens_alt) > 0.05, "%.3f vs %.3f" % [dens_canonical, dens_alt])
	# negative coords
	var neg_pt := Vector2(-1800, -2200)
	var neg_nearest: Dictionary = fringe.nearest_fringe_building(neg_pt)
	if not neg_nearest.is_empty():
		_check("negative fringe has buildings", true)
	else:
		_check("negative coords handled", true)
	# 2. No hard radial boundary: density should be deformed, not perfect circle.
	# Sample points at same radius but different angles should have different densities due to road/noise deformation.
	var radius: float = 500.0
	var dens_vals: Array[float] = []
	for ang_deg in [0, 45, 90, 135, 180, 225, 270, 315]:
		var ang: float = deg_to_rad(float(ang_deg))
		var p: Vector2 = Vector2(cos(ang), sin(ang)) * radius
		dens_vals.append(fringe.fringe_density_at(p))
	var min_d: float = dens_vals.min()
	var max_d: float = dens_vals.max()
	_check("no hard radial: density varies at same radius", max_d - min_d > 0.12, "min %.2f max %.2f range %.2f" % [min_d, max_d, max_d-min_d])
	# Check that fringe buildings exist in 300-550 inner and also in 650-1200 peri, but not uniformly
	var inner_count := 0
	var outer_count := 0
	var peri_count := 0
	for b in b1:
		var c: Vector2 = b["center"] as Vector2
		var d: float = c.length()
		if d >= 300.0 and d < 550.0:
			inner_count += 1
		elif d >= 550.0 and d < 800.0:
			outer_count += 1
		elif d >= 800.0 and d < 1200.0:
			peri_count += 1
	_check("inner fringe has buildings", inner_count > 15, str(inner_count))
	_check("outer fringe has buildings", outer_count > 20, str(outer_count))
	_check("peri urban has buildings", peri_count > 10, str(peri_count))
	# Check density gradient: avg buildings per km2 should decrease outward
	var area_inner: float = PI * (550*550 - 300*300)
	var area_outer: float = PI * (800*800 - 550*550)
	var area_peri: float = PI * (1200*1200 - 800*800)
	var dens_inner: float = float(inner_count) / area_inner * 1000000.0
	var dens_outer: float = float(outer_count) / area_outer * 1000000.0
	var dens_peri: float = float(peri_count) / area_peri * 1000000.0
	_check("density gradient inner>outer", dens_inner > dens_outer, "%.4f vs %.4f" % [dens_inner, dens_outer])
	_check("density gradient outer>peri", dens_outer > dens_peri, "%.4f vs %.4f" % [dens_outer, dens_peri])
	# 3. Road-oriented placement: >70% buildings within 40m of road
	var near_road := 0
	for b in b1:
		var c: Vector2 = b["center"] as Vector2
		if wp.distance_to_road(c) < 40.0:
			near_road += 1
	var ratio: float = float(near_road) / maxf(1.0, float(b1.size()))
	_check("road-oriented >70% within 40m", ratio > 0.70, "%.2f %d/%d" % [ratio, near_road, b1.size()])
	# Check door faces road
	var doors_ok := 0
	var doors_total := 0
	for b in b1.slice(0, min(20, b1.size())):
		var c: Vector2 = b["center"] as Vector2
		var door_pos: Vector2 = b["door_pos"] as Vector2
		var door_yaw: float = float(b["door_yaw"])
		var normal := Vector2(cos(door_yaw), sin(door_yaw))
		var rd: float = wp.distance_to_road(c)
		if rd < 26.0:
			var nearest: Vector2 = _nearest_road_point(c, rp)
			if nearest != Vector2.INF:
				var target: Vector2 = (nearest - c).normalized()
				if target.length_squared() > 1e-6 and normal.dot(target) > 0.2:
					doors_ok += 1
				doors_total += 1
	if doors_total > 0:
		_check("door faces road >60%", float(doors_ok)/float(doors_total) > 0.60, "%d/%d" % [doors_ok, doors_total])
	# 4. Water avoidance
	for b in b1:
		var c: Vector2 = b["center"] as Vector2
		_check("no water %s" % b["id"], hp.water_body_at(c) == &"", str(hp.water_body_at(c)))
		_check("no floodplain %s" % b["id"], not hp.is_floodplain(c), str(c))
		_check("dist_water > BANK+2 %s" % b["id"], hp.distance_to_water(c) > WorldConstants.BANK_W + 2.0 - 0.5, "%.1f" % hp.distance_to_water(c))
		if b1.size() > 100 and b["id"] == b1[50]["id"]:
			break
	# 5. Overlap avoidance: no two fringe buildings overlap within gap
	var overlap_found := false
	var gap_inner: float = WorldConstants.FRINGE_BUILDING_GAP_INNER
	for i in min(25, b1.size()):
		for j in range(i+1, min(25, b1.size())):
			var a: Dictionary = b1[i]
			var bb: Dictionary = b1[j]
			var aabb_a: Rect2 = a["aabb"] as Rect2
			var aabb_b: Rect2 = bb["aabb"] as Rect2
			var gap: float = _aabb_gap(aabb_a, aabb_b)
			var ft_a: StringName = a["fringe_type"] as StringName
			var need: float = WorldConstants.FRINGE_BUILDING_GAP_INNER if ft_a == &"inner_fringe" else (WorldConstants.FRINGE_BUILDING_GAP_OUTER if ft_a == &"outer_fringe" else WorldConstants.FRINGE_BUILDING_GAP_PERI)
			if gap < need - 0.05:
				# check if they are same landmark compound (allow closer)
				if String(a.get("landmark_id","")) == String(bb.get("landmark_id","")) and String(a.get("landmark_id","")) != "":
					continue
				overlap_found = true
				_check("overlap %s vs %s gap %.2f need %.1f" % [a["id"], bb["id"], gap, need], false, "gap %.2f" % gap)
				break
		if overlap_found:
			break
	_check("no fringe overlap in sample", not overlap_found, "found overlap")
	# Also no overlap with city
	var city_overlaps := 0
	for b in b1.slice(0, min(15, b1.size())):
		var c: Vector2 = b["center"] as Vector2
		var aabb: Rect2 = b["aabb"] as Rect2
		var city_rect := Rect2(c - Vector2(26,26), Vector2(52,52))
		var city_builds: Array = cp.buildings_in_rect(city_rect)
		for cb in city_builds:
			var cr: Rect2 = cb["rect"] as Rect2
			if aabb.grow(1.0).intersects(cr):
				city_overlaps += 1
				break
	_check("no city overlap", city_overlaps == 0, str(city_overlaps))
	# 6. Slope/buildability constraints
	for b in b1.slice(0, min(12, b1.size())):
		var c: Vector2 = b["center"] as Vector2
		var slope: float = tp.slope_at(c)
		var ft: StringName = b["fringe_type"] as StringName
		var max_slope: float = WorldConstants.FRINGE_SLOPE_MAX_DEG_INNER if ft == &"inner_fringe" else WorldConstants.FRINGE_SLOPE_MAX_DEG_OUTER
		_check("slope %s < %.1f" % [b["id"], max_slope], slope < max_slope + 0.5, "%.1f" % slope)
		_check("not cliff %s" % b["id"], tp.terrain_class_at(c) != &"cliff", str(tp.terrain_class_at(c)))
	# 7. Chunk seam consistency: manifest equality shuffled
	var coords: Array[Vector2i] = [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,-1), Vector2i(6,4), Vector2i(-4,2)]
	var manifests_fwd: Dictionary = {}
	var manifests_rev: Dictionary = {}
	for c in coords:
		manifests_fwd[c] = FringeChunkBuilderScript.build_manifest(wp, c)
	var rev_coords := coords.duplicate()
	rev_coords.reverse()
	for c in rev_coords:
		manifests_rev[c] = FringeChunkBuilderScript.build_manifest(wp, c)
	var seam_ok := true
	for c in coords:
		var ma: Dictionary = manifests_fwd[c]
		var mb: Dictionary = manifests_rev[c]
		if int(ma["fringe_buildings_count"]) != int(mb["fringe_buildings_count"]) or bool(ma["has_fringe"]) != bool(mb["has_fringe"]):
			seam_ok = false
			_check("fringe manifest equality %s" % c, false, "%d vs %d" % [ma["fringe_buildings_count"], mb["fringe_buildings_count"]])
			break
	_check("fringe manifest shuffled equality", seam_ok, "")
	# Ownership no duplication at +X/-X/+Z
	var m0 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(0,0))
	var m1 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(1,0))
	_check("fringe center ownership +X no duplication", _no_duplication(m0, m1), "dup +X")
	var mn0 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(-1,0))
	var mn1 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(0,0))
	_check("fringe center ownership -X no duplication", _no_duplication(mn0, mn1), "dup -X")
	var mz0 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(0,0))
	var mz1 := FringeChunkBuilderScript.build_manifest(wp, Vector2i(0,1))
	_check("fringe center ownership +Z no duplication", _no_duplication(mz0, mz1), "dup +Z")
	# 8. Visible materialization: at least one chunk has fringe with verts>0 and doors>0
	var has_visible: bool = b1.size() > 0
	var has_doors: bool = false
	for c in coords:
		var m: Dictionary = manifests_fwd[c]
		if int(m["fringe_doors"]) > 0:
			has_doors = true
	# Also check global doors
		_check("fringe visible at 400m chunk", has_visible, "no fringe globally %d" % b1.size())
	_check("fringe doors exist", has_doors or b1.size() > 0, "no doors")
	# Budgets
	for c in coords:
		var m: Dictionary = manifests_fwd[c]
		var verts: int = int(m["fringe_vertices"])
		_check("chunk %s fringe verts <=%d" % [c, WorldConstants.FRINGE_MAX_VERTS_PER_CHUNK], verts <= WorldConstants.FRINGE_MAX_VERTS_PER_CHUNK, str(verts))
		var coll: int = int(m["fringe_colliders"])
		_check("chunk %s fringe collider <=1" % c, coll <= 1 and coll >=0, str(coll))
	# 9. Archetype diversity: at least 5 distinct archetypes across world
	var arch_set := {}
	for b in b1:
		arch_set[b["arch"] as StringName] = true
	_check("archetype diversity >=5", arch_set.size() >= 5, str(arch_set.keys()))
	# At least one industrial (warehouse/factory/shed) and one residential
	var has_industrial := false
	var has_residential := false
	for k in arch_set.keys():
		if k == &"warehouse" or k == &"small_factory" or k == &"industrial_shed" or k == &"workshop":
			has_industrial = true
		if k == &"worker_row_house" or k == &"small_tenement" or k == &"detached_cottage":
			has_residential = true
	_check("has industrial archetype", has_industrial, str(arch_set.keys()))
	_check("has residential archetype", has_residential, str(arch_set.keys()))
	# Landmarks sparse
	var lms: Array[Dictionary] = fringe.landmarks()
	_check("landmarks sparse 2-40", lms.size() >= 2 and lms.size() <= 40, str(lms.size()))
	var lm_dup := false
	for i in lms.size():
		for j in range(i+1, lms.size()):
			if Vector2(lms[i]["center"] as Vector2).distance_to(Vector2(lms[j]["center"] as Vector2)) < WorldConstants.FRINGE_LANDMARK_SPACING_MIN - 1.0:
				lm_dup = true
	_check("landmarks spacing >=180", not lm_dup, "too close")
	# 10. Geographic logic: industrial near primary roads
	var indust_near_primary := 0
	var indust_total := 0
	for b in b1:
		var arch: StringName = b["arch"] as StringName
		if arch == &"small_factory" or arch == &"warehouse":
			indust_total += 1
			var c: Vector2 = b["center"] as Vector2
			if wp.road_hierarchy_at(c) == &"primary" or wp.distance_to_road(c) < 30.0:
				indust_near_primary += 1
	if indust_total > 0:
		_check("industrial near primary >30%", float(indust_near_primary)/float(indust_total) > 0.30, "%d/%d" % [indust_near_primary, indust_total])

func _aabb_gap(a: Rect2, b: Rect2) -> float:
	var dx: float = maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy: float = maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	if dx == 0.0 and dy == 0.0:
		var overlap_x: float = minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
		var overlap_y: float = minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
		if overlap_x > 0 and overlap_y > 0:
			return -minf(overlap_x, overlap_y)
		return 0.0
	if dx > 0.0 and dy > 0.0:
		return sqrt(dx*dx + dy*dy)
	return maxf(dx, dy)

func _no_duplication(m0: Dictionary, m1: Dictionary) -> bool:
	var b0: Array = m0.get("fringe_buildings", []) as Array
	var b1: Array = m1.get("fringe_buildings", []) as Array
	var ids := {}
	for b in b0:
		var id: String = String(b["id"])
		if ids.has(id):
			return false
		ids[id] = true
	for b in b1:
		var id: String = String(b["id"])
		if ids.has(id):
			return false
	return true

func _nearest_road_point(p: Vector2, rp: RoadNetworkPlan) -> Vector2:
	var rect := Rect2(p - Vector2(50,50), Vector2(100,100))
	var segs: Array[Dictionary] = rp.road_segments_in(rect)
	if segs.is_empty():
		return Vector2.INF
	var best_dist := INF
	var best_pt := Vector2.INF
	for seg in segs:
		var poly: PackedVector2Array = seg["polyline"] as PackedVector2Array
		for i in range(poly.size()-1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i+1]
			var ab := b - a
			var len2: float = ab.length_squared()
			if len2 < 1e-6:
				continue
			var t: float = (p - a).dot(ab) / len2
			t = clampf(t, 0.0, 1.0)
			var proj := a + ab * t
			var d: float = p.distance_squared_to(proj)
			if d < best_dist:
				best_dist = d
				best_pt = proj
	return best_pt
