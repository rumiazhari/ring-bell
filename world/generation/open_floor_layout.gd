class_name OpenFloorLayout
extends RefCounted
## Two straight walls at most. Reserve real entrance/stair geometry first;
## carve only peripheral essential rooms. Other room types are open furniture zones.

static func build(spec: Dictionary, fi: int, program: Array) -> Dictionary:
	var fp: Rect2 = spec["rect"]
	var inner := fp.grow(-0.37)
	var bid := str(spec.get("id", "b"))
	var keep: Array[Rect2] = []
	for local: Rect2 in BuildingBuilder.circulation_keepouts(spec, fi):
		local.position += fp.position
		keep.append(local.grow(0.12))
	if fi == 0:
		# The facade entrance exists only on the ground floor.
		var entry_box := BuildingBuilder._entrance_box(fp.size, int(spec.get("door_edge", 0)))
		entry_box.position += fp.position
		keep.append(entry_box)
		for edge: int in spec.get("extra_door_edges", []):
			var box := BuildingBuilder._entrance_box(fp.size, edge)
			box.position += fp.position
			keep.append(box)
			var center := inner.get_center()
			var start := box.get_center()
			keep.append(Rect2(start.min(center), (start - center).abs()).grow(0.75))
	var rooms: Array = []
	var parts: Array = []
	var solids: Array = []
	var remaining: Array[Rect2] = [inner]
	var enclosed: Array[String] = []
	var enclosed_cells: Array[Rect2] = []
	# A corner WC needs just two boards and uses the exterior walls for its
	# other sides. Try strips first: they need only one board, leaving a second
	# board available for a bedroom or back room on sufficiently large floors.
	var private_kind := _private_kind(program)
	for kind: StringName in [&"toilet", private_kind]:
		if parts.size() + solids.size() >= 2:
			break
		var found := false
		for ri in remaining.size():
			var plate := remaining[ri]
			var depth := 2.0 if kind == &"toilet" else 3.0
			for edge in 4:
				var cell := _strip(plate, edge, depth)
				var wall := _boundary(cell, edge)
				if inner.get_area() < 180.0 or cell.get_area() > inner.get_area() * 0.22 \
						or _hits(cell.grow(0.12), keep) \
						or _hits(cell.grow(0.02), enclosed_cells) \
						or minf(plate.size.x, plate.size.y) < depth + 3.0:
					continue
				var rest := BuildingBuilder._rect_subtract(plate, cell)
				var rid := "%s_f%d_%s" % [bid, fi, kind]
				rooms.append(_room(rid, kind, cell, true))
				enclosed.append(rid)
				enclosed_cells.append(cell)
				parts.append({"rect": wall, "opening": _opening(wall), "b": rid})
				keep.append(_opening(wall).grow(0.7))
				remaining.remove_at(ri)
				remaining.append_array(rest)
				found = true
				break
			if found:
				break
		if kind != &"toilet" or found:
			continue
		# Tight floors: two-board corner bathroom, never a wall across circulation.
		for corner in 4:
			var size := Vector2(2.8, 2.8)
			var pos := Vector2(inner.position.x if corner % 2 == 0 else inner.end.x - size.x,
				inner.position.y if corner < 2 else inner.end.y - size.y)
			var cell := Rect2(pos, size)
			if not inner.encloses(cell) or _hits(cell.grow(0.1), keep) or cell.get_area() > inner.get_area() * 0.35:
				continue
			var rid := "%s_f%d_toilet" % [bid, fi]
			rooms.append(_room(rid, &"toilet", cell, true))
			enclosed.append(rid)
			enclosed_cells.append(cell)
			var wall := _boundary(cell, 0 if corner < 2 else 2)
			parts.append({"rect": wall, "opening": _opening(wall), "b": rid})
			solids.append(_boundary(cell, 3 if corner % 2 == 0 else 1))
			remaining = BuildingBuilder._rect_subtract(inner, cell)
			break
	# Preserve use-specific gameplay zones without deriving walls from adjacency.
	var kinds: Array = []
	for kind: StringName in program:
		var exists := false
		for r: Dictionary in rooms:
			if r["kind"] == kind:
				exists = true
		if not exists:
			kinds.append(kind)
	if kinds.has(&"toilet"):
		kinds.erase(&"toilet")
		kinds.push_front(&"toilet")
	# Stair-only remnants are halls, not usable furniture zones. Split the
	# usable plate instead of assigning a bedroom to the stair footprint.
	var usable := 0
	for r in remaining:
		if _free_area(r, keep) >= 3.0:
			usable += 1
	while usable < kinds.size():
		var idx := 0
		for i in remaining.size():
			if _free_area(remaining[i], keep) > _free_area(remaining[idx], keep):
				idx = i
		var r := remaining[idx]
		var along_x := r.size.x > r.size.y
		if (r.size.x if along_x else r.size.y) < 3.0:
			break
		var first := r
		first.size *= Vector2(0.5, 1.0) if along_x else Vector2(1.0, 0.5)
		remaining.remove_at(idx)
		remaining.append(first)
		remaining.append(Rect2(first.position + (Vector2(first.size.x, 0) if along_x else Vector2(0, first.size.y)), first.size))
		usable = 0
		for piece in remaining:
			if _free_area(piece, keep) >= 3.0:
				usable += 1
	var ordered: Array[Rect2] = []
	var pool := remaining.duplicate()
	while not pool.is_empty():
		var best := 0
		for i in pool.size():
			if _free_area(pool[i], keep) > _free_area(pool[best], keep):
				best = i
		ordered.append(pool.pop_at(best))
	var next_kind := 0
	for i in ordered.size():
		var kind: StringName = kinds[next_kind] if next_kind < kinds.size() else &"hall"
		next_kind += 1
		rooms.append(_room("%s_f%d_open%d" % [bid, fi, i], kind, ordered[i], false))
		if kind != &"hall":
			keep.append(Rect2(ordered[i].get_center() - Vector2(0.45, 0.45), Vector2(0.9, 0.9)))
	var links: Array = []
	for a: Dictionary in rooms:
		if enclosed.has(a["id"]):
			continue
		for b: Dictionary in rooms:
			if a == b or enclosed.has(b["id"]):
				continue
			if _shared(a["rect"], b["rect"]) >= 0.9:
				links.append([a["id"], b["id"]])
	for part: Dictionary in parts:
		part["id"] = "%s_f%d_p%d" % [bid, fi, parts.find(part)]
		part["planned_clearance"] = true
		var opening: Rect2 = part["opening"]
		for room: Dictionary in rooms:
			if not enclosed.has(room["id"]) and (room["rect"] as Rect2).grow(0.01).has_point(opening.get_center()):
				part["a"] = room["id"]
				break
		# Clearance into both sides of every aperture; furniture shares this list.
		keep.append(opening.grow(0.7))
	return {"floor_i": fi, "rooms": rooms, "partitions": parts, "solid_walls": solids,
		"circulation": keep, "open_connections": links, "topology": "open_plan"}

