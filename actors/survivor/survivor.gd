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

# Phase T: player handheld lantern — warm point light that makes genuine
# darkness survivable. Follows the player like a carried torch/lantern,
# visible only at night (GameClock.is_night()), with a subtle bob.
const LANTERN_RANGE := 10.0
const LANTERN_ENERGY := 2.2
const LANTERN_COLOR := Color(1.0, 0.85, 0.58)
const LANTERN_OFFSET := Vector3(0.35, 1.10, 0.25)
const LANTERN_BOB_AMPL := 0.045
const LANTERN_BOB_FREQ := 4.2

# Preload (not global class_name lookup): keeps headless suites green even
# before the editor rescans the global script-class cache.
const PARKOUR_SCRIPT := preload("res://actors/traversal/parkour_controller.gd")

var identity: IdentityComponent
var health: HealthComponent
var needs: NeedsComponent
var inventory: InventoryComponent
var interactable: InteractableComponent
var parkour: PARKOUR_SCRIPT            # vertical mobility + fall damage

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
var _skeleton: Skeleton3D
var _locomotion: CharacterLocomotion
var _visual_yaw: float = 0.0
var _lantern: OmniLight3D
var _lantern_t := 0.0
var _capsule_shape: CollisionShape3D
var _capsule: CapsuleShape3D


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

	parkour = PARKOUR_SCRIPT.new()
	add_child(parkour)
	parkour.setup(self)

	# Phase T: handheld lantern — only the player carries it. OmniLight
	# follows the body (child) so it survives streaming/teleports
	# automatically; DayNightController darkness makes it the readable
	# pool at night while day keeps it off.
	if is_player():
		_lantern = OmniLight3D.new()
		_lantern.name = "Lantern"
		_lantern.position = LANTERN_OFFSET
		_lantern.omni_range = LANTERN_RANGE
		_lantern.omni_attenuation = 1.4
		_lantern.light_energy = LANTERN_ENERGY
		_lantern.light_color = LANTERN_COLOR
		_lantern.shadow_enabled = false
		_lantern.visible = GameClock.is_night()
		_lantern.add_to_group(&"player_lantern")
		add_child(_lantern)


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
	_capsule_shape = shape
	_capsule = capsule

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
	# Skeleton + locomotion (in-place, ACTIVE-only)
	_skeleton = SkeletonFactory.build_survivor_skeleton()
	_visual_root.add_child(_skeleton)
	_locomotion = CharacterLocomotion.new()
	_locomotion.name = "Locomotion"
	_visual_root.add_child(_locomotion)
	# Attach primitive meshes via BoneAttachment3D before animator
	SkeletonFactory.attach_model(_skeleton, _model_root)
	_animator = HumanoidAnimator.new()
	_visual_root.add_child(_animator)
	_animator.add_child(_model_root)
	_animator.configure(_model_root.get_meta("anim_limbs"))
	# Wire locomotion after skeleton is in tree (deferred to silence Skeleton3D track warnings)
	if _skeleton != null and is_instance_valid(_skeleton):
		_locomotion.call_deferred("setup", _skeleton, _model_root)
	else:
		_locomotion.setup(_skeleton, _model_root)
	# Gate animator: when skeleton exists, locomotion is authoritative
	if _skeleton != null:
		_animator.set_process(false)


func set_body_color(color: Color) -> void:
	if _model_root == null or not _model_root.has_meta("shirt_material"):
		return
	var shirt_m: StandardMaterial3D = _model_root.get_meta("shirt_material")
	shirt_m.albedo_color = color

func _check_headroom_clear() -> bool:
	# Upward sphere 0.25m radius at +1.55y for STAND_UP gate
	if not is_inside_tree() or get_world_3d() == null:
		return true
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.25
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0, 1.55, 0))
	params.collision_mask = LAYER_ENVIRONMENT
	params.exclude = [get_rid()]
	var hits: Array = space.intersect_shape(params, 1)
	return hits.is_empty()

func set_crouch(held: bool) -> void:
	# Helper for harness: harness may call via set_meta or direct
	set_meta("crouch_held", held)

