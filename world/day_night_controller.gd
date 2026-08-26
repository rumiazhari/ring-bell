class_name DayNightController
extends Node
## Ties GameClock to 3D lighting.
##
## Creates its own DirectionalLight3D (sun) and WorldEnvironment, and toggles
## the streetlamp OmniLights found in group "streetlamp" at night.
## Phase S: night is GENUINELY dark (sun ~0.015, ambient ~0.03, background
## near-black) so streetlamp spill becomes the only readable light source.
## Lamps are re-queried live each frame so streamed CITY chunks (created
## after this controller) are picked up without a stale _lamps cache.
## Phase V: volumetric street ambience — faint ground fog + bloom halo
## around streetlamps / window glows via Environment glow + volumetric fog
## that breathes with darkness, reinforcing light-as-gameplay without
## new geometry.

const HOUR_SUNRISE := 6.0
const HOUR_SUNSET := 20.0
const HOUR_NOON_START := 9.0
const HOUR_NOON_END := 16.0

# Phase S night targets (genuine darkness): keep a faint moon tint but
# kill most ambient/sun so players need lamp spill to see.
const NIGHT_SUN_ENERGY := 0.015
const DAY_SUN_ENERGY := 1.35
const NIGHT_AMBIENT := 0.03
const DAY_AMBIENT := 0.60
const NIGHT_BG := Color(0.015, 0.022, 0.045)
const DAY_BG := Color(0.42, 0.52, 0.66)

# Phase V: volumetric street ambience — faint ground fog + bloom halos
# that make lamp/window pools read through a soft haze at night.
const GLOW_INTENSITY_NIGHT := 0.62
const GLOW_INTENSITY_DAY := 0.28
const GLOW_STRENGTH := 1.0
const GLOW_BLOOM := 0.12
const GLOW_HDR_THRESHOLD := 0.88
const GLOW_HDR_SCALE := 1.6
const VOL_FOG_DENSITY_NIGHT := 0.022
const VOL_FOG_DENSITY_DAY := 0.005
const VOL_FOG_EMISSION_NIGHT := 0.52
const VOL_FOG_EMISSION_DAY := 0.08
const VOL_FOG_ALBEDO := Color(0.60, 0.63, 0.70)
const VOL_FOG_EMISSION := Color(0.86, 0.68, 0.42)

# Phase W: flicker/dead-lamp variant — sputtery lamps modulate at night.
const FLICKER_AMPL := 0.18
const FLICKER_FREQ := 3.0
const BASE_LAMP_ENERGY := 2.8

var _sun: DirectionalLight3D
var _env: Environment
var _world_env: WorldEnvironment
var _flicker_time := 0.0   # accumulates _delta for Phase W sputter


func _ready() -> void:
	if _sun != null:
		return
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	_sun.shadow_enabled = true
	add_child(_sun)

	_world_env = WorldEnvironment.new()
	_world_env.name = "WorldEnv"
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.35, 0.45, 0.6)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.72, 0.76, 0.86)
	_env.ambient_light_energy = 0.5
	# Subtle depth fog at night sells distance + makes lamp halos read.
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.55, 0.62, 0.78)
	_env.fog_light_energy = 0.18
	_env.fog_density = 0.003
	# Phase V: bloom halo around every bright lamp/window point.
	_env.glow_enabled = true
	_env.glow_intensity = GLOW_INTENSITY_DAY
	_env.glow_strength = GLOW_STRENGTH
	_env.glow_bloom = GLOW_BLOOM
	_env.glow_hdr_threshold = GLOW_HDR_THRESHOLD
	_env.glow_hdr_scale = GLOW_HDR_SCALE
	_env.glow_normalized = true
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# Phase V: volumetric ground fog — faint haze that catches lamp spill.
	_env.volumetric_fog_enabled = true
	_env.volumetric_fog_density = VOL_FOG_DENSITY_DAY
	_env.volumetric_fog_albedo = VOL_FOG_ALBEDO
	_env.volumetric_fog_emission = VOL_FOG_EMISSION
	_env.volumetric_fog_emission_energy = VOL_FOG_EMISSION_DAY
	_env.volumetric_fog_gi_inject = 0.45
	_env.volumetric_fog_length = 64.0
	_env.volumetric_fog_detail_spread = 6.0
	_env.volumetric_fog_sky_affect = 0.15
	_world_env.environment = _env
	add_child(_world_env)


