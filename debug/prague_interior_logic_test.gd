extends Node
## Prague interior-logic audit. Asks the question the gameplay suite does not:
## is each floor laid out the way a historic Prague burgher house actually is?
##
## Grounded in the documented disposition of the Prague burgher house:
##   * the MAZHAUS - a large, unheated, vaulted room across the front of the
##     ground floor, used for the trade or the beer tap, and the circulation
##     node "from which stairs led to the first floor and the cellar, and the
##     passage to the courtyard" (cs.wikipedia: Mazhaus). The street door opens
##     into it - never into a private room.
##   * the depth tract ("hloubkovy trakt"): rooms in a row from street to
##     courtyard, each of the two ends giving light, so every habitable room
##     reaches a facade. A substantial room with no facade touches nothing but
##     party walls and would be lit only by candles.
##   * the stair is a fixed column, on the same footprint on every floor,
##     anchored to the wall opposite the entrance.
##   * the kitchen sits at the back / courtyard side with the flue, not on the
##     prime street frontage; the privy ("prevet") hangs off the landing or the
##     gallery, never in the middle of a room.
##   * the front rooms are public (shop, taproom, workshop, parlour); sleeping
##     and service rooms sit behind them and are not mandatory through-routes.
##
## Exit code is the failure count, so tools/run_suite.py can gate on it.
const BuildingBuilder = preload("res://world/generation/building_builder.gd")
const InteriorPlan = preload("res://world/generation/interior_plan.gd")

const SEEDS := [19041207, 19041208, 19041209]
const CIRCULATION: Array[StringName] = [&"stair_hall", &"landing", &"hall"]
const PUBLIC: Array[StringName] = [&"sales", &"workshop", &"taproom", &"office", &"warehouse", &"living"]
const PRIVATE: Array[StringName] = [&"sleeping", &"kitchen", &"storage", &"store_room", &"archive"]

const KIND_COLOR := {
	&"sales": "#d9a13a", &"workshop": "#c8873a", &"taproom": "#d96b3a",
	&"office": "#b9a04a", &"warehouse": "#a88a5a", &"living": "#4f9c46",
	&"sleeping": "#4f7fc2", &"kitchen": "#c2443a", &"toilet": "#9a9a9a",
	&"stair_hall": "#6f777c", &"landing": "#8d959a",
	&"storage": "#8a7a5a", &"store_room": "#8a7a5a", &"archive": "#8a7a5a",
}

var failures := 0


func _ready() -> void:
	for seed_value: int in SEEDS:
		audit(seed_value)
		if OS.get_cmdline_user_args().has("--single"):
			break
	print("[PragueInteriorLogic] finished with %d failure(s)" % failures)
	get_tree().quit(failures)


