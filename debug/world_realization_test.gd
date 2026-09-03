extends Node
## Focused realized-world integration regression.
##
##   godot --headless --path . -- --worldrealizationtest
##
## Exercises ChunkManager's real worker-build + scene-materialization seam,
## rather than accepting WorldPlan dictionaries as proof.

const SPAWN_KINDS: Array[StringName] = [
	&"city_center", &"hamlet", &"quarry", &"river_bank", &"forest",
]

var failures := 0

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[WorldRealization] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run()
	print("[WorldRealization] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[WorldRealization] PASS: %s" % label)
	else:
		failures += 1
		print("[WorldRealization] FAIL: %s%s" % [label, " -- " + detail if detail != "" else ""])

func _run() -> void:
	var city := CityPlan.new()
	var world := WorldPlan.new(city.seed_used)
	_check("WorldPlan exposes authoritative outdoor surface", world.has_method(&"surface_height_at"))
	_check("WorldPlan exposes chunk composition", world.has_method(&"chunk_composition"))
	if not world.has_method(&"surface_height_at") or not world.has_method(&"chunk_composition"):
		return
	for kind in SPAWN_KINDS:
		await _probe_spawn(kind, world, city)

func _probe_spawn(kind: StringName, world: WorldPlan, city: CityPlan) -> void:
	var spawn: Vector3 = SpawnPoints.get_spawn_position(kind, world, city)
	var p := Vector2(spawn.x, spawn.z)
	var coord := WorldSeed.chunk_coord(spawn.x, spawn.z)
	var composition: Dictionary = world.chunk_composition(coord)
	var surface_y: float = world.surface_height_at(p)
	_check("%s has a WorldPlan composition" % kind, not composition.is_empty(), str(coord))
	_check("%s spawn is plan-derived" % kind,
		absf(spawn.y - (surface_y + WorldConstants.SPAWN_FEET_CLEARANCE_M)) <= 0.12,
		"spawn %.3f surface %.3f" % [spawn.y, surface_y])
	_check("%s spawn is dry" % kind, world.water_body_at(p) == &"", str(world.water_body_at(p)))

	var manager := ChunkManager.new()
	add_child(manager)
	manager.setup_world(city, world)
	# Drive the exact worker/materialization seam below; disable the unrelated
	# streaming timer so it cannot replace the fixture with the sentinel ring.
	manager.set_process(false)
	var threaded_composition: Dictionary = _thread_composition(manager, coord)
	_check("%s worker composition matches WorldPlan" % kind,
		str(threaded_composition) == str(composition),
		"thread=%s plan=%s" % [threaded_composition, composition])
	await _materialize(manager, coord, true)

	_check("%s spawn chunk materialized" % kind, manager._chunks.has(coord), str(coord))
	if manager._chunks.has(coord):
		var rec: Dictionary = manager._chunks[coord] as Dictionary
		var city_materialized: bool = bool(rec.get("city_materialized", false))
		if kind == &"city_center":
			_check("city keeps bounded urban fabric", city_materialized and _ring_total(manager, "buildings") > 0,
				"city=%s buildings=%s" % [city_materialized, _ring_total(manager, "buildings")])
		else:
			_check("%s excludes dense city fabric" % kind,
				not city_materialized and _ring_total(manager, "buildings") == 0,
				"city=%s buildings=%s" % [city_materialized, _ring_total(manager, "buildings")])
		if kind == &"hamlet":
			_check("hamlet has realized rural settlement geometry", _ring_total(manager, "rural_buildings") > 0,
				str(_ring_total(manager, "rural_buildings")))
		elif kind == &"quarry":
			_check("quarry has physical excavation evidence", bool(rec.get("quarry_feature", false)) and float(rec.get("quarry_excavation_depth", 0.0)) > 0.5,
				str(rec.get("quarry_excavation_depth", 0.0)))
		elif kind == &"river_bank":
			_check("river bank has water within its streamed ring", _ring_total(manager, "water_vertices") > 0,
				str(_ring_total(manager, "water_vertices")))
		elif kind == &"forest":
			_check("forest has realized biome dressing", _ring_total(manager, "biome_instances") > 0,
				str(_ring_total(manager, "biome_instances")))

		var verified: Dictionary = manager.verify_spawn_surface(spawn)
		_check("%s walkable surface collision verifies" % kind, bool(verified.get("ok", false)), str(verified))
		if bool(verified.get("ok", false)):
			_check("%s feet match verified ground" % kind,
				absf(float(verified.get("feet_y", -999.0)) - float(verified.get("surface_y", 999.0))) <= 0.35,
				str(verified))
			_check("%s capsule clears structural collision" % kind,
				not bool(verified.get("structural_overlap", true)), str(verified))
			_check("%s has no duplicate primary ground at feet" % kind,
				not bool(verified.get("duplicate_ground", true)), str(verified))

	# A real unload removes the nodes, then the exact chunk rebuild must retain
	# the same WorldPlan composition and realized-surface contract.
	var before: Dictionary = manager._chunks.get(coord, {}).duplicate(true) as Dictionary
	manager._unload_far({}, coord + Vector2i(16, 16))
	await get_tree().process_frame
	await get_tree().physics_frame
	_check("%s spawn chunk unloads" % kind, not manager._chunks.has(coord), str(coord))
	await _materialize(manager, coord, false)
	var after: Dictionary = manager._chunks.get(coord, {}) as Dictionary
	_check("%s reload preserves composition" % kind,
		str(before.get("composition", {})) == str(after.get("composition", {})),
		"before=%s after=%s" % [before.get("composition", {}), after.get("composition", {})])
	manager.queue_free()
	await get_tree().process_frame

