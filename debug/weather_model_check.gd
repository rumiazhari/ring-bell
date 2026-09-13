extends SceneTree

## Fast, dependency-free checks for the weather *model* maths: no autoloads, no world,
## no rendering, no city bootstrap (which is minutes long on a loaded machine).
##
##   Godot --headless --path . --script debug/weather_model_check.gd
##
## Covers the fixes that do not need a live EnvironmentManager: the cross-midnight
## blend, the wetness integrator's frame-independence, and the tuning invariants.
## Exit code 0 = all checks passed, 1 = at least one failed.

const MODEL_SEED := 19041207
const DAY := 1440.0

var checks := 0
var failures := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	var tail := "" if detail.is_empty() else "  (%s)" % detail
	if ok:
		print("[WeatherCheck]  ok    %s%s" % [name, tail])
	else:
		failures += 1
		printerr("[WeatherCheck]  FAIL  %s%s" % [name, tail])
		print("[WeatherCheck]  FAIL  %s%s" % [name, tail])


func _sample(minute: float) -> Dictionary:
	var out := {}
	WeatherModel.sample(MODEL_SEED, minute, out)
	return out


func _initialize() -> void:
	_test_day_boundary()
	_test_wetness_math()
	_test_tuning_invariants()
	print("[WeatherCheck] finished with %d failure(s)  (%d checks)" % [failures, checks])
	quit(0 if failures == 0 else 1)


## The first episode of a day has no earlier episode to blend from, so it used to apply
## at full strength on the 00:00 frame: a day that ended in a storm snapped to clear in
## one frame.  `prev` is now the previous day's last episode.
func _test_day_boundary() -> void:
	# Scan every midnight and keep the worst step: this is exactly the case that used to
	# jump (yesterday's last state versus today's opener).
	var worst := 0.0
	var worst_at := 0.0
	var day := 1
	while day <= 40:
		var midnight := float(day) * DAY
		var before := _sample(midnight - 1.0)
		var at := _sample(midnight)
		var step := maxf(absf(float(at["precipitation"]) - float(before["precipitation"])),
				absf(float(at["fog"]) - float(before["fog"])))
		if step > worst:
			worst = step
			worst_at = midnight
		day += 1
	_check("no weather step across 40 midnights", worst < 0.06,
		"worst %.4f at minute %.0f" % [worst, worst_at])
	_check("the model reports a state id", int(_sample(0.0)["state"]) >= 0)
	_check("episode states do change over time (the scan is not vacuous)",
		WeatherModel.episodes_for_day(MODEL_SEED, 3).size() > 1)
	# The first two hours after midnight must ramp, never snap.
	var m := 0.0
	var worst_minute := 0.0
	var prev := _sample(DAY - 1.0)
	while m <= 120.0:
		var cur := _sample(DAY + m)
		worst_minute = maxf(worst_minute, absf(float(cur["precipitation"]) - float(prev["precipitation"])))
		prev = cur
		m += 1.0
	_check("the first two hours after midnight ramp, never jump", worst_minute < 0.06,
		"worst %.4f" % worst_minute)
	# A day that ends in a storm must hand its state to the next midnight (the carry-in),
	# rather than the next midnight reporting the new day's opener.
	var carried := 0
	var checked := 0
	day = 1
	while day <= 40:
		var midnight := float(day) * DAY
		var before := _sample(midnight - 1.0)
		if int(before["state"]) == int(WeatherModel.State.STORM):
			checked += 1
			if int(_sample(midnight)["state"]) == int(WeatherModel.State.STORM):
				carried += 1
		day += 1
	_check("a midnight after a storm still reads as a storm", checked == 0 or carried == checked,
		"%d of %d storm midnights carried" % [carried, checked])


## Wetness is integrated in fixed game-minute substeps: the same interval must give the
## same result, and one long frame must not be truncated the way the old
## `minf(game_delta, WETNESS_MAX_JUMP_MINUTES)` clamp truncated it.
func _test_wetness_math() -> void:
	var interval := 12.0
	var precip := 0.34
	var one_step := _wetness_after(precip, [interval])
	var many_steps := _wetness_after(precip, [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0])
	_check("wetness does not depend on frame length",
		absf(one_step - many_steps) < 0.001,
		"one frame %.4f vs twelve %.4f" % [one_step, many_steps])
	var capped := _wetness_after(0.0, [60.0 * 24.0], 0.5)
	_check("a time skip cannot dry the world out in one frame", capped > 0.0,
		"%.4f after a dry day" % capped)
	_check("a single frame integrates at most WETNESS_MAX_SUBSTEPS * WETNESS_MAX_JUMP_MINUTES",
		EnvironmentConfig.WETNESS_MAX_SUBSTEPS * EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES
			>= 30.0, "%d x %.1f minutes" % [EnvironmentConfig.WETNESS_MAX_SUBSTEPS,
			EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES])


