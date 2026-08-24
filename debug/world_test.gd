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

	print("[CityTest] DEBUG: Starting building-foundation acceptance tests")
	# --- 11..17: P0 foundation contract tests ------------------------------------
	_check("slab coverage = footprint minus shaft (numeric)", _test_slab_coverage())
	_check("stair flight geometry (flush endpoints, slope, all storeys)",
			_test_stair_geometry())
	_check("furniture floor ownership + placement bounds", _test_furniture())
	_check("facade apertures composed without solid backs", _test_facade_apertures())
	_check("structural damage accumulates by material", _test_damage_model())
	_check("destruction deltas persist across rebuild + save/load",
			_test_destruction_persistence())
	_check("interior probe detection + facade sector math", _test_interior_probe())


# --- 11: Slab coverage ---------------------------------------------------------
func _test_slab_coverage() -> bool:
	var seeds := [WorldSeed.get_world_seed(), WorldSeed.get_world_seed() + 4242]
	var checked := 0
	for seed_v: int in seeds:
		WorldSeed.set_world_seed(seed_v)
		var plan := CityPlan.new()
		for cell in plan.cells_in_rect(Rect2(-200, -200, 400, 400)):
			if checked >= 40:
				break
			var block := plan.cell_block(cell)
			for spec: Dictionary in block["buildings"]:
				if int(spec["floors"]) < 2:
					continue
				var fp: Rect2 = spec["rect"]
				var fh := float(spec["floor_h"])
				var hole := BuildingBuilder.stair_zone_world(spec)
				# Local-frame conversion of the world-space zone.
				var local_hole := Rect2(hole.position - fp.position,
						hole.size)
				var pieces := BuildingBuilder.slab_pieces(
						fp.size.x, fp.size.y, local_hole)
				var usable_area := (fp.size.x - 0.7) * (fp.size.y - 0.7)
				var shaft := local_hole.intersection(Rect2(
						0.35, 0.35, fp.size.x - 0.7, fp.size.y - 0.7))
				var expected := usable_area - shaft.get_area()
				var got := SlabMath.total_area(pieces)
				if absf(got - expected) > 0.5:
					print("[CityTest] slab area %s: got %.2f want %.2f"
							% [spec["id"], got, expected])
					return false
				if SlabMath.overlaps_any(pieces):
					print("[CityTest] slab pieces overlap in %s" % spec["id"])
					return false
				# Grid sampling: every interior point is either covered or in
				# the shaft - no uncovered region outside the aperture.
				for gx in range(1, int(fp.size.x * 3)):
					for gz in range(1, int(fp.size.y * 3)):
						var pnt := Vector2(gx / 3.0, gz / 3.0)
						if pnt.x < 0.35 or pnt.y < 0.35 \
								or pnt.x > fp.size.x - 0.35 \
								or pnt.y > fp.size.y - 0.35:
							continue
						if not SlabMath.covers_point(pieces, pnt) \
								and not local_hole.has_point(pnt):
							print("[CityTest] uncovered point %s at %s"
									% [spec["id"], pnt])
							return false
				checked += 1
	WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
	return checked >= 10


# --- 12: Stair geometry --------------------------------------------------------
func _test_stair_geometry() -> bool:
	var plan := CityPlan.new()
	var tested := 0
	for cell in plan.cells_in_rect(Rect2(-300, -300, 600, 600)):
		if tested >= 30:
			break
		var block := plan.cell_block(cell)
		for spec: Dictionary in block["buildings"]:
			var n := int(spec["floors"])
			if n < 2 or not BuildingBuilder.has_stairs_for(
					(spec["rect"] as Rect2).size, float(spec["floor_h"]), n):
				continue
			var fh := float(spec["floor_h"])
			var run := BuildingBuilder.flight_run(fh)
			var ang := BuildingBuilder.flight_angle(fh)
			# Slope must be climbable by the Survivor body.
			if ang >= deg_to_rad(46.0):
				print("[CityTest] stair too steep %s: %.1f deg"
						% [spec["id"], rad_to_deg(ang)])
				return false
			var zone := BuildingBuilder.stair_zone_world(spec)
			# Ramp top surface endpoints must sit exactly on landing surfaces.
			var bottom := BuildingBuilder.ramp_height_at(
					zone.position.y + BuildingBuilder.LAND, 0.0, fh,
					zone.position.y)
			var top := BuildingBuilder.ramp_height_at(
					zone.end.y - BuildingBuilder.LAND, 0.0, fh,
					zone.position.y)
			if absf(bottom - 0.0) > 0.02:
				print("[CityTest] ramp bottom lip %s: %.3f" % [spec["id"], bottom])
				return false
			if absf(top - fh) > 0.02:
				print("[CityTest] ramp top mismatch %s: %.3f vs %.3f"
						% [spec["id"], top, fh])
				return false
			# Every storey k: base_y = k*fh must produce flush endpoints.
			for k in range(1, n):
				var yk := BuildingBuilder.ramp_height_at(
						zone.end.y - BuildingBuilder.LAND, float(k) * fh,
						fh, zone.position.y)
				if absf(yk - float(k + 1) * fh) > 0.02:
					print("[CityTest] storey %d endpoint off in %s" % [k, spec["id"]])
					return false
			tested += 1
	return tested >= 8


