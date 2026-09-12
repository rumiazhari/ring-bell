class_name WeatherController
extends Node
## Runtime weather brain.
##
## Layering: `WeatherModel` is the pure deterministic model (what the weather
## *should* be at a given game minute); this node is the stateful runtime around
## it - it integrates wetness, adds wind gustiness, fires lightning, honours
## debug overrides and guards against strobing at high time scale.
##
## It is driven by `EnvironmentManager.tick()` rather than its own `_process`, so
## tests can advance it deterministically without waiting on real frames.
##
## Public state lives in `params` (Dictionary, mutated in place - do not hold a
## second copy) plus `wetness`.  Read it through the small getters below.

signal weather_changed(from_state: int, to_state: int)
signal lightning_struck(intensity: float, distance_m: float,
	thunder_delay: float, stages: int, wind_dir: float)

## How often the (allocation-free but not free) deterministic sample is taken.
const SAMPLE_INTERVAL := 0.25

var seed_used := 0
## Blended parameter vector, see WeatherModel.PARAM_KEYS.
var params: Dictionary = {}
## 0..1 surface wetness.  Rises while it rains, dries slowly afterwards.
var wetness := 0.0
## -1 == follow the deterministic schedule, otherwise a WeatherModel.State.
var forced_state := -1
var lightning_enabled := true
var strikes_fired := 0

var _sample_accum := 0.0
var _last_total_minutes := 0.0
var _last_state := -1
var _next_strike: Dictionary = {}
var _real_clock := 0.0
var _last_strike_real := -1e9
var _wind_speed_override := -1.0
var _wind_dir_override := -1.0
var _initialised := false


func _ready() -> void:
	if seed_used == 0:
		seed_used = WorldSeed.get_world_seed()
	_ensure_ready()


func _ensure_ready() -> void:
	if _initialised:
		return
	_initialised = true
	if params.is_empty():
		for key in WeatherModel.PARAM_KEYS:
			params[key] = 0.0
		params["state"] = WeatherModel.State.CLEAR
		params["target_state"] = WeatherModel.State.CLEAR
		params["blend"] = 1.0
		params["progress"] = 1.0
		params["wind_direction"] = 0.0
		params["gust"] = 1.0
		params["day"] = 1
		params["minute_of_day"] = 0.0
	_last_total_minutes = GameClock.total_minutes
	_refresh(GameClock.total_minutes, true)


## Re-seed for a new world (new game / world seed change).
func reseed(new_seed: int) -> void:
	seed_used = new_seed
	forced_state = -1
	_wind_speed_override = -1.0
	_wind_dir_override = -1.0
	wetness = 0.0
	_next_strike = {}
	_last_state = -1
	params.clear()
	_initialised = false
	_ensure_ready()


## Re-aligns the derived parameter vector with the clock *without* clearing any
## override (unlike reseed(), which is for a brand-new world).  Used after a
## save/load, a debug time jump or a world-step jump, so a forced weather state
## and a restored wetness survive the resync.
func resample() -> void:
	_ensure_ready()
	_last_total_minutes = GameClock.total_minutes
	_refresh(GameClock.total_minutes, true)


## Advance by `delta` real seconds.  Called by EnvironmentManager each frame.
func tick(delta: float) -> void:
	_ensure_ready()
	_real_clock += delta

	var now_total := GameClock.total_minutes
	_sample_accum += delta
	if _sample_accum >= SAMPLE_INTERVAL:
		_sample_accum = 0.0
		_refresh(now_total, false)

	_integrate_wetness(now_total - _last_total_minutes)
	_last_total_minutes = now_total

	if absf(delta) < 1.0:      # a huge delta means a scene/step jump: resync only
		_update_lightning(now_total)
	else:
		_next_strike = {}


# ------------------------------------------------------------------ getters
func state() -> int:
	return int(params.get("state", WeatherModel.State.CLEAR))


func target_state() -> int:
	return int(params.get("target_state", WeatherModel.State.CLEAR))


func state_name() -> StringName:
	return WeatherModel.state_name(state())


func target_state_name() -> StringName:
	return WeatherModel.state_name(target_state())


func transition_progress() -> float:
	return float(params.get("progress", 1.0))


func transition_blend() -> float:
	return float(params.get("blend", 1.0))


