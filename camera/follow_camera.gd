class_name FollowCamera
extends Node3D
## Elevated rotatable top-down camera rig (Divinity/BG3 style presentation).
##
## - Smoothly follows its target node in FULL 3D: X/Z and Y all track the
##   player, so climbing stairs raises the rig instead of leaving the player
##   glued to ground level.
## - Q / R keys or right-mouse drag rotate yaw; mouse wheel zooms.
## - Interior mode (set_interior): steeper pitch + shorter boom so rooms
##   read clearly while roof dressing is hidden by the world layer.
## - add_shake: explosion kick, decays automatically.
## - ground_point_under_mouse: screen cursor -> world aim point for guns.
##
## Registers itself in group "camera_rig"; PlayerController reads its yaw
## so movement stays camera-relative.

const PITCH_DEG := -52.0
const INTERIOR_PITCH_DEG := -66.0
const MIN_DISTANCE := 6.0
const MAX_DISTANCE := 26.0
const DEFAULT_DISTANCE := 16.0
const INTERIOR_DISTANCE := 9.0
const FOLLOW_SPEED := 7.0          # higher = snappier follow
const VERTICAL_SPEED := 9.0        # stairs should feel attached
const KEY_ROTATE_SPEED := 2.4      # rad/s with Q/R
const DRAG_SENSITIVITY := 0.0055
const ZOOM_STEP := 1.0
const PRESENT_SPEED := 5.0         # interior/exterior blend rate (pitch AND distance)

var target: Node3D = null

var _yaw := 0.0
var _distance := DEFAULT_DISTANCE
var _pitch := PITCH_DEG
var _interior := false
var _shake := 0.0
var _camera: Camera3D
var _cam_base := Vector3.ZERO      # un-shaken boom position


func _ready() -> void:
	add_to_group(&"camera_rig")
	_camera = Camera3D.new()
	_camera.fov = 55.0
	add_child(_camera)
	_apply_camera_transform()
	_camera.current = true


## Places the camera UP and BACK along its own viewing axis so the rig target
## stays centered. The boom uses the CURRENT blended pitch and distance, so
## interior transitions glide instead of snapping.
func _apply_camera_transform() -> void:
	_camera.rotation_degrees = Vector3(_pitch, 0, 0)
	var boom := Vector3(0, 0, 1).rotated(Vector3.RIGHT, deg_to_rad(_pitch))
	_cam_base = boom * _distance
	_camera.position = _cam_base


## Point the rig at a new target and snap there immediately (no lerp glide).
func set_target(new_target: Node3D) -> void:
	target = new_target
	if target != null:
		global_position = target.global_position


## World toggles this when the player steps inside a building footprint:
## steeper angle + tighter boom reads interiors much better.
func set_interior(interior: bool) -> void:
	if _interior == interior:
		return
	_interior = interior


func is_interior() -> bool:
	return _interior


## Explosion feedback; decays every frame.
func add_shake(amount: float) -> void:
	_shake = minf(_shake + amount, 1.2)


## Screen cursor projected onto a horizontal plane at `plane_y` - the aim
## point for firearms (PlayerController feeds this to WeaponSystem).
func ground_point_under_mouse(plane_y: float) -> Vector3:
	var vp := get_viewport()
	if vp == null or _camera == null:
		return Vector3.ZERO
	var origin := _camera.project_ray_origin(vp.get_mouse_position())
	var normal := _camera.project_ray_normal(vp.get_mouse_position())
	if absf(normal.y) < 0.0001:
		return origin + normal * 20.0
	var t := (plane_y - origin.y) / normal.y
	if t < 0.0:
		t = 0.0
	return origin + normal * t


func _process(delta: float) -> void:
	if Input.is_action_pressed(&"camera_rotate_left"):
		_yaw += KEY_ROTATE_SPEED * delta
	if Input.is_action_pressed(&"camera_rotate_right"):
		_yaw -= KEY_ROTATE_SPEED * delta

	if target != null and is_instance_valid(target):
		var desired := target.global_position
		var blend_xz := 1.0 - exp(-FOLLOW_SPEED * delta)
		var blend_y := 1.0 - exp(-VERTICAL_SPEED * delta)
		global_position.x = lerpf(global_position.x, desired.x, blend_xz)
		global_position.z = lerpf(global_position.z, desired.z, blend_xz)
		global_position.y = lerpf(global_position.y, desired.y, blend_y)

	rotation.y = _yaw

	# Ease pitch AND distance toward the interior or exterior presentation
	# with the SAME exponential blend: no zoom pop at the doorway - the boom
	# shortens smoothly while the view steepens.
	var target_pitch := INTERIOR_PITCH_DEG if _interior else PITCH_DEG
	var target_dist := minf(_distance, INTERIOR_DISTANCE) if _interior \
			else _distance
	if not is_equal_approx(_pitch, target_pitch) \
			or not is_equal_approx(_distance, target_dist):
		var blend := 1.0 - exp(-PRESENT_SPEED * delta)
		_pitch = lerpf(_pitch, target_pitch, blend)
		_distance = lerpf(_distance, target_dist, blend)
		_apply_camera_transform()

	# Explosion shake: jitter the lens around the boom BASE so the offset
	# never accumulates - each frame is base + fresh jitter, and when the
	# shake decays the lens lands exactly back on its boom position.
	if _shake > 0.003:
		_camera.position = _cam_base + Vector3(
				randf_range(-_shake, _shake),
				randf_range(-_shake, _shake),
				randf_range(-_shake, _shake)) * 0.35
		_shake *= exp(-7.0 * delta)
	elif _camera.position != _cam_base:
		_camera.position = _cam_base


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		_yaw -= event.relative.x * DRAG_SENSITIVITY
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clampf(_distance - ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
				_apply_camera_transform()
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clampf(_distance + ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
				_apply_camera_transform()
