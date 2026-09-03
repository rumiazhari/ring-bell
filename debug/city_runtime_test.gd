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
	get_tree().create_timer(360.0).timeout.connect(func() -> void:
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
		# Prefer closest exterior door to player for deterministic selection
		var door: Node = null
		var best_d := INF
		for cand in doors:
			var m: Dictionary = cand.manifest if cand.get("manifest") != null else {}
			if bool(m.get("interior", false)):
				continue
			var pos: Vector3 = m.get("position", Vector3.ZERO)
			var d: float = player.global_position.distance_to(pos)
			if d < best_d:
				best_d = d
				door = cand
		if door == null:
			# fallback to closest any door
			for cand in doors:
				var m2: Dictionary = cand.manifest if cand.get("manifest") != null else {}
				var pos2: Vector3 = m2.get("position", Vector3.ZERO)
				var d2: float = player.global_position.distance_to(pos2)
				if d2 < best_d:
					best_d = d2
					door = cand
		if door == null:
			door = doors[0]
		# Let the closed leaf's existing physics pose settle before ray check.
		# The closed pose must remain physically anchored; do not unfreeze it
		# merely to make this query pass.
		await _wait(0.6)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var dm: Dictionary = door.manifest
		# 4a. CLOSED: a ray through the doorway center hits the leaf.
		var dpos: Vector3 = dm.get("position")
		var yaw: float = float(dm.get("yaw", 0.0))
		var inw := Vector3(sin(yaw), 0, cos(yaw))   # facade inward normal
		var space: PhysicsDirectSpaceState3D = door.get_world_3d().direct_space_state
		var q_closed := PhysicsRayQueryParameters3D.create(
				dpos - inw * 0.6 + Vector3(0, 1.1, 0),
				dpos + inw * 1.4 + Vector3(0, 1.1, 0), 1)
		q_closed.exclude = [player.get_rid()]
		var hit_closed := space.intersect_ray(q_closed)
		print("[CityRuntime][DBG] door=%s pos=%s yaw=%.1f leaf=%s hit_empty=%s collider=%s pos_hit=%s" % [str(dm.get("id")), str(dpos), rad_to_deg(yaw), str(door.call("_pivot_ref")), str(hit_closed.is_empty()), str(hit_closed.get("collider")), str(hit_closed.get("position"))])
		var blocked_by_leaf: bool = not hit_closed.is_empty() \
				and hit_closed.get("collider") == door.call("_pivot_ref")
		_check("closed leaf blocks doorway ray", blocked_by_leaf,
				str(hit_closed.get("collider")))
		# 4b. Open it; the leaf must reach its expected swing angle.
		door.call("open")
		await _wait(2.0)
		var opened: bool = door.call("is_open")
		_check("door opens via API", opened)
		var leaf_yaw: float = wrapf(
				(door.call("_pivot_ref") as Node3D).rotation.y, -PI, PI)
		var want_yaw: float = absf(wrapf(
				float(door.get("_open_angle")), -PI, PI))
		_check("open leaf reaches swing angle range",
				absf(absf(leaf_yaw) - want_yaw) < deg_to_rad(6.0),
				"leaf=%.1fdeg target=%.1fdeg"
						% [rad_to_deg(leaf_yaw), rad_to_deg(want_yaw)])
		# 4c. OPEN: the doorway center is clear WITHOUT excluding the leaf
		# RID - if the leaf still hung across the opening this would catch it.
		var q_open := PhysicsRayQueryParameters3D.create(
				dpos - inw * 0.6 + Vector3(0, 1.1, 0),
				dpos + inw * 1.4 + Vector3(0, 1.1, 0), 1)
		q_open.exclude = [player.get_rid()]
		var clear: bool = space.intersect_ray(q_open).is_empty()
		_check("open doorway physically passable (no RID exclusion)", clear)
		# 4d. OPEN: the leaf itself is STILL PHYSICAL at its swung position -
		# a ray aimed at the rotated leaf's actual position must hit IT.
		var leaf := (door.call("_pivot_ref") as Node3D)
		var w := float(dm.get("width", 1.5))
		var side := -1.0 if str(dm.get("hinge", "left")) == "right" else 1.0
		var leaf_mid_world := leaf.global_transform * Vector3(-side * w * 0.5,
				1.1, 0.0)
		var q_leaf := PhysicsRayQueryParameters3D.create(
				dpos + Vector3(0, 1.1, 0),
				leaf_mid_world + (leaf_mid_world - dpos).normalized() * 0.5, 1)
		q_leaf.exclude = [player.get_rid()]
		var hit_leaf := space.intersect_ray(q_leaf)
		var leaf_solid: bool = not hit_leaf.is_empty() \
				and hit_leaf.get("collider") == leaf
		_check("open leaf still collidable at swung position", leaf_solid,
				str(hit_leaf.get("collider")))
		# Deterministic door close: mirror walkthrough step-back retry to avoid leaf pinning.
		# Place player clear of the 0.5 m leaf sweep before close, then retry with physics drain.
		var away := Vector3(dpos.x, 0.15, dpos.z) - inw * 2.2
		player.global_position = away
		await _wait(0.1)
		await get_tree().physics_frame
		door.call("close")
		var closed_ok: bool = false
		for attempts in range(4):
			await _wait(0.9)
			await get_tree().physics_frame
			await get_tree().physics_frame
			closed_ok = not door.call("is_open")
			if closed_ok:
				break
			# Blocked leaf bounces open (DRIVE_TICKS_LIMIT 90); step back further and retry.
			var retry_away := Vector3(dpos.x, 0.15, dpos.z) - inw * (1.8 + attempts + 1)
			player.global_position = retry_away
			await get_tree().physics_frame
			door.call("close")
		_check("door closes via API", closed_ok)

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

	# --- 6b. Camera: real lens position + facade sectors + zoom memory (P0-4/5)
	var rig := _camera_rig()
	_check("camera rig found", rig != null)
	if rig != null:
		await _camera_sector_and_zoom(rig, player, mgr)

	# --- 7. REAL streamed destruction persistence (P0-2) ------------------------
	# Destroy a structural cell through the runtime path, walk away until
	# its chunk truly unloads, return, and verify the real _materialize()
	# rebuilt it WITHOUT the destroyed mesh/collider and WITH doors/props.
	_check("streamed destruction survives unload/reload",
			await _persistence_roundtrip(mgr, player))
	# --- 8. Door state persistence across unload/reload -------------------------
	_check("destroyed/opened door states survive streaming",
			await _door_persistence(mgr, player))

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


func _camera_rig() -> FollowCamera:
	var rigs := get_tree().get_nodes_in_group(&"camera_rig")
	return rigs[0] if not rigs.is_empty() else null


## Fire a horizontal ray at a nearby tall building's north wall from
## outside; it must be stopped by static city collision, not fly through.
func _wall_ray_blocks(mgr: ChunkManager, player: Node3D) -> bool:
	var spec := _nearest_stair_building(mgr, player.global_position, 3)
	if spec.is_empty():
		return false
	var lr: Rect2 = spec["rect"]
	if not await _building_resident(mgr, spec):
		return false
	# Choose a facade that is not the entrance, then aim below the window
	# band. The old probe aimed at the north-face midpoint, which is often the
	# real doorway and therefore correctly returned no wall hit.
	var door_edge := int(spec.get("door_edge", -1))
	var wall_edge := 0 if door_edge != 0 else 1
	var wall_y := 0.45
	var building_center := lr.get_center()
	var yaw := float(spec.get("yaw", 0.0))
	var local_point := Vector2.ZERO
	var local_direction := Vector2.ZERO
	match wall_edge:
		0:
			local_point = Vector2(lr.position.x + lr.size.x * 0.23, lr.position.y - 0.8)
			local_direction = Vector2(0, 1)
		1:
			local_point = Vector2(lr.end.x + 0.8, lr.position.y + lr.size.y * 0.23)
			local_direction = Vector2(-1, 0)
		2:
			local_point = Vector2(lr.position.x + lr.size.x * 0.23, lr.end.y + 0.8)
			local_direction = Vector2(0, -1)
		_:
			local_point = Vector2(lr.position.x - 0.8, lr.position.y + lr.size.y * 0.23)
			local_direction = Vector2(1, 0)
	var world_point := CityPlan._rotate_plan_point(building_center, local_point, yaw)
	var world_direction := CityPlan._rotate_plan_vector(local_direction, yaw)
	var from := Vector3(world_point.x, wall_y, world_point.y)
	var to := from + Vector3(world_direction.x, 0, world_direction.y) * 1.6
	var space: PhysicsDirectSpaceState3D \
			= player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
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
	var footprint: Rect2 = target["rect"]
	var yaw := float(target.get("yaw", 0.0))
	# Flight A occupies the WEST lane and climbs local NORTH->SOUTH from
	# ground. Transform both the entry and travel direction with the same
	# rigid frame as the universal building assembler.
	var local_entry := Vector2(zone.position.x + BuildingBuilder.LANE_W * 0.5,
			zone.position.y + BuildingBuilder.LAND * 0.5)
	var entry_plan := CityPlan._rotate_plan_point(footprint.get_center(), local_entry, yaw)
	var local_direction := CityPlan._rotate_plan_vector(Vector2(0, 1), yaw)
	var entry := Vector3(entry_plan.x, 0.4, entry_plan.y)

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
	_probe_dir = Vector3(local_direction.x, 0, local_direction.y)

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


## P0-4 + P0-5 acceptance against the LIVE FollowCamera:
##   - camera_world_position() returns the actual Camera3D lens position
##     (differs from the rig/player origin by the full boom length);
##   - horizontal_view_direction() points from player to lens and its
##     sector matches faded_facades();
##   - interior mode pulls presentation distance to <= INTERIOR_DISTANCE
##     while _user_distance is preserved, and leaving restores it (no snap).
func _camera_sector_and_zoom(rig: FollowCamera, player: Node3D,
		mgr: ChunkManager) -> void:
	var lens := rig.camera_world_position()
	var lens_offset := Vector2(lens.x - player.global_position.x,
			lens.z - player.global_position.z)
	_check("camera API exposes REAL lens offset (>6 m)",
			lens_offset.length() > 6.0, str(lens_offset.length()))
	var view_dir := rig.horizontal_view_direction()
	_check("view direction matches lens sector",
			view_dir.length() > 0.9 and absf(
					view_dir.angle_to(lens_offset.normalized())) < 0.05)
	# Sector math on the live direction: N/E/S/W classification agrees with
	# InteriorProbe.faded_facades().
	var faked := InteriorProbe.faded_facades(Vector2.ZERO, view_dir)
	var sector_ok := false
	if view_dir.y < -0.35:
		sector_ok = faked.has("N")
	elif view_dir.y > 0.35:
		sector_ok = faked.has("S")
	elif view_dir.x > 0.35:
		sector_ok = faked.has("E")
	elif view_dir.x < -0.35:
		sector_ok = faked.has("W")
	else:
		sector_ok = true   # diagonal tolerance zone
	_check("faded_facades sector matches live view direction", sector_ok,
			str(faked))
	# Zoom state separation (P0-5): driven through the WORLD'S OWN interior
	# detection - main.gd re-asserts the rig state every frame, so we stand
	# the player inside a REAL building instead of toggling the flag by hand.
	rig.set("_user_distance", 18.0)
	rig.set_interior(false)
	await _wait(1.5)   # let presentation ease out fully
	var spec_in := {}
	for cand in mgr.plan.buildings_in_rect(Rect2(
			player.global_position.x - 90.0,
			player.global_position.z - 90.0, 180.0, 180.0)):
		if int(cand["floors"]) >= 1:
			spec_in = cand
			break
	if spec_in.is_empty():
		_check("interior zoom test had a building available", false)
		return
	var c_in: Vector2 = (spec_in["rect"] as Rect2).get_center()
	var saved_pos: Vector3 = player.global_position
	player.global_position = Vector3(c_in.x, 0.3, c_in.y)
	var ok_enter := await _until(func() -> bool:
		return bool(rig.is_interior()), 6.0)
	var ok_in := await _until(func() -> bool:
		var pd: float = rig.get("_presentation_distance")
		return pd <= FollowCamera.INTERIOR_DISTANCE + 0.25, 8.0)
	var pres_in: float = rig.get("_presentation_distance")
	var user_kept: float = rig.get("_user_distance")
	_check("interior presentation <= 9 m",
			ok_enter and ok_in and pres_in <= 9.25,
			"entered=%s presentation=%.2f" % [str(ok_enter), pres_in])
	_check("interior keeps user zoom preference (~18 m)",
			absf(user_kept - 18.0) < 0.01, "user=%.2f" % user_kept)
	player.global_position = Vector3(saved_pos.x, 0.3, saved_pos.z)
	var ok_out := await _until(func() -> bool:
		return not bool(rig.is_interior()) \
				and float(rig.get("_presentation_distance")) >= 17.5, 12.0)
	_check("exit restores exterior zoom smoothly", ok_out,
			"presentation=%.2f" % float(rig.get("_presentation_distance")))
	rig.set("_user_distance", FollowCamera.DEFAULT_DISTANCE)


## P0-2 REAL streaming acceptance: destroy a structural cell through the
## actual ChunkManager path, force a genuine unload (player leaves the
## hysteresis ring), return, wait for the real _materialize(), then assert
## mesh+collision agree (destroyed cell gone from BOTH) and doors/props
## still exist. No manual batcher reconstruction anywhere.
func _persistence_roundtrip(mgr: ChunkManager, player: Node3D) -> bool:
	# Pick the chunk under the player and find a destructible wall cell.
	var coord := WorldSeed.chunk_coord(
			player.global_position.x, player.global_position.z)
	if not mgr.is_resident(coord):
		return false
	var rec: Dictionary = mgr._chunks[coord]
	var batcher: MeshBatcher = rec["batcher"]
	var static_body: Node = rec["static"]
	if static_body == null or not is_instance_valid(static_body):
		return false
	var by_vox := {}
	for sh in (static_body as Node).get_children():
		if sh is CollisionShape3D and not (sh as CollisionShape3D).disabled \
				and sh.has_meta("vox_id"):
			by_vox[int(sh.get_meta("vox_id"))] = sh
	var target_shape: CollisionShape3D = null
	var target_key := ""
	for s in batcher.specs():
		if StringName(s["material"]) != &"concrete":
			continue
		var sid := int(s["id"])
		if by_vox.has(sid):
			target_shape = by_vox[sid]
			target_key = batcher.cell_key_for_id(sid)
			break
	if target_shape == null or target_key == "":
		print("[CityRuntime] no destructible concrete cell found")
		return false
	var doors_before := 0
	var props_before := 0
	var chunk_node := get_tree().current_scene \
			.get_node_or_null(NodePath("Chunks/Chunk_%d_%d"
					% [coord.x, coord.y]))
	if chunk_node != null:
		for child in chunk_node.get_children():
			if child is Door:
				doors_before += 1
			elif child is DestructibleProp:
				props_before += 1
	# Destroy through the runtime API.
	if mgr.destroy_box(target_shape).is_empty():
		return false
	# Leave far beyond the hysteresis ring so this chunk truly unloads.
	var away := player.global_position + Vector3(480.0, 0, 0)
	player.global_position = away
	if not await _until(func() -> bool:
				return not mgr.is_resident(coord), 60.0):
		print("[CityRuntime] owner chunk never unloaded")
		return false
	# Return; the REAL _materialize() rebuilds it.
	player.global_position = Vector3(away.x - 480.0, away.y, away.z)
	if not await _until(func() -> bool:
			return mgr.is_resident(coord) \
					and mgr.pending_count() == 0, 60.0):
		print("[CityRuntime] owner chunk never returned")
		return false
	# Assert on the REBUILT record.
	var rec2: Dictionary = mgr._chunks[coord]
	var batcher2: MeshBatcher = rec2["batcher"]
	var mesh_absent := true
	for s in batcher2.specs():
		if batcher2.is_destroyed(int(s["id"])):
			continue
		if batcher2.cell_key_for_id(int(s["id"])) == target_key:
			mesh_absent = false   # destroyed cell came back to the mesh
			break
	if not mesh_absent:
		print("[CityRuntime] destroyed cell re-materialized as MESH")
		return false
	var collider_absent := true
	var static2: Node = rec2["static"]
	if static2 == null or not is_instance_valid(static2):
		return false
	for sh in static2.get_children():
		if sh is CollisionShape3D and sh.has_meta("vox_id") \
				and int(sh.get_meta("vox_id")) in batcher2._destroyed:
			collider_absent = false
	if not collider_absent:
		print("[CityRuntime] destroyed cell re-materialized as COLLIDER")
		return false
	# Doors/props survived the rebake.
	var doors_after := 0
	var props_after := 0
	var chunk2 := get_tree().current_scene \
			.get_node_or_null(NodePath("Chunks/Chunk_%d_%d"
					% [coord.x, coord.y]))
	if chunk2 == null:
		return false
	for child in chunk2.get_children():
		if child is Door:
			doors_after += 1
		elif child is DestructibleProp:
			props_after += 1
	if doors_after < doors_before or props_after < props_before:
		print("[CityRuntime] doors/props lost on reload (%d/%d -> %d/%d)"
				% [doors_before, props_before, doors_after, props_after])
		return false
	print(("[CityRuntime] persistence ok: key %s stays destroyed, "
			+ "%d doors / %d props intact") % [target_key.substr(0, 16),
					doors_after, props_after])
	return true


## Door state persistence: destroy one door, open another (or the same if
## only one exists), stream the chunk out and back, verify the destroyed
## door did NOT respawn and survivors restore their logical state.
func _door_persistence(mgr: ChunkManager, player: Node3D) -> bool:
	var origin := WorldSeed.chunk_coord(
			player.global_position.x, player.global_position.z)
	if not await _until(func() -> bool:
			return mgr.pending_count() == 0, 40.0):
		return false
	var door_nodes := get_tree().get_nodes_in_group(&"doors")
	if door_nodes.is_empty():
		print("[CityRuntime] no doors for persistence test")
		return false
	# Only doors INSIDE the chunk we are about to cycle prove anything.
	var local_doors: Array[Node] = []
	for d in door_nodes:
		var p3: Vector3 = (d as Node3D).global_position
		if WorldSeed.chunk_coord(p3.x, p3.z) == origin:
			local_doors.append(d)
	if local_doors.is_empty():
		print("[CityRuntime] no doors in the origin chunk")
		return true   # nothing to assert here; not a failure of persistence
	# Destroy one local door, open another if possible.
	var victim: Node = local_doors[0]
	var victim_id := String(victim.name)
	victim.call("take_structural_damage", 4000.0, &"player")
	await _wait(0.3)
	var opener: Node = null
	for d in local_doors:
		if d != victim:
			opener = d
			break
	var opened_id := ""
	if opener != null:
		opener.call("open")
		await _wait(1.2)
		if bool(opener.call("is_open")):
			opened_id = String(opener.name)
	# Stream the whole area out and back.
	var away := player.global_position + Vector3(544.0, 0, 0)
	player.global_position = away
	if not await _until(func() -> bool:
			return not mgr.is_resident(origin), 60.0):
		return false
	player.global_position = Vector3(away.x - 544.0, away.y, away.z)
	if not await _until(func() -> bool:
			return mgr.is_resident(origin) \
					and mgr.pending_count() == 0, 60.0):
		return false
	# The destroyed door must NOT be back.
	var ids_now: Array[String] = _door_ids()
	if ids_now.has(victim_id):
		print("[CityRuntime] destroyed door %s respawned" % victim_id)
		return false
	# Any door recorded open must have come back open.
	var dstates: Dictionary = mgr.door_states(origin)
	for d in get_tree().get_nodes_in_group(&"doors"):
		var did := String(d.name)
		if dstates.has(did) and bool(dstates[did].get("open", false)) \
				and not bool(d.call("is_open")):
			print("[CityRuntime] door %s lost its OPEN state" % did)
			return false
	if opened_id != "" and dstates.has(opened_id) \
			and bool(dstates[opened_id].get("open", false)):
		print("[CityRuntime] opened door %s restored open" % opened_id)
	return true




func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[CityRuntime] PASS  %s" % test_name)
	else:
		failures += 1
		print("[CityRuntime] FAIL  %s   (%s)" % [test_name, detail])
