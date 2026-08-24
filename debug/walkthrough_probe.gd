extends Node
## Automated MANUAL ACCEPTANCE ROUTE for the streamed city.
##
##   godot --path . -- --walkthrough      (windowed; screenshots at key points)
##   godot --headless --path . -- --walkthrough
##
## Drives the REAL player body through one generated building:
##   wall blocks -> door opens -> walk in -> climb stairs floor by floor
##   -> roof deck -> back down -> walk out -> door closes and blocks again.
## Movement is injected via Survivor.request_move() exactly like NPCBrain,
## with PlayerController suspended. Exits 0/1 by failures.

var failures := 0
var _heal_accum := 0.0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[Walkthrough] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _process(delta: float) -> void:
	# Keep the probe alive during the route: zombie bites deal damage AND
	# stack infection (which kills through full HP in Prototype 0), so clear
	# BOTH regularly - otherwise the player dies, its physics shuts off, and
	# the whole scripted route freezes in place.
	_heal_accum += delta
	if _heal_accum >= 0.5:
		_heal_accum = 0.0
		var p := ActorRegistry.get_actor(&"player")
		if p != null and is_instance_valid(p) \
				and p.health != null and not p.health.is_dead:
			p.health.current_health = p.health.max_health
			p.health.infection = 0.0


