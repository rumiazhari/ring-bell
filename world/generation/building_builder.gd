class_name BuildingBuilder
extends RefCounted
## Emits ONE procedural building into a MeshBatcher: exterior shell, storey
## slabs with a stairwell shaft, a usable switchback staircase (walkable ramp
## colliders + decorative treads), roof deck with parapet, pitched roof shell,
## bulkhead roof exit, balconies, windows/shopfronts and chimney.
##
## COLLISION POLICY (auditable via MeshBatcher.add_structural_box):
##   STRUCTURAL: every wall segment incl. door-wall pieces + lintels,
##     ground slab, all storey slabs, stair ramps + landings, guard rails,
##     parapets, bulkhead walls + rooflet, chimneys, flat-roof caps.
##   VISUAL ONLY: windows, signboards, shopfront panels, stair treads,
##     pitched roof shells, dormer dressing.
##
## DOORS: this builder emits the WALL OPENING only (segments + lintel). The
## movable door leaf is a dynamic Door entity spawned by ChunkBuilder from
## spec.doors manifests produced by CityPlan - never baked into static mesh.
##
## STAIRS target 30-35 deg (PITCH_DEG); ramps overlap landings by RAMP_OVERLAP
## so there is no step at flight/landing seams; shaft holes are cut through
## EVERY intermediate slab including collision.
##
## Local frame: origin = spec.rect.position, X east, Rect2.y = Z (south),
## heights in Y. Ground top surface at y = 0.

const WALL_T := 0.35
const SLAB_T := 0.22
const LANE_W := 1.25                 # stair lane width
const LAND := 1.25                   # landing depth at each stairwell end
const STAIR_MARGIN_X := 0.5          # stairwell inset from west wall
const STAIR_MARGIN_Z := 0.5
const PITCH_DEG := 34.0              # within safe CharacterBody floor angle
const RAMP_T := 0.22                 # ramp collider thickness
const RAMP_OVERLAP := 0.2            # flight tucks onto landings (no step)
const DOOR_W := 1.5
const DOOR_H := 2.25
const WIN_W := 1.15
const WIN_H := 1.35
const WIN_SILL := 0.85
const WIN_SPACING := 2.4
const PARAPET_H := 0.9

# Prague-flavored placeholder palettes.
const WALL_COLORS := [
	Color("d8cfc0"), Color("c9a86b"), Color("c4938a"), Color("a9b6bb"),
	Color("a8b39a"), Color("b3aca1"), Color("c7b299"), Color("ded7ca"),
]
const ROOF_COLORS := [
	Color("a34a30"), Color("b5563a"), Color("8f4630"), Color("96502f"),
	Color("6e5550"),
]
const SIGN_COLORS := [
	Color("27556c"), Color("6d2230"), Color("2f4a2f"), Color("2b3350"),
]
const PLINTH_COLOR := Color("8a8074")
const FLOOR_COLOR := Color("6b5843")
const WINDOW_COLOR := Color("232e36")
const DOOR_COLOR := Color("4a3623")
const RAIL_COLOR := Color("3c3833")
const DECK_COLOR := Color("7d7268")

## Stair zone length for a given floor height (CityPlan mirrors this).
static func stair_zone_len(fh: float) -> float:
	return fh / tan(deg_to_rad(PITCH_DEG)) + 2.0 * LAND


## True when the footprint can host the stairwell for `n` floors.
## Minimums guarantee the ENTRANCE door (facade midpoint, ~1.5 m inward
## leaf swing) can never reach the diagonally-opposite stair zone even on
## the smallest eligible lot.
static func has_stairs_for(fp: Vector2, fh: float, n: int) -> bool:
	return n >= 2 and fp.x >= 4.7 \
			and fp.y >= stair_zone_len(fh) + 2.0


## Local-footprint rect of the stairwell zone: anchored in the corner
## DIAGONALLY OPPOSITE the entrance facade, so stairs and the swinging
## door leaf never share floor space on any lot.
static func _zone_rect(fp_size: Vector2, fh: float, door_edge: int) -> Rect2:
	var zx := STAIR_MARGIN_X   # west anchor by default
	var zy := STAIR_MARGIN_Z   # north anchor by default
	if door_edge == 1 or door_edge == 3:
		zx = fp_size.x - STAIR_MARGIN_X - LANE_W * 2.0   # east anchor
	if door_edge == 0 or door_edge == 2:
		zy = fp_size.y - STAIR_MARGIN_Z - stair_zone_len(fh)  # south anchor
	return Rect2(zx, zy, LANE_W * 2.0, stair_zone_len(fh))


## World-space rect of the stairwell zone for a spec (plan-layer usable).
static func stair_zone_world(spec: Dictionary) -> Rect2:
	var fp: Rect2 = spec["rect"]
	var local := _zone_rect(fp.size, float(spec["floor_h"]),
			int(spec.get("door_edge", 0)))
	local.position += fp.position
	return local


