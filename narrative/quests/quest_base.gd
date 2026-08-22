class_name QuestBase
extends RefCounted
## Base class for quest definitions.
##
## A quest definition is PURE LOGIC + DATA: it never touches scene nodes.
## It reads world facts (WorldState) and reacts to events reported by
## QuestManager. QuestManager owns all state transitions (ACTIVE/COMPLETED/...).
##
## This separation lets quests react to simulation outcomes (e.g. an NPC dying
## on its own) without any hard-coded quest scripts inside character logic.

var id: StringName = &""
var title: String = ""


## Called by QuestManager when the quest transitions to ACTIVE.
func on_started() -> void:
	pass


## Called when any actor dies while this quest is ACTIVE.
## Return {"action": "fail", "reason": "..."} to fail the quest,
## or {} to ignore. Future actions: "branch", "transform", ...
func on_actor_died(_actor_id: StringName) -> Dictionary:
	return {}


## Human-readable current objective, shown in HUD and debug overlay.
func objective_text() -> String:
	return ""
