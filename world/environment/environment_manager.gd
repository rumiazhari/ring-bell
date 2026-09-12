class_name EnvironmentManager
extends Node3D
## The one authoritative environment system for Ring Bell.
##
## Owns, in one place:
##   time        -> GameClock (existing autoload, still the clock authority) + TimeOfDay (pure maths)
##   weather     -> WeatherModel (pure, deterministic) + WeatherController (runtime state)
##   atmosphere  -> AtmosphereController (sky, sun, moon, ambient, fog, volumetric haze, glow)
##   wind        -> WeatherController world wind state (`wind_vector()`)
##   wetness     -> WeatherController (rain-driven, exposed to rendering as a global shader parameter)
##   rain        -> EnvironmentPrecipitation (one camera-local emitter)
##   exposure    -> EnvironmentExposureProbe (indoor/outdoor hook)
##   ambience    -> EnvironmentAmbience (generated exterior loops + thunder)
##   debug       -> EnvironmentDebug (hotkeys + overlay text)
##
## Integration is deliberately tiny: `world/main.gd` adds ONE node.  Everything
## else is internal, so this subsystem never edits building generation, interiors,
## chunk streaming or the player - it only *reads* the world (the focus node plus
## three throttled shelter raycasts).
##
## This node is WORLD state, not chunk state: it survives chunk streaming and
## refuses to be duplicated (see `_ready`), which is what keeps a moving player's
## weather from resetting at every load boundary.

signal time_phase_changed(phase: int, name: StringName)
signal lightning_event(intensity: float, distance_m: float, delay: float)
signal ready_state()

const GROUP := &"environment_manager"
const DEFAULT_QUALITY := EnvironmentConfig.Quality.MEDIUM
const FOCUS_GROUP := &"player"

## Global shader parameters the subsystem publishes for materials/shaders.
## Declare `global uniform float environment_wetness;` etc. in any shader to
## consume them - no per-material bookkeeping, no per-frame material loops.
## See world/environment/shaders/wetness_overlay.gdshader for a reference
## consumer.  The declarations live in project.godot ([shader_globals]) because
## the renderer errors on every publish of an undeclared parameter, and the
## runtime declaration API is editor-only.
const GP_WETNESS := &"environment_wetness"
const GP_RAIN := &"environment_rain_intensity"
const GP_WIND := &"environment_wind_vector"
const GP_NIGHT := &"environment_night_factor"
const GP_HOUR := &"environment_hour"
const GP_STORM := &"environment_storm"