static func build(b: MeshBatcher, spec: Dictionary) -> void:
	var fp: Rect2 = spec["rect"]
	var style: Dictionary = spec["style"]
	var wall_c: Color = WALL_COLORS[style["wall"] % WALL_COLORS.size()]
	var roof_c: Color = ROOF_COLORS[style["roof"] % ROOF_COLORS.size()]
	var fh: float = spec["floor_h"]
	var n: int = mini(int(spec["floors"]), 8)
	var total_h := n * fh

	# Interior-reveal LAYER tag for this building: "<id>:f<storey>" and
	# "<id>:roof" let the world hide storeys ABOVE the player's floor.
	var tag := "%s" % str(spec.get("id", "b"))

	var has_stairs := has_stairs_for(fp.size, fh, n)
	var zone := _zone_rect(fp.size, fh, int(spec.get("door_edge", 0)))

	var off := Vector3(fp.position.x, 0.0, fp.position.y)
	var w := fp.size.x
	var d := fp.size.y

	# --- ground slab (STRUCTURAL, top FLUSH with street level y=0) -------------
	# A raised plinth here used to put a 22 cm vertical lip in every doorway -
	# an impassable wall for a CharacterBody3D (no step-up support). The slab
	# now sits fully below grade so entrances are truly walkable.
	b.push_layer(tag + ":f0")
	b.add_structural_box(off + Vector3(w * 0.5, -SLAB_T * 0.5 - 0.02, d * 0.5),
			Vector3(w, SLAB_T, d), FLOOR_COLOR)
	# Thin VISUAL floor finish so interiors still read as floored.
	b.add_visual_box(off + Vector3(w * 0.5, 0.01, d * 0.5),
			Vector3(w - WALL_T, 0.02, d - WALL_T), FLOOR_COLOR.lightened(0.08))
	b.pop_layer()

	# --- storey slabs with stairwell hole (levels 1 .. n) ----------------------
	# Slab at lvl*fh is tagged f<lvl>: it is the CEILING of storey lvl-1, so
	# hiding layers ABOVE the player's floor opens their room to the sky.
	for lvl in range(1, n + 1):
		b.push_layer(tag + ":f%d" % lvl)
		if has_stairs:
			_slab_with_hole(b, off, w, d, zone, lvl * fh)
		else:
			b.add_destructible_box(
					off + Vector3(w * 0.5, lvl * fh - SLAB_T * 0.5, d * 0.5),
					Vector3(w - WALL_T, SLAB_T, d - WALL_T), DECK_COLOR,
					&"concrete")
		b.pop_layer()

	# --- walls + windows + furniture ---------------------------------------------
	var door_edge := int(spec.get("door_edge", 0))
	for f in n:
		b.push_layer(tag + ":f%d" % f)
		var y0 := f * fh
		var col := PLINTH_COLOR if f == 0 else wall_c
		_storey_walls(b, off, w, d, y0, fh, col,
				door_edge if f == 0 else -1)
		for facade in 4:
			_window_row(b, off, w, d, facade, f, fh,
					door_edge == facade and f == 0)
		if f == 0:
			# Shopfront dressing on the street-facing ground wall (visual).
			_shopfront(b, off, w, d, spec)
		_furnish(b, off, w, d, fh, f, tag, zone,
				door_edge if f == 0 else -1)
		b.pop_layer()

	# --- staircase --------------------------------------------------------------
	var guard_on_east := true
	if has_stairs:
		guard_on_east = zone.position.x + zone.size.x \
				< w * 0.5 + 0.01   # open side faces the room center
		_staircase(b, off, zone, fh, n, tag, guard_on_east)

	# --- roof -------------------------------------------------------------------
	b.push_layer(tag + ":roof")
	_roof(b, off, fp, style, roof_c, wall_c, total_h, zone, has_stairs,
			guard_on_east)
	b.pop_layer()


# --- Walls -------------------------------------------------------------------

## All four walls of one storey. Every piece is STRUCTURAL: exterior walls
## must physically stop the player. `door_edge` >= 0 splits that wall around
## the real doorway opening (filled by a dynamic Door entity at runtime).
static func _storey_walls(b: MeshBatcher, off: Vector3, w: float, d: float,
		y0: float, fh: float, col: Color, door_edge: int) -> void:
	var cy := y0 + fh * 0.5
	# Order MUST match the door_edge encoding (0=N, 1=E, 2=S, 3=W).
	# An earlier N/S/W/E ordering made edge==3 replace the EAST wall's slot:
	# the STREET-side wall went up solid behind the door entity, bricking
	# every generated entrance shut.
	var sides := [
		[Vector3(w * 0.5, 0, WALL_T * 0.5), Vector3(w + WALL_T, fh, WALL_T)],   # N
		[Vector3(w - WALL_T * 0.5, 0, d * 0.5), Vector3(WALL_T, fh, d + WALL_T)],# E
		[Vector3(w * 0.5, 0, d - WALL_T * 0.5), Vector3(w + WALL_T, fh, WALL_T)],# S
		[Vector3(WALL_T * 0.5, 0, d * 0.5), Vector3(WALL_T, fh, d + WALL_T)],   # W
	]
	for side in 4:
		if door_edge == side:
			_wall_with_door(b, off, side, w, d, y0, fh, col)
		else:
			var c: Vector3 = sides[side][0]
			b.add_destructible_box(off + Vector3(c.x, cy, c.z),
					sides[side][1], col, &"concrete")


