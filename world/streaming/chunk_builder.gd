class_name ChunkBuilder
extends RefCounted
## Materializes ONE chunk of the deterministic city plan into batched
## geometry. This is the MATERIAL layer's worker: it never makes random
## choices - every scatter roll flows from WorldSeed with the chunk coords
## mixed in, so a chunk always builds identically no matter when it loads.
##
## BUILD OWNERSHIP: a building is emitted only by the chunk containing its
## footprint CENTER. Buildings may visually span chunk borders, but their
## whole node subtree lives under one owner, so streaming can never duplicate
## or tear them (the owning chunk stays resident while neighbors do).
##
## Cross-chunk continuity trick: road dashes / lamp posts / curbs are anchored
## to GLOBAL grid steps (multiples of fixed meters), never to chunk-local
## offsets - so adjacent chunks continue each other's decoration exactly.

const GROUND_COLOR := Color("4c4a44")
const ASPHALT := Color("3a3d40")
const ASPHALT_AVENUE := Color("45484c")
const DASH_COLOR := Color("b9ae82")
const SIDEWALK_HISTORIC := Color("a29a8b")
const SIDEWALK_INNER := Color("98948a")
const PLAZA_PAVE := Color("b3ab97")
const GRASS := Color("55693f")
const TRUNK_COLOR := Color("4a3826")
const CANOPY_COLOR := Color("3f5c30")
const FOUNTAIN_RIM := Color("8d8577")
const FOUNTAIN_WATER := Color("3e5e63")
const STALL_COLORS := [
	Color("8c3a30"), Color("3f5e6b"), Color("6b6f36"), Color("7c4a63"),
]

const CAR_COLORS := [
	Color("6d2222"), Color("2c3e50"), Color("7a7a72"),
	Color("5c5648"), Color("274232"), Color("803c20"),
]
const DEBRIS_COLORS := [
	Color("7a4a35"), Color("6f6b60"), Color("57544c"), Color("4d463c"),
]

const DASH_STEP := 7.0
const LAMP_STEP := 22.0


## Emits everything for `coord` into `b`. Deterministic and side-effect free.
static func fill_batcher(b: MeshBatcher, plan: CityPlan, coord: Vector2i) -> void:
	var rect := WorldSeed.chunk_rect(coord)
	_ground(b, plan, coord)
	_roads(b, plan, rect)
	for cell in plan.cells_in_rect(rect):
		var block := plan.cell_block(cell)
		if not (block["rect"] as Rect2).intersects(rect):
			continue
		match block["kind"]:
			&"built":
				_pavement(b, block["rect"], rect, SIDEWALK_HISTORIC \
						if block["district"] == CityPlan.DISTRICT_HISTORIC \
						else SIDEWALK_INNER)
			&"plaza":
				_plaza(b, plan, block, rect, coord)
			_:
				_park(b, plan, block, rect, coord)
	for spec in _owned_buildings(plan, rect, coord):
		BuildingBuilder.build(b, spec)
	_scatter_props(b, plan, rect, coord)


