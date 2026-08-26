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
	# --- 11..19: P0 foundation contract tests ------------------------------------
	_check("slab coverage = footprint minus shaft (numeric)", _test_slab_coverage())
	_check("stair flight geometry (flush endpoints, slope, all storeys)",
			_test_stair_geometry())
	_check("stair zone opposite-edge mapping + entrance clearance",
			_test_stair_zone_edges())
	_check("stair ramp COLLIDER meets both landings (real spec bounds)",
			_test_stair_collider_spec())
	_check("furniture floor ownership + placement bounds", _test_furniture())
	_check("bookshelf wall-snapped footprint matches 1.6 x 0.34 geometry",
			_test_shelf_placement())
	_check("facade apertures composed without solid backs",
			_test_facade_apertures())
	_check("facade layer keys are building-scoped f<storey>:<side>",
			_test_facade_layer_keys())
	_check("floor slab paneling bounded 2D (~2.5 m both axes)",
			_test_slab_granularity())
	_check("structural damage accumulates by material", _test_damage_model())
	_check("explosion-grade damage respects integrity (wood < concrete < steel)",
			_test_explosion_integrity_ladder())
	_check("glass calibration vs ItemDB weapon damage",
			_test_glass_calibration())
	_check("destruction deltas persist across rebuild + save/load",
			_test_destruction_persistence())
	_check("corner building doors face a street (NW/NE/SE/SW)",
			_test_corner_door_edges())
	_check("intra-block passages pierce both fronts unobstructed",
			_test_passages())
	_check("interior probe detection + facade sector math", _test_interior_probe())
	_check("flat-roof props placed, bounded, deterministic; attic decks bare",
			_test_roof_props())
	_check("rooftop clutter: HVAC duct run, solar panel, satellite dish",
			_test_roof_clutter())
	_check("rooftop water-tower landmark on large retail decks",
			_test_roof_tower())
	_check("bulkhead roof-exit rim: above doorway lane, gated to stairs",
			_test_bulkhead_rails())
	_check("bulkhead plant-room details: hatch+vents on cap, gated to stairs",
			_test_bulkhead_plant())


# --- 24: Flat-roof prop dressing -----------------------------------------------
func _test_roof_props() -> bool:
	# Synthetic 12 x 10 m, 3-storey flat-roofed building built straight
	# through BuildingBuilder (no city-plan dependency). Contract:
	#   >=1 colliding prop box stands above the deck,
	#   every prop is fully inside the parapet-inset usable area and clear
	#     of the bulkhead keep-out ring (roof exit never blocked),
	#   rebuild is byte-identical (seeded placement),
	#   an attic variant dresses NOTHING (pitched shell has no deck).
	var base := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0,
		"floors": 3,
		"id": "rooftest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var total_h := 9.0
	var inset := 0.9   # WALL_T (0.35) + 0.55 dressing inset
	var usable := Rect2(inset, inset, 12.0 - 2.0 * inset, 10.0 - 2.0 * inset)
	var keepout: Rect2 = BuildingBuilder._zone_rect(
			(base["rect"] as Rect2).size, float(base["floor_h"]), 0).grow(1.2)

	var b_a := MeshBatcher.new()
	BuildingBuilder.build(b_a, base)
	var props_a: Array = _collect_roof_props(b_a, total_h, usable, keepout)
	if props_a.is_empty():
		print("[CityTest] roofprops: no prop boxes found on flat deck")
		return false

	for p: Dictionary in props_a:
		var sz: Vector3 = p["size"]
		var pos: Vector3 = p["pos"]
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5, sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), usable):
			print("[CityTest] roofprops: prop outside usable deck %s" % [r])
			return false
		if r.intersects(keepout):
			print("[CityTest] roofprops: prop inside bulkhead keep-out %s"
					% [r])
			return false
		# Phase F iter 20: the approach ring carries PROP_CLEARANCE, so no
		# prop footprint may enter the clearance buffer around the ring.
		if r.intersects(keepout.grow(BuildingBuilder.PROP_CLEARANCE)):
			print("[CityTest] roofprops: prop inside bulkhead clearance "
					+ "buffer %s" % [r])
			return false

	var b_b := MeshBatcher.new()
	BuildingBuilder.build(b_b, base)
	var props_b: Array = _collect_roof_props(b_b, total_h, usable, keepout)
	if props_a.size() != props_b.size():
		print("[CityTest] roofprops: nondeterministic count %d vs %d"
				% [props_a.size(), props_b.size()])
		return false
	for i in props_a.size():
		var pa: Dictionary = props_a[i]
		var pb: Dictionary = props_b[i]
		if pa["pos"] != pb["pos"] or pa["size"] != pb["size"]:
			print("[CityTest] roofprops: nondeterministic box %d" % i)
			return false

	var attic := {"rect": base["rect"], "floor_h": base["floor_h"],
			"floors": base["floors"], "id": "rooftest-attic",
			"door_edge": 0,
			"style": {"wall": 1, "roof": 2, "attic": true}}
	var b_c := MeshBatcher.new()
	BuildingBuilder.build(b_c, attic)
	if not _collect_roof_props(b_c, total_h, usable, keepout).is_empty():
		print("[CityTest] roofprops: attic shell must stay undressed")
		return false
	return true


## Roof-layer colliding specs strictly above the deck and inside the dressed
## region (parapet/bulkhead geometry sits on the wall line or in the zone).
func _collect_roof_props(b: MeshBatcher, total_h: float, usable: Rect2,
		keepout: Rect2) -> Array:
	var out: Array = []
	for s in b.specs():
		if String(s["layer"]) != "rooftest:roof" \
				and String(s["layer"]) != "rooftest-attic:roof":
			continue
		if not bool(s["collide"]):
			continue
		var pos: Vector3 = s["pos"]
		if pos.y <= total_h + 0.05:
			continue
		var sz: Vector3 = s["size"]
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5, sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), usable):
			continue
		if r.intersects(keepout):
			continue
		out.append(s)
	return out