## Wall split around a centered doorway gap + structural lintel above it.
## NO decorative leaf here - Door entities own the leaf.
static func _wall_with_door(b: MeshBatcher, off: Vector3, side: int,
		w: float, d: float, y0: float, fh: float, col: Color) -> void:
	var horizontal := side == 0 or side == 2     # N/S walls run along X
	var length := w if horizontal else d
	var mid := length * 0.5
	var seg_len := (length - DOOR_W) * 0.5
	var lintel_h := fh - DOOR_H

	for s in 2:
		var seg_mid := (seg_len * 0.5) if s == 0 else length - seg_len * 0.5
		var c := _side_point(side, w, d, seg_mid)
		var size := Vector3(seg_len, fh, WALL_T) if horizontal \
				else Vector3(WALL_T, fh, seg_len)
		b.add_destructible_box(
				off + Vector3(c.x, y0 + fh * 0.5, c.y), size, col,
				&"concrete")
	# Structural lintel band above the opening.
	var lc := _side_point(side, w, d, mid)
	var lsize := Vector3(DOOR_W, lintel_h, WALL_T) if horizontal \
			else Vector3(WALL_T, lintel_h, DOOR_W)
	b.add_destructible_box(
			off + Vector3(lc.x, y0 + DOOR_H + lintel_h * 0.5, lc.y),
			lsize, col, &"concrete")


## Point along a facade at distance t from its first corner.
static func _side_point(side: int, w: float, d: float, t: float) -> Vector2:
	match side:
		0: return Vector2(t, WALL_T * 0.5)          # N: along +X at north face
		1: return Vector2(w - WALL_T * 0.5, t)      # E: along +Z at east face
		2: return Vector2(t, d - WALL_T * 0.5)      # S
		_: return Vector2(WALL_T * 0.5, t)          # W


# --- Windows -----------------------------------------------------------------

static func _window_row(b: MeshBatcher, off: Vector3, w: float, d: float,
		facade: int, floor_i: int, fh: float, is_street_ground: bool) -> void:
	var horizontal := facade == 0 or facade == 2
	var length := w if horizontal else d
	var count := int(floor((length - 1.6) / WIN_SPACING))
	if count <= 0:
		return
	var cy := floor_i * fh + WIN_SILL + WIN_H * 0.5
	for i in count:
		var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
		if is_street_ground and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
			continue   # keep the entrance clear; shopfront dresses this wall
		var p := _side_point(facade, w, d, t)
		var size := Vector3(WIN_W, WIN_H, 0.5) if horizontal \
				else Vector3(0.5, WIN_H, WIN_W)
		# Collidable so bullets/zombies can hit the panes; the glass
		# material renders them as tinted translucent panes.
		b.add_destructible_box(off + Vector3(p.x, cy, p.y), size,
				WINDOW_COLOR, &"glass", true)


## Signboard band + tall display panels flanking the door on historic lots.
static func _shopfront(b: MeshBatcher, off: Vector3, w: float, d: float,
		spec: Dictionary) -> void:
	var side := int(spec["door_edge"])
	var style: Dictionary = spec["style"]
	var horizontal := side == 0 or side == 2
	var length := w if horizontal else d
	if length < 7.0 or not style.get("attic", false):
		return
	var sign_c: Color = SIGN_COLORS[(style["wall"] + style["roof"]) % SIGN_COLORS.size()]
	var mid := length * 0.5
	var pc := _side_point(side, w, d, mid)
	var bsize := Vector3(length - 0.9, 0.55, 0.55) if horizontal \
			else Vector3(0.55, 0.55, length - 0.9)
	b.add_visual_box(off + Vector3(pc.x, 2.62, pc.y), bsize, sign_c)
	for i in 2:
		var t := mid + (DOOR_W * 0.5 + 1.15) * (1.0 if i == 0 else -1.0)
		var p := _side_point(side, w, d, t)
		var psize := Vector3(1.7, 2.15, 0.5) if horizontal \
				else Vector3(0.5, 2.15, 1.7)
		b.add_visual_box(off + Vector3(p.x, 1.22, p.y), psize, WINDOW_COLOR)


