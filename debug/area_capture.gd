extends Node
## Area capture: boots the REAL streamed city (windowed) and screenshots named
## areas from cameras placed by this harness.
##
##   godot --path . -- --areacapture        (windowed: real Forward+ rendering)
##
## Design notes (each learned from a broken capture):
##  * The PLAYER is only ever parked on street ground in front of the target
##    building. Teleporting the player into a building dropped it through
##    floor-less interior space and the anti-fall guard yanked it back
##    ("Pulled back from the void!"), which both ruined the shot and moved the
##    streaming centre. Cameras go where the player cannot: cameras do not fall.
##  * The game's own camera is an overhead city rig, so every shot uses a
##    temporary Camera3D. Without this the "interior" frames were rooftops.
##  * The debug stat overlay is hidden: it is a full-screen text panel whose
##    translucent background washed out every frame.
##  * Shots are taken at a settable clock (RB_CLOCK_HOUR) so "why is it dark"
##    is answerable by measurement rather than argument.
##
## Out: res://captures/areas[_<tag>]/*.png

const OUT_DIR := "res://captures/areas"
const SETTLE_S := 1.2

var _mgr: ChunkManager
var _player: Node3D
var _shots := 0
var _out_dir := OUT_DIR
var _cert_tag := ""
var _spec: Dictionary = {}
var _fh := 3.1
var _ground := 0.0
var _door_world := Vector2.ZERO
var _outer := Vector2.ZERO
var _rise := 0.0
var _access_kind := "none"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[AreaCapture] needs a windowed run - the headless dummy renderer cannot capture 3D")
		get_tree().quit(0)
		return
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[AreaCapture] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _run() -> void:
	await _until(func() -> bool:
			return not get_tree().get_nodes_in_group(&"chunk_manager").is_empty(), 240.0)
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	if managers.is_empty():
		print("[AreaCapture] no chunk manager after 240 s (world did not boot)")
		return get_tree().quit(1)
	_mgr = managers[0] as ChunkManager
	await _until(func() -> bool:
			return ActorRegistry.get_actor(&"player") != null, 120.0)
	_player = ActorRegistry.get_actor(&"player") as Node3D
	if _player == null:
		print("[AreaCapture] no player spawned after 120 s")
		return get_tree().quit(1)
	print("[AreaCapture] world up: active=%d" % _mgr.active_count())

	_cert_tag = OS.get_environment("RB_CAPTURE_TAG")
	if _cert_tag != "":
		_out_dir = OUT_DIR + "_" + _cert_tag
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))

	# Hide the debug stat overlay: its translucent full-screen panel swamped
	# every frame (and made "texture energy" measure text edges).
	var overlay := get_node_or_null("/root/DebugOverlay") as CanvasLayer
	if overlay != null and is_instance_valid(overlay):
		overlay.visible = false

	# Clock control: RB_CLOCK_HOUR reproduces a specific hour (e.g. 7.5 to match
	# a dawn report). GameClock.advance() takes MINUTES from a 07:00 start.
	var want_hour := 12.0
	var hour_env := OS.get_environment("RB_CLOCK_HOUR")
	if hour_env != "":
		want_hour = float(hour_env)
	GameClock.advance(want_hour * 60.0 - float(GameClock.get_minute_of_day()))
	print("[AreaCapture] clock %s" % GameClock.time_string())

	_player.health.max_health = 1000000.0
	_player.health.current_health = 1000000.0

	_pick_building()
	if _spec.is_empty():
		print("[AreaCapture] no building found")
		return get_tree().quit(1)
	print("[AreaCapture] target %s use=%s floors=%d access=%s" % [
		str(_spec.get("id", "?")), str(_spec.get("use", "?")),
		int(_spec.get("floors", 1)), str((_spec.get("access", {}) as Dictionary).get("kind", "none"))])

	# Park the player on the street in front of the entrance: safe ground, and
	# it keeps the target building's chunks warm for every interior camera.
	var stand := _door_world + _outer * 9.0
	_player.global_position = Vector3(stand.x, _ground + 0.6, stand.y)
	await _until(func() -> bool:
			return _mgr.is_resident(WorldSeed.chunk_coord(stand.x, stand.y)) \
					and _mgr.pending_count() == 0, 60.0)
	await _wait(2.0)

	# --- 01 veranda / entrance, from the street ------------------------------
	# Aim at the ENTRY DECK, not the door, and keep the camera on the street:
	# standing 11 m out put the camera inside the building opposite (streets are
	# ~8-10 m wide), which is why the "entrance" frame showed a neighbour's wall.
	var deck_pt := _door_world + _outer * 0.8
	var eye_y := _ground + _rise + 1.85
	var outside := _door_world + _outer * 6.2
	await _shot(Vector3(outside.x, eye_y, outside.y),
			_yaw_to_xy(outside, deck_pt), -7.0, "01_veranda_entrance")
	# A low street-level frame: this is the view that shows deck + posts + the
	# steps meeting the pavement.
	var low := _door_world + _outer * 4.2
	await _shot(Vector3(low.x, _ground + 1.15, low.y),
			_yaw_to_xy(low, deck_pt), 5.0, "01b_veranda_low")

	# --- 02 street canyon ----------------------------------------------------
	var along := Vector2(-_outer.y, _outer.x)
	var street_a := _door_world + along * 26.0 + _outer * 7.0
	var street_b := _door_world - along * 26.0 + _outer * 7.0
	await _shot(Vector3(street_a.x, _ground + 1.7, street_a.y),
			_yaw_to_xy(street_a, street_b), 0.0, "02_street_canyon")

	# --- 03 plaza ------------------------------------------------------------
	var plaza := _named_square()
	if plaza != Vector2.INF:
		await _shot(Vector3(plaza.x - 12.0, _ground + 1.7, plaza.y - 12.0),
				_yaw_to_xy(Vector2(plaza.x - 12.0, plaza.y - 12.0), plaza), 2.0, "03_plaza")
	else:
		print("[AreaCapture] no named square - skipping 03_plaza")

	# --- 04/05 interiors (cameras inside; the player stays outside) ----------
	var inner := _inner_rect()
	await _shot(Vector3(inner.get_center().x, _ground + 1.62, inner.get_center().y),
			_yaw_to_xy(inner.get_center(), inner.get_center() + _outer), 0.0, "04_interior_lobby")

	var room := _non_lobby_room()
	if not room.is_empty():
		await _shot(Vector3(room["center"].x, _ground + 1.62, room["center"].y),
				_yaw_to_xy(room["center"], room["center"] + _outer), 0.0, "05_interior_room")
	else:
		print("[AreaCapture] no non-lobby ground room - skipping 05_interior_room")

	# --- 07 upper floor ------------------------------------------------------
	if int(_spec.get("floors", 1)) > 1:
		await _shot(Vector3(inner.get_center().x, _ground + _fh + 1.62, inner.get_center().y),
				_yaw_to_xy(inner.get_center(), inner.get_center() + _outer), 0.0, "07_interior_upper")
	else:
		print("[AreaCapture] single storey - skipping 07_interior_upper")

	# --- 06 stairwell: stand back from the flight and look along it ----------
	var zone: Rect2 = BuildingBuilder.stair_zone_world(_spec)
	var z_n := zone.position.y
	var zm := (z_n + BuildingBuilder.LAND + zone.end.y - BuildingBuilder.LAND) * 0.5
	var lane_w := zone.position.x + BuildingBuilder.LANE_W * 0.5
	# Stand on the ground-floor landing and look ALONG the first flight, which
	# is what "stairs" means to a viewer. (Framing from outside the shaft only
	# ever showed the wing wall.)
	var stair_from := Vector2(lane_w, z_n + BuildingBuilder.LAND * 0.5)
	var stair_to := Vector2(lane_w, zm)
	await _shot(Vector3(stair_from.x, _ground + 1.6, stair_from.y),
			_yaw_to_xy(stair_from, stair_to), 12.0, "06_stairwell")
	# A second stair view from the upper landing looking back down the shaft.
	if int(_spec.get("floors", 1)) > 1:
		var down_from := Vector2(lane_w, zone.end.y - BuildingBuilder.LAND * 0.5)
		var down_to := Vector2(lane_w, zm)
		await _shot(Vector3(down_from.x, _ground + _fh + 1.6, down_from.y),
				_yaw_to_xy(down_from, down_to), -14.0, "06b_stairwell_down")

	# --- 08 overview ---------------------------------------------------------
	await _overview("08_overview")

	print("[AreaCapture] all captures done (%d) in %s" % [_shots,
			ProjectSettings.globalize_path(_out_dir)])
	get_tree().quit(0)


