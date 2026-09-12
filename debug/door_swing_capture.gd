extends Node3D
## Rendered capture of ONE door swinging, so the pivot can be SEEN:
## three frames (closed / mid-swing / open) from a 3/4 view, plus a top-down
## frame of the open leaf. Wall aperture is centred on the world origin and the
## leaf is hinged on its +X jamb, so a correct door keeps its hinge at the same
## wall point in every frame.

const OUT_DIR := "res://captures"

var _door: Door
var _phase := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("6f93c0")
	sky_mat.sky_horizon_color = Color("cfd9e2")
	sky_mat.ground_bottom_color = Color("4a4f45")
	sky_mat.ground_horizon_color = Color("9aa39b")
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 1.1
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	add_child(sun)

	# --- facade wall with a REAL 1.0 m aperture centred on the origin --------
	var wall_col := Color("c9c2b4")
	var depth := 0.24
	var height := 2.75
	var half_gap := 0.5
	_wall_piece(Vector2(-4.0, -half_gap), wall_col, depth, height)   # left of door
	_wall_piece(Vector2(half_gap, 4.0), wall_col, depth, height)     # right of door
	# lintel above the 2.25 m opening
	var lintel := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(1.0, height - 2.25, depth)
	lintel.mesh = lb
	var lm := StandardMaterial3D.new()
	lm.albedo_color = wall_col
	lintel.material_override = lm
	lintel.position = Vector3(0.0, 2.25 + (height - 2.25) * 0.5, 0.0)
	add_child(lintel)

	var floor_mesh := MeshInstance3D.new()
	var fb := BoxMesh.new()
	fb.size = Vector3(14.0, 0.2, 14.0)
	floor_mesh.mesh = fb
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color("8d8577")
	floor_mesh.material_override = fm
	floor_mesh.position = Vector3(0.0, -0.1, 0.0)
	add_child(floor_mesh)

	# --- the door -------------------------------------------------------------
	_door = Door.new()
	_door.name = "CaptureDoor"
	_door.setup({
		"id": "capture_door", "building_id": "capture",
		"position": Vector3.ZERO, "yaw": 0.0, "edge": 0,
		"width": 1.0, "height": 2.25, "hinge": "left",
		"locked": false, "open_angle": 95.0,
	})
	add_child(_door)

	# --- cameras --------------------------------------------------------------
	var cam := Camera3D.new()
	cam.name = "View"
	cam.position = Vector3(3.6, 2.9, 4.1)
	cam.look_at_from_position(Vector3(3.6, 2.9, 4.1), Vector3(0.0, 1.0, 0.0))
	cam.current = true
	add_child(cam)

	await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	_capture("door_swing_1_closed")

	_door.open()
	await get_tree().create_timer(0.42).timeout
	_capture("door_swing_2_mid")
	await get_tree().create_timer(1.6).timeout
	_capture("door_swing_3_open")

	# Top-down: hinge point must not wander.
	cam.look_at_from_position(Vector3(1.2, 7.0, 0.4), Vector3(0.05, 0.0, 0.05))
	await get_tree().create_timer(0.5).timeout
	_capture("door_swing_4_topdown_open")

	print("[DoorSwingCapture] yaw_final=%.1f deg state=%d" % [
		rad_to_deg(wrapf(_door._pivot_ref().rotation.y, -PI, PI)), _door.state])
	get_tree().quit()


func _wall_piece(x_span: Vector2, col: Color, depth: float, height: float) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(absf(x_span.y - x_span.x), height, depth)
	mi.mesh = b
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	mi.material_override = m
	mi.position = Vector3((x_span.x + x_span.y) * 0.5, height * 0.5, 0.0)
	add_child(mi)


func _capture(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, tag]
	var err := img.save_png(path)
	print("[DoorSwingCapture] %s -> %s (err=%d)" % [tag, ProjectSettings.globalize_path(path), err])
