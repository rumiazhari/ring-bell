class_name Zombie
extends CharacterBody3D
## Slow shambler. Individual danger is low; the threat is numbers and noise.
##
## States: WANDER -> CHASE (sees a survivor) / INVESTIGATE (heard a noise).
## In the streamed city, WANDER targets are ROAD points sampled from the
## CityPlan so idle zombies roam streets instead of grinding into walls.
## Zombies are transient actors: not persisted in saves; the CitySpawner
## recreates deterministic per-chunk populations when chunks go ACTIVE.
##
## SPAWN CONTRACT (city): set requested_id + city_plan BEFORE add_child().

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
const GRAVITY := 18.0
const KNOCKBACK_MAX := 9.0             # clamp so blasts shove, not launch
const ROAM_MIN_DIST := 6.0         # road-roam annulus around current spot
const ROAM_MAX_DIST := 24.0
const STUCK_TIME := 2.0            # seconds without progress -> new target

# Phase G pack steering: instead of beelining, a chasing zombie hugs its
# assigned flank while far out and commits to the direct line up close -
# converging crowds envelop the survivor from both sides instead of forming
# a single-file conga line behind the leader.
const FLANK_NEAR := 2.5         # inside this range: straight-line commitment
const FLANK_FAR := 6.0          # at/above this range: full arc strength
const FLANK_ARC := 0.85         # max tangential blend (~40 deg off the line)

enum State { WANDER, CHASE, INVESTIGATE }

static var _spawn_counter := 0

var zombie_id: StringName
var requested_id: StringName = &"" # deterministic city id ("z_1_-2_004")
var anchor := Vector3.ZERO         # home point it shambles around
var state := State.WANDER
var target: Node3D = null          # chased survivor (live node reference)
var city_plan: CityPlan = null     # when set, WANDER follows road space

var health: HealthComponent

var _attack_cooldown := 0.0
var _retarget_cooldown := 0.0
var _wander_target := Vector3.ZERO
var _wander_pause := randf_range(1.0, 5.0)
var _roam_rng := RandomNumberGenerator.new()
var _stuck_timer := 0.0
var _knockback := Vector3.ZERO         # havoc impulses (explosions, shots)
var _death_impulse := Vector3.ZERO     # snapshot of the killing blow's push
var _flank_sign := 1.0                 # preferred approach side (-1 / +1)
var _flank_strength := 0.7             # 0..1 how hard this zombie arcs wide
var _model_root: Node3D
var _animator: HumanoidAnimator
var _visual_yaw := 0.0                 # smoothed facing from movement


func _ready() -> void:
	_spawn_counter += 1
	zombie_id = requested_id if requested_id != &"" \
			else StringName("zombie_%03d" % _spawn_counter)
	anchor = global_position
	_wander_target = global_position
	if city_plan != null:
		_roam_rng.seed = WorldSeed.combine([
				WorldSeed.str_hash("zroam"), WorldSeed.str_hash(str(zombie_id))])

	collision_layer = LAYER_ZOMBIES
	collision_mask = LAYER_ENVIRONMENT | LAYER_SURVIVORS | LAYER_ZOMBIES

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	shape.shape = capsule
	shape.position = Vector3(0, 0.85, 0)
	add_child(shape)

	# Bloody rotten human body - variation seeded per zombie id so the city
	# crowd is deterministic (same id -> same rot).
	var look_rng := RandomNumberGenerator.new()
	if requested_id != &"":
		look_rng.seed = WorldSeed.combine([
				WorldSeed.str_hash("zlook"),
				WorldSeed.str_hash(str(zombie_id))])
	else:
		look_rng.randomize()
	_model_root = HumanoidModel.build_zombie(look_rng)

	# Phase G: flank assignment - deterministic per id for city zombies.
	if requested_id != &"":
		_flank_sign = flank_sign_for(zombie_id)
		var frng := RandomNumberGenerator.new()
		frng.seed = WorldSeed.combine([
				WorldSeed.str_hash("zflankstr"),
				WorldSeed.str_hash(str(zombie_id))])
		_flank_strength = frng.randf_range(0.55, 1.0)
	else:
		_flank_sign = 1.0 if randf() < 0.5 else -1.0
		_flank_strength = randf_range(0.55, 1.0)

	_animator = HumanoidAnimator.new()
	add_child(_animator)
	_animator.add_child(_model_root)
	_animator.configure(_model_root.get_meta("anim_limbs"),
			{"shamble": true})

	health = HealthComponent.new()
	health.max_health = MAX_HEALTH
	add_child(health)
	health.current_health = health.max_health
	health.died.connect(_on_health_died)

	add_to_group(&"zombies")
	ActorRegistry.register(self, zombie_id)
	EventBus.attack_performed.connect(_on_noise_heard)
	EventBus.explosion_occurred.connect(_on_noise_heard)


func take_damage(amount: float, source_id: StringName) -> void:
	health.damage(amount, source_id)


## Deterministic per-id flank side: the same city id hugs the same side of
## its prey every run (like rot/look), while mixed ids in a crowd split
## around the survivor from BOTH sides - that is what makes packs corner.
static func flank_sign_for(id: StringName) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = WorldSeed.combine([
			WorldSeed.str_hash("zflank"), WorldSeed.str_hash(str(id))])
	return 1.0 if rng.randf() < 0.5 else -1.0


## Havoc physics: radial impulses from explosions and heavy hits.
func apply_knockback(impulse: Vector3) -> void:
	_knockback = (_knockback + impulse).limit_length(KNOCKBACK_MAX)


