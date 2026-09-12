extends Node
## --envperf : frame-cost comparison for the environment states on the REAL
## streamed city.
##
## Why this exists: the environment subsystem adds rain particles, volumetric fog
## and lightning to a city that is already streaming chunks, so "it feels fine"
## is not evidence.  This probe measures the same camera at the same time of day
## across clear / heavy rain / storm and reports what each state actually costs:
## frame time (avg/p99), draw calls, primitives, particle budget, node count
## growth and duplicate-node checks.
##
## Run it windowed (a real GPU; headless has no draw calls and no GPU cost):
##   godot --path "<project>" -- --envperf
## Optional: --envperf --envquality=low to compare quality steps.

const SETTLE_SECONDS := 25.0
const SETTLE_MAX_SECONDS := 150.0
const WARMUP_SECONDS := 2.0
const SAMPLE_SECONDS := 6.0
const PERF_STATES: Array[String] = ["clear", "cloudy", "heavy_rain", "storm"]
const PERF_HOUR := 12.0

var _env: EnvironmentManager = null
var _frame_ms: Array[float] = []
var _fps: Array[float] = []
var _draws: Array[float] = []
var _prims: Array[float] = []
var _sampling := false
var _t := 0.0
var _rows: Array[Dictionary] = []
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "EnvironmentPerf"
	_run.call_deferred()


func _process(delta: float) -> void:
	if _done or not _sampling:
		return
	_frame_ms.append(delta * 1000.0)
	_fps.append(float(Engine.get_frames_per_second()))
	_draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_prims.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("[EnvPerf] SKIPPED - headless has no GPU cost to measure")
		get_tree().quit(0)
		return
	if DisplayServer.window_can_draw():
		DisplayServer.window_move_to_foreground()
	await _settle_ring()
	await get_tree().process_frame
	_env = EnvironmentManager.instance_or_null()
	if _env == null:
		printerr("[EnvPerf] no EnvironmentManager in the live world")
		get_tree().quit(1)
		return
	print("[EnvPerf] quality=%s  day_length=%.0f s (%.0f game minutes)  hour=%.1f" % [
		EnvironmentConfig.QUALITY_NAMES[_env.quality], EnvironmentConfig.DAY_LENGTH_SECONDS,
		EnvironmentConfig.MINUTES_PER_DAY, PERF_HOUR])
	# Time is forced so every state is measured under identical lighting.
	if _env.has_method("force_time"):
		_env.force_time(PERF_HOUR, 0.0)
	await get_tree().create_timer(1.0).timeout
	for state in PERF_STATES:
		await _measure_state(state)
	_finish()


func _settle_ring() -> void:
	## A representative frame, not the first empty one: wait for the stream ring to
	## stop growing, with a hard cap so a stalled ring still reports.
	var waited := 0.0
	while waited < SETTLE_MAX_SECONDS:
		await get_tree().create_timer(10.0).timeout
		waited += 10.0
		var cm := _find_chunk_manager()
		var pending := -1
		if cm != null and "pending_jobs" in cm and cm.pending_jobs != null:
			pending = int(cm.pending_jobs)
		if waited >= SETTLE_SECONDS and (pending == 0 or pending < 0):
			break
	print("[EnvPerf] settlement wait finished after %0.0f s" % waited)


func _find_chunk_manager() -> Node:
	for n: Node in get_tree().root.find_children("*", "Node3D", true, false):
		if "chunk" in n.name.to_lower() and n.has_method("debug_lines"):
			return n
	return null


func _measure_state(state: String) -> void:
	_frame_ms.clear()
	_fps.clear()
	_draws.clear()
	_prims.clear()
	var nodes_before := _node_count()
	var env_nodes_before := _env_node_counts()
	_env.force_weather(state)
	await get_tree().create_timer(WARMUP_SECONDS).timeout
	_t = 0.0
	_sampling = true
	await get_tree().create_timer(SAMPLE_SECONDS).timeout
	_sampling = false
	# One more full transition frame before the leak check, so any per-transition
	# allocation (particle buffers, one-shot nodes) is included.
	await get_tree().create_timer(0.5).timeout
	var row := _summarize(state, nodes_before, env_nodes_before)
	_rows.append(row)
	_print_row(row)


func _summarize(state: String, nodes_before: int, env_nodes_before: Dictionary) -> Dictionary:
	var sorted_ms := _frame_ms.duplicate()
	sorted_ms.sort()
	var n := sorted_ms.size()
	var avg_ms := 0.0
	for v in _frame_ms:
		avg_ms += v
	avg_ms = avg_ms / maxf(1.0, float(n))
	var p99_ms := 0.0
	if n > 0:
		p99_ms = sorted_ms[int(clampf(float(n) * 0.99, 0.0, float(n - 1)))]
	var avg_draw := 0.0
	for v in _draws:
		avg_draw += v
	avg_draw = avg_draw / maxf(1.0, float(_draws.size()))
	var avg_prim := 0.0
	for v in _prims:
		avg_prim += v
	avg_prim = avg_prim / maxf(1.0, float(_prims.size()))
	var snapshot: Dictionary = _env.state()
	var env_nodes_after := _env_node_counts()
	return {
		"state": state,
		"samples": n,
		"avg_ms": avg_ms,
		"p99_ms": p99_ms,
		"worst_ms": sorted_ms[n - 1] if n > 0 else 0.0,
		"fps": (1000.0 / avg_ms) if avg_ms > 0.0 else 0.0,
		"draws": avg_draw,
		"prims": avg_prim,
		"rain": float(snapshot.get("precipitation", 0.0)),
		"fog": float(snapshot.get("fog", 0.0)),
		"cloud": float(snapshot.get("cloud", 0.0)),
		"wind": float(snapshot.get("wind_speed", 0.0)),
		"wetness": float(snapshot.get("wetness", 0.0)),
		"rain_particles": int(snapshot.get("rain_particles", 0)),
		"manager_particles": _particle_budget(),
		"nodes_before": nodes_before,
		"nodes_after": _node_count(),
		"env_nodes_before": env_nodes_before,
		"env_nodes_after": env_nodes_after,
		"lights": _count("Light3D"),
		"world_envs": _count("WorldEnvironment"),
	}


