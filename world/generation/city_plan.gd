class_name CityPlan
extends RefCounted
## Deterministic macro plan of the whole city, derived ONLY from the world
## seed. This is the PLAN LAYER: pure data, no scene tree access, no RNG use
## outside WorldSeed helpers, and every query is a pure function of world
## coordinates - so chunk generation order can never influence the layout.
##
## Hierarchy:
##   district noise (128 m cells)  ->  street grid (bounded-jitter lines)
##   -> urban blocks (cells between grid lines) -> plaza/park carving
##   -> perimeter parcels per built block -> BuildingSpec dicts (stable IDs)
##
## PARCEL CORRECTNESS: lots are generated with EXPLICIT CORNER OWNERSHIP -
## four corner lots are placed first, then the four edge rows subdivide only
## the frontage BETWEEN them. Two buildings can therefore never claim the
## same corner volume. validate_buildings() enforces zero overlaps and is
## exercised by --citytest across many blocks and seeds.
##
## BuildingSpec dictionary shape:
##   id:        String   stable global id "b_<cell>_<edge><k>"
##   rect:      Rect2    XZ footprint (world coords)
##   floors:    int      storeys above ground
##   floor_h:   float    storey height in meters
##   door_edge: int      0=N 1=E 2=S 3=W (street-facing entrance)
##   style:     Dictionary { wall:int palette idx, roof:int, balcony:bool,
##                            attic:bool }
##   doors:     Array    door manifests (see _door_manifest)

const DISTRICT_CELL := 128

const GRID_BASE_SPACING := 88          # mean distance between street lines
const GRID_JITTER := 18                 # +/- meters per line offset
const AVENUE_CHANCE := 0.18             # a grid line becomes a wide avenue
const NARROW_HALF := Vector2(4.2, 5.6)  # min/max half-width of normal streets
const AVENUE_HALF := Vector2(6.6, 8.4)

# Stair feasibility (must match BuildingBuilder geometry).

const DISTRICT_HISTORIC := &"historic"
const DISTRICT_INNER := &"inner_city"
const DISTRICT_OUTER := &"outer"

# Palette indices resolved by ChunkBuilder into colors.
const WALL_PALETTES := 8
const ROOF_PALETTES := 5

const DOOR_W := 1.5


var seed_used: int = WorldSeed.get_world_seed()
var _line_pos_cache := [{}, {}]        # [axis x=0/z=1][index] -> float
var _cell_cache := {}                  # Vector2i cell index -> block dict
var _building_cache := {}              # Vector2i cell index -> Array[BuildingSpec]
# NOTE: instances are NOT thread-safe (plain Dictionary caches). Worker
# threads must generate chunks against their own private CityPlan copy -
# every query is a pure function of the world seed, so results are identical.


# --- Districts ---------------------------------------------------------------

## District archetype for a district-grid cell. Historic core is forced around
## the world origin (the city center concept); farther cells blend by noise.
func district_at_point(p: Vector2) -> StringName:
	var dist := p.length()
	if dist < 190.0:
		return DISTRICT_HISTORIC
	var roll := WorldSeed.unit_float("district", [_dc(p)])
	var inner_reach := 420.0 + 140.0 * WorldSeed.unit_float("dreach", [_dc(p)])
	if dist < inner_reach:
		return DISTRICT_INNER if roll < 0.72 else DISTRICT_HISTORIC
	return DISTRICT_OUTER if roll < 0.55 else DISTRICT_INNER


func _dc(p: Vector2) -> int:
	var cell := Vector2i((p / float(DISTRICT_CELL)).floor())
	return WorldSeed.combine([cell.x, cell.y])


# --- Street grid -------------------------------------------------------------

## World position of grid line `i` on axis (0 = vertical lines varying X,
## 1 = horizontal lines varying Z). Each line carries its own BOUNDED offset
## (+/- GRID_JITTER around i * GRID_BASE_SPACING): no cumulative drift, so
## cheap index bracketing in lines_in_range stays exact at any distance and
## every caller agrees on every line regardless of query order.
func line_pos(axis: int, i: int) -> float:
	var cache: Dictionary = _line_pos_cache[axis]
	if cache.has(i):
		return cache[i]
	var offset := WorldSeed.unit_float("gap%d" % axis, [i]) * 2.0 - 1.0
	var pos := i * float(GRID_BASE_SPACING) + offset * float(GRID_JITTER)
	cache[i] = pos
	return pos