func get_capsule_height() -> float:
	if _capsule != null:
		return _capsule.height
	if _capsule_shape != null and _capsule_shape.shape is CapsuleShape3D:
		return (_capsule_shape.shape as CapsuleShape3D).height
	if _locomotion != null and is_instance_valid(_locomotion):
		return _locomotion.capsule_height
	return 1.7

func _update_capsule(delta: float) -> void:
	if _capsule == null or _locomotion == null or not is_instance_valid(_locomotion):
		return
	var target: float = _locomotion.capsule_height
	var cur: float = _capsule.height
	if abs(cur - target) < 0.001:
		_capsule.height = target
	else:
		var max_diff: float = abs(CharacterLocomotion.CAP_STAND - CharacterLocomotion.CAP_SLIDE)
		var speed: float = max_diff / CharacterLocomotion.CAP_LERP
		_capsule.height = move_toward(cur, target, speed * delta)
	if _capsule_shape != null:
		_capsule_shape.position = Vector3(0, _capsule.height * 0.5, 0)


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
	var is_sliding_now: bool = _locomotion != null and is_instance_valid(_locomotion) and _locomotion.state == CharacterLocomotion.State.SLIDE
	if is_sliding_now:
		# During SLIDE, stamina drain is handled by CharacterLocomotion (18/s); skip regen/drain here
		pass
	elif sprinting:
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

	# P-C2: respect parkour state lock - queue move but don't apply while vault/mantle/hang/climb/turn/slide/stand locked
	var is_locked: bool = false
	if _locomotion != null and is_instance_valid(_locomotion):
		var ls: int = int(_locomotion.state)
		if ls == CharacterLocomotion.State.VAULT or ls == CharacterLocomotion.State.MANTLE or ls == CharacterLocomotion.State.HANG or ls == CharacterLocomotion.State.CLIMB_UP or ls == CharacterLocomotion.State.TURN_L90 or ls == CharacterLocomotion.State.TURN_R90 or ls == CharacterLocomotion.State.TURN_180 or ls == CharacterLocomotion.State.SLIDE or ls == CharacterLocomotion.State.STAND_UP:
			is_locked = true
	# HANG freezes xz (capsule holds, gravity still applies but is_on_floor false keeps hang)
	# SLIDE locked to facing*6.0 regardless of stick
	if is_locked and _locomotion != null and is_instance_valid(_locomotion):
		if _locomotion.state == CharacterLocomotion.State.HANG:
			velocity.x = 0.0
			velocity.z = 0.0
		elif _locomotion.state == CharacterLocomotion.State.SLIDE:
			velocity.x = facing.x * CharacterLocomotion.SLIDE_SPEED
			velocity.z = facing.z * CharacterLocomotion.SLIDE_SPEED
			# keep gravity still but is_on_floor true keeps grounded
		elif _locomotion.state == CharacterLocomotion.State.STAND_UP:
			# Damp velocity during stand-up (keep current but lerp to reduced target)
			var target_speed_su := WALK_SPEED * 0.5 if moving else 0.0
			var target_vel_su := _move_dir * target_speed_su if moving else Vector3.ZERO
			velocity.x = lerpf(velocity.x, target_vel_su.x, 0.3)
			velocity.z = lerpf(velocity.z, target_vel_su.z, 0.3)

	var target_speed := RUN_SPEED if sprinting else WALK_SPEED
	target_speed *= needs.speed_multiplier()
	# CROUCH_WALK clamps to 1.2 even if sprint requested
	if _locomotion != null and is_instance_valid(_locomotion):
		if _locomotion.state == CharacterLocomotion.State.CROUCH_WALK:
			target_speed = 1.2 * needs.speed_multiplier()
		elif _locomotion.state == CharacterLocomotion.State.CROUCH_IDLE:
			target_speed = 0.0
	var target_velocity := _move_dir * target_speed if moving else Vector3.ZERO
	# If crouch idle, zero velocity regardless of move_dir
	if _locomotion != null and is_instance_valid(_locomotion) and _locomotion.state == CharacterLocomotion.State.CROUCH_IDLE:
		target_velocity = Vector3.ZERO
	var blend := 1.0 - exp(-ACCELERATION * delta)
	if not is_locked:
		velocity.x = lerpf(velocity.x, target_velocity.x, blend)
		velocity.z = lerpf(velocity.z, target_velocity.z, blend)
	else:
		# During vault/mantle/climb/slide/stand, keep current xz but allow HANG/SLIDE already handled
		pass
	# Gravity: knockback can lift the body airborne, so the arc must come
	# back down instead of drifting away forever.
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
	# Havoc impulses ride on top of locomotion and decay exponentially.
	velocity += _knockback
	_knockback *= exp(-5.5 * delta)

	# Vault/mantle probes (Phase E slice 2): detect low obstacles ahead.
	parkour.process_traversal(_move_dir, delta)

	move_and_slide()

	if _locomotion != null and _skeleton != null and is_instance_valid(_locomotion) and is_instance_valid(_skeleton):
		var xz_speed: float = Vector2(velocity.x, velocity.z).length()
		# strafe: signed lateral where +1 is right
		var right := Vector3(-facing.z, 0.0, facing.x)
		var strafe_val: float = 0.0
		if _move_dir.length_squared() > 0.001:
			strafe_val = clamp(_move_dir.dot(right), -1.0, 1.0)
		# slope: from floor normal or WorldPlan height delta (read-only)
		var slope_val: float = 0.0
		if is_on_floor():
			var n: Vector3 = get_floor_normal()
			slope_val = rad_to_deg(acos(clampf(n.dot(Vector3.UP), -1.0, 1.0)))
			# Clamp to buildable max
			slope_val = min(slope_val, 22.0)
		else:
			# Fallback: sample WorldPlan heights if available (read-only)
			var mgr_world := get_tree().get_first_node_in_group("chunk_manager") if get_tree().has_method("get_first_node_in_group") else null
			if mgr_world == null:
				var managers2 := get_tree().get_nodes_in_group("chunk_manager")
				if not managers2.is_empty():
					mgr_world = managers2[0]
			if mgr_world != null and mgr_world.has_method("get") and mgr_world.get("world_plan") != null:
				var wp: WorldPlan = mgr_world.get("world_plan") as WorldPlan
				if wp != null:
					var p0 := Vector2(global_position.x, global_position.z)
					var p1 := p0 + Vector2(1, 0)
					var h0: float = wp.terrain_height_at(p0)
					var h1: float = wp.terrain_height_at(p1)
					slope_val = rad_to_deg(atan2(abs(h1 - h0), 1.0))
		# yaw delta: wrap target - facing
		var facing_yaw: float = atan2(facing.x, facing.z)
		var target_yaw: float = facing_yaw
		if _move_dir.length_squared() > 0.001:
			target_yaw = atan2(_move_dir.x, _move_dir.z)
		else:
			# For stationary turn, check visual yaw vs facing (mouse yaw)
			target_yaw = _visual_yaw
		var yaw_delta: float = wrapf(target_yaw - facing_yaw, -PI, PI)
		# Deadzone to avoid jitter
		if abs(yaw_delta) < deg_to_rad(15.0):
			yaw_delta = 0.0
		# P-C2: gather vault/mantle/ledge probes and stamina for locomotion
		var vault_probe: Dictionary = {}
		var mantle_probe: Dictionary = {}
		var ledge_probe: Dictionary = {}
		if parkour != null and is_instance_valid(parkour):
			if parkour.has_method("get_vault_probe"):
				vault_probe = parkour.get_vault_probe()
			if parkour.has_method("get_mantle_probe"):
				mantle_probe = parkour.get_mantle_probe()
			if parkour.has_method("get_ledge_probe"):
				ledge_probe = parkour.get_ledge_probe()
		var jump_pressed: bool = false
		if InputMap.has_action("jump"):
			jump_pressed = Input.is_action_just_pressed("jump")
		var crouch_held: bool = false
		if InputMap.has_action("crouch"):
			crouch_held = Input.is_action_pressed("crouch")
		if has_meta("crouch_held"):
			crouch_held = crouch_held or bool(get_meta("crouch_held"))
		var crouch_pressed: bool = false
		if InputMap.has_action("crouch"):
			crouch_pressed = Input.is_action_just_pressed("crouch")
		if has_meta("crouch_pressed"):
			crouch_pressed = crouch_pressed or bool(get_meta("crouch_pressed"))
		# Also check meta for crouch_pressed triggered via harness direct set
		var sprint_held: bool = _wants_sprint
		var headroom_clear: bool = _check_headroom_clear()
		_locomotion.update({
			"speed": xz_speed,
			"strafe": strafe_val,
			"slope_deg": slope_val,
			"yaw_delta": yaw_delta,
			"is_airborne": not is_on_floor(),
			"move_dir": _move_dir,
			"facing": facing,
			"stamina": stamina,
			"vault_probe": vault_probe,
			"mantle_probe": mantle_probe,
			"ledge_probe": ledge_probe,
			"jump_pressed": jump_pressed,
			"crouch_held": crouch_held,
			"crouch_pressed": crouch_pressed,
			"sprint_held": sprint_held,
			"headroom_clear": headroom_clear
		}, delta)
		# Capsule lerp after locomotion decides target
		_update_capsule(delta)
		# While HANG, freeze xz and ensure hand_snap
		# While SLIDE, ensure velocity stays locked (already set before move_and_slide, also enforce post-update)
		if _locomotion.state == CharacterLocomotion.State.SLIDE:
			velocity.x = facing.x * CharacterLocomotion.SLIDE_SPEED
			velocity.z = facing.z * CharacterLocomotion.SLIDE_SPEED
		elif _locomotion.state == CharacterLocomotion.State.HANG:
			velocity.x = 0.0
			velocity.z = 0.0
		# In-place guarantee: root bone must stay <0.005
		if _skeleton != null and is_instance_valid(_skeleton):
			var rid: int = _skeleton.find_bone("root")
			if rid >= 0:
				var pos: Vector3 = _skeleton.get_bone_pose_position(rid)
				if pos.length() > 0.0049:
					_skeleton.set_bone_pose_position(rid, Vector3.ZERO)
	elif _animator != null:
		_animator.set_motion(
			Vector2(velocity.x, velocity.z).length(),
			not is_on_floor())

	if moving:
		facing = _move_dir.normalized()
	# Visual yaw: face where we move, smoothed
	_visual_yaw = atan2(facing.x, facing.z)
	_visual_root.rotation.y = _visual_yaw

	_update_lantern(delta)

	parkour.tick(delta)

	tick_survival(delta)


