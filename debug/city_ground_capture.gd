extends Node
## City GROUND surface capture: streets, pavements and bare ground.
##
##   godot --path . -- --citygroundcapture            (windowed: real rendering)
##
## Builds one dense city chunk through the real ChunkBuilder path and renders
## three views so the ground textures can actually be judged:
##   ground_top.png     - overhead: street ribbons, pavements, block interiors
##   ground_street.png  - eye level along the street (setts + slabs + facades)
##   ground_close.png   - close 45-degree look at the paving (texel detail)
##
## Lighting is deliberately flat/neutral daylight: this is a TEXTURE
## verification shot, not an atmosphere shot (the horror lighting pass is
## verified separately by --buildingrepairtest).

const OUT_DIR := "res://captures/city-ground"

var _shots := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[GroundCapture] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	_run()


## Midpoint of the first street edge inside `area`, so ground shots are framed
## on actual paving rather than wherever the camera happened to point.
func _street_point(plan: CityPlan, area: Rect2) -> Vector3:
	var edges := plan.city_road_segments_in(area)
	for edge: Dictionary in edges:
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var mid: Vector2 = poly[poly.size() / 2]
		return Vector3(mid.x, 0.0, mid.y)
	return Vector3(area.get_center().x, 0.0, area.get_center().y)


func _run() -> void:
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
	add_child(camera)
	camera.current = true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	var holder := Node3D.new()
	add_child(holder)
	# Build a 2x2 city area WITH its terrain: the visible ground of the city
	# core is terrain (the flat city ground box only exists for chunks fully
	# inside the basin), so a capture without terrain proves nothing about it.
	var coords: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	for coord: Vector2i in coords:
		var tm := TerrainChunkBuilder.build_manifest(world_plan, coord)
		TerrainChunkBuilder.materialize(holder, tm)
		ChunkBuilder.build(holder, plan, coord, null, {}, false, true, world_plan)
	# No collision needed for a capture, and skipping it keeps this fast.
	var centre := Vector3(64.0, 0.0, 64.0)
	# Aim the close-up at a REAL street point: the previous framing looked into
	# an occluded dark corner, so it "proved" the paving had no texture when the
	# camera simply was not looking at any.
	var street := _street_point(plan, Rect2(centre.x - 64.0, centre.z - 64.0, 128.0, 128.0))

	var views := [
		{"name": "ground_top", "pos": centre + Vector3(-42.0, 62.0, 44.0),
			"look": centre + Vector3(0.0, 0.0, -6.0)},
		{"name": "ground_street", "pos": street + Vector3(-26.0, 1.75, 1.5),
			"look": street + Vector3(26.0, 1.0, -1.5)},
		{"name": "ground_close", "pos": street + Vector3(-3.2, 2.35, -3.2),
			"look": street + Vector3(0.0, 0.0, 0.0)},
	]
	for view: Dictionary in views:
		camera.position = view["pos"]
		camera.look_at(view["look"])
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [OUT_DIR, view["name"]])
		_shots += 1
		print("[GroundCapture] saved %s.png" % view["name"])

	print("[GroundCapture] all captures done (%d)" % _shots)
	get_tree().quit(0)
