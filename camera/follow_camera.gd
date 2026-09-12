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
## INTERIOR SHELL EXEMPTION: the geometry of the building the player is standing
## in is the layer the interior presentation CUTS AWAY from the camera, so the
## boom has to see through it rather than clamp to it (see _resolve_boom_length).
const SHELL_MAX_SKIP := 4          # in-shell faces one boom length may cross
const SHELL_SLIP_M := 0.04         # step past a skipped face before re-casting
const SHELL_INSET_M := 0.02        # a party wall stays the NEIGHBOUR's face
const SHELL_WALL_NORMAL_Y := 0.5   # |normal.y| below this = a VERTICAL face
const SHELL_FLAT_NORMAL_Y := -0.35 # legacy "downward" test, shell-less callers

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
## Footprint band of the building the player is standing in, handed over by the
## world (CityInteriorState.shell_of) while interior mode is active: the
## plan-space rect, the yaw that rotates it into the world, and the building's
## vertical extent in world Y. Empty means "unknown", which falls back to the
## pre-shell behaviour.
var _shell_rect := Rect2()
var _shell_yaw := 0.0
var _shell_y := Vector2.ZERO
## RB_CAM_SHELL_OFF=1 replays the pre-shell rule for A/B captures: in-shell faces
## are then judged only by their normal (the behaviour the exemption replaced).
var _shell_ab := false
var _shake := 0.0
var _camera: Camera3D
var _cam_base := Vector3.ZERO      # un-shaken boom position


func _ready() -> void:
	add_to_group(&"camera_rig")
	_collide = OS.get_environment("RB_CAM_COLLIDE") != "0"
	_shell_ab = OS.get_environment("RB_CAM_SHELL_OFF") == "1"
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
## wanted lens position and stop short of the first SOLID hit. Without this the
## lens sits inside roofs/facades and the player sees a slab filling the frame.
##
## The one exception is the building the player is STANDING IN. Its geometry is
## the interior presentation's cutaway layer - the world hides the pieces between
## the camera and the player (collision and shadows stay) - so clamping to it
## means clamping to something the player cannot even see. That is what made the
## view pump in and out while walking near a wall indoors: the boom collapsed
## onto the hidden facade (~1.8 m) for as long as the ray grazed it, and sprang
## straight back to the interior length the moment it did not. Faces landing
## inside the player's own footprint band are therefore stepped over; the first
## face of any OTHER building still stops the boom.
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
	var q := PhysicsRayQueryParameters3D.create(origin, origin + wdir * want)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var body := target if target is CollisionObject3D else null
	if body != null:
		q.exclude = [body]
	var reach := want + COLLIDE_MARGIN
	var from := origin
	var steps := 0
	for _step in range(SHELL_MAX_SKIP + 1):
		var travel := reach - from.distance_to(origin)
		if travel <= 0.05:
			break
		q.from = from
		q.to = from + wdir * travel
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return want
		var hp: Vector3 = hit["position"]
		if _skippable(hit, hp):
			from = hp + wdir * SHELL_SLIP_M
			steps += 1
			continue
		# Legacy rule (no footprint handed over, or RB_CAM_SHELL_OFF=1 A/B): keep
		# forgiving the storey slab above the player's head, as this used to.
		if _interior and (_shell_ab or _shell_rect.size.x <= 0.0) \
				and (hit["normal"] as Vector3).y < SHELL_FLAT_NORMAL_Y:
			return want
		var d := origin.distance_to(hp)
		var clamped := clampf(d - COLLIDE_MARGIN, MIN_COLLIDE_DISTANCE, want)
		_shell_diag(hit, hp, d, want, clamped, steps)
		return clamped
	return want


## RB_CAM_SHELL_DIAG=1 names the face that stopped the boom and why the shell
## exemption did not step over it: the attribution step when an interior clamp
## has no face the player can see.
func _shell_diag(hit: Dictionary, hp: Vector3, d: float, want: float,
		boom: float, steps: int) -> void:
	if OS.get_environment("RB_CAM_SHELL_DIAG") == "":
		return
	var coll: Variant = hit.get("collider")
	var ny := (hit["normal"] as Vector3).y
	var local := CityPlan._rotate_plan_point(_shell_rect.get_center(),
			Vector2(hp.x, hp.z), -_shell_yaw)
	var inset := SHELL_INSET_M if absf(ny) < SHELL_WALL_NORMAL_Y else 0.0
	print("[CamShellDiag] boom=%.2f want=%.2f yaw=%.3f d=%.2f n_y=%.2f in_shell=%s ab=%s steps=%d interior=%s local=%s rect=%s inset=%.2f inside=%s band=%s y=%.2f coll=%s" % [
			boom, want, _yaw, d, ny,
			str(_hit_in_shell(hp, ny)), str(_shell_ab), steps, str(_interior),
			"%.2f,%.2f" % [local.x, local.y], str(_shell_rect), inset,
			str(_shell_rect.grow(-inset).has_point(local)), str(_shell_y), hp.y,
			coll.get_class() if coll is Object else "null"])


## A face the boom may look through because the interior presentation already
## cuts it away: inside the player's own footprint band AND static world
## geometry. A body inside the shell (prop, actor) still blocks the lens.
func _skippable(hit: Dictionary, hp: Vector3) -> bool:
	if _shell_ab or not _hit_in_shell(hp, (hit["normal"] as Vector3).y):
		return false
	var collider: Variant = hit.get("collider")
	return collider == null or collider is StaticBody3D


## Is this world-space hit inside the footprint band of the building the player
## is in? Faces lying exactly ON the boundary are ambiguous - the party wall
## shared with the neighbour lives there and is NOT cut away, so it must still
## stop the boom - but so does the player's own slab where it meets its own
## wall. The normal settles it: a VERTICAL face on the boundary is that party
## wall (inset a hair, so it keeps blocking); a FLAT one is the room's own
## ceiling/slab corner (no inset - it is the shell the cutaway hides).
func _hit_in_shell(p: Vector3, normal_y: float) -> bool:
	if _shell_rect.size.x <= 0.0 or _shell_rect.size.y <= 0.0:
		return false
	if p.y < _shell_y.x or p.y > _shell_y.y:
		return false
	# Back into the footprint's own plan frame the way world/main.gd does it,
	# through the same helper that built the transform (-yaw is the inverse).
	var local := CityPlan._rotate_plan_point(_shell_rect.get_center(),
			Vector2(p.x, p.z), -_shell_yaw)
	var inset := SHELL_INSET_M if absf(normal_y) < SHELL_WALL_NORMAL_Y else 0.0
	return _shell_rect.grow(-inset).has_point(local)


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
	if not interior:
		clear_interior_shell()


## The world hands the rig the footprint band of the building the player is
## inside so the boom can look THROUGH the cutaway layer instead of clamping to
## it. An empty/degenerate rect withdraws it.
func set_interior_shell(rect: Rect2, yaw: float, y_band: Vector2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0 or y_band.y <= y_band.x:
		clear_interior_shell()
		return
	_shell_rect = rect
	_shell_yaw = yaw
	_shell_y = y_band


func clear_interior_shell() -> void:
	_shell_rect = Rect2()
	_shell_yaw = 0.0
	_shell_y = Vector2.ZERO


## Footprint band currently exempted from boom collision (empty = none).
func interior_shell_rect() -> Rect2:
	return _shell_rect


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
