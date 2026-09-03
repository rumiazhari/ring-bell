extends Node
## Authentic Forward+ visual acceptance capture for G10-P2B.
## The images are saved from the live game's viewport, never synthesized.

const OUT_DIR := "C:/Vibe Code project/Godot Project/ring-bell/captures/g10p2b_final_20260903_v19"
const CAPTURE_WAIT := 3.0

var _main: Node3D
var _player: Node3D
var _city: CityPlan
var _world: WorldPlan
var _manager: ChunkManager
var _debug_overlay: CanvasLayer


func _ready() -> void:
	_main = get_parent() as Node3D
	_bind_main_objects()
	await _wait_for_main_world(12.0)
	_bind_main_objects()
	if _main == null or not is_instance_valid(_main):
		print("[G10P2BCapture] main root unavailable")
		get_tree().quit(2)
		return
	if _manager == null or _city == null:
		print("[G10P2BCapture] city/manager unavailable")
		get_tree().quit(2)
		return
	_debug_overlay = get_node_or_null("/root/DebugOverlay") as CanvasLayer
	if _debug_overlay != null and is_instance_valid(_debug_overlay):
		_debug_overlay.visible = false
		print("[G10P2BCapture] debug overlay hidden for unobstructed evidence")
	_protect_player()
	await _run()


func _bind_main_objects() -> void:
	if _main == null or not is_instance_valid(_main):
		return
	var city_candidate: Variant = _main.get("city_plan")
	var manager_candidate: Variant = _main.get("chunk_manager")
	var player_candidate: Variant = _main.get("player")
	if city_candidate is CityPlan:
		_city = city_candidate as CityPlan
	if manager_candidate is ChunkManager:
		_manager = manager_candidate as ChunkManager
	if player_candidate is Node3D:
		_player = player_candidate as Node3D
	if _manager != null and is_instance_valid(_manager):
		_world = _manager.world_plan if _manager.world_plan != null else WorldPlan.new(_city.seed_used)


func _protect_player() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var health_component: Variant = _player.get("health")
	if health_component != null and is_instance_valid(health_component):
		health_component.set("max_health", 1000000000.0)
		health_component.set("current_health", 1000000000.0)
	# The capture camera/manager needs the player's position, not player input
	# or physics. Keep the live player stationary and invulnerable while the
	# real Forward+ world streams around the requested viewpoints.
	_player.process_mode = Node.PROCESS_MODE_DISABLED


func _process(_delta: float) -> void:
	_protect_player()


