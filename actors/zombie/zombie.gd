class_name Zombie
extends CharacterBody3D
## Slow shambler. Individual danger is low; the threat is numbers and noise.
##
## States: WANDER -> CHASE (sees a survivor) / INVESTIGATE (heard a noise).
## Zombies are transient actors: not persisted in saves during Prototype 0,
## they respawn fresh from the population manifest on load.

signal died(zombie: Zombie)

const LAYER_ENVIRONMENT := 1
const LAYER_SURVIVORS := 2
const LAYER_ZOMBIES := 4

const SPEED_WANDER := 0.55
const SPEED_CHASE := 1.35          # slower than walking player by design
const SIGHT_RADIUS := 10.0         # ignores walls in P0 (TODO: LOS check)
const HEARING_RADIUS := 18.0       # reacts to EventBus.attack_performed
const ATTACK_RANGE := 1.25
const ATTACK_COOLDOWN := 1.5
const ATTACK_DAMAGE := 12.0

const MAX_HEALTH := 45.0

enum State { WANDER, CHASE, INVESTIGATE }

static var _spawn_counter := 0

var zombie_id: StringName
var anchor := Vector3.ZERO         # home point it shambles around
var state := State.WANDER
var target: Node3D = null          # chased survivor (live node reference)

var health: HealthComponent

var _attack_cooldown := 0.0
var _retarget_cooldown := 0.0
var _wander_target := Vector3.ZERO
var _wander_pause := randf_range(1.0, 5.0)


func _ready() -> void:
	_spawn_counter += 1
	zombie_id = StringName("zombie_%03d" % _spawn_counter)
	anchor = global_position
	_wander_target = global_position

	collision_layer = LAYER_ZOMBIES
	collision_mask = LAYER_ENVIRONMENT | LAYER_SURVIVORS | LAYER_ZOMBIES

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0, 0.85, 0)
	add_child(shape)

	var mesh_instance := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.38
	mesh.height = 1.65
	mesh_instance.mesh = mesh
	mesh_instance.position = Vector3(0, 0.8, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.52, 0.38)
	mat.roughness = 1.0
	mesh_instance.material_override = mat
	mesh_instance.rotation_degrees.x = 12.0  # hunched silhouette
	add_child(mesh_instance)

	health = HealthComponent.new()
	health.max_health = MAX_HEALTH
	add_child(health)
	health.current_health = health.max_health
	health.died.connect(_on_health_died)

	add_to_group(&"zombies")
	ActorRegistry.register(self, zombie_id)
	EventBus.attack_performed.connect(_on_noise_heard)


func take_damage(amount: float, source_id: StringName) -> void:
	health.damage(amount, source_id)


func _physics_process(delta: float) -> void:
	if health.is_dead:
		return
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_retarget_cooldown -= delta

	if _retarget_cooldown <= 0.0:
		_retarget_cooldown = 0.5
		_acquire_target()

	match state:
		State.WANDER:
			_do_wander(delta)
		State.INVESTIGATE:
			_do_investigate(delta)
		State.CHASE:
			_do_chase()

	move_and_slide()


# --- Perception -------------------------------------------------------------

func _acquire_target() -> void:
	var found := ActorRegistry.find_nearest_in_group(
			global_position, &"survivors", SIGHT_RADIUS)
	if found != null:
		target = found
		state = State.CHASE
	elif state == State.CHASE:
		target = null
		state = State.WANDER
		_pick_wander_target()


func _on_noise_heard(noise_position: Vector3) -> void:
	if health.is_dead or state == State.CHASE:
		return
	if global_position.distance_to(noise_position) <= HEARING_RADIUS:
		state = State.INVESTIGATE
		_wander_target = noise_position


# --- Behavior ---------------------------------------------------------------

func _do_wander(delta: float) -> void:
	_wander_pause -= delta
	if _wander_pause <= 0.0:
		_wander_pause = randf_range(2.0, 6.0)
		_pick_wander_target()
	var to_target := _wander_target - global_position
	to_target.y = 0.0
	if to_target.length() > 0.3:
		velocity.x = to_target.normalized().x * SPEED_WANDER
		velocity.z = to_target.normalized().z * SPEED_WANDER
	else:
		velocity.x = 0.0
		velocity.z = 0.0


func _pick_wander_target() -> void:
	var offset := Vector3(randf_range(-4.0, 4.0), 0, randf_range(-4.0, 4.0))
	_wander_target = anchor + offset


func _do_investigate(_delta: float) -> void:
	var to_target := _wander_target - global_position
	to_target.y = 0.0
	if to_target.length() > 0.8:
		velocity.x = to_target.normalized().x * SPEED_CHASE
		velocity.z = to_target.normalized().z * SPEED_CHASE
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		state = State.WANDER
		_wander_pause = randf_range(2.0, 5.0)


func _do_chase() -> void:
	if target == null or not is_instance_valid(target) or target.health.is_dead:
		state = State.WANDER
		target = null
		return
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var distance := to_target.length()
	if distance > ATTACK_RANGE:
		velocity.x = to_target.x / distance * SPEED_CHASE
		velocity.z = to_target.z / distance * SPEED_CHASE
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		if _attack_cooldown <= 0.0:
			_attack(target)


func _attack(victim: Node3D) -> void:
	_attack_cooldown = ATTACK_COOLDOWN
	victim.receive_bite(ATTACK_DAMAGE, zombie_id)
	EventBus.attack_performed.emit(global_position)


# --- Death ------------------------------------------------------------------

func _on_health_died(source_id: StringName) -> void:
	died.emit(self)
	EventBus.actor_died.emit(zombie_id, source_id)
	ActorRegistry.unregister(zombie_id)
	remove_from_group(&"zombies")
	collision_layer = 0
	collision_mask = 0
	set_physics_process(false)
	velocity = Vector3.ZERO

	# Corpse conversion: fall over and darken.
	for child in get_children():
		if child is MeshInstance3D:
			child.material_override.albedo_color = Color(0.3, 0.33, 0.28)
	rotation_degrees.x = 90.0
	position.y = 0.3