func _process(_delta: float) -> void:
	_flicker_time += _delta
	var hour := float(GameClock.get_minute_of_day()) / 60.0
	var day_factor := _day_factor(hour)

	_sun.light_energy = lerpf(NIGHT_SUN_ENERGY, DAY_SUN_ENERGY, day_factor)
	# Warm at low sun, neutral white at noon, cold blue at night.
	var dusk_color := Color(1.0, 0.74, 0.52)
	var noon_color := Color(1.0, 0.97, 0.92)
	var night_color := Color(0.42, 0.52, 0.78)
	if day_factor > 0.02:
		# Reach neutral light early in the morning ramp for readability.
		var noonness := clampf((day_factor - 0.3) * 1.8, 0.0, 1.0)
		_sun.light_color = dusk_color.lerp(noon_color, noonness)
	else:
		_sun.light_color = night_color

	_env.background_color = NIGHT_BG.lerp(DAY_BG, day_factor)
	_env.ambient_light_energy = lerpf(NIGHT_AMBIENT, DAY_AMBIENT, day_factor)
	# Fog density breathes with darkness: thicker at night for eerie depth.
	_env.fog_density = lerpf(0.008, 0.0025, day_factor)
	_env.fog_light_energy = lerpf(0.12, 0.18, day_factor)
	# Phase V: volumetric fog + glow also breathe — denser/brighter at night
	# so lamp/window halos punch through a faint haze, thin by day.
	_env.volumetric_fog_density = lerpf(VOL_FOG_DENSITY_NIGHT, VOL_FOG_DENSITY_DAY, day_factor)
	_env.volumetric_fog_emission_energy = lerpf(VOL_FOG_EMISSION_NIGHT, VOL_FOG_EMISSION_DAY, day_factor)
	_env.glow_intensity = lerpf(GLOW_INTENSITY_NIGHT, GLOW_INTENSITY_DAY, day_factor)

	var night := GameClock.is_night()
	# Live query so streamed CITY lamps (spawned long after _ready) are
	# included; avoids the stale-cache bug that kept CITY dark at night.
	if is_inside_tree():
		for lamp in get_tree().get_nodes_in_group(&"streetlamp"):
			if is_instance_valid(lamp):
				# Phase W: dead lamps stay dark even at night.
				if lamp.has_meta(&"dead_lamp") and bool(lamp.get_meta(&"dead_lamp")):
					lamp.visible = false
					continue
				lamp.visible = night
				if night and lamp.has_meta(&"lamp_flicker") and bool(lamp.get_meta(&"lamp_flicker")):
					var phase: float = float(lamp.get_meta(&"flicker_phase", 0.0))
					var noise := sin(_flicker_time * FLICKER_FREQ * TAU + phase * TAU) * 0.6 \
							+ sin(_flicker_time * FLICKER_FREQ * 1.73 * TAU + phase * 2.11) * 0.4
					var mod := BASE_LAMP_ENERGY * (1.0 + FLICKER_AMPL * noise)
					if lamp is OmniLight3D:
						(lamp as OmniLight3D).light_energy = clampf(mod, BASE_LAMP_ENERGY * 0.55, BASE_LAMP_ENERGY * 1.40)
				elif lamp is OmniLight3D:
					(lamp as OmniLight3D).light_energy = BASE_LAMP_ENERGY
		for glow in get_tree().get_nodes_in_group(&"window_glow"):
			if is_instance_valid(glow):
				glow.visible = night


## 0.0 at night, 1.0 mid-day with dawn/dusk ramps around sunrise/sunset.
func _day_factor(hour: float) -> float:
	if hour < HOUR_SUNRISE or hour > HOUR_SUNSET + 1.0:
		return 0.0
	if hour < HOUR_SUNRISE + 2.0:
		return (hour - HOUR_SUNRISE) / 2.0
	if hour > HOUR_SUNSET:
		return 1.0 - (hour - HOUR_SUNSET)
	return 1.0
