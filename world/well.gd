class_name Well
extends Area3D
## Village well: deterministic stone ring with water plane, renewable water source.
## Interactable prompt "Draw water (Water Bottle x1)" -> "Well is dry — refills at dawn" (04:00 next day).
## Persistence via depleted + depleted_at_day; refills via GameClock.
## P4.5 unified collider: Well is Area3D (no second StaticBody); well cylinder is baked into RuralBody Concave (single collider per chunk).
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, collision_layer 0 always.

var well_id: String = ""
var depleted: bool = false
var depleted_at_day: int = -1
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if well_id == "":
		well_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
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
	var total_min: float = GameClock.total_minutes if GameClock != null else 0.0
	var refill_minutes: float = float(depleted_at_day * 1440 + 240)
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
	if player != null and player.get("inventory") != null:
		var inv = player.get("inventory")
		if inv != null and inv.has_method("add"):
			inv.add(&"water_bottle", 1)
		elif inv != null and inv.has_method("add_item"):
			inv.add_item(&"water_bottle", 1)
	depleted = true
	depleted_at_day = GameClock.get_day() if GameClock != null else 1
	_update_prompt()
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
		monitorable = false
	else:
		interactable.prompt = "Draw water (Water Bottle x1)"
		interactable.enabled = true
		monitorable = true

func save_state() -> Dictionary:
	return {"depleted": depleted, "depleted_at_day": depleted_at_day}

func load_state(data: Dictionary) -> void:
	depleted = bool(data.get("depleted", false))
	depleted_at_day = int(data.get("depleted_at_day", -1))
	_update_prompt()

func set_active_enabled(enabled: bool) -> void:
	# ACTIVE-only gate from ChunkManager: warm disables monitorable and interactable
	_try_refill()
	var dep: bool = depleted
	if not enabled:
		monitorable = false
		if interactable != null:
			interactable.enabled = false
	else:
		monitorable = not dep
		if interactable != null:
			interactable.enabled = not dep