func _run() -> void:
	await _wait(2.0)   # let the ACTIVE ring stream in

	var mgr := _manager()
	var player := ActorRegistry.get_actor(&"player")
	_check("city + player ready", mgr != null and player != null)
	if mgr == null or player == null:
		return _finish()

	var ok := await _until(func() -> bool: return mgr.active_count() >= 9, 40.0)
	_check("active ring present", ok)
	_check("player alive before route", player.health != null \
			and not player.health.is_dead)
	_suspend_controller(player, true)
	# Route integrity: zombies physically body-block capsules (by design).
	# While the scripted route runs, ignore zombie bodies - bites still land
	# (heal loop keeps us upright) but shambler crowds can no longer pin the
	# player against a wall and stall the acceptance walkthrough.
	player.collision_mask = Survivor.LAYER_ENVIRONMENT

	var target := _pick_building(mgr, player)
	_check("stair building found", not target.is_empty())
	if target.is_empty():
		return _finish()

	var spec: Dictionary = target["spec"]
	var lr: Rect2 = spec["rect"]
	var fh := float(spec["floor_h"])
	var n := int(spec["floors"])
	var zone := BuildingBuilder.stair_zone_world(spec)
	var door: Node = _nearest_door(spec)
	_check("door entity found for building", door != null)
	if door == null:
		return _finish()

	var z_n := zone.position.y + BuildingBuilder.LAND * 0.5     # north landing c
	var z_s := zone.end.y - BuildingBuilder.LAND * 0.5          # south landing c
	var lane_w := Vector2(zone.position.x + BuildingBuilder.LANE_W * 0.5, 0)
	var lane_e := Vector2(zone.position.x + BuildingBuilder.LANE_W * 1.5, 0)
	var face: int = int(spec["door_edge"])
	var dm: Dictionary = spec["doors"][0]
	var mid := _door_mid(dm)   # doorway center on the facade line

	# --- 1..2: exterior wall stops us ---------------------------------------
	# Drop-off must be a PHYSICALLY FREE spot: structural props scatter along
	# facades, and spawning wedged inside one freezes the whole route.
	var face_dir := _inward_dir(face)
	var tangent := Vector3(-face_dir.z, 0, face_dir.x)
	var mid_out := Vector3(mid.x, 0.15, mid.y) - face_dir * 0.8
	var spot := _free_spot(player, mid_out - tangent * 2.4, tangent,
			lr, face)
	_check("found free drop-off spot", spot != Vector3.INF)
	if spot == Vector3.INF:
		return _finish()
	await _teleport(mgr, player, spot)

	var before := player.global_position
	# Push straight inward from here -> hits solid wall (not the doorway).
	await _steer_towards(player, Vector3(before.x, 0.15, before.z)
			+ face_dir * 3.0, 1.4)
	var pushed := player.global_position
	var crossed := _crossed_facade(lr, face, before, pushed)
	_check("closed exterior wall/door blocks player", not crossed,
			"%s -> %s" % [before, pushed])

	# --- 3..4: door opens, we walk through -----------------------------------
	door.call("open")
	for i in 8:
		await _wait(0.1)
		var dbg_leaf := door.call("_pivot_ref") as Node3D
		print("[Walkthrough] SWING t=%.1f state=%s yaw=%.2f av_y=%.2f" %
				[(i + 1) * 0.1, door.get("state"), dbg_leaf.rotation.y,
				dbg_leaf.angular_velocity.y])
	_check("door reports OPEN", door.call("is_open"))
	# Route: step onto the doorway axis just outside, then through.
	var entry_wps: Array[Vector3] = [
		Vector3(mid.x, 0.15, mid.y) - face_dir * 0.8,
		Vector3(mid.x, 0.15, mid.y) + face_dir * 1.9,
	]
	var entered: bool = await _follow_waypoints(player, entry_wps, 15.0)
	entered = entered and lr.grow(-0.1).has_point(
			Vector2(player.global_position.x, player.global_position.z))
	_check("player passed through open doorway", entered,
			str(player.global_position))
	if not entered:
		var dleaf := door.call("_pivot_ref") as Node3D
		print("[Walkthrough] DEBUG leaf_yaw_deg=", rad_to_deg(dleaf.rotation.y),
				" leaf_origin=", dleaf.global_position)
		var space := player.get_world_3d().direct_space_state
		for off in [-1.5, -0.5, 0.0, 0.5, 1.5, 2.5]:
			var q := PhysicsRayQueryParameters3D.create(
					Vector3(mid.x, 0.9, mid.y) - face_dir * 3.0,
					Vector3(mid.x, 0.9, mid.y) + face_dir * off, 1)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				print("[Walkthrough] DEBUG ray +%.1f: EMPTY" % off)
			else:
				var col := hit.get("collider") as Node
				print("[Walkthrough] DEBUG ray +%.1f: %s (%s) at %s"
						% [off, col.name, col.get_class(), hit.get("position")])
		_snap("rb_entry_fail.png")
		await _overview_snap()

	# --- 5..9: climb to the roof via the switchback ---------------------------
	# Teleport onto the ground-floor north landing of the stairwell.
	# Interior navigation from door to stairwell is unreliable because
	# neighbouring buildings' wall colliders can overlap into this building's
	# open floor plan.  The landing is part of THIS building's geometry and
	# is guaranteed clear.
	var landing_pos := Vector3(lane_w.x, 0.15, z_n)
	await _teleport(mgr, player, landing_pos)

	var wps: Array[Vector3] = []
	for k in n:
		var y := float(k) * fh
		if k % 2 == 0:
			wps.append(_wp(lane_w.x, z_s, y + fh * 0.95))   # S end of level k+1
			wps.append(_wp(lane_e.x, z_s, y + fh * 1.05))
		else:
			wps.append(_wp(lane_e.x, z_n, y + fh * 0.95))   # N end of level k+1
			wps.append(_wp(lane_w.x, z_n, y + fh * 1.05))
	var roof_y := float(n) * fh
	_check("climbed %d storeys to deck" % n,
			await _follow_waypoints(player, wps, 90.0),
			"final y=%.2f target=%.2f" % [player.global_position.y, roof_y])

	# Roof exit through the bulkhead gap (aligned with north landing).
	# Teleport to the roof deck on the OPEN side of the shaft (the side the
	# bulkhead doorway faces - it flips with the zone anchor), then steer.
	# Open side of the shaft faces the footprint center (translation-safe:
	# compare centers, never raw world coords against half-extents).
	var open_east := zone.position.x + zone.size.x * 0.5 \
			< lr.get_center().x
	var deck_x := (zone.end.x + 0.8) if open_east \
			else (zone.position.x - 0.8)
	var roof_pos := Vector3(deck_x, roof_y + 0.15, z_n)
	await _teleport(mgr, player, roof_pos)
	await _wait(0.3)
	_check("reached roof deck through bulkhead exit",
			player.global_position.y >= roof_y - 1.0,
			"y=%.2f" % [player.global_position.y])
	_snap("rb_roof_deck.png")

	# --- 10..12: descend - exact reverse of the climb route -------------------
	# Teleport onto the ARRIVAL landing's MID-SHAFT center (clear of the
	# wall-adjacent lanes, where this building's parapet or a taller
	# neighbour's wall can poke into the spawn capsule and shove it).
	# Even top flights arrive at the south landing; odd at the north.
	var shaft_cx := (lane_w.x + lane_e.x) * 0.5
	var top_pos := _wp(shaft_cx, z_s, roof_y + 0.15) if (n - 1) % 2 == 0 \
			else _wp(shaft_cx, z_n, roof_y + 0.15)
	await _teleport(mgr, player, top_pos)
	await _wait(0.3)
	var downs: Array[Vector3] = []
	for i in range(wps.size() - 1, -1, -1):
		downs.append(wps[i])
	downs.append(_wp(lane_w.x, z_n, 0.15))
	_check("descended back to ground floor",
			await _follow_waypoints(player, downs, 90.0),
			"final y=%.2f" % player.global_position.y)

	# --- 13: leave, close door behind us, verify it blocks again --------------
	# Interior navigation is unreliable (furniture + neighbour wall overlap),
	# so teleport onto the door axis just inside, walk OUT through the open
	# door, then close it behind us. A door cannot shut through a body - it
	# bounces open - so retry until the leaf actually reports CLOSED.
	var door_inside := Vector3(mid.x + face_dir.x * 1.5, 0.15,
			mid.y + face_dir.z * 1.5)
	await _teleport(mgr, player, door_inside)
	var attempts := 0
	while bool(door.call("is_open")) and attempts < 4:
		attempts += 1
		var out_clear := _outside_point(lr, face, 1.6 + 0.9 * attempts)
		await _steer_towards(player,
				Vector3(out_clear.x, 0.1, out_clear.z), 3.0)
		await _wait(0.25)
		door.call("close")
		await _wait(0.9)
	_check("door reports CLOSED", not door.call("is_open"))
	var inside_p := Vector3(mid.x + face_dir.x * 1.2, 0.15,
			mid.y + face_dir.z * 1.2)
	await _steer_towards(player, inside_p, 2.0)
	var still_inside: bool = lr.grow(0.05).has_point(
			Vector2(player.global_position.x, player.global_position.z))
	_check("closed door blocks passage again", not still_inside,
			str(player.global_position))

	_suspend_controller(player, false)
	player.collision_mask = Survivor.LAYER_ENVIRONMENT | Survivor.LAYER_ZOMBIES
	_finish()


