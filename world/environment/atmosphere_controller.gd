class_name AtmosphereController
extends Node
## Owns the *look* of the environment: sky, sun/moon lights, ambient light,
## fog, volumetric haze, glow and the lightning flash envelope.
##
## It owns no policy - it never reads the clock or the weather model directly.
## `EnvironmentManager` computes a per-frame state dictionary (time + weather
## derived scalars and directions) and hands it to `apply()`; this controller
## turns that into actual rendering state, writing only what changed.
##
## Replaces the light/environment half of the legacy `DayNightController`
## (which keeps the street-lamp / window-glow gameplay behaviour).
##
## Performance: all values are plain scalars, no per-frame allocation, and
## every `Environment` / shader write is dirty-checked, so an unchanged frame
## is (almost) free.

const SKY_SHADER_PATH := "res://world/environment/shaders/environment_sky.gdshader"

const SUN_NODE_NAME := "EnvironmentSun"
const MOON_NODE_NAME := "EnvironmentMoon"
const ENV_NODE_NAME := "EnvironmentWorldEnv"
const BOLT_NODE_NAME := "EnvironmentLightningBolt"

## Bolt geometry (metres) and how long a strike stays drawn.
const BOLT_SEGMENTS := 9
const BOLT_TOP_HEIGHT := 260.0
const BOLT_MIN_DISTANCE := 220.0
const BOLT_VISIBLE_SECONDS := 0.14


# --- colour anchors (transferred from DayNightController + art direction) ---
const DAY_ZENITH := Color(0.28, 0.44, 0.70)
const DAY_HORIZON := Color(0.63, 0.72, 0.85)
const NIGHT_ZENITH := Color(0.016, 0.024, 0.050)
const NIGHT_HORIZON := Color(0.045, 0.062, 0.110)
const DUSK_ZENITH := Color(0.17, 0.25, 0.45)
const DUSK_HORIZON := Color(0.95, 0.53, 0.29)
const STORM_GREY_DAY := Color(0.27, 0.29, 0.34)
const STORM_GREY_NIGHT := Color(0.058, 0.066, 0.085)
const GROUND_DAY := Color(0.17, 0.18, 0.20)
const GROUND_NIGHT := Color(0.022, 0.026, 0.034)
const HAZE_DAY := Color(0.66, 0.70, 0.76)
const HAZE_DUSK := Color(0.82, 0.55, 0.36)
const HAZE_NIGHT := Color(0.075, 0.092, 0.132)
const SUN_NOON := Color(1.0, 0.97, 0.92)
const SUN_DUSK := Color(1.0, 0.74, 0.52)
const SUN_NIGHT := Color(0.42, 0.52, 0.78)
const MOON_COLOR := Color(0.60, 0.70, 0.96)
const CLOUD_LIT := Color(0.88, 0.90, 0.95)
const CLOUD_DUSK := Color(0.92, 0.66, 0.50)
const CLOUD_SHADOW := Color(0.33, 0.36, 0.43)
const CLOUD_SHADOW_STORM := Color(0.17, 0.18, 0.22)
const AMBIENT_DAY := Color(0.72, 0.76, 0.86)
const AMBIENT_NIGHT := Color(0.44, 0.53, 0.74)
const FLASH_COLOR := Color(0.72, 0.78, 1.0)

const PROCESS_MODE := Sky.PROCESS_MODE_REALTIME

var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _world_env: WorldEnvironment
var _env: Environment
var _sky: Sky
var _sky_mat: ShaderMaterial
var _proc_sky: ProceduralSkyMaterial
var _quality := EnvironmentConfig.Quality.MEDIUM
var _uniforms := {}
var _frames := 0

# lightning flash envelope (real seconds; cosmetic, not simulation state)
var _flash_seq: Array[Vector2] = []
var _flash_index := 0
var _flash_time := 0.0
var _flash_level := 0.0

# lightning bolt mesh (rebuilt per strike)
var _bolt: MeshInstance3D
var _bolt_material: StandardMaterial3D
var _bolt_timer := 0.0


