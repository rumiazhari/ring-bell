class_name SiteContractValidator
extends RefCounted
## Universal Site Envelope Contract validator (G10-P2C).
##
## Same job as BuildingContractValidator, one layer out: it proves a plot's
## OUTDOOR envelope is real rather than decorative. A site that fails here may
## not be materialized, exactly as a bypassing building may not.
##
## Two entry points:
##   validate_spec(spec, surface_fn)  — the declaration is well formed,
##       grounded, and internally coherent (no fence through a wall, no tree
##       standing in the kitchen, a gate for every doorway the fence encloses).
##   validate_build(spec, evidence)   — what a site builder actually emitted
##       matches the declaration: every post/rail/gate/tree accounted for, a
##       styled fence carries real collision, an open yard carries no ghost
##       posts. Evidence keys are documented on the function.
##
## Every rule below is derived from footprint geometry wherever possible, so
## the polygon form of a plot needs no Rect2 fallback to pass.

# ---------------------------------------------------------------- spec rules

static func validate_spec(spec: Dictionary, surface_fn: Callable = Callable()) -> Array[String]:
	var errs: Array[String] = []
	var s := SiteSpec.normalize(spec)

	if s["id"] == "":
		errs.append("missing id")
	var quality: StringName = s["quality"]
	if not SiteSpec.QUALITIES.has(quality):
		errs.append("invalid quality: %s" % String(quality))
	if quality == &"DISTANT_LOD" and str(s.get("lod_of", "")) == "":
		errs.append("DISTANT_LOD requires lod_of")
	if quality == &"DECOR_ONLY" and str(s.get("decor_of", "")) == "":
		errs.append("DECOR_ONLY requires decor_of")
	if not SiteSpec.KINDS.has(StringName(s["kind"])):
		errs.append("unknown yard kind: %s" % String(s["kind"]))
	if s["building_id"] == "":
		errs.append("missing building_id (a yard belongs to a plot with a building)")

	var idx := _index_errors(s, surface_fn)
	errs.append_array(idx)
	errs.append_array(_fence_errors(s, surface_fn))
	errs.append_array(_tree_errors(s, surface_fn))
	return errs


## Plot/yard coherence: area, usable outdoor share, classification sanity.
static func _index_errors(s: Dictionary, surface_fn: Callable) -> Array[String]:
	var errs: Array[String] = []
	var plot := SiteSpec._as_polygon(s["plot"])
	var area := SiteSpec.yard_area(s)
	if plot.size() < 3:
		errs.append("plot needs at least 3 points")
	if area < WorldConstants.SITE_MIN_PLOT_AREA_M2:
		errs.append("plot too small: %.1f m2" % area)

	# Usable outdoor share: the yard is the ground that is neither building nor
	# void. A plot whose building eats it is not a site, it is a wall.
	var brect := SiteSpec._as_rect(s["building_rect"])
	var built := brect.get_area()
	var share := 1.0 if built <= 0.0 else area / (area + built)
	if built > 0.0 and share < WorldConstants.SITE_MIN_YARD_FRACTION:
		errs.append("yard too small for the plot: %.0f%% outdoors" % (share * 100.0))

	var style := SiteSpec.fence_style(s)
	if style != &"none" and area < WorldConstants.SITE_MIN_YARD_AREA_M2:
		errs.append("fenced yard below %.0f m2: %.1f m2"
			% [WorldConstants.SITE_MIN_YARD_AREA_M2, area])

	if s["quality"] == &"DECOR_ONLY" and SiteSpec.trees_of(s).size() > 0:
		errs.append("DECOR_ONLY yard may not plant trees")

	# Grounding: the yard surface itself must sit on the terrain.
	if surface_fn.is_valid() and s.has("ground_y"):
		var c := _polygon_center(plot)
		var surf: float = surface_fn.call(c)
		if absf(float(s["ground_y"]) - surf) > WorldConstants.SITE_GROUND_TOL_M:
			errs.append("yard not grounded at %s: %.2f m off surface" % [c, float(s["ground_y"]) - surf])
	return errs


