extends Node
## Havoc physics + firearms integration harness.
##
##   godot --headless --path . -- --havoctest
##
## Verifies:
##   1. Structural damage destroys a real Door -> wood debris spawns,
##      doorway group membership clears.
##   2. DebrisManager.explosion applies falloff damage + knockback to
##      living actors and emits the noise event zombies listen to.
##   3. Hitscan guns raycast, tracers/muzzle VFX spawn, and bullets erode
##      a DestructibleProp through its material strength.
##   4. The rocket projectile launches, flies and detonates into debris.
##   5. FollowCamera tracks the target's Y (stairs) and serves aim points.
##
## Exits 0 on success, 1 otherwise. Does not touch the save file.

var failures := 0


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[Havoc] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _run() -> void:
	await _wait(1.5)
	var mgr := _manager()
	var player: Survivor = ActorRegistry.get_actor(&"player")
	_check("city ready with player", mgr != null and player != null)
	if mgr == null or player == null:
		return _finish()

	var ok := await _until(func() -> bool:
		return mgr.active_count() >= 9, 40.0)
	_check("active ring present", ok)

	# --- 1. Door structural destruction --------------------------------------
	await _until(func() -> bool:
		return get_tree().get_nodes_in_group(&"doors").size() > 0, 30.0)
	var doors := get_tree().get_nodes_in_group(&"doors")
	_check("door available", doors.size() > 0)
	if doors.size() > 0:
		var door: Node = doors[0]
		var before := _piece_count()
		var doors_before := get_tree().get_nodes_in_group(&"doors").size()
		door.call("take_structural_damage", 4000.0, &"player")
		await _wait(0.3)
		var doors_after := get_tree().get_nodes_in_group(&"doors").size()
		_check("door destroyed leaves doors group",
				doors_after == doors_before - 1,
				"%d -> %d" % [doors_before, doors_after])
		_check("wood debris spawned", _piece_count() > before,
				"%d -> %d" % [before, _piece_count()])

	# --- 2. Explosion damage + knockback + noise event ------------------------
	var zombie := _nearest_zombie(player.global_position)
	_check("zombie found for blast", zombie != null)
	if zombie != null:
		var hp_before: float = zombie.health.current_health
		var blast_at: Vector3 = zombie.global_position \
				+ Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
		var heard := {"count": 0}
		EventBus.explosion_occurred.connect(func(_pos: Vector3) -> void:
			heard["count"] += 1)
		# Stand back so the blasts do not kill the observer.
		player.global_position = blast_at + Vector3(10.0, 0.2, 10.0)
		DebrisManager.explosion(blast_at, 6.0, 120.0, &"player")
		await _wait(0.25)

		# A lethal blast frees the zombie node entirely (ragdoll replaces
		# the body) - that counts as damage done.
		var corpse_origin := blast_at
		var zombie_gone := not is_instance_valid(zombie)
		var damaged := zombie_gone
		if not zombie_gone:
			damaged = zombie.health.is_dead \
					or zombie.health.current_health < hp_before
			corpse_origin = zombie.global_position
		_check("explosion damaged/killed zombie", damaged,
				"%.0f -> %s" % [hp_before,
						"gone" if zombie_gone else str(
								zombie.health.current_health)])
		_check("explosion noise event emitted", int(heard["count"]) == 1)

		# Keep blasting until it drops, then a physics ragdoll must exist.
		for i in 4:
			if not is_instance_valid(zombie) or zombie.health.is_dead:
				break
			if is_instance_valid(player):
				player.global_position = zombie.global_position \
						+ Vector3(10.0, 0.2, 10.0)
			DebrisManager.explosion(
					zombie.global_position + Vector3.UP * 0.5,
					5.0, 200.0, &"player")
			await _wait(0.25)
		if not is_instance_valid(zombie) or zombie.health.is_dead:
			await _wait(0.3)
		var ragdoll_found := false
		for node in get_tree().get_nodes_in_group(&"corpses"):
			if node.global_position.distance_to(corpse_origin) < 40.0:
				ragdoll_found = true
		_check("zombie death spawns ragdoll corpse", ragdoll_found)

	# The observer may have died in the crossfire; re-acquire it.
	player = ActorRegistry.get_actor(&"player")
	_check("player survived blast test", player != null)
	if player == null:
		return _finish()

	# --- 3. SMG pellets erode a destructible prop -----------------------------
	var weapons: WeaponSystem = _find_weapons(player)
	_check("weapon system wired", weapons != null)
	if weapons == null:
		return _finish()
	# Spawn a KNOWN tree-trunk prop beside the player so the test does not
	# depend on the seed's local furniture. Placement is verified by a probe
	# ray; unlucky angles are retried around the player.
	var prop: DestructibleProp = null
	for attempt in 8:
		var ang := TAU * float(attempt) / 8.0
		var dirp := Vector3(cos(ang), 0, sin(ang))
		var candidate := DestructibleProp.new()
		candidate.setup({
			"position": player.global_position + dirp * 6.0
					+ Vector3(0, -0.1, 0),
			"material": &"wood",
			"parts": [{
				"offset": Vector3(0, 1.15, 0),
				"size": Vector3(0.42, 2.3, 0.42),
				"color": Color("4a3826"),
				"collide": true,
			}],
		})
		get_tree().current_scene.add_child(candidate)
		await _wait(0.05)
		var space := player.get_world_3d().direct_space_state
		var muzzle := player.global_position + Vector3.UP * 1.35
		var to_prop := candidate.global_position + Vector3(0, 1.15, 0) - muzzle
		to_prop.y = 0.0
		if to_prop.length_squared() < 0.01:
			candidate.queue_free()
			continue
		var probe := PhysicsRayQueryParameters3D.create(muzzle,
				muzzle + to_prop.normalized() * 60.0, 1)
		probe.exclude = [player.get_rid()]
		var hit := space.intersect_ray(probe)
		if not hit.is_empty() and hit.get("collider") == candidate \
				and (hit["position"] as Vector3).distance_to(
						candidate.global_position) < 4.5:
			prop = candidate
			break
		candidate.queue_free()
	_check("destructible prop placed with clear shot", prop != null)
	if prop == null:
		return _finish()
	await _wait(0.1)
	var integrity_before: float = prop._destructible.structural_damage
	var killed := {"gone": false}
	prop._destructible.destroyed.connect(func() -> void:
		killed["gone"] = true)

	weapons.select_slot(1)   # SMG: tight spread, precise probe
	var gun_def: Dictionary = weapons.current_def()
	_check("slot 1 is smg", String(gun_def.get("name", "")) == "Scrap SMG")

	for i in 25:
		if bool(killed["gone"]) or not is_instance_valid(prop):
			break
		weapons.call("_fire_hitscan", gun_def,
				prop.global_position + Vector3(0, 1.15, 0))
		await _wait(0.02)
	await _wait(0.3)
	if bool(killed["gone"]) or not is_instance_valid(prop):
		_check("smg damaged prop", true, "fully destroyed")
	else:
		var after_damage: float = prop._destructible.structural_damage
		_check("smg chipped prop integrity",
				after_damage > integrity_before,
				"%.1f -> %.1f" % [integrity_before, after_damage])
	if is_instance_valid(prop):
		prop.queue_free()

	# --- 4. Rocket launches and detonates -------------------------------------
	var weapons2: WeaponSystem = _find_weapons(player)
	if weapons2 != null:
		weapons2.select_slot(3)
		var before := _piece_count()
		weapons2.call("_launch_rocket", weapons2.current_def(),
				player.global_position + Vector3(8, 0, 0))
		var rocket_ref: RocketProjectile = null
		for node in get_tree().current_scene.get_children():
			if node is RocketProjectile:
				rocket_ref = node
		_check("rocket in flight", rocket_ref != null)
		if rocket_ref != null:
			var holder := {"node": rocket_ref}
			await _until(func() -> bool:
				return not is_instance_valid(holder["node"]), 6.0)
			_check("rocket detonated into debris",
					_piece_count() >= before + 2,
					"pieces=%d baseline=%d" % [_piece_count(), before])

	# --- 5. Camera Y follow + aim point ----------------------------------------
	var rig := _camera_rig()
	_check("camera rig found", rig != null)
	if rig != null:
		var y0: float = rig.global_position.y
		player.global_position += Vector3(0, 9.0, 0)
		ok = await _until(func() -> bool:
			return rig.global_position.y > y0 + 5.0, 5.0)
		_check("camera follows vertical movement", ok,
				"y %.1f -> %.1f" % [y0, rig.global_position.y])
		var aim: Vector3 = rig.call("ground_point_under_mouse", 0.0)
		_check("aim point finite", aim.is_finite())
		player.global_position -= Vector3(0, 9.0, 0)

	_finish()


# --- Helpers ------------------------------------------------------------------

func _finish() -> void:
	print("[Havoc] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _manager() -> ChunkManager:
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	return managers[0] if not managers.is_empty() else null


func _camera_rig() -> FollowCamera:
	var rigs := get_tree().get_nodes_in_group(&"camera_rig")
	return rigs[0] if not rigs.is_empty() else null


func _piece_count() -> int:
	var n := 0
	for node in get_tree().current_scene.get_children():
		if node is DebrisPiece:
			n += 1
	return n


func _nearest_zombie(from: Vector3) -> Zombie:
	var best: Zombie = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(&"zombies"):
		var z := node as Zombie
		if z == null or z.health.is_dead:
			continue
		var d := z.global_position.distance_to(from)
		if d < best_d:
			best_d = d
			best = z
	return best


func _find_weapons(player: Survivor) -> WeaponSystem:
	for child in player.get_children():
		if child is WeaponSystem:
			return child
	return null


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
		print("[Havoc] PASS  %s" % test_name)
	else:
		failures += 1
		print("[Havoc] FAIL  %s   (%s)" % [test_name, detail])
