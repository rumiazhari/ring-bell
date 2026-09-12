class_name FloorPlanPlanner
extends RefCounted
## Archetype-driven floor planner. Replaces "subdivide the leftover space and
## name the pieces afterwards" with:
##
##   building type -> floor role -> archetype -> circulation core -> room
##   programme by relationship -> fit to footprint -> validate -> emit
##
## Output contract (all geometry in the InteriorPlan *plan frame*, i.e. the same
## frame `Buildings`/`ChunkBuilder` already consume):
##
##   {
##     "floor_i": int, "archetype": String,
##     "rooms":       [{id, kind, rect, entry, service, circulation}],
##     "boundaries":  [{a, b, door, wall:Rect2, opening:Rect2}],
##     "circulation": [Rect2],      # plan frame, becomes the clip authority
##     "metrics":     {...}
##   }
##
## `boundaries` is deliberately abstract: InteriorPlan turns each one into a
## partition plus (optionally) a door leaf, so wall/door leaf construction stays
## in exactly one place and this file stays pure geometry. Nothing here touches
## BuildingBuilder, so there is no cyclic class_name dependency.

## Partition half-thickness / door aperture. These mirror InteriorPlan's own
## constants; the planner only describes boundaries, InteriorPlan builds them.
const WALL_T := 0.18
const OPEN_W := 0.95

## Smallest inner plate the archetype system will speak for. Below this the
## caller keeps the legacy manifest (sheds, kiosks, annexes).
const MIN_INNER := 4.2
## Shortest shared edge that can hold a 0.95 aperture plus jambs.
const DOOR_EDGE_MIN := 1.25
## Two circulation cells are the same circulation system: the edge only
## has to carry the aperture (0.95) plus slim jambs. Sealing a 1.19 m
## landing-to-corridor edge splits the floor's circulation in two, and
## the reachability gate rightly rejects that plan.
const PASSAGE_EDGE_MIN := 1.15
## Shared edge must be at least this long to count as a room boundary at all.
const EDGE_MIN := 0.55
const SEALED := Rect2(0.0, 0.0, 0.0, 0.0)

## Archetypes. `roles` selects by FloorProgram.role_of(); the size gates are
## hard applicability conditions, not scoring hints. Order = preference.
const ARCHETYPES := [
	{  # 1 - narrow Prague house: one-room-wide, deep, rooms stacked front->back
		"id": "prague_narrow_townhouse", "roles": [&"residential"],
		"max_w": 7.2, "spine_frac": 0.15, "spine_max": 1.15, "front_frac": 0.20,
		"row_depth": 3.6, "max_rows": 4, "front_split": true, "back_split": false,
	},
	{  # 2 - classic side-spine flat: corridor down one side, rooms off it
		"id": "prague_side_spine_flat", "roles": [&"residential"],
		"spine_frac": 0.16, "spine_max": 1.40, "front_frac": 0.22,
		"row_depth": 4.3, "max_rows": 3, "front_split": true, "back_split": true,
	},
	{  # 3 - deep tenement: two room rows per column, wider spine
		"id": "prague_deep_tenement", "roles": [&"residential"],
		"min_w": 8.6, "min_d": 11.0, "spine_frac": 0.17, "spine_max": 1.50,
		"front_frac": 0.20, "row_depth": 4.6, "max_rows": 3,
		"front_split": true, "back_split": true,
	},
	{  # 4 - tiny flat: no front room, everything doubles off the hall
		"id": "prague_compact_flat", "roles": [&"residential"],
		"max_area": 62.0, "spine_frac": 0.15, "spine_max": 1.10, "front_frac": 0.30,
		"row_depth": 4.0, "max_rows": 2, "front_split": false, "back_split": false,
	},
	{  # 5 - open on two sides: principal room takes the best facade. A courtyard
	   # plot is deep by definition; on a shallow plate this archetype only
	   # produces a street strip too narrow to hang a door on.
		"id": "courtyard_double_front", "roles": [&"residential"],
		"min_open_sides": 2, "min_w": 7.6, "min_d": 7.4,
		"spine_frac": 0.16, "spine_max": 1.30,
		"front_frac": 0.22, "row_depth": 4.2, "max_rows": 3,
		"front_split": true, "back_split": true,
	},
	{  # 6 - shopfront + rear service
		"id": "shopfront_rear_service", "roles": [&"commercial"],
		"spine_frac": 0.16, "spine_max": 1.35, "front_frac": 0.24,
		"row_depth": 4.4, "max_rows": 2, "big_front": true, "back_split": false,
	},
	{  # 7 - tavern: big taproom front, kitchen/store behind
		"id": "tavern_taproom_ground", "roles": [&"commercial"],
		"min_w": 7.0, "spine_frac": 0.16, "spine_max": 1.40, "front_frac": 0.26,
		"row_depth": 4.6, "max_rows": 2, "big_front": true, "back_split": true,
	},
	{  # 8 - office suite off a corridor
		"id": "office_corridor_suite", "roles": [&"civic"],
		"spine_frac": 0.15, "spine_max": 1.40, "front_frac": 0.22,
		"row_depth": 3.8, "max_rows": 4, "front_split": true, "back_split": true,
	},
	{  # 9 - civic reception hall
		"id": "civic_reception_hall", "roles": [&"civic"],
		"spine_frac": 0.16, "spine_max": 1.35, "front_frac": 0.24,
		"row_depth": 4.4, "max_rows": 2, "big_front": true, "back_split": false,
	},
	{  # 10 - workshop hall
		"id": "workshop_hall_ground", "roles": [&"work"],
		"spine_frac": 0.16, "spine_max": 1.40, "row_depth": 4.6, "max_rows": 2,
		"big_front": true, "front_split": true, "back_split": false,
	},
	{  # 11 - warehouse with a loading bay
		"id": "warehouse_loading_ground", "roles": [&"work"],
		"min_w": 7.5, "spine_frac": 0.17, "spine_max": 1.45, "row_depth": 5.0,
		"max_rows": 2, "big_front": true, "front_split": false, "back_split": true,
	},
]

## Kinds that may act as a through-room when a cell has no circulation edge.
## A private room may never be one (no bedroom-as-corridor).
static func _may_relay(kind: StringName) -> bool:
	var spec := FloorProgram.spec_of(kind)
	return not bool(spec.get("private", false)) and not bool(spec.get("service", false)) and not FloorProgram.is_circulation(kind)


## Why the last plan_best() call returned no candidate. Probes and the
## statistical suite read this instead of guessing why a building fell back to
## the legacy generator; empty means the last call succeeded.
static var last_reject: String = ""

## Companion detail for the last _validate() rejection (why the candidate was
## thrown away: outside/overlap/sliver counts, coverage, circulation share...).
static var _last_validate: String = ""