# --- Slabs -------------------------------------------------------------------

## Floor slab split into three boxes leaving `hole` open (the stair shaft).
## The hole is REAL: collision is cut through every level, so the shaft is
## traversable and nothing invisible ever blocks the stairs.
static func _slab_with_hole(b: MeshBatcher, off: Vector3, w: float, d: float,
		hole: Rect2, y: float) -> void:
	var cy := y - SLAB_T * 0.5
	var pieces := [
		Rect2(hole.end.x, WALL_T, w - WALL_T - hole.end.x, d - 2.0 * WALL_T),
		Rect2(WALL_T, WALL_T, hole.position.x - WALL_T, hole.position.y - WALL_T),
		Rect2(WALL_T, hole.end.y, hole.position.x - WALL_T,
				d - WALL_T - hole.end.y),
	]
	for r: Rect2 in pieces:
		if r.size.x <= 0.05 or r.size.y <= 0.05:
			continue
		b.add_destructible_box(
				off + Vector3(r.get_center().x, cy, r.get_center().y),
				Vector3(r.size.x, SLAB_T, r.size.y), DECK_COLOR,
				&"concrete")


# --- Stairs ------------------------------------------------------------------

## Switchback staircase: structural landings at BOTH shaft ends at every
## level; flights alternate lanes as single rotated ramp colliders whose top
## surface runs EXACTLY from landing surface to landing surface (overlap into
## both landings removes any step). Treads are visual only.
static func _staircase(b: MeshBatcher, off: Vector3, zone: Rect2,
		fh: float, n: int, tag: String, guard_on_east := true) -> void:
	var ang := deg_to_rad(PITCH_DEG)
	var z_n := zone.position.y                  # north end
	var z_s := zone.end.y                       # south end
	var zx := zone.position.x
	var cx_west := zx + LANE_W * 0.5
	var cx_east := zx + LANE_W * 1.5

	# Landings at every level 0..n (structural, top flush with floor level).
	# Tagged f<lvl-1>: a landing is the floor you START from when walking
	# the flight above it, so the whole upward route stays visible from the
	# player's current storey (landing 0 clamps to f0 = the ground floor).
	for lvl in n + 1:
		b.push_layer(tag + ":f%d" % maxi(lvl - 1, 0))
		var ly := lvl * fh - SLAB_T * 0.5
		b.add_destructible_box(off + Vector3(zx + LANE_W, ly, z_n + LAND * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND), DECK_COLOR, &"concrete")
		b.add_destructible_box(off + Vector3(zx + LANE_W, ly, z_s - LAND * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND), DECK_COLOR, &"concrete")
		b.pop_layer()

	var z0 := z_n + LAND - RAMP_OVERLAP
	var z1 := z_s - LAND + RAMP_OVERLAP
	var run := z1 - z0
	var cos_a := cos(ang)

	for k in n:
		var ascending_south := k % 2 == 0
		var lane_c := cx_west if ascending_south else cx_east
		var y0 := k * fh
		# Single walkable ramp collider; top surface spans y0 -> y0+fh across
		# [z0, z1]. Center corrected by half-thickness along the normal.
		# Tagged f<k> (the floor you board it from): the staircase up is
		# ALWAYS visible from the resident level so the player can climb.
		b.push_layer(tag + ":f%d" % k)
		var hyp := sqrt(run * run + fh * fh)
		var basis := Basis(Vector3.RIGHT, -ang if ascending_south else ang)
		var center_y := y0 + fh * 0.5 - (RAMP_T * 0.5) / cos_a
		b.add_box_rotated(
				off + Vector3(lane_c, center_y, (z0 + z1) * 0.5),
				Vector3(LANE_W - 0.04, RAMP_T, hyp), basis, DECK_COLOR, true,
				false, &"concrete")
		# Handrails both sides of the flight: slope-parallel slim bars at
		# ~0.85 m above the ramp surface. SOLID - railings must stop bodies.
		# Each rail stops ~0.5 m short of both flight ends: the landing
		# funnel stays clear (a full-length rail's tip clips bodies that
		# approach the 1.1 m lane gap diagonally from the 2.5 m landing).
		for rail_side in [-1.0, 1.0]:
			b.add_box_rotated(
					off + Vector3(lane_c + rail_side * (LANE_W * 0.5 - 0.04),
							center_y + 0.85 / cos_a, (z0 + z1) * 0.5),
					Vector3(0.07, 0.07, maxf(hyp - 1.0, hyp * 0.7)), basis,
					RAIL_COLOR, true, false, &"steel")
		# Decorative treads (collision comes from the ramps). `t` FOLLOWS the
		# flight's real ascent direction - north-bound flights previously
		# rendered their steps backwards, crossing the ramp visually.
		var steps := maxi(8, int(round(run / 0.28)))
		for i in steps:
			var raw := (float(i) + 0.5) / float(steps)
			var t := raw if ascending_south else 1.0 - raw
			var z := lerpf(z0, z1, t)
			var sy := y0 + raw * fh + 0.03
			b.add_visual_box(off + Vector3(lane_c, sy, z),
					Vector3(LANE_W - 0.06, 0.06, run / float(steps) + 0.02),
					FLOOR_COLOR)
		b.pop_layer()

	# --- fall protection around the shaft --------------------------------------
	# Switchback parity decides which landing halves expose a void:
	#   north landing: both halves connected on EVEN levels (flight L departs
	#     west, flight L-1 arrives east); ISOLATED on odd levels.
	#   south landing: both halves connected on ODD levels; ISOLATED on even
	#     levels (lvl 0 is ground-flush, no fall).
	#   deck (lvl == n): the top flight arrives on exactly ONE half - the
	#     OTHER half is void and gets the rail, the arrival half stays open
	#     or the final flight is unreachable (this boxed-in the descent).
	for lvl in n + 1:
		var ry := lvl * fh + 0.55
		var rail_tag := tag + ":f%d" % maxi(lvl - 1, 0)
		var half_w := LANE_W - 0.06
		var north_void_west := false
		var north_void_east := false
		var south_void_west := false
		var south_void_east := false
		if lvl == n:
			if lvl % 2 == 0:
				# Flight n-1 (odd) arrives north deck EAST half.
				north_void_west = true
				south_void_west = true   # south deck isolated
				south_void_east = true
			else:
				# Flight n-1 (even) arrives south deck WEST half.
				north_void_west = true   # north deck isolated
				north_void_east = true
				south_void_east = true
		elif lvl % 2 == 1 and lvl >= 1:
			north_void_west = true       # north landing isolated
			north_void_east = true
		elif lvl % 2 == 0 and lvl >= 2:
			south_void_west = true       # south landing isolated
			south_void_east = true
		if north_void_west or north_void_east \
				or south_void_west or south_void_east:
			b.push_layer(rail_tag)
			if north_void_west:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 0.5, ry,
								z_n + LAND - 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if north_void_east:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 1.5, ry,
								z_n + LAND - 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if south_void_west:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 0.5, ry,
								z_s - LAND + 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			if south_void_east:
				b.add_destructible_box(
						off + Vector3(zx + LANE_W * 1.5, ry,
								z_s - LAND + 0.045),
						Vector3(half_w, 1.05, 0.09), RAIL_COLOR, &"steel")
			b.pop_layer()
	# Long-edge guard between the landings, every storey. NOT at deck level:
	# the bulkhead walls already enclose the shaft up there, and a rail at
	# that height intersects them (wedging actors in the seam).
	for lvl in n:
		b.push_layer(tag + ":f%d" % lvl)
		var ry2 := lvl * fh + 0.55
		var guard_x := zx + LANE_W * 2.0 + 0.06 if guard_on_east \
				else zx - 0.06
		b.add_destructible_box(off + Vector3(guard_x, ry2,
						(z_n + z_s) * 0.5),
				Vector3(0.09, 1.05, zone.size.y - 2.0 * LAND), RAIL_COLOR,
				&"steel")
		b.pop_layer()


