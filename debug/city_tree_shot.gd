extends Node
## In-city planting proof: real city chunks, real planting passes, so blank city
## ground can be judged filled (or not) inside the actual city.
##
##   godot --path . -- --citytreeshot [radius]      (windowed: real rendering)
##
## Runs the generators that place vegetation - _roads for street context,
## _plant_garden_trees and _plant_city_greens - and deliberately skips the
## building pass: a full chunk fill does not finish inside several minutes, and
## this is a planting question. Every tree here is a tree the city really plants.
##
## Views land in captures/city-green/: city_overview, city_street, city_inside.

const OUT_DIR := "res://captures/city-green"


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[CityTreeShot] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	_run()


func _centre_of(plan: CityPlan, area: Rect2, kind: StringName) -> Vector3:
	var best := Vector2.ZERO
	var best_area := 0.0
	for cell in plan.cells_in_rect(area):
		var block := plan.cell_block(cell)
		if block.is_empty() or StringName(block.get("kind", &"")) != kind:
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


func _road_point(plan: CityPlan, area: Rect2) -> Vector3:
	for edge: Dictionary in plan.city_road_segments_in(area):
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() >= 2:
			var mid: Vector2 = poly[poly.size() / 2]
			return Vector3(mid.x, 0.0, mid.y)
	return Vector3(area.get_center().x, 0.0, area.get_center().y)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var radius := 0
	for i in args.size():
		if args[i] == "--citytreeshot" and i + 1 < args.size():
			radius = maxi(0, mini(2, int(args[i + 1])))

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -34, 0)
	sun.light_energy = 1.1
	sun.light_color = Color(1.0, 0.97, 0.92)
	add_child(sun)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("7d8b93")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.92, 0.94, 0.98)
	env.environment.ambient_light_energy = 0.60
	add_child(env)

	var camera := Camera3D.new()
	camera.far = 4000.0
	camera.fov = 70.0
	add_child(camera)
	camera.current = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var t0 := Time.get_ticks_msec()
	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	print("[CityTreeShot] plan %d ms" % (Time.get_ticks_msec() - t0))

	var holder := Node3D.new()
	add_child(holder)
	var with_roads := args.has("--withroads")
	# A flat ground plate: without it the trees float over the void, and the
	# pavement/sidewalk geometry that would hide the seams is exactly the pass
	# that is too slow to run here (_roads does not finish in minutes).
	var gb := MeshBatcher.new()
	var span_all := 64.0 * float(radius + 1)
	for gx in int(span_all / 2.0) + 2:
		for gz in int(span_all / 2.0) + 2:
			gb.add_visual_box(Vector3(float(gx) * 2.0 - 1.0, -0.1, float(gz) * 2.0 - 1.0),
				Vector3(2.0, 0.2, 2.0), Color("8b8d84"))
	var gmi := MeshInstance3D.new()
	gmi.mesh = gb._mesh_from(gb._build_layers())
	holder.add_child(gmi)

	for dx in range(0, radius + 1):
		for dz in range(0, radius + 1):
			var coord := Vector2i(dx, dz)
			var rect := WorldSeed.chunk_rect(coord)
			var b := MeshBatcher.new()
			var t := Time.get_ticks_msec()
			var boxes_before := int(b._box_count)
			ChunkBuilder._plant_city_greens(b, plan, rect, coord, world_plan)
			var t_green := Time.get_ticks_msec()
			var green_boxes := int(b._box_count) - boxes_before
			print("[CityTreeShot] %s city_greens=%dms boxes=%d" % [str(coord), t_green - t, green_boxes])
			ChunkBuilder._plant_garden_trees(b, plan, rect, world_plan)
			var t_garden := Time.get_ticks_msec()
			print("[CityTreeShot] %s garden_trees=%dms" % [str(coord), t_garden - t_green])
			if with_roads:
				ChunkBuilder._roads(b, plan, rect, world_plan)
				print("[CityTreeShot] %s roads=%dms" % [str(coord), Time.get_ticks_msec() - t_garden])
			var mi := MeshInstance3D.new()
			mi.mesh = b._mesh_from(b._build_layers())
			holder.add_child(mi)

	var span := 64.0 * float(radius + 1)
	var area := Rect2(0.0, 0.0, span, span)
	var centre := Vector3(span * 0.5, 0.0, span * 0.5)
	var street := _road_point(plan, area)
	var plaza := _centre_of(plan, area, &"plaza")
	if plaza == Vector3.ZERO:
		plaza = centre
	var inner := _centre_of(plan, area, &"block")
	if inner == Vector3.ZERO:
		inner = centre

	var views := [
		{"name": "city_overview", "pos": centre + Vector3(-span * 0.60, span * 0.70, span * 0.64),
			"look": centre + Vector3(0.0, 0.0, -span * 0.05)},
		{"name": "city_street", "pos": street + Vector3(-26.0, 1.7, 3.0),
			"look": street + Vector3(26.0, 1.4, -3.0)},
		{"name": "city_inside", "pos": inner + Vector3(-14.0, 9.0, 14.0),
			"look": inner + Vector3(0.0, 0.5, 0.0)},
		{"name": "city_plaza", "pos": plaza + Vector3(-22.0, 3.0, 20.0),
			"look": plaza + Vector3(2.0, 1.0, -2.0)},
	]
	for view: Dictionary in views:
		camera.position = view["pos"]
		camera.look_at(view["look"])
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, view["name"]])
		print("[CityTreeShot] saved %s.png" % view["name"])

	print("[CityTreeShot] done")
	get_tree().quit(0)