## Public entry. `p` keys (plan frame unless noted):
##   building_id:String, rect:Rect2, door_edge:int, yaw:float, use:String,
##   floor_i:int, floors:int, floor_h:float, seed_used:int,
##   open_by_plan_edge:Array[bool], core:Rect2, entry_box:Rect2
## Returns {} when no archetype produces a valid plan (caller falls back).
static func plan_best(p: Dictionary) -> Dictionary:
	last_reject = ""
	var frame0 := FloorPlanFrame.build(p.duplicate())
	if frame0.size.x < MIN_INNER or frame0.size.y < MIN_INNER:
		last_reject = "inner %.2fx%.2f below MIN_INNER %.2f" % [frame0.size.x, frame0.size.y, MIN_INNER]
		return {}
	var role := FloorProgram.role_of(str(p.get("use", "residential")), int(p.get("floor_i", 0)))
	var candidates: Array = []
	for arch: Dictionary in ARCHETYPES:
		if not (role in arch["roles"]):
			continue
		if candidates.size() >= 3:
			break
		if not _applicable(arch, frame0, p):
			continue
		for mirrored in [false, true]:
			var pp := p.duplicate()
			pp["mirrored"] = mirrored
			var frame := FloorPlanFrame.build(pp)
			var cand := _candidate(frame, arch, pp)
			if cand.is_empty():
				continue
			cand["arch_id"] = arch["id"]
			cand["mirrored"] = mirrored
			candidates.append({"frame": frame, "cand": cand, "arch": arch})
	if candidates.is_empty():
		if last_reject == "":
			last_reject = "no archetype applicable for role=%s (%.1fx%.1f open=%s core=%s)" % [
				role, frame0.size.x, frame0.size.y, str(frame0.face_open), str(frame0.has_core)]
		return {}
	var best: Dictionary = candidates[0]
	var best_score := _score(best["cand"], best["frame"])
	for c: Dictionary in candidates:
		var s := _score(c["cand"], c["frame"])
		if s > best_score:
			best_score = s
			best = c
	return _emit(best["frame"], best["cand"], best["arch"], p)


static func _applicable(arch: Dictionary, frame: FloorPlanFrame, p: Dictionary) -> bool:
	var want := int(arch.get("min_open_sides", 0))
	if want > 0:
		var n := 0
		for e in 4:
			if frame.face_open[e]:
				n += 1
		if n < want:
			return false
	if frame.size.x < float(arch.get("min_w", 0.0)):
		return false
	if frame.size.y < float(arch.get("min_d", 0.0)):
		return false
	var max_w := float(arch.get("max_w", 0.0))
	if max_w > 0.0 and frame.size.x > max_w:
		return false
	var max_area := float(arch.get("max_area", 0.0))
	if max_area > 0.0 and frame.size.x * frame.size.y > max_area:
		return false
	return true


# ==========================================================================
# Skeleton: circulation core first, then rooms around it.
# ==========================================================================

static func _cell(kind: StringName, rect: Rect2, circ: bool) -> Dictionary:
	return {
		"kind": kind, "rect": rect, "circ": circ, "id": "",
		"facade": [], "flen": 0.0, "doors": 0, "tier": 1,
	}


static func _skeleton(frame: FloorPlanFrame, arch: Dictionary, p: Dictionary) -> Array:
	var W := frame.size.x
	var D := frame.size.y
	var cells: Array = []
	# ---- 1. circulation side: the corridor follows the stair core, or the
	# closed party wall when this floor has no core of its own.
	var spine_left := true
	if frame.has_core:
		spine_left = frame.core.get_center().x <= W * 0.5
	else:
		var lc := not frame.face_open[FloorPlanFrame.EDGE_LEFT]
		var rc := not frame.face_open[FloorPlanFrame.EDGE_RIGHT]
		if lc and not rc:
			spine_left = true
		elif rc and not lc:
			spine_left = false
		else:
			spine_left = not frame.mirrored
	# ---- 2. entrance box must end up inside the hall
	var box := frame.rect_to_local(p.get("entry_box", Rect2()))
	var box_dep := 0.0
	var bx0 := W * 0.5 - 1.2
	var bx1 := W * 0.5 + 1.2
	if box.size.x > 0.4 and box.size.y > 0.4:
		box_dep = clampf(box.end.y, 0.0, D * 0.6)
		bx0 = clampf(box.position.x, 0.0, W)
		bx1 = clampf(box.end.x, 0.0, W)
	# ---- 3. corridor width. A flat corridor is 1.15-1.6 m wide. Letting it
	# scale freely with the plate is what produced 2.6 m "corridors" and
	# circulation shares above 50% on floors that should be mostly rooms.
	var cw := clampf(W * float(arch.get("spine_frac", 0.16)), 1.15, float(arch.get("spine_max", 1.4)))
	cw = minf(cw, maxf(1.15, W * 0.30))
	# ---- 4. front band depth: must clear the entrance clearance box
	var front_d := clampf(D * float(arch.get("front_frac", 0.22)), 1.9, 3.2)
	if box_dep > 0.5:
		front_d = maxf(front_d, minf(box_dep + 0.12, D * 0.40))
	front_d = minf(front_d, D * 0.45)
	# ---- 5. circulation backbone: it runs the FULL depth of the floor. A
	# corridor that stops at the stair core leaves every room behind the core
	# with no way in -- that is the defect the reachability gate kept catching.
	var central := bool(arch.get("central_spine", false)) and W >= 9.0
	if central:
		var cx := clampf((W - cw) * 0.5, 2.4, maxf(2.4, W - cw - 2.4))
		cells.append(_corridor(Rect2(cx, 0.0, cw, D)))
		# Only the band the entrance opens into gets a hall; the other band is
		# rooms straight off the corridor. Two full-width front halls per floor
		# were eating half of these plates as circulation.
		var hall_left := (bx0 + bx1) * 0.5 <= cx
		_band(cells, frame, Rect2(0.0, 0.0, cx, D), arch, p, 1 if hall_left else -1, front_d, bx0, bx1)
		_band(cells, frame, Rect2(cx + cw, 0.0, W - cx - cw, D), arch, p, 0 if not hall_left else -1, front_d, bx0, bx1)
	elif W > D * 1.15:
		# ---- 5b. Wide plate: the corridor runs PARALLEL TO THE STREET, not along a
		# party wall. On a 13.3 x 6.9 m plate a party-wall spine puts the entrance
		# column between the corridor and the rooms, so every depth slice but the
		# first can reach the corridor only through another room -- the reject dumps
		# show exactly that. The shallow-house plan real ones use instead: a
		# corridor along the street, one room tract behind it (courtyard-lit), and
		# an entrance bay that cuts the plate from the street to the courtyard with
		# the hall at the door, the stair behind it and a chamber behind that.
		var bxw := bx1 - bx0
		var bay_w := clampf(maxf(bxw + 0.9, 2.6), 2.6, minf(3.2, W * 0.45))
		var bay_x := clampf((bx0 + bx1) * 0.5 - bay_w * 0.5, 0.0, maxf(0.0, W - bay_w))
		var hall_d := clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.40))
		var shaft_d := 0.0
		var core_d := frame.core.size.y if frame.has_core else 0.0
		if frame.has_core and D - hall_d >= 2.6:
			shaft_d = clampf(core_d, 2.4, D - hall_d)
		var tail_d := D - hall_d - shaft_d
		if tail_d > 0.0 and tail_d < 1.6:
			# A 40 cm strip behind the stair is not a room: the stair hall takes
			# it. But the bay must not become circulation from the street to the
			# courtyard -- "the whole bay is hall" is the giant-lobby failure in
			# miniature. The shaft is capped at the stair's own depth plus its
			# landing, and whatever that leaves over 1.6 m becomes a courtyard
			# room reached off the stair hall.
			if shaft_d > 0.0:
				var cap_d := minf(shaft_d, core_d + 1.3)
				shaft_d = cap_d if tail_d + (shaft_d - cap_d) >= 1.6 else maxf(0.0, D - hall_d)
			else:
				# No stair on this floor: the hall stops where a room can start.
				hall_d = minf(D - 1.6, hall_d + 1.4)
				if hall_d < 1.6:
					hall_d = D
			tail_d = D - hall_d - shaft_d
		cells.append(_hall_cell(Rect2(bay_x, 0.0, bay_w, hall_d),
				int(p.get("floor_i", 0)) == 0))
		if shaft_d > 0.0:
			cells.append(_locked_cell(&"stair_hall",
					Rect2(bay_x, hall_d, bay_w, shaft_d), true))
		if tail_d >= 1.5:
			cells.append(_cell(&"room", Rect2(bay_x, D - tail_d, bay_w, tail_d), false))
		# The corridor along the street, either side of the bay.
		if bay_x >= 1.2:
			cells.append(_corridor(Rect2(0.0, 0.0, bay_x, cw)))
		if W - (bay_x + bay_w) >= 1.2:
			cells.append(_corridor(Rect2(bay_x + bay_w, 0.0, W - bay_x - bay_w, cw)))
		# The room tract behind the corridor: every slab of it borders the
		# corridor, so every room takes its own door off circulation.
		if bay_x >= 1.5:
			_slice_x(cells, Rect2(0.0, cw, bay_x, D - cw), arch)
		if W - (bay_x + bay_w) >= 1.5:
			_slice_x(cells, Rect2(bay_x + bay_w, cw, W - bay_x - bay_w, D - cw), arch)
	else:
		var cor_x := 0.0 if spine_left else W - cw
		cells.append(_corridor(Rect2(cor_x, 0.0, cw, D)))
		# The plate lies on the other side of the corridor from the spine, so
		# the band starts at 0 when the corridor hugs the right edge. Getting
		# this backwards made the band empty, which is what produced "band too
		# thin", "assignment failed" and the uncovered-void rejects.
		var band_x0 := cw if spine_left else 0.0
		var band_w := W - cw
		if band_w < 2.0:
			last_reject = "band too thin (W=%.1f D=%.1f)" % [W, D]
			return []
		# ---- 6-8. the plate beside the corridor: hall against the corridor,
		# front room opened off the hall, rows off the corridor, stair core
		# carved out of the band, rear service strip.
		_band(cells, frame, Rect2(band_x0, 0.0, band_w, D), arch, p, 0 if spine_left else 1, front_d, bx0, bx1)
	# ---- 9. any cell too thin to be a room kills the candidate (no slivers)
	for c: Dictionary in cells:
		var r: Rect2 = c["rect"]
		if r.size.x < 1.0 or r.size.y < 1.0:
			last_reject = "skeleton sliver kind=%s rect=%s (W=%.1f D=%.1f)" % [
				str(c["kind"]), str(r), W, D]
			return []
	return cells