func _physics_process(delta: float) -> void:
	if health.is_dead:
		return
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_retarget_cooldown -= delta

	if not is_on_floor():
		velocity.y = velocity.y - GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

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

	velocity += _knockback
	_knockback *= exp(-5.5 * delta)
	move_and_slide()

	# Face where we actually walk (model front is local +Z), smoothed.
	var xz_speed := Vector2(velocity.x, velocity.z).length()
	if xz_speed > 0.15:
		_visual_yaw = lerp_angle(_visual_yaw,
				atan2(velocity.x, velocity.z),
				minf(1.0, 9.0 * delta))
	if _animator != null:
		_animator.rotation.y = _visual_yaw
		_animator.set_motion(xz_speed, not is_on_floor())


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
	var to_target := _wander_target - global_position
	to_target.y = 0.0
	# Stuck detection: ordered to move but not actually progressing (wall,
	# car, fence) -> drop the current road target and pick another one.
	if to_target.length() > 0.6:
		if Vector2(velocity.x, velocity.z).length() < 0.1:
			_stuck_timer += delta
			if _stuck_timer >= STUCK_TIME:
				_pick_wander_target()
				_stuck_timer = 0.0
		else:
			_stuck_timer = 0.0
	else:
		_stuck_timer = 0.0
	if _wander_pause <= 0.0:
		_wander_pause = randf_range(2.0, 6.0)
		_pick_wander_target()
	if to_target.length() > 0.3:
		velocity.x = to_target.normalized().x * SPEED_WANDER
		velocity.z = to_target.normalized().z * SPEED_WANDER
	else:
		velocity.x = 0.0
		velocity.z = 0.0


func _pick_wander_target() -> void:
	if city_plan != null:
		var p := city_plan.sample_road_position(
				Vector2(global_position.x, global_position.z),
				ROAM_MIN_DIST, ROAM_MAX_DIST, _roam_rng)
		if p != Vector2.INF:
			_wander_target = Vector3(p.x, global_position.y, p.y)
			return
	# Fallback (legacy block or no road found): small anchor scatter.
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
		var dir := Vector3(to_target.x / distance, 0.0, to_target.z / distance)
		# Phase G pack steering: blend the direct line with a tangential
		# drift toward this zombie's assigned flank. Far out the arc is at
		# full strength (scaled by per-zombie boldness); inside FLANK_NEAR
		# it fades to zero so the kill lunge stays a straight commitment.
		var arc := clampf(inverse_lerp(FLANK_NEAR, FLANK_FAR, distance),
				0.0, 1.0)
		arc *= _flank_strength * FLANK_ARC
		var steer := dir + Vector3(-dir.z, 0.0, dir.x) * (_flank_sign * arc)
		var steer_xz := steer.normalized()
		velocity.x = steer_xz.x * SPEED_CHASE
		velocity.z = steer_xz.z * SPEED_CHASE
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		if _attack_cooldown <= 0.0:
			_attack(target)


func _attack(victim: Node3D) -> void:
	_attack_cooldown = ATTACK_COOLDOWN
	if _animator != null:
		_animator.play_attack()
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

	# Gore burst - violent ends shed flesh gibs that fall and pile up.
	if source_id != &"infection":
		DebrisManager.burst_box(global_position + Vector3.UP * 0.9,
				Vector3(0.55, 1.2, 0.45),
				Color(0.38, 0.2, 0.16), &"flesh", 7, 2.8)

	# Violent deaths become a physics ragdoll: the corpse tumbles with the
	# killing impulse and settles where gravity and walls put it. Quiet
	# deaths (starvation/infection) keep the old scripted tip-over.
	_death_impulse = _knockback
	if source_id != &"infection" or _death_impulse.length() > 1.5:
		_spawn_ragdoll_corpse(source_id)
		queue_free()
		return

	# Corpse conversion (quiet deaths only): fall over and go pale.
	for mesh in HumanoidModel.collect_meshes(_model_root):
		if mesh.material_override is StandardMaterial3D:
			(mesh.material_override as StandardMaterial3D).albedo_color = \
					Color(0.34, 0.32, 0.28)
	# Rotate only the visual model, not the collision capsule.
	if _animator != null:
		_animator.rotation_degrees.x = 90.0
		_animator.position.y = 0.3


## Replace the body with a physics ragdoll carrying the ACTUAL humanoid
## model (tinted pale), launched by the killing blow.
func _spawn_ragdoll_corpse(_source_id: StringName) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Quiet-death tint for the adopted body.
	for mesh in HumanoidModel.collect_meshes(_model_root):
		if mesh.material_override is StandardMaterial3D:
			var mat := mesh.material_override as StandardMaterial3D
			mat.albedo_color = mat.albedo_color.lerp(
					Color(0.36, 0.3, 0.26), 0.45)
	var corpse := CorpseBody.new()
	scene.add_child(corpse)
	corpse.global_position = global_position
	# Carry the facing into the ragdoll (the model itself never yawed).
	if _animator != null:
		_animator.stop()
		corpse.rotation.y = _animator.rotation.y
	if _model_root != null:
		corpse.take_visual(_model_root)
	# Dampen the launch: a slump toward the hit, never a rocket jump.
	var launch := _death_impulse
	launch.y *= 0.4
	if launch.length() < 1.0:
		launch = Vector3(randf_range(-0.6, 0.6), 0.8, randf_range(-0.6, 0.6))
	corpse.launch(launch)
