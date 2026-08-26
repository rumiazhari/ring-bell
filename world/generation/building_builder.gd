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
const RAIL_SETBACK := 0.6            # rail stops this far short of each flight end
const DOOR_W := 1.5
const DOOR_H := 2.25
const DOOR_FRAME := 0.06               # jamb clearance: aperture = DOOR_W + this
const WIN_W := 1.15
const WIN_H := 1.35
const WIN_SILL := 0.85
const WIN_SPACING := 2.4
const GLASS_T := 0.2                   # pane thickness inside the WALL_T aperture
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


## Local-footprint rect of the stairwell zone: EXPLICIT per-edge mapping
## (P0-6). The zone anchors to the side OPPOSITE the entrance facade so
## stairs and the swinging door leaf never share floor space on any lot:
##   N entrance (0) -> SOUTH stair zone     S entrance (2) -> NORTH stair zone
##   E entrance (1) -> WEST stair zone      W entrance (3) -> EAST stair zone
## Every edge is spelled out - no broad condition may collapse two opposite
## edges onto the same anchor again.
static func _zone_rect(fp_size: Vector2, fh: float, door_edge: int) -> Rect2:
	var zx := STAIR_MARGIN_X
	var zy := STAIR_MARGIN_Z
	match door_edge:
		0:   # N entrance -> zone against the SOUTH wall
			zy = fp_size.y - STAIR_MARGIN_Z - stair_zone_len(fh)
		1:   # E entrance -> zone against the WEST wall
			zx = STAIR_MARGIN_X
		2:   # S entrance -> zone against the NORTH wall
			zy = STAIR_MARGIN_Z
		_:   # W entrance (3) -> zone against the EAST wall
			zx = fp_size.x - STAIR_MARGIN_X - LANE_W * 2.0
	return Rect2(zx, zy, LANE_W * 2.0, stair_zone_len(fh))


## World-space rect of the stairwell zone for a spec (plan-layer usable).
static func stair_zone_world(spec: Dictionary) -> Rect2:
	var fp: Rect2 = spec["rect"]
	var local := _zone_rect(fp.size, float(spec["floor_h"]),
			int(spec.get("door_edge", 0)))
	local.position += fp.position
	return local


## Horizontal run of one flight: the shaft length minus both landing depths.
static func flight_run(fh: float) -> float:
	return stair_zone_len(fh) - 2.0 * LAND


## The ACTUAL ramp inclination for a floor height - derived from the fixed
## run, never assumed. PITCH_DEG is only the design target that sizes the
## shaft; the real slope is atan2(fh, flight_run).
static func flight_angle(fh: float) -> float:
	return atan2(fh, flight_run(fh))


## Height of the ramp's walkable TOP surface at shaft-local z (world z
## relative like zone.position.y). Linear between the flush endpoints.
static func ramp_height_at(z: float, base_y: float, fh: float,
		zone_y: float) -> float:
	var t := clampf((z - (zone_y + LAND)) / maxf(flight_run(fh), 0.001),
			0.0, 1.0)
	return base_y + t * fh


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
			_emit_slab_panels(b, off, Rect2(WALL_T, WALL_T,
					maxf(w - 2.0 * WALL_T, 0.0),
					maxf(d - 2.0 * WALL_T, 0.0)),
					lvl * fh - SLAB_T * 0.5)
		b.pop_layer()

	# --- walls + windows + furniture ---------------------------------------------
	# One aperture-composing facade generator handles doors AND windows.
	var door_edge := int(spec.get("door_edge", 0))
	for f in n:
		b.push_layer(tag + ":f%d" % f)
		var y0 := f * fh
		var col := PLINTH_COLOR if f == 0 else wall_c
		_storey_walls(b, off, w, d, y0, fh, col, f,
			door_edge if f == 0 else -1, tag)
		if f == 0:
			# Shopfront dressing on the street-facing ground wall (visual) - retail only.
			if str(style.get("room_type", "residential")) == "retail":
				_shopfront(b, off, w, d, spec)
		_furnish(b, off, w, d, fh, f, tag, zone,
				door_edge if f == 0 else -1,
				str(style.get("room_type", "residential")))
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

## All four walls of one storey as REAL APERTURE COMPOSITION (P0-E):
## every opening - the entrance door and each window - is carved by the
## SAME generator. Piers stand between openings, a sill band closes each
## window below, a structural lintel closes each opening above, and window
## panes are centered INSIDE their empty gaps. Nothing solid is ever left
## behind glass; after shattering, the aperture is genuinely open.
##
## DESTRUCTION GRANULARITY (P0-F): piers are emitted as stacked ~1 m tall
## modules (CELL_H), so blasts carve out a few courses instead of deleting a
## whole multi-metre wall segment. Every module is its own integrity record.
##
## LAYER OWNERSHIP (P0-3): each facade pushes its EXPLICIT reveal key
## "<building tag>:f<storey>:<N/E/S/W>" directly (no nesting tricks), so
## ChunkManager.apply_floor_gate() can fade exactly one building's
## camera-facing wall per storey.
static func _storey_walls(b: MeshBatcher, off: Vector3, w: float, d: float,
		y0: float, fh: float, col: Color, floor_i: int, door_edge: int,
		tag: String) -> void:
	var facades := ["N", "E", "S", "W"]   # order matches side encoding 0..3
	for side in 4:
		b.push_layer("%s:f%d:%s" % [tag, floor_i, facades[side]])
		_facade_with_openings(b, off, side, w, d, y0, fh, col, floor_i,
				door_edge == side)
		b.pop_layer()


const CELL_H := 2.5      # floor slab panel target edge (BOTH dimensions)
const WALL_CELL := 1.25  # wall pier horizontal module target width


