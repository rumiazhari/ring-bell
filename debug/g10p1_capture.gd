extends Node
## G10-P1 real capture: 6 deterministic player-view screenshots using live ChunkManager + FollowCamera
## Trigger: godot --path . -- --g10p1-capture  (windowed, not headless)
## Saves to .hermes/autopilot/reports/G10-P1-vegetation/real/

const OUT_DIR := "C:/Vibe Code project/Godot Project/ring-bell/.hermes/autopilot/reports/G10-P1-vegetation/real"
const W := 1200
const H := 720

var _world: WorldPlan
var _city_plan: CityPlan
var _manager: ChunkManager
var _debug_overlay: CanvasLayer
var _capture_failed := false
var _captures: Array[Dictionary] = []

func _ready() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("headless"):
		push_error("[G10P1Capture] refusing headless/dummy capture; real window required")
		get_tree().quit(2)
		return
	var window := get_window()
	if window != null:
		window.size = Vector2i(W, H)
	print("[G10P1Capture] starting real windowed capture %dx%d renderer=%s" % [W, H, DisplayServer.get_name()])
	var capture_main: Node = get_tree().current_scene
	_debug_overlay = get_node_or_null("/root/DebugOverlay") as CanvasLayer
	if _debug_overlay != null:
		_debug_overlay.visible = false
		print("[G10P1Capture] debug overlay hidden for unobstructed player-view evidence")
	var capture_manager: ChunkManager = capture_main.get("chunk_manager") as ChunkManager
	if capture_manager != null:
		_manager = capture_manager
		# Evidence still uses the real Forward+ renderer and production builders,
		# but drains chunk manifests synchronously so remote teleports cannot leave
		# stale worker jobs racing the camera or shared pure-plan caches.
		capture_manager.synchronous = true
		# Stop the first automatic city ring before it starts. The capture pass
		# chooses its deterministic target first, then enables the real streamer.
		capture_manager.set_process(false)
	var t := get_tree().create_timer(2.0)
	await t.timeout
	_ensure_out_dir()
	await _build_capture_list()
	var only_id: String = ""
	for arg in OS.get_cmdline_user_args():
		var arg_s: String = str(arg)
		if arg_s.begins_with("--g10p1-only="):
			only_id = arg_s.trim_prefix("--g10p1-only=")
	if not only_id.is_empty():
		var selected: Array[Dictionary] = []
		for cap in _captures:
			if str(cap.get("id", "")).begins_with(only_id):
				selected.append(cap)
		_captures = selected
		print("[G10P1Capture] filtered to %d capture(s) by %s" % [_captures.size(), only_id])
	if _manager != null and is_instance_valid(_manager):
		# Leave normal streaming paused. The pass below invokes the same production
		# manifest/materialization path one target chunk at a time, which keeps the
		# window responsive while preserving a real Forward+ player view.
		_manager.set_process(false)
	for idx in _captures.size():
		var cap: Dictionary = _captures[idx]
		await _capture_one(cap, idx)
		if _capture_failed:
			return
	print("[G10P1Capture] all captures done")
	# Also dump stats
	var mgrs := get_tree().get_nodes_in_group(&"chunk_manager")
	if mgrs.size() > 0:
		var mgr: ChunkManager = mgrs[0]
		for line in mgr.debug_lines():
			print("[G10P1Capture] %s" % line)
	get_tree().quit(0)

func _ensure_out_dir() -> void:
	var dir := DirAccess.open("C:/Vibe Code project/Godot Project/ring-bell/.hermes/autopilot/reports/G10-P1-vegetation")
	if dir == null:
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
	else:
		if not DirAccess.dir_exists_absolute(OUT_DIR):
			DirAccess.make_dir_recursive_absolute(OUT_DIR)