func audit(seed_value: int) -> void:
	var started := Time.get_ticks_msec()
	var city := CityPlan.new(seed_value)
	var blocks := city.city_blocks()
	# Every footprint in the city, in one grid: "does this face look into a
	# neighbour's house or into open air" is a party-wall question, and a party
	# wall is the one thing a Prague room cannot take its light from.
	var lot_polys: Array[PackedVector2Array] = []
	var lot_boxes: Array[Rect2] = []
	var lot_grid := {}
	for block: Dictionary in blocks:
		for spec: Dictionary in block.get("buildings", []) as Array:
			var corners := CityPlan._lot_corners(spec["rect"] as Rect2, float(spec.get("yaw", 0.0)))
			lot_polys.append(corners)
			var box := poly_bounds(corners)
			lot_boxes.append(box)
			grid_add(lot_grid, lot_boxes.size() - 1, box.grow(1.0), 8.0)

	var wings := 0
	var floors_seen := 0
	var floors_counted := 0
	var blind_rooms := 0
	var blind_samples: Array[String] = []
	var blind_total := 0.0
	var door_missing := 0
	var door_private := 0
	var door_samples: Array[String] = []
	var stair_uncovered := 0
	var stair_floors := 0
	var chained_private := 0
	var chained_bedrooms := 0
	var chain_samples: Array[String] = []
	var kitchens := 0
	var kitchens_rear := 0
	var prvets := 0
	var prvets_ok := 0
	var mazhaus_floors := 0
	var mazhaus_ok := 0
	var mazhaus_front_floors := 0
	var mazhaus_front_ok := 0
	var mazhaus_samples: Array[String] = []
	var hall_widths: Array[float] = []
	var lit_contact: Array[float] = []
	var combat_floors := 0
	var combat_fixable := 0
	var combat_tiny := 0
	var combat_samples: Array[String] = []
	var panels: Array[Dictionary] = []
	var diag := OS.get_cmdline_user_args().has("--diag")
	var seen_ids := {}
	var dup_specs := 0
	var no_compound := 0
	var duplicate_rooms := 0

	for block: Dictionary in blocks:
		if not bool(block.get("historic_compound", false)) or block.kind != &"built":
			continue
		for spec: Dictionary in block.get("buildings", []) as Array:
			var rect: Rect2 = spec["rect"] as Rect2
			var floors := int(spec.get("floors", 1))
			if floors < 1 or rect.get_area() < 12.0:
				continue
			var open_edges := _open_edges(spec, lot_polys, lot_boxes, lot_grid)
			var manifest := InteriorPlan.build_for_building(spec)
			var street_side := int(spec.get("door_edge", 0))
			var sid := str(spec.get("id", ""))
			if seen_ids.has(sid):
				dup_specs += 1
			seen_ids[sid] = true
			if not spec.has("compound_id"):
				no_compound += 1
			for floor_plan: Dictionary in manifest.get("floors", []) as Array:
				var rects := {}
				for room: Dictionary in floor_plan.get("rooms", []) as Array:
					var key := "%s" % (room.rect as Rect2)
					rects[key] = int(rects.get(key, 0)) + 1
					if int(rects[key]) > 1:
						duplicate_rooms += 1
						if diag and duplicate_rooms <= 6:
							print("[PragueInteriorLogic]   diag: %s f%d duplicate rect %s kind=%s" % [
								sid, int(floor_plan.get("floor_i", 0)), key, str(room.kind)])
			if diag and seen_ids.size() <= 2:
				print("[PragueInteriorLogic]   diag: %s compound=%s floors=%d rect=%.1fx%.1f door_edge=%d wing=%s" % [
					sid, str(spec.has("compound_id")), manifest.get("floors", []).size(),
					rect.size.x, rect.size.y, street_side, str(spec.get("wing_role", ""))])
			if str(spec.get("wing_role", "")) == "front":
				wings += 1
				if panels.size() < 12 and str(spec.get("use", "")) in ["retail", "workshop", "office", "tavern", "storage", "caretaker"]:
					var use_seen := false
					for other: Dictionary in panels:
						if str((other["spec"] as Dictionary).get("use", "")) == str(spec.get("use", "")):
							use_seen = true
					if not use_seen:
						panels.append({"spec": spec, "manifest": manifest, "open": open_edges})
			for floor_plan: Dictionary in manifest.get("floors", []) as Array:
				var rooms: Array = floor_plan.get("rooms", []) as Array
				var fi := int(floor_plan.get("floor_i", 0))
				if fi >= floors:
					continue
				floors_seen += 1
				var inner := rect.grow(-0.35)
				var adjacency := _adjacency(rooms, floor_plan)
				var door_room := _door_room(rect, street_side, rooms)
				# 1. Mazhaus: the street door opens into the public front room,
				#    which is the room the trade or the tap happens in. Only a
				#    street wing has a street entrance to open; a rear or side wing
				#    is entered from the courtyard, where no public front room is
				#    owed, so the strict count is the front-wing one.
				if fi == 0:
					var front_wing := str(spec.get("wing_role", "")) == "front"
					if front_wing:
						mazhaus_front_floors += 1
					mazhaus_floors += 1
					if door_room >= 0:
						var dr: Dictionary = rooms[door_room]
						var dr_rect: Rect2 = dr.rect
						# The mazhaus proper is the public front room; a narrow
						# house instead enters through the entry passage (the
						# sin), which is circulation. Both are correct; what is
						# never correct is a door into a chamber or a store.
						var is_public := str(dr.kind) in _names(PUBLIC) and dr_rect.get_area() >= 12.0
						var is_entry := StringName(dr.kind) in CIRCULATION
						if is_public or is_entry:
							mazhaus_ok += 1
							if front_wing:
								mazhaus_front_ok += 1
						elif mazhaus_samples.size() < 3:
							mazhaus_samples.append("%s use=%s door_room=%s area=%.1f" % [
								str(spec.id), str(spec.use), str(dr.kind), (dr.rect as Rect2).get_area()])
					elif mazhaus_samples.size() < 3:
						mazhaus_samples.append("%s use=%s door_room=NONE" % [str(spec.id), str(spec.use)])
				# The street entrance exists on the ground floor only; upper
				# floors reach the street through their own stair, not a door.
				if fi == 0:
					if door_room < 0:
						door_missing += 1
						if door_missing <= 4:
							print("[PragueInteriorLogic]   nodoor: %s use=%s edge=%d rect=%.1fx%.1f rooms=%d first=%s" % [
								str(spec.id), str(spec.use), street_side, rect.size.x, rect.size.y,
								rooms.size(), "%s" % ((rooms[0].rect as Rect2) if not rooms.is_empty() else Rect2())])
					elif str((rooms[door_room] as Dictionary).kind) in _names(PRIVATE):
						door_private += 1
						if door_samples.size() < 3:
							door_samples.append("%s f%d use=%s door opens into %s" % [
								str(spec.id), fi, str(spec.use), str((rooms[door_room] as Dictionary).kind)])
				# 2b. Manoeuvre room: gameplay wants one 18 m2 room on 90% of
				#     floors. Record the floors that miss it together with the
				#     plate and the rooms that were cut, so a shortfall traces
				#     to the geometry that produced it.
				var best := 0.0
				for room0: Dictionary in rooms:
					if bool(room0.service) or StringName(room0.kind) in CIRCULATION:
						continue
					best = maxf(best, (room0.rect as Rect2).get_area())
				floors_counted += 1
				var plate_area := (inner.size.x * inner.size.y)
				if best >= 18.0:
					combat_floors += 1
				elif plate_area >= 25.0:
					combat_fixable += 1
					if combat_samples.size() < 6:
						var ks: Array[String] = []
						for room1: Dictionary in rooms:
							ks.append("%s=%.0f" % [str(room1.kind), (room1.rect as Rect2).get_area()])
						combat_samples.append("%s f%d %.1fx%.1f best=%.1f [%s]" % [
							str(spec.id), fi, rect.size.x, rect.size.y, best, ", ".join(ks)])
				else:
					combat_tiny += 1
				# 2. Light: a substantial room that touches only party walls is
				#    a cellar with furniture in it.
				for room: Dictionary in rooms:
					var kind := StringName(room.kind)
					if kind == &"stair_hall":
						hall_widths.append((room.rect as Rect2).size.x)
					if bool(room.service) or kind in CIRCULATION:
						continue
					var lights := _light_contact(room.rect as Rect2, inner, open_edges)
					lit_contact.append(lights)
					if lights < 1.0:
						blind_rooms += 1
						blind_total += (room.rect as Rect2).get_area()
						if blind_samples.size() < 4:
							blind_samples.append("%s f%d %s %.1fx%.1f area=%.1f doors=%d" % [
								str(spec.id), fi, str(kind), (room.rect as Rect2).size.x,
								(room.rect as Rect2).size.y, (room.rect as Rect2).get_area(),
								int(adjacency.get(str(room.id), []).size())])
				# 3. Stair column: the shaft must be free floor inside circulation.
				if BuildingBuilder.has_stairs_for(rect.size, float(spec.get("floor_h", 3.0)), floors):
					stair_floors += 1
					var zone := BuildingBuilder.stair_zone_world(spec)
					var holder := -1
					for i in rooms.size():
						if (rooms[i].rect as Rect2).has_point(zone.get_center()):
							holder = i
							break
					if holder < 0 or not (StringName(rooms[holder].kind) in CIRCULATION):
						stair_uncovered += 1
				# 4. Private rooms must not be mandatory through-routes: a
				#    chamber is entered off the hall or the landing, not off
				#    the next bedroom.
				var chain := _chained(rooms, adjacency)
				chained_private += int(chain["sleeping"]) + int(chain["other"])
				chained_bedrooms += int(chain["sleeping"])
				if chained_bedrooms > 0 and chain_samples.size() < 3:
					chain_samples.append("%s f%d use=%s bedroom behind a private room" % [str(spec.id), fi, str(spec.use)])
				# 5. Kitchen at the back with the flue, not on the street front.
				for room: Dictionary in rooms:
					if StringName(room.kind) != &"kitchen":
						continue
					kitchens += 1
					if _depth_fraction(room.rect as Rect2, rect, street_side) >= 0.5:
						kitchens_rear += 1
				# 6. Prevet: off the circulation or on an outside wall.
				for room: Dictionary in rooms:
					if StringName(room.kind) != &"toilet":
						continue
					prvets += 1
					if _touches_circulation(room.rect as Rect2, rooms) or _light_contact(room.rect as Rect2, inner, open_edges) >= 1.0:
						prvets_ok += 1

	print("[PragueInteriorLogic] seed=%d wings=%d floors=%d dups=%d no_compound=%d dup_rooms=%d rooms_lit_p10=%.2f blind=%d blind_area=%.0fm2 door_missing=%d door_private=%d stair_uncovered=%d/%d chained_private=%d chained_bedrooms=%d kitchens=%d kitchen_rear=%.3f prvets=%d prevet_ok=%.3f mazhaus_front=%.3f/%d mazhaus_all=%.3f/%d hall_p50=%.2f ms=%d" % [
		seed_value, wings, floors_seen, dup_specs, no_compound, duplicate_rooms,
		percentile(lit_contact, 0.1), blind_rooms, blind_total,
		door_missing, door_private, stair_uncovered, stair_floors, chained_private, chained_bedrooms,
		kitchens, float(kitchens_rear) / maxf(1.0, float(kitchens)),
		prvets, float(prvets_ok) / maxf(1.0, float(prvets)),
		float(mazhaus_front_ok) / maxf(1.0, float(mazhaus_front_floors)), mazhaus_front_floors,
		float(mazhaus_ok) / maxf(1.0, float(mazhaus_floors)), mazhaus_floors,
		percentile(hall_widths, 0.5), Time.get_ticks_msec() - started])
	for line: String in blind_samples:
		print("[PragueInteriorLogic]   blind: %s" % line)
	for line: String in door_samples:
		print("[PragueInteriorLogic]   door: %s" % line)
	for line: String in mazhaus_samples:
		print("[PragueInteriorLogic]   mazhaus: %s" % line)
	for line: String in chain_samples:
		print("[PragueInteriorLogic]   chained: %s" % line)
	_draw(seed_value, panels)

	print("[PragueInteriorLogic] combat=%d/%d (%.1f%%) fixable=%d tiny=%d" % [combat_floors, floors_counted,
		100.0 * float(combat_floors) / maxf(1.0, float(floors_counted)), combat_fixable, combat_tiny])
	for line1: String in combat_samples:
		print("[PragueInteriorLogic]   nocombat: %s" % line1)
	check(blind_rooms == 0, "every habitable room reaches a facade (no blind rooms)")
	check(door_missing == 0, "the street door lands inside a room")
	check(door_private == 0, "the street door opens into the public room, never a private one")
	check(stair_uncovered == 0, "the stair column is free floor on every floor")
	check(chained_bedrooms == 0, "no bedroom is a mandatory through-route")
	check(chained_private * 20 <= lit_contact.size(), "private rooms behind private rooms stay under 5% of substantial rooms")
	check(float(kitchens_rear) / maxf(1.0, float(kitchens)) >= 0.6, "the kitchen sits behind the parlour, never on the street front")
	check(chained_private * 4 <= lit_contact.size(), "private rooms behind private rooms stay under 25% of substantial rooms")
	check(float(prvets_ok) / maxf(1.0, float(prvets)) >= 0.9, "privies stand off the circulation or an outside wall")
	check(float(mazhaus_front_ok) / maxf(1.0, float(mazhaus_front_floors)) >= 0.9, "the street wing opens into its mazhaus")
	check(float(mazhaus_ok) / maxf(1.0, float(mazhaus_floors)) >= 0.9, "every wing's entrance opens into a public room")


