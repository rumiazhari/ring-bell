class_name Survivor
extends CharacterBody3D
## Shared body for every human actor (player-controlled or autonomous).
##
## Owns: movement execution, stamina, melee attack execution, survival ticks
## (needs + health coordination), death handling and corpse conversion.
## Decision making lives in NPCBrain (autonomous) or PlayerController (player).
## Structured data lives in child components created in _ready().
##
## SPAWN CONTRACT: call configure() BEFORE add_child(); _ready() builds
## everything from that config. See world/population.gd for the data shape.

signal died(survivor: Survivor)

# Physics layers (see project.godot layer names).
const LAYER_ENVIRONMENT := 1
const LAYER_SURVIVORS := 2
const LAYER_ZOMBIES := 4

const WALK_SPEED := 3.6
const RUN_SPEED := 6.4
const ACCELERATION := 12.0

const STAMINA_MAX := 100.0
const STAMINA_SPRINT_DRAIN := 14.0     # per second while sprinting
const STAMINA_REGEN_IDLE := 15.0       # per second standing still
const STAMINA_REGEN_MOVE := 8.0        # per second walking
const STAMINA_ATTACK_COST := 10.0
const EXHAUSTED_RECOVER_AT := 25.0     # stamina needed to clear exhaustion

var identity: IdentityComponent
var health: HealthComponent
var needs: NeedsComponent
var inventory: InventoryComponent
var interactable: InteractableComponent

var equipped_weapon_id: StringName = &""
var stamina := STAMINA_MAX
var exhausted := false                 # latched until stamina recovers

# Set by the owner-side controller each frame; world-space direction.
var facing := Vector3(0, 0, -1)

var _config := {}                      # spawn config, applied in _ready()
var _move_dir := Vector3.ZERO          # world-space desired direction
var _wants_sprint := false
var _attack_cooldown := 0.0
var _visual_root: Node3D
var _body_mesh: MeshInstance3D


## Store spawn configuration; consumed in _ready(). Keys:
##   id: StringName, name: String, occupation: String,
##   color: Color, weapon: StringName, items: Dictionary, is_player: bool
func configure(cfg: Dictionary) -> void:
	_config = cfg


func is_player() -> bool:
	return bool(_config.get("is_player", false))


func _ready() -> void:
	_setup_components_from_config()
	_setup_body()

	collision_layer = LAYER_SURVIVORS
	# NOTE: survivors do not collide with each other on purpose - it prevents
	# crowding jams around doors/crates. Zombies DO collide with survivors.
	collision_mask = LAYER_ENVIRONMENT | LAYER_ZOMBIES

	add_to_group(&"survivors")
	if identity.persistent_id != &"":
		add_to_group(&"interactables")
		interactable = InteractableComponent.new()
		interactable.prompt = "Talk to %s" % identity.display_name
		add_child(interactable)
		ActorRegistry.register(self, identity.persistent_id)
	health.died.connect(_on_health_died)


func _setup_components_from_config() -> void:
	identity = IdentityComponent.new()
	identity.persistent_id = _config.get("id", &"")
	identity.display_name = _config.get("name", "Survivor")
	identity.occupation = _config.get("occupation", "")
	identity.faction_id = _config.get("faction", &"survivors")
	add_child(identity)

	health = HealthComponent.new()
	add_child(health)

	needs = NeedsComponent.new()
	add_child(needs)

	inventory = InventoryComponent.new()
	var items: Dictionary = _config.get("items", {})
	for item_id in items:
		inventory.add(StringName(item_id), int(items[item_id]))
	add_child(inventory)

	equipped_weapon_id = _config.get("weapon", &"")


func _setup_body() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0, 0.85, 0)
	add_child(shape)

	_visual_root = Node3D.new()
	_visual_root.name = "Visual"
	add_child(_visual_root)

	_body_mesh = MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.7
	_body_mesh.mesh = mesh
	_body_mesh.position = Vector3(0, 0.85, 0)
	set_body_color(_config.get("color", Color(0.6, 0.65, 0.7)))
	_visual_root.add_child(_body_mesh)

	# Facing indicator so movement direction reads at a glance.
	var nose := MeshInstance3D.new()
	var nose_mesh := BoxMesh.new()
	nose_mesh.size = Vector3(0.12, 0.12, 0.28)
	nose.mesh = nose_mesh
	nose.position = Vector3(0, 1.35, 0.42)  # local +Z = forward (see facing logic)
	nose.material_override = _make_material(Color(0.95, 0.92, 0.85))
	_visual_root.add_child(nose)


func set_body_color(color: Color) -> void:
	if _body_mesh == null:
		return
	_body_mesh.material_override = _make_material(color)


static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


# --- Movement ---------------------------------------------------------------

## Requested by PlayerController or NPCBrain every frame. World-space dir.
func request_move(dir: Vector3, sprint: bool) -> void:
	_move_dir = dir.limit_length(1.0)
	_wants_sprint = sprint


func stop_moving() -> void:
	_move_dir = Vector3.ZERO
	_wants_sprint = false


