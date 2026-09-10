extends Node
## Focused regression gate for streamed-city stability and frame pacing.
##
## --streamingregressiontest intentionally boots without the normal city scene
## so it can isolate stale roster cleanup and completed-job scheduling.

var failures := 0


class CountingChunkManager extends ChunkManager:
	var materialized_coords: Array[Vector2i] = []

	func _materialize(coord: Vector2i, _batcher: MeshBatcher,
			_terrain_manifest: Dictionary, _gen_ms: float, _pc: Vector2i,
			_terrain_gen_ms: float = 0.0, _water_manifest: Dictionary = {},
			_water_gen_ms: float = 0.0, _biome_manifest: Dictionary = {},
			_biome_gen_ms: float = 0.0, _road_manifest: Dictionary = {},
			_road_gen_ms: float = 0.0, _rural_manifest: Dictionary = {},
			_rural_gen_ms: float = 0.0, _fringe_manifest: Dictionary = {},
			_fringe_gen_ms: float = 0.0, _composition: Dictionary = {},
			_cave_manifest: Dictionary = {}, _cave_gen_ms: float = 0.0,
			_vertical_manifest: Dictionary = {}, _vertical_gen_ms: float = 0.0) -> void:
		materialized_coords.append(coord)


func _ready() -> void:
	_run()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--collision-cost-only"):
		_test_streaming_performance()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--streaming-performance-only"):
		_test_streaming_performance()
		_test_building_query_index()
		_test_road_clearance_broad_phase()
		_test_city_snapshot_leases()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--pavement-runtime-only"):
		_test_pavement_runtime()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--world-construction-only"):
		_test_world_construction_concurrency()
		_finish()
		return
	if OS.get_cmdline_user_args().has("--urban-geometry-only"):
		_test_urban_geometry()
		_finish()
		return
	_test_despawn_tolerates_a_freed_zombie()
	_test_completed_jobs_do_not_materialize_as_a_burst()
	_test_city_snapshot_leases()
	_test_world_construction_concurrency()
	_test_city_boundary_admission()
	_test_basin_grading()
	_test_urban_geometry()
	_finish()


func _test_building_query_index() -> void:
	var city := CityPlan.new(19041208)
	city._generated = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 73612
	for i in 200:
		city._all_buildings.append({"id": "query_%04d" % i,
			"rect": Rect2(Vector2(rng.randf_range(-400, 400), rng.randf_range(-400, 400)), Vector2(16, 27)),
			"yaw": rng.randf_range(-PI, PI)})
	var exact := true
	for i in 80:
		var query := Rect2(Vector2(rng.randf_range(-400, 400), rng.randf_range(-400, 400)), Vector2(64, 96))
		var expected: Array[Dictionary] = []
		for spec in city._all_buildings:
			if CityPlan._spec_world_bounds(spec).intersects(query):
				expected.append(spec)
		exact = exact and city.buildings_in_rect(query) == expected
	_check("indexed negative-coordinate building queries exactly match exhaustive footprint scan", exact)
	var clone := city.clone_generated()
	var area := Rect2(-512, -512, 1024, 1024)
	_check("private worker query index preserves all buildings and ordering", clone.buildings_in_rect(area) == city.buildings_in_rect(area))


func _performance_fixture() -> MeshBatcher:
	var batch := MeshBatcher.new()
	for i in 6000:
		batch.push_layer("fixture_%d" % (i / 100))
		batch.add_box_rotated(Vector3((i % 100) * 2, (i / 100) * 3, -64),
			Vector3(1, 2, 0.2), Basis(Vector3.UP, 0.3 if i % 2 else 0.0),
			Color.WHITE, true, false, &"wood")
		batch.pop_layer()
	return batch


