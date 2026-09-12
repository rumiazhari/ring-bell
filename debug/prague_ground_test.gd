extends Node
## Independent audit of the city's GROUND against the realized terrain.
##
## The defect this exists for: a ground surface emitted as one FLAT layer at the
## height of a single sample point (a block centre, a polygon centroid, the
## highest of a 3x3 grid). Wherever the terrain is not level, such a pad hangs
## in the air over its downhill half - a green plate flying above the pavement -
## or buries its uphill half. Nothing here reuses the generator's own placement
## predicate: every pad, wall and prop is compared against WorldPlan directly.
##
##   A. ground pads      does each emitted polygon follow the surface under it?
##   B. ground slabs     does a flat paving slab hover over the ground?
##   C. walls and fences does a long run stand on the ground along its length?
##   D. ground props     do trees, fences, debris stand ON the terrain?
##
## Audited on the city chunk builder and on the fringe manifest builder.
## Exit code is the failure count, so tools/run_suite.py can gate on it.
var failures := 0

## A pad that follows the terrain shows the same (surface - terrain) offset at
## every one of its own vertices. A flat pad over a slope shows the slope.
const FOLLOW_TOL := 0.06
## A real pad is laid 2-16 cm above the ground; more than this is a floater.
const FLOAT_MAX := 0.35
## Being buried is bad too, but surfaces overlap on purpose at junctions.
const BURIED_MIN := -0.12
## A paving slab: flat, big enough to be ground, and its TOP is at ground level
## (which is what separates a slab from an awning or a table top at the same
## footprint).
const SLAB_MAX_H := 0.70
const SLAB_MIN_FOOT := 12.0
const SLAB_TOP_MAX := 0.70
## Air under a slab is always wrong: a slab is laid ON the ground. The 0.35 m
## allowance is for stoops and steps that meet a building's raised ground.
const SLAB_CLEAR_MAX := 0.35
## A wall run: thin, long, and low enough to be masonry rather than a roof.
const WALL_MIN_FOOT := 8.0
const WALL_MAX_THICK := 0.60
const WALL_MAX_H := 3.50
## A wall must meet the ground along its length; posts and plinths are sunk on
## purpose, so only air underneath counts.
const WALL_CLEAR_MAX := 0.15
## A tree, a fence post or a debris pile is rooted in the ground. Posts are
## driven IN on purpose, so only a prop standing in the air is a defect.
const PROP_FLOAT_MAX := 0.35

## City chunks audited per seed (historic core first).
const MAX_CHUNKS := 24
const MAX_FRINGE_CHUNKS := 8
## Fringe chunks audited per seed.
## The palette the ground passes paint with. Only these colours are judged as
## ground slabs; a table top or an awning is somebody else's problem.
const GROUND_COLORS: Array[String] = [
	"6b6a62", "847d70", "8f887b", "a29a8b", "98948a", "b3ab97", "7e7668",
	"55693f", "647054", "776b59", "8b7656", "71814d", "6a7a5a",
]

## Fence and wall paint (WorldConstants.COL_FRINGE_WALL_BRICK / _FENCE_WOOD).
const WALL_COLORS: Array[String] = ["8a3a2a", "6b4b32"]

var _colors: Array[Color] = []
var _wall_colors: Array[Color] = []


func _ready() -> void:
	for c: String in GROUND_COLORS:
		_colors.append(Color(c))
	for w: String in WALL_COLORS:
		_wall_colors.append(Color(w))
	var diag := OS.get_cmdline_user_args().has("--diag")
	for seed_value: int in [19041207, 19041208, 19041209]:
		audit(seed_value, diag)
		if OS.get_cmdline_user_args().has("--single"):
			break
	print("[PragueGroundTest] finished with %d failure(s)" % failures)
	get_tree().quit(failures)


