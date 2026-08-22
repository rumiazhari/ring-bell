extends Node
## Advances in-game time and exposes day/night queries.
##
## TIME MODEL: total_minutes counts game minutes since day 1, 00:00.
## time_scale = how many game minutes pass per real second (1.0 by default,
## so one in-game hour takes 60 real seconds). DebugOverlay can change it.
##
## Consumers: NeedsComponent (rates per game minute), DayNightController
## (lighting), NPCBrain (sleep at night), WorldState (death timestamps).

signal minute_passed(day: int, minute_of_day: int)
signal hour_changed(day: int, hour: int)
signal day_changed(day: int)

const MINUTES_PER_DAY := 1440

var total_minutes: float = 7.0 * 60.0  # new games start at 07:00 on day 1
var time_scale: float = 1.0            # game minutes per real second
var paused: bool = false


func _process(delta: float) -> void:
	if paused:
		return
	advance(delta * time_scale)


func advance(minutes: float) -> void:
	if minutes <= 0.0:
		return
	var prev_hour := get_hour()
	var prev_day := get_day()
	total_minutes += minutes
	minute_passed.emit(get_day(), get_minute_of_day())
	if get_hour() != prev_hour:
		hour_changed.emit(get_day(), get_hour())
	if get_day() != prev_day:
		day_changed.emit(get_day())


func get_day() -> int:
	return floori(total_minutes / float(MINUTES_PER_DAY)) + 1


func get_hour() -> int:
	return floori(float(get_minute_of_day()) / 60.0)


func get_minute_of_day() -> int:
	return int(total_minutes) % MINUTES_PER_DAY


func time_string() -> String:
	var m := get_minute_of_day()
	return "%02d:%02d" % [floori(m / 60.0), m % 60]


func is_night() -> bool:
	var h := get_hour()
	return h < 6 or h >= 20


func save_state() -> Dictionary:
	return {"total_minutes": total_minutes}


func load_state(data: Dictionary) -> void:
	total_minutes = float(data.get("total_minutes", 7.0 * 60.0))