func build(quality: int = EnvironmentConfig.Quality.MEDIUM) -> void:
	_quality = quality
	if _sun != null:
		return

	_sun = DirectionalLight3D.new()
	_sun.name = SUN_NODE_NAME
	_sun.shadow_enabled = true
	_sun.light_energy = 1.0
	add_child(_sun)

	_moon = DirectionalLight3D.new()
	_moon.name = MOON_NODE_NAME
	# The moon is a fill light; shadows off keeps night as cheap as before.
	_moon.shadow_enabled = false
	_moon.light_energy = 0.0
	add_child(_moon)

	_build_bolt()

	_world_env = WorldEnvironment.new()
	_world_env.name = ENV_NODE_NAME
	_env = Environment.new()
	_build_environment()
	_world_env.environment = _env
	add_child(_world_env)


func _build_environment() -> void:
	_env.background_mode = Environment.BG_SKY
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Ambient comes from `ambient_light_color/energy` only - the sky is already
	# a controlled stylised gradient, so the expensive sky-ambient path is off.
	_env.ambient_light_sky_contribution = 0.0
	_env.ambient_light_energy = 0.5
	_env.ambient_light_color = AMBIENT_DAY

	_build_sky()

	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	_env.fog_sky_affect = 0.35
	_env.fog_light_color = Color(0.55, 0.62, 0.78)
	_env.fog_light_energy = 0.18
	_env.fog_density = 0.003

	# Phase V (kept): bloom halo around every bright lamp / window point.
	_env.glow_enabled = true
	_env.glow_intensity = EnvironmentConfig.GLOW_DAY
	_env.glow_strength = EnvironmentConfig.GLOW_STRENGTH
	_env.glow_bloom = EnvironmentConfig.GLOW_BLOOM
	_env.glow_hdr_threshold = EnvironmentConfig.GLOW_HDR_THRESHOLD
	_env.glow_hdr_scale = EnvironmentConfig.GLOW_HDR_SCALE
	_env.glow_normalized = true
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	# Phase V (kept): faint volumetric ground fog that catches lamp spill.
	_env.volumetric_fog_enabled = _quality != EnvironmentConfig.Quality.LOW
	_env.volumetric_fog_density = EnvironmentConfig.VOL_FOG_DENSITY_DAY
	_env.volumetric_fog_albedo = EnvironmentConfig.VOL_FOG_ALBEDO_DAY
	_env.volumetric_fog_emission = EnvironmentConfig.VOL_FOG_EMISSION
	_env.volumetric_fog_emission_energy = EnvironmentConfig.VOL_FOG_EMISSION_DAY
	_env.volumetric_fog_gi_inject = 0.45
	_env.volumetric_fog_length = 64.0
	_env.volumetric_fog_detail_spread = 6.0
	_env.volumetric_fog_sky_affect = 0.15
	_env.volumetric_fog_ambient_inject = 0.1


func _build_sky() -> void:
	_sky = Sky.new()
	# A realtime sky is forced to a 256 radiance size by the renderer (it warns
	# otherwise).  Sky ambient is unused here, so declare the engine's value rather
	# than fighting it: no warning, no extra cost beyond what the engine already
	# allocates.
	_sky.radiance_size = (Sky.RADIANCE_SIZE_256 if PROCESS_MODE == Sky.PROCESS_MODE_REALTIME
			else Sky.RADIANCE_SIZE_64)
	_sky.process_mode = PROCESS_MODE
	if ResourceLoader.exists(SKY_SHADER_PATH):
		var shader: Shader = load(SKY_SHADER_PATH)
		if shader != null:
			_sky_mat = ShaderMaterial.new()
			_sky_mat.shader = shader
			_sky.sky_material = _sky_mat
	_env.sky = _sky
	if _sky_mat == null:
		# Fallback: engine procedural sky so a missing shader is still playable.
		_proc_sky = ProceduralSkyMaterial.new()
		_proc_sky.sky_top_color = DAY_ZENITH
		_proc_sky.sky_horizon_color = DAY_HORIZON
		_proc_sky.ground_bottom_color = GROUND_NIGHT
		_proc_sky.ground_horizon_color = DAY_HORIZON
		_proc_sky.sun_angle_max = 12.0
		_proc_sky.sun_curve = 0.12
		_sky.sky_material = _proc_sky


