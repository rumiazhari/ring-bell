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


func _ready() -> void:
	SaveManager.register_world_provider(self)

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
	elif user_args.has("--doortest"):
		var tester7: Node = load("res://debug/temp_door_probe.gd").new()
		tester7.name = "TempDoorProbe"
		add_child(tester7)
	elif user_args.has("--shot"):
		var probe: Node = load("res://debug/shot_probe.gd").new()
		probe.name = "ShotProbe"
		add_child(probe)


func _process(_delta: float) -> void:
	if _city_spawn_gate_active:
		_release_city_spawn_gate_when_ready()
	match _mode:
		WorldMode.LEGACY_BLOCK:
			_update_roof_visibility()
		WorldMode.STREAMED_CITY:
			_update_city_interior()


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
	_city_spawn_gate_active = false
	if is_instance_valid(player) and player.is_inside_tree():
		player.process_mode = Node.PROCESS_MODE_INHERIT


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

	hud.hide_death_screen()
	hud.refresh_quest_tracker()