# --- Furniture -----------------------------------------------------------------

const FURN_WOOD := Color("a9743e")        # oak tabletops, chair seats
const FURN_WOOD_DARK := Color("5d452c")   # chair backs, table aprons
const FURN_WALNUT := Color("6b4a2f")      # shelf carcasses
const FURN_DESK := Color("7a5230")        # computer desks
const FURN_METAL := Color("3a3f44")       # monitor stands
const FURN_SCREEN := Color("16202b")      # dark monitor panels
const FURN_KEYBOARD := Color("2e3338")
const FURN_POT := Color("b06238")         # terracotta plant pots
const FURN_LEAF := Color("3f7d32")
const FURN_LEAF_DARK := Color("356b2a")
const FURN_BOOKS := [
	Color("7a3030"), Color("31527a"), Color("3f6b34"),
	Color("8a7a30"), Color("5a3a6b"),
]

## Scatter deterministic furniture through one storey's open floor.
## Everything inherits the CURRENT storey layer (the cutaway hides it with
## the room). Placement keeps clear of the stair zone (+0.7 m), the ground-
## floor entrance swing arc, and previously placed items. Tables/desks/
## shelves collide (walk around them); chairs and plants are soft clutter.
static func _furnish(b: MeshBatcher, off: Vector3, w: float, d: float,
		_fh: float, floor_i: int, tag: String, zone: Rect2,
		door_edge: int) -> void:
	var rng := WorldSeed.rng_for("furnish",
			[WorldSeed.str_hash(tag), floor_i])
	var usable := Rect2(WALL_T + 0.45, WALL_T + 0.45,
			w - 2.0 * (WALL_T + 0.45), d - 2.0 * (WALL_T + 0.45))
	if usable.size.x < 1.4 or usable.size.y < 1.4:
		return
	# Interior point just past the entrance (swing-arc keep-out center).
	var door_pt := Vector2(-99.0, -99.0)
	if door_edge >= 0:
		var mid_len := (w if door_edge == 0 or door_edge == 2 else d) * 0.5
		var dp := _side_point(door_edge, w, d, mid_len)
		match door_edge:
			0: dp += Vector2(0, 1.1)
			1: dp += Vector2(-1.1, 0)
			2: dp += Vector2(0, -1.1)
			_: dp += Vector2(1.1, 0)
		door_pt = dp

	var zone_grown: Rect2 = zone.grow(0.7)
	var placed: Array[Vector2] = []
	var spot_free := func(p: Vector2, radius: float) -> bool:
		if zone_grown.has_point(p):
			return false
		if p.distance_to(door_pt) < 2.3:
			return false
		for q in placed:
			if p.distance_to(q) < radius + 0.9:
				return false
		return true
	var take_spot := func(radius: float) -> Variant:
		for attempt in 40:
			var cand := Vector2(
					rng.randf_range(usable.position.x, usable.end.x),
					rng.randf_range(usable.position.y, usable.end.y))
			if spot_free.call(cand, radius):
				placed.append(cand)
				return cand
		return null

	# Tables with chairs pulled up around them.
	for i in rng.randi_range(1, 3):
		var t: Variant = take_spot.call(1.5)
		if t == null:
			break
		var tp: Vector2 = t
		_f_table(b, off + Vector3(tp.x, 0.0, tp.y))
		for c in rng.randi_range(1, 2):
			var ca := TAU * rng.randf()
			var cp := tp + Vector2(cos(ca), sin(ca)) * 0.95
			if usable.grow(-0.3).has_point(cp) \
					and not zone_grown.has_point(cp):
				_f_chair(b, off + Vector3(cp.x, 0.0, cp.y),
						atan2(tp.x - cp.x, tp.y - cp.y))
	# Bookshelves nudged against the nearest wall.
	for i in rng.randi_range(1, 2):
		var s: Variant = take_spot.call(1.2)
		if s == null:
			break
		var sp: Vector2 = s
		var dists: Array[float] = [sp.x, w - sp.x, sp.y, d - sp.y]
		var wall_dir: Vector2
		match dists.find(minf_array(dists)):
			0: wall_dir = Vector2(1, 0)
			1: wall_dir = Vector2(-1, 0)
			2: wall_dir = Vector2(0, 1)
			_: wall_dir = Vector2(0, -1)
		_f_shelf(b, off + Vector3(sp.x, 0.0, sp.y),
				atan2(wall_dir.x, wall_dir.y), rng)
	# Computer desks.
	for i in rng.randi_range(0, 2):
		var dv: Variant = take_spot.call(1.4)
		if dv == null:
			break
		var dp2: Vector2 = dv
		_f_desk_pc(b, off + Vector3(dp2.x, 0.0, dp2.y),
				rng.randf_range(0.0, TAU))
	# Plant vases tucked into leftovers.
	for i in rng.randi_range(1, 3):
		var pv: Variant = take_spot.call(0.6)
		if pv == null:
			break
		var pp: Vector2 = pv
		_f_plant(b, off + Vector3(pp.x, 0.0, pp.y))