# ------------------------------------------------------------------- ticking
## Advances the cosmetic lightning flash envelope.
func tick(delta: float) -> void:
	if _bolt_timer > 0.0:
		_bolt_timer -= delta
		if _bolt_timer <= 0.0 and _bolt != null:
			_bolt.visible = false
	if _flash_index >= _flash_seq.size():
		_flash_level = 0.0
		return
	_flash_time += delta
	while _flash_index < _flash_seq.size() and _flash_time >= _flash_seq[_flash_index].x:
		_flash_time -= _flash_seq[_flash_index].x
		_flash_index += 1
	_flash_level = _flash_seq[_flash_index].y if _flash_index < _flash_seq.size() else 0.0


func flash_level() -> float:
	return _flash_level


## Multi-stage flash: a short bright stage, a secondary echo, then a dim long
## tail - dramatic but never a strobe (requirement 20).
func trigger_flash(intensity: float, stages: int) -> void:
	var s := clampi(stages, 1, 3)
	var amp := clampf(intensity, 0.1, 1.0)
	_flash_seq = []
	_flash_seq.append(Vector2(0.055, amp))
	_flash_seq.append(Vector2(0.045, 0.0))
	if s >= 2:
		_flash_seq.append(Vector2(0.085, amp * 0.72))
		_flash_seq.append(Vector2(0.055, 0.02))
	if s >= 3:
		_flash_seq.append(Vector2(0.220, amp * 0.34))
		_flash_seq.append(Vector2(0.180, 0.0))
	_flash_index = 0
	_flash_time = 0.0
	_flash_level = amp


