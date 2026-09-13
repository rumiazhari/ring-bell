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
var _wetness_scratch: Dictionary = {}   ## reused sample target for the wetness substeps
## -1 == follow the deterministic schedule, otherwise a WeatherModel.State.
var forced_state := -1
var lightning_enabled := true
var strikes_fired := 0

var _sample_accum := 0.0
var _last_total_minutes := 0.0
## Sub-cell game time not yet integrated (see _integrate_wetness).
var _wetness_backlog := 0.0
## Lattice anchor for the parameter refresh (see tick).
var _next_sample_total := -1.0
var _last_state := -1
var _next_strike: Dictionary = {}
var _real_clock := 0.0
var _last_strike_real := -1e9
## Game minute of the last strike: the anti-strobe valve is a game-time predicate so
## the same seed and clock always produce the same strikes.
var _last_strike_total := -1e9
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
	_wetness_backlog = 0.0
	_next_strike = {}
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
	_wetness_backlog = 0.0
	_next_strike = {}
	_refresh(GameClock.total_minutes, true)


## Advance by `delta` real seconds.  Called by EnvironmentManager each frame.
func tick(delta: float) -> void:
	_ensure_ready()
	_real_clock += delta

	var now_total := GameClock.total_minutes
	# Refresh on an absolute game-minute lattice instead of a frame-count accumulator: the
	# accumulator's phase depended on frame sizes, so two runs could expose different
	# weather bookkeeping at the same world minute.
	var sample_interval := maxf(SAMPLE_INTERVAL * maxf(GameClock.time_scale, 0.001), 0.0001)
	if _next_sample_total < 0.0 or now_total < _last_total_minutes \
			or now_total >= _next_sample_total:
		_refresh(now_total, false)
		_next_sample_total = (floorf(now_total / sample_interval) + 1.0) * sample_interval

	_integrate_wetness(now_total - _last_total_minutes)
	_last_total_minutes = now_total

	# A pending strike that has come due is ALWAYS fired, however large this frame was:
	# discarding it made the number of strikes depend on frame rate instead of on the
	# deterministic schedule (a hitch or a fast-forward silently lost strikes).
	_update_lightning(now_total)


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
	# Fixed game-minute substeps: wetness is a function of game time, so a long frame
	# lands the same as many short ones.  The old single-step clamp truncated a hitch
	# (a 12-minute frame wet the world for 5), which made the road depend on frame
	# history rather than on the rain that actually fell; WETNESS_MAX_SUBSTEPS still
	# bounds one frame, so a debug time skip cannot wet the city instantly.
	if forced_state >= 0:
		_apply_wetness_step(float(WeatherModel.PARAMS[forced_state]["precipitation"]),
				minf(game_delta, EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES
						* float(EnvironmentConfig.WETNESS_MAX_SUBSTEPS)))
		return
	# Whole fixed cells anchored to the game-minute lattice: the sequence of cells is then
	# the same however the elapsed time was split into frames, and the leftover fraction
	# waits in `_wetness_backlog` for the next frame (the old per-frame step integrated a
	# different precipitation sample depending on where the frame boundaries fell).  Each
	# cell is sampled at its midpoint.  One frame integrates at most WETNESS_MAX_SUBSTEPS
	# cells (60 game minutes), so a debug time skip still cannot soak or dry the city.
	_wetness_backlog += minf(game_delta, EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES
			* float(EnvironmentConfig.WETNESS_MAX_SUBSTEPS))
	var cell := EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES
	var at := _last_total_minutes
	var guard := 0
	while _wetness_backlog >= cell and guard < EnvironmentConfig.WETNESS_MAX_SUBSTEPS * 4:
		guard += 1
		at += cell
		WeatherModel.sample(seed_used, at - cell * 0.5, _wetness_scratch)
		_apply_wetness_step(float(_wetness_scratch.get("precipitation", 0.0)), cell)
		_wetness_backlog -= cell


## One wetness substep: `minutes` of game time at a constant precipitation rate.
func _apply_wetness_step(precip: float, minutes: float) -> void:
	if minutes <= 0.0:
		return
	if precip > EnvironmentConfig.WETNESS_PRECIP_THRESHOLD:
		wetness = minf(1.0,
			wetness + EnvironmentConfig.WETNESS_GAIN_PER_GAME_MINUTE * precip * minutes)
	else:
		wetness = maxf(0.0,
			wetness - EnvironmentConfig.WETNESS_DRY_PER_GAME_MINUTE * minutes)