func _test_streaming_performance() -> void:
	var batch := _performance_fixture()
	var start := Time.get_ticks_usec()
	var reference := batch._build_layers()
	print("[StreamingPerf] reference mesh preparation ms=", (Time.get_ticks_usec() - start) / 1000.0)
	var task := WorkerThreadPool.add_task(batch.prepare_mesh_data)
	WorkerThreadPool.wait_for_task_completion(task)
	_check("worker mesh buffers exactly match reference vertices, normals, colors and indices", batch._prepared_layers == reference)
	var prepared_parent := Node3D.new()
	add_child(prepared_parent)
	start = Time.get_ticks_usec()
	batch.flush_into(prepared_parent)
	var prepared_ms := (Time.get_ticks_usec() - start) / 1000.0
	_check("prepared buffers released after main-thread upload", batch._prepared_layers.is_empty())
	_check("shared box resources preserve all 6000 collision cells", batch._shape_nodes.size() == 6000 and batch._box_shapes.size() == 1)
	var id_a := int(batch.specs()[0].id)
	var id_b := int(batch.specs()[1].id)
	var shape_a: CollisionShape3D = batch._shape_nodes[id_a]
	var shape_b: CollisionShape3D = batch._shape_nodes[id_b]
	_check("collision instances retain independent transforms and damage identifiers", shape_a.shape == shape_b.shape
		and shape_a.transform != shape_b.transform and shape_a.get_meta("vox_id") == id_a and shape_b.get_meta("vox_id") == id_b)
	batch.destroy_box(id_a)
	start = Time.get_ticks_usec()
	batch.disable_collision()
	print("[StreamingPerf] collision teardown ms=", (Time.get_ticks_usec() - start) / 1000.0)
	_check("warm collision is absent from both the scene and physics world", prepared_parent.get_node_or_null("Static") == null
		and batch._inactive_body != null and not batch._inactive_body.is_inside_tree()
		and not PhysicsServer3D.body_get_space(batch._inactive_body.get_rid()).is_valid())
	start = Time.get_ticks_usec()
	batch.enable_collision()
	print("[StreamingPerf] collision activation ms=", (Time.get_ticks_usec() - start) / 1000.0)
	_check("warm reactivation preserves destruction without removing neighboring cells", not batch._shape_nodes.has(id_a) and batch._shape_nodes.size() == 5999)
	batch.prepare_mesh_data()
	batch.add_visual_box(Vector3.ZERO, Vector3.ONE, Color.WHITE)
	_check("geometry additions invalidate prepared buffers", batch._prepared_layers.is_empty())
	batch.prepare_mesh_data()
	batch.destroy_box(id_b)
	_check("destruction invalidates prepared buffers", batch._prepared_layers.is_empty())
	batch.disable_collision()
	var retiring := ChunkManager.new()
	retiring._retire_collision(batch)
	_check("cold retirement transfers ownership out of the reusable batcher", batch._inactive_body == null and retiring._retired_collision_bodies.size() == 1)
	var before := retiring._retired_collision_bodies[0].get_child_count()
	retiring._dispose_retired_collision()
	_check("cold collision disposal makes bounded incremental progress", retiring._retired_collision_bodies.size() == 1
		and retiring._retired_collision_bodies[0].get_child_count() < before
		and retiring._retired_collision_bodies[0].get_child_count() > 0)
	retiring.free()
	prepared_parent.free()
	var direct := _performance_fixture()
	var direct_parent := Node3D.new()
	add_child(direct_parent)
	start = Time.get_ticks_usec()
	direct.flush_into(direct_parent)
	var direct_ms := (Time.get_ticks_usec() - start) / 1000.0
	print("[StreamingPerf] 6000 cells direct materialization ms=", direct_ms,
		" worker-prepared materialization ms=", prepared_ms)
	direct_parent.free()


func _test_pavement_runtime() -> void:
	var plan := CityPlan.new(19041208)
	print("[PavementRuntime] generating city")
	plan.city_buildings()
	var world := WorldPlan.new(19041208)
	world.city_plan = plan
	print("[PavementRuntime] city ready")
	for coord: Vector2i in [Vector2i(2, 1), Vector2i(3, -2), Vector2i(-1, -5)]:
		var batch := MeshBatcher.new()
		var start := Time.get_ticks_msec()
		print("[PavementRuntime] joining ", coord)
		ChunkBuilder._joined_pavements(batch, plan, WorldSeed.chunk_rect(coord), world)
		print("[PavementRuntime] joined ms=", Time.get_ticks_msec() - start, " polygons=", batch._polygon_specs.size())
		_check("real city pavement batch remains bounded %s" % coord, batch._polygon_specs.size() > 0 and batch._polygon_specs.size() < 4096)
		var root := Node3D.new()
		start = Time.get_ticks_msec()
		batch.flush_into(root)
		print("[PavementRuntime] materialized ms=", Time.get_ticks_msec() - start)
		root.free()


func _test_world_construction_concurrency() -> void:
	for seed_value in [19041207, 19041208, -1]:
		var holders: Array[Dictionary] = []
		var tasks: Array[int] = []
		for worker in range(6):
			var holder := {}
			holders.append(holder)
			tasks.append(WorkerThreadPool.add_task(_construct_world_probe.bind(seed_value, holder)))
		for task_id in tasks:
			WorkerThreadPool.wait_for_task_completion(task_id)
		var expected := {}
		_construct_world_probe(seed_value, expected)
		var same := true
		for holder in holders:
			same = same and holder == expected
		_check("six concurrent world constructors preserve negative-coordinate queries seed %d" % seed_value, same)


func _construct_world_probe(seed_value: int, holder: Dictionary) -> void:
	var world := WorldPlan.new(seed_value)
	holder["seed"] = world.seed_used
	holder["height"] = world.terrain_height_at(Vector2(-128, -64))
	holder["composition"] = world.chunk_composition(Vector2i(-2, -1))


func _test_urban_geometry() -> void:
	_test_pavement_connectors()
	_test_pavement_front_faces()
	_test_raised_window_validation()
	_test_placement_index()
	_test_no_motorcars()
	_test_street_owned_pavement()
	_test_splitter_crosses_face()
	_test_small_perimeter_access()
	_test_passage_frontage_rows()
	_test_oriented_overlap_broad_phase()
	_test_frontage_anchor()
	_test_interior_coordinate_adapter()
	_test_road_clearance_broad_phase()
	_test_parcel_seed_isolation()
	_test_rear_courtyard_with_front_setbacks()
	_test_frontage_packing()
	_test_interior_road_subtraction()
	_test_civic_land_requires_a_node()
	_test_concave_block_anchor()


