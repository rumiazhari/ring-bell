extends Node
## Door-leaf dollhouse cut: a door whose wall the camera is looking through is
## CUT at the picture rail with that wall - it is never retired from the view.
##
## User report: "the walls and doors are cut whenever they obstruct the camera
## view, but it shouldn't remove the door entirely - the door must be cut by half
## similar to the wall cut."
##
## Checks
##   1. A real Door splits its leaf at the picture rail: the piece below the rail
##      is always drawn, the piece above it is kept and merely dropped from the
##      camera pass (the treatment "structure hidden from the camera keeps
##      casting shadows" gives every other hidden piece).
##   2. View states full / cut / hidden, and a cut that never touches collision,
##      mass or the door's own state machine.
##   3. MeshBatcher.door_reveal truth table: storey rule, facade rule, and the
##      interior-leaf rule (its own partition rect vs the camera wedge).
##   4. REAL generated city geometry through the REAL gate
##      (ChunkManager.apply_floor_gate): on the resident storey no leaf of the
##      resident building is retired, the leaf on the faded facade is CUT, an
##      interior leaf whose wall sits in the camera wedge is CUT and one outside
##      it stays whole, and only a leaf a storey above the cutaway hides.
##
## Run: "C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe"
##        --headless --path . res://debug/q3_door_cut_test.tscn

const RAIL := WorldConstants.PICTURE_RAIL_H

var _checks := 0
var _fails := 0
var _skips := 0


func _ready() -> void:
	# Failsafe: a script error must never hang the harness.
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_error("[Q3DoorCut] watchdog timeout")
		get_tree().quit(2))
	_run()


