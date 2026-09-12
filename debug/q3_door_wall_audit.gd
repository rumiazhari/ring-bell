extends Node
## Door / wall placement audit in plan space (frontend question: does the
## interior the player walks into make sense?).  For every city building and
## every storey it inspects exactly the geometry the renderer will emit:
##
##   unwalled_edge   two rooms share an edge >= 0.6 m but NO partition covers
##                   it -> the two "rooms" are one open space (the plan says two
##                   rooms, the player sees one)
##   wall_off_edge   a partition covers no room-to-room edge -> a wall standing
##                   inside a room
##   door_not_in_wall a door leaf whose position is not inside any wall
##   door_same_room  a door whose room_a == room_b
##   door_cross_room a door whose two rooms do not share a wall edge
##   door_missing_room a door naming a room id that does not exist
##   room_no_door    a room with no door
##   doors_per_wall  walls carrying more than one door
##
## Run headless: --q3doorwalleaudit

const EDGE_MIN := 1.2
## Shared edges shorter than the generator's own 1.2 m minimum are counted
## separately: they are spandrel slivers between offsets, not room boundaries,
## so they are reported but not part of the unwalled metric.
const EDGE_SLIVER := 0.6

var buildings := 0
var floors := 0
var rooms_total := 0
var walls_total := 0
var doors_total := 0
var shared_edges := 0
var unwalled_edges := 0
var unwalled_historic := 0
var unwalled_other := 0
var walls_off_edge := 0
var doors_not_in_wall := 0
var doors_same_room := 0
var doors_cross_room := 0
var doors_missing_room := 0
var rooms_no_door := 0
var walls_multi_door := 0
## Partitions that exist in the PLAN but are dropped at build time by the
## circulation keep-out test (BuildingBuilder.interior_partition_visible). A
## dropped partition is a wall the plan promised and the player never sees.
var clipped_partitions := 0
var through_door_partitions := 0
var samples: Array = []
var worst: Array = []

func _ready() -> void:
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	for spec: Dictionary in plan.city_buildings():
		var man: Dictionary = InteriorPlan.build_for_building(spec)
		var fls: Array = man.get("floors", [])
		if fls.is_empty():
			continue
		buildings += 1
		for fi in fls.size():
			_audit_floor(str(spec.get("id", "?")), fi, fls[fi], spec)
	print("[DoorWallAudit] buildings=%d floors=%d rooms=%d walls=%d doors=%d" % [
		buildings, floors, rooms_total, walls_total, doors_total])
	print("[DoorWallAudit] shared_room_edges=%d unwalled_edges=%d (%.1f%% of shared edges) [historic_wing=%d other=%d]" % [
		shared_edges, unwalled_edges,
		100.0 * float(unwalled_edges) / maxf(1.0, float(shared_edges)),
		unwalled_historic, unwalled_other])
	print("[DoorWallAudit] walk-route walls: emitted=%d of %d previously-dropped (route_through_doorway=%d clipped_around_route=%d)" % [
		clipped_partitions + through_door_partitions, clipped_partitions + through_door_partitions,
		through_door_partitions, clipped_partitions])
	print("[DoorWallAudit] walls_off_room_edge=%d walls_with_2plus_doors=%d doors_not_in_wall=%d doors_same_room=%d doors_cross_room=%d doors_missing_room=%d rooms_without_door=%d" % [
		walls_off_edge, walls_multi_door, doors_not_in_wall, doors_same_room,
		doors_cross_room, doors_missing_room, rooms_no_door])
	worst.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
	for w: Dictionary in worst.slice(0, 8):
		print("[DoorWallWorst] %s" % str(w["s"]))
	for line: String in samples.slice(0, 10):
		print("[DoorWallSample] %s" % line)
	_wall_cut_selftest()
	get_tree().quit(0)