## Builds the chunk node under `parent` and returns generation stats.
static func build(parent: Node3D, plan: CityPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var b := MeshBatcher.new()
	fill_batcher(b, plan, coord)

	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]
	parent.add_child(chunk)
	var stats := b.flush_into(chunk)
	stats["boxes"] = b.box_count()
	stats["gen_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return stats


## Buildings whose footprint center lies inside `rect` AND owned by this chunk.
static func _owned_buildings(plan: CityPlan, rect: Rect2,
		coord: Vector2i) -> Array:
	var out: Array = []
	for spec in plan.buildings_in_rect(rect):
		var center: Vector2 = (spec["rect"] as Rect2).get_center()
		if WorldSeed.chunk_coord(center.x, center.y) == coord:
			out.append(spec)
	return out


# --- Ground ------------------------------------------------------------------

static func _ground(b: MeshBatcher, plan: CityPlan, coord: Vector2i) -> void:
	var s := float(WorldSeed.CHUNK_SIZE)
	# Subtle per-chunk tone variation keeps large surfaces from reading flat.
	var tint := 0.94 + 0.06 * WorldSeed.unit_float("ground", [coord.x, coord.y])
	b.add_box(Vector3((coord.x + 0.5) * s, -0.25, (coord.y + 0.5) * s),
			Vector3(s, 0.5, s), GROUND_COLOR * tint, true)


# --- Roads -------------------------------------------------------------------

static func _roads(b: MeshBatcher, plan: CityPlan, rect: Rect2) -> void:
	for axis in 2:
		var along_min := rect.position.y if axis == 0 else rect.position.x
		var along_max := rect.end.y if axis == 0 else rect.end.x
		for i in plan.lines_in_range(axis, rect.position.x if axis == 0
				else rect.position.y, rect.end.x if axis == 0 else rect.end.y):
			var center := plan.line_pos(axis, i)
			var half_w := plan.line_half_width(axis, i)
			var strip := Rect2(
					Vector2(center - half_w, along_min) if axis == 0
					else Vector2(along_min, center - half_w),
					Vector2(half_w * 2.0, along_max - along_min) if axis == 0
					else Vector2(along_max - along_min, half_w * 2.0))
			var clipped := strip.intersection(rect)
			if clipped.size.x <= 0.01 or clipped.size.y <= 0.01:
				continue
			var avenue := plan.is_avenue(axis, i)
			b.add_box(Vector3(clipped.get_center().x, 0.04, clipped.get_center().y),
					Vector3(clipped.size.x, 0.08, clipped.size.y),
					ASPHALT_AVENUE if avenue else ASPHALT)
			if avenue:
				_center_dashes(b, axis, center, clipped)


## Center-line dashes anchored to global DASH_STEP grid -> seam-free.
static func _center_dashes(b: MeshBatcher, axis: int, center: float,
		clipped: Rect2) -> void:
	var from_k := ceili(minf(clipped.position.x, clipped.position.y) / DASH_STEP)
	var to_k := floori(maxf(clipped.end.x, clipped.end.y) / DASH_STEP)
	for k in range(from_k, to_k + 1):
		var p := k * DASH_STEP + 1.75   # offset so junctions stay clear-ish
		var pos := Vector3(p, 0.09, center) if axis == 0 \
				else Vector3(center, 0.09, p)
		var size := Vector3(2.6, 0.02, 0.34) if axis == 0 \
				else Vector3(0.34, 0.02, 2.6)
		b.add_box(pos, size, DASH_COLOR)


# --- Blocks ------------------------------------------------------------------

static func _pavement(b: MeshBatcher, block_rect: Rect2, chunk_rect: Rect2,
		color: Color) -> void:
	var r := block_rect.intersection(chunk_rect)
	if r.size.x <= 0.01 or r.size.y <= 0.01:
		return
	b.add_box(Vector3(r.get_center().x, 0.03, r.get_center().y),
			Vector3(r.size.x, 0.06, r.size.y), color)


static func _plaza(b: MeshBatcher, plan: CityPlan, block: Dictionary,
		chunk_rect: Rect2, coord: Vector2i) -> void:
	# The paved square is the block INTERIOR between the perimeter buildings
	# (a European square is framed by building fronts, not an open field).
	# Deep insets on large blocks keep squares at walkable, intimate scale.
	var br: Rect2 = block["rect"]
	var inset := maxf(15.0, (minf(br.size.x, br.size.y) - 56.0) * 0.5)
	var interior: Rect2 = br.grow(-inset)
	if interior.size.x > 8.0 and interior.size.y > 8.0:
		_pavement(b, interior, chunk_rect, PLAZA_PAVE)
	var center: Vector2 = interior.get_center()
	if WorldSeed.chunk_coord(center.x, center.y) != coord:
		return
	if interior.size.x < 20.0 or interior.size.y < 20.0:
		return
	# Octagonal fountain basin at square center.
	for i in 8:
		var ang := TAU * float(i) / 8.0 + TAU / 16.0
		var dir := Vector2(cos(ang), sin(ang))
		# Rotate 90 deg further so each segment's long axis runs TANGENT to
		# the ring, not radially outward through it.
		var basis := Basis(Vector3.UP, -ang - TAU * 0.25)
		b.add_box_rotated(
				Vector3(center.x + dir.x * 2.3, 0.28, center.y + dir.y * 2.3),
				Vector3(1.95, 0.56, 0.42), basis, FOUNTAIN_RIM, true)
	b.add_box(Vector3(center.x, 0.16, center.y), Vector3(4.0, 0.32, 4.0),
			FOUNTAIN_WATER)
	b.add_box(Vector3(center.x, 0.62, center.y), Vector3(0.9, 0.92, 0.9),
			FOUNTAIN_RIM, true)
	# Market stalls in the four quadrants (abandoned market area).
	var rng := WorldSeed.rng_for("market", [coord.x, coord.y])
	var stall_count := rng.randi_range(3, 6)
	var half := Vector2(minf(14.0, interior.size.x * 0.32),
			minf(14.0, interior.size.y * 0.32))
	for i in stall_count:
		var qx := -1.0 if i % 2 == 0 else 1.0
		var qy := -1.0 if (i >> 1) % 2 == 0 else 1.0
		var p := center + Vector2(qx * rng.randf_range(6.5, half.x),
				qy * rng.randf_range(6.5, half.y))
		if not interior.grow(-1.5).has_point(p):
			continue
		if p.distance_to(center) < 7.0:
			continue
		_market_stall(b, p, rng)


static func _market_stall(b: MeshBatcher, p: Vector2,
		rng: RandomNumberGenerator) -> void:
	var yaw := PI * 0.5 * float(rng.randi_range(0, 1)) \
			+ rng.randf_range(-0.08, 0.08)
	var basis := Basis(Vector3.UP, -yaw)
	var canopy_c: Color = STALL_COLORS[rng.randi_range(0, STALL_COLORS.size() - 1)]
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var off := basis * Vector3(corner.x * 1.15, 0, corner.y * 1.05)
		b.add_box(Vector3(p.x + off.x, 1.1, p.y + off.z),
				Vector3(0.12, 2.2, 0.12), Color("5c5148"), true)
	b.add_box_rotated(Vector3(p.x, 2.28, p.y), Vector3(2.7, 0.16, 2.5),
			basis, canopy_c)
	b.add_box_rotated(Vector3(p.x, 0.45, p.y), Vector3(2.3, 0.9, 1.0),
			basis, Color("6b5a41"), true)
	# Scattered wares under the canopy.
	for j in rng.randi_range(1, 3):
		var off := basis * Vector3(rng.randf_range(-0.9, 0.9), 0,
				rng.randf_range(-0.35, 0.35))
		b.add_box(Vector3(p.x + off.x, 1.02, p.y + off.z),
				Vector3(rng.randf_range(0.25, 0.5), rng.randf_range(0.15, 0.3),
						rng.randf_range(0.25, 0.5)),
				Color("8c7b5a").lightened(rng.randf() * 0.25))


static func _park(b: MeshBatcher, plan: CityPlan, block: Dictionary,
		chunk_rect: Rect2, coord: Vector2i) -> void:
	_pavement(b, block["rect"], chunk_rect, GRASS)
	var rng := WorldSeed.rng_for("park_trees",
			[int(WorldSeed.combine([block["id"].hash()]))])
	var br: Rect2 = block["rect"]
	var count := 4 + int(rng.randf() * 5.0)
	for i in count:
		var p := Vector2(
				rng.randf_range(br.position.x + 2.5, br.end.x - 2.5),
				rng.randf_range(br.position.y + 2.5, br.end.y - 2.5))
		if WorldSeed.chunk_coord(p.x, p.y) != coord:
			continue
		var h := rng.randf_range(1.9, 2.6)
		b.add_box(Vector3(p.x, h * 0.5, p.y), Vector3(0.42, h, 0.42),
				TRUNK_COLOR, true)
		b.add_box(Vector3(p.x, h + 0.7, p.y),
				Vector3(rng.randf_range(1.9, 2.6), 1.6,
						rng.randf_range(1.9, 2.6)), CANOPY_COLOR)


# --- Props / apocalypse decoration pass v0 ------------------------------------

static func _scatter_props(b: MeshBatcher, plan: CityPlan, rect: Rect2,
		coord: Vector2i) -> void:
	var rng := WorldSeed.rng_for("props", [coord.x, coord.y])

	# Wrecked cars parked along street edges.
	var car_count := rng.randi_range(0, 3)
	for i in car_count:
		var axis := 0 if rng.randf() < 0.5 else 1
		var perp_min := rect.position.x if axis == 0 else rect.position.y
		var perp_max := rect.end.x if axis == 0 else rect.end.y
		var lines := plan.lines_in_range(axis, perp_min, perp_max)
		if lines.is_empty():
			continue
		var li: int = lines[rng.randi_range(0, lines.size() - 1)]
		var center := plan.line_pos(axis, li)
		var lateral := (plan.line_half_width(axis, li) - 1.4) \
				* (1.0 if rng.randf() < 0.5 else -1.0)
		var along_lo := rect.position.y if axis == 0 else rect.position.x
		var along_hi := rect.end.y if axis == 0 else rect.end.x
		var t := rng.randf_range(along_lo + 4.0, maxf(along_lo + 4.1, along_hi - 4.0))
		var p := Vector2(center + lateral, t) if axis == 0 \
				else Vector2(t, center + lateral)
		if _inside_any_building(plan, p):
			continue
		_car(b, p, rng, CAR_COLORS[rng.randi_range(0, CAR_COLORS.size() - 1)])

	# Debris piles.
	for i in rng.randi_range(4, 10):
		var p := Vector2(rng.randf_range(rect.position.x, rect.end.x),
				rng.randf_range(rect.position.y, rect.end.y))
		if _inside_any_building(plan, p):
			continue
		var base_c: Color = DEBRIS_COLORS[rng.randi_range(0, DEBRIS_COLORS.size() - 1)]
		for j in rng.randi_range(2, 4):
			var off := Vector2(rng.randf_range(-0.9, 0.9),
					rng.randf_range(-0.9, 0.9))
			b.add_box(Vector3(p.x + off.x, rng.randf_range(0.12, 0.3),
					p.y + off.y),
					Vector3(rng.randf_range(0.4, 1.1), rng.randf_range(0.2, 0.5),
							rng.randf_range(0.4, 1.1)),
					base_c.lightened(rng.randf() * 0.18))

	# Trash bins / bags near building fronts.
	for i in rng.randi_range(2, 6):
		var specs := plan.buildings_in_rect(rect)
		if specs.is_empty():
			break
		var spec: Dictionary = specs[rng.randi_range(0, specs.size() - 1)]
		var lr: Rect2 = spec["rect"]
		var side := int(spec["door_edge"])
		var p := _front_of(lr, side, rng.randf_range(0.25, 0.75))
		p += Vector2(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2))
		b.add_box(Vector3(p.x, rng.randf_range(0.22, 0.3), p.y),
				Vector3(rng.randf_range(0.5, 0.8), rng.randf_range(0.45, 0.6),
						rng.randf_range(0.5, 0.8)),
				Color("30332e").lightened(rng.randf() * 0.2), true)

	# Street lamps along avenues only (posts now; real lights come later).
	for axis in 2:
		var perp_min := rect.position.x if axis == 0 else rect.position.y
		var perp_max := rect.end.x if axis == 0 else rect.end.y
		var along_min := rect.position.y if axis == 0 else rect.position.x
		var along_max := rect.end.y if axis == 0 else rect.end.x
		for li in plan.lines_in_range(axis, perp_min, perp_max):
			if not plan.is_avenue(axis, li):
				continue
			var center := plan.line_pos(axis, li)
			var from_k := ceili(along_min / LAMP_STEP)
			var to_k := floori(along_max / LAMP_STEP)
			for k in range(from_k, to_k + 1):
				var side_flip := 1.0 if (k % 2 == 0) else -1.0
				var lateral := (plan.line_half_width(axis, li) + 0.8) * side_flip
				var p := Vector2(center + lateral, k * LAMP_STEP) if axis == 0 \
						else Vector2(k * LAMP_STEP, center + lateral)
				_lamp_post(b, p)


