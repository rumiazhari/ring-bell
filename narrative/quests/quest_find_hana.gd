class_name QuestFindHana
extends QuestBase
## PROTOTYPE NARRATIVE TEST.
##
## Kenji asks the player to find his daughter Hana. Hana is a real simulated
## survivor living her own life in the world; this quest NEVER creates a fake
## "quest copy" of her. It only queries her actual persistent state:
##
##   - she may already have been met before the quest starts (flag "met_hana"),
##   - she may have moved (her live position comes from ActorRegistry),
##   - she may be dead (WorldState death record), which fails the quest,
##   - telling Kenji afterwards completes it.

const KENJI_ID := &"npc_kenji"
const HANA_ID := &"npc_hana"


func _init() -> void:
	id = &"find_hana"
	title = "Where Is Hana?"


func objective_text() -> String:
	if WorldState.is_dead(HANA_ID):
		return "Hana is dead. Tell Kenji."
	if WorldState.has_flag(&"met_hana"):
		return "Return to Kenji."
	return "Find Hana Tanaka."


func on_actor_died(actor_id: StringName) -> Dictionary:
	# The simulation decided Hana died; the story must react without the player.
	if actor_id == HANA_ID:
		return {"action": "fail", "reason": "Hana Tanaka has died."}
	return {}