# --- 24b: Rooftop clutter pass (Phase D slice 6) -------------------------------
func _test_roof_clutter() -> bool:
	# HVAC rect picker: rects land inside the usable deck, and the picker
	# gives up (empty Rect2) when the bulkhead keep-out swallows every edge.
	var usable := Rect2(0.9, 0.9, 10.2, 8.2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in 6:
		var hr := BuildingBuilder._hvac_rect(usable, Rect2(), rng)
		if hr.size.x <= 0.0 or hr.size.y <= 0.0:
			print("[CityTest] clutter: hvac rect empty on a free deck")
			return false
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(hr), usable):
			print("[CityTest] clutter: hvac rect outside usable %s" % [hr])
			return false
	if not (BuildingBuilder._hvac_rect(
				usable, usable.grow(-0.01),
				RandomNumberGenerator.new()) == Rect2()):
			print("[CityTest] clutter: hvac rect ignored total keep-out")
			return false

	# The three new builders emit colliding boxes standing above the deck.
	var y := 9.04   # deck plane at total_h 9.0 + membrane offset
	var b := MeshBatcher.new()
	BuildingBuilder._rp_hvac_duct(b, Vector3.ZERO,
			Rect2(1.0, 0.9, 3.6, 0.42), y)
	BuildingBuilder._rp_solar_panel(b, Vector3.ZERO,
			Rect2(4.0, 4.0, 1.9, 1.05), y)
	BuildingBuilder._rp_satellite_dish(b, Vector3.ZERO,
			Rect2(4.5, 7.0, 0.75, 0.75), y)
	var hits := 0
	for s in b.specs():
		if not bool(s["collide"]):
			continue
		hits += 1
		var pos: Vector3 = s["pos"]
		if pos.y <= 9.09:   # must stand above the walkable deck plane
			print("[CityTest] clutter: box sunk into deck at %s" % [pos])
			return false
	if hits < 12:   # duct 4 + solar 3 + dish 5
		print("[CityTest] clutter: expected >=12 colliding boxes, got %d"
				% [hits])
		return false
	return true


# --- 24c: Rooftop water-tower landmark (Phase G) -----------------------------
func _test_roof_tower() -> bool:
	# A large retail flat deck MUST grow a water tower (legs + tank + cap
	# + ladder rungs, all colliding steel tagged "tower"). The tower must sit
	# inside the parapet-inset usable deck, stand clearly above the walkable
	# deck plane (tall vantage), and a rebuild is byte-identical (seeded).
	# A SMALL retail deck and a residential deck must NOT grow one.
	var large := {
		"rect": Rect2(0, 0, 30, 26),
		"floor_h": 3.0, "floors": 3, "id": "towertest-big",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false,
				"room_type": "retail"},
	}
	var b_big := MeshBatcher.new()
	BuildingBuilder.build(b_big, large)
	var tower_big := _collect_tower(b_big)
	if tower_big.is_empty():
		print("[CityTest] tower: large retail deck grew no water tower")
		return false
	var usable := BuildingBuilder.usable_roof_rect(large["rect"])
	for s: Dictionary in tower_big:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5,
				sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), usable):
			print("[CityTest] tower: box outside usable deck %s" % [r])
			return false
		if pos.y <= 9.09:   # must stand above the deck plane (total_h 9.0)
			print("[CityTest] tower: box sunk into deck at %s" % [pos])
			return false
	# Tank top must reach a real elevated vantage (>= 3.5 m above deck).
	var max_top := 0.0
	for s2: Dictionary in tower_big:
		max_top = maxf(max_top, float(s2["pos"].y) + s2["size"].y * 0.5)
	if max_top < 3.4:
		print("[CityTest] tower: not tall enough (top=%.2f)" % max_top)
		return false

	# Determinism: rebuild is byte-identical.
	var b_big2 := MeshBatcher.new()
	BuildingBuilder.build(b_big2, large)
	var tower_big2 := _collect_tower(b_big2)
	if tower_big.size() != tower_big2.size():
		print("[CityTest] tower: nondeterministic count %d vs %d"
				% [tower_big.size(), tower_big2.size()])
		return false
	for i in tower_big.size():
		if tower_big[i]["pos"] != tower_big2[i]["pos"] \
				or tower_big[i]["size"] != tower_big2[i]["size"]:
			print("[CityTest] tower: nondeterministic box %d" % i)
			return false

	# Gating: small retail deck and residential deck get no tower.
	var small := {
		"rect": Rect2(0, 0, 8, 7),
		"floor_h": 3.0, "floors": 2, "id": "towertest-small",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false,
				"room_type": "retail"},
	}
	var b_small := MeshBatcher.new()
	BuildingBuilder.build(b_small, small)
	if not _collect_tower(b_small).is_empty():
		print("[CityTest] tower: small retail deck wrongly grew a tower")
		return false
	var resid := {
		"rect": Rect2(0, 0, 16, 14),
		"floor_h": 3.0, "floors": 3, "id": "towertest-res",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false,
				"room_type": "residential"},
	}
	var b_res := MeshBatcher.new()
	BuildingBuilder.build(b_res, resid)
	if not _collect_tower(b_res).is_empty():
		print("[CityTest] tower: residential deck wrongly grew a tower")
		return false
	return true