## Half-width of the street along grid line (axis, i).
func line_half_width(axis: int, i: int) -> float:
	var avenue := WorldSeed.unit_float("avenue%d" % axis, [i]) < AVENUE_CHANCE
	var r := WorldSeed.unit_float("width%d" % axis, [i])
	return lerpf(AVENUE_HALF.x, AVENUE_HALF.y, r) if avenue \
			else lerpf(NARROW_HALF.x, NARROW_HALF.y, r)


func is_avenue(axis: int, i: int) -> bool:
	return WorldSeed.unit_float("avenue%d" % axis, [i]) < AVENUE_CHANCE


## Grid line indices whose street strip overlaps [from,to[ on that axis.
## Exact because line offsets are bounded by GRID_JITTER (< half spacing).
func lines_in_range(axis: int, from_p: float, to_p: float) -> Array[int]:
	var lo := floori((from_p - GRID_JITTER) / float(GRID_BASE_SPACING)) - 1
	var hi := ceili((to_p + GRID_JITTER) / float(GRID_BASE_SPACING)) + 1
	var out: Array[int] = []
	for i in range(lo, hi + 1):
		var half := line_half_width(axis, i)
		if line_pos(axis, i) + half >= from_p and line_pos(axis, i) - half <= to_p:
			out.append(i)
	return out


## Deterministic walkable ROAD point within an annulus around `near`.
## Tries candidate directions, snaps to the nearest street strip, then rejects
## points that fall inside building footprints or plaza interiors. Returns
## Vector2.INF when nothing valid was found in the tries budget.
func sample_road_position(near: Vector2, min_distance: float,
		max_distance: float, rng: RandomNumberGenerator,
		tries := 24) -> Vector2:
	for t in tries:
		var ang := rng.randf() * TAU
		var dist := lerpf(min_distance, max_distance, rng.randf())
		var p := near + Vector2(cos(ang), sin(ang)) * dist
		var snapped := _snap_to_road(p)
		if snapped == Vector2.INF:
			continue
		if _inside_obstacle(snapped):
			continue
		return snapped
	return Vector2.INF


## Nearest point on any street strip within ~1.2 m of p's strip, else INF.
func _snap_to_road(p: Vector2) -> Vector2:
	var best := Vector2.INF
	for axis in 2:
		var perp := p.x if axis == 0 else p.y
		var along := p.y if axis == 0 else p.x
		var lo := floori((perp - GRID_JITTER) / float(GRID_BASE_SPACING))
		for i in range(lo, lo + 3):
			var center := line_pos(axis, i)
			var half := line_half_width(axis, i)
			if absf(perp - center) > half - 1.0:
				continue
			# Keep out of junction middles? Junctions are fine - open asphalt.
			var q := Vector2(center, along) if axis == 0 else Vector2(along, center)
			if best == Vector2.INF or q.distance_to(p) < best.distance_to(p):
				best = q
	return best


func _inside_obstacle(p: Vector2) -> bool:
	for spec in buildings_in_rect(Rect2(p - Vector2(2, 2), Vector2(4, 4))):
		if (spec["rect"] as Rect2).has_point(p):
			return true
	# Plaza interiors keep zombies off the fountain square.
	for cell in cells_in_rect(Rect2(p - Vector2(2, 2), Vector2(4, 4))):
		var block := cell_block(cell)
		if block["kind"] != &"plaza":
			continue
		var br: Rect2 = block["rect"]
		var inset := maxf(15.0, (minf(br.size.x, br.size.y) - 56.0) * 0.5)
		if br.grow(-inset).has_point(p):
			return true
	return false


# --- Urban blocks -------------------------------------------------------------

