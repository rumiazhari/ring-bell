class_name TreeBuilder
extends RefCounted
## Deterministic procedural trees for Prague-style streets, parks and fringe.
##
## Design constraints (do not relax these):
##   * Everything is batched through MeshBatcher as ORIENTED BOXES, so a whole
##     chunk of trees is still one draw call. No per-tree MeshInstance3D, no new
##     material, no new shader.
##   * Budget: <= ~34 parts (816 verts) for CITY detail, 46 parts (1104 verts)
##     for FEATURE. Parts, not vertices, are the thing to watch.
##   * Shape vocabulary per species: tapered + crooked trunk spine, 3-5 buttress
##     root wedges sitting flush on the ground, 2 branch orders that visibly zig
##     and droop, twigs at the tips, and foliage as many small overlapping
##     clusters (or radial tiers for conifers) so the canopy reads as a canopy
##     instead of a cube with species-specific size and silhouette.
##   * Wind: every part carries sway weight + phase, which MeshBatcher writes to
##     the mesh's second UV channel (ARRAY_TEX_UV2). See WindSystem.
##   * Season: foliage colour comes from TreeSeasons; no geometry changes with
##     season, so a future season system never regenerates a vertex.
##
## Realistic dimensions are researched per species (Czech/Prague planting stock):
## see docs/world/TREES.md.

## Detail tiers. `STREET` is the city street tree: the trunk and limbs of an
## impostor, but with its crown actually filled in. An impostor is cheap because
## it skips the canopy fill, and a crown with its envelope empty is exactly what
## reads as a bare stub at eye level - which is what a street tree must not be.
enum Detail { IMPOSTOR = 0, CITY = 1, FEATURE = 2, STREET = 3 }


## True for the tiers that buy their cheapness by dropping structure (roots,
## crown fill, second-order limbs).
static func _lite(detail: int) -> bool:
	return detail == Detail.IMPOSTOR or detail == Detail.STREET


const VERTS_PER_BOX := 24

## Vertex cost of a tapered prism: one flat-shaded quad per side, plus a centre
## fan cap at each end (the top cap is dropped when the segment comes to a
## point). Kept in lock-step with MeshBatcher._emit_prism — the audit sums this
## and cross-checks it against the meshes the batcher actually produced.
static func prism_verts(sides: int, taper: float) -> int:
	var n: int = maxi(sides, 3)
	return n * 4 + (n + 1) + ((n + 1) if taper >= 0.25 else 0)


static func part_verts(part: Dictionary) -> int:
	var sides: int = int(part.get("sides", 0))
	if sides > 2:
		return prism_verts(sides, float(part.get("taper", 1.0)))
	return VERTS_PER_BOX


## Vertex caps per detail tier for a single tree. A tapered-prism part costs
## 4*sides + (sides + 1) per capped end, so these are dominated by limb count.
const MAX_VERTS := {
	Detail.IMPOSTOR: 520,
	Detail.CITY: 8200,
	Detail.FEATURE: 9200,
	Detail.STREET: 5200,
}

## Part caps per detail tier. Foliage is dropped first when over budget, so the
## caps have to leave room for a dense canopy: the ceiling is set by what the
## streaming budget will carry (see debug/chunk_budget_test.gd), not by taste.
const MAX_PARTS := {
	Detail.IMPOSTOR: 16,
	Detail.CITY: 240,
	Detail.FEATURE: 280,
	Detail.STREET: 160,
}

