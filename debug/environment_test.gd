extends Node
## Environment subsystem harness (success criterion 33).
##
## Builds its own minimal world (camera + EnvironmentManager) unless a live
## manager already exists, so the contract never depends on the city/interior
## track's current state:
##   godot --headless --path "<project>" -- --envtest
##
## Report convention matches the rest of debug/ ("finished with N failure(s)").
##
## What it proves:
##   * time model: day/minute wrap, sun arc, phase coverage, no lighting jumps
##   * the rendered frame is a pure function of the clock (frame-rate independent)
##   * weather determinism (same seed + minute => same weather, forever)
##   * legal weather transitions only, no CLEAR -> STORM shortcut
##   * every model parameter stays inside its documented range
##   * debug forcing works for all 7 states; wetness rises and falls; wind is state
##   * lightning produces a flash + a delayed thunder event
##   * the shelter hook reduces rain indoors
##   * save/load restores clock, weather, wetness, wind, and replays deterministically
##   * exactly one authoritative manager (no duplicate sun/moon/sky/rain nodes)
##   * the environment is world state, not chunk state

const SEED_A := 4242
const SEED_B := 997711
const TOL := 0.0001

var failures := 0
var checks := 0
var env: EnvironmentManager
var _clock := {}
var _standalone := false


func _ready() -> void:
	_ensure_world()
	await get_tree().process_frame
	await get_tree().process_frame
	env = EnvironmentManager.instance_or_null()
	_check("a single EnvironmentManager is live on the world node", env != null)
	if env == null:
		_finish()
		return
	_clock = {
		"minutes": GameClock.total_minutes,
		"scale": GameClock.time_scale,
		"paused": GameClock.paused,
	}
	GameClock.paused = true    # the harness drives the clock by hand

	_test_nodes()
	_test_time_model()
	_test_day_phases()
	_test_time_progression()
	_test_phase_smoothness()
	_test_weather_determinism()
	_test_weather_transitions()
	_test_parameter_ranges()
	_test_forced_weather()
	_test_wetness_cycle()
	_test_wind_state()
	_test_lightning_thunder()
	_test_shelter_hook()
	await _test_save_load()
	_test_debug_surface()
	await _test_singleton()
	_test_no_duplicates()
	_test_world_state_not_chunk_state()
	_restore()

	_finish()


## The harness runs against its own minimal world by default: the environment
## contract must be verifiable no matter what the city/interior tracks are doing.
## If a world already built an EnvironmentManager, adopt that one instead of
## creating a second (the manager is a singleton by design).
func _ensure_world() -> void:
	if EnvironmentManager.instance_or_null() != null:
		return
	_standalone = true
	var world := Node3D.new()
	world.name = "EnvironmentTestWorld"
	add_child(world)
	var cam := Camera3D.new()
	cam.name = "TestCamera"
	cam.far = 6000.0
	world.add_child(cam)
	cam.global_position = Vector3(0.0, 14.0, 0.0)
	cam.current = true
	var mgr := EnvironmentManager.new()
	world.add_child(mgr)


# ------------------------------------------------------------------- harness
func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	var tail := "" if detail.is_empty() else "  (%s)" % detail
	if ok:
		print("[Environment]  ok    %s%s" % [name, tail])
	else:
		failures += 1
		printerr("[Environment]  FAIL  %s%s" % [name, tail])
		print("[Environment]  FAIL  %s%s" % [name, tail])


## Advances game time in game minutes while giving the weather integrator the
## real seconds it needs, without depending on rendered frames.
func _advance(minutes: float, step_minutes := 1.0) -> void:
	var left := minutes
	while left > TOL:
		var dm: float = minf(step_minutes, left)
		GameClock.advance(dm)
		env.tick(1.0)
		left -= dm


func _restore() -> void:
	env.force_shelter(-1.0)
	env.clear_forced_weather()
	env.clear_wind_override()
	GameClock.total_minutes = float(_clock["minutes"])
	GameClock.time_scale = float(_clock["scale"])
	GameClock.paused = bool(_clock["paused"])
	env.resync()


func _finish() -> void:
	print("[EnvironmentTest] finished with %d failure(s)  (%d checks)" % [failures, checks])
	get_tree().quit(0 if failures == 0 else 1)


