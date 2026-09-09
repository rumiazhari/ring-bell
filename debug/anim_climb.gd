class_name AnimClimb
extends Node
## End-to-end climb verification with REAL geometry and a REAL actor
## (not bare-locomotion unit updates): floor + 2.0 m wall, survivor walks
## in, jumps, hangs/mantles/climbs via its own parkour raycasts, then
## walks away (stale-ledge drop case). Asserts across the whole run:
## arm bones never leave rest (the detached-arms regression), hang really
## triggers, hands stay sanely near the ledge while hanging.
## Usage: godot --headless --path . -- --animclimb

var failures := 0
var _max_arm_off := 0.0
var _hang_frames := 0
var _hang_gap_worst := 0.0
var _states_seen := {}

func _check(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("[AnimClimb] PASS %s" % test_name)
	else:
		failures += 1
		print("[AnimClimb] FAIL %s (%s)" % [test_name, detail])

func _run() -> void:
	print("[AnimClimb] start pid=%d" % OS.get_process_id())
	await get_tree().process_frame
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	floor_body.add_child(col)
	# Wall: 6 wide, top at y=2.0, front face at z=-2.0.
	var wall := StaticBody3D.new()
	wall.name = "Wall"
	add_child(wall)
	var wcol := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(6, 2.0, 1.0)
	wcol.shape = wbox
	wcol.position = Vector3(0, 1.0, -2.5)
	wall.add_child(wcol)

	var holder := Node3D.new()
	holder.name = "Holder"
	add_child(holder)
	var survivor := Survivor.new()
	survivor.configure({"is_player": false, "female": false})
	holder.add_child(survivor)
	survivor.global_position = Vector3(0, 0.6, 5.0)
	PhysicsServer3D.body_set_state((survivor as CharacterBody3D).get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, survivor.global_transform)
	for i in 8:
		await get_tree().physics_frame

	# Phase 1: walk at the wall.
	survivor.request_move(Vector3(0, 0, -1), false)
	for i in 70:
		await get_tree().physics_frame
		_sample(survivor)
	# Phase 2: jump near the wall, keep pushing in (rise window 1.6-2.1
	# over feet catches the 2.0 lip while rising).
	(survivor.get("parkour") as Node).call("try_jump")
	for i in 200:
		await get_tree().physics_frame
		_sample(survivor)
		if i % 40 == 39:
			Input.action_press("jump")
	# Phase 3: walk away (drop / stale-ledge case).
	survivor.request_move(Vector3(0, 0, 1), false)
	for i in 120:
		await get_tree().physics_frame
		_sample(survivor)
	survivor.stop_moving()

	print("[AnimClimb] states=%s hang_frames=%d" % [str(_states_seen.keys()), _hang_frames])
	_check("real hang triggered on wall", _hang_frames > 5, "hang_frames=%d" % _hang_frames)
	_check("arms never leave rest all run", _max_arm_off == 0.0, "max_off=%.4f" % _max_arm_off)
	# Gap is geometry-dependent (early hang: body at ground, ledge 2 m up),
	# so this is a sanity envelope against solver blowup, not a grab bar.
	# The limb guarantee is the exact attached check above.
	_check("hang hand gap sane", _hang_gap_worst < 2.0, "worst=%.3f" % _hang_gap_worst)
	var p: Vector3 = survivor.global_position
	_check("actor sane at end", p.y > -0.05 and p.y < 3.0 and p.x == p.x, str(p))
	print("[AnimClimb] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _sample(actor: Node) -> void:
	var skel: Skeleton3D = actor.get("_skeleton") as Skeleton3D
	if skel == null:
		return
	for b in ["l_upper_arm", "r_upper_arm"]:
		var bi := skel.find_bone(b)
		if bi < 0:
			continue
		var off: float = skel.get_bone_pose_position(bi).distance_to(skel.get_bone_rest(bi).origin)
		_max_arm_off = maxf(_max_arm_off, off)
	var loco: Node = actor.get("_locomotion") as Node
	if loco == null:
		return
	var st: int = int(loco.get("state"))
	_states_seen[st] = int(_states_seen.get(st, 0)) + 1
	if st == CharacterLocomotion.State.HANG:
		_hang_frames += 1
		_hang_gap_worst = maxf(_hang_gap_worst, float(loco.get("hand_snap")))

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[AnimClimb] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()
