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
	sun.rotation_degrees = Vector3(-35, 150, 0)
	sun.light_energy = 0.8
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
	camera.fov = 35.0
	get_node("/root/DebugOverlay").hide()
	var cloths: Array[SkirtCloth] = []
	for attachment in actor._skeleton.get_children():
		for child in attachment.get_children():
			if child is SkirtCloth:
				cloths.append(child)
	check("five garment simulations", cloths.size() == 5)
	check("authored commoner metadata", actor._model_root.get_meta("authored_commoner", false))
	var authored := true
	var face_found := false
	for attachment in actor._skeleton.get_children():
		for child in attachment.get_children():
			if child is MeshInstance3D:
				authored = authored and child.mesh is ArrayMesh
				face_found = face_found or child.name == "SculptedFace"
	check("all player surfaces authored ArrayMesh", authored)
	check("sculpted face attached to animated skeleton", face_found)
	check("player has 14 articulated bones", actor._skeleton.get_bone_count() == 14)
	for side in ["l", "r"]:
		var calf := actor._skeleton.find_bone(side + "_calf")
		var elbow := actor._skeleton.find_bone(side + "_forearm")
		check(side + " knee rest length", is_equal_approx(actor._skeleton.get_bone_rest(calf).origin.length(), 0.42))
		check(side + " elbow rest length", is_equal_approx(actor._skeleton.get_bone_rest(elbow).origin.length(), 0.27))
	var dir := "res://captures/player-commoner"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for phase in ["Idle", "Walk", "Run", "Sprint", "CrouchIdle", "Slide", "ClimbUp"]:
		var hips := actor._skeleton.find_bone("hips")
		actor._skeleton.set_bone_pose_position(hips, actor._skeleton.get_bone_rest(hips).origin)
		actor.set_physics_process(false)
		actor._locomotion.set_process(false)
		actor._locomotion.set_physics_process(false)
		actor._locomotion.anim_tree.active = false
		actor._locomotion.anim_player.play("locomotion/" + phase)
		if phase in ["Slide", "ClimbUp"]:
			actor._locomotion.anim_player.seek(0.35, true)
			actor._locomotion.anim_player.pause()
		var measured_knee := 0.0
		var measured_elbow := 0.0
		for tick in 90:
			if phase in ["Walk", "Run", "Sprint"]:
				actor.position.z += 0.035
			await get_tree().physics_frame
			if phase != "ClimbUp":
				actor._locomotion._ground_articulated_pose()
			for side in ["l", "r"]:
				var sk := actor._skeleton
				measured_knee = maxf(measured_knee, absf(sk.get_bone_pose_rotation(sk.find_bone(side + "_calf")).get_euler().x))
				measured_elbow = maxf(measured_elbow, absf(sk.get_bone_pose_rotation(sk.find_bone(side + "_forearm")).get_euler().x))
		actor._locomotion.anim_player.pause()
		await get_tree().physics_frame
		await get_tree().physics_frame
		var finite := true
		var above_floor := true
		var pinned := true
		for cloth in cloths:
			for i in cloth._pts.size():
				above_floor = above_floor and (cloth.global_transform * cloth._pts[i]).y >= -0.025
				finite = finite and cloth._pts[i].is_finite() and cloth._pts[i].length() < 2.0
				if cloth._pinned(i):
					pinned = pinned and cloth._pts[i].distance_to(cloth.pin_position(i)) < 0.015
		check(phase + " finite bounded cloth", finite)
		if phase in ["Walk", "Run", "Sprint"]:
			check(phase + " elbows flex during cycle", measured_elbow > 0.1)
			check(phase + " knees flex during cycle", measured_knee > 0.1)
		check(phase + " pins fixed", pinned)
		check(phase + " world floor clearance", above_floor)
		if DisplayServer.get_name() != "headless":
			for view in [Vector3(2.0, 1.4, 3.0), Vector3(-2.4, 1.3, -2.4)]:
				camera.position = actor.position + actor._visual_root.basis * view
				camera.look_at(actor.position + Vector3(0, 0.9, 0))
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(dir + "/" + phase + ("-front.png" if view.z > 0 else "-back.png"))
	# Verify actual gameplay update also drives the joints, not just preview clips.
	actor._locomotion.update({"speed": 4.2, "is_airborne": false, "stamina": 100.0}, 1.0 / 60.0)
	for side in ["l", "r"]:
		var sk := actor._skeleton
		var elbow := sk.find_bone(side + "_forearm")
		var ankle := sk.find_bone(side + "_shin")
		check("live " + side + " elbow bends", absf(sk.get_bone_pose_rotation(elbow).get_euler().x) > 0.1)
		check("live " + side + " ankle remains attached", sk.get_bone_pose_position(ankle).is_equal_approx(sk.get_bone_rest(ankle).origin))
	actor._locomotion.anim_tree.active = false
	if DisplayServer.get_name() != "headless":
		actor._locomotion.anim_player.play("locomotion/Idle")
		await get_tree().process_frame
		camera.position = actor.position + actor._visual_root.basis * Vector3(0.10, 1.69, 0.88)
		camera.look_at(actor.position + Vector3(0, 1.68, 0))
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir + "/Portrait.png")
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
	print("[Clothing] five garments physics mean ms=%.3f particles=%d" % [((Time.get_ticks_usec() - start) / 30000.0), cloths.reduce(func(total, cloth): return total + cloth._pts.size(), 0)])
	for cloth in cloths:
		cloth.set_simulating(false)
		var before := cloth._pts.duplicate()
		await get_tree().physics_frame
		check("freeze " + cloth.name, before == cloth._pts)
	print("ClothingTest finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
