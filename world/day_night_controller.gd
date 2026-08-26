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

var _sun: DirectionalLight3D
var _env: Environment
var _world_env: WorldEnvironment


func _ready() -> void:
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
	# Subtle volumetric fog at night sells depth + makes lamp halos read.
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.55, 0.62, 0.78)
	_env.fog_light_energy = 0.18
	_env.fog_density = 0.003
	_world_env.environment = _env
	add_child(_world_env)


func _process(_delta: float) -> void:
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

	var night := GameClock.is_night()
	# Live query so streamed CITY lamps (spawned long after _ready) are
	# included; avoids the stale-cache bug that kept CITY dark at night.
	for lamp in get_tree().get_nodes_in_group(&"streetlamp"):
		if is_instance_valid(lamp):
			lamp.visible = night
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
