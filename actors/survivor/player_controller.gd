class_name PlayerController
extends Node
## Reads input actions and drives the parent Survivor.
##
## Also owns the interaction scan (nearest interactable within range), the
## HUD prompt and the WeaponSystem (slots 1-4 switch guns; melee stays on
## slot 1). While a dialogue is open, main.gd sets input_enabled = false.

const INTERACT_RANGE := 2.4

var input_enabled := true

var _survivor: Survivor
var _hud: Node = null                 # injected by main.gd (ui/hud.gd)
var _camera_rig: Node3D = null        # found via group "camera_rig"
var _hovered: Node3D = null           # interactable body currently in range
var _weapons: WeaponSystem            # created lazily in setup()


func _ready() -> void:
	_survivor = get_parent() as Survivor


func setup(hud: Node) -> void:
	_hud = hud
	_weapons = WeaponSystem.new()
	_survivor.add_child(_weapons)
	if _hud != null and _hud.has_method(&"set_weapon_label"):
		EventBus.weapon_switched.connect(
				func(weapon_name: String) -> void:
					_hud.call(&"set_weapon_label", weapon_name))
		_hud.call(&"set_weapon_label", _weapons.weapon_label())
	if _survivor.parkour != null:
		_survivor.parkour.ledge_grabbed.connect(_on_ledge_grabbed)


## Phase F: traversal feedback - flash a HUD notice whenever the survivor
## grabs a ledge mid-fall, distinguishing rooftop cornices from plain props.
func _on_ledge_grabbed(is_building: bool) -> void:
	if _hud == null:
		return
	var text := "Mantled onto the rooftop!" if is_building else "Grabbed the ledge!"
	_hud.call("flash_notice", text)


func _physics_process(delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		_survivor.stop_moving()
		_set_prompt("")
		return

	if not input_enabled:
		_survivor.stop_moving()
		_set_prompt("")
		return

	var yaw := 0.0
	if _camera_rig != null and is_instance_valid(_camera_rig):
		yaw = _camera_rig.rotation.y
	else:
		var rigs := get_tree().get_nodes_in_group(&"camera_rig")
		if rigs.size() > 0:
			_camera_rig = rigs[0]
			yaw = _camera_rig.rotation.y

	var raw := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var dir := Vector3(raw.x, 0.0, raw.y).rotated(Vector3.UP, yaw)
	_survivor.request_move(dir, Input.is_action_pressed(&"sprint"))
	if Input.is_action_just_pressed(&"jump"):
		_survivor.parkour.try_jump()

	for i in 4:
		if Input.is_action_just_pressed(StringName("weapon_%d" % (i + 1))):
			_weapons.select_slot(i)

	# Aim point: mouse cursor projected onto the player's ground plane.
	var aim_point := _survivor.global_position + Vector3(
			_survivor.facing.x, 0, _survivor.facing.z) * 8.0
	if _camera_rig != null and is_instance_valid(_camera_rig) \
			and _camera_rig.has_method(&"ground_point_under_mouse"):
		aim_point = _camera_rig.call(&"ground_point_under_mouse",
				_survivor.global_position.y)
	_weapons.tick(delta, aim_point)
	if _weapons.current_is_melee() and Input.is_action_just_pressed(&"attack"):
		_survivor.try_attack()

	if Input.is_action_just_pressed(&"eat"):
		_try_eat()
	if Input.is_action_just_pressed(&"use_medical"):
		_try_medical()

	_update_hover()
	if Input.is_action_just_pressed(&"interact"):
		_try_interact()


# --- Self-care --------------------------------------------------------------

func _try_eat() -> void:
	var eaten := _survivor.eat_food()
	if _hud != null and eaten == "":
		_hud.call("flash_notice", "No food in inventory.")


func _try_medical() -> void:
	var used := _survivor.use_medical_item()
	if _hud != null:
		_hud.call("flash_notice", "Used %s." % used if used != "" else "No medical items.")


# --- Interaction ------------------------------------------------------------

func _update_hover() -> void:
	var best: Node3D = null
	var best_d := INTERACT_RANGE * INTERACT_RANGE
	for body in get_tree().get_nodes_in_group(&"interactables"):
		var candidate := body as Node3D
		if candidate == null or candidate == _survivor:
			continue
		var comp: InteractableComponent = candidate.get("interactable") \
				if "interactable" in candidate else null
		if comp == null or not comp.enabled:
			continue
		var d := _survivor.global_position.distance_squared_to(candidate.global_position)
		if d < best_d:
			best_d = d
			best = candidate
	_hovered = best
	if best != null:
		var comp: InteractableComponent = best.get("interactable")
		_set_prompt("[E] %s" % comp.prompt)
	else:
		_set_prompt("")


func _try_interact() -> void:
	if _hovered == null or not is_instance_valid(_hovered):
		return
	var comp: InteractableComponent = _hovered.get("interactable")
	if comp != null:
		comp.try_interact(_survivor)


func _set_prompt(text: String) -> void:
	if _hud != null:
		_hud.call("set_interact_prompt", text)


## Called by main.gd when this survivor dies; shows death notice on HUD.
func on_player_died() -> void:
	input_enabled = false
	if _hud != null:
		_hud.call("show_death_screen")