static func minf_array(arr: Array[float]) -> float:
	var best := arr[0]
	for v in arr:
		best = minf(best, v)
	return best


## Dining/work table: oak top on a dark apron base. Collides (walk around).
static func _f_table(b: MeshBatcher, pos: Vector3) -> void:
	b.add_destructible_box(pos + Vector3(0, 0.37, 0),
			Vector3(1.15, 0.74, 0.78), FURN_WOOD_DARK, &"wood")
	b.add_visual_box(pos + Vector3(0, 0.755, 0),
			Vector3(1.25, 0.07, 0.88), FURN_WOOD)


static func _f_chair(b: MeshBatcher, pos: Vector3, yaw: float) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.23, 0),
			Vector3(0.44, 0.06, 0.42), basis, FURN_WOOD, false)
	b.add_box_rotated(pos - basis.z * 0.19 + Vector3(0, 0.51, 0),
			Vector3(0.44, 0.52, 0.05), basis, FURN_WOOD_DARK, false)


## Bookcase: walnut carcass (collides) with colored book rows on shelves.
static func _f_shelf(b: MeshBatcher, pos: Vector3, yaw: float,
		rng: RandomNumberGenerator) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 1.0, 0),
			Vector3(1.6, 2.0, 0.34), basis, FURN_WALNUT, true,
			false, &"wood")
	for shelf_y in [0.55, 1.05, 1.55]:
		b.add_box_rotated(pos + Vector3(0, shelf_y, 0.02),
				Vector3(1.5, 0.04, 0.28), basis, FURN_WOOD, false)
		var cursor := -0.62
		while cursor < 0.58:
			var bw := rng.randf_range(0.07, 0.15)
			cursor += bw + 0.03
			if cursor > 0.62:
				break
			var bc: Color = FURN_BOOKS[rng.randi_range(
					0, FURN_BOOKS.size() - 1)]
			b.add_box_rotated(pos + basis.x * cursor + Vector3(0,
					shelf_y + 0.14, 0.02),
					Vector3(bw, 0.26, 0.22), basis, bc, false)