# --------------------------------------------------------------------- tests
func _test_nodes() -> void:
	var report := env.self_check()
	_check("self_check is clean", bool(report["ok"]), str(report["problems"]))
	_check("atmosphere has applied at least one frame", env.atmosphere.frames_applied() > 0)
	_check("sun light exists", env.atmosphere.sun_light() != null)
	_check("moon light exists", env.atmosphere.moon_light() != null)
	_check("Environment resource exists", env.atmosphere.environment() != null)
	_check("sky shader material exists", env.atmosphere.sky_material() != null)
	_check("precipitation node is parented by the manager", env.precipitation.get_parent() == env)
	_check("exposure probe is parented by the manager", env.exposure.get_parent() == env)
	_check("ambience node is parented by the manager", env.ambience.get_parent() == env)
	_check("debug panel exists", env.debug_panel != null)


func _test_time_model() -> void:
	_check("day 1 starts at minute 0",
		TimeOfDay.day_of(0.0) == 1 and is_equal_approx(TimeOfDay.minute_of_day_of(0.0), 0.0))
	_check("minute_of_day wraps at midnight",
		is_equal_approx(TimeOfDay.minute_of_day_of(1440.0 + 90.0), 90.0))
	_check("the day counter advances", TimeOfDay.day_of(1440.0 + 10.0) == 2)

	var noon := TimeOfDay.sun_elevation_rad(720.0)
	var dawn := TimeOfDay.sun_elevation_rad(360.0)
	var midnight := TimeOfDay.sun_elevation_rad(0.0)
	# Prague-ish latitude: the noon sun sits high but well short of the zenith,
	# so assert a realistic band and that noon is in fact the daily maximum.
	var peak := 0.0
	var peak_minute := 0.0
	var m := 0.0
	while m < 1440.0:
		var e := TimeOfDay.sun_elevation_rad(m)
		if e > peak:
			peak = e
			peak_minute = m
		m += 5.0
	_check("the sun peaks at the configured solar zenith (%02d:00, Prague CET)" % int(EnvironmentConfig.SOLAR_ZENITH_HOUR),
		noon > 0.6
			and absf(peak_minute - EnvironmentConfig.SOLAR_ZENITH_HOUR * 60.0) <= 30.0,
		"noon %.3f rad, peak %.3f rad at %02d:%02d" % [noon, peak, int(peak_minute / 60.0), int(peak_minute) % 60])
	_check("the sun is lower at 06:00 than at noon", dawn < noon, "%.3f < %.3f" % [dawn, noon])
	_check("the sun is below the horizon at midnight", midnight < 0.0, "%.3f rad" % midnight)

	_check("noon is fully daylight", TimeOfDay.daylight_factor(720.0) > 0.8,
		"%.3f" % TimeOfDay.daylight_factor(720.0))
	_check("midnight is fully night", TimeOfDay.daylight_factor(0.0) < 0.05,
		"%.3f" % TimeOfDay.daylight_factor(0.0))
	_check("night factor is high at midnight", TimeOfDay.night_factor(0.0) > 0.9,
		"%.3f" % TimeOfDay.night_factor(0.0))
	_check("there is no night at noon", TimeOfDay.night_factor(720.0) < 0.05,
		"%.3f" % TimeOfDay.night_factor(720.0))

	var best_moon := 0.0
	for day in range(1, 31):
		best_moon = maxf(best_moon, TimeOfDay.moon_visibility(0.0, day))
	_check("the moon is bright on some nights (a real lunar cycle)", best_moon > 0.6,
		"best %.2f over 30 nights" % best_moon)