func _test_pavement_front_faces() -> void:
	var batch := MeshBatcher.new()
	batch.push_layer("street_pavement")
	batch.add_visual_polygon_heights(PackedVector2Array([Vector2(-2, -2), Vector2(2, -2), Vector2(2, 2), Vector2(-2, 2)]),
		PackedFloat32Array([0.15, 0.2, 0.2, 0.15]), Color.WHITE)
	batch.pop_layer()
	var buffer: Dictionary = batch._build_layers()["street_pavement"]
	var valid: bool = buffer.verts.size() == 4 and buffer.idx.size() == 6
	for i in range(0, buffer.idx.size(), 3):
		var a: Vector3 = buffer.verts[buffer.idx[i]]
		var b: Vector3 = buffer.verts[buffer.idx[i + 1]]
		var c: Vector3 = buffer.verts[buffer.idx[i + 2]]
		valid = valid and (b - a).cross(c - a).y < 0.0
	_check("pavement mesh retains vertices and clockwise upward-visible faces", valid)


func _test_raised_window_validation() -> void:
	# A solid box below a raised window is not an aperture obstruction;
	# the same box moved to the actual window height must still be rejected.
	var spec := {"id": "raised_aperture", "rect": Rect2(-20, -20, 12, 16),
		"floors": 1, "floor_h": 3.0, "door_edge": 2, "building_ground_y": 8.0}
	var opening: Dictionary = BuildingSpec.city_window_openings(12.0, false)[0]
	for raised in [false, true]:
		var batch := MeshBatcher.new()
		batch.register_contract_building("raised_aperture", spec)
		batch.push_layer("raised_aperture")
		batch.add_box(Vector3(-20 + float(opening.c), float(opening.bot) + float(opening.h) * 0.5 + (8.0 if raised else 0.0), -20),
			Vector3(float(opening.wd) + 0.1, float(opening.h), 0.4), Color.WHITE, true)
		batch.pop_layer()
		var blocked := false
		for error in BuildingContractValidator.validate_build(spec, batch):
			blocked = blocked or error.begins_with("solid geometry behind window")
		_check("raised window validation tests actual foundation datum obstruction=%s" % raised, blocked == raised)


