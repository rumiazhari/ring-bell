class_name InteriorPlan
extends RefCounted
const HistoricInterior = preload("res://world/generation/historic_interior_plan.gd")

const ROOM_PROGRAMS := {
	"residential": [&"living", &"kitchen", &"sleeping", &"toilet"],
	"retail": [&"sales", &"storage", &"workshop", &"toilet"],
	"office": [&"office", &"archive", &"meeting", &"toilet"],
	"workshop": [&"machine_shop", &"toolstore", &"craft", &"toilet"],
	"police": [&"reception", &"office", &"holding", &"toilet"],
	"hospital": [&"ward", &"surgery", &"dispensary", &"toilet"],
	"government": [&"reception", &"council", &"archive", &"toilet"],
	"tavern": [&"taproom", &"kitchen", &"store_room", &"toilet"],
	"storage": [&"warehouse", &"store_room", &"loading", &"toilet"],
	"caretaker": [&"living", &"kitchen", &"store_room", &"toilet"],
}

## Fallback room kinds when a program row slot has no furniture program:
## keeps every furnished room populated while allowing per-use variation.
const ROOM_PROGRAM_FALLBACKS := {
	"meeting": ["documents", "bench", "shelf"],
	"machine_shop": ["machine", "workbench"],
	"toolstore": ["shelf", "workbench", "shelf"],
	"craft": ["workbench", "shelf", "documents"],
}

const WALL_T := 0.35 # outer wall legacy (CityPlan lot inset)
const DOOR_W := WorldConstants.DOOR_W_PERSON   # one authority: DOOR_KIND_W
# City interior partition thickness and opening authoritative via WorldConstants (G9 M1)
const WALL_T_INTERIOR: float = 0.18 # == WorldConstants.CITY_INTERIOR_WALL_T
const OPEN_W: float = WorldConstants.CITY_INTERIOR_OPEN_W # one authority for interior leaf/aperture
const OPEN_H: float = WorldConstants.CITY_INTERIOR_OPEN_H

static func build_for_building(spec: Dictionary) -> Dictionary:
	var bid: String = str(spec.get("id", "b"))
	var floors: int = int(spec.get("floors", 1))
	var fh: float = float(spec.get("floor_h", 3.0))
	var rect: Rect2 = spec.get("rect", Rect2(0,0,10,10))
	var style: Dictionary = spec.get("style", {})
	var legacy_rt: String = str(style.get("room_type", "residential"))
	var use_val: String = str(spec.get("use", legacy_rt))
	if not ROOM_PROGRAMS.has(use_val):
		use_val = legacy_rt if legacy_rt == "retail" else "residential"
	var inset := WALL_T + 0.02
	var inner := Rect2(rect.position + Vector2(inset, inset), rect.size - Vector2(inset*2, inset*2))
	var small := inner.size.x < 4.5 or inner.size.y < 4.5
	var manifest := {
		"version": 1,
		"building_id": bid,
		"use": use_val,
		"floors": [],
	}
	for fi in floors:
		var floor_dict: Dictionary
		if spec.has("compound_id"):
			floor_dict = HistoricInterior.floor_plan(spec, fi)
		elif rect.size.x >= 9.0 and rect.size.y >= 12.0:
			floor_dict = _corridor_floor(bid, fi, use_val, inner, spec, fh)
		else:
			floor_dict = _floor_manifest(bid, fi, use_val, inner, rect, spec, small, fh)
		floor_dict["furniture"] = _room_furniture(floor_dict, spec)
		floor_dict["stations"] = []
		for item: Dictionary in floor_dict["furniture"]:
			if item["kind"] == "bed" or item["kind"] == "counter":
				floor_dict["stations"].append({"id": item["id"] + "_station", "room_id": item["room_id"], "kind": item["kind"], "position": item["position"], "yaw": 0.0, "visual": false, "loot": &"canned_food"})
		manifest["floors"].append(floor_dict)
	return manifest

