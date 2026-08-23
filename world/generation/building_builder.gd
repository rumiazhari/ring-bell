class_name BuildingBuilder
extends RefCounted
## Emits ONE procedural building into a MeshBatcher: exterior shell, storey
## slabs with a stairwell shaft, a real switchback staircase (walkable ramp
## colliders + decorative treads), roof deck with parapet, pitched roof shell,
## bulkhead roof exit, balconies, windows/shopfronts and chimney.
##
## Everything here is decoration-free geometry driven purely by the
## BuildingSpec dict produced by CityPlan - identical specs always produce
## identical geometry. Upper floors are ALWAYS reachable: every multi-storey
## building has stairs and a roof exit (no fake facades, per design rules).
##
## Local frame: origin = spec.rect.position, X east, Rect2.y = Z (south),
## heights in Y. Ground top surface at y = 0.

const WALL_T := 0.35
const SLAB_T := 0.22
const LANE_W := 1.25                 # stair lane width
const LAND := 1.35                   # landing depth at each stairwell end
const STAIR_MARGIN_X := 0.5          # stairwell inset from west wall
const STAIR_MARGIN_Z := 0.5
const PITCH_DEG := 38.0              # flight pitch -> run = fh / tan(pitch)
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


static func build(b: MeshBatcher, spec: Dictionary) -> void:
	var fp: Rect2 = spec["rect"]
	var style: Dictionary = spec["style"]
	var wall_c: Color = WALL_COLORS[style["wall"] % WALL_COLORS.size()]
	var roof_c: Color = ROOF_COLORS[style["roof"] % ROOF_COLORS.size()]
	var fh: float = spec["floor_h"]
	var n: int = mini(int(spec["floors"]), 8)
	var total_h := n * fh

	# --- stairwell layout (west side, running north -> south) -----------------
	var run := fh / tan(deg_to_rad(PITCH_DEG))
	var zone_len := run + 2.0 * LAND
	var has_stairs := fp.size.y >= zone_len + 1.1 and fp.size.x >= 4.2 \
			and n >= 2
	var zone := Rect2(STAIR_MARGIN_X, STAIR_MARGIN_Z, LANE_W * 2.0, zone_len)

	var off := Vector3(fp.position.x, 0.0, fp.position.y)
	var w := fp.size.x
	var d := fp.size.y

	# --- ground slab ----------------------------------------------------------
	b.add_box(off + Vector3(w * 0.5, SLAB_T * 0.5, d * 0.5),
			Vector3(w, SLAB_T, d), FLOOR_COLOR)

	# --- storey slabs with stairwell hole (levels 1 .. n) ----------------------
	for lvl in range(1, n + 1):
		if has_stairs:
			_slab_with_hole(b, off, w, d, zone, lvl * fh)
		else:
			b.add_box(off + Vector3(w * 0.5, lvl * fh - SLAB_T * 0.5, d * 0.5),
					Vector3(w - WALL_T, SLAB_T, d - WALL_T), DECK_COLOR)

	# --- walls + windows -------------------------------------------------------
	for f in n:
		var y0 := f * fh
		var col := PLINTH_COLOR if f == 0 else wall_c
		_storey_walls(b, off, w, d, y0, fh, col,
				spec["door_edge"] if f == 0 else -1)
		for facade in 4:
			_window_row(b, off, w, d, facade, f, fh,
					spec["door_edge"] == facade and f == 0)
	# Shopfront dressing on the street-facing ground wall.
	_shopfront(b, off, w, d, spec)

	# --- staircase --------------------------------------------------------------
	if has_stairs:
		_staircase(b, off, zone, fh, n)

	# --- roof -------------------------------------------------------------------
	_roof(b, off, fp, style, roof_c, wall_c, total_h, zone, has_stairs)


# --- Walls -------------------------------------------------------------------

static func _storey_walls(b: MeshBatcher, off: Vector3, w: float, d: float,
		y0: float, fh: float, col: Color, door_edge: int) -> void:
	var cy := y0 + fh * 0.5
	# North (outward -Z) / South (+Z) / West (-X) / East (+X).
	var sides := [
		[Vector3(w * 0.5, 0, WALL_T * 0.5), Vector3(w + WALL_T, fh, WALL_T)],   # N
		[Vector3(w * 0.5, 0, d - WALL_T * 0.5), Vector3(w + WALL_T, fh, WALL_T)],# S
		[Vector3(WALL_T * 0.5, 0, d * 0.5), Vector3(WALL_T, fh, d + WALL_T)],   # W
		[Vector3(w - WALL_T * 0.5, 0, d * 0.5), Vector3(WALL_T, fh, d + WALL_T)],# E
	]
	for side in 4:
		var c: Vector3 = sides[side][0]
		var size: Vector3 = sides[side][1]
		if door_edge == side:
			_wall_with_door(b, off, side, w, d, y0, fh, col)
		else:
			b.add_box(off + Vector3(c.x, cy, c.z), size, col)


