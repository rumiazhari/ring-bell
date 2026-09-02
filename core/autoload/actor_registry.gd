extends Node
## Tracks live actor nodes by persistent id and answers spatial queries.
##
## Pure lookup service: it owns no simulation state and never mutates actors.
## AI, quests and dialogue use it to find targets without hard-coded references.
## Persistent facts (alive/dead across sessions) belong to WorldState instead.

var _actors := {}  # String (persistent_id) -> Node3D


func register(actor: Node3D, persistent_id: StringName) -> void:
	var key := str(persistent_id)
	if _actors.has(key):
		push_warning("ActorRegistry: duplicate registration for '%s'" % key)
		return
	_actors[key] = actor


func unregister(persistent_id: StringName) -> void:
	_actors.erase(str(persistent_id))


func get_actor(persistent_id: StringName) -> Node3D:
	return _actors.get(str(persistent_id))


## Returns true when the node is gone or its HealthComponent reports death.
static func is_actor_down(actor: Node) -> bool:
	if not is_instance_valid(actor):
		return true
	var health_value: Variant = actor.get("health")
	if health_value == null:
		return false
	return bool(health_value.is_dead)


## Returns the closest registered actor whose node is in `group` and not dead.
## Iteration guards against stale roster entries (freed actors): a previously
## freed object must never be passed into a typed argument (`is_actor_down`)
## — the arg-type check itself raises a script error — so validity is
## confirmed here and stale keys are pruned in place.
func find_nearest_in_group(from_position: Vector3, group: StringName, max_distance: float) -> Node3D:
	var best: Node3D = null
	var best_d2 := max_distance * max_distance
	var stale: Array[String] = []
	for key: String in _actors:
		var actor = _actors[key]  # untyped: a freed object must not hit a typed local/arg check
		if not is_instance_valid(actor):
			stale.append(key)
			continue
		if is_actor_down(actor) or not actor.is_in_group(group):
			continue
		var d2 := from_position.distance_squared_to(actor.global_position)
		if d2 < best_d2:
			best_d2 = d2
			best = actor
	for k in stale:
		_actors.erase(k)
	return best


func count_alive_in_group(group: StringName) -> int:
	var n := 0
	var stale: Array[String] = []
	for key: String in _actors:
		var actor = _actors[key]  # untyped: freed objects must not hit typed checks
		if not is_instance_valid(actor):
			stale.append(key)
			continue
		if not is_actor_down(actor) and actor.is_in_group(group):
			n += 1
	for k in stale:
		_actors.erase(k)
	return n


func clear() -> void:
	_actors.clear()
