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
