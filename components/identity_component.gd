class_name IdentityComponent
extends Node
## Stable identity data for an actor.
##
## persistent_id is THE link between a live node and everything else:
## ActorRegistry lookup, WorldState death records, quest logic, dialogue,
## save files. Never change it for an existing character.

@export var persistent_id: StringName = &""
@export var display_name: String = "Survivor"
@export var occupation: String = ""          # background/occupation flavor
@export var faction_id: StringName = &"survivors"
@export var is_persistent: bool = true       # false for disposable actors (zombies)
