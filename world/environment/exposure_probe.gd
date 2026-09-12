class_name EnvironmentExposureProbe
extends Node
## "Am I under a roof?" - the indoor/outdoor hook for the environment.
##
## This is deliberately the smallest possible interface into the building world:
## three short raycasts against the physics world, throttled to
## `SHELTER_PROBE_INTERVAL`, smoothed, and nothing else.  It never reads, edits
## or rebuilds interiors, roofs, rooms or buildings (see the isolation mandate in
## .hermes/autopilot/ENVIRONMENT_OVERHAUL.md).
##
## Anything that wants the answer - rain particles, exterior ambience, future
## acoustic or wetness work - asks the environment manager for `exposure`
## instead of probing for itself, so the raycast cost stays constant whether one
## or ten systems care about shelter.

var exposure := 0.0   ## 0 == outdoors, 1 == fully sheltered (smoothed)
var _raw := 0.0
var _timer := 0.0
var _enabled := true
var _forced := -1.0   ## debug override; < 0 == use the physics probe
var _samples := 0
var _hits := 0
var _last_origin := Vector3.ZERO

const _RAY_DIRECTIONS: Array[Vector3] = [
	Vector3(0.0, 1.0, 0.0),
	Vector3(0.55, 1.0, 0.0),
	Vector3(-0.40, 1.0, 0.55),
]


func _init() -> void:
	name = "ExposureProbe"


func set_enabled(value: bool) -> void:
	_enabled = value
	if not value:
		exposure = 0.0
		_raw = 0.0


## Debug/test override.  `value` < 0 restores the physics probe.
func force(value: float) -> void:
	_forced = value
	if value >= 0.0:
		_raw = clampf(value, 0.0, 1.0)
		exposure = _raw


func is_sheltered() -> bool:
	return exposure >= EnvironmentConfig.SHELTER_INDOOR_THRESHOLD


## Called by the environment manager every frame with the player position (or
## the camera when no player exists yet).
func update_frame(delta: float, origin: Vector3, world: World3D) -> void:
	if not _enabled:
		exposure = 0.0
		_raw = 0.0
		return
	if _forced >= 0.0:
		exposure = _raw
		return
	_last_origin = origin
	_timer -= delta
	if _timer <= 0.0:
		_timer = EnvironmentConfig.SHELTER_PROBE_INTERVAL
		var result := _sample(origin, world)
		_raw = result
	_samples += 1
	exposure = lerpf(exposure, _raw, clampf(delta * EnvironmentConfig.SHELTER_SMOOTHING, 0.0, 1.0))


func _sample(origin: Vector3, world: World3D) -> float:
	if world == null:
		return 0.0
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var hits := 0
	for dir: Vector3 in _RAY_DIRECTIONS:
		if _ray(space, origin, dir.normalized()):
			hits += 1
	_hits = hits
	if hits <= 0:
		return 0.0
	# One hit == partial cover (an awning, a bridge, a doorway); two or more
	# overlapping hits == a real ceiling.  Clamped, so any of the three rays
	# already counts as meaningfully sheltered.
	return clampf(float(hits) / 1.5, 0.0, 1.0)


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
			from, from + dir * EnvironmentConfig.SHELTER_PROBE_DISTANCE)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := space.intersect_ray(query)
	return not hit.is_empty()


func state() -> Dictionary:
	return {
		"exposure": snappedf(exposure, 0.001),
		"raw": snappedf(_raw, 0.001),
		"sheltered": is_sheltered(),
		"forced": _forced >= 0.0,
		"rays_last_sample": _hits,
		"origin": _last_origin,
	}
