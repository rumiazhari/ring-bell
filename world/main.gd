extends Node3D
## Entry scene and SaveManager "world provider".
##
## WORLD MODES:
##   LEGACY - the P0 hand-built test block (LevelBuilder). Used by --smoke,
##            --soak and --legacy-block; keeps every Prototype 0 assertion
##            valid until the narrative cast migrates into the city.
##   CITY   - the streamed procedural city (ChunkManager + CityPlan). Default
##            mode. Spawns the player on a plaza/street anchor plus ambient
##            zombies; NPC cast migration is a pending roadmap item.
##
## Responsibilities (both modes):
##   - create UI, camera, day/night controller
##   - spawn population (or restore from a save)
##   - wire player controls, dialogue opening
##   - implement save_state()/load_state() as SaveManager's world provider
##
## SPAWN MENU (additive, Option A):
##   In windowed interactive runs (no --headless / no test flags) _ready()
##   shows MainMenu and DEFILES world streaming until the player picks a spawn
##   kind. Only after pick does the LoadingScreen appear, the city streams
##   fully (gate wait), then gameplay starts — avoids first-frame spike.
##   Headless and all --*test paths bypass the menu entirely and behave exactly
##   as before, so existing harnesses stay green.

enum WorldMode { LEGACY_BLOCK, STREAMED_CITY }

const SpawnPoints = preload("res://world/spawn_points.gd")

var hud: HUD
var dialogue_ui: DialogueUI
var camera_rig: FollowCamera
var day_night: DayNightController
var player: Survivor

var _player_controller: PlayerController
var _buildings: Array = []             # legacy roof hiding
var _crates: Array[FoodCrate] = []
var _mode := WorldMode.LEGACY_BLOCK
var _gate_coord := Vector2i(99, 99)   # chunk currently floor-gated
var _gate_tag := ""                   # building id currently floor-gated
var _was_inside := false              # interior hysteresis state
var _faded := []                      # currently faded facade letters

var city_plan: CityPlan
var chunk_manager: ChunkManager
var city_spawner: CitySpawner
var _city_spawn_gate_active := false

# --- Deferred menu/loading state (additive) ---
var _main_menu: CanvasLayer = null
var _loading_screen: CanvasLayer = null
var _pending_spawn_kind: StringName = &""
var _game_started := false