## Species table. Heights/trunk radii are mature-tree ranges in metres on good
## Prague sites; `crown` is the fraction of total height where the crown starts
## (a pine's bare trunk is why pine is 0.58), `spread` is crown radius as a
## fraction of height, `crook`/`droop` shape the limbs, `leaf` is a foliage
## cluster span in metres.
const SPECIES := {
	&"spruce": {"h_min": 18.0, "h_max": 32.0, "r_min": 0.22, "r_max": 0.42,
		"crown": 0.10, "spread": 0.20, "orders": 1, "crook": 0.10, "droop": 0.02,
		"leaf": 2.2, "evergreen": true, "form": "tier"},
	&"pine": {"h_min": 18.0, "h_max": 28.0, "r_min": 0.20, "r_max": 0.38,
		"crown": 0.58, "spread": 0.34, "orders": 1, "crook": 0.35, "droop": 0.20,
		"leaf": 2.4, "evergreen": true, "form": "umbrella"},
	&"oak": {"h_min": 14.0, "h_max": 24.0, "r_min": 0.30, "r_max": 0.50,
		"crown": 0.33, "spread": 0.44, "orders": 2, "crook": 0.55, "droop": 0.35,
		"leaf": 1.9, "evergreen": false, "form": "wide"},
	&"linden": {"h_min": 14.0, "h_max": 24.0, "r_min": 0.22, "r_max": 0.38,
		"crown": 0.28, "spread": 0.38, "orders": 2, "crook": 0.35, "droop": 0.30,
		"leaf": 1.4, "evergreen": false, "form": "dome"},
	&"beech": {"h_min": 18.0, "h_max": 30.0, "r_min": 0.25, "r_max": 0.45,
		"crown": 0.42, "spread": 0.34, "orders": 2, "crook": 0.35, "droop": 0.25,
		"leaf": 1.5, "evergreen": false, "form": "dome"},
	&"birch": {"h_min": 12.0, "h_max": 20.0, "r_min": 0.12, "r_max": 0.22,
		"crown": 0.38, "spread": 0.26, "orders": 2, "crook": 0.30, "droop": 0.55,
		"leaf": 1.1, "evergreen": false, "form": "airy"},
	&"maple": {"h_min": 14.0, "h_max": 24.0, "r_min": 0.20, "r_max": 0.35,
		"crown": 0.34, "spread": 0.30, "orders": 2, "crook": 0.30, "droop": 0.25,
		"leaf": 1.5, "evergreen": false, "form": "oval"},
	&"locust": {"h_min": 10.0, "h_max": 18.0, "r_min": 0.14, "r_max": 0.26,
		"crown": 0.38, "spread": 0.30, "orders": 2, "crook": 0.55, "droop": 0.40,
		"leaf": 1.3, "evergreen": false, "form": "sparse"},
	&"chestnut": {"h_min": 14.0, "h_max": 24.0, "r_min": 0.28, "r_max": 0.48,
		"crown": 0.28, "spread": 0.40, "orders": 2, "crook": 0.45, "droop": 0.25,
		"leaf": 2.0, "evergreen": false, "form": "coarse"},
	&"ash": {"h_min": 16.0, "h_max": 26.0, "r_min": 0.24, "r_max": 0.40,
		"crown": 0.40, "spread": 0.28, "orders": 2, "crook": 0.30, "droop": 0.30,
		"leaf": 1.4, "evergreen": false, "form": "oval"},
}

## Legacy kind aliases used by the world plans (forest + fringe vocabularies).
const ALIASES := {
	&"tree_beech": &"beech", &"tree_oak": &"oak", &"tree_birch": &"birch",
	&"tree_spruce": &"spruce", &"tree_pine": &"pine", &"broadleaf": &"linden",
	&"conifer": &"spruce",
}


static func species_for_kind(kind: StringName) -> StringName:
	if SPECIES.has(kind):
		return kind
	return ALIASES.get(kind, &"linden") as StringName


## A plausible Prague street/park planting mix (linden is the national tree and
## the commonest street lime; oak, maple, ash horse chestnut and birch sit in
## parks; pine and spruce appear in courtyards and hillside gardens).
const PARK_MIX := [&"linden", &"oak", &"maple", &"ash", &"chestnut", &"beech",
	&"birch", &"pine", &"spruce", &"locust"]


static func mix_species(index: int) -> StringName:
	return PARK_MIX[absi(index) % PARK_MIX.size()] as StringName


static func describe_species() -> Array:
	var out: Array = []
	for s: StringName in SPECIES.keys():
		var sp: Dictionary = SPECIES[s] as Dictionary
		out.append({
			"species": String(s), "h_min": sp["h_min"], "h_max": sp["h_max"],
			"trunk_r_min": sp["r_min"], "trunk_r_max": sp["r_max"],
			"evergreen": sp["evergreen"], "form": sp["form"],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["species"]) < String(b["species"]))
	return out


# ---------------------------------------------------------------- generation

