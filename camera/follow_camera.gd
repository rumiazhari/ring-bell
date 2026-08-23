class_name FollowCamera
extends Node3D
## Elevated rotatable top-down camera rig (Divinity/BG3 style presentation).
##
## - Smoothly follows its target node (the player survivor).
## - Q / R keys or right-mouse drag rotate yaw; mouse wheel zooms.
## - Pitch fixed inside the 35-55 degree design window (-52 deg here).
## - Registers itself in group "camera_rig"; PlayerController reads its yaw
##   so movement stays camera-relative.

const PITCH_DEG := -52.0
const MIN_DISTANCE := 8.0
const MAX_DISTANCE := 26.0
const DEFAULT_DISTANCE := 16.0
const FOLLOW_SPEED := 7.0          # higher = snappier follow
const KEY_ROTATE_SPEED := 2.4      # rad/s with Q/R
const DRAG_SENSITIVITY := 0.0055
const ZOOM_STEP := 1.0

var target: Node3D = null

var _yaw := 0.0
var _distance := DEFAULT_DISTANCE
var _camera: Camera3D


func _ready() -> void:
	add_to_group(&"camera_rig")
	_camera = Camera3D.new()
	_camera.fov = 55.0
	add_child(_camera)
	_apply_camera_transform()
	_camera.current = true


## Places the camera UP and BACK along its own viewing axis so the rig target
## stays centered. With PITCH_DEG = -52 this puts the lens ~0.79*distance
## above ground and ~0.62*distance behind - a real crane shot, NOT at ground
## level (a flat +Z offset would put the camera at y~0 and half the frustum
## under the terrain, rendering nothing but the sky clear color).
func _apply_camera_transform() -> void:
	_camera.rotation_degrees = Vector3(PITCH_DEG, 0, 0)
	var boom := Vector3(0, 0, 1).rotated(Vector3.RIGHT, deg_to_rad(PITCH_DEG))
	_camera.position = boom * _distance


## Point the rig at a new target and snap there immediately (no lerp glide).
func set_target(new_target: Node3D) -> void:
	target = new_target
	if target != null:
		global_position = target.global_position


func _process(delta: float) -> void:
	if Input.is_action_pressed(&"camera_rotate_left"):
		_yaw += KEY_ROTATE_SPEED * delta
	if Input.is_action_pressed(&"camera_rotate_right"):
		_yaw -= KEY_ROTATE_SPEED * delta

	if target != null and is_instance_valid(target):
		var blend := 1.0 - exp(-FOLLOW_SPEED * delta)
		var desired := target.global_position
		desired.y = 0.0
		global_position = global_position.lerp(desired, blend)
	rotation.y = _yaw


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		_yaw -= event.relative.x * DRAG_SENSITIVITY
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clampf(_distance - ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
				_apply_zoom()
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clampf(_distance + ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
				_apply_zoom()


func _apply_zoom() -> void:
	_apply_camera_transform()
