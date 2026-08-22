class_name DialogueData
extends RefCounted
## Dialogue trees for Prototype 0.
##
## DESIGN: trees are BUILT at open time by querying WorldState/QuestManager
## directly, so every branch reflects what actually happened in the
## simulation (no stale flags, no fake quest copies of NPCs). Character
## scripts contain NO dialogue logic; UI applies small coded effects.
##
## TREE SHAPE:
##   { "node_id": {"text": String,
##                 "options": [{"label": String, "next": String|null,
##                              "effect": StringName(optional)}] } }
## Missing "next" or unknown node id ends the conversation.

const QUEST_ID := &"find_hana"
const HANA_ID := QuestFindHana.HANA_ID


static func build_tree(npc_id: StringName) -> Dictionary:
	match npc_id:
		QuestFindHana.KENJI_ID:
			return _kenji_tree()
		HANA_ID:
			return _hana_tree()
		&"npc_masa":
			return _masa_tree()
		_:
			return _generic_tree(npc_id)


static func apply_effect(effect: StringName, npc: Survivor, player: Survivor) -> void:
	match effect:
		&"quest_start_find_hana":
			QuestManager.start_quest(QUEST_ID)
		&"set_flag_met_hana":
			WorldState.set_flag(&"met_hana")
		&"finish_find_hana":
			QuestManager.complete_quest(QUEST_ID)
			player.inventory.add(&"canned_food", 2)
		&"":
			pass
		var other:
			push_warning("DialogueData: unhandled effect '%s' (%s)" % [other, npc.identity.persistent_id])


# --- Kenji Tanaka -----------------------------------------------------------
# His mood is derived entirely from world facts: whether Hana lives, whether
# you have met her, and what state the quest is in.

static func _kenji_tree() -> Dictionary:
	if WorldState.is_dead(HANA_ID):
		return {
			"start": {
				"text": "Some scavengers found her by the east fence this morning... [i]She didn't make it.[/i] Thank you for trying. That's more than most did.",
				"options": [
					{"label": "(Sit with him in silence.)", "next": "silence"},
					{"label": "\"I'm sorry, Kenji.\"", "next": "silence"},
				],
			},
			"silence": {
				"text": "She was going to be a teacher, you know...",
				"options": [{"label": "(Leave him to grieve.)"}],
			},
		}

	var state := QuestManager.get_state(QUEST_ID)
	if state == QuestManager.State.COMPLETED:
		return {
			"start": {
				"text": "I can't thank you enough. She eats first now, always. Old habits.",
				"options": [
					{"label": "\"Keep her inside at night.\"", "next": "advice"},
					{"label": "Leave."},
				],
			},
			"advice": {
				"text": "You too, rider. The dark belongs to them.",
				"options": [{"label": "Leave."}],
			},
		}

	if state == QuestManager.State.ACTIVE:
		if WorldState.has_flag(&"met_hana"):
			return {
				"start": {
					"text": "You've [b]seen[/b] her? She's breathing? Tell me everything!",
					"options": [{
						"label": "\"She's holed up past the east road. She's safe.\"",
						"next": "thanks",
						"effect": &"finish_find_hana",
					}],
				},
				"thanks": {
					"text": "[i]Bless you.[/i] Here - it isn't much, but take it. You found my whole world.",
					"options": [{"label": "Take the canned food. (Quest complete)", "effect": &""}],
				},
			}
		return {
			"start": {
				"text": "Anything? Please... check the alleys, she wouldn't go far on foot...",
				"options": [
					{"label": "\"Not yet. Keep the door barred.\"", "next": "wait"},
				],
			},
			"wait": {
				"text": "I will. I will. Hurry.",
				"options": [{"label": "Leave."}],
			},
		}

	# Quest not started yet (INACTIVE or FAILED without death).
	return {
		"start": {
			"text": "You don't look like one of those looters... Listen. My daughter Hana went out two nights ago when the sirens died. She never came home.",
			"options": [
				{"label": "\"What does she look like?\"", "next": "describe"},
				{"label": "\"I'll find her. Where was she headed?\"", "next": "accept",
						"effect": &"quest_start_find_hana"},
				{"label": "\"That's not my problem.\"", "next": "cold"},
			],
		},
		"describe": {
			"text": "Sixteen. Blue school backpack, hair tied back. She was heading toward her friend Yuki's place across the east road.",
			"options": [
				{"label": "\"I'll bring her home.\"", "next": "accept",
						"effect": &"quest_start_find_hana"},
				{"label": "\"Maybe later.\"", "next": "later"},
			],
		},
		"accept": {
			"text": "The east side, past the wrecked cars. Please - bar nothing behind you but your fear. Go at first light if you must, just GO.",
			"options": [{"label": "\"Stay here. Bar the door. I'll be back.\""}],
		},
		"later": {
			"text": "Then who will help us? ... Come back when you grow a spine.",
			"options": [{"label": "Leave."}],
		},
		"cold": {
			"text": "...Then may the dead pass you by, stranger. They don't care about excuses either.",
			"options": [{"label": "Leave."}],
		},
	}


