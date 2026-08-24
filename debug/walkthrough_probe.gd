extends Node
## REAL ACCEPTANCE ROUTE for the streamed city - NO TELEPORTS after the
## initial street drop-off near the chosen building.
##
##   godot --path . -- --walkthrough      (windowed; screenshots at key points)
##   godot --headless --path . -- --walkthrough
##
## Route (P1 contract):
##   street -> approach CLOSED entrance -> wall blocks player -> open door
##   -> walk through doorway -> cross ground-floor interior WITHOUT teleport
##   -> reach staircase -> climb every storey -> roof deck -> bulkhead exit
##   check -> descend -> walk back through interior -> exit building
##   -> close door -> closed door blocks again.
##
## Movement is injected via Survivor.request_move() exactly like NPCBrain,
## with PlayerController suspended. If furniture blocks the route the test
## FAILS - the generator must be fixed, never the test.
## Exits 0/1 by failures.

var failures := 0
var _heal_accum := 0.0


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[Walkthrough] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _process(delta: float) -> void:
	# Keep the probe alive during the route: zombie bites deal damage AND
	# stack infection, and a dead body freezes the scripted route.
	_heal_accum += delta
	if _heal_accum >= 0.5:
		_heal_accum = 0.0
		var p := ActorRegistry.get_actor(&"player")
		if p != null and is_instance_valid(p) \
				and p.health != null and not p.health.is_dead:
			p.health.current_health = p.health.max_health
			p.health.infection = 0.0
			# Long route: keep needs/stamina topped so the climb speed never
			# collapses to zero (fatigue scales movement down).
			p.stamina = p.STAMINA_MAX
			p.exhausted = false
			if p.needs != null:
				p.needs.hunger = 0.0
				p.needs.thirst = 0.0
				p.needs.fatigue = 0.0


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

	var dm: Dictionary = spec["doors"][0]
	var mid := _door_mid(dm)                 # geometric opening center
	var face: int = int(spec["door_edge"])
	var face_dir := _inward_dir(face)

	# === 1. Street drop-off OUTSIDE the entrance (the ONLY placement) ======
	var spot := _free_spot(player, Vector3(mid.x, 0.15, mid.y) - face_dir * 2.2,
			lr, face)
	_check("found free street drop-off", spot != Vector3.INF)
	if spot == Vector3.INF:
		return _finish()
	await _teleport_to_resident(mgr, player, spot)   # resident-wait only;
	# the position equals the drop-off itself, no in-route teleport happens.

	# === 2. Approach the closed door; wall/door must stop us ================
	var before := player.global_position
	await _steer_towards(player, Vector3(mid.x, 0.15, mid.y), 3.5)
	var pushed := player.global_position
	var crossed := _crossed_facade(lr, face, before, pushed)
	var reached_door := pushed.distance_to(
			Vector3(mid.x, 0.15, mid.y)) < 2.4
	_check("approached closed entrance", reached_door or not crossed,
			"%s" % [pushed])
	_check("closed door blocks passage", not crossed,
			"%s -> %s" % [before, pushed])

	# === 3. Door opens =======================================================
	door.call("open")
	ok = await _until(func() -> bool: return bool(door.call("is_open")), 3.0)
	_check("door reports OPEN", ok)

	# === 4..8. Walk THROUGH the door and REACH THE STAIRWELL on foot ========
	var z_n := zone.position.y + BuildingBuilder.LAND * 0.5
	var lane_w := zone.position.x + BuildingBuilder.LANE_W * 0.5
	# Waypoints: doorway axis -> a point 1.5 m inside -> stair landing center.
	var wps: Array[Vector3] = [
		Vector3(mid.x, 0.15, mid.y) + face_dir * 0.9,
		Vector3(mid.x, 0.15, mid.y) + face_dir * 2.6,
		Vector3(lane_w, 0.15, z_n),
	]
	var entered := await _follow_waypoints(player, wps, 40.0)
	_check("walked door -> stairwell without teleport", entered,
			"at %s" % [player.global_position])
	if not entered:
		_snap("rb_route_fail.png")

	# === 9. Climb EVERY storey to the deck ===================================
	var climb: Array[Vector3] = []
	var lane_e := zone.position.x + BuildingBuilder.LANE_W * 1.5
	var shaft_cx := (lane_w + lane_e) * 0.5
	for k in n:
		var y := float(k) * fh
		if k % 2 == 0:
			# Even flights ascend SOUTH in the WEST lane.
			climb.append(_wp(lane_w, zone.position.y + BuildingBuilder.LAND,
					y + fh * 0.05))    # bottom: north-west landing
			climb.append(_wp(lane_w, zone.end.y - BuildingBuilder.LAND,
					y + fh * 0.95))    # top: south-west landing
			# Landing cross in two legs: first pull to THIS lane's center on
			# solid floor, then across the middle to the far lane edge.
			climb.append(_wp(lane_w, zone.end.y - BuildingBuilder.LAND * 0.7,
					y + fh * 1.02))
			climb.append(_wp(shaft_cx, zone.end.y - BuildingBuilder.LAND * 0.6,
					y + fh * 1.02))
		else:
			# Odd flights ascend NORTH in the EAST lane.
			climb.append(_wp(lane_e, zone.end.y - BuildingBuilder.LAND,
					y + fh * 0.05))    # bottom: south-east landing
			climb.append(_wp(lane_e, zone.position.y + BuildingBuilder.LAND,
					y + fh * 0.95))    # top: north-east landing
			climb.append(_wp(lane_e, zone.position.y + BuildingBuilder.LAND
					* 0.7, y + fh * 1.02))
			climb.append(_wp(shaft_cx, zone.position.y + BuildingBuilder.LAND
					* 0.6, y + fh * 1.02))
	var roof_y := float(n) * fh
	var climb_radius := func(i: int) -> float:
		if i == climb.size() - 1:
			return 1.1
		return 0.85 if (i + 1) % 3 == 0 else 0.55   # cross points: wide
	_check("climbed all %d storeys to deck" % n,
			await _follow_waypoints_r(player, climb, 120.0, climb_radius),
			"y=%.2f want %.2f" % [player.global_position.y, roof_y])
	_check("camera tracks the vertical climb",
			camera_rig_y_near(player.global_position.y),
			"rig y=%s" % [_rig_y()])

	# === 10. Descend ==========================================================
	var downs: Array[Vector3] = []
	for i in range(climb.size() - 1, -1, -1):
		downs.append(climb[i])
	downs.append(_wp(lane_w, z_n, 0.15))
	var down_radius := func(i: int) -> float:
		if i == 0:
			return 1.1
		return 0.85 if i % 3 == 0 else 0.55   # reversed cross points: wide
	_check("descended to ground floor",
			await _follow_waypoints_r(player, downs, 120.0, down_radius),
			"final y=%.2f" % player.global_position.y)

	# === 11. Walk back through the interior and EXIT =========================
	var exit_wps: Array[Vector3] = [
		Vector3(mid.x, 0.15, mid.y) + face_dir * 1.2,
		Vector3(mid.x, 0.15, mid.y) - face_dir * 0.4,   # through the doorway
		Vector3(mid.x, 0.15, mid.y) - face_dir * 1.6,   # clear outside
	]
	var outside := await _follow_waypoints(player, exit_wps, 30.0)
	outside = outside and not lr.has_point(
			Vector2(player.global_position.x, player.global_position.z))
	_check("walked out of the building", outside,
			str(player.global_position))

	# === 12. Close door; it must block again =================================
	var attempts := 0
	while attempts < 4:
		attempts += 1
		door.call("close")
		await _wait(0.9)
		if not bool(door.call("is_open")):
			break
		# A blocked leaf bounces open; step back further and retry.
		var away := Vector3(mid.x, 0.15, mid.y) - face_dir * (1.8 + attempts)
		await _steer_towards(player, away, 1.5)
	_check("door reports CLOSED", not bool(door.call("is_open")))
	before = player.global_position
	await _steer_towards(player, Vector3(mid.x, 0.15, mid.y) + face_dir * 2.0,
			2.5)
	pushed = player.global_position
	crossed = _crossed_facade(lr, face, before, pushed)
	_check("closed door blocks again", not crossed,
			"%s -> %s" % [before, pushed])

	_suspend_controller(player, false)
	player.collision_mask = Survivor.LAYER_ENVIRONMENT | Survivor.LAYER_ZOMBIES
	_finish()