## Wall split around a centered doorway gap + lintel + closed door leaf.
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
		b.add_box(off + Vector3(c.x, y0 + fh * 0.5, c.y), size, col)
	# Lintel band above the opening.
	var lc := _side_point(side, w, d, mid)
	var lsize := Vector3(DOOR_W, lintel_h, WALL_T) if horizontal \
			else Vector3(WALL_T, lintel_h, DOOR_W)
	b.add_box(off + Vector3(lc.x, y0 + DOOR_H + lintel_h * 0.5, lc.y), lsize, col)
	# Closed door leaf (decor; becomes interactable in a later phase).
	var dsize := Vector3(DOOR_W - 0.1, DOOR_H - 0.05, WALL_T * 0.4)
	b.add_box(off + Vector3(lc.x, y0 + DOOR_H * 0.5, lc.y), dsize, DOOR_COLOR)


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
		b.add_box(off + Vector3(p.x, cy, p.y), size, WINDOW_COLOR)


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
	b.add_box(off + Vector3(pc.x, 2.62, pc.y), bsize, sign_c)
	for i in 2:
		var t := mid + (DOOR_W * 0.5 + 1.15) * (1.0 if i == 0 else -1.0)
		var p := _side_point(side, w, d, t)
		var psize := Vector3(1.7, 2.15, 0.5) if horizontal \
				else Vector3(0.5, 2.15, 1.7)
		b.add_box(off + Vector3(p.x, 1.22, p.y), psize, WINDOW_COLOR)


# --- Slabs -------------------------------------------------------------------

## Floor slab split into three boxes leaving `hole` open (the stair shaft).
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
		b.add_box(off + Vector3(r.get_center().x, cy, r.get_center().y),
				Vector3(r.size.x, SLAB_T, r.size.y), DECK_COLOR, true)


# --- Stairs ------------------------------------------------------------------

## Switchback staircase: landings at BOTH ends of the shaft at every level,
## flights alternating lanes. Ramp colliders are walkable (<= 42 deg);
## thin tread boxes give the visual read.
static func _staircase(b: MeshBatcher, off: Vector3, zone: Rect2,
		fh: float, n: int) -> void:
	var run := zone.size.y - 2.0 * LAND
	var ang := atan2(fh, run)
	var zx := zone.position.x
	var z_n := zone.position.y                  # north end
	var z_s := zone.end.y                       # south end
	var cx_west := zx + LANE_W * 0.5
	var cx_east := zx + LANE_W * 1.5

	for lvl in n + 1:
		var ly := lvl * fh - SLAB_T * 0.5
		b.add_box(off + Vector3(zx + LANE_W, ly, z_n + LAND * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND), DECK_COLOR, true)
		b.add_box(off + Vector3(zx + LANE_W, ly, z_s - LAND * 0.5),
				Vector3(LANE_W * 2.0, SLAB_T, LAND), DECK_COLOR, true)

	for k in n:
		var ascending_south := k % 2 == 0
		var lane_c := cx_west if ascending_south else cx_east
		var z0 := z_n + LAND
		var z1 := z_s - LAND
		var y0 := k * fh
		var dir := 1.0 if ascending_south else -1.0
		# Walkable ramp collider (top surface carries the player).
		var hyp := sqrt(run * run + fh * fh)
		var basis := Basis(Vector3.RIGHT, -ang if ascending_south else ang)
		b.add_box_rotated(
				off + Vector3(lane_c, y0 + fh * 0.5 - 0.11, (z0 + z1) * 0.5),
				Vector3(LANE_W - 0.04, 0.22, hyp), basis, DECK_COLOR, true)
		# Decorative treads.
		var steps := maxi(8, int(round(run / 0.28)))
		for i in steps:
			var t := (float(i) + 0.5) / float(steps)
			var z := lerpf(z0, z1, t) if ascending_south else lerpf(z1, z0, t)
			var sy := y0 + t * fh + 0.03
			b.add_box(off + Vector3(lane_c, sy, z),
					Vector3(LANE_W - 0.06, 0.06, run / float(steps) + 0.02),
					FLOOR_COLOR)
	# Guard rail along the shaft's room-facing (east) side, per storey.
	for lvl in n:
		var ry := lvl * fh + 0.5
		b.add_box(off + Vector3(zx + LANE_W * 2.0 + 0.06, ry,
						(z_n + z_s) * 0.5),
				Vector3(0.09, 1.0, zone.size.y - 2.0 * LAND), RAIL_COLOR, true)


