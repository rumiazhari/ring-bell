class_name EnvironmentPrecipitation
extends Node3D
## Camera-local precipitation for the Ring Bell environment subsystem.
##
## ONE rain emitter, not a city-wide one: a 44 x 30 x 44 m box that is
## recentred on the active camera every frame and emits `budget` streaks, where
## the budget is the weather model's precipitation level times a quality-scaled
## cap.  `local_coords` is false, so the streaks live in world space and the box
## can follow the camera without rain sliding along with it.
##
## Determinism: precipitation intensity is 100% weather-model driven, so the
## amount of rain in the world is reproducible.  Per-particle jitter is
## cosmetic (Godot's particle RNG is not world state) and nothing in the save
## file is derived from it - that is the documented line for success
## criterion 9.
##
## Cost: one CPUParticles3D, `fixed_fps` capped by quality, amount quantised
## so the particle buffer is not reallocated every frame, and the emitter is
## fully disabled (amount 0, invisible) when there is no rain.

var _rain: CPUParticles3D
var _quad: QuadMesh
var _material: StandardMaterial3D

var _quality := EnvironmentConfig.Quality.MEDIUM
var _amount_step := 120
var _budget := -1
var _emitting := false
var _precipitation := 0.0
var _shelter := 0.0
var _effective := 0.0
var _storm := 0.0
var _last_camera := Vector3.ZERO
var _has_camera := false
var _enabled := true


func _init() -> void:
	name = "EnvironmentPrecipitation"


func _ready() -> void:
	_build()


# --------------------------------------------------------------------- build
func _build() -> void:
	if _rain != null:
		return
	_amount_step = maxi(60, EnvironmentConfig.rain_amount(_quality) / 12)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	# Velocity-aligned billboard: facing the camera, but tilted along the particle's
	# own velocity, so wind-driven rain reads as slanted, not as vertical bars.
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_material.billboard_keep_scale = true
	_material.disable_receive_shadows = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = EnvironmentConfig.RAIN_COLOR

	_quad = QuadMesh.new()
	_quad.size = Vector2(EnvironmentConfig.RAIN_STREAK_WIDTH, EnvironmentConfig.RAIN_STREAK_LENGTH)
	_quad.material = _material

	_rain = CPUParticles3D.new()
	_rain.name = "RainStreaks"
	_rain.mesh = _quad
	# Parked, not empty: the engine rejects `amount = 0`, so a silent emitter
	# keeps one budget step allocated and `emitting = false`.
	_rain.amount = _amount_step
	_rain.lifetime = EnvironmentConfig.RAIN_LIFETIME
	_rain.fixed_fps = EnvironmentConfig.rain_fixed_fps(_quality)
	_rain.fract_delta = false
	_rain.local_coords = false
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(
			EnvironmentConfig.RAIN_BOX_METERS * 0.5,
			EnvironmentConfig.RAIN_BOX_HEIGHT * 0.5,
			EnvironmentConfig.RAIN_BOX_METERS * 0.5)
	_rain.direction = Vector3(0.0, -1.0, 0.0)
	_rain.spread = 0.0
	_rain.initial_velocity_min = 0.0
	_rain.initial_velocity_max = 0.0
	_rain.gravity = Vector3(0.0, -EnvironmentConfig.RAIN_FALL_SPEED, 0.0)
	# Align each streak with its own velocity: a slanted fall drawn as a vertical
	# bar still reads as vertical, which is what "rain ignores the wind" looks like.
	_rain.particle_flag_align_y = true
	_rain.scale_amount_min = 1.0
	_rain.scale_amount_max = 1.0
	_rain.color = Color.WHITE
	_rain.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_rain.extra_cull_margin = EnvironmentConfig.RAIN_BOX_METERS
	_rain.visibility_aabb = AABB(Vector3(-30.0, -24.0, -30.0), Vector3(60.0, 48.0, 60.0))
	_rain.emitting = false
	_rain.visible = false
	add_child(_rain)


# ------------------------------------------------------------------ settings
func set_quality(quality: int) -> void:
	_quality = clampi(quality, 0, EnvironmentConfig.Quality.HIGH)
	if _rain == null:
		return
	_rain.fixed_fps = EnvironmentConfig.rain_fixed_fps(_quality)
	_amount_step = maxi(60, EnvironmentConfig.rain_amount(_quality) / 12)
	_budget = -1          # force a re-apply on the next frame


# --------------------------------------------------------------------- frame
## `precipitation` and `storm` are 0..1 weather parameters, `wind` is the world
## wind vector in m/s and `shelter` is 0 (open sky) .. 1 (roofed).
func update_frame(delta: float, camera: Camera3D, precipitation: float,
		storm: float, wind: Vector3, shelter: float) -> void:
	if _rain == null:
		_build()
		if _rain == null:
			return
	if not _enabled:
		# Debug/quality switch: the emitter node stays, it just never rains.
		if _emitting or _rain.visible:
			_emitting = false
			_rain.emitting = false
			_rain.visible = false
		_budget = -1
		return
	_precipitation = clampf(precipitation, 0.0, 1.0)
	_storm = clampf(storm, 0.0, 1.0)
	_shelter = clampf(shelter, 0.0, 1.0)
	_effective = _precipitation * (1.0 - _shelter * EnvironmentConfig.SHELTER_RAIN_REDUCTION)

	if camera != null and camera.is_inside_tree():
		_last_camera = camera.global_position
		_has_camera = true
		global_position = _last_camera
		_rain.global_position = _last_camera + Vector3(0.0, EnvironmentConfig.RAIN_BOX_LIFT, 0.0)

	var want := _effective > EnvironmentConfig.RAIN_MIN_PRECIPITATION
	if want != _emitting:
		_emitting = want
		_rain.emitting = want
		_rain.visible = want
	if not want:
		if _budget != 0:
			_budget = 0
			_rain.amount = _amount_step
		return

	var budget := EnvironmentConfig.rain_particle_budget(_quality, _effective)
	budget = (budget / _amount_step) * _amount_step
	if budget != _budget:
		_budget = budget
		_rain.amount = maxi(budget, _amount_step)

	# Wind bends the fall; a storm falls harder and reads colder.
	var bend := EnvironmentConfig.RAIN_WIND_FACTOR
	var fall := EnvironmentConfig.RAIN_FALL_SPEED * lerpf(0.86, 1.22, _storm)
	_rain.gravity = Vector3(wind.x * bend, -fall, wind.z * bend)
	_material.albedo_color = EnvironmentConfig.RAIN_COLOR.lerp(
			EnvironmentConfig.RAIN_COLOR_STORM, _storm)


func set_enabled(value: bool) -> void:
	_enabled = value
	if _rain == null:
		return
	if not value:
		_budget = 0
		_emitting = false
		_rain.amount = _amount_step
		_rain.emitting = false
		_rain.visible = false
	else:
		# Re-arm: the next update_frame recomputes the budget from scratch.
		_budget = -1


func is_enabled() -> bool:
	return _enabled


# --------------------------------------------------------------------- status
func active_particles() -> int:
	if _rain == null or not _emitting:
		return 0
	return int(_rain.amount)


func is_raining() -> bool:
	return _emitting


func state() -> Dictionary:
	return {
		"emitting": _emitting,
		"particles": active_particles(),
		"precipitation": snappedf(_precipitation, 0.001),
		"effective": snappedf(_effective, 0.001),
		"shelter": snappedf(_shelter, 0.001),
		"storm": snappedf(_storm, 0.001),
		"quality": EnvironmentConfig.quality_name(_quality),
		"camera_following": _has_camera,
	}