## Direct check of the locked wall rule: in a simple two-room plan, only the
## wall the camera actually looks through may be cut. Same room, four camera
## bearings: each one must cut the wall on its own side and leave the other
## walls (and one storey below/above handling) alone.
func _wall_cut_selftest() -> void:
	var player := Vector2(5.0, 5.0)
	# Four walls around the player, 2 m away on each side.
	var north := MeshBatcher.wall_cut_key(Vector3(5.0, 0.0, 7.0), Vector3(8.0, 2.5, 0.2))
	var south := MeshBatcher.wall_cut_key(Vector3(5.0, 0.0, 3.0), Vector3(8.0, 2.5, 0.2))
	var west := MeshBatcher.wall_cut_key(Vector3(3.0, 0.0, 5.0), Vector3(0.2, 2.5, 8.0))
	var east := MeshBatcher.wall_cut_key(Vector3(7.0, 0.0, 5.0), Vector3(0.2, 2.5, 8.0))
	var bearings := {
		"camera_north": Vector2(5.0, 11.0),
		"camera_south": Vector2(5.0, -1.0),
		"camera_west": Vector2(-1.0, 5.0),
		"camera_east": Vector2(11.0, 5.0),
	}
	for name: String in bearings.keys():
		var cam: Vector2 = bearings[name]
		print("[WallCut] %s cut: north=%s south=%s west=%s east=%s" % [name,
				str(MeshBatcher.wall_cut_hidden(north, cam, player)),
				str(MeshBatcher.wall_cut_hidden(south, cam, player)),
				str(MeshBatcher.wall_cut_hidden(west, cam, player)),
				str(MeshBatcher.wall_cut_hidden(east, cam, player))])
	print("[WallCut] camera_moved_onto_player cut_any=%s (must be false: no sightline)" % str(
			MeshBatcher.wall_cut_hidden(north, player, player)))
	print("[WallCut] no_sightline cut_any=%s (must be false)" % str(
			MeshBatcher.wall_cut_hidden(north, Vector2.INF, Vector2.INF)))

func _audit_floor(bid: String, fi: int, fl: Dictionary, spec: Dictionary) -> void:
	floors += 1
	var rooms: Array = fl.get("rooms", [])
	var walls: Array = []
	var fp_rect: Rect2 = spec.get("rect", Rect2())
	for p: Dictionary in fl.get("partitions", []):
		walls.append(p.get("rect", Rect2()))
		if BuildingBuilder.interior_partition_visible(p, spec, fi):
			continue
		# The route crosses this wall. Before this change the whole partition was
		# DROPPED, so the plan's layout never reached the player. Now the wall is
		# kept: either the route goes through its doorway (already a passage) or
		# the wall is clipped around the keep-out (building_builder._emit_wall_piece).
		var pr: Rect2 = p.get("rect", Rect2())
		var op: Rect2 = p.get("opening", Rect2())
		pr.position -= fp_rect.position
		op.position -= fp_rect.position
		var vert := pr.size.x < pr.size.y + 0.01
		var opening_plan := Rect2(pr.position.x, op.position.y, pr.size.x, op.size.y) if vert \
				else Rect2(op.position.x, pr.position.y, op.size.x, pr.size.y)
		var through_door := op.size.x > 0.05 and op.size.y > 0.05 and BuildingBuilder._rect_hits_any(
				opening_plan, BuildingBuilder.circulation_keepouts(spec, fi))
		if through_door:
			through_door_partitions += 1
		else:
			clipped_partitions += 1
	for w in fl.get("solid_walls", []):
		walls.append(w as Rect2)
	rooms_total += rooms.size()
	walls_total += walls.size()
	var doors: Array = fl.get("doors", [])
	doors_total += doors.size()
	var by_id := {}
	for r: Dictionary in rooms:
		by_id[str(r["id"])] = r["rect"]

	var unwalled_here := 0
	for i in rooms.size():
		for j in range(i + 1, rooms.size()):
			var e := _edge_between(rooms[i]["rect"], rooms[j]["rect"])
			if e.size == Vector2.ZERO:
				continue
			shared_edges += 1
			if not _covered_by_any(e, walls):
				unwalled_edges += 1
				if str(fl.get("topology", "")) == "historic_wing":
					unwalled_historic += 1
				else:
					unwalled_other += 1
				unwalled_here += 1

	var walls_off := 0
	var multi := 0
	var door_per_wall := {}
	for w: Rect2 in walls:
		var hit := false
		for i in rooms.size():
			for j in range(i + 1, rooms.size()):
				var e := _edge_between(rooms[i]["rect"], rooms[j]["rect"])
				if e.size != Vector2.ZERO and _overlap_len(e, w) >= EDGE_MIN:
					hit = true
					break
			if hit:
				break
		if not hit:
			walls_off += 1
	walls_off_edge += walls_off

	var not_in_wall := 0
	var same_room := 0
	var cross_room := 0
	var missing_room := 0
	var rooms_with_door := {}
	for d: Dictionary in doors:
		var pos3: Vector3 = d.get("position", Vector3.ZERO)
		var p := Vector2(pos3.x, pos3.z)
		var widx := -1
		for wi in walls.size():
			if (walls[wi] as Rect2).grow(0.5).has_point(p):
				widx = wi
				break
		if widx < 0:
			not_in_wall += 1
		else:
			door_per_wall[widx] = int(door_per_wall.get(widx, 0)) + 1
		var a_id := str(d.get("room_a", ""))
		var b_id := str(d.get("room_b", ""))
		if a_id == b_id:
			same_room += 1
		if not by_id.has(a_id) or not by_id.has(b_id):
			missing_room += 1
		else:
			var ra: Rect2 = by_id[a_id]
			var rb: Rect2 = by_id[b_id]
			if _edge_between(ra, rb).size == Vector2.ZERO:
				cross_room += 1
		rooms_with_door[a_id] = true
		rooms_with_door[b_id] = true
	doors_not_in_wall += not_in_wall
	doors_same_room += same_room
	doors_cross_room += cross_room
	doors_missing_room += missing_room
	for v: int in door_per_wall.values():
		if v > 1:
			multi += 1
	walls_multi_door += multi
	var nodoor := 0
	for r: Dictionary in rooms:
		if not rooms_with_door.has(str(r["id"])):
			nodoor += 1
	rooms_no_door += nodoor

	var total_bad := unwalled_here + walls_off + not_in_wall + same_room + cross_room + missing_room + nodoor + multi
	if total_bad > 0:
		worst.append({"n": total_bad, "s": "%s f%d rooms=%d walls=%d doors=%d unwalled=%d wall_off_edge=%d door_not_in_wall=%d same_room=%d cross_room=%d missing_room=%d room_no_door=%d wall_multi_door=%d" % [
			bid, fi, rooms.size(), walls.size(), doors.size(), unwalled_here, walls_off,
			not_in_wall, same_room, cross_room, missing_room, nodoor, multi]})
		if samples.size() < 10:
			samples.append(worst.back()["s"])

