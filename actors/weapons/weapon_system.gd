class_name WeaponSystem
extends Node
## Ranged firearms for the player survivor: SMG, pump shotgun, rocket
## launcher (slots 2-4; slot 1 stays melee/fists via Survivor.try_attack).
##
## Aiming is top-down style: the controller feeds the mouse's ground-plane
## projection as the aim point; shots originate at the survivor's chest.
## Hitscan guns raycast per pellet; the rocket spawns a swept-ray projectile
## whose detonation routes through DebrisManager.explosion so structures
## erode by material, debris bounces and actors are knocked back.

const HIT_MASK := 1 | 2 | 4          # environment | survivors | zombies
const MUZZLE_HEIGHT := 1.35

## Slot 0 is the unarmed/melee fallback handled by the Survivor itself.
var slots: Array[StringName] = [&"", &"smg", &"shotgun", &"rocket_launcher"]
var current_slot := 1                # start on the SMG

var _survivor: Survivor
var _cooldown := 0.0


func _ready() -> void:
	_survivor = get_parent() as Survivor


func current_def() -> Dictionary:
	if current_slot <= 0 or current_slot >= slots.size():
		return {}
	return ItemDB.get_gun_def(slots[current_slot])


func current_is_melee() -> bool:
	return current_def().is_empty()


func select_slot(index: int) -> void:
	if index < 0 or index >= slots.size() or index == current_slot:
		return
	current_slot = index
	_cooldown = maxf(_cooldown, 0.12)    # tiny swap delay
	EventBus.weapon_switched.emit(ItemDB.item_name(slots[index]))


func weapon_label() -> String:
	if current_is_melee():
		return ItemDB.item_name(_survivor.equipped_weapon_id)
	return String(current_def().get("name", "Gun"))


## Driven by PlayerController every physics frame with the mouse aim point.
func tick(delta: float, aim_point: Vector3) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	var def := current_def()
	if def.is_empty() or _survivor.health.is_dead:
		return

	var action := Input.is_action_pressed(&"attack") if bool(
			def.get("auto", false)) else Input.is_action_just_pressed(&"attack")
	if action and _cooldown <= 0.0:
		_cooldown = float(def.get("cooldown", 0.5))
		if def.get("projectile", &"") == &"rocket":
			_launch_rocket(def, aim_point)
		else:
			_fire_hitscan(def, aim_point)


# --- Hitscan -----------------------------------------------------------------

func _fire_hitscan(def: Dictionary, aim_point: Vector3) -> void:
	var muzzle := _survivor.global_position + Vector3.UP * MUZZLE_HEIGHT
	var base_dir := aim_point - muzzle
	base_dir.y = 0.0
	if base_dir.length_squared() < 0.001:
		base_dir = Vector3(_survivor.facing.x, 0.0, _survivor.facing.z)
	else:
		base_dir = base_dir.normalized()

	var spread_deg := float(def.get("spread_deg", 2.0))
	var range_m := float(def.get("range", 50.0))
	var pellets := int(def.get("pellets", 1))
	var end_for_tracer := muzzle

	for i in pellets:
		var dir := _spread(base_dir, spread_deg)
		var space := _survivor.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(muzzle,
				muzzle + dir * range_m, HIT_MASK)
		query.exclude = [_survivor.get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			end_for_tracer = muzzle + dir * range_m
			continue
		var point: Vector3 = hit["position"]
		end_for_tracer = point
		_apply_bullet_hit(hit, def, dir)

	_spawn_tracer(muzzle + base_dir * 0.45, end_for_tracer,
			def.get("tracer_color", Color(1, 1, 0.6)))
	_muzzle_flash(muzzle)
	if _survivor.has_method(&"notify_attack_anim"):
		_survivor.call(&"notify_attack_anim")

	EventBus.attack_performed.emit(_survivor.global_position)


func _apply_bullet_hit(hit: Dictionary, def: Dictionary, dir: Vector3) -> void:
	var collider: Object = hit.get("collider")
	var damage := float(def.get("damage", 8.0))
	var knockback := float(def.get("knockback", 1.0))

	if collider != null and collider.has_method("take_damage") \
			and collider.get("health") is HealthComponent \
			and not (collider.get("health") as HealthComponent).is_dead:
		collider.take_damage(damage, _survivor.identity.persistent_id)
		if collider.has_method("apply_knockback"):
			collider.apply_knockback(dir * knockback)
		# Blood spray - a few flesh gibs sell the impact.
		DebrisManager.burst_box(hit["position"] as Vector3,
				Vector3.ONE * 0.16, MaterialDB.get_material(&"flesh")
				.get("debris_color"), &"flesh", 2, 1.4)
	elif collider != null and collider.has_method("take_structural_damage"):
		var scale_factor := float(def.get("structural_scale", 1.0))
		collider.take_structural_damage(damage * scale_factor,
				_survivor.identity.persistent_id)
	else:
		# Static city geometry: bullets never destroy buildings - they only
		# kick up dust. Structural destruction is explosives-only.
		var scale_factor := float(def.get("structural_scale", 1.0))
		DebrisManager.bullet_hit_static(hit, damage * scale_factor)


func _spread(dir: Vector3, spread_deg: float) -> Vector3:
	if spread_deg <= 0.0:
		return dir
	var axis := Vector3.UP.cross(dir)
	if axis.length_squared() < 0.001:
		axis = Vector3.RIGHT.cross(dir)
	axis = axis.normalized()
	var angle := deg_to_rad(randf_range(-spread_deg, spread_deg))
	var tilted := dir.rotated(axis, angle)
	# Second rotation around the shot axis keeps the cone round.
	return tilted.rotated(dir.normalized(), randf_range(0.0, TAU))


# --- Rocket ------------------------------------------------------------------

func _launch_rocket(def: Dictionary, aim_point: Vector3) -> void:
	var muzzle := _survivor.global_position + Vector3.UP * MUZZLE_HEIGHT
	var dir := aim_point - muzzle
	dir.y = 0.0
	if dir.length_squared() < 0.001:
		dir = Vector3(_survivor.facing.x, 0.05, _survivor.facing.z)
	else:
		dir = dir.normalized()

	var rocket := RocketProjectile.new()
	rocket.velocity = dir.normalized() * float(def.get("speed", 24.0))
	rocket.damage = float(def.get("damage", 120.0))
	rocket.explosion_radius = float(def.get("explosion_radius", 5.0))
	rocket.source_id = _survivor.identity.persistent_id
	rocket.set_meta("shooter", _survivor)
	get_tree().current_scene.add_child(rocket)
	rocket.global_position = muzzle + dir * 0.7
	_muzzle_flash(muzzle)
	if _survivor.has_method(&"notify_attack_anim"):
		_survivor.call(&"notify_attack_anim")
	EventBus.attack_performed.emit(_survivor.global_position)


# --- VFX ---------------------------------------------------------------------

func _spawn_tracer(from: Vector3, to: Vector3, color: Color) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var length := from.distance_to(to)
	if length < 0.2:
		return
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.03, 0.03, length)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	scene.add_child(mi)
	mi.global_position = (from + to) * 0.5
	mi.look_at(to, Vector3.UP)
	var tween := mi.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.09)
	tween.tween_callback(mi.queue_free)


func _muzzle_flash(at: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.85, 0.5)
	flash.light_energy = 3.0
	flash.omni_range = 7.0
	flash.position = at
	scene.add_child(flash)
	var tween := flash.create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.06)
	tween.tween_callback(flash.queue_free)
