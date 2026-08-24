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
const GRAVITY := 18.0                  # airborne arcs from knockback
const KNOCKBACK_MAX := 9.0             # clamp so blasts shove, not launch

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
var _knockback := Vector3.ZERO         # havoc impulses (explosions, shots)
var _death_impulse := Vector3.ZERO     # snapshot of the killing blow's push
var _visual_root: Node3D
var _model_root: Node3D
var _animator: HumanoidAnimator


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

	# Stair/floor contract: explicit so procedural 34 deg stair ramps stay
	# safely inside the floor angle, and slopes don't fling the capsule.
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.3

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

	# The player is a woman in a skirt; NPCs are varied humans dressed by
	# their spawn manifest color.
	var shirt: Color = _config.get("color", Color(0.6, 0.65, 0.7))
	var female := is_player() or bool(_config.get("female", false))
	var cfg := {
		"female": female,
		"shirt": shirt,
	}
	if female and is_player():
		cfg["skin"] = Color(0.9, 0.74, 0.62)
		cfg["hair"] = Color(0.4, 0.27, 0.16)
		cfg["pants"] = Color(0.35, 0.32, 0.36)
	_model_root = HumanoidModel.build_human(cfg)
	_animator = HumanoidAnimator.new()
	_visual_root.add_child(_animator)
	_animator.add_child(_model_root)
	_animator.configure(_model_root.get_meta("anim_limbs"))


func set_body_color(color: Color) -> void:
	if _model_root == null or not _model_root.has_meta("shirt_material"):
		return
	var shirt_m: StandardMaterial3D = _model_root.get_meta("shirt_material")
	shirt_m.albedo_color = color


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
	# Gravity: knockback can lift the body airborne, so the arc must come
	# back down instead of drifting away forever.
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
	# Havoc impulses ride on top of locomotion and decay exponentially.
	velocity += _knockback
	_knockback *= exp(-5.5 * delta)
	move_and_slide()

	if _animator != null:
		_animator.set_motion(
				Vector2(velocity.x, velocity.z).length(),
				not is_on_floor())

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
	if _animator != null:
		_animator.play_attack()

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


## Havoc physics: radial impulses from explosions and heavy hits.
func apply_knockback(impulse: Vector3) -> void:
	_knockback = (_knockback + impulse).limit_length(KNOCKBACK_MAX)


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
	# Violent deaths shed a flesh burst before the corpse settles.
	var violent := source_id != &"deprivation" and source_id != &"infection"
	if violent:
		DebrisManager.burst_box(global_position + Vector3.UP * 0.9,
				Vector3(0.55, 1.2, 0.45),
				MaterialDB.get_material(&"flesh").get("debris_color"),
				&"flesh", 6, 2.6)
	collision_layer = 0
	collision_mask = 0
	set_physics_process(false)
	if interactable != null:
		interactable.enabled = false

	if violent:
		_death_impulse = _knockback
		_spawn_ragdoll_corpse()
		return

	# Quiet death (starvation/infection): static corpse, tip over in place.
	for mesh in HumanoidModel.collect_meshes(_visual_root):
		if mesh.material_override is StandardMaterial3D:
			(mesh.material_override as StandardMaterial3D).albedo_color = \
					Color(0.45, 0.15, 0.15)
	_visual_root.rotation_degrees.x = 90.0
	_visual_root.position.y = 0.35


## Violent deaths become a physics ragdoll carrying the ACTUAL body model.
func _spawn_ragdoll_corpse() -> void:
	var scene := get_tree().current_scene
	if scene == null or _model_root == null:
		return
	for mesh in HumanoidModel.collect_meshes(_model_root):
		if mesh.material_override is StandardMaterial3D:
			var mat := mesh.material_override as StandardMaterial3D
			mat.albedo_color = mat.albedo_color.lerp(
					Color(0.4, 0.12, 0.1), 0.5)
	var corpse := CorpseBody.new()
	scene.add_child(corpse)
	corpse.global_position = global_position
	if _visual_root != null:
		corpse.rotation.y = _visual_root.rotation.y
	if _animator != null:
		_animator.stop()
	corpse.take_visual(_model_root)
	var launch := _death_impulse
	launch.y *= 0.4
	if launch.length() < 1.0:
		launch = Vector3(randf_range(-0.6, 0.6), 0.8, randf_range(-0.6, 0.6))
	corpse.launch(launch)
	queue_free()


## Firearm recoil / melee swing cue for the procedural animator.
func notify_attack_anim() -> void:
	if _animator != null:
		_animator.play_attack()


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