## The built block occupying the cell between grid lines i..i+1 / j..j+1.
## Shape: { id:String, rect:Rect2, kind:&"built"/&"plaza"/&"park",
##          district:StringName, buildings:Array }
func cell_block(cell: Vector2i) -> Dictionary:
	if _cell_cache.has(cell):
		return _cell_cache[cell]

	var x0 := line_pos(0, cell.x)
	var x1 := line_pos(0, cell.x + 1)
	var z0 := line_pos(1, cell.y)
	var z1 := line_pos(1, cell.y + 1)
	# Inset by the streets bounding the cell on every side.
	var rect := Rect2(
			Vector2(x0 + line_half_width(0, cell.x),
					z0 + line_half_width(1, cell.y)),
			Vector2(x1 - x0 - line_half_width(0, cell.x) - line_half_width(0, cell.x + 1),
					z1 - z0 - line_half_width(1, cell.y) - line_half_width(1, cell.y + 1)))

	var center := rect.get_center()
	var district := district_at_point(center)
	var kind := &"built"
	var roll := WorldSeed.unit_float("blockkind", [cell.x, cell.y])
	if district == DISTRICT_HISTORIC and roll < 0.07:
		kind = &"plaza"
	elif roll < 0.10:
		kind = &"park"

	var block := {
		"id": "blk_%d_%d" % [cell.x, cell.y],
		"rect": rect,
		"kind": kind,
		"district": district,
		"buildings": [],
	}
	# Perimeter rows frame BOTH ordinary blocks AND plazas: a real European
	# square is enclosed by continuous building fronts, not an open field.
	# Park cells stay open. The plaza pavement is the block interior (see
	# ChunkBuilder._plaza); ordinary-block courtyards get rear wings.
	if kind != &"park" and rect.size.x > 26.0 and rect.size.y > 26.0:
		block["buildings"] = _buildings_for_cell(block, cell)

	_cell_cache[cell] = block
	return block


