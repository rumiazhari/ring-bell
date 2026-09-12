class_name WeatherModel
extends RefCounted
## Deterministic weather model: pure functions of (world seed, game minute).
##
## There is no hidden state here.  Given the same seed and the same clock the
## same weather always happens, which is what makes weather reproducible,
## save/load-safe and chunk-streaming-safe (success criteria 9, 10, 11).
##
## Structure: every day is a contiguous chain of weather EPISODES
## (WeatherModel.episodes_for_day).  Each episode carries a target parameter
## vector (PARAMS) and the model smoothly blends from the previous episode over
## a TRANSITION_MINUTES window, so weather never pops.  Thunderstorms also get a
## deterministic LIGHTNING strike schedule.
##
## Parameter vector keys (public contract, read by the debug overlay and tests):
##   cloud 0..1, precipitation 0..1, fog 0..1, wind m/s, storm 0..1, dim 0..0.5

enum State { CLEAR, PARTLY_CLOUDY, CLOUDY, FOG, LIGHT_RAIN, HEAVY_RAIN, STORM }

const STATE_COUNT := 7

const STATE_NAMES: Array[StringName] = [
	&"clear", &"partly_cloudy", &"cloudy", &"fog",
	&"light_rain", &"heavy_rain", &"storm",
]

const PARAM_KEYS: Array[StringName] = [
	&"cloud", &"precipitation", &"fog", &"wind", &"storm", &"dim",
]

const PARAMS := {
	State.CLEAR: {
		"cloud": 0.06, "precipitation": 0.00, "fog": 0.04,
		"wind": 3.0, "storm": 0.00, "dim": 0.00,
	},
	State.PARTLY_CLOUDY: {
		"cloud": 0.34, "precipitation": 0.00, "fog": 0.07,
		"wind": 5.0, "storm": 0.00, "dim": 0.06,
	},
	State.CLOUDY: {
		"cloud": 0.72, "precipitation": 0.00, "fog": 0.14,
		"wind": 7.5, "storm": 0.06, "dim": 0.14,
	},
	State.FOG: {
		"cloud": 0.55, "precipitation": 0.00, "fog": 1.00,
		"wind": 2.0, "storm": 0.00, "dim": 0.18,
	},
	State.LIGHT_RAIN: {
		"cloud": 0.82, "precipitation": 0.34, "fog": 0.28,
		"wind": 9.5, "storm": 0.10, "dim": 0.24,
	},
	State.HEAVY_RAIN: {
		"cloud": 0.93, "precipitation": 0.72, "fog": 0.42,
		"wind": 14.0, "storm": 0.35, "dim": 0.33,
	},
	State.STORM: {
		"cloud": 1.00, "precipitation": 1.00, "fog": 0.52,
		"wind": 22.0, "storm": 1.00, "dim": 0.44,
	},
}

## Allowed successors, weighted.  There is deliberately no CLEAR -> STORM edge:
## that is the structural guarantee behind "do not instantly switch CLEAR to
## FULL STORM".  Storms are only reachable through the rain chain.
const TRANSITIONS := {
	State.CLEAR: [
		[State.PARTLY_CLOUDY, 0.62], [State.CLEAR, 0.18], [State.FOG, 0.20],
	],
	State.PARTLY_CLOUDY: [
		[State.CLOUDY, 0.42], [State.CLEAR, 0.24], [State.PARTLY_CLOUDY, 0.16],
		[State.LIGHT_RAIN, 0.12], [State.FOG, 0.06],
	],
	State.CLOUDY: [
		[State.LIGHT_RAIN, 0.30], [State.PARTLY_CLOUDY, 0.27], [State.CLOUDY, 0.14],
		[State.HEAVY_RAIN, 0.13], [State.FOG, 0.10], [State.STORM, 0.06],
	],
	State.FOG: [
		[State.PARTLY_CLOUDY, 0.42], [State.CLOUDY, 0.36], [State.CLEAR, 0.22],
	],
	State.LIGHT_RAIN: [
		[State.CLOUDY, 0.34], [State.HEAVY_RAIN, 0.28], [State.PARTLY_CLOUDY, 0.18],
		[State.LIGHT_RAIN, 0.14], [State.STORM, 0.06],
	],
	State.HEAVY_RAIN: [
		[State.STORM, 0.30], [State.CLOUDY, 0.32], [State.LIGHT_RAIN, 0.28],
		[State.HEAVY_RAIN, 0.10],
	],
	State.STORM: [
		[State.HEAVY_RAIN, 0.55], [State.LIGHT_RAIN, 0.27], [State.CLOUDY, 0.18],
	],
}

