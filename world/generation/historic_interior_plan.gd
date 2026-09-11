class_name HistoricInteriorPlan
extends RefCounted
## Rooms follow the passage and the existing physical stair shaft. Plans use
## the same unrotated world-coordinate convention as InteriorPlan.

## Ground-floor programs per use: a historic house carries several uses at once,
## so the street room, the middle room and the courtyard room differ in program
## rather than only in label (shop / workshop / tavern / store / caretaker).
const GROUND_PROGRAMS := {
	"retail": [&"sales", &"storage", &"toilet"],
	"workshop": [&"workshop", &"storage", &"toilet"],
	"office": [&"office", &"archive", &"toilet"],
	"tavern": [&"taproom", &"kitchen", &"toilet"],
	"storage": [&"warehouse", &"store_room", &"toilet"],
	"caretaker": [&"living", &"kitchen", &"toilet"],
}

## --- Phase 2 area tiers (m^2) ------------------------------------------------
## A historic floor is a small number of real rooms, not a dungeon maze. The
## minimums are what make the partition rule honest: a cut is only taken when
## every resulting room clears the smallest room its tier allows.
const PRINCIPAL_MIN := 22.0
const NORMAL_MIN := 12.0
const SERVICE_MIN := 6.0
const SERVICE_MAX := 10.0
const COMBAT_MIN := 18.0        # one manoeuvre room on every normal floor
const ROOM_MIN_SIDE := 1.8      # narrower than this is furniture, not a room
const ROOM_MAX_RATIO := 2.6     # longer than this reads as a corridor
const SUBDIVIDE_TARGET := 18.0  # m^2 target for one substantial room
const SPLIT_FLOOR := 28.8       # a zone above this is halved into two real rooms
const MAX_SUBSTANTIAL := 8      # upper bound for very large historic plates

## Substantial-room programs. Service spaces (toilet band, stores) are added
## separately and never count as tiers, so a floor is never "two toilets and a
## corridor". A ground floor mixes uses the way a real historic house does.
const TIER_PROGRAMS := {
	"retail": [&"sales", &"sales", &"office"],
	"workshop": [&"workshop", &"workshop", &"office"],
	"office": [&"office", &"archive", &"office"],
	"tavern": [&"taproom", &"kitchen", &"taproom"],
	"storage": [&"warehouse", &"store_room", &"warehouse"],
	"caretaker": [&"living", &"kitchen", &"kitchen"],
}
const UPPER_TIERS: Array = [&"sleeping", &"living", &"kitchen", &"sleeping"]

static func _tier_kinds(use: String, fi: int) -> Array:
	if fi == 0:
		return TIER_PROGRAMS.get(use, [&"living", &"kitchen", &"living"])
	return UPPER_TIERS

static func _tier_kind(use: String, fi: int, index: int) -> StringName:
	var kinds := _tier_kinds(use, fi)
	return kinds[mini(index, kinds.size() - 1)]

## Split a zone into substantial rooms by repeated halving: always cut the long
## axis in half, so pieces stay squarish however large the plate is. Every split
## must leave both halves above NORMAL_MIN and above the minimum side, otherwise
## the zone stays one larger room. A 90 m^2 flank becomes four 22 m^2 rooms; a
## 4 m deep wing becomes chambers along its length, not corridor slivers.
static func _subdivide_zone(zone: Rect2, tiers: Array) -> Array[Rect2]:
	var pieces: Array[Rect2] = [zone]
	if zone.get_area() < NORMAL_MIN:
		return pieces
	var budget := clampi(int(round(zone.get_area() / SUBDIVIDE_TARGET)), 2, MAX_SUBSTANTIAL)
	while pieces.size() < budget:
		var index := -1
		var largest := 0.0
		for i in pieces.size():
			if pieces[i].get_area() < SPLIT_FLOOR or pieces[i].get_area() <= largest:
				continue
			if _halve(pieces[i]).size() != 2:
				continue
			largest = pieces[i].get_area()
			index = i
		if index < 0:
			break
		var halves := _halve(pieces[index])
		pieces.remove_at(index)
		pieces.append(halves[0])
		pieces.append(halves[1])
	return pieces

