class_name GranaryChest
extends Area3D
## Village barn granary chest: deterministic provisioning cache reusing barn furniture anchor.
## Prompts:
##   Store grain (Wheat Grain x1 -> Chest 3/8) when player has KIND_FOOD and chest not full
##   Take bread (Bread x1 <- Chest 2/8) when chest has items (priority Take)
##   Granary — empty / Granary — full (8/8) when lacking
## Persistent via deltas.granaries : {chest_id: {items:{item:count}}} re-applied before materialize.
## ACTIVE-only via ChunkManager: monitorable/enabled toggled, collision_layer 0 always.
## Box 1.2x0.6x0.8 at terrain+0.04, vertex-colored 6b4a3a in RuralMesh, Area3D only no collider counted.

var granary_id: String = ""
var building_id: String = ""
var settlement_id: String = ""
var chest_items: Dictionary = {} # StringName -> int
var interactable: InteractableComponent

const CAPACITY := 8
const PRIORITY: Array[StringName] = [&"bread", &"cider", &"apple", &"plum", &"pear", &"cherry", &"flour", &"wheat_grain", &"barley_grain", &"canned_food", &"water_bottle", &"bandage", &"antibiotics"]

func _ready() -> void:
	monitoring = false
	monitorable = true
	collision_layer = 0
	collision_mask = 0
	if granary_id == "":
		granary_id = name
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = WorldConstants.RURAL_GRANARY_SIZE
	shape_node.shape = box
	shape_node.position = Vector3(0, WorldConstants.RURAL_GRANARY_SIZE.y * 0.5, 0)
	add_child(shape_node)
	_update_prompt(null)

func setup(data: Dictionary) -> void:
	granary_id = String(data.get("id", data.get("granary_id", name)))
	building_id = String(data.get("building_id", ""))
	settlement_id = String(data.get("settlement_id", ""))
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
	if data.has("items"):
		var it: Dictionary = data["items"] as Dictionary
		chest_items.clear()
		for k in it.keys():
			chest_items[StringName(str(k))] = int(it[k])
	elif data.has("chest_items"):
		var it2: Dictionary = data["chest_items"] as Dictionary
		chest_items.clear()
		for k in it2.keys():
			chest_items[StringName(str(k))] = int(it2[k])
	if data.has("capacity"):
		pass
	_update_prompt(null)

func _total_count() -> int:
	var n := 0
	for k in chest_items.keys():
		n += int(chest_items[k])
	return n

func is_empty() -> bool:
	return _total_count() == 0

func is_full() -> bool:
	return _total_count() >= CAPACITY

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

func _has_food(inv) -> bool:
	if inv == null:
		return false
	if inv.has_method("items") or "items" in inv:
		var items = inv.get("items") if inv.get("items") != null else {}
		if inv.items is Dictionary:
			for id in inv.items.keys():
				var def := ItemDB.get_def(StringName(str(id)))
				if def.get("kind", &"") == ItemDB.KIND_FOOD and int(inv.items[id]) > 0:
					return true
			return false
	if inv.has_method("find_item_of_kind"):
		var found: StringName = inv.find_item_of_kind(ItemDB.KIND_FOOD)
		return found != &""
	if inv.get("items") != null and inv.get("items") is Dictionary:
		for id in (inv.get("items") as Dictionary).keys():
			var def := ItemDB.get_def(StringName(str(id)))
			if def.get("kind", &"") == ItemDB.KIND_FOOD and int((inv.get("items") as Dictionary)[id]) > 0:
				return true
	return false

func _best_chest_item() -> StringName:
	if chest_items.is_empty():
		return &""
	for pid in PRIORITY:
		if chest_items.has(pid) and int(chest_items[pid]) > 0:
			return pid
	for k in chest_items.keys():
		if int(chest_items[k]) > 0:
			return StringName(str(k))
	return &""

func _best_player_item(inv) -> StringName:
	if inv == null:
		return &""
	for pid in PRIORITY:
		if _inv_count(inv, pid) > 0:
			var def := ItemDB.get_def(pid)
			if def.get("kind", &"") == ItemDB.KIND_FOOD:
				return pid
	if inv.has_method("items") or "items" in inv:
		var dict = null
		if inv.get("items") != null:
			dict = inv.get("items")
		elif inv.items is Dictionary:
			dict = inv.items
		if dict is Dictionary:
			for id in (dict as Dictionary).keys():
				var sid := StringName(str(id))
				var def := ItemDB.get_def(sid)
				if def.get("kind", &"") == ItemDB.KIND_FOOD and int((dict as Dictionary)[id]) > 0:
					return sid
	if inv.has_method("find_item_of_kind"):
		var f: StringName = inv.find_item_of_kind(ItemDB.KIND_FOOD)
		if f != &"" and _inv_count(inv, f) > 0:
			return f
	return &""