func _ready() -> void:
	SaveManager.register_world_provider(self)
	# --seed override for deterministic captures (fringe part 1)
	var __seed_args := OS.get_cmdline_user_args()
	var __seed_idx := __seed_args.find("--seed")
	if __seed_idx != -1 and __seed_idx + 1 < __seed_args.size():
		var __s_val := int(__seed_args[__seed_idx + 1])
		WorldSeed.set_world_seed(__s_val)
		print("[Main] seed override --seed %d" % __s_val)

	var args := OS.get_cmdline_user_args()
	_mode = WorldMode.STREAMED_CITY
	if args.has("--smoke") or args.has("--soak") or args.has("--legacy-block"):
		_mode = WorldMode.LEGACY_BLOCK

	# --import: bounded BOOT check. Reaching _ready means every global
	# class parsed (a broken script fails the whole boot with SCRIPT ERROR),
	# so report success and quit before building the heavy streamed city.
	if args.has("--import"):
		print("[Import] boot OK - all scripts parsed, world build skipped")
		get_tree().quit(0)
		return

	# Focused regression harnesses own their fixtures and intentionally bypass
	# normal city startup so their materialization contracts stay isolated.
	if args.has("--streamingregressiontest"):
		var streaming_tester: Node = load("res://debug/streaming_regression_test.gd").new()
		streaming_tester.name = "StreamingRegressionTest"
		add_child(streaming_tester)
		return
	if args.has("--worldrealizationtest"):
		var realization_tester: Node = load("res://debug/world_realization_test.gd").new()
		realization_tester.name = "WorldRealizationTest"
		add_child(realization_tester)
		return

	# Deferred menu: windowed interactive only — headless/tests go straight through
	if _should_show_main_menu(args):
		_show_main_menu()
		return

	# Original immediate startup (tests, legacy, headless)
	if _mode == WorldMode.LEGACY_BLOCK:
		_build_legacy_block()
	else:
		_build_streamed_city()

	_create_game_ui()

	if _mode == WorldMode.LEGACY_BLOCK:
		_spawn_from_manifest()
	else:
		_spawn_city_population()

	# Optional automated regression passes (see DEVELOPMENT.md):
	#   godot --headless --path . -- --smoke        functional checks (legacy)
	#   godot --headless --path . -- --soak         day/night + AI stability
	#   godot --headless --path . -- --citytest     city determinism checks
	#   godot --headless --path . -- --cityruntime  streamed-city integration
	var user_args := OS.get_cmdline_user_args()
	if user_args.has("--smoke") or user_args.has("--soak"):
		var tester: Node = load("res://debug/smoke_test.gd").new()
		tester.name = "SmokeTest"
		add_child(tester)
	elif user_args.has("--citytest"):
		var tester2: Node = load("res://debug/world_test.gd").new()
		tester2.name = "WorldTest"
		add_child(tester2)
	elif user_args.has("--cityruntime"):
		var tester3: Node = load("res://debug/city_runtime_test.gd").new()
		tester3.name = "CityRuntimeTest"
		add_child(tester3)
	elif user_args.has("--walkthrough"):
		var tester4: Node = load("res://debug/walkthrough_probe.gd").new()
		tester4.name = "WalkthroughProbe"
		add_child(tester4)
	elif user_args.has("--havoctest"):
		var tester5: Node = load("res://debug/havoc_test.gd").new()
		tester5.name = "HavocTest"
		add_child(tester5)
	elif user_args.has("--terraintest"):
		var tester6: Node = load("res://debug/terrain_test.gd").new()
		tester6.name = "TerrainTest"
		add_child(tester6)
	elif user_args.has("--terrainmaterialtest"):
		var tester6b: Node = load("res://debug/terrain_material_test.gd").new()
		tester6b.name = "TerrainMaterialTest"
		add_child(tester6b)
	elif user_args.has("--hydrotest") or user_args.has("--hydromaterialtest"):
		var tester6c: Node = load("res://debug/hydrology_test.gd").new()
		tester6c.name = "HydrologyTest"
		add_child(tester6c)
	elif user_args.has("--biometest") or user_args.has("--biomematerialtest"):
		var tester6d: Node = load("res://debug/biome_test.gd").new()
		tester6d.name = "BiomeTest"
		add_child(tester6d)
	elif user_args.has("--roadtest") or user_args.has("--settlementtest") or user_args.has("--roadmaterialtest"):
		var tester6e: Node = load("res://debug/road_test.gd").new()
		tester6e.name = "RoadTest"
		add_child(tester6e)
	elif user_args.has("--ruraltest") or user_args.has("--settlementbuildingtest") or user_args.has("--ruralfabrictest"):
		var tester6f: Node = load("res://debug/rural_test.gd").new()
		tester6f.name = "RuralTest"
		add_child(tester6f)
	elif user_args.has("--fringetest"):
		var tester6fr: Node = load("res://debug/fringe_test.gd").new()
		tester6fr.name = "FringeTest"
		add_child(tester6fr)
	elif user_args.has("--cavetest"):
		var tester6g: Node = load("res://debug/cave_test.gd").new()
		tester6g.name = "CaveTest"
		add_child(tester6g)
	elif user_args.has("--verticaltest") or user_args.has("--vertical"):
		var tester6h: Node = load("res://debug/vertical_test.gd").new()
		tester6h.name = "VerticalTest"
		add_child(tester6h)
	elif user_args.has("--animationtest"):
		var tester_anim: Node = load("res://debug/animation_test.gd").new()
		tester_anim.name = "AnimationTest"
		add_child(tester_anim)
	elif user_args.has("--doortest"):
		var tester7: Node = load("res://debug/temp_door_probe.gd").new()
		tester7.name = "TempDoorProbe"
		add_child(tester7)
	elif user_args.has("--shot"):
		var probe: Node = load("res://debug/shot_probe.gd").new()
		probe.name = "ShotProbe"
		add_child(probe)
	elif user_args.has("--g10p1-capture"):
		var cap: Node = load("res://debug/g10p1_capture.gd").new()
		cap.name = "G10P1Capture"
		add_child(cap)
	elif user_args.has("--fringe-capture"):
		var cap2: Node = load("res://debug/fringe_capture.gd").new()
		cap2.name = "FringeCapture"
		add_child(cap2)
	elif user_args.has("--fringe-dump"):
		var dump: Node = load("res://debug/fringe_dump.gd").new()
		dump.name = "FringeDump"
		add_child(dump)


