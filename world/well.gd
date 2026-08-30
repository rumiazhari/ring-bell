class_name Well
extends StaticBody3D
## Village well: deterministic stone ring with water plane, renewable water source.
## Interactable prompt "Draw water (Water Bottle x1)" -> "Well is dry — refills at dawn" (04:00 next day).
## Persistence via depleted + depleted_at_day; refills via GameClock.

var well_id: String = ""
var depleted: bool = false
var depleted_at_day: int = -1
var interactable: InteractableComponent

func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	if well_id == "":
		well_id = name
	# Add Interactable
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	# Add a small cylinder shape for interaction proximity (not counted toward rural_colliders budget)
	# Use a tiny collision shape so the well itself has a body but we keep it disabled when warm via layer 0
	var shape_node := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = WorldConstants.RURAL_WELL_RADIUS
	cyl.height = WorldConstants.RURAL_WELL_HEIGHT
	shape_node.shape = cyl
	shape_node.position = Vector3(0, WorldConstants.RURAL_WELL_HEIGHT * 0.5, 0)
	add_child(shape_node)
	_update_prompt()

func setup(data: Dictionary) -> void:
	well_id = String(data.get("id", name))
	if data.has("pos"):
		var p: Vector2 = data["pos"] as Vector2
		position = Vector3(p.x, float(data.get("position", Vector3.ZERO).y) if data.has("position") else 0, p.y)
		well_id = String(data.get("id", well_id))
	if data.has("depleted"):
		depleted = bool(data["depleted"])
		depleted_at_day = int(data.get("depleted_at_day", -1))
	_update_prompt()

func _try_refill() -> void:
	if not depleted:
		return
	if depleted_at_day < 0:
		return
	# Check GameClock for next day 04:00
	var current_day: int = GameClock.get_day() if Engine.has_singleton("GameClock") or GameClock != null else 1
	var total_min: float = GameClock.total_minutes if GameClock != null else 0.0
	# Refill time is depleted_at_day * 1440 + 240 (04:00 next day)
	var refill_minutes: float = float(depleted_at_day * 1440 + 240)
	# depleted_at_day is day number (1-based), so refill at next day 04:00 = depleted_at_day *1440 +240
	if total_min >= refill_minutes:
		depleted = false
		depleted_at_day = -1
		_update_prompt()

func is_depleted() -> bool:
	_try_refill()
	return depleted

func _on_interacted(player: Node3D) -> void:
	_try_refill()
	if depleted:
		_update_prompt()
		return
	# Give water bottle
	if player != null and player.get("inventory") != null:
		var inv = player.get("inventory")
		if inv != null and inv.has_method("add"):
			inv.add(&"water_bottle", 1)
		elif inv != null and inv.has_method("add_item"):
			inv.add_item(&"water_bottle", 1)
	depleted = true
	depleted_at_day = GameClock.get_day() if GameClock != null else 1
	_update_prompt()
	# Record to ChunkManager
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_well"):
			mgr.call("_record_well", coord, well_id, save_state())
		elif mgr.has_method("record_well_state"):
			mgr.call("record_well_state", coord, well_id, save_state())

func _update_prompt() -> void:
	if interactable == null:
		return
	_try_refill()
	if depleted:
		interactable.prompt = "Well is dry — refills at dawn"
		interactable.enabled = false
	else:
		interactable.prompt = "Draw water (Water Bottle x1)"
		interactable.enabled = true

func save_state() -> Dictionary:
	return {"depleted": depleted, "depleted_at_day": depleted_at_day}

func load_state(data: Dictionary) -> void:
	depleted = bool(data.get("depleted", false))
	depleted_at_day = int(data.get("depleted_at_day", -1))
	_update_prompt()
