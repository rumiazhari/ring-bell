class_name CorpseBody
extends RigidBody3D
## Havoc-physics corpse: the dead actor's actual HumanoidModel is adopted
## (reparented) so what hits the ground is the BODY, not a bare capsule.
## It tumbles from the killing impulse, falls under gravity, bounces and
## settles where physics puts it - then fades out so battlefields stay clean.
##
## Usage:
##   corpse.global_position = actor_pos
##   corpse.take_visual(actor_model_root)
##   corpse.launch(impulse)

const LIFETIME := 14.0

var _age := 0.0
var _fading := false
var _model_scale := 1.0


## Adopt the dying actor's model node. Its animator is frozen so the last
## pose is preserved; collision shapes are sized from the model scale.
func take_visual(model: Node3D) -> void:
	_model_scale = model.scale.y
	var parent := model.get_parent()
	if parent != null:
		parent.remove_child(model)
	for child in model.get_children():
		if child is HumanoidAnimator:
			child.stop()
	# Freeze cloth sims so the last drape is preserved on the corpse.
	for mesh in HumanoidModel.collect_meshes(model):
		if mesh is SkirtCloth:
			(mesh as SkirtCloth).set_simulating(false)
	add_child(model)
	model.position = Vector3.ZERO
	model.rotation = Vector3.ZERO
	name = "Corpse"


## Add approximate body collision, then apply the killing blow as a damped
## launch impulse plus tumble torque.
func launch(impulse: Vector3) -> void:
	add_to_group(&"corpses")
	mass = 32.0
	collision_layer = 16          # debris layer: never blocks gameplay rays
	collision_mask = 1 | 2 | 4 | 16
	can_sleep = true
	linear_damp = 0.25
	angular_damp = 1.4

	var s := _model_scale
	var torso := CollisionShape3D.new()
	var torso_box := BoxShape3D.new()
	torso_box.size = Vector3(0.62, 1.05, 0.45) * s
	torso.shape = torso_box
	torso.position = Vector3(0, 0.95 * s, 0)
	add_child(torso)

	var head := CollisionShape3D.new()
	var head_sphere := SphereShape3D.new()
	head_sphere.radius = 0.19 * s
	head.shape = head_sphere
	head.position = Vector3(0, 1.68 * s, 0.02 * s)
	add_child(head)

	# Damped delta-v: crumple toward the hit, never rocket away.
	apply_central_impulse(impulse * mass * 0.4)
	apply_torque_impulse(Vector3(
			randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1))
			* mass * 0.35)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME and not _fading:
		_fading = true
		set_physics_process(false)
		# Freeze BEFORE scaling: shrinking a live RigidBody3D resizes its
		# collision shapes mid-simulation (solver glitches).
		freeze = true
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector3.ONE * 0.05, 1.0)\
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(queue_free)