## One facade: openings list -> pier / sill / lintel segments (+ panes).
## `is_entrance` turns the mid-facade door into a real aperture; the Door
## ENTITY from the CityPlan manifest fills it at runtime.
static func _facade_with_openings(b: MeshBatcher, off: Vector3, side: int,
		w: float, d: float, y0: float, fh: float, col: Color, floor_i: int,
		is_entrance: bool) -> void:
	var horizontal := side == 0 or side == 2     # N/S walls run along X
	var length := w if horizontal else d
	var lo := -WALL_T * 0.5                      # extend past corners like the
	var hi := length + WALL_T * 0.5              # old monolithic walls did

	# --- openings: {c: center_t, wd: width, bot: sill height, h: height,
	#                glass: bool}
	var openings: Array[Dictionary] = []
	# Doorway aperture gets a small jamb clearance (real door frames have
	# one) so the leaf never rubs the piers and no collider face lies
	# exactly on the leaf's swing plane.
	if is_entrance and floor_i == 0:
		openings.append({"c": length * 0.5, "wd": DOOR_W + DOOR_FRAME,
				"bot": 0.0, "h": DOOR_H, "glass": false})
	var count := int(floor((length - 1.6) / WIN_SPACING))
	for i in count:
		var t := length * 0.5 + (float(i) - (count - 1) * 0.5) * WIN_SPACING
		if is_entrance and absf(t - length * 0.5) < DOOR_W * 0.5 + 0.9:
			continue   # keep the entrance clear; shopfront dresses this wall
		openings.append({"c": t, "wd": WIN_W, "bot": WIN_SILL, "h": WIN_H,
				"glass": true})
	if openings.is_empty():
		# Solid wall: one full-length piece.
		_emit_wall_seg(b, off, side, horizontal, lo, hi, y0, fh, col, w, d)
		return
	openings.sort_custom(_opening_cmp)

	# --- piers between openings (full height) ---------------------------------
	var cursor := lo
	for o in openings:
		var a: float = float(o["c"]) - float(o["wd"]) * 0.5
		if a - cursor >= 0.05:
			_emit_wall_seg(b, off, side, horizontal, cursor, a, y0, fh,
					col, w, d)
		cursor = maxf(cursor, float(o["c"]) + float(o["wd"]) * 0.5)
	if hi - cursor >= 0.05:
		_emit_wall_seg(b, off, side, horizontal, cursor, hi, y0, fh, col,
				w, d)

	# --- vertical closure + glass per opening ----------------------------------
	for o in openings:
		var oc: float = float(o["c"])
		var obot: float = float(o["bot"])
		var oh: float = float(o["h"])
		var owd: float = float(o["wd"])
		# Sill band below window openings.
		if obot > 0.05:
			_emit_band(b, off, side, horizontal, w, d, oc, owd, y0,
					obot, col)
		# Structural lintel/header above every opening.
		var lh := fh - obot - oh
		if lh > 0.05:
			_emit_band(b, off, side, horizontal, w, d, oc, owd,
					y0 + obot + oh, lh, col)
		# Glass pane centered INSIDE the aperture (windows only).
		if bool(o["glass"]):
			var p := _side_point(side, w, d, oc)
			var gsize := Vector3(owd - 0.06, oh - 0.04, GLASS_T) \
					if horizontal else Vector3(GLASS_T, oh - 0.04, owd - 0.06)
			b.add_destructible_box(
					off + Vector3(p.x, y0 + obot + oh * 0.5, p.y), gsize,
					WINDOW_COLOR, &"glass", true)


static func _emit_wall_seg(b: MeshBatcher, off: Vector3, side: int,
		horizontal: bool, a: float, b2: float, y0: float, fh: float,
		col: Color, w: float, d: float) -> void:
	# Horizontal wall modules (P1-9): piers longer than ~WALL_CELL split
	# into even ~1.25 m destructible cells so blasts punch LOCAL holes.
	# Vertical courses stay full-storey (documented compromise - keeps the
	# collider count linear and small; asserted by --citytest).
	var length := b2 - a
	var cells := maxi(1, ceili(length / WALL_CELL))
	var cw := length / float(cells)
	for i in cells:
		var mid_t := a + (float(i) + 0.5) * cw
		var p := _side_point(side, w, d, mid_t)
		var size := Vector3(cw, fh, WALL_T) if horizontal \
				else Vector3(WALL_T, fh, cw)
		b.add_destructible_box(off + Vector3(p.x, y0 + fh * 0.5, p.y),
				size, col, &"concrete")


## Sill/lintel band of `bw` meters centered at opening center `oc`.
static func _emit_band(b: MeshBatcher, off: Vector3, side: int,
		horizontal: bool, w: float, d: float, oc: float, bw: float,
		y_base: float, bh: float, col: Color) -> void:
	var p := _side_point(side, w, d, oc)
	var size := Vector3(bw, bh, WALL_T) if horizontal \
			else Vector3(WALL_T, bh, bw)
	b.add_destructible_box(off + Vector3(p.x, y_base + bh * 0.5, p.y),
			size, col, &"concrete")


static func _opening_cmp(a: Dictionary, b2: Dictionary) -> bool:
	return float(a["c"]) < float(b2["c"])


## Point along a facade at distance t from its first corner.
static func _side_point(side: int, w: float, d: float, t: float) -> Vector2:
	match side:
		0: return Vector2(t, WALL_T * 0.5)          # N: along +X at north face
		1: return Vector2(w - WALL_T * 0.5, t)      # E: along +Z at east face
		2: return Vector2(t, d - WALL_T * 0.5)      # S
		_: return Vector2(WALL_T * 0.5, t)          # W


# --- Windows -----------------------------------------------------------------
# Window apertures are composed by _facade_with_openings() together with the
# entrance door: one generator, one set of physical aperture rules (piers,
# sill, lintel, glass centered inside the gap). Ground-floor shopfront glazing
# follows the same rules when it becomes structural (see _shopfront dressing).

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

## Floor slab split around the stairwell aperture. DELEGATES to slab_pieces()
## so tests can validate coverage numerically without a scene tree.
##
## COVERAGE CONTRACT (enforced by --citytest): union(pieces) equals the usable
## interior footprint minus EXACTLY the shaft hole - no accidental gaps, no
## overlaps, exactly one intended opening.
static func slab_pieces(w: float, d: float, hole: Rect2) -> Array[Rect2]:
	var inner := Rect2(WALL_T, WALL_T,
			maxf(w - 2.0 * WALL_T, 0.0), maxf(d - 2.0 * WALL_T, 0.0))
	return SlabMath.subtract_rect(inner, hole)