## Fence rules: a fence is a closed, grounded, gated loop that never passes
## through the building it protects.
static func _fence_errors(s: Dictionary, surface_fn: Callable) -> Array[String]:
	var errs: Array[String] = []
	var fence := SiteSpec.fence_of(s)
	var style := StringName(fence.get("style", &"none"))
	if not SiteSpec.FENCE_STYLES.has(style):
		errs.append("unknown fence style: %s" % String(style))
	if style == &"none":
		return errs

	var loop := SiteSpec.fence_loop(s)
	if loop.size() < 3:
		errs.append("fence needs a closed loop (>=3 distinct points)")
	elif not _loop_is_ring(loop):
		errs.append("fence loop does not enclose ground")
	elif _has_duplicate_points(loop):
		errs.append("fence loop repeats a point")
	var h := float(fence.get("height", 0.0))
	if h < WorldConstants.SITE_MIN_FENCE_H or h > WorldConstants.SITE_MAX_FENCE_H:
		errs.append("fence height out of scale: %.2f m" % h)
	var sp := float(fence.get("post_spacing", 0.0))
	if sp < WorldConstants.SITE_MIN_POST_SPACING or sp > WorldConstants.SITE_MAX_POST_SPACING:
		errs.append("post spacing out of scale: %.2f m" % sp)

	# The fence may not pass THROUGH the building. A fence line legitimately
	# runs along a party wall, so the footprint is shrunk by an epsilon first:
	# grazing is allowed, crossing is not.
	var brect := SiteSpec._as_rect(s["building_rect"])
	if brect.get_area() > 0.0:
		var solid := brect.grow(-0.05)
		if solid.get_area() > 0.0:
			for i in range(loop.size()):
				var a := loop[i]
				var b := loop[(i + 1) % loop.size()]
				if _segment_hits_rect(a, b, solid):
					errs.append("fence crosses the building at %s" % a)
					break

	var gates := SiteSpec.gates_of(s)
	if gates.is_empty():
		errs.append("fence needs at least one gate")
	for g: Variant in gates:
		var gw := float((g as Dictionary).get("width", 0.0))
		if gw < WorldConstants.SITE_MIN_GATE_W or gw > WorldConstants.SITE_MAX_GATE_W:
			errs.append("gate width out of scale: %.2f m" % gw)
		var gc := SiteSpec._as_vec2((g as Dictionary).get("center", Vector2.ZERO))
		if not _point_on_loop(gc, loop):
			errs.append("gate is not on the fence loop at %s" % gc)

	# Every doorway the fence encloses needs a gate within reach; a doorway
	# outside the loop is served by the street, not by this fence.
	for e: Variant in SiteSpec.entrances_of(s):
		var en: Dictionary = e
		var p := SiteSpec._as_vec2(en.get("pos", Vector2.ZERO))
		if not _point_inside_loop(p, loop):
			continue
		var best := INF
		for g: Variant in gates:
			best = minf(best, p.distance_to(SiteSpec._as_vec2((g as Dictionary).get("center", Vector2.ZERO))))
		if best > WorldConstants.SITE_GATE_ALIGN_M:
			errs.append("no gate for enclosed entrance %s (%.2f m away)"
				% [str(en.get("id", "?")), best])

	# A fence follows the ground it stands on.
	if surface_fn.is_valid():
		for i in range(loop.size()):
			var surf: float = surface_fn.call(loop[i])
			var g := float(s.get("ground_y", surf))
			if absf(g - surf) > WorldConstants.SITE_GROUND_TOL_M:
				errs.append("fence not grounded at %s: %.2f m off surface" % [loop[i], g - surf])
				break
	return errs


## Tree rules: rooted, inside the plot, out of the building, spaced apart.
static func _tree_errors(s: Dictionary, surface_fn: Callable) -> Array[String]:
	var errs: Array[String] = []
	var trees := SiteSpec.trees_of(s)
	if trees.size() > WorldConstants.SITE_MAX_TREES_PER_SITE:
		errs.append("too many trees in one yard: %d" % trees.size())
	var plot := SiteSpec._as_polygon(s["plot"])
	var brect := SiteSpec._as_rect(s["building_rect"])
	for i in range(trees.size()):
		var t: Dictionary = trees[i]
		var id := str(t.get("id", "#%d" % i))
		var sp := StringName(t.get("species", &""))
		if not TreeBuilder.SPECIES.has(sp):
			errs.append("tree %s unknown species: %s" % [id, String(sp)])
			continue
		var p := SiteSpec._as_vec2(t.get("pos", Vector2.ZERO))
		if plot.size() >= 3 and not Geometry2D.is_point_in_polygon(p, plot):
			errs.append("tree %s outside the plot" % id)
		if brect.get_area() > 0.0:
			var d := _dist_point_rect(p, brect)
			if d <= 0.0:
				errs.append("tree %s stands inside the building" % id)
			elif d < WorldConstants.SITE_TREE_BUILDING_CLEAR_M:
				errs.append("tree %s too close to the building: %.2f m" % [id, d])
		for j in range(i + 1, trees.size()):
			var o: Dictionary = trees[j]
			var op := SiteSpec._as_vec2(o.get("pos", Vector2.ZERO))
			var need: float = float(t.get("radius", 0.5)) + float(o.get("radius", 0.5))
			var gap := p.distance_to(op) - need
			if gap < WorldConstants.SITE_TREE_TREE_CLEAR_M - need:
				errs.append("tree %s and %s too close: %.2f m gap" % [id, str(o.get("id", "?")), gap])
		if surface_fn.is_valid():
			var surf: float = surface_fn.call(p)
			var g := float(t.get("ground_y", surf)) if t.has("ground_y") else surf
			if absf(g - surf) > WorldConstants.SITE_GROUND_TOL_M:
				errs.append("tree %s not rooted: %.2f m off surface" % [id, g - surf])
	return errs