static func _car(b: MeshBatcher, p: Vector2, rng: RandomNumberGenerator,
		color: Color) -> void:
	var yaw := rng.randf_range(-0.12, 0.12) + (PI * 0.5 if rng.randf() < 0.5 else 0.0)
	# Cars align across streets: orient perpendicular to nearest street line.
	var basis := Basis(Vector3.UP, yaw)
	b.add_box_rotated(Vector3(p.x, 0.45, p.y), Vector3(1.85, 0.7, 4.2),
			basis, color, true)
	b.add_box_rotated(Vector3(p.x, 1.05, p.y), Vector3(1.65, 0.55, 2.1),
			basis, color.darkened(0.25), true)


static func _lamp_post(b: MeshBatcher, p: Vector2) -> void:
	b.add_box(Vector3(p.x, 2.3, p.y), Vector3(0.16, 4.6, 0.16),
			Color("33363a"), true)
	b.add_box(Vector3(p.x, 4.65, p.y), Vector3(0.5, 0.18, 0.5),
			Color("d8cf9f"))


static func _inside_any_building(plan: CityPlan, p: Vector2) -> bool:
	for spec in plan.buildings_in_rect(Rect2(p - Vector2.ONE, Vector2(2, 2))):
		if (spec["rect"] as Rect2).has_point(p):
			return true
	return false


## Point just outside a footprint's facade midpoint (t in [0,1] along it).
static func _front_of(lr: Rect2, door_edge: int, t: float) -> Vector2:
	match door_edge:
		0: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.position.y - 1.4)
		1: return Vector2(lr.end.x + 1.4, lerpf(lr.position.y, lr.end.y, t))
		2: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.end.y + 1.4)
		_: return Vector2(lr.position.x - 1.4, lerpf(lr.position.y, lr.end.y, t))
