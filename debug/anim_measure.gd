class_name AnimMeasure
extends Node
## Headless quantitative animation/grounding probe.
## Usage: godot --headless --path . -- --animmeasure
## Spawns survivor (measured fully first) then zombie on a flat static
## floor, and prints world-space measurements: body origin height, lowest
## mesh vertex, bone worlds, thigh swing amplitude.
## Prints [AnimMeasure] PASS/FAIL lines + finished with N failure(s).
##
## NOTE: survivor is measured BEFORE the zombie spawns. Spawning several
## bodies + teleporting them in one frame leaves stale server state that
## detonates on tick 1 (depenetration launch), so spawns stay staggered.

var failures := 0

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[AnimMeasure] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[AnimMeasure] PASS %s" % test_name)
	else:
		failures += 1
		print("[AnimMeasure] FAIL %s (%s)" % [test_name, detail])

func _run() -> void:
	print("[AnimMeasure] start pid=%d" % OS.get_process_id())
	await get_tree().process_frame
	# Static floor, top surface at y=0.
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	add_child(floor_body)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	floor_body.add_child(col)

	var holder := Node3D.new()
	holder.name = "Holder"
	add_child(holder)

	# Factory baseline: pose must equal rest out of the box (reset_bone_poses).
	var fresh := SkeletonFactory.build_survivor_skeleton()
	holder.add_child(fresh)
	fresh.position = Vector3(-6, 0, 0)
	await _physics(5)
	var fhips := fresh.find_bone("hips")
	_check("factory pose starts at rest",
		fresh.get_bone_global_pose(fhips).origin.distance_to(Vector3(0, 0.86, 0)) < 0.01,
		str(fresh.get_bone_global_pose(fhips).origin))
	fresh.queue_free()

	# --- Survivor, alone ---
	var survivor := Survivor.new()
	survivor.configure({"is_player": false, "female": false})
	await _spawn_settled(holder, survivor, Vector3(0, 0.6, 0))
	await _physics(60)
	var sy: float = survivor.global_position.y
	_check("survivor origin rests near floor", absf(sy) < 0.08, "y=%.3f" % sy)
	var smin := _lowest_mesh_y(survivor)
	_check("survivor meshes above floor", smin > -0.06, "min_y=%.3f" % smin)
	_print_bones(survivor, "survivor")
	# --- Walk swing ---
	survivor.request_move(Vector3(0, 0, -1), false)
	await _physics(30)  # settle into stride
	var walk_sw := await _swing_amplitude(survivor, 90)
	print("[AnimMeasure] walk thigh amplitude deg=%.1f" % walk_sw)
	_check("walk thigh swing present", walk_sw > 10.0, "amp=%.1f" % walk_sw)
	var wpos0: Vector3 = survivor.global_position
	await _physics(60)
	var wdist: float = Vector2(survivor.global_position.x - wpos0.x, survivor.global_position.z - wpos0.z).length()
	print("[AnimMeasure] walk 1s travel=%.2f speed~%.2f" % [wdist, wdist])
	# --- Sprint swing ---
	survivor.request_move(Vector3(0, 0, -1), true)
	await _physics(30)
	var run_sw := await _swing_amplitude(survivor, 90)
	print("[AnimMeasure] sprint thigh amplitude deg=%.1f" % run_sw)
	_check("sprint thigh swing present", run_sw > 10.0, "amp=%.1f" % run_sw)
	# Knee-gap guard: shin pose must stay at rest (+tiny lift). The old
	# fore-aft offset dislocated the knee up to 0.6 m = detached-limb look.
	var gap_max := await _max_knee_gap(survivor, 90)
	print("[AnimMeasure] sprint max knee gap=%.3f" % gap_max)
	_check("knee stays attached in sprint", gap_max < 0.08, "gap=%.3f" % gap_max)
	# --- Idle: limbs return near rest ---
	survivor.stop_moving()
	await _physics(60)
	var idle_sw := await _swing_amplitude(survivor, 45)
	print("[AnimMeasure] idle thigh residual deg=%.1f" % idle_sw)
	_check("idle legs near rest", idle_sw < 6.0, "amp=%.1f" % idle_sw)
	print("[AnimMeasure] survivor done at %s" % str(survivor.global_position))

	# --- Zombie, only now ---
	var zombie := Zombie.new()
	await _spawn_settled(holder, zombie, Vector3(10, 0.6, 0))
	await _physics(60)
	var zy: float = zombie.global_position.y
	_check("zombie origin rests near floor", absf(zy) < 0.08, "y=%.3f" % zy)
	var zmin := _lowest_mesh_y(zombie)
	_check("zombie meshes above floor", zmin > -0.06, "min_y=%.3f" % zmin)
	_print_bones(zombie, "zombie")
	var zpos0: Vector3 = zombie.global_position
	await _physics(120)
	var zdist: float = Vector2(zombie.global_position.x - zpos0.x, zombie.global_position.z - zpos0.z).length()
	print("[AnimMeasure] zombie 2s wander=%.2f" % zdist)
	print("[AnimMeasure] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Staggered spawn: add + place + let several physics ticks run before the
## next body exists. Same-frame create+teleport of multiple bodies leaves
## stale server/broadphase state that detonates on tick 1 (body launched
## across the map by depenetration vs a ghost entry).
func _spawn_settled(parent: Node, body: CharacterBody3D, pos: Vector3) -> void:
	parent.add_child(body)
	body.global_position = pos
	PhysicsServer3D.body_set_state(body.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, body.global_transform)
	for i in 8:
		await get_tree().physics_frame

func _lowest_mesh_y(actor: Node) -> float:
	var skel: Skeleton3D = actor.get("_skeleton") as Skeleton3D
	if skel == null:
		return _lowest_under(actor)
	var lo := 999.0
	for mi in HumanoidModel.collect_meshes(skel):
		var aabb: AABB = mi.get_aabb()
		for c in 8:
			var local: Vector3 = aabb.position + Vector3(
				aabb.size.x if (c & 1) else 0.0,
				aabb.size.y if (c & 2) else 0.0,
				aabb.size.z if (c & 4) else 0.0)
			var w: Vector3 = mi.global_transform * local
			lo = minf(lo, w.y)
	return lo

func _lowest_under(n: Node) -> float:
	var lo := 999.0
	if n is MeshInstance3D:
		var aabb: AABB = (n as MeshInstance3D).get_aabb()
		lo = ((n as MeshInstance3D).global_transform * aabb.position).y
	for c in n.get_children():
		lo = minf(lo, _lowest_under(c))
	return lo

func _print_bones(actor: Node, tag: String) -> void:
	var skel: Skeleton3D = actor.get("_skeleton") as Skeleton3D
	if skel == null:
		print("[AnimMeasure] %s has no skeleton" % tag)
		return
	var hips := skel.find_bone("hips")
	if hips >= 0:
		print("[AnimMeasure] %s hips global_pose=%s (rest 0.86)" % [
			tag, str(skel.get_bone_global_pose(hips).origin)])
	var loco: Node = actor.get("_locomotion") as Node
	if loco != null:
		var tree: AnimationTree = loco.get("anim_tree") as AnimationTree
		var cur := ""
		if tree != null:
			var pb: Variant = tree.get("parameters/playback")
			if pb != null:
				cur = str(pb.get_current_node())
			var ap := loco.get("anim_player") as AnimationPlayer
			if ap != null:
				var skel2: Skeleton3D = actor.get("_skeleton") as Skeleton3D
				print("[AnimMeasure] %s player=%s skel=%s root=%s resolves=%s" % [
					tag, str(ap.get_path()), str(skel2.get_path()), str(ap.root_node),
					str(ap.get_node_or_null(ap.root_node))])
		print("[AnimMeasure] %s state=%d tree=%s active=%s" % [
			tag, int(loco.get("state")), cur,
			str(tree != null and tree.active)])

func _max_knee_gap(actor: Node, frames: int) -> float:
	var skel: Skeleton3D = actor.get("_skeleton") as Skeleton3D
	if skel == null:
		return -1.0
	var li := skel.find_bone("l_shin")
	var ri := skel.find_bone("r_shin")
	if li < 0 or ri < 0:
		return -1.0
	var lr: Vector3 = skel.get_bone_rest(li).origin
	var rr: Vector3 = skel.get_bone_rest(ri).origin
	var mx := 0.0
	for i in frames:
		await get_tree().physics_frame
		var dl: Vector3 = skel.get_bone_pose_position(li) - lr
		var dr: Vector3 = skel.get_bone_pose_position(ri) - rr
		mx = maxf(mx, maxf(dl.length(), dr.length()))
	return mx

func _swing_amplitude(actor: Node, frames: int) -> float:
	var skel: Skeleton3D = actor.get("_skeleton") as Skeleton3D
	if skel == null:
		return -1.0
	var idx := skel.find_bone("l_thigh")
	if idx < 0:
		return -1.0
	var mn := 999.0
	var mx := -999.0
	for i in frames:
		await get_tree().physics_frame
		var q: Quaternion = skel.get_bone_pose_rotation(idx)
		var e := q.get_euler()
		var deg := rad_to_deg(e.x)
		mn = minf(mn, deg)
		mx = maxf(mx, deg)
	return mx - mn
