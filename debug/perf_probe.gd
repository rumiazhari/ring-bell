extends Node
## --perftest  : windowed frame-performance bisection on the REAL streamed city.
##
## Why this exists: "4-5 FPS" is a symptom, and the fix depends on WHICH budget is
## blown. This probe measures instead of guessing:
##   * is the frame CPU-script bound, CPU-physics bound or GPU bound
##   * how many draw calls / primitives / lights / bodies the live ring actually has
##   * what each render feature costs, by toggling ONE feature at a time and
##     re-sampling the same camera, then restoring it
## Run it windowed (real GPU) through the project runner:
##   python tools/run_suite.py --perftest 300 --rendered
## Headless runs are useless here (dummy renderer: zero draw calls, no GPU cost).

const SAMPLE_SECONDS := 5.0
const SETTLE_SECONDS := 20.0
const SETTLE_MAX_SECONDS := 150.0
const WARMUP_SECONDS := 2.0

var _samples: Array[Dictionary] = []
var _acc_fps: Array[float] = []
var _acc_proc: Array[float] = []
var _acc_phys: Array[float] = []
var _acc_draw: Array[float] = []
var _acc_prim: Array[float] = []
var _report: Array[Dictionary] = []
var _t := 0.0
var _sampling := false
var _done := false
var _sun: DirectionalLight3D = null
var _env: Environment = null
var _lights: Array[Light3D] = []
var _stages: Array[Dictionary] = []
var _stage_i := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "PerfProbe"


func _process(delta: float) -> void:
	if _done:
		return
	_t += delta
	if not _sampling:
		return
	_acc_fps.append(float(Engine.get_frames_per_second()))
	_acc_proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_acc_phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_acc_draw.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_acc_prim.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))


func _start() -> void:
	print("[Perf] probe start - settling the stream ring")
	# Phase-level flush timing: MeshBatcher/ChunkBuilder debug_profile prints one
	# [Flush] line per materialized chunk (layers/mesh/collision/assets ms).
	MeshBatcher.debug_profile = true
	ChunkBuilder.debug_profile = true
	if DisplayServer.window_can_draw():
		DisplayServer.window_move_to_foreground()
	await _settle_ring()
	_collect_refs()
	_print_inventory()
	_stages = _build_stages()
	await _run_stage(0)
	if _stage_i >= _stages.size():
		_finish()


func _settle_ring() -> void:
	## Measure a REPRESENTATIVE frame, not the first empty one: wait until the
	## stream ring stops growing, with a hard cap so a stalled ring still reports.
	var waited := 0.0
	while waited < SETTLE_MAX_SECONDS:
		await get_tree().create_timer(10.0).timeout
		waited += 10.0
		var cm: Node = _find_chunk_manager()
		var pending := -1
		if cm != null and cm.has_method("debug_lines"):
			var lines: Variant = cm.debug_lines()
			if lines is PackedStringArray:
				print("[Perf] ring@%0.0fs %s" % [waited, " | ".join(lines as PackedStringArray)])
		if cm != null and "pending_jobs" in cm:
			pending = int(cm.pending_jobs) if cm.pending_jobs != null else -1
		if waited >= SETTLE_SECONDS and (pending == 0 or pending < 0):
			break
	print("[Perf] settlement wait finished after %0.0f s" % waited)


func _find_chunk_manager() -> Node:
	## Search by NAME, not by script class: find_children(type) matches native
	## classes reliably, while a GDScript class_name is not guaranteed to match.
	for n: Node in get_tree().root.find_children("*", "Node3D", true, false):
		if "chunk" in n.name.to_lower() and n.has_method("debug_lines"):
			return n
	return null


func _collect_refs() -> void:
	for n: Node in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		_sun = n as DirectionalLight3D
		break
	for n2: Node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var we := n2 as WorldEnvironment
		if we != null and we.environment != null:
			_env = we.environment
			break
	_lights.clear()
	for n3: Node in get_tree().root.find_children("*", "Light3D", true, false):
		var l := n3 as Light3D
		if l != null and l is DirectionalLight3D == false:
			_lights.append(l)


func _count_nodes(klass: String) -> int:
	return get_tree().root.find_children("*", klass, true, false).size()