func _update_lightning(now_total: float) -> void:
	if not lightning_enabled or storm_intensity() < 0.5:
		return
	if _next_strike.is_empty():
		_next_strike = WeatherModel.next_strike(seed_used, now_total)
		if _next_strike.is_empty():
			_next_strike = _synthetic_strike(now_total)
	if _next_strike.is_empty():
		return

	# Anti-strobe valve: whatever the time scale, never flash more often than
	# LIGHTNING_MIN_REAL_GAP in real seconds (requirement 20).  Expressed in game
	# minutes so the strike schedule stays a function of game time: 2 real seconds
	# at 1x, 8 game minutes at 240x, which is what stops a fast-forwarded storm
	# from strobing without making the strikes frame-clock dependent.
	var min_gap := maxf(EnvironmentConfig.LIGHTNING_STRIKE_MIN_GAP,
			EnvironmentConfig.LIGHTNING_MIN_REAL_GAP * maxf(GameClock.time_scale, 0.001))

	# Fire EVERY strike the schedule has already passed, scheduling each successor from
	# its own minute: the strike count is then a function of game time instead of frame
	# size.  A frame that carried the clock past a pending strike used to discard it, so
	# coarse frames saw fewer strikes than fine ones over the same interval.  The
	# catch-up is capped, because several flashes inside one frame collapse into one
	# visible flash anyway - beyond the cap the schedule is skipped forward instead.
	var fired := 0
	while not _next_strike.is_empty() and now_total >= float(_next_strike["abs_minute"]):
		if fired >= EnvironmentConfig.LIGHTNING_MAX_CATCHUP:
			_next_strike = WeatherModel.next_strike(seed_used, now_total)
			if _next_strike.is_empty():
				_next_strike = _synthetic_strike(now_total)
			return
		if _last_strike_total >= 0.0 \
				and float(_next_strike["abs_minute"]) - _last_strike_total < min_gap:
			_next_strike = WeatherModel.next_strike(seed_used, maxf(
					float(_next_strike["abs_minute"]), now_total) + 0.001)
			if _next_strike.is_empty():
				_next_strike = _synthetic_strike(now_total)
			return
		var strike := _next_strike
		_fire(strike)
		fired += 1
		_next_strike = WeatherModel.next_strike(seed_used, float(strike["abs_minute"]))
		if _next_strike.is_empty():
			_next_strike = _synthetic_strike(float(strike["abs_minute"]))


## Absolute game minute of the next scheduled strike, or -1 when none is pending.
func pending_strike_minute() -> float:
	return -1.0 if _next_strike.is_empty() else float(_next_strike.get("abs_minute", -1.0))


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
	# The strike's own minute, so a catch-up burst is spaced by the schedule rather
	# than by whatever time the frame happened to arrive at.
	_last_strike_total = float(strike.get("abs_minute", GameClock.total_minutes))
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
		"last_strike_total": _last_strike_total,
		"next_strike": _next_strike.duplicate(),
	}


func load_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	# A partial/older block has no seed: follow the world that was actually loaded
	# instead of keeping the previous one (weather would diverge from the layout).
	seed_used = int(data.get("seed_used", WorldSeed.get_world_seed()))
	if seed_used == 0:
		seed_used = WorldSeed.get_world_seed()
	wetness = clampf(float(data.get("wetness", 0.0)), 0.0, 1.0)
	forced_state = clampi(int(data.get("forced_state", -1)), -1, WeatherModel.STATE_COUNT - 1)
	_wind_speed_override = float(data.get("wind_speed_override", -1.0))
	_wind_dir_override = float(data.get("wind_direction_override", -1.0))
	lightning_enabled = bool(data.get("lightning_enabled", true))
	strikes_fired = int(data.get("strikes_fired", 0))
	_last_total_minutes = GameClock.total_minutes
	_wetness_backlog = 0.0
	_next_strike = {}
	_next_sample_total = -1.0
	_last_strike_real = _real_clock
	_last_strike_total = float(data.get("last_strike_total", GameClock.total_minutes))
	# Restore a pending strike so thunder timing survives a save; JSON turns the
	# numeric fields into floats, so coerce them back.
	var raw_strike: Dictionary = data.get("next_strike", {})
	if raw_strike.is_empty():
		_next_strike = {}
	else:
		_next_strike = {
			"abs_minute": float(raw_strike.get("abs_minute", 0.0)),
			"intensity": float(raw_strike.get("intensity", 0.5)),
			"distance": float(raw_strike.get("distance", 1000.0)),
			"stages": int(raw_strike.get("stages", 2)),
			"thunder_delay": float(raw_strike.get("thunder_delay", 1.0)),
		}
	_refresh(GameClock.total_minutes, true)