## Build the part list for one tree. Deterministic for a given (species, seed).
## Each part: offset (from the trunk base), size, basis, color, collide, sway.
static func generate(species: StringName, rng: RandomNumberGenerator,
		scale := 1.0, detail := Detail.CITY) -> Array[Dictionary]:
	var sp: StringName = species_for_kind(species)
	var spec: Dictionary = SPECIES[sp] as Dictionary
	var parts: Array[Dictionary] = []
	var bark: Color = TreeSeasons.bark_color(sp)
	var h: float = rng.randf_range(float(spec["h_min"]), float(spec["h_max"])) * scale
	var r0: float = rng.randf_range(float(spec["r_min"]), float(spec["r_max"])) * scale
	var phase: float = rng.randf() * TAU
	var crown_base: float = h * float(spec["crown"])
	var crown_r: float = h * float(spec["spread"])
	var leaf_span: float = float(spec["leaf"]) * scale
	var density: float = TreeSeasons.leaf_density(sp)
	var evergreen: bool = bool(spec["evergreen"])

	# --- trunk spine: leans, then crooks segment by segment as it climbs.
	# The spine runs the whole species height, not just up to the crown base.
	# A pine or a spruce carries its log up through the crown - a trunk that
	# stops at the crown base leaves the upper tree with no log at all - and
	# every limb, bough and whorl is hung off a real spine node, so nothing
	# starts in mid-air beside the trunk.
	var seg_n: int = 4 if _lite(detail) else 6
	var seg_len: float = h / float(seg_n)
	var tip_frac: float = 0.30 if evergreen else 0.24
	var nodes: Array[Vector3] = []
	var pos := Vector3.ZERO
	var dir := Vector3.UP.rotated(_rand_axis(rng), rng.randf_range(0.0, 0.09)).normalized()
	for i in seg_n:
		nodes.append(pos)
		var t: float = float(i) / float(seg_n)
		var r: float = lerpf(r0, r0 * tip_frac, t)
		parts.append(_part(pos + dir * (seg_len * 0.5),
			Vector3(r * 2.0, seg_len * 1.06, r * 2.0), _basis_from_dir(dir),
			bark, i == 0, _sway(pos.y + dir.y * seg_len * 0.5, h, phase),
			false, 6, 0.86))
		pos += dir * seg_len
		dir = _crook(dir, rng, float(spec["crook"]) * (0.35 + t * 0.5))
	nodes.append(pos)

	# --- roots: 3-5 buttress wedges, flush on the ground (sway weight 0.0).
	if not _lite(detail):
		var root_n: int = 3 + int(rng.randf() * 3.0)
		for i in root_n:
			var ang: float = TAU * float(i) / float(root_n) + rng.randf_range(-0.25, 0.25)
			var rd := Vector3(cos(ang), 0.22, sin(ang)).normalized()
			var rl: float = r0 * rng.randf_range(1.6, 2.2)
			parts.append(_part(rd * (rl * 0.42) + Vector3(0, -r0 * 0.12, 0),
				Vector3(r0 * 1.6, rl, r0 * 0.9), _basis_from_dir(rd),
				bark.darkened(0.18), false, Vector2(0.0, phase), false, 6, 0.14))

	# --- crown
	# The crown's horizontal reach. Both the limb recursion and the canopy fill
	# below need it, so it is declared out here rather than inside one branch.
	var crown_reach: float = maxf(h - crown_base, h * 0.30)
	if evergreen:
		_add_conifer(parts, nodes, pos, dir, spec, rng, phase, h, r0, crown_base,
			crown_r, detail, leaf_span, sp)
	else:
		var base_n: int = 3 if _lite(detail) else 3 + int(rng.randf() * 2.0)
		# Limbs must actually climb: the first order covers most of the gap
		# between the crown base and the species height, children finish it.
		# High-droop species (birch) get extra upward bias to pay for the sag.
		var reach: float = crown_reach
		var lift: float = 0.95 + float(spec["droop"]) * 0.6
		for i in base_n:
			var ang2: float = TAU * float(i) / float(base_n) + rng.randf_range(-0.4, 0.4)
			var bd := Vector3(cos(ang2) * rng.randf_range(0.45, 0.95),
				rng.randf_range(lift, lift + 0.40),
				sin(ang2) * rng.randf_range(0.45, 0.95)).normalized()
			var start_y: float = crown_base + (h - crown_base) * rng.randf_range(0.0, 0.20)
			_limb(parts, _spine_at(nodes, start_y), bd,
				reach * rng.randf_range(0.55, 0.68), r0 * 0.62, 0, spec, rng, phase,
				detail, h, density, leaf_span, sp, bark)

	# Canopy fill: the crown envelope gets its own scatter of tufts, sized to
	# bridge the gaps between the limb tips. Density is a coverage problem, not a
	# vertex-count problem: a canopy only reads dense when tufts overlap across the
	# whole crown envelope, so these are numerous and generous rather than small
	# and few. Empty crown envelope is what shows sky through the middle of a tree.
	if detail != Detail.IMPOSTOR:
		# Tuft count follows the crown's area, so a wide chestnut crown gets the same
		# tuft density as a narrow birch one instead of the same number of tufts.
		var fills: int = clampi(16 + int(crown_r * crown_r * 6.0), 30, 60)
		if detail == Detail.STREET:
			# A street tree's crown must read closed at eye level without the
			# thirty tufts a park tree spends. Enough to stop sky showing through
			# the middle of the canopy, few enough that a whole street of them
			# stays inside the chunk's box budget.
			fills = clampi(8 + int(crown_r * crown_r * 2.0), 10, 16)
		for f in fills:
			var fa: float = rng.randf() * TAU
			# sqrt() spreads the tufts evenly over the crown's area, not its radius.
			# The crown's real radius, not the crown's height. Using a height here
			# threw a third of every canopy's tufts far outside the tree: they read
			# as floating clumps and left the actual crown sparse.
			var fr: float = crown_r * 0.95 * sqrt(rng.randf())
			var fy: float = crown_base + (h - crown_base) * rng.randf_range(0.05, 1.0)
			var fp: Vector3 = _spine_at(nodes, fy) + Vector3(cos(fa) * fr, 0.0, sin(fa) * fr)
			# Tuft size scales with the crown, so a wide beech crown gets tufts big
			# enough to close the volume it has to cover. Size costs no extra
			# vertices, so this is density for free where more tufts would not be.
			var fspan: float = maxf(leaf_span * 1.15, crown_r * 0.55) * rng.randf_range(0.85, 1.20)
			var fdir := Vector3(cos(fa), rng.randf_range(0.10, 0.55), sin(fa)).normalized()
			parts.append(_part(fp, Vector3(fspan, fspan * 0.70, fspan * 0.95),
				_basis_from_dir(fdir) * Basis(Vector3.UP, rng.randf() * TAU),
				TreeSeasons.foliage_color(sp, rng.randf_range(0.42, 0.92)), false,
				_sway(fp.y, h, phase), true, 5, 0.30))

	_trim(parts, int(MAX_PARTS[detail]))
	# The crown is grown to a target height; where the limb recursion overshoots
	# or the budget trim shortens the tips, scale the whole tree so the species
	# height is what actually stands in the world.
	var top := 0.0
	for pv in parts:
		var ptop: Dictionary = pv as Dictionary
		top = maxf(top, (ptop["offset"] as Vector3).y + (ptop["size"] as Vector3).y * 0.5)
	if top > 0.001 and absf(top - h) > h * 0.02:
		var fit: float = h / top
		for pv in parts:
			var part: Dictionary = pv as Dictionary
			part["offset"] = (part["offset"] as Vector3) * fit
			part["size"] = (part["size"] as Vector3) * fit
	_normalise_sway(parts)
	return parts