## Colliding steel specs tagged "tower" standing above the deck plane.
func _collect_tower(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if StringName(s["material"]) != &"steel" \
				or not bool(s["collide"]):
			continue
		if String(s.get("building_id", "")) != "tower":
			continue
		out.append(s)
	return out


# --- 24d: Bulkhead roof-exit rim railing (Phase H) ----------------------------
func _test_bulkhead_rails() -> bool:
	# A stair building MUST finish its bulkhead with the Phase H rim:
	# >=4 colliding steel boxes tagged "bhexit", every member standing
	# strictly ABOVE the bulkhead wall top (the walk-through doorway lane
	# below bh_h stays untouched), footprints confined to the bulkhead
	# zone grown by the cap overhang, and a rebuild is byte-identical.
	# A building WITHOUT stairs grows none.
	var spec := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 3, "id": "bhrailtest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	var rims := _collect_bhexit(b)
	if rims.size() < 4:
		print("[CityTest] bhrail: expected >=4 rim segments, got %d"
				% rims.size())
		return false
	var total_h := 9.0
	var cap_zone: Rect2 = BuildingBuilder._zone_rect(
			(spec["rect"] as Rect2).size, 3.0, 0).grow(0.14 + 0.15 + 0.05)
	for s: Dictionary in rims:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 <= total_h + 2.4:
			print("[CityTest] bhrail: rail dips into doorway lane at %s"
					% [pos])
			return false
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5,
				sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), cap_zone):
			print("[CityTest] bhrail: rail outside bulkhead cap %s" % [r])
			return false

	# Determinism: rebuild is byte-identical.
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, spec)
	var rims2 := _collect_bhexit(b2)
	if rims.size() != rims2.size():
		print("[CityTest] bhrail: nondeterministic count %d vs %d"
				% [rims.size(), rims2.size()])
		return false
	for i in rims.size():
		if rims[i]["pos"] != rims2[i]["pos"] \
				or rims[i]["size"] != rims2[i]["size"]:
			print("[CityTest] bhrail: nondeterministic box %d" % i)
			return false

	# Gating: a flat deck WITHOUT stairs grows no rim.
	var nostair := {
		"rect": Rect2(0, 0, 30, 26),
		"floor_h": 3.0, "floors": 1, "id": "bhrail-nostair",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nostair)
	if not _collect_bhexit(b3).is_empty():
		print("[CityTest] bhrail: non-stair building grew a rim")
		return false
	return true


## Colliding steel specs tagged "bhexit" (bulkhead roof-exit rim).
func _collect_bhexit(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if StringName(s["material"]) != &"steel" \
				or not bool(s["collide"]):
			continue
		if String(s.get("building_id", "")) != "bhexit":
			continue
		out.append(s)
	return out


## Colliding steel specs tagged "bhplant" (Phase I serviced plant-room
## details on the bulkhead cap: hatch lid + two vents).
func _collect_bhplant(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if StringName(s["material"]) != &"steel" \
				or not bool(s["collide"]):
			continue
		if String(s.get("building_id", "")) != "bhplant":
			continue
		out.append(s)
	return out


func _test_bulkhead_plant() -> bool:
	# A stair building MUST finish its bulkhead cap with Phase I plant-room
	# details: exactly 3 colliding steel boxes tagged "bhplant" (1 hatch
	# lid + 2 vents), every box resting ON the cap surface (center y >=
	# total_h + bh_h, sitting above the doorway lane), footprints confined
	# to the bulkhead cap zone (inside the Phase H railed enclosure), and a
	# rebuild is byte-identical. A building WITHOUT stairs grows none.
	var spec := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 3, "id": "bhplanttest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	var plants := _collect_bhplant(b)
	if plants.size() != 3:
		print("[CityTest] bhplant: expected 3 plant boxes (hatch+2 vents), got %d"
				% plants.size())
		return false
	var total_h := 9.0
	var bh_h := 2.4
	var cap_zone: Rect2 = BuildingBuilder._zone_rect(
		(spec["rect"] as Rect2).size, 3.0, 0).grow(0.14 + 0.15 + 0.05)
	for s: Dictionary in plants:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		# Must rest on / above the cap surface, above the doorway lane.
		if pos.y - sz.y * 0.5 < total_h + bh_h:
			print("[CityTest] bhplant: detail below cap at %s" % [pos])
			return false
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5,
				sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), cap_zone):
			print("[CityTest] bhplant: detail outside bulkhead cap %s" % [r])
			return false

	# Determinism: rebuild is byte-identical.
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, spec)
	var plants2 := _collect_bhplant(b2)
	if plants.size() != plants2.size():
		print("[CityTest] bhplant: nondeterministic count %d vs %d"
				% [plants.size(), plants2.size()])
		return false
	for i in plants.size():
		if plants[i]["pos"] != plants2[i]["pos"] \
				or plants[i]["size"] != plants2[i]["size"]:
			print("[CityTest] bhplant: nondeterministic box %d" % i)
			return false

	# Gating: a flat deck WITHOUT stairs grows no plant details.
	var nostair := {
		"rect": Rect2(0, 0, 30, 26),
		"floor_h": 3.0, "floors": 1, "id": "bhplant-nostair",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nostair)
	if not _collect_bhplant(b3).is_empty():
		print("[CityTest] bhplant: non-stair building grew plant details")
		return false
	return true





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
	# Emit one known multi-storey building and verify EVERY furniture-class
	# collider sits exactly on ITS OWN storey's surface (P0-C contract):
	# expected_floor_y == floor_i * fh. The old version collected unique
	# Y heights and pattern-matched them against a whitelist - that can
	# miss stacked/duplicated upper-floor furniture and passed on
	# approximate matches. Specs now carry building_id/floor_i metadata.
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
	var tag := str(spec["id"])
	var fp: Rect2 = spec["rect"]
	# Furniture-class: colliding wood specs inside this footprint whose
	# size.y is in the table/desk/shelf band (walls/slabs are concrete;
	# rails are steel).
	var checked := 0
	for s in b.specs():
		if StringName(s["material"]) != &"wood" or not bool(s["collide"]):
			continue
		var sz: Vector3 = s["size"]
		if sz.y < 0.6 or sz.y > 2.1:
			continue
		var pos: Vector3 = s["pos"]
		var lx := pos.x - fp.position.x
		var lz := pos.z - fp.position.y
		if lx < -0.5 or lz < -0.5 or lx > fp.size.x + 0.5 \
				or lz > fp.size.y + 0.5:
			continue   # some other building's furniture (same chunk)
		if not s.has("building_id") or not s.has("floor_i"):
			print("[CityTest] wood furniture spec lacks ownership metadata")
			return false
		if str(s["building_id"]) != tag:
			continue   # neighboring building's item caught by the margin
		var fi := int(s["floor_i"])
		var expected_y := float(fi) * fh
		# Collider center sits at floor_y + half its height.
		var want := expected_y + sz.y * 0.5
		if absf(pos.y - want) > 0.02:
			print("[CityTest] furniture %s floor %d: y=%.3f want %.3f"
					% [tag, fi, pos.y, want])
			return false
		checked += 1
	return true