static func _hall_cell(rect: Rect2, entry: bool) -> Dictionary:
	var c := _cell(&"hall", rect, true)
	c["entry"] = entry
	c["locked"] = true
	return c


## A cell whose kind the planner decides outright (the WC beside the hall, the
## stair landing). The programme assignment never renames a locked cell: where
## the WC goes is an architectural decision, not a leftover-space decision.
static func _locked_cell(kind: StringName, rect: Rect2, circ: bool = false) -> Dictionary:
	var c := _cell(kind, rect, circ)
	c["locked"] = true
	return c


static func _corridor(rect: Rect2) -> Dictionary:
	var c := _cell(&"corridor", rect, true)
	c["entry"] = false
	return c


## Every floor has exactly one way in from the street. The hall that the band's
## entrance column places carries it; when a floor has no hall -- the shaft took
## the column, or the plate is too shallow for one -- the street door opens into
## the corridor that reaches the street instead. A floor whose door leads only
## to wall is not enterable, however good its rooms are.
static func _ensure_entry(cells: Array, p: Dictionary) -> void:
	if int(p.get("floor_i", 0)) != 0:
		return
	for c: Dictionary in cells:
		if bool(c.get("entry", false)):
			return
	var best := -1
	var best_len := -1.0
	for i in cells.size():
		var c: Dictionary = cells[i]
		var r: Rect2 = c["rect"]
		if not bool(c["circ"]) or r.position.y > 0.35:
			continue
		if r.size.x > best_len:
			best_len = r.size.x
			best = i
	if best >= 0:
		cells[best]["entry"] = true


## One band of a floor: the strip of plate beside the corridor, together with
## the circulation that serves it.
##
## The arrangement is the one a Bohemian town house actually uses. The corridor
## runs the full depth of the plate along a party wall, and the rooms beside it
## are slabs ACROSS the width, each of them spanning that full depth. Every room
## in a band therefore has a street window at one end and a courtyard window at
## the other, and every room touches circulation along the whole of its inner
## edge. Stacking rooms along the depth instead -- the obvious thing, and the
## first thing this planner did -- leaves every room but the front one
## windowless, which is how a floor plan starts to look like a dungeon map.
##
## `cor_side` is 0 when the corridor runs along the band's left edge, 1 when it
## runs along the right edge, -1 when this band carries no entrance column of
## its own (the second band of a central-spine plate is served by the hall of
## the first).
static func _band(cells: Array, frame: FloorPlanFrame, band: Rect2, arch: Dictionary,
		p: Dictionary, cor_side: int, front_d: float, bx0: float, bx1: float) -> void:
	if band.size.x < 1.8 or band.size.y < 1.8:
		return
	# The column of plate between the corridor and the first room: hall at the
	# street end, WC at the courtyard end. It is built only where an entrance
	# actually is, and only when the band can still keep a real room beside it.
	var col_w := 0.0
	var col_x := band.position.x
	if cor_side >= 0 and bool(arch.get("front_hall", true)) and band.size.x >= 4.4:
		var need := (bx1 + 0.40 - band.position.x) if cor_side == 0 else (band.end.x - (bx0 - 0.40))
		col_w = clampf(need, 2.1, minf(3.0, band.size.x - 2.6))
		# The entrance column belongs against the CORRIDOR, whichever party wall
		# the corridor runs along. Placing it always at the band's left edge puts
		# it on the far side of the plate whenever cor_side == 1, and the hall
		# then has no neighbour but the room between -- an isolated circulation
		# cell, which the validator is quite right to reject.
		if cor_side == 1:
			col_x = band.end.x - col_w
		# The stair shaft outranks the hall. If the stair stands where the
		# entrance column would go, the column is dropped and the leftovers
		# beside the shaft (see _slice_rooms) take the hall's place.
		if frame.has_core and frame.core.position.x < col_x + col_w + 0.2 \
				and frame.core.end.x > col_x + 0.2:
			col_w = 0.0
	if col_w > 0.0:
		_corner_cluster(cells, Rect2(col_x, band.position.y, col_w, band.size.y),
				arch, p, front_d)
	var rooms_x := band.position.x + (col_w if cor_side == 0 else 0.0)
	var rooms := Rect2(rooms_x, band.position.y, band.size.x - col_w, band.size.y)
	if rooms.size.x < 1.5:
		return
	if col_w <= 0.0 and cor_side >= 0 and rooms.size.y >= 6.0 and not frame.has_core:
		# A narrow band with no entrance column: the WC takes the courtyard end
		# and the room in front of it keeps the whole street frontage.
		_rear_wc(cells, rooms, arch)
		return
	_slice_rooms(cells, frame, rooms, arch)


