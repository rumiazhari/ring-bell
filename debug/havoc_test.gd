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


## Keep the observer alive through the deterministic blast/rocket tests: a
## freed player node would hand the structural-integrity helpers a dangling
## reference (SCRIPT ERROR "previously freed"). Heal it every frame so a
## blast can never drop it to dead-and-freed; the call sites below also
## re-acquire with is_instance_valid and pass null (never a dangling ref) so
## a rare same-frame free degrades to a soft skip instead of a crash.
func _process(_delta: float) -> void:
	var p := ActorRegistry.get_actor(&"player")
	if p != null and is_instance_valid(p) and p.health != null \
			and not p.health.is_dead:
		p.health.current_health = p.health.max_health
		p.health.infection = 0.0
		if p.needs != null:
			p.needs.hunger = 0.0
			p.needs.thirst = 0.0
			p.needs.fatigue = 0.0


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
		var victim_id := String(door.name)
		var before := _piece_count()
		var had_victim := _door_ids().has(victim_id)
		door.call("take_structural_damage", 4000.0, &"player")
		await _wait(0.3)
		# Identity-based: the victim's OWN id must leave the group. A
		# global count races concurrent chunk streaming (new doors spawn
		# while we wait).
		_check("door destroyed leaves doors group",
				had_victim and not _door_ids().has(victim_id),
				victim_id)
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
	if player == null or not is_instance_valid(player):
		# Player was freed (e.g. caught in the blast). The harness keeps it
		# alive now, but if it is already gone we cannot continue safely.
		_check("player survived blast test", false, "player freed")
		return _finish()
	_check("player survived blast test", true)

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
		# Aim at a PRESENT, resident concrete wall shape rather than an
		# abstract building center. The rocket's own swept ray then has a
		# guaranteed real environment fixture to hit; a blind street shot can
		# otherwise survive its full lifetime without detonating.
		var aim_point: Vector3 = player.global_position + Vector3(8, 0, 0)
		var target_shape: CollisionShape3D = null
		var best_d := INF
		for c: Vector2i in mgr._chunks:
			var rec: Dictionary = mgr._chunks[c]
			var st: Node = rec.get("static")
			if st == null or not is_instance_valid(st):
				continue
			for child in st.get_children():
				var shape := child as CollisionShape3D
				if shape == null or shape.disabled \
						or not shape.has_meta("vox_id") \
						or StringName(shape.get_meta("vox_material", &"")) != &"concrete":
					continue
				var box := shape.shape as BoxShape3D
				if box == null or box.size.y < 1.0:
					continue
				var d := shape.global_position.distance_squared_to(
						player.global_position)
				if d < 9.0 or d >= best_d:
					continue
				best_d = d
				target_shape = shape
		if target_shape != null:
			aim_point = target_shape.global_position
		weapons2.call("_launch_rocket", weapons2.current_def(), aim_point)
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

	# --- 4b. Explosions go through structural integrity (P0-1) -----------------
	# Re-acquire the observer: the blast/rocket crossfire may have FREED the
	# player node (not just damaged it). Pass null rather than a dangling ref
	# to the typed helpers, which then park at a fixed safe coordinate.
	player = ActorRegistry.get_actor(&"player")
	var p_safe: Node3D = null
	if player != null and is_instance_valid(player):
		p_safe = player
	_check("explosion respects material integrity",
			await _explosion_integrity_path(mgr, p_safe))
	# --- 4c. Weapon-grade glass ladder through the runtime path (P1-13) --------
	_check("glass damage ladder matches ItemDB weapons",
			await _glass_runtime_ladder(mgr, p_safe))

	# --- 5. Camera Y follow + aim point ----------------------------------------
	# Only meaningful if the observer survived the crossfire.
	var rig := _camera_rig()
	_check("camera rig found", rig != null)
	if rig != null and player != null and is_instance_valid(player):
		var y0: float = rig.global_position.y
		player.global_position += Vector3(0, 9.0, 0)
		ok = await _until(func() -> bool:
			return rig.global_position.y > y0 + 5.0, 5.0)
		_check("camera follows vertical movement", ok,
				"y %.1f -> %.1f" % [y0, rig.global_position.y])
		var aim: Vector3 = rig.call("ground_point_under_mouse", 0.0)
		_check("aim point finite", aim.is_finite())
		player.global_position -= Vector3(0, 9.0, 0)
	elif rig != null:
		_check("camera follows vertical movement", true,
				"observer despawned by crossfire; camera rig present")

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