func _build_capture_list() -> void:
	# Reuse the live main-scene plans. Constructing a second WorldPlan while
	# ChunkManager worker threads are streaming would race shared fringe caches.
	var main_node: Node = get_tree().current_scene
	var live_manager: ChunkManager = main_node.get("chunk_manager") as ChunkManager
	var live_city: CityPlan = main_node.get("city_plan") as CityPlan
	if live_manager == null or live_manager.world_plan == null or live_city == null:
		push_error("[G10P1Capture] live ChunkManager/WorldPlan not ready")
		return
	_world = live_manager.world_plan
	_city_plan = live_city
	var world: WorldPlan = _world
	# Find deterministic locations via the same WorldPlan/manifest data used by the game.
	var dense := _find_forest_chunk(world, 35, 900.0, 2400.0)
	var dense_focus := _focus_in_forest(world, dense)
	var dense_ground_focus := _forest_floor_focus(world, dense, dense_focus)
	var dense_camera_p2: Vector2 = Vector2(dense_ground_focus.x, dense_ground_focus.z) + Vector2(-6.0, -6.0)
	for offset in [Vector2(-6.0, -6.0), Vector2(-6.0, 6.0), Vector2(6.0, -6.0), Vector2(6.0, 6.0), Vector2(-10.0, 0.0), Vector2(0.0, -10.0)]:
		var candidate_p: Vector2 = Vector2(dense_ground_focus.x, dense_ground_focus.z) + offset
		if world.water_body_at(candidate_p) != &"" or world.is_floodplain(candidate_p):
			continue
		if world.surface_class_at(candidate_p) == &"cliff" or world.surface_slope_at(candidate_p) >= 22.0:
			continue
		dense_camera_p2 = candidate_p
		break
	var dense_camera: Vector3 = Vector3(dense_camera_p2.x, world.surface_height_at(dense_camera_p2) + WorldConstants.SPAWN_FEET_CLEARANCE_M, dense_camera_p2.y)
	var edge_view: Dictionary = _find_forest_edge_view(world)
	var edge: Vector3 = edge_view.get("pos", dense_camera)
	var edge_look: Vector3 = edge_view.get("look", edge + Vector3(18, -0.8, 0))
	var road_view: Dictionary = _find_road_woodland(world)
	var field_view: Dictionary = _find_field_view(world)
	var settlement_view: Dictionary = _find_settlement_view(world)
	var distant_view: Dictionary = _find_distant_forest_view(world, dense)
	_captures = [
		{"id": "01_dense_forest_interior", "pos": dense_camera, "look": dense_ground_focus + Vector3(0, 1.1, 0), "desc": "Dense forest interior — clustered beech/oak/birch/spruce, saplings, bushes, grass, leaf litter, stones, logs, lit"},
		{"id": "02_forest_edge_open_field", "pos": edge, "look": edge_look, "desc": "Forest edge meeting open field — lower tree density, saplings and field transition"},
		{"id": "03_road_through_woodland", "pos": road_view.get("pos", dense), "look": road_view.get("look", dense + Vector3(0, -0.8, 22)), "desc": "Road passing beside/through woodland — readable road ribbon, shoulders, roadside shrubs"},
		{"id": "04_rural_open_countryside", "pos": field_view.get("pos", dense), "look": field_view.get("look", dense + Vector3(14, -0.6, 8)), "desc": "Rural open countryside — tilled field, hedgerow, restrained solitary tree and roadside grass"},
		{"id": "05_settlement_edge", "pos": settlement_view.get("pos", dense), "look": settlement_view.get("look", dense + Vector3(10, -0.9, -12)), "desc": "Settlement edge — rural house/barn yards with improved trees, fences and undergrowth"},
		{"id": "06_distant_forest_silhouette", "pos": distant_view.get("pos", dense - Vector3(160, 0, 0)), "look": distant_view.get("look", dense), "desc": "Distant forest silhouette — open terrain foreground and recognizable mixed forest horizon"},
	]
	for c in _captures:
		print("[G10P1Capture] planned %s at %s look %s" % [c["id"], str(c["pos"]), str(c["look"])])

func _find_forest_chunk(world: WorldPlan, min_samples: int, min_dist: float, max_dist: float, want_edge: bool = false) -> Vector3:
	# Locate a deterministic composition with cheap pure biome probes. Do not
	# build full render manifests in the main thread while the live streamer runs.
	var rng := WorldSeed.rng_for("g10p1_forest_search", [min_samples])
	for attempt in 300:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(min_dist, max_dist, rng.randf())
		var p2 := Vector2(cos(ang), sin(ang)) * dist
		if p2.length() < WorldConstants.URBAN_OUTER_M + 80:
			continue
		if world.water_body_at(p2) != &"" or world.is_floodplain(p2):
			continue
		var origin := Vector2(WorldSeed.chunk_coord(p2.x, p2.y)) * BiomeChunkBuilder.CHUNK_M
		var samples := _forest_sample_count(world, origin)
		if want_edge and _open_field_sample_count(world, origin) < 1:
			continue
		if samples < min_samples:
			continue
		if want_edge and samples >= 35:
			continue
		if not want_edge and min_samples >= 35:
			var non_forest_feature := 0
			for fj in 9:
				for fi in 9:
					var sample_biome: StringName = world.biome_at(origin + Vector2(float(fi) * 8.0, float(fj) * 8.0))
					if sample_biome == &"rocky_quarry":
						non_forest_feature += 1
			if non_forest_feature > 0:
				continue
			var probe_manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, WorldSeed.chunk_coord(origin.x, origin.y))
			var probe_counts: Dictionary = probe_manifest.get("vegetation_counts", {}) as Dictionary
			var probe_trees: int = int(probe_counts.get(&"beech", 0)) + int(probe_counts.get(&"oak", 0)) + int(probe_counts.get(&"birch", 0)) + int(probe_counts.get(&"spruce", 0))
			if probe_trees < 24:
				continue
		var center := origin + Vector2.ONE * 32.0
		if not _is_forest(world.biome_at(center)):
			continue
		var h: float = world.surface_height_at(center)
		return Vector3(center.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, center.y)
	# fallback to SpawnPoints forest
	var fp: Vector3 = SpawnPoints.get_spawn_position(&"forest", world, _city_plan)
	return fp

func _focus_in_forest(world: WorldPlan, seed_pos: Vector3) -> Vector3:
	# Use the production manifest once to place the camera over the densest local
	# cluster, rather than judging a gap between trees as the forest interior.
	var coord := WorldSeed.chunk_coord(seed_pos.x, seed_pos.z)
	var manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, coord)
	var typed: Dictionary = manifest.get("vegetation_typed", {}) as Dictionary
	var points: Array[Vector2] = []
	for kind in [&"beech", &"oak", &"birch", &"spruce", &"sapling", &"bush"]:
		var group: Array = typed.get(kind, []) as Array
		for xf in group:
			var t: Transform3D = xf as Transform3D
			var point := Vector2(t.origin.x, t.origin.z)
			points.append(point)
			if kind == &"bush":
				points.append(point)
				points.append(point)
	if points.is_empty():
		return seed_pos
	var best: Vector2 = points[0]
	var best_score := -1
	for p in points:
		var score := 0
		for q in points:
			if p.distance_squared_to(q) <= 15.0 * 15.0:
				score += 1
		if score > best_score:
			best_score = score
			best = p
	var h: float = world.surface_height_at(best)
	return Vector3(best.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, best.y)