static func _slab_with_hole(b: MeshBatcher, off: Vector3, w: float, d: float,
		hole: Rect2, y: float) -> void:
	var cy := y - SLAB_T * 0.5
	for r: Rect2 in slab_pieces(w, d, hole):
		_emit_slab_panels(b, off, r, cy)


## Bounded 2D paneling of ONE slab strip (P1-9): ~CELL_H modules in BOTH
## dimensions so a blast carves a LOCAL hole instead of a full-depth strip
## across the floor. Panel counts derive from the strip size (deterministic,
## no slivers - remainders fold into even cell widths); the count stays
## LINEAR in floor area and far under the RID budget.
static func _emit_slab_panels(b: MeshBatcher, off: Vector3, r: Rect2,
		cy: float) -> void:
	var cols := maxi(1, ceili(r.size.x / CELL_H))
	var rows := maxi(1, ceili(r.size.y / CELL_H))
	var cw := r.size.x / float(cols)
	var ch := r.size.y / float(rows)
	for cx in cols:
		for cz in rows:
			var c := Vector2(r.position.x + (float(cx) + 0.5) * cw,
					r.position.y + (float(cz) + 0.5) * ch)
			b.add_destructible_box(off + Vector3(c.x, cy, c.y),
					Vector3(cw, SLAB_T, ch), DECK_COLOR,
					&"concrete")


# --- Stairs ------------------------------------------------------------------