# --------------------------------------------------------------- build rules

## Validate what a site builder emitted for a spec.
## Evidence keys (all mandatory):
##   fence_posts:int, fence_segments:int, gate_leaves:int, fence_colliders:int,
##   tree_trunks:int, ground_y:float
static func validate_build(spec: Dictionary, evidence: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var s := SiteSpec.normalize(spec)
	for key: String in ["fence_posts", "fence_segments", "gate_leaves", "fence_colliders", "tree_trunks"]:
		if not evidence.has(key):
			errs.append("missing evidence: %s" % key)
	if not errs.is_empty():
		return errs

	var style := SiteSpec.fence_style(s)
	var loop := SiteSpec.fence_loop(s)
	var gates := SiteSpec.gates_of(s)
	var trees := SiteSpec.trees_of(s)
	var posts := int(evidence["fence_posts"])
	var segments := int(evidence["fence_segments"])
	var leaves := int(evidence["gate_leaves"])
	var colliders := int(evidence["fence_colliders"])
	var trunks := int(evidence["tree_trunks"])

	if style == &"none":
		# An open yard must stay open: no phantom posts or invisible walls.
		if posts > 0 or segments > 0 or colliders > 0:
			errs.append("invisible fence emitted for an open yard")
	elif loop.size() < 3:
		errs.append("styled fence without a usable loop")
	else:
		var perim := SiteSpec.fence_perimeter(loop)
		var spacing := float(SiteSpec.fence_of(s).get("post_spacing", 2.4))
		var need_posts := int(floor(perim / maxf(spacing, 0.01))) + 1
		if posts < need_posts:
			errs.append("fence posts missing: %d of %d for %.1f m perimeter"
				% [posts, need_posts, perim])
		if segments < need_posts - 1:
			errs.append("fence rails missing: %d for %d posts" % [segments, need_posts])
		if colliders < 1:
			errs.append("fence has no collision")
		if leaves != gates.size():
			errs.append("gate leaves %d for %d gates" % [leaves, gates.size()])

	if trunks != trees.size():
		errs.append("tree trunks %d for %d declared trees" % [trunks, trees.size()])

	if evidence.has("ground_y") and s.has("ground_y"):
		var drift := absf(float(evidence["ground_y"]) - float(s["ground_y"]))
		if drift > WorldConstants.SITE_GROUND_TOL_M:
			errs.append("site grounding drift: %.2f m" % drift)
	return errs


# ------------------------------------------------------------------- helpers

static func _loop_is_ring(loop: PackedVector2Array) -> bool:
	if loop.size() < 3:
		return false
	# A ring encloses ground. A polyline the planner forgot to wrap would
	# collapse to (near) zero area, which is the failure worth catching.
	return absf(BuildingSpec.polygon_area(loop)) >= 1.0


static func _has_duplicate_points(loop: PackedVector2Array) -> bool:
	for i in range(loop.size()):
		if loop[i].distance_to(loop[(i + 1) % loop.size()]) <= 0.01:
			return true
	return false


## A gate opening is cut INTO the fence: its centre must lie on the loop, or
## the fence has a hole somewhere else and a gate standing in the open.
static func _point_on_loop(p: Vector2, loop: PackedVector2Array) -> bool:
	if loop.size() < 2:
		return false
	for i in range(loop.size()):
		var a := loop[i]
		var b := loop[(i + 1) % loop.size()]
		var near := Geometry2D.get_closest_point_to_segment(p, a, b)
		if near.distance_to(p) <= 0.6:
			return true
	return false


static func _polygon_center(pts: PackedVector2Array) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in pts:
		sum += p
	return sum / float(pts.size())


static func _point_inside_loop(p: Vector2, loop: PackedVector2Array) -> bool:
	return loop.size() >= 3 and Geometry2D.is_point_in_polygon(p, loop)


## Distance from a point to a rect: 0 when inside, otherwise the gap (m).
static func _dist_point_rect(p: Vector2, r: Rect2) -> float:
	if r.has_point(p):
		return 0.0
	var dx := maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dy := maxf(maxf(r.position.y - p.y, 0.0), p.y - r.end.y)
	return Vector2(dx, dy).length()


## Does segment a-b touch the rect at all (crossing or ending inside)?
static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.has_point(a) or r.has_point(b):
		return true
	var c0 := r.position
	var c1 := Vector2(r.end.x, r.position.y)
	var c2 := r.end
	var c3 := Vector2(r.position.x, r.end.y)
	for seg: Array in [[c0, c1], [c1, c2], [c2, c3], [c3, c0]]:
		if Geometry2D.segment_intersects_segment(a, b, seg[0], seg[1]) != null:
			return true
	return false
