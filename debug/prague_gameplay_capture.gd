extends Node
## Real rendered geometry through ChunkBuilder; no synthetic screenshot proxy.
var camera: Camera3D
var output := ""
var failures := 0

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Prague captures require a real renderer")
		get_tree().quit(1)
		return
	run()

func run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	output = "res://.hermes/autopilot/reports/prague-gameplay-pass/render-%d" % WorldSeed.get_world_seed()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("81909e")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("d1d9e0")
	env.environment.ambient_light_energy = 0.7
	add_child(env)
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 78
	add_child(camera)
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	var specs := plan.city_buildings()
	var merged := {}
	var score := INF
	for spec: Dictionary in specs:
		if not spec.has("compound_id") or str(spec.wing_role) != "front" or (spec.rect as Rect2).size.x < 15:
			continue
		var distance := (spec.rect as Rect2).get_center().length_squared()
		if distance < score:
			merged = spec
			score = distance
	if merged.is_empty():
		push_error("No merged building for capture")
		get_tree().quit(1)
		return
	var centre: Vector2 = (merged.rect as Rect2).get_center()
	var owner: Vector2i = merged.owner_chunk
	var ordinary := merged
	score = INF
	for spec: Dictionary in specs:
		if not spec.has("compound_id") or str(spec.wing_role) != "front" or (spec.rect as Rect2).size.x > 12:
			continue
		var distance := (spec.rect as Rect2).get_center().distance_squared_to(centre)
		if distance < score:
			ordinary = spec
			score = distance
	var holder := Node3D.new()
	add_child(holder)
	for x in range(owner.x - 1, owner.x + 2):
		for z in range(owner.y - 1, owner.y + 2):
			var coord := Vector2i(x, z)
			TerrainChunkBuilder.materialize(holder, TerrainChunkBuilder.build_manifest(world, coord))
			ChunkBuilder.build(holder, plan, coord, null, {}, false, true, world)
			await get_tree().process_frame
			print("[PragueCapture] built ", coord)
	var rect: Rect2 = ordinary.rect
	var front := CityPlan._rotate_plan_point(rect.get_center(), Vector2(rect.get_center().x, rect.position.y), ordinary.yaw)
	var tangent := Vector2(cos(float(ordinary.yaw)), sin(float(ordinary.yaw)))
	var inward := Vector2(-tangent.y, tangent.x)
	var street := front - inward * 2.8
	await shot("01_ordinary_street", at(street, world.surface_height_at(street) + 1.7), at(street + tangent * 20, world.surface_height_at(street) + 2.0))
	var lane := {}
	score = INF
	for edge: Dictionary in plan._city_edges:
		if float(edge.width) >= 5.5 or not bool(edge.get("shared_surface", false)):
			continue
		var line: PackedVector2Array = edge.polyline
		for i in range(line.size() - 1):
			var mid := (line[i] + line[i + 1]) * 0.5
			if mid.distance_squared_to(centre) < score:
				score = mid.distance_squared_to(centre)
				lane = {"point": mid, "direction": (line[i + 1] - line[i]).normalized()}
	if not lane.is_empty():
		var pos: Vector2 = lane.point
		await shot("02_narrow_lane", at(pos, world.surface_height_at(pos) + 1.7), at(pos + lane.direction * 15, world.surface_height_at(pos) + 2))
	var court := Vector2.INF
	score = INF
	for plot: Dictionary in plan.city_plots():
		for courtyard: Dictionary in plot.courtyards:
			var local: Rect2 = courtyard.local_rect
			var pos := CityPlan._rotate_plan_point((plot.rect as Rect2).get_center(), (plot.rect as Rect2).position + local.get_center(), plot.yaw)
			if pos.distance_squared_to(centre) < score:
				score = pos.distance_squared_to(centre)
				court = pos
	if court != Vector2.INF:
		await shot("03_courtyard", at(court, world.surface_height_at(court) + 2), at(court + Vector2(8, 2), world.surface_height_at(court) + 4))
	await interior_shot("04_house_interior", ordinary)
	await interior_shot("05_merged_interior", merged)
	var roof_y: float = merged.planned_ground_y + float(merged.floors) * float(merged.floor_h)
	await shot("06_roofscape", at(centre + Vector2(-12, 5), roof_y + 5), at(centre + Vector2(45, 10), roof_y - 2))
	await shot("07_blocks_overview", at(centre + Vector2(-8, 18), roof_y + 76), at(centre, 0))
	print("[PragueCapture] finished with %d failure(s)" % failures)
	get_tree().quit(failures)

func at(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)

func interior_shot(label: String, spec: Dictionary) -> void:
	var fl: Dictionary = InteriorPlan.build_for_building(spec).floors[0]
	var biggest := Rect2()
	for room: Dictionary in fl.rooms:
		if room.kind in [&"stair_hall", &"landing"] or bool(room.service):
			continue
		if (room.rect as Rect2).get_area() > biggest.get_area():
			biggest = room.rect
	var fp: Rect2 = spec.rect
	var pos := CityPlan._rotate_plan_point(fp.get_center(), biggest.position + Vector2(0.7, 0.7), spec.yaw)
	var target := CityPlan._rotate_plan_point(fp.get_center(), biggest.end - Vector2(0.7, 0.7), spec.yaw)
	await shot(label, at(pos, float(spec.planned_ground_y) + 1.65), at(target, float(spec.planned_ground_y) + 1.5))

func shot(label: String, position: Vector3, target: Vector3) -> void:
	camera.position = position
	camera.look_at(target)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var screenshot := get_viewport().get_texture().get_image()
	if screenshot.save_png(output + "/" + label + ".png") != OK:
		failures += 1
	print("[PragueCapture] saved ", label, " camera=", position, " target=", target)
