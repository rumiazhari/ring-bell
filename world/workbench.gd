class_name Workbench
extends Area3D
## Village barn workbench: deterministic mill/press crafting station reusing barn furniture anchor.
## Prompts:
##   Bake bread (Flour x1 -> Bread x1) when flour>=1 (priority 1)
##   Press cider (Apple x2 -> Cider x1) when apple>=2 (priority 2)
##   Mill flour (Wheat Grain x2 -> Flour x1) when wheat_grain>=2 or barley_grain>=2 (priority 3)
##   Workbench — needs Wheat Grain x2 or Apple x2 when lacking
## Consumes via InventoryComponent.remove and gives via add, stateless, ACTIVE-only monitorable.
## Box 1.2x0.9x0.6 at terrain+0.04, vertex-colored 7a6a5a in RuralMesh, Area3D only no collider counted.

var workbench_id: String = ""
var building_id: String = ""
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if workbench_id == "":
		workbench_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = WorldConstants.RURAL_WORKBENCH_SIZE
	shape_node.shape = box
	shape_node.position = Vector3(0, WorldConstants.RURAL_WORKBENCH_SIZE.y * 0.5, 0)
	add_child(shape_node)
	_update_prompt(null)

func setup(data: Dictionary) -> void:
	workbench_id = String(data.get("id", data.get("workbench_id", name)))
	building_id = String(data.get("building_id", ""))
	if data.has("pos"):
		var p: Vector2 = data["pos"] as Vector2
		if data.has("position"):
			var pos3: Vector3 = data["position"] as Vector3
			position = pos3
		elif data.has("pos3"):
			var pos3b: Vector3 = data["pos3"] as Vector3
			position = pos3b
		else:
			position = Vector3(p.x, position.y, p.y)
	elif data.has("position"):
		position = data["position"] as Vector3
	elif data.has("pos3"):
		position = data["pos3"] as Vector3
	if data.has("yaw"):
		rotation.y = float(data["yaw"])
	_update_prompt(null)

func _inv_count(inv, id: StringName) -> int:
	if inv == null:
		return 0
	if inv.has_method("count"):
		return int(inv.count(id))
	if inv.has_method("get_count"):
		return int(inv.call("get_count", id))
	if inv.has_method("has"):
		return 1 if bool(inv.call("has", id)) else 0
	return 0

func _has(inv, id: StringName, need: int) -> bool:
	return _inv_count(inv, id) >= need

func _update_prompt(player: Node3D) -> void:
	if interactable == null:
		return
	if player != null:
		var inv = player.get("inventory")
		if inv == null:
			interactable.prompt = "Workbench — needs Wheat Grain x2 or Apple x2"
			interactable.enabled = false
			monitorable = true
			return
		var has_flour: bool = _has(inv, &"flour", 1)
		var has_apple: bool = _has(inv, &"apple", 2)
		var has_wheat: bool = _has(inv, &"wheat_grain", 2)
		var has_barley: bool = _has(inv, &"barley_grain", 2)
		# Priority Bake > Cider > Mill
		if has_flour:
			interactable.prompt = "Bake bread (Flour x1 -> Bread x1)"
			interactable.enabled = true
			monitorable = true
		elif has_apple:
			interactable.prompt = "Press cider (Apple x2 -> Cider x1)"
			interactable.enabled = true
			monitorable = true
		elif has_wheat or has_barley:
			interactable.prompt = "Mill flour (Wheat Grain x2 -> Flour x1)"
			interactable.enabled = true
			monitorable = true
		else:
			interactable.prompt = "Workbench — needs Wheat Grain x2 or Apple x2"
			interactable.enabled = false
			monitorable = true
	else:
		# headless generic: show Mill flour enabled (will check on interact)
		interactable.prompt = "Mill flour (Wheat Grain x2 -> Flour x1)"
		interactable.enabled = true
		monitorable = true

func _on_interacted(player: Node3D) -> void:
	if player == null:
		return
	var inv = player.get("inventory")
	if inv == null:
		_update_prompt(player)
		return
	# Priority Bake > Cider > Mill - attempt each if has inputs
	var has_flour: bool = _has(inv, &"flour", 1)
	var has_apple: bool = _has(inv, &"apple", 2)
	var has_wheat: bool = _has(inv, &"wheat_grain", 2)
	var has_barley: bool = _has(inv, &"barley_grain", 2)
	# Also check plum as alternative? spec says apple only; keep apple
	if has_flour:
		# Bake bread Flour x1 -> Bread x1
		if inv.has_method("remove"):
			inv.remove(&"flour", 1)
		if inv.has_method("add"):
			inv.add(&"bread", 1)
		elif inv.has_method("add_item"):
			inv.add_item(&"bread", 1)
	elif has_apple:
		if inv.has_method("remove"):
			inv.remove(&"apple", 2)
		if inv.has_method("add"):
			inv.add(&"cider", 1)
		elif inv.has_method("add_item"):
			inv.add_item(&"cider", 1)
	elif has_wheat:
		if inv.has_method("remove"):
			inv.remove(&"wheat_grain", 2)
		if inv.has_method("add"):
			inv.add(&"flour", 1)
		elif inv.has_method("add_item"):
			inv.add_item(&"flour", 1)
	elif has_barley:
		if inv.has_method("remove"):
			inv.remove(&"barley_grain", 2)
		if inv.has_method("add"):
			inv.add(&"flour", 1)
		elif inv.has_method("add_item"):
			inv.add_item(&"flour", 1)
	else:
		_update_prompt(player)
		return
	_update_prompt(player)

func is_interactable_enabled() -> bool:
	return interactable != null and interactable.enabled

func set_active_enabled(enabled: bool) -> void:
	monitorable = enabled
	if interactable != null:
		if enabled:
			_update_prompt(null)
		else:
			interactable.enabled = false
			monitorable = false