func _update_prompt(player: Variant) -> void:
	if interactable == null:
		return
	var total: int = _total_count()
	var has_chest: bool = total > 0
	var is_full_flag: bool = total >= CAPACITY
	if player != null:
		var inv = player.get("inventory") if player.has_method("get") or "inventory" in player else null
		if inv == null:
			inv = player.get("inventory")
		if inv == null:
			interactable.prompt = "Granary — empty" if total == 0 else "Granary — %d/8" % total
			interactable.enabled = false
			monitorable = true
			return
		var best_chest: StringName = _best_chest_item()
		if has_chest and best_chest != &"":
			interactable.prompt = "Take %s (%s x1 <- Chest %d/8)" % [ItemDB.item_name(best_chest), ItemDB.item_name(best_chest), total]
			interactable.enabled = true
			monitorable = true
			return
		var best_player: StringName = _best_player_item(inv)
		if best_player != &"" and not is_full_flag:
			interactable.prompt = "Store %s (%s x1 -> Chest %d/8)" % [ItemDB.item_name(best_player), ItemDB.item_name(best_player), total]
			interactable.enabled = true
			monitorable = true
			return
		if is_full_flag:
			interactable.prompt = "Granary — full (8/8)"
			interactable.enabled = false
			monitorable = true
			return
		else:
			interactable.prompt = "Granary — empty"
			interactable.enabled = false
			monitorable = true
			return
	else:
		if has_chest:
			var bc: StringName = _best_chest_item()
			if bc == &"":
				bc = &"bread"
			interactable.prompt = "Take %s (%s x1 <- Chest %d/8)" % [ItemDB.item_name(bc), ItemDB.item_name(bc), total]
			interactable.enabled = true
			monitorable = true
			return
		if is_full_flag:
			interactable.prompt = "Granary — full (8/8)"
			interactable.enabled = false
			monitorable = true
			return
		interactable.prompt = "Store grain (Wheat Grain x1 -> Chest %d/8)" % total
		interactable.enabled = true
		monitorable = true

func _on_interacted(player: Node3D) -> void:
	if player == null:
		return
	var inv = player.get("inventory")
	if inv == null:
		_update_prompt(player)
		return
	var total: int = _total_count()
	var has_chest: bool = total > 0
	var is_full_flag: bool = total >= CAPACITY
	var best_chest: StringName = _best_chest_item()
	if has_chest and best_chest != &"":
		var cnt: int = int(chest_items.get(best_chest, 0))
		if cnt > 0:
			chest_items[best_chest] = cnt - 1
			if int(chest_items[best_chest]) <= 0:
				chest_items.erase(best_chest)
			if inv.has_method("add"):
				inv.add(best_chest, 1)
			elif inv.has_method("add_item"):
				inv.add_item(best_chest, 1)
			_update_prompt(player)
			_record_state()
			return
	if not is_full_flag:
		var best_player: StringName = _best_player_item(inv)
		if best_player != &"" and _inv_count(inv, best_player) > 0:
			var taken: int = 0
			if inv.has_method("remove"):
				taken = int(inv.remove(best_player, 1))
			elif inv.has_method("take"):
				taken = int(inv.call("remove", best_player, 1))
			if taken > 0:
				chest_items[best_player] = int(chest_items.get(best_player, 0)) + 1
				_update_prompt(player)
				_record_state()
				return
	_update_prompt(player)

func _record_state() -> void:
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_granary"):
			mgr.call("_record_granary", coord, granary_id, save_state())
		elif mgr.has_method("record_granary_state"):
			mgr.call("record_granary_state", coord, granary_id, save_state())

func save_state() -> Dictionary:
	var out_items := {}
	for k in chest_items.keys():
		out_items[str(k)] = int(chest_items[k])
	return {"items": out_items}

func load_state(data: Dictionary) -> void:
	chest_items.clear()
	var src: Dictionary = data.get("items", data.get("chest_items", {})) as Dictionary
	for k in src.keys():
		chest_items[StringName(str(k))] = int(src[k])
	_update_prompt(null)

func set_active_enabled(enabled: bool) -> void:
	monitorable = enabled
	if interactable != null:
		if enabled:
			_update_prompt(null)
		else:
			interactable.enabled = false
			monitorable = false