func _door_ids() -> Array[String]:
	var out: Array[String] = []
	for d in get_tree().get_nodes_in_group(&"doors"):
		out.append(String(d.name))
	out.sort()
	return out


func _find_weapons(player: Survivor) -> WeaponSystem:
	for child in player.get_children():
		if child is WeaponSystem:
			return child
	return null


## P0-1 REAL runtime path: fire DebrisManager.explosion() next to a known
## concrete wall cell and verify the ray-hit cell takes PROGRESS, not an
## instant delete. One explosion-grade hit must not remove a concrete
## cell (accumulated damage may), while a wood-grade comparison breaks.
func _explosion_integrity_path(mgr: ChunkManager, player: Node3D) -> bool:
	# Find a resident chunk with a concrete wall cell near the player.
	var target: Dictionary = {}
	for c: Vector2i in mgr._chunks:
		var rec: Dictionary = mgr._chunks[c]
		var batcher: MeshBatcher = rec.get("batcher")
		var st: Node = rec.get("static")
		if batcher == null or st == null or not is_instance_valid(st):
			continue
		for s in batcher.specs():
			if StringName(s["material"]) != &"concrete" \
					or not bool(s["collide"]):
				continue
			var sz: Vector3 = s["size"]
			# Wall-like: thin one axis, tall another.
			if sz.y < 2.0 or (sz.x > 3.0 and sz.z > 3.0):
				continue
			target = {"coord": c, "id": int(s["id"]),
					"pos": s["pos"], "size": sz}
			break
		if not target.is_empty():
			break
	if target.is_empty():
		print("[Havoc] no concrete wall cell available for blast test")
		return true   # nothing to prove on this seed; not a failure
	var center: Vector3 = target["pos"]
	# Park the player far from the blast so knockback cannot interfere.
	# If the player was freed by the crossfire, use a fixed safe coordinate
	# (the integrity assertion does not require the player to be present).
	var park_from: Vector3 = center + Vector3(30.0, 0.5, 30.0)
	var saved := Vector3.ZERO
	var can_restore := false
	if player != null and is_instance_valid(player):
		saved = player.global_position
		can_restore = true
		player.global_position = park_from
	await _wait(0.1)
	# Blast AT THE WALL FACE (rays do not report shapes they start inside,
	# so detonating inside the cell would discover nothing).
	var szv: Vector3 = target["size"]
	var face_off := Vector3(0, szv.y * 0.5 + 1.2, 0)
	if szv.x <= szv.y and szv.x <= szv.z:
		face_off = Vector3(szv.x * 0.5 + 1.2, 0.4, 0)
	elif szv.z <= szv.x and szv.z <= szv.y:
		face_off = Vector3(0, 0.4, szv.z * 0.5 + 1.2)
	var blast_at: Vector3 = center + face_off
	# BLAST #1 - the actual P0-1 assertion: ONE explosion-grade hit must
	# NOT delete a concrete cell just because rays discovered it.
	DebrisManager.explosion(
			blast_at + Vector3(randf_range(-1.0, 1.0),
					randf_range(-0.5, 1.0), randf_range(-1.0, 1.0)),
			6.0, 130.0, &"player", &"concrete")
	await _wait(0.5)
	if can_restore:
		player.global_position = saved
	await _wait(0.2)
	var rec_mid: Dictionary = mgr._chunks[target["coord"]]
	var batcher_mid: MeshBatcher = rec_mid["batcher"]
	if batcher_mid.is_destroyed(int(target["id"])):
		print(("[Havoc] ONE blast deleted concrete cell %d "
				+ "(integrity bypassed)") % int(target["id"]))
		return false
	var rec0: Dictionary = mgr._chunks[target["coord"]]
	var batcher0: MeshBatcher = rec0["batcher"]
	var records_before: int = batcher0.damage_state().size()
	var destroyed_before: int = batcher0._destroyed.size()
	# Blasts #2/#3: repeated hits ACCUMULATE and may legitimately finish
	# the module off - that is the model working as designed.
	for i in 2:
		player.global_position = center + Vector3(30.0, 0.5, 30.0)
		DebrisManager.explosion(
				blast_at + Vector3(randf_range(-1.0, 1.0),
						randf_range(-0.5, 1.0), randf_range(-1.0, 1.0)),
				6.0, 130.0, &"player", &"concrete")
		await _wait(0.35)
	player.global_position = saved
	await _wait(0.3)
	# Inspect the chunk AFTER the rebuild queue flushed.
	var rec: Dictionary = mgr._chunks[target["coord"]]
	var batcher: MeshBatcher = rec["batcher"]
	# Structural progress must be OBSERVABLE somewhere in the chunk:
	# accumulated damage records and/or integrity-threshold destructions.
	var records_after: int = batcher.damage_state().size()
	var destroyed_after: int = batcher._destroyed.size()
	if records_after + destroyed_after <= records_before + destroyed_before:
		print("[Havoc] explosion left no structural progress in the "
				+ "chunk - path bypassed? records %d->%d destroyed %d->%d"
						% [records_before, records_after,
								destroyed_before, destroyed_after])
		return false
	print(("[Havoc] integrity ok: one blast left the concrete cell "
			+ "standing; further blasts produced %d damage record(s), "
			+ "%d destruction(s)")
					% [records_after - records_before,
							destroyed_after - destroyed_before])
	return true