## Rain states that should be reachable at any hour; fog only in the morning.
const _CACHE_LIMIT := 24

static var _episode_cache: Dictionary = {}
static var _strike_cache: Dictionary = {}


static func state_name(state: int) -> StringName:
	var s := clampi(state, 0, STATE_COUNT - 1)
	return STATE_NAMES[s]


static func state_from_name(name: String) -> int:
	var wanted := StringName(name.strip_edges().to_lower().replace(" ", "_"))
	var idx := STATE_NAMES.find(wanted)
	return idx   # -1 when unknown


## Contiguous weather episodes covering 00:00-24:00 of `day`, deterministic in
## (seed_used, day).  Cached; the returned array must be treated as read-only.
static func episodes_for_day(seed_used: int, day: int) -> Array:
	var key := "%d:%d" % [seed_used, day]
	var cached: Variant = _episode_cache.get(key)
	if cached != null:
		return cached

	var rng := WorldSeed.rng_for_seed(seed_used, "environment_weather", [day])
	var out: Array = []
	var minute := 0.0
	var state := int(rng.randi_range(State.CLEAR, State.CLOUDY))
	var index := 0
	while minute < float(EnvironmentConfig.MINUTES_PER_DAY) - 0.001:
		var span := rng.randf_range(
			EnvironmentConfig.EPISODE_MIN_MINUTES, EnvironmentConfig.EPISODE_MAX_MINUTES)
		var end := minf(minute + span, float(EnvironmentConfig.MINUTES_PER_DAY))
		out.append({
			"index": index,
			"start": minute,
			"end": end,
			"state": state,
			"wind_dir": rng.randf_range(0.0, TAU),
			"gust": rng.randf_range(0.55, 1.35),
		})
		minute = end
		index += 1
		state = _pick_successor(rng, state, minute)

	if _episode_cache.size() >= _CACHE_LIMIT:
		_episode_cache.clear()
	_episode_cache[key] = out
	return out


## Fills `out` (mutated in place, no allocation) with the blended parameter
## vector for an absolute game minute.  See PARAM_KEYS for the contract, plus:
##   state, target_state, blend 0..1, progress 0..1, wind_direction (rad),
##   gust, episode_start, episode_end, episode_index, day, minute_of_day
static func sample(seed_used: int, total_minutes: float, out: Dictionary) -> void:
	var day := TimeOfDay.day_of(total_minutes)
	var mod_min := TimeOfDay.minute_of_day_of(total_minutes)
	var eps := episodes_for_day(seed_used, day)
	var idx := _episode_index(eps, mod_min)
	var cur: Dictionary = eps[idx]
	var prev: Dictionary = eps[idx - 1] if idx > 0 else cur

	var span := maxf(float(cur["end"]) - float(cur["start"]), 1.0)
	var window := minf(EnvironmentConfig.TRANSITION_MINUTES, span * 0.5)
	var progress := clampf((mod_min - float(cur["start"])) / maxf(window, 0.001), 0.0, 1.0)
	var blend := progress * progress * (3.0 - 2.0 * progress)   # smoothstep

	var cur_params: Dictionary = PARAMS[int(cur["state"])]
	var prev_params: Dictionary = PARAMS[int(prev["state"])]
	for key in PARAM_KEYS:
		out[key] = lerpf(float(prev_params[key]), float(cur_params[key]), blend)

	out["wind_direction"] = lerp_angle(float(prev["wind_dir"]), float(cur["wind_dir"]), blend)
	out["gust"] = lerpf(float(prev["gust"]), float(cur["gust"]), blend)
	out["blend"] = blend
	out["progress"] = progress
	out["target_state"] = int(cur["state"])
	out["state"] = int(cur["state"]) if blend >= 0.5 else int(prev["state"])
	out["episode_start"] = float(cur["start"])
	out["episode_end"] = float(cur["end"])
	out["episode_index"] = int(cur["index"])
	out["day"] = day
	out["minute_of_day"] = mod_min


