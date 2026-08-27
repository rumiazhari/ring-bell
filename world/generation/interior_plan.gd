class_name InteriorPlan
extends RefCounted

const WALL_T := 0.35
const DOOR_W := 1.5
const OPEN_W := 1.0
const OPEN_H := 2.05

static func build_for_building(spec: Dictionary) -> Dictionary:
	var bid: String = str(spec.get("id", "b"))
	var floors: int = int(spec.get("floors", 1))
	var fh: float = float(spec.get("floor_h", 3.0))
	var rect: Rect2 = spec.get("rect", Rect2(0,0,10,10))
	var style: Dictionary = spec.get("style", {})
	var legacy_rt: String = str(style.get("room_type", "residential"))
	var use_val: String = str(spec.get("use", legacy_rt))
	if use_val != "residential" and use_val != "retail":
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
		var floor_dict := _floor_manifest(bid, fi, use_val, inner, rect, spec, small, fh)
		manifest["floors"].append(floor_dict)
	return manifest

static func _floor_manifest(bid: String, fi: int, use_val: String, inner: Rect2, lot: Rect2, spec: Dictionary, small: bool, fh: float) -> Dictionary:
	var rng := WorldSeed.rng_for("interior", [WorldSeed.str_hash(bid), fi])
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
		var kinds: Array[StringName] = []
		if use_val == "residential":
			if fi == 0:
				kinds = [&"entry", &"kitchen", &"sleeping", &"toilet"]
			else:
				kinds = [&"sleeping", &"toilet"]
		else:
			if fi == 0:
				kinds = [&"entry", &"storage", &"toilet"]
			else:
				kinds = [&"office", &"toilet"]
		var rects := _split_inner(inner, kinds.size(), rng, bid, fi)
		for idx in rects.size():
			var k: StringName = kinds[idx] if idx < kinds.size() else kinds.back()
			var is_entry := k == &"entry" and fi == 0 and idx == 0
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
		if sleep_room.is_empty():
			for r in rooms:
				if bool(r.get("entry", false)):
					sleep_room = r
					break
		if sleep_room.is_empty() and rooms.size() > 0:
			sleep_room = rooms[0]
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
