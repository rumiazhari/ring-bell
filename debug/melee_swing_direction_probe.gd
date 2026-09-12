class_name MeleeSwingDirectionProbe
extends Node
## Diagnostic probe (NOT a spec test): for each authored swing clip, WHERE does
## the blade actually travel -- measured in the character's own axes?
##
## Why this exists: the swing clips were authored against debug/melee_axis_probe.gd,
## which tags a hand direction as "FORWARD" when `d.z < -0.35`. But the rig's
## visible front is +Z: actors/humanoid_model.gd authors the nose ("Nose bump
## doubles as the facing cue (+Z)") at z=+0.125 and the face panel at +Z, and
## survivor.gd turns the visual root with `atan2(facing.x, facing.z)`, which aims
## that nose along `facing`. So the probe's "FORWARD" was the character's BACK,
## and every X (fwd/back) and Y (twist) sign authored from it is inverted.
##
## This probe measures the truth instead of re-reading the comment. Reference
## frame is the actor's REAL frame, taken from `facing`:
##   fwd   = facing (the way the character walks -- its visible front)
##   right = facing x UP
##   up    = UP
## Every printed side/up/front component is a dot product in that frame, so the
## verdict needs no convention: dot(blade motion, aim) > 0 means the blade goes
## where the player aimed.
##
## Usage: python tools/run_suite.py --meleedirprobe 300

const WATCHDOG := 300.0
const FRAME_CAP := 900

## Aim that should select each clip, matching debug/melee_capture.gd. The actor
## faces -Z, so a world aim of -Z is straight ahead of it.
const SWINGS: Array = [
	{"clip": &"SlashR", "weapon": &"cane_sabre", "aim": Vector3(0.866, 0, -0.5), "heavy": false},
	{"clip": &"SlashL", "weapon": &"cane_sabre", "aim": Vector3(-0.866, 0, -0.5), "heavy": false},
	{"clip": &"DiagR", "weapon": &"cane_sabre", "aim": Vector3(0.469, 0, -0.883), "heavy": false},
	{"clip": &"DiagL", "weapon": &"cane_sabre", "aim": Vector3(-0.469, 0, -0.883), "heavy": false},
	{"clip": &"Sweep", "weapon": &"cane_sabre", "aim": Vector3(0, 0, 1), "heavy": false},
	{"clip": &"Chop", "weapon": &"pipe_wrench", "aim": Vector3(0, 0, -1), "heavy": false},
	{"clip": &"Smash", "weapon": &"pipe_wrench", "aim": Vector3(0, 0, -1), "heavy": true},
	{"clip": &"Thrust", "weapon": &"boiler_lance", "aim": Vector3(0, 0, -1), "heavy": false},
]

var _stage: Node3D
var _survivor: Survivor
var _fwd := Vector3(0, 0, -1)
var _right := Vector3(1, 0, 0)