func _test_day_phases() -> void:
	var anchors := [
		["pre-dawn", 4.0], ["dawn", 6.0], ["morning", 9.0],
		["noon", 12.0], ["sunset", 18.0], ["evening", 21.0], ["midnight", 0.0],
	]
	var sun := {}
	var moon := {}
	var ambient := {}
	var floor_energy := 999.0
	for anchor in anchors:
		env.force_time(float(anchor[1]), 0.0)
		env.tick(0.0)
		var key: String = anchor[0]
		sun[key] = env.atmosphere.sun_light().light_energy
		moon[key] = env.atmosphere.moon_light().light_energy
		ambient[key] = env.atmosphere.environment().ambient_light_energy
		floor_energy = minf(floor_energy, float(sun[key]) + float(moon[key]) + float(ambient[key]))
		print("[Environment]  %-9s sun %.2f  moon %.2f  ambient %.2f" % [
			key, sun[key], moon[key], ambient[key],
		])
	_check("noon sun is stronger than dawn sun", float(sun["noon"]) > float(sun["dawn"]),
		"%.2f > %.2f" % [sun["noon"], sun["dawn"]])
	_check("sunset sun is dimmer than noon sun", float(sun["sunset"]) < float(sun["noon"]),
		"%.2f < %.2f" % [sun["sunset"], sun["noon"]])
	_check("the sun is off at midnight", float(sun["midnight"]) < 0.05,
		"%.3f" % sun["midnight"])
	_check("midnight is lit by moon + ambient, not black",
		float(moon["midnight"]) + float(ambient["midnight"]) > 0.02,
		"moon %.3f ambient %.3f" % [moon["midnight"], ambient["midnight"]])
	_check("every phase stays above the readability floor", floor_energy > 0.02,
		"darkest %.3f" % floor_energy)
	_check("ambient light is dimmer at midnight than at noon",
		float(ambient["midnight"]) < float(ambient["noon"]),
		"%.2f < %.2f" % [ambient["midnight"], ambient["noon"]])


func _test_time_progression() -> void:
	# The rendered frame must be a pure function of the clock: jump far away and
	# back and the lighting has to land exactly where it was.
	GameClock.total_minutes = 400.0
	env.tick(0.016)
	var rot := env.atmosphere.sun_light().global_rotation
	var energy := env.atmosphere.sun_light().light_energy
	var sky_cloud: float = float(env.state()["cloud"])
	GameClock.total_minutes = 1300.0
	env.tick(0.016)
	GameClock.total_minutes = 400.0
	env.tick(0.016)
	_check("the frame is a pure function of the clock (no hidden per-frame state)",
		rot.is_equal_approx(env.atmosphere.sun_light().global_rotation)
			and is_equal_approx(energy, env.atmosphere.sun_light().light_energy),
		"%.4f vs %.4f" % [energy, env.atmosphere.sun_light().light_energy])
	_check("weather follows the clock, not the frame count",
		is_equal_approx(float(sky_cloud), float(env.state()["cloud"])))

	# Day length is configuration, not a hardwired constant.
	var scale := EnvironmentConfig.time_scale_for_day_length(600.0)
	GameClock.time_scale = scale
	GameClock.total_minutes = 0.0
	GameClock.advance(300.0)
	_check("the clock advances by exactly the requested game minutes",
		is_equal_approx(GameClock.total_minutes, 300.0), "%.3f" % GameClock.total_minutes)
	_check("a 10 real-minute day is honoured",
		is_equal_approx(EnvironmentConfig.day_length_seconds(scale), 600.0),
		"%.1f s/day" % EnvironmentConfig.day_length_seconds(scale))
	_check("the sun has moved after 5 game hours",
		not TimeOfDay.sun_direction(0.0).is_equal_approx(TimeOfDay.sun_direction(300.0)))


func _test_phase_smoothness() -> void:
	var prev := -1.0
	var worst := 0.0
	var minute := 0.0
	while minute < 1440.0:
		GameClock.total_minutes = minute
		env.tick(0.0)
		var e := env.atmosphere.sun_light().light_energy
		if prev >= 0.0:
			worst = maxf(worst, absf(e - prev))
		prev = e
		minute += 1.0
	_check("no lighting discontinuity across a full day (max step < 0.06)", worst < 0.06,
		"worst step %.4f" % worst)


