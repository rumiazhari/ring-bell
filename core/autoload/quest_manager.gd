extends Node
## Owns quest lifecycle state and forwards world events to active quests.
##
## Quest definitions live in res://narrative/quests/*.gd (pure logic, no nodes).
## QuestManager is the ONLY system allowed to change quest states; dialogue and
## world events request changes through its public API.

enum State { INACTIVE, ACTIVE, COMPLETED, FAILED }

const QUEST_DEFS := {
	&"find_hana": preload("res://narrative/quests/quest_find_hana.gd"),
}

var _states := {}        # String quest id -> State
var _fail_reasons := {}  # String quest id -> String
var _defs := {}          # String quest id -> QuestBase instance


func _ready() -> void:
	for quest_id: StringName in QUEST_DEFS:
		_defs[str(quest_id)] = QUEST_DEFS[quest_id].new()
		_states[str(quest_id)] = State.INACTIVE
	EventBus.actor_died.connect(_on_actor_died)


func _on_actor_died(actor_id: StringName, _killer_id: StringName) -> void:
	for quest_id in _defs:
		if get_state(StringName(quest_id)) != State.ACTIVE:
			continue
		var reaction: Dictionary = _defs[quest_id].on_actor_died(actor_id)
		if reaction.get("action", &"") == &"fail":
			fail_quest(StringName(quest_id), reaction.get("reason", ""))


func start_quest(quest_id: StringName) -> void:
	var key := str(quest_id)
	if get_state(quest_id) != State.INACTIVE:
		return
	_states[key] = State.ACTIVE
	_defs[key].on_started()
	EventBus.quest_state_changed.emit(quest_id, State.ACTIVE)


func complete_quest(quest_id: StringName) -> void:
	if get_state(quest_id) != State.ACTIVE:
		return
	_states[str(quest_id)] = State.COMPLETED
	EventBus.quest_state_changed.emit(quest_id, State.COMPLETED)


func fail_quest(quest_id: StringName, reason: String = "") -> void:
	if get_state(quest_id) != State.ACTIVE:
		return
	_states[str(quest_id)] = State.FAILED
	if reason != "":
		_fail_reasons[str(quest_id)] = reason
	EventBus.quest_state_changed.emit(quest_id, State.FAILED)


func get_state(quest_id: StringName) -> int:
	return _states.get(str(quest_id), State.INACTIVE)


func is_active(quest_id: StringName) -> bool:
	return get_state(quest_id) == State.ACTIVE


func get_title(quest_id: StringName) -> String:
	var def: QuestBase = _defs.get(str(quest_id))
	return def.title if def != null else str(quest_id)


## Current objective text for an ACTIVE quest ("" otherwise).
func get_objective_text(quest_id: StringName) -> String:
	if not is_active(quest_id):
		return ""
	return _defs[str(quest_id)].objective_text()


func get_fail_reason(quest_id: StringName) -> String:
	return _fail_reasons.get(str(quest_id), "")


func save_state() -> Dictionary:
	return {
		"states": _states.duplicate(),
		"fail_reasons": _fail_reasons.duplicate(true),
	}


func load_state(data: Dictionary) -> void:
	var states: Dictionary = data.get("states", {})
	for key in states:
		_states[key] = int(states[key])
	_fail_reasons = data.get("fail_reasons", {}).duplicate(true)