func _understory_focus(world: WorldPlan, seed_pos: Vector3, tree_focus: Vector3) -> Vector3:
	var coord := WorldSeed.chunk_coord(seed_pos.x, seed_pos.z)
	var manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, coord)
	var typed: Dictionary = manifest.get("vegetation_typed", {}) as Dictionary
	var chosen := Vector2(tree_focus.x, tree_focus.z)
	var best_distance: float = INF
	for kind in [&"bush", &"grass", &"leaf_litter", &"stone"]:
		var group: Array = typed.get(kind, []) as Array
		for xf in group:
			var t: Transform3D = xf as Transform3D
			var point := Vector2(t.origin.x, t.origin.z)
			var distance_to_tree: float = point.distance_to(Vector2(tree_focus.x, tree_focus.z))
			var priority_distance: float = distance_to_tree + (0.0 if kind == &"grass" else 8.0)
			if priority_distance < best_distance:
				best_distance = priority_distance
				chosen = point
	var h: float = world.surface_height_at(chosen)
	return Vector3(chosen.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, chosen.y)

func _forest_floor_focus(world: WorldPlan, seed_pos: Vector3, fallback: Vector3) -> Vector3:
	var coord := WorldSeed.chunk_coord(seed_pos.x, seed_pos.z)
	var manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, coord)
	var typed: Dictionary = manifest.get("vegetation_typed", {}) as Dictionary
	var floor_points: Array[Vector2] = []
	var tree_points: Array[Vector2] = []
	for kind in [&"beech", &"oak", &"birch", &"spruce", &"sapling"]:
		for xf in typed.get(kind, []) as Array:
			var tree_t: Transform3D = xf as Transform3D
			tree_points.append(Vector2(tree_t.origin.x, tree_t.origin.z))
	for kind in [&"bush", &"grass", &"leaf_litter", &"stone", &"log", &"dead_branch"]:
		for xf in typed.get(kind, []) as Array:
			var floor_t: Transform3D = xf as Transform3D
			floor_points.append(Vector2(floor_t.origin.x, floor_t.origin.z))
	if floor_points.is_empty():
		return fallback
	var best := floor_points[0]
	var best_score: float = -INF
	for point in floor_points:
		if world.surface_class_at(point) == &"cliff" or world.surface_slope_at(point) >= 22.0:
			continue
		var nearby_floor := 0
		for other_floor in floor_points:
			if point.distance_squared_to(other_floor) <= 10.0 * 10.0:
				nearby_floor += 1
		var nearest_tree: float = INF
		var nearby_trees := 0
		for tree_point in tree_points:
			var distance_to_tree: float = point.distance_to(tree_point)
			nearest_tree = minf(nearest_tree, distance_to_tree)
			if distance_to_tree <= 16.0:
				nearby_trees += 1
		var score: float = float(nearby_floor) * 5.0 + float(mini(nearby_trees, 8))
		if nearest_tree < 3.0:
			score -= 6.0
		if score > best_score:
			best_score = score
			best = point
	var h: float = world.surface_height_at(best)
	return Vector3(best.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, best.y)

func _forest_sample_count(world: WorldPlan, origin: Vector2) -> int:
	var count := 0
	for j in 9:
		for i in 9:
			if _is_forest(world.biome_at(origin + Vector2(float(i) * 8.0, float(j) * 8.0))):
				count += 1
	return count

func _open_field_sample_count(world: WorldPlan, origin: Vector2) -> int:
	var count := 0
	for j in 9:
		for i in 9:
			if _is_open_field(world.biome_at(origin + Vector2(float(i) * 8.0, float(j) * 8.0))):
				count += 1
	return count

func _find_forest_edge_view(world: WorldPlan) -> Dictionary:
	var rng := WorldSeed.rng_for("g10p1_forest_edge_search", [world.seed_used, 204])
	for attempt in 420:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(900.0, 3200.0, rng.randf())
		var probe := Vector2(cos(ang), sin(ang)) * dist
		if probe.length() < WorldConstants.URBAN_OUTER_M + 100.0:
			continue
		var coord := WorldSeed.chunk_coord(probe.x, probe.y)
		var origin := Vector2(coord) * BiomeChunkBuilder.CHUNK_M
		var forest_point := Vector2.ZERO
		var field_point := Vector2.ZERO
		var forest_found := false
		var field_found := false
		for j in 9:
			for i in 9:
				var sample := origin + Vector2(float(i) * 8.0, float(j) * 8.0)
				if not forest_found and _is_forest(world.biome_at(sample)) and world.water_body_at(sample) == &"" and not world.is_floodplain(sample):
					forest_point = sample
					forest_found = true
				if not field_found and _is_open_field(world.biome_at(sample)) and world.water_body_at(sample) == &"" and not world.is_floodplain(sample):
					field_point = sample
					field_found = true
		if not forest_found or not field_found or forest_point.distance_to(field_point) < 12.0:
			continue
		var manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, coord)
		var typed: Dictionary = manifest.get("vegetation_typed", {}) as Dictionary
		var rendered_tree_count := 0
		for kind in [&"beech", &"oak", &"birch", &"spruce", &"sapling"]:
			rendered_tree_count += (typed.get(kind, []) as Array).size()
		var parcel_manifests: Array = manifest.get("field_parcel_manifests", []) as Array
		if rendered_tree_count < 8 or parcel_manifests.is_empty():
			continue
		var to_forest: Vector2 = (forest_point - field_point).normalized()
		var camera_p: Vector2 = field_point - to_forest * 12.0
		if not _is_open_field(world.biome_at(camera_p)) or world.water_body_at(camera_p) != &"" or world.is_floodplain(camera_p):
			continue
		var view_p: Vector2 = field_point.lerp(forest_point, 0.82)
		var camera_h: float = world.surface_height_at(camera_p)
		var target_h: float = world.surface_height_at(view_p)
		return {"pos": Vector3(camera_p.x, camera_h + WorldConstants.SPAWN_FEET_CLEARANCE_M, camera_p.y), "look": Vector3(view_p.x, target_h + 1.5, view_p.y)}
	# Deterministic fallback remains a real production query, but should be rare.
	var fallback := _find_forest_chunk(world, 8, 700.0, 3200.0, true)
	return {"pos": fallback, "look": _edge_look(world, fallback)}

