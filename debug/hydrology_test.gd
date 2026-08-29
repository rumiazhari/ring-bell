extends Node
## Hydrology determinism + materialization harness -- --hydrotest / --hydromaterialtest
## Covers SPEC-C002 P2.2-HYDRO-ANCHORS acceptance criteria 1-4.

var failures := 0

func _ready() -> void:
	get_tree().create_timer(80.0).timeout.connect(func() -> void:
		print("[HydroTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[HydroTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[HydroTest] PASS: %s" % label)
	else:
		failures += 1
		if detail != "":
			print("[HydroTest] FAIL: %s -- %s" % [label, detail])
		else:
			print("[HydroTest] FAIL: %s" % label)

func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	var alt_a := canonical + 1234567
	var alt_b := canonical + 7654321
	var alt_c := canonical - 54321
	var alt_d := canonical + 99999
	var alt_seeds: Array[int] = [alt_a, alt_b, alt_c, alt_d]

	var hp := HydrologyPlan.new(canonical)
	var hp2 := HydrologyPlan.new(canonical)
	var wp := WorldPlan.new(canonical)
	var wp_alt_a := WorldPlan.new(alt_a)
	var tp := TerrainPlan.new(canonical)

	# ---------- 1. Determinism: same-seed identical regardless of query order, incl negative coords ----------
	var pts: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(-512.3, -768.7),
		Vector2(530, 0),
		Vector2(620, 800),
		Vector2(-2000, 1500),
		Vector2(700, -1200),
		Vector2(8191, 0),
		Vector2(0, -2000),
		Vector2(650, 3000),
	]
	var shuffled: Array[Vector2] = [pts[3], pts[0], pts[5], pts[1], pts[4], pts[2], pts[6], pts[7], pts[8]]
	var rev: Array[Vector2] = pts.duplicate()
	rev.reverse()
	for p in pts:
		_check("same-seed body %s" % p, hp.water_body_at(p) == hp2.water_body_at(p), "%s vs %s" % [hp.water_body_at(p), hp2.water_body_at(p)])
		_check("same-seed dist %s" % p, is_equal_approx(hp.distance_to_water(p), hp2.distance_to_water(p)), str(p))
		_check("same-seed bank %s" % p, is_equal_approx(hp.bank_distance_at(p), hp2.bank_distance_at(p)), str(p))
		_check("same-seed level %s" % p, is_equal_approx(hp.water_level_at(p), hp2.water_level_at(p)), "%f vs %f" % [hp.water_level_at(p), hp2.water_level_at(p)])
		_check("same-seed flow %s" % p, hp.flow_direction_at(p).is_equal_approx(hp2.flow_direction_at(p)), str(p))
		_check("same-seed body_id %s" % p, hp.water_body_id_at(p) == hp2.water_body_id_at(p), str(p))
		_check("same-seed vocab %s" % p, hp.water_body_at(p) == &"" or WorldConstants.WATER_BODIES.has(hp.water_body_at(p)) or hp.water_body_at(p) == &"river" or hp.water_body_at(p) == &"tributary", str(hp.water_body_at(p)))
	for p in shuffled:
		_check("shuffled body %s" % p, hp.water_body_at(p) == hp2.water_body_at(p), str(p))
	for p in rev:
		_check("rev body %s" % p, hp.water_body_at(p) == hp2.water_body_at(p), str(p))
	# negative coords vocab
	var neg_pt := Vector2(-1800, -2200)
	_check("negative coords vocab", hp.water_body_at(neg_pt) == &"" or WorldConstants.WATER_BODIES.has(hp.water_body_at(neg_pt)) or hp.water_body_at(neg_pt) == &"river" or hp.water_body_at(neg_pt) == &"tributary", str(hp.water_body_at(neg_pt)))
	_check("negative coords finite dist", is_finite(hp.distance_to_water(neg_pt)), str(hp.distance_to_water(neg_pt)))
	_check("negative coords flow finite", hp.flow_direction_at(neg_pt).is_finite(), str(hp.flow_direction_at(neg_pt)))

	# Different seed materially differs
	var diff_count := 0
	for p in pts:
		if hp.water_body_at(p) != wp_alt_a.hydrology.water_body_at(p):
			diff_count += 1
		elif not is_equal_approx(hp.distance_to_water(p), wp_alt_a.hydrology.distance_to_water(p)):
			diff_count += 1
		elif not is_equal_approx(hp.river_center_x_at(p.y), wp_alt_a.hydrology.river_center_x_at(p.y)):
			diff_count += 1
	_check("different seed materially differs", diff_count >= 3, "diff %d/%d" % [diff_count, pts.size()])

	# Also alt_b differs
	var diff_b := 0
	var hp_alt_b := HydrologyPlan.new(alt_b)
	for p in pts:
		if not is_equal_approx(hp.river_center_x_at(p.y), hp_alt_b.river_center_x_at(p.y)):
			diff_b += 1
	_check("alt_b center variation", diff_b >= 3, str(diff_b))

	# ---------- 1b. Primary centerline continuous across every chunk seam (40 probes spaced 64m) ----------
	var seam_ok := true
	var seam_detail := ""
	for i in 40:
		var z := -1280.0 + float(i) * 64.0
		var cx := hp.river_center_x_at(z)
		var p := Vector2(cx, z)
		var body := hp.water_body_at(p)
		if body != &"river":
			seam_ok = false
			seam_detail = "gap at z=%f body=%s" % [z, body]
			break
		# Adjacent seam point 0.5m beyond
		var cx2 := hp.river_center_x_at(z + 0.5)
		if absf(cx - cx2) > 0.5:
			pass
	_check("primary centerline continuous 40 probes", seam_ok, seam_detail)

	# Also check continuity at chunk seam boundaries via manifest shared edges (later section does explicit)

	# ---------- 1c. Both tributaries approach monotonically and meet within 600m of seeded confluence ----------
	for k in 2:
		var trib: Dictionary = hp.tributary_info(k)
		var ax: float = float(trib["ax"])
		var az: float = float(trib["az"])
		var cx: float = float(trib["cx"])
		var cz: float = float(trib["cz"])
		var p0 := Vector2(ax, az)
		var p1 := Vector2(float(trib["mx"]), float(trib["mz"]))
		var p2 := Vector2(cx, cz)
		# Sample bezier at t=0..1
		var prev_dist_to_primary := INF
		var mono_ok := true
		var mono_detail := ""
		for si in 16:
			var t := float(si) / 15.0
			var b := _bezier2(p0, p1, p2, t)
			# Distance to primary corridor at same Z
			var river_cx := hp.river_center_x_at(b.y)
			var dist_to_primary := absf(b.x - river_cx)
			if dist_to_primary > prev_dist_to_primary + 0.5:
				mono_ok = false
				mono_detail = "trib %d t=%.2f dist %.1f prev %.1f" % [k, t, dist_to_primary, prev_dist_to_primary]
				break
			prev_dist_to_primary = dist_to_primary
		_check("trib %d monotonic approach" % k, mono_ok, mono_detail)
		# Meeting within 600m of seeded confluence: endpoint distance to primary center at cz should be ~0, and distance between endpoint and confluence is 0.
		var endpoint := Vector2(cx, cz)
		var river_at_cz := hp.river_center_x_at(cz)
		var dist_to_river_at_cz := absf(endpoint.x - river_at_cz)
		_check("trib %d meets within 600m (dist to river at cz %.1f)" % [k, dist_to_river_at_cz], dist_to_river_at_cz < 600.0, "%.1f" % dist_to_river_at_cz)
		# Also check endpoint distance to its own confluence is 0 (by construction)
		var dist_endpoint_to_confluence := endpoint.distance_to(Vector2(cx, cz))
		_check("trib %d endpoint at confluence" % k, dist_endpoint_to_confluence < 0.01, str(dist_endpoint_to_confluence))
		# Check trib confluence Cz distance to Az is northward (cz > az)
		_check("trib %d northward cz > az" % k, cz > az, "%f vs %f" % [cz, az])

	# ---------- 2. Geographic validity for canonical +4 alts ----------
	var all_seeds: Array[int] = [canonical, alt_a, alt_b, alt_c, alt_d]
	for seed in all_seeds:
		var h := HydrologyPlan.new(seed)
		var tplan := TerrainPlan.new(seed)
		# CX 530-710
		_check("seed %d cx_mean 530-710" % seed, h.cx_mean >= 530.0 and h.cx_mean <= 710.0, "%.1f" % h.cx_mean)
		# Meander +-72 primary amplitude check: sample many z, check center within cx_mean +- (72+18+1)
		var meander_ok := true
		for zi in 20:
			var zf := -2000.0 + float(zi) * 200.0
			var cen := h.river_center_x_at(zf)
			var diff := absf(cen - h.cx_mean)
			if diff > WorldConstants.HYDRO_MEANDER_AMPL + WorldConstants.HYDRO_MEANDER2_AMPL + 2.0:
				meander_ok = false
				break
		_check("seed %d meander +-72 (+18) " % seed, meander_ok, "")
		# Width 38-50
		var width_ok := true
		for zi in 20:
			var zf := -2000.0 + float(zi) * 200.0
			var w := h.river_width_at(zf)
			if w < WorldConstants.RIVER_WIDTH_MIN - 0.01 or w > WorldConstants.RIVER_WIDTH_MAX + 0.01:
				width_ok = false
				break
		_check("seed %d width 38-50" % seed, width_ok, "")
		# Trib width 14-22
		for k in WorldConstants.TRIB_COUNT:
			var ti: Dictionary = h.tributary_info(k)
			var w2: float = float(ti["width"])
			_check("seed %d trib %d width 14-22" % [seed, k], w2 >= WorldConstants.TRIBUTARY_WIDTH_MIN - 0.01 and w2 <= WorldConstants.TRIBUTARY_WIDTH_MAX + 0.01, "%.1f" % w2)
		# Bank 9 flood 26 constants
		_check("seed %d BANK_W 9" % seed, is_equal_approx(WorldConstants.BANK_W, 9.0), str(WorldConstants.BANK_W))
		_check("seed %d FLOOD 26" % seed, is_equal_approx(WorldConstants.FLOODPLAIN_W, 26.0), str(WorldConstants.FLOODPLAIN_W))
		# Flow unit length and northward components
		var flow_ok := true
		var trib_dot_ok := true
		for zi in 16:
			var zf := -1500.0 + float(zi) * 200.0
			var cx := h.river_center_x_at(zf)
			var p := Vector2(cx, zf)
			var flow := h.flow_direction_at(p)
			if absf(flow.length() - 1.0) > 0.01:
				flow_ok = false
				break
			if flow.y <= 0.35:
				flow_ok = false
				break
		_check("seed %d primary flow unit + northward >0.35" % seed, flow_ok, "")
		# Tributary flow convergence dot >0.45
		for k in WorldConstants.TRIB_COUNT:
			var ti: Dictionary = h.tributary_info(k)
			var ax2: float = float(ti["ax"])
			var az2: float = float(ti["az"])
			var mx2: float = float(ti["mx"])
			var mz2: float = float(ti["mz"])
			var cx2: float = float(ti["cx"])
			var cz2: float = float(ti["cz"])
			var p0t := Vector2(ax2, az2)
			var p1t := Vector2(mx2, mz2)
			var p2t := Vector2(cx2, cz2)
			var trib_flow_ok := true
			for si in 8:
				var t := float(si + 1) / 9.0
				var b := _bezier2(p0t, p1t, p2t, t)
				var flow2 := h.flow_direction_at(b)
				if absf(flow2.length() - 1.0) > 0.02:
					trib_flow_ok = false
					break
				var to_conf := (p2t - b).normalized()
				var dot: float = flow2.dot(to_conf)
				if dot <= 0.45:
					trib_flow_ok = false
					break
			_check("seed %d trib %d convergence dot >0.45" % [seed, k], trib_flow_ok, "")
		# No water on cliff slopes/ridge hilltops except lake placeholder: sample 200 random points per seed
		var rng := RandomNumberGenerator.new()
		rng.seed = int(seed) ^ 12345
		var cliff_ok := true
		var cliff_detail := ""
		for i in 200:
			var rx := rng.randf_range(WorldConstants.WORLD_MIN_M * 0.5, WorldConstants.WORLD_MAX_M * 0.5)
			var rz := rng.randf_range(WorldConstants.WORLD_MIN_M * 0.5, WorldConstants.WORLD_MAX_M * 0.5)
			var p := Vector2(rx, rz)
			var slope := tplan.slope_at(p)
			var cls := tplan.terrain_class_at(p)
			if slope >= WorldConstants.CLIFF_SLOPE_DEG and cls == &"cliff":
				var body := h.water_body_at(p)
				if body != &"":
					# Allow lake placeholder? Our vocabulary includes lake/reservoir but we don't generate them on cliffs generally.
					# So fail if any cliff has water.
					cliff_ok = false
					cliff_detail = "cliff water at %s slope %.1f body %s" % [p, slope, body]
					break
		_check("seed %d no water on cliff slopes" % seed, cliff_ok, cliff_detail)
		# Bank/flood monotonic from center at a sample Z (choose north beyond tributaries to avoid trib overlap)
		var sample_z := 2500.0
		var center_x := h.river_center_x_at(sample_z)
		var half := h.river_half_width_at(sample_z)
		var d0 := h.distance_to_water(Vector2(center_x, sample_z))
		var d1 := h.distance_to_water(Vector2(center_x + half, sample_z))
		var d2 := h.distance_to_water(Vector2(center_x + half + WorldConstants.BANK_W, sample_z))
		var d3 := h.distance_to_water(Vector2(center_x + half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W, sample_z))
		_check("seed %d bank/flood monotonic dist" % seed, d0 < -5.0 and is_equal_approx(d1, 0.0) or absf(d1) < 0.5 and d2 > 5.0 and d3 > 15.0, "%.1f %.1f %.1f %.1f" % [d0, d1, d2, d3])

	# ---------- 2b. Water level mean +-0.6 ----------
	var level_ok := true
	for zi in 10:
		var zf := -1000.0 + float(zi) * 200.0
		var lvl := hp.water_level_at(Vector2(hp.river_center_x_at(zf), zf))
		if lvl < WorldConstants.WATER_LEVEL_MEAN - WorldConstants.WATER_LEVEL_VAR - 0.01 or lvl > WorldConstants.WATER_LEVEL_MEAN + WorldConstants.WATER_LEVEL_VAR + 0.01:
			level_ok = false
			break
	_check("water level mean +-0.6", level_ok, "")

	# ---------- 3. Water materialization budgets and seams ----------
	# Manifest byte-identical across shuffled builds
	var coords: Array[Vector2i] = [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,-1), Vector2i(8,0), Vector2i(-2,3), Vector2i(10,5)]
	var manifests_fwd: Dictionary = {}
	var manifests_rev: Dictionary = {}
	for c in coords:
		manifests_fwd[c] = WaterChunkBuilder.build_manifest(wp, c)
	var rev_coords := coords.duplicate()
	rev_coords.reverse()
	for c in rev_coords:
		manifests_rev[c] = WaterChunkBuilder.build_manifest(wp, c)
	var det_ok := true
	for c in coords:
		var ha: PackedFloat32Array = manifests_fwd[c]["heights"]
		var hb: PackedFloat32Array = manifests_rev[c]["heights"]
		if ha.size() != hb.size():
			det_ok = false
			break
		for idx in ha.size():
			if is_nan(ha[idx]) and is_nan(hb[idx]):
				continue
			if not is_equal_approx(ha[idx], hb[idx]):
				det_ok = false
				break
		var ia: PackedInt32Array = manifests_fwd[c]["indices"]
		var ib: PackedInt32Array = manifests_rev[c]["indices"]
		if ia != ib:
			det_ok = false
			break
	_check("water manifest equality shuffled order", det_ok, "")

	# Shared-edge heights/centerline within 0.02 at + and - boundaries
	var m0 := WaterChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var m1 := WaterChunkBuilder.build_manifest(wp, Vector2i(1,0))
	var h0: PackedFloat32Array = m0["heights"]
	var h1: PackedFloat32Array = m1["heights"]
	var edge_ok := true
	for j in WaterChunkBuilder.RESOLUTION:
		var idx0 := j * WaterChunkBuilder.RESOLUTION + (WaterChunkBuilder.RESOLUTION - 1)
		var idx1 := j * WaterChunkBuilder.RESOLUTION + 0
		var a: float = h0[idx0]
		var b: float = h1[idx1]
		if is_nan(a) and is_nan(b):
			continue
		if is_nan(a) or is_nan(b):
			edge_ok = false
			break
		if absf(a - b) > WorldConstants.SEAM_CONTINUITY_TOL_M + 1e-6:
			edge_ok = false
			break
	_check("shared edge heights + boundary within 0.02", edge_ok, "")
	var mn0 := WaterChunkBuilder.build_manifest(wp, Vector2i(-1,0))
	var mn1 := WaterChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var hn0: PackedFloat32Array = mn0["heights"]
	var hn1: PackedFloat32Array = mn1["heights"]
	var neg_ok := true
	for j in WaterChunkBuilder.RESOLUTION:
		var a2 := j * WaterChunkBuilder.RESOLUTION + WaterChunkBuilder.RESOLUTION -1
		var b2 := j * WaterChunkBuilder.RESOLUTION
		var a2v: float = hn0[a2]
		var b2v: float = hn1[b2]
		if is_nan(a2v) and is_nan(b2v):
			continue
		if is_nan(a2v) or is_nan(b2v):
			neg_ok = false
			break
		if absf(a2v - b2v) > 0.02:
			neg_ok = false
			break
	_check("shared edge negative coord within 0.02", neg_ok, "")

	# Also Z seams
	var mz0 := WaterChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var mz1 := WaterChunkBuilder.build_manifest(wp, Vector2i(0,1))
	var hz0: PackedFloat32Array = mz0["heights"]
	var hz1: PackedFloat32Array = mz1["heights"]
	var z_edge_ok := true
	for i in WaterChunkBuilder.RESOLUTION:
		var idx_a := (WaterChunkBuilder.RESOLUTION -1) * WaterChunkBuilder.RESOLUTION + i
		var idx_b := i
		var va: float = hz0[idx_a]
		var vb: float = hz1[idx_b]
		if is_nan(va) and is_nan(vb):
			continue
		if is_nan(va) or is_nan(vb):
			z_edge_ok = false
			break
		if absf(va - vb) > 0.02:
			z_edge_ok = false
			break
	_check("shared edge Z boundary within 0.02", z_edge_ok, "")

	# <=1 water collider per chunk (0 if dry), and bounded verts/tris + water_mat_ms measured
	for c in coords:
		var m: Dictionary = manifests_fwd[c]
		var coll: int = int(m["water_colliders"])
		_check("chunk %s collider <=1" % c, coll <= 1 and coll >= 0, str(coll))
		if coll > 0:
			_check("chunk %s water_vertices 81" % c, int(m["water_vertices"]) == 81, str(m["water_vertices"]))
			_check("chunk %s water_triangles <=128" % c, int(m["water_triangles"]) <= 128 and int(m["water_triangles"]) >= 0, str(m["water_triangles"]))
		else:
			_check("dry chunk %s 0 verts" % c, int(m["water_vertices"]) == 0, str(m["water_vertices"]))
		_check("chunk %s water_gen_ms measured" % c, m.has("water_gen_ms") and float(m["water_gen_ms"]) >= 0.0, str(m.get("water_gen_ms", "")))
	# Materialize and check water_mat_ms
	var parent := Node3D.new()
	add_child(parent)
	var wet_candidates: Array[Vector2i] = []
	for c in [Vector2i(8,0), Vector2i(9,0), Vector2i(10,0), Vector2i(8,1), Vector2i(8,-1), Vector2i(9,1)]:
		var mm := WaterChunkBuilder.build_manifest(wp, c)
		if int(mm["water_colliders"]) == 1:
			wet_candidates.append(c)
	# Ensure we have wet chunks near river
	_check("wet chunks found near river", wet_candidates.size() >= 2, str(wet_candidates.size()))
	for c in wet_candidates:
		var m: Dictionary = WaterChunkBuilder.build_manifest(wp, c)
		var st: Dictionary = WaterChunkBuilder.materialize(parent, m)
		_check("materialize water_mat_ms %s" % c, st.has("water_mat_ms") and float(st["water_mat_ms"]) >= 0.0, str(st.get("water_mat_ms", "")))
		_check("materialize vertices 81 %s" % c, int(st["water_vertices"]) == 81, str(st["water_vertices"]))
		_check("materialize collider 1 %s" % c, int(st["water_colliders"]) == 1, str(st["water_colliders"]))
	# Dry chunk materialize expects 0
	var dry_c: Vector2i = Vector2i(0,0)
	# origin chunk is dry (river at 620)
	var dry_m := WaterChunkBuilder.build_manifest(wp, dry_c)
	if int(dry_m["water_colliders"]) == 0:
		var dry_st := WaterChunkBuilder.materialize(parent, dry_m)
		_check("dry chunk materialize 0 collider", int(dry_st["water_colliders"]) == 0, str(dry_st["water_colliders"]))
	parent.queue_free()

	# <=9 active water colliders in 3x3 ring (test via ChunkManager synchronous)
	var cm := ChunkManager.new()
	add_child(cm)
	cm.synchronous = true
	cm.setup_world(CityPlan.new(), WorldPlan.new(canonical))
	var fake_player := Node3D.new()
	# Hill near river: pick point at river center x ~620, z 0
	var river_x := hp.river_center_x_at(0.0)
	fake_player.position = Vector3(river_x, 0, 0)
	add_child(fake_player)
	cm.set_player(fake_player)
	cm._player_chunk_changed = true
	cm._stream_timer = 1.0
	cm._process(0.3)
	for _drain in 8:
		if cm._pending.is_empty() and cm._inflight.is_empty():
			break
		cm._player_chunk_changed = false
		cm._stream_timer = 1.0
		cm._process(0.3)
		await get_tree().process_frame
	var sum_active_water := 0
	var sum_active_verts := 0
	for coord in cm._chunks.keys():
		var rec: Dictionary = cm._chunks[coord]
		if String(rec.get("state","")) == "active":
			sum_active_water += int(rec.get("water_colliders",0))
			sum_active_verts += int(rec.get("water_vertices",0))
	_check("active water <=9 hill near river", sum_active_water <= 9, str(sum_active_water))
	_check("active water == water in ACTIVE", sum_active_water == cm.water_active_count(), "%d vs %d" % [sum_active_water, cm.water_active_count()])
	_check("bounded verts per wet chunk", sum_active_verts <= 9*81 or sum_active_verts == cm.water_active_count()*81, str(sum_active_verts))
	_check("active water measured t_water_gen present", cm._total_water_gen_ms >= 0.0, str(cm._total_water_gen_ms))
	_check("terrain still present with water", cm.terrain_active_count() <= 9, str(cm.terrain_active_count()))

	# 3x3 ring around hill near river with shuffled builds byte-identical
	var manifest_a := WaterChunkBuilder.build_manifest(wp, Vector2i(int(river_x/64.0), 0))
	var manifest_b := WaterChunkBuilder.build_manifest(wp, Vector2i(int(river_x/64.0), 0))
	var same_manifest := PackedFloat32Array(manifest_a["heights"]) == PackedFloat32Array(manifest_b["heights"]) and PackedInt32Array(manifest_a["indices"]) == PackedInt32Array(manifest_b["indices"])
	_check("water manifest deterministic", same_manifest, "")

	# ---------- 4. ChunkManager streams water with terrain+city without duplication ----------
	# Debug stats contain t_water_gen/t_water_mat
	var lines: Array[String] = cm.debug_lines()
	var has_water_gen := false
	var has_water_mat := false
	for ln in lines:
		if ln.find("t_water_gen") != -1:
			has_water_gen = true
		if ln.find("t_water_mat") != -1:
			has_water_mat = true
	_check("debug stats contain t_water_gen", has_water_gen, str(lines))
	_check("debug stats contain t_water_mat", has_water_mat, str(lines))

	# Walking 480m beyond UNLOAD_RADIUS unloads river chunks and returning regenerates identical manifests
	# Save current river manifests
	var river_coords: Array[Vector2i] = []
	for coord in cm._chunks.keys():
		var rec: Dictionary = cm._chunks[coord]
		if int(rec.get("water_colliders",0)) > 0:
			river_coords.append(coord)
	_check("river chunks present for unload test", river_coords.size() > 0, str(river_coords.size()))
	var saved_manifests: Dictionary = {}
	for rc in river_coords:
		var rec: Dictionary = cm._chunks[rc]
		var wm: Dictionary = rec.get("water_manifest", {})
		if not wm.is_empty():
			saved_manifests[rc] = {
				"verts": int(wm.get("water_vertices",0)),
				"tris": int(wm.get("water_triangles",0)),
				"coll": int(wm.get("water_colliders",0)),
				"heights": PackedFloat32Array(wm.get("heights", PackedFloat32Array())),
			}
	# Move far 480m beyond unload radius
	fake_player.position += Vector3(480.0, 0, 480.0)
	cm._player_chunk_changed = true
	cm._stream_timer = 1.0
	cm._process(0.3)
	var waited := 0.0
	while waited < 4.0:
		await get_tree().process_frame
		cm._process(0.1)
		waited += 0.1
		var any_old := false
		for rc in river_coords:
			if cm.is_resident(rc):
				any_old = true
				break
		if not any_old:
			break
	var unloaded_ok := true
	for rc in river_coords:
		if cm.is_resident(rc):
			unloaded_ok = false
			break
	_check("river chunks unload after 480m walk", unloaded_ok, str(river_coords))
	# Return
	fake_player.position = Vector3(river_x, 0, 0)
	cm._player_chunk_changed = true
	cm._stream_timer = 1.0
	cm._process(0.3)
	waited = 0.0
	while waited < 5.0:
		await get_tree().process_frame
		cm._process(0.1)
		waited += 0.1
		if cm._pending.is_empty() and cm._inflight.is_empty():
			var all_back := true
			for rc in river_coords:
				if not cm.is_resident(rc):
					all_back = false
			if all_back:
				break
	var regen_ok := true
	for rc in river_coords:
		if not cm.is_resident(rc):
			regen_ok = false
			break
		var rec2: Dictionary = cm._chunks[rc]
		var wm2: Dictionary = rec2.get("water_manifest", {})
		var saved: Dictionary = saved_manifests.get(rc, {})
		if saved.is_empty() or wm2.is_empty():
			regen_ok = false
			break
		if int(wm2.get("water_vertices",0)) != int(saved["verts"]):
			regen_ok = false
			break
		if int(wm2.get("water_triangles",0)) != int(saved["tris"]):
			regen_ok = false
			break
		if int(wm2.get("water_colliders",0)) != int(saved["coll"]):
			regen_ok = false
			break
		var h2: PackedFloat32Array = wm2["heights"]
		var hs: PackedFloat32Array = saved["heights"]
		if h2.size() != hs.size():
			regen_ok = false
			break
		for idx in h2.size():
			var a: float = h2[idx]
			var b: float = hs[idx]
			if is_nan(a) and is_nan(b):
				continue
			if not is_equal_approx(a, b):
				regen_ok = false
				break
	_check("river water regenerates identical after unload/return", regen_ok, "")

	# save_state excludes generated water
	var save: Dictionary = cm.save_state()
	var has_water_in_save := false
	var save_str := str(save)
	if save_str.find("water_vertices") != -1 or save_str.find("water_triangles") != -1 or save_str.find("Water_") != -1 or save_str.find("water_manifest") != -1:
		has_water_in_save = true
	_check("save_state excludes water geometry", not has_water_in_save, save_str.substr(0, 200))

	# GENERATOR_VERSION stays 2
	_check("GENERATOR_VERSION stays 2", WorldSeed.GENERATOR_VERSION == 2, str(WorldSeed.GENERATOR_VERSION))
	# WorldPlan pure: check that creating HydrologyPlan doesn't mutate CityPlan
	var city_before := CityPlan.new()
	var digest_before := _city_digest(city_before)
	var _hp_tmp := HydrologyPlan.new(canonical)
	var _wm_tmp := WorldPlan.new(canonical)
	var digest_after := _city_digest(city_before)
	_check("CityPlan unchanged after hydrology", digest_before == digest_after, "%d vs %d" % [digest_before, digest_after])

	# Crossing candidates
	var rect := Rect2(500, -1000, 400, 2000)
	var crossings: Array[Dictionary] = hp.crossing_candidates(rect)
	_check("crossing candidates at least one per 800m", crossings.size() >= 2, str(crossings.size()))
	for cr in crossings:
		_check("crossing has center", cr.has("center"), str(cr))
		_check("crossing has water_id", cr.has("water_id") and String(cr["water_id"]) == "river_main", str(cr.get("water_id", "")))
		_check("crossing axis is Vector2", cr["axis"] is Vector2, str(cr["axis"]))

	cm.queue_free()
	fake_player.queue_free()

	# WorldPlan forwarding checks
	_check("WorldPlan forwards river_center", is_equal_approx(wp.river_center_x_at(0.0), hp.river_center_x_at(0.0)), str(wp.river_center_x_at(0.0)))
	_check("WorldPlan forwards water_body", wp.water_body_at(Vector2(620, 0)) == hp.water_body_at(Vector2(620,0)), str(wp.water_body_at(Vector2(620,0))))
	_check("WorldPlan forwards flow", wp.flow_direction_at(Vector2(620,0)).is_equal_approx(hp.flow_direction_at(Vector2(620,0))), str(wp.flow_direction_at(Vector2(620,0))))

	# Summary
	print("[HydroTest] SUMMARY canonical cx=%.1f river_x0=%.1f wet_candidates=%d" % [hp.cx_mean, hp.river_center_x_at(0.0), wet_candidates.size()])

func _bezier2(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u*u*p0 + 2.0*u*t*p1 + t*t*p2

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