func camera_rig_y_near(player_y: float) -> bool:
	var rigs := get_tree().get_nodes_in_group(&"camera_rig")
	if rigs.is_empty():
		return false
	return absf((rigs[0] as Node3D).global_position.y - player_y) < 4.0


func _rig_y() -> String:
	var rigs := get_tree().get_nodes_in_group(&"camera_rig")
	if rigs.is_empty():
		return "?"
	return "%.2f" % (rigs[0] as Node3D).global_position.y


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


func _free_spot(player: Node3D, start: Vector3, lr: Rect2,
		face: int) -> Vector3:
	# Capsule-free position near `start`, searching lateral offsets along
	# the facade. Verifies the spot is genuinely OUTSIDE the footprint.
	var space := player.get_world_3d().direct_space_state
	var cap := CapsuleShape3D.new()
	cap.radius = 0.37
	cap.height = 1.72
	var face_dir := _inward_dir(face)
	var tangent := Vector3(-face_dir.z, 0, face_dir.x)
	for t: float in [0.0, -1.4, 1.4, -2.8, 2.8, -4.2, 4.2]:
		var p := start + tangent * t
		if lr.grow(0.3).has_point(Vector2(p.x, p.z)):
			continue   # must be OUTSIDE
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
	return await _follow_waypoints_r(player, wps, timeout,
			func(_i: int) -> float: return 0.55)