func _process(_delta: float) -> void:
	if _city_spawn_gate_active:
		_release_city_spawn_gate_when_ready()
		if _loading_screen != null and is_instance_valid(_loading_screen):
			_update_loading_progress()
	# no interior updates until game actually started (menu showing)
	if not _game_started and _main_menu != null and is_instance_valid(_main_menu):
		return
	# also wait until hud/camera exist when deferred
	if hud == null or camera_rig == null:
		return
	match _mode:
		WorldMode.LEGACY_BLOCK:
			_update_roof_visibility()
		WorldMode.STREAMED_CITY:
			_update_city_interior()

# ---------- Menu / loading gate ----------

func _should_show_main_menu(args: PackedStringArray) -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if OS.has_feature("headless"):
		return false
	# Any test flag bypasses menu
	var test_flags: Array[String] = [
			"--smoke", "--soak", "--legacy-block",
			"--citytest", "--cityruntime", "--walkthrough", "--havoctest",
			"--terraintest", "--terrainmaterialtest",
			"--hydrotest", "--hydromaterialtest",
			"--biometest", "--biomaterialtest",
			"--roadtest", "--settlementtest", "--roadmaterialtest",
			"--ruraltest", "--settlementbuildingtest", "--ruralfabrictest",
			"--fringetest",
			"--cavetest",
		"--fringe-capture", "--fringe-dump", "--seed",
		"--verticaltest", "--vertical",
			"--animationtest", "--streamingregressiontest",
			"--import", "--shot", "--doortest", "--g10p1-capture"
	]
	for f in test_flags:
		if args.has(f):
			return false
	return true

func _show_main_menu() -> void:
	if _main_menu != null and is_instance_valid(_main_menu):
		return
	var script: Script = load("res://ui/main_menu.gd") as Script
	if script == null:
		push_error("Main: ui/main_menu.gd not found — falling back to city spawn")
		_build_streamed_city()
		_create_game_ui()
		_spawn_city_population()
		return
	_main_menu = (script.new() as CanvasLayer)
	_main_menu.name = "MainMenu"
	add_child(_main_menu)
	if _main_menu.has_signal("spawn_selected"):
		_main_menu.connect("spawn_selected", _on_spawn_selected)
	if _main_menu.has_signal("load_game_requested"):
		_main_menu.connect("load_game_requested", _on_load_game_requested)

func _on_spawn_selected(kind: StringName) -> void:
	_pending_spawn_kind = kind
	if _main_menu != null and is_instance_valid(_main_menu):
		_main_menu.queue_free()
		_main_menu = null
	_show_loading_screen("Spawning at %s..." % SpawnPoints.label_for(kind))
	_start_game_with_spawn(kind)

