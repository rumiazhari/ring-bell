class_name HistoricInteriorPlan
extends RefCounted
## Rooms follow the passage and the existing physical stair shaft. Plans use
## the same unrotated world-coordinate convention as InteriorPlan.


## --- Prague depth plan --------------------------------------------------------
## A historic burgher house is a *depth* plan. The street front carries the
## mazhaus: the unheated vaulted front room that is the house's communication
## node, holding the stair, the cellar entry and the passage through to the
## courtyard. Chambers sit behind it, and the working room - the kitchen with its
## flue stack - sits at the courtyard end. Light reaches a room only from the two
## ends of the plot, because both flanking walls are party walls shared with the
## neighbours. Two rules follow, and debug/prague_interior_logic_test.gd measures
## both:
##   1. every substantial room touches the street facade or the courtyard facade.
##      A bay that can reach neither is circulation, or the windowless store
##      (komora) a real house kept for exactly that dead middle ground.
##   2. the room nearest the street carries the public program, and no chamber is
##      ever a mandatory passage on the way to it.
const DEPTH_GROUND := {
	"retail": [&"sales", &"office", &"sales"],
	"workshop": [&"workshop", &"office", &"workshop"],
	"office": [&"office", &"office", &"office"],
	"tavern": [&"taproom", &"taproom", &"taproom"],
	"storage": [&"warehouse", &"warehouse", &"warehouse"],
	"caretaker": [&"living", &"living", &"living"],
}
## The working rooms of the ground floor sit at the back, by the courtyard where
## the well and the flue stack are: the tavern kitchen, the shop's store, the
## workshop's yard store.
const DEPTH_GROUND_BACK := {
	"retail": &"storage",
	"workshop": &"storage",
	"office": &"archive",
	"tavern": &"kitchen",
	"storage": &"store_room",
	"caretaker": &"kitchen",
}
## Upper floors: the parlours (predni pokoj) face the street, the chamber sits
## behind them, the kitchen looks onto the courtyard.
const DEPTH_UPPER := [&"living", &"living", &"sleeping"]
const DEPTH_UPPER_BACK: StringName = &"kitchen"
const DEPTH_TAIL: StringName = &"storage"
## Rooms nobody lives in, and the ways through: a floor made only of these has
## no room at all, which the rescue pass below corrects.
const SERVICE_KINDS := [&"storage", &"store_room", &"warehouse", &"archive", &"loading", &"toilet"]
const CIRC_KINDS := [&"stair_hall", &"landing", &"entry"]
const CHAIN_PRIVATE_KINDS := [&"sleeping", &"kitchen", &"storage", &"store_room", &"archive"]
const DEPTH_BAYS_MAX := 3

## A room's light is an adjacency fact, not a size heuristic. CityPlan publishes
## `open_faces` in raw lot-edge order; direct fixtures without that field retain
## the old boundary-only fallback so generic callers remain compatible.
static func _face_open(spec: Dictionary, edge: int, fallback: bool = true) -> bool:
	var faces: Array = spec.get("open_faces", []) as Array
	if faces.size() >= 4:
		return bool(faces[edge])
	return fallback

static func _cell_has_open_face(cell_rect: Rect2, plate: Rect2, basis: Array, spec: Dictionary) -> bool:
	var raw_cell := _rect_to_raw(cell_rect, basis)
	var raw_plate := _rect_to_raw(plate, basis)
	var touches := false
	for edge in 4:
		var on_edge := false
		match edge:
			0: on_edge = absf(raw_cell.position.y - raw_plate.position.y) < 0.06
			1: on_edge = absf(raw_cell.end.x - raw_plate.end.x) < 0.06
			2: on_edge = absf(raw_cell.end.y - raw_plate.end.y) < 0.06
			_: on_edge = absf(raw_cell.position.x - raw_plate.position.x) < 0.06
		if not on_edge:
			continue
		touches = true
		if _face_open(spec, edge, false):
			return true
	if not spec.has("open_faces"):
		return touches
	return false

static func _room_touches_edge(room_rect: Rect2, inner: Rect2, edge: int) -> bool:
	match edge:
		0: return absf(room_rect.position.y - inner.position.y) < 0.06
		1: return absf(room_rect.end.x - inner.end.x) < 0.06
		2: return absf(room_rect.end.y - inner.end.y) < 0.06
		_: return absf(room_rect.position.x - inner.position.x) < 0.06