func _wait_for_main_world(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _main != null and is_instance_valid(_main):
			var city_candidate: Variant = _main.get("city_plan")
			var manager_candidate: Variant = _main.get("chunk_manager")
			var player_candidate: Variant = _main.get("player")
			if city_candidate != null and manager_candidate != null and player_candidate != null:
				return
		await _wait(0.25)


func _run() -> void:
	await _until_ready(75.0)
	if _player == null or _city == null:
		print("[G10P2BCapture] no live player/city plan")
		get_tree().quit(2)
		return
	var graph: Dictionary = _city.road_graph()
	var hub := _city.find_spawn_point()
	var core := _pick_core_point(hub)
	var diagonal := _pick_primary_point(graph, 0.28, hub)
	var junction := _pick_junction(graph, hub)
	var dense := _pick_dense_point(hub)
	var outer := _pick_outer_point(graph, dense)
	var crossing := _pick_river_crossing(hub)
	print("[G10P2BCapture] targets hub=", hub, " core=", core, " diagonal=", diagonal,
			" junction=", junction, " dense=", dense, " outer=", outer,
			" crossing=", crossing)

	await _move_player(core)
	await _capture_tilted("01_irregular_historic_core.png", core, 18.0, 4.0, 78.0,
			_road_azimuth(core, &""))
	# Broad aerial evidence must be captured from the same loaded area it
	# depicts; keep the broad city view centered on the hub. The river crossing
	# is captured separately from its own streamed chunk below.
	await _move_player(hub)
	await _capture_top("06_broad_aerial_city.png", hub, 220.0, 76.0)

	await _move_player(diagonal)
	await _capture_top("02_radial_diagonal_route.png", diagonal, 120.0, 75.0)

	await _move_player(junction)
	await _capture_tilted("03_non90_intersection.png", junction, 72.0, 42.0, 80.0,
			_road_azimuth(junction, &"secondary"))

	await _move_player(dense)
	await _capture_tilted("04_dense_inner_neighborhood.png", dense, 38.0, 22.0, 76.0,
			_road_azimuth(dense, &"local"))

	await _move_player(outer)
	await _capture_tilted("05_city_outer_transition.png", outer, 100.0, 42.0, 70.0)

	await _move_player(crossing)
	await _capture_top("07_river_bridge_influence.png", crossing, 82.0, 72.0)

	print("[G10P2BCapture] all captures done")
	get_tree().quit(0)


func _until_ready(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _manager != null and _player != null:
			if _manager.pending_count() == 0 and _manager.active_count() >= 9:
				await _wait(1.0)
				return
		await _wait(0.25)


func _move_player(p: Vector2) -> void:
	var y := _world.surface_height_at(p) + 1.0
	_player.global_position = Vector3(p.x, y, p.y)
	var target_coord := WorldSeed.chunk_coord(p.x, p.y)
	await _wait(0.35)
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline:
		var at_target := _manager.last_player_chunk() == target_coord
		var target_active := _manager.is_resident(target_coord) \
				and _manager.state_of(target_coord) == &"active"
		if at_target and target_active and _manager.pending_count() == 0 \
				and _manager.active_count() >= 9:
			break
		await _wait(0.25)
	print("[G10P2BCapture] move target=", target_coord,
			" player_chunk=", _manager.last_player_chunk(),
			" active=", _manager.active_count(),
			" pending=", _manager.pending_count())
	await _wait(CAPTURE_WAIT)


func _pick_core_point(fallback: Vector2) -> Vector2:
	var best := fallback
	var best_count := 0
	for z in range(-240, 241, 16):
		for x in range(-240, 241, 16):
			var p := Vector2(x, z)
			if p.length() > 290.0:
				continue
			var count := _city.buildings_in_rect(Rect2(p - Vector2(48.0, 48.0), Vector2(96.0, 96.0))).size()
			if count > best_count:
				best_count = count
				best = _city.nearest_city_road_point(p)
	return best if best != Vector2.INF else fallback


func _pick_primary_point(graph: Dictionary, t: float, fallback: Vector2) -> Vector2:
	var best := fallback
	var best_len := 0.0
	for edge: Dictionary in graph.get("edges", []):
		if edge.get("hierarchy", &"") != &"primary":
			continue
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var p := poly[clampi(int(floor(float(poly.size() - 1) * t)), 0, poly.size() - 1)]
		var d := p.length()
		if d > best_len and d < 500.0:
			best_len = d
			best = p
	return best


func _pick_junction(graph: Dictionary, fallback: Vector2) -> Vector2:
	var best := fallback
	var best_score := 0
	for node: Dictionary in graph.get("nodes", []):
		var p: Vector2 = node.get("center", fallback) as Vector2
		var degree := int(node.get("degree", 0))
		if degree > best_score and p.length() < 300.0:
			best_score = degree
			best = p
	return best


func _pick_dense_point(fallback: Vector2) -> Vector2:
	var best := fallback
	var best_count := 0
	for z in range(-260, 261, 32):
		for x in range(-260, 261, 32):
			var p := Vector2(x, z)
			if p.length() > 420.0:
				continue
			var count := _city.buildings_in_rect(Rect2(p - Vector2(64.0, 64.0), Vector2(128.0, 128.0))).size()
			if count > best_count:
				best_count = count
				best = p
	return best if best != Vector2.INF else fallback


func _pick_outer_point(graph: Dictionary, fallback: Vector2) -> Vector2:
	var best := fallback
	var best_radius := 0.0
	var best_count := -1
	for edge: Dictionary in graph.get("edges", []):
		if edge.get("hierarchy", &"") != &"primary":
			continue
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		for p: Vector2 in poly:
			var r := p.length()
			if r < 460.0 or r > 620.0:
				continue
			var count := _city.buildings_in_rect(Rect2(p - Vector2(70.0, 70.0), Vector2(140.0, 140.0))).size()
			if count > best_count or (count == best_count and r > best_radius):
				best_count = count
				best_radius = r
				best = p
	return best


func _pick_river_crossing(fallback: Vector2) -> Vector2:
	var crossing := fallback
	var best_distance := INF
	for landmark: Dictionary in _city.city_landmarks():
		if landmark.get("kind", &"") != &"river_crossing":
			continue
		var p: Vector2 = landmark.get("center", fallback) as Vector2
		var d := p.distance_to(fallback)
		if d < best_distance:
			best_distance = d
			crossing = p
	return crossing


func _road_azimuth(center: Vector2, hierarchy: StringName) -> float:
	var best_angle := -0.72
	var best_distance := INF
	for edge: Dictionary in _city.road_graph().get("edges", []):
		if hierarchy != &"" and edge.get("hierarchy", &"") != hierarchy:
			continue
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var delta := b - a
			if delta.length_squared() < 0.01:
				continue
			var d := ((a + b) * 0.5).distance_to(center)
			if d < best_distance:
				best_distance = d
				best_angle = atan2(delta.y, delta.x)
	return best_angle


func _capture_top(file_name: String, center: Vector2, height: float, fov: float) -> void:
	var camera := Camera3D.new()
	var target := Vector3(center.x, _world.surface_height_at(center), center.y)
	camera.position = Vector3(center.x, target.y + height, center.y)
	camera.fov = fov
	camera.far = 2400.0
	add_child(camera)
	camera.look_at(target, Vector3.FORWARD)
	camera.make_current()
	await _wait_frames()
	_snap(file_name)
	camera.queue_free()
	await get_tree().process_frame


func _capture_tilted(file_name: String, center: Vector2, distance: float,
		elevation: float, fov: float, camera_azimuth := -0.72) -> void:
	var camera := Camera3D.new()
	var azimuth := camera_azimuth
	var direction := Vector3(cos(azimuth), 0.0, sin(azimuth))
	var target: Vector3
	var camera_position: Vector3
	if file_name.begins_with("05_"):
		# Stand just beyond the outer city and look inward across the last
		# developed frontage. This makes the density falloff visible in one
		# authentic player-view frame instead of showing an isolated edge chunk.
		var outward := Vector2(center.x, center.y).normalized()
		if outward.length_squared() < 0.01:
			outward = Vector2.RIGHT
		var look_p := center - outward * 52.0
		target = Vector3(look_p.x, _world.surface_height_at(look_p) + 4.0, look_p.y)
		camera_position = Vector3(center.x, _world.surface_height_at(center) + 4.0, center.y)
		camera_position += Vector3(outward.x, 0.0, outward.y) * distance
	else:
		target = Vector3(center.x, _world.surface_height_at(center) + 4.0, center.y)
		camera_position = target + Vector3(direction.x, 0.0, direction.z) * distance
	camera_position.y += tan(deg_to_rad(elevation)) * distance
	camera.position = camera_position
	camera.fov = fov
	camera.far = 2400.0
	add_child(camera)
	camera.look_at(target, Vector3.UP)
	camera.make_current()
	await _wait_frames()
	_snap(file_name)
	camera.queue_free()
	await get_tree().process_frame


func _wait_frames() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame


func _snap(file_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var image := get_viewport().get_texture().get_image()
	var path := OUT_DIR + "/" + file_name
	image.save_png(path)
	print("[G10P2BCapture] saved ", path, " ", image.get_width(), "x", image.get_height())


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