## The entrance column: hall at the street end, WC at the courtyard end, and a
## service cell between them when the house is deep enough for one. All three
## open onto the corridor, so nothing in this column depends on another room in
## order to be reached.
static func _corner_cluster(cells: Array, col: Rect2, arch: Dictionary,
		p: Dictionary, front_d: float) -> void:
	var avail := col.size.y
	var hd := minf(clampf(front_d, 2.1, 2.8), maxf(1.7, avail - 1.3))
	var entry := int(p.get("floor_i", 0)) == 0
	var y := col.position.y
	if avail - hd >= 1.3:
		# The WC is capped in area as well as in depth: the validator rejects a
		# toilet the size of a room, and this column is a wide one.
		var wc_d := minf(2.3, avail - hd)
		wc_d = minf(wc_d, maxf(1.3, 5.6 / maxf(col.size.x, 1.0)))
		var mid := avail - hd - wc_d
		if mid > 0.0 and mid < 1.7:
			# Too thin to be its own room: the hall absorbs it, rather than
			# leaving a 1.4 m strip that no room programme can use.
			hd += mid
			mid = 0.0
		cells.append(_hall_cell(Rect2(col.position.x, y, col.size.x, hd), entry))
		y += hd
		if mid > 0.0:
			cells.append(_cell(&"room", Rect2(col.position.x, y, col.size.x, mid), false))
			y += mid
		if col.end.y - y >= 1.3:
			cells.append(_locked_cell(&"toilet",
					Rect2(col.position.x, y, col.size.x, col.end.y - y)))
		else:
			cells.append(_cell(&"room", Rect2(col.position.x, y, col.size.x, col.end.y - y), false))
	else:
		cells.append(_hall_cell(Rect2(col.position.x, y, col.size.x, hd), entry))
		if col.end.y - (y + hd) > 0.3:
			cells.append(_cell(&"room",
					Rect2(col.position.x, y + hd, col.size.x, col.end.y - y - hd), false))


## A WC across the courtyard end of a band too narrow for an entrance column.
static func _rear_wc(cells: Array, rooms: Rect2, arch: Dictionary) -> void:
	var d := clampf(5.6 / maxf(rooms.size.x, 1.0), 1.4, 2.2)
	cells.append(_locked_cell(&"toilet", Rect2(rooms.position.x, rooms.end.y - d,
			rooms.size.x, d)))
	_slice_x(cells, Rect2(rooms.position.x, rooms.position.y, rooms.size.x,
			rooms.size.y - d), arch)


## Slice a zone into the rooms that line the corridor. The zone is split
## depthwise: the band that holds the stair shaft becomes CIRCULATION (the
## landing at one end, plus a cross-hall running to the far wall), and the bands
## in front of and behind it are rooms sliced across the width. Both room bands
## keep their facade -- street in front, courtyard behind -- and every slab of
## them shares an edge with the circulation band, so no room is ever entered
## through another room. The first version of this function put the shaft in a
## column and left the far side as slab rooms; the room furthest from the shaft
## then had no neighbour but its own neighbour, and every such plan was rejected
## as unreachable.
static func _slice_rooms(cells: Array, frame: FloorPlanFrame, zone: Rect2,
		arch: Dictionary) -> void:
	if zone.size.x < 1.5 or zone.size.y < 1.5:
		return
	if not frame.has_core:
		_slice_x(cells, zone, arch)
		return
	var core: Rect2 = frame.core
	# Depth of the stair band: the shaft's own depth, widened to something
	# walkable, and kept clear of both facades so the room bands stay real rooms.
	var band := clampf(maxf(core.size.y, 2.4), 2.4, minf(3.8, maxf(2.4, zone.size.y * 0.45)))
	var cy0 := clampf(core.position.y, zone.position.y,
			maxf(zone.position.y, zone.end.y - band))
	var cy1 := minf(cy0 + band, zone.end.y)
	if zone.end.y - cy1 < 1.5:
		cy1 = zone.end.y
		cy0 = maxf(zone.position.y, cy1 - band)
	if cy0 - zone.position.y < 1.5:
		# Too shallow for a band in front of the stair: put the stair across the
		# far end of the plate instead, so that the single room band it leaves
		# keeps the corridor edge.
		band = minf(maxf(band, 2.4), maxf(2.4, zone.size.y - 1.5))
		cy0 = maxf(zone.position.y, zone.end.y - band)
		cy1 = zone.end.y
	# The stair band is circulation ACROSS THE FULL WIDTH of the plate. Anything
	# narrower severs the room bands in front of and behind it from the corridor:
	# a room given walls beside the shaft blocks the band behind it, and those
	# rooms then reach circulation only through a service room, which the
	# reachability gate rejects -- correctly. The shaft stands inside this band,
	# so it reads as the stair hall it is, not as an empty lobby.
	cells.append(_locked_cell(&"stair_hall",
			Rect2(zone.position.x, cy0, zone.size.x, cy1 - cy0), true))
	# The room bands: the one in front of the stair keeps the street facade, the
	# one behind it keeps the courtyard. Both are sliced across the width and
	# both abut circulation along their full length, so every room -- whatever
	# its kind -- takes its own door off the hall and none is reached through a
	# neighbour. This is what keeps a deep plate legible: bands of rooms either
	# side of the stair, not a corridor with rectangles hung off it.
	if cy0 - zone.position.y >= 1.5:
		_slice_x(cells, Rect2(zone.position.x, zone.position.y,
				zone.size.x, cy0 - zone.position.y), arch)
	if zone.end.y - cy1 >= 1.5:
		_slice_x(cells, Rect2(zone.position.x, cy1, zone.size.x,
				zone.end.y - cy1), arch)