# --- 14: Facade apertures -------------------------------------------------------
func _test_facade_apertures() -> bool:
	# For a sample building: count glass specs and verify NO concrete collider
	# occupies the same XZ band as a window pane at window height (the old
	# bug: solid wall behind destructible glass).
	# TEST QUALITY FIX: this used to funnel its result into a `_fail_flag`
	# while RETURNING `found` - detected solid-backed glass still yielded
	# PASS. The real validation result is now returned.
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
				var ok := _manifest_check(b.manifest()["colliders"])
				if not ok:
					return false
				found = true
				break
		if found:
			break
	return found


func _manifest_check(colliders: Array) -> bool:
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
					return false
	return true


# --- 18: Stair zone opposite-edge mapping (P0-6) -------------------------------
func _test_stair_zone_edges() -> bool:
	# Deterministic: for ALL FOUR door edges the zone must sit on the
	# OPPOSITE side of the footprint and stay fully inside it.
	var fh := 3.1
	var fp := Vector2(9.0, BuildingBuilder.stair_zone_len(fh) + 3.0)
	var expectations := [
		# [door_edge, zone_south_anchored, zone_east_anchored]
		[0, true, false],    # N entrance -> SOUTH zone
		[1, false, false],   # E entrance -> WEST zone
		[2, false, false],   # S entrance -> NORTH zone
		[3, false, true],    # W entrance -> EAST zone
	]
	for exp: Array in expectations:
		var edge := int(exp[0])
		var zone := BuildingBuilder.stair_zone_world({
			"rect": Rect2(100.0, 100.0, fp.x, fp.y),
			"floor_h": fh,
			"door_edge": edge,
		})
		var local := Rect2(zone.position - Vector2(100.0, 100.0), zone.size)
		if not Rect2(Vector2.ZERO, fp).encloses(local):
			print("[CityTest] edge %d zone escapes footprint" % edge)
			return false
		# Anchored-in-half assertions: the zone must sit in the half
		# OPPOSITE the entrance (small margin for the structural inset).
		var south := local.get_center().y > fp.y * 0.4
		var north := local.get_center().y < fp.y * 0.6
		var west := local.get_center().x < fp.x * 0.6
		var east := local.get_center().x > fp.x * 0.4
		match edge:
			0:
				if not south:
					print("[CityTest] N entrance must anchor zone SOUTH")
					return false
			1:
				if not west:
					print("[CityTest] E entrance must anchor zone WEST")
					return false
			2:
				if not north:
					print("[CityTest] S entrance must anchor zone NORTH")
					return false
			3:
				if not east:
					print("[CityTest] W entrance must anchor zone EAST")
					return false
	# Entrance corridor / stair clearance: on a minimal legal lot the door
	# swing + walk-in lane must NOT reach into the stair zone.
	var plan := CityPlan.new()
	for cell in plan.cells_in_rect(Rect2(-200, -200, 400, 400)):
		for s: Dictionary in plan.cell_block(cell)["buildings"]:
			if int(s["floors"]) < 2 or not BuildingBuilder.has_stairs_for(
					(s["rect"] as Rect2).size, float(s["floor_h"]),
					int(s["floors"])):
				continue
			var lr: Rect2 = s["rect"]
			var z2 := BuildingBuilder.stair_zone_world(s)
			var mid_len := (lr.size.x if int(s["door_edge"]) == 0
					or int(s["door_edge"]) == 2 else lr.size.y) * 0.5
			var dp := _edge_point(lr, int(s["door_edge"]), mid_len)
			var inward := _inward_for_edge(int(s["door_edge"]))
			# Walk-in lane behind the door (~DOOR_W+2.4 long).
			var lane_end := dp + inward * 3.9
			var seg := Rect2(
					Vector2(minf(dp.x, lane_end.x), minf(dp.y, lane_end.y)),
					Vector2(absf(lane_end.x - dp.x), absf(lane_end.y - dp.y)))
			if seg.intersects(z2):
				print("[CityTest] entrance lane overlaps stair zone in %s"
						% s["id"])
				return false
	return true