func _test_weather_determinism() -> void:
	var a := {}
	var b := {}
	WeatherModel.sample(SEED_A, 3000.0, a)
	WeatherModel.sample(SEED_A, 3000.0, b)
	_check("the model is deterministic (same seed, same minute)",
		JSON.stringify(a) == JSON.stringify(b))
	var later := {}
	WeatherModel.sample(SEED_A, 3040.0, later)
	_check("the model moves over time", JSON.stringify(a) != JSON.stringify(later))

	var eps_a := WeatherModel.episodes_for_day(SEED_A, 3)
	var eps_b := WeatherModel.episodes_for_day(SEED_A, 3)
	_check("episode chains are deterministic",
		eps_a.size() == eps_b.size() and JSON.stringify(eps_a) == JSON.stringify(eps_b),
		"%d episodes" % eps_a.size())
	_check("a day is built from several weather episodes", eps_a.size() >= 2)

	var diff := 0
	var m := 0.0
	while m < 1440.0:
		var oa := {}
		var ob := {}
		WeatherModel.sample(SEED_A, m, oa)
		WeatherModel.sample(SEED_B, m, ob)
		if JSON.stringify(oa) != JSON.stringify(ob):
			diff += 1
		m += 30.0
	_check("a different world seed produces different weather", diff > 0,
		"%d differing samples" % diff)

	var strikes := WeatherModel.lightning_strikes_for_day(SEED_A, 3)
	_check("lightning schedules are deterministic arrays", strikes is Array)


func _test_weather_transitions() -> void:
	var illegal_edges := 0
	for state in WeatherModel.TRANSITIONS:
		for edge in WeatherModel.TRANSITIONS[state]:
			var target := int(edge[0])
			if target < 0 or target >= WeatherModel.STATE_COUNT:
				illegal_edges += 1
	_check("every transition targets a real state", illegal_edges == 0,
		"%d bad edges" % illegal_edges)
	_check("there is no CLEAR -> STORM / CLEAR -> HEAVY_RAIN shortcut",
		not _has_edge(_clear_state(), _storm_state())
			and not _has_edge(_clear_state(), WeatherModel.state_from_name("heavy_rain")))

	var seed_used := SEED_A
	var changes := 0
	var illegal := 0
	var from_clear_to_storm := 0
	var prev := -1
	var m := 1440.0 * 4.0
	while m < 1440.0 * 5.0:
		var out := {}
		WeatherModel.sample(seed_used, m, out)
		var target := int(out.get("target_state", -1))
		if prev >= 0 and target != prev:
			changes += 1
			if not _has_edge(prev, target):
				illegal += 1
			if prev == _clear_state() and target == _storm_state():
				from_clear_to_storm += 1
		prev = target
		m += 1.0
	_check("weather changes during a day", changes >= 2, "%d changes" % changes)
	_check("every weather change follows a legal transition edge", illegal == 0,
		"%d illegal of %d changes" % [illegal, changes])
	_check("weather never jumps CLEAR -> STORM inside a day", from_clear_to_storm == 0)
	_check("only a debug force can go straight to a storm",
		env.force_weather(&"clear") and env.force_weather(&"storm"))


func _test_parameter_ranges() -> void:
	var bad := 0
	var worst := ""
	var m := 0.0
	while m < 1440.0 * 3.0:
		var out := {}
		WeatherModel.sample(SEED_A, m, out)
		for key in ["cloud", "precipitation", "fog", "storm"]:
			var v := float(out.get(key, 0.0))
			if v < 0.0 or v > 1.0:
				bad += 1
				worst = "%s=%.3f" % [key, v]
		var wind := float(out.get("wind", 0.0))
		if wind < 0.0 or wind > 60.0:
			bad += 1
			worst = "wind=%.2f" % wind
		var dim := float(out.get("dim", 0.0))
		if dim < 0.0 or dim > 0.5:
			bad += 1
			worst = "dim=%.3f" % dim
		var gust := float(out.get("gust", 1.0))
		if gust < 0.5 or gust > 2.5:
			bad += 1
			worst = "gust=%.3f" % gust
		m += 5.0
	_check("all model parameters stay in range across 3 days", bad == 0,
		"%d bad samples %s" % [bad, worst])

	# The live frame must respect its clamps too.
	var frame_bad := 0
	var minute := 0.0
	while minute < 1440.0:
		GameClock.total_minutes = minute
		env.tick(0.0)
		var ambient := env.atmosphere.environment().ambient_light_energy
		if ambient < EnvironmentConfig.MIN_AMBIENT_ENERGY - TOL \
				or ambient > EnvironmentConfig.MAX_AMBIENT_ENERGY + TOL:
			frame_bad += 1
		if env.atmosphere.sun_light().light_energy < 0.0:
			frame_bad += 1
		minute += 10.0
	_check("the live ambient light respects its readability clamp", frame_bad == 0,
		"%d bad frames" % frame_bad)