## Cells whose blocks intersect `rect` (plus one-ring margin).
func cells_in_rect(rect: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in range(_cell_lower(rect.position.x), _cell_upper(rect.end.x)):
		for j in range(_cell_lower(rect.position.y), _cell_upper(rect.end.y)):
			out.append(Vector2i(i, j))
	return out


func _cell_lower(v: float) -> int:
	return floori(v / GRID_BASE_SPACING) - 2


func _cell_upper(v: float) -> int:
	return floori(v / GRID_BASE_SPACING) + 2


# --- Parcels / buildings -------------------------------------------------------

## Perimeter subdivision with EXPLICIT CORNER OWNERSHIP:
##   1. four square corner lots are claimed first (classic Prague corner
##      houses), sized by their adjacent edge depths;
##   2. each edge row subdivides ONLY the frontage between its corners;
##   3. large ordinary blocks may add ONE rear wing inside the courtyard.
## Overlapping volumes are impossible by construction; validate_buildings()
## double-checks anyway and --citytest asserts it across hundreds of blocks.
func _buildings_for_cell(block: Dictionary, cell: Vector2i) -> Array:
	if _building_cache.has(cell):
		return _building_cache[cell]
	var rng := WorldSeed.rng_for("parcels", [cell.x, cell.y])
	var br: Rect2 = block["rect"]
	var result: Array = []
	var depth_range := Vector2(9.0, 13.0)
	if block["district"] == DISTRICT_HISTORIC:
		depth_range = Vector2(10.0, 14.0)

	var d_n := rng.randf_range(depth_range.x, depth_range.y)
	var d_e := rng.randf_range(depth_range.x, depth_range.y)
	var d_s := rng.randf_range(depth_range.x, depth_range.y)
	var d_w := rng.randf_range(depth_range.x, depth_range.y)
	# Keep corner squares modest so mid-row lots always retain >= 5 m frontage.
	d_n = minf(d_n, br.size.y - 10.0)
	d_s = minf(d_s, br.size.y - 10.0)
	d_e = minf(d_e, br.size.x - 10.0)
	d_w = minf(d_w, br.size.x - 10.0)
	if d_n < 6.0 or d_e < 6.0 or d_s < 6.0 or d_w < 6.0:
		_building_cache[cell] = result
		return result

	# 1. Corner buildings (edge ids C0..C3; door faces the longer street side).
	var corners := [
		Rect2(br.position.x, br.position.y, d_w, d_n),                       # NW
		Rect2(br.end.x - d_e, br.position.y, d_e, d_n),                      # NE
		Rect2(br.end.x - d_e, br.end.y - d_s, d_e, d_s),                     # SE
		Rect2(br.position.x, br.end.y - d_s, d_w, d_s),                      # SW
	]
	for c in 4:
		var lot: Rect2 = corners[c]
		var edge := 0 if (lot.size.x >= lot.size.y) else 1
		result.append(_make_spec(lot, edge, cell, c, rng, true))

	# 2. Edge rows between corners.
	result.append_array(_lots_for_edge(0, br, d_w, br.size.x - d_e, d_n,
			rng, cell))
	result.append_array(_lots_for_edge(1, br, d_n, br.size.y - d_s, d_e,
			rng, cell))
	result.append_array(_lots_for_edge(2, br, d_w, br.size.x - d_e, d_s,
			rng, cell))
	result.append_array(_lots_for_edge(3, br, d_n, br.size.y - d_s, d_w,
			rng, cell))

	# 3. Rear wing across the courtyard of large ordinary blocks.
	if block["kind"] == &"built" and br.size.x > 54.0 and br.size.y > 48.0:
		var wing := Rect2(
				br.position.x + d_w + rng.randf_range(4.0, 9.0),
				br.position.y + d_n + 5.0,
				maxf(12.0, br.size.x - d_w - d_e - rng.randf_range(8.0, 18.0)),
				rng.randf_range(8.5, 11.5))
		var clear := true
		for spec in result:
			if (spec["rect"] as Rect2).grow(1.5).intersects(wing):
				clear = false
				break
		if clear:
			var spec := _make_spec(wing, 0, cell, 90 + result.size(), rng, false)
			spec["id"] += "_W"
			# Wing annexes only rise if the stairwell genuinely fits.
			if int(spec["floors"]) > 1 and BuildingBuilder.has_stairs_for(
					(spec["rect"] as Rect2).size,
					float(spec["floor_h"]), int(spec["floors"])):
				spec["floors"] = clampi(int(spec["floors"]), 2, 4)
			else:
				spec["floors"] = 1
			result.append(spec)

	if not validate_buildings(result).is_empty():
		push_error("CityPlan: overlapping parcels in block %s - dropping block"
				% block["id"])
		_building_cache[cell] = []
		return []
	_building_cache[cell] = result
	return result


## Frontage row along one edge, subdividing [start_t, end_t] at `depth`.
func _lots_for_edge(edge: int, br: Rect2, start_t: float, end_t: float,
		depth: float, rng: RandomNumberGenerator, cell: Vector2i) -> Array:
	var lots: Array = []
	var frontage_start := start_t
	var k := 0
	while frontage_start < end_t - 4.0:
		var width := clampf(rng.randf_range(6.5, 11.5), 5.0, end_t - frontage_start)
		var lot := _lot_rect(edge, br, frontage_start,
				frontage_start + width, depth)
		if lot.size.x >= 4.5 and lot.size.y >= 4.5:
			lots.append(_make_spec(lot, edge, cell, 10 + k, rng, false))
		frontage_start += width
		k += 1
	return lots


func _lot_rect(edge: int, br: Rect2, t0: float, t1: float, depth: float) -> Rect2:
	match edge:
		0: return Rect2(br.position.x + t0, br.position.y, t1 - t0, depth)
		1: return Rect2(br.end.x - depth, br.position.y + t0, depth, t1 - t0)
		2: return Rect2(br.position.x + t0, br.end.y - depth, t1 - t0, depth)
		_: return Rect2(br.position.x, br.position.y + t0, depth, t1 - t0)


func _make_spec(lot: Rect2, edge: int, cell: Vector2i, k: int,
		rng: RandomNumberGenerator, corner: bool) -> Dictionary:
	var district := district_at_point(lot.get_center())
	var floors_min := 3
	var floors_max := 6 if district == DISTRICT_HISTORIC else 5
	var floors := rng.randi_range(floors_min, floors_max)
	if corner and rng.randf() < 0.35:
		floors = mini(floors + 1, 7)
	var spec := {
		"id": "b_%d_%d_%s%02d" % [cell.x, cell.y, char(78 + edge), k],  # b_x_y_N03
		"rect": lot,
		"floors": floors,
		"floor_h": snappedf(rng.randf_range(2.9, 3.25), 0.05),
		"door_edge": edge,
		"style": {
			"wall": rng.randi_range(0, WALL_PALETTES - 1),
			"roof": rng.randi_range(0, ROOF_PALETTES - 1),
			"balcony": rng.randf() < 0.45,
			"attic": rng.randf() < 0.7,
		},
		"doors": [_door_manifest(spec_id(cell, edge, k), lot, edge)],
	}
	# DESIGN RULE: no unreachable storeys. Stair eligibility lives in ONE
	# place - BuildingBuilder.has_stairs_for - which accounts for floor_h
	# (zone length) and lot width. Lots that fail stay single-storey.
	if floors > 1 and not BuildingBuilder.has_stairs_for(lot.size,
			float(spec["floor_h"]), floors):
		spec["floors"] = 1
	return spec


static func spec_id(cell: Vector2i, edge: int, k: int) -> String:
	return "b_%d_%d_%s%02d" % [cell.x, cell.y, char(78 + edge), k]


## Door manifest derived from footprint + door_edge. Position sits ON the
## facade line at ground level; yaw orients the leaf parallel to the wall.
## Hinge side alternates deterministically with the lot position hash.
static func _door_manifest(building_id: String, lot: Rect2,
		edge: int) -> Dictionary:
	var mid := lot.get_center()
	var yaw := 0.0
	match edge:
		0: mid.y = lot.position.y            # N face: leaf runs along X
		1: yaw = PI * 0.5                    # E face: leaf runs along Z
		2: mid.y = lot.end.y                 # S face
		_: yaw = PI * 0.5                    # W face
	match edge:
		1: mid.x = lot.end.x
		3: mid.x = lot.position.x
	var hinge_left := WorldSeed.unit_float("hinge",
			[WorldSeed.str_hash(building_id)]) < 0.5
	# Swing sign opens the leaf INTO the building given the manifest yaw
	# convention (edges 0/3 rotate negative, 1/2 positive).
	return {
		"id": "%s_door_0" % building_id,
		"building_id": building_id,
		"position": Vector3(mid.x, 0.0, mid.y),
		"yaw": yaw,
		"edge": edge,
		"width": DOOR_W,
		"height": 2.25,
		"hinge": "left" if hinge_left else "right",
		"locked": false,
		"open_angle": 95.0,
		"swing": -1.0 if edge == 0 or edge == 3 else 1.0,
	}


# --- Validation ---------------------------------------------------------------

## Returns a list of parcel errors (overlaps, degenerate footprints).
## Empty list == mutually valid footprints. Shared party-wall contact is
## legal and does not count as overlap (intersection must exceed tolerance).
static func validate_buildings(buildings: Array) -> Array[String]:
	var errors: Array[String] = []
	for i in buildings.size():
		var a: Rect2 = buildings[i]["rect"]
		if a.size.x < 4.0 or a.size.y < 4.0:
			errors.append("invalid tiny building %s" % buildings[i]["id"])
		for j in range(i + 1, buildings.size()):
			var b: Rect2 = buildings[j]["rect"]
			var overlap := a.intersection(b)
			if overlap.size.x > 0.15 and overlap.size.y > 0.15:
				errors.append("%s overlaps %s by %s" % [buildings[i]["id"],
						buildings[j]["id"], overlap.size])
	return errors


## Validate every built/plaza block intersecting `rect`. Used by --citytest.
func validate_area(rect: Rect2) -> Array[String]:
	var errors: Array[String] = []
	for cell in cells_in_rect(rect):
		var block := cell_block(cell)
		if block["kind"] == &"park":
			continue
		errors.append_array(validate_buildings(block["buildings"]))
	return errors


# --- Queries ------------------------------------------------------------------

## All building specs whose footprint intersects `rect`. Shared specs come from
## the same caches everywhere, so two neighboring chunks agree on every wall.
func buildings_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	for cell in cells_in_rect(rect):
		var block := cell_block(cell)
		if block["kind"] == &"park":
			continue
		for spec: Dictionary in block["buildings"]:
			if (spec["rect"] as Rect2).intersects(rect):
				out.append(spec)
	return out


## Deterministic spawn anchor: plaza-adjacent street point near the origin
## (buildings visible immediately), else the nearest street intersection.
func find_spawn_point() -> Vector2:
	var best_plaza := Rect2()
	var best_d := INF
	for cell in cells_in_rect(Rect2(-260, -260, 520, 520)):
		var block := cell_block(cell)
		if block["kind"] == &"plaza":
			var d: float = (block["rect"] as Rect2).get_center().length()
			if d < best_d:
				best_d = d
				best_plaza = block["rect"]
	if best_d < INF:
		# Stand on the street beside the square: buildings in view, fountain
		# and stalls across the way.
		return best_plaza.get_center() \
				+ Vector2(best_plaza.size.x * 0.5 + 3.0, 0.0)
	return Vector2(line_pos(0, 0), line_pos(1, 0))
