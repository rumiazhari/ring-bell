extends Node
## Global signal hub for world events and gameplay events.
##
## Systems communicate through these signals instead of holding references to
## each other. WorldState records persistent consequences (deaths, flags);
## quests, dialogue and future systems subscribe here.
##
## SIGNAL CONTRACTS (keep this list current when adding signals):
##  - actor_died(actor_id: StringName, killer_id: StringName)
##      Emitted once per actor death (survivors AND zombies). actor_id is the
##      persistent id from IdentityComponent ("player", "npc_kenji", "zombie_003").
##  - flag_set(flag: StringName, value: Variant)
##      Emitted by WorldState when a world flag changes.
##  - quest_state_changed(quest_id: StringName, new_state: int)
##      Emitted by QuestManager on start/complete/fail.
##  - attack_performed(position: Vector3)
##      Emitted by any melee attack; zombies use it as a noise cue.

# --- World events -----------------------------------------------------------
signal actor_died(actor_id: StringName, killer_id: StringName)
signal flag_set(flag: StringName, value: Variant)

# --- Quests -----------------------------------------------------------------
signal quest_state_changed(quest_id: StringName, new_state: int)

# --- Gameplay ---------------------------------------------------------------
signal attack_performed(position: Vector3)
signal weapon_switched(weapon_name: String)
signal explosion_occurred(position: Vector3)

# --- Time -------------------------------------------------------------------
signal hour_changed(day: int, hour: int)
signal day_changed(day: int)
