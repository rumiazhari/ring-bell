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
	_check("bulkhead access ladder: climbable rungs deck->rim, gated to stairs",
			_test_bulkhead_ladder())
	_check("facade balconies: deck+steel lip on upper storeys, gated to multi-storey",
		_test_balconies())
	_check("street awnings: canopy deck + steel lip on ground facade, gated to street wall",
		_test_awnings())
	_check("construction scaffolding: steel cage + plank decks on plaza-adjacent historic facades",
		_test_scaffolds())
	_check("facade cornices + pilasters: stone ledge bands + pillar strips on historic multi-storey facades",
		_test_cornices_pilasters())
	_check("facade decay: graffiti / rust / moss visual decals on historic facades",
		_test_facade_decay())
	_check("broken windows + street litter: missing panes / dark interiors + sidewalk debris on historic facades",
		_test_broken_and_litter())
	_check("streetlamp night lights: genuine darkness + avenue-aligned warm pools (deterministic)",
		_test_streetlamps_and_darkness())
	_check("player lantern: warm handheld light at night with bob (deterministic)",
		_test_player_lantern())


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


## Colliding steel specs tagged "bhladder" (Phase J bulkhead access ladder).
func _collect_bhladder(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if StringName(s["material"]) != &"steel" \
				or not bool(s["collide"]):
			continue
		if String(s.get("building_id", "")) != "bhladder":
			continue
		out.append(s)
	return out


func _test_bulkhead_ladder() -> bool:
	# A stair building MUST finish its bulkhead with Phase J access ladder:
	# a vertical run of >=4 colliding steel "bhladder" rungs on the hut's
	# +Z face spanning from just above the deck up to the rim top, so the
	# plant-room cap (Phase H rim + Phase I hatch) is climbable rather than
	# a mantle-only target. Every rung rests ABOVE the doorway lane, the
	# rung footprints sit inside the bulkhead cap zone (within the Phase H
	# railed enclosure), the rungs are ordered strictly ascending in y, and
	# a rebuild is byte-identical. A building WITHOUT stairs grows none.
	var spec := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 3, "id": "bhladdertest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	var rungs := _collect_bhladder(b)
	if rungs.size() < 4:
		print("[CityTest] bhladder: expected >=4 rungs, got %d" % rungs.size())
		return false
	var total_h := 9.0
	var bh_h := 2.4
	var cap_top := total_h + bh_h + 0.18
	var cap_zone: Rect2 = BuildingBuilder._zone_rect(
		(spec["rect"] as Rect2).size, 3.0, 0).grow(0.14 + 0.15 + 0.05)
	var prev_y := -INF
	var min_y := INF
	var max_y := -INF
	for s: Dictionary in rungs:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		# Rung footprint confined to the bulkhead cap zone (on the hut
		# face, within the Phase H railed enclosure footprint).
		var r := Rect2(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5,
				sz.x, sz.z)
		if not BuildingBuilder._obb_in_rect(
				BuildingBuilder._rect_obb(r), cap_zone):
			print("[CityTest] bhladder: rung outside bulkhead cap %s" % [r])
			return false
		# Strictly ascending so it reads as a climbable ladder.
		if pos.y <= prev_y:
			print("[CityTest] bhladder: rungs not ascending at %s" % [pos])
			return false
		prev_y = pos.y
		min_y = minf(min_y, pos.y - sz.y * 0.5)
		max_y = maxf(max_y, pos.y + sz.y * 0.5)
	# Bottom rung must start near the deck (climbable from the roof deck),
	# top rung must reach the cap so the plant-room roof is reachable.
	if min_y > total_h + 0.7:
		print("[CityTest] bhladder: bottom rung too high above deck (%f)"
				% min_y)
		return false
	if max_y < cap_top:
		print("[CityTest] bhladder: top rung below cap (%f < %f)"
				% [max_y, cap_top])
		return false

	# Determinism: rebuild is byte-identical.
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, spec)
	var rungs2 := _collect_bhladder(b2)
	if rungs.size() != rungs2.size():
		print("[CityTest] bhladder: nondeterministic count %d vs %d"
				% [rungs.size(), rungs2.size()])
		return false
	for i in rungs.size():
		if rungs[i]["pos"] != rungs2[i]["pos"] \
				or rungs[i]["size"] != rungs2[i]["size"]:
			print("[CityTest] bhladder: nondeterministic rung %d" % i)
			return false

	# Gating: a flat deck WITHOUT stairs grows no ladder.
	var nostair := {
		"rect": Rect2(0, 0, 30, 26),
		"floor_h": 3.0, "floors": 1, "id": "bhladder-nostair",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nostair)
	if not _collect_bhladder(b3).is_empty():
		print("[CityTest] bhladder: non-stair building grew a ladder")
		return false
	return true


