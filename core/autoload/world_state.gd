extends Node
## Persistent record of world facts that must outlive live scene nodes:
## who is dead (and when/why), plus generic world flags.
##
## QUESTS AND DIALOGUE READ FROM HERE, never from live scenes, so narrative
## reacts to what actually happened even after the involved node is gone.
## ActorRegistry answers "where is X right now"; WorldState answers
## "what is true about the world".

signal flag_set(flag: StringName, value: Variant)

# String flag key -> Variant (default true when set without value).
var _flags := {}

# String actor id -> {"day": int, "hour": int, "killer": String}
var _death_records := {}


func _ready() -> void:
	EventBus.actor_died.connect(_on_actor_died)


## NOTE: the player's own death is deliberately NOT a world fact here -
## it must be recoverable via quickload. NPC deaths ARE permanent facts.
func _on_actor_died(actor_id: StringName, killer_id: StringName) -> void:
	if actor_id == &"player":
		return
	record_death(actor_id, killer_id)


func set_flag(flag: StringName, value: Variant = true) -> void:
	var key := str(flag)
	if _flags.get(key) == value and _flags.has(key):
		return
	_flags[key] = value
	flag_set.emit(flag, value)


func has_flag(flag: StringName) -> bool:
	return _flags.has(str(flag))


func get_flag(flag: StringName, default_value: Variant = null) -> Variant:
	return _flags.get(str(flag), default_value)


func clear_flag(flag: StringName) -> void:
	_flags.erase(str(flag))


func record_death(actor_id: StringName, killer_id: StringName) -> void:
	var key := str(actor_id)
	if _death_records.has(key):
		return  # first death wins; deaths are permanent
	_death_records[key] = {
		"day": GameClock.get_day(),
		"hour": GameClock.get_hour(),
		"killer": str(killer_id),
	}


func is_dead(persistent_id: StringName) -> bool:
	return _death_records.has(str(persistent_id))


func get_death_record(persistent_id: StringName) -> Dictionary:
	return _death_records.get(str(persistent_id), {})


func save_state() -> Dictionary:
	return {
		"flags": _flags.duplicate(true),
		"deaths": _death_records.duplicate(true),
	}


func load_state(data: Dictionary) -> void:
	_flags = data.get("flags", {}).duplicate(true)
	_death_records = data.get("deaths", {}).duplicate(true)