## Widthwise slicing: even slabs, no lonely tail at the end. A 2.7 m room beside
## a 5.1 m one is not a plan, it is leftover.
static func _slice_x(cells: Array, zone: Rect2, arch: Dictionary) -> void:
	if zone.size.x < 1.5 or zone.size.y < 1.5:
		return
	var rw := maxf(float(arch.get("room_w", 3.4)), 2.5)
	var n := clampi(int(round(zone.size.x / rw)), 1, maxi(int(arch.get("max_rooms", 3)), 1))
	var sizes: Array[float] = []
	for i in n:
		sizes.append(zone.size.x / float(n))
	if sizes.size() >= 2 and sizes[sizes.size() - 1] < zone.size.x / float(sizes.size()) * 0.7:
		sizes[sizes.size() - 2] += sizes[sizes.size() - 1]
		sizes.remove_at(sizes.size() - 1)
	var off := zone.position.x
	for s in sizes:
		cells.append(_cell(&"room", Rect2(off, zone.position.y, s, zone.size.y), false))
		off += s


static func _assign(frame: FloorPlanFrame, arch: Dictionary, p: Dictionary, cells: Array) -> Array:
	var room_cells: Array = []
	for c: Dictionary in cells:
		if bool(c["circ"]):
			continue
		c["facade"] = frame.facade_edges_of(c["rect"])
		c["flen"] = frame.facade_length_of(c["rect"])
		room_cells.append(c)
	if room_cells.is_empty():
		return []
	var slots := FloorProgram.slots(str(p.get("use", "residential")), int(p.get("floor_i", 0)), room_cells.size())
	var used := {}
	for si in slots.size():
		var kind: StringName = slots[si]
		# A locked cell that already carries this kind fills the slot as it
		# stands: the planner placed it (the WC beside the hall), so the
		# programme must not spend a second cell on the same room type.
		var pre := -1
		for i in room_cells.size():
			if used.has(i) or not bool(room_cells[i].get("locked", false)):
				continue
			if room_cells[i]["kind"] == kind:
				pre = i
				break
		if pre >= 0:
			used[pre] = true
			continue
		# Otherwise pick the best cell -- but only among cells that can actually
		# host the kind. When none can, the slot takes the least-bad cell and is
		# downgraded instead of forcing, say, a 16 m2 kitchen into a 1.4 m sliver.
		var best := -1
		var best_fit := -1.0e9
		var spare := -1
		var spare_fit := -1.0e9
		for i in room_cells.size():
			if used.has(i) or bool(room_cells[i].get("locked", false)):
				continue
			var f := _fit(kind, room_cells[i], si)
			if f > spare_fit:
				spare_fit = f
				spare = i
			if _can_host(kind, room_cells[i]) and f > best_fit:
				best_fit = f
				best = i
		var pick := best if best >= 0 else spare
		if pick < 0:
			continue
		used[pick] = true
		var cell: Dictionary = room_cells[pick]
		var k: StringName = kind if best >= 0 else _downgrade(kind, cell)
		cell["kind"] = k
		cell["tier"] = int(FloorProgram.spec_of(k).get("tier", 1))
	for i in room_cells.size():
		if used.has(i) or bool(room_cells[i].get("locked", false)):
			continue
		var cell: Dictionary = room_cells[i]
		if _can_host(&"storage", cell):
			cell["kind"] = &"storage"
			cell["tier"] = 3
		else:
			cell["kind"] = &"landing"
			cell["tier"] = 9
	return room_cells


static func _fit(kind: StringName, cell: Dictionary, slot_i: int) -> float:
	var spec := FloorProgram.spec_of(kind)
	var r: Rect2 = cell["rect"]
	var side := minf(r.size.x, r.size.y)
	var area := r.size.x * r.size.y
	var fit := 0.0
	fit -= maxf(0.0, float(spec.get("min_side", 2.0)) - side) * 12.0
	fit -= maxf(0.0, float(spec.get("min_area", 4.0)) - area) * 2.0
	# facade: a room that wants light must touch a facade or it is a service room
	var want := int(spec.get("facade", 0))
	if want > 0:
		if (cell["facade"] as Array).size() > 0:
			fit += 3.0 * want + float(cell["flen"]) * 0.30
		else:
			fit -= 3.0 * want
	# usable proportions
	var asp := maxf(r.size.x, r.size.y) / maxf(side, 0.01)
	fit -= maxf(0.0, asp - 2.2) * 2.5
	if slot_i == 0:
		fit += area * 0.10                      # principal room takes the best cell
	if kind == &"toilet":
		fit -= area * 0.35                      # a toilet never dominates
	if bool(spec.get("private", false)):
		fit += minf(r.position.y, 6.0) * 0.20   # private rooms sit away from the door
	if FloorProgram.is_service(kind):
		fit += minf(r.position.y, 8.0) * 0.10
	return fit


static func _can_host(kind: StringName, cell: Dictionary) -> bool:
	var spec := FloorProgram.spec_of(kind)
	var r: Rect2 = cell["rect"]
	var area := r.size.x * r.size.y
	# A cell may only host a kind it fits both ways round. Too small is a sliver;
	# too large is the "toilet the size of the whole band" defect -- a room type
	# with a sane ceiling must never be forced into a cell that dwarfs it.
	var max_area := float(spec.get("max_area", 0.0))
	if max_area > 0.0 and area > max_area * 1.05:
		return false
	if kind == &"toilet" and area > 8.0:
		return false
	if minf(r.size.x, r.size.y) < float(spec.get("min_side", 2.0)) - 0.05:
		return false
	return area >= float(spec.get("min_area", 4.0)) * 0.85


## Largest kind in the substitute chain this cell can host.
static func _downgrade(kind: StringName, cell: Dictionary) -> StringName:
	const CHAIN := {
		&"living": [&"sleeping", &"storage"],
		&"sleeping": [&"storage"],
		&"kitchen": [&"storage"],
		&"sales": [&"workshop", &"store_room", &"storage"],
		&"taproom": [&"sales", &"store_room", &"storage"],
		&"office": [&"storage"],
		&"meeting": [&"office", &"storage"],
		&"ward": [&"craft", &"storage"],
		&"surgery": [&"office", &"storage"],
		&"council": [&"meeting", &"office", &"storage"],
		&"reception": [&"office", &"storage"],
		&"machine_shop": [&"workshop", &"toolstore", &"storage"],
		&"workshop": [&"toolstore", &"storage"],
		&"craft": [&"toolstore", &"storage"],
		&"warehouse": [&"loading", &"store_room", &"storage"],
		&"loading": [&"store_room", &"storage"],
		&"holding": [&"storage"],
		&"dispensary": [&"storage"],
		&"archive": [&"storage"],
		&"toilet": [&"storage"],
	}
	for k: StringName in CHAIN.get(kind, [&"storage"]):
		if _can_host(k, cell):
			return k
	return &"storage"


# ==========================================================================
# Boundaries: adjacency -> doors, sealing, reachability.
# ==========================================================================

