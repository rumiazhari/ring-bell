extends Node
## Headless determinism harness for the procedural city.
##
##   godot --headless --path . -- --citytest
##
## Verifies the generation contract:
##   1. Same seed -> identical plan data, regardless of query ORDER.
##   2. Same seed -> identical chunk geometry manifests.
##   3. Different seed -> materially different city.
##   4. Spawn anchors exist; multi-storey buildings are generated.
##   5. Chunk persistence records round-trip through save/load dicts.
##   6. Building footprint overlap validation across many blocks/seeds.
##   7. Door manifest consistency for every primary entrance.
##   8. Stair consistency for multi-storey buildings.
##   9. Chunk ACTIVE/WARM/COLD state transitions.
##  10. Negative coordinate blocks generate correctly.
##
## Exits 0 on success, 1 otherwise. Does not touch the save file.

var failures := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[CityTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[CityTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _run_all() -> void:
	print("[CityTest] DEBUG: _run_all started")
	var seed_a := WorldSeed.get_world_seed()

	# --- 1+2: plan + chunk determinism under two query orders -----------------
	var plan_forward := CityPlan.new()
	var digest_fwd := _plan_digest(plan_forward, false)
	var chunk_manifests_fwd := _chunk_manifests(plan_forward)

	var plan_shuffled := CityPlan.new()
	var digest_rev := _plan_digest(plan_shuffled, true)
	var chunk_manifests_rev := _chunk_manifests(plan_shuffled)

	_check("same-seed plans identical regardless of query order",
			digest_fwd == digest_rev,
			"%d vs %d" % [digest_fwd, digest_rev])
	for coord in chunk_manifests_fwd:
		var same := _manifest_equal(chunk_manifests_fwd[coord],
				chunk_manifests_rev[coord])
		_check("chunk %s builds identically" % coord, same,
				str(chunk_manifests_fwd[coord]["boxes"]) + " vs "
				+ str(chunk_manifests_rev[coord]["boxes"]))

	# --- 3: different seed differs ---------------------------------------------
	WorldSeed.set_world_seed(seed_a + 7919)
	var plan_other := CityPlan.new()
	var digest_other := _plan_digest(plan_other, false)
	_check("different seed produces a materially different city",
			digest_other != digest_fwd)
	WorldSeed.set_world_seed(seed_a)

	# --- 4: world sanity ---------------------------------------------------------
	var plan := CityPlan.new()
	var spawn := plan.find_spawn_point()
	_check("spawn anchor found", spawn.is_finite(), str(spawn))
	var nearby := plan.buildings_in_rect(Rect2(spawn - Vector2(90, 90),
			Vector2(180, 180)))
	_check("buildings generated around spawn", nearby.size() >= 8,
			str(nearby.size()))
	var tall := 0
	for spec in plan.buildings_in_rect(Rect2(-160, -160, 320, 320)):
		if int(spec["floors"]) >= 4:
			tall += 1
	_check("multi-storey buildings exist near center", tall >= 5, str(tall))
	var plaza_found := false
	for cell in plan.cells_in_rect(Rect2(-260, -260, 520, 520)):
		if plan.cell_block(cell)["kind"] == &"plaza":
			plaza_found = true
			break
	_check("at least one plaza near center", plaza_found)

	# --- 5: persistence records round-trip --------------------------------------
	var manager := ChunkManager.new()
	manager.setup(CityPlan.new())
	manager.note_discovered(Vector2i(3, -4))
	var rec_data := manager.save_state()
	manager.free()
	var manager2 := ChunkManager.new()
	manager2.setup(CityPlan.new())
	manager2.load_state(rec_data)
	var recs: Dictionary = manager2.save_state()["records"]
	_check("chunk discovery record survives save/load round-trip",
			recs.has("3,-4"), str(recs.keys()))
	manager2.free()
	print("[CityTest] DEBUG: After manager2.free()")

	print("[CityTest] DEBUG: Starting overlap validation tests")
	# --- 6: Building footprint overlap validation (100+ blocks, multiple seeds) --
	_check("building overlap validation - seed A", _validate_no_overlaps(plan, seed_a, 200))
	var test_seeds := [seed_a + 12345, seed_a + 67890, seed_a - 54321, seed_a + 99999]
	for test_seed in test_seeds:
		WorldSeed.set_world_seed(test_seed)
		var test_plan := CityPlan.new()
		_check("building overlap validation - seed %d" % test_seed, _validate_no_overlaps(test_plan, test_seed, 150))
	WorldSeed.set_world_seed(seed_a)
	
	print("[CityTest] DEBUG: Starting door manifest tests")
	# --- 7: Door manifest consistency -------------------------------------------
	_check("door manifest consistency", _validate_door_manifests(plan))

	print("[CityTest] DEBUG: Starting stair consistency tests")
	# --- 8: Stair consistency for multi-storey buildings -----------------------
	_check("stair consistency", _validate_stair_consistency(plan))

	print("[CityTest] DEBUG: Starting negative coordinate tests")
	# --- 10: Negative coordinates -----------------------------------------------
	_check("negative coordinate blocks", _test_negative_coordinates(plan))

	print("[CityTest] DEBUG: Starting chunk state transition tests")
	# --- 9: Chunk ACTIVE/WARM/COLD transitions ----------------------------------
	_check("chunk state transitions", _test_chunk_state_transitions())


# --- Digest helpers ------------------------------------------------------------

func _plan_digest(plan: CityPlan, reverse: bool) -> int:
	var cells := plan.cells_in_rect(Rect2(-220, -220, 440, 440))
	if reverse:
		cells.reverse()
	var parts: Array[String] = []
	for cell in cells:
		var block := plan.cell_block(cell)
		parts.append("%s|%s|%s" % [block["id"], block["rect"], block["kind"]])
		var specs: Array = block["buildings"]
		specs.sort_custom(func(a, b) -> bool: return a["id"] < b["id"])
		for spec in specs:
			parts.append("%s|%s|%d|%.2f|%d|%s" % [spec["id"], spec["rect"],
					spec["floors"], spec["floor_h"], spec["door_edge"],
					spec["style"]])
	parts.sort()   # order-insensitive: query order must not affect the digest
	return hash("\n".join(parts))


func _chunk_manifests(plan: CityPlan) -> Dictionary:
	var out := {}
	for coord in [Vector2i(0, 0), Vector2i(-2, 1), Vector2i(3, -2)]:
		var b := MeshBatcher.new()
		ChunkBuilder.fill_batcher(b, plan, coord)
		out[coord] = b.manifest()
	return out


func _manifest_equal(a: Dictionary, b: Dictionary) -> bool:
	if int(a["boxes"]) != int(b["boxes"]):
		return false
	var ca: Array = a["colliders"]
	var cb: Array = b["colliders"]
	if ca.size() != cb.size():
		return false
	for i in ca.size():
		var x: Dictionary = ca[i]
		var y: Dictionary = cb[i]
		if x["pos"] != y["pos"] or x["size"] != y["size"] \
				or x["basis"] != y["basis"]:
			return false
	if (a["group_keys"] as Array).size() != (b["group_keys"] as Array).size():
		return false
	return true


# --- 6: Building footprint overlap validation ----------------------------------
func _validate_no_overlaps(plan: CityPlan, seed: int, max_blocks: int) -> bool:
	var errors: Array[String] = []
	var blocks_checked := 0
	# Check a smaller area for speed
	for cell in plan.cells_in_rect(Rect2(-400, -400, 800, 800)):
		if blocks_checked >= max_blocks:
			break
		var block := plan.cell_block(cell)
		if block["kind"] == &"park":
			continue
		errors.append_array(CityPlan.validate_buildings(block["buildings"]))
		blocks_checked += 1
	if not errors.is_empty():
		print("[CityTest] Overlap errors for seed %d: %s" % [seed, errors])
		return false
	return true


# --- 7: Door manifest consistency ----------------------------------------------
func _validate_door_manifests(plan: CityPlan) -> bool:
	for cell in plan.cells_in_rect(Rect2(-400, -400, 800, 800)):
		var block := plan.cell_block(cell)
		if block["kind"] == &"park":
			continue
		for spec in block["buildings"]:
			var doors: Array = spec.get("doors", [])
			if doors.is_empty():
				return false
			for dm: Dictionary in doors:
				# Every door must have a stable unique ID
				if not dm.has("id") or str(dm["id"]).is_empty():
					return false
				# Door must reference its building
				if not dm.has("building_id") or str(dm["building_id"]).is_empty():
					return false
				# Door must have position, yaw, dimensions
				if not dm.has("position") or not dm.has("yaw"):
					return false
				if not dm.has("width") or not dm.has("height"):
					return false
				# Hinge must be left or right
				var hinge := str(dm.get("hinge", ""))
				if hinge != "left" and hinge != "right":
					return false
				# Locked state
				if not dm.has("locked"):
					return false
				# Open angle
				if not dm.has("open_angle"):
					return false
				# Swing direction
				if not dm.has("swing"):
					return false
				# Geometry: the door position must lie ON the facade line of
				# its footprint for the declared edge (opening really exists).
				var lot: Rect2 = spec["rect"]
				var pos: Vector3 = dm["position"]
				match int(spec["door_edge"]):
					0:
						if absf(pos.z - lot.position.y) > 0.01 \
								or pos.x < lot.position.x \
								or pos.x > lot.end.x:
							return false
					1:
						if absf(pos.x - lot.end.x) > 0.01 \
								or pos.z < lot.position.y \
								or pos.z > lot.end.y:
							return false
					2:
						if absf(pos.z - lot.end.y) > 0.01 \
								or pos.x < lot.position.x \
								or pos.x > lot.end.x:
							return false
					_:
						if absf(pos.x - lot.position.x) > 0.01 \
								or pos.z < lot.position.y \
								or pos.z > lot.end.y:
							return false
	return true


# --- 8: Stair consistency for multi-storey buildings --------------------------
func _validate_stair_consistency(plan: CityPlan) -> bool:
	for cell in plan.cells_in_rect(Rect2(-400, -400, 800, 800)):
		var block := plan.cell_block(cell)
		if block["kind"] == &"park":
			continue
		for spec in block["buildings"]:
			var floors := int(spec["floors"])
			if floors < 2:
				continue  # single-storey buildings don't need stairs
			var fp: Vector2 = (spec["rect"] as Rect2).size
			var fh := float(spec["floor_h"])
			# Building must have enough depth for stair zone
			if not BuildingBuilder.has_stairs_for(fp, fh, floors):
				print("[CityTest] Building %s has floors=%d but insufficient depth for stairs" % [spec["id"], floors])
				return false
			# Stair zone must be within footprint
			var zone := BuildingBuilder.stair_zone_world(spec)
			var footprint: Rect2 = spec["rect"]
			if not footprint.encloses(zone):
				print("[CityTest] Building %s stair zone extends outside footprint" % spec["id"])
				return false
	return true


# --- 9: Chunk state transitions ------------------------------------------------
func _test_chunk_state_transitions() -> bool:
	var test_plan := CityPlan.new()
	var manager := ChunkManager.new()
	manager.setup(test_plan)
	manager.synchronous = true   # inline builds: deterministic pump loop

	# Mock player at chunk (0,0)
	var player_mock := Node3D.new()
	add_child(player_mock)
	player_mock.global_position = Vector3(0, 0, 0)
	manager.set_player(player_mock)

	# Record every state transition for the signal-contract check.
	var transitions: Array[String] = []
	manager.chunk_state_changed.connect(_capture_transition.bind(transitions))

	# Pump until the initial warm ring is fully resident (budgeted loads).
	if not _pump_stable(manager):
		print("[CityTest] initial ring never stabilized")
		manager.free()
		player_mock.free()
		return false

	for coord: Vector2i in manager._chunks:
		var d := chebyshev_distance(coord, Vector2i(0, 0))
		var expected := &"active" if d <= ChunkManager.ACTIVE_RADIUS else &"warm"
		if manager.state_of(coord) != expected:
			print("[CityTest] Chunk %s has state %s but expected %s"
					% [coord, manager.state_of(coord), expected])
			manager.free()
			player_mock.free()
			return false

	# Move player to chunk (2,0) - states must re-evaluate and far chunks unload.
	transitions.clear()
	player_mock.global_position = Vector3(128 + 1.0, 0, 0)   # safely inside (2,0)
	if not _pump_stable(manager):
		print("[CityTest] ring never stabilized after move")
		manager.free()
		player_mock.free()
		return false

	for coord: Vector2i in manager._chunks:
		var d := chebyshev_distance(coord, Vector2i(2, 0))
		if d > ChunkManager.UNLOAD_RADIUS:
			print("[CityTest] Chunk %s should have unloaded (d=%d)"
					% [coord, d])
			manager.free()
			player_mock.free()
			return false
		var expected := &"active" if d <= ChunkManager.ACTIVE_RADIUS \
				else (&"warm" if d <= ChunkManager.WARM_RADIUS else &"cold")
		if manager.state_of(coord) != expected:
			print("[CityTest] After move: Chunk %s has state %s but expected %s"
					% [coord, manager.state_of(coord), expected])
			manager.free()
			player_mock.free()
			return false

	# The move MUST have produced at least one state change event.
	if transitions.is_empty():
		print("[CityTest] no chunk_state_changed signals after player moved")
		manager.free()
		player_mock.free()
		return false

	manager.free()
	player_mock.free()
	return true


## Run streaming updates until nothing is pending/inflight (bounded).
func _pump_stable(manager: ChunkManager, max_iterations := 400) -> bool:
	for i in max_iterations:
		manager._process(0.25)
		if manager.pending_count() == 0:
			return true
	return false


func _capture_transition(coord: Vector2i, new_state: StringName,
		sink: Array[String]) -> void:
	sink.append("%s->%s" % [coord, new_state])


# Helper for chebyshev distance
func chebyshev_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# --- 10: Negative coordinate blocks --------------------------------------------
func _test_negative_coordinates(plan: CityPlan) -> bool:
	# Test that negative coordinates generate valid blocks
	var neg_rect := Rect2(-1000, -1000, 500, 500)
	var blocks_found := 0
	for cell in plan.cells_in_rect(neg_rect):
		var block := plan.cell_block(cell)
		if block["kind"] != &"park":
			blocks_found += 1
			# Verify buildings have valid footprints
			for spec in block["buildings"]:
				var r: Rect2 = spec["rect"]
				if r.size.x < 4.0 or r.size.y < 4.0:
					return false
				if int(spec["floors"]) < 1:
					return false
	
	# Also test positive coordinates for symmetry
	var pos_rect := Rect2(500, 500, 500, 500)
	var pos_blocks := 0
	for cell in plan.cells_in_rect(pos_rect):
		var block := plan.cell_block(cell)
		if block["kind"] != &"park":
			pos_blocks += 1
	
	return blocks_found > 0 and pos_blocks > 0


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[CityTest] PASS  %s" % test_name)
	else:
		failures += 1
		print("[CityTest] FAIL  %s   (%s)" % [test_name, detail])