func cloud_cover() -> float:
	return float(params.get("cloud", 0.0))


func precipitation() -> float:
	return float(params.get("precipitation", 0.0))


func fog_amount() -> float:
	return float(params.get("fog", 0.0))


func storm_intensity() -> float:
	return float(params.get("storm", 0.0))


func dimming() -> float:
	return float(params.get("dim", 0.0))


func wind_direction() -> float:
	return float(params.get("wind_direction", 0.0))


## Base wind speed in m/s, before gustiness.
func wind_speed() -> float:
	return float(params.get("wind", 0.0))


## Deterministic gust factor around 1.0, driven by simulation time only.
func wind_gust_factor() -> float:
	var phase := GameClock.total_minutes * EnvironmentConfig.GUST_FREQUENCY * TAU
	var amp := EnvironmentConfig.GUST_AMPLITUDE * float(params.get("gust", 1.0))
	return 1.0 + amp * (0.6 * sin(phase) + 0.4 * sin(phase * 2.17 + 1.3))


## Wind as reusable world state: direction the air travels, m/s.
## Compass convention: bearing 0 == towards north (-Z), pi/2 == towards east (+X).
func wind_vector() -> Vector3:
	var dir := wind_direction()
	var speed := maxf(0.0, wind_speed() * wind_gust_factor())
	return Vector3(sin(dir), 0.0, -cos(dir)) * speed


func wind_speed_gusted() -> float:
	return maxf(0.0, wind_speed() * wind_gust_factor())


# ------------------------------------------------------------- debug control
## -1 restores the deterministic schedule; anything else forces a state now.
func set_forced_state(state: int) -> void:
	forced_state = clampi(state, -1, WeatherModel.STATE_COUNT - 1)
	_refresh(GameClock.total_minutes, true)


func set_wetness(value: float) -> void:
	wetness = clampf(value, 0.0, 1.0)


func set_wind(speed: float, direction_rad := -1.0) -> void:
	_wind_speed_override = maxf(0.0, speed)
	if direction_rad >= 0.0:
		_wind_dir_override = direction_rad
	_refresh(GameClock.total_minutes, true)


func clear_wind_override() -> void:
	_wind_speed_override = -1.0
	_wind_dir_override = -1.0
	_refresh(GameClock.total_minutes, true)


## Sneak a strike in right now (debug).  Returns what was fired.
func force_lightning() -> Dictionary:
	var dir := wind_direction()
	var info := {
		"intensity": 1.0,
		"distance": 900.0,
		"stages": EnvironmentConfig.lightning_stages(EnvironmentConfig.Quality.HIGH),
		"thunder_delay": clampf(900.0 / EnvironmentConfig.THUNDER_SPEED_MPS,
			EnvironmentConfig.THUNDER_DELAY_MIN, EnvironmentConfig.THUNDER_DELAY_MAX),
		"wind_dir": dir,
		"forced": true,
	}
	_fire(info)
	return info


# ---------------------------------------------------------------- internals
func _refresh(now_total: float, snap: bool) -> void:
	WeatherModel.sample(seed_used, now_total, params)
	params["day"] = TimeOfDay.day_of(now_total)
	params["minute_of_day"] = TimeOfDay.minute_of_day_of(now_total)

	if forced_state >= 0:
		var forced: Dictionary = WeatherModel.PARAMS[forced_state]
		for key in WeatherModel.PARAM_KEYS:
			params[key] = forced[key]
		params["state"] = forced_state
		params["target_state"] = forced_state
		params["blend"] = 1.0
		params["progress"] = 1.0

	if _wind_speed_override >= 0.0:
		params["wind"] = _wind_speed_override
	if _wind_dir_override >= 0.0:
		params["wind_direction"] = _wind_dir_override

	var current := state()
	if current != _last_state:
		if _last_state >= 0 and not snap:
			weather_changed.emit(_last_state, current)
		_last_state = current
		_next_strike = {}      # re-evaluate the strike schedule for the new state


