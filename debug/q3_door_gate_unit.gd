extends Node
## FAST gate-level door test: no city generation, no chunk builds.
##
## Builds one synthetic chunk node holding a single real Door and drives the
## REAL gate (ChunkManager.apply_floor_gate) at it, so the door contract is
## checked end to end without paying ~90 s of CityPlan + chunk geometry:
##
##   * a leaf whose whole storey is above the cutaway plane HIDES, and the
##     hidden leaf still reports "hidden" (its cut state is recomputed from the
##     current verdict, never left over from a previous one),
##   * a leaf whose wall the camera looks through is CUT - it stays in the view,
##     halved at the picture rail, with collision intact,
##   * clearing the gate brings the whole leaf back.
##
## Run: godot --headless --path . res://debug/q3_door_gate_unit.tscn

var _cm: ChunkManager
var _chunk: Node3D
var _door: Door
var _checks := 0
var _failures := 0

func _ready() -> void:
	_cm = ChunkManager.new()
	add_child(_cm)

	_chunk = Node3D.new()
	_chunk.name = "Chunk_0_0"
	_cm.add_child(_chunk)

	_door = Door.new()
	_door.name = "Door_b1_0"
	_door.setup({
		"width": 1.10, "height": 2.25, "yaw": 0.0, "hinge": "left",
		"position": Vector3(0.0, 0.0, 0.0), "building_id": "b1", "floor_i": 1,
	})
	_door.set_meta("interior_building_id", "b1")
	_door.set_meta("interior_floor", 1)
	_door.set_meta("door_facade_side", "")
	# The gate stamps interior leaves with their partition rect, footprint-local.
	_door.set_meta("door_wall_cut_key", MeshBatcher.door_wall_cut_key(
			Rect2(0.20, 0.20, 1.10, 0.18)))
	_chunk.add_child(_door)
	_cm._chunks[Vector2i(0, 0)] = {"layers": {}, "asset_nodes": []}

	await get_tree().process_frame
	_check("the leaf is built in two pieces",
			_door._leaf_lower != null and _door._leaf_upper != null)

	# Gate one storey BELOW the leaf: the whole leaf's storey is above the
	# cutaway plane, so no leaf belongs in the view at all.
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 0)
	_check("a leaf above the cutaway hides", not _door.visible)
	_check("the hidden leaf reports hidden, not a stale cut",
			_door.view_state_name() == "hidden")
	_check("hiding never deletes the leaf's geometry",
			_door._leaf_upper != null and _door._leaf_lower != null)

	# Back on the leaf's own storey, outside any sightline: whole leaf again.
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 1)
	_check("coming back down shows the whole leaf",
			_door.visible and _door.view_state_name() == "full")

	# Camera on the leaf's storey looking through the partition it hangs in:
	# the wall is cut, so the leaf must be cut with it - still in the view.
	var from := Vector2(0.20, 3.20)
	var to := Vector2(0.75, 0.20)
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 1, [], -1, from, to)
	_check("a leaf in the camera's wedge is cut", _door.view_state_name() == "cut")
	_check("a cut leaf stays in the world", _door.visible)
	_check("a cut leaf keeps casting the band it lost",
			_door._leaf_upper.cast_shadow
			== MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	_check("a cut leaf keeps the band below the rail drawn",
			_door._leaf_lower.cast_shadow == MeshInstance3D.SHADOW_CASTING_SETTING_ON)
	_check("a cut leaf keeps its collision", _collision_shapes(_door._leaf) == 1)

	# Gate away from the leaf: back to a whole leaf, no lingering cut.
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 1, [], -1, Vector2(40.0, 40.0),
			Vector2(46.0, 40.0))
	_check("leaving the wedge restores the whole leaf",
			_door.view_state_name() == "full" and _door.visible)

	# Exterior leaf on the faded facade: cut, exactly like its wall.
	_door.set_meta("door_facade_side", "N")
	_door.set_meta("door_wall_cut_key", "")
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 1, ["N"])
	_check("an entrance on the faded facade is cut, not removed",
			_door.view_state_name() == "cut" and _door.visible)
	_cm.apply_floor_gate(Vector2i(0, 0), "b1", 1, ["S"])
	_check("a facade the camera is not behind leaves the leaf whole",
			_door.view_state_name() == "full")

	print("[Q3DoorGate] checks=%d failures=%d" % [_checks, _failures])
	# Drop the manager before quitting: its worker threads must join, or the
	# harness hangs on exit and blocks the suite runner.
	_cm.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)


func _collision_shapes(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		if child is CollisionShape3D:
			n += 1
	return n


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("[Q3DoorGate] PASS %s" % label)
	else:
		_failures += 1
		print("[Q3DoorGate] FAIL %s" % label)