## Corridor floors: ground floor is a LOBBY (G10 requirement) with a toilet
## cell; upper floors stream the use's rooms off a 4 m hall. Two deterministic
## topologies for variation: A = single row against the divider, B = staggered
## two-column grid. Every shared edge carries a partition WITH a door leaf, so
## no room can end up sealed and door swings stay inside planned clearances.
## Walls never cross stairs (hall side holds the stair zone on every edge).
static func _corridor_floor(bid: String, fi: int, use_val: String, inner: Rect2, spec: Dictionary, fh: float) -> Dictionary:
	var fp: Rect2 = spec["rect"]
	var east_hall := int(spec.get("door_edge", 0)) == 3
	var hall_width := 4.0
	var divider := inner.end.x - hall_width if east_hall else inner.position.x + hall_width
	var hall := Rect2(divider if east_hall else inner.position.x, inner.position.y, hall_width, inner.size.y)
	var hall_id := "%s_f%d_hall" % [bid, fi]
	var rooms: Array = [{"id": hall_id, "kind": &"hall", "rect": hall, "entry": fi == 0, "service": false}]
	var parts: Array = []
	var solid_walls: Array = []
	var doors: Array = []
	var rng := WorldSeed.rng_for_seed(int(spec.get("seed_used", WorldSeed.get_world_seed())), "interior", [WorldSeed.str_hash(bid), fi])
	# ---- Ground floor: one big LOBBY (the whole inner minus a toilet strip) —
	# "mainly lobby" per G10 steering. The toilet strip sits at the end
	# OPPOSITE the stairwell zone so it never overlaps stairs/risers:
	#   N entrance (0) -> zone SOUTH -> toilet NORTH   S (2) -> toilet SOUTH
	#   E entrance (1) -> zone WEST  -> toilet EAST    W (3) -> toilet WEST
	if fi == 0:
		var toilet_t := 3.2
		var lobby_rect: Rect2
		var toilet_rect: Rect2
		var horiz_sep := true   # separator wall is horizontal (N/S toilet strip)
		var edge := int(spec.get("door_edge", 0))
		match edge:
			1:   # toilet strip on EAST wall (vertical strip)
				lobby_rect = Rect2(inner.position, Vector2(inner.size.x - toilet_t, inner.size.y))
				toilet_rect = Rect2(Vector2(lobby_rect.end.x, inner.position.y), Vector2(toilet_t, inner.size.y))
				horiz_sep = false
			3:   # toilet strip on WEST wall
				toilet_rect = Rect2(inner.position, Vector2(toilet_t, inner.size.y))
				lobby_rect = Rect2(Vector2(inner.position.x + toilet_t, inner.position.y), Vector2(inner.size.x - toilet_t, inner.size.y))
				horiz_sep = false
			2:   # south entrance -> stair zone north -> toilet SOUTH (original behavior)
				lobby_rect = Rect2(inner.position, Vector2(inner.size.x, inner.size.y - toilet_t))
				toilet_rect = Rect2(Vector2(inner.position.x, inner.end.y - toilet_t), Vector2(inner.size.x, toilet_t))
			_:   # north entrance (default) -> stair zone south -> toilet NORTH
				toilet_rect = Rect2(inner.position, Vector2(inner.size.x, toilet_t))
				lobby_rect = Rect2(Vector2(inner.position.x, inner.position.y + toilet_t), Vector2(inner.size.x, inner.size.y - toilet_t))
		var lobby_id := "%s_f0_lobby_1" % bid
		# Ground floor payload: Toilet + Lobby ONLY (the former hall band is
		# dissolved into the lobby). Partition `a`/`b` are the two rooms it
		# actually separates; the entry door serves the lobby via the facade.
		rooms.clear()
		parts.clear()
		rooms.append({"id": lobby_id, "kind": &"lobby", "rect": lobby_rect, "entry": fi == 0, "service": false})
		rooms.append({"id": "%s_f0_toilet_2" % bid, "kind": &"toilet", "rect": toilet_rect, "entry": false, "service": true})
		# Separator between toilet and lobby: 0.18 thick, aperture 1.3 x 1.0,
		# centered on the shared edge with 0.3 m standoffs from the side walls.
		# planned_clearance: frame is contract-owned; this wall never crosses
		# the stair zone (opposite end) or entry aisles (facade midpoint).
		var wall: Rect2
		var topen: Rect2
		if horiz_sep:
			var wx0 := lobby_rect.position.x + 0.3
			var wx1 := lobby_rect.end.x - 0.3
			var wy := toilet_rect.position.y if edge == 2 else lobby_rect.position.y - 0.09
			wall = Rect2(wx0, wy, wx1 - wx0, 0.18)
			var wcx := wall.get_center().x
			topen = Rect2(wcx - OPEN_W * 0.5, wall.position.y - 0.5 + 0.09, OPEN_W, 1.0)
		else:
			var wy0 := lobby_rect.position.y + 0.3
			var wy1 := lobby_rect.end.y - 0.3
			var wx := lobby_rect.end.x - 0.09 if edge == 1 else lobby_rect.position.x
			wall = Rect2(wx, wy0, 0.18, wy1 - wy0)
			var wcy := wall.get_center().y
			topen = Rect2(wall.position.x - 0.5 + 0.09, wcy - OPEN_W * 0.5, 1.0, OPEN_W)
		parts.append({"id": "%s_f0_p0" % bid, "a": lobby_id, "b": "%s_f0_toilet_2" % bid, "rect": wall, "opening": topen, "planned_clearance": true})
		var tdm := _door_for_partition(bid, 0, doors.size(), topen, wall, lobby_id, "%s_f0_toilet_2" % bid, fh, rng)
		# Leaf span equals the aperture span along the wall.
		tdm["width"] = topen.size.x if horiz_sep else topen.size.y
		doors.append(tdm)
		# Lobby dressing: per-use Victorian program replaces the generic hall
		# furniture list; keep the room id in sync so blocked/sweep keepouts hit.
		return {"floor_i": fi, "rooms": rooms, "partitions": parts, "doors": doors, "stations": [], "corridor_layout": true, "solid_walls": [], "topology": "lobby",
			"lobby_use": use_val}
	# ---- Upper floors: three depth profiles (see comment below) + room row
	# with a door on every hall edge. Pantry dropped from generic middle rooms.
	var kinds: Array = ROOM_PROGRAMS[use_val]
	var prof := int(WorldSeed.rng_for_seed(int(spec.get("seed_used", WorldSeed.get_world_seed())), "interior_topo", [WorldSeed.str_hash(bid)]).randf_range(0, 3.0))
	var inner_y: float = inner.size.y
	var cut1: float
	var cut2: float
	var cut3: float
	match prof:
		1:   # deep-rear: front rooms tighter
			cut1 = maxf(inner.position.y + inner_y * 0.15, inner.position.y + 2.9)
			cut2 = maxf(cut1 + inner_y * 0.15, cut1 + 2.9)
			cut3 = maxf(cut2 + inner_y * 0.35, cut2 + 2.8)
		2:   # deep-front: public front rooms roomier
			cut1 = maxf(inner.position.y + inner_y * 0.25, inner.position.y + 2.9)
			cut2 = maxf(cut1 + inner_y * 0.25, cut1 + 2.9)
			cut3 = maxf(cut2 + inner_y * 0.25, cut2 + 2.8)
		_:   # balanced (original shape)
			cut1 = maxf(inner.position.y + inner_y * 0.20, inner.position.y + 2.9)
			cut2 = maxf(cut1 + inner_y * 0.20, cut1 + 2.9)
			cut3 = maxf(cut2 + inner_y * 0.30, cut2 + 2.8)
	var cuts: Array[float] = [inner.position.y, cut1, cut2, minf(cut3, inner.end.y - 2.0), inner.end.y]
	for i in 4:
		var room := Rect2(inner.position.x if east_hall else divider, cuts[i], divider - inner.position.x if east_hall else inner.end.x - divider, cuts[i + 1] - cuts[i])
		var room_id := "%s_f%d_%s_%d" % [bid, fi, kinds[i], i]
		rooms.append({"id": room_id, "kind": kinds[i], "rect": room, "entry": false, "service": kinds[i] == &"toilet"})
		var door_y := room.get_center().y
		if i == 0:
			door_y = fp.position.y + 1.4
		elif i == 3:
			door_y = fp.end.y - 1.4
		elif i == 2:
			door_y = fp.get_center().y
		var wall := Rect2(divider - 0.09, room.position.y, 0.18, room.size.y)
		var opening := Rect2(divider - 0.5, door_y - OPEN_W * 0.5, 1.0, OPEN_W)
		parts.append({"id": "%s_f%d_p%d" % [bid, fi, parts.size()], "a": hall_id, "b": room_id, "rect": wall, "opening": opening, "planned_clearance": true})
		var dm := _door_for_partition(bid, fi, doors.size(), opening, wall, hall_id, room_id, fh, rng)
		# Leaf span must equal the aperture span along the wall (OPEN_W here):
		# derive it from the opening instead of a re-typed magic constant. This
		# wall is vertical (size.x=0.18), so the aperture length is size.y.
		dm["width"] = opening.size.y
		doors.append(dm)
		if i > 0:
			solid_walls.append(Rect2(room.position.x, room.position.y - 0.09, room.size.x, 0.18))

	return {"floor_i": fi, "rooms": rooms, "partitions": parts, "doors": doors, "stations": [], "corridor_layout": true, "solid_walls": solid_walls}