func _on_load_game_requested() -> void:
	if not SaveManager.has_save():
		# menu will show disabled, but guard anyway
		print("[Main] no save to load")
		return
	if _main_menu != null and is_instance_valid(_main_menu):
		_main_menu.queue_free()
		_main_menu = null
	_show_loading_screen("Loading save...")
	_mode = WorldMode.STREAMED_CITY
	_build_streamed_city()
	_create_game_ui()
	# defer one frame so ChunkManager is in tree before SaveManager restores seed
	await get_tree().process_frame
	var ok: bool = SaveManager.load_game()
	if not ok:
		push_warning("Main: SaveManager.load_game failed")
		_hide_loading_screen()
		_show_main_menu()
		return
	# SaveManager.load_game queues _respawn_after_load deferred — wait for player + gate
	_wait_for_save_load_async()

func _wait_for_save_load_async() -> void:
	# player is spawned via _respawn_after_load deferred; wait for it
	var t := 0.0
	while t < 14.0:
		await get_tree().process_frame
		if player != null and is_instance_valid(player):
			if _city_spawn_gate_active:
				_release_city_spawn_gate_when_ready()
			_update_loading_progress()
			if not _city_spawn_gate_active:
				# extra settle frames
				for i in 3:
					await get_tree().process_frame
				break
		t += get_process_delta_time()
		if _loading_screen != null and is_instance_valid(_loading_screen) and _loading_screen.has_method("set_progress"):
			_loading_screen.call("set_progress", clampf(18.0 + t * 6.0, 18.0, 88.0), "")
	_hide_loading_screen()
	_game_started = true

func _start_game_with_spawn(kind: StringName) -> void:
	if _mode == WorldMode.LEGACY_BLOCK:
		_build_legacy_block()
		_create_game_ui()
		_spawn_from_manifest()
	else:
		_build_streamed_city()
		_create_game_ui()
		_spawn_city_population_with_override(kind)
	_wait_for_initial_chunks_async()

func _wait_for_initial_chunks_async() -> void:
	var t := 0.0
	while _city_spawn_gate_active and t < 14.0:
		await get_tree().process_frame
		_release_city_spawn_gate_when_ready()
		_update_loading_progress()
		t += get_process_delta_time()
		if _loading_screen != null and is_instance_valid(_loading_screen) and _loading_screen.has_method("set_progress"):
			var pct := clampf(34.0 + t * 8.0, 34.0, 86.0)
			if not _city_spawn_gate_active:
				pct = 90.0
			_loading_screen.call("set_progress", pct, "")
	# let streaming fill 3x3 a few frames
	for i in 4:
		await get_tree().process_frame
		_update_loading_progress()
	if _loading_screen != null and is_instance_valid(_loading_screen) and _loading_screen.has_method("set_progress"):
		_loading_screen.call("set_progress", 100.0, "World ready")
	await get_tree().create_timer(0.18).timeout
	_hide_loading_screen()
	_game_started = true

func _create_game_ui() -> void:
	if hud == null:
		hud = HUD.new()
		add_child(hud)
	if dialogue_ui == null:
		dialogue_ui = DialogueUI.new()
		add_child(dialogue_ui)
		dialogue_ui.dialogue_opened.connect(_on_dialogue_opened)
		dialogue_ui.dialogue_closed.connect(_on_dialogue_closed)
	if day_night == null:
		day_night = DayNightController.new()
		add_child(day_night)
	if camera_rig == null:
		camera_rig = FollowCamera.new()
		add_child(camera_rig)

func _show_loading_screen(text: String) -> void:
	if _loading_screen != null and is_instance_valid(_loading_screen):
		if _loading_screen.has_method("set_progress"):
			_loading_screen.call("set_progress", 6.0, text)
		return
	var script: Script = load("res://ui/loading_screen.gd") as Script
	if script == null:
		push_warning("Main: loading_screen.gd missing")
		return
	_loading_screen = (script.new() as CanvasLayer)
	_loading_screen.name = "LoadingScreen"
	add_child(_loading_screen)
	if _loading_screen.has_method("set_progress"):
		_loading_screen.call("set_progress", 6.0, text)

func _hide_loading_screen() -> void:
	if _loading_screen != null and is_instance_valid(_loading_screen):
		_loading_screen.queue_free()
		_loading_screen = null

