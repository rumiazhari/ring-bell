class_name CavePortal
extends Area3D
## Quarry-linked cave entrance portal: deterministic box at terrain+0.01 with Area3D prompt "Enter cave".
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, collision_layer 0 always, no collider counted toward 54 peak.
## Persistence via deltas.cave_discovered {entrance_id: true} sibling to other deltas.

var cave_id: String = ""
var discovered: bool = false
var discovered_at_day: int = -1
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if cave_id == "":
		cave_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = WorldConstants.CAVE_ENTRANCE_SIZE
	shape_node.shape = box
	shape_node.position = Vector3(0, WorldConstants.CAVE_ENTRANCE_HEIGHT * 0.5, 0)
	add_child(shape_node)
	_update_prompt()

func _update_prompt() -> void:
	if interactable == null:
		return
	# For M1 slice, prompt always "Enter cave"; discovered does not change prompt but kept for persistence proof
	interactable.prompt = "Enter cave"
	interactable.enabled = true
	# monitorable handled by ChunkManager ACTIVE gate, but keep enabled true

func _on_interacted(player: Node3D) -> void:
	discovered = true
	discovered_at_day = GameClock.get_day() if GameClock != null else 1
	_update_prompt()
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_cave_discovered"):
			mgr.call("_record_cave_discovered", coord, cave_id, save_state())
		elif mgr.has_method("record_cave_state"):
			mgr.call("record_cave_state", coord, cave_id, save_state())

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
	# keep monitoring false? For Area3D we need monitoring? For interact scan, monitorable matters.
	# Keep monitoring as false (we are Area, player scans via Interactable)
	monitoring = false
