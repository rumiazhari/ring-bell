extends Node
## Headless regression harness for Prototype 0.
##
## Two modes (see DEVELOPMENT.md):
##   godot --headless --path . -- --smoke   functional checks, fast
##   godot --headless --path . -- --soak    long-run stability (day/night,
##                                          sleep AI, zombie wandering)
## Exits 0 when every check passes, 1 otherwise. Deletes its own save file.
##
## Verifies the core success criterion: persistent autonomous survivors,
## zombie combat, and an authored quest reacting correctly to simulated
## world changes (pre-existing knowledge, independent death, persistence).

var failures := 0


func _ready() -> void:
	# Watchdog: if anything hangs below, quit anyway so output gets flushed.
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[SmokeTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	if OS.get_cmdline_user_args().has("--soak"):
		await _run_soak()
	else:
		await _run_all()
	print("[SmokeTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _run_all() -> void:
	await _wait(0.8)

	# --- 1. Population ------------------------------------------------------
	_check("7 survivors spawned", ActorRegistry.count_alive_in_group(&"survivors") == 7,
			str(ActorRegistry.count_alive_in_group(&"survivors")))
	_check("16 zombies spawned", ActorRegistry.count_alive_in_group(&"zombies") == 16,
			str(ActorRegistry.count_alive_in_group(&"zombies")))

	# --- 1b. Camera sanity (guards against ground-level/aimed-away rigs) ----
	var cam := get_viewport().get_camera_3d()
	_check("an active camera exists", cam != null)
	if cam != null:
		_check("camera is elevated above ground", cam.global_position.y > 4.0,
				str(cam.global_position))
		# Camera looks along -Z; pitched down means +Z points upward.
		_check("camera looks downward", cam.global_basis.z.y > 0.5,
				str(cam.global_basis.z))

	# --- 2. Needs/AI: a hungry NPC eats carried food ------------------------
	var kenji := ActorRegistry.get_actor(&"npc_kenji")
	_check("kenji exists", kenji != null)
	if kenji != null:
		kenji.needs.hunger = 80.0
		await _wait(1.5)
		_check("hungry NPC ate from inventory", kenji.needs.hunger < 60.0,
				str(kenji.needs.hunger))

	# --- 3. Crates feed NPCs -----------------------------------------------
	var crates := get_tree().get_nodes_in_group(&"food_storage")
	_check("2 food crates exist", crates.size() == 2, str(crates.size()))
	if crates.size() > 0 and kenji != null:
		var crate: FoodCrate = crates[0]
		var before := _stock_total(crate)
		crate.npc_take_food(kenji)
		_check("crate gave item to NPC", _stock_total(crate) < before)

	# --- 4. Melee combat ----------------------------------------------------
	var player := ActorRegistry.get_actor(&"player")
	var zombies := get_tree().get_nodes_in_group(&"zombies")
	if player != null and zombies.size() > 0:
		var target: Zombie = zombies[0]
		target.global_position = player.global_position + Vector3(1.4, 0, 0)
		player.facing = Vector3(1, 0, 0)
		player.stamina = Survivor.STAMINA_MAX
		# Let the physics server sync the teleported transform before sweeping.
		await get_tree().physics_frame
		await get_tree().physics_frame
		var hp_before: float = target.health.current_health
		player.try_attack()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check("melee swing damaged zombie", target.health.current_health < hp_before,
				"%s -> %s" % [hp_before, target.health.current_health])
		target.take_damage(9999.0, &"test")
		await _wait(0.3)
		_check("zombie death removed it from registry",
				not is_instance_valid(target) or target.is_queued_for_deletion()
				or ActorRegistry.get_actor(target.zombie_id) == null)

	# --- 5. Quest reacts to PRE-EXISTING knowledge --------------------------
	WorldState.set_flag(&"met_hana")
	QuestManager.start_quest(&"find_hana")
	_check("prior meeting advances objective", QuestManager.get_objective_text(&"find_hana")
			.contains("Return"), QuestManager.get_objective_text(&"find_hana"))

	# --- 6. Independent death fails the quest ------------------------------
	var hana := ActorRegistry.get_actor(&"npc_hana")
	_check("hana exists before death", hana != null)
	if hana != null:
		hana.health.damage(99999.0, &"test_zombie")
		await _wait(0.2)
		_check("quest failed by simulated death",
				QuestManager.get_state(&"find_hana") == QuestManager.State.FAILED)
		_check("world recorded hana's death", WorldState.is_dead(&"npc_hana"))

	# --- 7. Grief branch appears in dialogue --------------------------------
	var grief_tree := DialogueData.build_tree(&"npc_kenji")
	_check("kenji dialogue shows grief after death",
			str(grief_tree.get("start", {}).get("text", "")).contains("didn't make it"),
			str(grief_tree.get("start", {}).get("text", "")).left(40))

	# --- 7b. Traversal: ledge grab arrests fall and prevents damage --------------
	# Place fixtures far from the streamed city (active radius ~128 m) in empty space.
	var anchor := player.global_position
	if player != null:
		# Suspend PlayerController so our injected request_move() isn't overwritten.
		for c in player.get_children():
			if c is PlayerController:
				c.set_physics_process(false)
				break
		# Build a climbable ledge box in empty space.
		var box_pos := anchor + Vector3(600.0, 0.0, 0.0)
		# Local floor so the player does not fall through empty world at this offset.
		var floor_body := StaticBody3D.new()
		var floor_shape := CollisionShape3D.new()
		var floor_mesh := BoxShape3D.new()
		floor_mesh.size = Vector3(200.0, 1.0, 200.0)
		floor_shape.shape = floor_mesh
		floor_body.global_position = box_pos + Vector3(0.0, -0.5, 40.0)  # top at y=0
		floor_body.add_child(floor_shape)
		get_tree().current_scene.add_child(floor_body)
		var box_body := StaticBody3D.new()
		box_body.global_position = box_pos + Vector3(0.0, 1.2, 0.0)  # base on ground, half-height
		var box_shape := CollisionShape3D.new()
		var box_mesh := BoxShape3D.new()
		box_mesh.size = Vector3(3.0, 2.4, 3.0)  # top at y=2.4, grab window feet in [0.3, 1.5]
		box_shape.shape = box_mesh
		box_body.add_child(box_shape)
		get_tree().current_scene.add_child(box_body)
		# Position player airborne beside the box face (no forward drift: the
		# grab's own forward boost carries it up). Set facing so the probe
		# direction is known even with zero move input.
		var face_x := box_pos.x - 1.5  # box left face
		var start_y := 4.2  # drop 4.2 m -> would deal fall damage without grab
		player.global_position = Vector3(face_x - 0.45, start_y, box_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.RIGHT
		player.stamina = Survivor.STAMINA_MAX
		player.exhausted = false
		if player.needs != null:
			player.needs.hunger = 0.0
			player.needs.thirst = 0.0
			player.needs.fatigue = 0.0
		# Stationary fall: let gravity + grab do the work.
		player.request_move(Vector3.ZERO, false)
		# Physics frames to fall and trigger grab.
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("ledge grab triggered during fall", player.parkour.ledge_grabs > 0,
			"grabs=%d" % player.parkour.ledge_grabs)
		# After grab, player should be on top of the box (y ~ 2.4), not on ground (y ~ 0).
		_check("survivor mounted ledge top", player.global_position.y > 2.0,
			"y=%.2f" % player.global_position.y)
		# Fall damage from a 4.2 m drop would be (4.2-3.5)*9 = 6.3; grab resets peak so no damage.
		_check("no fall damage from arrested fall", player.health.current_health == player.health.max_health,
			"hp=%.1f/%.1f" % [player.health.current_health, player.health.max_health])
		# Phase F: a plain test box is NOT batched building structure.
		_check("plain crate ledge not flagged as rooftop",
				not player.parkour.last_grab_was_building,
				"last_building=%s" % player.parkour.last_grab_was_building)
		# Phase M: ...and not a feature-tagged awning either.
		_check("plain crate not flagged as awning",
				not player.parkour.last_grab_was_awning,
				"last_awning=%s" % player.parkour.last_grab_was_awning)
		# Negative control: tall wall (no ledge within reach) should NOT trigger grab.
		var wall_pos := box_pos + Vector3(0.0, 0.0, 80.0)
		var wall_body := StaticBody3D.new()
		wall_body.global_position = wall_pos + Vector3(0.0, 6.0, 0.0)
		var wall_shape := CollisionShape3D.new()
		var wall_mesh := BoxShape3D.new()
		wall_mesh.size = Vector3(3.0, 12.0, 3.0)  # top at y=12, far above reach
		wall_shape.shape = wall_mesh
		wall_body.add_child(wall_shape)
		get_tree().current_scene.add_child(wall_body)
		var grabs_before: int = player.parkour.ledge_grabs
		var face_x2 := wall_pos.x - 1.5
		player.global_position = Vector3(face_x2 - 0.45, start_y, wall_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.RIGHT
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("tall wall does not trigger ledge grab", player.parkour.ledge_grabs == grabs_before,
			"grabs before=%d after=%d" % [grabs_before, player.parkour.ledge_grabs])
		_check("survivor landed on ground (not wall)", player.global_position.y < 0.5,
			"y=%.2f" % player.global_position.y)
		# Phase F: grabbing a batched-building wall (vox_material meta, as
		# stamped by MeshBatcher.flush_into) counts as a rooftop mantle and
		# the follow-through drive must mount the top deterministically.
		var cor_pos := box_pos + Vector3(0.0, 0.0, 120.0)
		var cor_body := StaticBody3D.new()
		cor_body.global_position = cor_pos + Vector3(0.0, 1.2, 0.0)
		var cor_shape := CollisionShape3D.new()
		var cor_mesh := BoxShape3D.new()
		cor_mesh.size = Vector3(3.0, 2.4, 3.0)   # top at y=2.4
		cor_shape.shape = cor_mesh
		cor_shape.set_meta("vox_material", &"concrete")   # mimic building cells
		cor_body.add_child(cor_shape)
		get_tree().current_scene.add_child(cor_body)
		grabs_before = player.parkour.ledge_grabs
		var mantles_before: int = player.parkour.rooftop_mantles
		player.global_position = Vector3(cor_pos.x - 1.95, start_y, cor_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.RIGHT
		player.stamina = Survivor.STAMINA_MAX
		player.exhausted = false
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("cornice grab triggered during fall",
				player.parkour.ledge_grabs == grabs_before + 1,
				"grabs=%d expected=%d" % [player.parkour.ledge_grabs, grabs_before + 1])
		_check("cornice grab flagged as rooftop mantle",
				player.parkour.last_grab_was_building
						and player.parkour.rooftop_mantles == mantles_before + 1,
				"building=%s mantles=%d" % [player.parkour.last_grab_was_building,
						player.parkour.rooftop_mantles])
		_check("survivor mounted cornice top", player.global_position.y > 2.0,
				"y=%.2f" % player.global_position.y)
		# --- Phase F slice 2: radial ledge-seek --------------------------------
		# Survivor falls with its BACK to the wall (facing away): the primary
		# probe sees nothing, only the radial fan can find the lip. This is
		# the zombie-chase escape hatch for NPCs fleeing off rooftops.
		var rad_pos := box_pos + Vector3(0.0, 0.0, 100.0)
		var rad_body := StaticBody3D.new()
		rad_body.global_position = rad_pos + Vector3(0.0, 1.2, 0.0)
		var rad_shape := CollisionShape3D.new()
		var rad_mesh := BoxShape3D.new()
		rad_mesh.size = Vector3(3.0, 2.4, 3.0)
		rad_shape.shape = rad_mesh
		rad_body.add_child(rad_shape)
		get_tree().current_scene.add_child(rad_body)
		grabs_before = player.parkour.ledge_grabs
		var rad_face_x := rad_pos.x - 1.5
		player.global_position = Vector3(rad_face_x - 0.45, start_y, rad_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.LEFT   # back to the wall; primary probe blind
		player.stamina = Survivor.STAMINA_MAX
		player.exhausted = false
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("radial seek grabs wall behind survivor",
				player.parkour.ledge_grabs == grabs_before + 1,
				"grabs=%d expected=%d" % [player.parkour.ledge_grabs,
						grabs_before + 1])
		_check("radial grab mounted top", player.global_position.y > 2.0,
				"y=%.2f" % player.global_position.y)
		# Stamina now scales with lip height: the charged cost lies inside
		# the scaled band and the curve rises as the lip gets higher.
		_check("grab charged a lip-scaled stamina cost",
				player.parkour.last_stamina_cost >= player.parkour.LEDGE_STAMINA_COST_LOW
						and player.parkour.last_stamina_cost <= player.parkour.LEDGE_STAMINA_COST_HIGH,
				"cost=%.2f band=[%.1f,%.1f]" % [player.parkour.last_stamina_cost,
						player.parkour.LEDGE_STAMINA_COST_LOW,
						player.parkour.LEDGE_STAMINA_COST_HIGH])
		_check("lip-height stamina scaling rises with reach",
				player.parkour._ledge_stamina_cost(1.0)
						< player.parkour._ledge_stamina_cost(2.05),
				"low_lip=%.2f high_lip=%.2f" % [
						player.parkour._ledge_stamina_cost(1.0),
						player.parkour._ledge_stamina_cost(2.05)])
		# Exhausted survivor (latched: no strenuous moves until stamina
		# recovers to 25 - unreachable during a sub-second fall, so this
		# is deterministic despite idle regen) cannot pull up at all.
		grabs_before = player.parkour.ledge_grabs
		player.global_position = Vector3(rad_face_x - 0.45, start_y, rad_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.LEFT
		player.stamina = 1.0   # below LEDGE_STAMINA_COST_LOW
		player.exhausted = true
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("exhausted survivor cannot grab",
				player.parkour.ledge_grabs == grabs_before,
				"grabs before=%d after=%d" % [grabs_before,
						player.parkour.ledge_grabs])
		_check("exhausted survivor landed on ground",
				player.global_position.y < 0.5,
				"y=%.2f" % player.global_position.y)
		player.stamina = Survivor.STAMINA_MAX

		# --- Phase M: street-awning grab classification -------------------
		# Mimics the iter-26 geometry: standable wood canopy deck (top at
		# 2.3 m like AWN_DECK_Y) with a steel front lip (top at 2.75 m like
		# AWN_DECK_Y + AWN_RAIL_H), both stamped vox_tag "awning" exactly
		# as MeshBatcher.flush_into now does for real city awnings. The
		# grab must classify as AWNING (soft structure: gentler
		# follow-through drive, own lifetime counter) yet NOT as a concrete
		# rooftop mantle.
		var awn_pos := box_pos + Vector3(0.0, 0.0, 160.0)
		var awn_body := StaticBody3D.new()
		var awn_deck_shape := CollisionShape3D.new()
		var awn_deck_box := BoxShape3D.new()
		awn_deck_box.size = Vector3(3.0, 0.12, 2.4)   # deck top at y=2.3
		awn_deck_shape.shape = awn_deck_box
		awn_deck_shape.position = Vector3(0.0, 2.24, 0.0)
		awn_deck_shape.set_meta("vox_material", &"wood")
		awn_deck_shape.set_meta("vox_tag", &"awning")
		var awn_lip_shape := CollisionShape3D.new()
		var awn_lip_box := BoxShape3D.new()
		awn_lip_box.size = Vector3(0.07, 0.45, 2.4)   # lip top at y=2.75
		awn_lip_shape.shape = awn_lip_box
		awn_lip_shape.position = Vector3(-1.465, 2.525, 0.0)
		awn_lip_shape.set_meta("vox_material", &"steel")
		awn_lip_shape.set_meta("vox_tag", &"awning")
		awn_body.add_child(awn_deck_shape)
		awn_body.add_child(awn_lip_shape)
		awn_body.global_position = awn_pos   # local y=0 sits on the floor slab
		get_tree().current_scene.add_child(awn_body)
		# Drop beside the OUTER face of the front lip, descending past it.
		var awn_face_x := awn_pos.x - 1.5   # outer lip plane
		var awn_grabs_before: int = player.parkour.ledge_grabs
		player.global_position = Vector3(awn_face_x - 0.45, 4.6, awn_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.RIGHT
		player.stamina = Survivor.STAMINA_MAX
		player.exhausted = false
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("awning grab triggered during fall",
				player.parkour.ledge_grabs == awn_grabs_before + 1,
				"grabs=%d expected=%d" % [player.parkour.ledge_grabs,
						awn_grabs_before + 1])
		_check("awning grab classified as awning",
				player.parkour.last_grab_was_awning
						and player.parkour.awning_grabs == 1,
				"awning=%s count=%d" % [player.parkour.last_grab_was_awning,
						player.parkour.awning_grabs])
		_check("awning grab not counted as rooftop mantle",
				not player.parkour.last_grab_was_building,
				"last_building=%s" % player.parkour.last_grab_was_building)
		_check("survivor mounted awning deck",
				player.global_position.y > 2.0,
				"y=%.2f" % player.global_position.y)

		# --- Phase N: awning->balcony chain reach audit --------------------
		# A street awning deck (top 2.3) sits directly below a first-floor
		# balcony deck (top 3.25, lip 3.75) on the SAME outward face - the
		# AC ground->first-floor vertical. We prove the balcony lip is
		# grabbable (falling fixture) and that the height delta from the
		# awning deck (rise ~1.45 within 0.9-2.1) is within the parkour
		# window — so a jump from the awning CAN chain to the balcony.
		# Heights are NOT tuned: 2.3 vs 3.25/3.75 already pairs within the
		# window and this fixture proves it. If it ever fails, tune
		# AWN_DECK_Y / BAL heights or BAL slot y.
		var chain_pos := box_pos + Vector3(0.0, 0.0, 200.0)
		var chain_floor := StaticBody3D.new()
		var chain_floor_shape := CollisionShape3D.new()
		var chain_floor_box := BoxShape3D.new()
		chain_floor_box.size = Vector3(20.0, 1.0, 20.0)
		chain_floor_shape.shape = chain_floor_box
		chain_floor.global_position = chain_pos + Vector3(0.0, -0.5, 0.0)
		chain_floor.add_child(chain_floor_shape)
		get_tree().current_scene.add_child(chain_floor)
		var chain_body := StaticBody3D.new()
		var ch_aw_deck_shape := CollisionShape3D.new()
		var ch_aw_deck_box := BoxShape3D.new()
		ch_aw_deck_box.size = Vector3(3.0, 0.12, 2.4)
		ch_aw_deck_shape.shape = ch_aw_deck_box
		ch_aw_deck_shape.position = Vector3(0.0, 2.24, 0.0)
		ch_aw_deck_shape.set_meta("vox_material", &"wood")
		ch_aw_deck_shape.set_meta("vox_tag", &"awning")
		var ch_aw_lip_shape := CollisionShape3D.new()
		var ch_aw_lip_box := BoxShape3D.new()
		ch_aw_lip_box.size = Vector3(0.07, 0.45, 2.4)
		ch_aw_lip_shape.shape = ch_aw_lip_box
		ch_aw_lip_shape.position = Vector3(-1.465, 2.525, 0.0)
		ch_aw_lip_shape.set_meta("vox_material", &"steel")
		ch_aw_lip_shape.set_meta("vox_tag", &"awning")
		var ch_ba_deck_shape := CollisionShape3D.new()
		var ch_ba_deck_box := BoxShape3D.new()
		ch_ba_deck_box.size = Vector3(3.0, 0.16, 2.4)
		ch_ba_deck_shape.shape = ch_ba_deck_box
		ch_ba_deck_shape.position = Vector3(0.0, 3.17, 0.0)
		ch_ba_deck_shape.set_meta("vox_material", &"concrete")
		ch_ba_deck_shape.set_meta("vox_tag", &"balcony")
		var ch_ba_lip_shape := CollisionShape3D.new()
		var ch_ba_lip_box := BoxShape3D.new()
		ch_ba_lip_box.size = Vector3(0.07, 0.5, 2.4)
		ch_ba_lip_shape.shape = ch_ba_lip_box
		ch_ba_lip_shape.position = Vector3(-1.465, 3.50, 0.0)
		ch_ba_lip_shape.set_meta("vox_material", &"steel")
		ch_ba_lip_shape.set_meta("vox_tag", &"balcony")
		chain_body.add_child(ch_aw_deck_shape)
		chain_body.add_child(ch_aw_lip_shape)
		chain_body.add_child(ch_ba_deck_shape)
		chain_body.add_child(ch_ba_lip_shape)
		chain_body.global_position = chain_pos
		get_tree().current_scene.add_child(chain_body)
		await _wait(0.3)
		var chain_grabs_before: int = player.parkour.ledge_grabs
		# Drop alongside the BALCONY lip (outer plane at x=-1.5) from above,
		# exactly like the awning fixture — proves the balcony lip is
		# grabbable on its own. Combined with the height-delta check below,
		# this proves awning->balcony chaining is reachable.
		var chain_face_x := chain_pos.x - 1.5
		player.global_position = Vector3(chain_face_x - 0.45, 5.4, chain_pos.z)
		player.velocity = Vector3.ZERO
		player.facing = Vector3.RIGHT
		player.stamina = Survivor.STAMINA_MAX
		player.exhausted = false
		player.request_move(Vector3.ZERO, false)
		await _wait(2.5)
		player.request_move(Vector3.ZERO, false)
		await _wait(0.5)
		_check("awning->balcony chain: balcony grab triggered during fall",
				player.parkour.ledge_grabs == chain_grabs_before + 1,
				"grabs=%d expected=%d" % [player.parkour.ledge_grabs, chain_grabs_before + 1])
		_check("chain grab not classified as awning",
				not player.parkour.last_grab_was_awning,
				"last_awning=%s" % player.parkour.last_grab_was_awning)
		_check("chain grab not counted as rooftop mantle",
				not player.parkour.last_grab_was_building,
				"last_building=%s" % player.parkour.last_grab_was_building)
		_check("survivor mounted balcony deck",
				player.global_position.y > 3.0,
				"y=%.2f" % player.global_position.y)
		# Height-delta audit: from a standable awning deck (2.3) a jump
		# (apex ~1.14) plus the 2.1 reach window must cover the first-
		# floor balcony lip (3.75). Rise 1.45 is well inside 0.9-2.1, so
		# no tuning needed; this cements the chain's physical possibility.
		var awn_top := 2.3
		var bal_lip_top := 3.75
		var rise := bal_lip_top - awn_top
		_check("chain height delta within grab window (awning->balcony)",
				rise >= player.parkour.LEDGE_TOP_MIN and rise <= player.parkour.LEDGE_REACH_ABOVE,
				"rise=%.2f window=[%.1f,%.1f]" % [rise, player.parkour.LEDGE_TOP_MIN, player.parkour.LEDGE_REACH_ABOVE])

		# Phase F slice 3: HUD stamina-bar flash + grab counter readout.
		var hud: HUD = null
		for c in get_tree().current_scene.get_children():
			if c is HUD:
				hud = c
				break
		if hud != null and player.parkour != null:
			var flashes_before: int = hud.stamina_flashes
			player.parkour.ledge_grabbed.emit(true)
			_check("grab signal flashes the stamina bar",
					hud.stamina_flashes == flashes_before + 1,
					"flashes=%d expected=%d" % [hud.stamina_flashes, flashes_before + 1])
			_check("grab signal raises rooftop HUD notice",
					hud.last_notice().contains("rooftop"), hud.last_notice())
			_check("stamina bar modulate is non-white while flash active",
					hud.stamina_flash_active(), "modulate=%s" % hud._bars["stamina"].modulate)
			hud.set_grab_counter(4, 2)
			var txt := hud.grab_counter_text()
			_check("HUD grab counter renders counts",
					txt.contains("4") and txt.contains("2"), txt)
			# After the cornice grab earlier, parkour counters are non-zero.
			# One frame later the HUD _process should have refreshed the line.
			var grabs_now: int = player.parkour.ledge_grabs
			var mantles_now: int = player.parkour.rooftop_mantles
			await _wait(0.2)
			txt = hud.grab_counter_text()
			_check("HUD grab counter tracks parkour stats",
					txt.contains("Grabs: %d" % grabs_now),
					"%s vs grabs=%d mantles=%d" % [txt, grabs_now, mantles_now])

		# Restore controller.
		for c in player.get_children():
			if c is PlayerController:
				c.set_physics_process(true)
				break

	# --- 7c. Semantic room layouts (Phase D slice 2) --------------------------
	# The room_type label must drive the furniture program: residential
	# rooms sleep (bed wall-snapped), retail shops sell (counter along a
	# wall, never a bed). Pure spec -> batcher data via BuildingBuilder -
	# no scene tree involvement.
	var rt_style := {"wall": 0, "roof": 0, "balcony": false,
			"attic": false}
	var found := {"residential": {"beds": 0, "bed_ok": true},
			"retail": {"beds": 0, "counters": 0}}
	for rt in ["residential", "retail"]:
		rt_style["room_type"] = rt
		var spec := {
			"id": "smoke_room_%s" % rt,
			"rect": Rect2(4000.0, 4000.0, 12.0, 10.0),
			"floors": 2, "floor_h": 3.0, "door_edge": 0,
			"style": rt_style.duplicate(), "doors": [],
		}
		var batch := MeshBatcher.new()
		BuildingBuilder.build(batch, spec)
		var fp: Rect2 = spec["rect"]
		for s in batch.specs():
			if not bool(s["collide"]) \
					or StringName(s["material"]) != &"wood":
				continue
			var sz: Vector3 = s["size"]
			if absf(sz.x - BuildingBuilder.BED_ALONG) < 0.02 \
					and absf(sz.y - 0.42) < 0.02 \
					and absf(sz.z - BuildingBuilder.BED_DEPTH) < 0.02:
				found[rt]["beds"] += 1
				# Headboard alignment: the center sits depth/2 + gap
				# inside SOME interior face (any of the four walls).
				var want: float = BuildingBuilder.WALL_T \
						+ BuildingBuilder.BED_DEPTH * 0.5 \
						+ BuildingBuilder.SHELF_GAP
				var p: Vector3 = s["pos"]
				if absf(p.z - fp.position.y - want) > 0.02 \
						and absf(fp.end.y - p.z - want) > 0.02 \
						and absf(p.x - fp.position.x - want) > 0.02 \
						and absf(fp.end.x - p.x - want) > 0.02:
					found[rt]["bed_ok"] = false
			elif absf(sz.x - BuildingBuilder.COUNTER_ALONG) < 0.02 \
					and absf(sz.y - 0.95) < 0.02 \
					and absf(sz.z - BuildingBuilder.COUNTER_DEPTH) < 0.02:
				found[rt]["counters"] += 1
	_check("residential room contains a bed",
			int(found["residential"]["beds"]) >= 1,
			str(found["residential"]))
	_check("residential bed hugs a wall",
			bool(found["residential"]["bed_ok"]),
			str(found["residential"]))
	_check("retail shop has a counter",
			int(found["retail"]["counters"]) >= 1,
			str(found["retail"]))
	_check("retail shop has no beds",
			int(found["retail"]["beds"]) == 0,
			str(found["retail"]))

	# --- 7d. Phase G: zombie pack steering (flank arc + deterministic sides) ---
	# Pure math checks on velocity steering (no physics tick needed).
	var ztest := Zombie.new()
	get_tree().current_scene.add_child(ztest)
	ztest.set_physics_process(false)
	ztest.global_position = Vector3(-600.0, 0.3, 0.0)
	var survivor := player
	ztest.target = survivor
	ztest.state = Zombie.State.CHASE

	# Far (8 m) -> lateral arc component non-zero, still closing.
	survivor.global_position = ztest.global_position + Vector3(8.0, 0.0, 0.0)
	ztest._do_chase()
	var v_far := Vector3(ztest.velocity.x, 0.0, ztest.velocity.z)
	var los_far := Vector3(1.0, 0.0, 0.0)
	var lateral_far := absf(v_far.dot(Vector3(0.0, 0.0, 1.0)))
	_check("far chase arcs off the direct line",
		lateral_far > 0.05,
		"lateral=%.3f" % lateral_far)
	_check("far arc still closes on survivor",
		v_far.dot(los_far) > 0.0,
		"forward=%.3f" % v_far.dot(los_far))

	# Near (2.0 m, > ATTACK_RANGE 1.25 but < FLANK_NEAR 2.5) -> pure LOS.
	survivor.global_position = ztest.global_position + Vector3(2.0, 0.0, 0.0)
	ztest._do_chase()
	var v_near := Vector3(ztest.velocity.x, 0.0, ztest.velocity.z)
	var lateral_near := absf(v_near.dot(Vector3(0.0, 0.0, 1.0)))
	_check("near chase commits straight to target",
		lateral_near < 0.001,
		"lateral=%.6f" % lateral_near)

	# Determinism: same id twice -> same sign.
	var sign_a := Zombie.flank_sign_for(&"z_gtest_001")
	var sign_b := Zombie.flank_sign_for(&"z_gtest_001")
	_check("flank_sign_for deterministic per id",
		sign_a == sign_b, "a=%.1f b=%.1f" % [sign_a, sign_b])

	# Coverage: sample many ids -> both sides appear.
	var has_pos := false
	var has_neg := false
	for i in 24:
		var s := Zombie.flank_sign_for(&"zz_%d" % i)
		if s > 0.0:
			has_pos = true
		else:
			has_neg = true
	_check("mixed city ids split around survivor (both sides)",
		has_pos and has_neg,
		"pos=%s neg=%s" % [has_pos, has_neg])

	# Instance agreement: seeded zombie matches static helper.
	ActorRegistry.unregister(ztest.zombie_id)
	ztest.remove_from_group(&"zombies")
	ztest.queue_free()
	var z2 := Zombie.new()
	z2.requested_id = &"z_gtest_002"
	get_tree().current_scene.add_child(z2)
	z2.set_physics_process(false)
	_check("id-seeded zombie agrees with static helper",
		z2._flank_sign == Zombie.flank_sign_for(&"z_gtest_002"),
		"instance=%.1f static=%.1f" % [z2._flank_sign, Zombie.flank_sign_for(&"z_gtest_002")])
	ActorRegistry.unregister(z2.zombie_id)
	z2.remove_from_group(&"zombies")
	z2.queue_free()

	# --- 8. Save/load preserves death + clock -------------------------------
	var saved_day := GameClock.get_day()
	GameClock.advance(500.0)
	_check("save written", SaveManager.save_game())
	_check("load applied", SaveManager.load_game())
	await _wait_frames(3)
	_check("dead NPC did NOT respawn", ActorRegistry.get_actor(&"npc_hana") == null)
	_check("living NPC respawned", ActorRegistry.get_actor(&"npc_kenji") != null
			and not ActorRegistry.get_actor(&"npc_kenji").health.is_dead)
	_check("player respawned", ActorRegistry.get_actor(&"player") != null)
	_check("clock restored across load", GameClock.get_day() == saved_day,
			"%d vs %d" % [GameClock.get_day(), saved_day])

	# Clean up so the developer never inherits test state.
	SaveManager.delete_save()


# --- Soak mode: day/night, sleep AI, zombie wandering ------------------------

func _run_soak() -> void:
	print("[SmokeTest] soak: starting")
	await _wait(0.8)

	# Remember where zombies started so we can prove they move.
	var zombie_anchors := {}
	for zombie in get_tree().get_nodes_in_group(&"zombies"):
		zombie_anchors[zombie] = zombie.global_position

	# Make SLEEP the dominant goal tonight for every autonomous NPC.
	for survivor in get_tree().get_nodes_in_group(&"survivors"):
		if not survivor.is_player():
			survivor.needs.fatigue = 75.0

	GameClock.advance(800.0)  # 07:00 -> past nightfall
	print("[SmokeTest] soak: clock advanced to %s" % GameClock.time_string())
	_check("night reached after fast-forward", GameClock.is_night())

	await _wait(4.0)
	print("[SmokeTest] soak: brains reacted")

	var lamps := get_tree().get_nodes_in_group(&"streetlamp")
	var lamps_on := lamps.size() > 0
	for lamp in lamps:
		if not lamp.visible:
			lamps_on = false
	_check("streetlamps lit at night", lamps_on, "count=%d" % lamps.size())

	var sleeping := 0
	for survivor in get_tree().get_nodes_in_group(&"survivors"):
		if survivor.needs.sleeping:
			sleeping += 1
	_check("at least one NPC went to sleep", sleeping >= 1, str(sleeping))

	var moved := 0
	for zombie in zombie_anchors:
		if not is_instance_valid(zombie):
			moved += 1  # died or was removed - still "activity"
			continue
		if zombie.global_position.distance_to(zombie_anchors[zombie]) > 0.2:
			moved += 1
	_check("zombies wander over time", moved >= 1, str(moved))


# --- Helpers ----------------------------------------------------------------

func _stock_total(crate: FoodCrate) -> int:
	var total := 0
	for value in crate.contents.values():
		total += int(value)
	return total


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[SmokeTest] PASS  %s" % test_name)
	else:
		failures += 1
		print("[SmokeTest] FAIL  %s   (%s)" % [test_name, detail])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_frames(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
