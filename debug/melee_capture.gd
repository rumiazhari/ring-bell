class_name MeleeCapture
extends Node
## Rendered visual capture of the melee kit for review.
## Usage: python tools/run_suite.py --meleecapture 300 --rendered
##
## Three passes, all deterministic (no randomness, fixed stage):
##   1. gallery  - every weapon model alone, 3/4 product shot
##   2. in-hand  - each weapon gripped by a survivor, close on the fist
##   3. swings   - the eight authored swings at their strike frame, side+front
##
## PNGs land in .hermes/autopilot/reports/melee-capture-<seed>-<ts>/.
## Also prints a PASS/MISMATCH line per swing so the capture doubles as
## evidence that the aim -> clip mapping really fires on the live rig.

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

	# Product shot per weapon: frame the model's own bounds.
	for id in ids:
		var model := MeleeWeaponModels.build(id as StringName)
		_stage.add_child(model)
		var box := _aabb(model)
		var centre := box.get_center()
		var size := box.size
		var span := maxf(0.4, maxf(size.x, maxf(size.y, size.z)))
		var d := span * 1.55 + 0.35
		model.rotation_degrees = Vector3(0, -32, 0)
		await _settle(4)
		box = _aabb(model)
		centre = box.get_center()
		_aim_at(centre + Vector3(d * 0.62, d * 0.42, -d * 0.70), centre)
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
		var at := box.get_center()
		if box.size.length() < 0.05:
			at = _hand_anchor()
			if at == Vector3.INF:
				at = _survivor.global_position + Vector3(0, 1.0, 0)
			box = AABB(at, Vector3(0.5, 0.5, 0.5))
		var span := maxf(0.35, maxf(box.size.x, maxf(box.size.y, box.size.z)))
		var d := span * 1.45 + 0.30
		# Three-quarter view from the actor's right, above the weapon.
		_aim_at(at + _survivor.facing * (d * 0.5) + Vector3(d * 0.85, d * 0.45, 0.0), at)
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


# --- Pass 3: the eight swings ------------------------------------------------

func _capture_swings() -> void:
	for entry in SWINGS:
		var clip: StringName = entry["clip"]
		_survivor.equip_weapon(entry["weapon"])
		await _settle(4)
		var guard := 0
		while _survivor.melee.state() != MeleeCombat.State.IDLE and guard < 200:
			guard += 1
			await get_tree().physics_frame
		_survivor.facing = Vector3(0, 0, -1)
		# Each capture is the *opening* swing, so no combo scaling and no
		# cooldown gate from the previous shot: without this every second
		# swing is refused (the cooldown outlives the clip).
		_survivor.melee.set("_combo", 0)
		_survivor.melee.set("_combo_deadline", 0)
		_survivor.melee.set("_cooldown_left", 0.0)
		_survivor.stamina = Survivor.STAMINA_MAX
		var started: bool = _survivor.melee_attack(entry["aim"], entry["heavy"])
		if not started:
			print("[MeleeCapture] %s MISMATCH: swing refused" % clip)
			continue
		# Step to the strike frame, then hold still for the shot.
		var waited := 0
		while _survivor.melee.phase() == "WINDUP" and waited < 400:
			waited += 1
			await get_tree().physics_frame
		var got := _survivor.melee.current_clip()
		var verdict := "PASS" if got == clip else "MISMATCH"
		var hand_now := _hand_anchor()
		print("[MeleeCapture] %s -> %s %s phase=%s hand_y=%.3f" % [
			clip, got, verdict, _survivor.melee.phase(),
			hand_now.y if hand_now != Vector3.INF else -99.0])
		# Ground truth: a bone ORIGIN never moves when its own track rotates it,
		# so the only honest check is the bone's rotation plus where the weapon
		# sits. Sample the whole clip for one swing.
		if str(clip) == "Chop":
			var skel_t: Skeleton3D = _survivor.get("_skeleton")
			var loc: Node = _survivor.get("_locomotion")
			var ap: AnimationPlayer = null if loc == null else loc.get("anim_player")
			var at_node: AnimationTree = null if loc == null else loc.get("anim_tree")
			var bi := skel_t.find_bone("r_upper_arm")
			for k in 8:
				var b: Basis = skel_t.get_bone_global_pose(bi).basis
				print("[MeleeCapture] trace k=%d anim=%s playing=%s tree=%s arm_euler=%s grip_y=%.3f" % [
					k,
					"null" if ap == null else ap.current_animation,
					"null" if ap == null else str(ap.is_playing()),
					"null" if at_node == null else str(at_node.active),
					str(b.get_euler() * 57.2958),
					_hand_anchor().y if _hand_anchor() != Vector3.INF else -99.0])
				await get_tree().physics_frame
		await get_tree().physics_frame
		var hand := _hand_anchor()
		# Keep the actor on its mark so side/front framing stays comparable
		# across all eight swings.
		_survivor.global_position = Vector3(0, 0.6, 0)
		var at := _survivor.global_position + Vector3(0, 1.05, 0)
		# Side view: the plane every swing reads in.
		_aim_at(at + Vector3(2.75, 0.70, 0.45), at + Vector3(0, 0.05, -0.30))
		await _snap("%02d_swing_%s_side.png" % [_step + 1, clip])
		# Front-ish view on the side the actor is aiming at, so the arc reads
		# against the body instead of from behind it.
		_aim_at(at - _survivor.facing * 2.45 + Vector3(0.85, 0.75, 0.0), at + Vector3(0, 0.05, -0.25))
		await _snap("%02d_swing_%s_front.png" % [_step + 1, clip])
		# Framing must be measurable, not eyeballed: project head + feet so a
		# bad shot is a number in the log, not a guess.
		var head := _survivor.global_position + Vector3(0, 1.62, 0)
		var feet := _survivor.global_position
		print("[MeleeCapture] %s framing head=%s feet=%s behind=%s dist=%.2f" % [
			clip, _cam.unproject_position(head), _cam.unproject_position(feet),
			str(_cam.is_position_behind(head)),
			_cam.global_position.distance_to(_survivor.global_position)])
		if hand != Vector3.INF and hand == Vector3.ZERO:
			print("[MeleeCapture] %s hand anchor degenerate" % clip)
		# Let the clip finish before re-arming.
		guard = 0
		while _survivor.melee.state() != MeleeCombat.State.IDLE and guard < 400:
			guard += 1
			await get_tree().physics_frame
		await _settle(4)