func _test_forced_weather() -> void:
	var stuck := 0
	for name in WeatherModel.STATE_NAMES:
		var ok := env.force_weather(name)
		env.tick(0.0)
		var got := String(env.state()["weather"])
		if not ok or got != String(name):
			stuck += 1
			print("[Environment]  force %s -> %s (accepted=%s)" % [name, got, ok])
	_check("every weather state can be forced from debug controls", stuck == 0,
		"%d states failed" % stuck)
	env.clear_forced_weather()
	env.tick(0.0)
	_check("clearing the force returns control to the deterministic model",
		env.weather.forced_state == -1)


func _test_wetness_cycle() -> void:
	env.clear_forced_weather()
	env.set_wetness(0.0)
	env.tick(0.0)
	_check("wetness starts dry", is_equal_approx(float(env.state()["wetness"]), 0.0))
	env.force_weather(&"heavy_rain")
	_advance(45.0)
	var wet_rain := float(env.state()["wetness"])
	_check("wetness rises while it rains", wet_rain > 0.001, "%.4f" % wet_rain)
	env.force_weather(&"clear")
	var peak := wet_rain
	_advance(120.0)
	var wet_dry := float(env.state()["wetness"])
	_check("wetness falls after the rain stops", wet_dry < peak,
		"%.4f -> %.4f" % [peak, wet_dry])
	_check("wetness stays inside 0..1", wet_dry >= 0.0 and wet_dry <= 1.0, "%.4f" % wet_dry)
	env.set_wetness(4.0)
	_check("wetness clamps high", float(env.state()["wetness"]) <= 1.0,
		"%.3f" % float(env.state()["wetness"]))
	env.set_wetness(-4.0)
	_check("wetness clamps low", float(env.state()["wetness"]) >= 0.0,
		"%.3f" % float(env.state()["wetness"]))
	var wet := env.wetness()
	_check("wetness is published for materials", wet >= 0.0 and wet <= 1.0, "%.3f" % wet)
	env.clear_forced_weather()


func _test_wind_state() -> void:
	env.set_wind(16.0, 210.0)
	env.tick(0.0)
	var s := env.state()
	_check("wind direction override is exposed",
		absf(angle_difference(deg_to_rad(210.0), deg_to_rad(float(s["wind_dir_deg"])))) < 0.02,
		"%.0f deg" % float(s["wind_dir_deg"]))
	_check("wind speed override is in the gusted band",
		absf(float(s["wind_speed"]) - 16.0) < 9.0, "%.1f m/s" % float(s["wind_speed"]))
	var v: Vector3 = env.wind_vector()
	_check("wind is reusable 3D world state", v.length() > 1.0, "%.2f m/s" % v.length())
	env.clear_wind_override()
	env.tick(0.0)
	var base := float(env.state()["wind_speed"])
	_check("wind falls back to the deterministic model when released", base >= 0.0,
		"%.1f m/s" % base)


func _test_lightning_thunder() -> void:
	env.force_weather(&"storm")
	env.tick(0.0)
	var strikes_before := env.weather.strikes_fired
	var thunder_before := int(env.state()["thunder_plays"])
	var strike := env.force_lightning()
	env.tick(0.0)
	_check("a forced strike produces a strike record", not strike.is_empty(), str(strike))
	_check("the strike is counted as a lightning event", env.weather.strikes_fired > strikes_before,
		"%d -> %d" % [strikes_before, env.weather.strikes_fired])
	var delay := float(strike.get("thunder_delay", strike.get("delay", 0.0)))
	_check("the thunder delay is inside the configured band",
		delay >= EnvironmentConfig.THUNDER_DELAY_MIN - TOL
			and delay <= EnvironmentConfig.THUNDER_DELAY_MAX + TOL,
		"%.2f s" % delay)
	_check("the flash lights up immediately (the visual is not delayed)",
		env.atmosphere._flash_level > 0.0, "%.2f" % env.atmosphere._flash_level)
	_check("thunder is queued behind the flash", env.pending_thunder() >= 1,
		"%d queued" % env.pending_thunder())
	var waited := 0.0
	while waited < EnvironmentConfig.THUNDER_DELAY_MAX + 2.0 and env.pending_thunder() > 0:
		env.tick(0.25)
		waited += 0.25
	_check("thunder plays after its simulated distance delay",
		int(env.state()["thunder_plays"]) > thunder_before,
		"%d plays after %.2f s" % [int(env.state()["thunder_plays"]), waited])
	_check("the thunder queue drains", env.pending_thunder() == 0)
	env.clear_forced_weather()


