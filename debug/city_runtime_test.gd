extends Node
## Runtime streamed-city integration harness.
##
##   godot --headless --path . -- --cityruntime
##
## Unlike --citytest (pure plan data), this boots the REAL streamed city:
##   1. 3x3 ACTIVE ring becomes present around the spawned player.
##   2. City geometry carries collision - a physics ray fired at an
##      exterior wall from outside is stopped by it.
##   3. Zombies exist and their home chunks are ACTIVE.
##   4. Walking far unloads old chunks; returning rebuilds them with the
##      SAME deterministic door ids.
##   5. A physics probe walks up a real stair ramp to the next floor.
##   6. Doors toggle open/closed through their public API.
##
## Exits 0 on success, 1 otherwise. Does not touch the save file.

var failures := 0

var _probe: CharacterBody3D = null
var _probe_dir := Vector3.ZERO


func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[CityRuntime] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _run() -> void:
	await _wait(1.0)
	var mgr := _manager()
	_check("chunk manager exists", mgr != null)
	if mgr == null:
		return _finish()

	# --- 1. 3x3 ACTIVE ring materializes ------------------------------------
	var ok := await _until(func() -> bool: return mgr.active_count() >= 9, 40.0)
	_check("3x3 ACTIVE ring present", ok,
			"active=%d" % mgr.active_count())

	var player := ActorRegistry.get_actor(&"player")
	_check("player spawned", player != null)
	if player == null:
		return _finish()
	# The route takes minutes - keep the observer off the starvation clock.
	player.health.max_health = 1000000.0
	player.health.current_health = 1000000.0

	# --- 2. Exterior walls carry collision -----------------------------------
	_check("exterior wall blocks physics ray",
			await _wall_ray_blocks(mgr, player))

	# --- 3. Zombies populate ACTIVE chunks ------------------------------------
	ok = await _until(func() -> bool:
		return get_tree().get_nodes_in_group(&"zombies").size() \
				>= CitySpawner.MIN_PER_CHUNK, 30.0)
	_check("city zombies spawned", ok,
			"zombies=%d" % get_tree().get_nodes_in_group(&"zombies").size())
	var spawners := get_tree().get_nodes_in_group(&"city_spawner")
	var spawner: CitySpawner = spawners[0] if not spawners.is_empty() else null
	_check("city spawner tracks population",
			spawner != null and spawner.live_total() > 0,
			str(spawner.live_total()) if spawner != null else "no spawner")

	# --- 4. Doors are dynamic entities ---------------------------------------
	var doors := get_tree().get_nodes_in_group(&"doors")
	_check("door entities exist", doors.size() > 0, str(doors.size()))
	if doors.size() > 0:
		var door: Node = doors[0]
		door.call("open")
		await _wait(0.8)
		var opened: bool = door.call("is_open")
		_check("door opens via API", opened)
		# The COLLIDER must actually move with the leaf: a ray fired through
		# the doorway center must now pass (previously it hit the leaf).
		var dpos: Vector3 = door.global_position
		var dm: Dictionary = door.manifest
		var yaw: float = float(dm.get("yaw", 0.0))
		var inw := Vector3(sin(yaw), 0, cos(yaw))   # facade inward normal
		var space: PhysicsDirectSpaceState3D = door.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(
				dpos - inw * 0.6 + Vector3(0, 1.1, 0),
				dpos + inw * 1.4 + Vector3(0, 1.1, 0), 1)
		q.exclude = [(door.call("_pivot_rid") as RID)]
		var clear: bool = space.intersect_ray(q).is_empty()
		_check("open doorway physically passable", clear)
		door.call("close")
		await _wait(0.8)
		_check("door closes via API", not door.call("is_open"))

	# --- 5. Deterministic ids survive unload/reload ---------------------------
	var far := player.global_position + Vector3(320.0, 0, 96.0)
	player.global_position = far
	var pc := WorldSeed.chunk_coord(far.x, far.z)
	ok = await _until(func() -> bool: return mgr.active_count() >= 9, 60.0)
	_check("far ring activates after teleport", ok)

	player.global_position += Vector3(160.0, 0, 0)   # beyond UNLOAD_RADIUS
	var origin_coord := WorldSeed.chunk_coord(
			mgr.plan.find_spawn_point().x, mgr.plan.find_spawn_point().y)
	ok = await _until(func() -> bool: return not mgr.is_resident(origin_coord),
			60.0)
	_check("origin chunks unload when far away", ok,
			"resident=%s" % str(mgr.is_resident(origin_coord)))

	# Remember the door ids near spawn before leaving...
	player.global_position = Vector3(mgr.plan.find_spawn_point().x, 0.2,
			mgr.plan.find_spawn_point().y)
	ok = await _until(func() -> bool:
		return mgr.is_resident(origin_coord) \
				and mgr.state_of(origin_coord) == &"active", 60.0)
	_check("returning reactivates origin chunk", ok)
	# Let the whole warm ring finish materializing before counting doors -
	# physics doors/props make chunk builds heavier, so a mid-stream count
	# would race the loader.
	await _until(func() -> bool: return mgr.pending_count() == 0, 60.0)
	var ids_before := _door_ids()

	# ...leave again, return again, compare.
	player.global_position = far + Vector3(160.0, 0, 0)
	ok = await _until(func() -> bool: return not mgr.is_resident(origin_coord),
			60.0)
	player.global_position = Vector3(mgr.plan.find_spawn_point().x, 0.2,
			mgr.plan.find_spawn_point().y)
	ok = await _until(func() -> bool: return mgr.is_resident(origin_coord), 60.0)
	await _until(func() -> bool: return mgr.pending_count() == 0, 60.0)
	_check("same door ids regenerate deterministically",
			ok and _door_ids() == ids_before,
			"%d vs %d" % [ids_before.size(), _door_ids().size()])

	# --- 6. Stair climb probe --------------------------------------------------
	_check("stair probe reaches upper floor", await _stair_probe_reaches_floor(mgr))

	_finish()


