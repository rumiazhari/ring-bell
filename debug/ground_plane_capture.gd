extends Node
## Ground plane capture: the defect the player reported - a ground pad drawn as
## a flat plate that hangs in the air over sloping ground ("what is this green
## plane flying here").
##
##   godot --path . -- --groundplanecapture [seed]
##
## Finds the grass/park block with the LARGEST terrain relief across it (the
## worst case of a pad that used to be laid flat at one sample height) and
## frames it three ways, terrain included, so the fix can be judged by eye:
##   pad_edge.png - 1.7 m eye level across the pad, where a gap underneath shows
##   pad_low.png  - 0.6 m close on the pad edge, the classic floater shot
##   pad_top.png  - overhead, the pad against the slopes around it
## A windowed run is required; the headless renderer cannot capture 3D.
const OUT_DIR := "res://captures/ground-plane"

var _seed := 19041207
var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[GroundPlaneCapture] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	var user_args := OS.get_cmdline_user_args()
	for i in user_args.size():
		if user_args[i] == "--seed" and i + 1 < user_args.size():
			_seed = int(user_args[i + 1])
	_run()


func _run() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -38, 0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.97, 0.92)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("6f7a80")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.92, 0.94, 0.98)
	env.environment.ambient_light_energy = 0.55
	add_child(env)
	var camera := Camera3D.new()
	add_child(camera)
	camera.current = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var world_plan := WorldPlan.new(_seed)
	var plan := CityPlan.new(_seed)

	# Worst-case pad: the green block with the most terrain across it.
	var best: Dictionary = {}
	var best_relief := -1.0
	for block_variant in plan.city_blocks():
		var block: Dictionary = block_variant as Dictionary
		var kind := StringName(block.get("kind", &""))
		if kind == &"built" or kind == &"plaza":
			continue
		var rect: Rect2 = block.get("bounds", block.get("rect", Rect2())) as Rect2
		# A park the player actually walks past: modest size, real slope.
		if rect.size.x > 90.0 or rect.size.y > 90.0 or rect.size.x < 12.0 or rect.size.y < 12.0:
			continue
		var historic := StringName(block.get("district", &"")) == CityPlan.DISTRICT_HISTORIC
		var lo := INF
		var hi := -INF
		for ix in 5:
			for iz in 5:
				var p := rect.position + Vector2(rect.size.x * float(ix) / 4.0,
						rect.size.y * float(iz) / 4.0)
				var h := world_plan.surface_height_at(p)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		var score := hi - lo
		if score < 0.80 or score > 4.0:
			continue
		if historic:
			score += 0.5
		if score > best_relief:
			best_relief = hi - lo
			best = block
	if best.is_empty():
		print("[GroundPlaneCapture] no green block found")
		get_tree().quit(1)
		return
	var pad_rect: Rect2 = best.get("bounds", best.get("rect", Rect2())) as Rect2
	var pad_center := pad_rect.get_center()
	print("[GroundPlaneCapture] seed=%d block=%s relief=%.2fm center=(%.1f, %.1f) size=%.1fx%.1f" % [
		_seed, str(best.get("id", "")), best_relief, pad_center.x, pad_center.y,
		pad_rect.size.x, pad_rect.size.y])

	# Build the chunk the pad lives in plus its neighbours, terrain included.
	var holder := Node3D.new()
	add_child(holder)
	var coord := WorldSeed.chunk_coord(pad_center.x, pad_center.y)
	for dx in [-1, 0, 1, 2]:
		for dz in [-1, 0, 1, 2]:
			var c := coord + Vector2i(dx, dz)
			var tm := TerrainChunkBuilder.build_manifest(world_plan, c)
			TerrainChunkBuilder.materialize(holder, tm)
			ChunkBuilder.build(holder, plan, c, null, {}, false, true, world_plan)

	var ground := world_plan.surface_height_at(pad_center)
	var edge_a := Vector2(pad_rect.position.x, pad_center.y)
	var edge_b := Vector2(pad_rect.end.x, pad_center.y)
	var out_dir := Vector2(0.0, -1.0)
	var views := [
		{"name": "pad_edge", "pos": Vector3(edge_a.x + out_dir.x * 11.0,
				world_plan.surface_height_at(edge_a + out_dir * 11.0) + 1.70,
				edge_a.y + out_dir.y * 11.0),
			"look": Vector3(edge_b.x, world_plan.surface_height_at(edge_b) + 0.35, edge_b.y)},
		{"name": "pad_low", "pos": Vector3(edge_a.x + out_dir.x * 2.4,
				world_plan.surface_height_at(edge_a + out_dir * 2.4) + 0.60,
				edge_a.y + out_dir.y * 2.4),
			"look": Vector3(edge_b.x, world_plan.surface_height_at(edge_b) + 0.20, edge_b.y)},
		{"name": "pad_top", "pos": Vector3(pad_center.x - pad_rect.size.x * 0.55,
				ground + 24.0, pad_center.y - pad_rect.size.y * 0.75),
			"look": Vector3(pad_center.x, ground, pad_center.y)},
	]
	for view: Dictionary in views:
		camera.position = view["pos"] as Vector3
		camera.look_at(view["look"] as Vector3)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, view["name"]]
		img.save_png(path)
		_shots += 1
		print("[GroundPlaneCapture] saved %s" % ProjectSettings.globalize_path(path))
	print("[GroundPlaneCapture] all captures done (%d)" % _shots)
	get_tree().quit(0)
