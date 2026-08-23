class_name DayNightController
extends Node
## Ties GameClock to 3D lighting.
##
## Creates its own DirectionalLight3D (sun) and WorldEnvironment, and toggles
## the streetlamp OmniLights found in group "streetlamp" at night.
## Darkness gameplay hooks (stealth/fear/vision) come later - for now this
## only changes what the player sees.

const HOUR_SUNRISE := 6.0
const HOUR_SUNSET := 20.0
const HOUR_NOON_START := 9.0
const HOUR_NOON_END := 16.0

var _sun: DirectionalLight3D
var _env: Environment
var _lamps: Array[Node] = []


func _ready() -> void:
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	_sun.shadow_enabled = true
	add_child(_sun)

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnv"
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.35, 0.45, 0.6)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.7, 0.75, 0.85)
	_env.ambient_light_energy = 0.5
	world_env.environment = _env
	add_child(world_env)

	# Streetlamps are created by LevelBuilder after us in tree order? No:
	# main.gd builds level first, then adds this controller - so lamps exist.
	_lamps = get_tree().get_nodes_in_group(&"streetlamp")


func _process(_delta: float) -> void:
	var hour := float(GameClock.get_minute_of_day()) / 60.0
	var day_factor := _day_factor(hour)

	_sun.light_energy = lerpf(0.04, 1.25, day_factor)
	# Warm at low sun, neutral white at noon, cold blue at night.
	var dusk_color := Color(1.0, 0.74, 0.52)
	var noon_color := Color(1.0, 0.97, 0.92)
	var night_color := Color(0.45, 0.55, 0.85)
	if day_factor > 0.02:
		# Reach neutral light early in the morning ramp for readability.
		var noonness := clampf((day_factor - 0.3) * 1.8, 0.0, 1.0)
		_sun.light_color = dusk_color.lerp(noon_color, noonness)
	else:
		_sun.light_color = night_color

	_env.background_color = Color(0.06, 0.08, 0.14).lerp(Color(0.42, 0.52, 0.66), day_factor)
	_env.ambient_light_energy = lerpf(0.18, 0.55, day_factor)

	var night := GameClock.is_night()
	for lamp in _lamps:
		if is_instance_valid(lamp):
			lamp.visible = night


## 0.0 at night, 1.0 mid-day with dawn/dusk ramps around sunrise/sunset.
func _day_factor(hour: float) -> float:
	if hour < HOUR_SUNRISE or hour > HOUR_SUNSET + 1.0:
		return 0.0
	if hour < HOUR_SUNRISE + 2.0:
		return (hour - HOUR_SUNRISE) / 2.0
	if hour > HOUR_SUNSET:
		return 1.0 - (hour - HOUR_SUNSET)
	return 1.0