func _test_pavement_connectors() -> void:
	var pavement = preload("res://world/generation/pavement_plan.gd")
	# Offset from the chunk seam so a four-way carriageway does not consume
	# the entire seam; the test must exercise actual pavement on both sides.
	var center := Vector2(-60, -32)
	for count in [2, 3, 4]:
		var edges: Array[Dictionary] = []
		var directions := [Vector2.RIGHT, Vector2.UP, Vector2.LEFT, Vector2.DOWN]
		for i in count:
			edges.append({"id": "arm_%d" % i, "width": 6.0,
				"polyline": PackedVector2Array([center, center + directions[i] * 40.0])})
		var query := Rect2(center - Vector2(20, 20), Vector2(40, 40))
		var connectors: Array = pavement.connectors(edges, query)
		_check("negative-coordinate %d-way pavement connector exists" % count,
			connectors.size() == 1 and connectors[0].kind == "connector_%dway" % count)
		if connectors.is_empty():
			continue
		var clear: bool = not connectors[0].polygons.is_empty()
		for polygon: PackedVector2Array in connectors[0].polygons:
			clear = clear and not Geometry2D.triangulate_polygon(polygon).is_empty()
			for edge in edges:
				var road := CityPlan._road_strip_polygon(edge.polyline[0], edge.polyline[1], 3.0)
				for overlap in Geometry2D.intersect_polygons(polygon, road):
					clear = clear and CityPlan._polygon_area(overlap) < 0.01
		_check("%d-way connector is triangulatable and leaves carriageways clear" % count, clear)
		edges.reverse()
		_check("%d-way connectors are independent of query order" % count, connectors == pavement.connectors(edges, query))
		var plan := CityPlan.new(19041208)
		plan._generated = true
		plan._city_edges = edges
		var joined := MeshBatcher.new()
		ChunkBuilder._joined_pavements(joined, plan, query)
		_check("%d-way joined pavement emits a bounded surface batch" % count,
			not joined._polygon_specs.is_empty() and joined._polygon_specs.size() < 1000)
		var disjoint := true
		for i in joined._polygon_specs.size():
			var first: PackedVector2Array = joined._polygon_specs[i].points
			for j in range(i + 1, joined._polygon_specs.size()):
				var second: PackedVector2Array = joined._polygon_specs[j].points
				if not pavement.bounds(first).intersects(pavement.bounds(second)):
					continue
				for overlap in Geometry2D.intersect_polygons(first, second):
					disjoint = disjoint and CityPlan._polygon_area(overlap) < 0.001
		_check("%d-way pavement patches do not overlap after joining" % count, disjoint)
		var left := MeshBatcher.new()
		var right := MeshBatcher.new()
		ChunkBuilder._joined_pavements(left, plan, Rect2(-128, -64, 64, 64))
		ChunkBuilder._joined_pavements(right, plan, Rect2(-64, -64, 64, 64))
		var seam_left: Array = []
		var seam_right: Array = []
		for pair in [[left, seam_left], [right, seam_right]]:
			for surface: Dictionary in pair[0]._polygon_specs:
				for i in surface.points.size():
					var point: Vector2 = surface.points[i]
					if absf(point.x + 64.0) < 0.0001:
						var vertex := Vector2(snappedf(point.y, 0.001), surface.heights[i])
						if not pair[1].has(vertex):
							pair[1].append(vertex)
		seam_left.sort()
		seam_right.sort()
		_check("%d-way pavement shares identical vertices and heights across negative chunk seam" % count,
			not seam_left.is_empty() and seam_left == seam_right)
	for yaw in [0.0, 0.47, -1.1]:
		var rect := Rect2(-78, -50, 12, 10)
		var corners := CityPlan._lot_corners(rect, yaw)
		var front := (corners[0] + corners[1]) * 0.5
		var outward := (front - rect.get_center()).normalized()
		var spec := {"rect": rect, "yaw": yaw, "door_edge": 0, "frontage_center": front + outward * 3.0}
		var patches: Array = pavement.building_contact_polygons(spec)
		var touches := false
		var reaches_frontage := false
		var clear := true
		for polygon: PackedVector2Array in patches:
			touches = touches or Geometry2D.is_point_in_polygon(front + outward * 0.001, polygon)
			reaches_frontage = reaches_frontage or Geometry2D.is_point_in_polygon(front + outward * 2.999, polygon)
			for overlap in Geometry2D.intersect_polygons(polygon, corners):
				clear = clear and CityPlan._polygon_area(overlap) < 0.01
		_check("oriented building pavement touches facade without entering footprint yaw %.2f" % yaw, touches and clear)
		_check("oriented building pavement reaches recorded street frontage yaw %.2f" % yaw, reaches_frontage)
	for seed_value in [19041207, 19041208, -1]:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_value
		var angle := rng.randf_range(-PI, PI)
		var first := Vector2.RIGHT.rotated(angle) * 40.0
		var second := Vector2.RIGHT.rotated(angle + 1.2) * 40.0
		var edges: Array[Dictionary] = [
			{"id": "cross_a", "width": 6.0, "polyline": PackedVector2Array([center - first, center + first])},
			{"id": "cross_b", "width": 4.0, "polyline": PackedVector2Array([center - second, center + second])}]
		var query := Rect2(center - Vector2(20, 20), Vector2(40, 40))
		var connectors: Array = pavement.connectors(edges, query)
		edges.reverse()
		_check("skew crossing derives four-way connector without endpoint node seed %d" % seed_value,
			connectors.size() == 1 and connectors[0].kind == "connector_4way"
			and connectors == pavement.connectors(edges, query))


func _test_placement_index() -> void:
	var plan := CityPlan.new(19041208)
	var rng := RandomNumberGenerator.new()
	rng.seed = 82173
	var agrees := true
	for i in range(200):
		var center := Vector2(rng.randf_range(-150, 150), rng.randf_range(-150, 150))
		var lot := Rect2(center, Vector2(rng.randf_range(5, 24), rng.randf_range(5, 24)))
		var yaw := rng.randf_range(-PI, PI)
		var exhaustive := false
		for existing in plan._all_buildings:
			if CityPlan._lots_overlap(lot, yaw, existing["rect"], existing["yaw"], 0.22):
				exhaustive = true
		agrees = agrees and plan._city_lot_overlaps_existing(lot, yaw) == exhaustive
		plan._all_buildings.append({"rect": lot, "yaw": yaw})
	_check("placement index matches exhaustive SAT during incremental negative-coordinate placement", agrees)


func _test_no_motorcars() -> void:
	var plan := CityPlan.new(19041208)
	plan._generated = true
	plan._city_edges.append({"id": "car_regression_street", "width": 6.0,
		"polyline": PackedVector2Array([Vector2(-256, 0), Vector2(256, 0)])})
	var clear := true
	for x in range(-3, 4):
		var batcher := MeshBatcher.new()
		var coord := Vector2i(x, 0)
		ChunkBuilder._scatter_props(batcher, plan, WorldSeed.chunk_rect(coord), coord)
		clear = clear and batcher.props().is_empty()
	_check("streamed streets emit no motorcars", clear)
	var fallback := Node3D.new()
	LevelBuilder._build_props(fallback)
	_check("fallback level emits no motorcars", fallback.find_children("Car*", "", true, false).is_empty())
	fallback.free()


