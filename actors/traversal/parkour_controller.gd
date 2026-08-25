class_name ParkourController
extends Node
## Jump intent + fall-damage tracking for one Survivor body.
##
## Phase E slice 1 of the traversal split: this node owns vertical mobility
## (jump requests) and landing consequences (fall damage), while Survivor
## keeps executing the physics. Attached to every human actor, so NPCs eat
## fall damage too. Later slices extend this with vault/mantle/ledge-grab
## detection via geometry probes (ray casts, no trigger volumes).

const JUMP_SPEED := 6.4                # apex ~1.14 m: clears crates, not walls
const JUMP_STAMINA_COST := 6.0
const FALL_SAFE_HEIGHT := 3.5          # meters: no damage within this drop
const FALL_DAMAGE_PER_M := 9.0         # damage per meter beyond safe height

var _survivor: Survivor
var _peak_y := 0.0


## Wire to the owning body. Call once, right after add_child().
func setup(survivor: Survivor) -> void:
	_survivor = survivor
	_peak_y = survivor.global_position.y


## Called by PlayerController once per jump-input press.
func try_jump() -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if not _survivor.is_on_floor():
		return
	if _survivor.needs.sleeping or _survivor.exhausted:
		return
	if _survivor.stamina < JUMP_STAMINA_COST:
		return
	_survivor.stamina -= JUMP_STAMINA_COST
	_survivor.velocity.y = JUMP_SPEED


## Track airtime peaks; charge fall damage on hard landings.
## Call from Survivor._physics_process AFTER move_and_slide().
func tick(_delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if _survivor.is_on_floor():
		var drop := _peak_y - _survivor.global_position.y
		if drop > FALL_SAFE_HEIGHT:
			_survivor.take_damage(
					(drop - FALL_SAFE_HEIGHT) * FALL_DAMAGE_PER_M, &"fall")
		_peak_y = _survivor.global_position.y
	else:
		_peak_y = maxf(_peak_y, _survivor.global_position.y)
