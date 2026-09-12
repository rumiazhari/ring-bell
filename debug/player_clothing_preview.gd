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
		check(side + " knee rest length", is_equal_approx(actor._skeleton.get_bone_rest(calf).origin.length(), 0.41))
		check(side + " elbow rest length", is_equal_approx(actor._skeleton.get_bone_rest(elbow).origin.length(), 0.29))
	# Inspect the built neutral model, not just constants used to build it.
	actor.set_physics_process(false)
	actor._locomotion.anim_tree.active = false
	actor._locomotion.anim_player.stop()
	actor._skeleton.reset_bone_poses()
	await get_tree().process_frame
	await get_tree().physics_frame
	var neutral := actor._skeleton
	var hip_y := neutral.get_bone_global_rest(neutral.find_bone("hips")).origin.y
	var shoulder_y := neutral.get_bone_global_rest(neutral.find_bone("l_upper_arm")).origin.y
	var knee_y := neutral.get_bone_global_rest(neutral.find_bone("l_calf")).origin.y
	var ankle_y := neutral.get_bone_global_rest(neutral.find_bone("l_shin")).origin.y
	var head_bounds := mesh_bounds(neutral, "JawAndTemples")
	var hood_bounds := mesh_bounds(neutral, "WrappedHijab")
	var sole_bounds := mesh_bounds(neutral, "BootSole")
	var hand_bounds := mesh_bounds(neutral, "Finger")
	var belt_bounds := mesh_bounds(neutral, "LeatherBelt")
	var palm_bounds := mesh_bounds(neutral, "Hand")
	var stature := hood_bounds.end.y - sole_bounds.position.y
	var head_height := head_bounds.size.y
	check("adult clothed stature 1.68-1.73m", stature > 1.68 and stature < 1.73)
	check("anatomical head 21-24cm", head_height > 0.21 and head_height < 0.24)
	check("adult stature is 7-8 anatomical heads", stature / head_height > 7.0 and stature / head_height < 8.0)
	check("hip height is 51-55 percent of stature", hip_y / stature > 0.51 and hip_y / stature < 0.55)
	check("shoulder height is 81-84 percent of stature", shoulder_y / stature > 0.81 and shoulder_y / stature < 0.84)
	check("knee and ankle anatomical heights", absf(knee_y - 0.49) < 0.001 and absf(ankle_y - 0.08) < 0.001)
	check("neutral soles contact floor", absf(sole_bounds.position.y) < 0.005)
	check("neutral fingertips at upper thigh 0.68-0.72m", hand_bounds.position.y > 0.68 and hand_bounds.position.y < 0.72)
	check("wrist at 0.86m", absf(palm_bounds.end.y - 0.86) < 0.002)
	check("belt at natural waist 1.03-1.09m", belt_bounds.get_center().y > 1.03 and belt_bounds.get_center().y < 1.09)
	print("[Proportions] stature=%.3f head=%.3f hips=%.3f shoulders=%.3f knee=%.3f ankle=%.3f fingertips=%.3f waist=%.3f" % [stature, head_height, hip_y, shoulder_y, knee_y, ankle_y, hand_bounds.position.y, belt_bounds.get_center().y])
	var dir := "res://captures/player-commoner"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if DisplayServer.get_name() != "headless":
		for side in ["l", "r"]:
			neutral.set_bone_pose_rotation(neutral.find_bone(side + "_upper_arm"), Quaternion.from_euler(Vector3(0, 0, deg_to_rad(-8.0 if side == "l" else 8.0))))
		for settle in 6:
			await get_tree().physics_frame
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2.05
		for view_name in ["Neutral-front", "Neutral-side", "Neutral-back"]:
			var view := Vector3(0, 0.85, 4) if view_name == "Neutral-front" else (Vector3(4, 0.85, 0) if view_name == "Neutral-side" else Vector3(0, 0.85, -4))
			camera.position = actor.position + actor._visual_root.basis * view
			camera.look_at(actor.position + Vector3(0, 0.85, 0))
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(dir + "/" + view_name + ".png")
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# Broad animation suite uses NPC fixtures: explicitly check the actual player's reach.
	neutral.reset_bone_poses()
	for side in ["l", "r"]:
		var arm := neutral.find_bone(side + "_upper_arm")
		var shoulder_world := (neutral.global_transform * neutral.get_bone_global_rest(arm)).origin
		var target := shoulder_world + Vector3.UP * 0.71
		var gap: float = actor._locomotion._aim_arm_at(arm, target)
		var nearest := INF
		for attachment in neutral.get_children():
			if not attachment is BoneAttachment3D or attachment.bone_name != side + "_forearm":
				continue
			var frame := neutral.global_transform * neutral.get_bone_global_pose(neutral.find_bone(attachment.bone_name))
			for part in attachment.get_children():
				if part is MeshInstance3D and part.get_meta("authored_part", "") == "Finger":
					var vertices: PackedVector3Array = part.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
					for vertex in vertices:
						nearest = minf(nearest, (frame * part.transform * vertex).distance_to(target))
		check(side + " player reach telemetry matches 71cm arm", gap < 0.002)
		check(side + " actual gloved fingertips reach target", nearest < 0.025)
	neutral.reset_bone_poses()
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
		for settle in 4:
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
		camera.position = actor.position + actor._visual_root.basis * Vector3(0.10, 1.57, 0.88)
		camera.look_at(actor.position + Vector3(0, 1.56, 0))
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir + "/Portrait.png")
	actor._locomotion.anim_player.play("locomotion/Idle")
	for tick in 30:
		await get_tree().physics_frame
	for cloth in cloths:
		var before_motion := cloth._pts.duplicate()
		actor.position.x += 0.15
		for settle in 4:
			await get_tree().physics_frame
		check("inertial response " + cloth.name, before_motion != cloth._pts)
	actor.position.x += 10.0
	for settle in 4:
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


func mesh_bounds(skeleton: Skeleton3D, prefix: String) -> AABB:
	var result := AABB()
	var first := true
	for attachment in skeleton.get_children():
		if not attachment is BoneAttachment3D:
			continue
		var bone_frame := skeleton.get_bone_global_rest(skeleton.find_bone(attachment.bone_name))
		for part in attachment.get_children():
			if part is MeshInstance3D and String(part.get_meta("authored_part", part.name)).begins_with(prefix):
				var vertices: PackedVector3Array = part.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				for vertex in vertices:
					var point: Vector3 = bone_frame * part.transform * vertex
					if first:
						result = AABB(point, Vector3.ZERO)
						first = false
					else:
						result = result.expand(point)
	return result