## Phase T: bob + night visibility for the handheld lantern.
func _update_lantern(delta: float) -> void:
	if _lantern == null or not is_instance_valid(_lantern):
		return
	_lantern.visible = GameClock.is_night()
	_lantern_t += delta
	# Subtle bob so the carried light reads as handheld, not a drone halo.
	var moving := _move_dir.length_squared() > 0.01
	var idle_bob := sin(_lantern_t * LANTERN_BOB_FREQ) * LANTERN_BOB_AMPL
	var walk_bob := sin(_lantern_t * 7.0) * 0.018 if moving else 0.0
	_lantern.position = LANTERN_OFFSET + Vector3(0.0, idle_bob + walk_bob, 0.0)

## Exposed for headless tests to force a visibility refresh without waiting
## a physics frame (GameClock was just rewound to night/day).
func refresh_lantern() -> void:
	_update_lantern(0.0)


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
	if _locomotion != null and is_instance_valid(_locomotion):
		# Locomotion authoritative, but also trigger animator for attacks if needed
		if _animator != null:
			_animator.play_attack()
		return
	if _animator != null:
		_animator.play_attack()

func get_locomotion_state() -> String:
	if _locomotion != null and is_instance_valid(_locomotion):
		match _locomotion.state:
			CharacterLocomotion.State.IDLE: return "IDLE"
			CharacterLocomotion.State.WALK: return "WALK"
			CharacterLocomotion.State.RUN: return "RUN"
			CharacterLocomotion.State.SPRINT: return "SPRINT"
			CharacterLocomotion.State.TURN_L90: return "TURN_L90"
			CharacterLocomotion.State.TURN_R90: return "TURN_R90"
			CharacterLocomotion.State.TURN_180: return "TURN_180"
			CharacterLocomotion.State.VAULT: return "VAULT"
			CharacterLocomotion.State.MANTLE: return "MANTLE"
			CharacterLocomotion.State.HANG: return "HANG"
			CharacterLocomotion.State.CLIMB_UP: return "CLIMB_UP"
			CharacterLocomotion.State.CROUCH_IDLE: return "CROUCH_IDLE"
			CharacterLocomotion.State.CROUCH_WALK: return "CROUCH_WALK"
			CharacterLocomotion.State.SLIDE: return "SLIDE"
			CharacterLocomotion.State.STAND_UP: return "STAND_UP"
	return "IDLE"

