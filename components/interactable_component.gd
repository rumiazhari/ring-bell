class_name InteractableComponent
extends Node
## Marks an object as usable by the player's interaction scan.
##
## The owning body must be in group "interactables". PlayerController scans
## that group, finds this component on the closest candidate and calls
## try_interact(). Owners connect to `interacted` to implement behavior.
##
## prompt is what the HUD shows ("[E] Talk to Kenji" is assembled by HUD).

signal interacted(player: Node3D)

@export var prompt := "Interact"
@export var enabled := true


func try_interact(player: Node3D) -> bool:
	if not enabled:
		return false
	interacted.emit(player)
	return true