static func _halve(zone: Rect2) -> Array[Rect2]:
	var vertical := zone.size.x >= zone.size.y
	var first: Rect2
	var second: Rect2
	if vertical:
		first = Rect2(zone.position, Vector2(zone.size.x * 0.5, zone.size.y))
		second = Rect2(zone.position + Vector2(zone.size.x * 0.5, 0.0), Vector2(zone.size.x * 0.5, zone.size.y))
	else:
		first = Rect2(zone.position, Vector2(zone.size.x, zone.size.y * 0.5))
		second = Rect2(zone.position + Vector2(0.0, zone.size.y * 0.5), Vector2(zone.size.x, zone.size.y * 0.5))
	for piece: Rect2 in [first, second]:
		if piece.get_area() < NORMAL_MIN or minf(piece.size.x, piece.size.y) < ROOM_MIN_SIDE:
			return []
	return [first, second]

static func floor_plan(spec: Dictionary, fi: int) -> Dictionary:
	var rect: Rect2 = spec.rect
	var inner := rect.grow(-0.37)
	var bid := str(spec.id)
	var rooms: Array = []
	var use := str((spec.floor_uses as Array)[fi])
	var kinds: Array = GROUND_PROGRAMS.get(use, [&"living", &"kitchen", &"toilet"])
	var has_stair := BuildingBuilder.has_stairs_for(rect.size, float(spec.floor_h), int(spec.floors))
	var one_plate := inner.size.y < 3.6 or inner.size.x < 3.2
	if not has_stair or one_plate:
		# Service wings have one useful work room, not three equal cells. A house
		# too small for a passage AND a landing at once is planned the same way,
		# but its plate IS the stair landing when the building carries a stair, so
		# every upper floor keeps its reachability.
		var plate: StringName = &"stair_hall" if has_stair else kinds[0]
		var toilet_depth := clampf(7.0 / maxf(inner.size.x, 1.0), 1.3, maxf(inner.size.y * 0.3, 1.3))
		toilet_depth = minf(toilet_depth, maxf(inner.size.y - 1.0, 1.3))
		rooms.append(room(bid, fi, 0, plate, Rect2(inner.position, Vector2(inner.size.x, inner.size.y - toilet_depth)), fi == 0))
		rooms.append(room(bid, fi, 1, &"toilet", Rect2(inner.position.x, inner.end.y - toilet_depth, inner.size.x, toilet_depth), false))
	else:
		# Keep the physical shaft as the circulation anchor. The stairwell column
		# holds the stair; the entry hall beside it is a real 1.5-2.0 m passage
		# (a hall-sized room is what the player was crossing before). The street
		# band and the rear band then each hold their own substantial rooms, so a
		# floor reads as entry passage -> stair -> rooms instead of one big plate.
		var stair := BuildingBuilder.stair_zone_world(spec)
		var shaft_end := stair.end.x + 0.18
		var cut_y := clampf(stair.position.y - 0.18, inner.position.y + 1.3, inner.end.y - 1.3)
		var hall_w := clampf(1.35 + inner.size.x * 0.08, 1.5, 2.0)
		var street_zone := Rect2(inner.position.x + hall_w, inner.position.y, inner.end.x - inner.position.x - hall_w, cut_y - inner.position.y)
		var street_ok := street_zone.get_area() >= NORMAL_MIN and minf(street_zone.size.x, street_zone.size.y) >= ROOM_MIN_SIDE
		if not street_ok:
			# Too narrow for a passage beside the stair: the entry keeps the whole
			# street band rather than inventing a sliver room.
			hall_w = shaft_end - inner.position.x
			street_zone = Rect2(inner.position.x, inner.position.y, 0.0, 0.0)
		var hall := Rect2(inner.position, Vector2(hall_w, cut_y - inner.position.y))
		rooms.append(room(bid, fi, rooms.size(), &"stair_hall", hall, fi == 0))
		var landing := Rect2(inner.position.x, cut_y, maxf(shaft_end - inner.position.x, 0.0), maxf(inner.end.y - cut_y, 0.0))
		rooms.append(room(bid, fi, rooms.size(), &"landing", landing, false))
		var tiers := _tier_kinds(use, fi)
		var rear_width := maxf(inner.end.x - shaft_end, 0.0)
		var rear_depth := maxf(inner.end.y - cut_y, 0.0)
		# Service first: the toilet is the one room the interior contract always
		# requires, so a shallow or narrow infill house takes it from whichever
		# band can really hold it - never as a degenerate sliver that overlaps
		# the stair landing.
		var toilet := Rect2()
		if rear_width >= 2.4 and rear_depth >= 3.4:
			var depth := minf(clampf(8.0 / rear_width, 1.3, 2.4), rear_depth - 2.0)
			if depth >= 1.2:
				toilet = Rect2(shaft_end, inner.end.y - depth, rear_width, depth)
		if toilet.size == Vector2.ZERO and street_zone.size.x >= 3.2 and street_zone.size.y >= 2.6:
			var wc := clampf(6.0 / street_zone.size.y, 1.4, 2.0)
			if street_zone.size.x - wc >= 1.4:
				toilet = Rect2(street_zone.end.x - wc, street_zone.position.y, wc, street_zone.size.y)
				street_zone = Rect2(street_zone.position, Vector2(street_zone.size.x - wc, street_zone.size.y))
		var rear_zone := Rect2(shaft_end, cut_y, rear_width, maxf(rear_depth - toilet.size.y, 0.0))
		var pieces: Array[Rect2] = []
		if street_ok and minf(street_zone.size.x, street_zone.size.y) >= ROOM_MIN_SIDE:
			pieces.append_array(_subdivide_zone(street_zone, tiers))
		if rear_zone.get_area() >= SERVICE_MIN and minf(rear_zone.size.x, rear_zone.size.y) >= 1.0:
			pieces.append_array(_subdivide_zone(rear_zone, tiers))
		if toilet.size == Vector2.ZERO and not pieces.is_empty():
			# Last resort: carve the WC out of the largest room rather than leave
			# the floor without one.
			var big := 0
			for i in pieces.size():
				if pieces[i].get_area() > pieces[big].get_area():
					big = i
			var piece := pieces[big]
			if minf(piece.size.x, piece.size.y) >= 2.4:
				toilet = Rect2(piece.end.x - 1.4, piece.position.y, 1.4, piece.size.y)
				pieces[big] = Rect2(piece.position, Vector2(piece.size.x - 1.4, piece.size.y))
		if toilet.size.x >= 1.0 and toilet.size.y >= 1.0:
			rooms.append(room(bid, fi, rooms.size(), &"toilet", toilet, false))
		for pi in pieces.size():
			rooms.append(room(bid, fi, rooms.size(), _tier_kind(use, fi, pi), pieces[pi], fi == 0 and pi == 0))
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
			candidates.append({"i": i, "j": j, "wall": wall, "priority": int(circulation_a) + int(circulation_b)})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	var groups: Array[int] = []
	var degree := {}
	for i in rooms.size():
		groups.append(i)
		degree[i] = 0
	for link_pass in 3:
		var repairing := link_pass > 0
		var strict := link_pass < 2
		for candidate: Dictionary in candidates:
			var i: int = candidate.i
			var j: int = candidate.j
			var wall: Rect2 = candidate.wall
			if groups[i] == groups[j]:
				if not repairing:
					solid_walls.append(wall)
				continue
			if strict:
				# An ordinary room stops at two connections so a bedroom or a shop
				# is never a mandatory through-route; the stair hall and its landing
				# are the circulation spine and may serve three. A wall that loses
				# this contest stays solid geometry - nothing is faked shut.
				var cap_i: int = 3 if rooms[i].kind in [&"stair_hall", &"landing"] else 2
				var cap_j: int = 3 if rooms[j].kind in [&"stair_hall", &"landing"] else 2
				if int(degree[i]) >= cap_i or int(degree[j]) >= cap_j:
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

static func room(bid: String, fi: int, index: int, kind: StringName, rect: Rect2, entry: bool) -> Dictionary:
	return {"id": "%s_f%d_%s_%d" % [bid, fi, kind, index], "kind": kind, "rect": rect,
		"entry": entry, "service": kind == &"toilet" or kind == &"storage"}