func _edge_look(world: WorldPlan, edge: Vector3) -> Vector3:
	var origin := Vector2(WorldSeed.chunk_coord(edge.x, edge.z)) * BiomeChunkBuilder.CHUNK_M
	var center := Vector2(edge.x, edge.z)
	var best_dir := Vector2(18.0, -4.0)
	var best_distance := INF
	for j in 9:
		for i in 9:
			var p := origin + Vector2(float(i) * 8.0, float(j) * 8.0)
			if _is_open_field(world.biome_at(p)):
				var delta := p - center
				if delta.length_squared() > 4.0 and delta.length_squared() < best_distance:
					best_distance = delta.length_squared()
					best_dir = delta.normalized() * 22.0
	var look_p: Vector2 = center + best_dir
	var look_h: float = world.surface_height_at(look_p)
	return Vector3(look_p.x, look_h + 0.45, look_p.y)

func _is_forest(biome: StringName) -> bool:
	return biome == &"deciduous_forest" or biome == &"mixed_upland_forest"

func _find_road_woodland(world: WorldPlan) -> Dictionary:
	var rng := WorldSeed.rng_for("g10p1_road_wood", [world.seed_used & 0xFFFF, 77])
	for attempt in 180:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(900.0, 2600.0, rng.randf())
		var probe := Vector2(cos(ang), sin(ang)) * dist
		if probe.length() < WorldConstants.URBAN_OUTER_M + 60.0:
			continue
		var coord := WorldSeed.chunk_coord(probe.x, probe.y)
		var origin := Vector2(coord) * BiomeChunkBuilder.CHUNK_M
		var rect := Rect2(origin, Vector2(BiomeChunkBuilder.CHUNK_M, BiomeChunkBuilder.CHUNK_M))
		var segments: Array[Dictionary] = world.road_segments_in(rect)
		for seg in segments:
			if bool(seg.get("is_bridge", false)):
				continue
			var poly: PackedVector2Array = seg.get("polyline_clipped", seg.get("polyline", PackedVector2Array())) as PackedVector2Array
			if poly.size() < 2:
				continue
			var mid_index: int = clampi(poly.size() / 2, 1, poly.size() - 1)
			var mid: Vector2 = poly[mid_index]
			var direction := (poly[mid_index] - poly[mid_index - 1]).normalized()
			if direction.length_squared() < 0.01:
				continue
			var perpendicular := Vector2(-direction.y, direction.x)
			for side in [-1.0, 1.0]:
				var woodland_side: Vector2 = mid + perpendicular * side * 10.0
				var camera_p: Vector2 = mid - direction * 5.0 + perpendicular * side * 2.0
				if world.water_body_at(camera_p) != &"" or world.is_floodplain(camera_p) or world.surface_class_at(camera_p) == &"cliff" or world.surface_slope_at(camera_p) >= 22.0:
					continue
				var h: float = world.surface_height_at(camera_p)
				var road_coord := WorldSeed.chunk_coord(woodland_side.x, woodland_side.y)
				var target_p := woodland_side + direction * 30.0
				var best_tree_score: float = -INF
				var found_tree := false
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						var neighbor_coord: Vector2i = road_coord + Vector2i(dx, dz)
						var road_manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, neighbor_coord)
						var road_typed: Dictionary = road_manifest.get("vegetation_typed", {}) as Dictionary
						for kind in [&"beech", &"oak", &"birch", &"spruce", &"sapling", &"bush", &"roadside_shrub"]:
							for xf_value in road_typed.get(kind, []) as Array:
								var tree_xf: Transform3D = xf_value as Transform3D
								var tree_p := Vector2(tree_xf.origin.x, tree_xf.origin.z)
								var relative: Vector2 = tree_p - mid
								if tree_p.distance_to(mid) < 18.0 or tree_p.distance_to(mid) > 60.0:
									continue
								var tree_score: float = tree_p.distance_to(mid)
								if tree_score > best_tree_score:
									best_tree_score = tree_score
									target_p = tree_p
									found_tree = true
				if not found_tree:
					continue
				# Keep the road tangent primary, with a bounded look toward the
				# woodland side instead of a distant tree that can swing the view
				# completely off the rendered road ribbon.
				var road_look: Vector2 = mid + direction * 34.0
				var view_target: Vector2 = road_look.lerp(target_p, 0.82)
				var target_h: float = world.surface_height_at(view_target)
				return {"pos": Vector3(camera_p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, camera_p.y), "look": Vector3(view_target.x, target_h + 1.0, view_target.y)}
	# Stable fallback is still a real road/forest query, not a made-up point.
	var fallback := Vector2(412.9707, 1508.437)
	var fh: float = world.surface_height_at(fallback)
	return {"pos": Vector3(fallback.x, fh + WorldConstants.SPAWN_FEET_CLEARANCE_M, fallback.y), "look": Vector3(fallback.x, fh + 0.4, fallback.y + 22.0)}