## Desk with keyboard, monitor stand and dark screen. Desk collides.
static func _f_desk_pc(b: MeshBatcher, pos: Vector3, yaw: float) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_destructible_box(pos + Vector3(0, 0.36, 0),
			Vector3(1.35, 0.72, 0.68), FURN_DESK, &"wood")
	b.add_box_rotated(pos + basis.z * 0.18 + Vector3(0, 0.79, 0),
			Vector3(0.42, 0.05, 0.16), basis, FURN_KEYBOARD, false)
	b.add_box_rotated(pos - basis.z * 0.16 + Vector3(0, 0.82, 0),
			Vector3(0.10, 0.16, 0.10), basis, FURN_METAL, false)
	b.add_box_rotated(pos - basis.z * 0.20 + Vector3(0, 1.06, 0),
			Vector3(0.58, 0.36, 0.04), basis, FURN_SCREEN, false)


## Terracotta pot with two-tone green foliage. Soft clutter (no collision).
static func _f_plant(b: MeshBatcher, pos: Vector3) -> void:
	b.add_visual_box(pos + Vector3(0, 0.17, 0),
			Vector3(0.30, 0.34, 0.30), FURN_POT)
	b.add_visual_box(pos + Vector3(0, 0.52, 0),
			Vector3(0.46, 0.30, 0.46), FURN_LEAF)
	b.add_visual_box(pos + Vector3(0, 0.76, 0),
			Vector3(0.30, 0.24, 0.30), FURN_LEAF_DARK)


# --- Roof --------------------------------------------------------------------

static func _roof(b: MeshBatcher, off: Vector3, fp: Rect2, style: Dictionary,
		roof_c: Color, wall_c: Color, total_h: float, zone: Rect2,
		has_stairs: bool, guard_on_east := true) -> void:
	var w := fp.size.x
	var d := fp.size.y
	# Parapet ring on top of the perimeter walls (standable edge, blocking).
	var ring := [
		[Vector3(w * 0.5, total_h + PARAPET_H * 0.5, WALL_T * 0.5),
				Vector3(w + 0.3, PARAPET_H, 0.28)],
		[Vector3(w * 0.5, total_h + PARAPET_H * 0.5, d - WALL_T * 0.5),
				Vector3(w + 0.3, PARAPET_H, 0.28)],
		[Vector3(WALL_T * 0.5, total_h + PARAPET_H * 0.5, d * 0.5),
				Vector3(0.28, PARAPET_H, d + 0.3)],
		[Vector3(w - WALL_T * 0.5, total_h + PARAPET_H * 0.5, d * 0.5),
				Vector3(0.28, PARAPET_H, d + 0.3)],
	]
	for r: Array in ring:
		b.add_destructible_box(off + r[0], r[1], wall_c.darkened(0.25),
				&"concrete")

	# Bulkhead around the stair shaft exit (roof access hut).
	if has_stairs:
		var bz := zone.grow(0.14)
		# Opening must clear the 1.7 m player capsule AND sit over the top
		# LANDING, not over the open shaft. The doorway faces the OPEN ROOM
		# side of the shaft (east or west - it follows the zone anchor), so
		# exiting always steps onto real deck, never off the building.
		var bh_h := 2.4
		var opening_h := 1.95
		var wy := total_h + bh_h * 0.5
		var gap_wall_x := bz.end.x if guard_on_east else bz.position.x
		var side_walls := [
			[Vector3(bz.get_center().x, wy, bz.position.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.get_center().x, wy, bz.end.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.position.x if guard_on_east else bz.end.x,
					wy, bz.get_center().y),
					Vector3(0.22, bh_h, bz.size.y)],
		]
		for wl: Array in side_walls:
			b.add_destructible_box(off + wl[0], wl[1], wall_c.darkened(0.15),
					&"concrete")
		# Doorway wall with gap + header, centered on the north landing.
		var gz := bz.position.y + 0.14 + LAND * 0.5   # landing center z
		var gap := 1.0
		var seg_lo := clampf(gz - gap * 0.5 - bz.position.y, 0.0, bz.size.y)
		var seg_hi := clampf(bz.end.y - (gz + gap * 0.5), 0.0, bz.size.y)
		if seg_lo > 0.05:
			b.add_destructible_box(
					off + Vector3(gap_wall_x, wy, bz.position.y + seg_lo * 0.5),
					Vector3(0.22, bh_h, seg_lo), wall_c.darkened(0.15),
					&"concrete")
		if seg_hi > 0.05:
			b.add_destructible_box(
					off + Vector3(gap_wall_x, wy, bz.end.y - seg_hi * 0.5),
					Vector3(0.22, bh_h, seg_hi), wall_c.darkened(0.15),
					&"concrete")
		b.add_destructible_box(
				off + Vector3(gap_wall_x, total_h + opening_h + 0.225, gz),
				Vector3(0.22, bh_h - opening_h, gap), wall_c.darkened(0.15),
				&"concrete")
		b.add_destructible_box(
				off + Vector3(bz.get_center().x, total_h + bh_h + 0.09,
						bz.get_center().y),
				Vector3(bz.size.x + 0.3, 0.18, bz.size.y + 0.3), ROOF_COLORS[0],
				&"wood")

	if style.get("attic", false):
		_pitched_shell(b, off, w, d, total_h, roof_c, style)
	else:
		# Flat roof variant: VISUAL membrane only. The walkable deck is the
		# top storey slab (already structural, with the shaft hole); a solid
		# cap here used to seal the stairwell shut below a 12 cm ceiling.
		if has_stairs:
			_membrane_with_hole(b, off, w, d, zone, total_h + 0.02, roof_c)
		else:
			b.add_roof_visual_box(off + Vector3(w * 0.5, total_h + 0.02, d * 0.5),
					Vector3(w - WALL_T, 0.04, d - WALL_T), roof_c)