func _print_inventory() -> void:
	var player: Node3D = null
	for n: Node in get_tree().root.find_children("*", "CharacterBody3D", true, false):
		player = n as Node3D
		break
	print("[Perf] === live ring inventory ===")
	print("[Perf] nodes=%d render_objs=%d staticbodys=%d multimeshes=%d lights=%d viewport=%dx%d scale=%.2f msaa=%d" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		_count_nodes("StaticBody3D"),
		_count_nodes("MultiMeshInstance3D"),
		_lights.size(),
		get_viewport().size.x, get_viewport().size.y,
		get_viewport().scaling_3d_scale, get_viewport().msaa_3d])
	print("[Perf] resource_objs=%d memory_static=%.0f MB video_mem=%.0f MB texture_mem=%.0f MB" % [
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0])
	print("[Perf] physics3d active=%d pairs=%d islands=%d" % [
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)])
	# A throttled/occluded window fakes a low FPS: record focus + engine caps so a
	# suspicious flat frame time can be attributed instead of believed.
	print("[Perf] focus=%s vsync=%d max_fps=%d physics_hz=%d max_phys_steps=%d" % [
		str(DisplayServer.window_is_focused()),
		DisplayServer.window_get_vsync_mode(),
		Engine.max_fps,
		Engine.physics_ticks_per_second,
		Engine.max_physics_steps_per_frame])
	if _env != null:
		print("[Perf] env volfog=%s glow=%s ssao=%s ssil=%s sdfgi=%s fog=%s" % [
			str(_env.volumetric_fog_enabled), str(_env.glow_enabled),
			str(_env.ssao_enabled), str(_env.ssil_enabled),
			str(_env.sdfgi_enabled), str(_env.fog_enabled)])
	if player != null:
		print("[Perf] player at %s" % str(player.global_position))
	_tally_processing()


func _tally_processing() -> void:
	## Script-side per-step cost is invisible to ms_process when it lands in
	## _physics_process of thousands of small nodes. Tally who is ticking.
	var by_script: Dictionary = {}
	var phys_total := 0
	var proc_total := 0
	for n: Node in get_tree().root.find_children("*", "Node", true, false):
		var is_phys := n.is_physics_processing()
		var is_proc := n.is_processing()
		if not is_phys and not is_proc:
			continue
		if is_phys:
			phys_total += 1
		if is_proc:
			proc_total += 1
		var sk := ""
		var s: Script = null
		var raw_script: Variant = n.get_script()
		if raw_script is Script:
			s = raw_script as Script
		if s != null:
			sk = str(s.resource_path)
		var key := "%s|%s" % [n.get_class() if sk == "" else sk.get_file(), "P" if is_phys else "", ]
		key = key.rstrip("|")
		if is_phys:
			key += "|physics:" + str(is_proc)
		else:
			key += "|process"
		var cur: Array = by_script.get(key, [0, 0])
		cur[0] = int(cur[0]) + 1
		by_script[key] = cur
	print("[Perf] ticking nodes: physics=%d process=%d (unique=%d)" % [
		phys_total, proc_total, by_script.size()])
	var keys: Array = by_script.keys()
	keys.sort()
	for k: String in keys:
		print("[Perf]   tick %-58s x%d" % [k, int(by_script[k][0])])