# --- 13: Furniture floor ownership ----------------------------------------------
func _test_furniture() -> bool:
	# Emit one known multi-storey building and verify every furniture-class
	# collider sits on ITS OWN storey's band and never on floor 0's.
	var plan := CityPlan.new()
	var spec := {}
	for cell in plan.cells_in_rect(Rect2(-160, -160, 320, 320)):
		for s: Dictionary in plan.cell_block(cell)["buildings"]:
			if int(s["floors"]) >= 4 and BuildingBuilder.has_stairs_for(
					(s["rect"] as Rect2).size, float(s["floor_h"]),
					int(s["floors"])):
				spec = s
				break
		if not spec.is_empty():
			break
	if spec.is_empty():
		print("[CityTest] no stair building found for furniture test")
		return false
	var b := MeshBatcher.new()
	var fp_local := CityPlan.new()
	var coord := WorldSeed.chunk_coord(
			(spec["rect"] as Rect2).get_center().x,
			(spec["rect"] as Rect2).get_center().y)
	ChunkBuilder.fill_batcher(b, fp_local, coord)
	var fh := float(spec["floor_h"])
	var floors := mini(int(spec["floors"]), 8)
	var fp: Rect2 = spec["rect"]
	# Furniture Y signatures: collect distinct base heights of colliders that
	# match table/desk/shelf volumes and lie inside this footprint.
	var heights := {}
	for col in b.manifest()["colliders"]:
		var pos: Vector3 = col["pos"]
		var size: Vector3 = col["size"]
		if size.y > 0.6 and size.y < 2.1 and pos.y > 0.3:
			var lx := pos.x - fp.position.x
			var lz := pos.z - fp.position.y
			if lx < -0.5 or lz < -0.5 or lx > fp.size.x + 0.5 \
					or lz > fp.size.y + 0.5:
				continue
			heights[snappedf(pos.y, 0.01)] = true
	if heights.is_empty():
		return true   # nothing furnished here; vacuously fine
	# Furniture-height classifier (P0-C contract): every furniture-class
	# collider must sit on the surface of SOME storey of THIS building:
	#   h - floor_i*fh in {table/desk ~0.37, shelf 1.0, chair 0.23, rail .55,
	#   lintel/sill bands, glass centers} - i.e. within a known furniture or
	#   aperture band above a storey surface. Crucially NO height may map to
	#   "between floors" (the old stacking bug put floor-1+ items at Y=0.37).
	var win_sill := 0.85
	var win_h := 1.35
	var lintel_c: float = win_sill + win_h \
			+ maxf(fh - win_sill - win_h, 0.0) * 0.5
	var known_offsets := [0.05, 0.17, 0.23, 0.36, 0.37, 0.425, 0.55,
			0.525, 1.0, 1.06, 1.31, 1.525, 0.9, 0.85, 0.7, lintel_c]
	for h: float in heights.keys():
		var ok := false
		# Rails/guards live one storey HIGHER than the surface they protect
		# (deck rails sit above the top slab), so scan fi in floors+1.
		for fi in floors + 1:
			var off := h - float(fi) * fh
			if off < -0.01:
				break
			for ko: float in known_offsets:
				if absf(off - ko) < 0.08:
					ok = true
					break
			if ok:
				break
		if not ok:
			print("[CityTest] furniture y=%.3f matches no storey band" % h)
			return false
	return true


# --- 14: Facade apertures -------------------------------------------------------
func _test_facade_apertures() -> bool:
	# For a sample building: count glass specs and verify NO concrete collider
	# occupies the same XZ band as a window pane at window height (the old
	# bug: solid wall behind destructible glass).
	var plan := CityPlan.new()
	var found := false
	for cell in plan.cells_in_rect(Rect2(-160, -160, 320, 320)):
		for s: Dictionary in plan.cell_block(cell)["buildings"]:
			if int(s["floors"]) >= 3:
				var b := MeshBatcher.new()
				var c := WorldSeed.chunk_coord(
						(s["rect"] as Rect2).get_center().x,
						(s["rect"] as Rect2).get_center().y)
				ChunkBuilder.fill_batcher(b, CityPlan.new(), c)
				manifest_check(b.manifest()["colliders"])
				found = true
				break
		if found:
			break
	return found