func audit(seed_value: int, diag: bool) -> void:
	var started := Time.get_ticks_msec()
	var plan := CityPlan.new(seed_value)
	var world_plan := WorldPlan.new(seed_value)

	# Every chunk that owns a block, historic core first.
	var coords := {}
	var historic: Array[Vector2i] = []
	var other: Array[Vector2i] = []
	for block_variant in plan.city_blocks():
		var block: Dictionary = block_variant as Dictionary
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		var coord := WorldSeed.chunk_coord(center.x, center.y)
		if coords.has(coord):
			continue
		coords[coord] = true
		if StringName(block.get("district", &"")) == CityPlan.DISTRICT_HISTORIC:
			historic.append(coord)
		else:
			other.append(coord)
	historic.sort()
	other.sort()
	# Cap the walk: every historic chunk first, then the rest, so the audit is a
	# census of the core and a sample of the outskirts rather than a stall.
	var visit: Array[Vector2i] = (historic + other).slice(0, MAX_CHUNKS)

	var acc := _blank()
	for index in visit.size():
		var coord: Vector2i = visit[index]
		if index % 4 == 0:
			print("[PragueGroundTest]   ...chunk %d/%d at %s (%d ms)" % [
				index + 1, visit.size(), str(coord), Time.get_ticks_msec() - started])
		var b := MeshBatcher.new()
		ChunkBuilder.fill_batcher(b, plan, coord, world_plan)
		_audit_batcher(b, world_plan, diag, acc)

	# The fringe builds its own manifest: yards, compound walls and fences live
	# there, on far steeper ground than the city.
	var fringe_visit: Array[Vector2i] = []
	for cx in range(-7, 8):
		for cz in range(-7, 8):
			var coord := Vector2i(cx, cz)
			if world_plan.fringe_buildings_in(WorldSeed.chunk_rect(coord)).is_empty():
				continue
			fringe_visit.append(coord)
			if fringe_visit.size() >= MAX_FRINGE_CHUNKS:
				break
		if fringe_visit.size() >= MAX_FRINGE_CHUNKS:
			break
	for coord: Vector2i in fringe_visit:
		var manifest: Dictionary = FringeChunkBuilder.build_manifest(world_plan, coord)
		var fb: MeshBatcher = manifest.get("batcher", null) as MeshBatcher
		if fb == null:
			continue
		_audit_batcher(fb, world_plan, diag, acc, "fringe")

	var ms := Time.get_ticks_msec() - started
	print("[PragueGroundTest] seed=%d ms=%d chunks=%d fringe_chunks=%d pads=%d pad_not_following=%d pad_floating=%d pad_buried=%d slabs=%d floating_slabs=%d worst_slab_clear=%.2fm walls=%d floating_walls=%d worst_wall_clear=%.2fm props=%d floating_props=%d worst_prop_float=%.2fm" % [
		seed_value, ms, visit.size(), fringe_visit.size(),
		acc["pads"], acc["pad_not_following"], acc["pad_floating"],
		acc["pad_buried"], acc["slabs"], acc["floating_slabs"],
		acc["worst_slab_clear"], acc["walls"], acc["floating_walls"],
		acc["worst_wall_clear"], acc["props"], acc["floating_props"],
		acc["worst_prop_float"]])

	_check(acc["pad_not_following"] == 0,
		"every ground pad follows the terrain under it (spread <= %.2f m)" % FOLLOW_TOL,
		acc["pad_not_following"], acc["pads"])
	_check(acc["pad_floating"] == 0,
		"no ground pad floats above the terrain", acc["pad_floating"], acc["pads"])
	_check(acc["pad_buried"] == 0,
		"no ground pad sinks under the terrain", acc["pad_buried"], acc["pads"])
	_check(acc["floating_slabs"] == 0,
		"no flat paving slab hovers over the ground", acc["floating_slabs"],
		acc["slabs"])
	_check(acc["floating_walls"] == 0,
		"every wall and fence meets the ground along its length",
		acc["floating_walls"], acc["walls"])
	_check(acc["floating_props"] == 0,
		"every ground prop stands on the terrain", acc["floating_props"],
		acc["props"])


func _blank() -> Dictionary:
	return {
		"pads": 0, "pad_not_following": 0, "pad_floating": 0, "pad_buried": 0,
		"slabs": 0, "floating_slabs": 0, "worst_slab_clear": 0.0,
		"walls": 0, "floating_walls": 0, "worst_wall_clear": 0.0,
		"props": 0, "floating_props": 0, "worst_prop_float": 0.0,
		"shown_pad": 0, "shown_slab": 0, "shown_wall": 0, "shown_prop": 0,
	}