## --- Phase 2 area tiers (m^2) -------------------------------------------------
## A historic floor is a small number of real rooms, not a dungeon maze: a bay is
## only cut when the rooms it makes clear the smallest room their tier allows.
const PRINCIPAL_MIN := 22.0
const NORMAL_MIN := 12.0
const SERVICE_MIN := 6.0
const SERVICE_MAX := 10.0
const COMBAT_MIN := 18.0        # one manoeuvre room on every normal floor
const ROOM_MIN_SIDE := 1.8      # narrower than this is furniture, not a room
const ROOM_MAX_RATIO := 2.6     # longer than this reads as a corridor
const ROOM_BAY_TARGET := (NORMAL_MIN + PRINCIPAL_MIN) * 0.5
const BAND_DEPTH_MIN := 3.2     # shallower bands cannot hold a real room
const BAND_DEPTH_MAX := 7.2     # deeper bays leave the far end of the room dark
const CORRIDOR_H := 1.5         # middle cross passage (passages are 1.3-1.6 m)
const PRIVET_MIN := 1.2         # a privet smaller than this is a cupboard
const PRIVET_H := 1.6           # depth of a privet taken as a strip

## Frame the plate so the street facade lies on -y and the stair column on the
## west. Without this frame three of the four entrance orientations were planned
## as if the door faced north, which put the hall, the landing and the street
## band on the wrong side of the house.
static func _basis(de: int, mirror: bool) -> Array:
	var ex := Vector2(1, 0)
	var ey := Vector2(0, 1)
	match de:
		1:
			ex = Vector2(0, -1)
			ey = Vector2(1, 0)
		2:
			ex = Vector2(-1, 0)
			ey = Vector2(0, -1)
		3:
			ex = Vector2(0, 1)
			ey = Vector2(-1, 0)
	if mirror:
		ex = Vector2(-ex.x, ex.y)
		ey = Vector2(-ey.x, ey.y)
	return [ex, ey]

static func _to_c(p: Vector2, b: Array) -> Vector2:
	var ex: Vector2 = b[0]
	var ey: Vector2 = b[1]
	return Vector2(p.x * ex.x + p.y * ey.x, p.x * ex.y + p.y * ey.y)

static func _to_raw(q: Vector2, b: Array) -> Vector2:
	var ex: Vector2 = b[0]
	var ey: Vector2 = b[1]
	return Vector2(q.dot(ex), q.dot(ey))

static func _bounds(a: Vector2, c: Vector2) -> Rect2:
	return Rect2(minf(a.x, c.x), minf(a.y, c.y), absf(c.x - a.x), absf(c.y - a.y))

static func _rect_to_c(r: Rect2, b: Array) -> Rect2:
	return _bounds(_to_c(r.position, b), _to_c(r.end, b))

static func _rect_to_raw(r: Rect2, b: Array) -> Rect2:
	return _bounds(_to_raw(r.position, b), _to_raw(r.end, b))

## The plate and the stair column in canonical coordinates: street on -y, stair
## column on the west.
static func _frame(spec: Dictionary, inner: Rect2, has_stair: bool) -> Dictionary:
	var de := int(spec.get("door_edge", 0))
	var b := _basis(de, false)
	var plate := _rect_to_c(inner, b)
	var stair := Rect2()
	if not has_stair:
		return {"basis": b, "plate": plate, "stair": stair}
	stair = _rect_to_c(BuildingBuilder.stair_zone_world(spec), b)
	if stair.get_center().x > plate.get_center().x:
		b = _basis(de, true)
		plate = _rect_to_c(inner, b)
		stair = _rect_to_c(BuildingBuilder.stair_zone_world(spec), b)
	return {"basis": b, "plate": plate, "stair": stair}