static func _limb(parts: Array[Dictionary], start: Vector3, dir: Vector3, length: float,
		radius: float, order: int, spec: Dictionary, rng: RandomNumberGenerator,
		phase: float, detail: int, h: float, density: float, leaf_span: float,
		sp: StringName, bark: Color) -> void:
	var segs: int = 1 if (_lite(detail) or order >= int(spec["orders"])) else 2
	var seg_len: float = length / float(segs)
	var p := start
	var d := dir
	for s in segs:
		var t: float = float(s) / float(segs)
		var r: float = maxf(radius * (1.0 - 0.45 * t), 0.06)
		parts.append(_part(p + d * (seg_len * 0.5),
			Vector3(r * 2.0, seg_len * 1.08, r * 2.0), _basis_from_dir(d), bark,
			false, _sway(p.y + d.y * seg_len * 0.5, h, phase), false, 4,
			0.20 if order >= int(spec["orders"]) else 0.72))
		p += d * seg_len
		d = _crook(d, rng, float(spec["crook"]) * 1.1)
		# Limbs sag under their own weight: the further out, the more they droop.
		d = (d + Vector3.DOWN * float(spec["droop"]) * 0.35).normalized()
	if order < int(spec["orders"]):
		# The outermost order stays single-branched: the part budget is better
		# spent on foliage than on yet more twig segments.
		var kids: int = 1 if order == int(spec["orders"]) - 1 else (2 if _lite(detail) else 2 + (1 if rng.randf() < 0.45 else 0))
		for k in kids:
			var kd := (d + Vector3(rng.randf_range(-0.6, 0.6),
				rng.randf_range(-0.25, 0.45), rng.randf_range(-0.6, 0.6))).normalized()
			_limb(parts, p, kd, length * 0.62, radius * 0.58, order + 1, spec, rng,
				phase, detail, h, density, leaf_span, sp, bark)
	elif density > 0.0:
		_add_leaves(parts, p, d, rng, phase, h, leaf_span, density, sp, detail)