func _thread_composition(manager: ChunkManager, coord: Vector2i) -> Dictionary:
	var batcher := MeshBatcher.new()
	var holder: Dictionary = {
		"terrain": {}, "water": {}, "biome": {}, "road": {}, "rural": {},
		"terrain_gen_ms": 0.0, "water_gen_ms": 0.0, "biome_gen_ms": 0.0,
		"road_gen_ms": 0.0, "rural_gen_ms": 0.0,
	}
	manager._thread_build(batcher, coord, holder, manager.world_plan.seed_used)
	return holder.get("composition", {}) as Dictionary

func _materialize(manager: ChunkManager, center: Vector2i, ring: bool) -> void:
	var coords: Array[Vector2i] = [center]
	if ring:
		coords = []
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				coords.append(center + Vector2i(dx, dz))
	for coord in coords:
		var composition: Dictionary = manager.world_plan.chunk_composition(coord)
		var batcher := MeshBatcher.new()
		if bool(composition.get("city_materialized", false)):
			ChunkBuilder.fill_batcher(batcher, manager.plan, coord)
		var terrain_manifest: Dictionary = TerrainChunkBuilder.build_manifest(manager.world_plan, coord)
		var water_manifest: Dictionary = WaterChunkBuilder.build_manifest(manager.world_plan, coord)
		var biome_manifest: Dictionary = BiomeChunkBuilder.build_manifest(manager.world_plan, coord)
		var road_manifest: Dictionary = RoadChunkBuilder.build_manifest(manager.world_plan, coord)
		var rural_manifest: Dictionary = RuralBuildingChunkBuilder.build_manifest(manager.world_plan, coord)
		manager._materialize(coord, batcher, terrain_manifest, 0.0, center,
			float(terrain_manifest.get("terrain_gen_ms", 0.0)), water_manifest, float(water_manifest.get("water_gen_ms", 0.0)),
			biome_manifest, float(biome_manifest.get("biome_gen_ms", 0.0)), road_manifest, float(road_manifest.get("road_gen_ms", 0.0)),
			rural_manifest, float(rural_manifest.get("rural_gen_ms", 0.0)),
			{}, 0.0, composition)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

func _ring_total(manager: ChunkManager, field: String) -> int:
	var total := 0
	for rec_variant in manager._chunks.values():
		var rec: Dictionary = rec_variant as Dictionary
		total += int(rec.get(field, 0))
	return total