func _update_loading_progress() -> void:
	if _loading_screen == null or not is_instance_valid(_loading_screen):
		return
	var pct := 46.0
	var sub := ""
	if chunk_manager != null:
		if _city_spawn_gate_active:
			pct = 52.0
			sub = "Waiting for terrain collision..."
		else:
			pct = 90.0
			sub = "Finalizing streaming..."
		if chunk_manager.has_method("debug_lines"):
			var lines: PackedStringArray = chunk_manager.debug_lines()
			if not lines.is_empty():
				# first line is most informative for debug
				sub = String(lines[0])
	if _loading_screen.has_method("set_progress"):
		_loading_screen.call("set_progress", pct, "")
	if _loading_screen.has_method("set_sub_text"):
		_loading_screen.call("set_sub_text", sub)


# --- Legacy block ------------------------------------------------------------

func _build_legacy_block() -> void:
	var built: Dictionary = LevelBuilder.build(self)
	_buildings = built["buildings"]
	for crate in built["crates"]:
		_crates.append(crate)


func _spawn_from_manifest() -> void:
	_spawn_survivor(Population.PLAYER_ENTRY.duplicate(true), {})
	for entry in Population.SURVIVORS:
		_spawn_survivor(entry.duplicate(true), {})
	player = ActorRegistry.get_actor(&"player")
	if player != null:
		_wire_player(player)
	else:
		push_error("Main: no player spawned - check Population.PLAYER_ENTRY")

	for pos in Population.ZOMBIE_POSITIONS:
		var zombie := Zombie.new()
		add_child(zombie)
		zombie.position = pos


## entry: Population manifest shape. saved_state: optional Survivor save data.
func _spawn_survivor(entry: Dictionary, saved_state: Dictionary) -> Survivor:
	var survivor := Survivor.new()
	survivor.configure(entry)
	survivor.position = entry.get("position", Vector3(0, 0.1, 0))
	survivor.facing = entry.get("facing", Vector3(0, 0, -1))
	add_child(survivor)
	if not saved_state.is_empty():
		survivor.load_state(saved_state)

	if survivor.is_player():
		return survivor

	var brain := NPCBrain.new()
	brain.home_position = survivor.global_position
	brain.cowardice = float(entry.get("cowardice", 1.0))
	survivor.add_child(brain)
	survivor.interactable.interacted.connect(_on_survivor_interacted.bind(survivor))
	return survivor


# --- Streamed city -----------------------------------------------------------

func _build_streamed_city() -> void:
	city_plan = CityPlan.new()
	var wplan := WorldPlan.new(city_plan.seed_used)
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "Chunks"
	add_child(chunk_manager)
	chunk_manager.setup_world(city_plan, wplan)
	if OS.get_cmdline_user_args().has("--g10p1-capture"):
		# The real windowed evidence runner still uses the production builders and
		# Forward+ renderer, but avoids worker/cache races while it jumps between
		# six far deterministic locations.
		chunk_manager.synchronous = true


func _spawn_city_population() -> void:
	var entry: Dictionary = Population.PLAYER_ENTRY.duplicate(true)
	var wplan: WorldPlan = chunk_manager.world_plan if chunk_manager != null and chunk_manager.world_plan != null else WorldPlan.new(city_plan.seed_used if city_plan != null else WorldSeed.get_world_seed())
	# Normal play starts at the WorldPlan-owned urban terrace. CityPlan supplies
	# only the city-center X/Z anchor; it no longer owns the physical Y datum.
	var spawn_pos: Vector3 = SpawnPoints.get_spawn_position(&"city_center", wplan, city_plan)
	entry["position"] = spawn_pos
	_spawn_survivor(entry, {})
	player = ActorRegistry.get_actor(&"player")
	if player != null:
		chunk_manager.set_player(player)
		_wire_player(player)
		# Chunk streaming starts after this scene's ready pass. Hold the
		# player (and its controllers) until the exact spawn chunk has a
		# terrain body, otherwise the first physics frames apply gravity in
		# an empty world and the player falls below the eventual floor.
		_city_spawn_gate_active = true
		player.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		chunk_manager.set_player(null)

	# Per-ACTIVE-chunk procedural zombie population on road space.
	if city_spawner != null and is_instance_valid(city_spawner):
		city_spawner.queue_free()
	city_spawner = CitySpawner.new()
	city_spawner.name = "CitySpawner"
	city_spawner.setup(city_plan, chunk_manager)
	add_child(city_spawner)

