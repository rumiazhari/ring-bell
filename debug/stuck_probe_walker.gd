extends CharacterBody3D
## Lightweight stand-in for Survivor used by the stair/step wedge audit.
##
## It replicates Survivor's *movement contract* exactly (capsule 0.35 x 1.7,
## WALK 3.6, ACCELERATION 12, GRAVITY 18, floor_max_angle 46 deg,
## floor_snap_length 0.3, mask = environment | zombies) but skips the humanoid
## skeleton, animator, needs and parkour stack. The audit needs tens of
## thousands of physics steps, and the parkour layer is exercised separately by
## --stairstucktest with RB_STUCK_BODY=survivor.

const WALK_SPEED := 3.6
const ACCELERATION := 12.0
const GRAVITY := 18.0
const ENV_LAYER := 1
const ZOMBIE_LAYER := 4

var move_dir := Vector3.ZERO


func _init() -> void:
	collision_layer = 2
	collision_mask = ENV_LAYER | ZOMBIE_LAYER
	up_direction = Vector3.UP
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.3
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position = Vector3(0, 0.85, 0)
	add_child(shape)


func _physics_process(delta: float) -> void:
	var target := move_dir * WALK_SPEED
	var blend := 1.0 - exp(-ACCELERATION * delta)
	velocity.x = lerpf(velocity.x, target.x, blend)
	velocity.z = lerpf(velocity.z, target.z, blend)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
	move_and_slide()
