class_name EnvironmentDebug
extends Node
## Debug controls + overlay text for the environment subsystem.
##
## Success criteria 12 (debug controls that make testing easy) and 29 (readable
## debug output without leaving verbose logging on in release).
##
## HOTKEYS - active in debug builds, or in any build launched with `--envdebug`:
##   F6   cycle the time anchor    06:00 -> 12:00 -> 18:00 -> 00:00
##   F7   cycle the weather state  clear -> partly -> cloudy -> fog ->
##                                 light rain -> heavy rain -> storm -> (auto)
##   F8   freeze / unfreeze the clock
##   F10  force a lightning strike (flash + bolt + delayed thunder)
##   F11  cycle the quality tier   low -> medium -> high
##   F12  cycle the shelter probe  auto -> FORCED INDOORS -> FORCED OUTDOORS
##   [    shorter game day          ]  longer game day
##   P    print the full environment state block
##
## The overlay text is pulled by `DebugOverlay` (group "environment_manager"),
## so the environment never has to own UI.  Console output only happens on an
## explicit key press or when `--envverbose` is passed.

const TIME_ANCHORS: Array[Vector2] = [
	Vector2(6.0, 0.0),
	Vector2(12.0, 0.0),
	Vector2(18.0, 0.0),
	Vector2(0.0, 0.0),
]

const WEATHER_CYCLE: Array[StringName] = [
	&"clear", &"partly_cloudy", &"cloudy", &"fog", &"light_rain", &"heavy_rain", &"storm",
]

const DAY_LENGTH_STEP := 1.6

var enabled := true
var verbose := false
var _manager: EnvironmentManager = null
var _anchor := -1
var _weather := -1
var _shelter_mode := 0        # 0 auto, 1 forced indoors, 2 forced outdoors
var _log_accum := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	enabled = OS.is_debug_build() or args.has("--envdebug")
	verbose = args.has("--envverbose")
	set_process_unhandled_input(enabled)
	set_process(enabled)
	if not enabled:
		return
	print("[Environment] debug controls on (F6 time, F7 weather, F8 freeze, F10 lightning, F11 quality, F12 shelter, P state)")


func manager() -> EnvironmentManager:
	if _manager != null and is_instance_valid(_manager):
		return _manager
	_manager = EnvironmentManager.instance_or_null()
	return _manager


func tick(delta: float) -> void:
	if not enabled:
		return
	if not verbose:
		return
	_log_accum += delta
	if _log_accum < 30.0:
		return
	_log_accum = 0.0
	var env := manager()
	if env != null:
		print(env.status_line())


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var env := manager()
	if env == null:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_F6:
			_cycle_time(env)
		KEY_F7:
			_cycle_weather(env)
		KEY_F8:
			env.freeze_time(not env.time_frozen())
			print("[Environment] time %s" % ("FROZEN" if env.time_frozen() else "running"))
		KEY_F10:
			print("[Environment] forced lightning: %s" % [JSON.stringify(env.force_lightning())])
		KEY_F11:
			var next := (env.quality + 1) % 3
			env.set_quality(next)
			print("[Environment] quality -> %s" % env.quality_name())
		KEY_F12:
			_cycle_shelter(env)
		KEY_BRACKETLEFT:
			print("[Environment] day length -> %.0fs" % env.set_day_length(env.day_length_seconds() / DAY_LENGTH_STEP))
		KEY_BRACKETRIGHT:
			print("[Environment] day length -> %.0fs" % env.set_day_length(env.day_length_seconds() * DAY_LENGTH_STEP))
		KEY_P:
			env.dump_state()


func _cycle_time(env: EnvironmentManager) -> void:
	_anchor = (_anchor + 1) % TIME_ANCHORS.size()
	var anchor := TIME_ANCHORS[_anchor]
	env.force_time(anchor.x, anchor.y)
	print("[Environment] time anchor -> %s" % env.clock_string())


func _cycle_weather(env: EnvironmentManager) -> void:
	_weather += 1
	if _weather >= WEATHER_CYCLE.size():
		# Past the end: hand control back to the deterministic model.
		_weather = -1
		env.clear_forced_weather()
		print("[Environment] weather -> AUTO (deterministic model)")
		return
	var wanted: StringName = WEATHER_CYCLE[_weather]
	if env.force_weather(wanted):
		print("[Environment] weather -> %s (forced)" % wanted)
	else:
		_weather = -1
		push_warning("[Environment] unknown weather '%s'" % wanted)


func _cycle_shelter(env: EnvironmentManager) -> void:
	_shelter_mode = (_shelter_mode + 1) % 3
	match _shelter_mode:
		1:
			env.force_shelter(1.0)
			print("[Environment] shelter -> FORCED INDOORS")
		2:
			env.force_shelter(0.0)
			print("[Environment] shelter -> FORCED OUTDOORS")
		_:
			env.force_shelter(-1.0)
			print("[Environment] shelter -> AUTO (roof probe)")


## One line per state field, for `DebugOverlay` and for `--envdump`.
func overlay_lines() -> PackedStringArray:
	var env := manager()
	if env == null:
		return PackedStringArray(["env  (no environment manager)"])
	return env.status_lines()