var _aligned := 0
var _trace := false
var _inverted := 0
var _front_ok := 0
var _front_bad := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG).timeout.connect(func() -> void:
		print("[MeleeDirProbe] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()


func _run() -> void:
	await get_tree().process_frame
	_trace = OS.get_environment("RB_TRACE") == "1"
	var only := OS.get_environment("RB_TRACE_CLIP")
	_build_stage()
	await _setup_survivor()
	_report_rig_frame()

	for entry in SWINGS:
		if only != "" and not only.contains(String(entry["clip"])):
			continue
		await _probe_swing(entry)

	print("[MeleeDirProbe] SUMMARY aligned=%d inverted=%d front_ok=%d front_bad=%d of %d" % [
		_aligned, _inverted, _front_ok, _front_bad, SWINGS.size()])
	if _stage != null:
		_stage.queue_free()
	await get_tree().process_frame
	get_tree().quit(0)


# --- Stage -------------------------------------------------------------------

func _build_stage() -> void:
	_stage = Node3D.new()
	_stage.name = "ProbeStage"
	add_child(_stage)
	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorBody"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	shape.shape = box
	shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(shape)
	_stage.add_child(floor_body)


func _setup_survivor() -> void:
	_survivor = Survivor.new()
	_survivor.configure({
		"id": &"melee_dir_probe", "name": "MeleeDirProbe", "is_player": false,
		"color": Color(0.80, 0.70, 0.42), "weapon": &"cane_sabre",
	})
	_stage.add_child(_survivor)
	_survivor.global_position = Vector3(0, 0.6, 0)
	_survivor.facing = Vector3(0, 0, -1)
	_fwd = Vector3(0, 0, -1).normalized()
	_right = _fwd.cross(Vector3.UP).normalized()
	await _settle(12)


func _settle(frames := 8) -> void:
	for _i in frames:
		await get_tree().physics_frame
	await get_tree().process_frame


# --- Proof of the rig's own frame --------------------------------------------

## The whole probe rests on "+Z is the way the character faces". Rather than
## re-asserting the comment, measure the geometry: the head's meshes in the
## visual root's frame must protrude toward +Z (that is the nose), and the
## facing vector must agree with the visual root's own +Z axis.
func _report_rig_frame() -> void:
	var visual: Node3D = _survivor.get("_visual_root")
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	if visual == null or skeleton == null:
		print("[MeleeDirProbe] FRAME: no visual root / skeleton")
		return
	# Does the visual root's +Z axis point the way the actor walks?
	var root_fwd := visual.global_transform.basis.z.normalized()
	print("[MeleeDirProbe] FRAME facing=%s visual_root_+Z=%s dot=%.3f" % [
		str(_fwd), str(root_fwd), root_fwd.dot(_fwd)])
	# Where is the head's geometry? The nose is the only asymmetric head part.
	var idx := skeleton.find_bone(&"head")
	if idx < 0:
		return
	var head_xf := skeleton.global_transform * skeleton.get_bone_global_pose(idx)
	var to_visual := visual.global_transform.affine_inverse()
	var lo := INF
	var hi := -INF
	for mi in _meshes(skeleton):
		var parent := mi.get_parent_node_3d()
		if parent == null:
			continue
		# Only the meshes that sit directly under the head bone attachment.
		var on_head := String(parent.name) == "head"
		if not on_head and not _is_head_mesh(mi, head_xf):
			continue
		var rel: Transform3D = to_visual * mi.global_transform
		var local: AABB = rel * mi.get_aabb()
		lo = minf(lo, local.position.z)
		hi = maxf(hi, local.end.z)
	if lo < INF:
		print("[MeleeDirProbe] FRAME head_mesh_z[min=%.3f max=%.3f] -> +Z is the face side" % [lo, hi])
	else:
		print("[MeleeDirProbe] FRAME head mesh not resolvable (mesh axes only)")


func _is_head_mesh(mi: MeshInstance3D, _head_xf: Transform3D) -> bool:
	var n := String(mi.name).to_lower()
	return n.contains("head") or n.contains("nose") or n.contains("face")


# --- One swing ---------------------------------------------------------------

func _probe_swing(entry: Dictionary) -> void:
	var clip: StringName = entry["clip"]
	_survivor.equip_weapon(entry["weapon"])
	await _settle(6)

	# Wait out any previous swing, then clear the combo gates so this is the
	# opening swing (same contract as the capture harness).
	var guard := 0
	while _survivor.melee.state() != MeleeCombat.State.IDLE and guard < FRAME_CAP:
		guard += 1
		await get_tree().physics_frame
	_survivor.facing = Vector3(0, 0, -1)
	_fwd = _survivor.facing.normalized()
	_right = _fwd.cross(Vector3.UP).normalized()
	_survivor.melee.set("_combo", 0)
	_survivor.melee.set("_combo_deadline", 0)
	_survivor.melee.set("_cooldown_left", 0.0)
	_survivor.stamina = Survivor.STAMINA_MAX
	await _settle(4)

	var rest_hand := _hand_anchor()
	var mesh: Node3D = _survivor.melee.get("_mesh")
	if mesh == null:
		print("[MeleeDirProbe] %s NO WEAPON MESH" % clip)
		return
	# Resolve the blade tip ONCE per clip, in the weapon's own frame: the
	# long-axis end farther from the hand. Re-picking "farthest end" every frame
	# made the tip teleport between the two ends mid-swing and poisoned the
	# travel/direction numbers.
	var rest_tip := _weapon_tip_at(mesh, rest_hand)
	if rest_tip == Vector3.INF:
		print("[MeleeDirProbe] %s NO WEAPON MESH" % clip)
		return
	var tip_local: Vector3 = mesh.global_transform.affine_inverse() * rest_tip

	var aim: Vector3 = entry["aim"]
	var aim_n := aim.normalized()
	var started: bool = _survivor.melee_attack(aim, bool(entry["heavy"]))
	if not started:
		print("[MeleeDirProbe] %s REFUSED" % clip)
		return

	# Sample every frame, then read the blade's motion at the moment the DEFS say
	# it lands ("hit" is a fraction of "length"). Endpoint metrics are useless
	# here: the biggest single frame step in a clip is the rest->windup snap, and
	# the largest displacement-from-rest is the follow-through, not the swing.
	var tips: Array[Vector3] = []
	var max_step := 0.0
	var min_body := INF
	var travel := 0.0
	var prev_tip := rest_tip
	var frames := 0
	var got: StringName = &""
	while _survivor.melee.state() != MeleeCombat.State.IDLE and frames < FRAME_CAP:
		frames += 1
		await get_tree().physics_frame
		if got == &"" and String(_survivor.melee.current_clip()) != "":
			got = _survivor.melee.current_clip()
		if mesh == null or not is_instance_valid(mesh):
			continue
		var tip: Vector3 = mesh.global_transform * tip_local
		tips.append(tip)
		if _trace:
			var hv := _axes(_hand_anchor() - _survivor.global_position)
			var tv := _axes(tip - _survivor.global_position)
			print("[Trace] %s f=%02d hand(s=%+.2f f=%+.2f u=%+.2f) tip(s=%+.2f f=%+.2f u=%+.2f)" % [
				clip, frames, hv["side"], hv["front"], hv["up"],
				tv["side"], tv["front"], tv["up"]])
		var step_len := tip.distance_to(prev_tip)
		max_step = maxf(max_step, step_len)
		travel += step_len
		prev_tip = tip
		min_body = minf(min_body, _dist_to_body_axis(tip))

	if got == &"":
		got = _survivor.melee.current_clip()
	var sel := "SEL_OK" if got == clip else "SEL_MISMATCH(%s)" % got
	# The swing window: +-3 frames (0.1 s at 60 Hz) around the authored hit time.
	var def: Dictionary = MeleeSwingLibrary.DEFS.get(clip, {})
	var hit_s := float(def.get("hit", 0.45)) * float(def.get("length", 0.7))
	var hit_f := int(round(hit_s * 60.0))
	var strike_vec := Vector3.ZERO
	if tips.size() >= 7:
		var lo := clampi(hit_f - 3, 0, tips.size() - 1)
		var hi := clampi(hit_f + 3, 0, tips.size() - 1)
		strike_vec = tips[hi] - tips[lo]
	var window_s := 0.1
	var m := _axes(strike_vec)
	var a := _axes(aim_n)
	# Does the blade travel toward the aim? (ignore the vertical for the verdict:
	# aims are authored on the ground plane, arcs are not)
	var flat_m := Vector3(float(m["side"]), 0.0, float(m["front"]))
	var flat_a := Vector3(float(a["side"]), 0.0, float(a["front"]))
	var dot := 0.0
	if flat_m.length() > 0.0001 and flat_a.length() > 0.0001:
		dot = flat_m.normalized().dot(flat_a.normalized())
	if dot > 0.15:
		_aligned += 1
	elif dot < -0.15:
		_inverted += 1
	# Front/back: the user-visible complaint. Does a forward aim send the blade
	# forward (and a backward aim send it back)?
	var want_front: float = float(a["front"])
	var got_front: float = float(m["front"])
	if absf(want_front) < 0.15:
		pass
	elif signf(want_front) == signf(got_front):
		_front_ok += 1
	else:
		_front_bad += 1

	print("[MeleeDirProbe] %-7s %s aim(side=%+.2f front=%+.2f) | STRIKE_d side=%+.2f up=%+.2f front=%+.2f speed=%.1fm/s | dot=%+.2f %s | frames=%d hit_f=%d max_step=%.2f tip_h=%.2f body_gap=%.2f travel=%.2f len=%.2f" % [
		clip, sel,
		a["side"], a["front"],
		m["side"], m["up"], m["front"], strike_vec.length() / window_s,
		dot, "ALIGNED" if dot > 0.15 else ("INVERTED" if dot < -0.15 else "SIDEWAYS"),
		frames, hit_f, max_step,
		(rest_tip - rest_hand).length(),
		min_body if min_body < INF else -1.0,
		travel,
		rest_tip.distance_to(rest_hand)])

	# Held orientation at rest, in the actor's frame: a weapon that points into
	# the character's back at rest is wrong before any swing plays.
	var held := _axes((rest_tip - rest_hand).normalized())
	print("[MeleeDirProbe] %-7s REST held_dir side=%+.2f up=%+.2f front=%+.2f" % [
		clip, held["side"], held["up"], held["front"]])

	guard = 0
	while _survivor.melee.state() != MeleeCombat.State.IDLE and guard < FRAME_CAP:
		guard += 1
		await get_tree().physics_frame
	await _settle(4)


# --- Measurement -------------------------------------------------------------

## Dot products of a world vector against the actor's REAL frame.
func _axes(v: Vector3) -> Dictionary:
	return {
		"side": v.dot(_right),
		"up": v.dot(Vector3.UP),
		"front": v.dot(_fwd),
	}


func _hand_anchor() -> Vector3:
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	if skeleton == null:
		return Vector3.INF
	for child in skeleton.get_children():
		if child is BoneAttachment3D and String(child.name) == "MeleeHand":
			var holder: Node3D = (child as BoneAttachment3D).get_node_or_null("MeleeGrip")
			if holder != null:
				return holder.global_position
	return Vector3.INF


## Blade tip: the far end of the weapon mesh's own long axis (same local-bounds
## idiom the capture harness uses -- a world AABB cannot say which way a rotated
## weapon's length runs).
func _weapon_tip_at(mesh: Node3D, hand: Vector3) -> Vector3:
	if mesh == null or not is_instance_valid(mesh):
		return Vector3.INF
	var box := _local_aabb(mesh)
	var axis := _long_axis(box.size)
	var half := axis.dot(box.size * 0.5)
	var a := mesh.global_transform * (box.get_center() + axis * half)
	var b := mesh.global_transform * (box.get_center() - axis * half)
	if hand == Vector3.INF:
		return a
	return a if a.distance_to(hand) > b.distance_to(hand) else b


func _long_axis(sz: Vector3) -> Vector3:
	if sz.x >= sz.y and sz.x >= sz.z:
		return Vector3(1, 0, 0)
	if sz.y >= sz.z:
		return Vector3(0, 1, 0)
	return Vector3(0, 0, 1)


func _local_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var to_local: Transform3D = root.global_transform.affine_inverse()
	for mi in _meshes(root):
		var rel: Transform3D = to_local * mi.global_transform
		var box: AABB = rel * mi.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


func _meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(_meshes(child))
	return out


## Gap between a point and the body's vertical axis (hips -> head). A blade that
## crosses this line is inside the character.
func _dist_to_body_axis(p: Vector3) -> float:
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	if skeleton == null:
		return -1.0
	var hips := skeleton.find_bone(&"hips")
	var head := skeleton.find_bone(&"head")
	if hips < 0 or head < 0:
		return -1.0
	var a: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hips).origin
	var b: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(head).origin
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 0.0001:
		t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)