## Switchback staircase. GEOMETRY CONTRACT (P0-B):
##   - The flight's horizontal run is FIXED by the shaft layout; the ramp
##     angle is DERIVED from it (atan2(fh, run)) - never assumed.
##   - The walkable top surface starts EXACTLY flush with the lower landing
##     top (z0 at height lvl*fh) and ends EXACTLY flush with the upper
##     landing top (z1 at height (lvl+1)*fh). No lip, no invisible step,
##     no overshoot into a landing.
##   - Visual treads are placed ON the same inclined plane as the collider,
##     so what you see is what you stand on.
##   - Slope stays below Survivor.floor_max_angle (46 deg) for every
##     generated floor height (asserted by --citytest).
## Treads are visual only. Landings at both shaft ends on every level are
## structural and tagged f<lvl-1> (the storey you board from).
static func _staircase(b: MeshBatcher, off: Vector3, zone: Rect2,
		fh: float, n: int, tag: String, guard_on_east := true) -> void:
	var z_n := zone.position.y                  # north end
	var z_s := zone.end.y                       # south end
	var zx := zone.position.x
	var cx_west := zx + LANE_W * 0.5
	var cx_east := zx + LANE_W * 1.5

	const LAND_TUCK := 0.08   # landings tuck under flight ends: no seam notch
	# Structural landings at every level 1..n, top FLUSH with that level's
	# floor surface (top face exactly at y = lvl*fh). Level 0 needs none:
	# the ground slab already provides it. Each landing extends a few cm
	# UNDER its adjacent flight ends so the ramp underside meets the landing
	# plate above floor level - a capsule crossing the seam can no longer
	# wedge in the right-angle notch.
	for lvl in range(1, n + 1):
		b.push_layer(tag + ":f%d" % (lvl - 1))
		var ly := lvl * fh - SLAB_T * 0.5
		b.add_destructible_box(
				off + Vector3(zx + LANE_W, ly,
						z_n + (LAND - LAND_TUCK) * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND + LAND_TUCK),
				DECK_COLOR, &"concrete")
		b.add_destructible_box(
				off + Vector3(zx + LANE_W, ly,
						z_s - (LAND - LAND_TUCK) * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND + LAND_TUCK),
				DECK_COLOR, &"concrete")
		b.pop_layer()

	# Flight span between landing INNER edges. No RAMP_OVERLAP fudge: flush
	# start/end come from exact endpoint placement instead.
	var z0 := z_n + LAND
	var z1 := z_s - LAND
	var run := z1 - z0
	var ang := atan2(fh, run)          # DERIVED - the actual slope
	var cos_a := cos(ang)

	for k in n:
		var ascending_south := k % 2 == 0
		var lane_c := cx_west if ascending_south else cx_east
		var y0 := k * fh
		# Single walkable ramp collider. P1-8 GEOMETRY CONTRACT:
		#   - The walkable TOP face lies EXACTLY on the flight plane
		#     through (z0, y0) -> (z1, y0 + fh): the center is the plane
		#     midpoint pushed down half a thickness along the plane NORMAL
		#     (a pure-Y drop skews the box so only ONE endpoint meets its
		#     landing). Both endpoints are therefore FLUSH with their
		#     landing surfaces - no lip a capsule could not climb.
		#   - The seam is kept notch-free WITHOUT trimming the walkable
		#     surface: the landing plates extend LAND_TUCK under each
		#     flight end, so the ramp's end faces and underside corners
		#     are buried inside solid landing geometry (static overlaps
		#     are harmless) and no right-angle pocket remains above any
		#     walkable surface. Verified against the REAL collider bounds
		#     by --citytest.
		b.push_layer(tag + ":f%d" % k)
		var hyp := sqrt(run * run + fh * fh)
		var basis := Basis(Vector3.RIGHT, -ang if ascending_south else ang)
		var n_up := (basis * Vector3(0, 1, 0)).normalized()
		var mid := off + Vector3(lane_c, y0 + fh * 0.5, (z0 + z1) * 0.5)
		b.add_box_rotated(mid - n_up * (RAMP_T * 0.5),
				Vector3(LANE_W - 0.04, RAMP_T, hyp), basis, DECK_COLOR,
				true, false, &"concrete", tag, k)
		# Handrails: only on the OUTER edge of each lane (west lane -> the
		# shaft's west edge against the building interior; east lane -> the
		# shaft's east edge, already long-guarded). The INNER sides face the
		# adjacent lane's solid landing/flight at every z, so no rail is
		# needed there - and a rail would block the switchback crossing
		# (the lane gap between inner rail tips is < the capsule width).
		# Rails stop RAIL_SETBACK short of each flight end so the landing
		# funnel stays clear.
		var rail_len := maxf(hyp - 2.0 * RAIL_SETBACK, hyp * 0.55)
		var rail_sides := [-1.0] if ascending_south else [1.0]
		for rail_side in rail_sides:
			var rail_lat := basis * Vector3(
					rail_side * (LANE_W * 0.5 - 0.04), 0.0, 0.0)
			b.add_box_rotated(
					mid + n_up * 0.85 + rail_lat,
					Vector3(0.07, 0.07, rail_len), basis,
					RAIL_COLOR, true, false, &"steel")
		# Decorative treads (collision comes from the ramps) lying ON the
		# ramp plane: each tread's center follows the same straight line as
		# the collider's top surface, offset by half its thickness along
		# the plane normal. Visual and physical describe ONE plane.
		var steps := maxi(8, int(round(run / 0.28)))
		var step_len := hyp / float(steps)
		for i in steps:
			var raw := (float(i) + 0.5) / float(steps)
			var t := raw if ascending_south else 1.0 - raw
			var z := lerpf(z0, z1, t)
			var sy := y0 + raw * fh + 0.03 / cos_a
			b.add_visual_box(off + Vector3(lane_c, sy, z),
					Vector3(LANE_W - 0.06, 0.06, step_len + 0.02),
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
# Phase D slice 2 - semantic room layouts. Beds and counters are the big
# wall-snapped pieces that make a room READ as residential or retail.
const BED_ALONG := 1.45      # bed width, running ALONG its wall
const BED_DEPTH := 2.05      # headboard (wall side) to footboard
const COUNTER_ALONG := 2.2   # shop counter run along its wall
const COUNTER_DEPTH := 0.62

## Scatter deterministic furniture through one storey's open floor.
## Everything inherits the CURRENT storey layer (the cutaway hides it with
## the room) AND sits on THAT storey's floor: every item's origin Y is
## floor_i * fh (P0-C) - upper-storey furniture can never stack onto the
## ground-floor colliders again.
##
## Placement (P0-D) validates each item's ORIENTED footprint (OBB) against:
## exterior-wall inset, stair shaft + circulation margin, entrance swing +
## walk-in corridor, and previously placed solid items. Visual and collider
## transforms are identical everywhere (the desk body shares its accessories'
## rotated basis; bookshelves are genuinely snapped against their wall).
##
## Phase D slice 2: the room_type label picks the furniture PROGRAM -
## "residential" rooms sleep (wall-snapped beds first, then the home mix),
## "retail" floors sell (wall-run counters, dense shelf rows, display
## tables, never a bed).
static func _furnish(b: MeshBatcher, off: Vector3, w: float, d: float,
		fh: float, floor_i: int, tag: String, zone: Rect2,
		door_edge: int, room_type := "residential") -> void:
	var rng := WorldSeed.rng_for("furnish",
			[WorldSeed.str_hash(tag), floor_i])
	var floor_y := float(floor_i) * fh   # THE floor this furniture lives on
	var usable := Rect2(WALL_T + 0.45, WALL_T + 0.45,
			w - 2.0 * (WALL_T + 0.45), d - 2.0 * (WALL_T + 0.45))
	if usable.size.x < 1.4 or usable.size.y < 1.4:
		return

	# --- keep-out OBBs: stair shaft, entrance swing, walk-in corridor ------
	# The shaft keep-out is the EXACT zone rect: it already contains the
	# builder's structural margins, so nothing overlaps the stairs them-
	# selves. Growing it used to reach the perimeter walls on the zone's
	# anchored side and reject EVERY wall-snapped bookcase there (P1-12).
	var blocked: Array[Dictionary] = []
	blocked.append(_rect_obb(zone))
	if door_edge >= 0:
		var mid_len := (w if door_edge == 0 or door_edge == 2 else d) * 0.5
		var dp := _side_point(door_edge, w, d, mid_len)
		match door_edge:
			0: dp += Vector2(0, 1.1)
			1: dp += Vector2(-1.1, 0)
			2: dp += Vector2(0, -1.1)
			_: dp += Vector2(1.1, 0)
		# Facade-aligned strip covering the leaf swing (~1.5 m radius) plus
		# a 2.4 m walk-in lane behind it - the entrance route stays open.
		var corridor_len := DOOR_W + 2.4
		var corridor_depth := DOOR_W + 0.4
		var cc := dp
		match door_edge:
			0: cc += Vector2(0, corridor_depth * 0.5 - 0.55)
			1: cc += Vector2(-corridor_depth * 0.5 + 0.55, 0)
			2: cc += Vector2(0, -corridor_depth * 0.5 + 0.55)
			_: cc += Vector2(corridor_depth * 0.5 - 0.55, 0)
		var along_x := door_edge == 0 or door_edge == 2
		blocked.append({
			"c": cc,
			"e": Vector2(corridor_len * 0.5, corridor_depth * 0.5)
					if along_x else Vector2(corridor_depth * 0.5,
					corridor_len * 0.5),
			"r": 0.0,
		})

	var placed: Array[Dictionary] = []    # solid furniture OBBs so far
	var spot_free := func(p: Vector2, half: Vector2, yaw: float) -> bool:
		var obb := {"c": p, "e": half, "r": yaw}
		if not _obb_in_rect(obb, usable):
			return false
		for bl in blocked:
			if _obb_overlap(obb, bl):
				return false
		for q in placed:
			if _obb_overlap(obb, q):
				return false
		return true
	var take_spot := func(half: Vector2, yaw: float) -> Variant:
		for attempt in 40:
			var cand := Vector2(
					rng.randf_range(usable.position.x + half.x,
							usable.end.x - half.x),
					rng.randf_range(usable.position.y + half.y,
							usable.end.y - half.y))
			if spot_free.call(cand, half, yaw):
				placed.append({"c": cand, "e": half, "r": yaw})
				return cand
		return null

	# --- room_type picks the furniture PROGRAM (Phase D slice 2) --------------
	if room_type == "retail":
		# SHOP floor: counters run ALONG a wall, dense shelf rows, small
		# display tables - retail never sleeps.
		for i in rng.randi_range(1, 2):
			var cs := {}
			for attempt in 5:
				cs = _wall_snap_spot(rng, usable, w, d, blocked, placed,
						COUNTER_ALONG * 0.5, COUNTER_DEPTH)
				if not cs.is_empty():
					break
			if cs.is_empty():
				continue
			placed.append(cs["obb"])
			_f_counter(b, off + Vector3(cs["pos"].x, floor_y,
					cs["pos"].y), float(cs["yaw"]), tag, floor_i)
		for i in rng.randi_range(2, 3):
			var s := _shelf_spot(rng, usable, w, d, blocked, placed)
			if s.is_empty():
				break
			placed.append(s["obb"])
			_f_shelf(b, off + Vector3(s["pos"].x, floor_y, s["pos"].y),
					float(s["yaw"]), rng, tag, floor_i)
		for i in rng.randi_range(1, 2):
			var t: Variant = take_spot.call(Vector2(0.63, 0.44), 0.0)
			if t == null:
				break
			var tp: Vector2 = t
			_f_table(b, off + Vector3(tp.x, floor_y, tp.y), tag, floor_i)
		for i in rng.randi_range(1, 2):
			var pv: Variant = take_spot.call(Vector2(0.26, 0.26), 0.0)
			if pv == null:
				break
			var pp: Vector2 = pv
			_f_plant(b, off + Vector3(pp.x, floor_y, pp.y))
	else:
		# RESIDENTIAL floor: beds claim wall space FIRST (largest foot-
		# print wins), then the familiar home mix.
		for i in rng.randi_range(1, 2):
			var bs := {}
			for attempt in 5:
				bs = _wall_snap_spot(rng, usable, w, d, blocked, placed,
						BED_ALONG * 0.5, BED_DEPTH)
				if not bs.is_empty():
					break
			if bs.is_empty():
				continue
			placed.append(bs["obb"])
			_f_bed(b, off + Vector3(bs["pos"].x, floor_y,
					bs["pos"].y), float(bs["yaw"]), tag, floor_i)
		# Tables with chairs pulled up around them.
		for i in rng.randi_range(1, 3):
			var t: Variant = take_spot.call(Vector2(0.63, 0.44), 0.0)
			if t == null:
				break
			var tp: Vector2 = t
			_f_table(b, off + Vector3(tp.x, floor_y, tp.y), tag, floor_i)
			for c in rng.randi_range(1, 2):
				var ca := TAU * rng.randf()
				var cp := tp + Vector2(cos(ca), sin(ca)) * 0.95
				if usable.grow(-0.3).has_point(cp) \
						and spot_free.call(cp, Vector2(0.24, 0.24), ca) \
						or (_obb_in_rect({"c": cp, "e": Vector2(0.24, 0.24),
						"r": ca}, usable.grow(-0.1))
						and not _point_in_any(cp, blocked)):
					_f_chair(b, off + Vector3(cp.x, floor_y, cp.y),
							atan2(tp.x - cp.x, tp.y - cp.y))
		# Bookshelves/wardrobes: snapped against a wall (P1-12 contract).
		for i in rng.randi_range(1, 2):
			var s := _shelf_spot(rng, usable, w, d, blocked, placed)
			if s.is_empty():
				break
			placed.append(s["obb"])
			_f_shelf(b, off + Vector3(s["pos"].x, floor_y, s["pos"].y),
					float(s["yaw"]), rng, tag, floor_i)
		# Computer desks: accessories AND body share one rotated basis.
		for i in rng.randi_range(0, 2):
			var yaw := rng.randf_range(0.0, TAU)
			var dv: Variant = take_spot.call(Vector2(0.68, 0.36), yaw)
			if dv == null:
				break
			var dp2: Vector2 = dv
			_f_desk_pc(b, off + Vector3(dp2.x, floor_y, dp2.y), yaw, tag,
					floor_i)
		# Plant vases tucked into leftovers (soft clutter - no collision).
		for i in rng.randi_range(1, 3):
			var pv: Variant = take_spot.call(Vector2(0.26, 0.26), 0.0)
			if pv == null:
				break
			var pp: Vector2 = pv
			_f_plant(b, off + Vector3(pp.x, floor_y, pp.y))


## Nearest-wall shelf placement (P1-12). The shelf is a 1.6 x 0.34 slab:
## its local X axis is WIDTH, local Z axis is DEPTH. Wall-snapped against
## the interior wall face (+ GAP), yaw turns the width to run ALONG the
## chosen wall. Validation uses the shelf's REAL oriented footprint against
## the interior bounds and keep-out zones - never a furniture-center
## rectangle that excludes wall-adjacent placement.
const SHELF_WIDTH := 1.6
const SHELF_DEPTH := 0.34
const SHELF_GAP := 0.02


static func _shelf_spot(rng: RandomNumberGenerator, usable: Rect2,
		w: float, d: float, blocked: Array[Dictionary],
		placed: Array[Dictionary]) -> Dictionary:
	return _wall_snap_spot(rng, usable, w, d, blocked, placed,
			SHELF_WIDTH * 0.5, SHELF_DEPTH)


## Generic wall-SNAPPED placement for any rectangular piece whose back face
## must touch an interior wall (Phase D slice 2): shelves, counters, beds.
## `half_along` is HALF the along-wall width, `depth` the FULL wall-to-room
## extent; yaw aligns the width axis WITH the chosen wall exactly like the
## furniture builders' basis convention (local X = along-wall, local -Z =
## the wall side). Validation mirrors P1-12: TRUE interior bounds + keep-out
## zones + already-placed OBBs - never a furniture-center rectangle that
## excludes wall-adjacent placement. Returns {} when no side fits.
static func _wall_snap_spot(rng: RandomNumberGenerator, usable: Rect2,
		w: float, d: float, blocked: Array[Dictionary],
		placed: Array[Dictionary], half_along: float,
		depth: float, gap := SHELF_GAP) -> Dictionary:
	var side := rng.randi_range(0, 3)          # 0=W 1=E 2=N 3=S
	var yaw := 0.0
	var pos := Vector2.ZERO
	match side:
		0:   # west wall: width runs along Z, depth extends +X inward
			yaw = PI * 0.5
			pos = Vector2(WALL_T + depth * 0.5 + gap,
					rng.randf_range(usable.position.y + half_along,
							usable.end.y - half_along))
		1:   # east wall
			yaw = PI * 0.5
			pos = Vector2(w - WALL_T - depth * 0.5 - gap,
					rng.randf_range(usable.position.y + half_along,
							usable.end.y - half_along))
		2:   # north wall: width runs along X, depth extends +Y inward
			yaw = 0.0
			pos = Vector2(rng.randf_range(usable.position.x + half_along,
					usable.end.x - half_along),
					WALL_T + depth * 0.5 + gap)
		_:   # south wall
			yaw = 0.0
			pos = Vector2(rng.randf_range(usable.position.x + half_along,
					usable.end.x - half_along),
					d - WALL_T - depth * 0.5 - gap)
	# OBB half-extents MATCH the drawn/colliding box after the wall-aligned
	# yaw: E/W snaps carry (depth/2 along X, half_along along Y) in world
	# terms; N/S snaps the transpose.
	var half := Vector2(depth * 0.5, half_along) if side <= 1 \
			else Vector2(half_along, depth * 0.5)
	var obb := {"c": pos, "e": half, "r": yaw}
	var interior := Rect2(WALL_T, WALL_T,
			maxf(w - 2.0 * WALL_T, 0.0), maxf(d - 2.0 * WALL_T, 0.0))
	if not _obb_in_rect(obb, interior):
		return {}
	for bl in blocked:
		if _obb_overlap(obb, bl):
			return {}
	for q in placed:
		if _obb_overlap(obb, q):
			return {}
	return {"pos": pos, "yaw": yaw, "obb": obb}


static func _point_in_any(p: Vector2, obbs: Array[Dictionary]) -> bool:
	for o in obbs:
		if _obb_contains_point(o, p):
			return true
	return false


## Oriented-bounding-box containment/intersection helpers (2D SAT).
## An OBB is {c: Vector2 center, e: Vector2 half-extents, r: float yaw}.
static func _obb_axes(r: float) -> Vector2:
	return Vector2(cos(r), sin(r))


static func _obb_contains_point(o: Dictionary, p: Vector2) -> bool:
	var u := _obb_axes(float(o["r"]))
	var v := Vector2(-u.y, u.x)
	var l := p - (o["c"] as Vector2)
	var e: Vector2 = o["e"]
	return absf(l.dot(u)) <= e.x + SlabMath.EPS \
			and absf(l.dot(v)) <= e.y + SlabMath.EPS


static func _obb_in_rect(o: Dictionary, r: Rect2) -> bool:
	var u := _obb_axes(float(o["r"]))
	var v := Vector2(-u.y, u.x)
	var e: Vector2 = o["e"]
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner: Vector2 = (o["c"] as Vector2) + u * e.x * sx \
					+ v * e.y * sy
			if not r.grow(SlabMath.EPS).has_point(corner):
				return false
	return true


static func _obb_overlap(a: Dictionary, b2: Dictionary) -> bool:
	var axes: Array[Vector2] = []
	var ua := _obb_axes(float(a["r"]))
	var ub := _obb_axes(float(b2["r"]))
	axes.append(ua)
	axes.append(Vector2(-ua.y, ua.x))
	axes.append(ub)
	axes.append(Vector2(-ub.y, ub.x))
	var ea: Vector2 = a["e"]
	var eb: Vector2 = b2["e"]
	var d: Vector2 = (b2["c"] as Vector2) - (a["c"] as Vector2)
	for ax in axes:
		var ra := ea.x * absf(ax.dot(ua)) + ea.y * absf(ax.dot(Vector2(-ua.y, ua.x)))
		var rb := eb.x * absf(ax.dot(ub)) + eb.y * absf(ax.dot(Vector2(-ub.y, ub.x)))
		if absf(d.dot(ax)) > ra + rb:
			return false
	return true


static func _rect_obb(r: Rect2) -> Dictionary:
	return {"c": r.get_center(), "e": r.size * 0.5, "r": 0.0}


## Dining/work table: oak top on a dark apron base. Collides (walk around).
static func _f_table(b: MeshBatcher, pos: Vector3, owner_tag := "",
		floor_i := -1) -> void:
	b.add_destructible_box(pos + Vector3(0, 0.37, 0),
			Vector3(1.15, 0.74, 0.78), FURN_WOOD_DARK, &"wood", true,
			owner_tag, floor_i)
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
		rng: RandomNumberGenerator, owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 1.0, 0),
			Vector3(SHELF_WIDTH, 2.0, SHELF_DEPTH), basis, FURN_WALNUT, true,
			false, &"wood", owner_tag, floor_i)
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