# ------------------------------------------------------------------ applying
func apply(frame: Dictionary) -> void:
	if _env == null:
		return
	_frames += 1

	var daylight := float(frame.get("daylight", 1.0))
	var night := float(frame.get("night", 0.0))
	var dusk := float(frame.get("dusk_warmth", 0.0))
	var cloud := clampf(float(frame.get("cloud_cover", 0.0)), 0.0, 1.0)
	var precip := clampf(float(frame.get("precipitation", 0.0)), 0.0, 1.0)
	var fog_amount := clampf(float(frame.get("fog_amount", 0.0)), 0.0, 1.0)
	var storm := clampf(float(frame.get("storm", 0.0)), 0.0, 1.0)
	var dim := clampf(float(frame.get("dim", 0.0)), 0.0, 0.6)

	# ---------------------------------------------------------------- lights
	var sun_color := SUN_NIGHT.lerp(SUN_NOON, daylight).lerp(SUN_DUSK, dusk * 0.85)
	var sun_energy := float(frame.get("sun_energy", 0.0))
	_sun.light_color = sun_color.lerp(sun_color.lerp(STORM_GREY_DAY, dim * 0.8), cloud * 0.35)
	_sun.light_energy = sun_energy
	_sun.visible = sun_energy > 0.002
	_face(_sun, frame.get("sun_dir", Vector3.UP))

	var moon_energy := float(frame.get("moon_energy", 0.0))
	_moon.light_color = MOON_COLOR
	_moon.light_energy = moon_energy
	_moon.visible = moon_energy > 0.002
	_face(_moon, frame.get("moon_dir", Vector3.DOWN))

	var ambient_energy := float(frame.get("ambient_energy", 0.0))
	_env.ambient_light_energy = ambient_energy
	var ambient_color := AMBIENT_NIGHT.lerp(AMBIENT_DAY, daylight)
	ambient_color = ambient_color.lerp(ambient_color.lerp(STORM_GREY_DAY, 0.55), dim)
	_env.ambient_light_color = _floor_luma(ambient_color, EnvironmentConfig.MIN_AMBIENT_LUMA)

	# ------------------------------------------------------------------- sky
	var zenith := NIGHT_ZENITH.lerp(DAY_ZENITH, daylight).lerp(DUSK_ZENITH, dusk * 0.55)
	var horizon := NIGHT_HORIZON.lerp(DAY_HORIZON, daylight).lerp(DUSK_HORIZON, dusk * 0.80)
	var grey := STORM_GREY_NIGHT.lerp(STORM_GREY_DAY, daylight)
	var grey_mix := clampf(cloud * 0.50 + storm * 0.26 + fog_amount * 0.06, 0.0, 0.86)
	zenith = zenith.lerp(grey * 0.85, grey_mix)
	horizon = horizon.lerp(grey, grey_mix)
	# Readability floor: art direction forbids a crushed background, and a storm
	# at midnight is exactly where that would otherwise happen.
	zenith = _floor_luma(zenith, EnvironmentConfig.MIN_ZENITH_LUMA)
	horizon = _floor_luma(horizon, EnvironmentConfig.MIN_HORIZON_LUMA)

	var haze := HAZE_NIGHT.lerp(HAZE_DAY, daylight).lerp(HAZE_DUSK, dusk * 0.6)
	haze = haze.lerp(zenith, 0.35)
	var haze_amount := clampf(
		EnvironmentConfig.SKY_BASE_HAZE
		+ fog_amount * EnvironmentConfig.SKY_FOG_HAZE
		+ precip * 0.10 + storm * 0.06, 0.0, 0.92)

	var cloud_color := CLOUD_LIT.lerp(STORM_GREY_DAY.lerp(NIGHT_ZENITH * 3.0, night), dim)
	cloud_color = cloud_color.lerp(CLOUD_DUSK, dusk * 0.5)
	var cloud_shadow := CLOUD_SHADOW.lerp(CLOUD_SHADOW_STORM, storm * 0.8).lerp(
		NIGHT_ZENITH * 2.4, night * 0.7)
	var star_amount := 0.0
	if _quality > EnvironmentConfig.Quality.LOW:
		star_amount = clampf(night * (1.0 - cloud * 1.15) * (1.0 - fog_amount * 0.9)
			* (1.0 - storm), 0.0, 1.0) * EnvironmentConfig.STAR_MAX

	if _sky_mat != null:
		_uniform(&"zenith_color", zenith)
		_uniform(&"horizon_color", horizon)
		_uniform(&"ground_color", GROUND_NIGHT.lerp(GROUND_DAY, daylight))
		_uniform(&"sun_color", sun_color)
		_uniform(&"sun_direction", frame.get("sun_dir", Vector3.UP))
		_uniform(&"sun_energy", clampf(sun_energy * EnvironmentConfig.SKY_SUN_GAIN, 0.0, 6.0))
		_uniform(&"sun_disc_scale", 1.0)
		_uniform(&"moon_color", MOON_COLOR)
		_uniform(&"moon_direction", frame.get("moon_dir", Vector3.DOWN))
		_uniform(&"moon_energy", clampf(moon_energy * EnvironmentConfig.SKY_MOON_GAIN, 0.0, 6.0))
		_uniform(&"cloud_color", cloud_color)
		_uniform(&"cloud_shadow_color", cloud_shadow)
		_uniform(&"cloud_cover", cloud)
		_uniform(&"cloud_sharpness", lerpf(0.26, 0.10, sqrt(cloud)))
		_uniform(&"cloud_scale", EnvironmentConfig.SKY_CLOUD_SCALE)
		_uniform(&"cloud_darkness", clampf(dim * 1.6 + storm * 0.25, 0.0, 1.0))
		_uniform(&"cloud_height", EnvironmentConfig.SKY_CLOUD_HEIGHT)
		_uniform(&"cloud_offset", frame.get("cloud_offset", Vector2.ZERO))
		_uniform(&"cloud_steps", float(EnvironmentConfig.sky_cloud_steps(_quality)))
		_uniform(&"haze_color", haze)
		_uniform(&"haze_amount", haze_amount)
		_uniform(&"star_amount", star_amount)
		_uniform(&"flash", _flash_level)
		_uniform(&"exposure_scale", lerpf(0.90, 1.0, daylight) * (1.0 - dim * 0.22))
	elif _proc_sky != null:
		_proc_sky.sky_top_color = zenith
		_proc_sky.sky_horizon_color = horizon
		_proc_sky.ground_horizon_color = horizon
		_proc_sky.ground_bottom_color = GROUND_NIGHT.lerp(GROUND_DAY, daylight)
		_proc_sky.sun_angle_max = 12.0
		_proc_sky.sun_curve = 0.12

	# ------------------------------------------------------------------- fog
	var fog_col := haze.lerp(horizon, 0.4)
	_env.fog_light_color = fog_col
	_env.fog_light_energy = lerpf(EnvironmentConfig.NIGHT_FOG_ENERGY,
		EnvironmentConfig.DAY_FOG_ENERGY, daylight) * (1.0 + dim * 0.3)
	var density := lerpf(EnvironmentConfig.NIGHT_FOG_DENSITY,
		EnvironmentConfig.DAY_FOG_DENSITY, daylight)
	density = density * (1.0 + fog_amount * EnvironmentConfig.FOG_DENSITY_SCALE)
	density += precip * EnvironmentConfig.PRECIP_FOG_DENSITY + storm * 0.002
	_env.fog_density = clampf(density, 0.0005, EnvironmentConfig.MAX_FOG_DENSITY)
	_env.fog_sky_affect = 0.35 + fog_amount * 0.35

	# ------------------------------------------------------- volumetric haze
	if _env.volumetric_fog_enabled:
		var vd := lerpf(EnvironmentConfig.VOL_FOG_DENSITY_NIGHT,
			EnvironmentConfig.VOL_FOG_DENSITY_DAY, daylight)
		vd *= 1.0 + fog_amount * 1.5 + precip * 0.5 + storm * 0.6
		_env.volumetric_fog_density = minf(vd, EnvironmentConfig.MAX_VOLUMETRIC_DENSITY)
		_env.volumetric_fog_emission_energy = lerpf(
			EnvironmentConfig.VOL_FOG_EMISSION_NIGHT,
			EnvironmentConfig.VOL_FOG_EMISSION_DAY, daylight) * (1.0 + fog_amount * 0.4)
		# The haze must be *lit*, not self-luminous: a fixed bright albedo is what
		# turned midnight into grey overcast.  Both facets follow the sun.
		_env.volumetric_fog_albedo = EnvironmentConfig.VOL_FOG_ALBEDO_NIGHT.lerp(
			EnvironmentConfig.VOL_FOG_ALBEDO_DAY, daylight)
		_env.volumetric_fog_emission = EnvironmentConfig.VOL_FOG_EMISSION_TINT_NIGHT.lerp(
			EnvironmentConfig.VOL_FOG_EMISSION, daylight)
		_env.volumetric_fog_length = 96.0 if fog_amount > 0.5 else 64.0
		# Keep the buffer thin: haze is atmosphere, not a fog wall.
		_env.volumetric_fog_density = minf(_env.volumetric_fog_density,
			EnvironmentConfig.MAX_VOLUMETRIC_DENSITY)

	# ------------------------------------------------------------------ glow
	if GameSettings.graphics("glow"):
		var glow := lerpf(EnvironmentConfig.GLOW_NIGHT, EnvironmentConfig.GLOW_DAY, daylight)
		_env.glow_intensity = clampf(glow + storm * 0.05, 0.0, 1.0)


