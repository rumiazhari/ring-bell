extends Node
const OUT_BASE := "C:/Vibe Code project/Godot Project/ring-bell/.hermes/autopilot/reports/fringe-part1"
const W := 1200
const H := 720
var _captures: Array[Dictionary] = []
var _world: WorldPlan
var _city: CityPlan
func _ready() -> void:
	print("[FringeCapture] starting")
	var t := get_tree().create_timer(1.5)
	await t.timeout
	await _ensure_dirs()
	await _build_capture_list()
	for idx in _captures.size():
		var cap: Dictionary = _captures[idx]
		await _capture_one(cap, idx)
	print("[FringeCapture] all done for seed %d" % WorldSeed.get_world_seed())
	var mgrs := get_tree().get_nodes_in_group(&"chunk_manager")
	if mgrs.size() > 0:
		var mgr: ChunkManager = mgrs[0]
		for line in mgr.debug_lines():
			print("[FringeCapture] %s" % line)
	get_tree().quit(0)
func _ensure_dirs() -> void:
	var base := DirAccess.open(OUT_BASE)
	if base == null:
		DirAccess.make_dir_recursive_absolute(OUT_BASE + "/real")
	else:
		if not DirAccess.dir_exists_absolute(OUT_BASE + "/real"):
			DirAccess.make_dir_recursive_absolute(OUT_BASE + "/real")
func _build_capture_list() -> void:
	_city = CityPlan.new()
	_world = WorldPlan.new(_city.seed_used)
	var pos1 := Vector3(300, 0, 0)
	pos1.y = _world.surface_height_at(Vector2(pos1.x, pos1.z)) + 1.65
	var look1 := Vector3(650, 0, 20)
	look1.y = _world.surface_height_at(Vector2(look1.x, look1.z)) + 2.0
	var inner_pos := Vector3(400, 0, 30)
	inner_pos.y = _world.surface_height_at(Vector2(inner_pos.x, inner_pos.z)) + 1.65
	var inner_look := inner_pos + Vector3(18, -0.9, 12)
	var ind_pos := Vector3(620, 0, -40)
	ind_pos.y = _world.surface_height_at(Vector2(ind_pos.x, ind_pos.z)) + 1.65
	var ind_look := ind_pos + Vector3(14, -0.8, -10)
	var peri_pos := Vector3(900, 0, 60)
	peri_pos.y = _world.surface_height_at(Vector2(peri_pos.x, peri_pos.z)) + 1.65
	var peri_look := peri_pos + Vector3(20, -1.0, -6)
	var macro_pos := Vector3(0, 0, 0)
	macro_pos.y = _world.surface_height_at(Vector2.ZERO) + 65.0
	var macro_look := Vector3(700, 0, 700)
	macro_look.y = _world.surface_height_at(Vector2(macro_look.x, macro_look.z)) + 1.0
	var seed_tag := "seed_%d" % WorldSeed.get_world_seed()
	_captures = [
		{"id": "%s_01_city_toward_fringe" % seed_tag, "pos": pos1, "look": look1, "desc": "View from dense city toward fringe — gradual reduction, inner fringe dense streets 300-550"},
		{"id": "%s_02_inner_fringe_street" % seed_tag, "pos": inner_pos, "look": inner_look, "desc": "Inner fringe street — tenements/row houses, continuous frontage, workshops, courtyards"},
		{"id": "%s_03_industrial_fringe" % seed_tag, "pos": ind_pos, "look": ind_look, "desc": "Industrial fringe — warehouse/factory yard, brick walls, chimneys, fenced compound"},
		{"id": "%s_04_outer_peri_urban" % seed_tag, "pos": peri_pos, "look": peri_look, "desc": "Outer/peri-urban — detached houses, garden plots, orchards blending to fields"},
		{"id": "%s_05_elevated_macro" % seed_tag, "pos": macro_pos, "look": macro_look, "desc": "Elevated macro — proves no circular 350/600 cutoff, deformed by roads/terrain"},
	]
	for c in _captures:
		print("[FringeCapture] planned %s at %s look %s" % [c["id"], str(c["pos"]), str(c["look"])])