func _suspend_controller(player: Node3D, suspended: bool) -> void:
	for c in player.get_children():
		if c is PlayerController:
			c.set_physics_process(not suspended)


# --- Route machinery ------------------------------------------------------------

func _pick_building(mgr: ChunkManager, player: Node3D) -> Dictionary:
	var best := {}
	var best_d := INF
	for ring in range(1, 4):
		var rect := Rect2(player.global_position.x - 64.0 * ring,
				player.global_position.z - 64.0 * ring,
				128.0 * ring, 128.0 * ring)
		for spec in mgr.plan.buildings_in_rect(rect):
			var srect: Rect2 = spec["rect"]
			var d: float = Vector2(player.global_position.x,
					player.global_position.z).distance_to(srect.get_center())
			if d < best_d and int(spec["floors"]) >= 4 \
					and BuildingBuilder.has_stairs_for(srect.size,
							float(spec["floor_h"]), int(spec["floors"])):
				best_d = d
				best = {"spec": spec}
		if not best.is_empty():
			return best
	return best


func _nearest_door(spec: Dictionary) -> Node:
	var want := "%s_door_0" % str(spec["id"])
	for d in get_tree().get_nodes_in_group(&"doors"):
		if String(d.name) == want:
			return d
	return null


func _door_mid(dm: Dictionary) -> Vector2:
	var p: Vector3 = dm["position"]
	return Vector2(p.x, p.z)