## Deterministic lightning strikes for a day, sorted by minute.  Each entry:
## minute (relative to the day), intensity 0..1, distance (m), stages,
## thunder_delay (real seconds), wind_dir.
static func lightning_strikes_for_day(seed_used: int, day: int) -> Array:
	var key := "L%d:%d" % [seed_used, day]
	var cached: Variant = _strike_cache.get(key)
	if cached != null:
		return cached

	var out: Array = []
	for ep: Dictionary in episodes_for_day(seed_used, day):
		if int(ep["state"]) != State.STORM:
			continue
		var rng := WorldSeed.rng_for_seed(
			seed_used, "environment_lightning", [day, int(ep["index"])])
		var minute := float(ep["start"]) + EnvironmentConfig.LIGHTNING_STORM_BUILD_MINUTES
		var count := 0
		while minute < float(ep["end"]) - 1.0 \
				and count < EnvironmentConfig.LIGHTNING_MAX_STRIKES_PER_EPISODE:
			var distance := 320.0 + 5200.0 * pow(rng.randf(), 2.0)
			out.append({
				"minute": minute,
				"intensity": rng.randf_range(0.35, 1.0),
				"distance": distance,
				"stages": 2 + (1 if rng.randf() < 0.45 else 0),
				"thunder_delay": clampf(distance / EnvironmentConfig.THUNDER_SPEED_MPS,
					EnvironmentConfig.THUNDER_DELAY_MIN, EnvironmentConfig.THUNDER_DELAY_MAX),
				"wind_dir": float(ep["wind_dir"]),
			})
			count += 1
			minute += rng.randf_range(
				EnvironmentConfig.LIGHTNING_STRIKE_MIN_GAP,
				EnvironmentConfig.LIGHTNING_STRIKE_MAX_GAP)

	if _strike_cache.size() >= _CACHE_LIMIT:
		_strike_cache.clear()
	_strike_cache[key] = out
	return out


## Next scheduled strike strictly after `total_minutes`, with an extra
## "abs_minute" key, or {} when the schedule is empty.
static func next_strike(seed_used: int, total_minutes: float) -> Dictionary:
	var day := TimeOfDay.day_of(total_minutes)
	for d in [day, day + 1]:
		for strike: Dictionary in lightning_strikes_for_day(seed_used, d):
			var abs_minute := float(d - 1) * 1440.0 + float(strike["minute"])
			if abs_minute > total_minutes + 0.0001:
				var info := strike.duplicate()
				info["abs_minute"] = abs_minute
				return info
	return {}


## Fraction of the day that is stormy, per state parameters - useful for the
## debug overlay and for tests that check "storms are rare, not constant".
static func storm_share_of_day(seed_used: int, day: int) -> float:
	var total := 0.0
	for ep: Dictionary in episodes_for_day(seed_used, day):
		if int(ep["state"]) == State.STORM:
			total += float(ep["end"]) - float(ep["start"])
	return total / 1440.0


static func _episode_index(eps: Array, minute: float) -> int:
	for i in range(eps.size()):
		if minute < float(eps[i]["end"]) - 0.000001:
			return i
	return maxi(eps.size() - 1, 0)


static func _fog_start_allowed(start_minute: float) -> bool:
	var hour := start_minute / 60.0
	return hour >= float(EnvironmentConfig.FOG_START_HOUR_MIN) \
		and hour <= float(EnvironmentConfig.FOG_START_HOUR_MAX)


static func _pick_successor(rng: RandomNumberGenerator, state: int, start_minute: float) -> int:
	var options: Array = TRANSITIONS.get(state, [[State.PARTLY_CLOUDY, 1.0]])
	for _attempt in range(4):
		var pick := _weighted_pick(rng, options)
		if pick != State.FOG or _fog_start_allowed(start_minute):
			return pick
	return State.PARTLY_CLOUDY if state != State.FOG else State.CLEAR


static func _weighted_pick(rng: RandomNumberGenerator, options: Array) -> int:
	var total := 0.0
	for option: Array in options:
		total += float(option[1])
	var roll := rng.randf() * maxf(total, 0.0001)
	var acc := 0.0
	for option: Array in options:
		acc += float(option[1])
		if roll <= acc:
			return int(option[0])
	return int(options[options.size() - 1][0])