func _capture_one(cap: Dictionary, idx: int) -> void:
	var id: String = cap["id"]
	var pos: Vector3 = cap["pos"]
	var look: Vector3 = cap["look"]
	var desc: String = cap["desc"]
	print("[FringeCapture] capturing %s pos %s look %s" % [id, str(pos), str(look)])
	var player := ActorRegistry.get_actor(&"player")
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	var mgr: ChunkManager = null
	if managers.size() > 0:
		mgr = managers[0] as ChunkManager
	if player != null and is_instance_valid(player):
		var p2 := Vector2(pos.x, pos.z)
		var h: float = _world.surface_height_at(p2) if _world != null else pos.y
		player.global_position = Vector3(pos.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M + 1.55, pos.z)
		var cam := _get_or_create_camera()
		cam.global_position = player.global_position
		cam.look_at(Vector3(look.x, cam.global_position.y - 1.1, look.z), Vector3.UP)
		await _wait_for_chunks(mgr, Vector2(pos.x, pos.z))
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().create_timer(0.7).timeout
		await _save_viewport(id, desc)
	else:
		var cam2 := Camera3D.new()
		cam2.fov = 72
		cam2.near = 0.05
		cam2.far = 1200.0
		get_tree().root.add_child(cam2)
		cam2.global_position = pos
		cam2.look_at(look, Vector3.UP)
		cam2.make_current()
		await get_tree().process_frame
		await get_tree().process_frame
		if mgr != null:
			await _wait_for_chunks(mgr, Vector2(pos.x, pos.z))
		await get_tree().create_timer(0.9).timeout
		await _save_viewport(id, desc)
		cam2.queue_free()
func _get_or_create_camera() -> Camera3D:
	var existing := get_viewport().get_camera_3d()
	if existing != null and is_instance_valid(existing):
		return existing
	var cam := Camera3D.new()
	cam.fov = 72
	get_tree().root.add_child(cam)
	cam.make_current()
	return cam
func _wait_for_chunks(mgr: ChunkManager, p2: Vector2) -> void:
	if mgr == null:
		await get_tree().create_timer(1.0).timeout
		return
	var coord := WorldSeed.chunk_coord(p2.x, p2.y)
	var t := 0.0
	while t < 7.0:
		await get_tree().process_frame
		var ok := true
		for dx in [-1,0,1]:
			for dz in [-1,0,1]:
				var c := coord + Vector2i(dx, dz)
				if not mgr.is_resident(c):
					ok = false
		if ok:
			break
		t += get_process_delta_time()
		if int(t*10) % 20 == 0:
			print("[FringeCapture] waiting chunks at %s t=%.1f resident=%d" % [str(coord), t, mgr._chunks.size()])
func _save_viewport(id: String, desc: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var vp := get_viewport()
	if vp is Window:
		(vp as Window).size = Vector2i(W, H)
	var img := vp.get_texture().get_image()
	var path := OUT_BASE + "/real/" + id + ".png"
	var err := img.save_png(path)
	if err != OK:
		print("[FringeCapture] save FAILED %s err %d" % [path, err])
	else:
		print("[FringeCapture] saved %s (%dx%d) desc: %s" % [path, img.get_width(), img.get_height(), desc])
	var mgrs2 := get_tree().get_nodes_in_group(&"chunk_manager")
	if mgrs2.size() > 0:
		var m: ChunkManager = mgrs2[0]
		var lines: Array[String] = m.debug_lines()
		var log_path := OUT_BASE + "/real/" + id + ".log"
		var f := FileAccess.open(log_path, FileAccess.WRITE)
		if f != null:
			f.store_line("id=%s" % id)
			f.store_line("desc=%s" % desc)
			for ln in lines:
				f.store_line(ln)
			f.close()
			print("[FringeCapture] log %s" % log_path)