## Point a directional light along `dir` (the direction the light travels from).
func _face(light: DirectionalLight3D, dir: Vector3) -> void:
	var travel := -dir.normalized()
	var up := Vector3.UP
	if absf(travel.y) > 0.999:
		up = Vector3.FORWARD
	var basis := Basis.looking_at(travel, up)
	var xform := Transform3D(basis, Vector3.ZERO)
	if not light.transform.is_equal_approx(xform):
		light.transform = xform


func _uniform(name: StringName, value: Variant) -> void:
	if _uniforms.get(name) == value:
		return
	_uniforms[name] = value
	_sky_mat.set_shader_parameter(String(name), value)


## Never let a colour drop below `min_luma` (scale-up keeps the hue).
func _floor_luma(c: Color, min_luma: float) -> Color:
	# Rec.709 luma.  `Color.luminance` is not available in this engine build.
	var l: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	if l >= min_luma:
		return c
	if l <= 0.0005:
		return Color(min_luma, min_luma, min_luma * 1.25)
	return c * (min_luma / l)


# -------------------------------------------------------------- accessors
func sun_light() -> DirectionalLight3D:
	return _sun


func moon_light() -> DirectionalLight3D:
	return _moon


func environment_node() -> WorldEnvironment:
	return _world_env


func environment() -> Environment:
	return _env