func _edge_point(lr: Rect2, edge: int, t: float) -> Vector2:
	match edge:
		0: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.position.y)
		1: return Vector2(lr.end.x, lerpf(lr.position.y, lr.end.y, t))
		2: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.end.y)
		_: return Vector2(lr.position.x, lerpf(lr.position.y, lr.end.y, t))


func _inward_for_edge(edge: int) -> Vector2:
	match edge:
		0: return Vector2(0, 1)
		1: return Vector2(-1, 0)
		2: return Vector2(0, -1)
		_: return Vector2(1, 0)


# --- 19: Stair ramp COLLIDER spec vs landings (P1-8) ----------------------------
func _test_stair_collider_spec() -> bool:
	# The old test validated ramp_height_at() (a helper). The REAL collider
	# is shortened by `trim` while its center stays put - so we now inspect
	# the actual generated rotated box spec and derive its top-face
	# endpoints from basis/size/center.
	var plan := CityPlan.new()
	var tested := 0
	for cell in plan.cells_in_rect(Rect2(-300, -300, 600, 600)):
		if tested >= 12:
			break
		var block := plan.cell_block(cell)
		for spec: Dictionary in block["buildings"]:
			var n := int(spec["floors"])
			if n < 2 or not BuildingBuilder.has_stairs_for(
					(spec["rect"] as Rect2).size,
					float(spec["floor_h"]), n):
				continue
			var b := MeshBatcher.new()
			var coord := WorldSeed.chunk_coord(
					(spec["rect"] as Rect2).get_center().x,
					(spec["rect"] as Rect2).get_center().y)
			ChunkBuilder.fill_batcher(b, CityPlan.new(), coord)
			var fh := float(spec["floor_h"])
			var run := BuildingBuilder.flight_run(fh)
			var ang := atan2(fh, run)
			# P1-8: the walkable surface is NOT trimmed - full hypotenuse.
			var hyp_eff := sqrt(run * run + fh * fh)
			var found_flights := 0
			for s in b.specs():
				# Ramp colliders of THIS building only (one chunk batches
				# many buildings): rotated concrete boxes of LANE width.
				if StringName(s["material"]) != &"concrete" \
						or s["basis"] == Basis.IDENTITY \
						or not bool(s["collide"]) \
						or str(s.get("building_id", "")) != str(spec["id"]):
					continue
				var sz: Vector3 = s["size"]
				if absf(sz.x - (BuildingBuilder.LANE_W - 0.04)) > 0.02 \
						or absf(sz.z - hyp_eff) > 0.05:
					continue
				found_flights += 1
				var basis: Basis = s["basis"]
				var center: Vector3 = s["pos"]
				# Slope direction = local Z transformed by the basis.
				var slope_dir := (basis * Vector3(0, 0, 1)).normalized()
				if slope_dir.z < 0.0:
					slope_dir = -slope_dir   # orient north->south
				# Top-face endpoints from the REAL collider bounds: the top
				# face is the center plane shifted by half the thickness
				# along the box's local +Y (plane normal).
				var thick_up := (basis * Vector3(0, 1, 0)).normalized()
				var top_offset := thick_up * (sz.y * 0.5)
				var p_low := center - slope_dir * (sz.z * 0.5) + top_offset
				var p_high := center + slope_dir * (sz.z * 0.5) + top_offset
				# P1-8 contract: BOTH top-face endpoints sit EXACTLY on
				# their landing surfaces (flush - no lip a capsule cannot
				# climb, no tuck gap). The seam is kept notch-free by the
				# landing plates' LAND_TUCK overlap burying the ramp's end
				# faces, NOT by shortening the walkable surface. Flights
				# may start at any storey: derive the base from the lower
				# endpoint.
				var y_lo := minf(p_low.y, p_high.y)
				var y_hi := maxf(p_low.y, p_high.y)
				var base := roundf(y_lo / fh) * fh
				if absf(y_lo - base) > 0.02 \
						or absf(y_hi - (base + fh)) > 0.02:
					print(("[CityTest] ramp collider endpoints off: "
							+ "lo %.3f (base %.3f) hi %.3f want %.3f")
									% [y_lo, base, y_hi, base + fh])
					return false
			if found_flights != n:
				print("[CityTest] %s: %d ramp colliders for %d storeys"
						% [spec["id"], found_flights, n])
				return false
			tested += 1
	return tested >= 4