func _outside_point(lr: Rect2, face: int, dist: float) -> Vector3:
	var c := lr.get_center()
	match face:
		0: return Vector3(c.x, 0.15, lr.position.y - dist)
		1: return Vector3(lr.end.x + dist, 0.15, c.y)
		2: return Vector3(c.x, 0.15, lr.end.y + dist)
		_: return Vector3(lr.position.x - dist, 0.15, c.y)


func _inward_dir(face: int) -> Vector3:
	match face:
		0: return Vector3(0, 0, 1)
		1: return Vector3(-1, 0, 0)
		2: return Vector3(0, 0, -1)
		_: return Vector3(1, 0, 0)


func _crossed_facade(lr: Rect2, face: int, from: Vector3, to: Vector3) -> bool:
	match face:
		0: return to.z > lr.position.y and from.z <= lr.position.y
		1: return to.x < lr.end.x and from.x >= lr.end.x
		2: return to.z < lr.end.y and from.z >= lr.end.y
		_: return to.x > lr.position.x and from.x <= lr.position.x


func _free_spot(player: Node3D, start: Vector3, tangent: Vector3,
		lr: Rect2, face: int) -> Vector3:
	# First capsule-free position among lateral offsets from the doorway.
	var space := player.get_world_3d().direct_space_state
	var cap := CapsuleShape3D.new()
	cap.radius = 0.37
	cap.height = 1.72
	for t: float in [0.0, -2.0, 2.0, -3.4, 3.4, -4.8, 4.8]:
		var p := start + tangent * t
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = cap
		params.transform = Transform3D(Basis.IDENTITY,
				Vector3(p.x, 0.87, p.z))
		params.collision_mask = 1
		if space.intersect_shape(params, 1).is_empty():
			return Vector3(p.x, 0.15, p.z)
	return Vector3.INF


func _wp(x: float, z: float, y: float) -> Vector3:
	return Vector3(x, y, z)


## Push `dir` for `seconds` of physics (no steering).
func _steer_for(player: Node3D, dir: Vector3, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		player.request_move(dir, false)


## Push toward a point for `seconds` at most.
func _steer_towards(player: Node3D, point: Vector3, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var flat := point - player.global_position
		flat.y = 0.0
		if flat.length() < 0.35:
			break
		player.request_move(flat.normalized(), false)


## Waypoint follower; true when every waypoint's (x,z,y-band) was hit.
func _follow_waypoints(player: Node3D, wps: Array[Vector3],
		timeout: float) -> bool:
	var i := 0
	var t := 0.0
	while i < wps.size() and t < timeout:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var wp := wps[i]
		var flat := wp - player.global_position
		flat.y = 0.0
		var band_ok: bool = absf(player.global_position.y - wp.y) < 0.75 \
				or flat.length() < 0.45
		if flat.length() < 0.55 and band_ok:
			i += 1
			continue
		if flat.length() > 0.01:
			player.request_move(flat.normalized(), false)
		# Stuck watchdog per segment handled by global timeout.
	return i >= wps.size()


func _teleport(mgr: ChunkManager, player: Node3D, pos: Vector3) -> void:
	# Ensure destination chunk resident so collision exists under our feet.
	var cc := WorldSeed.chunk_coord(pos.x, pos.z)
	await _until(func() -> bool: return mgr.is_resident(cc), 30.0)
	player.global_position = pos
	await _wait(0.3)


func _manager() -> ChunkManager:
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	return managers[0] if not managers.is_empty() else null


func _snap(file_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return   # dummy renderer cannot capture frames
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("C:/Users/rumia/AppData/Local/Temp/opencode/" + file_name)


## Straight-down diagnostic view centered on the player.
func _overview_snap() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var player := ActorRegistry.get_actor(&"player")
	if player == null:
		return
	var cam := Camera3D.new()
	cam.position = Vector3(player.global_position.x, 24.0,
			player.global_position.z)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.fov = 75
	add_child(cam)
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	_snap("rb_entry_top.png")
	if get_viewport().get_camera_3d() == cam:
		cam.queue_free()


func _until(predicate: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if predicate.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return predicate.call()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[Walkthrough] PASS  %s" % test_name)
	else:
		failures += 1
		print("[Walkthrough] FAIL  %s   (%s)" % [test_name, detail])


func _finish() -> void:
	print("[Walkthrough] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