static func _room(id: String, kind: StringName, rect: Rect2, enclosed: bool) -> Dictionary:
	return {"id": id, "kind": kind, "rect": rect, "entry": not enclosed,
		"service": kind in [&"toilet", &"storage", &"store_room", &"archive"], "enclosed": enclosed}

static func _private_kind(program: Array) -> StringName:
	for kind: StringName in [&"sleeping", &"storage", &"store_room", &"archive",
			&"toolstore", &"dispensary", &"holding"]:
		if program.has(kind):
			return kind
	return &"storage"

static func _strip(r: Rect2, edge: int, depth: float) -> Rect2:
	match edge:
		0: return Rect2(r.position, Vector2(r.size.x, depth))
		1: return Rect2(r.end.x - depth, r.position.y, depth, r.size.y)
		2: return Rect2(r.position.x, r.end.y - depth, r.size.x, depth)
		_: return Rect2(r.position, Vector2(depth, r.size.y))

static func _boundary(r: Rect2, edge: int) -> Rect2:
	match edge:
		0: return Rect2(r.position.x, r.end.y - 0.09, r.size.x, 0.18)
		1: return Rect2(r.position.x - 0.09, r.position.y, 0.18, r.size.y)
		2: return Rect2(r.position.x, r.position.y - 0.09, r.size.x, 0.18)
		_: return Rect2(r.end.x - 0.09, r.position.y, 0.18, r.size.y)

static func _opening(wall: Rect2) -> Rect2:
	var size := Vector2(WorldConstants.CITY_INTERIOR_OPEN_W, 1.0) if wall.size.x > wall.size.y else Vector2(1.0, WorldConstants.CITY_INTERIOR_OPEN_W)
	return Rect2(wall.get_center() - size * 0.5, size)

static func _hits(r: Rect2, keep: Array[Rect2]) -> bool:
	for k in keep:
		if r.intersects(k):
			return true
	return false

static func _shared(a: Rect2, b: Rect2) -> float:
	if absf(a.end.x - b.position.x) < 0.02 or absf(b.end.x - a.position.x) < 0.02:
		return minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	if absf(a.end.y - b.position.y) < 0.02 or absf(b.end.y - a.position.y) < 0.02:
		return minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	return 0.0

static func _free_area(r: Rect2, keep: Array[Rect2]) -> float:
	var pieces: Array[Rect2] = [r]
	for obstacle in keep:
		var next: Array[Rect2] = []
		for piece in pieces:
			next.append_array(BuildingBuilder._rect_subtract(piece, obstacle))
		pieces = next
	var area := 0.0
	for piece in pieces:
		area += piece.get_area()
	return area