## Cut a band into bays *perpendicular* to the facade it touches, so every bay
## keeps the window it needs. Repeated halving cut across the light instead,
## which left half the rooms of a deep plate with no facade at all. `min_area`
## keeps at least one bay at the tier the band owes the floor.
static func _bays(band: Rect2, cap: int, min_area: float, principal_first: bool) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if band.size.x < ROOM_MIN_SIDE or band.size.y < 1.0:
		return out
	var w_min := ROOM_MIN_SIDE + 0.4
	var n := clampi(int(round(band.get_area() / ROOM_BAY_TARGET)), 1, cap)
	n = mini(n, maxi(1, int(band.get_area() / maxf(min_area, 1.0))))
	n = mini(n, maxi(1, int(band.size.x / w_min)))
	while n > 1 and band.size.x / float(n) < w_min:
		n -= 1
	n = maxi(n, 1)
	# The front room of a Prague floor is the big one - the predni pokoj, or the
	# mazhaus at ground level - so the bay nearest the spine takes the principal
	# width and what is left over is split between the rooms behind it.
	var w0 := band.size.x / float(n)
	if principal_first and band.size.y > 0.5:
		w0 = clampf((PRINCIPAL_MIN + 3.0) / band.size.y, w_min, maxf(band.size.x - float(n - 1) * w_min, w_min))
	out.append(Rect2(band.position.x, band.position.y, w0, band.size.y))
	var rest := maxf(band.size.x - w0, 0.0)
	for i in range(1, n):
		var w := rest / float(n - 1)
		out.append(Rect2(band.position.x + w0 + w * float(i - 1), band.position.y, w, band.size.y))
	return out

## Bay depth: shallow enough that a bay does not read as a corridor, deep enough
## to clear the tier the band is asked for.
static func _band_depth(width: float, bay_count: int, limit: float, target: float) -> float:
	var bay_w := maxf(width / float(maxi(1, bay_count)), 1.0)
	# Never deeper than the space that exists: a band that overruns its limit
	# overlaps whatever lies beyond it.
	var cap := maxf(limit, 1.0)
	var d := clampf(target / bay_w, BAND_DEPTH_MIN, BAND_DEPTH_MAX)
	d = minf(d, cap)
	if d * bay_w < NORMAL_MIN:
		d = minf(maxf(NORMAL_MIN / bay_w, 2.2), cap)
	if d * bay_w < PRINCIPAL_MIN and cap > d:
		d = minf(cap, PRINCIPAL_MIN / bay_w)
	return clampf(d, minf(2.2, cap), cap)

static func _depth_front(fi: int, index: int, use: String, narrow: bool) -> StringName:
	if fi == 0:
		var kinds: Array = DEPTH_GROUND.get(use, [&"living", &"office", &"living"])
		return kinds[mini(index, kinds.size() - 1)]
	if narrow and index > 0:
		# The courtyard face of a deep narrow plot is the neighbour's wall, so
		# the kitchen stays on the street side - the only window it can have.
		return &"kitchen"
	return DEPTH_UPPER[mini(index, DEPTH_UPPER.size() - 1)]

static func _depth_back(fi: int, index: int, use: String, narrow: bool, back_open: bool = true) -> StringName:
	if index == 0:
		if narrow or not back_open:
			# A party wall cannot carry the kitchen: keep the back bay as the
			# windowless komora instead of promoting geometry to a room.
			return &"storage"
		return StringName(DEPTH_GROUND_BACK.get(use, &"storage")) if fi == 0 else DEPTH_UPPER_BACK
	return DEPTH_TAIL

## The privet (prevet): the one service room a floor must have. It is taken where
## a Prague house took it - over the courtyard, or beside the entrance - and
## always off the end of a bay that faces *away* from the window, so no room ever
## loses its facade to the privy.
static func _carve_privet(bay: Rect2, toward_street: bool) -> Array:
	var d := clampf(SERVICE_MIN / maxf(bay.size.x, 1.0), PRIVET_MIN, 2.0)
	if bay.size.y - d < 1.2:
		return [bay, Rect2()]
	if toward_street:
		return [Rect2(bay.position.x, bay.position.y, bay.size.x, bay.size.y - d),
				Rect2(bay.position.x, bay.end.y - d, bay.size.x, d)]
	return [Rect2(bay.position.x, bay.position.y + d, bay.size.x, bay.size.y - d),
			Rect2(bay.position.x, bay.position.y, bay.size.x, d)]