func _integrate_wetness(game_delta: float) -> void:
	if game_delta <= 0.0:
		return
	var minutes := minf(game_delta, EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES)
	var precip := precipitation()
	if forced_state >= 0:
		precip = float(WeatherModel.PARAMS[forced_state]["precipitation"])
	if precip > EnvironmentConfig.WETNESS_PRECIP_THRESHOLD:
		wetness = minf(1.0,
			wetness + EnvironmentConfig.WETNESS_GAIN_PER_GAME_MINUTE * precip * minutes)
	else:
		wetness = maxf(0.0,
			wetness - EnvironmentConfig.WETNESS_DRY_PER_GAME_MINUTE * minutes)


func _update_lightning(now_total: float) -> void:
	if not lightning_enabled or storm_intensity() < 0.5:
		return
	if _next_strike.is_empty() or float(_next_strike.get("abs_minute", -1.0)) < now_total - 0.5:
		_next_strike = WeatherModel.next_strike(seed_used, now_total)
	if _next_strike.is_empty():
		_next_strike = _synthetic_strike(now_total)
	if _next_strike.is_empty():
		return
	if now_total < float(_next_strike["abs_minute"]):
		return

	# Anti-strobe valve: whatever the time scale, never flash more often than
	# LIGHTNING_MIN_REAL_GAP in real seconds (requirement 20).
	if _real_clock - _last_strike_real < EnvironmentConfig.LIGHTNING_MIN_REAL_GAP:
		var skip_from := maxf(float(_next_strike["abs_minute"]), now_total) + 0.001
		_next_strike = WeatherModel.next_strike(seed_used, skip_from)
		if _next_strike.is_empty():
			_next_strike = _synthetic_strike(now_total)
		return

	_fire(_next_strike)
	_next_strike = {}


func _synthetic_strike(now_total: float) -> Dictionary:
	var rng := WorldSeed.rng_for_seed(
		seed_used, "environment_lightning_forced", [int(now_total)])
	var distance := 320.0 + 5200.0 * pow(rng.randf(), 2.0)
	return {
		"abs_minute": now_total + rng.randf_range(
			EnvironmentConfig.LIGHTNING_STRIKE_MIN_GAP,
			EnvironmentConfig.LIGHTNING_STRIKE_MAX_GAP),
		"intensity": rng.randf_range(0.45, 1.0),
		"distance": distance,
		"stages": 2 + (1 if rng.randf() < 0.45 else 0),
		"thunder_delay": clampf(distance / EnvironmentConfig.THUNDER_SPEED_MPS,
			EnvironmentConfig.THUNDER_DELAY_MIN, EnvironmentConfig.THUNDER_DELAY_MAX),
	}


func _fire(strike: Dictionary) -> void:
	strikes_fired += 1
	_last_strike_real = _real_clock
	var gate := clampf(storm_intensity() / 0.6, 0.0, 1.0)
	if bool(strike.get("forced", false)):
		gate = 1.0
	var intensity := clampf(float(strike.get("intensity", 0.6)) * maxf(gate, 0.35), 0.1, 1.0)
	var distance := float(strike.get("distance", 1500.0))
	var stages := clampi(int(strike.get("stages", 3)), 1, 3)
	var delay := float(strike.get("thunder_delay", 2.0))
	var dir := float(strike.get("wind_dir", wind_direction()))
	lightning_struck.emit(intensity, distance, delay, stages, dir)


# -------------------------------------------------------------- save / load
func save_state() -> Dictionary:
	return {
		"version": 1,
		"seed_used": seed_used,
		"wetness": wetness,
		"forced_state": forced_state,
		"wind_speed_override": _wind_speed_override,
		"wind_direction_override": _wind_dir_override,
		"lightning_enabled": lightning_enabled,
		"strikes_fired": strikes_fired,
	}


func load_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	seed_used = int(data.get("seed_used", seed_used))
	if seed_used == 0:
		seed_used = WorldSeed.get_world_seed()
	wetness = clampf(float(data.get("wetness", 0.0)), 0.0, 1.0)
	forced_state = clampi(int(data.get("forced_state", -1)), -1, WeatherModel.STATE_COUNT - 1)
	_wind_speed_override = float(data.get("wind_speed_override", -1.0))
	_wind_dir_override = float(data.get("wind_direction_override", -1.0))
	lightning_enabled = bool(data.get("lightning_enabled", true))
	strikes_fired = int(data.get("strikes_fired", 0))
	_last_total_minutes = GameClock.total_minutes
	_next_strike = {}
	_last_strike_real = _real_clock
	_refresh(GameClock.total_minutes, true)