func get_locomotion_blend() -> float:
	if _locomotion != null and is_instance_valid(_locomotion):
		return _locomotion.blend
	return 0.0

func get_foot_slide() -> float:
	if _locomotion != null and is_instance_valid(_locomotion):
		return _locomotion.foot_slide
	return 0.0

func get_hand_snap() -> float:
	if _locomotion != null and is_instance_valid(_locomotion):
		return _locomotion.hand_snap
	return 0.0

func get_stamina() -> float:
	return stamina

func get_vault_state() -> String:
	if _locomotion != null and is_instance_valid(_locomotion):
		match _locomotion.state:
			CharacterLocomotion.State.VAULT: return "VAULT"
			CharacterLocomotion.State.MANTLE: return "MANTLE"
			CharacterLocomotion.State.HANG: return "HANG"
			CharacterLocomotion.State.CLIMB_UP: return "CLIMB_UP"
			CharacterLocomotion.State.SLIDE: return "SLIDE"
			CharacterLocomotion.State.CROUCH_IDLE: return "CROUCH_IDLE"
			CharacterLocomotion.State.CROUCH_WALK: return "CROUCH_WALK"
			CharacterLocomotion.State.STAND_UP: return "STAND_UP"
			_: return "NONE"
	return "NONE"

func get_skeleton() -> Skeleton3D:
	return _skeleton