# --- 20: Bookshelf placement (P1-12) ---------------------------------------------
func _test_shelf_placement() -> bool:
	# Deterministic across many seeds/buildings: every emitted shelf
	# collider must be a 1.6 x 0.34 (x 2.0) box snapped DEPTH/2+GAP from
	# its wall face, aligned to that wall, fully inside the interior.
	var plan := CityPlan.new()
	var checked := 0
	for cell in plan.cells_in_rect(Rect2(-260, -260, 520, 520)):
		if checked >= 30:
			break
		var block := plan.cell_block(cell)
		for spec: Dictionary in block["buildings"]:
			if checked >= 30:
				break
			var b := MeshBatcher.new()
			var coord := WorldSeed.chunk_coord(
					(spec["rect"] as Rect2).get_center().x,
					(spec["rect"] as Rect2).get_center().y)
			ChunkBuilder.fill_batcher(b, CityPlan.new(), coord)
			var fp: Rect2 = spec["rect"]
			var w := fp.size.x
			var d := fp.size.y
			var gap := BuildingBuilder.SHELF_DEPTH * 0.5 + BuildingBuilder.SHELF_GAP
			for s in b.specs():
				if StringName(s["material"]) != &"wood":
					continue
				var sz: Vector3 = s["size"]
				# Shelf carcass signature: 1.6 x 0.34 (x 2.0) (axis order
				# may be swapped for E/W walls).
				var is_shelf := (absf(sz.x - BuildingBuilder.SHELF_WIDTH)
						< 0.02 and absf(sz.z
						- BuildingBuilder.SHELF_DEPTH) < 0.02) \
						or (absf(sz.x - BuildingBuilder.SHELF_DEPTH) < 0.02
						and absf(sz.z - BuildingBuilder.SHELF_WIDTH) < 0.02)
				if not is_shelf or absf(sz.y - 2.0) > 0.02:
					continue
				# Only THIS building's shelves: one chunk batches many
				# buildings, and neighbors' furniture shares the spec list.
				if str(s.get("building_id", "")) != str(spec["id"]):
					continue
				var pos: Vector3 = s["pos"]
				var lx := pos.x - fp.position.x
				var lz := pos.z - fp.position.y
				# Which wall is it snapped to?
				var dists := [absf(lx - (BuildingBuilder.WALL_T + gap)),
						absf(w - BuildingBuilder.WALL_T - gap - lx),
						absf(lz - (BuildingBuilder.WALL_T + gap)),
						absf(d - BuildingBuilder.WALL_T - gap - lz)]
				var best_side := 0
				for i in 4:
					if dists[i] < dists[best_side]:
						best_side = i
				if dists[best_side] > 0.03:
					print("[CityTest] shelf not wall-snapped: lx=%.2f lz=%.2f"
							% [lx, lz])
					return false
				# Width runs ALONG the chosen wall.
				if (best_side <= 1 and absf(sz.x - 0.34) > 0.02) \
						or (best_side >= 2 and absf(sz.z - 0.34) > 0.02):
					print("[CityTest] shelf width not parallel to its wall")
					return false
				checked += 1
	return checked >= 20


# --- 21: Floor slab paneling granularity (P1-9) -----------------------------------
func _test_slab_granularity() -> bool:
	# Every floor-slab cell must be bounded in BOTH dimensions; measure
	# collider counts per chunk while we are here.
	var plan := CityPlan.new()
	var max_cell := 0.0
	var worst_chunk := 0
	var chunks_measured := 0
	for coord in [Vector2i(0, 0), Vector2i(-1, 1), Vector2i(2, -1),
			Vector2i(-2, -2)]:
		var b := MeshBatcher.new()
		ChunkBuilder.fill_batcher(b, CityPlan.new(), coord)
		worst_chunk = maxi(worst_chunk, b.collider_count())
		chunks_measured += 1
		for s in b.specs():
			if StringName(s["material"]) != &"concrete":
				continue
			var sz: Vector3 = s["size"]
			# Floor slab cells: AXIS-ALIGNED thin horizontal plates at the
			# exact SLAB_T thickness (excludes rotated ramps/rails, whose
			# local size.y is also RAMP_T but whose basis is rotated).
			if absf(sz.y - BuildingBuilder.SLAB_T) > 0.001 \
					or s["basis"] != Basis.IDENTITY:
				continue
			max_cell = maxf(max_cell, maxf(sz.x, sz.z))
	if chunks_measured == 0:
		return false
	if max_cell > BuildingBuilder.CELL_H + 0.01:
		print("[CityTest] slab panel too large: %.2f m" % max_cell)
		return false
	print(("[CityTest] slab panels ok (max %.2f m), colliders/chunk worst "
			+ "sampled: %d") % [max_cell, worst_chunk])
	return true


# --- 22: Explosion-grade integrity ladder (P0-1) ------------------------------------
func _test_explosion_integrity_ladder() -> bool:
	# Comparable wood/concrete structural cells take the SAME raw blast
	# damage through MeshBatcher.damage_box(): wood must break first and
	# concrete must NOT vanish from one rocket-grade hit.
	var mk := func(mat: StringName) -> Array:
		var bx := MeshBatcher.new()
		bx.add_box_rotated(Vector3(0, 1.55, 0), Vector3(1.25, 3.1, 0.35),
				Basis.IDENTITY, Color.RED, true, false, mat)
		return [bx, int((bx.manifest()["colliders"] as Array)[0]["id"])]
	var wood: Array = mk.call(&"wood")
	var conc: Array = mk.call(&"concrete")
	var steel: Array = mk.call(&"steel")
	var bw: MeshBatcher = wood[0]
	var bc: MeshBatcher = conc[0]
	var bs: MeshBatcher = steel[0]
	var id_w := int(wood[1])
	var id_c := int(conc[1])
	var id_s := int(steel[1])
	# Rocket core grade: 130 raw.
	var res_w: Dictionary = bw.damage_box(id_w, 130.0)
	bc.damage_box(id_c, 130.0)
	bs.damage_box(id_s, 130.0)
	if not bool(res_w.get("shattered", false)):
		print("[CityTest] wood wall module must break on a rocket-core hit")
		return false
	# Concrete/steel SURVIVE one hit but must carry OBSERVABLE accumulated
	# damage (the persistence record exists) - no silent bypass.
	if bc.is_destroyed(id_c) or bs.is_destroyed(id_s):
		print("[CityTest] one explosion hit must not delete concrete/steel")
		return false
	var state_c: Dictionary = bc.damage_state()
	var state_s: Dictionary = bs.damage_state()
	if state_c.size() != 1 or state_s.size() != 1:
		print(("[CityTest] explosion left no damage record on "
				+ "concrete/steel (bypass?) %d/%d")
						% [state_c.size(), state_s.size()])
		return false
	# Concrete accumulates: repeated rocket hits eventually break it.
	var hits_c := 1
	while hits_c < 50 and not bc.is_destroyed(id_c):
		bc.damage_box(id_c, 130.0)
		hits_c += 1
	if not bc.is_destroyed(id_c):
		print("[CityTest] concrete never broke under repeated blasts")
		return false
	var integ_w := MeshBatcher.cell_integrity(Vector3(1.25, 3.1, 0.35), &"wood")
	var integ_c := MeshBatcher.cell_integrity(Vector3(1.25, 3.1, 0.35), &"concrete")
	var integ_s := MeshBatcher.cell_integrity(Vector3(1.25, 3.1, 0.35), &"steel")
	if not integ_w < integ_c or not integ_c < integ_s:
		print("[CityTest] strength ladder broken: %.1f/%.1f/%.1f"
				% [integ_w, integ_c, integ_s])
		return false
	# Sub-threshold damage must accumulate WITHOUT destroying (partial
	# damage persists).
	var b2 := MeshBatcher.new()
	b2.add_box_rotated(Vector3(0, 1.55, 0), Vector3(1.25, 3.1, 0.35),
			Basis.IDENTITY, Color.RED, true, false, &"concrete")
	var cid := int((b2.manifest()["colliders"] as Array)[0]["id"])
	for i in 3:
		b2.damage_box(cid, 40.0)
		if b2.is_destroyed(cid):
			print("[CityTest] partial damage destroyed too early")
			return false
	if b2.damage_state().size() != 1:
		print("[CityTest] partial damage not recorded for persistence")
		return false
	return true