## Spawn with explicit kind via SpawnPoints (additive, for menu testing)
func _spawn_city_population_with_override(kind: StringName) -> void:
	var entry: Dictionary = Population.PLAYER_ENTRY.duplicate(true)
	var wplan: WorldPlan = chunk_manager.world_plan if chunk_manager != null and chunk_manager.world_plan != null else WorldPlan.new(city_plan.seed_used if city_plan != null else WorldSeed.get_world_seed())
	var spawn_pos: Vector3 = SpawnPoints.get_spawn_position(kind, wplan, city_plan)
	# SpawnPoints already returns WorldPlan surface + clearance.
	# Guard against water: if still in water, fallback to city center.
	if wplan.water_body_at(Vector2(spawn_pos.x, spawn_pos.z)) != &"":
		var fallback: Vector3 = SpawnPoints.get_spawn_position(&"city_center", wplan, city_plan)
		spawn_pos = fallback
	entry["position"] = spawn_pos
	print("[Main] spawn kind=%s pos=(%.1f, %.1f, %.1f)" % [kind, spawn_pos.x, spawn_pos.y, spawn_pos.z])
	_spawn_survivor(entry, {})
	player = ActorRegistry.get_actor(&"player")
	if player != null:
		chunk_manager.set_player(player)
		_wire_player(player)
		_city_spawn_gate_active = true
		player.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		chunk_manager.set_player(null)

	if city_spawner != null and is_instance_valid(city_spawner):
		city_spawner.queue_free()
	city_spawner = CitySpawner.new()
	city_spawner.name = "CitySpawner"
	city_spawner.setup(city_plan, chunk_manager)
	add_child(city_spawner)