func _build_stages() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"label": "baseline"})
	# Ordered by suspicion: fog/glow (fullscreen GPU passes) first, then MSAA,
	# then shadow map, then real-light count, then geometry/CPU, then resolution.
	if _env != null:
		out.append({"label": "volumetric_fog OFF", "feat": "volfog"})
		out.append({"label": "glow OFF", "feat": "glow"})
		out.append({"label": "depth fog OFF", "feat": "fog"})
	if _sun != null:
		out.append({"label": "sun shadows OFF", "feat": "sunshadow"})
	out.append({"label": "msaa OFF", "feat": "msaa"})
	# PHYSICS-AXIS probes: ms_physics is a per-STEP cost, so with 60 Hz physics and
	# max_physics_steps_per_frame=8 the loop can starve on time alone — independent
	# of anything the camera can see. These three isolate that.
	out.append({"label": "physics hz 30", "feat": "physhz"})
	# Per-class isolation runs BEFORE "script ticks off": ms_physics is script time
	# (0.19 ms with ticks off), so turning one ticking class off at a time names the
	# culprit. Ticks-off must come last: its restore pass would otherwise re-enable
	# ticks on every node in the tree and corrupt the stages that follow it.
	out.append({"label": "cloth ticks off", "feat": "ticks_cloth"})
	out.append({"label": "player tick off", "feat": "ticks_player"})
	out.append({"label": "survivor tick off", "feat": "ticks_survivor"})
	out.append({"label": "abyss tick off", "feat": "ticks_abyss"})
	out.append({"label": "player+survivor off", "feat": "ticks_actor"})
	out.append({"label": "script ticks off", "feat": "ticks"})
	out.append({"label": "static bodies out of broadphase", "feat": "bodies"})
	out.append({"label": "real lights hidden", "feat": "lights"})
	out.append({"label": "mesh instances hidden", "feat": "meshes"})
	out.append({"label": "render scale 0.6", "feat": "scale"})
	out.append({"label": "volfog+glow+msaa OFF", "feat": "combo"})
	return out


func _apply_stage(feat: String, on: bool) -> void:
	match feat:
		"volfog":
			if _env != null:
				_env.volumetric_fog_enabled = on
		"glow":
			if _env != null:
				_env.glow_enabled = on
		"fog":
			if _env != null:
				_env.fog_enabled = on
		"sunshadow":
			if _sun != null:
				_sun.shadow_enabled = on
		"msaa":
			get_viewport().msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED
		"lights":
			for l: Light3D in _lights:
				if is_instance_valid(l):
					l.visible = on
		"meshes":
			if not on:
				_hide_mesh_instances()
			else:
				_restore_mesh_instances()
		"scale":
			get_viewport().scaling_3d_scale = 1.0 if on else 0.6
		"combo":
			if _env != null:
				_env.volumetric_fog_enabled = on
				_env.glow_enabled = on
			get_viewport().msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED
		"physhz":
			Engine.physics_ticks_per_second = 60 if on else 30
		"ticks":
			_set_script_ticks(on)
		"ticks_cloth":
			_set_class_ticks(["skirt_cloth.gd", "garment_joint.gd"], on)
		"ticks_player":
			_set_class_ticks(["player_controller.gd"], on)
		"ticks_survivor":
			_set_class_ticks(["survivor.gd"], on)
		"ticks_abyss":
			_set_class_ticks(["abyss_recovery.gd"], on)
		"ticks_actor":
			_set_class_ticks(["player_controller.gd", "survivor.gd"], on)
		"bodies":
			_set_body_collision(on)


var _restore_phys: Array[Node] = []
var _restore_proc: Array[Node] = []


func _set_class_ticks(script_names: Array, on: bool) -> void:
	## Turns physics/process ticks off for every node whose script file matches one
	## of script_names. ms_physics is script time, so this names the per-step culprit.
	for n: Node in get_tree().root.find_children("*", "Node", true, false):
		var raw: Variant = n.get_script()
		if not (raw is Script):
			continue
		var path: String = (raw as Script).resource_path
		for wanted: String in script_names:
			if path.ends_with(wanted):
				n.set_physics_process(on)
				n.set_process(on)
				break


func _set_script_ticks(on: bool) -> void:
	# Isolates scripted per-step cost from the physics server: leaves the PLAYER
	# and the camera ticking so the probe still behaves normally.
	var keep: Array[Node] = []
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		keep.append(cam)
		var walk: Node = cam
		while walk != null:
			keep.append(walk)
			walk = walk.get_parent()
	if on:
		# Restore ONLY the nodes this function disabled. Blanket set_physics_process(true)
		# across the tree switched ticking on for ~165k nodes that never ticked, which
		# silently changed the cost of every stage after this one (ms_process 12 -> 28).
		for n in _restore_phys:
			if is_instance_valid(n):
				n.set_physics_process(true)
		for n in _restore_proc:
			if is_instance_valid(n):
				n.set_process(true)
		_restore_phys.clear()
		_restore_proc.clear()
		return
	for n: Node in get_tree().root.find_children("*", "Node", true, false):
		if n == self or keep.has(n):
			continue
		if n.is_physics_processing():
			n.set_physics_process(false)
			_restore_phys.append(n)
		if n.is_processing():
			n.set_process(false)
			_restore_proc.append(n)