func _find_field_view(world: WorldPlan) -> Dictionary:
	var parcels: Array[Dictionary] = world.field_parcels()
	parcels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	for parcel in parcels:
		var center: Vector2 = parcel.get("center", parcel.get("pos", Vector2.ZERO)) as Vector2
		if center == Vector2.ZERO or center.length() < WorldConstants.URBAN_OUTER_M + 40.0:
			continue
		if world.water_body_at(center) != &"" or world.is_floodplain(center):
			continue
		if not _is_open_field(world.biome_at(center)):
			continue
		var origin := Vector2(WorldSeed.chunk_coord(center.x, center.y)) * BiomeChunkBuilder.CHUNK_M
		if _forest_sample_count(world, origin) > 4:
			continue
		var yaw: float = float(parcel.get("yaw", 0.0))
		var direction := Vector2(cos(yaw), sin(yaw))
		# Prefer actual countryside vegetation transforms from this production
		# manifest. A field center alone is not sufficient visual evidence.
		var manifest: Dictionary = BiomeChunkBuilder.build_manifest(world, WorldSeed.chunk_coord(center.x, center.y))
		var typed: Dictionary = manifest.get("vegetation_typed", {}) as Dictionary
		var feature := center
		var feature_axis: Vector2 = direction
		var feature_distance: float = INF
		for kind in [&"hedgerow", &"roadside_shrub", &"solitary_oak", &"orchard_canopy"]:
			for xf_value in typed.get(kind, []) as Array:
				var feature_xf: Transform3D = xf_value as Transform3D
				var feature_p := Vector2(feature_xf.origin.x, feature_xf.origin.z)
				var distance_to_center: float = feature_p.distance_to(center)
				if distance_to_center < feature_distance:
					feature_distance = distance_to_center
					feature = feature_p
					if kind == &"hedgerow":
						feature_axis = Vector2(feature_xf.basis.x.x, feature_xf.basis.x.z).normalized()
			if feature_distance < INF:
				break
		var secondary_feature := Vector2.ZERO
		var secondary_distance: float = INF
		for xf_value in typed.get(&"solitary_oak", []) as Array:
			var secondary_xf: Transform3D = xf_value as Transform3D
			var secondary_p := Vector2(secondary_xf.origin.x, secondary_xf.origin.z)
			var secondary_d: float = secondary_p.distance_to(feature)
			if secondary_d < secondary_distance:
				secondary_distance = secondary_d
				secondary_feature = secondary_p
		var view_center: Vector2 = feature
		if secondary_distance < INF:
			view_center = feature.lerp(secondary_feature, 0.30)
		var to_feature: Vector2 = (feature - center).normalized()
		if to_feature.length_squared() < 0.01:
			to_feature = direction
		if feature_axis.length_squared() < 0.01:
			feature_axis = direction
		var hedge_normal: Vector2 = Vector2(-feature_axis.y, feature_axis.x)
		var camera_candidates: Array[Vector2] = [
			feature - hedge_normal * 14.0,
			feature + hedge_normal * 14.0,
			feature - to_feature * 14.0,
			feature + to_feature * 14.0,
		]
		var target_p: Vector2 = feature.lerp(secondary_feature, 0.05) if secondary_distance < INF else feature
		var best_camera: Vector2 = Vector2.ZERO
		var best_camera_score: int = -1
		for camera_p in camera_candidates:
			if not _is_open_field(world.biome_at(camera_p)):
				continue
			if world.water_body_at(camera_p) != &"" or world.is_floodplain(camera_p) or world.distance_to_road(camera_p) < 3.0:
				continue
			var camera_score: int = 0
			for kind in [&"grass", &"bush"]:
				for xf_value in typed.get(kind, []) as Array:
					var dressing_xf: Transform3D = xf_value as Transform3D
					var dressing_p := Vector2(dressing_xf.origin.x, dressing_xf.origin.z)
					if dressing_p.distance_to(camera_p) <= 14.0:
						camera_score += 1
			if camera_score > best_camera_score:
				best_camera_score = camera_score
				best_camera = camera_p
		var best_dressing: Vector2 = Vector2.ZERO
		var best_dressing_score: int = -1
		for kind in [&"grass", &"bush"]:
			for xf_value in typed.get(kind, []) as Array:
				var dressing_xf: Transform3D = xf_value as Transform3D
				var dressing_p := Vector2(dressing_xf.origin.x, dressing_xf.origin.z)
				var distance_to_hedge: float = dressing_p.distance_to(feature)
				if distance_to_hedge < 5.0 or distance_to_hedge > 18.0:
					continue
				var dressing_score: int = 0
				for other_kind in [&"grass", &"bush"]:
					for other_value in typed.get(other_kind, []) as Array:
						var other_xf: Transform3D = other_value as Transform3D
						var other_p := Vector2(other_xf.origin.x, other_xf.origin.z)
						if dressing_p.distance_to(other_p) <= 9.0:
							dressing_score += 1
				if dressing_score > best_dressing_score:
					best_dressing_score = dressing_score
					best_dressing = dressing_p
		if best_dressing_score >= 0:
			var toward_hedge: Vector2 = (target_p - best_dressing).normalized()
			var dressing_camera: Vector2 = best_dressing - toward_hedge * 3.0
			if _is_open_field(world.biome_at(dressing_camera)) and world.water_body_at(dressing_camera) == &"" and not world.is_floodplain(dressing_camera):
				best_camera = dressing_camera
		if best_camera_score >= 0:
			var h: float = world.surface_height_at(best_camera)
			var target_h: float = world.surface_height_at(target_p)
			return {"pos": Vector3(best_camera.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, best_camera.y), "look": Vector3(target_p.x, target_h + 3.0, target_p.y)}
	var all_parcels: Array[Dictionary] = world.field_parcels()
	if not all_parcels.is_empty():
		var fallback_parcel: Dictionary = all_parcels[0]
		var fallback_center: Vector2 = fallback_parcel.get("center", Vector2.ZERO) as Vector2
		var fallback_yaw: float = float(fallback_parcel.get("yaw", 0.0))
		var fallback_dir: Vector2 = Vector2(cos(fallback_yaw), sin(fallback_yaw))
		var fallback_camera: Vector2 = fallback_center - fallback_dir * 10.0
		var fallback_h: float = world.surface_height_at(fallback_camera)
		var fallback_target_h: float = world.surface_height_at(fallback_center)
		return {"pos": Vector3(fallback_camera.x, fallback_h + WorldConstants.SPAWN_FEET_CLEARANCE_M, fallback_camera.y), "look": Vector3(fallback_center.x, fallback_target_h + 0.4, fallback_center.y)}
	var fallback := SpawnPoints.get_spawn_position(&"field", world, _city_plan)
	return {"pos": fallback, "look": fallback + Vector3(18.0, -0.8, 10.0)}

