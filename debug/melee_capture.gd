class_name MeleeCapture
extends Node
## Rendered visual capture of the melee kit for review.
## Usage: python tools/run_suite.py --meleecapture 300 --rendered
##
## Three passes, all deterministic (no randomness, fixed stage):
##   1. gallery  - every weapon model alone, 3/4 product shot
##   2. in-hand  - each weapon gripped by a survivor, close on the fist
##   3. combo rows - every non-empty row declared by MeleeCombos.COMBOS,
##                   captured at the authored strike/hold pose, side+front
##
## PNGs land in .hermes/autopilot/reports/melee-capture-<seed>-<ts>/.
## The combo rows are built at runtime from the combo table rather than from
## legacy clip names. Each verdict includes both weapon id and clip so a
## correct per-weapon mapping cannot be reported as a mismatch.

var _swings: Array = []

## Weapons with their own in-hand shot (fists draw nothing by design).
const HAND_WEAPONS: Array[StringName] = [
	&"cane_sabre", &"pipe_wrench", &"boarding_axe",
	&"boiler_lance", &"pipe", &"kitchen_knife",
]

const WATCHDOG := 150.0
const STEP := 0.02

var _dir := ""
var _step := 0
var _ui_hidden := -1
var _stage: Node3D
var _cam: Camera3D
var _survivor: Survivor


func _ready() -> void:
	# Headless cannot render; bail politely (same contract as anim_capture).
	if DisplayServer.get_name() == "headless":
		print("[MeleeCapture] headless, no capture possible")
		get_tree().quit(0)
		return
	get_tree().create_timer(WATCHDOG).timeout.connect(func() -> void:
		print("[MeleeCapture] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_build_stage()
	_swings = _enumerate_combo_rows()
	print("[MeleeCapture] combo rows=%d weapons=%d" % [_swings.size(), MeleeCombos.COMBOS.size()])
	_dir = ProjectSettings.globalize_path(
		"res://.hermes/autopilot/reports/melee-capture-%d-%d/"
		% [WorldSeed.get_world_seed(), int(Time.get_unix_time_from_system())])
	DirAccess.make_dir_recursive_absolute(_dir)
	print("[MeleeCapture] dir=%s" % _dir)

	await _capture_gallery()
	await _capture_in_hand()
	await _capture_swings()

	print("[MeleeCapture] finished %d shots dir=%s" % [_step, _dir])
	# Drop the staged scene before quitting. After a ~100 s run the world's
	# streaming pool is still winding down, and letting the engine free our
	# stage inside that teardown ended in a silent access violation at exit --
	# the shots were already written, so it only ever looked like a failed run.
	if _stage != null:
		_stage.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


## Build the capture rows from the authoritative per-weapon combo table. Empty
## heavy/counter fields are intentional for fists; they are reported as absent
## rather than replaced with a legacy clip.
func _enumerate_combo_rows() -> Array:
	var rows: Array = []
	for key in MeleeCombos.COMBOS.keys():
		var weapon: StringName = key as StringName
		var combo: Dictionary = MeleeCombos.COMBOS[weapon] as Dictionary
		var chain: Array = combo.get("chain", []) as Array
		for step_index in range(3):
			if step_index < chain.size():
				rows.append(_combo_row(weapon, "light_%d" % (step_index + 1),
						chain[step_index] as StringName, false, step_index + 1))
		_append_combo_field(rows, weapon, combo, "heavy", true, 0)
		_append_combo_field(rows, weapon, combo, "unique", false, 0)
		_append_combo_field(rows, weapon, combo, "guard", false, 0)
		_append_combo_field(rows, weapon, combo, "counter", false, 0)
	return rows


func _append_combo_field(rows: Array, weapon: StringName, combo: Dictionary,
			field: String, heavy: bool, step: int) -> void:
	var clip := StringName(combo.get(field, &""))
	if clip == &"":
		print("[MeleeCapture] combo row %s %s unavailable (COMBOS empty)" % [
			weapon, field])
		return
	rows.append(_combo_row(weapon, field, clip, heavy, step))


func _combo_row(weapon: StringName, kind: String, clip: StringName,
		heavy: bool, step: int) -> Dictionary:
	var angle := deg_to_rad(MeleeSwingLibrary.entry_angle(clip))
	return {
		"weapon": weapon,
		"kind": kind,
		"clip": clip,
		"aim": Vector3(sin(angle), 0.0, -cos(angle)),
		"heavy": heavy,
		"step": step,
	}


# --- Stage -------------------------------------------------------------------

func _build_stage() -> void:
	_stage = Node3D.new()
	_stage.name = "Stage"
	add_child(_stage)
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(60, 60)
	floor_mi.mesh = floor_mesh
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.20, 0.19, 0.18)
	floor_mi.mesh.surface_set_material(0, floor_mat)
	_stage.add_child(floor_mi)
	# The floor needs a body under it: a bare mesh lets the capture actor fall
	# out of the world, and a falling actor wrecks every subsequent frame.
	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorBody"
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(60.0, 1.0, 60.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	_stage.add_child(floor_body)
	# Key light plus a dim fill, so brass reads warm and steel still separates.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-52, 34, 0)
	key.light_energy = 1.35
	_stage.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-24, -140, 0)
	fill.light_energy = 0.45
	_stage.add_child(fill)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.19, 0.21, 0.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.60)
	env.ambient_light_energy = 0.65
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_stage.add_child(world_env)
	_cam = Camera3D.new()
	_cam.fov = 46.0
	_cam.current = true
	_stage.add_child(_cam)
	_hide_game_ui()