func _print_row(r: Dictionary) -> void:
	print("[EnvPerf] %-10s avg %6.2f ms (%5.1f fps)  p99 %6.2f ms  worst %7.2f ms  draws %6.0f  prims %9.0f  particles %d" % [
		r["state"], r["avg_ms"], r["fps"], r["p99_ms"], r["worst_ms"], r["draws"], r["prims"], r["manager_particles"]])
	print("[EnvPerf] %-10s cloud %.2f rain %.2f fog %.2f wind %.1f wet %.2f  rain_particles %d  nodes %d->%d  lights %d  world_envs %d  env_nodes %s->%s" % [
		r["state"], r["cloud"], r["rain"], r["fog"], r["wind"], r["wetness"],
		r["rain_particles"], r["nodes_before"], r["nodes_after"], r["lights"], r["world_envs"],
		str(r["env_nodes_before"]), str(r["env_nodes_after"])])


func _finish() -> void:
	_done = true
	print("[EnvPerf] === environment cost summary (same camera, same hour) ===")
	for r: Dictionary in _rows:
		print("[EnvPerf] %-10s %6.2f ms avg / %6.2f ms p99  (%5.1f fps)  nodes +%d  draws %6.0f  particles %d" % [
			r["state"], r["avg_ms"], r["p99_ms"], r["fps"],
			int(r["nodes_after"]) - int(r["nodes_before"]), r["draws"], r["manager_particles"]])
	var clear_ms := float(_rows[0]["avg_ms"]) if _rows.size() > 0 else 0.0
	for r: Dictionary in _rows:
		var delta := float(r["avg_ms"]) - clear_ms
		print("[EnvPerf] %-10s costs %+6.2f ms vs clear (%+.1f%%)" % [
			r["state"], delta, (delta / clear_ms * 100.0) if clear_ms > 0.0 else 0.0])
	# Duplicate-node guard: atmosphere, rain and lightning must be single
	# instances, and chunk streaming must not add more of them.
	var dupes: Array[String] = []
	if int(_rows[-1]["world_envs"]) > 1:
		dupes.append("world_envs=%d" % int(_rows[-1]["world_envs"]))
	var after: Dictionary = _rows[-1]["env_nodes_after"]
	var before: Dictionary = _rows[-1]["env_nodes_before"]
	for key: String in after:
		if int(after[key]) > int(before.get(key, 0)):
			dupes.append("%s %d->%d" % [key, int(before.get(key, 0)), int(after[key])])
	if dupes.is_empty():
		print("[EnvPerf] ok   no duplicate environment nodes after 3 weather transitions")
	else:
		print("[EnvPerf] FAIL duplicate environment nodes: %s" % ", ".join(dupes))
	get_tree().quit(0)


func _count(klass: String) -> int:
	return get_tree().root.find_children("*", klass, true, false).size()


func _node_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _particle_budget() -> int:
	## Sum of `amount` over ACTIVE particle emitters: the number that actually
	## costs fill rate, as opposed to allocated-but-parked emitters.
	var total := 0
	for n: Node in get_tree().root.find_children("*", "CPUParticles3D", true, false):
		var p := n as CPUParticles3D
		if p != null and p.emitting and p.visible:
			total += p.amount
	for n: Node in get_tree().root.find_children("*", "GPUParticles3D", true, false):
		var p := n as GPUParticles3D
		if p != null and p.emitting and p.visible:
			total += p.amount
	return total


## Counts the nodes the environment subsystem owns.  Type-based, not name-based:
## the check exists to prove chunk streaming never grows the count, so it must
## count exactly what the subsystem creates (one manager, one sun, one moon, one
## precipitation emitter).
func _env_node_counts() -> Dictionary:
	var counts := {"suns": 0, "moons": 0, "managers": 0, "rain": 0}
	for n: Node in get_tree().root.find_children("*", "Node", true, false):
		if n is EnvironmentManager:
			counts["managers"] += 1
		elif n is EnvironmentPrecipitation:
			counts["rain"] += 1
		elif n is DirectionalLight3D and n.name == AtmosphereController.SUN_NODE_NAME:
			counts["suns"] += 1
		elif n is DirectionalLight3D and n.name == AtmosphereController.MOON_NODE_NAME:
			counts["moons"] += 1
	return counts