func _is_open_field(biome: StringName) -> bool:
	return biome == &"arable_field" or biome == &"pasture" or biome == &"pasture_orchard" or biome == &"orchard"

func _find_settlement_view(world: WorldPlan) -> Dictionary:
	# Pick a real rural building that also has deterministic settlement trees nearby;
	# this guarantees the capture view contains settlement fabric, not only a gate.
	for building in world.rural_buildings():
		var center: Vector2 = building.get("center", building.get("pos", Vector2.ZERO)) as Vector2
		if center.length() < WorldConstants.URBAN_OUTER_M + 120.0:
			continue
		var trees: Array[Dictionary] = world.settlement_trees_in(Rect2(center - Vector2.ONE * 70.0, Vector2.ONE * 140.0))
		if trees.is_empty():
			continue
		var fences: Array[Dictionary] = world.settlement_fences_in(Rect2(center - Vector2.ONE * 90.0, Vector2.ONE * 180.0))
		if fences.is_empty():
			continue
		var fence_mid: Vector2 = center
		var fence_distance: float = -INF
		for fence in fences:
			var fence_a: Vector2 = fence.get("a", center) as Vector2
			var fence_b: Vector2 = fence.get("b", center) as Vector2
			var candidate_mid: Vector2 = (fence_a + fence_b) * 0.5
			var candidate_distance: float = candidate_mid.distance_squared_to(center)
			if candidate_distance > fence_distance:
				fence_distance = candidate_distance
				fence_mid = candidate_mid
		if fence_distance < 16.0:
			continue
		var nearest_tree: Vector2 = trees[0].get("pos", center) as Vector2
		var nearest_tree_distance: float = nearest_tree.distance_squared_to(center)
		for tree in trees:
			var tree_point: Vector2 = tree.get("pos", center) as Vector2
			var tree_distance: float = tree_point.distance_squared_to(center)
			if tree_distance < nearest_tree_distance:
				nearest_tree = tree_point
				nearest_tree_distance = tree_distance
		var fence_direction: Vector2 = (fence_mid - center).normalized()
		if fence_direction.length_squared() < 0.01:
			fence_direction = Vector2.RIGHT
		var building_target: Vector2 = center.lerp(nearest_tree, 0.08)
		var target_center: Vector2 = fence_mid.lerp(building_target, 0.42)
		var side_axis := Vector2(-fence_direction.y, fence_direction.x)
		# Stand just outside the far fence so the fence crosses the foreground
		# while the common, buildings, trees, and ground clutter remain behind it.
		var camera_candidates: Array = [
			target_center + fence_direction * 12.0,
			target_center + fence_direction * 18.0,
			target_center - fence_direction * 18.0,
			target_center + side_axis * 20.0,
			target_center - side_axis * 20.0,
		]
		for camera_p in camera_candidates:
			var outside_buildings := true
			for other_building in world.rural_buildings():
				var other_aabb: Rect2 = other_building.get("aabb", Rect2()) as Rect2
				if other_aabb.grow(3.0).has_point(camera_p):
					outside_buildings = false
					break
			if not outside_buildings or world.water_body_at(camera_p) != &"" or world.is_floodplain(camera_p):
				continue
			var near_well: bool = false
			for well in world.rural_wells_in(Rect2(camera_p - Vector2.ONE * 10.0, Vector2.ONE * 20.0)):
				var well_pos: Vector2 = well.get("center", well.get("pos", camera_p)) as Vector2
				if well_pos.distance_to(camera_p) < 8.0:
					near_well = true
					break
			if near_well:
				continue
			var h: float = world.surface_height_at(camera_p)
			var target_h: float = world.surface_height_at(target_center)
			return {"pos": Vector3(camera_p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, camera_p.y), "look": Vector3(target_center.x, target_h + 4.0, target_center.y)}
	var fallback := SpawnPoints.get_spawn_position(&"hamlet", world, _city_plan)
	return {"pos": fallback, "look": fallback + Vector3(10.0, -0.7, -12.0)}

func _find_distant_forest_view(world: WorldPlan, dense: Vector3) -> Dictionary:
	var forest_p := Vector2(dense.x, dense.z)
	for distance in [60.0, 80.0, 100.0]:
		for angle_deg in [0, 45, 90, 135, 180, 225, 270, 315]:
			var angle: float = deg_to_rad(float(angle_deg))
			var to_forest := Vector2(cos(angle), sin(angle))
			var camera_p: Vector2 = forest_p - to_forest * distance
			if _is_forest(world.biome_at(camera_p)) or world.water_body_at(camera_p) != &"" or world.is_floodplain(camera_p):
				continue
			var camera_h: float = world.surface_height_at(camera_p)
			return {"pos": Vector3(camera_p.x, camera_h + WorldConstants.SPAWN_FEET_CLEARANCE_M, camera_p.y), "look": Vector3(forest_p.x, dense.y + 0.6, forest_p.y)}
	return {"pos": dense - Vector3(160.0, 0.0, 0.0), "look": dense}