## Capture shots are for judging models and poses, so every on-screen readout
## (debug overlay, HUD, interaction prompts) is hidden. Only the stage draws.
func _hide_game_ui() -> void:
	var hidden := 0
	var stack: Array[Node] = []
	for node in get_tree().root.get_children():
		stack.append(node)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == self:
			continue
		# The HUD is not a direct child of root, so walk the whole tree. Only
		# on-screen readouts are hidden -- CanvasLayer/Control plus world-space
		# text and sprites -- never 3D geometry.
		# CanvasLayer is a plain Node and Label3D/Sprite3D are Node3D, so a
		# CanvasItem cast would be null for most of these: go through the
		# property instead.
		var is_ui := n is CanvasLayer or n is Control or n is Label3D or n is Sprite3D
		if is_ui and bool(n.get("visible")):
			n.set("visible", false)
			hidden += 1
		for c in n.get_children():
			stack.append(c)
	# The game keeps creating overlays as streaming progresses (a capture run
	# outlives the startup UI), so _snap() re-hides before every frame.
	if hidden != _ui_hidden:
		_ui_hidden = hidden
		print("[MeleeCapture] hid %d UI nodes" % hidden)


func _aim_at(from: Vector3, at: Vector3) -> void:
	_cam.global_position = from
	_cam.look_at(at, Vector3.UP)


func _snap(file_name: String) -> void:
	_hide_game_ui()
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("[MeleeCapture] %s NO IMAGE" % file_name)
		return
	_step += 1
	var path := _dir.path_join(file_name)
	var err := img.save_png(path)
	print("[MeleeCapture] %s err=%d" % [file_name, err])


func _settle(frames := 6) -> void:
	for _i in frames:
		await get_tree().physics_frame
	await get_tree().process_frame


# --- Pass 1: weapon gallery --------------------------------------------------

func _aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(root):
		var world: AABB = mi.global_transform * mi.get_aabb()
		if first:
			box = world
			first = false
		else:
			box = box.merge(world)
	return box


## AABB in the node's OWN frame: the world-space _aabb above cannot say which way
## a weapon's length runs once the weapon is rotated by the hand it hangs off.
func _local_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var to_local := root.global_transform.affine_inverse()
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