## Take a shot from a temporary camera at `pos` facing yaw/pitch degrees.
func _shot(pos: Vector3, yaw: float, pitch_deg: float, name: String) -> void:
	var old_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.position = pos
	cam.rotation = Vector3(deg_to_rad(pitch_deg), yaw, 0.0)
	cam.fov = 72.0
	cam.near = 0.05
	add_child(cam)
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait(SETTLE_S)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_out_dir, name])
	_shots += 1
	print("[AreaCapture] saved %s" % name)
	if old_cam != null and is_instance_valid(old_cam):
		old_cam.make_current()
	cam.queue_free()
	await get_tree().process_frame


func _overview(file_name: String) -> void:
	var old_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.position = Vector3(_door_world.x, 78.0, _door_world.y)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.fov = 78
	add_child(cam)
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_out_dir, file_name])
	_shots += 1
	print("[AreaCapture] saved %s" % file_name)
	if old_cam != null and is_instance_valid(old_cam):
		old_cam.make_current()
	cam.queue_free()
	await get_tree().process_frame


## Yaw that makes a camera at `from` (XZ) look toward `to` (XZ).
## Camera3D looks down -Z, so this is NOT the player's +Z facing formula.
func _yaw_to_xy(from: Vector2, to: Vector2) -> float:
	return atan2(-(to.x - from.x), -(to.y - from.y))