func _physics_process(delta: float) -> void:
	if health.is_dead:
		return

	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)

	var moving := _move_dir.length_squared() > 0.01 and not needs.sleeping
	var sprinting := moving and _wants_sprint and not exhausted

	if sprinting:
		stamina -= STAMINA_SPRINT_DRAIN * delta
		if stamina <= 1.0:
			stamina = 1.0
			exhausted = true
	else:
		var regen := STAMINA_REGEN_IDLE if not moving else STAMINA_REGEN_MOVE
		stamina = minf(stamina + regen * delta, STAMINA_MAX)
	if exhausted and stamina >= EXHAUSTED_RECOVER_AT:
		exhausted = false

	needs.exerting = sprinting

	var target_speed := RUN_SPEED if sprinting else WALK_SPEED
	target_speed *= needs.speed_multiplier()
	var target_velocity := _move_dir * target_speed if moving else Vector3.ZERO
	var blend := 1.0 - exp(-ACCELERATION * delta)
	velocity.x = lerpf(velocity.x, target_velocity.x, blend)
	velocity.z = lerpf(velocity.z, target_velocity.z, blend)
	move_and_slide()

	if moving:
		facing = _move_dir.normalized()
	_visual_root.rotation.y = atan2(facing.x, facing.z)

	tick_survival(delta)


## Coordinates the two simulation tickers that need each other's context.
func tick_survival(delta: float) -> void:
	needs.tick(delta)
	health.tick(delta, needs.hunger < 55.0 and needs.thirst < 60.0)
	var deprivation := needs.deprivation_damage(delta)
	if deprivation > 0.0:
		health.damage(deprivation, &"deprivation")


# --- Combat -----------------------------------------------------------------

## Attempt one melee swing. Returns true if a swing was performed.
func try_attack() -> bool:
	if health.is_dead or needs.sleeping or _attack_cooldown > 0.0:
		return false
	if stamina < STAMINA_ATTACK_COST:
		return false
	var weapon := ItemDB.get_weapon_def(equipped_weapon_id)
	stamina -= STAMINA_ATTACK_COST
	_attack_cooldown = float(weapon.get("cooldown", 0.8))

	for target in query_melee_targets(float(weapon.get("reach", 1.5))):
		target.take_damage(float(weapon.get("damage", 10.0)), identity.persistent_id)
	EventBus.attack_performed.emit(global_position)
	return true


## Sphere sweep in front of the survivor; returns zombie nodes hit.
func query_melee_targets(reach: float) -> Array[Node]:
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = reach * 0.6
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, global_position + facing * reach * 0.45)
	params.collision_mask = LAYER_ZOMBIES
	params.exclude = [get_rid()]

	var targets: Array[Node] = []
	for hit in space.intersect_shape(params, 12):
		var collider: Node = hit.get("collider")
		if collider != null and collider != self and collider.has_method("take_damage") \
				and not collider.health.is_dead:
			targets.append(collider)
	return targets


func take_damage(amount: float, source_id: StringName) -> void:
	health.damage(amount, source_id)


## Zombie bite entry point (damage + infection risk).
func receive_bite(damage: float, source_id: StringName) -> void:
	health.apply_bite(damage, source_id)


# --- Item use ---------------------------------------------------------------

## Consume one food item from inventory. Returns item display name or "".
func eat_food() -> String:
	var food_id := inventory.find_item_of_kind(ItemDB.KIND_FOOD)
	if food_id == &"":
		return ""
	var def := ItemDB.get_def(food_id)
	inventory.remove(food_id, 1)
	if def.has("hunger_reduction"):
		needs.eat(def["hunger_reduction"])
	if def.has("thirst_reduction"):
		needs.drink(def["thirst_reduction"])
	return String(def.get("name", food_id))


## Use a medical item (bandage heals, antibiotics treats infection).
func use_medical_item() -> String:
	for med_id: StringName in inventory.items.keys():
		var def := ItemDB.get_def(med_id)
		if def.get("kind", &"") != ItemDB.KIND_MEDICAL:
			continue
		inventory.remove(med_id, 1)
		if def.has("heal_amount"):
			health.heal(def["heal_amount"])
		if def.has("infection_reduction"):
			health.treat_infection(def["infection_reduction"])
		return String(def.get("name", med_id))
	return ""


# --- Death ------------------------------------------------------------------

func _on_health_died(source_id: StringName) -> void:
	died.emit(self)
	EventBus.actor_died.emit(identity.persistent_id, source_id)
	ActorRegistry.unregister(identity.persistent_id)
	remove_from_group(&"survivors")
	remove_from_group(&"interactables")
	stop_moving()
	# Become a static corpse: no collision, no processing, visual change.
	collision_layer = 0
	collision_mask = 0
	set_physics_process(false)
	if interactable != null:
		interactable.enabled = false
	_body_mesh.material_override = _make_material(Color(0.45, 0.15, 0.15))
	_visual_root.rotation_degrees.x = 90.0
	_visual_root.position.y = 0.35


# --- Persistence ------------------------------------------------------------

func save_state() -> Dictionary:
	var data := {
		"id": str(identity.persistent_id),
		"name": identity.display_name,
		"occupation": identity.occupation,
		"faction": str(identity.faction_id),
		"is_player": is_player(),
		"position": [global_position.x, global_position.y, global_position.z],
		"facing_xz": [facing.x, facing.z],
		"weapon": str(equipped_weapon_id),
		"stamina": stamina,
		"color": _config.get("color", Color.WHITE).to_html(),
		"items": inventory.save_state(),
	}
	data.merge(health.save_state(), true)
	data.merge(needs.save_state(), true)
	return data


## Restores state onto an already-spawned survivor (spawn first via config).
func load_state(data: Dictionary) -> void:
	var pos: Array = data.get("position", [global_position.x, global_position.y, global_position.z])
	global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	var facing_xz: Array = data.get("facing_xz", [facing.x, facing.z])
	facing = Vector3(float(facing_xz[0]), 0.0, float(facing_xz[1]))
	equipped_weapon_id = StringName(data.get("weapon", ""))
	stamina = float(data.get("stamina", STAMINA_MAX))
	inventory.load_state(data.get("items", {}))
	health.load_state(data)
	needs.load_state(data)