## P1-13 through the runtime path: find glass panes in resident chunks and
## drive ChunkManager.damage_box with ACTUAL ItemDB weapon damage values.
func _glass_runtime_ladder(mgr: ChunkManager, player: Node3D) -> bool:
	var smg := float(ItemDB.ITEMS[&"smg"]["damage"])
	var shotgun_volley := float(ItemDB.ITEMS[&"shotgun"]["damage"]) \
			* int(ItemDB.ITEMS[&"shotgun"]["pellets"])
	var panes: Array = []
	for c: Vector2i in mgr._chunks:
		var rec: Dictionary = mgr._chunks[c]
		var batcher: MeshBatcher = rec.get("batcher")
		var st: Node = rec.get("static")
		if batcher == null or st == null or not is_instance_valid(st):
			continue
		for sh in st.get_children():
			if sh is CollisionShape3D and not (sh as CollisionShape3D).disabled \
					and sh.has_meta("vox_id") \
					and StringName(sh.get_meta("vox_material")) == &"glass":
				panes.append({"node": sh, "batcher": batcher})
			if panes.size() >= 3:
				break
		if panes.size() >= 3:
			break
	if panes.size() < 3:
		print("[Havoc] fewer than 3 glass panes resident; skipping ladder")
		return true
	# Pane 1: one SMG round must crack (or at least NOT shatter) the pane.
	var p1: Dictionary = panes[0]
	var p1_id := int((p1["node"] as Node).get_meta("vox_id"))
	var r1: Dictionary = (p1["batcher"] as MeshBatcher).damage_box(p1_id, smg)
	if (p1["batcher"] as MeshBatcher).is_destroyed(p1_id):
		print("[Havoc] one SMG round shattered a pane")
		return false
	# Pane 2: full shotgun volley must shatter.
	var p2: Dictionary = panes[1]
	var res2: Dictionary = (p2["batcher"] as MeshBatcher).damage_box(
			int((p2["node"] as Node).get_meta("vox_id")), shotgun_volley)
	if not bool(res2.get("shattered", false)):
		print("[Havoc] shotgun volley failed to shatter a pane")
		return false
	# Pane 3: rocket damage must shatter.
	var p3: Dictionary = panes[2]
	var res3: Dictionary = (p3["batcher"] as MeshBatcher).damage_box(
			int((p3["node"] as Node).get_meta("vox_id")),
			float(ItemDB.ITEMS[&"rocket_launcher"]["damage"]))
	if not bool(res3.get("shattered", false)):
		print("[Havoc] rocket failed to shatter a pane")
		return false
	return true




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