func _test_street_owned_pavement() -> void:
	var edge := {"id": "street", "width": 6.0}
	var streets: Array[Dictionary] = [edge]
	var batcher := MeshBatcher.new()
	ChunkBuilder._emit_street_pavements(batcher, edge, streets, Vector2(-64, -32), 4.0, 2.0, 6.0, Basis.IDENTITY)
	_check("street owns two pavements and curbs without needing a block polygon", batcher.specs().size() == 4)
	var other := {"id": "crossing", "width": 6.0,
		"polyline_clipped": PackedVector2Array([Vector2(-80, -32), Vector2(-48, -32)])}
	streets.append(other)
	var junction := MeshBatcher.new()
	ChunkBuilder._emit_street_pavements(junction, edge, streets, Vector2(-64, -32), 4.0, 2.0, 6.0, Basis.IDENTITY)
	_check("pavements leave intersecting carriageways open", junction.specs().is_empty())


func _test_passage_frontage_rows() -> void:
	var plan := CityPlan.new(19041207)
	plan._ensure_support_plans()
	var poly := CityPlan._rect_polygon(Rect2(-40, -40, 80, 80))
	var passage := {"road_connected": true, "entry_point": Vector2(0, -35),
		"direction": Vector2.DOWN, "width": 3.0,
		"polygon": CityPlan._rect_polygon(Rect2(-1.5, -35, 3, 60))}
	var block := {"id": "passage_fixture", "cell": Vector2i.ZERO, "kind": &"built",
		"district": CityPlan.DISTRICT_HISTORIC, "passage": passage}
	var lots: Array[Dictionary] = []
	plan._append_passage_side_lots(lots, block, poly, 0.0, 24)
	_check("passage frontage fills more than two rows", lots.size() >= 8)
	var valid := not lots.is_empty()
	for spec in lots:
		var rect: Rect2 = spec["rect"]
		valid = valid and is_equal_approx(float(spec.get("yaw", 0.0)), PI * 0.5)
		valid = valid and int(spec.get("door_edge", -1)) == (0 if rect.get_center().x < 0.0 else 2)
		valid = valid and not plan._lot_overlaps_passage(rect, float(spec.get("yaw", 0.0)), passage)
		var doors: Array = spec.get("doors", []) as Array
		valid = valid and not doors.is_empty()
		if not doors.is_empty():
			var door_position: Vector3 = doors[0].get("position", Vector3.ZERO)
			valid = valid and absf(door_position.x) < 2.5
	_check("passage parcels face the lane and leave it clear", valid)


func _test_small_perimeter_access() -> void:
	for seed_value in [19041207, 19041208, -1]:
		var plan := CityPlan.new(seed_value)
		plan._city_edges.append({"id": "front_street", "width": 5.0,
			"polyline": PackedVector2Array([Vector2(-10, -5), Vector2(50, -5)])})
		var block := {"polygon": CityPlan._rect_polygon(Rect2(0, 0, 40, 40)),
			"rect": Rect2(0, 0, 40, 40), "district": CityPlan.DISTRICT_HISTORIC}
		for index in range(8):
			var passage := plan._passage_for_block(block, index)
			_check("normal historic perimeter court has street access seed %d block %d" % [seed_value, index],
				bool(passage.get("road_connected", false)))


func _test_splitter_crosses_face() -> void:
	for seed_value in [19041207, 19041208, -1]:
		var plan := CityPlan.new(seed_value)
		plan._add_city_node("first", Vector2(-20, 0), &"local")
		plan._add_city_node("same_side", Vector2(-21, 2), &"local")
		plan._add_city_node("opposite", Vector2(35, 8), &"local")
		var first := plan._nearest_splitter_anchor(Vector2.ZERO, "center")
		var second := plan._nearest_splitter_anchor(Vector2.ZERO, "center", first)
		_check("block lane connects opposite streets seed %d" % seed_value,
			first == "first" and second == "opposite")


func _test_concave_block_anchor() -> void:
	var plan := CityPlan.new(19041207)
	var polygon := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 40),
		Vector2(30, 40), Vector2(30, 10), Vector2(10, 10), Vector2(10, 40), Vector2(0, 40)])
	var rect := plan._safe_block_rect(polygon, Rect2(0, 0, 40, 40))
	_check("concave road-cut face retains an interior parcel anchor",
		Geometry2D.is_point_in_polygon(rect.get_center(), polygon) and minf(rect.size.x, rect.size.y) >= 6.0)


func _test_civic_land_requires_a_node() -> void:
	var plan := CityPlan.new(19041207)
	var ordinary := PackedVector2Array([Vector2(350, 0), Vector2(450, 0), Vector2(450, 100), Vector2(350, 100)])
	_check("large ordinary urban block is not automatically a park", plan._civic_kind_for(Vector2(400, 50), ordinary) == &"")
	plan._add_landmark("market", Vector2.ZERO, &"market_square", 34.0)
	var square := PackedVector2Array([Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20)])
	_check("bounded market node still produces civic space", plan._civic_kind_for(Vector2.ZERO, square) == &"plaza")


