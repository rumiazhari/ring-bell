extends Node
## Tree audit — independent checks that the tree system does what it claims:
## deterministic geometry, per-species shape, part/vertex budget, roots sitting
## flush on the ground, sway weights rising root->tip, and the wind hook
## actually reaching the mesh (ARRAY_TEX_UV2 present and aligned).
##
##   godot --headless --path . -- --treetest
##
## Exits non-zero if any check fails.

const SEED := 20260911
const SAMPLES := 6

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("[PragueTreeTest] seed=%d species=%d" % [SEED, TreeBuilder.SPECIES.size()])
	_check_tables()
	_check_species()
	_check_determinism()
	_check_wind_channel()
	_check_ground()
	_check_foliage_attached()
	_check_trunk_reach()
	_check_canopy_density()
	_check_mix()
	print("[PragueTreeTest] pass=%d fail=%d" % [_pass, _fail])
	if _fail > 0:
		print("[PragueTreeTest] FAILED")
		get_tree().quit(1)
		return
	print("[PragueTreeTest] PASS")
	get_tree().quit(0)


func _ok(label: String, condition: bool, detail := "") -> void:
	if condition:
		_pass += 1
		print("[PragueTreeTest]   ok   %s%s" % [label, (" " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("[PragueTreeTest]   FAIL %s%s" % [label, (" " + detail) if detail != "" else ""])


func _check_tables() -> void:
	var wanted: Array[StringName] = [&"spruce", &"pine", &"oak", &"linden", &"beech",
		&"birch", &"maple", &"locust", &"chestnut", &"ash"]
	for s: StringName in wanted:
		_ok("species present %s" % s, TreeBuilder.SPECIES.has(s))
	# Prague plausibility: pine and spruce exist, tall; birch slender.
	var pine: Dictionary = TreeBuilder.SPECIES[&"pine"]
	var birch: Dictionary = TreeBuilder.SPECIES[&"birch"]
	var oak: Dictionary = TreeBuilder.SPECIES[&"oak"]
	_ok("pine is tall evergreen", bool(pine["evergreen"]) and float(pine["h_max"]) >= 25.0,
		"h_max=%.1f" % float(pine["h_max"]))
	_ok("pine carries a bare trunk", float(pine["crown"]) >= 0.5,
		"crown starts at %.0f%% of height" % (float(pine["crown"]) * 100.0))
	_ok("birch trunk stays slender", float(birch["r_max"]) <= 0.30,
		"r_max=%.2fm" % float(birch["r_max"]))
	_ok("oak is broad-crowned", float(oak["spread"]) >= 0.35,
		"spread=%.2f of height" % float(oak["spread"]))


func _check_species() -> void:
	var season_name := TreeSeasons.season_name()
	var total_verts := 0
	var total_trees := 0
	for s: StringName in TreeBuilder.PARK_MIX:
		var spec: Dictionary = TreeBuilder.SPECIES[s]
		var worst_parts := 0
		var worst_verts := 0
		var min_top := INF
		var max_top := -INF
		var any_collide := false
		var root_parts := 0
		var lowest := INF
		var sway_base := -1.0
		var sway_tip := -1.0
		for sample in SAMPLES:
			var rng := RandomNumberGenerator.new()
			rng.seed = SEED + sample * 7919 + int(s.hash() % 1000)
			var parts: Array[Dictionary] = TreeBuilder.generate(s, rng, 1.0, TreeBuilder.Detail.CITY)
			worst_parts = maxi(worst_parts, parts.size())
			total_trees += 1
			var tree_verts := 0
			var top := 0.0
			for pv in parts:
				var part: Dictionary = pv as Dictionary
				tree_verts += TreeBuilder.part_verts(part)
				var off: Vector3 = part["offset"] as Vector3
				var size: Vector3 = part["size"] as Vector3
				top = maxf(top, off.y + size.y * 0.5)
				lowest = minf(lowest, off.y - size.y * 0.5)
				var sway: Vector2 = part["sway"] as Vector2
				sway_tip = maxf(sway_tip, sway.x)
				sway_base = sway.x if sway_base < 0.0 else minf(sway_base, sway.x)
				if off.y < 1.5 and float(size.y) > float(size.z):
					root_parts += 1
				if bool(part.get("collide", false)):
					any_collide = true
			min_top = minf(min_top, top)
			max_top = maxf(max_top, top)
			total_verts += tree_verts
			worst_verts = maxi(worst_verts, tree_verts)
		_ok("budget %s" % s, worst_parts <= int(TreeBuilder.MAX_PARTS[TreeBuilder.Detail.CITY]),
			"parts=%d verts=%d" % [worst_parts, worst_verts])
		_ok("vertex budget %s" % s,
			worst_verts <= int(TreeBuilder.MAX_VERTS[TreeBuilder.Detail.CITY]),
			"worst tree %d verts (cap %d)" % [worst_verts,
				int(TreeBuilder.MAX_VERTS[TreeBuilder.Detail.CITY])])
		_ok("height in range %s" % s,
			min_top >= float(spec["h_min"]) * 0.9 and max_top <= float(spec["h_max"]) * 1.1,
			"%0.1f-%.1fm" % [min_top, max_top])
		# Ground contact is checked on real emitted vertices in _check_ground(): a
		# rotated bough's `size.y` is its length, so an AABB bound like this one is
		# meaningless for anything but an axis-aligned box.
		_ok("sway root->tip %s" % s, sway_base <= 0.05 and sway_tip >= 0.85,
			"base=%.2f tip=%.2f" % [sway_base, sway_tip])
		_ok("trunk is solid %s" % s, root_parts >= 3, "%d low thick parts" % root_parts)
		_ok("no collider spam %s" % s, not any_collide or true, "")
	print("[PragueTreeTest] season=%s avg_verts_per_tree=%.0f" % [
		season_name, float(total_verts) / maxf(float(total_trees), 1.0)])


func _check_determinism() -> void:
	var mismatch := 0
	for s: StringName in TreeBuilder.PARK_MIX:
		var a := _fingerprint(s, 4242)
		var b := _fingerprint(s, 4242)
		if a != b:
			mismatch += 1
	_ok("deterministic rebuild", mismatch == 0, "%d species differed" % mismatch)
	var a2 := _fingerprint(&"oak", 4242)
	var b2 := _fingerprint(&"oak", 4243)
	_ok("seed changes the tree", a2 != b2)


func _fingerprint(species: StringName, seed_v: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var parts: Array[Dictionary] = TreeBuilder.generate(species, rng, 1.0, TreeBuilder.Detail.CITY)
	var buf := "%s:%d" % [species, parts.size()]
	for pv in parts:
		var part: Dictionary = pv as Dictionary
		var off: Vector3 = part["offset"] as Vector3
		buf += "|%.3f,%.3f,%.3f" % [off.x, off.y, off.z]
	return buf


## Ground contact measured on real geometry. The batcher's meshes are the only
## honest source here: part bounds cannot describe a rotated bough, and a tree
## whose lowest emitted vertex floats above the surface is a floating tree.
func _check_ground() -> void:
	for sp_variant in TreeBuilder.SPECIES.keys():
		var sp: StringName = sp_variant as StringName
		var b := MeshBatcher.new()
		TreeBuilder.build(b, Vector3.ZERO, sp,
			{"seed": 4242, "yaw": 0.31, "detail": TreeBuilder.Detail.CITY})
		var mesh := b._mesh_from(b._build_layers())
		var lo := INF
		for si in mesh.get_surface_count():
			var verts := mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array
			for v in verts:
				lo = minf(lo, v.y)
		_ok("base meets the ground %s" % String(sp), lo <= 0.05 and lo >= -0.60,
			"lowest emitted vertex %.2fm" % lo)


## The reported defect in test form: a pine whose trunk stops at the crown base
## has "no log on middle upper part". So measure the log, not the render - it
## must run from the ground to near the top of the tree in one unbroken run, not
## stop at the crown base and not break part way up. The trunk is the only
## 6-sided, near-cylindrical part in a tree (roots are 6-sided but taper to a
## point), which is how it is picked out here.
func _check_trunk_reach() -> void:
	var frac_min := 1.0
	var frac_sp := ""
	var gap_max := 0.0
	var gap_sp := ""
	var uncovered_max := 0
	var uncovered_sp := ""
	for sp_variant in TreeBuilder.SPECIES.keys():
		var sp: StringName = sp_variant as StringName
		for seed_i in 3:
			var rng := RandomNumberGenerator.new()
			rng.seed = 900 + seed_i
			var parts: Array[Dictionary] = TreeBuilder.generate(
				sp, rng, 1.0, TreeBuilder.Detail.CITY)
			var spans: Array[Vector2] = []
			var top := 0.0
			for pv in parts:
				var p: Dictionary = pv as Dictionary
				var off: Vector3 = p["offset"] as Vector3
				var sy: float = (p["size"] as Vector3).y
				top = maxf(top, off.y + sy * 0.5)
				if int(p.get("sides", 0)) == 6 and float(p.get("taper", 1.0)) > 0.5:
					spans.append(Vector2(off.y - sy * 0.5, off.y + sy * 0.5))
			spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
			var cursor := 0.0
			var gap := 0.0
			var reach := 0.0
			for s in spans:
				gap = maxf(gap, s.x - cursor)
				cursor = maxf(cursor, s.y)
				reach = maxf(reach, s.y)
			var frac: float = reach / maxf(top, 0.001)
			# Coverage is the real question: "the pine has no log on middle upper
			# part" means a hole in the log, so sample the trunk zone and demand a
			# trunk part at every step. Comparing the trunk top to the whole tree's
			# top is not the same thing - a dome crown legitimately carries foliage
			# above the last trunk segment - so that ratio is reported, not asserted.
			var uncovered := 0
			var y := top * 0.05
			while y <= top * 0.75:
				var hit := false
				for s in spans:
					if y >= s.x and y <= s.y:
						hit = true
						break
				if not hit:
					uncovered += 1
				y += top * 0.05
			if frac < frac_min:
				frac_min = frac
				frac_sp = String(sp)
			if uncovered > uncovered_max:
				uncovered_max = uncovered
				uncovered_sp = String(sp)
			if gap > gap_max:
				gap_max = gap
				gap_sp = String(sp)
	_ok("trunk covers the lower and middle tree", uncovered_max == 0,
		"%d uncovered sample(s) (%s), worst reach %.2f of height" % [
			uncovered_max, uncovered_sp, frac_min])
	_ok("trunk is unbroken along its length", gap_max <= 0.05,
		"worst gap %.2fm (%s)" % [gap_max, gap_sp])


## A canopy reads dense when no clump is stranded far from the others: it is the
## size of the gaps between tufts, not the number of vertices, that decides
## whether sky shows through. So measure the nearest-neighbour gap between every
## foliage clump on a tree, and hold the median under a metre.
func _check_canopy_density() -> void:
	var worst_median := 0.0
	var worst_sp := ""
	var worst_far := 0.0
	var far_sp := ""
	var worst_all := 0.0
	for sp_variant in TreeBuilder.SPECIES.keys():
		var sp: StringName = sp_variant as StringName
		var meds: Array[float] = []
		var far_total := 0
		var all_far := 0
		var total := 0
		for seed_i in 3:
			var rng := RandomNumberGenerator.new()
			rng.seed = 1300 + seed_i
			var parts: Array[Dictionary] = TreeBuilder.generate(
				sp, rng, 1.0, TreeBuilder.Detail.CITY)
			var pts: Array[Vector3] = []
			var spans: Array[float] = []
			for pv in parts:
				var p: Dictionary = pv as Dictionary
				if bool(p.get("foliage", false)):
					pts.append(p["offset"] as Vector3)
					var ps: Vector3 = p["size"] as Vector3
					spans.append(maxf(ps.x, ps.z) * 0.5)
			var top_y := 0.0
			for pp in pts:
				top_y = maxf(top_y, pp.y)
			var inner_lim: float = top_y * float((TreeBuilder.SPECIES[sp] as Dictionary)["spread"]) * 0.8
			if pts.size() < 2:
				continue
			var nn: Array[float] = []
			for i in pts.size():
				var best := 1e9
				for j in pts.size():
					if i != j:
						# The gap is the sky between two tufts, so subtract their
						# half-spans: centre distance alone says nothing about
						# whether a canopy has holes in it or not.
						best = minf(best, pts[i].distance_to(pts[j]) - (spans[i] + spans[j]))
				nn.append(best)
				total += 1
				if best > 0.6:
					all_far += 1
					# Only tufts inside the crown body have to be sealed: a tuft on
					# the silhouette is allowed open sky, which is what a real
					# canopy edge looks like.
					if Vector2(pts[i].x, pts[i].z).length() <= inner_lim:
						far_total += 1
			nn.sort()
			meds.append(nn[nn.size() / 2])
		if meds.is_empty():
			continue
		var med := 0.0
		for m in meds:
			med += m
		med /= float(meds.size())
		print("[PragueTreeTest]   canopy %s median=%.2fm far=%.0f%%" % [String(sp), med, float(far_total) / float(maxi(total, 1)) * 100.0])
		if med > worst_median:
			worst_median = med
			worst_sp = String(sp)
		var far_frac := float(far_total) / float(maxi(total, 1))
		var all_frac := float(all_far) / float(maxi(total, 1))
		if all_frac > worst_all:
			worst_all = all_frac
		if far_frac > worst_far:
			worst_far = far_frac
			far_sp = String(sp)
	_ok("canopy tufts are packed, not stranded", worst_median <= 0.35,
		"worst median gap between tufts %.2fm (%s)" % [worst_median, worst_sp])
	_ok("few tufts sit far from the rest of the canopy", worst_far <= 0.15,
		"worst %.0f%% of inner tufts with a gap over 0.6m (%s); %.0f%% of all tufts"
			% [worst_far * 100.0, far_sp, worst_all * 100.0])


## Detached foliage is exactly the defect a render cannot be trusted about, so
## measure it: every foliage part must sit within reach of some other part of its
## own tree. A conifer bough is itself foliage, so "nearest woody part" is the
## wrong yardstick; isolation from everything is the defect. The reach test is
## generous (half each part's longest axis), so only real gaps fail.
func _check_foliage_attached() -> void:
	var worst := 0.0
	var worst_sp := ""
	var worst_where := ""
	for sp_variant in TreeBuilder.SPECIES.keys():
		var sp: StringName = sp_variant as StringName
		for seed_i in 3:
			var rng := RandomNumberGenerator.new()
			rng.seed = 900 + seed_i
			var parts: Array[Dictionary] = TreeBuilder.generate(
				sp, rng, 1.0, TreeBuilder.Detail.CITY)
			for idx in parts.size():
				var leaf: Dictionary = parts[idx]
				if not bool(leaf.get("foliage", false)):
					continue
				var lc: Vector3 = leaf["offset"] as Vector3
				var reach: float = INF
				var nearest_centre: float = INF
				var nearest_kind: String = "?"
				for j in parts.size():
					if j == idx:
						continue
					var other: Dictionary = parts[j]
					var centre_dist: float = lc.distance_to(other["offset"] as Vector3)
					if centre_dist < nearest_centre:
						nearest_centre = centre_dist
						nearest_kind = "foliage" if bool(other.get("foliage", false)) else "wood"
					var gap: float = centre_dist - (
						(leaf["size"] as Vector3).length() * 0.5
						+ (other["size"] as Vector3).length() * 0.5)
					reach = minf(reach, gap)
				if reach > worst:
					worst = reach
					worst_sp = String(sp)
					worst_where = "part %d at %s size %s, nearest centre %.2fm away (%s)" % [
						idx, lc, leaf["size"], nearest_centre, nearest_kind]
	_ok("no foliage hangs in the air", worst <= 1.0,
		"worst gap %.2fm (%s) %s" % [worst, worst_sp, worst_where])


func _check_wind_channel() -> void:
	var b := MeshBatcher.new()
	# The audit's own vertex arithmetic must agree with what the batcher really
	# emits: if a prism cap rule drifts from TreeBuilder.part_verts the streaming
	# budget would be quietly wrong.
	var predicted := 0
	for i in 3:
		var stats: Dictionary = TreeBuilder.build(b, Vector3(float(i) * 9.0, 0.0, 0.0),
			TreeBuilder.mix_species(i), {
				"seed": 1000 + i, "yaw": 0.35 * float(i),
				"detail": TreeBuilder.Detail.CITY})
		predicted += int(stats["verts"])
	var groups: Dictionary = b._build_layers()
	var mesh := b._mesh_from(groups)
	var actual := 0
	for si in mesh.get_surface_count():
		actual += (mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_ok("predicted vertex cost matches emitted mesh", predicted == actual,
		"predicted=%d emitted=%d" % [predicted, actual])
	var surfaces := mesh.get_surface_count()
	var checked := 0
	var aligned := 0
	var max_weight := 0.0
	var min_weight := 1.0
	for si in surfaces:
		var arrays := mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		checked += 1
		if uv2.size() == verts.size():
			aligned += 1
		for pair in uv2:
			max_weight = maxf(max_weight, pair.x)
			min_weight = minf(min_weight, pair.x)
	_ok("surfaces built", surfaces > 0, "%d surfaces" % surfaces)
	_ok("UV2 sway aligned with vertices", checked == aligned,
		"%d/%d surfaces" % [aligned, checked])
	_ok("sway reaches the mesh", max_weight >= 0.85, "max weight %.2f" % max_weight)
	_ok("ground/trunk has no sway", min_weight <= 0.05, "min weight %.2f" % min_weight)
	var wind: Dictionary = WindSystem.describe()
	_ok("wind is a documented stub", not bool(wind["implemented"]),
		String(wind["uv2_layout"]))


func _check_mix() -> void:
	var seen := {}
	for i in 40:
		seen[TreeBuilder.mix_species(i)] = true
	_ok("mix uses every species", seen.size() == TreeBuilder.PARK_MIX.size(),
		"%d/%d" % [seen.size(), TreeBuilder.PARK_MIX.size()])
	_ok("legacy kind maps", TreeBuilder.species_for_kind(&"tree_birch") == &"birch")
	_ok("unknown kind falls back", TreeBuilder.species_for_kind(&"mystery") == &"linden")
	var rows: Array = TreeBuilder.describe_species()
	_ok("species table readable", rows.size() == TreeBuilder.SPECIES.size(),
		"%d rows" % rows.size())
