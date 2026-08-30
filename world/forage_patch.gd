class_name ForagePatch
extends Area3D
## Wild forage patch: bush/mushroom/herb proxy, renewable food/medical.
## Prompt "Forage bushes (Item x1)" -> "Picked clean — regrows in 2 days"
## Regrows after 2 game days. Monitorable only when ACTIVE.

var patch_id: String = ""
var depleted: bool = false
var depleted_at_day: int = -1
var contents: Dictionary = {} # StringName -> int (single item 1)
var forage_kind: StringName = &"bush_berry"
var interactable: InteractableComponent

func _ready() -> void:
	# Area3D defaults: monitorable true
	monitoring = false
	monitorable = true
	if patch_id == "":
		patch_id = name
	if contents.is_empty():
		contents = {&"canned_food": 1}
	if interactable == null:
		interactable = InteractableComponent.new()
		interactable.interacted.connect(_on_interacted)
		add_child(interactable)
	add_to_group(&"interactables")
	var shape_node := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.6
	cyl.height = 0.8
	shape_node.shape = cyl
	shape_node.position = Vector3(0, 0.4, 0)
	add_child(shape_node)
	_update_prompt()

func setup(data: Dictionary) -> void:
	patch_id = String(data.get("id", name))
	if data.has("pos"):
		var p: Vector2 = data["pos"] as Vector2
		position = Vector3(p.x, float(data.get("position", Vector3.ZERO).y) if data.has("position") else 0, p.y)
	forage_kind = StringName(str(data.get("kind", forage_kind)))
	if data.has("contents"):
		var c: Dictionary = data["contents"] as Dictionary
		contents.clear()
		for k in c.keys():
			contents[StringName(str(k))] = int(c[k])
	if data.has("depleted"):
		depleted = bool(data["depleted"])
		depleted_at_day = int(data.get("depleted_at_day", -1))
	_update_prompt()

func _try_regrow() -> void:
	if not depleted:
		return
	if depleted_at_day < 0:
		return
	var current_day: int = GameClock.get_day() if GameClock != null else 1
	if current_day >= depleted_at_day + 2:
		depleted = false
		depleted_at_day = -1
		_update_prompt()

func is_depleted() -> bool:
	_try_regrow()
	return depleted

func _on_interacted(player: Node3D) -> void:
	_try_regrow()
	if depleted:
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
	depleted_at_day = GameClock.get_day() if GameClock != null else 1
	monitorable = false
	_update_prompt()
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method("_record_forage"):
			mgr.call("_record_forage", coord, patch_id, save_state())
		elif mgr.has_method("record_forage_state"):
			mgr.call("record_forage_state", coord, patch_id, save_state())

func _update_prompt() -> void:
	if interactable == null:
		return
	_try_regrow()
	if depleted:
		interactable.prompt = "Picked clean — regrows in 2 days"
		interactable.enabled = false
		monitorable = false
	else:
		var label := ""
		for id in contents.keys():
			label = "%s x%d" % [ItemDB.item_name(StringName(str(id))), int(contents[id])]
			break
		if label == "":
			label = "Canned Food x1"
		interactable.prompt = "Forage bushes (%s)" % label
		interactable.enabled = true
		monitorable = true

func save_state() -> Dictionary:
	var out_contents := {}
	for k in contents.keys():
		out_contents[str(k)] = int(contents[k])
	return {"depleted": depleted, "depleted_at_day": depleted_at_day, "contents": out_contents}

func load_state(data: Dictionary) -> void:
	depleted = bool(data.get("depleted", false))
	depleted_at_day = int(data.get("depleted_at_day", -1))
	var c: Dictionary = data.get("contents", {}) as Dictionary
	if not c.is_empty():
		contents.clear()
		for k in c.keys():
			contents[StringName(str(k))] = int(c[k])
	_update_prompt()
