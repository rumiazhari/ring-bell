class_name RocketProjectile
extends Node3D
## Slow-ish rocket with a smoke trail; detonates on the first thing it
## touches and hands the blast to DebrisManager (radius damage, radial
## impulses, structural erosion by material, camera shake).
##
## Movement is a swept ray per physics tick so it can never tunnel through
## a thin wall at speed.

const LIFETIME := 4.0

var velocity := Vector3.ZERO
var damage := 130.0
var explosion_radius := 5.5
var source_id: StringName = &"player"

var _age := 0.0
var _dead := false


func _ready() -> void:
	var mesh_instance := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.09
	capsule.height = 0.5
	mesh_instance.mesh = capsule
	mesh_instance.rotation_degrees.x = 90.0   # align long axis with -Z travel
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.72, 0.66)
	mat.metallic = 0.6
	mat.roughness = 0.4
	mesh_instance.material_override = mat
	add_child(mesh_instance)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 1.6
	light.omni_range = 6.0
	add_child(light)

	# Smoke trail rides along and dies with the rocket - no debris budget.
	var trail := CPUParticles3D.new()
	trail.amount = 90
	trail.lifetime = 0.7
	trail.mesh = _trail_mesh()
	trail.direction = Vector3(0, 0, 1)      # opposite of -Z travel
	trail.spread = 12.0
	trail.initial_velocity_min = 1.2
	trail.initial_velocity_max = 2.4
	trail.gravity = Vector3(0, 0.8, 0)
	trail.scale_amount_min = 0.5
	trail.scale_amount_max = 1.4
	trail.color = Color(0.45, 0.43, 0.41, 0.85)
	add_child(trail)


func _trail_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.09
	sphere.height = 0.18
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.5, 0.48, 0.46, 0.8)
	sphere.material = mat
	return sphere


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_age += delta
	if _age >= LIFETIME:
		_detonate()
		return

	var from := global_position
	# Slight drop over distance - reads as a real projectile in top-down view.
	velocity.y -= 2.2 * delta
	var motion := velocity * delta

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			from, from + motion, 1 | 2 | 4)
	query.exclude = [source_excluded_rid()]
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit["position"]
		_detonate()
		return

	global_position = from + motion
	rotation.y = atan2(velocity.x, velocity.z)


func source_excluded_rid() -> RID:
	var shooter: Node = get_meta("shooter", null)
	if shooter is CollisionObject3D:
		return (shooter as CollisionObject3D).get_rid()
	return RID()


func _detonate() -> void:
	if _dead:
		return
	_dead = true
	DebrisManager.explosion(global_position, explosion_radius, damage,
			source_id)
	queue_free()