## The neighbour of `i` across one edge. Adjacency entries carry the pair as
## "i"/"j"; emitted boundary parts carry it as "a_i"/"b_i". A helper that reads
## only one of the two shapes returns -1 (or 0) instead of failing, so every
## diagnostic built on it lies -- exactly what made the first reject dump
## unreadable.
static func _other(e: Dictionary, i: int) -> int:
	var a := int(e.get("a_i", e.get("i", -1)))
	var b := int(e.get("b_i", e.get("j", -1)))
	if a == i:
		return b
	if b == i:
		return a
	return -1


## Shared wall between two cells, or {} when they are not edge-adjacent.
static func _shared_edge(a: Rect2, b: Rect2) -> Dictionary:
	if absf(a.end.x - b.position.x) < 0.06 or absf(b.end.x - a.position.x) < 0.06:
		var x: float = a.end.x if absf(a.end.x - b.position.x) < 0.06 else b.end.x
		var y0 := maxf(a.position.y, b.position.y)
		var y1 := minf(a.end.y, b.end.y)
		if y1 - y0 >= EDGE_MIN:
			return {"axis": 0, "at": x, "lo": y0, "hi": y1}
	if absf(a.end.y - b.position.y) < 0.06 or absf(b.end.y - a.position.y) < 0.06:
		var y: float = a.end.y if absf(a.end.y - b.position.y) < 0.06 else b.end.y
		var x0 := maxf(a.position.x, b.position.x)
		var x1 := minf(a.end.x, b.end.x)
		if x1 - x0 >= EDGE_MIN:
			return {"axis": 1, "at": y, "lo": x0, "hi": x1}
	return {}


static func _adjacency(cells: Array) -> Array:
	var out: Array = []
	for i in cells.size():
		for j in range(i + 1, cells.size()):
			var e := _shared_edge(cells[i]["rect"], cells[j]["rect"])
			if e.is_empty():
				continue
			e["i"] = i
			e["j"] = j
			out.append(e)
	return out


## Emit one boundary. Returns true when a real door was cut.
static func _add_boundary(parts: Array, door_list: Array, a_i: int, b_i: int,
		e: Dictionary, with_door: bool, edge_min: float = DOOR_EDGE_MIN) -> bool:
	var lo := float(e["lo"])
	var hi := float(e["hi"])
	var at := float(e["at"])
	var axis := int(e["axis"])
	# Wall rect uses InteriorPlan's partition convention: 0.18 m slab centred on
	# the shared edge (half-thickness 0.09), so both rooms keep their planned
	# rect and the wall is rebuilt by the existing partition emitter.
	var h := WALL_T * 0.5
	var wall := Rect2(lo, at - h, hi - lo, WALL_T) if axis == 1 \
			else Rect2(at - h, lo, WALL_T, hi - lo)
	var door := false
	var opening := SEALED
	if with_door and hi - lo >= edge_min:
		var c := clampf((lo + hi) * 0.5, lo + OPEN_W * 0.5 + 0.12, hi - OPEN_W * 0.5 - 0.12)
		# Opening rect: 0.95 aperture along the wall, 1.0 deep across it (the
		# same shape InteriorPlan's own partitions use; consumers split the wall
		# on this rect and hang the leaf in it).
		opening = Rect2(c - OPEN_W * 0.5, at - 0.5, OPEN_W, 1.0) if axis == 1 \
				else Rect2(at - 0.5, c - OPEN_W * 0.5, 1.0, OPEN_W)
		door = true
	# Stable key order so the sealed-edge pass can never re-emit a door edge.
	var a2 := mini(a_i, b_i)
	var b2 := maxi(a_i, b_i)
	parts.append({"a_i": a2, "b_i": b2, "axis": axis, "at": at, "lo": lo, "hi": hi,
			"door": door, "wall": wall, "opening": opening})
	if door:
		door_list.append({"a": a2, "b": b2})
	return door


static func _boundaries(cells: Array) -> Dictionary:
	var adj := _adjacency(cells)
	var parts: Array = []
	var door_list: Array = []
	# 1. circulation connects to circulation - the hall always reaches the spine.
	# Two circ cells open to each other with a passage (PASSAGE_EDGE_MIN): a
	# landing and its corridor are one space, and a sealed edge between them
	# would split the floor's circulation into two components.
	for e: Dictionary in adj:
		var a: Dictionary = cells[int(e["i"])]
		var b: Dictionary = cells[int(e["j"])]
		if bool(a["circ"]) and bool(b["circ"]):
			if _add_boundary(parts, door_list, int(e["i"]), int(e["j"]), e, true,
					PASSAGE_EDGE_MIN):
				a["doors"] = int(a["doors"]) + 1
				b["doors"] = int(b["doors"]) + 1
	# 2. every room gets its door on the widest edge it shares with circulation.
	for i in cells.size():
		var c: Dictionary = cells[i]
		if bool(c["circ"]):
			continue
		var best := {}
		var best_span := 0.0
		for e: Dictionary in adj:
			var oi := _other(e, i)
			if oi < 0 or not bool(cells[oi]["circ"]):
				continue
			var span := float(e["hi"]) - float(e["lo"])
			if span > best_span:
				best_span = span
				best = e
		if not best.is_empty() and _add_boundary(parts, door_list, i, _other(best, i), best, true):
			c["doors"] = int(c["doors"]) + 1
			cells[_other(best, i)]["doors"] = int(cells[_other(best, i)]["doors"]) + 1
	# 3. a room that touches no circulation at all may relay once through an
	# adjacent public room (never through a bedroom or a toilet).
	for i in cells.size():
		var c2: Dictionary = cells[i]
		if bool(c2["circ"]) or int(c2["doors"]) > 0:
			continue
		var pick := {}
		var pick_span := 0.0
		for e: Dictionary in adj:
			var oi2 := _other(e, i)
			if oi2 < 0:
				continue
			var o2: Dictionary = cells[oi2]
			if not _may_relay(o2["kind"]) or int(o2["doors"]) == 0:
				continue
			var span2 := float(e["hi"]) - float(e["lo"])
			if span2 >= DOOR_EDGE_MIN + 0.1 and span2 > pick_span:
				pick_span = span2
				pick = e
		if not pick.is_empty() and _add_boundary(parts, door_list, i, _other(pick, i), pick, true):
			c2["doors"] = int(c2["doors"]) + 1
	# 4. every remaining shared edge is a sealed wall between two rooms.
	var done := {}
	for p: Dictionary in parts:
		done["%d|%d" % [int(p["a_i"]), int(p["b_i"])]] = true
	for e: Dictionary in adj:
		if done.has("%d|%d" % [int(e["i"]), int(e["j"])]):
			continue
		_add_boundary(parts, door_list, int(e["i"]), int(e["j"]), e, false)
	return {"parts": parts, "doors": door_list}


## Human-readable reason the last _reach_ok() rejected a plan (fed into
## last_reject so probes report which room had no circulation door).
static var _reach_why: String = ""