func sky_material() -> ShaderMaterial:
	return _sky_mat


func apply_shadows_enabled(on: bool) -> void:
	if _sun != null:
		_sun.shadow_enabled = on


func set_quality(quality: int) -> void:
	_quality = quality
	if _env != null:
		# GameSettings owns the on/off switch (graphics.volumetric_fog); quality
		# only decides whether this subsystem is willing to pay for it at all.
		_env.volumetric_fog_enabled = EnvironmentConfig.volumetric_enabled(quality) \
				and bool(GameSettings.graphics("volumetric_fog"))


# --------------------------------------------------------------- lightning
func _build_bolt() -> void:
	_bolt_material = StandardMaterial3D.new()
	_bolt_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bolt_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bolt_material.albedo_color = FLASH_COLOR
	_bolt_material.emission_enabled = true
	_bolt_material.emission = FLASH_COLOR
	_bolt_material.emission_energy_multiplier = 6.0
	_bolt_material.no_depth_test = true
	_bolt_material.disable_receive_shadows = true
	_bolt = MeshInstance3D.new()
	_bolt.name = BOLT_NODE_NAME
	_bolt.mesh = ImmediateMesh.new()
	_bolt.visible = false
	_bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bolt)


## Draws a fresh zig-zag bolt at `distance` metres along `bearing_rad` from the
## camera/player.  Rebuilt only when a strike actually happens (a storm fires at
## most a few times a minute), so the cost never shows up in the frame budget.
func trigger_bolt(origin: Vector3, bearing_rad: float, distance: float) -> void:
	if _bolt == null:
		_build_bolt()
		if _bolt == null:
			return
	var d := maxf(distance, BOLT_MIN_DISTANCE)
	var offset := Vector3(sin(bearing_rad), 0.0, -cos(bearing_rad)) * d
	var rng := WorldSeed.rng_for("environment_bolt",
			[int(origin.x), int(origin.z), int(origin.y), _frames])
	var mesh := _bolt.mesh as ImmediateMesh
	if mesh == null:
		return
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _bolt_material)
	var y := BOLT_TOP_HEIGHT
	var step := BOLT_TOP_HEIGHT / float(BOLT_SEGMENTS)
	for i in BOLT_SEGMENTS + 1:
		var t := float(i) / float(BOLT_SEGMENTS)
		var jitter := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)) \
				* d * 0.03 * (1.0 - t * 0.4)
		mesh.surface_add_vertex(offset + jitter + Vector3(0.0, y, 0.0))
		y -= step
	mesh.surface_end()
	_bolt.global_position = Vector3(origin.x, origin.y, origin.z)
	_bolt.visible = true
	_bolt_timer = BOLT_VISIBLE_SECONDS


func bolt_active() -> bool:
	return _bolt != null and _bolt.visible


func frames_applied() -> int:
	return _frames