# --- Helpers ------------------------------------------------------------------

func _finish() -> void:
	print("[CityRuntime] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _manager() -> ChunkManager:
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	return managers[0] if not managers.is_empty() else null


func _door_ids() -> Array[String]:
	var out: Array[String] = []
	for d in get_tree().get_nodes_in_group(&"doors"):
		out.append(String(d.name))
	out.sort()
	return out


## Fire a horizontal ray at a nearby tall building's north wall from
## outside; it must be stopped by static city collision, not fly through.
func _wall_ray_blocks(mgr: ChunkManager, player: Node3D) -> bool:
	var spec := _nearest_stair_building(mgr, player.global_position, 3)
	if spec.is_empty():
		return false
	var lr: Rect2 = spec["rect"]
	var from := Vector3(lr.get_center().x, 0.9, lr.position.y - 0.8)
	if not await _building_resident(mgr, spec):
		return false
	var space: PhysicsDirectSpaceState3D \
			= player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0, 0, 1.6), 1)   # straight into the north wall
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	return collider is StaticBody3D or collider is AnimatableBody3D


## Nearest multi-storey stair-equipped spec around `from`, within max_chunks
## of the player's chunk so its geometry is (or will be) resident.
func _nearest_stair_building(mgr: ChunkManager, from: Vector3,
		max_ring: int) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for ring in range(1, max_ring + 1):
		var rect := Rect2(from.x - 64.0 * ring, from.z - 64.0 * ring,
				128.0 * ring, 128.0 * ring)
		for spec in mgr.plan.buildings_in_rect(rect):
			if int(spec["floors"]) < 4 or not BuildingBuilder.has_stairs_for(
					(spec["rect"] as Rect2).size, float(spec["floor_h"]),
					int(spec["floors"])):
				continue
			var d: float = Vector2(from.x, from.z).distance_to(
					(spec["rect"] as Rect2).get_center())
			if d < best_d:
				best_d = d
				best = spec
		if not best.is_empty():
			return best   # closest ring wins
	return best


func _owner_chunk(mgr: ChunkManager, spec: Dictionary) -> Vector2i:
	var c: Vector2 = (spec["rect"] as Rect2).get_center()
	return WorldSeed.chunk_coord(c.x, c.y)


func _building_resident(mgr: ChunkManager, spec: Dictionary) -> bool:
	return await _until(func() -> bool:
		return mgr.is_resident(_owner_chunk(mgr, spec)), 40.0)


## Walk a plain capsule up flight A of a known multi-storey staircase using
## nothing but physics: proves ramps/landings/slab holes work together.
func _stair_probe_reaches_floor(mgr: ChunkManager) -> bool:
	var player := ActorRegistry.get_actor(&"player")
	if player == null:
		return false
	var target := _nearest_stair_building(mgr, player.global_position, 3)
	if target.is_empty():
		print("[CityRuntime] no stair-equipped building near spawn")
		return false
	if not await _building_resident(mgr, target):
		print("[CityRuntime] stair building chunk never became resident")
		return false

	var fh := float(target["floor_h"])
	var zone := BuildingBuilder.stair_zone_world(target)
	# Flight A occupies the WEST lane and climbs NORTH->SOUTH from ground.
	var entry := Vector3(zone.position.x + BuildingBuilder.LANE_W * 0.5,
			0.4, zone.position.y + BuildingBuilder.LAND * 0.5)

	_probe = CharacterBody3D.new()
	_probe.collision_layer = 0
	_probe.collision_mask = 1
	_probe.up_direction = Vector3.UP
	_probe.floor_max_angle = deg_to_rad(46.0)
	_probe.floor_snap_length = 0.3
	var shape_node := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	shape_node.shape = capsule
	shape_node.position = Vector3(0, 0.85, 0)
	_probe.add_child(shape_node)
	add_child(_probe)
	_probe.global_position = entry
	_probe_dir = Vector3(0, 0, 1)   # push south, up the ramp

	var t := 0.0
	while t < 10.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if _probe == null or not is_instance_valid(_probe):
			return false
		_probe.velocity = _probe_dir * 2.6
		if not _probe.is_on_floor():
			_probe.velocity.y -= 18.0 * get_physics_process_delta_time()
		_probe.move_and_slide()
		if _probe.global_position.y >= fh * 0.85:
			var reached: bool = _probe.global_position.y >= fh * 0.85
			_probe.queue_free()
			_probe = null
			return reached
	var final_y := _probe.global_position.y
	_probe.queue_free()
	_probe = null
	print("[CityRuntime] stair probe stalled at y=%.2f (target %.2f)"
			% [final_y, fh * 0.85])
	return false


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
		print("[CityRuntime] PASS  %s" % test_name)
	else:
		failures += 1
		print("[CityRuntime] FAIL  %s   (%s)" % [test_name, detail])