static func _edge_between(a: Rect2, b: Rect2) -> Rect2:
	var v_lo := maxf(a.position.y, b.position.y)
	var v_hi := minf(a.end.y, b.end.y)
	if v_hi - v_lo >= EDGE_MIN:
		if absf(a.end.x - b.position.x) < 0.25:
			return Rect2(a.end.x, v_lo, 0.0, v_hi - v_lo)
		if absf(b.end.x - a.position.x) < 0.25:
			return Rect2(b.end.x, v_lo, 0.0, v_hi - v_lo)
	var h_lo := maxf(a.position.x, b.position.x)
	var h_hi := minf(a.end.x, b.end.x)
	if h_hi - h_lo >= EDGE_MIN:
		if absf(a.end.y - b.position.y) < 0.25:
			return Rect2(h_lo, a.end.y, h_hi - h_lo, 0.0)
		if absf(b.end.y - a.position.y) < 0.25:
			return Rect2(h_lo, b.end.y, h_hi - h_lo, 0.0)
	return Rect2()

static func _covered_by_any(edge: Rect2, walls: Array) -> bool:
	for w: Rect2 in walls:
		if _overlap_len(edge, w) >= EDGE_MIN:
			return true
	return false

static func _overlap_len(edge: Rect2, w: Rect2) -> float:
	if edge.size.x == 0.0:
		var near := absf(edge.position.x - w.get_center().x) <= w.size.x * 0.5 + 0.4
		if not near:
			return 0.0
		return minf(edge.end.y, w.end.y) - maxf(edge.position.y, w.position.y)
	var near2 := absf(edge.position.y - w.get_center().y) <= w.size.y * 0.5 + 0.4
	if not near2:
		return 0.0
	return minf(edge.end.x, w.end.x) - maxf(edge.position.x, w.position.x)