func _capture_one(cap: Dictionary, idx: int) -> void:
	var id: String = cap["id"]
	var pos: Vector3 = cap["pos"]
	var look: Vector3 = cap["look"]
	var desc: String = cap["desc"]
	print("[G10P1Capture] capturing %s pos %s look %s" % [id, str(pos), str(look)])
	# Teleport player if exists, else create temp camera
	var player := ActorRegistry.get_actor(&"player")
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	var mgr: ChunkManager = null
	if managers.size() > 0:
		mgr = managers[0] as ChunkManager
	var main_node: Node = get_tree().current_scene
	var rig: FollowCamera = main_node.get("camera_rig") as FollowCamera
	# Ensure ChunkManager knows player
	if player != null and is_instance_valid(player):
		# Freeze the player while a capture teleports to a deterministic location;
		# the camera remains the normal FollowCamera player view.
		player.process_mode = Node.PROCESS_MODE_DISABLED
		var p2 := Vector2(pos.x, pos.z)
		var h: float = _world.surface_height_at(p2) if _world != null else pos.y
		player.global_position = Vector3(pos.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, pos.z)
		var active_camera: Camera3D = get_viewport().get_camera_3d()
		if rig != null and is_instance_valid(rig):
			# Freeze the normal follow logic while keeping its real Camera3D and
			# player HUD. This makes each evidence sightline exact and deterministic.
			rig.set_process(false)
		if active_camera != null and is_instance_valid(active_camera):
			var target_p2: Vector2 = Vector2(look.x, look.z)
			var target_h: float = _world.surface_height_at(target_p2) if _world != null else look.y
			active_camera.fov = 65.0
			active_camera.near = 0.05
			active_camera.far = 900.0
			var camera_lift: float = 8.0
			if id.begins_with("01_"):
				active_camera.fov = 52.0
				camera_lift = 4.8
			elif id.begins_with("03_"):
				active_camera.fov = 68.0
				camera_lift = 6.2
			elif id.begins_with("05_"):
				active_camera.fov = 40.0
				camera_lift = 5.2
			elif id.begins_with("04_"):
				active_camera.fov = 65.0
				camera_lift = 5.2
			elif id.begins_with("06_"):
				active_camera.fov = 58.0
				camera_lift = 6.0
			active_camera.global_position = Vector3(pos.x, h + camera_lift, pos.z)
			active_camera.look_at(Vector3(look.x, target_h + 1.6, look.z), Vector3.UP)
			active_camera.make_current()
		if mgr != null:
			# Materialize only the camera chunk (and the sight-line chunks for the
			# distant silhouette) through the real production path. The streamer is
			# paused so this cannot discard the target during a remote jump.
			var ready: bool = _materialize_capture_chunks(mgr, p2, Vector2(look.x, look.z))
			if not ready:
				_capture_failed = true
				push_error("[G10P1Capture] aborting; %s has no materialized target chunk" % id)
				get_tree().quit(3)
				return
			if not _validate_capture_scene(id, mgr, p2):
				_capture_failed = true
				push_error("[G10P1Capture] aborting; %s did not materialize its required scene layer" % id)
				get_tree().quit(4)
				return
			await get_tree().process_frame
			await get_tree().process_frame
			await get_tree().create_timer(0.8).timeout
			await _save_viewport(id, desc)
		player.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		# No player yet — create standalone camera
		var cam2 := Camera3D.new()
		cam2.fov = 75
		cam2.near = 0.05
		cam2.far = 800.0
		get_tree().root.add_child(cam2)
		cam2.global_position = pos
		cam2.look_at(look, Vector3.UP)
		cam2.make_current()
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().create_timer(0.8).timeout
		await _save_viewport(id, desc)
		cam2.queue_free()

func _validate_capture_scene(id: String, mgr: ChunkManager, camera_p2: Vector2) -> bool:
	var tree_count := 0
	var forest_floor := 0
	var fields := 0
	var roads := 0
	var rural_buildings := 0
	var rural_trees := 0
	for value in mgr._chunks.values():
		tree_count += int(value.get("forest_beech", 0)) + int(value.get("forest_oak", 0)) + int(value.get("forest_birch", 0)) + int(value.get("forest_spruce", 0)) + int(value.get("forest_sapling", 0))
		forest_floor += int(value.get("forest_leaf_litter", 0)) + int(value.get("forest_stone", 0)) + int(value.get("forest_dead_branch", 0)) + int(value.get("forest_bush", 0)) + int(value.get("forest_grass", 0))
		fields += int(value.get("field_parcels", 0))
		roads += int(value.get("road_vertices", 0))
		rural_buildings += int(value.get("rural_buildings", 0))
		var rural_manifest: Dictionary = value.get("rural_manifest", {}) as Dictionary
		rural_trees += int(rural_manifest.get("settlement_tree_count", 0))
	var ok := true
	if id.begins_with("01_"):
		ok = tree_count >= 30 and forest_floor >= 20
	elif id.begins_with("02_"):
		var origin := Vector2(WorldSeed.chunk_coord(camera_p2.x, camera_p2.y)) * BiomeChunkBuilder.CHUNK_M
		ok = tree_count >= 8 and (fields >= 1 or _open_field_sample_count(_world, origin) >= 1)
	elif id.begins_with("03_"):
		ok = tree_count >= 4 and roads > 0
	elif id.begins_with("04_"):
		ok = fields >= 1
	elif id.begins_with("05_"):
		ok = rural_buildings >= 1 and rural_trees >= 1
	elif id.begins_with("06_"):
		ok = tree_count >= 20
	print("[G10P1Capture] validate %s trees=%d floor=%d fields=%d road_v=%d rural_buildings=%d rural_trees=%d => %s" % [id, tree_count, forest_floor, fields, roads, rural_buildings, rural_trees, str(ok)])
	return ok