static func _floor_manifest(bid: String, fi: int, use_val: String, inner: Rect2, lot: Rect2, spec: Dictionary, small: bool, fh: float) -> Dictionary:
	var rng := WorldSeed.rng_for_seed(int(spec.get("seed_used", WorldSeed.get_world_seed())), "interior", [WorldSeed.str_hash(bid), fi])
	var rooms: Array = []
	var partitions: Array = []
	var doors: Array = []
	var stations: Array = []
	if small:
		# Minimal valid: split inner if possible into 2 rooms so we have a toilet kind.
		# Fallback to single room with toilet kind if truly tiny.
		if inner.size.x >= 3.0 and inner.size.y >= 3.0:
			var half := inner.size.x * 0.5
			var r0 := Rect2(inner.position, Vector2(half, inner.size.y))
			var r1 := Rect2(Vector2(inner.position.x+half, inner.position.y), Vector2(inner.size.x-half, inner.size.y))
			rooms.append({"id": "%s_f%d_entry_0" % [bid, fi], "kind": &"entry", "rect": r0, "entry": fi==0, "service": false})
			rooms.append({"id": "%s_f%d_toilet_1" % [bid, fi], "kind": &"toilet", "rect": r1, "entry": false, "service": true})
			var wall_rect := Rect2(inner.position.x+half-0.09, inner.position.y+0.3, 0.18, inner.size.y-0.6)
			var cy := inner.get_center().y
			var opening := Rect2(inner.position.x+half-0.5, cy - OPEN_W*0.5, 1.0, OPEN_W)
			partitions.append({"id": "%s_f%d_p0" % [bid, fi], "a": rooms[0]["id"], "b": rooms[1]["id"], "rect": wall_rect, "opening": opening})
			doors.append(_door_for_partition(bid, fi, 0, opening, wall_rect, rooms[0]["id"], rooms[1]["id"], fh, rng))
		else:
			var rid := "%s_f%d_toilet_0" % [bid, fi]
			rooms.append({"id": rid, "kind": &"toilet", "rect": inner, "entry": fi==0, "service": true})
	else:
		var kinds: Array = ROOM_PROGRAMS.get(use_val, ROOM_PROGRAMS["residential"])
		var rects := _split_inner(inner, kinds.size(), rng, bid, fi)
		for idx in rects.size():
			var k: StringName = kinds[idx] if idx < kinds.size() else kinds.back()
			var is_entry := fi == 0 and idx == 0
			rooms.append({"id": "%s_f%d_%s_%d" % [bid, fi, String(k), idx], "kind": k, "rect": rects[idx], "entry": is_entry, "service": k == &"toilet"})
		# Build partitions: need adjacency-aware chain. Use rect adjacency order.
		# For 4 rooms grid: connect A-B, A-C, B-D, C-D fails if naive chain includes diagonal B-C.
		# Instead build spanning tree over adjacent rects.
		var edges := _adjacent_edges(rooms)
		var used := {}
		var graph := {}
		for r in rooms:
			graph[str(r["id"])] = []
		# Kruskal-like: connect disconnected components via closest adjacent edge
		for e in edges:
			var a_id: String = e["a"]
			var b_id: String = e["b"]
			# check if already connected via partitions
			var comp_a := _component(graph, a_id)
			var comp_b := _component(graph, b_id)
			if comp_a != comp_b:
				graph[a_id].append(b_id)
				graph[b_id].append(a_id)
				var ra: Rect2 = e["ra"]
				var rb: Rect2 = e["rb"]
				var wall_rect: Rect2
				var opening: Rect2
				if e["vertical"]:
					var x := ra.end.x if absf(ra.end.x - rb.position.x) < 0.1 else rb.end.x
					var y0 := maxf(ra.position.y, rb.position.y) + 0.3
					var y1 := minf(ra.end.y, rb.end.y) - 0.3
					var cy := (y0 + y1) * 0.5
					wall_rect = Rect2(x - 0.09, minf(y0,y1), 0.18, maxf(y1 - y0, 0.1))
					opening = Rect2(x - 0.5, cy - OPEN_W*0.5, 1.0, OPEN_W)
				else:
					var y := ra.end.y if absf(ra.end.y - rb.position.y) < 0.1 else rb.end.y
					var x0 := maxf(ra.position.x, rb.position.x) + 0.3
					var x1 := minf(ra.end.x, rb.end.x) - 0.3
					var cx := (x0 + x1) * 0.5
					wall_rect = Rect2(minf(x0,x1), y - 0.09, maxf(x1 - x0, 0.1), 0.18)
					opening = Rect2(cx - OPEN_W*0.5, y - 0.5, OPEN_W, 1.0)
				var pid := "%s_f%d_p%d" % [bid, fi, partitions.size()]
				partitions.append({"id": pid, "a": a_id, "b": b_id, "rect": wall_rect, "opening": opening})
				doors.append(_door_for_partition(bid, fi, partitions.size()-1, opening, wall_rect, a_id, b_id, fh, rng))
				if partitions.size() >= rooms.size() - 1:
					break
		# If still disconnected (should not), fall back to chain over adjacent only
		if partitions.size() < rooms.size() - 1:
			for p in range(rooms.size() - 1):
				if partitions.size() >= rooms.size()-1:
					break
				var a: Dictionary = rooms[p]
				var b: Dictionary = rooms[p+1]
				var ra: Rect2 = a["rect"]
				var rb: Rect2 = b["rect"]
				# only if adjacent
				if not _rects_adjacent(ra, rb):
					continue
				var already := false
				for part in partitions:
					if (part["a"]==a["id"] and part["b"]==b["id"]) or (part["a"]==b["id"] and part["b"]==a["id"]):
						already = true
						break
				if already:
					continue
				var wall_rect: Rect2
				var opening: Rect2
				if absf(ra.end.x - rb.position.x) < 0.05 or absf(rb.end.x - ra.position.x) < 0.05:
					var x := ra.end.x if ra.end.x <= rb.position.x + 0.1 else rb.end.x
					var y0 := maxf(ra.position.y, rb.position.y) + 0.3
					var y1 := minf(ra.end.y, rb.end.y) - 0.3
					var cy := (y0 + y1) * 0.5
					wall_rect = Rect2(x - 0.09, minf(y0,y1), 0.18, maxf(y1 - y0, 0.1))
					opening = Rect2(x - 0.5, cy - OPEN_W*0.5, 1.0, OPEN_W)
				else:
					var y := ra.end.y if ra.end.y <= rb.position.y + 0.1 else rb.end.y
					var x0 := maxf(ra.position.x, rb.position.x) + 0.3
					var x1 := minf(ra.end.x, rb.end.x) - 0.3
					var cx := (x0 + x1) * 0.5
					wall_rect = Rect2(minf(x0,x1), y - 0.09, maxf(x1 - x0, 0.1), 0.18)
					opening = Rect2(cx - OPEN_W*0.5, y - 0.5, OPEN_W, 1.0)
				var pid2 := "%s_f%d_p%d" % [bid, fi, partitions.size()]
				partitions.append({"id": pid2, "a": a["id"], "b": b["id"], "rect": wall_rect, "opening": opening})
				doors.append(_door_for_partition(bid, fi, partitions.size()-1, opening, wall_rect, a["id"], b["id"], fh, rng))
	# Stations
	if use_val == "residential":
		var sleep_room: Dictionary = {}
		for r in rooms:
			if String(r["kind"]) == "sleeping":
				sleep_room = r
				break
		if not sleep_room.is_empty():
			var rr: Rect2 = sleep_room["rect"]
			var spos := rr.get_center() + Vector2(0.3, 0.3)
			stations.append({
				"id": "%s_f%d_station_bed" % [bid, fi],
				"room_id": str(sleep_room["id"]),
				"kind": &"bed",
				"position": Vector3(spos.x, float(fi)*fh, spos.y),
				"yaw": 0.0,
				"loot": &"",
			})
	else:
		if fi == 0:
			var entry_room: Dictionary = {}
			for r in rooms:
				if String(r["kind"]) == "entry":
					entry_room = r
					break
			if entry_room.is_empty() and rooms.size()>0:
				entry_room = rooms[0]
			if not entry_room.is_empty():
				var rr2: Rect2 = entry_room["rect"]
				var spos2 := rr2.get_center()
				stations.append({
					"id": "%s_f%d_station_counter" % [bid, fi],
					"room_id": str(entry_room["id"]),
					"kind": &"counter",
					"position": Vector3(spos2.x, float(fi)*fh, spos2.y),
					"yaw": 0.0,
					"loot": &"canned_food",
				})
	if stations.size() > 1:
		stations = stations.slice(0,1)
	return {"floor_i": fi, "rooms": rooms, "partitions": partitions, "doors": doors, "stations": stations}