## Every cell of the rejected skeleton, compactly. "Which cell covers that strip
## beside the corridor" is not answerable by hand from a list of rectangles, and
## a reject that cannot be localised is a reject that gets patched blind.
static func _cell_dump(cells: Array) -> String:
	var out: Array = []
	for i in cells.size():
		var c: Dictionary = cells[i]
		var r: Rect2 = c["rect"]
		out.append("%d:%s(%.2f,%.2f,%.2f,%.2f%s%s)" % [i, str(c["kind"]),
				r.position.x, r.position.y, r.size.x, r.size.y,
				",circ" if bool(c["circ"]) else "",
				",lock" if bool(c.get("locked", false)) else ""])
	return str(out)


## Every room is reachable from circulation in at most one relay hop, no private
## room is ever the only way through to another room, and the circulation cells
## form one connected network (a stair hall must not float free of the corridor).
static func _reach_ok(cells: Array, parts: Array) -> bool:
	_reach_why = ""
	var graph := {}
	for i in cells.size():
		graph[i] = []
	for p: Dictionary in parts:
		if not bool(p["door"]):
			continue
		var ai := int(p["a_i"])
		var bi := int(p["b_i"])
		(graph[ai] as Array).append(bi)
		(graph[bi] as Array).append(ai)
	# 1. circulation is connected to circulation.
	var circ: Array = []
	for i in cells.size():
		if bool(cells[i]["circ"]):
			circ.append(i)
	if not circ.is_empty():
		var seen := {int(circ[0]): true}
		var stack: Array = [int(circ[0])]
		while not stack.is_empty():
			var cur := int(stack.pop_back())
			for nb: int in graph[cur]:
				if bool(cells[nb]["circ"]) and not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
		if seen.size() != circ.size():
			var miss: Array = []
			for i: int in circ:
				if not seen.has(i):
					miss.append("%d(%s)" % [i, str(cells[i]["kind"])])
			_reach_why = "circ %d/%d connected, isolated=%s cells=%s" % [
				seen.size(), circ.size(), str(miss), _cell_dump(cells)]
			return false
	# 2. every other room opens directly onto circulation, or relays through one
	# public room that does (never through a bedroom or a toilet).
	var direct := {}
	for i in cells.size():
		if bool(cells[i]["circ"]):
			continue
		for nb: int in graph[i]:
			if bool(cells[nb]["circ"]):
				direct[i] = true
				break
	for i in cells.size():
		if bool(cells[i]["circ"]) or direct.has(i):
			continue
		var ok := false
		for nb: int in graph[i]:
			if direct.has(nb) and _may_relay(cells[nb]["kind"]):
				ok = true
				break
		if not ok:
			var nbs: Array = []
			for nb: int in graph[i]:
				nbs.append("%d(%s%s)" % [nb, str(cells[nb]["kind"]), "*" if direct.has(nb) else ""])
			# The failing cell's full adjacency, door or sealed, plus the
			# circulation cells themselves: "no circulation neighbour" and "no
			# neighbour at all" need completely different fixes, and without
			# this dump the two look identical in the log.
			var adj_nb: Array = []
			for p2: Dictionary in parts:
				var oi3 := _other(p2, i)
				if oi3 >= 0:
					adj_nb.append("%d(%s%s%s)" % [oi3, str(cells[oi3]["kind"]),
							"*" if direct.has(oi3) else "", "D" if bool(p2["door"]) else "-"])
			var circ_rects: Array = []
			for ci: int in circ:
				circ_rects.append("%d(%s)%s" % [ci, str(cells[ci]["kind"]), str(cells[ci]["rect"])])
			_reach_why = "room %d kind=%s rect=%s doors_to=%s adj=%s circ=%s cells=%s" % [
				i, str(cells[i]["kind"]), str(cells[i]["rect"]), str(nbs), str(adj_nb),
				str(circ_rects), _cell_dump(cells)]
			return false
	return true


# ==========================================================================
# Validation. These rules reject a plan; they never create one.
# ==========================================================================

static func _validate(frame: FloorPlanFrame, cells: Array, parts: Array, p: Dictionary) -> Dictionary:
	var inner := frame.size
	var metrics := {"rooms": cells.size(), "overlap": 0, "sliver": 0, "outside": 0,
			"doors": 0, "circ_frac": 0.0, "uncovered": 0.0, "facade_rooms": 0,
			"tier0_facade": 0}
	var circ_area := 0.0
	var core_area := 0.0
	var total := 0.0
	var toilet_area := 0.0
	for i in cells.size():
		var c: Dictionary = cells[i]
		var r: Rect2 = c["rect"]
		var spec := FloorProgram.spec_of(c["kind"])
		if r.position.x < -0.03 or r.position.y < -0.03 \
				or r.end.x > inner.x + 0.03 or r.end.y > inner.y + 0.03:
			metrics["outside"] = int(metrics["outside"]) + 1
		var side := minf(r.size.x, r.size.y)
		if side < float(spec.get("min_side", 1.2)) * 0.92 \
				or r.size.x * r.size.y < float(spec.get("min_area", 1.0)) * 0.80:
			metrics["sliver"] = int(metrics["sliver"]) + 1
		var area := r.size.x * r.size.y
		total += area
		if bool(c["circ"]):
			circ_area += area
			# The shaft's own footprint is not floor anyone can walk on, so it
			# leaves the numerator and the denominator alike. The rest of the
			# stair band is the landing and cross-hall that reaches the rooms on
			# both sides of it, and is circulation like any other corridor.
			if frame.has_core:
				var sh: Rect2 = r.intersection(frame.core)
				if sh.size.x > 0.0 and sh.size.y > 0.0:
					core_area += sh.size.x * sh.size.y
		if c["kind"] == &"toilet":
			toilet_area = maxf(toilet_area, area)
		var fac: Array = c.get("facade", [])
		if fac.size() > 0 and int(spec.get("facade", 0)) > 0:
			metrics["facade_rooms"] = int(metrics["facade_rooms"]) + 1
			if int(spec.get("tier", 1)) == 0:
				metrics["tier0_facade"] = int(metrics["tier0_facade"]) + 1
		for j in range(i + 1, cells.size()):
			var ov: Rect2 = (cells[j]["rect"] as Rect2).intersection(r)
			if ov.size.x > 0.10 and ov.size.y > 0.10:
				metrics["overlap"] = int(metrics["overlap"]) + 1
	for pt: Dictionary in parts:
		if bool(pt["door"]):
			metrics["doors"] = int(metrics["doors"]) + 1
	# coverage on a 0.25 m grid; the stair core is legitimately not a room
	var step := 0.25
	var gx := int(ceil(inner.x / step))
	var gy := int(ceil(inner.y / step))
	var seen := 0
	var covered := 0
	var hole := Vector2(-1.0, -1.0)
	for ix in gx:
		for iy in gy:
			var pt2 := Vector2((float(ix) + 0.5) * step, (float(iy) + 0.5) * step)
			if pt2.x > inner.x or pt2.y > inner.y:
				continue
			seen += 1
			var hit := false
			if frame.has_core and frame.core.has_point(pt2):
				hit = true
			if not hit:
				for c2: Dictionary in cells:
					if (c2["rect"] as Rect2).has_point(pt2):
						hit = true
						break
			if hit:
				covered += 1
			elif hole.x < 0.0:
				hole = pt2
	metrics["uncovered"] = 1.0 - float(covered) / maxf(float(seen), 1.0)
	metrics["circ_frac"] = maxf(circ_area - core_area, 0.0) / maxf(total - core_area, 0.1)
	metrics["core_area"] = core_area
	metrics["floor_area"] = total
	if int(metrics["outside"]) > 0 or int(metrics["overlap"]) > 0 or int(metrics["sliver"]) > 0:
		_last_validate = "geometry outside=%d overlap=%d sliver=%d" % [int(metrics["outside"]), int(metrics["overlap"]), int(metrics["sliver"])]
		return {}
	if float(metrics["uncovered"]) > 0.06:
		_last_validate = "uncovered=%.3f first hole (%.2f, %.2f) of %.1fx%.1f" % [
			float(metrics["uncovered"]), hole.x, hole.y, inner.x, inner.y]
		return {}
	# What counts as excessive circulation depends on what the floor has to
	# carry. A stair floor owns its landing AND the cross-hall that serves the
	# room bands either side of it; a smaller plate spends a larger share on the
	# same stair. Floors without a stair are held to the tighter share, and a
	# floor too small to hold a room at all is only asked to be connected.
	var circ_cap := 0.40 if frame.has_core else 0.34
	if total < 34.0:
		circ_cap = 0.52
	if float(metrics["circ_frac"]) > circ_cap or float(metrics["circ_frac"]) < 0.05:
		_last_validate = "circ_frac=%.3f (cap %.2f, floor 0.05)" % [float(metrics["circ_frac"]), circ_cap]
		return {}
	if toilet_area > maxf(6.5, 0.13 * total):
		_last_validate = "toilet_area=%.2f of %.2f" % [toilet_area, total]
		return {}
	for c3: Dictionary in cells:
		if int(c3["doors"]) == 0:
			_last_validate = "room without door (kind=%s)" % str(c3["kind"])
			return {}
	return metrics


