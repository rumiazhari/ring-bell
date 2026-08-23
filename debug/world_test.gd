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


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[CityTest] PASS  %s" % test_name)
	else:
		failures += 1
		print("[CityTest] FAIL  %s   (%s)" % [test_name, detail])