## Desk with keyboard, monitor stand and dark screen. VISUAL/COLLIDER
## AGREEMENT (P0-D): the destructible desk BODY shares its accessories'
## rotated basis - collider and visuals describe the same oriented footprint.
static func _f_desk_pc(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.36, 0),
			Vector3(1.35, 0.72, 0.68), basis, FURN_DESK, true,
			false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + basis.z * 0.18 + Vector3(0, 0.79, 0),
			Vector3(0.42, 0.05, 0.16), basis, FURN_KEYBOARD, false)
	b.add_box_rotated(pos - basis.z * 0.16 + Vector3(0, 0.82, 0),
			Vector3(0.10, 0.16, 0.10), basis, FURN_METAL, false)
	b.add_box_rotated(pos - basis.z * 0.20 + Vector3(0, 1.06, 0),
			Vector3(0.58, 0.36, 0.04), basis, FURN_SCREEN, false)


## Bed: walnut frame (collides) with headboard AGAINST the wall - local
## X runs ALONG the wall, local -Z faces it (the _wall_snap_spot basis
## convention). Pale mattress, pillow at the head, blanket band across the
## foot half; all dressing shares the rotated basis.
static func _f_bed(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.21, 0),
			Vector3(BED_ALONG, 0.42, BED_DEPTH), basis, FURN_WOOD_DARK,
			true, false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + Vector3(0, 0.50, 0),
			Vector3(BED_ALONG - 0.12, 0.16, BED_DEPTH - 0.18), basis,
			Color("cfc4b0"), false)
	b.add_box_rotated(pos - basis.z * (BED_DEPTH * 0.5 - 0.04)
			+ Vector3(0, 0.62, 0),
			Vector3(BED_ALONG, 0.82, 0.07), basis, FURN_WALNUT, false)
	b.add_box_rotated(pos - basis.z * (BED_DEPTH * 0.5 - 0.34)
			+ Vector3(0, 0.62, 0),
			Vector3(BED_ALONG - 0.34, 0.13, 0.52), basis,
			Color("ded8ca"), false)
	b.add_box_rotated(pos + basis.z * (BED_DEPTH * 0.5 - 0.62)
			+ Vector3(0, 0.60, 0),
			Vector3(BED_ALONG - 0.10, 0.10, 1.02), basis, FURN_LEAF_DARK,
			false)