func _capture_gallery() -> void:
	var ids: Array = []
	for id in MeleeWeaponModels.MODELS:
		if id != &"fists":
			ids.append(id)
	# Lineup: one wide row so all six weapons sit in a single frame.
	var row := Node3D.new()
	row.name = "GalleryRow"
	_stage.add_child(row)
	var i := 0
	for id in ids:
		var model := MeleeWeaponModels.build(id as StringName)
		# Lay each weapon down flat, length running along X. 1.9 m pitch keeps
		# a two-handed polearm clear of its neighbours, and the camera sits far
		# enough back (8.2 m) that the outermost weapon is fully in frame.
		model.position = Vector3(-4.75 + 1.9 * i, 0.10, 0)
		model.rotation_degrees = Vector3(0, -90, 0)
		row.add_child(model)
		i += 1
	await _settle(4)
	_aim_at(Vector3(0, 1.70, 8.2), Vector3(0, 0.06, 0))
	await _snap("%02d_gallery_row.png" % (_step + 1))
	row.queue_free()

	# Product shot per weapon: frame the model's own bounds and aim the camera
	# ACROSS the weapon's long axis (CaptureFraming). A fixed camera direction is
	# broadside to a model whose length runs along X and exactly end-on to one
	# whose length runs along Z - which is how the cane-sabre shot came out as a
	# stub. The framing line below prints the angle so the shot can be judged by
	# a number as well as by eye.
	for id in ids:
		var model := MeleeWeaponModels.build(id as StringName)
		_stage.add_child(model)
		# One presentation spin for every weapon, then the camera follows it.
		model.rotation_degrees = Vector3(0, -32, 0)
		await _settle(4)
		var box := _aabb(model)
		var centre := box.get_center()
		var long_local := CaptureFraming.long_axis_vector(box.size)
		var long_world := CaptureFraming.rotated_axis(long_local,
				model.rotation_degrees.y)
		var radius := maxf(0.25, box.size.length() * 0.5)
		var cam_dir := CaptureFraming.view_dir(long_world)
		var d := CaptureFraming.distance_for(radius, _cam.fov, 0.72)
		_aim_at(centre + cam_dir * d, centre)
		var report := CaptureFraming.frame_coverage(_cam, box)
		print("[MeleeCapture] framing %s long=%s broadside=%.0f fill=%.0f%% inside=%s" % [
			id, str(long_local), CaptureFraming.broadside_deg(long_world, cam_dir),
			float(report["fill"]) * 100.0, str(report["inside"])])
		await _snap("%02d_weapon_%s.png" % [_step + 1, id])
		model.queue_free()
		await get_tree().process_frame


# --- Pass 2: in hand ---------------------------------------------------------

func _setup_survivor(weapon: StringName) -> void:
	_survivor = Survivor.new()
	_survivor.configure({
		"id": &"melee_capture", "name": "MeleeCapture", "is_player": false,
		"color": Color(0.80, 0.70, 0.42), "weapon": weapon,
	})
	_stage.add_child(_survivor)
	_survivor.global_position = Vector3(0, 0.6, 0)
	_survivor.facing = Vector3(0, 0, -1)
	# Nameplates / health bars are world-space sprites, so they survive the
	# CanvasLayer sweep above; hide them on the capture actor too.
	for node in _survivor.get_children():
		if node is Label3D or node is Sprite3D or node is MeshInstance3D \
				and String(node.name).to_lower().contains("bar"):
			(node as Node3D).visible = false
	await _settle(10)