## Broadleaf foliage: a handful of squashed, twisted tufts around the tip, each
## its own shade and rolled to its own yaw so the canopy silhouette comes from a
## cloud of soft cones rather than one block.
static func _add_leaves(parts: Array[Dictionary], tip: Vector3, dir: Vector3,
		rng: RandomNumberGenerator, phase: float, h: float, leaf_span: float,
		density: float, sp: StringName, detail: int) -> void:
	var clusters: int = 1 if detail == Detail.IMPOSTOR else (3 if detail == Detail.STREET else 6 + (1 if rng.randf() < 0.5 else 0))
	if density < 0.8 and rng.randf() > density + 0.15:
		clusters = 2
	for c in clusters:
		var centre := Vector3(rng.randf_range(-0.26, 0.26), rng.randf_range(-0.22, 0.32),
			rng.randf_range(-0.26, 0.26)) * leaf_span
		var span: float = leaf_span * rng.randf_range(0.95, 1.35)
		var shade: float = clampf(0.5 + dir.y * 0.35 + rng.randf_range(-0.25, 0.25), 0.0, 1.0)
		# One tuft per cluster: the two sub-clumps this used to emit were jittered
		# by less than a fifth of a leaf span, so they read as a single tuft while
		# costing a part each. That budget buys a whole extra tuft instead.
		for q in 1:
			var jitter := Vector3(rng.randf_range(-0.30, 0.30), rng.randf_range(-0.26, 0.34),
				rng.randf_range(-0.30, 0.30)) * leaf_span
			var tilt := Vector3(rng.randf_range(-0.4, 0.4), 1.0,
				rng.randf_range(-0.4, 0.4)).normalized()
			parts.append(_part(tip + centre + jitter,
				Vector3(span * 0.66, span * 0.62 * rng.randf_range(0.6, 0.95),
					span * 0.66 * rng.randf_range(0.85, 1.15)),
				_basis_from_dir(tilt) * Basis(Vector3.UP, rng.randf() * TAU),
				TreeSeasons.foliage_color(sp, shade), false,
				_sway(tip.y + centre.y + jitter.y, h, phase), true, 5, 0.30))


## Basis for a bough: local +Y runs along the branch and local +X is held
## horizontal, so `size.x` is the bough's width across and `size.z` its thickness
## through - a flattened pad stays flat instead of rolling to a random angle.
static func _bough_basis(d: Vector3) -> Basis:
	var y := d.normalized()
	var x := Vector3(y.z, 0.0, -y.x)
	if x.length_squared() < 1e-6:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, y, x.cross(y).normalized())


