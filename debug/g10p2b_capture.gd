extends Node
## Authentic Forward+ visual acceptance capture for G10-P2B.
## The images are saved from the live game's viewport, never synthesized.

const OUT_DIR := "C:/Vibe Code project/Godot Project/ring-bell/captures/g10p2b_fix3_iter3_20260904"
const CAPTURE_WAIT := 3.0

var _main: Node3D
var _player: Node3D
var _city: CityPlan
var _world: WorldPlan
var _manager: ChunkManager
var _debug_overlay: CanvasLayer


func _ready() -> void:
	if DisplayServer.get_name() != "headless" and not OS.has_feature("headless"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1200, 720))
		await get_tree().process_frame
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
	var junction := _pick_junction(graph, hub)
	var wider := _pick_dense_point(hub)
	var courtyard := _pick_courtyard_block(hub)
	var alley_entrance := _pick_courtyard_entrance(courtyard, hub)
	var reveal_point := _pick_reveal_point(core)
	print("[G10P2BCapture] targets hub=", hub, " core=", core,
			" junction=", junction, " alley=", alley_entrance,
			" courtyard=", courtyard, " reveal=", reveal_point)
	_describe_nearby_blocks("core", core)

	await _move_player(core)
	await _capture_tilted("01_dense_historic_street.png", core, 18.0, 4.0, 78.0,
			_road_azimuth(core, &""))

	await _move_player(junction)
	await _capture_tilted("02_corner_intersection.png", junction, 56.0, 34.0, 78.0,
			_road_azimuth(junction, &"secondary"))

	await _move_player(alley_entrance)
	await _capture_tilted("03_narrow_alley_courtyard_entrance.png", alley_entrance,
			28.0, 18.0, 74.0, _road_azimuth(alley_entrance, &""))

	await _move_player(courtyard)
	await _capture_top("04_interior_courtyard_block.png", courtyard, 46.0, 78.0)

	await _move_player(wider)
	await _capture_top("05_wider_inner_city.png", wider, 112.0, 76.0)

	await _move_player(reveal_point)
	await _capture_reveal("06_reveal_parity_interior.png", reveal_point,
			_road_azimuth(reveal_point, &""))

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


func _describe_nearby_blocks(label: String, point: Vector2) -> void:
	var ranked: Array = []
	for block: Dictionary in _city.city_blocks():
		var center: Vector2 = block.get("center", point) as Vector2
		var distance := center.distance_to(point)
		if distance <= 110.0:
			ranked.append({"distance": distance, "block": block})
	ranked.sort_custom(_nearby_block_cmp)
	for i in mini(6, ranked.size()):
		var block: Dictionary = ranked[i]["block"] as Dictionary
		var bs: Array = block.get("buildings", []) as Array
		print("[G10P2BCapture] ", label, " block=", block.get("id", ""),
			" d=", ranked[i]["distance"], " kind=", block.get("kind", ""),
			" area=", absf(CityPlan._polygon_signed_area(block.get("polygon", PackedVector2Array()) as PackedVector2Array)),
			" buildings=", bs.size(), " frontage=", block.get("frontage_buildings", 0),
			" void=", block.get("void_reason", ""))


static func _nearby_block_cmp(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("distance", INF)) < float(b.get("distance", INF))


func _pick_core_point(fallback: Vector2) -> Vector2:
	var best := fallback
	var best_score := -1.0
	for z in range(-240, 241, 16):
		for x in range(-240, 241, 16):
			var p := Vector2(x, z)
			if p.length() > 290.0:
				continue
			var candidate := _city.nearest_city_road_point(p)
			if candidate == Vector2.INF:
				continue
			var angle := _road_azimuth(candidate, &"")
			var tangent := Vector2(cos(angle), sin(angle))
			var normal := Vector2(-tangent.y, tangent.x)
			var left := _count_buildings_in_road_band(candidate, tangent, normal, 1.0)
			var right := _count_buildings_in_road_band(candidate, tangent, normal, -1.0)
			var count := _city.buildings_in_rect(Rect2(candidate - Vector2(48.0, 48.0), Vector2(96.0, 96.0))).size()
			var score := float(mini(left, right)) * 10000.0 + float(count) * 100.0 - candidate.length()
			if score > best_score:
				best_score = score
				best = candidate
	return best if best != Vector2.INF else fallback