# --- Roof --------------------------------------------------------------------

static func _roof(b: MeshBatcher, off: Vector3, fp: Rect2, style: Dictionary,
		roof_c: Color, wall_c: Color, total_h: float, zone: Rect2,
		has_stairs: bool) -> void:
	var w := fp.size.x
	var d := fp.size.y
	# Parapet ring on top of the perimeter walls (standable edge).
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
		b.add_box(off + r[0], r[1], wall_c.darkened(0.25), true)

	# Bulkhead around the stair shaft exit (roof access hut).
	if has_stairs:
		var bz := zone.grow(0.14)
		var bh_h := 2.1
		var wy := total_h + bh_h * 0.5
		var walls := [
			[Vector3(bz.get_center().x, wy, bz.position.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.get_center().x, wy, bz.end.y),
					Vector3(bz.size.x, bh_h, 0.22)],
			[Vector3(bz.position.x, wy, bz.get_center().y),
					Vector3(0.22, bh_h, bz.size.y)],
		]
		for wl: Array in walls:
			b.add_box(off + wl[0], wl[1], wall_c.darkened(0.15), true)
		# East wall with doorway gap + header.
		var ex := bz.end.x
		var cz := bz.get_center().y
		var gap := 1.0
		var seg := (bz.size.y - gap) * 0.5
		for s in 2:
			var zz := bz.position.y + seg * 0.5 if s == 0 else bz.end.y - seg * 0.5
			b.add_box(off + Vector3(ex, wy, zz), Vector3(0.22, bh_h, seg),
					wall_c.darkened(0.15), true)
		b.add_box(off + Vector3(ex, total_h + bh_h - 0.25, cz),
				Vector3(0.22, 0.5, gap), wall_c.darkened(0.15))
		b.add_box(off + Vector3(bz.get_center().x, total_h + bh_h + 0.09, cz),
				Vector3(bz.size.x + 0.3, 0.18, bz.size.y + 0.3),
				ROOF_COLORS[0], true)

	if style.get("attic", false):
		_pitched_shell(b, off, w, d, total_h, roof_c, style)
	else:
		# Flat roof variant: standing seam panels hint.
		b.add_box(off + Vector3(w * 0.5, total_h + 0.06, d * 0.5),
				Vector3(w - 0.7, 0.12, d - 0.7), roof_c)


static func _pitched_shell(b: MeshBatcher, off: Vector3, w: float, d: float,
		total_h: float, roof_c: Color, style: Dictionary) -> void:
	var eave := 0.28
	var half_run := d * 0.5 + eave
	var rise := minf(2.4, d * 0.42)
	var ang := atan2(rise, half_run)
	var slope_len := sqrt(half_run * half_run + rise * rise)
	var cy := total_h + rise * 0.5
	# North slope: high at ridge (z = d/2), low at north eave (z < 0).
	var basis_n := Basis(Vector3.RIGHT, ang)
	b.add_box_rotated(
			off + Vector3(w * 0.5, cy, d * 0.25 - eave * 0.5 + 0.0),
			Vector3(w + 0.55, 0.18, slope_len), basis_n, roof_c)
	# South slope mirrors.
	var basis_s := Basis(Vector3.RIGHT, -ang)
	b.add_box_rotated(
			off + Vector3(w * 0.5, cy, d * 0.75 + eave * 0.5),
			Vector3(w + 0.55, 0.18, slope_len), basis_s, roof_c)

	# Dormer(s) punching through the south slope.
	if style.get("balcony", false):
		return   # stylistic variety: some roofs stay plain
	var dz := d * 0.78
	var dx := w * 0.32
	b.add_box(off + Vector3(dx, total_h + rise * 0.45, dz),
			Vector3(1.1, 1.1, 1.0), PLINTH_COLOR)
	b.add_box(off + Vector3(dx, total_h + rise * 0.45 + 0.61, dz + 0.1),
			Vector3(1.3, 0.12, 1.2), roof_c)
	b.add_box(off + Vector3(dx, total_h + rise * 0.45, dz + 0.48),
			Vector3(0.7, 0.8, 0.12), WINDOW_COLOR)
	# Chimney on the ridge (seeded by style for stable placement).
	var rng_pos := WorldSeed.rng_for("chimney",
			[int(style["wall"]), int(style["roof"]), int(round(d * 10))])
	var ch_x := lerpf(w * 0.25, w * 0.75, rng_pos.randf())
	b.add_box(off + Vector3(ch_x, total_h + rise * 0.55 + 0.75, d * 0.5),
			Vector3(0.65, 1.5, 0.65), PLINTH_COLOR.darkened(0.2), true)