## Flat-roof dressing: thin VISUAL membrane around the shaft hole (no
## collision - the structural top slab below is the real deck). Lives on the
## RoofLayer so interiors can be revealed while the player is inside.
static func _membrane_with_hole(b: MeshBatcher, off: Vector3, w: float,
		d: float, hole: Rect2, y: float, color: Color) -> void:
	var pieces := [
		Rect2(hole.end.x, WALL_T, w - WALL_T - hole.end.x, d - 2.0 * WALL_T),
		Rect2(WALL_T, WALL_T, hole.position.x - WALL_T, hole.position.y - WALL_T),
		Rect2(WALL_T, hole.end.y, hole.position.x - WALL_T,
				d - WALL_T - hole.end.y),
	]
	for r: Rect2 in pieces:
		if r.size.x <= 0.05 or r.size.y <= 0.05:
			continue
		b.add_roof_visual_box(
				off + Vector3(r.get_center().x, y, r.get_center().y),
				Vector3(r.size.x, 0.04, r.size.y), color)


static func _pitched_shell(b: MeshBatcher, off: Vector3, w: float, d: float,
		total_h: float, roof_c: Color, style: Dictionary) -> void:
	var eave := 0.28
	var half_run := d * 0.5 + eave
	var rise := minf(2.4, d * 0.42)
	var ang := atan2(rise, half_run)
	var slope_len := sqrt(half_run * half_run + rise * rise)
	var cy := total_h + rise * 0.5
	# Roof shells are VISUAL RoofLayer geometry: players walk the structural
	# deck beneath them, and the whole shell hides away indoors.
	b.add_roof_visual_box(
			off + Vector3(w * 0.5, cy, d * 0.25 - eave * 0.5 + 0.0),
			Vector3(w + 0.55, 0.18, slope_len), roof_c)
	b.add_roof_visual_box(
			off + Vector3(w * 0.5, cy, d * 0.75 + eave * 0.5),
			Vector3(w + 0.55, 0.18, slope_len), roof_c)

	# Dormer(s) punching through the south slope.
	if style.get("balcony", false):
		return   # stylistic variety: some roofs stay plain
	var dz := d * 0.78
	var dx := w * 0.32
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45, dz),
			Vector3(1.1, 1.1, 1.0), PLINTH_COLOR)
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45 + 0.61, dz + 0.1),
			Vector3(1.3, 0.12, 1.2), roof_c)
	b.add_roof_visual_box(off + Vector3(dx, total_h + rise * 0.45, dz + 0.48),
			Vector3(0.7, 0.8, 0.12), WINDOW_COLOR)
	# Chimney on the ridge (seeded by style for stable placement).
	var rng_pos := WorldSeed.rng_for("chimney",
			[int(style["wall"]), int(style["roof"]), int(round(d * 10))])
	var ch_x := lerpf(w * 0.25, w * 0.75, rng_pos.randf())
	b.add_roof_visual_box(off + Vector3(ch_x, total_h + rise * 0.55 + 0.75,
					d * 0.5),
			Vector3(0.65, 1.5, 0.65), PLINTH_COLOR.darkened(0.2))