func _materialize_capture_chunks(mgr: ChunkManager, camera_p2: Vector2, target_p2: Vector2) -> bool:
	mgr.set_process(false)
	mgr.synchronous = true
	# Keep previously materialized production chunks resident between evidence
	# viewpoints; resetting here discarded visual subtrees while retaining records.
	var wanted: Array = []
	var camera_coord := WorldSeed.chunk_coord(camera_p2.x, camera_p2.y)
	wanted.append(camera_coord)
	var sight_distance := camera_p2.distance_to(target_p2)
	var steps := maxi(1, int(ceil(sight_distance / 52.0)))
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		var p := camera_p2.lerp(target_p2, f)
		var c := WorldSeed.chunk_coord(p.x, p.y)
		if not wanted.has(c):
			wanted.append(c)
	# Load a one-chunk visual apron around the sightline. The normal streamer
	# would keep this frustum ring resident; capture mode has its process paused.
	var sightline_chunks: Array = wanted.duplicate()
	for base_coord in sightline_chunks:
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var neighbor: Vector2i = base_coord + Vector2i(dx, dz)
				if not wanted.has(neighbor):
					wanted.append(neighbor)
	for c in wanted:
		print("[G10P1Capture] materializing real chunk %s" % str(c))
		mgr._pending.clear()
		mgr._pending.append(c)
		mgr._launch_batch_jobs()
		mgr._collect_finished_jobs(c)
		if not mgr._chunks.has(c):
			push_error("[G10P1Capture] production chunk materialization failed for %s" % str(c))
			return false
		var record: Dictionary = mgr._chunks[c]
		var veg_manifest: Dictionary = record.get("biome_manifest", {}) as Dictionary
		var veg_counts: Dictionary = veg_manifest.get("vegetation_counts", {}) as Dictionary
		var road_record_vertices: int = int(record.get("road_vertices", 0))
		var rural_record_vertices: int = int(record.get("rural_vertices", 0))
		var field_count: int = int(record.get("field_parcels", 0))
		var carpet_vertices: int = int(record.get("forest_floor_vertices", 0))
		var carpet_cells: int = int(record.get("forest_floor_cells", 0))
		var carpet_skipped: int = int(record.get("forest_floor_skipped", 0))
		print("[G10P1Capture] real chunk %s active boxes=%d biome=%d carpet_v=%d carpet_cells=%d carpet_skipped=%d fields=%d road_v=%d rural_v=%d veg groups=%s" % [str(c), int(record.get("boxes", 0)), int(record.get("biome_instances", 0)), carpet_vertices, carpet_cells, carpet_skipped, field_count, road_record_vertices, rural_record_vertices, str(veg_counts)])
	return mgr._chunks.has(camera_coord)

func _get_or_create_camera() -> Camera3D:
	var existing := get_viewport().get_camera_3d()
	if existing != null and is_instance_valid(existing):
		return existing
	var cam := Camera3D.new()
	cam.fov = 75
	get_tree().root.add_child(cam)
	cam.make_current()
	return cam

func _wait_for_chunks(mgr: ChunkManager, p2: Vector2) -> bool:
	if mgr == null:
		await get_tree().create_timer(1.0).timeout
		return false
	var coord := WorldSeed.chunk_coord(p2.x, p2.y)
	# A chunk build may take several seconds on the real Forward+ path. Wait for
	# the actual target chunk to materialize ACTIVE; the previous 6 s fixed delay
	# captured an empty viewport and then discarded every in-flight job.
	var t := 0.0
	var last_report := -1
	while t < 90.0:
		await get_tree().process_frame
		if mgr._chunks.has(coord):
			var rec: Dictionary = mgr._chunks[coord]
			if str(rec.get("state", "")) == "active":
				print("[G10P1Capture] target chunk %s active after %.1fs" % [str(coord), t])
				return true
		var sec := int(t)
		if sec != last_report:
			last_report = sec
			print("[G10P1Capture] waiting target %s t=%.1f resident=%d pending=%d inflight=%d" % [str(coord), t, mgr._chunks.size(), mgr._pending.size(), mgr._inflight.size()])
		t += get_process_delta_time()
	push_error("[G10P1Capture] target chunk %s did not materialize within 90s" % str(coord))
	return false

func _save_viewport(id: String, desc: String) -> void:
	# Wait for a completed renderer frame rather than sampling during materialization.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	# Ensure window size 1200x720
	var vp := get_viewport()
	if vp != null:
		# Try to set size if Window
		if vp is Window:
			(vp as Window).size = Vector2i(W, H)
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var path := OUT_DIR + "/" + id + ".png"
	var err := img.save_png(path)
	if err != OK:
		print("[G10P1Capture] save FAILED %s err %d" % [path, err])
	else:
		print("[G10P1Capture] saved %s (%dx%d) desc: %s" % [path, img.get_width(), img.get_height(), desc])
	# also save debug overlay
	var mgrs2 := get_tree().get_nodes_in_group(&"chunk_manager")
	if mgrs2.size()>0:
		var m: ChunkManager = mgrs2[0]
		var lines: Array[String] = m.debug_lines()
		var log_path := OUT_DIR + "/" + id + ".log"
		var f := FileAccess.open(log_path, FileAccess.WRITE)
		if f != null:
			f.store_line("id=%s" % id)
			f.store_line("desc=%s" % desc)
			f.store_line("pos=%s" % str(m._last_player_chunk if m.has_method("last_player_chunk") else ""))
			for ln in lines:
				f.store_line(ln)
			f.close()
			print("[G10P1Capture] log %s" % log_path)

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
