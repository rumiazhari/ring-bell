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

static func floor_plan(spec: Dictionary, fi: int) -> Dictionary:
	var rect: Rect2 = spec.rect
	var inner := rect.grow(-0.37)
	var bid := str(spec.id)
	var rooms: Array = []
	var use := str((spec.floor_uses as Array)[fi])
	var kinds: Array = GROUND_PROGRAMS.get(use, [&"living", &"kitchen", &"toilet"])
	var has_stair := BuildingBuilder.has_stairs_for(rect.size, float(spec.floor_h), int(spec.floors))
	if not has_stair:
		# Service wings have one useful work room, not three equal cells.
		var toilet_depth := clampf(7.0 / inner.size.x, 1.3, inner.size.y * 0.3)
		rooms.append(room(bid, fi, 0, kinds[0], Rect2(inner.position, Vector2(inner.size.x, inner.size.y - toilet_depth)), fi == 0))
		rooms.append(room(bid, fi, 1, &"toilet", Rect2(inner.position.x, inner.end.y - toilet_depth, inner.size.x, toilet_depth), false))
	else:
		# Keep the physical shaft as the circulation anchor. Its entry landing
		# serves the courtyard room directly; the entry hall serves the street room.
		# Do not put a full-length central corridor through an already narrow wing.
		var stair := BuildingBuilder.stair_zone_world(spec)
		var circulation_end := stair.end.x + 0.18
		var cut_y := clampf(stair.position.y - 0.18, inner.position.y + 1.3, inner.end.y - 1.3)
		var hall := Rect2(inner.position, Vector2(circulation_end - inner.position.x, cut_y - inner.position.y))
		rooms.append(room(bid, fi, rooms.size(), &"stair_hall", hall, fi == 0))
		rooms.append(room(bid, fi, rooms.size(), &"landing", Rect2(inner.position.x, cut_y, hall.size.x, inner.end.y - cut_y), false))
		var flank := Rect2(circulation_end, inner.position.y, inner.end.x - circulation_end, inner.size.y)
		var toilet_depth := clampf(8.0 / flank.size.x, 1.3, 2.6)
		var usable := Rect2(flank.position, Vector2(flank.size.x, flank.size.y - toilet_depth))
		var street := Rect2(usable.position, Vector2(usable.size.x, cut_y - usable.position.y))
		var rear := Rect2(usable.position.x, cut_y, usable.size.x, usable.end.y - cut_y)
		# A partition is earned by two substantial resulting rooms. Narrow or
		# shallow exceptions remain one chamber instead of creating tiny bedrooms.
		if street.get_area() >= 18.0 and rear.get_area() >= 18.0 and street.size.y >= 3.5:
			rooms.append(room(bid, fi, rooms.size(), kinds[0], street, fi == 0))
			rooms.append(room(bid, fi, rooms.size(), &"kitchen" if fi > 0 else &"workshop", rear, false))
		else:
			rooms.append(room(bid, fi, rooms.size(), kinds[0], usable, fi == 0))
		rooms.append(room(bid, fi, rooms.size(), &"toilet", Rect2(flank.position.x, usable.end.y, flank.size.x, toilet_depth), false))
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
	for i in rooms.size():
		groups.append(i)
	for candidate: Dictionary in candidates:
		var i: int = candidate.i
		var j: int = candidate.j
		var wall: Rect2 = candidate.wall
		if groups[i] == groups[j]:
			solid_walls.append(wall)
			continue
		var old := groups[j]
		var replacement := groups[i]
		for k in groups.size():
			if groups[k] == old:
				groups[k] = replacement
		var vertical := wall.size.x < wall.size.y
		var span := minf(1.3, (wall.size.y if vertical else wall.size.x) - 0.3)
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