static func _door_for_partition(bid: String, fi: int, idx: int, opening: Rect2, wall_rect: Rect2, a_id: String, b_id: String, fh: float, rng: RandomNumberGenerator) -> Dictionary:
	var hinge_left := rng.randf() < 0.5
	var door_pos := Vector2(opening.get_center().x, opening.get_center().y)
	return {
		"id": "%s_f%d_door_%d" % [bid, fi, idx],
		"building_id": bid,
		"position": Vector3(door_pos.x, float(fi) * fh, door_pos.y),
		"yaw": 0.0 if wall_rect.size.x > wall_rect.size.y else PI*0.5,
		"edge": -1,
		"width": OPEN_W,
		"height": OPEN_H,
		"hinge": "left" if hinge_left else "right",
		"locked": false,
		"open_angle": 90.0,
		"swing": 1.0,
		"interior": true,
		"room_a": a_id,
		"room_b": b_id,
	}

## Props that hang on a wall rather than stand on the floor. Corner and lattice
## candidates sit ~0.22 m inside the room, which leaves a clock or a print
## hovering off the plaster; these are moved onto the nearest wall instead.
const HANG_KINDS: Array[String] = ["wallclock", "print", "gauge"]
## Clear of the 0.18 m partition board that straddles a room boundary.
const HANG_OFFSET := 0.11