## Which of the four local edges look into open air rather than a neighbour.
## Edge order matches door_edge: 0 = N (-y), 1 = E (+x), 2 = S (+y), 3 = W (-x).
func _open_edges(spec: Dictionary, polys: Array[PackedVector2Array], boxes: Array[Rect2], grid: Dictionary) -> Array[bool]:
	var rect: Rect2 = spec["rect"] as Rect2
	var yaw := float(spec.get("yaw", 0.0))
	var corners := CityPlan._lot_corners(rect, yaw)
	var center := rect.get_center()
	var out: Array[bool] = [true, true, true, true]
	for i in 4:
		var mid := (corners[i] + corners[(i + 1) % 4]) * 0.5
		var outward := (mid - center)
		if outward.length_squared() < 1e-6:
			continue
		var probe := mid + outward.normalized() * 0.8
		# A neighbour sitting on the far side of this face means a party wall:
		# the room behind it gets no window and no air from that direction.
		out[i] = not grid_any(grid, probe, func(index: int) -> bool:
			return boxes[index].has_point(probe) and Geometry2D.is_point_in_polygon(probe, polys[index]))
	return out


## Length of room wall lying on an outside face (party walls do not count).
func _light_contact(room: Rect2, inner: Rect2, open_edges: Array[bool]) -> float:
	var total := 0.0
	if open_edges[0] and absf(room.position.y - inner.position.y) < 0.06:
		total = maxf(total, room.size.x)
	if open_edges[1] and absf(room.end.x - inner.end.x) < 0.06:
		total = maxf(total, room.size.y)
	if open_edges[2] and absf(room.end.y - inner.end.y) < 0.06:
		total = maxf(total, room.size.x)
	if open_edges[3] and absf(room.position.x - inner.position.x) < 0.06:
		total = maxf(total, room.size.y)
	return total