func _capture_in_hand() -> void:
	await _setup_survivor(&"cane_sabre")
	for id in HAND_WEAPONS:
		_survivor.equip_weapon(id)
		await _settle(4)
		_survivor.global_position = Vector3(0, 0.6, 0)
		# Frame the weapon's own bounds rather than the fist: a sword cane hangs
		# well below the hand, so a close-up centred on the grip cropped the
		# weapon out of frame entirely.
		var mesh: Node3D = _survivor.melee.get("_mesh")
		var box := _aabb(mesh) if mesh != null else AABB()
		if box.size.length() < 0.05:
			var anchor := _hand_anchor()
			if anchor == Vector3.INF:
				anchor = _survivor.global_position + Vector3(0, 1.0, 0)
			box = AABB(anchor, Vector3(0.5, 0.5, 0.5))
		# The head belongs in the frame as well: a QA shot that decapitates the
		# actor reads as a framing bug even when the weapon itself is perfect.
		var head := _head_anchor()
		if head != Vector3.INF:
			box = box.merge(AABB(head - Vector3.ONE * 0.18, Vector3.ONE * 0.36))
		var at := box.get_center()
		# Aim ACROSS the weapon's own long axis, measured in the weapon's frame
		# and then taken to world space: a sword cane hangs off the hand at an
		# angle, so one fixed camera offset is side-on to a sabre and end-on to
		# an axe. The camera also takes the weapon's own side of the body, so the
		# torso cannot sit between the lens and the weapon.
		var long_world := Vector3.UP
		if mesh != null:
			var local_box := _local_aabb(mesh)
			long_world = (mesh.global_transform.basis
					* CaptureFraming.long_axis_vector(local_box.size)).normalized()
		var to_weapon := at - _survivor.global_position
		to_weapon.y = 0.0
		var cam_dir := CaptureFraming.view_dir(long_world, 28.0, 0.30, to_weapon)
		var radius := maxf(0.30, box.size.length() * 0.5)
		var d := CaptureFraming.distance_for(radius, _cam.fov, 0.76)
		_aim_at(at + cam_dir * d, at)
		var report := CaptureFraming.frame_coverage(_cam, box)
		print("[MeleeCapture] framing hand_%s broadside=%.0f fill=%.0f%% inside=%s" % [
			id, CaptureFraming.broadside_deg(long_world, cam_dir),
			float(report["fill"]) * 100.0, str(report["inside"])])
		await _snap("%02d_hand_%s.png" % [_step + 1, id])
	# Idle reference from the swing camera: without it there is no way to tell
	# a caught-mid-swing frame from a rest pose by eye.
	_survivor.global_position = Vector3(0, 0.6, 0)
	var idle_at := _survivor.global_position + Vector3(0, 1.05, 0)
	_aim_at(idle_at + Vector3(2.75, 0.70, 0.45), idle_at + Vector3(0, 0.05, -0.30))
	await _snap("00_idle_reference.png")
	await _snap("00_idle_reference_b.png")


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


## World position of the actor's head bone (Vector3.INF when the rig has none).
func _head_anchor() -> Vector3:
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	if skeleton == null:
		return Vector3.INF
	var idx := skeleton.find_bone(&"head")
	if idx < 0:
		return Vector3.INF
	return skeleton.global_transform * skeleton.get_bone_global_pose(idx).origin


# --- Pass 3: combo rows -------------------------------------------------------