func _test_interior_road_subtraction() -> void:
	var plan := CityPlan.new(19041207)
	plan._city_edges.append({"width": 2.0, "polyline": PackedVector2Array([Vector2(-2, 0), Vector2(2, 0)])})
	var polygon := PackedVector2Array([Vector2(-10, -10), Vector2(10, -10), Vector2(10, 10), Vector2(-10, 10)])
	var pieces := plan._road_subtracted_pieces({"polygon": polygon, "bounds": Rect2(-10, -10, 20, 20)})
	var ribbon := plan._road_strip_polygon(Vector2(-2, 0), Vector2(2, 0), 3.4)
	var remaining := 0.0
	var intrusion := 0.0
	for piece in pieces:
		remaining += CityPlan._polygon_area(piece)
		for overlap in Geometry2D.intersect_polygons(piece, ribbon):
			intrusion += CityPlan._polygon_area(overlap)
	_check("interior road cut conserves buildable area without treating holes as blocks",
		absf(remaining - (400.0 - CityPlan._polygon_area(ribbon))) < 0.01)
	_check("road-subtracted block pieces exclude the full carriageway", intrusion < 0.01)


func _test_frontage_packing() -> void:
	var filled := true
	for length in [12.0, 24.0, 40.0, 64.0, 100.0, 180.0]:
		var count := CityPlan._frontage_piece_count(length, 4.8, 8.8)
		var width := minf(length / float(count) - 0.5, 8.8)
		filled = filled and width >= 4.8 and width <= 8.8
		filled = filled and float(count) * width / length >= 0.85
	_check("long street boundaries pack frontage instead of stopping at four parcels", filled)


func _test_rear_courtyard_with_front_setbacks() -> void:
	var plan := CityPlan.new(19041207)
	var buildings: Array = []
	for rect: Rect2 in [Rect2(2, 2, 15, 8), Rect2(23, 2, 15, 8), Rect2(2, 30, 36, 8),
		Rect2(2, 10, 8, 20), Rect2(30, 10, 8, 20)]:
		buildings.append({"rect": rect, "yaw": 0.0})
	var block := {"polygon": PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 40), Vector2(0, 40)]),
		"buildings": buildings, "passage": {"road_connected": true, "kind": &"historic_alley",
			"polygon": PackedVector2Array([Vector2(17, 0), Vector2(23, 0), Vector2(23, 22), Vector2(17, 22)])}}
	var regions := plan._courtyard_regions_for_block(block)
	var area := 0.0
	var clear := true
	for region: Dictionary in regions:
		area += float(region["area_m2"])
		for building: Dictionary in buildings:
			for intersection in Geometry2D.intersect_polygons(region["polygon"], CityPlan._lot_corners(building["rect"], 0.0)):
				clear = clear and CityPlan._polygon_area(intersection) < 0.01
	_check("setback perimeter block retains its accessible rear courtyard", area >= 300.0 and area <= 650.0)
	_check("rear courtyard surface never occupies a building footprint", clear and not regions.is_empty())


func _test_parcel_seed_isolation() -> void:
	var original_seed := WorldSeed.get_world_seed()
	var isolated := true
	for seed_value in [19041207, 19041208, -7919, -1]:
		var plan := CityPlan.new(seed_value)
		var block := {"id": "seed_fixture", "cell": Vector2i(-2, 3), "district": CityPlan.DISTRICT_HISTORIC, "kind": &"built"}
		WorldSeed.set_world_seed(seed_value)
		var first := plan._make_city_spec(block, Rect2(-128, -64, 10, 16), 2, 1, 0, 150, 0.43)
		WorldSeed.set_world_seed(seed_value + 991)
		var second := plan._make_city_spec(block, Rect2(-128, -64, 10, 16), 2, 1, 0, 150, 0.43)
		isolated = isolated and not first.is_empty() and var_to_str(first) == var_to_str(second)
	WorldSeed.set_world_seed(original_seed)
	_check("parcel and door manifests use instance seed independently of selected world", isolated)


func _test_road_clearance_broad_phase() -> void:
	var plan := CityPlan.new(19041207)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77621
	for i in 30:
		plan._city_edges.append({"width": rng.randf_range(3, 18),
			"polyline": PackedVector2Array([Vector2(rng.randf_range(-200, 200), rng.randf_range(-200, 200)),
				Vector2(rng.randf_range(-200, 200), rng.randf_range(-200, 200))])})
	var agrees := true
	for i in 1000:
		var lot := Rect2(Vector2(rng.randf_range(-250, 250), rng.randf_range(-250, 250)),
			Vector2(rng.randf_range(4, 30), rng.randf_range(4, 30)))
		var yaw := rng.randf_range(-PI, PI)
		var exact_clear := true
		for edge: Dictionary in plan._city_edges:
			var points: PackedVector2Array = edge["polyline"]
			if plan._segment_intersects_oriented_lot(points[0], points[1], lot, yaw, float(edge["width"]) * 0.5 + 0.8):
				exact_clear = false
				break
		agrees = agrees and exact_clear == plan._lot_clear_of_city_roads(lot, yaw)
	_check("road broad phase preserves exhaustive oriented clearance", agrees)