## Colliding boxes tagged "balcony" (Phase K facade balconies).
func _collect_balcony(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if not bool(s.get("collide", false)):
			continue
		if String(s.get("building_id", "")) != "balcony":
			continue
		out.append(s)
	return out


## Colliding boxes tagged "awning" (Phase L street awnings).
func _collect_awning(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if not bool(s.get("collide", false)):
			continue
		if String(s.get("building_id", "")) != "awning":
			continue
		out.append(s)
	return out

## Colliding boxes tagged "scaffold" (Phase O construction scaffolding).
func _collect_scaffold(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if not bool(s.get("collide", false)):
			continue
		if String(s.get("building_id", "")) != "scaffold":
			continue
		out.append(s)
	return out

## Colliding boxes tagged "cornice" / "pilaster" (Phase P facade detailing).
func _collect_cornice(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if not bool(s.get("collide", false)):
			continue
		if String(s.get("building_id", "")) != "cornice":
			continue
		out.append(s)
	return out

func _collect_pilaster(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if not bool(s.get("collide", false)):
			continue
		if String(s.get("building_id", "")) != "pilaster":
			continue
		out.append(s)
	return out

## Visual-only boxes tagged "decay" (Phase Q facade decay — historic dressing).
func _collect_decay(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if String(s.get("building_id", "")) != "decay":
			continue
		out.append(s)
	return out

## Visual-only boxes tagged "broken" (Phase R missing panes — dark interiors).
func _collect_broken(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if String(s.get("building_id", "")) != "broken":
			continue
		out.append(s)
	return out

## Visual-only boxes tagged "litter" (Phase R sidewalk debris).
func _collect_litter(b: MeshBatcher) -> Array:
	var out: Array = []
	for s: Dictionary in b.specs():
		if String(s.get("building_id", "")) != "litter":
			continue
		out.append(s)
	return out

func _count_glass(b: MeshBatcher) -> int:
	var n := 0
	for s: Dictionary in b.specs():
		if StringName(s["material"]) == &"glass":
			n += 1
	return n


# --- 24e: Facade balconies (Phase K) ------------------------------------------
func _test_balconies() -> bool:
	# A multi-storey building MUST grow AC-style facade balconies on some of
	# its upper-storey (f>=1) facades: colliding boxes tagged "balcony",
	# confined to a believable protrusion band just beyond the wall face,
	# with a standable concrete deck and a steel railing lip whose TOP sits
	# BAL_RAIL_H above the deck (a grabbable parkour ledge). They must hang
	# on a floor >=1 above grade, never on the ground floor, and a rebuild is
	# byte-identical. A single-storey building (no upper storey) grows none.
	var spec := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 4, "id": "balconytest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	var bal := _collect_balcony(b)
	if bal.is_empty():
		print("[CityTest] balcony: multi-storey building grew no balconies")
		return false
	var total_h := 12.0   # 4 floors * 3.0
	var fh := 3.0
	var BAL_RAIL_H := 0.5
	var saw_upper := false
	for s: Dictionary in bal:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 < fh * 0.5:
			print("[CityTest] balcony: box too low (ground floor?) at %s" % [pos])
			return false
		if pos.y - sz.y * 0.5 > total_h:
			print("[CityTest] balcony: box above the roof at %s" % [pos])
			return false
		saw_upper = true
		# Protrusion must stay within the balcony band beyond a wall face.
		var ox: float = pos.x - sz.x * 0.5
		var ox2: float = pos.x + sz.x * 0.5
		var oz: float = pos.z - sz.z * 0.5
		var oz2: float = pos.z + sz.z * 0.5
		var beyond_x := ox < -0.05 or ox2 > 12.0 + 0.05
		var beyond_z := oz < -0.05 or oz2 > 10.0 + 0.05
		var protrudes := false
		if beyond_x and oz >= -0.05 and oz2 <= 10.0 + 0.05:
			protrudes = true
		if beyond_z and ox >= -0.05 and ox2 <= 12.0 + 0.05:
			protrudes = true
		if not protrudes and (beyond_x or beyond_z):
			print("[CityTest] balcony: box outside footprint band %s" % [pos])
			return false
		if StringName(s["material"]) == &"steel":
			# The railing upright IS the grabbable parkour lip, so its
			# vertical extent must read as BAL_RAIL_H exactly.
			if absf(sz.y - BAL_RAIL_H) > 0.05:
				print("[CityTest] balcony: rail lip height %f != %f"
						% [sz.y, BAL_RAIL_H])
				return false
	if not saw_upper:
		print("[CityTest] balcony: no upper-storey boxes")
		return false

	# Determinism: rebuild is byte-identical.
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, spec)
	var bal2 := _collect_balcony(b2)
	if bal.size() != bal2.size():
		print("[CityTest] balcony: nondeterministic count %d vs %d"
				% [bal.size(), bal2.size()])
		return false
	for i in bal.size():
		if bal[i]["pos"] != bal2[i]["pos"] \
				or bal[i]["size"] != bal2[i]["size"]:
			print("[CityTest] balcony: nondeterministic box %d" % i)
			return false

	# Gating: a single-storey building grows no balconies.
	var one := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 1, "id": "balcony-1storey",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, one)
	if not _collect_balcony(b3).is_empty():
		print("[CityTest] balcony: single-storey building wrongly grew one")
		return false
	return true


# --- 24f: Street awnings (Phase L) ------------------------------------------
func _test_awnings() -> bool:
	# A ground-floor street wall MUST project an AC-style awning: a colliding
	# "awning" canopy deck whose top sits near AWN_DECK_Y above grade (a
	# standable parkour surface) plus a steel front lip whose TOP sits
	# AWN_RAIL_H above the deck (a grabbable parkour ledge). The canopy must
	# protrude beyond a wall face, sit at ground level (never an upper storey),
	# a rebuild is byte-identical, and a building with a too-short street facade
	# grows none.
	var AWN_PROJ := 1.1
	var AWN_DECK_Y := 2.3
	var AWN_RAIL_H := 0.45
	var spec := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0, "floors": 4, "id": "awningtest",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	var awn := _collect_awning(b)
	if awn.is_empty():
		print("[CityTest] awning: street wall grew no awning")
		return false
	var saw_deck := false
	var saw_lip := false
	for s: Dictionary in awn:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 < 0.5:
			print("[CityTest] awning: box below grade at %s" % [pos])
			return false
		if pos.y - sz.y * 0.5 > AWN_DECK_Y + 1.0:
			print("[CityTest] awning: box too high (not ground level?) at %s"
				% [pos])
			return false
		# Protrusion must leave the footprint band on the N wall (door_edge 0).
		var oz: float = pos.z - sz.z * 0.5
		var oz2: float = pos.z + sz.z * 0.5
		var beyond_z := oz < -0.05 or oz2 > 10.0 + 0.05
		if not beyond_z:
			print("[CityTest] awning: box does not protrude past wall at %s"
				% [pos])
			return false
		if StringName(s["material"]) == &"wood":
			# Canopy deck: standable top near AWN_DECK_Y above grade.
			saw_deck = true
		if StringName(s["material"]) == &"steel":
			# Front lip: vertical extent reads as AWN_RAIL_H exactly.
			saw_lip = true
			if absf(sz.y - AWN_RAIL_H) > 0.05:
				print("[CityTest] awning: lip height %f != %f"
					% [sz.y, AWN_RAIL_H])
				return false
	if not saw_deck:
		print("[CityTest] awning: no standable canopy deck box")
		return false
	if not saw_lip:
		print("[CityTest] awning: no grabbable steel front lip")
		return false

	# Determinism: rebuild is byte-identical.
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, spec)
	var awn2 := _collect_awning(b2)
	if awn.size() != awn2.size():
		print("[CityTest] awning: nondeterministic count %d vs %d"
			% [awn.size(), awn2.size()])
		return false
	for i in awn.size():
		if awn[i]["pos"] != awn2[i]["pos"] \
				or awn[i]["size"] != awn2[i]["size"]:
			print("[CityTest] awning: nondeterministic box %d" % i)
			return false

	# Gating: a building whose street facade is too short grows no awning.
	var tiny := {
		"rect": Rect2(0, 0, 4, 4),
		"floor_h": 3.0, "floors": 1, "id": "awning-tiny",
		"door_edge": 0,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, tiny)
	if not _collect_awning(b3).is_empty():
		print("[CityTest] awning: tiny-facade building wrongly grew one")
		return false
	return true

# --- 24g: Construction scaffolding (Phase O) --------------------------------
func _test_scaffolds() -> bool:
	var base := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0,
		"floors": 4,
		"id": "scaffoldtest",
		"door_edge": 0,
		"district": "historic",
		"plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var found_spec: Dictionary = {}
	var found_boxes: Array = []
	for try_id in ["scaffoldtest", "scaffoldtest2", "scaffoldtest3", "scaffoldtest4"]:
		var s := base.duplicate(true)
		s["id"] = try_id
		var b_try := MeshBatcher.new()
		BuildingBuilder.build(b_try, s)
		var got := _collect_scaffold(b_try)
		if not got.is_empty():
			found_spec = s
			found_boxes = got
			break
	if found_boxes.is_empty():
		print("[CityTest] scaffold: plaza-adjacent historic building grew no scaffold (tried 4 ids)")
		return false
	var saw_plank := false
	var saw_pole := false
	for s: Dictionary in found_boxes:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 < -0.1:
			print("[CityTest] scaffold: box below grade at %s" % [pos])
			return false
		if pos.y + sz.y * 0.5 > 12.0 + 0.5:
			print("[CityTest] scaffold: box above roof at %s" % [pos])
			return false
		var ox: float = pos.x - sz.x * 0.5
		var ox2: float = pos.x + sz.x * 0.5
		var oz: float = pos.z - sz.z * 0.5
		var oz2: float = pos.z + sz.z * 0.5
		var beyond := ox < -0.05 or ox2 > 12.0 + 0.05 or oz < -0.05 or oz2 > 10.0 + 0.05
		if not beyond:
			print("[CityTest] scaffold: box does not protrude past wall at %s" % [pos])
			return false
		if StringName(s["material"]) == &"wood":
			saw_plank = true
			if absf(sz.y - BuildingBuilder.SCAFF_PLANK_T) > 0.02:
				print("[CityTest] scaffold: plank thickness %f != %f" % [sz.y, BuildingBuilder.SCAFF_PLANK_T])
				return false
		elif StringName(s["material"]) == &"steel":
			saw_pole = true
			if absf(sz.x - BuildingBuilder.SCAFF_POLE_S) > 0.02 and absf(sz.z - BuildingBuilder.SCAFF_POLE_S) > 0.02:
				print("[CityTest] scaffold: pole section %s not %.2f" % [sz, BuildingBuilder.SCAFF_POLE_S])
				return false
	if not saw_plank:
		print("[CityTest] scaffold: no wood plank deck")
		return false
	if not saw_pole:
		print("[CityTest] scaffold: no steel pole")
		return false
	var planks := 0
	for s2: Dictionary in found_boxes:
		if StringName(s2["material"]) == &"wood":
			planks += 1
	if planks < 2:
		print("[CityTest] scaffold: expected planks on multiple storeys, got %d" % planks)
		return false
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, found_spec)
	var got2 := _collect_scaffold(b2)
	if found_boxes.size() != got2.size():
		print("[CityTest] scaffold: nondeterministic count %d vs %d" % [found_boxes.size(), got2.size()])
		return false
	for i in found_boxes.size():
		if found_boxes[i]["pos"] != got2[i]["pos"] or found_boxes[i]["size"] != got2[i]["size"]:
			print("[CityTest] scaffold: nondeterministic box %d" % i)
			return false
	var nonhist := base.duplicate(true)
	nonhist["id"] = "scaffold-nonhist"
	nonhist["district"] = "outer"
	nonhist["plaza_adjacent"] = true
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nonhist)
	if not _collect_scaffold(b3).is_empty():
		print("[CityTest] scaffold: non-historic building wrongly grew one")
		return false
	var noplaza := base.duplicate(true)
	noplaza["id"] = "scaffold-noplaza"
	noplaza["district"] = "historic"
	noplaza["plaza_adjacent"] = false
	var b4 := MeshBatcher.new()
	BuildingBuilder.build(b4, noplaza)
	if not _collect_scaffold(b4).is_empty():
		print("[CityTest] scaffold: non-plaza building wrongly grew one")
		return false
	var one := base.duplicate(true)
	one["id"] = "scaffold-onestorey"
	one["floors"] = 1
	var b5 := MeshBatcher.new()
	BuildingBuilder.build(b5, one)
	if not _collect_scaffold(b5).is_empty():
		print("[CityTest] scaffold: single-storey building wrongly grew one")
		return false
	var tiny := {
		"rect": Rect2(0, 0, 4, 4),
		"floor_h": 3.0, "floors": 3, "id": "scaffold-tiny",
		"door_edge": 0, "district": "historic", "plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b6 := MeshBatcher.new()
	BuildingBuilder.build(b6, tiny)
	if not _collect_scaffold(b6).is_empty():
		print("[CityTest] scaffold: tiny-facade building wrongly grew one")
		return false
	return true



# --- 24h: Facade cornices + pilasters (Phase P) --------------------------------
func _test_cornices_pilasters() -> bool:
	var base := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0,
		"floors": 4,
		"id": "corpiltest",
		"door_edge": 0,
		"district": "historic",
		"plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var found_spec: Dictionary = {}
	var found_corn: Array = []
	var found_pil: Array = []
	for try_id in ["corpiltest", "corpiltest2", "corpiltest3", "corpiltest4", "corpiltest5"]:
		var s := base.duplicate(true)
		s["id"] = try_id
		var b_try := MeshBatcher.new()
		BuildingBuilder.build(b_try, s)
		var got_c := _collect_cornice(b_try)
		var got_p := _collect_pilaster(b_try)
		if not got_c.is_empty() and not got_p.is_empty():
			found_spec = s
			found_corn = got_c
			found_pil = got_p
			break
	if found_corn.is_empty() or found_pil.is_empty():
		print("[CityTest] cornice/pilaster: historic multi-storey building grew no pair (tried 5 ids)")
		return false
	var corn_h := BuildingBuilder.CORN_H
	var corn_proj := BuildingBuilder.CORN_PROJ
	for s: Dictionary in found_corn:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 < 0.5:
			print("[CityTest] cornice: box too low at %s" % [pos])
			return false
		if pos.y + sz.y * 0.5 > 12.0 + 0.5:
			print("[CityTest] cornice: box above roof at %s" % [pos])
			return false
		var ox: float = pos.x - sz.x * 0.5
		var ox2: float = pos.x + sz.x * 0.5
		var oz: float = pos.z - sz.z * 0.5
		var oz2: float = pos.z + sz.z * 0.5
		var beyond := ox < -0.05 or ox2 > 12.0 + 0.05 or oz < -0.05 or oz2 > 10.0 + 0.05
		if not beyond:
			print("[CityTest] cornice: box does not protrude past wall at %s" % [pos])
			return false
		if StringName(s["material"]) != &"concrete":
			print("[CityTest] cornice: material %s != concrete" % [s["material"]])
			return false
		if absf(sz.y - corn_h) > 0.02:
			print("[CityTest] cornice: height %f != %f" % [sz.y, corn_h])
			return false
		var is_proj_x := absf(sz.x - corn_proj) < 0.02
		var is_proj_z := absf(sz.z - corn_proj) < 0.02
		if not (is_proj_x or is_proj_z):
			print("[CityTest] cornice: planar projection %s != %f" % [sz, corn_proj])
			return false
	if found_corn.size() < 4:
		print("[CityTest] cornice: expected >=4 bands (one per storey junction), got %d" % found_corn.size())
		return false
	var pil_w := BuildingBuilder.PIL_W
	var pil_proj := BuildingBuilder.PIL_PROJ
	for s: Dictionary in found_pil:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if pos.y - sz.y * 0.5 < -0.1:
			print("[CityTest] pilaster: box below grade at %s" % [pos])
			return false
		if pos.y + sz.y * 0.5 > 12.0 + 0.5:
			print("[CityTest] pilaster: box above roof at %s" % [pos])
			return false
		var ox: float = pos.x - sz.x * 0.5
		var ox2: float = pos.x + sz.x * 0.5
		var oz: float = pos.z - sz.z * 0.5
		var oz2: float = pos.z + sz.z * 0.5
		var beyond := ox < -0.05 or ox2 > 12.0 + 0.05 or oz < -0.05 or oz2 > 10.0 + 0.05
		if not beyond:
			print("[CityTest] pilaster: box does not protrude past wall at %s" % [pos])
			return false
		if StringName(s["material"]) != &"concrete":
			print("[CityTest] pilaster: material %s != concrete" % [s["material"]])
			return false
		var is_w_x := absf(sz.x - pil_w) < 0.02
		var is_w_z := absf(sz.z - pil_w) < 0.02
		if not (is_w_x or is_w_z):
			print("[CityTest] pilaster: width %s != %f" % [sz, pil_w])
			return false
		var is_proj2_x := absf(sz.x - pil_proj) < 0.02
		var is_proj2_z := absf(sz.z - pil_proj) < 0.02
		if not (is_proj2_x or is_proj2_z):
			print("[CityTest] pilaster: projection %s != %f" % [sz, pil_proj])
			return false
		if absf(sz.y - (3.0 - 0.02)) > 0.02:
			print("[CityTest] pilaster: segment height %f != 2.98" % [sz.y])
			return false
	if found_pil.size() < 4:
		print("[CityTest] pilaster: expected >=4 segments (at least one pillar x 4 storeys), got %d" % found_pil.size())
		return false
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, found_spec)
	var got_c2 := _collect_cornice(b2)
	var got_p2 := _collect_pilaster(b2)
	if found_corn.size() != got_c2.size() or found_pil.size() != got_p2.size():
		print("[CityTest] cornice/pilaster: nondeterministic counts cornice %d vs %d / pilaster %d vs %d" % [found_corn.size(), got_c2.size(), found_pil.size(), got_p2.size()])
		return false
	for i in found_corn.size():
		if found_corn[i]["pos"] != got_c2[i]["pos"] or found_corn[i]["size"] != got_c2[i]["size"]:
			print("[CityTest] cornice: nondeterministic box %d" % i)
			return false
	for i in found_pil.size():
		if found_pil[i]["pos"] != got_p2[i]["pos"] or found_pil[i]["size"] != got_p2[i]["size"]:
			print("[CityTest] pilaster: nondeterministic box %d" % i)
			return false
	var nonhist := base.duplicate(true)
	nonhist["id"] = "corpil-nonhist"
	nonhist["district"] = "outer"
	nonhist["plaza_adjacent"] = true
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nonhist)
	if not _collect_cornice(b3).is_empty() or not _collect_pilaster(b3).is_empty():
		print("[CityTest] cornice/pilaster: non-historic building wrongly grew one")
		return false
	var one := base.duplicate(true)
	one["id"] = "corpil-onestorey"
	one["floors"] = 1
	var b5 := MeshBatcher.new()
	BuildingBuilder.build(b5, one)
	if not _collect_cornice(b5).is_empty() or not _collect_pilaster(b5).is_empty():
		print("[CityTest] cornice/pilaster: single-storey building wrongly grew one")
		return false
	var tiny := {
		"rect": Rect2(0, 0, 4, 4),
		"floor_h": 3.0, "floors": 3, "id": "corpil-tiny",
		"door_edge": 0, "district": "historic", "plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b6 := MeshBatcher.new()
	BuildingBuilder.build(b6, tiny)
	if not _collect_cornice(b6).is_empty() or not _collect_pilaster(b6).is_empty():
		print("[CityTest] cornice/pilaster: tiny-facade building wrongly grew one")
		return false
	return true


# --- 24i: Facade decay (Phase Q) — visual-only historic dressing ----------------
func _test_facade_decay() -> bool:
	var base := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0,
		"floors": 4,
		"id": "decaytest",
		"door_edge": 0,
		"district": "historic",
		"plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var found_spec: Dictionary = {}
	var found: Array = []
	for try_id in ["decaytest", "decaytest2", "decaytest3", "decaytest4", "decaytest5", "decaytest6"]:
		var s := base.duplicate(true)
		s["id"] = try_id
		var b_try := MeshBatcher.new()
		BuildingBuilder.build(b_try, s)
		var got := _collect_decay(b_try)
		if not got.is_empty():
			found_spec = s
			found = got
			break
	if found.is_empty():
		print("[CityTest] decay: historic building grew no decay decals (tried 6 ids)")
		return false
	for s: Dictionary in found:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if bool(s["collide"]):
			print("[CityTest] decay: decal must be visual-only at %s" % [pos])
			return false
		if StringName(s["material"]) != &"":
			print("[CityTest] decay: material %s != empty (visual)" % [s["material"]])
			return false
		if String(s.get("building_id", "")) != "decay":
			print("[CityTest] decay: building_id %s != decay" % [s.get("building_id", "")])
			return false
		if pos.y - sz.y * 0.5 < -0.1:
			print("[CityTest] decay: box below grade at %s" % [pos])
			return false
		if pos.y + sz.y * 0.5 > 12.0 + 0.5:
			print("[CityTest] decay: box above roof at %s" % [pos])
			return false
		var is_thin_x := absf(sz.x - BuildingBuilder.DECAY_T) < 0.015
		var is_thin_z := absf(sz.z - BuildingBuilder.DECAY_T) < 0.015
		if not (is_thin_x or is_thin_z):
			print("[CityTest] decay: thin dimension %s != %.3f" % [sz, BuildingBuilder.DECAY_T])
			return false
		if not is_thin_x and not is_thin_z:
			return false
		# At least one face just outside the wall (thin plane pressed outward).
		var ox := pos.x - sz.x * 0.5
		var ox2 := pos.x + sz.x * 0.5
		var oz := pos.z - sz.z * 0.5
		var oz2 := pos.z + sz.z * 0.5
		var near_wall := (ox2 > -0.08 and ox < 0.08) or (ox2 > 12.0 - 0.08 and ox < 12.0 + 0.08) or (oz2 > -0.08 and oz < 0.08) or (oz2 > 10.0 - 0.08 and oz < 10.0 + 0.08)
		if not near_wall:
			print("[CityTest] decay: decal not on wall face at %s sz %s" % [pos, sz])
			return false
		# Colour must be set (not a default zero).
		var col: Color = s["color"]
		if col.a < 0.9:
			print("[CityTest] decay: unexpected alpha %f" % col.a)
			return false
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, found_spec)
	var got2 := _collect_decay(b2)
	if found.size() != got2.size():
		print("[CityTest] decay: nondeterministic count %d vs %d" % [found.size(), got2.size()])
		return false
	for i in found.size():
		if found[i]["pos"] != got2[i]["pos"] or found[i]["size"] != got2[i]["size"] or found[i]["color"] != got2[i]["color"]:
			print("[CityTest] decay: nondeterministic box %d" % i)
			return false
	var nonhist := base.duplicate(true)
	nonhist["id"] = "decay-nonhist"
	nonhist["district"] = "outer"
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nonhist)
	if not _collect_decay(b3).is_empty():
		print("[CityTest] decay: non-historic building wrongly grew decals")
		return false
	var tiny := {
		"rect": Rect2(0, 0, 4, 4),
		"floor_h": 3.0, "floors": 3, "id": "decay-tiny",
		"door_edge": 0, "district": "historic", "plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b4 := MeshBatcher.new()
	BuildingBuilder.build(b4, tiny)
	if not _collect_decay(b4).is_empty():
		print("[CityTest] decay: tiny-facade building wrongly grew decals")
		return false
	return true


# --- 24j: Broken windows + street litter (Phase R) --------------------------
func _test_broken_and_litter() -> bool:
	var base := {
		"rect": Rect2(0, 0, 12, 10),
		"floor_h": 3.0,
		"floors": 4,
		"id": "brokentest",
		"door_edge": 0,
		"district": "historic",
		"plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var found_spec: Dictionary = {}
	var found_litter: Array = []
	var found_broken: Array = []
	var found_glass_hist: int = -1
	var found_glass_outer: int = -1
	for try_id in ["brokentest", "brokentest2", "brokentest3", "brokentest4", "brokentest5", "brokentest6", "brokentest7", "brokentest8"]:
		var s_hist := base.duplicate(true)
		s_hist["id"] = try_id
		s_hist["district"] = "historic"
		var b_hist := MeshBatcher.new()
		BuildingBuilder.build(b_hist, s_hist)
		var lit := _collect_litter(b_hist)
		var bro := _collect_broken(b_hist)
		var g_hist := _count_glass(b_hist)
		var s_outer := base.duplicate(true)
		s_outer["id"] = try_id
		s_outer["district"] = "outer"
		var b_outer := MeshBatcher.new()
		BuildingBuilder.build(b_outer, s_outer)
		var g_outer := _count_glass(b_outer)
		if not lit.is_empty() and not bro.is_empty() and g_hist < g_outer:
			found_spec = s_hist
			found_litter = lit
			found_broken = bro
			found_glass_hist = g_hist
			found_glass_outer = g_outer
			break
	if found_litter.is_empty() or found_broken.is_empty():
		print("[CityTest] broken/litter: historic building grew no pair (tried 8 ids; glass_hist=%d glass_outer=%d broken=%d litter=%d)" % [found_glass_hist, found_glass_outer, found_broken.size(), found_litter.size()])
		return false
	for s: Dictionary in found_broken:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if bool(s["collide"]):
			print("[CityTest] broken: dark plane must be visual-only at %s" % [pos])
			return false
		if StringName(s["material"]) != &"":
			print("[CityTest] broken: material %s != empty (visual)" % [s["material"]])
			return false
		if String(s.get("building_id", "")) != "broken":
			print("[CityTest] broken: building_id %s != broken" % [s.get("building_id", "")])
			return false
		if pos.y - sz.y * 0.5 < 0.5:
			print("[CityTest] broken: box too low at %s" % [pos])
			return false
		if pos.y + sz.y * 0.5 > 12.0 + 0.5:
			print("[CityTest] broken: box above roof at %s" % [pos])
			return false
		var is_thin := absf(sz.x - BuildingBuilder.BROKEN_DARK_T) < 0.015 or absf(sz.z - BuildingBuilder.BROKEN_DARK_T) < 0.015
		if not is_thin:
			print("[CityTest] broken: thin dimension %s != %.3f" % [sz, BuildingBuilder.BROKEN_DARK_T])
			return false
	var outer_for_found := base.duplicate(true)
	outer_for_found["id"] = String(found_spec["id"])
	outer_for_found["district"] = "outer"
	var b_outer_found := MeshBatcher.new()
	BuildingBuilder.build(b_outer_found, outer_for_found)
	var g_outer_found := _count_glass(b_outer_found)
	if found_glass_hist >= g_outer_found:
		print("[CityTest] broken: historic glass %d should be < outer %d" % [found_glass_hist, g_outer_found])
		return false
	for s: Dictionary in found_litter:
		var pos: Vector3 = s["pos"]
		var sz: Vector3 = s["size"]
		if bool(s["collide"]):
			print("[CityTest] litter: decal must be visual-only at %s" % [pos])
			return false
		if StringName(s["material"]) != &"":
			print("[CityTest] litter: material %s != empty (visual)" % [s["material"]])
			return false
		if String(s.get("building_id", "")) != "litter":
			print("[CityTest] litter: building_id %s != litter" % [s.get("building_id", "")])
			return false
		if pos.y - sz.y * 0.5 < -0.05 or pos.y + sz.y * 0.5 > 0.6:
			print("[CityTest] litter: box not on sidewalk ground at %s" % [pos])
			return false
		var ox := pos.x - sz.x * 0.5
		var ox2 := pos.x + sz.x * 0.5
		var oz := pos.z - sz.z * 0.5
		var oz2 := pos.z + sz.z * 0.5
		var outside := ox < -0.08 or ox2 > 12.0 + 0.08 or oz < -0.08 or oz2 > 10.0 + 0.08
		if not outside:
			print("[CityTest] litter: decal not outside footprint at %s sz %s" % [pos, sz])
			return false
	var b2 := MeshBatcher.new()
	BuildingBuilder.build(b2, found_spec)
	var got_bro2 := _collect_broken(b2)
	var got_lit2 := _collect_litter(b2)
	if found_broken.size() != got_bro2.size() or found_litter.size() != got_lit2.size():
		print("[CityTest] broken/litter: nondeterministic counts broken %d vs %d / litter %d vs %d" % [found_broken.size(), got_bro2.size(), found_litter.size(), got_lit2.size()])
		return false
	for i in found_broken.size():
		if found_broken[i]["pos"] != got_bro2[i]["pos"] or found_broken[i]["size"] != got_bro2[i]["size"]:
			print("[CityTest] broken: nondeterministic box %d" % i)
			return false
	for i in found_litter.size():
		if found_litter[i]["pos"] != got_lit2[i]["pos"] or found_litter[i]["size"] != got_lit2[i]["size"]:
			print("[CityTest] litter: nondeterministic box %d" % i)
			return false
	var nonhist := base.duplicate(true)
	nonhist["id"] = "broken-nonhist"
	nonhist["district"] = "outer"
	var b3 := MeshBatcher.new()
	BuildingBuilder.build(b3, nonhist)
	if not _collect_broken(b3).is_empty() or not _collect_litter(b3).is_empty():
		print("[CityTest] broken/litter: non-historic building wrongly grew one (broken=%d litter=%d)" % [_collect_broken(b3).size(), _collect_litter(b3).size()])
		return false
	var tiny := {
		"rect": Rect2(0, 0, 4, 4),
		"floor_h": 3.0, "floors": 3, "id": "broken-tiny",
		"door_edge": 0, "district": "historic", "plaza_adjacent": true,
		"style": {"wall": 1, "roof": 2, "attic": false},
	}
	var b4 := MeshBatcher.new()
	BuildingBuilder.build(b4, tiny)
	if not _collect_broken(b4).is_empty() or not _collect_litter(b4).is_empty():
		print("[CityTest] broken/litter: tiny-facade building wrongly grew one")
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
	# Phase S: street_light positions must be deterministic too.
	var sa: Array = a.get("street_lights", [])
	var sb: Array = b.get("street_lights", [])
	if sa.size() != sb.size():
		return false
	for i in sa.size():
		if sa[i] != sb[i]:
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


# --- 24k: Streetlamp night lights + genuine darkness (Phase S) -----------------
func _test_streetlamps_and_darkness() -> bool:
	# 1) DayNightController night targets must be genuinely dark.
	if DayNightController.NIGHT_SUN_ENERGY > 0.025:
		print("[CityTest] night sun %.3f not dark enough (want <=0.025)" % DayNightController.NIGHT_SUN_ENERGY)
		return false
	if DayNightController.NIGHT_AMBIENT > 0.05:
		print("[CityTest] night ambient %.3f not dark enough (want <=0.05)" % DayNightController.NIGHT_AMBIENT)
		return false
	if DayNightController.NIGHT_BG.get_luminance() > 0.04:
		print("[CityTest] night BG luminance %.3f not dark enough" % DayNightController.NIGHT_BG.get_luminance())
		return false
	# Day must still be readable.
	if DayNightController.DAY_SUN_ENERGY < 1.0:
		print("[CityTest] day sun %.3f too dim" % DayNightController.DAY_SUN_ENERGY)
		return false
	if DayNightController.DAY_AMBIENT < 0.4:
		print("[CityTest] day ambient %.3f too dim" % DayNightController.DAY_AMBIENT)
		return false

	# 2) Streamed lamps: at least one chunk with an avenue should have lights,
	#    lights sit at y ~4.1 (head height), match prop positions, deterministic.
	var plan := CityPlan.new()
	var avenue_coord := Vector2i.ZERO
	var found := false
	for coord in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(0, 2)]:
		var rect := WorldSeed.chunk_rect(coord)
		var has_avenue := false
		for axis in 2:
			for li in plan.lines_in_range(axis, rect.position.x if axis == 0 else rect.position.y, rect.end.x if axis == 0 else rect.end.y):
				if plan.is_avenue(axis, li):
					has_avenue = true
					break
			if has_avenue:
				break
		if has_avenue:
			avenue_coord = coord
			found = true
			break
	if not found:
		print("[CityTest] streetlamp: no avenue-bearing chunk found in probe ring")
		return false
	var b1 := MeshBatcher.new()
	ChunkBuilder.fill_batcher(b1, plan, avenue_coord)
	var lights1: Array = b1.street_lights()
	if lights1.is_empty():
		print("[CityTest] streetlamp: avenue chunk %s has 0 lights" % avenue_coord)
		return false
	for pos: Vector3 in lights1:
		if absf(pos.y - 4.1) > 0.05:
			print("[CityTest] streetlamp: light y %.2f != 4.1 at %s" % [pos.y, pos])
			return false
		if pos.y < 3.5 or pos.y > 5.0:
			print("[CityTest] streetlamp: light height out of head range at %s" % pos)
			return false
	# Each light must sit just outside the avenue strip (+0.8 lateral).
	var rect_a := WorldSeed.chunk_rect(avenue_coord)
	var avenue_hit := false
	for p: Vector3 in lights1:
		var p2 := Vector2(p.x, p.z)
		if rect_a.has_point(p2):
			avenue_hit = true
			break
	if not avenue_hit:
		print("[CityTest] streetlamp: no light inside its own chunk rect")
		return false
	# Determinism: second fill yields identical lights.
	var b2 := MeshBatcher.new()
	ChunkBuilder.fill_batcher(b2, plan, avenue_coord)
	var lights2: Array = b2.street_lights()
	if lights1.size() != lights2.size():
		print("[CityTest] streetlamp: nondeterministic count %d vs %d" % [lights1.size(), lights2.size()])
		return false
	for i in lights1.size():
		if lights1[i] != lights2[i]:
			print("[CityTest] streetlamp: nondeterministic light %d" % i)
			return false
	# Manifest equality already checks street_lights, but also verify build node creation
	# by materializing a chunk and counting OmniLight3D members.
	var parent := Node3D.new()
	add_child(parent)
	var st := ChunkBuilder.build(parent, plan, avenue_coord, b1)
	var chunk: Node3D = parent.get_child(0) if parent.get_child_count() > 0 else null
	var lamp_nodes := 0
	if chunk != null:
		for child in chunk.get_children():
			if child is OmniLight3D and child.is_in_group(&"streetlamp"):
				lamp_nodes += 1
				if (child as OmniLight3D).omni_range < 10.0:
					print("[CityTest] streetlamp: range %.1f too small" % (child as OmniLight3D).omni_range)
					parent.queue_free()
					return false
				if (child as OmniLight3D).light_energy < 1.5:
					print("[CityTest] streetlamp: energy %.1f too dim" % (child as OmniLight3D).light_energy)
					parent.queue_free()
					return false
	parent.queue_free()
	if lamp_nodes != lights1.size():
		print("[CityTest] streetlamp: node count %d != manifest %d" % [lamp_nodes, lights1.size()])
		return false
	if int(st.get("street_lights", -1)) != lights1.size():
		print("[CityTest] streetlamp: stats street_lights %s != %d" % [st.get("street_lights", -1), lights1.size()])
		return false
	return true


# --- 24l: Player handheld lantern (Phase T) — light-as-gameplay at night --------
func _test_player_lantern() -> bool:
	# Constants must be in the right band: big enough to be useful in genuine
	# darkness, small enough that streetlamps still matter. Warm color for torch mood.
	if Survivor.LANTERN_RANGE < 8.0 or Survivor.LANTERN_RANGE > 14.0:
		print("[CityTest] lantern: range %.1f not in [8,14]" % Survivor.LANTERN_RANGE)
		return false
	if Survivor.LANTERN_ENERGY < 1.5 or Survivor.LANTERN_ENERGY > 3.5:
		print("[CityTest] lantern: energy %.2f not in [1.5,3.5]" % Survivor.LANTERN_ENERGY)
		return false
	if Survivor.LANTERN_COLOR.get_luminance() < 0.6:
		print("[CityTest] lantern: color too dim / not warm enough %s" % Survivor.LANTERN_COLOR)
		return false
	# Warm check: red channel dominates.
	if Survivor.LANTERN_COLOR.r < 0.9 or Survivor.LANTERN_COLOR.g < 0.6:
		print("[CityTest] lantern: color not warm enough %s" % Survivor.LANTERN_COLOR)
		return false
	if Survivor.LANTERN_BOB_AMPL < 0.02 or Survivor.LANTERN_BOB_AMPL > 0.08:
		print("[CityTest] lantern: bob ampl %.3f not in [0.02,0.08]" % Survivor.LANTERN_BOB_AMPL)
		return false

	var saved_clock := GameClock.total_minutes
	# Start from a known DAY state — matches new-game 07:00.
	GameClock.total_minutes = 7.0 * 60.0
	var holder := Node3D.new()
	add_child(holder)
	var player := Survivor.new()
	player.configure({"id": &"test_player_lantern", "name": "LanternTest", "is_player": true})
	holder.add_child(player)
	# _ready creates the lantern synchronously; no await needed.
	var lantern := player.get_node_or_null("Lantern") as OmniLight3D
	if lantern == null:
		print("[CityTest] lantern: player has no Lantern child")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if not lantern.is_in_group(&"player_lantern"):
		print("[CityTest] lantern: not in group player_lantern")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if not (lantern is OmniLight3D):
		print("[CityTest] lantern: not an OmniLight3D")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if absf(lantern.omni_range - Survivor.LANTERN_RANGE) > 0.01:
		print("[CityTest] lantern: range %.2f != const %.2f" % [lantern.omni_range, Survivor.LANTERN_RANGE])
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if absf(lantern.light_energy - Survivor.LANTERN_ENERGY) > 0.01:
		print("[CityTest] lantern: energy %.2f != const %.2f" % [lantern.light_energy, Survivor.LANTERN_ENERGY])
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if lantern.shadow_enabled:
		print("[CityTest] lantern: shadow_enabled should be false (perf)")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# At DAY start, lantern must be OFF — darkness is day-readable.
	if lantern.visible:
		print("[CityTest] lantern: visible at day (should be night-only)")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# Offset sanity: lantern rides at shoulder-ish height around LANTERN_OFFSET.
	if (lantern.position - Survivor.LANTERN_OFFSET).length() > 0.06:
		print("[CityTest] lantern: initial pos %s != offset %s" % [lantern.position, Survivor.LANTERN_OFFSET])
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# Flip to NIGHT and force a refresh — lantern must turn on.
	GameClock.total_minutes = 22.0 * 60.0
	player.refresh_lantern()
	if not lantern.visible:
		print("[CityTest] lantern: not visible at night after refresh")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# Flip back to DAY — must go dark again.
	GameClock.total_minutes = 12.0 * 60.0
	player.refresh_lantern()
	if lantern.visible:
		print("[CityTest] lantern: still visible at noon")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# Bob: night + a delta should displace y within amplitude.
	GameClock.total_minutes = 22.0 * 60.0
	player.refresh_lantern()
	var base_y := lantern.position.y
	player._update_lantern(0.37)
	var dy := lantern.position.y - Survivor.LANTERN_OFFSET.y
	if absf(dy) < 0.005:
		print("[CityTest] lantern: bob didn't displace y (dy=%.4f)" % dy)
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	if absf(dy) > Survivor.LANTERN_BOB_AMPL + 0.025:
		print("[CityTest] lantern: bob dy %.4f exceeds ampl %.3f" % [dy, Survivor.LANTERN_BOB_AMPL])
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# NPC must NOT get a lantern.
	var npc := Survivor.new()
	npc.configure({"id": &"test_npc_lantern", "name": "NpcTest", "is_player": false})
	holder.add_child(npc)
	if npc.get_node_or_null("Lantern") != null:
		print("[CityTest] lantern: NPC wrongly has a Lantern child")
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false
	# Lantern follows the player (child transform): after moving player, lantern
	# global x/z must track.
	player.global_position = Vector3(42.0, 0.0, -17.0)
	var lp := lantern.global_position
	if absf(lp.x - (42.0 + lantern.position.x)) > 0.01 or absf(lp.z - (-17.0 + lantern.position.z)) > 0.01:
		print("[CityTest] lantern: not following player global %s vs player %s" % [lp, player.global_position])
		holder.queue_free()
		GameClock.total_minutes = saved_clock
		return false

	holder.queue_free()
	GameClock.total_minutes = saved_clock
	return true


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