## Shop counter: walnut carcass against the wall (collides), oak countertop
## with a slight overhang, dark register block toward one end. Same basis
## convention as _f_bed / _f_shelf.
static func _f_counter(b: MeshBatcher, pos: Vector3, yaw: float,
		owner_tag := "", floor_i := -1) -> void:
	var basis := Basis(Vector3.UP, -yaw)
	b.add_box_rotated(pos + Vector3(0, 0.475, 0),
			Vector3(COUNTER_ALONG, 0.95, COUNTER_DEPTH), basis,
			FURN_WALNUT, true, false, &"wood", owner_tag, floor_i)
	b.add_box_rotated(pos + Vector3(0, 0.99, 0.03),
			Vector3(COUNTER_ALONG + 0.14, 0.06, COUNTER_DEPTH + 0.12),
			basis, FURN_WOOD, false)
	b.add_box_rotated(pos + basis.x * (COUNTER_ALONG * 0.5 - 0.38)
			+ Vector3(0, 1.17, 0.02),
			Vector3(0.38, 0.30, 0.30), basis, FURN_SCREEN, false)


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
		_roof_props(b, off, fp, style, total_h, zone, has_stairs)


## Flat-roof dressing: thin VISUAL membrane around the shaft hole (no
## collision - the structural top slab below is the real deck). Lives on the
## RoofLayer so interiors can be revealed while the player is inside. Shares
## slab_pieces() with the structural slabs: same aperture, same four strips.
static func _membrane_with_hole(b: MeshBatcher, off: Vector3, w: float,
		d: float, hole: Rect2, y: float, color: Color) -> void:
	for r: Rect2 in slab_pieces(w, d, hole):
		b.add_roof_visual_box(
				off + Vector3(r.get_center().x, y, r.get_center().y),
				Vector3(r.size.x, 0.04, r.size.y), color)