func _test_interior_coordinate_adapter() -> void:
	# Moving an identical parcel must translate its emitted interior once.
	# In particular, negative parcel positions must not be added twice.
	var reference: Array = []
	for offset: Vector2 in [Vector2.ZERO, Vector2(-128, -64), Vector2(96, 128)]:
		var spec := {"id": "interior_translation_fixture", "rect": Rect2(offset, Vector2(12, 16)),
			"use": "residential", "floors": 1, "floor_h": 3.0, "door_edge": 2}
		var batch := MeshBatcher.new()
		BuildingBuilder._emit_interior_partitions(batch, Vector3(offset.x, 0, offset.y),
			12, 16, 3, 1, str(spec["id"]), spec, Rect2(), false)
		var emitted := batch.specs()
		_check("interior fixture emits geometry", not emitted.is_empty())
		if offset == Vector2.ZERO:
			reference = emitted
		else:
			var matches := emitted.size() == reference.size()
			for i in mini(emitted.size(), reference.size()):
				var local: Vector3 = emitted[i]["pos"] - Vector3(offset.x, 0, offset.y)
				matches = matches and local.distance_to(reference[i]["pos"]) < 0.001
				matches = matches and (emitted[i]["size"] as Vector3).is_equal_approx(reference[i]["size"])
			_check("interiors translate exactly once at %s" % offset, matches)


func _test_frontage_anchor() -> void:
	var plan := CityPlan.new(19041207)
	# A shallow block forces a 20 m-deep parcel to yield at its rear. Repeat
	# with diagonal streets and both frontage sides at negative coordinates.
	for yaw in [0.0, 0.43, -1.2, PI * 0.5]:
		for side in [-1.0, 1.0]:
			var frontage := Vector2(-128, -64)
			var inward := CityPlan._rotate_plan_vector(Vector2(0, side), yaw)
			var block_center := frontage + inward * 5.8
			var polygon := CityPlan._lot_corners(Rect2(block_center - Vector2(8, 6.2), Vector2(16, 12.4)), yaw)
			var lot := plan._fit_frontage_lot(frontage + inward * 10.0, Vector2(8, 20), yaw, polygon, inward)
			_check("shallow oriented lot retains street frontage", lot.size.y > 0.0
				and (lot.get_center() - inward * lot.size.y * 0.5).distance_to(frontage) < 0.001)
			_check("shallow frontage stays within its irregular block", plan._lot_inside_polygon(lot, yaw, polygon))


func _test_city_boundary_admission() -> void:
	for seed_value in [19041207, 19041208, -7919]:
		var world := WorldPlan.new(seed_value)
		for coord: Vector2i in [Vector2i(15, 0), Vector2i(-16, -1), Vector2i(0, 15), Vector2i(-1, -16)]:
			_check("city admits partial boundary chunk %s seed %d" % [coord, seed_value], world.should_materialize_city(coord))
		_check("city excludes distant rural chunks", not world.should_materialize_city(Vector2i(20, 20)))


func _test_basin_grading() -> void:
	for seed_value in [19041207, 19041208, -7919]:
		var world := WorldPlan.new(seed_value)
		var varied := false
		var continuous := true
		for angle_i in 16:
			var direction := Vector2.from_angle(TAU * float(angle_i) / 16.0)
			var p := direction * 250.0
			varied = varied or absf(world.surface_height_at(p)) > 0.05
			for radius in [WorldConstants.CITY_MARKET_TERRACE_RADIUS_M, WorldConstants.URBAN_INNER_M, WorldConstants.URBAN_OUTER_M]:
				var jump := absf(world.surface_height_at(direction * (radius - 0.01))
					- world.surface_height_at(direction * (radius + 0.01)))
				# River banks can be steep. A continuous slope converges as
				# sample spacing shrinks; a datum discontinuity does not.
				var fine_jump := absf(world.surface_height_at(direction * (radius - 0.001))
					- world.surface_height_at(direction * (radius + 0.001)))
				continuous = continuous and fine_jump < 0.05 and fine_jump <= jump * 0.2 + 0.001
		_check("historic core follows basin outside civic pad seed %d" % seed_value, varied)
		_check("urban grading has no boundary height steps seed %d" % seed_value, continuous)
		_check("origin civic approach remains level", absf(world.surface_height_at(Vector2(64, 64))) < 0.01)


func _test_oriented_overlap_broad_phase() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 78123
	var agrees := true
	for i in 1000:
		var a := Rect2(Vector2(rng.randf_range(-100, 100), rng.randf_range(-100, 100)),
			Vector2(rng.randf_range(4, 30), rng.randf_range(4, 30)))
		var b := Rect2(Vector2(rng.randf_range(-100, 100), rng.randf_range(-100, 100)),
			Vector2(rng.randf_range(4, 30), rng.randf_range(4, 30)))
		var ay := rng.randf_range(-PI, PI)
		var by := rng.randf_range(-PI, PI)
		var margin := rng.randf_range(0, 1)
		var intersection := Geometry2D.intersect_polygons(CityPlan._lot_corners(a, ay, margin), CityPlan._lot_corners(b, by, margin))
		var area := 0.0
		for polygon in intersection:
			area += CityPlan._polygon_area(polygon)
		# Avoid numerically ambiguous contacts in the independent polygon oracle.
		if area > 0.001 or intersection.is_empty():
			agrees = agrees and CityPlan._lots_overlap(a, ay, b, by, margin) == (area > 0.001)
	_check("oriented overlap agrees with independent polygon intersections", agrees)