const GLOBAL_PARAMS := [
	{"name": GP_WETNESS, "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "default": 0.0},
	{"name": GP_RAIN, "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "default": 0.0},
	{"name": GP_STORM, "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "default": 0.0},
	{"name": GP_WIND, "type": RenderingServer.GLOBAL_VAR_TYPE_VEC3, "default": Vector3.ZERO},
	{"name": GP_NIGHT, "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "default": 0.0},
	{"name": GP_HOUR, "type": RenderingServer.GLOBAL_VAR_TYPE_FLOAT, "default": 12.0},
]

static var _shared: EnvironmentManager = null

var weather := WeatherController.new()
var atmosphere := AtmosphereController.new()
var precipitation := EnvironmentPrecipitation.new()
var exposure := EnvironmentExposureProbe.new()
var ambience := EnvironmentAmbience.new()
var debug_panel: Node = null

var quality := DEFAULT_QUALITY
var focus: Node3D = null
var ready_done := false
var frames := 0
var lightning_events := 0

var _frame: Dictionary = {}
var _thunder_queue: Array[Dictionary] = []
var _thunder_cursor := 0
var _focus_warned := false
var _last_origin := Vector3.ZERO
var _last_phase := -1
var _global_params_applied := 0
var _globals_ready := false


# ------------------------------------------------------------------ lifecycle
static func instance() -> EnvironmentManager:
	return _shared


static func instance_or_null() -> EnvironmentManager:
	if _shared != null and is_instance_valid(_shared):
		return _shared
	return null


func _init() -> void:
	name = "Environment"


func _ready() -> void:
	if _shared != null and is_instance_valid(_shared) and _shared != self:
		# Success criterion 32: exactly one authoritative manager, ever.
		push_warning("[Environment] duplicate EnvironmentManager ignored (%s)" % [str(get_path())])
		queue_free()
		return
	_shared = self
	add_to_group(GROUP)
	add_to_group(String(GROUP) + "_singleton")
	weather.lightning_struck.connect(_on_lightning_struck)
	_check_global_params()
	_build_children()
	var settings_quality := _quality_from_settings()
	set_quality(settings_quality)
	apply_cli_options(OS.get_cmdline_user_args(), OS.get_cmdline_args())
	debug_panel = EnvironmentDebug.new()
	debug_panel.name = "Debug"
	add_child(debug_panel)
	_resync(true)
	ready_done = true
	ready_state.emit()


func _exit_tree() -> void:
	if _shared == self:
		_shared = null


func _build_children() -> void:
	for child: Node in [weather, atmosphere, precipitation, exposure, ambience]:
		if child.get_parent() == null:
			add_child(child)
	atmosphere.build(quality)
	atmosphere.apply_shadows_enabled(bool(GameSettings.graphics("shadows")))
	precipitation.set_quality(quality)


func _process(delta: float) -> void:
	if not ready_done:
		return
	tick(delta)


## One simulation step.  Public and delta-driven so tests can advance the whole
## environment deterministically without waiting on rendered frames.
func tick(delta: float) -> void:
	if not ready_done:
		return
	frames += 1
	var camera := _resolve_camera()
	var origin := _probe_origin(camera)
	_last_origin = origin

	weather.tick(delta)
	exposure.update_frame(delta, origin, get_world_3d())

	_build_frame()
	atmosphere.tick(delta)
	atmosphere.apply(_frame)

	precipitation.update_frame(delta, camera, weather.precipitation(),
			weather.storm_intensity(), weather.wind_vector(), exposure.exposure)
	ambience.update_frame(weather.precipitation(), weather.storm_intensity(),
			weather.wind_speed_gusted(), exposure.exposure)
	_drain_thunder(delta)
	_publish_global_params()
	_emit_phase_if_changed()
	_debug_tick(delta)


# --------------------------------------------------------------- frame build
## Assembles the atmosphere parameter vector from the clock + weather.
## The dictionary is reused in place: no per-frame allocation.
func _build_frame() -> void:
	var minute := TimeOfDay.minute_of_day_of(GameClock.total_minutes)
	var day := TimeOfDay.day_of(GameClock.total_minutes)
	var daylight := TimeOfDay.daylight_factor(minute)
	var night := TimeOfDay.night_factor(minute)
	var dusk := TimeOfDay.dusk_warmth(minute)
	var moon_vis := TimeOfDay.moon_visibility(minute, day)

	var cloud := weather.cloud_cover()
	var precip := weather.precipitation()
	var storm := weather.storm_intensity()
	var fog_amount := weather.fog_amount()
	var dim := weather.dimming()
	var wind := weather.wind_vector()

	var sun_energy := lerpf(EnvironmentConfig.NIGHT_SUN_ENERGY, EnvironmentConfig.DAY_SUN_ENERGY, daylight)
	sun_energy *= lerpf(1.0, 0.52, cloud) * (1.0 - dim * 0.35)
	var moon_energy := lerpf(EnvironmentConfig.MOON_MIN_ENERGY, EnvironmentConfig.MOON_MAX_ENERGY, moon_vis)
	moon_energy *= lerpf(1.0, 0.50, cloud) * (1.0 - dim * 0.45)
	var ambient_energy := lerpf(EnvironmentConfig.NIGHT_AMBIENT_ENERGY,
			EnvironmentConfig.DAY_AMBIENT_ENERGY, daylight) * (1.0 - dim * 0.25)
	ambient_energy = clampf(ambient_energy, EnvironmentConfig.MIN_AMBIENT_ENERGY,
			EnvironmentConfig.MAX_AMBIENT_ENERGY)

	# Blown-highlight guard: at dawn the sun, the moon and ambient briefly overlap.
	var total := sun_energy + moon_energy + ambient_energy
	var budget := EnvironmentConfig.MAX_TOTAL_LIGHT_ENERGY
	if total > budget:
		var over := total - budget
		var sun_cut := minf(sun_energy, over)
		sun_energy -= sun_cut
		over -= sun_cut
		if over > 0.0:
			moon_energy = maxf(moon_energy - over, 0.0)

	# Clouds drift with the wind.  The offset is a pure function of (game minute,
	# wind), so it is deterministic and survives save/load and chunk streaming.
	var drift := float(GameClock.total_minutes) * EnvironmentConfig.SKY_CLOUD_DRIFT
	var cloud_offset := Vector2(wind.x * drift, wind.z * drift)

	_frame["daylight"] = daylight
	_frame["night"] = night
	_frame["dusk_warmth"] = dusk
	_frame["cloud_cover"] = cloud
	_frame["precipitation"] = precip
	_frame["fog_amount"] = fog_amount
	_frame["storm"] = storm
	_frame["dim"] = dim
	_frame["sun_energy"] = sun_energy
	_frame["moon_energy"] = moon_energy
	_frame["ambient_energy"] = ambient_energy
	_frame["sun_dir"] = TimeOfDay.sun_direction(minute)
	_frame["moon_dir"] = TimeOfDay.moon_direction(minute)
	_frame["cloud_offset"] = cloud_offset
	_frame["moon_visibility"] = moon_vis
	_frame["wind_speed"] = weather.wind_speed_gusted()
	_frame["wetness"] = weather.wetness


func _emit_phase_if_changed() -> void:
	var phase := TimeOfDay.phase_of(TimeOfDay.minute_of_day_of(GameClock.total_minutes))
	if phase != _last_phase:
		_last_phase = phase
		time_phase_changed.emit(phase, TimeOfDay.phase_name(
				TimeOfDay.minute_of_day_of(GameClock.total_minutes)))


# ---------------------------------------------------------------- lightning
func _on_lightning_struck(intensity: float, distance_m: float, delay: float,
		stages: int, wind_dir: float) -> void:
	lightning_events += 1
	atmosphere.trigger_flash(intensity, stages)
	var bearing := wind_dir + PI
	atmosphere.trigger_bolt(_last_origin, bearing, distance_m)
	var wait := clampf(delay, EnvironmentConfig.THUNDER_DELAY_MIN, EnvironmentConfig.THUNDER_DELAY_MAX)
	lightning_event.emit(intensity, distance_m, wait)
	if _thunder_queue.size() < 64:
		_thunder_queue.append({"t": wait, "intensity": intensity, "distance": distance_m})
	else:
		push_warning("[Environment] thunder queue full, dropping strike")


func _drain_thunder(delta: float) -> void:
	if _thunder_queue.is_empty():
		return
	var i := 0
	while i < _thunder_queue.size():
		var entry := _thunder_queue[i]
		entry["t"] = float(entry["t"]) - delta
		if float(entry["t"]) <= 0.0:
			ambience.play_thunder(float(entry["intensity"]), float(entry["distance"]))
			_thunder_queue.remove_at(i)
			continue
		i += 1


func pending_thunder() -> int:
	return _thunder_queue.size()


# ------------------------------------------------------------------- getters
func phase_name() -> StringName:
	return TimeOfDay.phase_name(TimeOfDay.minute_of_day_of(GameClock.total_minutes))


func clock_string() -> String:
	return TimeOfDay.clock_string(TimeOfDay.minute_of_day_of(GameClock.total_minutes))


func weather_name() -> StringName:
	return weather.state_name()


func wind_vector() -> Vector3:
	return weather.wind_vector()


func wetness() -> float:
	return weather.wetness


func is_indoors() -> bool:
	return exposure.is_sheltered()


func night_factor() -> float:
	return float(_frame.get("night", 0.0))


func daylight_factor() -> float:
	return float(_frame.get("daylight", 1.0))


func current_frame() -> Dictionary:
	return _frame


func set_focus(node: Node3D) -> void:
	focus = node


func set_quality(value: int) -> void:
	quality = clampi(value, EnvironmentConfig.Quality.LOW, EnvironmentConfig.Quality.HIGH)
	atmosphere.set_quality(quality)
	precipitation.set_quality(quality)


func quality_name() -> StringName:
	return EnvironmentConfig.quality_name(quality)


func set_ambience_enabled(value: bool) -> void:
	ambience.set_enabled(value)


func set_precipitation_enabled(value: bool) -> void:
	precipitation.set_enabled(value)


func set_exposure_probe_enabled(value: bool) -> void:
	exposure.set_enabled(value)


## Debug: force the shelter value and release the physics probe (-1 releases).
func force_shelter(value: float) -> void:
	if value < 0.0:
		exposure.force(-1.0)
		exposure.set_enabled(true)
	else:
		exposure.set_enabled(true)
		exposure.force(clampf(value, 0.0, 1.0))


# -------------------------------------------------------- global shader data
## Verifies the [shader_globals] declarations once, then publishes on every tick.
## Publishing an undeclared global makes the renderer error on *every frame*, and
## the alternative - RenderingServer.global_shader_parameter_add()/
## global_shader_parameter_get_list() - is editor-only ("This function should
## never be used outside the editor, it can severely damage performance"), so the
## declaration is a project setting and this is a one-time cheap check.
func _check_global_params() -> void:
	if _globals_ready:
		return
	var missing: Array[String] = []
	for spec in GLOBAL_PARAMS:
		if not ProjectSettings.has_setting("shader_globals/" + String(spec["name"])):
			missing.append(String(spec["name"]))
	_globals_ready = missing.is_empty()
	if not _globals_ready:
		push_warning("[Environment] global shader parameters missing from project.godot "
				+ "[shader_globals]: %s - weather-reactive materials will not receive "
				% [", ".join(missing)] + "environment data")


func _publish_global_params() -> void:
	if not _globals_ready:
		return
	RenderingServer.global_shader_parameter_set(GP_WETNESS, weather.wetness)
	RenderingServer.global_shader_parameter_set(GP_RAIN, weather.precipitation())
	RenderingServer.global_shader_parameter_set(GP_STORM, weather.storm_intensity())
	RenderingServer.global_shader_parameter_set(GP_WIND, weather.wind_vector())
	RenderingServer.global_shader_parameter_set(GP_NIGHT, float(_frame.get("night", 0.0)))
	RenderingServer.global_shader_parameter_set(GP_HOUR,
			TimeOfDay.hour_of(TimeOfDay.minute_of_day_of(GameClock.total_minutes)))
	_global_params_applied += 1


func global_params_applied() -> int:
	return _global_params_applied


# ----------------------------------------------------------------- save/load
## JSON-safe snapshot (SaveManager writes this straight into the save file).
## Weather is a pure function of (seed, total_minutes), and both of those are
## already saved, so this only has to persist what deterministic replay cannot
## reconstruct: wetness, any debug override, and the pacing knobs.
func save_state() -> Dictionary:
	# Self-sufficient environment snapshot: the project save (save_manager) also
	# stores the clock, and both writers carry the same value, so restore order
	# does not matter and the environment block alone is a coherent restore.
	return {
		"version": 2,
		"quality": quality,
		"clock_minutes": GameClock.total_minutes,
		"time_scale": GameClock.time_scale,
		"time_paused": GameClock.paused,
		"weather": weather.save_state(),
		"ambience_enabled": ambience.is_enabled(),
		"precipitation_enabled": precipitation.is_enabled(),
		"focus_note": "derived from the player node after load",
	}


func load_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	set_quality(int(data.get("quality", quality)))
	if data.has("ambience_enabled"):
		ambience.set_enabled(bool(data["ambience_enabled"]))
	if data.has("precipitation_enabled"):
		precipitation.set_enabled(bool(data["precipitation_enabled"]))
	if data.has("time_scale"):
		GameClock.time_scale = clampf(float(data["time_scale"]),
				EnvironmentConfig.time_scale_for_day_length(EnvironmentConfig.MAX_DAY_LENGTH_SECONDS),
				EnvironmentConfig.time_scale_for_day_length(EnvironmentConfig.MIN_DAY_LENGTH_SECONDS))
	GameClock.paused = bool(data.get("time_paused", false))
	if data.has("clock_minutes"):
		GameClock.total_minutes = maxf(0.0, float(data["clock_minutes"]))
	weather.load_state(data.get("weather", {}))
	# The save restores the clock *and* the environment; the clock may land after
	# us in the load order, so re-read it once the whole save has been applied.
	call_deferred("_resync_after_load")


func _resync_after_load() -> void:
	if not is_inside_tree():
		return
	_resync()


## Re-aligns derived state with the clock (after load, seed change or a debug
## time jump).  `full_reseed` is only for a brand-new world: it wipes overrides
## and wetness, so the load and debug paths must not use it.
func _resync(full_reseed: bool = false) -> void:
	if full_reseed:
		weather.reseed(WorldSeed.get_world_seed())
	else:
		weather.resample()
	weather.tick(0.0)
	_build_frame()
	atmosphere.apply(_frame)
	_publish_global_params()


func resync(full_reseed: bool = false) -> void:
	_resync(full_reseed)


# ---------------------------------------------------------------- debug / CLI
func force_time(hour: float, minute: float = 0.0) -> void:
	var day := TimeOfDay.day_of(GameClock.total_minutes)
	var m := clampf(hour, 0.0, 23.99) * 60.0 + clampf(minute, 0.0, 59.0)
	GameClock.total_minutes = float(day - 1) * float(EnvironmentConfig.MINUTES_PER_DAY) + m
	resync()


func freeze_time(value: bool) -> void:
	GameClock.paused = value


func time_frozen() -> bool:
	return GameClock.paused


func set_day_length(seconds: float) -> float:
	var scale := EnvironmentConfig.time_scale_for_day_length(seconds)
	GameClock.time_scale = scale
	return EnvironmentConfig.day_length_seconds(scale)


func day_length_seconds() -> float:
	return EnvironmentConfig.day_length_seconds(GameClock.time_scale)


## Accepts a state name ("storm") or index (6).  Returns false if unrecognised.
func force_weather(id: Variant) -> bool:
	if id is String or id is StringName:
		var resolved := WeatherModel.state_from_name(String(id))
		if resolved < 0:
			return false
		weather.set_forced_state(resolved)
		return true
	var index := int(id)
	if index < 0 or index >= WeatherModel.STATE_COUNT:
		return false
	weather.set_forced_state(index)
	return true


func clear_forced_weather() -> void:
	weather.set_forced_state(-1)


func force_lightning() -> Dictionary:
	var strike := weather.force_lightning()
	return strike


func set_wetness(value: float) -> void:
	weather.set_wetness(value)


func set_wind(speed: float, direction_deg: float = -1.0) -> void:
	var dir_rad := -1.0
	if direction_deg >= 0.0:
		dir_rad = deg_to_rad(direction_deg)
	weather.set_wind(speed, dir_rad)


func clear_wind_override() -> void:
	weather.clear_wind_override()


func dump_state() -> String:
	print(status_line())
	for line in status_lines():
		print(line)
	return status_line()


func _debug_tick(_delta: float) -> void:
	if debug_panel != null and debug_panel.has_method("tick"):
		debug_panel.call("tick", _delta)


# CLI switches, all optional and all debug-only:
#   --envtime=18:30      --envfreeze           --envdaylength=600
#   --envweather=storm   --envlightning        --envwetness=0.8
#   --envwind=14,90      --envquality=high     --envprobe=in|out
#   --envnonight         --envnorain           --envnoambience
func apply_cli_options(user_args: PackedStringArray, engine_args: PackedStringArray = PackedStringArray()) -> void:
	var args := user_args
	if args.is_empty():
		args = engine_args
	if args.is_empty():
		return
	var applied: Array[String] = []

	var t := _arg_value(args, "--envtime")
	if not t.is_empty() and t.contains(":"):
		var parts := t.split(":")
		force_time(float(parts[0]), float(parts[1]) if parts.size() > 1 else 0.0)
		applied.append("time=%s" % t)

	if _has_flag(args, "--envfreeze"):
		freeze_time(true)
		applied.append("freeze")

	var dl := _arg_value(args, "--envdaylength")
	if not dl.is_empty():
		var seconds := set_day_length(float(dl))
		applied.append("day=%.0fs" % seconds)

	var w := _arg_value(args, "--envweather")
	if not w.is_empty():
		if force_weather(w):
			applied.append("weather=%s" % w)
		else:
			push_warning("[Environment] unknown --envweather=%s" % w)

	var q := _arg_value(args, "--envquality")
	if not q.is_empty():
		set_quality(EnvironmentConfig.quality_from_preset(q))
		applied.append("quality=%s" % quality_name())

	var wet := _arg_value(args, "--envwetness")
	if not wet.is_empty():
		set_wetness(float(wet))
		applied.append("wetness=%s" % wet)

	var wind := _arg_value(args, "--envwind")
	if not wind.is_empty():
		var wp := wind.split(",")
		set_wind(float(wp[0]), float(wp[1]) if wp.size() > 1 else -1.0)
		applied.append("wind=%s" % wind)

	var probe := _arg_value(args, "--envprobe")
	if probe == "in" or probe == "indoors":
		force_shelter(1.0)
		applied.append("probe=in")
	elif probe == "out" or probe == "outdoors":
		force_shelter(0.0)
		applied.append("probe=out")

	if _has_flag(args, "--envnorain"):
		set_precipitation_enabled(false)
		applied.append("norain")
	if _has_flag(args, "--envnoambience"):
		set_ambience_enabled(false)
		applied.append("noambience")

	if not applied.is_empty():
		print("[Environment] CLI overrides: %s" % ", ".join(applied))

	if _has_flag(args, "--envlightning"):
		var strike := force_lightning()
		print("[Environment] forced lightning: %s" % [JSON.stringify(strike)])

	# Forced weather must be applied after the load-settling resync.
	call_deferred("_resync")


static func _arg_value(args: PackedStringArray, key: String) -> String:
	var prefix := key + "="
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


static func _has_flag(args: PackedStringArray, key: String) -> bool:
	return args.has(key)


# ------------------------------------------------------------------ settings
func _quality_from_settings() -> int:
	# GameSettings owns the graphics preset (low/medium/high/ultra); the
	# environment quality tier follows it so a low-preset player never pays for
	# 2600 rain particles, volumetric haze and 4-step clouds.
	return EnvironmentConfig.quality_from_preset(String(GameSettings.graphics("preset")))


# ------------------------------------------------------------------ plumbing
func _resolve_camera() -> Camera3D:
	if focus != null and is_instance_valid(focus):
		var cam := focus.get_viewport().get_camera_3d() if focus.is_inside_tree() else null
		if cam != null:
			return cam
	var vp := get_viewport()
	if vp != null:
		return vp.get_camera_3d()
	return null


func _probe_origin(camera: Camera3D) -> Vector3:
	if focus != null and is_instance_valid(focus) and focus.is_inside_tree():
		return focus.global_position
	if camera != null:
		return camera.global_position
	return global_position


## Called by the world after spawning the player: keeps the shelter probe on the
## player instead of the camera (matters when the camera detaches, e.g. cutscenes).
func adopt_focus(node: Node3D) -> void:
	focus = node


func resolve_default_focus() -> void:
	if focus != null and is_instance_valid(focus):
		return
	var node := get_tree().get_first_node_in_group(FOCUS_GROUP)
	if node is Node3D:
		focus = node
	elif not _focus_warned:
		_focus_warned = true
		push_warning("[Environment] no focus node in group '%s'; falling back to the active camera"
				% FOCUS_GROUP)


# -------------------------------------------------------------------- status
func state() -> Dictionary:
	var minute := TimeOfDay.minute_of_day_of(GameClock.total_minutes)
	return {
		"day": TimeOfDay.day_of(GameClock.total_minutes),
		"clock": TimeOfDay.clock_string(minute),
		"phase": TimeOfDay.phase_name(minute),
		"daylight": snappedf(TimeOfDay.daylight_factor(minute), 0.001),
		"night": snappedf(TimeOfDay.night_factor(minute), 0.001),
		"day_length_s": snappedf(day_length_seconds(), 0.1),
		"time_scale": snappedf(GameClock.time_scale, 0.0001),
		"frozen": GameClock.paused,
		"weather": weather.state_name(),
		"weather_target": weather.target_state_name(),
		"transition": snappedf(weather.transition_progress(), 0.001),
		"cloud": snappedf(weather.cloud_cover(), 0.001),
		"precipitation": snappedf(weather.precipitation(), 0.001),
		"fog": snappedf(weather.fog_amount(), 0.001),
		"storm": snappedf(weather.storm_intensity(), 0.001),
		"wind_speed": snappedf(weather.wind_speed_gusted(), 0.01),
		"wind_dir_deg": snappedf(fposmod(rad_to_deg(weather.wind_direction()), 360.0), 0.1),
		"wetness": snappedf(weather.wetness, 0.001),
		"indoors": exposure.is_sheltered(),
		"exposure": snappedf(exposure.exposure, 0.001),
		"rain_particles": precipitation.active_particles(),
		"lightning_events": lightning_events,
		"thunder_pending": pending_thunder(),
		"thunder_plays": ambience.thunder_plays,
		"quality": quality_name(),
		"ambience_rain": snappedf(ambience.rain_level, 0.001),
		"ambience_wind": snappedf(ambience.wind_level, 0.001),
		"frames": frames,
		"focus": "player" if focus != null and is_instance_valid(focus) else "camera",
	}


func status_line() -> String:
	var s := state()
	return "[Environment] day %d %s (%s) | %s%s | cloud %.2f rain %.2f fog %.2f storm %.2f dim %.2f | wind %.1f m/s @ %.0f deg | wet %.2f | %s | %s | %s" % [
		int(s["day"]), s["clock"], s["phase"],
		s["weather"], "" if s["weather"] == s["weather_target"] else "->" + str(s["weather_target"]),
		s["cloud"], s["precipitation"], s["fog"], s["storm"],
		snappedf(weather.dimming(), 0.01),
		s["wind_speed"], s["wind_dir_deg"], s["wetness"],
		"INDOORS" if s["indoors"] else "outdoors",
		s["quality"],
		"FROZEN" if s["frozen"] else "%.0fs/day" % float(s["day_length_s"]),
	]


## Multi-line block for the debug overlay.
func status_lines() -> PackedStringArray:
	var s := state()
	var lines := PackedStringArray()
	lines.append("env  day %d  %s  %s" % [int(s["day"]), s["clock"], s["phase"]])
	lines.append("env  weather %s%s  blend %.2f" % [
		s["weather"],
		"" if s["weather"] == s["weather_target"] else " -> " + str(s["weather_target"]),
		s["transition"],
	])
	lines.append("env  cloud %.2f  rain %.2f  fog %.2f  storm %.2f  dim %.2f" % [
		s["cloud"], s["precipitation"], s["fog"], s["storm"], snappedf(weather.dimming(), 0.01),
	])
	lines.append("env  wind %.1f m/s %.0f deg  gust %.2f  wetness %.2f" % [
		s["wind_speed"], s["wind_dir_deg"], snappedf(weather.wind_gust_factor(), 0.01), s["wetness"],
	])
	lines.append("env  %s  exposure %.2f  rain_particles %d  lightning %d  thunder %d" % [
		"INDOORS" if s["indoors"] else "OUTDOORS", s["exposure"],
		int(s["rain_particles"]), int(s["lightning_events"]), int(s["thunder_plays"]),
	])
	lines.append("env  quality %s  %s  ambience rain %.2f wind %.2f" % [
		s["quality"],
		"FROZEN" if s["frozen"] else "day %.0fs (x%.2f)" % [float(s["day_length_s"]), float(s["time_scale"])],
		s["ambience_rain"], s["ambience_wind"],
	])
	return lines


## Called by the umbrella test / perf probe.
func self_check() -> Dictionary:
	var problems := PackedStringArray()
	if not ready_done:
		problems.append("manager not ready")
	if atmosphere.sun_light() == null:
		problems.append("no sun light")
	if atmosphere.moon_light() == null:
		problems.append("no moon light")
	if atmosphere.environment() == null:
		problems.append("no Environment resource")
	if atmosphere.sky_material() == null:
		problems.append("sky shader material missing")
	if atmosphere.frames_applied() <= 0:
		problems.append("atmosphere never applied")
	if precipitation.get_parent() == null:
		problems.append("precipitation not in tree")
	return {
		"ok": problems.is_empty(),
		"problems": problems,
		"nodes": get_child_count(),
	}