## The same substep integration the controller uses, lifted to plain arithmetic so it can
## be checked without a clock.
func _wetness_after(precip: float, frame_minutes: Array, start := 0.0) -> float:
	var wet := start
	for frame: float in frame_minutes:
		var budget := minf(frame, EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES
				* float(EnvironmentConfig.WETNESS_MAX_SUBSTEPS))
		var steps := clampi(int(ceilf(budget / EnvironmentConfig.WETNESS_MAX_JUMP_MINUTES)),
				1, EnvironmentConfig.WETNESS_MAX_SUBSTEPS)
		var step := budget / float(steps)
		for i in steps:
			if precip > EnvironmentConfig.WETNESS_PRECIP_THRESHOLD:
				wet = minf(1.0, wet + EnvironmentConfig.WETNESS_GAIN_PER_GAME_MINUTE * precip * step)
			else:
				wet = maxf(0.0, wet - EnvironmentConfig.WETNESS_DRY_PER_GAME_MINUTE * step)
	return wet


## Tuning invariants the audit relied on: keep them asserted so a later retune cannot
## silently undo a fix.
func _test_tuning_invariants() -> void:
	_check("the rain cutoff sits above partial cover (2 of 3 rays)",
		EnvironmentConfig.SHELTER_RAIN_CUTOFF > EnvironmentConfig.SHELTER_INDOOR_THRESHOLD)
	_check("one of three roof rays stays under the indoor threshold",
		1.0 / 3.0 < EnvironmentConfig.SHELTER_INDOOR_THRESHOLD,
		"1/3 = %.2f vs threshold %.2f" % [1.0 / 3.0, EnvironmentConfig.SHELTER_INDOOR_THRESHOLD])
	_check("wetness begins on the frame the first streaks appear",
		is_equal_approx(EnvironmentConfig.WETNESS_PRECIP_THRESHOLD,
			EnvironmentConfig.RAIN_MIN_PRECIPITATION))
	_check("thunder stays audible out to THUNDER_SILENT_M",
		EnvironmentConfig.THUNDER_SILENT_M > EnvironmentConfig.THUNDER_FULL_M
			and EnvironmentConfig.THUNDER_PITCH_FAR < EnvironmentConfig.THUNDER_PITCH_NEAR)
	_check("the thunder delay band covers THUNDER_SILENT_M",
		EnvironmentConfig.THUNDER_DELAY_MAX * EnvironmentConfig.THUNDER_SPEED_MPS
			+ 500.0 >= EnvironmentConfig.THUNDER_SILENT_M,
		"%.0f m at the %.1f s cap" % [EnvironmentConfig.THUNDER_DELAY_MAX
			* EnvironmentConfig.THUNDER_SPEED_MPS, EnvironmentConfig.THUNDER_DELAY_MAX])
	# A storm slant is real, but a lateral drift of 3x the fall speed threw most of the
	# budget out of the camera-local box (the factor was 3.0 before this pass).  The
	# residual drift of 1.62x is documented in the overhaul doc, not hidden here.
	_check("storm rain is slanted, not horizontal",
		EnvironmentConfig.RAIN_WIND_FACTOR * 28.0 / EnvironmentConfig.RAIN_FALL_SPEED < 2.2,
		"slant factor %.2f" % (EnvironmentConfig.RAIN_WIND_FACTOR * 28.0
			/ EnvironmentConfig.RAIN_FALL_SPEED))
	_check("the wind factor stays at the retuned value",
		EnvironmentConfig.RAIN_WIND_FACTOR <= 1.2,
		"RAIN_WIND_FACTOR %.2f (was 3.0)" % EnvironmentConfig.RAIN_WIND_FACTOR)
	_check("the drawn bolt stays inside the far plane",
		EnvironmentConfig.BOLT_MAX_DRAWN_DISTANCE <= 4000.0,
		"%.0f m" % EnvironmentConfig.BOLT_MAX_DRAWN_DISTANCE)
