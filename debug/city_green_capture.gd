extends Node
## City GREENERY capture: are the city's blank spaces planted, and are the
## city trees the real procedural species (not cube proxies)?
##
##   godot --path . -- --citygreencapture [radius]     (windowed: real rendering)
##
## Builds a real city area through ChunkBuilder (same path the player streams)
## plus its terrain, then renders:
##   green_overview.png   - overhead: where blank ground sits in the blocks
##   green_street.png     - eye level along a street: street trees + gardens
##   green_courtyard.png  - inside a block: courtyard/void planting
##   green_plaza.png      - the public square
##
## Flat neutral daylight: this is a placement/species check, not a mood shot.

const OUT_DIR := "res://captures/city-green"

var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[GreenCapture] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	_run()


func _street_point(plan: CityPlan, area: Rect2) -> Vector3:
	var edges := plan.city_road_segments_in(area)
	for edge: Dictionary in edges:
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var mid: Vector2 = poly[poly.size() / 2]
		return Vector3(mid.x, 0.0, mid.y)
	return Vector3(area.get_center().x, 0.0, area.get_center().y)


## Centre of the largest plaza block inside `area`, so the square shot is
## framed on a real square rather than a guess.
func _plaza_center(plan: CityPlan, area: Rect2) -> Vector3:
	var best := Vector2.ZERO
	var best_area := 0.0
	for cell in plan.cells_in_rect(area):
		var block := plan.cell_block(cell)
		if block.is_empty() or StringName(block.get("kind", &"")) != &"plaza":
			continue
		var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 3:
			continue
		var a := 0.0
		for i in poly.size():
			var p0: Vector2 = poly[i]
			var p1: Vector2 = poly[(i + 1) % poly.size()]
			a += p0.x * p1.y - p1.x * p0.y
		a = absf(a * 0.5)
		if a > best_area:
			best_area = a
			best = block.get("center", Vector2.ZERO) as Vector2
	return Vector3(best.x, 0.0, best.y)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var radius := 1
	for i in args.size():
		if args[i] == "--citygreencapture" and i + 1 < args.size():
			radius = maxi(0, mini(3, int(args[i + 1])))
	if DisplayServer.get_name() == "headless":
		radius = 0

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -40, 0)
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
	camera.far = 4000.0
	add_child(camera)
	camera.current = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	var holder := Node3D.new()
	add_child(holder)

	var coords: Array[Vector2i] = []
	for dx in range(0, radius + 1):
		for dz in range(0, radius + 1):
			coords.append(Vector2i(dx, dz))
	for coord: Vector2i in coords:
		var tm := TerrainChunkBuilder.build_manifest(world_plan, coord)
		TerrainChunkBuilder.materialize(holder, tm)
		ChunkBuilder.build(holder, plan, coord, null, {}, false, true, world_plan)

	var span := 64.0 * float(radius + 1)
	var centre := Vector3(span * 0.5, 0.0, span * 0.5)
	var area := Rect2(0.0, 0.0, span, span)
	var street := _street_point(plan, area)
	var plaza := _plaza_center(plan, area)
	if plaza == Vector3.ZERO:
		plaza = centre

	var views := [
		{"name": "green_overview", "pos": centre + Vector3(-span * 0.55, span * 0.72, span * 0.62),
			"look": centre + Vector3(0.0, 0.0, -span * 0.06)},
		{"name": "green_street", "pos": street + Vector3(-30.0, 1.75, 2.0),
			"look": street + Vector3(30.0, 1.6, -2.0)},
		{"name": "green_courtyard", "pos": centre + Vector3(-16.0, 12.0, -16.0),
			"look": centre + Vector3(0.0, 0.0, 0.0)},
		{"name": "green_plaza", "pos": plaza + Vector3(-26.0, 3.2, 24.0),
			"look": plaza + Vector3(2.0, 1.0, -2.0)},
	]
	for view: Dictionary in views:
		camera.position = view["pos"]
		camera.look_at(view["look"])
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [OUT_DIR, view["name"]])
		_shots += 1
		print("[GreenCapture] saved %s.png" % view["name"])

	print("[GreenCapture] all captures done (%d)" % _shots)
	get_tree().quit(0)
