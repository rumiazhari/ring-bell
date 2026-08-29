class_name CitySpawner
extends Node3D
## Procedural zombie population for the streamed city.
##
## For every chunk that transitions to ACTIVE, spawns a deterministic band
## of zombies (MIN..MAX) at ROAD anchors sampled from CityPlan - never inside
## building footprints or plaza interiors. When a chunk drops to WARM/COLD
## (or unloads), its zombies despawn to nothing: only the deterministic ID
## scheme survives, so returning chunks repopulate identically unless the
## player killed/changed them during that visit (delta persistence is Phase F).
##
## Zombie nodes live under this node; ids follow "z_<cx>_<cy>_<nnn>".

const MIN_PER_CHUNK := 2
const MAX_PER_CHUNK := 8
const SPAWN_Y := 0.2

var plan: CityPlan

var _live := {}                        # Vector2i chunk coord -> Array[Zombie]


func setup(city_plan: CityPlan, manager: ChunkManager) -> void:
	plan = city_plan
	add_to_group(&"city_spawner")
	manager.chunk_state_changed.connect(_on_chunk_state_changed)
	manager.chunk_unloaded.connect(_on_chunk_unloaded)


func _on_chunk_state_changed(coord: Vector2i, new_state: StringName) -> void:
	if new_state == &"active":
		_spawn_for(coord)
	elif new_state == &"warm" or new_state == &"cold":
		_despawn(coord)


func _on_chunk_unloaded(coord: Vector2i) -> void:
	_despawn(coord)


func _spawn_for(coord: Vector2i) -> void:
	if plan == null or _live.has(coord):
		return
	var rng := WorldSeed.rng_for("zpop", [coord.x, coord.y])
	var count := rng.randi_range(MIN_PER_CHUNK, MAX_PER_CHUNK)
	var center: Vector2 = (WorldSeed.chunk_rect(coord) as Rect2).get_center()
	var roster: Array[Zombie] = []
	for i in count:
		var id := StringName("z_%d_%d_%03d" % [coord.x, coord.y, i])
		var anchor2 := plan.sample_road_position(center, 0.0,
				float(WorldSeed.CHUNK_SIZE) * 0.75, rng)
		if anchor2 == Vector2.INF:
			continue   # no valid road space this draw; skip (roads are dense)
		var zombie := Zombie.new()
		zombie.requested_id = id
		zombie.city_plan = plan
		add_child(zombie)
		zombie.global_position = Vector3(anchor2.x, SPAWN_Y, anchor2.y)
		zombie.anchor = zombie.global_position
		zombie._wander_pause = rng.randf_range(0.5, 4.0)
		roster.append(zombie)
	_live[coord] = roster


## Despawn to records. Zombies that died during the visit unregister
## themselves; survivors of the roster are unregistered here. A dead zombie
## can leave an invalid Object reference in the cached roster until this
## transition; keep the loop Variant-typed until validity is established.
func _despawn(coord: Vector2i) -> void:
	if not _live.has(coord):
		return
	var roster: Array = _live[coord] as Array
	for node in roster:
		if not is_instance_valid(node):
			continue
		if not (node is Zombie):
			continue
		var zombie: Zombie = node as Zombie
		ActorRegistry.unregister(zombie.zombie_id)
		zombie.queue_free()
	_live.erase(coord)


## Live zombie count for one chunk (debug/tests).
func live_in_chunk(coord: Vector2i) -> int:
	return (_live[coord] as Array).size() if _live.has(coord) else 0


func live_total() -> int:
	var n := 0
	for roster in _live.values():
		n += (roster as Array).size()
	return n


func debug_lines() -> Array[String]:
	return ["city zombies | live %d | populated chunks %d"
			% [live_total(), _live.size()]]
