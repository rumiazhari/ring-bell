extends Node3D
## Isolated real-player animation and cloth regression, with rendered evidence.
var failures := 0

func check(label: String, valid: bool) -> void:
	print("[Clothing] %s %s" % ["PASS" if valid else "FAIL", label])
	if not valid:
		failures += 1

func _ready() -> void:
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 0.2, 100)
	shape.shape = box
	shape.position.y = -0.1
	floor_body.add_child(shape)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	floor_mesh.mesh = plane
	add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("404959")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.5
	add_child(environment)
	var actor := Survivor.new()
	actor.configure({"is_player": true})
	add_child(actor)
	await get_tree().process_frame
	await get_tree().physics_frame
	var camera := Camera3D.new()
	add_child(camera)
	camera.current = true
	var cloths: Array[SkirtCloth] = []
	for attachment in actor._skeleton.get_children():
		for child in attachment.get_children():
			if child is SkirtCloth:
				cloths.append(child)
	check("four garment simulations", cloths.size() == 4)
	var dir := "res://captures/player-clothing"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for phase in ["Idle", "Walk", "Run", "Sprint", "CrouchIdle", "Slide", "ClimbUp"]:
		actor.set_physics_process(false)
		actor._locomotion.set_process(false)
		actor._locomotion.set_physics_process(false)
		actor._locomotion.anim_tree.active = false
		actor._locomotion.anim_player.play("locomotion/" + phase)
		if phase in ["Slide", "ClimbUp"]:
			actor._locomotion.anim_player.seek(0.35, true)
			actor._locomotion.anim_player.pause()
		for tick in 90:
			if phase in ["Walk", "Run", "Sprint"]:
				actor.position.z += 0.035
			await get_tree().physics_frame
		var finite := true
		var above_floor := true
		var pinned := true
		for cloth in cloths:
			for i in cloth._pts.size():
				above_floor = above_floor and (cloth.global_transform * cloth._pts[i]).y >= -0.025
				finite = finite and cloth._pts[i].is_finite() and cloth._pts[i].length() < 2.0
				if cloth._pinned(i):
					pinned = pinned and cloth._pts[i].is_equal_approx(cloth._rest[i])
		check(phase + " finite bounded cloth", finite)
		check(phase + " pins fixed", pinned)
		check(phase + " world floor clearance", above_floor)
		if DisplayServer.get_name() != "headless":
			for view in [Vector3(2.0, 1.4, 3.0), Vector3(-2.4, 1.3, -2.4)]:
				camera.position = actor.position + view
				camera.look_at(actor.position + Vector3(0, 0.9, 0))
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(dir + "/" + phase + ("-front.png" if view.z > 0 else "-back.png"))
	actor._locomotion.anim_player.play("locomotion/Idle")
	for tick in 30:
		await get_tree().physics_frame
	for cloth in cloths:
		var before_motion := cloth._pts.duplicate()
		actor.position.x += 0.15
		await get_tree().physics_frame
		await get_tree().physics_frame
		check("inertial response " + cloth.name, before_motion != cloth._pts)
	actor.position.x += 10.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	for cloth in cloths:
		var bounded := true
		for point in cloth._pts:
			bounded = bounded and point.is_finite() and point.length() < 2.0
		check("teleport recovery " + cloth.name, bounded)
	var start := Time.get_ticks_usec()
	for repeat in 30:
		for cloth in cloths:
			cloth._physics_process(1.0 / 60.0)
	print("[Clothing] four garments physics mean ms=%.3f particles=324" % ((Time.get_ticks_usec() - start) / 30000.0))
	for cloth in cloths:
		cloth.set_simulating(false)
		var before := cloth._pts.duplicate()
		await get_tree().physics_frame
		check("freeze " + cloth.name, before == cloth._pts)
	print("ClothingTest finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
