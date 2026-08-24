class_name DebrisPiece
extends RigidBody3D
## One voxel-like fragment of a destroyed object.
##
## A real physics body: gravity makes it fall, collisions pile it up, and
## explosion impulses bounce it away. Pieces live briefly (DebrisManager
## owns the cap and the fade-out) so long battles cannot flood the scene.

var _lifetime := 0.0
var _life_seconds := 7.0
var _dying := false


func setup(size: Vector3, color: Color, material_id: StringName,
		impulse: Vector3) -> void:
	var clamped := size.clamp(Vector3.ONE * 0.07, Vector3.ONE * 1.4)
	mass = maxf(0.15, clamped.x * clamped.y * clamped.z
			* float(MaterialDB.get_material(material_id).get("density", 1.0)))

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = clamped
	mesh_instance.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mesh_instance.material_override = mat
	add_child(mesh_instance)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = clamped
	shape.shape = box_shape
	add_child(shape)

	apply_central_impulse(impulse)
	apply_torque_impulse(Vector3(
			randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
			* mass * 0.35)


func _ready() -> void:
	collision_layer = 16          # debris
	collision_mask = 1 | 2 | 4    # environment | survivors | zombies (no debris-debris)
	can_sleep = true
	linear_damp = 0.25
	angular_damp = 0.6
	_life_seconds = randf_range(5.5, 9.0)


func _physics_process(delta: float) -> void:
	_lifetime += delta
	if _lifetime >= _life_seconds and not _dying:
		_dying = true
		set_physics_process(false)
		# Freeze BEFORE scaling: tweening the scale of a live RigidBody3D
		# resizes its collision shapes mid-simulation (solver glitches).
		freeze = true
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector3.ONE * 0.05, 0.6)\
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(queue_free)
