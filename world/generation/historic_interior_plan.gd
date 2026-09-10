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
	if rect.size.x < 6.6:
		# Narrow wing: the shaft keeps its own column and the rooms flank it, so a
		# narrow multi-storey house keeps stair access AND the contract's service
		# room + toilet on every floor. Room kinds are assigned in a fixed order so
		# the plan stays deterministic.
		var kinds := [&"workshop", &"toilet", &"storage"]
		var has_stair := BuildingBuilder.has_stairs_for(rect.size, float(spec.floor_h), int(spec.floors))
		var free: Array[Rect2] = []
		if has_stair:
			var stair := BuildingBuilder.stair_zone_world(spec)
			var zx0 := clampf(stair.position.x, inner.position.x, inner.end.x)
			var zx1 := clampf(stair.end.x, inner.position.x, inner.end.x)
			var land_y := clampf(stair.position.y, inner.position.y, inner.end.y)
			var land_end := clampf(stair.end.y, inner.position.y, inner.end.y)
			if land_end - land_y >= 1.0 and zx1 - zx0 >= 1.0:
				rooms.append(room(bid, fi, rooms.size(), &"landing", Rect2(zx0, land_y, zx1 - zx0, land_end - land_y), false))
				if land_y - inner.position.y >= 1.2:
					free.append(Rect2(inner.position.x, inner.position.y, inner.size.x, land_y - inner.position.y))
				if inner.end.y - land_end >= 1.2:
					free.append(Rect2(inner.position.x, land_end, inner.size.x, inner.end.y - land_end))
				if zx0 - inner.position.x >= 1.2:
					free.append(Rect2(inner.position.x, land_y, zx0 - inner.position.x, land_end - land_y))
				if inner.end.x - zx1 >= 1.2:
					free.append(Rect2(zx1, land_y, inner.end.x - zx1, land_end - land_y))
		if free.is_empty() and rooms.is_empty():
			# No landing was placed (the wing carries no shaft), so a three-room
			# stack is the fallback - never stacked over a placed landing.
			for i in 3:
				free.append(Rect2(inner.position + Vector2(0, inner.size.y * i / 3.0), Vector2(inner.size.x, inner.size.y / 3.0)))
		for slot in free.size():
			rooms.append(room(bid, fi, rooms.size(), kinds[slot % kinds.size()], free[slot], fi == 0 and slot == 0))
		# The contract needs a toilet on every floor: if the flank space only fit
		# one room, split it so the floor still has one.
		var has_toilet := false
		for r: Dictionary in rooms:
			if r.kind == &"toilet":
				has_toilet = true
				break
		if not has_toilet:
			var biggest := -1
			var best := 0.0
			for i in rooms.size():
				var r: Rect2 = rooms[i].rect
				if maxf(r.size.x, r.size.y) > best:
					best = maxf(r.size.x, r.size.y)
					biggest = i
			if biggest >= 0 and best >= 2.6:
				var split: Rect2 = rooms[biggest].rect
				if split.size.x >= split.size.y:
					rooms[biggest].rect = Rect2(split.position, Vector2(split.size.x - 1.2, split.size.y))
					rooms.append(room(bid, fi, rooms.size(), &"toilet", Rect2(split.end.x - 1.2, split.position.y, 1.2, split.size.y), false))
				else:
					rooms[biggest].rect = Rect2(split.position, Vector2(split.size.x, split.size.y - 1.2))
					rooms.append(room(bid, fi, rooms.size(), &"toilet", Rect2(split.position.x, split.end.y - 1.2, split.size.x, 1.2), false))
	else:
		var hall_width := 1.9
		var hall := Rect2(rect.get_center().x - hall_width * 0.5, inner.position.y, hall_width, inner.size.y)
		rooms.append(room(bid, fi, 0, &"stair_hall", hall, fi == 0))
		var right := Rect2(hall.end.x, inner.position.y, inner.end.x - hall.end.x, inner.size.y)
		var kinds: Array = GROUND_PROGRAMS.get(use, [&"living", &"sleeping", &"toilet"])
		# Three unequal longitudinal zones: lit street room, middle room,
		# courtyard service room. Alternate floors trade front/back depth.
		var fraction := 0.43 if fi % 2 == 0 else 0.35
		var cuts: Array[float] = [inner.position.y, inner.position.y + inner.size.y * fraction, inner.end.y - 2.0, inner.end.y]
		for i in 3:
			rooms.append(room(bid, fi, rooms.size(), kinds[i], Rect2(right.position.x, cuts[i], right.size.x, cuts[i + 1] - cuts[i]), false))
		var stair := BuildingBuilder.stair_zone_world(spec)
		var stair_y := maxf(inner.position.y, stair.position.y - 0.35)
		var stair_end := minf(inner.end.y, stair.end.y + 0.35)
		var left_width := hall.position.x - inner.position.x
		if stair_y - inner.position.y >= 1.0:
			rooms.append(room(bid, fi, rooms.size(), &"kitchen" if fi > 0 else &"workshop", Rect2(inner.position.x, inner.position.y, left_width, stair_y - inner.position.y), false))
		rooms.append(room(bid, fi, rooms.size(), &"landing", Rect2(inner.position.x, stair_y, left_width, stair_end - stair_y), false))
		if inner.end.y - stair_end >= 1.0:
			rooms.append(room(bid, fi, rooms.size(), &"kitchen", Rect2(inner.position.x, stair_end, left_width, inner.end.y - stair_end), false))
	var parts: Array = []
	var doors: Array = []
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
		"stations": [], "solid_walls": [], "corridor_layout": true, "topology": "historic_wing", "use": use}

static func room(bid: String, fi: int, index: int, kind: StringName, rect: Rect2, entry: bool) -> Dictionary:
	return {"id": "%s_f%d_%s_%d" % [bid, fi, kind, index], "kind": kind, "rect": rect,
		"entry": entry, "service": kind == &"toilet" or kind == &"storage"}