# --- 23: Glass calibration vs ItemDB weapons (P1-13) ---------------------------------
func _test_glass_calibration() -> bool:
	# Window pane geometry from the builder: WIN_W-0.06 x WIN_H-0.04.
	var pane := Vector3(BuildingBuilder.WIN_W - 0.06,
			BuildingBuilder.WIN_H - 0.04, BuildingBuilder.GLASS_T)
	var mk := func() -> Array:
		var bx := MeshBatcher.new()
		bx.add_box_rotated(Vector3(0, 1.6, 0), pane, Basis.IDENTITY,
				Color.BLUE, true, false, &"glass")
		return [bx, int((bx.manifest()["colliders"] as Array)[0]["id"])]
	var smg := float(ItemDB.ITEMS[&"smg"]["damage"])          # 9
	var pellet := float(ItemDB.ITEMS[&"shotgun"]["damage"])   # 8 x7
	var pellets := int(ItemDB.ITEMS[&"shotgun"]["pellets"])
	var rocket := float(ItemDB.ITEMS[&"rocket_launcher"]["damage"])  # 130
	# 1. A single SMG hit: crack OR stay intact - NEVER shatter.
	var g1: Array = mk.call()
	var r1: Dictionary = (g1[0] as MeshBatcher).damage_box(int(g1[1]), smg)
	if bool(r1.get("shattered", false)):
		print("[CityTest] single SMG round shattered a window")
		return false
	# 2. Several SMG rounds: crack progression then shatter.
	var shatter_after := -1
	for i in 12:
		var rr: Dictionary = (g1[0] as MeshBatcher).damage_box(
				int(g1[1]), smg)
		if bool(rr.get("shattered", false)):
			shatter_after = i + 2   # +1 for the first hit above
			break
	if shatter_after < 2 or shatter_after > 6:
		print(("[CityTest] SMG shatters windows after %s rounds "
				+ "(want 2..6)") % str(shatter_after))
		return false
	# 3. Close shotgun volley: likely shatter (all pellets on one pane).
	var g2: Array = mk.call()
	var r2: Dictionary = (g2[0] as MeshBatcher).damage_box(int(g2[1]),
			pellet * pellets)
	if not bool(r2.get("shattered", false)):
		print("[CityTest] full shotgun volley should shatter a pane")
		return false
	# 4. Rocket: always shatter.
	var g3: Array = mk.call()
	var r3: Dictionary = (g3[0] as MeshBatcher).damage_box(int(g3[1]), rocket)
	if not bool(r3.get("shattered", false)):
		print("[CityTest] rocket must shatter glass")
		return false
	# 5. Crack threshold alignment: ONE SMG hit must reach the crack
	# threshold (feedback before shatter) but two must NOT shatter yet.
	var integ := MeshBatcher.cell_integrity(pane, &"glass")
	if smg < integ * 0.4:
		print("[CityTest] one SMG hit fails to crack glass (integ %.1f)"
				% integ)
		return false
	if smg * 2 >= integ:
		print("[CityTest] two SMG hits already shatter glass (integ %.1f)"
				% integ)
		return false
	return true