static func _hang_on_wall(rr: Rect2, corner: Vector2, extent: Vector2) -> Vector2:
	var c := corner + extent * 0.5
	var dl := c.x - rr.position.x
	var dr := rr.end.x - c.x
	var dt := c.y - rr.position.y
	var db := rr.end.y - c.y
	var m := minf(minf(dl, dr), minf(dt, db))
	var x := c.x
	var y := c.y
	if m == dl:
		x = rr.position.x + HANG_OFFSET + extent.x * 0.5
	elif m == dr:
		x = rr.end.x - HANG_OFFSET - extent.x * 0.5
	elif m == dt:
		y = rr.position.y + HANG_OFFSET + extent.y * 0.5
	else:
		y = rr.end.y - HANG_OFFSET - extent.y * 0.5
	return Vector2(x, y) - extent * 0.5


static func _rects_adjacent(ra: Rect2, rb: Rect2) -> bool:
	if absf(ra.end.x - rb.position.x) < 0.06 or absf(rb.end.x - ra.position.x) < 0.06:
		var y0 := maxf(ra.position.y, rb.position.y)
		var y1 := minf(ra.end.y, rb.end.y)
		return y1 - y0 > 0.6
	if absf(ra.end.y - rb.position.y) < 0.06 or absf(rb.end.y - ra.position.y) < 0.06:
		var x0 := maxf(ra.position.x, rb.position.x)
		var x1 := minf(ra.end.x, rb.end.x)
		return x1 - x0 > 0.6
	return false

static func _adjacent_edges(rooms: Array) -> Array:
	var edges: Array = []
	for i in rooms.size():
		for j in range(i+1, rooms.size()):
			var ra: Rect2 = rooms[i]["rect"]
			var rb: Rect2 = rooms[j]["rect"]
			var vert := false
			var adj := false
			if absf(ra.end.x - rb.position.x) < 0.06 or absf(rb.end.x - ra.position.x) < 0.06:
				var y0 := maxf(ra.position.y, rb.position.y)
				var y1 := minf(ra.end.y, rb.end.y)
				if y1 - y0 > 0.6:
					adj = true
					vert = true
			elif absf(ra.end.y - rb.position.y) < 0.06 or absf(rb.end.y - ra.position.y) < 0.06:
				var x0 := maxf(ra.position.x, rb.position.x)
				var x1 := minf(ra.end.x, rb.end.x)
				if x1 - x0 > 0.6:
					adj = true
					vert = false
			if adj:
				edges.append({"a": str(rooms[i]["id"]), "b": str(rooms[j]["id"]), "ra": ra, "rb": rb, "vertical": vert})
	return edges

static func _component(graph: Dictionary, start: String) -> String:
	var visited := {}
	var stack := [start]
	visited[start]=true
	while stack.size()>0:
		var cur: String = stack.pop_back()
		for nb in graph.get(cur, []):
			if not visited.has(nb):
				visited[nb]=true
				stack.append(nb)
	var keys := visited.keys()
	keys.sort()
	return ",".join(keys)

