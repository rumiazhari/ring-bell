class_name Stove
extends Area3D
## Rural hearth stove: deterministic cooking interactable reusing furniture anchor.
## Prompt "Cook meal (Canned Food x1)" -> consumes 1 canned_food and calls NeedsComponent.eat(40).
## When inventory lacks canned_food, prompt is "Stove — needs Canned Food" and interact fails.
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, no collider counted toward rural_colliders.

var stove_id: String = ""
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if stove_id == "":
		stove_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.6
	cyl.height = 0.9
	shape_node.shape = cyl
	shape_node.position = Vector3(0, 0.45, 0)
	add_child(shape_node)
	_update_prompt(null)

func setup(data: Dictionary) -> void:
	stove_id = String(data.get("id", name))
	if data.has("pos"):
		var p: Vector2 = data["pos"] as Vector2
		position = Vector3(p.x, float(data.get("position", Vector3.ZERO).y) if data.has("position") else 0, p.y)
	if data.has("yaw"):
		rotation.y = float(data["yaw"])
	_update_prompt(null)

func _has_canned_food(player: Node3D) -> bool:
	if player == null:
		return false
	var inv = player.get("inventory")
	if inv != null and inv.has_method("count"):
		return int(inv.count(&"canned_food")) >= 1
	if inv != null and inv.has_method("has"):
		return bool(inv.has(&"canned_food"))
	return false

func _update_prompt(player: Node3D) -> void:
	if interactable == null:
		return
	# Called with player context when available; fallback to generic prompt
	if player != null:
		if _has_canned_food(player):
			interactable.prompt = "Cook meal (Canned Food x1)"
			interactable.enabled = true
			monitorable = true
		else:
			interactable.prompt = "Stove — needs Canned Food"
			interactable.enabled = false
			monitorable = true
	else:
		# Headless generic: show Cook meal, enabled true (will check on interact)
		interactable.prompt = "Cook meal (Canned Food x1)"
		interactable.enabled = true
		monitorable = true

func _on_interacted(player: Node3D) -> void:
	if player == null:
		return
	var inv = player.get("inventory")
	var needs = player.get("needs")
	if inv == null:
		_update_prompt(player)
		return
	var has: bool = false
	if inv.has_method("count"):
		has = int(inv.count(&"canned_food")) >= 1
	if not has:
		_update_prompt(player)
		return
	# Consume 1 canned_food
	if inv.has_method("remove"):
		inv.remove(&"canned_food", 1)
	elif inv.has_method("take_from"):
		pass
	# Reduce hunger via NeedsComponent
	if needs != null and needs.has_method("eat"):
		needs.eat(WorldConstants.STOVE_HUNGER_REDUCTION)
	elif needs != null and "hunger" in needs:
		needs.hunger = clampf(float(needs.hunger) - WorldConstants.STOVE_HUNGER_REDUCTION, 0.0, 100.0)
	_update_prompt(player)
	# No persistence needed (hearth stateless)

func is_interactable_enabled() -> bool:
	return interactable != null and interactable.enabled

# For ChunkManager ACTIVE-only gate
func set_active_enabled(enabled: bool) -> void:
	monitorable = enabled
	if interactable != null:
		# When re-enabling, show generic prompt; player-specific prompt will be refreshed on next scan
		if enabled:
			_update_prompt(null)
		else:
			interactable.enabled = false
			monitorable = false