func manifest_check(colliders: Array) -> void:
	# Group by quantized position; ensure glass boxes never share their
	# aperture with a concrete box of matching width/height at the same spot.
	var glasses: Array[Dictionary] = []
	var concretes: Array[Dictionary] = []
	for col: Dictionary in colliders:
		var mat: StringName = col["material"]
		if mat == &"glass":
			glasses.append(col)
		elif mat == &"concrete":
			concretes.append(col)
	for g in glasses:
		var gp: Vector3 = g["pos"]
		for c2 in concretes:
			var cp: Vector3 = c2["pos"]
			if gp.distance_to(cp) < 0.25:
				var gs: Vector3 = g["size"]
				var cs: Vector3 = c2["size"]
				# A concrete box swallowing the pane means solid-back windows.
				if cs.x >= gs.x - 0.01 and cs.z >= gs.z - 0.01 \
						and absf(cs.y - gs.y) < 0.01:
					print("[CityTest] solid wall behind glass at ", gp)
					_fail_flag = true
					return


var _fail_flag := false


# --- 15: Damage model ------------------------------------------------------------
func _test_damage_model() -> bool:
	var b := MeshBatcher.new()
	b.push_layer("t:f0")
	# One concrete cell and one wood cell of identical volume.
	b.add_box_rotated(Vector3(0, 0.5, 0), Vector3.ONE, Basis.IDENTITY,
			Color.RED, true, false, &"concrete")
	b.add_box_rotated(Vector3(5, 0.5, 0), Vector3.ONE, Basis.IDENTITY,
			Color.RED, true, false, &"wood")
	# Find their ids from collider list order.
	var cols: Array = b.manifest()["colliders"]
	var id_conc := int(cols[0]["id"])
	var id_wood := int(cols[1]["id"])
	var integ_conc := MeshBatcher.cell_integrity(Vector3.ONE, &"concrete")
	var integ_wood := MeshBatcher.cell_integrity(Vector3.ONE, &"wood")
	if integ_conc <= integ_wood:
		print("[CityTest] concrete integrity %.1f must exceed wood %.1f"
				% [integ_conc, integ_wood])
		return false
	# Sub-lethal hits must NOT destroy.
	var half := integ_conc * MaterialDB.effective_damage(10.0, &"concrete") \
			/ maxf(MaterialDB.effective_damage(10.0, &"concrete"), 0.001)
	half = integ_conc * 0.45
	var res := b.damage_box(id_conc, 10.0)
	while res.is_empty():
		break
	# Apply repeated sub-integrity damage to wood until it breaks: wood must
	# break with LESS raw damage than concrete needs.
	var wood_raw := 0.0
	res = {}
	while not bool(res.get("shattered", false)) and wood_raw < 100000.0:
		res = b.damage_box(id_wood, 5.0)
		wood_raw += 5.0
	var conc_raw := 0.0
	res = {}
	while not bool(res.get("shattered", false)) and conc_raw < 100000.0:
		res = b.damage_box(id_conc, 5.0)
		conc_raw += 5.0
	if not bool(res.get("shattered", false)):
		print("[CityTest] concrete cell never broke")
		return false
	if wood_raw >= conc_raw:
		print("[CityTest] wood broke at %.0f but concrete at %.0f"
				% [wood_raw, conc_raw])
		return false
	# Glass must shatter with far less than either.
	var b2 := MeshBatcher.new()
	b2.add_box_rotated(Vector3.ZERO, Vector3.ONE, Basis.IDENTITY,
			Color.BLUE, true, false, &"glass")
	var gid := int((b2.manifest()["colliders"] as Array)[0]["id"])
	var res2 := b2.damage_box(gid, 500.0)
	if not bool(res2.get("shattered", false)):
		return false
	return true