## Conifers do not have a tip-cluster canopy. A spruce carries drooping boughs
## from low on the trunk (a spire); a Scots pine keeps a bare trunk with a few
## long crooked limbs and a crown confined to the top third (an umbrella).
##
## The boughs are tapered prisms, each at its own angle and length and drooping
## away from the trunk. That structure is the point: horizontal slabs stacked up
## a pole read as a pagoda, which is exactly what this shape avoids.
static func _add_conifer(parts: Array[Dictionary], nodes: Array[Vector3], top: Vector3,
		dir: Vector3, spec: Dictionary, rng: RandomNumberGenerator, phase: float,
		h: float, r0: float, crown_base: float, crown_r: float, detail: int,
		leaf_span: float, sp: StringName) -> void:
	var form: String = String(spec["form"])
	var umbrella := form == "umbrella"
	var bark: Color = TreeSeasons.bark_color(sp)
	# A spruce boughs from low on the trunk (a spire); a pine stays bare far up.
	var lo: float = h * 0.58 if umbrella else maxf(crown_base, h * 0.22)
	var span: float = maxf(h - lo, h * 0.24)
	# Pine: the crown is carried out on a few long crooked limbs that leave the
	# trunk inside the crown, so the log stays visible underneath them.
	if umbrella and detail != Detail.IMPOSTOR:
		for k in 4:
			var la: float = rng.randf() * TAU
			var ld := Vector3(cos(la), 0.55, sin(la)).normalized()
			var ly: float = lo + span * rng.randf_range(0.05, 0.55)
			_limb(parts, _spine_at(nodes, ly), ld,
				span * rng.randf_range(0.45, 0.72), r0 * 0.45, 0, spec, rng, phase,
				detail, h, 0.6, leaf_span, sp, bark)
	# A spruce needs enough tiers to be a continuous cone rather than a stack of
	# plates; the pine's crown is short and wide, so its whorls are fewer.
	var tiers: int = 2 if detail == Detail.IMPOSTOR else (4 if detail == Detail.STREET else (4 if umbrella else 5))
	for i in tiers:
		var t: float = float(i) / float(maxf(float(tiers - 1), 1.0))
		var y: float = lo + span * t
		# Every tier hangs on the real spine, which crooks as it climbs.
		var base: Vector3 = _spine_at(nodes, y)
		# Widest at the top for the umbrella, widest low for the spire.
		var w: float = crown_r * (0.40 + 0.60 * t) if umbrella else crown_r * (0.82 - 0.62 * t)
		# A spruce whorl carries many short branches at the skirt and fewer near the
		# tip; four around a nine-metre skirt left every bough isolated from its
		# neighbours, which is precisely what "floating clumps" was.
		var boughs: int = 3 if detail == Detail.IMPOSTOR else (8 + int(round((1.0 - t) * 2.0)) if detail == Detail.STREET and not umbrella else (4 if detail == Detail.STREET else (4 if umbrella else 8 + int(round((1.0 - t) * 2.0)))))
		var spin: float = rng.randf() * TAU
		var by: float = base.y
		for b in boughs:
			var a: float = spin + TAU * float(b) / float(boughs) + rng.randf_range(-0.28, 0.28)
			# Boughs leave the trunk near-horizontal and sag: hardest at the
			# bottom, hardly at all at the top. That sag is the pine umbrella.
			var droop: float = (rng.randf_range(0.16, 0.42) if umbrella else rng.randf_range(0.30, 0.62)) * (0.35 + 0.65 * (1.0 - t))
			var bd := Vector3(cos(a), -droop, sin(a)).normalized()
			var blen: float = maxf(w * rng.randf_range(0.85, 1.20), 0.35)
			# A bough may hang low, never underground. The drop to clear is the sag
			# plus the pad's own thickness, so the clamp allows for both.
			var sag_max: float = maxf((by + 0.50) / maxf(blen, 0.01) - 0.10, 0.02)
			if droop > sag_max:
				droop = sag_max
				bd = Vector3(cos(a), -droop, sin(a)).normalized()
			# A bough made of one long pad reads as a plate, however it is tapered.
			# Five shorter overlapping clumps along the same line read as needles,
			# keep the same reach, and start at the trunk.
			# Clumps per bough: the pine's boughs are long and carry five; a spruce's
			# are short, but there are many of them per whorl.
			var segs: int = 5 if umbrella else 3
			var seg_len: float = blen / float(segs)
			for q in segs:
				var f0: float = (float(q) + 0.5) / float(segs)
				var pad_len: float = maxf(seg_len * (1.85 - 0.45 * f0), 0.30)
				parts.append(_part(base + bd * (blen * f0),
					Vector3(pad_len * 1.15, pad_len, pad_len * 0.55), _bough_basis(bd),
					TreeSeasons.foliage_color(sp, clampf(0.46 + t * 0.40 + rng.randf_range(-0.10, 0.10), 0.0, 1.0)),
					false, _sway(by, h, phase), true, 5, lerpf(0.85, 0.35, f0)))
			# Inner fill: only the pine needs it, to close the ring of needles on a
			# bough that starts away from a bare trunk. It sits far enough out to
			# leave the log itself visible through the crown. A spruce's whorl
			# already reaches the trunk, so an inner clump there buys nothing.
			if umbrella:
				parts.append(_part(base + bd * (blen * 0.20),
					Vector3(blen * 0.34, blen * 0.30, blen * 0.20), _bough_basis(bd),
					TreeSeasons.foliage_color(sp, clampf(0.40 + t * 0.36, 0.0, 1.0)),
					false, _sway(by, h, phase), true, 5, 0.55))
	# Leader: the spire tapers to a point, a pine's crown closes flat instead.
	var tip_r: float = maxf(r0 * 0.45, 0.05)
	parts.append(_part(_spine_at(nodes, h - span * 0.10),
		Vector3(tip_r * 2.0, span * 0.34, tip_r * 2.0), _basis_from_dir(dir),
		TreeSeasons.foliage_color(sp, 0.82), false, Vector2(1.0, phase), true,
		5, 0.42 if umbrella else 0.05))
	if umbrella:
		# The umbrella itself: flattened pads fanning out over the very top.
		for q in 4:
			var ea: float = TAU * float(q) / 4.0 + rng.randf_range(-0.30, 0.30)
			var ed := Vector3(cos(ea), 0.18, sin(ea)).normalized()
			var elen: float = crown_r * rng.randf_range(0.55, 0.85)
			parts.append(_part(_spine_at(nodes, h - span * 0.16) + ed * (elen * 0.5),
				Vector3(elen * 0.90, elen, elen * 0.20), _bough_basis(ed),
				TreeSeasons.foliage_color(sp, 0.88), false, Vector2(1.0, phase), true,
				5, 0.45))
	# Crown envelope fill: the whorls alone leave sky visible between the tiers,
	# which is what made the conifers read as stacked plates rather than a tree.
	# Each tuft is held off the trunk axis so the log still shows through the
	# crown - that is the whole point of a pine's bare upper trunk.
	if detail != Detail.IMPOSTOR:
		var cfills: int = 28 + int(rng.randf() * 13.0)
		if detail == Detail.STREET:
			cfills = 20 + int(rng.randf() * 9.0)
		var clump: float = crown_r * 0.32
		for f in cfills:
			var fa: float = rng.randf() * TAU
			var ft: float = rng.randf()
			var fy: float = lo + span * ft
			# The fill must live inside the same envelope the boughs use. It used to
			# keep the old wider spire radius, which scattered tufts outside the
			# crown: they read as floating clumps and bought no density.
			var fw: float = (crown_r * (0.40 + 0.60 * ft)) if umbrella else (crown_r * (0.82 - 0.62 * ft))
			# A spire's fill belongs anywhere inside the cone; a pine's has to keep
			# clear of the trunk axis or it would hide the log it is meant to frame.
			var fr: float = maxf(fw * sqrt(rng.randf()), crown_r * 0.34) if umbrella else fw * sqrt(rng.randf())
			var fp: Vector3 = _spine_at(nodes, fy) + Vector3(cos(fa) * fr,
				rng.randf_range(-0.10, 0.35) * clump, sin(fa) * fr)
			var fsz: float = maxf(clump * rng.randf_range(0.85, 1.30), 0.35)
			parts.append(_part(fp, Vector3(fsz, fsz * 0.72, fsz * 0.95),
				_bough_basis(Vector3(cos(fa), rng.randf_range(0.0, 0.35), sin(fa)).normalized()),
				TreeSeasons.foliage_color(sp, clampf(0.30 + ft * 0.60 + rng.randf_range(-0.10, 0.10), 0.0, 1.0)),
				false, _sway(fy, h, phase), true, 5, 0.35))
	# Dead snags: a few bare stubs low on the trunk.
	for tw in 2:
		if _lite(detail):
			break
		var ta: float = rng.randf() * TAU
		var td := Vector3(cos(ta), 0.28, sin(ta)).normalized()
		var snag_y: float = lo + span * rng.randf_range(0.15, 0.5)
		parts.append(_part(_spine_at(nodes, snag_y) + td * (crown_r * 0.45),
			Vector3(r0 * 0.5, crown_r * 0.7, r0 * 0.5),
			_basis_from_dir(td), bark, false, _sway(snag_y, h, phase),
			false, 5, 0.10))