func _run() -> void:
	await _unit_leaf()
	_unit_reveal_table()
	await _real_world()
	print("[Q3DoorCut] checks=%d failures=%d skipped=%d" % [_checks, _fails, _skips])
	get_tree().quit(1 if _fails > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("[Q3DoorCut] PASS %s %s" % [label, detail])
	else:
		_fails += 1
		print("[Q3DoorCut] FAIL %s %s" % [label, detail])


func _skip(label: String, why: String) -> void:
	_skips += 1
	print("[Q3DoorCut] SKIP %s (%s)" % [label, why])


# --- 1+2. one real Door node -------------------------------------------------

func _probe_door(man: Dictionary) -> Door:
	var door := Door.new()
	door.name = "CutProbe"
	door.setup(man)
	add_child(door)
	return door


func _collision_shapes(leaf: Node) -> int:
	var n := 0
	for c in leaf.get_children():
		if c is CollisionShape3D:
			n += 1
	return n


func _unit_leaf() -> void:
	var door := _probe_door({
		"id": "cut_probe", "building_id": "probe", "position": Vector3.ZERO,
		"yaw": 0.0, "edge": 0, "width": 1.05, "height": 2.25,
		"hinge": "left", "locked": false, "open_angle": 95.0,
	})
	await get_tree().process_frame

	var lower: MeshInstance3D = door._leaf_lower
	var upper: MeshInstance3D = door._leaf_upper
	_check("leaf is built in two pieces", lower != null and upper != null)
	if lower == null or upper == null:
		door.queue_free()
		return
	var lb: Vector3 = (lower.mesh as BoxMesh).size
	var ub: Vector3 = (upper.mesh as BoxMesh).size
	var rail := lower.position.y + lb.y * 0.5
	var upper_bottom := upper.position.y - ub.y * 0.5
	var leaf_top := upper.position.y + ub.y * 0.5
	_check("lower piece stops at the picture rail", absf(rail - RAIL) <= 0.02,
			"rail=%.3f want=%.3f" % [rail, RAIL])
	_check("upper piece starts where the lower ends",
			absf(upper_bottom - rail) <= 0.01, "%.3f vs %.3f" % [upper_bottom, rail])
	_check("the two pieces still span the whole leaf",
			absf(leaf_top - 2.23) <= 0.03 and lb.x == ub.x and lb.z == ub.z,
			"top=%.3f w=%.3f/%.3f d=%.3f/%.3f" % [leaf_top, lb.x, ub.x, lb.z, ub.z])
	_check("a leaf is not cut before the gate asks", door.view_state_name() == "full"
			and upper.cast_shadow == MeshInstance3D.SHADOW_CASTING_SETTING_ON)

	door.set_view_cut(true)
	_check("cut leaves the door in the world", door.visible and door.is_visible_in_tree())
	_check("cut drops only the band above the rail",
			upper.cast_shadow == MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	_check("cut keeps the band below the rail drawn",
			lower.cast_shadow == MeshInstance3D.SHADOW_CASTING_SETTING_ON and lower.visible)
	_check("cut keeps casting the dropped band's shadow", upper.is_visible_in_tree())
	_check("cut reads back as cut", door.view_state_name() == "cut")
	_check("cut leaves leaf collision alone",
			_collision_shapes(door._leaf) == 1 and door._leaf is RigidBody3D)
	_check("cut leaves the door's own state alone",
			door.state == Door.DoorState.CLOSED and door.is_solid())

	door.set_view_cut(false)
	_check("clearing the cut restores the whole leaf",
			door.view_state_name() == "full"
			and upper.cast_shadow == MeshInstance3D.SHADOW_CASTING_SETTING_ON)

	door.set_view_hidden(true)
	_check("only the storey-above state hides the door",
			door.view_state_name() == "hidden" and not door.visible)
	_check("hidden leaf still has its geometry",
			door._leaf_upper != null and _collision_shapes(door._leaf) == 1)
	door.set_view_hidden(false)
	_check("un-hiding brings the whole leaf back",
			door.visible and door.view_state_name() == "full")

	# A leaf shorter than the rail has nothing above it: the cut must be a no-op
	# rather than a lie about a band that does not exist.
	var low := _probe_door({
		"id": "low_probe", "building_id": "probe", "position": Vector3(3.0, 0.0, 0.0),
		"yaw": 0.0, "edge": 0, "width": 0.95, "height": 0.9,
		"hinge": "left", "locked": false, "open_angle": 95.0,
	})
	await get_tree().process_frame
	low.set_view_cut(true)
	_check("a leaf fully below the rail reports no cut",
			low._leaf_upper == null and low.view_state_name() == "full"
			and low.visible, "state=%s" % low.view_state_name())

	door.queue_free()
	low.queue_free()


# --- 3. the reveal rule itself ----------------------------------------------

func _unit_reveal_table() -> void:
	var R := MeshBatcher.DoorReveal
	_check("leaf of another building is untouched",
			MeshBatcher.door_reveal("b1", 0, "N", "", "b2", 0, ["N"]) == R.FULL)
	_check("leaf on a solid facade stays whole",
			MeshBatcher.door_reveal("b1", 0, "N", "", "b1", 0, ["S"]) == R.FULL)
	_check("entrance leaf on the cut facade is CUT, not retired",
			MeshBatcher.door_reveal("b1", 0, "N", "", "b1", 0, ["N"]) == R.CUT)
	_check("leaf below the cutaway keeps its wall and stays whole",
			MeshBatcher.door_reveal("b1", 0, "N", "", "b1", 2, ["N"]) == R.FULL)
	_check("leaf above the cutaway hides",
			MeshBatcher.door_reveal("b1", 3, "", "", "b1", 2, []) == R.HIDDEN)
	_check("gate closed again reveals everything",
			MeshBatcher.door_reveal("b1", 3, "N", "", "b1", -1, []) == R.FULL)
	_check("interior leaf ignores facade fading",
			MeshBatcher.door_reveal("b1", 1, "", "", "b1", 2, ["N"]) == R.FULL)
	# Interior leaf: its own partition rect against the camera->player wedge.
	var from := Vector2(1.09, 0.0)
	var to := Vector2(1.09, 4.0)
	_check("interior leaf whose wall the camera looks through is CUT",
			MeshBatcher.door_reveal("b1", 0, "", "1.00_2.00_0.18_3.00",
					"b1", 0, [], from, to) == R.CUT)
	_check("interior leaf outside the wedge stays whole",
			MeshBatcher.door_reveal("b1", 0, "", "6.00_2.00_0.18_3.00",
					"b1", 0, [], from, to) == R.FULL)
	_check("interior leaf with no wall key is never cut",
			MeshBatcher.door_reveal("b1", 0, "", "", "b1", 0, [], from, to) == R.FULL)
	_check("no sightline means no wedge cut",
			MeshBatcher.door_reveal("b1", 0, "", "1.00_2.00_0.18_3.00",
					"b1", 0, []) == R.FULL)


# --- 4. real city geometry through the real gate ----------------------------

func _pick_building(plan: CityPlan, world: WorldPlan) -> Dictionary:
	for spec: Dictionary in plan.city_buildings():
		if (spec.get("doors", []) as Array).is_empty():
			continue
		if int(spec.get("floors", 1)) < 2:
			continue
		var rect: Rect2 = spec["rect"]
		if rect.size.x < 6.0 or rect.size.y < 6.0:
			continue
		# The chunk must actually carry the historic-urban composition, or the
		# runtime emits no doors there at all.
		var c: Vector2 = rect.get_center()
		var comp: Dictionary = world.chunk_composition(WorldSeed.chunk_coord(c.x, c.y))
		if not bool(comp.get("city_materialized", false)):
			continue
		return spec
	return {}


## Every door leaf in the resident manager, keyed by the chunk that owns it.
func _doors_by_chunk(cm: ChunkManager) -> Dictionary:
	var out := {}
	for coord: Vector2i in cm._chunks.keys():
		var node := cm.get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if node == null:
			continue
		var list: Array = []
		for child in node.get_children():
			# Doors only: interior stations carry the same floor/building metas
			# but have no leaf to cut.
			if child is Door and child.has_meta("interior_floor"):
				list.append(child)
		if not list.is_empty():
			out[coord] = list
	return out


func _meta_str(d: Node, key: String) -> String:
	return str(d.get_meta(key, ""))


func _meta_floor(d: Node) -> int:
	return int(d.get_meta("interior_floor", -1))


func _real_world() -> void:
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	var spec := _pick_building(plan, world)
	if spec.is_empty():
		_check("a real multi-storey city building exists", false)
		return
	var centre: Vector2 = (spec["rect"] as Rect2).get_center()
	var cm := ChunkManager.new()
	add_child(cm)
	cm.synchronous = true
	cm.setup_world(plan, world)
	var player := Node3D.new()
	player.position = Vector3(centre.x,
			world.surface_height_at(centre) + 1.0, centre.y)
	add_child(player)
	cm.set_player(player)
	# Build only what the assertions need: the chunk holding the building plus its
	# ring, driven through the manager's own pipeline (_thread_build ->
	# _materialize) so the records, layers and gate bookkeeping are the real ones.
	# The normal stream walks a 5x5 warm ring, which is minutes of work here.
	var pc := WorldSeed.chunk_coord(centre.x, centre.y)
	var built := 0
	var t0 := Time.get_ticks_msec()
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var coord := Vector2i(pc.x + dx, pc.y + dy)
			var batcher := MeshBatcher.new()
			var holder := {
				"terrain": {}, "terrain_gen_ms": 0.0, "water": {}, "water_gen_ms": 0.0,
				"biome": {}, "biome_gen_ms": 0.0, "road": {}, "road_gen_ms": 0.0,
				"rural": {}, "rural_gen_ms": 0.0, "fringe": {}, "fringe_gen_ms": 0.0,
				"cave": {}, "cave_gen_ms": 0.0, "vertical": {}, "vertical_gen_ms": 0.0,
				"gen_ms": 0.0,
			}
			cm._thread_build(batcher, coord, holder, world.seed_used)
			cm._materialize(coord, batcher, holder.get("terrain", {}), 0.0, pc,
					0.0, holder.get("water", {}), 0.0, holder.get("biome", {}), 0.0,
					holder.get("road", {}), 0.0, holder.get("rural", {}), 0.0,
					holder.get("fringe", {}), 0.0, world.chunk_composition(coord),
					holder.get("cave", {}), 0.0, holder.get("vertical", {}), 0.0)
			built += 1
	print("[Q3DoorCut] built %d chunks around %s in %d ms" % [built, str(pc),
			Time.get_ticks_msec() - t0])
	var by_chunk := _doors_by_chunk(cm)
	var leaves := 0
	for _c: Vector2i in by_chunk.keys():
		leaves += (by_chunk[_c] as Array).size()
	_check("real city chunks with door leaves are resident", not by_chunk.is_empty(),
			"%d chunks, %d leaves" % [by_chunk.size(), leaves])

	# --- entrance leaf on the camera-facing facade -------------------------
	var entry_chunk := Vector2i.ZERO
	var entry: Node = null
	for coord: Vector2i in by_chunk.keys():
		for d: Node in by_chunk[coord]:
			if _meta_str(d, "door_facade_side") != "" and _meta_floor(d) == 0:
				entry_chunk = coord
				entry = d
				break
		if entry != null:
			break
	if entry == null:
		_skip("entrance leaf on the resident storey", "no exterior leaf in range")
	else:
		var bld := _meta_str(entry, "interior_building_id")
		var side := _meta_str(entry, "door_facade_side")
		var doomed := _meta_str(entry, "door_wall_cut_key")
		cm.apply_floor_gate(entry_chunk, bld, 0, [side], -1)
		_check("entrance leaf on the faded facade is CUT, not removed",
				entry.visible and entry.view_state_name() == "cut",
				"side=%s state=%s visible=%s" % [side, entry.view_state_name(),
				str(entry.visible)])
		_check("entrance leaf keeps the band below the rail",
				entry._leaf_lower != null and entry._leaf_upper != null
				and entry._leaf_upper.cast_shadow
						== MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				and _collision_shapes(entry._leaf) == 1)
		var storey := 0
		var retired := 0
		for d: Node in by_chunk[entry_chunk]:
			if _meta_str(d, "interior_building_id") == bld and _meta_floor(d) == storey:
				if not (d as Node3D).visible:
					retired += 1
		_check("no leaf of the resident building is retired on the resident storey",
				retired == 0, "retired=%d" % retired)

	# --- interior partition leaf vs the camera wedge ------------------------
	var wall_key := ""
	var wedge_chunk := Vector2i.ZERO
	var wedge_leaf: Node = null
	var wedge_floor := 0
	var wedge_bld := ""
	for coord: Vector2i in by_chunk.keys():
		for d: Node in by_chunk[coord]:
			if _meta_str(d, "door_wall_cut_key") != "":
				wall_key = _meta_str(d, "door_wall_cut_key")
				wedge_chunk = coord
				wedge_leaf = d
				wedge_floor = _meta_floor(d)
				wedge_bld = _meta_str(d, "interior_building_id")
				break
		if wedge_leaf != null:
			break
	if wedge_leaf == null:
		_skip("interior partition leaf in the camera wedge", "no interior leaf in range")
	else:
		var r := MeshBatcher._parse_rect_key(wall_key)
		var from := Vector2(r.get_center().x, r.position.y - 1.5)
		var to := Vector2(r.get_center().x, r.end.y + 1.5)
		cm.apply_floor_gate(wedge_chunk, wedge_bld, wedge_floor, [], -1, from, to)
		_check("interior leaf whose own wall is in the wedge is CUT",
				wedge_leaf.visible and wedge_leaf.view_state_name() == "cut",
				"key=%s state=%s" % [wall_key, wedge_leaf.view_state_name()])
		_check("interior leaf keeps collision through the cut",
				_collision_shapes(wedge_leaf._leaf) == 1)
		# A leaf on the same storey whose wall the wedge misses must stay whole.
		var other: Node = null
		for d: Node in by_chunk[wedge_chunk]:
			if d == wedge_leaf or _meta_str(d, "interior_building_id") != wedge_bld \
					or _meta_floor(d) != wedge_floor:
				continue
			var key := _meta_str(d, "door_wall_cut_key")
			if key != "" and key != wall_key \
					and not MeshBatcher.wall_cut_hidden(key, from, to):
				other = d
				break
		if other == null:
			_skip("interior leaf outside the wedge", "no second interior leaf in range")
		else:
			_check("interior leaf outside the wedge stays whole",
					other.visible and other.view_state_name() == "full",
					"state=%s" % other.view_state_name())

	# --- the only state that retires a leaf: a storey above the cutaway ----
	var high: Node = null
	var high_chunk := Vector2i.ZERO
	var high_bld := ""
	for coord: Vector2i in by_chunk.keys():
		for d: Node in by_chunk[coord]:
			if _meta_floor(d) >= 1:
				high = d
				high_chunk = coord
				high_bld = _meta_str(d, "interior_building_id")
				break
		if high != null:
			break
	if high == null:
		_skip("leaf one storey above the cutaway", "no upper-storey leaf in range")
	else:
		var upper_floor := _meta_floor(high)
		var cn := cm.get_node_or_null(NodePath("Chunk_%d_%d" % [high_chunk.x, high_chunk.y]))
		print("[Q3DoorCut] diag high name=%s bld=%s floor=%d parent=%s chunk_node=%s under_chunk=%s vis=%s verdict=%s" % [
			high.name, high_bld, upper_floor, high.get_parent().name,
			str(cn != null),
			str(cn != null and cn.is_ancestor_of(high)),
			str((high as Node3D).visible),
			MeshBatcher.DoorReveal.keys()[MeshBatcher.door_reveal(high_bld, upper_floor,
					_meta_str(high, "door_facade_side"), _meta_str(high, "door_wall_cut_key"),
					high_bld, upper_floor - 1, [])]])
		cm.apply_floor_gate(high_chunk, high_bld, upper_floor - 1, [], -1)
		_check("leaf one storey above the cutaway hides",
				high.view_state_name() == "hidden" and not (high as Node3D).visible,
				"floor=%d state=%s" % [upper_floor, high.view_state_name()])
		_check("a hidden leaf is not deleted geometry",
				high._leaf_upper != null and high._leaf_lower != null
				and _collision_shapes(high._leaf) == 1)
		cm.apply_floor_gate(high_chunk, high_bld, upper_floor, [], -1)
		_check("coming back down shows the leaf again",
				(high as Node3D).visible and high.view_state_name() == "full")

	cm.queue_free()