func _audit_batcher(b: MeshBatcher, world_plan: WorldPlan, diag: bool,
		acc: Dictionary, where := "city") -> void:
	# A. ground pads
	for poly_variant in b.manifest().get("polygons", []) as Array:
		var poly: Dictionary = poly_variant as Dictionary
		var points: PackedVector2Array = poly.get("points", PackedVector2Array()) as PackedVector2Array
		if points.size() < 3:
			continue
		var heights: PackedFloat32Array = poly.get("heights", PackedFloat32Array()) as PackedFloat32Array
		var flat_y := float(poly.get("y", 0.0))
		acc["pads"] += 1
		var lo := INF
		var hi := -INF
		for i in points.size():
			var surface := heights[i] if heights.size() == points.size() else flat_y
			var delta := surface - world_plan.surface_height_at(points[i])
			lo = minf(lo, delta)
			hi = maxf(hi, delta)
		var bad_follow := (hi - lo) > FOLLOW_TOL
		var bad_float := hi > FLOAT_MAX
		var bad_buried := lo < BURIED_MIN
		if bad_follow:
			acc["pad_not_following"] += 1
		if bad_float:
			acc["pad_floating"] += 1
		if bad_buried:
			acc["pad_buried"] += 1
		if (bad_follow or bad_float or bad_buried) and diag and acc["shown_pad"] < 6:
			acc["shown_pad"] += 1
			var pc: Color = poly.get("color", Color.WHITE) as Color
			print("[PragueGroundTest]   %s pad %s layer=%s pts=%d flat=%s spread=%.2fm above=%.2fm below=%.2fm at (%.1f, %.1f)" % [
				where, pc.to_html(false), str(poly.get("layer", "")), points.size(),
				"yes" if heights.is_empty() else "no", hi - lo, hi, lo,
				points[0].x, points[0].y])

	var specs: Array[Dictionary] = b.specs()
	for spec_variant in specs:
		var spec: Dictionary = spec_variant as Dictionary
		var size: Vector3 = spec.get("size", Vector3.ZERO) as Vector3
		var abs_size := Vector3(absf(size.x), absf(size.y), absf(size.z))
		if abs_size.x < 0.02 or abs_size.z < 0.02:
			continue
		var basis: Basis = spec.get("basis", Basis.IDENTITY) as Basis
		var pos: Vector3 = spec.get("pos", Vector3.ZERO) as Vector3
		var hx := abs_size.x * 0.5
		var hy := abs_size.y * 0.5
		var hz := abs_size.z * 0.5
		var bottom := INF
		var top := -INF
		var worst_corner := Vector2.ZERO
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var low := pos + basis * Vector3(sx * hx, -hy, sz * hz)
				var high := pos + basis * Vector3(sx * hx, hy, sz * hz)
				var low_gap := low.y - world_plan.surface_height_at(Vector2(low.x, low.z))
				var high_gap := high.y - world_plan.surface_height_at(Vector2(high.x, high.z))
				if low_gap < bottom:
					bottom = low_gap
					worst_corner = Vector2(low.x, low.z)
				top = maxf(top, high_gap)

		# B. a paving slab lies on the ground: flat, its top at ground level,
		# and no air underneath.
		if abs_size.y <= SLAB_MAX_H and abs_size.x * abs_size.z >= SLAB_MIN_FOOT \
				and top <= SLAB_TOP_MAX and _is_ground_color(spec.get("color", Color.WHITE) as Color):
			acc["slabs"] += 1
			if bottom > SLAB_CLEAR_MAX:
				acc["floating_slabs"] += 1
				acc["worst_slab_clear"] = maxf(acc["worst_slab_clear"], bottom)
				if diag and acc["shown_slab"] < 6:
					acc["shown_slab"] += 1
					var sc: Color = spec.get("color", Color.WHITE) as Color
					print("[PragueGroundTest]   %s slab %s size=%.1fx%.1fx%.1f clear=%.2fm at (%.1f, %.1f)" % [
						where, sc.to_html(false), abs_size.x, abs_size.y, abs_size.z,
						bottom, worst_corner.x, worst_corner.y])
		# C. a wall run: thin, long, masonry height, and painted in the fence and
		# wall palette. Without that colour gate a long cornice band on a facade
		# reads as a floating wall, which is why rule C is the fringe's business:
		# the city does not build compound walls at all.
		elif _is_wall_color(spec.get("color", Color.WHITE) as Color) \
				and abs_size.x * abs_size.z >= WALL_MIN_FOOT \
				and minf(abs_size.x, abs_size.z) <= WALL_MAX_THICK \
				and abs_size.y <= WALL_MAX_H:
			acc["walls"] += 1
			if bottom > WALL_CLEAR_MAX:
				acc["floating_walls"] += 1
				acc["worst_wall_clear"] = maxf(acc["worst_wall_clear"], bottom)
				if diag and acc["shown_wall"] < 6:
					acc["shown_wall"] += 1
					var wc: Color = spec.get("color", Color.WHITE) as Color
					print("[PragueGroundTest]   %s wall %s size=%.1fx%.1fx%.1f clear=%.2fm at (%.1f, %.1f)" % [
						where, wc.to_html(false), abs_size.x, abs_size.y, abs_size.z,
						bottom, worst_corner.x, worst_corner.y])

	# D. ground props
	for prop_variant in b.manifest().get("props", []) as Array:
		var prop: Dictionary = prop_variant as Dictionary
		var ppos: Vector3 = prop.get("position", Vector3.ZERO) as Vector3
		acc["props"] += 1
		var gap := ppos.y - world_plan.surface_height_at(Vector2(ppos.x, ppos.z))
		if gap > PROP_FLOAT_MAX:
			acc["floating_props"] += 1
			acc["worst_prop_float"] = maxf(acc["worst_prop_float"], gap)
			if diag and acc["shown_prop"] < 6:
				acc["shown_prop"] += 1
				print("[PragueGroundTest]   %s prop %s y=%.2f float=%+.2fm at (%.1f, %.1f)" % [
					where, str(prop.get("material", "")), ppos.y, gap, ppos.x, ppos.z])


func _is_wall_color(c: Color) -> bool:
	for w: Color in _wall_colors:
		if absf(c.r - w.r) < 0.02 and absf(c.g - w.g) < 0.02 and absf(c.b - w.b) < 0.02:
			return true
	return false


func _is_ground_color(c: Color) -> bool:
	for g: Color in _colors:
		if absf(c.r - g.r) < 0.02 and absf(c.g - g.g) < 0.02 and absf(c.b - g.b) < 0.02:
			return true
	return false


func _check(ok: bool, what: String, bad: int, total: int) -> void:
	if ok:
		return
	failures += 1
	print("[PragueGroundTest] FAIL %s (%d bad of %d)" % [what, bad, total])