func _count_buildings_in_road_band(center: Vector2, tangent: Vector2,
		normal: Vector2, side: float) -> int:
	var count := 0
	for spec_variant in _city.city_buildings() as Array:
		var spec: Dictionary = spec_variant as Dictionary
		var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
		var delta := lot.get_center() - center
		var along := delta.dot(tangent)
		var lateral := delta.dot(normal) * side
		if absf(along) <= 52.0 and lateral >= 4.0 and lateral <= 34.0:
			count += 1
	return count


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
	var best_score := -1.0
	for node: Dictionary in graph.get("nodes", []):
		var p: Vector2 = node.get("center", fallback) as Vector2
		var degree := int(node.get("degree", 0))
		if p.length() < 300.0:
			var nearby := _city.buildings_in_rect(Rect2(p - Vector2(42.0, 42.0), Vector2(84.0, 84.0)))
			var corner_count := 0
			for spec_variant in nearby:
				var spec: Dictionary = spec_variant as Dictionary
				if str(spec.get("frontage_role", "")) == "corner":
					corner_count += 1
			var angle := _road_azimuth(p, &"")
			var tangent := Vector2(cos(angle), sin(angle))
			var normal := Vector2(-tangent.y, tangent.x)
			var side_density := mini(
				_count_buildings_in_road_band(p, tangent, normal, 1.0),
				_count_buildings_in_road_band(p, tangent, normal, -1.0))
			var score := float(side_density) * 100000.0 + float(corner_count) * 10000.0 + float(degree) * 1000.0 + float(nearby.size())
			if score > best_score:
				best_score = score
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


func _pick_courtyard_block(fallback: Vector2) -> Vector2:
	var best := fallback
	var best_score := -1.0
	var access_fallback := fallback
	var access_score := -1.0
	for block: Dictionary in _city.city_blocks():
		if block.get("kind", &"") != &"built":
			continue
		var center: Vector2 = block.get("center", fallback) as Vector2
		if center.length() > 290.0:
			continue
		var regions: Array = block.get("courtyard_regions", []) as Array
		var buildings: Array = block.get("buildings", []) as Array
		var passage: Dictionary = block.get("passage", {}) as Dictionary
		if not passage.is_empty() and buildings.size() >= 3:
			var passage_center: Vector2 = passage.get("entry_point",
					(passage.get("rect", Rect2()) as Rect2).get_center()) as Vector2
			var access_candidate := passage_center
			var access_candidate_score := float(buildings.size()) * 1000.0 - passage_center.distance_to(fallback)
			if access_candidate_score > access_score:
				access_score = access_candidate_score
				access_fallback = access_candidate
		if regions.is_empty() or buildings.size() < 2:
			continue
		var area := float(regions[0].get("area_m2", 0.0)) if regions[0] is Dictionary else 0.0
		var score := float(buildings.size()) * 1000.0 + area
		if not passage.is_empty():
			score += 50000.0
		if score > best_score:
			best_score = score
			best = regions[0].get("center", center) as Vector2
	return best if best_score >= 0.0 else access_fallback


func _pick_reveal_point(fallback: Vector2) -> Vector2:
	var best := fallback
	var best_score := -1.0
	for block: Dictionary in _city.city_blocks():
		var center: Vector2 = block.get("center", fallback) as Vector2
		if center.length() > 300.0:
			continue
		for spec_variant in block.get("buildings", []) as Array:
			var spec: Dictionary = spec_variant as Dictionary
			if str(spec.get("frontage_role", "")) == "rear":
				continue
			var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
			var lot_center := lot.get_center()
			var score := float(lot.size.x * lot.size.y) - lot_center.distance_to(fallback) * 0.05
			if score > best_score:
				best_score = score
				best = lot_center
	return best


func _pick_courtyard_entrance(courtyard: Vector2, fallback: Vector2) -> Vector2:
	var best := fallback
	var best_d := INF
	for block: Dictionary in _city.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		var target := center
		for region_variant in block.get("courtyard_regions", []) as Array:
			var region: Dictionary = region_variant as Dictionary
			var region_center: Vector2 = region.get("center", center) as Vector2
			if region_center.distance_to(courtyard) < target.distance_to(courtyard):
				target = region_center
		if target.distance_to(courtyard) > 8.0:
			continue
		var passage: Dictionary = block.get("passage", {}) as Dictionary
		if passage.is_empty():
			continue
		var passage_center: Vector2 = (passage.get("rect", Rect2()) as Rect2).get_center()
		var road_point := _city.nearest_city_road_point(passage_center)
		if road_point == Vector2.INF:
			road_point = passage_center
		var d := road_point.distance_to(courtyard)
		if d < best_d:
			best_d = d
			best = road_point
	return best


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


func _capture_reveal(file_name: String, center: Vector2, road_angle: float) -> void:
	var camera := Camera3D.new()
	var side := Vector2(cos(road_angle + PI * 0.5), sin(road_angle + PI * 0.5))
	var target := Vector3(center.x, _world.surface_height_at(center) + 2.0, center.y)
	var camera_point := center + side * 1.25
	camera.position = Vector3(camera_point.x, target.y, camera_point.y)
	camera.fov = 72.0
	camera.far = 2400.0
	add_child(camera)
	# The camera stands just off the selected building. Aim at the building
	# point itself; adding `side` here would point back out into the street.
	camera.look_at(target, Vector3.UP)
	camera.make_current()
	await _wait_frames()
	_snap(file_name)
	camera.queue_free()
	await get_tree().process_frame


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
