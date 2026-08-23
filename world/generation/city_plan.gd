class_name CityPlan
extends RefCounted
## Deterministic macro plan of the whole city, derived ONLY from the world
## seed. This is the PLAN LAYER: pure data, no scene tree access, no RNG use
## outside WorldSeed helpers, and every query is a pure function of world
## coordinates - so chunk generation order can never influence the layout.
##
## Hierarchy:
##   district noise (128 m cells)  ->  street grid (jittered cumulative lines)
##   -> urban blocks (cells between grid lines) -> plaza/park carving
##   -> perimeter parcels per built block -> BuildingSpec dicts (stable IDs)
##
## All lazily-computed caches are keyed by global indices/coords only.
##
## BuildingSpec dictionary shape:
##   id:        String   stable global id "b_<cell>_<edge><k>"
##   rect:      Rect2    XZ footprint (world coords)
##   floors:    int      storeys above ground
##   floor_h:   float    storey height in meters
##   door_edge: int      0=N 1=E 2=S 3=W (street-facing entrance)
##   style:     Dictionary { wall:int palette idx, roof:int, balcony:bool,
##                            attic:bool }

const DISTRICT_CELL := 128

const GRID_BASE_SPACING := 88          # mean distance between street lines
const GRID_JITTER := 18                 # +/- meters per line offset
const AVENUE_CHANCE := 0.18             # a grid line becomes a wide avenue
const NARROW_HALF := Vector2(4.2, 5.6)  # min/max half-width of normal streets
const AVENUE_HALF := Vector2(6.6, 8.4)

const DISTRICT_HISTORIC := &"historic"
const DISTRICT_INNER := &"inner_city"
const DISTRICT_OUTER := &"outer"

# Palette indices resolved by ChunkBuilder into colors.
const WALL_PALETTES := 8
const ROOF_PALETTES := 5


var _line_pos_cache := [{}, {}]        # [axis x=0/z=1][index] -> float
var _cell_cache := {}                  # Vector2i cell index -> block dict
var _building_cache := {}              # Vector2i cell index -> Array[BuildingSpec]


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

## Perimeter row subdivision: attached lots along each block edge with a
## shared courtyard in the middle - the classic Prague block morphology.
func _buildings_for_cell(block: Dictionary, cell: Vector2i) -> Array:
	if _building_cache.has(cell):
		return _building_cache[cell]
	var rng := WorldSeed.rng_for("parcels", [cell.x, cell.y])
	var rect: Rect2 = block["rect"]
	var result: Array = []
	var depth_range := Vector2(9.0, 13.0)
	if block["district"] == DISTRICT_HISTORIC:
		depth_range = Vector2(10.0, 14.0)

	for edge in 4:
		result.append_array(_lots_for_edge(edge, rect, depth_range, rng, cell))

	# Rear wing across the courtyard of large ordinary blocks so their cores
	# are not hollow voids. Plazas keep their interior open.
	if block["kind"] == &"built" and rect.size.x > 54.0 and rect.size.y > 48.0:
		var wing := Rect2(
				rect.position.x + rng.randf_range(15.0, 20.0),
				rect.position.y + 19.0,
				maxf(12.0, rect.size.x - 36.0 - rng.randf_range(0.0, 12.0)),
				rng.randf_range(8.5, 11.5))
		var clear := true
		for spec in result:
			if (spec["rect"] as Rect2).intersects(wing):
				clear = false
				break
		if clear:
			var spec := _make_spec(wing, 0, cell, 90 + result.size(), rng, false)
			spec["id"] += "_W"
			spec["floors"] = clampi(int(spec["floors"]), 2, 4)
			result.append(spec)
	_building_cache[cell] = result
	return result


func _lots_for_edge(edge: int, block_rect: Rect2, depth_range: Vector2,
		rng: RandomNumberGenerator, cell: Vector2i) -> Array:
	var lots: Array = []
	var frontage_start := 0.0
	var frontage_end := 0.0
	match edge:
		0: frontage_end = block_rect.size.x   # north edge, runs +X
		1: frontage_end = block_rect.size.y   # east edge, runs +Z
		2: frontage_end = block_rect.size.x   # south edge, runs +X
		3: frontage_end = block_rect.size.y   # west edge, runs +Z

	var k := 0
	while frontage_start < frontage_end - 4.0:
		var width := clampf(rng.randf_range(6.5, 11.5), 5.0, frontage_end - frontage_start)
		var depth := rng.randf_range(depth_range.x, depth_range.y)
		var t0 := frontage_start
		var t1 := frontage_start + width
		var lot := _lot_rect(edge, block_rect, t0, t1, depth)
		if lot.size.x >= 4.5 and lot.size.y >= 4.5:
			lots.append(_make_spec(lot, edge, cell, k, rng, frontage_start == 0.0))
		frontage_start = t1
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
	# DESIGN RULE: no unreachable storeys. A lot too shallow to host the
	# switchback stairwell stays single-storey (annex / workshop row).
	if lot.size.y < 8.2:
		floors = 1
	return {
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
	}


## All building specs whose footprint intersects `rect`. Shared specs come from
## the same caches everywhere, so two neighboring chunks agree on every wall.
func buildings_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	for cell in cells_in_rect(rect):
		var block := cell_block(cell)
		if block["kind"] != &"built":
			continue
		for spec: Dictionary in block["buildings"]:
			if (spec["rect"] as Rect2).intersects(rect):
				out.append(spec)
	return out


## Deterministic spawn anchor: center of the first historic plaza near the
## origin, else the nearest street intersection to origin. Used to place the
## player when spawning into the streamed city.
func find_spawn_point() -> Vector2:
	var best_plaza := Vector2.ZERO
	var best_d := INF
	for cell in cells_in_rect(Rect2(-260, -260, 520, 520)):
		var block := cell_block(cell)
		if block["kind"] == &"plaza":
			var d: float = (block["rect"] as Rect2).get_center().length()
			if d < best_d:
				best_d = d
				best_plaza = block["rect"].get_center()
	if best_d < INF:
		# Offset from the exact center: the fountain occupies it.
		return best_plaza + Vector2(5.8, 0)
	return Vector2(line_pos(0, 0), line_pos(1, 0))