## Drop foliage first (then the outermost twigs) when a tree is over its part
## budget, so the trunk, roots and limb structure always survive.
static func _trim(parts: Array[Dictionary], cap: int) -> void:
	if parts.size() <= cap:
		return
	var i := parts.size() - 1
	while parts.size() > cap and i >= 0:
		if bool((parts[i] as Dictionary).get("foliage", false)):
			parts.remove_at(i)
		i -= 1
	while parts.size() > cap:
		parts.remove_at(parts.size() - 1)


# ---------------------------------------------------------------- emit paths

## Emit one tree into an existing MeshBatcher (one draw call for the whole
## chunk). `pos` is the trunk base; give it the ground height you sampled.
## Returns stats for the audit/tests.
static func build(b: MeshBatcher, pos: Vector3, species: StringName,
		opts: Dictionary = {}) -> Dictionary:
	var rng := _rng(opts)
	var scale: float = float(opts.get("scale", 1.0))
	var detail: int = int(opts.get("detail", Detail.CITY))
	var yaw: float = float(opts.get("yaw", 0.0))
	var collide_trunk: bool = bool(opts.get("collide_trunk", false))
	var sp: StringName = species_for_kind(species)
	var parts: Array[Dictionary] = generate(sp, rng, scale, detail)
	var yb := Basis(Vector3.UP, yaw)
	for part_variant in parts:
		var part: Dictionary = part_variant as Dictionary
		var collide: bool = collide_trunk and bool(part.get("collide", false))
		var sides: int = int(part.get("sides", 0))
		if sides > 2:
			b.add_prism_rotated(pos + yb * (part["offset"] as Vector3),
				part["size"] as Vector3, yb * (part["basis"] as Basis),
				part["color"] as Color, sides, float(part.get("taper", 1.0)),
				collide, StringName(""), part["sway"] as Vector2)
		else:
			b.add_box_rotated(pos + yb * (part["offset"] as Vector3), part["size"] as Vector3,
				yb * (part["basis"] as Basis), part["color"] as Color, collide, false,
				StringName(""), "", -1, part["sway"] as Vector2)
	return _stats(sp, parts, scale, yaw)


## Collider-only prop definition for a tree that is rendered by `build()`.
## The collider is the trunk cylinder's bounding box; `visual: false` tells
## DestructibleProp not to spawn a MeshInstance3D per part, which is what keeps
## a park full of choppable trees affordable.
static func prop_def(pos: Vector3, species: StringName, opts: Dictionary = {}) -> Dictionary:
	var rng := _rng(opts)
	var sp: StringName = species_for_kind(species)
	var spec: Dictionary = SPECIES[sp] as Dictionary
	var scale: float = float(opts.get("scale", 1.0))
	var h: float = rng.randf_range(float(spec["h_min"]), float(spec["h_max"])) * scale
	var r0: float = rng.randf_range(float(spec["r_min"]), float(spec["r_max"])) * scale
	var trunk_h: float = maxf(h * float(spec["crown"]), 2.0)
	return {
		"position": pos,
		"yaw": float(opts.get("yaw", 0.0)),
		"material": &"wood",
		"parts": [{
			"offset": Vector3(0, trunk_h * 0.5, 0),
			"size": Vector3(r0 * 2.0, trunk_h, r0 * 2.0),
			"color": TreeSeasons.bark_color(sp),
			"collide": true,
			"visual": false,
		}],
	}


