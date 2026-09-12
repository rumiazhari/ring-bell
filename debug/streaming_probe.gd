extends Node
## --streamprobe : diagnosis for "queued chunks never materialize" in a
## windowed async run (worker mode, not synchronous).
##
## The ESC-menu capture showed the world as a black void: the debug overlay
## reported `active 0 | warm 0 | queued 25 | loads 0/unloads 0` for minutes
## while the CityPlan was long finished. This prints the streams' internal
## counters every 2 s so the stall can be located instead of guessed at:
## whether jobs were ever launched, whether their worker tasks complete,
## whether the plan-lease pool is exhausted, and whether completed jobs get
## refused materialization.
##
## Read-only: it touches nothing and quits on its own.

const PROBE_SECONDS := 90.0
const PROBE_INTERVAL := 2.0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[StreamProbe] needs a windowed run")
		get_tree().quit(0)
		return
	get_tree().create_timer(600.0).timeout.connect(func() -> void: get_tree().quit(2))
	print("[StreamProbe] waiting for the streamed world...")
	if not await _until(func() -> bool:
			return not get_tree().get_nodes_in_group(&"chunk_manager").is_empty(), 300.0):
		print("[StreamProbe] no chunk manager after 300 s")
		get_tree().quit(1)
		return
	var cm := get_tree().get_nodes_in_group(&"chunk_manager")[0] as ChunkManager
	await _until(func() -> bool: return ActorRegistry.get_actor(&"player") != null, 120.0)
	print("[StreamProbe] synchronous=%s player_chunk=%s" % [str(cm.synchronous), str(cm._player_chunk())])

	var elapsed := 0.0
	while elapsed < PROBE_SECONDS:
		var inflight: Dictionary = cm._inflight
		var done := 0
		var waiting := 0
		var first_id := -1
		for c: Vector2i in inflight:
			var task_id: int = inflight[c]["task_id"]
			if first_id < 0:
				first_id = task_id
			if task_id < 0 or WorkerThreadPool.is_task_completed(task_id):
				done += 1
			else:
				waiting += 1
		print("[StreamProbe] t=%5.1fs pending=%d inflight=%d (done=%d running=%d) resident=%d warm=%d pc=%s first_task=%d first_done=%s avail_city=%d avail_world=%d"
				% [elapsed, cm._pending.size(), inflight.size(), done, waiting, cm._chunks.size(),
					cm._warm.size() if cm.has_method("warm_count") == false else 0, str(cm._player_chunk()),
					first_id, str(first_id >= 0 and WorkerThreadPool.is_task_completed(first_id)),
					cm._available_city_plans.size(), cm._available_world_plans.size()])
		await get_tree().create_timer(PROBE_INTERVAL).timeout
		elapsed += PROBE_INTERVAL
	print("[StreamProbe] done")
	get_tree().quit(0)


func _until(predicate: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if predicate.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return false