static func floor_plan(spec: Dictionary, fi: int) -> Dictionary:
	var rect: Rect2 = spec.rect
	var inner := rect.grow(-0.37)
	var bid := str(spec.id)
	var rooms: Array = []
	var use := str((spec.floor_uses as Array)[fi])
	var has_stair := BuildingBuilder.has_stairs_for(rect.size, float(spec.floor_h), int(spec.floors))
	var one_plate := inner.size.y < 3.6 or inner.size.x < 3.2
	var frame := _frame(spec, inner, has_stair)
	var basis: Array = frame["basis"]
	var plate: Rect2 = frame["plate"]
	var stair_c: Rect2 = frame["stair"]
	var back_edge := (int(spec.get("door_edge", 0)) + 2) % 4
	# [kind, rect in the canonical frame, carries the entrance]
	var cells: Array = []
	if not has_stair or one_plate:
		# A single-bay house keeps one work room and its privet, taken off the
		# end of the plate away from the street - the courtyard end, where a
		# narrow Prague house really did keep its WC.
		var plate_kind: StringName = &"stair_hall" if has_stair else _depth_front(fi, 0, use, inner.size.x < 6.5 and inner.size.y > 10.5)
		var privet_d := clampf(SERVICE_MIN / maxf(plate.size.x, 1.0), PRIVET_MIN, maxf(plate.size.y * 0.3, PRIVET_MIN))
		privet_d = minf(privet_d, maxf(plate.size.y - 1.0, PRIVET_MIN))
		cells.append([plate_kind, Rect2(plate.position, Vector2(plate.size.x, plate.size.y - privet_d)), fi == 0])
		cells.append([&"toilet", Rect2(plate.position.x, plate.end.y - privet_d, plate.size.x, privet_d), false])
	else:
		# The spine: the entry passage runs from the street facade to the stair,
		# the landing wraps the stair column and reaches the courtyard wall.
		var hall_w := clampf(1.35 + plate.size.x * 0.08, 1.5, 2.0)
		var sx := stair_c.end.x + 0.18
		var cut_y := clampf(stair_c.position.y - 0.18, plate.position.y + 1.3, plate.end.y - 1.3)
		var hall := Rect2(plate.position, Vector2(hall_w, cut_y - plate.position.y))
		var landing := Rect2(plate.position.x, cut_y, maxf(sx - plate.position.x, 0.0), maxf(plate.end.y - cut_y, 0.0))
		# A narrow plot that runs deep is the one case where the courtyard face is
		# the neighbour's wall: the back bay is then a windowless store (the zadni
		# komora) and the kitchen stays on the street side, where the window is.
		var narrow := plate.size.x < 6.5 and plate.size.y > 10.5
		var back_open := _face_open(spec, back_edge, not narrow)
		var rw := maxf(plate.end.x - sx, 0.0)
		var rd := maxf(plate.end.y - cut_y, 0.0)
		var rear_open := rw >= ROOM_MIN_SIDE + 0.4 and rd >= 2.8
		var rn := clampi(int(round(rw / 4.2)), 1, DEPTH_BAYS_MAX)
		var rbd := _band_depth(rw, rn, rd, ROOM_BAY_TARGET)
		if rd - rbd < 1.2:
			# Absorb a sliver remainder into the band rather than leaving a gap
			# no room can claim.
			rbd = rd
		# The privet is reserved before the bays are cut: every floor must have
		# one, and shrinking a bay is easier than inventing room later.
		var privet := Rect2()
		var pw := clampf(SERVICE_MIN / maxf(rbd, 1.0), 1.5, 2.0)
		var rear := Rect2()
		var fx := plate.position.x + hall_w
		var fw := maxf(plate.end.x - fx, 0.0)
		var have := maxf(cut_y - plate.position.y, 0.0)
		var privet_east := false
		var privet_end := false
		if rear_open and rw >= (ROOM_MIN_SIDE + 0.4) + pw:
			# Over the yard, where a Prague house kept it.
			rear = Rect2(sx, plate.end.y - rbd, rw - pw, rbd)
			privet = Rect2(plate.end.x - pw, plate.end.y - rbd, pw, rbd)
		elif fw >= ROOM_MIN_SIDE + 0.4 + pw and have >= BAND_DEPTH_MIN:
			# Beside the entrance: the east end of the street band.
			fw -= pw
			privet_east = true
		elif fw >= 2.4 and have >= BAND_DEPTH_MIN:
			# A narrow frontage still spares a sliver: a privy the width of a
			# cupboard beats a floor with no WC at all.
			pw = minf(pw, maxf(fw * 0.45, PRIVET_MIN))
			fw -= pw
			privet_east = true
		elif rear_open:
			rear = Rect2(sx, plate.end.y - rbd, rw, rbd)
		elif have >= BAND_DEPTH_MIN + PRIVET_H + 2.0:
			# A plot with no courtyard band at all: the privet is a strip across
			# the far end of the street band, and the bays stop short of it.
			privet_end = true
		else:
			# Too narrow for a courtyard band: the landing takes the whole back
			# of the house rather than inventing a sliver room.
			landing = Rect2(plate.position.x, cut_y, plate.size.x, maxf(plate.end.y - cut_y, 0.0))
		# Street band: bays cut across the frontage, every one of them lit, the
		# first one the principal room of the floor.
		var bays: Array[Rect2] = []
		var fd := have
		if privet_end:
			fd = maxf(fd - PRIVET_H, 2.2)
		if have >= BAND_DEPTH_MIN and fw >= ROOM_MIN_SIDE:
			var fn := clampi(int(round(fw / 4.2)), 1, DEPTH_BAYS_MAX)
			fd = _band_depth(fw, fn, have - (PRIVET_H if privet_end else 0.0), PRINCIPAL_MIN + 3.0)
			bays = _bays(Rect2(fx, plate.position.y, fw, fd), DEPTH_BAYS_MAX, NORMAL_MIN, true)
		if privet_end:
			var pw_end := minf(fw, 2.4)
			privet = Rect2(fx, plate.position.y + fd, pw_end, PRIVET_H)
			if fw - pw_end > 0.6:
				cells.append([&"storage", Rect2(fx + pw_end, plate.position.y + fd, fw - pw_end, PRIVET_H), false])
		if privet_east:
			privet = Rect2(plate.end.x - pw, plate.position.y, pw, maxf(fd, PRIVET_MIN))
		if privet.size.x < PRIVET_MIN and not bays.is_empty():
			# Nowhere over the yard: take it off the far end of the largest street
			# bay, which keeps its window.
			var big := 0
			for i in bays.size():
				if bays[i].get_area() > bays[big].get_area():
					big = i
			var carved := _carve_privet(bays[big], true)
			if (carved[1] as Rect2).size.y >= PRIVET_MIN:
				bays[big] = carved[0]
				privet = carved[1]
		var mid_y0 := plate.position.y + fd + (PRIVET_H if privet_end else 0.0)
		var mid_h := maxf(cut_y - mid_y0, 0.0)
		# A floor can only be asked for rooms it has the area to hold. Where the
		# house is too small for two real rooms, cutting a band in two produced
		# two rooms *both* under the manoeuvre-room floor — so keep the band
		# whole and let one room reach it. A small Prague house really did keep
		# one room per floor; gameplay wants one 18 m2 room on 90% of floors.
		var live_area := plate.get_area() - hall.get_area() - landing.get_area()
		if live_area < COMBAT_MIN * 2.2:
			bays = _bays(Rect2(fx, plate.position.y, fw, fd), DEPTH_BAYS_MAX, COMBAT_MIN, true)
		if privet.size.x < PRIVET_MIN and mid_h >= PRIVET_MIN + 0.2 and fw >= PRIVET_MIN:
			# Take it off the head of the middle passage instead.
			privet = Rect2(fx, mid_y0, minf(maxf(fw * 0.6, PRIVET_MIN), 2.4), minf(1.6, mid_h))
			mid_y0 += privet.size.y
			mid_h -= privet.size.y
		if privet.size.x < PRIVET_MIN and hall.size.y - 1.6 >= 1.3:
			# Last: the half-landing privy beside the stair.
			privet = Rect2(hall.position.x, hall.end.y - 1.6, hall.size.x, 1.6)
			hall = Rect2(hall.position, Vector2(hall.size.x, hall.size.y - 1.6))
		if privet.size.x < PRIVET_MIN and landing.size.y >= PRIVET_MIN + 0.4:
			# Nowhere else at all: the prevet comes off the landing by the stair,
			# which is where a Prague house kept the one that had no yard to sit
			# over. Every floor must have a WC; the contract test counts the
			# floors that end up without one.
			var lw := minf(maxf(stair_c.position.x - plate.position.x, 0.0), 2.0)
			if lw >= PRIVET_MIN:
				privet = Rect2(plate.position.x, landing.position.y, lw, PRIVET_H)
				landing = Rect2(Vector2(plate.position.x, landing.position.y + PRIVET_H), Vector2(landing.size.x, maxf(landing.size.y - PRIVET_H, 0.0)))
		if bays.is_empty():
			# No depth for a room on the street side: the whole head of the house
			# stays circulation rather than becoming a row of cupboards.
			cells.append([&"landing", Rect2(fx, plate.position.y, fw, fd), false])
		cells.append([&"stair_hall", hall, fi == 0])
		for i in bays.size():
			cells.append([_depth_front(fi, i, use, narrow), bays[i], fi == 0 and i == 0])
		var rbays: Array[Rect2] = []
		if rear.size.x > 0.0:
			# Keep the courtyard band as one working room. Splitting it across
			# the frontage leaves the second private bay behind the first one;
			# one full-depth cell can share the landing wall directly.
			rbays = _bays(rear, 1, maxf(NORMAL_MIN, COMBAT_MIN if live_area < COMBAT_MIN * 2.2 else NORMAL_MIN), false)
		for i in rbays.size():
			cells.append([_depth_back(fi, i, use, narrow, back_open), rbays[i], false])
		# The windowless middle: a cross passage everything reaches, and the store
		# behind it. This is the one part of the house no window can serve, so it
		# never holds a room.
		if mid_h >= 1.2:
			var cor_h := minf(CORRIDOR_H, mid_h)
			if mid_h - cor_h < 2.4:
				cor_h = mid_h
			cells.append([&"landing", Rect2(fx, mid_y0, fw, cor_h), false])
			if mid_h - cor_h >= 2.4:
				cells.append([&"storage", Rect2(fx, mid_y0 + cor_h, fw, mid_h - cor_h), false])
		var deep_h := maxf(plate.end.y - rbd - cut_y, 0.0)
		if rear_open and deep_h > 0.05:
			cells.append([&"storage", Rect2(sx, cut_y, rw, deep_h), false])
		if privet.size.x >= PRIVET_MIN and privet.size.y >= PRIVET_MIN:
			cells.append([&"toilet", privet, false])
		cells.append([&"landing", landing, false])
		# A floor of nothing but stores and landings is not a plan. Where the
		# stair, the privet and the passages have eaten every band, the largest
		# store becomes the room the floor is actually for - otherwise a 98 m2
		# house holds no room at all and the manoeuvre-room bar has nothing to
		# measure.
		var inhabited := false
		for cell0: Array in cells:
			if not (StringName(cell0[0]) in SERVICE_KINDS or StringName(cell0[0]) in CIRC_KINDS):
				inhabited = true
				break
		if not inhabited:
			var biggest := -1
			var best_area := 0.0
			for c_i in cells.size():
				var cr: Rect2 = cells[c_i][1]
				var kk := StringName(cells[c_i][0])
				if kk == &"toilet" or kk in CIRC_KINDS:
					continue
				# It must be a store that already reaches the street or the
				# courtyard; promoting the windowless middle store would only
				# manufacture a blind room.
				if not _cell_has_open_face(cr, plate, basis, spec):
					continue
				if cr.get_area() > best_area:
					best_area = cr.get_area()
					biggest = c_i
			if biggest >= 0:
				cells[biggest][0] = _depth_front(fi, 0, use, narrow)
		# Where the stair crowds the street, the landing - not the street band -
		# is where the space ends up: a 21 m2 approach beside a 9 m2 parlour.
		# Keep the approach to the stair and hand the surplus back as a room,
		# which is what a house with a deep plot does with its back half.
		var land_i := -1
		var land_area := 0.0
		for c_i2 in cells.size():
			var cr2: Rect2 = cells[c_i2][1]
			if StringName(cells[c_i2][0]) != &"landing":
				continue
			if cr2.get_area() > land_area:
				land_area = cr2.get_area()
				land_i = c_i2
		if land_i >= 0 and land_area >= COMBAT_MIN + 4.0:
			var lr: Rect2 = cells[land_i][1]
			var keep := clampf(maxf(stair_c.end.y - lr.position.y, 0.0) + 1.2, 2.0, lr.size.y)
			# Only a landing that already reaches the courtyard wall has light to
			# give: handing back the middle of the house would just make another
			# blind room, which is the one thing the plan must never do.
			var lit_end := absf(lr.end.y - plate.end.y) < 0.05 and back_open
			if lit_end and lr.size.y - keep >= BAND_DEPTH_MIN and lr.size.x >= ROOM_MIN_SIDE + 0.4:
				cells[land_i][1] = Rect2(lr.position, Vector2(lr.size.x, keep))
				cells.append([_depth_front(fi, 0, use, narrow),
					Rect2(lr.position.x, lr.position.y + keep, lr.size.x, lr.size.y - keep), false])
	# The audit probes the actual facade midpoint, not the first bay's origin.
	# Make that ground-floor cell the entry passage when it is service-scale or
	# otherwise service-only, so a narrow frontage never opens into a store.
	if fi == 0:
		var entry_point := Vector2(plate.get_center().x, plate.position.y + 0.6)
		for entry_i in cells.size():
			var entry_rect: Rect2 = cells[entry_i][1]
			if not entry_rect.has_point(entry_point):
				continue
			cells[entry_i][2] = true
			var entry_kind: StringName = cells[entry_i][0] as StringName
			if entry_kind in SERVICE_KINDS or entry_rect.get_area() < NORMAL_MIN:
				cells[entry_i][0] = &"landing"
			break
	for cell: Array in cells:
		var cell_rect: Rect2 = cell[1]
		if cell_rect.size.x < 1.0 or cell_rect.size.y < 1.0:
			continue
		var cell_kind: StringName = cell[0] as StringName
		# A tiny front cell is the historic sin (entry passage), not a service
		# room masquerading as a mazhaus. The audit accepts circulation here.
		if fi == 0 and bool(cell[2]) and cell_rect.get_area() < NORMAL_MIN:
			cell[0] = &"landing"
			cell_kind = &"landing"
		# Never promote a cell on a closed party wall to a habitable kind. Keep
		# its geometry as a real komora; preserve the ground entrance as an entry
		# passage when the public bay itself is too constrained.
		if not (cell_kind in SERVICE_KINDS or cell_kind in CIRC_KINDS) \
				and not _cell_has_open_face(cell_rect, plate, basis, spec):
			if fi == 0 and bool(cell[2]):
				cell[0] = &"landing"
			else:
				cell[0] = &"storage"
		rooms.append(room(bid, fi, rooms.size(), cell[0] as StringName, _rect_to_raw(cell_rect, basis), bool(cell[2])))
	var parts: Array = []
	var doors: Array = []
	var candidates: Array = []
	var solid_walls: Array = []
	for i in rooms.size():
		for j in range(i + 1, rooms.size()):
			var a: Rect2 = rooms[i].rect
			var b: Rect2 = rooms[j].rect
			var wall := Rect2()
			if absf(a.end.x - b.position.x) < 0.02 or absf(b.end.x - a.position.x) < 0.02:
				var lo := maxf(a.position.y, b.position.y)
				var hi := minf(a.end.y, b.end.y)
				if hi - lo >= 1.2:
					wall = Rect2(maxf(a.position.x, b.position.x) - 0.09, lo, 0.18, hi - lo)
			elif absf(a.end.y - b.position.y) < 0.02 or absf(b.end.y - a.position.y) < 0.02:
				var lo := maxf(a.position.x, b.position.x)
				var hi := minf(a.end.x, b.end.x)
				if hi - lo >= 1.2:
					wall = Rect2(lo, maxf(a.position.y, b.position.y) - 0.09, hi - lo, 0.18)
			if wall.size == Vector2.ZERO:
				continue
			var circulation_a: bool = rooms[i].kind in [&"stair_hall", &"landing"]
			var circulation_b: bool = rooms[j].kind in [&"stair_hall", &"landing"]
			var back_private_a: bool = StringName(rooms[i].kind) in CHAIN_PRIVATE_KINDS \
					and _room_touches_edge(rooms[i].rect, inner, back_edge)
			var back_private_b: bool = StringName(rooms[j].kind) in CHAIN_PRIVATE_KINDS \
					and _room_touches_edge(rooms[j].rect, inner, back_edge)
			var priority := int(circulation_a) + int(circulation_b)
			# Reserve a direct landing/crossing link for every private back bay
			# before ordinary room links consume the circulation degree budget.
			if (circulation_a and back_private_b) or (circulation_b and back_private_a):
				priority += 10
			candidates.append({"i": i, "j": j, "wall": wall, "priority": priority})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	var groups: Array[int] = []
	var degree := {}
	for i in rooms.size():
		groups.append(i)
		degree[i] = 0
	for link_pass in 3:
		var strict := link_pass < 2
		for candidate: Dictionary in candidates:
			var i: int = candidate.i
			var j: int = candidate.j
			var wall: Rect2 = candidate.wall
			if groups[i] == groups[j]:
				# Already linked: this boundary is a party wall. It used to be
				# recorded only on the first pass, so a pair that met in a repair
				# pass ended up with NO geometry at all and the player walked
				# between two rooms through a hole the plan never asked for.
				_add_solid(solid_walls, wall)
				continue
			if strict:
				# An ordinary room stops at two connections so a bedroom or a shop
				# is never a mandatory through-route; the stair hall and its landing
				# are the circulation spine and may serve three. A wall that loses
				# this contest stays solid geometry - nothing is faked shut.
				var cap_i: int = 3 if rooms[i].kind in [&"stair_hall", &"landing"] else 2
				var cap_j: int = 3 if rooms[j].kind in [&"stair_hall", &"landing"] else 2
				if int(degree[i]) >= cap_i or int(degree[j]) >= cap_j:
					_add_solid(solid_walls, wall)
					continue
			degree[i] = int(degree[i]) + 1
			degree[j] = int(degree[j]) + 1
			var old := groups[j]
			var replacement := groups[i]
			for k in groups.size():
				if groups[k] == old:
					groups[k] = replacement
			var vertical := wall.size.x < wall.size.y
			var wall_length: float = wall.size.y if vertical else wall.size.x
			# Passage openings sit in the 1.3-1.6 m band; a short party wall keeps
			# a narrower door rather than an opening wider than the wall itself.
			var span := minf(1.6, maxf(1.3, wall_length - 0.3))
			if wall_length - span < 0.2:
				span = maxf(0.9, wall_length - 0.2)
				if span > wall_length - 0.1:
					_add_solid(solid_walls, wall)
					continue
			var center := wall.get_center()
			if vertical and (rooms[i].kind == &"landing" or rooms[j].kind == &"landing"):
				var stair := BuildingBuilder.stair_zone_world(spec)
				center.y = clampf(stair.position.y + BuildingBuilder.LAND * 0.5, wall.position.y + span * 0.5, wall.end.y - span * 0.5)
			var opening := Rect2(center - Vector2(0.5, span * 0.5), Vector2(1.0, span)) if vertical else Rect2(center - Vector2(span * 0.5, 0.5), Vector2(span, 1.0))
			var id := "%s_f%d_partition_%d" % [bid, fi, parts.size()]
			parts.append({"id": id, "a": rooms[i].id, "b": rooms[j].id, "rect": wall, "opening": opening, "planned_clearance": true})
			doors.append({"id": id + "_door", "building_id": bid, "position": Vector3(center.x, fi * float(spec.floor_h), center.y),
				"yaw": PI * 0.5 if vertical else 0.0, "edge": -1, "width": span, "height": 2.05,
				"hinge": "left", "locked": false, "open_angle": 90.0, "swing": 1.0, "interior": true,
				"room_a": rooms[i].id, "room_b": rooms[j].id})
	return {"floor_i": fi, "rooms": rooms, "partitions": parts, "doors": doors,
		"stations": [], "solid_walls": solid_walls, "corridor_layout": true, "topology": "historic_wing", "use": use}

## Record a boundary as SOLID geometry (a wall with no opening). The link passes
## visit the same boundary up to three times, so the same wall rect must land in
## the list once.
static func _add_solid(solid_walls: Array, wall: Rect2) -> void:
	for w: Rect2 in solid_walls:
		if w.position.distance_to(wall.position) < 0.05 and w.size.distance_to(wall.size) < 0.05:
			return
	solid_walls.append(wall)


static func room(bid: String, fi: int, index: int, kind: StringName, rect: Rect2, entry: bool) -> Dictionary:
	return {"id": "%s_f%d_%s_%d" % [bid, fi, kind, index], "kind": kind, "rect": rect,
		"entry": entry, "service": kind == &"entry" or kind == &"toilet" or kind in SERVICE_KINDS}