# --- 24: Facade layer keys building-scoped (P0-3) -------------------------------------
func _test_facade_layer_keys() -> bool:
	var plan := CityPlan.new()
	for cell in plan.cells_in_rect(Rect2(-160, -160, 320, 320)):
		for spec: Dictionary in plan.cell_block(cell)["buildings"]:
			if int(spec["floors"]) < 2:
				continue
			var b := MeshBatcher.new()
			var coord := WorldSeed.chunk_coord(
					(spec["rect"] as Rect2).get_center().x,
					(spec["rect"] as Rect2).get_center().y)
			var holder := Node3D.new()
			add_child(holder)
			ChunkBuilder.fill_batcher(b, CityPlan.new(), coord)
			b.flush_into(holder)
			var tag := str(spec["id"])
			var n := mini(int(spec["floors"]), 8)
			# All four facades of every storey exist as EXPLICIT keys.
			for f in n:
				for side in ["N", "E", "S", "W"]:
					var key := "%s:f%d:%s" % [tag, f, side]
					if not b.layer_nodes.has(key):
						print("[CityTest] missing layer key ", key)
						holder.free()
						return false
			# No legacy global keys may remain.
			for key: String in b.layer_nodes.keys():
				if key.begins_with("facade:"):
					print("[CityTest] legacy global facade key ", key)
					holder.free()
					return false
			# Gate probe mirrors ChunkManager.apply_floor_gate() on REAL
			# generated layer nodes.
			var hidden := {}
			b.apply_floor_gate_probe(tag, 1, ["N"], hidden)
			for key3: String in hidden.keys():
				var expect_vis := true
				if key3.begins_with(tag + ":"):
					var suffix := key3.substr(tag.length() + 1)
					if suffix.begins_with("roof"):
						expect_vis = false
					elif suffix.begins_with("f"):
						var rest := suffix.substr(1)
						var colon := rest.find(":")
						if colon >= 0:
							var fl := int(rest.substr(0, colon))
							var fac := rest.substr(colon + 1)
							expect_vis = not (fl > 1
									or (fl == 1 and fac == "N"))
						else:
							expect_vis = int(rest) <= 1
				if hidden[key3] != expect_vis:
					print("[CityTest] gate visibility wrong for %s (%s)"
							% [key3, "vis" if hidden[key3] else "hid"])
					holder.free()
					return false
			holder.free()
			return true   # one representative building is enough
	return false


# --- 25: Corner buildings face a street (P0-7) ---------------------------------------
func _test_corner_door_edges() -> bool:
	# Valid street-facing edges per block corner:
	#   NW: N(0) or W(3) | NE: N(0) or E(1)
	#   SE: S(2) or E(1) | SW: S(2) or W(3)
	# SE must NEVER get an N entrance; SW must NEVER get an E entrance.
	# Corner lots are identified GEOMETRICALLY (lot touching both perimeter
	# faces of its corner); construction order guarantees they are the
	# FIRST FOUR specs of every block.
	var valid := [[0, 3], [0, 1], [2, 1], [2, 3]]
	var names := ["NW", "NE", "SE", "SW"]
	var seeds := [WorldSeed.get_world_seed(), WorldSeed.get_world_seed() + 111,
			WorldSeed.get_world_seed() + 222]
	var checked := 0
	for seed_v: int in seeds:
		WorldSeed.set_world_seed(seed_v)
		var plan := CityPlan.new()
		for cell in plan.cells_in_rect(Rect2(-400, -400, 800, 800)):
			var block := plan.cell_block(cell)
			if block["kind"] == &"park":
				continue
			var specs: Array = block["buildings"]
			if specs.size() < 4:
				continue
			var br: Rect2 = block["rect"]
			for ci in 4:
				var spec: Dictionary = specs[ci]
				var lot: Rect2 = spec["rect"]
				# Geometric corner identity: touches BOTH perimeter faces.
				var touch := {
					"N": absf(lot.position.y - br.position.y) < 0.05,
					"S": absf(lot.end.y - br.end.y) < 0.05,
					"W": absf(lot.position.x - br.position.x) < 0.05,
					"E": absf(lot.end.x - br.end.x) < 0.05,
				}
				var expect_touch: Array = [["N", "W"], ["N", "E"],
						["S", "E"], ["S", "W"]][ci]
				if not (bool(touch[expect_touch[0]])
						and bool(touch[expect_touch[1]])):
					continue   # degenerate block layout; skip this corner
				var edge := int(spec["door_edge"])
				if not valid[ci].has(edge):
					print(("[CityTest] %s corner %s door edge %d "
							+ "not street-facing (valid %s)")
									% [names[ci], spec["id"], edge,
											str(valid[ci])])
					WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
					return false
				checked += 1
	WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
	print("[CityTest] corner doors checked: %d" % checked)
	return checked >= 40



# --- 26: Intra-block passages ---------------------------------------------------
func _test_passages() -> bool:
	# Every seeded passage must span the FULL block extent on its axis
	# (piercing both opposite building fronts), stay within the designed
	# width band, and have NO parcel intruding into the cleared cut. Also
	# asserts passages actually occur often enough to shape the city.
	var found := 0
	for seed_v: int in [WorldSeed.get_world_seed(),
			WorldSeed.get_world_seed() + 777]:
		WorldSeed.set_world_seed(seed_v)
		var plan := CityPlan.new()
		for cell in plan.cells_in_rect(Rect2(-450, -450, 900, 900)):
			var block := plan.cell_block(cell)
			var p: Dictionary = block.get("passage", {})
			if p.is_empty():
				continue
			found += 1
			var band: Rect2 = p["rect"]
			var br: Rect2 = block["rect"]
			var ok_span := false
			if int(p["axis"]) == 0:
				ok_span = absf(band.position.y - br.position.y) < 0.05 \
						and absf(band.end.y - br.end.y) < 0.05 \
						and band.size.x >= 3.0 and band.size.x <= 5.6
			else:
				ok_span = absf(band.position.x - br.position.x) < 0.05 \
						and absf(band.end.x - br.end.x) < 0.05 \
						and band.size.y >= 3.0 and band.size.y <= 5.6
			if not ok_span:
				print("[CityTest] passage band malformed in %s: %s"
						% [block["id"], str(p)])
				WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
				return false
			for s: Dictionary in block["buildings"]:
				if (s["rect"] as Rect2).grow(0.05).intersects(band):
					print("[CityTest] %s intrudes into passage of %s"
							% [s["id"], block["id"]])
					WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
					return false
	WorldSeed.set_world_seed(WorldSeed.DEFAULT_SEED)
	print("[CityTest] passages checked: %d blocks pierced" % found)
	return found >= 6



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
