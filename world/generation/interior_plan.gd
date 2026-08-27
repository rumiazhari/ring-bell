class_name InteriorPlan
extends RefCounted
# Pure deterministic interior manifest generator.
# Use: InteriorPlan.build_for_building(spec) -> manifest

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
	# interior inset bounds (world coords)
	var inset := WALL_T + 0.02
	var inner := Rect2(rect.position + Vector2(inset, inset), rect.size - Vector2(inset*2, inset*2))
	# fallback if too small: single room per floor
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
		# minimal: single room that serves all required kinds as entry
		var rid := "%s_f%d_r0" % [bid, fi]
		var kind: StringName = &"entry" if fi == 0 else &"sleeping"
		rooms.append({"id": rid, "kind": kind, "rect": inner, "entry": fi==0, "service": false})
		# ensure service presence via same room service flag if small
		rooms[0]["service"] = true
		# at least one more sleeping/service? For small we mark service true to pass validation
	else:
		# Determine required kinds
		var kinds: Array[StringName] = []
		if use_val == "residential":
			if fi == 0:
				kinds = [&"entry", &"kitchen", &"sleeping", &"toilet"]
			else:
				kinds = [&"sleeping", &"toilet"]
		else: # retail
			if fi == 0:
				kinds = [&"entry", &"storage", &"toilet"]
			else:
				kinds = [&"office", &"toilet"]
		# Create rects by splitting inner
		var rects := _split_inner(inner, kinds.size(), rng, bid, fi)
		for idx in rects.size():
			var k: StringName = kinds[idx] if idx < kinds.size() else kinds.back()
			# last kind is toilet -> service true
			var is_service := k == &"toilet" or k == &"storage"
			var is_entry := k == &"entry" and fi == 0 and idx == 0
			rooms.append({"id": "%s_f%d_%s_%d" % [bid, fi, String(k), idx], "kind": k, "rect": rects[idx], "entry": is_entry, "service": k == &"toilet"})
		# Build partitions chain connecting rooms in order (ensures connectivity)
		for p in range(rooms.size() - 1):
			var a: Dictionary = rooms[p]
			var b: Dictionary = rooms[p+1]
			var ra: Rect2 = a["rect"]
			var rb: Rect2 = b["rect"]
			# Determine shared edge: if they share vertical or horizontal border
			# Our _split creates either vertical strips or grid; we just place a wall segment along shared border
			var wall_rect: Rect2
			var opening: Rect2
			# Find adjacency by proximity: shared edge center
			if absf(ra.end.x - rb.position.x) < 0.05 or absf(rb.end.x - ra.position.x) < 0.05:
				var x := ra.end.x if ra.end.x <= rb.position.x + 0.1 else rb.end.x
				var y0 := maxf(ra.position.y, rb.position.y) + 0.3
				var y1 := minf(ra.end.y, rb.end.y) - 0.3
				var cy := (y0 + y1) * 0.5
				# clamp opening within overlap
				var oh := OPEN_H
				var ow := 0.18 # wall thickness along opening
				wall_rect = Rect2(x - 0.09, minf(y0,y1), 0.18, maxf(y1 - y0, 0.1))
				opening = Rect2(x - 0.5, cy - OPEN_W*0.5, 1.0, OPEN_W)
			else:
				var y := ra.end.y if ra.end.y <= rb.position.y + 0.1 else rb.end.y
				var x0 := maxf(ra.position.x, rb.position.x) + 0.3
				var x1 := minf(ra.end.x, rb.end.x) - 0.3
				var cx := (x0 + x1) * 0.5
				wall_rect = Rect2(minf(x0,x1), y - 0.09, maxf(x1 - x0, 0.1), 0.18)
				opening = Rect2(cx - OPEN_W*0.5, y - 0.5, OPEN_W, 1.0)
			var pid := "%s_f%d_p%d" % [bid, fi, p]
			partitions.append({"id": pid, "a": a["id"], "b": b["id"], "rect": wall_rect, "opening": opening})
			# Door manifest for this partition
			var hinge_left := rng.randf() < 0.5
			var door_pos := Vector2(opening.get_center().x, opening.get_center().y)
			doors.append({
				"id": "%s_f%d_door_%d" % [bid, fi, p],
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
				"room_a": a["id"],
				"room_b": b["id"],
			})
	# Stations: one per building archetype, deterministic placement inside its room
	if use_val == "residential":
		# bed in sleeping room
		var sleep_room: Dictionary = {}
		for r in rooms:
			if String(r["kind"]) == "sleeping":
				sleep_room = r
				break
		if sleep_room.is_empty() and rooms.size() > 0:
			sleep_room = rooms[0]
		if not sleep_room.is_empty():
			var rr: Rect2 = sleep_room["rect"]
			var spos := rr.get_center()
			# offset slightly
			spos += Vector2(0.3, 0.3)
			stations.append({
				"id": "%s_f%d_station_bed_0" % [bid, fi] if fi==0 else "%s_f%d_station_bed" % [bid, fi],
				"room_id": str(sleep_room["id"]),
				"kind": &"bed",
				"position": Vector3(spos.x, float(fi)*fh, spos.y),
				"yaw": 0.0,
				"loot": &"",
			})
	else:
		# retail counter in entry room on ground, office upper
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
					"id": "%s_f%d_station_counter_0" % [bid, fi],
					"room_id": str(entry_room["id"]),
					"kind": &"counter",
					"position": Vector3(spos2.x, float(fi)*fh, spos2.y),
					"yaw": 0.0,
					"loot": &"canned_food",
				})
	# Deduplicate station ids across floors: ensure uniqueness already via fi
	# Trim to minimal: keep at most 1 per floor
	if stations.size() > 1:
		stations = stations.slice(0,1)
	return {"floor_i": fi, "rooms": rooms, "partitions": partitions, "doors": doors, "stations": stations}