# --- Hana Tanaka ------------------------------------------------------------
# Meeting her ALWAYS sets the met_hana flag - even before the quest starts,
# which is how pre-existing knowledge flows into quest logic.

static func _hana_tree() -> Dictionary:
	var active := QuestManager.is_active(QUEST_ID)
	var met := WorldState.has_flag(&"met_hana")

	if active or met:
		if met:
			return {
				"start": {
					"text": "Still hiding tight! Did you tell Dad I'm okay? He worries himself sick.",
					"options": [
						{"label": "\"He knows now. Stay put until things calm down.\"",
								"effect": &"set_flag_met_hana"},
						{"label": "(Nod and leave.)", "effect": &"set_flag_met_hana"},
					],
				},
			}
		return {
			"start": {
				"text": "S-stop right there! Are you bit?! ...You're not? Okay. Okay okay okay. I'm waiting for my dad, we got separated when the sirens stopped.",
				"options": [
					{"label": "\"Your father sent people looking. Stay hidden.\"",
							"next": "relief", "effect": &"set_flag_met_hana"},
					{"label": "(Back away slowly.)", "effect": &"set_flag_met_hana"},
				],
			},
			"relief": {
				"text": "Dad's alive?! Then tell him where I am! This corner store basement - no, wait, he'd worry MORE. Just... tell him I'm safe!",
				"options": [{"label": "\"I will. Don't open that door for anyone else.\""}],
			},
		}

	return {
		"start": {
			"text": "Don't come closer! I've got a knife! ...It's a box cutter. Please don't make me use it.",
			"options": [
				{"label": "\"Easy. I'm just passing through.\"",
						"next": "cautious", "effect": &"set_flag_met_hana"},
			],
		},
		"cautious": {
			"text": "Everyone's 'just passing through' lately. If you see an old man with a limp asking about his daughter... that's my dad. Tell him I went east.",
			"options": [{"label": "Leave."}],
		},
	}


# --- Old Masa ---------------------------------------------------------------

static func _masa_tree() -> Dictionary:
	return {
		"start": {
			"text": "No deliveries since the sirens stopped. Trucks don't run on roads full of [i]those things[/i].",
			"options": [
				{"label": "\"Business bad?\"", "next": "business"},
				{"label": "\"Mind if I search your storage?\"", "next": "storage"},
				{"label": "Leave.", },
			],
		},
		"business": {
			"text": "Bad? Boy, I'm the last shop still open in three districts. Bad is relative.",
			"options": [{"label": "Leave.", }],
		},
		"storage": {
			"text": "Back shelf. Take what you NEED, not what you want. And don't broadcast how much is left - hungry people do stupid things.",
			"options": [{"label": "Leave.", }],
		},
	}


# --- Fallback for background survivors -------------------------------------

static func _generic_tree(npc_id: StringName) -> Dictionary:
	var npc := ActorRegistry.get_actor(npc_id)
	var occupation := ""
	if npc != null and is_instance_valid(npc):
		occupation = npc.identity.occupation
	return {
		"start": {
			"text": "...Don't waste breath on small talk. %s - that's what I was, back when it mattered." % occupation,
			"options": [
				{"label": "\"Stay off the streets after dark.\"", "next": "dark"},
			],
		},
		"dark": {
			"text": "Believe me, I've noticed what walks at night. Doors locked, windows shut.",
			"options": [{"label": "Leave."}],
		},
	}