func get_locomotion() -> CharacterLocomotion:
	return _locomotion

func get_capsule_shape() -> CollisionShape3D:
	return _capsule_shape


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
	# Locomotion reconstruction: IDLE then next update corrects to material speed (persistence)
	if _locomotion != null and is_instance_valid(_locomotion):
		_locomotion.state = CharacterLocomotion.State.IDLE
		_locomotion.blend = 0.0
		_locomotion.strafe = 0.0
		_locomotion.slope_deg = 0.0
		_locomotion.foot_slide = 0.0
		_locomotion.hand_snap = 0.0
		_locomotion.stamina = stamina
		_locomotion.ledge_pos = Vector3.ZERO
		_locomotion.ledge_normal = Vector3.ZERO
		_locomotion._vault_timer = 0.0
		_locomotion._mantle_timer = 0.0
		_locomotion._climb_timer = 0.0
		_locomotion._hang_timer = 0.0
		_locomotion._slide_timer = 0.0
		_locomotion._standup_timer = 0.0
		_locomotion._turn_timer = 0.0
		_locomotion.capsule_height = CharacterLocomotion.CAP_STAND
		_locomotion._capsule_target = CharacterLocomotion.CAP_STAND
		if _capsule != null:
			_capsule.height = CharacterLocomotion.CAP_STAND
			if _capsule_shape != null:
				_capsule_shape.position = Vector3(0, _capsule.height * 0.5, 0)
		_visual_yaw = atan2(facing.x, facing.z)
		if _visual_root != null and is_instance_valid(_visual_root):
			_visual_root.rotation.y = _visual_yaw
