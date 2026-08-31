class_name VerticalBridge
extends Area3D
## Roof bridge between barn/stable: deterministic plank at ledge_y with Area3D prompt "Cross bridge".
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, collision_layer 0 always, no collider counted toward 54 peak.
## Persistence optional deltas.vertical_discovered or stateless (re-derive deterministically).

var bridge_id: String = ""
var building_a_id: String = ""
var building_b_id: String = ""
var settlement_id: String = ""
var span: float = 0.0
var width: float = 1.2
var discovered: bool = false
var discovered_at_day: int = -1
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if bridge_id == "":
		bridge_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Size: span x thickness(0.18) x width(1.2) ? In Godot BoxShape size is full extents.
	# We will set dynamically in setup; default uses constants.
	box.size = Vector3(WorldConstants.VERTICAL_BRIDGE_SPAN_MIN, WorldConstants.VERTICAL_BRIDGE_THICKNESS, WorldConstants.VERTICAL_BRIDGE_WIDTH)
	shape_node.shape = box
	# Shape centered at Area origin; portal node's position is at bridge mid, so shape at (0,0,0) is fine.
	# For thickness, shape is at (0, thickness*0.5)?? Actually bridge plank's top at ledge_y, thickness 0.18, so center at ledge_y - thickness*0.5? But Area's position is at mid/ledge_y, so shape at 0 is centered at mid. Keep at 0.
	shape_node.position = Vector3.ZERO
	add_child(shape_node)
	_update_prompt()

func setup(data: Dictionary) -> void:
	bridge_id = String(data.get("id", bridge_id))
	building_a_id = String(data.get("building_a_id", ""))
	building_b_id = String(data.get("building_b_id", ""))
	settlement_id = String(data.get("settlement_id", ""))
	span = float(data.get("span", span))
	width = float(data.get("width", width))
	discovered = bool(data.get("discovered", false))
	discovered_at_day = int(data.get("discovered_at_day", -1))
	# Update shape size
	for child in get_children():
		if child is CollisionShape3D:
			var b: BoxShape3D = child.shape as BoxShape3D
			if b != null:
				b.size = Vector3(span, WorldConstants.VERTICAL_BRIDGE_THICKNESS, width)
	_update_prompt()

func _update_prompt() -> void:
	if interactable == null:
		return
	interactable.prompt = "Cross bridge"
	interactable.enabled = true

func _on_interacted(player: Node3D) -> void:
	discovered = true
	var gc = get_node_or_null("/root/GameClock")
	if gc != null and gc.has_method("get_day"):
		discovered_at_day = gc.call("get_day")
	else:
		discovered_at_day = 1
	_update_prompt()
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_vertical_discovered"):
			mgr.call("_record_vertical_discovered", coord, bridge_id, save_state())
		elif mgr.has_method("record_vertical_state"):
			mgr.call("record_vertical_state", coord, bridge_id, save_state())

func save_state() -> Dictionary:
	return {"discovered": discovered, "discovered_at_day": discovered_at_day}

func load_state(data: Dictionary) -> void:
	discovered = bool(data.get("discovered", false))
	discovered_at_day = int(data.get("discovered_at_day", -1))
	_update_prompt()

func set_active_enabled(enabled: bool) -> void:
	monitorable = enabled
	if interactable != null:
		interactable.enabled = enabled
	monitoring = false
