class_name NPCBrain
extends Node
## Utility-based autonomous behavior for one Survivor NPC.
##
## THINK TICK (every 0.4s): score candidate goals from the NPC's actual state
## (needs, nearby danger, time of day) and pick the highest scorer.
## EXECUTE: drive movement toward the chosen goal until done or superseded.
##
## Deliberately small for Prototype 0, but structured to grow: scores are pure
## functions of state; actions are tiny state machines. Long term this becomes
## a utility -> goals -> planner pipeline (see ARCHITECTURE.md).

enum Action { IDLE, WANDER, EAT, SLEEP, FLEE }

const THINK_INTERVAL := 0.4
const ARRIVE_DISTANCE := 1.2
const PANIC_RADIUS := 9.0          # zombies closer than this trigger FLEE
const WANDER_RADIUS := 7.0         # wander around this far from home

var survivor: Survivor
var home_position := Vector3.ZERO  # where they sleep / tend to stay
var cowardice := 1.0               # personality multiplier on fear score

var current_action := Action.IDLE
var _action_target := Vector3.ZERO
var _think_timer := 0.0
var _stuck_timer := 0.0
var _last_position := Vector3.ZERO


func _ready() -> void:
	survivor = get_parent() as Survivor
	_last_position = survivor.global_position


func set_enabled(enabled: bool) -> void:
	set_physics_process(enabled)
	if not enabled:
		survivor.stop_moving()


func _physics_process(delta: float) -> void:
	if survivor == null or survivor.health.is_dead:
		return
	_think_timer -= delta
	if _think_timer <= 0.0:
		_think_timer = THINK_INTERVAL
		_think()
	_execute(delta)


# --- Goal selection ---------------------------------------------------------

func _think() -> void:
	var best := Action.IDLE
	var best_score := 0.12  # IDLE baseline: standing still is always an option

	var wander_score := 0.18 + (0.25 if GameClock.is_night() else 0.0) \
			+ randf() * 0.15
	if wander_score > best_score:
		best = Action.WANDER
		best_score = wander_score

	if survivor.needs.hunger > 45.0 or survivor.needs.thirst > 50.0:
		var eat_score := maxf(survivor.needs.hunger, survivor.needs.thirst) / 100.0
		if eat_score > best_score:
			best = Action.EAT
			best_score = eat_score

	if GameClock.is_night() and survivor.needs.fatigue > 40.0:
		var sleep_score := survivor.needs.fatigue / 100.0 + 0.2
		if sleep_score > best_score:
			best = Action.SLEEP
			best_score = sleep_score

	var threat := ActorRegistry.find_nearest_in_group(
			survivor.global_position, &"zombies", PANIC_RADIUS)
	if threat != null:
		var flee_score := 2.5 * cowardice
		if flee_score > best_score:
			best = Action.FLEE
			best_score = flee_score

	if best != current_action:
		current_action = best
		_on_action_started()


func _on_action_started() -> void:
	match current_action:
		Action.WANDER:
			var offset := Vector3(
					randf_range(-WANDER_RADIUS, WANDER_RADIUS), 0,
					randf_range(-WANDER_RADIUS, WANDER_RADIUS))
			_action_target = home_position + offset
		Action.EAT:
			if not _has_consumable():
				_action_target = _nearest_food_storage()
		Action.SLEEP:
			_action_target = home_position
		Action.FLEE, Action.IDLE:
			pass


# --- Execution --------------------------------------------------------------

func _execute(delta: float) -> void:
	match current_action:
		Action.IDLE:
			survivor.stop_moving()
		Action.WANDER:
			_move_toward(_action_target, false, delta)
			if _arrived():
				current_action = Action.IDLE
		Action.EAT:
			_execute_eat(delta)
		Action.SLEEP:
			_execute_sleep(delta)
		Action.FLEE:
			_execute_flee()


func _move_toward(target: Vector3, sprint: bool, delta: float) -> void:
	var to_target := target - survivor.global_position
	to_target.y = 0.0
	if to_target.length() < 0.05:
		survivor.stop_moving()
		return
	var dir := to_target.normalized()

	# Cheap stuck handling: if barely moving while trying to move, sidestep.
	var moved := survivor.global_position.distance_to(_last_position)
	_last_position = survivor.global_position
	if moved < 0.02:
		_stuck_timer += delta
		if _stuck_timer > 0.35:
			var side := 1 if int(_stuck_timer * 10.0) % 2 == 0 else -1
			dir = dir.rotated(Vector3.UP, PI / 2.0 * side)
		if _stuck_timer > 1.6:
			_stuck_timer = 0.0
	else:
		_stuck_timer = 0.0

	survivor.request_move(dir, sprint)


func _arrived() -> bool:
	var flat := survivor.global_position - _action_target
	flat.y = 0.0
	return flat.length() <= ARRIVE_DISTANCE


# --- Actions ----------------------------------------------------------------

func _has_consumable() -> bool:
	return survivor.inventory.find_item_of_kind(ItemDB.KIND_FOOD) != &""


func _consume() -> void:
	var food_id := survivor.inventory.find_item_of_kind(ItemDB.KIND_FOOD)
	if food_id == &"":
		return
	var def := ItemDB.get_def(food_id)
	survivor.inventory.remove(food_id, 1)
	if def.has("hunger_reduction"):
		survivor.needs.eat(def["hunger_reduction"])
	if def.has("thirst_reduction"):
		survivor.needs.drink(def["thirst_reduction"])


func _execute_eat(delta: float) -> void:
	if _has_consumable():
		survivor.stop_moving()
		_consume()
		current_action = Action.IDLE
		return

	# No food on hand: walk to known food storage and loot it.
	var crate := ActorRegistry.find_nearest_in_group(
			survivor.global_position, &"food_storage", 40.0)
	if crate == null:
		current_action = Action.IDLE  # nothing known; give up for now
		return
	var dist := survivor.global_position.distance_to(crate.global_position)
	if dist <= ARRIVE_DISTANCE + 0.8 and crate.has_method("npc_take_food"):
		crate.call("npc_take_food", survivor)
		current_action = Action.IDLE
	else:
		_action_target = crate.global_position
		_move_toward(_action_target, false, delta)


func _execute_sleep(delta: float) -> void:
	if not GameClock.is_night() and survivor.needs.fatigue < 30.0:
		survivor.needs.sleeping = false
		current_action = Action.IDLE
		return
	if not _arrived():
		_move_toward(home_position, false, delta)
		survivor.needs.sleeping = false  # only sleep once actually home
	else:
		survivor.stop_moving()
		survivor.needs.sleeping = true


func _execute_flee() -> void:
	var threat := ActorRegistry.find_nearest_in_group(
			survivor.global_position, &"zombies", PANIC_RADIUS * 1.4)
	if threat == null or not is_instance_valid(threat):
		current_action = Action.IDLE
		survivor.request_move(Vector3.ZERO, false)
		return
	var away := survivor.global_position - threat.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
	survivor.needs.sleeping = false
	survivor.request_move(away.normalized(), true)


func _nearest_food_storage() -> Vector3:
	var crate := ActorRegistry.find_nearest_in_group(
			survivor.global_position, &"food_storage", 60.0)
	return crate.global_position if crate != null else Vector3.INF