static func _score(cand: Dictionary, frame: FloorPlanFrame) -> float:
	var cells: Array = cand["cells"]
	var s := 0.0
	var circ_area := 0.0
	var total := 0.0
	for c: Dictionary in cells:
		var r: Rect2 = c["rect"]
		var area := r.size.x * r.size.y
		total += area
		var spec := FloorProgram.spec_of(c["kind"])
		var want := int(spec.get("facade", 0))
		var fac: Array = c.get("facade", [])
		if want > 0 and fac.size() > 0:
			s += 2.2 * want + float(c.get("flen", 0.0)) * 0.25
		elif want == 0 and fac.size() > 0:
			s -= 0.6
		if bool(c["circ"]):
			circ_area += area
			continue
		var side := minf(r.size.x, r.size.y)
		s -= maxf(0.0, (float(spec.get("min_side", 2.0)) + 0.55) - side) * 1.6
		s -= maxf(0.0, maxf(r.size.x, r.size.y) / maxf(side, 0.01) - 2.0) * 1.2
		if bool(spec.get("private", false)) and int(c["doors"]) > 1:
			s -= 3.0
		if c["kind"] == &"toilet":
			s -= area * 0.4
	s -= maxf(0.0, circ_area / maxf(total, 0.1) - 0.16) * 45.0
	s += float(cand["metrics"].get("rooms", 0)) * 0.7
	return s


# ==========================================================================
# Emission into the plan frame.
# ==========================================================================

static func _emit(frame: FloorPlanFrame, cand: Dictionary, arch: Dictionary, p: Dictionary) -> Dictionary:
	var bid := str(p.get("building_id", "b"))
	var fi := int(p.get("floor_i", 0))
	var cells: Array = cand["cells"]
	var parts: Array = cand["parts"]
	var rooms: Array = []
	var circulation: Array = []
	var per_kind := {}
	var id_of := {}
	for i in cells.size():
		var c: Dictionary = cells[i]
		var k: StringName = c["kind"]
		var n := int(per_kind.get(k, 0))
		per_kind[k] = n + 1
		var id := "%s_f%d_%s%d" % [bid, fi, String(k), n]
		c["id"] = id
		id_of[i] = id
		var rl: Rect2 = c["rect"]
		rooms.append({
			"id": id,
			"kind": k,
			"rect": frame.rect_to_plan(rl),
			"entry": bool(c.get("entry", false)),
			"service": FloorProgram.is_service(k),
			"circulation": bool(c["circ"]),
			"facade_edges": frame.facade_edges_of(rl),
			"facade_length": frame.facade_length_of(rl),
			"tier": int(FloorProgram.spec_of(k).get("tier", 1)),
		})
		if bool(c["circ"]):
			circulation.append(frame.rect_to_plan(rl))
	var boundaries: Array = []
	for pt: Dictionary in parts:
		var door := bool(pt["door"])
		boundaries.append({
			"a": String(id_of[int(pt["a_i"])]),
			"b": String(id_of[int(pt["b_i"])]),
			"door": door,
			"wall": frame.rect_to_plan(pt["wall"]),
			"opening": frame.rect_to_plan(pt["opening"]) if door else SEALED,
		})
	var core_plan := Rect2()
	if frame.has_core:
		core_plan = frame.rect_to_plan(frame.core)
	return {
		"floor_i": fi,
		"archetype": String(arch["id"]),
		"rooms": rooms,
		"boundaries": boundaries,
		"circulation": circulation,
		"core_rect": core_plan,
		"mirrored": frame.mirrored,
		"metrics": cand["metrics"],
	}


static func _candidate(frame: FloorPlanFrame, arch: Dictionary, p: Dictionary) -> Dictionary:
	var cells := _skeleton(frame, arch, p)
	if cells.is_empty():
		if last_reject.begins_with("skeleton") or last_reject.begins_with("band"):
			last_reject = "%s: %s" % [arch["id"], last_reject]
		else:
			last_reject = "%s: skeleton empty (%.1fx%.1f)" % [arch["id"], frame.size.x, frame.size.y]
		return {}
	_ensure_entry(cells, p)
	var room_cells := _assign(frame, arch, p, cells)
	if room_cells.is_empty():
		last_reject = "%s: assignment failed (%.1fx%.1f)" % [arch["id"], frame.size.x, frame.size.y]
		return {}
	var bnd := _boundaries(cells)
	if not _reach_ok(cells, bnd["parts"]):
		last_reject = "%s: reachability %s" % [arch["id"], _reach_why]
		return {}
	var metrics := _validate(frame, cells, bnd["parts"], p)
	if metrics.is_empty():
		last_reject = "%s: %s cells=%s" % [arch["id"], _last_validate, _cell_dump(cells)]
		return {}
	return {"cells": cells, "parts": bnd["parts"], "metrics": metrics}