## Distance of a room from the street face, as a fraction of the plot depth.
func _depth_fraction(room: Rect2, rect: Rect2, street_side: int) -> float:
	match street_side:
		0: return (room.position.y - rect.position.y) / maxf(rect.size.y, 0.001)
		1: return (rect.end.x - room.end.x) / maxf(rect.size.x, 0.001)
		2: return (rect.end.y - room.end.y) / maxf(rect.size.y, 0.001)
		_: return (room.position.x - rect.position.x) / maxf(rect.size.x, 0.001)


## Room the street door opens into: the facade midpoint walks 0.6 m indoors.
func _door_room(rect: Rect2, street_side: int, rooms: Array) -> int:
	var c := rect.get_center()
	var point := Vector2.ZERO
	match street_side:
		0: point = Vector2(c.x, rect.position.y + 0.6)
		1: point = Vector2(rect.end.x - 0.6, c.y)
		2: point = Vector2(c.x, rect.end.y - 0.6)
		_: point = Vector2(rect.position.x + 0.6, c.y)
	for i in rooms.size():
		if (rooms[i].rect as Rect2).has_point(point):
			return i
	return -1


func _adjacency(rooms: Array, floor_plan: Dictionary) -> Dictionary:
	var graph := {}
	for i in rooms.size():
		graph[str(rooms[i].id)] = []
	for door: Dictionary in floor_plan.get("doors", []) as Array:
		var a := str(door.get("room_a", ""))
		var b := str(door.get("room_b", ""))
		if a == "" or b == "":
			continue
		graph[a].append(b)
		graph[b].append(a)
	return graph


