class_name AnimCapture
extends Node
## Rendered visual capture of survivor + zombie animation for debugging.
## Usage: godot --path . -- --animcapture
## Spawns actors on flat ground, drives walk/run/sprint/idle, saves PNG frames
## per phase to .hermes/autopilot/reports/anim-capture-<seed>-<ts>/
## Non-destructive: does not touch test logic; additive debug tool only.

var _dir := ""
var _step := 0

func _ready() -> void:
	# Headless cannot render; bail politely.
	if DisplayServer.get_name() == "headless":
		print("[AnimCapture] headless, no capture possible")
		get_tree().quit(0)
		return
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[AnimCapture] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()

func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	# Flat lit stage: floor + sun + camera.
	var stage := Node3D.new()
	stage.name = "Stage"
	add_child(stage)
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(40, 40)
	floor_mi.mesh = floor_mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.55, 0.55, 0.58)
	floor_mi.mesh.surface_set_material(0, floor_mat)
	stage.add_child(floor_mi)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.2
	stage.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.25, 0.28, 0.35)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.7
	var cam := Camera3D.new()
	cam.position = Vector3(3.2, 1.7, 3.2)
	cam.fov = 50.0
	stage.add_child(cam)
	cam.look_at_from_position(cam.position, Vector3(0, 0.9, 0), Vector3.UP)
	cam.current = true

	# Actor under test: fresh survivor, not the game player (no registry clash).
	var survivor := Survivor.new()
	survivor.configure({"is_player": true})
	stage.add_child(survivor)
	survivor.global_position = Vector3(0, 0.6, 0)
	# Settle several physics ticks before driving: same-frame create+teleport
	# leaves stale server state that launches bodies on tick 1.
	for i in 10:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame

	_dir = ProjectSettings.globalize_path(
		"res://.hermes/autopilot/reports/anim-capture-%d-%d/"
		% [WorldSeed.get_world_seed(), int(Time.get_unix_time_from_system())])
	DirAccess.make_dir_recursive_absolute(_dir)

	# Phases: idle, walk, run, sprint. Each: settle then capture N frames.
	var phases := [
		{"name": "idle", "speed": 0.0, "sprint": false, "shots": 4, "gap": 0.25},
		{"name": "walk", "speed": 1.6, "sprint": false, "shots": 6, "gap": 0.12},
		{"name": "run", "speed": 4.2, "sprint": false, "shots": 6, "gap": 0.10},
		{"name": "sprint", "speed": 6.2, "sprint": true, "shots": 6, "gap": 0.10},
	]
	for ph in phases:
		var dir := Vector3(0, 0, -1)
		survivor.request_move(dir, ph["sprint"])
		var frames := 0
		var t := 0.0
		var shot := 0
		while shot < ph["shots"]:
			await get_tree().process_frame
			t += get_process_delta_time()
			if t >= ph["gap"]:
				t = 0.0
				_step += 1
				cam.global_position = survivor.global_position + Vector3(3.2, 1.7, 3.2)
				cam.look_at(survivor.global_position + Vector3(0, 0.9, 0), Vector3.UP)
				_snap("%02d_%s_%d.png" % [_step, ph["name"], shot])
				shot += 1
		survivor.stop_moving()
		await _wait(0.4)

	# Turn table: 8 angles around a walking survivor for stride view.
	survivor.request_move(Vector3(0, 0, -1), false)
	for i in 8:
		var ang := TAU * i / 8.0
		var pivot := Node3D.new()
		stage.add_child(pivot)
		var c := Camera3D.new()
		c.position = Vector3(sin(ang) * 3.4, 1.5, cos(ang) * 3.4)
		pivot.add_child(c)
		c.look_at_from_position(c.global_position, survivor.global_position + Vector3(0, 0.9, 0), Vector3.UP)
		c.current = true
		await get_tree().process_frame
		await get_tree().process_frame
		_step += 1
		_snap("%02d_turn_%d.png" % [_step, i])
		pivot.queue_free()
		cam.current = true
	survivor.stop_moving()

	# Zombie shamble check (zombies steer themselves via wander AI).
	var zombie := Zombie.new()
	stage.add_child(zombie)
	zombie.global_position = Vector3(4, 0.6, 0)
	for i in 10:
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 5:
		await _wait(0.6)
		_step += 1
		_snap("%02d_zombie_%d.png" % [_step, i])
	print("[AnimCapture] finished dir=%s" % _dir)
	get_tree().quit(0)

func _snap(file_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img != null:
		var path := _dir.path_join(file_name)
		var err := img.save_png(path)
		print("[AnimCapture] %s err=%d" % [file_name, err])

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
