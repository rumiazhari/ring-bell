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

enum WorldMode { LEGACY_BLOCK, STREAMED_CITY }

const ZOMBIE_COUNT_CITY := 16

var hud: HUD
var dialogue_ui: DialogueUI
var camera_rig: FollowCamera
var day_night: DayNightController
var player: Survivor

var _player_controller: PlayerController
var _buildings: Array = []             # legacy roof hiding
var _crates: Array[FoodCrate] = []
var _mode := WorldMode.LEGACY_BLOCK

var city_plan: CityPlan
var chunk_manager: ChunkManager


func _ready() -> void:
	SaveManager.register_world_provider(self)

	var args := OS.get_cmdline_user_args()
	_mode = WorldMode.STREAMED_CITY
	if args.has("--smoke") or args.has("--soak") or args.has("--legacy-block"):
		_mode = WorldMode.LEGACY_BLOCK

	if _mode == WorldMode.LEGACY_BLOCK:
		_build_legacy_block()
	else:
		_build_streamed_city()

	hud = HUD.new()
	add_child(hud)

	dialogue_ui = DialogueUI.new()
	add_child(dialogue_ui)
	dialogue_ui.dialogue_opened.connect(_on_dialogue_opened)
	dialogue_ui.dialogue_closed.connect(_on_dialogue_closed)

	day_night = DayNightController.new()
	add_child(day_night)

	camera_rig = FollowCamera.new()
	add_child(camera_rig)

	if _mode == WorldMode.LEGACY_BLOCK:
		_spawn_from_manifest()
	else:
		_spawn_city_population()

	# Optional automated regression passes (see DEVELOPMENT.md):
	#   godot --headless --path . -- --smoke     functional checks (legacy block)
	#   godot --headless --path . -- --soak      day/night + AI stability
	#   godot --headless --path . -- --citytest  city determinism checks
	var user_args := OS.get_cmdline_user_args()
	if user_args.has("--smoke") or user_args.has("--soak"):
		var tester: Node = load("res://debug/smoke_test.gd").new()
		tester.name = "SmokeTest"
		add_child(tester)
	elif user_args.has("--citytest"):
		var tester2: Node = load("res://debug/world_test.gd").new()
		tester2.name = "WorldTest"
		add_child(tester2)
	elif user_args.has("--shot"):
		var probe: Node = load("res://debug/shot_probe.gd").new()
		probe.name = "ShotProbe"
		add_child(probe)


func _process(_delta: float) -> void:
	if _mode == WorldMode.LEGACY_BLOCK:
		_update_roof_visibility()


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
	chunk_manager = ChunkManager.new()
	chunk_manager.name = "Chunks"
	add_child(chunk_manager)
	chunk_manager.setup(city_plan)


func _spawn_city_population() -> void:
	var entry: Dictionary = Population.PLAYER_ENTRY.duplicate(true)
	var spawn := city_plan.find_spawn_point() if city_plan != null \
			else Vector2.ZERO
	entry["position"] = Vector3(spawn.x, 0.15, spawn.y)
	_spawn_survivor(entry, {})
	player = ActorRegistry.get_actor(&"player")
	if player != null:
		chunk_manager.set_player(player)
		_wire_player(player)
	else:
		chunk_manager.set_player(null)

	for p in _city_zombie_positions():
		var zombie := Zombie.new()
		add_child(zombie)
		zombie.position = Vector3(p.x, 0.1, p.y)


## Deterministic zombie scatter: grid intersections ringed around spawn,
## jittered along streets. Pure plan queries + seeded rng -> identical runs.
func _city_zombie_positions() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var rng := WorldSeed.rng_for("city_zombies", [])
	var center := city_plan.find_spawn_point()
	var candidates: Array[Vector2] = []
	for i in range(-4, 5):
		for j in range(-4, 5):
			var p := Vector2(city_plan.line_pos(0, i), city_plan.line_pos(1, j))
			var d := p.distance_to(center)
			if d > 24.0 and d < 130.0:
				candidates.append(p)
	# Seeded Fisher-Yates so zombie placement never depends on global RNG.
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp
	while out.size() < ZOMBIE_COUNT_CITY and not candidates.is_empty():
		var base: Vector2 = candidates.pop_back()
		out.append(base + Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)))
	return out


func _wire_player(p: Survivor) -> void:
	player = p
	p.died.connect(_on_player_died)
	_player_controller = PlayerController.new()
	p.add_child(_player_controller)
	_player_controller.setup(hud)
	camera_rig.set_target(p)


func _on_survivor_interacted(interactor: Node3D, npc: Survivor) -> void:
	if not dialogue_ui.is_open():
		dialogue_ui.open_for(npc, interactor)


func _on_player_died(_p: Survivor) -> void:
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
	if player == null or not is_instance_valid(player):
		return
	var p := Vector2(player.global_position.x, player.global_position.z)
	for building in _buildings:
		var rect: Rect2 = building["rect"]
		var inside := rect.grow(0.4).has_point(p)
		if building.get("roof_hidden", false) == inside:
			continue
		building["roof_hidden"] = inside
		for roof_node in building.get("roof_nodes", []):
			if is_instance_valid(roof_node):
				(roof_node as MeshInstance3D).visible = not inside


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
			_spawn_city_population()
			if chunk_manager != null and data.has("chunks"):
				chunk_manager.load_state(data["chunks"])

	player = ActorRegistry.get_actor(&"player")
	if player != null:
		_wire_player(player)

	hud.hide_death_screen()
	hud.refresh_quest_tracker()
