extends Node
## Focused regression gate for streamed-city stability and frame pacing.
##
## --streamingregressiontest intentionally boots without the normal city scene
## so it can isolate stale roster cleanup and completed-job scheduling.

var failures := 0


class CountingChunkManager extends ChunkManager:
	var materialized_coords: Array[Vector2i] = []

	func _materialize(coord: Vector2i, _batcher: MeshBatcher,
			_terrain_manifest: Dictionary, _gen_ms: float, _pc: Vector2i,
			_terrain_gen_ms: float = 0.0, _water_manifest: Dictionary = {},
			_water_gen_ms: float = 0.0, _biome_manifest: Dictionary = {},
			_biome_gen_ms: float = 0.0) -> void:
		materialized_coords.append(coord)


func _ready() -> void:
	_run()


func _run() -> void:
	_test_despawn_tolerates_a_freed_zombie()
	_test_completed_jobs_do_not_materialize_as_a_burst()
	_finish()


func _test_despawn_tolerates_a_freed_zombie() -> void:
	var spawner := CitySpawner.new()
	var coord := Vector2i(2, -3)
	var dead_zombie := Zombie.new()
	spawner._live[coord] = [dead_zombie]
	dead_zombie.free()
	spawner._despawn(coord)
	_check("despawn clears a roster containing a freed zombie",
			not spawner._live.has(coord), "bucket still present after despawn")
	spawner.free()


func _test_completed_jobs_do_not_materialize_as_a_burst() -> void:
	var manager := CountingChunkManager.new()
	var player_chunk := Vector2i.ZERO
	var coords: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]
	for coord in coords:
		manager._inflight[coord] = {
			"batcher": MeshBatcher.new(),
			"terrain": {},
			"water": {},
			"biome": {},
			"task_id": -1,
			"gen_ms": 0.0,
			"terrain_gen_ms": 0.0,
			"water_gen_ms": 0.0,
			"biome_gen_ms": 0.0,
		}
	manager._collect_finished_jobs(player_chunk)
	_check("one scheduler tick materializes at most one completed chunk",
			manager.materialized_coords.size() <= 1,
			"materialized=%d" % manager.materialized_coords.size())
	manager._collect_finished_jobs(player_chunk)
	manager._collect_finished_jobs(player_chunk)
	_check("bounded scheduler eventually drains all completed chunks",
			manager.materialized_coords.size() == coords.size()
				and manager._inflight.is_empty(),
			"materialized=%d inflight=%d" % [manager.materialized_coords.size(), manager._inflight.size()])
	manager.free()


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		print("[StreamingRegression] PASS  %s" % name)
	else:
		failures += 1
		print("[StreamingRegression] FAIL  %s (%s)" % [name, detail])


func _finish() -> void:
	print("[StreamingRegression] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