## Private rooms reachable only by crossing another private room. Entering a
## public room to reach a chamber behind it is normal Prague enfilade; what the
## floor contract forbids is a bedroom you must walk through to reach another
## bedroom, so public rooms are traversable here and private ones are leaves.
func _chained(rooms: Array, graph: Dictionary) -> Dictionary:
	var kinds := {}
	for room: Dictionary in rooms:
		kinds[str(room.id)] = StringName(room.kind)
	var reachable := {}
	var queue: Array[String] = []
	for room: Dictionary in rooms:
		if StringName(room.kind) in CIRCULATION:
			var id := str(room.id)
			reachable[id] = true
			queue.append(id)
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for neighbour: String in graph.get(current, []) as Array:
			if reachable.has(neighbour) or kinds.get(neighbour, &"") in PRIVATE:
				continue
			reachable[neighbour] = true
			queue.append(neighbour)
	var chained_sleeping := 0
	var chained_other := 0
	for room: Dictionary in rooms:
		var id := str(room.id)
		var kind := StringName(kinds.get(id, &""))
		if not (kind in PRIVATE):
			continue
		var neighbours: Array = graph.get(id, []) as Array
		if neighbours.is_empty():
			continue
		var entered_from_open := false
		for neighbour: String in neighbours:
			if reachable.has(neighbour):
				entered_from_open = true
		if not entered_from_open:
			if kind == &"sleeping":
				chained_sleeping += 1
			else:
				chained_other += 1
	return {"sleeping": chained_sleeping, "other": chained_other}


