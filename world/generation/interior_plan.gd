class_name InteriorPlan
extends RefCounted
const OpenFloorLayout = preload("res://world/generation/open_floor_layout.gd")

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

## Compatibility hook for an older builder: circulation must always be checked.
static func uses_archetype_plan(_spec: Dictionary, _floor_i: int) -> bool:
	return false


static func build_for_building(spec: Dictionary) -> Dictionary:
	var bid := str(spec.get("id", "b"))
	var use_val := str(spec.get("use", spec.get("style", {}).get("room_type", "residential")))
	if not ROOM_PROGRAMS.has(use_val):
		use_val = "residential"
	var manifest := {"version": 1, "building_id": bid, "use": use_val, "floors": []}
	var floor_count := int(spec.get("floors", 1))
	for fi in floor_count:
		var fl := OpenFloorLayout.build(spec, fi,
				_program_for_floor(ROOM_PROGRAMS[use_val], fi, floor_count))
		var rng := WorldSeed.rng_for_seed(int(spec.get("seed_used", 0)), "interior", [WorldSeed.str_hash(bid), fi])
		fl["doors"] = []
		for part: Dictionary in fl["partitions"]:
			if bool(part.get("sealed", false)):
				continue
			fl["doors"].append(_door_for_partition(bid, fi, fl["doors"].size(), part["opening"], part["rect"], part["a"], part["b"], float(spec.get("floor_h", 3.0)), rng))
		fl["furniture"] = _room_furniture(fl, spec)
		fl["stations"] = []
		for item: Dictionary in fl["furniture"]:
			if item["kind"] in ["bed", "counter"]:
				fl["stations"].append({"id": item["id"] + "_station", "room_id": item["room_id"], "kind": item["kind"], "position": item["position"], "yaw": 0.0, "visual": false, "loot": &"canned_food"})
		manifest["floors"].append(fl)
	return manifest


static func _program_for_floor(full_program: Array, floor_i: int, floor_count: int) -> Array:
	if floor_count <= 1:
		return full_program
	var main_kinds: Array = []
	for kind: StringName in full_program:
		if kind != &"toilet":
			main_kinds.append(kind)
	var selected: Array = []
	var upper_half := floor_i % 2 == 1
	for i in main_kinds.size():
		if (i > 0) == upper_half:
			selected.append(main_kinds[i])
	selected.append(&"toilet")
	return selected


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
		# The partition this leaf is hung in, in the unrotated plan frame the
		# partition itself carries. ChunkBuilder turns it into the leaf's
		# "door_wall_cut_key" so the dollhouse gate can cut the leaf by exactly
		# the test it cuts that wall by (MeshBatcher.door_reveal).
		"wall_rect": wall_rect,
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
		var open_parts := 0
		for p in parts:
			var pr: Rect2 = p.get("rect", Rect2())
			var op: Rect2 = p.get("opening", Rect2())
			if pr.size.x < 0.05 or pr.size.y < 0.05:
				errs.append("partition %s degenerate" % str(p.get("id")))
			if not _rects_adjacent_for_validation(p, rooms):
				errs.append("partition %s not adjacent to both rooms" % str(p.get("id")))
			# A sealed partition is a plain wall between two rooms: no doorway, so
			# the opening geometry does not apply to it (both planners emit it with
			# opening = Rect2() and sealed = true).
			if bool(p.get("sealed", false)):
				continue
			open_parts += 1
			if op.size.x < 0.5 or op.size.y < 0.5:
				errs.append("partition %s opening too small" % str(p.get("id")))
			# opening must be inside partition expanded bounds
			if not pr.grow(0.6).intersects(op):
				errs.append("partition %s opening outside wall" % str(p.get("id")))
		# door-partition correspondence (sealed walls carry no door leaf)
		if open_parts != doors.size():
			errs.append("floor %d partition/door count mismatch %d vs %d" % [int(fl.get("floor_i",-1)), open_parts, doors.size()])
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
				# Connection graph counts doorways and open boundaries only: a sealed
				# partition is solid wall, so it must not make two rooms "connected".
				if bool(p.get("sealed", false)):
					continue
				var a := str(p.get("a")); var b2 := str(p.get("b"))
				if graph.has(a) and graph.has(b2):
					graph[a].append(b2); graph[b2].append(a)
			for link: Array in fl.get("open_connections", []):
				if graph.has(link[0]) and graph.has(link[1]):
					graph[link[0]].append(link[1])
					graph[link[1]].append(link[0])
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
	blocked.append_array(fl.get("circulation", []))
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
		var room_item_start := items.size()
		var large := bounds.size.x > 6.0 and bounds.size.y > 6.0
		var open_plan := str(fl.get("topology", "")) == "open_plan"
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
			if large or open_plan:
				var step := 0.45 if open_plan else 2.2
				var gy := bounds.position.y
				while gy < bounds.end.y - extent.y:
					var gx := bounds.position.x
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
				blocked.append(occupied.grow(0.55))
				break
		# Small semantic zones still need one gameplay-readable fixture. Choose
		# the smallest item from that room's own program and fit it tightly
		# against the perimeter while retaining every circulation exclusion.
		if open_plan and items.size() == room_item_start:
			var fallback_kind := ""
			var fallback_area := INF
			for candidate_kind: String in program:
				var candidate_size: Vector3 = FURNITURE_SIZES[candidate_kind]
				var candidate_area := candidate_size.x * candidate_size.z
				if candidate_area < fallback_area \
						and bounds.size.x >= candidate_size.x \
						and bounds.size.y >= candidate_size.z:
					fallback_kind = candidate_kind
					fallback_area = candidate_area
			if not fallback_kind.is_empty():
				var fallback_size: Vector3 = FURNITURE_SIZES[fallback_kind]
				var fallback_extent := Vector2(fallback_size.x, fallback_size.z)
				var fy := bounds.position.y
				var placed := false
				while fy <= bounds.end.y - fallback_extent.y + 0.001 and not placed:
					var fx := bounds.position.x
					while fx <= bounds.end.x - fallback_extent.x + 0.001:
						var occupied := Rect2(Vector2(fx, fy), fallback_extent)
						var clear := true
						for obstacle: Rect2 in blocked:
							if occupied.grow(0.04).intersects(obstacle):
								clear = false
								break
						if clear:
							var center := occupied.get_center()
							var toward_room := (room["rect"] as Rect2).get_center() - center
							items.append({"id": "%s_%s_%d" % [room["id"], fallback_kind, items.size()], "room_id": room["id"], "kind": fallback_kind, "size": fallback_size, "rect": occupied, "position": Vector3(center.x, fi * fh, center.y), "yaw": atan2(toward_room.x, toward_room.y)})
							blocked.append(occupied.grow(0.55))
							placed = true
							break
						fx += 0.15
					fy += 0.15
	return items
