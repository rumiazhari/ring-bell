class_name MeleeAxisProbe
extends Node
## Diagnostic probe (NOT a spec test): prints how candidate bone rotations map
## to world limb directions on the survivor rig.
##
## Rig frame reminder: local +X = character's RIGHT, -Z = FORWARD, +Y = UP.
## Swing clips are authored from these verified signs, so nobody has to guess
## whether "+X on an arm" means forward or backward.
##
## Usage: python tools/run_suite.py --meleeprobe

const CASES_ARM := [
	["X-60", Vector3(-60, 0, 0)],
	["X+60", Vector3(60, 0, 0)],
	["X+90", Vector3(90, 0, 0)],
	["X+150", Vector3(150, 0, 0)],
	["Z+60", Vector3(0, 0, 60)],
	["Z-60", Vector3(0, 0, -60)],
	["Y+60", Vector3(0, 60, 0)],
]


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[MeleeAxisProbe] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()


func _run() -> void:
	await get_tree().process_frame
	var holder := Node3D.new()
	add_child(holder)
	var skel := SkeletonFactory.build_survivor_skeleton(true)
	holder.add_child(skel)
	await get_tree().process_frame
	print("[MeleeAxisProbe] bones=%d articulated=%s" % [
			skel.get_bone_count(), str(skel.get_meta("articulated", false))])
	for b in ["hips", "spine_upper", "head", "l_upper_arm", "r_upper_arm",
			"l_forearm", "r_forearm"]:
		var idx := skel.find_bone(b)
		print("[MeleeAxisProbe] bone %-12s idx=%d rest=%s" % [
				b, idx, str(skel.get_bone_rest(idx).origin) if idx >= 0 else "-"])
	_arm(skel, "r_upper_arm", "r_forearm")
	_arm(skel, "l_upper_arm", "l_forearm")
	_elbow(skel, "r_forearm")
	_spine(skel)
	skel.queue_free()
	get_tree().quit(0)


func _clear(skel: Skeleton3D) -> void:
	for i in skel.get_bone_count():
		skel.set_bone_pose_rotation(i, Quaternion.IDENTITY)
	skel.force_update_all_bone_transforms()


func _arm(skel: Skeleton3D, upper: String, fore: String) -> void:
	var u := skel.find_bone(upper)
	var f := skel.find_bone(fore)
	if u < 0:
		print("[MeleeAxisProbe] missing bone %s" % upper)
		return
	var flen := skel.get_bone_rest(f).origin.length() if f >= 0 else 0.0
	for c in CASES_ARM:
		_clear(skel)
		skel.set_bone_pose_rotation(u, _q(c[1] as Vector3))
		skel.force_update_all_bone_transforms()
		var up_pose := skel.get_bone_global_pose(u)
		var shoulder: Vector3 = up_pose.origin
		var tip: Vector3
		if f >= 0:
			var f_pose := skel.get_bone_global_pose(f)
			tip = f_pose.origin + f_pose.basis.y * (-flen)
		else:
			tip = up_pose.origin + up_pose.basis.y * (-skel.get_bone_rest(u).origin.length())
		var d := (tip - shoulder).normalized()
		print("[MeleeAxisProbe] %s %-5s -> hand dir (x=%.2f y=%.2f z=%.2f) | hand=%s" % [
				upper, c[0], d.x, d.y, d.z, _tag(d)])


func _elbow(skel: Skeleton3D, fore: String) -> void:
	var f := skel.find_bone(fore)
	if f < 0:
		return
	var flen := skel.get_bone_rest(f).origin.length()
	for c in CASES_ARM:
		_clear(skel)
		skel.set_bone_pose_rotation(f, _q(c[1] as Vector3))
		skel.force_update_all_bone_transforms()
		var f_pose := skel.get_bone_global_pose(f)
		var elbow: Vector3 = f_pose.origin
		var hand := elbow + f_pose.basis.y * (-flen)
		var d := (hand - elbow).normalized()
		print("[MeleeAxisProbe] %s %-5s -> hand dir (x=%.2f y=%.2f z=%.2f) | hand=%s" % [
				fore, c[0], d.x, d.y, d.z, _tag(d)])


func _spine(skel: Skeleton3D) -> void:
	var sp := skel.find_bone("spine_upper")
	var head := skel.find_bone("head")
	var r_arm := skel.find_bone("r_upper_arm")
	if sp < 0:
		return
	for c in [["X+30", Vector3(30, 0, 0)], ["X-30", Vector3(-30, 0, 0)],
			["Y+30", Vector3(0, 30, 0)], ["Y-30", Vector3(0, -30, 0)]]:
		_clear(skel)
		skel.set_bone_pose_rotation(sp, _q(c[1] as Vector3))
		skel.force_update_all_bone_transforms()
		var sp_p := skel.get_bone_global_pose(sp)
		var head_p := skel.get_bone_global_pose(head)
		var arm_p := skel.get_bone_global_pose(r_arm)
		var up := (head_p.origin - sp_p.origin).normalized()
		var shoulder := (arm_p.origin - sp_p.origin).normalized()
		print("[MeleeAxisProbe] spine_upper %-4s -> torso up (x=%.2f z=%.2f) | r-shoulder rel (x=%.2f z=%.2f)" % [
				c[0], up.x, up.z, shoulder.x, shoulder.z])


func _tag(d: Vector3) -> String:
	var t: Array[String] = []
	if d.z < -0.35:
		t.append("FORWARD")
	elif d.z > 0.35:
		t.append("BACK")
	if d.y > 0.35:
		t.append("UP")
	elif d.y < -0.35:
		t.append("DOWN")
	if d.x > 0.35:
		t.append("RIGHT")
	elif d.x < -0.35:
		t.append("LEFT")
	return " ".join(t) if not t.is_empty() else "NEUTRAL"


func _q(deg: Vector3) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y),
			deg_to_rad(deg.z)))