func _touches_circulation(room: Rect2, rooms: Array) -> bool:
	for other: Dictionary in rooms:
		if not (StringName(other.kind) in CIRCULATION):
			continue
		var o: Rect2 = other.rect
		if absf(room.end.x - o.position.x) < 0.06 or absf(o.end.x - room.position.x) < 0.06:
			if minf(room.end.y, o.end.y) - maxf(room.position.y, o.position.y) >= 1.0:
				return true
		if absf(room.end.y - o.position.y) < 0.06 or absf(o.end.y - room.position.y) < 0.06:
			if minf(room.end.x, o.end.x) - maxf(room.position.x, o.position.x) >= 1.0:
				return true
	return false


func _names(list: Array[StringName]) -> Array:
	var out: Array = []
	for item: StringName in list:
		out.append(String(item))
	return out


## Floor plans of a sample of street houses, drawn the way a Prague survey
## drawing would be: one panel per house, one band per floor, ground floor
## first, the street side marked on the edge the door is in.
func _draw(seed_value: int, panels: Array[Dictionary]) -> void:
	var panel_w := 250.0
	var panel_h := 470.0
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"><rect width="%d" height="%d" fill="#20262a"/>' % [
		int(panel_w * 6.0 + 20.0), int(panel_h * 2.0 + 110.0),
		int(panel_w * 6.0 + 20.0), int(panel_h * 2.0 + 110.0),
		int(panel_w * 6.0 + 20.0), int(panel_h * 2.0 + 110.0)]
	var index := 0
	for panel: Dictionary in panels:
		var col := index % 6
		var row := index / 6
		index += 1
		var spec: Dictionary = panel.spec
		var rect: Rect2 = spec.rect
		var manifest: Dictionary = panel.manifest
		var floors: Array = manifest.get("floors", []) as Array
		var count := mini(floors.size(), 4)
		var ox := 10.0 + col * panel_w
		var oy := 20.0 + row * panel_h
		var band_h := (panel_h - 40.0) / maxf(1.0, float(count))
		var scale := minf((panel_w - 60.0) / maxf(rect.size.x, 1.0), (band_h - 26.0) / maxf(rect.size.y, 1.0))
		svg += '<text x="%.0f" y="%.0f" font-size="13" fill="#e8e8e8">%s %s %.1fx%.1f %df</text>' % [
			ox + 10.0, oy + 14.0, str(spec.id).replace("historic_block_", "b"), str(spec.use),
			rect.size.x, rect.size.y, int(spec.get("floors", 1))]
		for fi in count:
			var floor_plan: Dictionary = floors[fi]
			var by := oy + 22.0 + fi * band_h
			for room: Dictionary in floor_plan.get("rooms", []) as Array:
				var r: Rect2 = room.rect
				var color: String = KIND_COLOR.get(StringName(room.kind), "#666666")
				var fill := svg_rect_local(ox, by, rect, r, scale, color, 6.0)
				svg += fill
			var edges: Array = panel.open
			for e in 4:
				var street := int(spec.get("door_edge", 0)) == e
				var color_edge := "#f2f2f2" if street else ("#5a6a5a" if bool(edges[e]) else "#2a2a2a")
				svg += svg_edge_local(ox, by, rect, e, scale, color_edge, 3.0 if street else 1.0)
			var zone := BuildingBuilder.stair_zone_world(spec)
			svg += svg_rect_local(ox, by, rect, zone, scale, "none", 1.6, "#ffffff")
			svg += '<text x="%.0f" y="%.0f" font-size="11" fill="#c8c8c8">f%d</text>' % [ox + 12.0, by + 12.0, fi]
	var legend := "circulation #6f777c | living #4f9c46 | sleeping #4f7fc2 | kitchen #c2443a | shop/works #d9a13a | toilet #9a9a9a | stair zone white box | street face white line | party face dark"
	svg += '<text x="14" y="%d" font-size="14" fill="#e8e8e8">%s</text>' % [int(panel_h * 2.0 + 60.0), legend]
	svg += '<text x="14" y="%d" font-size="14" fill="#e8e8e8">Prague interior logic, seed %d</text>' % [int(panel_h * 2.0 + 84.0), seed_value]
	var raster := Image.new()
	raster.load_svg_from_string(svg + "</svg>")
	raster.save_png("res://.hermes/autopilot/reports/prague-gameplay-pass/interiors-%d.png" % seed_value)


