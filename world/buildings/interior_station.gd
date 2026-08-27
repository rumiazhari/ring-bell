class_name InteriorStation
extends Node3D

var station_id: String = ""
var room_id: String = ""
var station_kind: StringName = &""
var consumed: bool = false
var manifest: Dictionary = {}

var interactable: InteractableComponent

func setup(data: Dictionary) -> void:
	manifest = data
	station_id = str(data.get("id", ""))
	room_id = str(data.get("room_id", ""))
	station_kind = StringName(str(data.get("kind", "")))
	position = data.get("position", Vector3.ZERO)
	rotation.y = float(data.get("yaw", 0.0))
	var flag := StringName("interior_looted:%s" % station_id)
	if WorldState.has_flag(flag):
		consumed = true

func _ready() -> void:
	# Ensure position from manifest if not yet set
	if manifest.has("position") and position == Vector3.ZERO:
		position = manifest["position"]
	add_to_group(&"interactables")
	interactable = InteractableComponent.new()
	if station_kind == &"bed":
		interactable.prompt = "Rest" if not consumed else "Already rested"
	else:
		interactable.prompt = "Search" if not consumed else "Already searched"
	interactable.interacted.connect(_on_interacted)
	add_child(interactable)
	# Visual marker: small box
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	if station_kind == &"bed":
		box.size = Vector3(1.8, 0.4, 0.9)
	else:
		box.size = Vector3(0.9, 0.9, 0.6)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("6b8ca3") if station_kind == &"bed" else Color("8a6b4a")
	mi.material_override = mat
	mi.position = Vector3(0, 0.3, 0)
	add_child(mi)
	# Collision so ray checks can find it but not block?
	var body := StaticBody3D.new()
	body.collision_layer = 0
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var bshape := BoxShape3D.new()
	bshape.size = box.size
	shape.shape = bshape
	shape.position = Vector3(0, 0.3, 0)
	body.add_child(shape)
	add_child(body)
	_update_prompt()

func _update_prompt() -> void:
	if interactable == null:
		return
	if consumed:
		interactable.prompt = "Already used"
		interactable.enabled = false
	else:
		if station_kind == &"bed":
			interactable.prompt = "Rest"
		else:
			interactable.prompt = "Search"
		interactable.enabled = true

func interact(player: Node3D) -> void:
	_on_interacted(player)

func _on_interacted(player: Node3D) -> void:
	if consumed:
		return
	var flag := StringName("interior_looted:%s" % station_id)
	if WorldState.has_flag(flag):
		consumed = true
		_update_prompt()
		return
	if station_kind == &"bed":
		if player != null and player.get("needs") != null:
			var needs = player.get("needs")
			if needs != null:
				needs.fatigue = maxf(0.0, float(needs.fatigue) - 35.0)
		consumed = true
		WorldState.set_flag(flag, true)
		_update_prompt()
		_show_notice("Rested: fatigue reduced")
		EventBus.flag_set.emit(flag, true)
	elif station_kind == &"counter":
		var loot: StringName = manifest.get("loot", &"canned_food")
		if String(loot) == "":
			loot = &"canned_food"
		var allowed := [&"canned_food", &"water_bottle", &"bandage"]
		if not allowed.has(loot):
			loot = &"canned_food"
		if player != null and player.get("inventory") != null:
			var inv = player.get("inventory")
			if inv != null and inv.has_method("add_item"):
				inv.add_item(loot, 1)
			elif inv != null:
				# fallback dict
				pass
		consumed = true
		WorldState.set_flag(flag, true)
		_update_prompt()
		_show_notice("Found %s" % String(loot))
		EventBus.flag_set.emit(flag, true)
	else:
		consumed = true
		WorldState.set_flag(flag, true)
		_update_prompt()

func _show_notice(text: String) -> void:
	var hud_nodes := get_tree().get_nodes_in_group(&"hud")
	for h in hud_nodes:
		if h.has_method("show_banner"):
			h.show_banner(text)
			return
		if h.has_method("show_notice"):
			h.show_notice(text)
			return
	# fallback: print
	print("[InteriorStation] %s" % text)

func save_state() -> Dictionary:
	return {"id": station_id, "consumed": consumed}

func load_state(data: Dictionary) -> void:
	consumed = bool(data.get("consumed", false))
	_update_prompt()
