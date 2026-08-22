extends Node3D
## Prototype 0 entry scene and SaveManager "world provider".
##
## Responsibilities:
##   - build the test block (LevelBuilder)
##   - create UI, camera, day/night controller
##   - spawn population from world/population.gd (or restore from a save)
##   - wire player controls, dialogue opening, roof hiding
##   - implement save_state()/load_state() for live actors + crates
##
## Everything else lives in autoloads and components.

var hud: HUD
var dialogue_ui: DialogueUI
var camera_rig: FollowCamera
var day_night: DayNightController
var player: Survivor

var _player_controller: PlayerController
var _buildings: Array = []
var _crates: Array[FoodCrate] = []


func _ready() -> void:
	SaveManager.register_world_provider(self)

	var built: Dictionary = LevelBuilder.build(self)
	_buildings = built["buildings"]
	for crate in built["crates"]:
		_crates.append(crate)

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

	_spawn_from_manifest()

	# Optional automated regression passes (see DEVELOPMENT.md):
	#   godot --headless --path . -- --smoke   functional checks
	#   godot --headless --path . -- --soak    day/night + AI stability
	var user_args := OS.get_cmdline_user_args()
	if user_args.has("--smoke") or user_args.has("--soak"):
		var tester: Node = load("res://debug/smoke_test.gd").new()
		tester.name = "SmokeTest"
		add_child(tester)


func _process(_delta: float) -> void:
	_update_roof_visibility()


# --- Spawning ---------------------------------------------------------------

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


# --- Roof hiding ------------------------------------------------------------

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
	var survivor_states: Array = []
	for node in get_tree().get_nodes_in_group(&"survivors"):
		survivor_states.append(node.save_state())
	var crate_states: Array = []
	for crate in _crates:
		if is_instance_valid(crate):
			crate_states.append(crate.save_state())
	return {"survivors": survivor_states, "crates": crate_states}


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

	var entries: Array = [Population.PLAYER_ENTRY]
	entries.append_array(Population.SURVIVORS)
	for entry in entries:
		# Death persistence: NPCs recorded dead in WorldState never respawn.
		if WorldState.is_dead(entry["id"]):
			continue
		_spawn_survivor(entry.duplicate(true), saved_by_id.get(str(entry["id"]), {}))

	player = ActorRegistry.get_actor(&"player")
	if player != null:
		_wire_player(player)

	for pos in Population.ZOMBIE_POSITIONS:
		var zombie := Zombie.new()
		add_child(zombie)
		zombie.position = pos

	var crate_states: Array = data.get("crates", [])
	for i in mini(crate_states.size(), _crates.size()):
		_crates[i].load_state(crate_states[i])

	hud.hide_death_screen()
	hud.refresh_quest_tracker()