## Flat-roof prop dressing (Phase D slice 4/5): AC condensers, a water tank,
## vent pipes and an antenna mast scattered over the walkable roof deck.
## Phase D slice 5 adds ROOF-TYPE VARIETY: retail roofs get BILLBOARDS
## (tall vertical ad panels), residential roofs get LAUNDRY LINES (horizontal
## cables with struts) and PIGEON COOPS (small wooden hutches). Props are
## DESTRUCTIBLE boxes - standable cover that doubles as fresh ledge-grab
## lips for the Phase E parkour system. Placement is deterministic
## (WorldSeed.rng_for, same pattern as the chimney), confined to the deck
## area inset from the parapet line, and keeps a clear approach ring around
## the stair bulkhead so the roof exit never gets blocked. Pitched roofs
## carry no walkable deck and skip dressing entirely.
static func _roof_props(b: MeshBatcher, off: Vector3, fp: Rect2,
		style: Dictionary, total_h: float, zone: Rect2, has_stairs: bool) -> void:
	var w := fp.size.x
	var d := fp.size.y
	var inset := WALL_T + 0.55   # clear of the parapet inner face
	var usable := Rect2(inset, inset,
			maxf(w - 2.0 * inset, 0.0), maxf(d - 2.0 * inset, 0.0))
	if usable.size.x < 1.4 or usable.size.y < 1.4:
		return   # deck too small to dress safely
	var keepout := zone.grow(1.2) if has_stairs else Rect2()
	var rng := WorldSeed.rng_for("roofprops",
			[int(style["wall"]), int(style["roof"]), int(round(d * 10))])
	var budget := mini(int(usable.get_area() / 18.0), 4)
	var target := 1 + rng.randi_range(0, maxi(budget - 1, 0))
	var placed: Array[Dictionary] = []
	var attempts := 0
	var room_type := str(style.get("room_type", "residential"))
	var is_retail := room_type == "retail"
	while placed.size() < target and attempts < 40:
		attempts += 1
		# kind selection weighted by room_type for variety
		var kind := rng.randi_range(0, 5 if is_retail else 4)  # 0-5 retail (adds billboard), 0-4 residential (adds pigeon coop)
		var footprint := Vector2(0.95, 0.75)      # AC condenser
		if kind == 1:
			footprint = Vector2(1.25, 1.25)       # water tank
		elif kind == 2:
			footprint = Vector2(0.55, 0.55)       # vent cluster
		elif kind == 3:
			footprint = Vector2(0.35, 0.35)       # antenna base
		elif kind == 4:
			footprint = Vector2(2.0, 0.3)         # billboard (retail) / laundry line (residential)
		elif kind == 5:
			footprint = Vector2(1.1, 1.1)         # pigeon coop (residential only)
		var px := rng.randf_range(usable.position.x,
				maxf(usable.end.x - footprint.x, usable.position.x))
		var pz := rng.randf_range(usable.position.y,
				maxf(usable.end.y - footprint.y, usable.position.y))
		var r := Rect2(px, pz, footprint.x, footprint.y)
		if keepout.size.x > 0.0 and keepout.size.y > 0.0 \
				and r.intersects(keepout):
			continue
		var obb := _rect_obb(r)
		var clash := false
		for o in placed:
			if _obb_overlap(obb, o):
				clash = true
				break
		if clash:
			continue
		placed.append(obb)
		var y := total_h + 0.04   # on top of the membrane
		match kind:
			0: _rp_ac_unit(b, off, r, y)
			1: _rp_water_tank(b, off, r, y)
			2: _rp_vents(b, off, r, y)
			3: _rp_antenna(b, off, r, y)
			4: _rp_billboard_or_laundry(b, off, r, y, is_retail)
			5: _rp_pigeon_coop(b, off, r, y)