static func _split_inner(inner: Rect2, count: int, rng: RandomNumberGenerator, bid: String, fi: int) -> Array[Rect2]:
	if count <= 1:
		return [inner]
	if count == 2:
		var ratio := rng.randf_range(0.42, 0.58)
		var w1 := inner.size.x * ratio
		var r1 := Rect2(inner.position, Vector2(w1, inner.size.y))
		var r2 := Rect2(Vector2(inner.position.x+w1, inner.position.y), Vector2(inner.size.x - w1, inner.size.y))
		return [r1, r2]
	if count == 3:
		var vr := rng.randf_range(0.45, 0.55)
		var w1b := inner.size.x * vr
		var left := Rect2(inner.position, Vector2(w1b, inner.size.y))
		var right := Rect2(Vector2(inner.position.x+w1b, inner.position.y), Vector2(inner.size.x - w1b, inner.size.y))
		var hr := rng.randf_range(0.45, 0.55)
		var h1 := right.size.y * hr
		var rt := Rect2(right.position, Vector2(right.size.x, h1))
		var rb := Rect2(Vector2(right.position.x, right.position.y+h1), Vector2(right.size.x, right.size.y - h1))
		return [left, rt, rb]
	var vr2 := rng.randf_range(0.45, 0.55)
	var hr2 := rng.randf_range(0.45, 0.55)
	var w1c := inner.size.x * vr2
	var h1c := inner.size.y * hr2
	var rA := Rect2(inner.position, Vector2(w1c, h1c))
	var rB := Rect2(Vector2(inner.position.x+w1c, inner.position.y), Vector2(inner.size.x-w1c, h1c))
	var rC := Rect2(Vector2(inner.position.x, inner.position.y+h1c), Vector2(w1c, inner.size.y - h1c))
	var rD := Rect2(Vector2(inner.position.x+w1c, inner.position.y+h1c), Vector2(inner.size.x-w1c, inner.size.y - h1c))
	return [rA, rB, rC, rD]

