class_name CropPatch
extends Area3D
## Field crop patch: tilled parcel harvest, renewable crop rows.
## Prompt "Harvest wheat (Wheat x1)" when grown else "Growing — ready in N days"
## After harvest: "Picked clean — regrows in 2 days" and regrows after 2 days via GameClock.
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, no collider counted.

var crop_id: String = ""
var parcel_id: String = ""
var crop_kind: StringName = &"wheat"
var planted_day: int = 0
var depleted: bool = false
var depleted_at_day: int = -1
var contents: Dictionary = {}
var interactable: InteractableComponent

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if crop_id == "":
		crop_id = name
	if contents.is_empty():
		contents = _default_contents()
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 0.8, 1.2)
	shape_node.shape = box
	shape_node.position = Vector3(0, 0.4, 0)
	add_child(shape_node)
	_update_prompt()

func _default_contents() -> Dictionary:
	match crop_kind:
		&"wheat":
			return {&"wheat_grain": 1}
		&"barley":
			return {&"barley_grain": 1}
		&"potato":
			return {&"bandage": 1}
		&"beet":
			return {&"antibiotics": 1}
		_:
			return {&"wheat_grain": 1}

func setup(data: Dictionary) -> void:
	crop_id = String(data.get("id", data.get("parcel_id", name)))
	parcel_id = String(data.get("parcel_id", crop_id))
	if data.has("crop_kind"):
		crop_kind = StringName(str(data["crop_kind"]))
	elif data.has("kind"):
		crop_kind = StringName(str(data["kind"]))
	if data.has("planted_day"):
		planted_day = int(data["planted_day"])
	elif data.has("planted"):
		planted_day = int(data["planted"])
	if data.has("pos"):
		var p: Vector2 = data["pos"] as Vector2
		position = Vector3(p.x, float(data.get("position", Vector3.ZERO).y) if data.has("position") else position.y, p.y)
	elif data.has("position"):
		var pos3: Vector3 = data["position"] as Vector3
		position = pos3
	if data.has("yaw"):
		rotation.y = float(data["yaw"])
	if data.has("contents"):
		var c: Dictionary = data["contents"] as Dictionary
		contents.clear()
		for k in c.keys():
			contents[StringName(str(k))] = int(c[k])
	else:
		contents = _default_contents()
	if data.has("depleted"):
		depleted = bool(data["depleted"])
		depleted_at_day = int(data.get("depleted_at_day", -1))
		if data.has("is_grown"):
			pass
	_update_prompt()

func _cur_day() -> int:
	if GameClock != null and GameClock.has_method("get_day"):
		return GameClock.get_day()
	return 1

func _is_grown() -> bool:
	return _cur_day() >= planted_day + WorldConstants.CROP_GROW_DAYS

func _try_regrow() -> void:
	if not depleted:
		return
	if depleted_at_day < 0:
		return
	if _cur_day() >= depleted_at_day + WorldConstants.CROP_REGROW_DAYS:
		depleted = false
		depleted_at_day = -1
		_update_prompt()

func is_depleted() -> bool:
	_try_regrow()
	return depleted

func is_grown() -> bool:
	_try_regrow()
	return _is_grown()

func _on_interacted(player: Node3D) -> void:
	_try_regrow()
	if depleted:
		_update_prompt()
		return
	if not _is_grown():
		_update_prompt()
		return
	var item_id: StringName = &"canned_food"
	var count: int = 1
	for k in contents.keys():
		item_id = StringName(str(k))
		count = int(contents[k])
		break
	if player != null and player.get("inventory") != null:
		var inv = player.get("inventory")
		if inv != null and inv.has_method("add"):
			inv.add(item_id, count)
		elif inv != null and inv.has_method("add_item"):
			inv.add_item(item_id, count)
	depleted = true
	depleted_at_day = _cur_day()
	_update_prompt()
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_field_crop"):
			mgr.call("_record_field_crop", coord, crop_id, save_state())
		elif mgr.has_method("record_field_crop_state"):
			mgr.call("record_field_crop_state", coord, crop_id, save_state())

func _update_prompt() -> void:
	if interactable == null:
		return
	_try_regrow()
	if depleted:
		interactable.prompt = "Picked clean \u2014 regrows in 2 days"
		interactable.enabled = false
		monitorable = false
		return
	if not _is_grown():
		var days_left: int = (planted_day + WorldConstants.CROP_GROW_DAYS) - _cur_day()
		if days_left < 0:
			days_left = 0
		interactable.prompt = "Growing \u2014 ready in %d days" % days_left
		interactable.enabled = false
		monitorable = false
		return
	var label := ""
	for id in contents.keys():
		label = "%s x%d" % [ItemDB.item_name(StringName(str(id))), int(contents[id])]
		break
	if label == "":
		label = "%s x1" % ItemDB.item_name(crop_kind)
	# Use crop_kind for prompt prefix
	var crop_label := String(crop_kind).capitalize()
	if crop_kind == &"wheat":
		crop_label = "Wheat"
	elif crop_kind == &"barley":
		crop_label = "Barley"
	elif crop_kind == &"potato":
		crop_label = "Potato"
	elif crop_kind == &"beet":
		crop_label = "Beet"
	interactable.prompt = "Harvest %s (%s)" % [String(crop_kind), label]
	interactable.enabled = true
	monitorable = true

func save_state() -> Dictionary:
	var out_contents := {}
	for k in contents.keys():
		out_contents[str(k)] = int(contents[k])
	return {"depleted": depleted, "depleted_at_day": depleted_at_day, "contents": out_contents, "planted_day": planted_day, "crop_kind": String(crop_kind)}

func load_state(data: Dictionary) -> void:
	depleted = bool(data.get("depleted", false))
	depleted_at_day = int(data.get("depleted_at_day", -1))
	if data.has("planted_day"):
		planted_day = int(data["planted_day"])
	if data.has("crop_kind"):
		crop_kind = StringName(str(data["crop_kind"]))
	var c: Dictionary = data.get("contents", {}) as Dictionary
	if not c.is_empty():
		contents.clear()
		for k in c.keys():
			contents[StringName(str(k))] = int(c[k])
	_update_prompt()

func set_active_enabled(enabled: bool) -> void:
	_try_regrow()
	var grown: bool = _is_grown()
	var dep: bool = depleted
	if not enabled:
		monitorable = false
		if interactable != null:
			interactable.enabled = false
	else:
		var should_enable: bool = grown and not dep
		monitorable = should_enable
		if interactable != null:
			interactable.enabled = should_enable
		_update_prompt()
		# After update, ensure monitorable matches enabled logic (when grown not depleted)
		if not grown or dep:
			monitorable = false
			if interactable != null:
				interactable.enabled = false