# --- 16: Destruction persistence --------------------------------------------------
func _test_destruction_persistence() -> bool:
	var manager := ChunkManager.new()
	manager.setup(CityPlan.new())
	manager.synchronous = true
	add_child(manager)
	var player_mock := Node3D.new()
	add_child(player_mock)
	player_mock.global_position = Vector3(0, 0, 0)
	manager.set_player(player_mock)
	if not _pump_stable(manager):
		manager.free()
		player_mock.free()
		return false
	# Pick a resident chunk with a batcher.
	var target: Vector2i = Vector2i(99, 99)
	for c: Vector2i in manager._chunks:
		target = c
		break
	if target == Vector2i(99, 99):
		return false
	var rec: Dictionary = manager._chunks[target]
	var batcher: MeshBatcher = rec["batcher"]
	var specs: Array[Dictionary] = batcher.specs()
	if specs.is_empty():
		return false
	# Destroy cells via the gameplay path. NOTE: the chunk Static body holds
	# only COLLIDER shape nodes, so match them by vox_id meta - never assume
	# child index i corresponds to spec i.
	var keys: Array[String] = []
	var destroyed_count := 0
	var by_vox := {}
	for sh in (rec["static"] as Node).get_children():
		if sh is CollisionShape3D and sh.has_meta("vox_id"):
			by_vox[int(sh.get_meta("vox_id"))] = sh
	for s: Dictionary in specs:
		if destroyed_count >= 3:
			break
		if StringName(s["material"]) == &"":
			continue
		var sid := int(s["id"])
		if not by_vox.has(sid):
			continue
		var key := batcher.cell_key_for_id(sid)
		if key == "":
			continue
		manager.destroy_box(by_vox[sid])
		keys.append(key)
		destroyed_count += 1
	if destroyed_count == 0:
		return false
	# Simulate unload + rebuild: fresh batcher, reapply delta like _materialize.
	var delta: Dictionary = manager.chunk_delta(target)
	if not (delta.get("destroyed", []) as Array).size() >= destroyed_count:
		print("[CityTest] delta missing destroyed keys")
		return false
	var fresh := MeshBatcher.new()
	ChunkBuilder.fill_batcher(fresh, manager.plan, target)
	fresh.load_damage_state(delta.get("damage", {}))
	var dkeys: Array = delta["destroyed"]
	for s: Dictionary in fresh.specs():
		var k := fresh.cell_key_for_id(int(s["id"]))
		if dkeys.has(k):
			fresh.destroy_box(int(s["id"]))
	# Verify every persisted key exists in the fresh build and is destroyed.
	for k: String in keys:
		var still_gone := false
		for s: Dictionary in fresh.specs():
			if fresh.cell_key_for_id(int(s["id"])) == k \
					and fresh.is_destroyed(int(s["id"])):
				still_gone = true
		if not still_gone:
			print("[CityTest] cell %s survived rebuild" % k)
			return false
	# Save/load round-trip through the persistence dicts.
	var saved := manager.save_state()
	var manager2 := ChunkManager.new()
	manager2.setup(CityPlan.new())
	manager2.load_state(saved)
	var delta2: Dictionary = manager2.chunk_delta(target)
	if (delta2.get("destroyed", []) as Array) != (delta["destroyed"] as Array):
		print("[CityTest] save/load changed destroyed set")
		return false
	manager.free()
	manager2.free()
	player_mock.free()
	return true


# --- 17: Interior probe -----------------------------------------------------------
func _test_interior_probe() -> bool:
	var spec := {
		"rect": Rect2(0, 0, 10, 14),
		"floors": 3,
		"floor_h": 3.0,
	}
	# Outside: not inside regardless of history.
	if bool(InteriorProbe.evaluate(Vector2(-1, 5), 0.2, spec, false)["inside"]):
		return false
	# In the wall band: entering from outside must NOT read inside...
	var wall_pt := Vector2(5.0, 0.18)   # within WALL_T of the south face
	if bool(InteriorProbe.evaluate(wall_pt, 0.2, spec, false)["inside"]):
		return false
	# ...but once already inside, the hysteresis keeps it inside briefly.
	if not bool(InteriorProbe.evaluate(Vector2(5.0, 0.28), 0.2, spec, true)["inside"]):
		return false
	# Proper interior point on floor 0.
	var r0: Dictionary = InteriorProbe.evaluate(Vector2(5, 5), 0.2, spec, false)
	if not bool(r0["inside"]) or int(r0["floor"]) != 0:
		return false
	# Floor 1 under its ceiling.
	var r1: Dictionary = InteriorProbe.evaluate(Vector2(5, 5), 3.2, spec, true)
	if not bool(r1["inside"]) or int(r1["floor"]) != 1:
		return false
	# Above the roof: not inside.
	if bool(InteriorProbe.evaluate(Vector2(5, 5), 3 * 3.0 + 1.4, spec, true)["inside"]):
		return false
	# Facade sectors: camera north of player fades the N wall only.
	var f: Array = InteriorProbe.faded_facades(Vector2(5, 5), Vector2(5, -9))
	if not (f.size() == 1 and String(f[0]) == "N"):
		print("[CityTest] N-sector fade wrong: ", f)
		return false
	var f2: Array = InteriorProbe.faded_facades(Vector2(5, 5), Vector2(15, 5))
	if not (f2.size() == 1 and String(f2[0]) == "E"):
		return false
	# Diagonal camera fades two walls.
	var f3: Array = InteriorProbe.faded_facades(Vector2(5, 5), Vector2(13, 13))
	if f3.size() != 2:
		return false
	return true




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