static func validate(manifest: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	if int(manifest.get("version",0)) != 1:
		errs.append("version !=1")
	if not manifest.has("building_id"):
		errs.append("missing building_id")
	var building_id: String = str(manifest.get("building_id",""))
	var floors: Array = manifest.get("floors", [])
	for fl in floors:
		var rooms: Array = fl.get("rooms", [])
		var parts: Array = fl.get("partitions", [])
		var doors: Array = fl.get("doors", [])
		var stations: Array = fl.get("stations", [])
		if rooms.is_empty():
			errs.append("floor %d no rooms" % int(fl.get("floor_i",-1)))
		var has_service := false
		var has_toilet_kind := false
		for r in rooms:
			if bool(r.get("service", false)):
				has_service = true
			if String(r.get("kind")) == "toilet":
				has_toilet_kind = true
			var rc: Rect2 = r.get("rect", Rect2())
			if rc.size.x < 1.0 or rc.size.y < 1.0:
				errs.append("room %s tiny" % str(r.get("id")))
		if not has_service:
			errs.append("floor %d missing service room" % int(fl.get("floor_i",-1)))
		if not has_toilet_kind:
			errs.append("floor %d missing toilet kind" % int(fl.get("floor_i",-1)))
		for i in rooms.size():
			var ra: Rect2 = rooms[i].get("rect")
			for j in range(i+1, rooms.size()):
				var rb: Rect2 = rooms[j].get("rect")
				var inter := ra.intersection(rb)
				if inter.size.x > 0.05 and inter.size.y > 0.05:
					errs.append("rooms %s and %s overlap" % [str(rooms[i].get("id")), str(rooms[j].get("id"))])
		# bounds check partitions inside building
		var inner_bounds: Rect2 = Rect2()
		if rooms.size()>0:
			# approximate building inner as union of rooms expanded by wall thickness
			for r in rooms:
				var rc: Rect2 = r.get("rect")
				if inner_bounds.size == Vector2.ZERO:
					inner_bounds = rc
				else:
					inner_bounds = inner_bounds.merge(rc)
		for p in parts:
			var pr: Rect2 = p.get("rect", Rect2())
			var op: Rect2 = p.get("opening", Rect2())
			if pr.size.x < 0.05 or pr.size.y < 0.05:
				errs.append("partition %s degenerate" % str(p.get("id")))
			if not _rects_adjacent_for_validation(p, rooms):
				errs.append("partition %s not adjacent to both rooms" % str(p.get("id")))
			if op.size.x < 0.5 or op.size.y < 0.5:
				errs.append("partition %s opening too small" % str(p.get("id")))
			# opening must be inside partition expanded bounds
			if not pr.grow(0.6).intersects(op):
				errs.append("partition %s opening outside wall" % str(p.get("id")))
		# door-partition correspondence
		if parts.size() != doors.size():
			errs.append("floor %d partition/door count mismatch %d vs %d" % [int(fl.get("floor_i",-1)), parts.size(), doors.size()])
		var door_ids := {}
		for d in doors:
			var did := str(d.get("id"))
			if door_ids.has(did):
				errs.append("duplicate door id %s" % did)
			door_ids[did]=true
			if not did.begins_with(building_id):
				errs.append("door id %s not prefixed with building" % did)
		var station_ids := {}
		for s in stations:
			var sid := str(s.get("id"))
			if station_ids.has(sid):
				errs.append("duplicate station id %s" % sid)
			station_ids[sid]=true
		# connectivity via partitions graph
		if rooms.size() > 1:
			var graph := {}
			for r in rooms:
				graph[str(r["id"])] = []
			for p in parts:
				var a := str(p.get("a")); var b2 := str(p.get("b"))
				if graph.has(a) and graph.has(b2):
					graph[a].append(b2); graph[b2].append(a)
			var visited := {}
			var stack := [str(rooms[0].get("id"))]
			visited[stack[0]] = true
			while stack.size()>0:
				var cur = stack.pop_back()
				for nb in graph.get(cur, []):
					if not visited.has(nb):
						visited[nb]=true
						stack.append(nb)
			if visited.size() != rooms.size():
				errs.append("floor %d disconnected graph" % int(fl.get("floor_i",-1)))
	return errs

static func _rects_adjacent_for_validation(p: Dictionary, rooms: Array) -> bool:
	var a_id := str(p.get("a"))
	var b_id := str(p.get("b"))
	var ra := Rect2()
	var rb := Rect2()
	for r in rooms:
		if str(r.get("id"))==a_id:
			ra = r.get("rect")
		if str(r.get("id"))==b_id:
			rb = r.get("rect")
	if ra.size == Vector2.ZERO or rb.size == Vector2.ZERO:
		return false
	return _rects_adjacent(ra, rb)

static func room_at(manifest: Dictionary, floor_i: int, p: Vector2) -> Dictionary:
	for fl in manifest.get("floors", []):
		if int(fl.get("floor_i")) != floor_i:
			continue
		for r in fl.get("rooms", []):
			var rc: Rect2 = r.get("rect")
			if rc.has_point(p):
				return r
	return {}


## One furniture manifest supplies both the renderer and interaction stations.
## Full footprints are checked against rooms, stairs, door sweeps and each other.
const ROOM_FURNITURE := {
	"living": ["sofa", "table", "shelf"], "kitchen": ["stove", "counter", "sink"],
	"sleeping": ["bed", "shelf"], "toilet": ["toilet", "sink"],
	"sales": ["counter", "shelf", "table"], "storage": ["shelf", "shelf"],
	"pantry": ["counter", "stove", "sink"], "office": ["documents", "shelf", "documents"],
	"archive": ["shelf", "documents", "shelf"], "workshop": ["machine", "workbench"],
	"tools": ["workbench", "shelf"], "reception": ["documents", "bench"],
	"holding": ["bench", "shelf"], "ward": ["bed", "bed", "sink"],
	"surgery": ["examination", "sink", "instruments"], "dispensary": ["shelf", "instruments"],
	"council": ["documents", "bench", "shelf"], "entry": ["bench"],
	"lobby": ["bench", "documents", "shelf"],
	# Prague ground programmes (spec item 8) need their own furniture, not just
	# their own room names: a taproom gets tables and a counter, a store room
	# shelves and crates, a loading bay crates, a warehouse racks.
	"taproom": ["table", "bench", "counter"], "store_room": ["shelf", "crate", "shelf"],
	"warehouse": ["crate", "shelf", "crate"], "loading": ["crate", "bench"],
}

## Lobby house programs vary by building use (Victorian taste): civic lobbies
## get reception + waiting benches + gaslight; shopfronts get display counters;
## hospitals get waiting benches (no ledgers). All props are small-footprint
## Victorian dressing rendered visual-only by BuildingBuilder.
const LOBBY_PROGRAMS := {
	"retail": ["counter", "shelf", "counter", "shelf", "crate", "crate", "fern", "gaslamp", "gaslamp", "rug", "gauge", "wallclock", "hearth"],
	"hospital": ["fireplace", "bench", "bench", "bench", "documents", "fern", "fern", "gaslamp", "gaslamp", "rug", "wallclock", "print", "print"],
	"police": ["fireplace", "counter", "bench", "bench", "documents", "documents", "coatstand", "umbrella", "gaslamp", "gaslamp", "rug", "cabinet", "wallclock"],
	"government": ["fireplace", "counter", "bench", "bench", "documents", "documents", "fern", "fern", "coatstand", "gaslamp", "gaslamp", "rug", "wallclock", "print"],
	"office": ["fireplace", "counter", "documents", "documents", "bench", "cabinet", "cabinet", "fern", "gaslamp", "gaslamp", "rug", "wallclock", "gauge"],
	"workshop": ["machine", "workbench", "workbench", "shelf", "shelf", "crate", "crate", "crate", "gaslamp", "gaslamp", "rug", "gauge", "gauge", "fireplace"],
}
const LOBBY_PROGRAM_DEFAULT := ["counter", "bench", "bench", "documents", "fern", "gaslamp", "gaslamp", "rug", "wallclock", "print", "cabinet"]

const FURNITURE_SIZES := {
	"bed": Vector3(1.45, 0.65, 2.1), "table": Vector3(1.25, 0.8, 0.88),
	"documents": Vector3(1.25, 0.9, 0.88), "shelf": Vector3(1.6, 2.0, 0.34),
	"counter": Vector3(1.6, 0.95, 0.65), "stove": Vector3(0.8, 1.15, 0.8),
	"sink": Vector3(0.65, 0.9, 0.55), "toilet": Vector3(0.65, 0.8, 0.9),
	"sofa": Vector3(1.7, 0.85, 0.75), "bench": Vector3(1.5, 0.7, 0.55),
	"machine": Vector3(1.6, 1.6, 1.0), "workbench": Vector3(1.6, 1.0, 0.8),
	"examination": Vector3(0.9, 0.9, 1.9), "instruments": Vector3(1.2, 1.0, 0.65),
	# Gaslight-era dressing props: small footprints so lobby corners hold them.
	"gaslamp": Vector3(0.45, 2.4, 0.45), "fern": Vector3(0.7, 1.2, 0.7),
	"coatstand": Vector3(0.4, 1.9, 0.4), "rug": Vector3(2.2, 0.04, 1.5),
	# Round-3 period clutter: wall clocks, gilt-framed prints, ledger/file
	# cabinets, umbrella stand, potted palm variants, brass mechanism case.
	"wallclock": Vector3(0.55, 0.85, 0.12), "print": Vector3(0.75, 0.95, 0.08),
	"cabinet": Vector3(1.1, 2.05, 0.5), "umbrella": Vector3(0.35, 0.6, 0.35),
	"gauge": Vector3(0.5, 0.6, 0.2), "crate": Vector3(0.9, 0.75, 0.9),
	# Victorian hearth: cast-iron grate in a stone surround under an oak mantel.
	"fireplace": Vector3(1.7, 1.55, 0.6), "hearth": Vector3(1.9, 0.12, 0.7),
}

static func _room_furniture(fl: Dictionary, spec: Dictionary) -> Array:
	var fp: Rect2 = spec["rect"]
	var fh := float(spec.get("floor_h", 3.0))
	var fi := int(fl["floor_i"])
	var blocked: Array[Rect2] = []
	if BuildingBuilder.has_stairs_for(fp.size, fh, int(spec.get("floors", 1))):
		var zone := BuildingBuilder.stair_zone_world(spec)
		blocked.append(zone.grow(0.15))
		var local_zone := zone
		local_zone.position -= fp.position
		if not bool(fl.get("corridor_layout", false)):
			for aisle in BuildingBuilder._entry_aisles(fp.size.x, fp.size.y, local_zone, int(spec.get("door_edge", 0))):
				aisle.position += fp.position
				blocked.append(aisle)
	for door: Dictionary in fl["doors"]:
		var pos: Vector3 = door["position"]
		blocked.append(Rect2(Vector2(pos.x, pos.z) - Vector2.ONE * 1.15, Vector2.ONE * 2.3))
	if fi == 0:
		var edge := int(spec.get("door_edge", 0))
		var mid := fp.get_center()
		match edge:
			0: blocked.append(Rect2(mid.x - 1.2, fp.position.y, 2.4, 3.2))
			1: blocked.append(Rect2(fp.end.x - 3.2, mid.y - 1.2, 3.2, 2.4))
			2: blocked.append(Rect2(mid.x - 1.2, fp.end.y - 3.2, 2.4, 3.2))
			3: blocked.append(Rect2(fp.position.x, mid.y - 1.2, 3.2, 2.4))
	var items: Array = []
	for room: Dictionary in fl["rooms"]:
		if str(room.get("kind", "")) in ["stair_hall", "landing"]:
			continue
		# Reserve a central fighting/turning area before placing perimeter props.
		# This is an actual furniture exclusion, not a reported floor-area proxy.
		var room_rect: Rect2 = room.rect
		if spec.has("compound_id") and not bool(room.get("service", false)) and room_rect.size.x >= 3.9 and room_rect.size.y >= 4.4:
			blocked.append(Rect2(room_rect.get_center() - Vector2(1.75, 2.0), Vector2(3.5, 4.0)))
		var bounds: Rect2 = (room["rect"] as Rect2).grow(-0.22)
		var rkind := String(room["kind"])
		# Program lookup: lobby ground floors use the per-use Victorian dressing
		# program; other kinds use room programs then fallbacks.
		var program: Array
		if rkind == "lobby":
			program = LOBBY_PROGRAMS.get(String(fl.get("lobby_use", "residential")), LOBBY_PROGRAM_DEFAULT)
		else:
			program = ROOM_FURNITURE.get(rkind, ROOM_PROGRAM_FALLBACKS.get(rkind, []))
		if program.is_empty():
			continue
		var large := bounds.size.x > 6.0 and bounds.size.y > 6.0
		for kind: String in program:
			var size: Vector3 = FURNITURE_SIZES[kind]
			var extent := Vector2(size.x, size.z)
			if bounds.size.x < extent.x or bounds.size.y < extent.y:
				continue
			# Candidate spots: four corners first, then a 2.2 m interior
			# lattice for large rooms so lobby dressing is not corner-only.
			var candidates: Array[Vector2] = [
				bounds.position,
				Vector2(bounds.end.x - extent.x, bounds.position.y),
				bounds.end - extent,
				Vector2(bounds.position.x, bounds.end.y - extent.y),
			]
			if large:
				var step := 2.2
				var gy := bounds.position.y + 1.1
				while gy < bounds.end.y - extent.y:
					var gx := bounds.position.x + 1.1
					while gx < bounds.end.x - extent.x:
						candidates.append(Vector2(gx, gy))
						gx += step
					gy += step
			for corner in candidates:
				var place: Vector2 = corner
				if kind in HANG_KINDS:
					place = _hang_on_wall(room["rect"] as Rect2, corner, extent)
				var occupied := Rect2(place, extent)
				var clear := true
				# Visitor clearance: taller props (ferns, coat stands, cabinets,
				# lamps) keep a wider gap from neighbours so nothing reads as
				# clipping; rugs keep 0.5 m off furniture for the border.
				var halo := 0.4 if kind in ["fern", "coatstand", "gaslamp", "cabinet", "umbrella", "crate", "gauge"] else 0.12
				if kind == "rug":
					halo = 0.5
				for obstacle: Rect2 in blocked:
					if occupied.grow(halo).intersects(obstacle):
						clear = false
						break
				if not clear:
					continue
				var center := occupied.get_center()
				# Facing: directional props (fireplace/clock/print) must look into
				# the room, not into the wall they stand against.
				var to_room := (room["rect"] as Rect2).get_center() - center
				var yaw := atan2(to_room.x, to_room.y) if to_room.length() > 0.01 else 0.0
				items.append({"id": "%s_%s_%d" % [room["id"], kind, items.size()], "room_id": room["id"], "kind": kind, "size": size, "rect": occupied, "position": Vector3(center.x, fi * fh, center.y), "yaw": yaw})
				blocked.append(occupied.grow(0.25))
				break
	return items