static func _split_inner(inner: Rect2, count: int, rng: RandomNumberGenerator, bid: String, fi: int) -> Array[Rect2]:
	if count <= 1:
		return [inner]
	if count == 2:
		# vertical split
		var ratio := rng.randf_range(0.42, 0.58)
		var w1 := inner.size.x * ratio
		var r1 := Rect2(inner.position, Vector2(w1, inner.size.y))
		var r2 := Rect2(Vector2(inner.position.x+w1, inner.position.y), Vector2(inner.size.x - w1, inner.size.y))
		return [r1, r2]
	if count == 3:
		# L shape: vertical split then one side horizontal
		var vr := rng.randf_range(0.45, 0.55)
		var w1b := inner.size.x * vr
		var left := Rect2(inner.position, Vector2(w1b, inner.size.y))
		var right := Rect2(Vector2(inner.position.x+w1b, inner.position.y), Vector2(inner.size.x - w1b, inner.size.y))
		var hr := rng.randf_range(0.45, 0.55)
		var h1 := right.size.y * hr
		var rt := Rect2(right.position, Vector2(right.size.x, h1))
		var rb := Rect2(Vector2(right.position.x, right.position.y+h1), Vector2(right.size.x, right.size.y - h1))
		return [left, rt, rb]
	# 4 rooms: 2x2 grid
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
	var floors: Array = manifest.get("floors", [])
	for fl in floors:
		var rooms: Array = fl.get("rooms", [])
		var parts: Array = fl.get("partitions", [])
		if rooms.is_empty():
			errs.append("floor %d no rooms" % int(fl.get("floor_i",-1)))
		var has_service := false
		for r in rooms:
			if bool(r.get("service", false)):
				has_service = true
			var rc: Rect2 = r.get("rect", Rect2())
			if rc.size.x < 1.0 or rc.size.y < 1.0:
				errs.append("room %s tiny" % str(r.get("id")))
		if not has_service:
			errs.append("floor %d missing service room" % int(fl.get("floor_i",-1)))
		# non-overlap
		for i in rooms.size():
			var ra: Rect2 = rooms[i].get("rect")
			for j in range(i+1, rooms.size()):
				var rb: Rect2 = rooms[j].get("rect")
				var inter := ra.intersection(rb)
				if inter.size.x > 0.05 and inter.size.y > 0.05:
					errs.append("rooms %s and %s overlap" % [str(rooms[i].get("id")), str(rooms[j].get("id"))])
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

static func room_at(manifest: Dictionary, floor_i: int, p: Vector2) -> Dictionary:
	for fl in manifest.get("floors", []):
		if int(fl.get("floor_i")) != floor_i:
			continue
		for r in fl.get("rooms", []):
			var rc: Rect2 = r.get("rect")
			if rc.has_point(p):
				return r
	return {}
