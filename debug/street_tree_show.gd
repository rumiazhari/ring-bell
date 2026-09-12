extends Node
## Street-tree tier show — what the CITY plants, side by side with the old
## impostor and the park-tier tree, so the detail tier can be judged by eye.
##
##   godot --path . -- --streetshow
##
## Columns are detail tiers, left to right:
##   x=-12 IMPOSTOR (16 parts, no canopy fill - what the city used to plant)
##   x=+0  STREET   (crown filled, ~1/3 of a park tree's cost - what it plants now)
##   x=+12 CITY     (the park tree, for reference)
##
## No city plan and no terrain: the city generator costs a minute a run and this
## is purely a geometry question. Windowed only - headless cannot capture 3D.
##
## Row shots build one species at a time: with all rows in the scene at once, the
## rows nearer the lens sit inside the frame and cover the row being shot.

const OUT_DIR := "res://captures/city-green"
const SPECIES: Array[StringName] = [&"oak", &"pine", &"spruce"]
const TIERS: Array[int] = [TreeBuilder.Detail.IMPOSTOR, TreeBuilder.Detail.STREET,
	TreeBuilder.Detail.CITY]
const TIER_NAMES: Array[String] = ["IMPOSTOR", "STREET", "CITY"]
const COL_SPACING := 12.0
## Godot's camera looks down +z with +y up, so screen-right is -x: the tiers are
## laid out right-to-left in world space to read left-to-right on screen.
func _tier_x(c: int) -> float:
	return (1.0 - float(c)) * COL_SPACING
const ROW_SPACING := 14.0

var _stage: Node3D
var _vp: SubViewport
var _camera: Camera3D
var _tier_parts := [0, 0, 0]


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[StreetShow] headless renderer cannot capture 3D - run windowed")
		get_tree().quit(0)
		return
	_run()


## Three trees of one species - one per tier - plus their captions. Returns the
## node holding them so it can be freed after the shot.
func _tier_row(species: StringName, row_seed: int) -> Node3D:
	var holder := Node3D.new()
	_stage.add_child(holder)
	var b := MeshBatcher.new()
	for c in TIERS.size():
		var info := TreeBuilder.build(b, Vector3(_tier_x(c), 0.0, 0.0),
			species, {"seed": row_seed + c * 977, "yaw": 0.6 * float(c + 1),
				"scale": 1.0, "detail": TIERS[c]})
		_tier_parts[c] = maxi(int(_tier_parts[c]), int(info["parts"]))
		print("[StreetShow] %s %s h=%.1fm parts=%d verts=%d" % [
			TIER_NAMES[c], species, float(info["height"]),
			int(info["parts"]), int(info["verts"])])
	var mi := MeshInstance3D.new()
	mi.mesh = b._mesh_from(b._build_layers())
	holder.add_child(mi)
	for c in TIERS.size():
		var lab := Label3D.new()
		lab.text = "%s (%d parts)" % [TIER_NAMES[c], int(_tier_parts[c])]
		lab.position = Vector3(_tier_x(c), 0.9, 3.0)
		lab.font_size = 120
		lab.pixel_size = 0.03
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.modulate = Color(0.06, 0.07, 0.09)
		holder.add_child(lab)
	return holder


func _run() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(1600, 900)
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_stage = Node3D.new()
	_vp.add_child(_stage)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -18, 0)
	sun.light_energy = 1.05
	sun.light_color = Color(1.0, 0.97, 0.92)
	_stage.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("9fb6c6")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.93, 0.95, 0.99)
	env.environment.ambient_light_energy = 0.60
	_stage.add_child(env)
	_camera = Camera3D.new()
	_camera.far = 3000.0
	_camera.fov = 90.0
	_stage.add_child(_camera)
	_camera.make_current()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Flat ground, so the trees read against something and the trunk bases show.
	var gb := MeshBatcher.new()
	for gx in 120:
		for gz in 120:
			gb.add_visual_box(Vector3(-60.0 + float(gx) * 2.0, -0.1, -60.0 + float(gz) * 2.0),
				Vector3(2.0, 0.2, 2.0), Color("7c8471"))
	var gmi := MeshInstance3D.new()
	gmi.mesh = gb._mesh_from(gb._build_layers())
	_stage.add_child(gmi)

	# --- 1. One species per shot, three tiers across the frame.
	for r in SPECIES.size():
		var holder := _tier_row(SPECIES[r], 4100 + r * 131)
		await _shot(Vector3(0.0, 3.6, -15.0), Vector3(0.0, 9.0, 0.0),
			"street_row_%s" % SPECIES[r])
		holder.queue_free()
		await get_tree().process_frame

	# --- 2. Standing under a STREET oak, looking up: does the crown close to sky?
	var crown := _tier_row(&"oak", 4100)
	await _shot(Vector3(0.0, 1.8, 5.5), Vector3(0.0, 13.0, 0.0), "street_crown_up")
	crown.queue_free()
	await get_tree().process_frame

	# --- 3. Quarter view of every species at once, near field.
	var all := Node3D.new()
	_stage.add_child(all)
	var b := MeshBatcher.new()
	for r in SPECIES.size():
		for c in TIERS.size():
			TreeBuilder.build(b, Vector3(_tier_x(c), 0.0,
				float(r) * ROW_SPACING), SPECIES[r], {
					"seed": 4100 + c * 977 + r * 131, "yaw": 0.6 * float(c + 1),
					"scale": 1.0, "detail": TIERS[c]})
	var mi := MeshInstance3D.new()
	mi.mesh = b._mesh_from(b._build_layers())
	all.add_child(mi)
	await _shot(Vector3(-30.0, 14.0, -22.0), Vector3(1.0, 8.0, 12.0), "street_tiers")
	print("[StreetShow] done")
	get_tree().quit(0)


func _shot(pos: Vector3, look: Vector3, name: String) -> void:
	_camera.position = pos
	_camera.look_at(look)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	_vp.get_texture().get_image().save_png("%s/%s.png" % [OUT_DIR, name])
	print("[StreetShow] saved %s.png" % name)
