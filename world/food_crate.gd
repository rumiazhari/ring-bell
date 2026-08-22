class_name FoodCrate
extends StaticBody3D
## A world container the player can loot and hungry NPCs can take from.
##
## Lives in groups "interactables" (player scan) and "food_storage"
## (NPC brain queries). Holds one item per interaction so looting feels
## deliberate; prompt shows remaining stock.

var contents := {}  # StringName item id -> int count

var _interactable: InteractableComponent
var _mesh: MeshInstance3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0

	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.9, 1.0)
	_mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.42, 0.3)
	mat.roughness = 1.0
	_mesh.material_override = mat
	add_child(_mesh)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.0, 0.9, 1.0)
	shape.shape = box_shape
	shape.position = Vector3(0, 0.45, 0)
	add_child(shape)

	_interactable = InteractableComponent.new()
	_interactable.interacted.connect(_on_interacted)
	add_child(_interactable)

	add_to_group(&"interactables")
	add_to_group(&"food_storage")
	_update_prompt()


func _on_interacted(player: Node3D) -> void:
	_give_one_item(player)


## NPCs call this when they walk here hungry (see NPCBrain).
func npc_take_food(claimant: Node3D) -> void:
	_give_one_item(claimant)


func _give_one_item(taker: Node3D) -> void:
	for id: StringName in contents.keys():
		if int(contents[id]) > 0:
			contents[id] = int(contents[id]) - 1
			taker.inventory.add(id, 1)
			break
	_update_prompt()


func is_empty() -> bool:
	for value in contents.values():
		if int(value) > 0:
			return false
	return true


func _update_prompt() -> void:
	if is_empty():
		_interactable.prompt = "Search shelves (empty)"
		_interactable.enabled = false
		return
	var label := ""
	for id: StringName in contents.keys():
		if int(contents[id]) > 0:
			label = "%s x%d" % [ItemDB.item_name(id), contents[id]]
			break
	_interactable.prompt = "Search shelves (%s)" % label
	_interactable.enabled = true


func save_state() -> Dictionary:
	var out := {}
	for id: StringName in contents:
		out[str(id)] = contents[id]
	return out


func load_state(data: Dictionary) -> void:
	contents.clear()
	for id in data:
		contents[StringName(id)] = int(data[id])
	_update_prompt()