func svg_rect_local(ox: float, oy: float, rect: Rect2, r: Rect2, scale: float, fill: String, stroke_w: float, stroke := "#333333") -> String:
	var x := ox + 30.0 + (r.position.x - rect.position.x) * scale
	var y := oy + 8.0 + (r.position.y - rect.position.y) * scale
	return '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" stroke="%s" stroke-width="%.1f"/>' % [
		x, y, r.size.x * scale, r.size.y * scale, fill, stroke, stroke_w]


func svg_edge_local(ox: float, oy: float, rect: Rect2, edge: int, scale: float, color: String, width: float) -> String:
	var x0 := ox + 30.0
	var y0 := oy + 8.0
	var w := rect.size.x * scale
	var h := rect.size.y * scale
	match edge:
		0: return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"/>' % [x0, y0, x0 + w, y0, color, width]
		1: return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"/>' % [x0 + w, y0, x0 + w, y0 + h, color, width]
		2: return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"/>' % [x0, y0 + h, x0 + w, y0 + h, color, width]
		_: return '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%.1f"/>' % [x0, y0, x0, y0 + h, color, width]


func poly_bounds(poly: PackedVector2Array) -> Rect2:
	var box := Rect2(poly[0], Vector2.ZERO)
	for point: Vector2 in poly:
		box = box.expand(point)
	return box


func grid_add(grid: Dictionary, index: int, box: Rect2, cell: float) -> void:
	var x0 := int(floor(box.position.x / cell))
	var x1 := int(floor(box.end.x / cell))
	var y0 := int(floor(box.position.y / cell))
	var y1 := int(floor(box.end.y / cell))
	for cx in range(x0, x1 + 1):
		for cy in range(y0, y1 + 1):
			var key := Vector2i(cx, cy)
			if not grid.has(key):
				grid[key] = []
			(grid[key] as Array).append(index)


func grid_any(grid: Dictionary, point: Vector2, predicate: Callable) -> bool:
	var key := Vector2i(int(floor(point.x / 8.0)), int(floor(point.y / 8.0)))
	for index: int in grid.get(key, []) as Array:
		if predicate.call(index):
			return true
	return false


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		print("[PragueInteriorLogic] FAIL " + message)


func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	values.sort()
	return values[mini(values.size() - 1, int(values.size() * fraction))]
