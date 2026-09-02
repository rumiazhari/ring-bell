extends Node
## Universal Building Contract harness -- --buildingcontracttest (G10-P2A).
##
##   godot --headless --path . -- --buildingcontracttest
##
## Sections:
##   1. Malformed-spec matrix    — intentionally invalid specs/builds are
##                                 rejected by BuildingContractValidator.
##   2. Bypass detection         — colliding geometry outside the universal
##                                 assembler is flagged; a FULL building
##                                 built without registration is rejected.
##   3. City conformance         — real CityPlan chunks: every FULL spec
##                                 validates, every building is registered,
##                                 every build passes aperture/slab/roof/
##                                 stairs/grounding rules. No regression in
##                                 city construction.
##   4. Rural conformance        — real WorldPlan contract houses assemble
##                                 through the universal grammar and pass
##                                 the rural build rules + budget caps.
##   5. Rural tamper matrix      — solid geometry in the doorway, missing
##                                 evidence, door off the footprint.
##
## Judge by the "finished with 0 failure(s)" marker.

var failures := 0
const Art = preload("res://art/universal_building_art.gd")
const RuralArt = preload("res://art/rural_art.gd")


func _ready() -> void:
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[BuildingContractTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run_all()
	print("[BuildingContractTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[BuildingContractTest] PASS: %s" % label)
	else:
		failures += 1
		print("[BuildingContractTest] FAIL: %s -- %s" % [label, detail])


func _any_err(errs: Array, needle: String) -> bool:
	for e: String in errs:
		if e.contains(needle):
			return true
	return false


func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	# ---------- 1. Malformed spec matrix ------------------------------------
	print("[BuildingContractTest] --- section 1: malformed spec matrix")
	# 1a. missing id
	_check("spec without id rejected",
			not BuildingContractValidator.validate_spec(
					{"rect": Rect2(0, 0, 10, 10)}).is_empty())
	# 1b. bad quality
	_check("invalid quality rejected",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_badq", "rect": Rect2(0, 0, 10, 10),
				"quality": &"SHELL", "archetype": &"house",
			}), "invalid quality"))
	# 1c. unknown archetype
	_check("unknown archetype rejected",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_bada", "rect": Rect2(0, 0, 10, 10),
				"quality": &"FULL_BUILDING", "archetype": &"zombie_hut",
			}), "unknown archetype"))
	# 1d. house may NOT be PROP_STRUCTURE (no silent downgrade)
	_check("house-as-PROP rejected (anti-trash classification)",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_house_prop", "rect": Rect2(0, 0, 10, 10),
				"quality": &"PROP_STRUCTURE", "archetype": &"house",
			}), "invalid classification"))
	_check("shed-as-PROP accepted",
			BuildingContractValidator.validate_spec({
				"id": "t_shed_prop", "rect": Rect2(0, 0, 3, 3),
				"quality": &"PROP_STRUCTURE", "archetype": &"shed",
			}).is_empty())
	# 1e. DISTANT_LOD without lod_of
	_check("DISTANT_LOD without lod_of rejected",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_lod", "rect": Rect2(0, 0, 10, 10),
				"quality": &"DISTANT_LOD", "archetype": &"house",
			}), "lod_of"))
	# 1f. tiny footprint
	_check("tiny footprint rejected",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_tiny", "rect": Rect2(0, 0, 1.2, 1.2),
				"quality": &"FULL_BUILDING", "archetype": &"house",
				"floors": 1, "floor_h": 3.0,
			}), "footprint"))
	# 1g. bad floor height
	_check("floor_h out of band rejected",
			_any_err(BuildingContractValidator.validate_spec({
				"id": "t_fh", "rect": Rect2(0, 0, 10, 10),
				"quality": &"FULL_BUILDING", "archetype": &"house",
				"floors": 2, "floor_h": 9.0,
				"circulation": {"kind": &"stairs"},
				"style": {"room_type": "residential"}, "use": "residential",
			}), "floor_h"))
	# 1h. missing entrance (no doors, no door_edge manifest position)
	var no_door_spec := {
		"id": "t_nodoor", "rect": Rect2(0, 0, 10, 10),
		"quality": &"FULL_BUILDING", "archetype": &"house",
		"floors": 1, "floor_h": 3.0, "use": "residential",
		"style": {"room_type": "residential"},
	}
	_check("missing entrance rejected",
			_any_err(BuildingContractValidator.validate_spec(no_door_spec), "missing entrance"))
	# 1i. unreachable upper floors: floors>=2 without circulation
	var no_circ := no_door_spec.duplicate(true)
	no_circ["id"] = "t_nocirc"
	no_circ["floors"] = 3
	no_circ["doors"] = [{"id": "d", "position": Vector3(5, 0, 0), "width": 1.5, "height": 2.25}]
	no_circ["circulation"] = {"kind": &"none"}
	_check("upper floors without circulation rejected",
			_any_err(BuildingContractValidator.validate_spec(no_circ), "unreachable upper floors"))
	# 1j. stairs declared but cannot fit the footprint
	var stairs_nofit := no_door_spec.duplicate(true)
	stairs_nofit["id"] = "t_stairsfit"
	stairs_nofit["rect"] = Rect2(0, 0, 10, 7)
	stairs_nofit["floors"] = 4
	stairs_nofit["floor_h"] = 3.2
	stairs_nofit["doors"] = [{"id": "d", "position": Vector3(5, 0, 0), "width": 1.5, "height": 2.25}]
	stairs_nofit["circulation"] = {"kind": &"stairs"}
	_check("stairs that do not fit rejected",
			_any_err(BuildingContractValidator.validate_spec(stairs_nofit), "stairs do not fit"))
	# 1k/1l. overlapping + disconnected rooms (tamper the InteriorPlan manifest)
	var ip = load("res://world/generation/interior_plan.gd")
	var good_spec := {
		"id": "b_overlap", "rect": Rect2(0, 0, 12, 12),
		"floors": 2, "floor_h": 3.0, "use": "residential",
		"style": {"room_type": "residential"},
		"district": "inner_city", "door_edge": 0,
		"circulation": {"kind": &"stairs"},
		"doors": [{"id": "d", "position": Vector3(6, 0, 0), "width": 1.5, "height": 2.25}],
	}
	var ivalid: Dictionary = ip.build_for_building(good_spec)
	var fl0: Dictionary = ivalid["floors"][0]
	var rooms: Array = fl0["rooms"]
	if rooms.size() >= 2:
		var r0: Rect2 = rooms[0]["rect"]
		var r1: Rect2 = rooms[1]["rect"]
		# overlap by shifting the second room onto the first
		rooms[1]["rect"] = Rect2(r0.position + (r1.position - r0.position) * 0.5, r1.size)
		_check("overlapping rooms rejected",
				_any_err(BuildingContractValidator.validate_interior_manifest(ivalid), "overlap"))
	else:
		_check("overlapping rooms rejected", true, "fixture too small")
	fl0["partitions"] = []
	fl0["doors"] = []
	_check("disconnected rooms rejected",
			_any_err(BuildingContractValidator.validate_interior_manifest(ivalid), "disconnected"))
	# 1m. grounding violation (floating house)
	var float_spec := no_door_spec.duplicate(true)
	float_spec["id"] = "t_float"
	float_spec["ground_y"] = 12.0
	_check("floating building rejected via surface authority",
			_any_err(BuildingContractValidator.validate_spec(float_spec,
					func(_p: Vector2) -> float: return 0.0), "grounding"))
	# 1n. rural: door off the footprint edge
	var rural_bad := {
		"id": "r_baddoor", "kind": &"cottage", "archetype": &"cottage",
		"quality": &"FULL_BUILDING", "floors": 1, "floor_h": 4.2,
		"center": Vector2(100, 100), "footprint": Vector2(8, 10),
		"yaw": 0.0, "door_pos": Vector2(140, 100), "door_yaw": 0.0,
		"height": 4.2, "ground": 25.0, "ground_y": 25.0,
		"interior": {"walls": [], "furniture": []},
		"circulation": {"kind": &"none"}, "roof_family": &"gabled",
	}
	_check("rural door off footprint rejected",
			_any_err(BuildingContractValidator.validate_spec(rural_bad), "not on footprint edge"))

	print("[BuildingContractTest] --- section 2: bypass detection")
	# 2a. unregistered structural geometry flagged
	var rogue := MeshBatcher.new()
	rogue.add_structural_box(Vector3(0, 1.5, 0), Vector3(10, 3, 0.35), Color.WHITE)
	rogue.push_layer("rogue_building:f0")
	rogue.add_structural_box(Vector3(0, 8, 0), Vector3(10, 3, 0.35), Color.WHITE)
	rogue.pop_layer()
	_check("unregistered structural layer flagged",
			not BuildingContractValidator.unregistered_structural(rogue, ["real_b1"]).is_empty())
	_check("registered building not flagged",
			BuildingContractValidator.unregistered_structural(rogue, ["rogue_building"]).is_empty())
	# 2b. FULL building geometry built OUTSIDE the assembler is rejected
	var bypass := MeshBatcher.new()
	var real_city_spec := {
		"id": "b_bypass", "rect": Rect2(0, 0, 10, 12),
		"floors": 2, "floor_h": 3.0, "use": "residential",
		"style": {"room_type": "residential", "attic": false, "wall": 1, "roof": 2},
		"district": "inner_city", "door_edge": 0, "plaza_adjacent": false,
		"circulation": {"kind": &"stairs"},
		"doors": [{"id": "d", "position": Vector3(5, 0, 0), "width": 1.5, "height": 2.25}],
	}
	# built directly through the reference builder (simulated subsystem bypass)
	BuildingBuilder.build(bypass, real_city_spec)
	var bypass_errs: Array[String] = BuildingContractValidator.validate_build(real_city_spec, bypass)
	_check("FULL building not registered rejected (assembler bypass)",
			_any_err(bypass_errs, "bypassed the universal assembler"))
	# 2c. the same spec via the universal assembler passes registration
	var legit := MeshBatcher.new()
	UniversalBuildingAssembler.build_into(legit, real_city_spec.duplicate(true))
	_check("assembler-registered building accepted",
			BuildingContractValidator.validate_build(real_city_spec, legit).is_empty(),
			str(BuildingContractValidator.validate_build(real_city_spec, legit)))

	print("[BuildingContractTest] --- section 3: city conformance")
	var wp := WorldPlan.new(canonical)
	var city := CityPlan.new()
	var chunk_coords: Array[Vector2i] = []
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			chunk_coords.append(Vector2i(cx, cz))
	var city_specs := 0
	var city_ok := 0
	var registered_all := true
	for coord in chunk_coords:
		var rect := WorldSeed.chunk_rect(coord)
		var b := MeshBatcher.new()
		ChunkBuilder.fill_batcher(b, city, coord)
		var expected: Array = []
		var expected_ids: Array[String] = []
		for spec in city.buildings_in_rect(rect):
			var center: Vector2 = (spec["rect"] as Rect2).get_center()
			if WorldSeed.chunk_coord(center.x, center.y) == coord:
				expected.append(spec)
				expected_ids.append(str(spec["id"]))
		var registered: Array[String] = b.contract_building_ids()
		for eid in expected_ids:
			if not registered.has(eid):
				registered_all = false
				_check("chunk %s registered city id %s" % [coord, eid], false)
				break
		for spec in expected:
			city_specs += 1
			var serrs: Array[String] = BuildingContractValidator.validate_spec(spec, func(p: Vector2) -> float:
				return wp.surface_height_at(p))
			if not serrs.is_empty():
				_check("city spec %s valid" % str(spec["id"]), false, str(serrs))
				continue
			var verrs: Array[String] = BuildingContractValidator.validate_build(spec, b)
			if verrs.is_empty():
				city_ok += 1
			else:
				_check("city build %s passes contract" % str(spec["id"]), false, str(verrs))
		var rogue_errs: Array[String] = BuildingContractValidator.unregistered_structural(b, b.contract_building_ids())
		if not rogue_errs.is_empty():
			_check("chunk %s has no unregistered structural" % coord, false, str(rogue_errs))
	_check("city chunks produced expected buildings", city_specs > 20, str(city_specs))
	_check("all expected city ids registered", registered_all)
	_check("all city builds pass contract", city_ok == city_specs, "%d/%d" % [city_ok, city_specs])
	print("[BuildingContractTest] city specs validated: %d, passing: %d" % [city_specs, city_ok])

	print("[BuildingContractTest] --- section 4: rural conformance")
	var rural: RuralBuildingPlan = wp.rural_building
	var all_buildings: Array[Dictionary] = rural.rural_buildings()
	var contract_houses: Array[Dictionary] = []
	for b in all_buildings:
		if RuralBuildingPlan.is_contract_house(b):
			contract_houses.append(b)
	_check("contract houses exist in the world", contract_houses.size() > 0, str(contract_houses.size()))
	var sampled: int = mini(8, contract_houses.size())
	var rural_ok := 0
	var budget_ok := true
	var checked_chunks: Dictionary = {}
	for i in sampled:
		var b: Dictionary = contract_houses[i]
		var b2 := b.duplicate(true)
		var b_center: Vector2 = b2["center"] as Vector2
		b2["ground_y"] = wp.surface_height_at(b_center) + WorldConstants.RURAL_OVERLAY_LIFT_M
		var serrs: Array[String] = BuildingContractValidator.validate_spec(
				BuildingSpec.contractualize(b2),
				func(p: Vector2) -> float: return wp.surface_height_at(p) \
						+ WorldConstants.RURAL_OVERLAY_LIFT_M)
		if not serrs.is_empty():
			_check("rural spec %s valid" % str(b["id"]), false, str(serrs))
			continue
		var coord2 := WorldSeed.chunk_coord((b["center"] as Vector2).x, (b["center"] as Vector2).y)
		var m: Dictionary = RuralBuildingChunkBuilder.build_manifest(wp, coord2)
		var ev: Dictionary = {}
		for e2 in m.get("contract_buildings", []):
			if String((e2 as Dictionary).get("id", "")) == String(b["id"]):
				ev = e2 as Dictionary
				break
		_check("manifest contains evidence for %s" % String(b["id"]), not ev.is_empty(),
				"contract_buildings=%d" % (m.get("contract_buildings", []) as Array).size())
		if ev.is_empty():
			continue
		var verrs: Array[String] = BuildingContractValidator.validate_rural_build(
				b, ev, m.get("collider_verts", PackedVector3Array()) as PackedVector3Array)
		if verrs.is_empty():
			rural_ok += 1
		else:
			_check("rural build %s passes contract" % String(b["id"]), false, str(verrs))
		if not checked_chunks.has(coord2):
			checked_chunks[coord2] = true
			var v: int = int(m.get("rural_vertices", 0))
			var t: int = int(m.get("rural_triangles", 0))
			if v > WorldConstants.MAX_RURAL_VERTS_PER_CHUNK or t > WorldConstants.MAX_RURAL_TRIS_PER_CHUNK:
				budget_ok = false
				_check("chunk %s within rural budget" % coord2, false, "%d/%d" % [v, t])
	# determinism: same seed -> identical evidence
	var d_b: Dictionary = contract_houses[0] if contract_houses.size() > 0 else {}
	if not d_b.is_empty():
		var c1 := WorldSeed.chunk_coord((d_b["center"] as Vector2).x, (d_b["center"] as Vector2).y)
		var m1: Dictionary = RuralBuildingChunkBuilder.build_manifest(wp, c1)
		var m2: Dictionary = RuralBuildingChunkBuilder.build_manifest(wp, c1)
		var ids1 := (m1.get("contract_buildings", []) as Array).map(func(e: Dictionary) -> String:
			return String(e.get("id", "")))
		var ids2 := (m2.get("contract_buildings", []) as Array).map(func(e: Dictionary) -> String:
			return String(e.get("id", "")))
		_check("rural manifest deterministic (contract ids)",
				str(ids1) == str(ids2), "%s vs %s" % [ids1, ids2])
	_check("sampled rural builds pass contract", rural_ok == sampled, "%d/%d" % [rural_ok, sampled])
	_check("rural chunk budgets hold with contract houses", budget_ok)

	print("[BuildingContractTest] --- section 5: rural tamper matrix")
	if not d_b.is_empty():
		var c3 := WorldSeed.chunk_coord((d_b["center"] as Vector2).x, (d_b["center"] as Vector2).y)
		var m3: Dictionary = RuralBuildingChunkBuilder.build_manifest(wp, c3)
		var ev3: Dictionary = {}
		var b3: Dictionary = {}
		for e3 in m3.get("contract_buildings", []):
			ev3 = e3 as Dictionary
			# find source dict
			for bb in m3.get("rural_buildings", []):
				if String((bb as Dictionary).get("id", "")) == String(ev3.get("id", "")):
					b3 = bb as Dictionary
					break
			break
		if not ev3.is_empty():
			# 5a. evidence not assembled -> rejected
			var ev_fake: Dictionary = ev3.duplicate(true)
			ev_fake["assembled"] = false
			_check("missing assembler evidence rejected",
					not BuildingContractValidator.validate_rural_build(b3, ev_fake,
							m3.get("collider_verts", PackedVector3Array()) as PackedVector3Array).is_empty())
			# 5b. solid collider geometry inside the door aperture -> rejected
			var cv: PackedVector3Array = (m3.get("collider_verts", PackedVector3Array()) as PackedVector3Array).duplicate()
			var ci: PackedInt32Array = (m3.get("collider_indices", PackedInt32Array()) as PackedInt32Array).duplicate()
			var door_pos: Vector2 = b3.get("door_pos", Vector2.ZERO) as Vector2
			var base: int = cv.size()
			for corner in [
				Vector3(door_pos.x - 0.3, (ev3.get("ground", 0.0) as float) + 0.3, door_pos.y - 0.3),
				Vector3(door_pos.x + 0.3, (ev3.get("ground", 0.0) as float) + 0.3, door_pos.y - 0.3),
				Vector3(door_pos.x + 0.3, (ev3.get("ground", 0.0) as float) + 1.8, door_pos.y + 0.3),
				Vector3(door_pos.x - 0.3, (ev3.get("ground", 0.0) as float) + 1.8, door_pos.y + 0.3),
				Vector3(door_pos.x - 0.3, (ev3.get("ground", 0.0) as float) + 0.3, door_pos.y + 0.3),
				Vector3(door_pos.x + 0.3, (ev3.get("ground", 0.0) as float) + 0.3, door_pos.y + 0.3),
				Vector3(door_pos.x + 0.3, (ev3.get("ground", 0.0) as float) + 1.8, door_pos.y - 0.3),
				Vector3(door_pos.x - 0.3, (ev3.get("ground", 0.0) as float) + 1.8, door_pos.y - 0.3),
			]:
				cv.append(corner)
			var ci_faces: Array[Array] = [[0,1,2,3],[4,7,6,5],[0,4,5,1],[2,6,7,3],[1,5,6,2],[3,7,4,0]]
			for face in ci_faces:
				for idx in face:
					ci.append(base + int(idx))
			_check("solid geometry behind rural door rejected",
					_any_err(BuildingContractValidator.validate_rural_build(b3, ev3, cv), "door aperture"))
		else:
			_check("rural tamper fixtures found", false, "no contract house in chunk")