func _set_body_collision(on: bool) -> void:
	## Isolates broadphase/space cost from script cost: same bodies, but their
	## shapes leave the collision space entirely.
	var bodies := get_tree().root.find_children("*", "StaticBody3D", true, false)
	for b: Node in bodies:
		(b as StaticBody3D).collision_layer = 1 if on else 0
	print("[Perf]   (bodies toggled: %d)" % bodies.size())


var _hidden_meshes: Array[Node] = []


func _hide_mesh_instances() -> void:
	_hidden_meshes.clear()
	for n: Node in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			mi.visible = false
			_hidden_meshes.append(mi)


func _restore_mesh_instances() -> void:
	for n: Node in _hidden_meshes:
		if is_instance_valid(n):
			(n as MeshInstance3D).visible = true
	_hidden_meshes.clear()


func _run_stage(i: int) -> void:
	_stage_i = i
	if i >= _stages.size():
		return
	var st: Dictionary = _stages[i]
	var label := str(st["label"])
	var feat := str(st.get("feat", ""))
	if feat != "":
		_apply_stage(feat, false)
		await get_tree().create_timer(WARMUP_SECONDS).timeout
	_acc_fps.clear()
	_acc_proc.clear()
	_acc_phys.clear()
	_acc_draw.clear()
	_acc_prim.clear()
	_sampling = true
	await get_tree().create_timer(SAMPLE_SECONDS).timeout
	_sampling = false
	var row := _row(label)
	_report.append(row)
	print("[Perf] stage '%s' fps p50=%.1f p95=%.1f ms_process p50=%.2f ms_physics p50=%.2f draws p50=%.0f prims p50=%.0f" % [
		label, row["fps_p50"], row["fps_p95"], row["proc_p50"], row["phys_p50"],
		row["draw_p50"], row["prim_p50"]])
	if feat != "":
		_apply_stage(feat, true)
		await get_tree().create_timer(WARMUP_SECONDS).timeout
	await _run_stage(i + 1)


func _p50(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var b: Array[float] = a.duplicate()
	b.sort()
	return b[int(float(b.size() - 1) * 0.5)]


func _p95(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var b: Array[float] = a.duplicate()
	b.sort()
	return b[int(float(b.size() - 1) * 0.95)]


func _row(label: String) -> Dictionary:
	return {
		"label": label,
		"fps_p50": _p50(_acc_fps), "fps_p95": _p95(_acc_fps),
		"proc_p50": _p50(_acc_proc), "phys_p50": _p50(_acc_phys),
		"draw_p50": _p50(_acc_draw), "prim_p50": _p50(_acc_prim),
	}


func _finish() -> void:
	_done = true
	var base := 0.0
	for r: Dictionary in _report:
		if str(r["label"]) == "baseline":
			base = float(r["fps_p50"])
	print("[Perf] ==== summary (fps p50, delta vs baseline %0.1f) ====" % base)
	for r: Dictionary in _report:
		var f := float(r["fps_p50"])
		var saver := 0.0
		if f > 0.001 and base > 0.001:
			saver = (1.0 / f - 1.0 / base) * 1000.0
		print("[Perf] %-24s fps=%6.1f  delta=%+6.1f fps  saved=%.2f ms/frame  draws=%.0f  prims=%.0f" % [
			str(r["label"]), f, f - base, saver, float(r["draw_p50"]), float(r["prim_p50"])])
	var cpu := 0.0
	for r2: Dictionary in _report:
		if str(r2["label"]) == "baseline":
			cpu = float(r2["proc_p50"]) + float(r2["phys_p50"])
	var ft := 0.0
	if base > 0.001:
		ft = 1000.0 / base
	print("[Perf] verdict: frame=%.1f ms, script+physics=%.2f ms (%.0f%% of frame)" % [
		ft, cpu, (cpu / ft) * 100.0 if ft > 0.0 else 0.0])
	print("[Perf] finished -- perftest done, quitting")
	get_tree().quit(0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_start()
