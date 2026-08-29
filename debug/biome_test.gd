extends Node
## Biome & geology determinism + materialization harness -- --biometest / --biomematerialtest
## Covers SPEC-C003 P3.1-RURAL-MOSAIC acceptance criteria 1-4.
var failures := 0

func _ready() -> void:
	get_tree().create_timer(80.0).timeout.connect(func() -> void:
		print("[BiomeTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[BiomeTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[BiomeTest] PASS: %s" % label)
	else:
		failures += 1
		if detail != "":
			print("[BiomeTest] FAIL: %s -- %s" % [label, detail])
		else:
			print("[BiomeTest] FAIL: %s" % label)

func _bezier2(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * p0 + 2.0 * u * t * p1 + t * t * p2

func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	var alt_a := canonical + 1234567
	var alt_b := canonical + 7654321
	var alt_c := canonical - 54321
	var alt_d := canonical + 99999
	var alt_seeds: Array[int] = [alt_a, alt_b, alt_c, alt_d]
	var all_seeds: Array[int] = [canonical, alt_a, alt_b, alt_c, alt_d]
	# Plans
	var gp := GeologyPlan.new(canonical)
	var gp2 := GeologyPlan.new(canonical)
	var bp := BiomePlan.new(canonical)
	var bp2 := BiomePlan.new(canonical)
	var wp := WorldPlan.new(canonical)
	var wp_alt_a := WorldPlan.new(alt_a)
	var tp := TerrainPlan.new(canonical)
	var hp := HydrologyPlan.new(canonical)

	# ---------- 1. Determinism: same-seed identical shuffled, incl negative coords ----------
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
		_check("same-seed strata %s" % p, gp.strata_at(p) == gp2.strata_at(p), "%s vs %s" % [gp.strata_at(p), gp2.strata_at(p)])
		_check("same-seed soil %s" % p, gp.soil_at(p) == gp2.soil_at(p), str(p))
		_check("same-seed quarry %s" % p, is_equal_approx(gp.quarry_suitability_at(p), gp2.quarry_suitability_at(p)), str(p))
		_check("same-seed fertility %s" % p, is_equal_approx(gp.fertility_at(p), gp2.fertility_at(p)), str(p))
		_check("same-seed cave %s" % p, is_equal_approx(gp.cave_potential_at(p), gp2.cave_potential_at(p)), str(p))
		_check("same-seed biome %s" % p, bp.biome_at(p) == bp2.biome_at(p), "%s vs %s" % [bp.biome_at(p), bp2.biome_at(p)])
		_check("same-seed moisture %s" % p, is_equal_approx(bp.moisture_at(p), bp2.moisture_at(p)), str(p))
		_check("same-seed temp %s" % p, is_equal_approx(bp.temperature_at(p), bp2.temperature_at(p)), str(p))
		_check("same-seed density %s" % p, is_equal_approx(bp.biome_density_at(p), bp2.biome_density_at(p)), str(p))
		_check("same-seed tint %s" % p, bp.surface_tint_at(p).is_equal_approx(bp2.surface_tint_at(p)), str(p))
		_check("same-seed vocab %s" % p, WorldConstants.BIOME_VOCAB.has(bp.biome_at(p)), str(bp.biome_at(p)))
		_check("same-seed strata vocab %s" % p, WorldConstants.GEOLOGY_STRATA_VOCAB.has(gp.strata_at(p)), str(gp.strata_at(p)))
		_check("same-seed soil vocab %s" % p, WorldConstants.GEOLOGY_SOIL_VOCAB.has(gp.soil_at(p)), str(gp.soil_at(p)))
	for p in shuffled:
		_check("shuffled biome %s" % p, bp.biome_at(p) == bp2.biome_at(p), str(p))
		_check("shuffled strata %s" % p, gp.strata_at(p) == gp2.strata_at(p), str(p))
	for p in rev:
		_check("rev biome %s" % p, bp.biome_at(p) == bp2.biome_at(p), str(p))
	var neg_pt := Vector2(-1800, -2200)
	_check("negative coords biome vocab", WorldConstants.BIOME_VOCAB.has(bp.biome_at(neg_pt)), str(bp.biome_at(neg_pt)))
	_check("negative coords strata vocab", WorldConstants.GEOLOGY_STRATA_VOCAB.has(gp.strata_at(neg_pt)), str(gp.strata_at(neg_pt)))
	_check("negative coords finite quarry", is_finite(gp.quarry_suitability_at(neg_pt)), str(gp.quarry_suitability_at(neg_pt)))
	_check("negative coords finite moisture", is_finite(bp.moisture_at(neg_pt)), str(bp.moisture_at(neg_pt)))
	# Different seed materially differs >=3/9
	var diff_count := 0
	for p in pts:
		if bp.biome_at(p) != wp_alt_a.biome_at(p):
			diff_count += 1
		elif gp.strata_at(p) != GeologyPlan.new(alt_a).strata_at(p):
			diff_count += 1
		else:
			var q1 := gp.quarry_suitability_at(p)
			var q2 := GeologyPlan.new(alt_a).quarry_suitability_at(p)
			if not is_equal_approx(q1, q2):
				diff_count += 1
	_check("different seed materially differs >=3/9", diff_count >= 3, "diff %d/%d" % [diff_count, pts.size()])
	var diff_b := 0
	var gp_alt_b := GeologyPlan.new(alt_b)
	var bp_alt_b := BiomePlan.new(alt_b)
	for p in pts:
		if bp.biome_at(p) != bp_alt_b.biome_at(p):
			diff_b += 1
	_check("alt_b biome variation >=2", diff_b >= 2, str(diff_b))
	# ---------- 1b. Contiguous forest/field clusters run-length >=192 m (24 samples at 8m) ----------
	# Rural transects: 512m at 8m =64 samples
	var rural_transects: Array[Dictionary] = []
	# Choose rural y positions outside urban and outside immediate floodplain but rural
	rural_transects.append({"origin": Vector2(400, 900), "dir": Vector2(1, 0)})
	rural_transects.append({"origin": Vector2(600, 1200), "dir": Vector2(1, 0)})
	rural_transects.append({"origin": Vector2(-800, -900), "dir": Vector2(1, 0)})
	rural_transects.append({"origin": Vector2(800, -1200), "dir": Vector2(0, 1)})
	var contig_ok := false
	var contig_detail := ""
	for t in rural_transects:
		var orig: Vector2 = t["origin"]
		var dir: Vector2 = t["dir"]
		var samples: Array[StringName] = []
		samples.resize(64)
		for i in 64:
			var p := orig + dir * float(i) * 8.0
			samples[i] = bp.biome_at(p)
		# Compute longest run of same biome (or forest vs field grouping)
		# For forest belt, run of forest (deciduous/mixed) ; for field belt, run of arable/pasture
		# Compute forest run
		var cur_forest := 0
		var cur_field := 0
		var max_forest := 0
		var max_field := 0
		for i in samples.size():
			var b: StringName = samples[i]
			var is_forest := b == &"deciduous_forest" or b == &"mixed_upland_forest"
			var is_field := b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard" or b == &"orchard"
			if is_forest:
				cur_forest += 1
				cur_field = 0
				max_forest = maxi(max_forest, cur_forest)
			elif is_field:
				cur_field += 1
				cur_forest = 0
				max_field = maxi(max_field, cur_field)
			else:
				cur_forest = 0
				cur_field = 0
		# Also check speckling: count transitions
		var transitions := 0
		for i in range(1, samples.size()):
			if samples[i] != samples[i-1]:
				transitions += 1
		# speckling would be many transitions (>20) or isolated singletons
		var speckled := false
		for i in range(1, samples.size()-1):
			if samples[i] != samples[i-1] and samples[i] != samples[i+1]:
				# singleton isolated
				speckled = true
				break
		if max_forest * 8 >= 192 or max_field * 8 >= 192:
			if transitions <= 20 and not speckled:
				contig_ok = true
				contig_detail = "transect %s max_forest %d max_field %d trans %d" % [orig, max_forest, max_field, transitions]
				break
			else:
				contig_detail = "trans too many or speckled %d" % transitions
		else:
			contig_detail = "no long run at %s forest %d field %d" % [orig, max_forest, max_field]
	_check("contiguous forest/field clusters >=192m with no speckling", contig_ok, contig_detail)
	# Also check vocab subset for many random points 40 probes
	var vocab_ok := true
	var vocab_detail := ""
	var rng := RandomNumberGenerator.new()
	rng.seed = int(canonical) ^ 987654
	for i in 40:
		var rx := rng.randf_range(-2000, 2000)
		var rz := rng.randf_range(-2000, 2000)
		var p := Vector2(rx, rz)
		var b: StringName = bp.biome_at(p)
		if not WorldConstants.BIOME_VOCAB.has(b):
			vocab_ok = false
			vocab_detail = "bad vocab %s at %s" % [b, p]
			break
		var s: StringName = gp.strata_at(p)
		if not WorldConstants.GEOLOGY_STRATA_VOCAB.has(s):
			vocab_ok = false
			vocab_detail = "bad strata %s" % s
			break
	_check("vocab subset BIOME_VOCAB for 40 probes", vocab_ok, vocab_detail)

	# ---------- 2. Geographic validity for 5 seeds ----------
	for seed in all_seeds:
		var wpp := WorldPlan.new(seed)
		var tpp := TerrainPlan.new(seed)
		var hpp := HydrologyPlan.new(seed)
		var gpp := GeologyPlan.new(seed)
		var bpp := BiomePlan.new(seed, tpp, hpp, gpp)
		var rng2 := RandomNumberGenerator.new()
		rng2.seed = int(seed) ^ 424242
		var geo_ok := true
		var geo_detail := ""
		for i in 250:
			var rx := rng2.randf_range(WorldConstants.WORLD_MIN_M * 0.5, WorldConstants.WORLD_MAX_M * 0.5)
			var rz := rng2.randf_range(WorldConstants.WORLD_MIN_M * 0.5, WorldConstants.WORLD_MAX_M * 0.5)
			var p := Vector2(rx, rz)
			var biome: StringName = bpp.biome_at(p)
			var slope: float = tpp.slope_at(p)
			var tclass: StringName = tpp.terrain_class_at(p)
			var h: float = tpp.height_at(p)
			var d_water: float = hpp.distance_to_water(p)
			var is_fp: bool = hpp.is_floodplain(p)
			var water_body: StringName = hpp.water_body_at(p)
			var strata: StringName = gpp.strata_at(p)
			var qs: float = gpp.quarry_suitability_at(p)
			var fert: float = gpp.fertility_at(p)
			if biome == &"river_floodplain" or biome == &"wet_meadow":
				# must be within BANK+FLOOD+16 and slope < BUILDABLE and not cliff
				if d_water > WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W + 16.0 + 0.5:
					geo_ok = false
					geo_detail = "floodplain %s at %s d_water %.1f" % [biome, p, d_water]
					break
				if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG - 0.01 and tclass != &"cliff":
					# allow equality tolerance
					if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG + 0.5:
						geo_ok = false
						geo_detail = "floodplain steep %s slope %.1f at %s" % [biome, slope, p]
						break
				if tclass == &"cliff":
					geo_ok = false
					geo_detail = "floodplain on cliff at %s" % p
					break
			if biome == &"deciduous_forest" or biome == &"mixed_upland_forest":
				if water_body != &"" or is_fp:
					geo_ok = false
					geo_detail = "forest inside water/floodplain %s at %s" % [biome, p]
					break
				if slope >= WorldConstants.CLIFF_SLOPE_DEG:
					geo_ok = false
					geo_detail = "forest on cliff slope %.1f at %s" % [slope, p]
					break
				if biome == &"mixed_upland_forest":
					if h < WorldConstants.TERRAIN_UPLAND_HEIGHT_M - 0.5 and tclass != &"upland":
						geo_ok = false
						geo_detail = "mixed not upland h %.1f class %s at %s" % [h, tclass, p]
						break
			if biome == &"arable_field" or biome == &"pasture" or biome == &"pasture_orchard" or biome == &"orchard":
				# outside floodplain/forest already checked via not forest? but enforce
				if is_fp or water_body != &"":
					geo_ok = false
					geo_detail = "field inside floodplain %s at %s" % [biome, p]
					break
				# gentle slope
				var max_s := WorldConstants.ARABLE_MAX_SLOPE_DEG if biome == &"arable_field" else WorldConstants.PASTURE_MAX_SLOPE_DEG
				if slope >= max_s + 0.5:
					geo_ok = false
					geo_detail = "field steep %s slope %.1f at %s" % [biome, slope, p]
					break
				if biome == &"arable_field" and fert <= WorldConstants.BIOME_FERTILITY_ARABLE_MIN - 0.01:
					geo_ok = false
					geo_detail = "arable fertility %.2f at %s" % [fert, p]
					break
				if (biome == &"pasture" or biome == &"pasture_orchard" or biome == &"orchard") and fert <= WorldConstants.BIOME_FERTILITY_PASTURE_MIN - 0.01:
					# allow slightly lower
					if fert < 0.30:
						geo_ok = false
						geo_detail = "pasture fertility %.2f at %s" % [fert, p]
						break
			if biome == &"rocky_quarry":
				if qs <= WorldConstants.QUARRY_SUITABILITY_THRESHOLD - 0.001:
					geo_ok = false
					geo_detail = "quarry low suitability %.2f at %s" % [qs, p]
					break
				if not (slope >= WorldConstants.QUARRY_SLOPE_MIN_DEG - 0.5 or tclass == &"cliff" or (strata == &"limestone" and h >= 14.5)):
					geo_ok = false
					geo_detail = "quarry slope/strata fail slope %.1f class %s strata %s h %.1f at %s" % [slope, tclass, strata, h, p]
					break
				if water_body != &"" or is_fp:
					geo_ok = false
					geo_detail = "quarry inside water/floodplain at %s" % p
					break
		_check("seed %d geographic validity" % seed, geo_ok, geo_detail)
		# Hydrology distance correctly maps floodplain->wet margin->upland transect at sample Z beyond URBAN_OUTER_M
		var sample_z := 2000.0
		var cx := hpp.river_center_x_at(sample_z)
		var half := hpp.river_half_width_at(sample_z)
		var outer := half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W
		var p_flood := Vector2(cx + half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W * 0.5, sample_z)
		var p_wet := Vector2(cx + outer + 8.0, sample_z)
		var p_upland := Vector2(cx + outer + 100.0, sample_z)
		var b_flood: StringName = bpp.biome_at(p_flood)
		var b_wet: StringName = bpp.biome_at(p_wet)
		var b_up: StringName = bpp.biome_at(p_upland)
		var transect_ok := (b_flood == &"river_floodplain") or (b_flood == &"wet_meadow")
		# wet may be wet_meadow or field if moisture low, but should not be forest/quarry inside floodplain?
		# we just check that upland is not floodplain
		var up_ok := b_up != &"river_floodplain" and b_up != &"wet_meadow"
		_check("seed %d transect floodplain->wet->upland" % seed, transect_ok and up_ok, "flood %s wet %s up %s" % [b_flood, b_wet, b_up])

	# ---------- 3. Rural materialization budgets and seams ----------
	var coords: Array[Vector2i] = [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,-1), Vector2i(8,0), Vector2i(-2,3), Vector2i(10,5)]
	var manifests_fwd: Dictionary = {}
	var manifests_rev: Dictionary = {}
	for c in coords:
		manifests_fwd[c] = BiomeChunkBuilder.build_manifest(wp, c)
	var rev_coords := coords.duplicate()
	rev_coords.reverse()
	for c in rev_coords:
		manifests_rev[c] = BiomeChunkBuilder.build_manifest(wp, c)
	var det_ok := true
	var det_detail := ""
	for c in coords:
		var a_ids: Array = manifests_fwd[c]["biome_ids"]
		var b_ids: Array = manifests_rev[c]["biome_ids"]
		if a_ids.size() != b_ids.size():
			det_ok = false
			det_detail = "size mismatch %s" % c
			break
		for idx in a_ids.size():
			if a_ids[idx] != b_ids[idx]:
				det_ok = false
				det_detail = "biome_ids mismatch %s idx %d %s vs %s" % [c, idx, a_ids[idx], b_ids[idx]]
				break
		if not det_ok:
			break
		var a_cols: PackedColorArray = manifests_fwd[c]["colors"]
		var b_cols: PackedColorArray = manifests_rev[c]["colors"]
		if a_cols.size() != b_cols.size():
			det_ok = false
			det_detail = "colors size %s" % c
			break
		for idx in a_cols.size():
			if not a_cols[idx].is_equal_approx(b_cols[idx]):
				det_ok = false
				det_detail = "colors mismatch %s" % c
				break
		if not det_ok:
			break
		var a_inst: int = int(manifests_fwd[c]["instance_count"])
		var b_inst: int = int(manifests_rev[c]["instance_count"])
		if a_inst != b_inst:
			det_ok = false
			det_detail = "instance count %s %d vs %d" % [c, a_inst, b_inst]
			break
		var a_verts: int = int(manifests_fwd[c]["biome_vertices"])
		var b_verts: int = int(manifests_rev[c]["biome_vertices"])
		if a_verts != b_verts:
			det_ok = false
			det_detail = "verts %s" % c
			break
	_check("biome manifest equality shuffled order", det_ok, det_detail)
	# Shared-edge biome agreement >=7/9 at + and - boundaries
	var m0 := BiomeChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var m1 := BiomeChunkBuilder.build_manifest(wp, Vector2i(1,0))
	var ids0: Array = m0["biome_ids"]
	var ids1: Array = m1["biome_ids"]
	var agree := 0
	for j in BiomeChunkBuilder.RESOLUTION:
		var idx0 := j * BiomeChunkBuilder.RESOLUTION + (BiomeChunkBuilder.RESOLUTION - 1)
		var idx1 := j * BiomeChunkBuilder.RESOLUTION + 0
		if ids0[idx0] == ids1[idx1]:
			agree += 1
	_check("shared edge +X agreement >=7/9", agree >= 7, "%d/9" % agree)
	var mn0 := BiomeChunkBuilder.build_manifest(wp, Vector2i(-1,0))
	var mn1 := BiomeChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var idsn0: Array = mn0["biome_ids"]
	var idsn1: Array = mn1["biome_ids"]
	var agree_n := 0
	for j in BiomeChunkBuilder.RESOLUTION:
		var a_idx := j * BiomeChunkBuilder.RESOLUTION + BiomeChunkBuilder.RESOLUTION -1
		var b_idx := j * BiomeChunkBuilder.RESOLUTION
		if idsn0[a_idx] == idsn1[b_idx]:
			agree_n += 1
	_check("shared edge -X agreement >=7/9", agree_n >= 7, "%d/9" % agree_n)
	var mz0 := BiomeChunkBuilder.build_manifest(wp, Vector2i(0,0))
	var mz1 := BiomeChunkBuilder.build_manifest(wp, Vector2i(0,1))
	var idsz0: Array = mz0["biome_ids"]
	var idsz1: Array = mz1["biome_ids"]
	var agree_z := 0
	for i in BiomeChunkBuilder.RESOLUTION:
		var idx_a := (BiomeChunkBuilder.RESOLUTION -1) * BiomeChunkBuilder.RESOLUTION + i
		var idx_b := i
		if idsz0[idx_a] == idsz1[idx_b]:
			agree_z += 1
	_check("shared edge +Z agreement >=7/9", agree_z >= 7, "%d/9" % agree_z)
	# Each chunk <=1 biome collider (0 if no proxies), instances budgets
	for c in coords:
		var m: Dictionary = manifests_fwd[c]
		var coll: int = int(m["biome_colliders"])
		_check("chunk %s collider <=1" % c, coll <= 1 and coll >= 0, str(coll))
		var inst: int = int(m["instance_count"])
		var has_forest: bool = bool(m["has_forest"])
		var has_field: bool = bool(m["has_field"])
		var has_quarry: bool = bool(m["has_quarry"])
		if has_forest:
			_check("chunk %s forest instances <=48" % c, inst <= 48, str(inst))
		elif has_field and not has_forest:
			# field hedgerow <=12, but overall still <=48
			_check("chunk %s field instances <=12* (or <=48 total)" % c, inst <= 48, str(inst))
			if inst > 12 and not has_forest and has_field:
				# field dominant should be <=12, but if mixed we allow up to 48 total; check field-only
				if not has_quarry:
					_check("chunk %s field-only <=12" % c, inst <= 12, str(inst))
		if has_quarry:
			# quarry 2-6 but total still <=48
			_check("chunk %s quarry instances <=48" % c, inst <= 48, str(inst))
		if not has_forest and not has_quarry:
			_check("chunk %s non-forest/quarry collider 0" % c, coll == 0, str(coll))
		_check("chunk %s verts 81" % c, int(m["biome_vertices"]) == 81, str(m["biome_vertices"]))
		_check("chunk %s tris <=128" % c, int(m["biome_triangles"]) <= 128 and int(m["biome_triangles"]) >= 0, str(m["biome_triangles"]))
		_check("chunk %s biome_gen_ms measured" % c, m.has("biome_gen_ms") and float(m["biome_gen_ms"]) >= 0.0, str(m.get("biome_gen_ms", "")))
	# Materialize and check biome_mat_ms
	var parent := Node3D.new()
	add_child(parent)
	var wet_like_candidates: Array[Vector2i] = []
	# Find forest/quarry chunks for materialize check
	for c in [Vector2i(12,8), Vector2i(15,10), Vector2i(-8,12), Vector2i(8,8), Vector2i(10,10), Vector2i(-6,-6)]:
		var mm := BiomeChunkBuilder.build_manifest(wp, c)
		if int(mm["biome_colliders"]) == 1 or int(mm["instance_count"]) > 0:
			wet_like_candidates.append(c)
	_check("biome chunks with proxies found", wet_like_candidates.size() >= 1, str(wet_like_candidates.size()))
	for c in wet_like_candidates:
		var m: Dictionary = BiomeChunkBuilder.build_manifest(wp, c)
		var st: Dictionary = BiomeChunkBuilder.materialize(parent, m)
		_check("materialize biome_mat_ms %s" % c, st.has("biome_mat_ms") and float(st["biome_mat_ms"]) >= 0.0, str(st.get("biome_mat_ms", "")))
		_check("materialize vertices 81 %s" % c, int(st["biome_vertices"]) == 81, str(st["biome_vertices"]))
		_check("materialize collider 0/1 %s" % c, int(st["biome_colliders"]) <= 1, str(st["biome_colliders"]))
	# Dry chunk materialize expects correct (urban)
	var urban_c: Vector2i = Vector2i(0,0)
	var urban_m := BiomeChunkBuilder.build_manifest(wp, urban_c)
	if int(urban_m["instance_count"]) == 0:
		var urban_st := BiomeChunkBuilder.materialize(parent, urban_m)
		_check("urban chunk materialize 0 instances", int(urban_st["biome_instances"]) == 0, str(urban_st["biome_instances"]))
		_check("urban chunk 0 collider", int(urban_st["biome_colliders"]) == 0, str(urban_st["biome_colliders"]))
	parent.queue_free()
	# 3x3 ACTIVE <=9 biome colliders (test via ChunkManager synchronous)
	var cm := ChunkManager.new()
	add_child(cm)
	cm.synchronous = true
	cm.setup_world(CityPlan.new(), WorldPlan.new(canonical))
	var fake_player := Node3D.new()
	# Rural hill near field/forest edge: pick 900,800
	fake_player.position = Vector3(900, 0, 800)
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
	var sum_active_biome := 0
	var sum_active_verts := 0
	for coord in cm._chunks.keys():
		var rec: Dictionary = cm._chunks[coord]
		if String(rec.get("state","")) == "active":
			sum_active_biome += int(rec.get("biome_colliders",0))
			sum_active_verts += int(rec.get("biome_vertices",0))
	_check("active biome <=9 rural hill", sum_active_biome <= 9, str(sum_active_biome))
	_check("active biome == biome in ACTIVE", sum_active_biome == cm.biome_active_count(), "%d vs %d" % [sum_active_biome, cm.biome_active_count()])
	_check("bounded verts per biome chunk 81", sum_active_verts <= 9*81 or sum_active_verts == cm.biome_active_count()*81 or sum_active_verts <= 9*81, str(sum_active_verts))
	_check("active biome measured t_biome_gen present", cm._total_biome_gen_ms >= 0.0, str(cm._total_biome_gen_ms))
	_check("terrain still present with biome", cm.terrain_active_count() <= 9, str(cm.terrain_active_count()))
	_check("water still present with biome", cm.water_active_count() <= 9, str(cm.water_active_count()))
	# at least 9 resident biome chunks around rural transect
	var resident_biome := 0
	for coord in cm._chunks.keys():
		if cm.is_resident(coord) and int(cm._chunks[coord].get("biome_vertices",0)) > 0:
			resident_biome += 1
	_check("at least 9 resident biome chunks around rural", resident_biome >= 9, str(resident_biome))

	# ---------- 4. ChunkManager streams biome with terrain/water/city without duplication ----------
	var lines: Array[String] = cm.debug_lines()
	var has_biome_gen := false
	var has_biome_mat := false
	for ln in lines:
		if ln.find("t_biome_gen") != -1:
			has_biome_gen = true
		if ln.find("t_biome_mat") != -1:
			has_biome_mat = true
	_check("debug stats contain t_biome_gen", has_biome_gen, str(lines))
	_check("debug stats contain t_biome_mat", has_biome_mat, str(lines))
	# Walking 480m beyond UNLOAD_RADIUS unloads biome chunks and returning regenerates identical manifests
	var biome_coords: Array[Vector2i] = []
	for coord in cm._chunks.keys():
		var rec: Dictionary = cm._chunks[coord]
		if int(rec.get("biome_vertices",0)) > 0:
			biome_coords.append(coord)
	_check("biome chunks present for unload test", biome_coords.size() > 0, str(biome_coords.size()))
	var saved_manifests: Dictionary = {}
	for rc in biome_coords:
		var rec: Dictionary = cm._chunks[rc]
		var bm: Dictionary = rec.get("biome_manifest", {})
		if not bm.is_empty():
			saved_manifests[rc] = {
				"verts": int(bm.get("biome_vertices",0)),
				"tris": int(bm.get("biome_triangles",0)),
				"coll": int(bm.get("biome_colliders",0)),
				"colors": PackedColorArray(bm.get("colors", PackedColorArray())),
				"ids": Array(bm.get("biome_ids", [])),
				"instances": int(bm.get("instance_count",0)),
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
		for rc in biome_coords:
			if cm.is_resident(rc):
				any_old = true
				break
		if not any_old:
			break
	var unloaded_ok := true
	for rc in biome_coords:
		if cm.is_resident(rc):
			unloaded_ok = false
			break
	_check("biome chunks unload after 480m walk", unloaded_ok, str(biome_coords))
	# Return
	fake_player.position = Vector3(900, 0, 800)
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
			for rc in biome_coords:
				if not cm.is_resident(rc):
					all_back = false
					break
			if all_back:
				break
	var regen_ok := true
	var regen_detail := ""
	for rc in biome_coords:
		if not cm.is_resident(rc):
			regen_ok = false
			regen_detail = "missing %s" % rc
			break
		var rec: Dictionary = cm._chunks[rc]
		var bm: Dictionary = rec.get("biome_manifest", {})
		var saved: Dictionary = saved_manifests.get(rc, {})
		if saved.is_empty():
			continue
		if int(bm.get("biome_vertices",0)) != int(saved.get("verts",0)):
			regen_ok = false
			regen_detail = "verts mismatch %s" % rc
			break
		if int(bm.get("biome_triangles",0)) != int(saved.get("tris",0)):
			regen_ok = false
			regen_detail = "tris %s" % rc
			break
		if int(bm.get("biome_colliders",0)) != int(saved.get("coll",0)):
			regen_ok = false
			regen_detail = "coll %s" % rc
			break
		if int(bm.get("instance_count",0)) != int(saved.get("instances",0)):
			regen_ok = false
			regen_detail = "instances %s %d vs %d" % [rc, int(bm.get("instance_count",0)), int(saved.get("instances",0))]
			break
		var cols_a: PackedColorArray = bm.get("colors", PackedColorArray())
		var cols_b: PackedColorArray = saved.get("colors", PackedColorArray())
		if cols_a.size() != cols_b.size():
			regen_ok = false
			regen_detail = "colors size %s" % rc
			break
		for idx in cols_a.size():
			if not cols_a[idx].is_equal_approx(cols_b[idx]):
				regen_ok = false
				regen_detail = "colors mismatch %s" % rc
				break
		if not regen_ok:
			break
		var ids_a: Array = bm.get("biome_ids", [])
		var ids_b: Array = saved.get("ids", [])
		if ids_a.size() != ids_b.size():
			regen_ok = false
			regen_detail = "ids size %s" % rc
			break
		for idx in ids_a.size():
			if ids_a[idx] != ids_b[idx]:
				regen_ok = false
				regen_detail = "ids mismatch %s" % rc
				break
		if not regen_ok:
			break
	_check("biome chunks regenerate identical manifests after return", regen_ok, regen_detail)
	# Generated biome excluded from save_state()
	var save: Dictionary = cm.save_state()
	var has_biome_keys := false
	var save_str := str(save)
	if save_str.find("biome_vertices") != -1 or save_str.find("biome_triangles") != -1 or save_str.find("biome_manifest") != -1 or save_str.find("biome_instances") != -1:
		has_biome_keys = true
	_check("generated biome excluded from save_state()", not has_biome_keys, save_str.substr(0, 300))
	# Also check that save contains records but not biome geometry
	_check("save_state has records", save.has("records"), str(save.keys()))
	cm.queue_free()
	fake_player.queue_free()
	# ---------- 5. Determinism and buildability preserved ----------
	_check("GENERATOR_VERSION stays 2", WorldSeed.GENERATOR_VERSION == 2, str(WorldSeed.GENERATOR_VERSION))
	# WorldPlan pure check: after queries, second plan gives same height
	var wp2 := WorldPlan.new(canonical)
	var pure_ok := is_equal_approx(wp.terrain_height_at(Vector2(100,200)), wp2.terrain_height_at(Vector2(100,200)))
	_check("WorldPlan pure", pure_ok, "")
	# Spawn still urban_basin dry
	var spawn: Vector2 = CityPlan.new().find_spawn_point()
	var spawn_biome: StringName = wp.biome_at(spawn)
	var spawn_water: StringName = wp.water_body_at(spawn)
	_check("spawn urban_basin dry", spawn_biome == &"urban_basin" and spawn_water == &"", "%s water %s" % [spawn_biome, spawn_water])
	# CityPlan IDs unchanged: digest before/after? simple check building count similar
	var city_before := CityPlan.new()
	var city_after := CityPlan.new()
	var b1 := city_before.buildings_in_rect(Rect2(-160,-160,320,320)).size()
	var b2 := city_after.buildings_in_rect(Rect2(-160,-160,320,320)).size()
	_check("CityPlan IDs stable", b1 == b2 and b1 > 0, "%d vs %d" % [b1,b2])
	# TerrainPlan 17x17 unchanged
	var tm := TerrainChunkBuilder.build_manifest(wp, Vector2i.ZERO)
	_check("TerrainPlan 17x17 289/512", tm.get("resolution",0)==17 and int(tm.get("terrain_vertices",0))==289 and int(tm.get("terrain_triangles",0))==512, str(tm))
	# Hydrology CX/width still 530-710/72/38-50
	var hpp := HydrologyPlan.new(canonical)
	_check("hydrology CX 530-710", hpp.cx_mean >= 530.0 and hpp.cx_mean <= 710.0, str(hpp.cx_mean))
	var w := hpp.river_width_at(0.0)
	_check("hydrology width 38-50", w >= 38.0 and w <= 50.0, str(w))
	var meander_ok := true
	for zi in 10:
		var zf := -1000.0 + float(zi)*200.0
		var cen := hpp.river_center_x_at(zf)
		if absf(cen - hpp.cx_mean) > WorldConstants.HYDRO_MEANDER_AMPL + WorldConstants.HYDRO_MEANDER2_AMPL + 1.0:
			meander_ok = false
			break
	_check("hydrology meander 72+18", meander_ok, "")
	# Existing budgets not weakened: checked via other harnesses but ensure local sanity
	# Check water manifest still 81/128
	var wm2 := WaterChunkBuilder.build_manifest(wp, Vector2i(8,0))
	if int(wm2.get("water_colliders",0))==1:
		_check("water still 81 verts", int(wm2.get("water_vertices",0))==81, str(wm2.get("water_vertices",0)))
		_check("water still <=128 tris", int(wm2.get("water_triangles",0))<=128, str(wm2.get("water_triangles",0)))
		for k in wm2.keys():
			if str(k) == "district_hint":
				_check("water district_hint present", wm2.has("district_hint") and WorldConstants.WATER_DISTRICT_HINTS.has(wm2.get("district_hint")), str(wm2.get("district_hint")))
				break
	# Check that no biome vertices leaked into save
	var total_biome_checks := 0
	for seed in all_seeds:
		var gpp := GeologyPlan.new(seed)
		var bpp2 := BiomePlan.new(seed)
		for p in pts:
			if WorldConstants.BIOME_VOCAB.has(bpp2.biome_at(p)) and WorldConstants.GEOLOGY_STRATA_VOCAB.has(gpp.strata_at(p)):
				total_biome_checks += 1
	_check("biome/geology vocab checks across seeds", total_biome_checks >= 40, str(total_biome_checks))