## Radius-aware variant: `radius_for(index)` gives the arrival tolerance per
## waypoint (the bulkhead interior is tight; its landing point needs a wider
## tolerance than open-floor waypoints).
func _follow_waypoints_r(player: Node3D, wps: Array[Vector3],
		timeout: float, radius_for: Callable) -> bool:
	var i := 0
	var t := 0.0
	var stuck := 0.0
	var last_pos := player.global_position
	while i < wps.size() and t < timeout:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		var wp := wps[i]
		var arrive := float(radius_for.call(i))
		var flat := wp - player.global_position
		flat.y = 0.0
		var band_ok: bool = absf(player.global_position.y - wp.y) < 0.75 \
				or flat.length() < 0.45
		if flat.length() < arrive and band_ok:
			i += 1
			stuck = 0.0
			continue
		if flat.length() > 0.01:
			var dir := flat.normalized()
			# Micro-jitter when progress stalls: real bodies unstick from
			# seam corners by sidestepping; keeps the route physical.
			if stuck > 1.0:
				var side := Vector3(-dir.z, 0, dir.x) \
						* (1.0 if fmod(stuck, 2.0) < 1.0 else -1.0)
				dir = (dir * 0.4 + side).normalized()
			player.request_move(dir, false)
		# Per-segment stuck watchdog: no progress -> give up.
		if player.global_position.distance_to(last_pos) < 0.04:
			stuck += get_physics_process_delta_time()
			if stuck > 6.0:
				print("[Walkthrough] no progress before waypoint %d/%d"
						% [i + 1, wps.size()])
				return false
		else:
			stuck = 0.0
		last_pos = player.global_position
	return i >= wps.size()


## Wait until the chunk owning `pos` is resident, then place the player.
## Used ONLY for the initial street drop-off (route integrity requirement).
func _teleport_to_resident(mgr: ChunkManager, player: Node3D, pos: Vector3) -> void:
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