## Keep the initial CITY survivor stationary until its spawn chunk's
## asynchronous materialization has installed the real terrain collision.
## This is a startup synchronization gate, not a movement/teleport fallback.
func _release_city_spawn_gate_when_ready() -> void:
	if not _city_spawn_gate_active or player == null \
			or not is_instance_valid(player) or not player.is_inside_tree() \
			or chunk_manager == null or not is_instance_valid(chunk_manager) \
			or not chunk_manager.is_inside_tree():
		return
	var coord := WorldSeed.chunk_coord(player.global_position.x,
			player.global_position.z)
	var chunk := chunk_manager.get_node_or_null(
			NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
	if chunk == null or not is_instance_valid(chunk) or not chunk.is_inside_tree():
		return
	var terrain_body := chunk.get_node_or_null(
			NodePath("Terrain_%d_%d/TerrainBody" % [coord.x, coord.y]))
	if terrain_body == null or not is_instance_valid(terrain_body):
		return
	# The semantic candidate was chosen by WorldPlan; now verify the exact
	# materialized WALKABLE_GROUND collision and capsule clearance before any
	# player physics is enabled. This is validation, never a roof raycast spawn.
	var verified: Dictionary = chunk_manager.verify_spawn_surface(player.global_position)
	if not bool(verified.get("ok", false)):
		return
	player.global_position.y = float(verified.get("feet_y", player.global_position.y))
	_city_spawn_gate_active = false
	if is_instance_valid(player) and player.is_inside_tree():
		player.process_mode = Node.PROCESS_MODE_INHERIT


func _wire_player(p: Survivor) -> void:
	player = p
	p.died.connect(_on_player_died)
	_player_controller = PlayerController.new()
	p.add_child(_player_controller)
	if hud != null:
		_player_controller.setup(hud)
	if camera_rig != null:
		camera_rig.set_target(p)


func _on_survivor_interacted(interactor: Node3D, npc: Survivor) -> void:
	if dialogue_ui != null and not dialogue_ui.is_open():
		dialogue_ui.open_for(npc, interactor)


func _on_player_died(_p: Survivor) -> void:
	if hud != null:
		hud.show_death_screen()


func _on_dialogue_opened() -> void:
	if _player_controller != null:
		_player_controller.input_enabled = false


func _on_dialogue_closed() -> void:
	if _player_controller != null and player != null \
			and is_instance_valid(player) and not player.health.is_dead:
		_player_controller.input_enabled = true


# --- Roof hiding (legacy block only) -----------------------------------------

## Hide building roofs while the player stands inside the footprint so
## interiors stay readable from the elevated camera.
func _update_roof_visibility() -> void:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return
	var p := Vector2(player.global_position.x, player.global_position.z)
	var any_inside := false
	for building in _buildings:
		var rect: Rect2 = building["rect"]
		var inside := rect.grow(0.4).has_point(p)
		any_inside = any_inside or inside
		if building.get("roof_hidden", false) == inside:
			continue
		building["roof_hidden"] = inside
		for roof_node in building.get("roof_nodes", []):
			if is_instance_valid(roof_node):
				(roof_node as MeshInstance3D).visible = not inside
	if camera_rig != null:
		camera_rig.set_interior(any_inside)


# --- Interior cutaway (streamed city) -----------------------------------------

## REAL interior detection + sector cutaway (P1):
## 1. Interior state comes from InteriorProbe (actual interior boundary,
##    valid storey under the feet, hysteresis at thresholds) - no more
##    generously-grown footprint triggering while still outside.
## 2. Layers above the resident storey hide; the camera-facing facade(s) of
##    the resident storey fade based on the CAMERA's sector around the
##    player, so rotating the camera swaps which wall is faded. Opposite
##    walls stay visible and preserve the room shape.
func _update_city_interior() -> void:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree() \
			or city_plan == null or chunk_manager == null \
			or not is_instance_valid(chunk_manager) or not chunk_manager.is_inside_tree():
		return
	var p3 := player.global_position
	var p := Vector2(p3.x, p3.z)
	var spec := {}
	var inside := false
	var floor_i := -1
	for candidate in city_plan.buildings_in_rect(
			Rect2(p - Vector2.ONE * 1.5, Vector2.ONE * 3.0)):
		var res: Dictionary = InteriorProbe.evaluate(
				p, p3.y, candidate, _was_inside)
		if bool(res["inside"]):
			spec = candidate
			inside = true
			floor_i = int(res["floor"])
			break
	if not inside:
		_was_inside = false
	else:
		_was_inside = true

	var gate_active := inside and not spec.is_empty()
	var n := -1
	if gate_active:
		# Roof-deck rule: floor_i == n means standing on the deck - keep the
		# interior camera, hide roof dressing, keep deck layer visible.
		n = mini(int(spec["floors"]), 8)
		gate_active = floor_i >= 0 and floor_i <= n
	if gate_active:
		var center: Vector2 = (spec["rect"] as Rect2).get_center()
		var owner_coord := WorldSeed.chunk_coord(center.x, center.y)
		var tag := str(spec["id"])
		# Camera-sector facades to fade on the resident storey. P0-4: use
		# the ACTUAL Camera3D lens position - the rig origin tracks the
		# PLAYER, so it sits at the player and its "sector" was near zero.
		var cam_xz := p
		if camera_rig != null and is_instance_valid(camera_rig) and camera_rig.is_inside_tree():
			# Guard against shutdown race where camera_rig is freed but still instance-valid.
			var cam_pos: Vector3 = camera_rig.camera_world_position() if camera_rig.has_method("camera_world_position") else Vector3.ZERO
			if cam_pos.is_finite():
				cam_xz = Vector2(cam_pos.x, cam_pos.z)
			else:
				# Fallback to rig position if camera not yet inside tree.
				if camera_rig.is_inside_tree():
					cam_xz = Vector2(camera_rig.global_position.x, camera_rig.global_position.z)
		var new_faded: Array = InteriorProbe.faded_facades(p, cam_xz) \
				if floor_i < n else []
		if owner_coord != _gate_coord or tag != _gate_tag:
			if _gate_coord != Vector2i(99, 99):
				chunk_manager.apply_floor_gate(_gate_coord, "", -1)
		chunk_manager.apply_floor_gate(owner_coord, tag, floor_i, new_faded)
		_gate_coord = owner_coord
		_gate_tag = tag
		_faded = new_faded
	elif _gate_coord != Vector2i(99, 99):
		chunk_manager.apply_floor_gate(_gate_coord, "", -1)
		_gate_coord = Vector2i(99, 99)
		_gate_tag = ""
		_faded = []
	if camera_rig != null:
		camera_rig.set_interior(gate_active)


# --- World provider contract (see core/autoload/save_manager.gd) -------------

func save_state() -> Dictionary:
	var data := {"survivors": [], "crates": []}
	for node in get_tree().get_nodes_in_group(&"survivors"):
		data["survivors"].append(node.save_state())
	for crate in _crates:
		if is_instance_valid(crate):
			data["crates"].append(crate.save_state())
	if _mode == WorldMode.STREAMED_CITY and chunk_manager != null:
		data["chunks"] = chunk_manager.save_state()
	return data


func load_state(data: Dictionary) -> void:
	if dialogue_ui != null and is_instance_valid(dialogue_ui):
		dialogue_ui.close()
	for node in get_tree().get_nodes_in_group(&"survivors"):
		node.queue_free()
	for node in get_tree().get_nodes_in_group(&"zombies"):
		node.queue_free()
	ActorRegistry.clear()
	player = null
	# Respawn next frame so freed nodes are gone before new ones register.
	call_deferred("_respawn_after_load", data)


func _respawn_after_load(data: Dictionary) -> void:
	var saved_by_id := {}
	for state in data.get("survivors", []):
		saved_by_id[state.get("id", "")] = state

	# NOTE: the world seed was already restored by SaveManager BEFORE this
	# provider call, so city geometry below regenerates from the saved seed.

	match _mode:
		WorldMode.LEGACY_BLOCK:
			var entries: Array = [Population.PLAYER_ENTRY]
			entries.append_array(Population.SURVIVORS)
			for entry in entries:
				# Death persistence: NPCs recorded dead in WorldState never respawn.
				if WorldState.is_dead(entry["id"]):
					continue
				_spawn_survivor(entry.duplicate(true), saved_by_id.get(str(entry["id"]), {}))

			for pos in Population.ZOMBIE_POSITIONS:
				var zombie := Zombie.new()
				add_child(zombie)
				zombie.position = pos

			var crate_states: Array = data.get("crates", [])
			for i in mini(crate_states.size(), _crates.size()):
				_crates[i].load_state(crate_states[i])

		WorldMode.STREAMED_CITY:
			# A different seed means a DIFFERENT city: drop every cached
			# plan result and resident chunk before repopulating.
			if chunk_manager != null \
					and (city_plan == null
							or city_plan.seed_used != WorldSeed.get_world_seed()):
				chunk_manager.reset_stream()
				city_plan = CityPlan.new()
				chunk_manager.plan = city_plan
			_spawn_city_population()
			if chunk_manager != null and data.has("chunks"):
				chunk_manager.load_state(data["chunks"])

	player = ActorRegistry.get_actor(&"player")
	if player != null:
		_wire_player(player)

	if hud != null:
		hud.hide_death_screen()
		hud.refresh_quest_tracker()