func _capture_swings() -> void:
	for entry in _swings:
		var clip: StringName = entry["clip"]
		var weapon: StringName = entry["weapon"]
		var kind: String = String(entry["kind"])
		_survivor.equip_weapon(weapon)
		await _settle(4)
		await _wait_for_idle()
		var started := _start_combo_row(entry)
		var runtime_weapon := _runtime_weapon_id(weapon)
		var actual_weapon: StringName = _survivor.melee.weapon_id()
		var got: StringName = _survivor.melee.current_clip()
		var weapon_ok := actual_weapon == runtime_weapon
		var verdict := "PASS" if started and got == clip and weapon_ok else "MISMATCH"
		print("[MeleeCapture] %s/%s weapon=%s intended=%s actual=%s %s phase=%s" % [
			weapon, kind, weapon, clip, got, verdict, _survivor.melee.phase()])
		if not started:
			print("[MeleeCapture] %s/%s MISMATCH: row refused" % [weapon, kind])
			continue

		if kind == "guard":
			await _settle(3)
		else:
			# Attack rows are held at their authored strike frame. The runtime
			# clip is checked before and after this wait; a wrong mapping cannot
			# hide behind a later animation state.
			var waited := 0
			while _survivor.melee.phase() == "WINDUP" and waited < 400:
				waited += 1
				await get_tree().physics_frame
			got = _survivor.melee.current_clip()
			verdict = "PASS" if got == clip and _survivor.melee.weapon_id() == runtime_weapon else "MISMATCH"
			print("[MeleeCapture] %s/%s weapon=%s strike_actual=%s %s phase=%s" % [
				weapon, kind, weapon, got, verdict, _survivor.melee.phase()])

		var hand := _hand_anchor()
		_survivor.global_position = Vector3(0, 0.6, 0)
		var at := _survivor.global_position + Vector3(0, 1.05, 0)
		_aim_at(at + Vector3(2.75, 0.70, 0.45), at + Vector3(0, 0.05, -0.30))
		await _snap("%02d_swing_%s_%s_%s_side.png" % [
			_step + 1, weapon, kind, clip])
		_aim_at(at + _survivor.facing * 2.45 + Vector3(0.85, 0.75, 0.0),
			at + Vector3(0, 0.05, -0.25))
		await _snap("%02d_swing_%s_%s_%s_front.png" % [
			_step + 1, weapon, kind, clip])
		# Keep the established numeric framing evidence for every row.
		var head := _survivor.global_position + Vector3(0, 1.62, 0)
		var feet := _survivor.global_position
		print("[MeleeCapture] %s/%s framing head=%s feet=%s behind=%s dist=%.2f" % [
			weapon, kind, _cam.unproject_position(head), _cam.unproject_position(feet),
			str(_cam.is_position_behind(head)),
			_cam.global_position.distance_to(_survivor.global_position)])
		if hand != Vector3.INF and hand == Vector3.ZERO:
			print("[MeleeCapture] %s/%s hand anchor degenerate" % [weapon, kind])

		if kind == "guard":
			_survivor.melee.set_guarding(false)
		else:
			await _wait_for_idle()
		await _settle(4)


func _wait_for_idle() -> void:
	if _survivor.melee.is_guarding():
		_survivor.melee.set_guarding(false)
	var guard := 0
	while _survivor.melee.state() != MeleeCombat.State.IDLE and guard < 500:
		guard += 1
		await get_tree().physics_frame


func _reset_combo_gates() -> void:
	_survivor.melee.set("_combo_deadline", 0)
	_survivor.melee.set("_cooldown_left", 0.0)
	_survivor.melee.set("_riposte_armed_until", 0)
	_survivor.stamina = Survivor.STAMINA_MAX


func _start_combo_row(entry: Dictionary) -> bool:
	_reset_combo_gates()
	var kind: String = String(entry["kind"])
	if kind == "guard":
		return _survivor.melee.set_guarding(true)

	var step := int(entry.get("step", 0))
	_survivor.melee.set("_combo", maxi(0, step - 1))
	_survivor.melee.set("_combo_deadline", Time.get_ticks_msec() + 5000)
	if kind == "counter":
		# A counter is normally armed by a successful parry. The four non-sabre
		# combo tables intentionally have no perfect-parry window, so arm the
		# declared counter clip directly to measure its live animation path too.
		_survivor.melee.set("_riposte_armed_until", Time.get_ticks_msec() + 1000)
	if kind == "unique":
		# Unique finishers are data-defined but are not selected by ordinary
		# light/heavy input. Narrow the live combo definition for this one call,
		# then restore it immediately after _begin_attack has selected the clip.
		var def: Dictionary = _survivor.melee.weapon_def()
		var combo: Dictionary = def.get("combo", {}) as Dictionary
		var old_chain: Array = (combo.get("chain", []) as Array).duplicate()
		var old_combo_chain: Array = (def.get("combo_chain", []) as Array).duplicate()
		var old_pool: Array = (def.get("swing_pool", []) as Array).duplicate()
		var one: Array = [entry["clip"]]
		combo["chain"] = one
		def["combo_chain"] = one
		def["swing_pool"] = one
		var started_unique: bool = _survivor.melee_attack(entry["aim"], false)
		combo["chain"] = old_chain
		def["combo_chain"] = old_combo_chain
		def["swing_pool"] = old_pool
		return started_unique
	return _survivor.melee_attack(entry["aim"], bool(entry["heavy"]))


func _runtime_weapon_id(weapon: StringName) -> StringName:
	return &"" if weapon == &"fists" else weapon