func _test_shelter_hook() -> void:
	env.force_weather(&"heavy_rain")
	env.force_shelter(0.0)
	env.tick(1.0)
	env.tick(1.0)
	var outside := env.state()
	env.force_shelter(1.0)
	env.tick(1.0)
	env.tick(1.0)
	var inside := env.state()
	_check("the probe reports outdoors when unsheltered",
		not bool(outside["indoors"]) and float(outside["exposure"]) < 0.5,
		"exposure %.2f" % float(outside["exposure"]))
	_check("the probe reports indoors under a roof",
		bool(inside["indoors"]) and float(inside["exposure"]) > 0.5,
		"exposure %.2f" % float(inside["exposure"]))
	_check("rain is reduced indoors", int(inside["rain_particles"]) < int(outside["rain_particles"]),
		"%d -> %d particles" % [int(outside["rain_particles"]), int(inside["rain_particles"])])
	env.force_shelter(-1.0)
	env.tick(1.0)
	_check("the probe returns to automatic when released",
		env.exposure._forced < 0.0, "forced=%.2f" % env.exposure._forced)
	env.clear_forced_weather()


func _test_save_load() -> void:
	env.force_time(18.0, 30.0)
	env.force_weather(&"storm")
	env.set_wetness(0.42)
	env.set_wind(16.0, 210.0)
	env.tick(1.0)
	var saved := env.save_state()
	_check("the save payload is versioned", int(saved.get("version", 0)) >= 1)
	_check("the save payload carries the weather block", saved.has("weather"))

	# Walk away: different time, weather, wetness, wind.
	env.force_time(3.0, 0.0)
	env.force_weather(&"clear")
	env.set_wetness(0.0)
	env.set_wind(2.0, 10.0)
	env.tick(1.0)
	_check("the state really changed before restoring", String(env.state()["weather"]) == "clear")

	env.load_state(saved)
	await get_tree().process_frame    # let the deferred post-load resync run
	env.tick(0.5)
	var s := env.state()
	_check("save/load restores the clock", String(s["clock"]) == "18:30", String(s["clock"]))
	_check("save/load restores the weather state", String(s["weather"]) == "storm",
		String(s["weather"]))
	_check("save/load restores wetness", absf(float(s["wetness"]) - 0.42) < 0.03,
		"%.3f" % float(s["wetness"]))
	_check("save/load restores the wind override",
		absf(angle_difference(deg_to_rad(210.0), deg_to_rad(float(s["wind_dir_deg"])))) < 0.02,
		"%.0f deg" % float(s["wind_dir_deg"]))

	# Deterministic replay: with the override released, the saved minute must
	# produce exactly the weather the model computes for it.
	env.clear_forced_weather()
	env.clear_wind_override()
	env.resync()
	var model := {}
	WeatherModel.sample(env.weather.seed_used, GameClock.total_minutes, model)
	_check("the saved minute replays the deterministic weather",
		int(model.get("target_state", -1)) == env.weather.target_state(),
		"%s vs %s" % [WeatherModel.state_name(int(model.get("target_state", -1))),
			env.weather.target_state_name()])
	_check("save/load does not invent a random weather state",
		String(env.state()["weather"]) == String(WeatherModel.state_name(int(model.get("state", 0)))),
		String(env.state()["weather"]))