## Prefer a RAISED building with access enabled (verandas only exist on raised
## foundations) and stairs, so one capture set covers entrance + stairs + upper.
func _pick_building() -> void:
	var spawn := _mgr.plan.find_spawn_point()
	# Search the WHOLE city: verandas only exist on buildings with an elevated
	# foundation, which are not necessarily near the spawn.
	var specs: Array = _mgr.plan.city_buildings()
	var world_plan: WorldPlan = _mgr.world_plan if _mgr.world_plan != null 			else WorldPlan.new(_mgr.plan.seed_used)
	var best: Dictionary = {}
	var best_score := -1000
	var verandas := 0
	for spec_variant in specs:
		var raw: Dictionary = spec_variant
		var spec: Dictionary = ChunkBuilder._grounded_spec(raw, world_plan)
		if str((spec.get("access", {}) as Dictionary).get("kind", "none")) == "veranda":
			verandas += 1
		var rect: Rect2 = spec["rect"]
		var floors := int(spec.get("floors", 1))
		var access: Dictionary = spec.get("access", {}) as Dictionary
		var kind := str(access.get("kind", "none"))
		var score := 0
		if kind == "veranda":
			score += 4
		elif kind == "porch":
			score += 2
		if floors > 1 and BuildingBuilder.has_stairs_for(rect.size,
				float(spec.get("floor_h", 3.1)), floors):
			score += 3
		var dist := rect.get_center().distance_to(spawn)
		if dist < 260.0:
			score += 1
		if score > best_score:
			best_score = score
			best = spec
	print("[AreaCapture] scanned %d buildings, %d with a veranda" % [specs.size(), verandas])
	if best.is_empty():
		return
	_spec = best
	_fh = float(_spec.get("floor_h", 3.1))
	_ground = float(_spec.get("building_ground_y", _spec.get("ground_y", 0.0)))
	var acc: Dictionary = _spec.get("access", {}) as Dictionary
	_rise = float(acc.get("rise", 0.0))
	_access_kind = str(acc.get("kind", "none"))
	var rect: Rect2 = _spec["rect"]
	var edge := int(_spec.get("door_edge", 0))
	_door_world = ChunkBuilder._front_of(rect, edge, 0.5)
	_outer = BuildingBuilder._access_outward(edge)


func _has_veranda() -> bool:
	var access: Dictionary = _spec.get("access", {}) as Dictionary
	return str(access.get("kind", "none")) == "veranda"


func _inner_rect() -> Rect2:
	var rect: Rect2 = _spec["rect"]
	var inset := BuildingBuilder.WALL_T + 0.6
	return Rect2(rect.position + Vector2(inset, inset),
			(rect.size - Vector2(inset, inset) * 2.0).max(Vector2(1.0, 1.0)))


func _non_lobby_room() -> Dictionary:
	var manifest := InteriorPlan.build_for_building(_spec)
	var floors: Array = manifest.get("floors", [])
	if floors.is_empty():
		return {}
	var fl: Dictionary = floors[0]
	var rect: Rect2 = _spec["rect"]
	for room_variant in fl.get("rooms", []):
		var room: Dictionary = room_variant
		var kind := str(room.get("kind", ""))
		if kind == "lobby" or kind == "hall" or kind == "stairs":
			continue
		var rr: Rect2 = room["rect"]
		var centre := rect.position + rr.get_center()
		if str(fl.get("topology", "")) != "lobby":
			centre = rr.get_center()
		return {"center": centre, "kind": kind}
	return {}


func _named_square() -> Vector2:
	for node_variant in _mgr.plan.city_nodes():
		var node: Dictionary = node_variant
		var nid := str(node.get("id", ""))
		if nid == "market_square" or nid == "civic_square":
			return node.get("center", Vector2.INF) as Vector2
	return Vector2.INF


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _until(pred: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if pred.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return false