func _test_city_snapshot_leases() -> void:
	# A pre-generated fixture isolates ownership from expensive city creation.
	var city := CityPlan.new(19041207)
	city._generated = true
	city._support_ready = true
	city._city_nodes.append({"id": "fixture", "center": Vector2(-64, 0)})
	var manager := CountingChunkManager.new()
	manager.setup(city)
	_check("main world and fringe reuse the prepared city instead of generating duplicates", manager.world_plan.city_plan == city and manager.world_plan.fringe.city_plan == city)
	var ids := {}
	var world_ids := {}
	for snapshot in manager._available_city_plans:
		ids[snapshot.get_instance_id()] = true
	for worker_world in manager._available_world_plans:
		world_ids[worker_world.get_instance_id()] = true
	_check("worker snapshots are distinct and bounded", ids.size() == ChunkManager.MAX_INFLIGHT_BUILDS)
	_check("private worker worlds are distinct and bounded", world_ids.size() == ChunkManager.MAX_INFLIGHT_BUILDS)
	var lease: CityPlan = manager._available_city_plans.pop_back()
	var world_lease: WorldPlan = manager._available_world_plans.pop_back()
	_check("worker world and fringe use their paired city snapshot", world_lease.city_plan == lease and world_lease.fringe.city_plan == lease)
	lease._city_nodes[0]["center"] = Vector2(64, 0)
	_check("worker snapshot isolates nested plan data", city._city_nodes[0]["center"] == Vector2(-64, 0))
	var coord := Vector2i(20, -20)
	manager._inflight[coord] = {"task_id": -1, "city_plan_lease": lease, "world_plan_lease": world_lease}
	manager._collect_finished_jobs(Vector2i.ZERO)
	_check("stale completion returns its snapshot without materializing", manager.materialized_coords.is_empty()
		and manager._available_city_plans.size() == ids.size())
	for i in 20:
		var reused: CityPlan = manager._available_city_plans.pop_back()
		var reused_world: WorldPlan = manager._available_world_plans.pop_back()
		_check("snapshot reused without a new city copy %d" % i, ids.has(reused.get_instance_id()))
		_check("support world reused without construction %d" % i, world_ids.has(reused_world.get_instance_id()) and reused_world.city_plan == reused)
		var job := {"city_plan_lease": reused, "world_plan_lease": reused_world}
		manager._return_city_plan(job)
		manager._return_city_plan(job)
	_check("lease cannot return twice", manager._available_city_plans.size() == ids.size())
	_check("world lease cannot return twice", manager._available_world_plans.size() == world_ids.size())
	var reset_lease: CityPlan = manager._available_city_plans.pop_back()
	var reset_world: WorldPlan = manager._available_world_plans.pop_back()
	manager._inflight[coord] = {"task_id": -1, "city_plan_lease": reset_lease, "world_plan_lease": reset_world}
	manager.reset_stream()
	_check("stream reset returns outstanding snapshots", manager._available_city_plans.size() == ids.size())
	_check("stream reset returns outstanding worlds", manager._available_world_plans.size() == world_ids.size())
	manager.free()


func _test_despawn_tolerates_a_freed_zombie() -> void:
	var spawner := CitySpawner.new()
	var coord := Vector2i(2, -3)
	var dead_zombie := Zombie.new()
	spawner._live[coord] = [dead_zombie]
	dead_zombie.free()
	spawner._despawn(coord)
	_check("despawn clears a roster containing a freed zombie",
			not spawner._live.has(coord), "bucket still present after despawn")
	spawner.free()


func _test_completed_jobs_do_not_materialize_as_a_burst() -> void:
	var manager := CountingChunkManager.new()
	var player_chunk := Vector2i.ZERO
	var coords: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]
	for coord in coords:
		manager._inflight[coord] = {
			"batcher": MeshBatcher.new(),
			"terrain": {},
			"water": {},
			"biome": {},
			"task_id": -1,
			"gen_ms": 0.0,
			"terrain_gen_ms": 0.0,
			"water_gen_ms": 0.0,
			"biome_gen_ms": 0.0,
		}
	manager._collect_finished_jobs(player_chunk)
	_check("one scheduler tick materializes at most one completed chunk",
			manager.materialized_coords.size() <= 1,
			"materialized=%d" % manager.materialized_coords.size())
	manager._collect_finished_jobs(player_chunk)
	manager._collect_finished_jobs(player_chunk)
	_check("bounded scheduler eventually drains all completed chunks",
			manager.materialized_coords.size() == coords.size()
				and manager._inflight.is_empty(),
			"materialized=%d inflight=%d" % [manager.materialized_coords.size(), manager._inflight.size()])
	manager.free()


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		print("[StreamingRegression] PASS  %s" % name)
	else:
		failures += 1
		print("[StreamingRegression] FAIL  %s (%s)" % [name, detail])


func _finish() -> void:
	print("[StreamingRegression] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