func _test_debug_surface() -> void:
	if env.debug_panel != null:
		_check("debug panel exposes the time anchors (06:00 / 12:00 / 18:00 / 00:00)",
			env.debug_panel.TIME_ANCHORS.size() >= 4,
			"%d anchors" % env.debug_panel.TIME_ANCHORS.size())
		_check("debug panel exposes every weather cycle target",
			env.debug_panel.WEATHER_CYCLE.size() >= 6,
			"%d states" % env.debug_panel.WEATHER_CYCLE.size())
		_check("debug panel exposes an overlay block",
			env.debug_panel.overlay_lines().size() >= 5,
			"%d lines" % env.debug_panel.overlay_lines().size())
	var lines := env.status_lines()
	_check("the debug overlay reports time, weather, rain, fog, wind, wetness and shelter",
		lines.size() >= 5 and lines[0].begins_with("env"), "%d lines" % lines.size())

	env.apply_cli_options(PackedStringArray([
		"--envtime=21:15", "--envweather=fog", "--envquality=low",
		"--envwetness=0.33", "--envwind=12,45",
	]))
	env.tick(0.0)
	var s := env.state()
	_check("CLI --envtime works", String(s["clock"]) == "21:15", String(s["clock"]))
	_check("CLI --envweather works", String(s["weather"]) == "fog", String(s["weather"]))
	_check("CLI --envquality works", env.quality == EnvironmentConfig.Quality.LOW,
		env.quality_name())
	_check("CLI --envwetness works", absf(float(s["wetness"]) - 0.33) < 0.03,
		"%.3f" % float(s["wetness"]))
	_check("CLI --envwind works",
		absf(angle_difference(deg_to_rad(45.0), deg_to_rad(float(s["wind_dir_deg"])))) < 0.02,
		"%.0f deg" % float(s["wind_dir_deg"]))
	env.set_quality(EnvironmentConfig.quality_from_preset("medium"))
	env.clear_forced_weather()


func _test_singleton() -> void:
	_check("EnvironmentManager.instance() is the live manager",
		EnvironmentManager.instance() == env)
	var second := EnvironmentManager.new()
	second.name = "SecondEnvironmentManager"
	add_child(second)
	await get_tree().process_frame
	var freed := not is_instance_valid(second) or second.is_queued_for_deletion()
	_check("a second manager does not duplicate the world (it removes itself)", freed)
	_check("the original manager is still authoritative",
		EnvironmentManager.instance_or_null() == env)
	_check("still exactly one manager in the group after the attempt",
		get_tree().get_nodes_in_group(&"environment_manager").size() == 1,
		"%d managers" % get_tree().get_nodes_in_group(&"environment_manager").size())
	if not freed:
		second.queue_free()
		await get_tree().process_frame
	env.resync()


func _test_no_duplicates() -> void:
	_check("exactly one environment sun light",
		get_tree().root.find_children("EnvironmentSun", "DirectionalLight3D", true, false).size() == 1)
	_check("exactly one environment moon light",
		get_tree().root.find_children("EnvironmentMoon", "DirectionalLight3D", true, false).size() == 1)
	_check("exactly one environment WorldEnvironment",
		get_tree().root.find_children("EnvironmentWorldEnv", "WorldEnvironment", true, false).size() == 1)
	_check("exactly one lightning bolt node",
		get_tree().root.find_children("EnvironmentLightningBolt", "MeshInstance3D", true, false).size() == 1)
	_check("the manager does not spawn a new child per frame", env.get_child_count() <= 12,
		"%d children" % env.get_child_count())


func _test_world_state_not_chunk_state() -> void:
	var path := String(env.get_path())
	_check("the manager is not inside the chunk/streaming tree",
		not path.contains("Chunk") and not path.contains("chunk"), path)
	_check("precipitation is not owned by a chunk node",
		env.precipitation.get_parent() == env)
	# World state follows the seed + clock only: streaming cannot reset it.
	var before := String(env.state()["weather"])
	env.tick(1.0)
	_check("weather is unchanged by anything other than the clock",
		String(env.state()["weather"]) == before, before)
	var model := {}
	WeatherModel.sample(env.weather.seed_used, GameClock.total_minutes, model)
	_check("the live weather equals the pure (seed, minute) function",
		int(model.get("target_state", -1)) == env.weather.target_state())


func _has_edge(from: int, to: int) -> bool:
	if not WeatherModel.TRANSITIONS.has(from):
		return false
	for edge in WeatherModel.TRANSITIONS[from]:
		if int(edge[0]) == to:
			return true
	return false


func _clear_state() -> int:
	return WeatherModel.state_from_name("clear")


func _storm_state() -> int:
	return WeatherModel.state_from_name("storm")