static func _stats(sp: StringName, parts: Array[Dictionary], scale: float,
		yaw: float) -> Dictionary:
	var top := 0.0
	var verts := 0
	for part_variant in parts:
		var part: Dictionary = part_variant as Dictionary
		var off: Vector3 = part["offset"] as Vector3
		var size: Vector3 = part["size"] as Vector3
		top = maxf(top, off.y + size.y * 0.5)
		verts += part_verts(part)
	return {
		"species": String(sp),
		"parts": parts.size(),
		"verts": verts,
		"height": top,
		"scale": scale,
		"yaw": yaw,
	}


# ---------------------------------------------------------------- helpers

static func _rng(opts: Dictionary) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts.get("seed", 0))
	return rng


## One tree part. Sides > 2 makes it a tapered prism (`taper` is the top diameter
## as a fraction of the base) rather than a box: that is what keeps trunks,
## limbs and boughs from reading as stacked cuboids.
static func _part(offset: Vector3, size: Vector3, basis: Basis, color: Color,
		collide: bool, sway: Vector2, foliage := false, sides := 5,
		taper := 0.7) -> Dictionary:
	return {"offset": offset, "size": size, "basis": basis, "color": color,
		"collide": collide, "sway": sway, "foliage": foliage,
		"sides": sides, "taper": taper}


## Sway weight rises from 0.0 at the base to ~1.0 at the tips; phase is per tree
## so neighbouring trees never move in lockstep. Consumed by WindSystem.
static func _sway(y: float, h: float, phase: float) -> Vector2:
	var w: float = clampf(y / maxf(h, 0.001), 0.0, 1.0)
	return Vector2(pow(w, 1.3), phase)


## Wind sway is stored as 0 at the root rising to 1 at the top of the tree. The
## profile is authored against the species height, so after the geometry exists
## we rescale it: the outermost twigs always carry full weight, whatever the
## actual reach of the crown turned out to be.
static func _normalise_sway(parts: Array[Dictionary]) -> void:
	var peak := 0.0
	for pv in parts:
		peak = maxf(peak, (pv["sway"] as Vector2).x)
	if peak <= 0.001 or peak >= 0.995:
		return
	var k: float = 1.0 / peak
	for pv in parts:
		var part: Dictionary = pv as Dictionary
		var sway: Vector2 = part["sway"] as Vector2
		part["sway"] = Vector2(minf(sway.x * k, 1.0), sway.y)


## Position on the trunk spine at a given height. The spine crooks as it climbs,
## so the crown has to be hung off the real curve: hanging boughs and limbs on a
## straight vertical line is what left branches floating beside the trunk.
static func _spine_at(nodes: Array[Vector3], y: float) -> Vector3:
	if nodes.is_empty():
		return Vector3(0.0, y, 0.0)
	var prev: Vector3 = nodes[0]
	for i in range(1, nodes.size()):
		var cur: Vector3 = nodes[i]
		if y <= cur.y or i == nodes.size() - 1:
			var dy: float = cur.y - prev.y
			var t: float = 0.0 if absf(dy) < 1e-5 else clampf((y - prev.y) / dy, 0.0, 1.0)
			return prev.lerp(cur, t)
		prev = cur
	return nodes[nodes.size() - 1]


## Rotate `dir` by a small random tilt — this is what makes branches crooked
## rather than straight spokes.
static func _crook(dir: Vector3, rng: RandomNumberGenerator, amount: float) -> Vector3:
	var axis := _rand_axis(rng)
	return dir.rotated(axis, rng.randf_range(-amount, amount)).normalized()


static func _rand_axis(rng: RandomNumberGenerator) -> Vector3:
	var a := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
	if a.length_squared() < 0.0001:
		a = Vector3(1.0, 0.0, 0.0)
	return a.normalized()


## Basis whose local +Y axis points along `dir` (boxes are built Y-up).
static func _basis_from_dir(dir: Vector3) -> Basis:
	var d := dir.normalized()
	if d.dot(Vector3.UP) > 0.9999:
		return Basis.IDENTITY
	if d.dot(Vector3.UP) < -0.9999:
		return Basis(Vector3.RIGHT, PI)
	return Basis(Quaternion(Vector3.UP, d))
