extends Node
## Tree capture — renders the tree system so it can be judged by eye:
##   lineup_side.png   all ten species in a row, eye level 1.7 m
##   lineup_close.png  close on oak + pine: crook, roots, twig structure
##   lineup_contre.png looking up the row: crown silhouettes against sky
##   park_ingame.png   the real city: a park block with its trees, in situ
##
##   godot --path . -- --treecapture [seed]
##
## A windowed run is required; the headless renderer cannot capture 3D.

const OUT_DIR := "res://captures/trees"
const ROW: Array[StringName] = [&"linden", &"oak", &"pine", &"spruce", &"birch",
	&"beech", &"maple", &"ash", &"chestnut", &"locust"]
const SPACING := 9.0

var _seed := 19041207
var _shots := 0
var _vp: SubViewport
var _stage: Node3D


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[TreeCapture] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	var user_args := OS.get_cmdline_user_args()
	for i in user_args.size():
		if user_args[i] == "--seed" and i + 1 < user_args.size():
			_seed = int(user_args[i + 1])
	_run()


func _run() -> void:
	# Render into our own viewport with its own world: the running game's camera
	# would otherwise stay current and every shot would frame the player.
	_vp = SubViewport.new()
	_vp.size = Vector2i(1600, 900)
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_stage = Node3D.new()
	_vp.add_child(_stage)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-44, -36, 0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.97, 0.92)
	_stage.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("8ea7b8")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.92, 0.94, 0.98)
	env.environment.ambient_light_energy = 0.55
	_stage.add_child(env)
	var camera := Camera3D.new()
	camera.name = "TreeCaptureCamera"
	_stage.add_child(camera)
	camera.make_current()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var world_plan := WorldPlan.new(_seed)

	# ---- 1. Isolated line-up on real terrain, away from the city grid.
	var row_center := _flat_spot(world_plan)
	var holder := Node3D.new()
	_stage.add_child(holder)
	for dx in [-1, 0, 1]:
		for dz in [-2, -1, 0, 1, 2]:
			var c := WorldSeed.chunk_coord(row_center.x, row_center.y) + Vector2i(dx, dz)
			TerrainChunkBuilder.materialize(holder, TerrainChunkBuilder.build_manifest(world_plan, c))

	var b := MeshBatcher.new()
	var stats: Array[String] = []
	for i in ROW.size():
		var species: StringName = ROW[i]
		var x := row_center.x + (float(i) - float(ROW.size() - 1) * 0.5) * SPACING
		var p := Vector2(x, row_center.y)
		var y := world_plan.surface_height_at(p)
		var info := TreeBuilder.build(b, Vector3(p.x, y, p.y), species, {
			"seed": 7000 + i * 131, "yaw": 0.7 * float(i),
			"detail": TreeBuilder.Detail.FEATURE})
		stats.append("%s h=%.1fm parts=%d verts=%d" % [
			species, float(info["height"]), int(info["parts"]), int(info["verts"])])
	var line_holder := Node3D.new()
	_stage.add_child(line_holder)
	var mi := MeshInstance3D.new()
	mi.mesh = b._mesh_from(b._build_layers())
	line_holder.add_child(mi)
	for row in stats:
		print("[TreeCapture] %s" % row)

	var ground := world_plan.surface_height_at(row_center)
	var west := Vector3(row_center.x - float(ROW.size()) * SPACING * 0.5, 0.0, row_center.y)
	var east := Vector3(row_center.x + float(ROW.size()) * SPACING * 0.5, 0.0, row_center.y)
	await _shot(camera,
		Vector3(west.x - 16.0, ground + 1.75, west.z - 26.0),
		Vector3(row_center.x, ground + 6.0, row_center.y), "lineup_wide")
	# A few species filling the frame: at this distance the crown silhouettes are
	# large enough to actually judge (the wide shot alone is not).
	var side_x: float = row_center.x - 1.5 * SPACING
	await _shot(camera,
		Vector3(side_x, ground + 2.0, row_center.y - 17.0),
		Vector3(side_x, ground + 5.5, row_center.y), "lineup_side")
	# The Scots pine on its own: the crown the umbrella form has to sell.
	var pine_i: int = ROW.find(&"pine")
	var pine_x: float = row_center.x + (float(pine_i) - 4.5) * SPACING
	await _shot(camera,
		Vector3(pine_x - 7.0, ground + 2.2, row_center.y - 8.0),
		Vector3(pine_x, ground + 7.0, row_center.y), "pine_close")
	await _shot(camera,
		Vector3(row_center.x - 3.0 * SPACING - 5.5, ground + 1.60, row_center.y - 6.5),
		Vector3(row_center.x - 2.5 * SPACING, ground + 2.2, row_center.y), "lineup_close")
	await _shot(camera,
		Vector3(row_center.x, ground + 0.9, row_center.y - 9.0),
		Vector3(east.x, ground + 14.0, east.z), "lineup_contre")

	# ---- 2. In situ: real park block from the city plan, trees included.
	var plan := CityPlan.new(_seed)
	var park: Dictionary = {}
	for block_variant in plan.city_blocks():
		var block: Dictionary = block_variant as Dictionary
		var kind := StringName(block.get("kind", &""))
		if kind == &"built" or kind == &"plaza":
			continue
		var rect: Rect2 = block.get("bounds", block.get("rect", Rect2())) as Rect2
		if rect.size.x < 16.0 or rect.size.y < 16.0 or rect.size.x > 80.0 or rect.size.y > 80.0:
			continue
		park = block
		break
	if park.is_empty():
		print("[TreeCapture] no park block found; skipping in-situ shot")
	else:
		var rect2: Rect2 = park.get("bounds", park.get("rect", Rect2())) as Rect2
		var center := rect2.get_center()
		var coord := WorldSeed.chunk_coord(center.x, center.y)
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var c := coord + Vector2i(dx, dz)
				TerrainChunkBuilder.materialize(holder, TerrainChunkBuilder.build_manifest(world_plan, c))
				ChunkBuilder.build(holder, plan, c, null, {}, false, true, world_plan)
		var g := world_plan.surface_height_at(center)
		# Look in over the roofs from clear of the block edge: standing inside the
		# block at eye level framed a wall, not the trees.
		await _shot(camera,
			Vector3(center.x - rect2.size.x * 0.95, g + 9.0, center.y - rect2.size.y * 0.95),
			Vector3(center.x, g + 4.5, center.y), "park_ingame")
	print("[TreeCapture] all captures done (%d)" % _shots)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


## Walk the world until we find open ground with little relief, so the line-up
## stands on real terrain rather than a hand-made flat plane.
func _flat_spot(world_plan: WorldPlan) -> Vector2:
	var base := Vector2(340.0, 340.0)
	for step in 40:
		var p := base + Vector2(float(step % 8) * 34.0, float(step / 8) * 34.0)
		var lo := INF
		var hi := -INF
		for ix in 4:
			for iz in 4:
				var q := p + Vector2(float(ix) * 7.0 - 10.0, float(iz) * 7.0 - 10.0)
				var h := world_plan.surface_height_at(q)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		if hi - lo < 1.2:
			return p
	return base


func _shot(camera: Camera3D, pos: Vector3, look: Vector3, name: String) -> void:
	camera.make_current()
	camera.position = pos
	camera.look_at(look)
	for f in 5:
		await RenderingServer.frame_post_draw
	var active := _vp.get_camera_3d()
	if active == null or active.name != "TreeCaptureCamera":
		print("[TreeCapture] WARNING camera is %s" % str(active))
	var img := _vp.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	img.save_png(path)
	_shots += 1
	print("[TreeCapture] saved %s" % ProjectSettings.globalize_path(path))
