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
## CAMERA COLLISION: the rig is an elevated boom (6-26 m back and up), so in a
## dense city the lens ends up INSIDE a building - the player then sees the
## interior face of that roof/floor slab filling the whole frame ("a giant flat
## slab across the view, no supports, clipping the neighbour"). Pull the boom in
## to the first solid hit so the lens always has clear line of sight back to the
## player. Exposed as RB_CAM_COLLIDE=0 for A/B captures.
const COLLIDE_MARGIN := 0.45       # keep the lens this far off the hit surface
const MIN_COLLIDE_DISTANCE := 1.8  # never collapse the lens into the player
const COLLIDE_ORIGIN_H := 1.05     # ray leaves the player's chest, not their feet
const COLLIDE_SNAP_IN := true      # shrink instantly, ease back out
const COLLIDE_GROW_SPEED := 6.0

var target: Node3D = null

var _yaw := 0.0
# P0-5 SEPARATE ZOOM STATES: `_user_distance` is the player's requested
# boom length (mouse wheel); `_presentation_distance` is what the camera
# actually renders RIGHT NOW. Interior mode pulls the PRESENTATION in to
# INTERIOR_DISTANCE but never writes over the user's preference, so
# leaving a building eases back out to exactly where they had it.
var _user_distance := DEFAULT_DISTANCE
var _presentation_distance := DEFAULT_DISTANCE
## Collision-clamped length of the boom right now. `_presentation_distance` is
## the presentation the mode (interior/exterior) asks for; `_boom` is what
## actually renders once buildings/terrain are taken into account.
var _boom := DEFAULT_DISTANCE
var _collide := true               # RB_CAM_COLLIDE=0 disables (A/B capture)
var _pitch := PITCH_DEG
var _interior := false
var _shake := 0.0
var _camera: Camera3D
var _cam_base := Vector3.ZERO      # un-shaken boom position


func _ready() -> void:
	add_to_group(&"camera_rig")
	_collide = OS.get_environment("RB_CAM_COLLIDE") != "0"
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
	_boom = _resolve_boom_length()
	_cam_base = _boom_dir_local() * _boom
	_camera.position = _cam_base


## Rig-local unit direction from the target to the lens, at the current pitch.
func _boom_dir_local() -> Vector3:
	return Vector3(0, 0, 1).rotated(Vector3.RIGHT, deg_to_rad(_pitch))


## Length the boom wants before collision (the mode's presentation, clamped to
## the user's zoom limits).
func _wanted_boom_length() -> float:
	return clampf(_presentation_distance, MIN_DISTANCE, MAX_DISTANCE)


## Boom length that keeps line of sight: cast from the player's chest toward the
## wanted lens position and stop short of the first solid hit. Without this the
## lens sits inside roofs/facades and the player sees a slab filling the frame.
func _resolve_boom_length() -> float:
	var want := _wanted_boom_length()
	if not _collide:
		return want
	var world := get_world_3d()
	if world == null:
		return want
	var space := world.direct_space_state
	if space == null:
		return want
	var origin := global_position + Vector3(0, COLLIDE_ORIGIN_H, 0)
	var wdir := (global_transform.basis * _boom_dir_local()).normalized()
	if wdir.length_squared() < 0.5:
		return want
	var q := PhysicsRayQueryParameters3D.create(
			origin, origin + wdir * (want + COLLIDE_MARGIN))
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var body := target if target is CollisionObject3D else null
	if body != null:
		q.exclude = [body]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return want
	# Indoors the boom aims at the ceiling above the player, and that plane is
	# the storey slab the interior presentation is built around (the cutaway
	# layer). Clamping to it would collapse the interior view into a head cam,
	# so downward-facing hits are ignored while the rig is in interior mode.
	if _interior and (hit["normal"] as Vector3).y < -0.35:
		return want
	var dist := origin.distance_to(hit["position"]) - COLLIDE_MARGIN
	return clampf(dist, MIN_COLLIDE_DISTANCE, want)


## P0-4: world position of the ACTUAL Camera3D lens (not the player-follow
## rig origin) - facade sector logic must look from where the view really is.
func camera_world_position() -> Vector3:
	if _camera != null and is_instance_valid(_camera):
		return _camera.global_position
	return global_position


## P0-4: unit XZ direction from the rig target toward the actual camera.
## This is "where the viewer stands relative to the player", the input the
## interior cutaway needs to decide which facade(s) to fade. Zero only when
## no target/camera exists yet.
func horizontal_view_direction() -> Vector2:
	if _camera == null or not is_instance_valid(_camera):
		return Vector2.ZERO
	var d := _camera.global_position - global_position
	var flat := Vector2(d.x, d.z)
	if flat.length_squared() < 0.0001:
		return Vector2.ZERO
	return flat.normalized()


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


## Re-resolve the boom every frame: the player moves, so a length with clear
## line of sight one frame can be inside a roof slab the next. Snap IN at once
## (never render from inside a wall) and ease back OUT so the view recovers
## smoothly when the player steps clear.
func _update_boom(delta: float) -> void:
	var want := _resolve_boom_length()
	if want < _boom or not COLLIDE_SNAP_IN:
		_boom = want
	elif not is_equal_approx(want, _boom):
		_boom = lerpf(_boom, want, 1.0 - exp(-COLLIDE_GROW_SPEED * delta))
	_cam_base = _boom_dir_local() * _boom
	if _shake <= 0.003:
		_camera.position = _cam_base


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
	_update_boom(delta)

	# Ease pitch AND distance toward the interior or exterior presentation
	# with the SAME exponential blend: no zoom pop at the doorway - the boom
	# shortens smoothly while the view steepens. Interior only ever CLAMPS
	# the presentation; `_user_distance` keeps the player's zoom preference.
	var target_pitch := INTERIOR_PITCH_DEG if _interior else PITCH_DEG
	var target_dist: float = minf(_user_distance, INTERIOR_DISTANCE) \
			if _interior else _user_distance
	if not is_equal_approx(_pitch, target_pitch) \
			or not is_equal_approx(_presentation_distance, target_dist):
		var blend := 1.0 - exp(-PRESENT_SPEED * delta)
		_pitch = lerpf(_pitch, target_pitch, blend)
		_presentation_distance = lerpf(
				_presentation_distance, target_dist, blend)
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
				_user_distance = clampf(_user_distance - ZOOM_STEP,
						MIN_DISTANCE, MAX_DISTANCE)
				_apply_camera_transform()
			MOUSE_BUTTON_WHEEL_DOWN:
				_user_distance = clampf(_user_distance + ZOOM_STEP,
						MIN_DISTANCE, MAX_DISTANCE)
				_apply_camera_transform()