static func _rp_ac_unit(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 0.42, c.y),
			Vector3(r.size.x, 0.84, r.size.y), Color("b8bcc2"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 0.90, c.y),
			Vector3(r.size.x * 0.7, 0.12, r.size.y * 0.7),
			Color("6f767c"), &"steel")


static func _rp_water_tank(b: MeshBatcher, off: Vector3, r: Rect2,
		y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 0.14, c.y),
			Vector3(r.size.x * 0.8, 0.28, r.size.y * 0.8), PLINTH_COLOR,
			&"concrete")
	b.add_destructible_box(off + Vector3(c.x, y + 0.98, c.y),
			Vector3(r.size.x, 1.4, r.size.y), Color("3e5a6e"), &"steel")


static func _rp_vents(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x - 0.12, y + 0.45, c.y - 0.10),
			Vector3(0.24, 0.9, 0.24), PLINTH_COLOR.darkened(0.15), &"concrete")
	b.add_destructible_box(off + Vector3(c.x + 0.13, y + 0.32, c.y + 0.12),
			Vector3(0.20, 0.64, 0.20), PLINTH_COLOR.darkened(0.15), &"concrete")


static func _rp_antenna(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	b.add_destructible_box(off + Vector3(c.x, y + 1.15, c.y),
			Vector3(0.12, 2.3, 0.12), Color("565d63"), &"steel")
	b.add_destructible_box(off + Vector3(c.x, y + 1.95, c.y),
			Vector3(0.90, 0.07, 0.07), Color("565d63"), &"steel")


## Retail billboard OR residential laundry line (Phase D slice 5).
## Single function avoids duplication: both are vertical posts with a
## cross member. Retail = tall ad panel (steel frame + dark face).
## Residential = laundry line (two posts + horizontal cables + struts).
static func _rp_billboard_or_laundry(b: MeshBatcher, off: Vector3,
		r: Rect2, y: float, is_retail: bool) -> void:
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	if is_retail:
		# BILLBOARD: steel I-beam posts + large dark ad panel.
		# Posts at the long edges, panel spans between them.
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.15, y + 4.5, c.y),
				Vector3(0.3, 9.0, d), Color("3a3f44"), &"steel")
		b.add_destructible_box(off + Vector3(c.x + w * 0.5 - 0.15, y + 4.5, c.y),
				Vector3(0.3, 9.0, d), Color("3a3f44"), &"steel")
		b.add_destructible_box(off + Vector3(c.x, y + 4.5, c.y),
				Vector3(w - 0.6, 8.5, 0.15), Color("1a1a20"), &"wood")
		# Small ladder rung on one post (visual ledge-grab lip).
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.15, y + 0.5, c.y + d * 0.5 + 0.1),
				Vector3(0.08, 0.08, 0.3), Color("3a3f44"), &"steel")
	else:
		# LAUNDRY LINE: two wooden posts with horizontal cables.
		var post_h := 2.2
		b.add_destructible_box(off + Vector3(c.x - w * 0.5 + 0.1, y + post_h * 0.5, c.y),
				Vector3(0.12, post_h, 0.12), FURN_WOOD_DARK, &"wood")
		b.add_destructible_box(off + Vector3(c.x + w * 0.5 - 0.1, y + post_h * 0.5, c.y),
				Vector3(0.12, post_h, 0.12), FURN_WOOD_DARK, &"wood")
		# 3 cable strands (visual only, no collision needed - posts are the cover).
		for i in 3:
			var ch := y + 0.5 + float(i) * 0.55
			b.add_visual_box(off + Vector3(c.x, ch, c.y),
					Vector3(w - 0.3, 0.02, d), Color("cfc4b0"))


## Pigeon coop (residential only, Phase D slice 5).
## Small wooden hutch with slatted front and a perching ledge.
## Destructible - standable cover + ledge-grab lip.
static func _rp_pigeon_coop(b: MeshBatcher, off: Vector3, r: Rect2, y: float) -> void:
	var c := r.get_center()
	var w := r.size.x
	var d := r.size.y
	var h := 1.3
	# Main box (hutch body).
	b.add_destructible_box(off + Vector3(c.x, y + h * 0.5, c.y),
			Vector3(w * 0.9, h, d * 0.9), FURN_WOOD_DARK, &"wood")
	# Slatted front face (visual).
	b.add_visual_box(off + Vector3(c.x, y + h * 0.5, c.y + d * 0.5),
			Vector3(w * 0.85, h * 0.8, 0.06), FURN_WOOD)
	# Perching ledge on top (standable + ledge-grab).
	b.add_destructible_box(off + Vector3(c.x, y + h + 0.08, c.y),
			Vector3(w, 0.16, d), FURN_WOOD, &"wood")
	# Entry hole (visual only).
	b.add_visual_box(off + Vector3(c.x, y + h * 0.6, c.y + d * 0.5),
			Vector3(0.3, 0.3, 0.06), Color("1a1a20"))


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
