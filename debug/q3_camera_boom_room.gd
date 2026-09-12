extends Node
## Focused, city-free measurement of the interior boom.
##
## The player report this guards: "when inside the building, the camera keeps
## closing in and out suddenly without reason."
##
## Why a synthetic room instead of the city: the city run costs minutes per
## capture and its geometry moves between seeds, so a clamp cannot be A/B'd.
## Here the room is built to the SAME convention the world builder uses (walls
## INSIDE the footprint, inner face one wall thickness from the boundary, the
## neighbour's wall beyond the shared boundary plane), the rig is dropped into
## it, and the view is swept a full turn. Then the only question left is which
## body stopped the boom:
##
##   own_clamp   the boom was pulled in by the room the player is STANDING IN -
##               geometry the interior presentation cuts away for the camera, so
##               the step in lens distance has no visible cause. This is the bug.
##   other_clamp the boom was pulled in by something else (here: the neighbour
##               across the party wall) - real, visible occlusion. Reported, not
##               failed: every third-person camera does this.
##
## RB_CAM_SHELL_OFF=1 replays the pre-fix rule for an A/B, so the test is
## falsifiable in the direction that matters: it must fail without the fix.
##
## Run: python tools/run_suite.py --q3boomroom 240
##      RB_BOOMROOM_DIAG=1 prints one line per clamped pose.
##      RB_BOOMROOM_SELFTEST=1 proves the room's colliders are raycastable first.

const BASE := Vector3(4000.0, 300.0, 4000.0)  # far from anything generated
const ROOM_HALF := 4.0            # footprint half-span, inner space is smaller
const WALL_T := 0.3               # building_builder.gd's wall thickness band
const CEIL_Y := 3.2               # storey height used by the probe
const SLAB_T := 0.4
const SETTLE_FRAMES := 60         # frames per pose: let the interior blend land
const FIXED_DT := 1.0 / 60.0
const SWEEP_STEP_DEG := 3.0
const TAU := 6.283185307179586
const HUG_INNER_M := 0.4          # capsule-radius-ish standoff from the wall face

var _world_root: Node3D
var failures := 0


func _ready() -> void:
	_world_root = Node3D.new()
	_world_root.name = "BoomRoom"
	add_child(_world_root)
	_build_room()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if OS.get_environment("RB_BOOMROOM_SELFTEST") != "":
		_selftest()
	# The wall's inner face sits WALL_T inside the boundary; stand against it.
	var inner := ROOM_HALF - WALL_T
	# RB_BOOMROOM_ONLY=hug|all narrows the sweep while iterating.
	var only := OS.get_environment("RB_BOOMROOM_ONLY")
	await _run_station("wall-hug", Vector3(-inner + HUG_INNER_M, 0.0, 0.0))
	if only == "" or only == "all":
		await _run_station("mid-room", Vector3(0.0, 0.0, 0.0))
		await _run_station("open-floor", Vector3(inner - 2.2, 0.0, -1.5))
		await _run_station("wall-hug-back", Vector3(-inner + HUG_INNER_M * 0.5, 0.0, 0.0))
	print("[BoomRoom] finished with %d failure(s)%s" % [
			failures, " (legacy rule: RB_CAM_SHELL_OFF=1)" \
					if OS.get_environment("RB_CAM_SHELL_OFF") == "1" else ""])
	get_tree().quit(0 if failures == 0 else 1)


## RB_BOOMROOM_SELFTEST=1: prove the room's colliders are actually visible to a
## raycast before blaming the rig for not clamping to them.
func _selftest() -> void:
	var space: PhysicsDirectSpaceState3D = _world_root.get_world_3d().direct_space_state
	print("[BoomRoomSelf] children=%d space=%s" % [_world_root.get_child_count(),
			str(space != null)])
	var origin := BASE + Vector3(0.0, 1.05, 0.0)
	var names: Array[String] = ["ceiling", "wall-x", "floor", "neighbour"]
	var dirs: Array[Vector3] = [Vector3(0, 1, 0), Vector3(-1, 0, 0),
			Vector3(0, -1, 0), Vector3(-1, 0.2, 0)]
	for i in range(names.size()):
		var label: String = names[i]
		var dir: Vector3 = dirs[i]
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 20.0)
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit: Dictionary = space.intersect_ray(q)
		print("[BoomRoomSelf] %s hit=%s owner=%s d=%.2f n_y=%.2f" % [label,
				str(not hit.is_empty()), _owner_of(hit),
				origin.distance_to(hit["position"]) if not hit.is_empty() else -1.0,
				(hit["normal"] as Vector3).y if not hit.is_empty() else 0.0])


## One static box: the room is only ever colliders (nothing here is rendered).
## `owner` is the probe's own stand-in for the world's src_layer/vox_tag metas:
## it is what lets a clamp be attributed to the room or to the neighbour.
func _box(centre: Vector3, size: Vector3, owner: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	# The room lives at BASE, far from anything the world may have generated:
	# this probe measures the rig, not the city.
	shape.position = BASE + centre
	shape.set_meta("boom_owner", owner)
	body.add_child(shape)
	_world_root.add_child(body)
	return body


func _owner_of(hit: Dictionary) -> String:
	if hit.is_empty():
		return "-"
	var collider: Variant = hit.get("collider")
	if collider is Node3D:
		for child in (collider as Node3D).get_children():
			if child.has_meta("boom_owner"):
				return str(child.get_meta("boom_owner"))
	return str(collider)


## The room the player stands in, and the neighbour sharing its -X party wall.
## Wall placement mirrors the world builder: the wall box spans the boundary
## inwards, so its INNER face is WALL_T inside the footprint and the walkable
## space is the smaller of the two. The neighbour is the same on the far side of
## the shared boundary, which is why its face is NOT part of the player's room.
func _build_room() -> void:
	var span := ROOM_HALF * 2.0
	_box(Vector3(0.0, -SLAB_T * 0.5, 0.0), Vector3(span, SLAB_T, span), "room")
	_box(Vector3(0.0, CEIL_Y + SLAB_T * 0.5, 0.0), Vector3(span, SLAB_T, span), "room")
	for sign_x in [-1.0, 1.0]:
		_box(Vector3(sign_x * (ROOM_HALF - WALL_T * 0.5), CEIL_Y * 0.5, 0.0),
				Vector3(WALL_T, CEIL_Y, span), "room")
	for sign_z in [-1.0, 1.0]:
		_box(Vector3(0.0, CEIL_Y * 0.5, sign_z * (ROOM_HALF - WALL_T * 0.5)),
				Vector3(span, CEIL_Y, WALL_T), "room")
	# Neighbour across -X: its wall's inner face is WALL_T beyond the boundary.
	_box(Vector3(-ROOM_HALF - (6.0 - WALL_T) * 0.5, CEIL_Y * 0.5, 0.0),
			Vector3(6.0, CEIL_Y, 6.0), "neighbour")


func _run_station(name: String, local: Vector3) -> void:
	var player := Node3D.new()
	player.position = BASE + local
	_world_root.add_child(player)
	var rig: Node3D = load("res://camera/follow_camera.gd").new()
	_world_root.add_child(rig)
	await get_tree().physics_frame
	rig.call("set_target", player)
	rig.call("set_interior", true)
	rig.set("_presentation_distance", rig.get("_user_distance"))
	rig.call("set_interior_shell",
			Rect2(Vector2(BASE.x - ROOM_HALF, BASE.z - ROOM_HALF),
					Vector2(ROOM_HALF * 2.0, ROOM_HALF * 2.0)), 0.0,
			Vector2(BASE.y - 1.0, BASE.y + CEIL_Y + 1.0))
	# Settle ONE pose first: interior mode blends the presentation length in
	# (PRESENT_SPEED), so "want" is only final once the blend has converged.
	rig.set("_yaw", 0.0)
	for _s in range(SETTLE_FRAMES):
		rig.call("_process", FIXED_DT)
	# Free length for this station: the boom the presentation WANTS, read after
	# the interior blend has landed (comparing against a half-blended value
	# would mark every pose as clamped).
	var want: float = rig.call("_wanted_boom_length")
	var clamp_tol := 0.2
	var raws: Array[float] = []
	var rendereds: Array[float] = []
	var thetas: Array[float] = []
	var boom_min := INF
	var boom_max := -INF
	var rendered_min := INF
	var rendered_max := -INF
	var poses := 0
	var theta := 0.0
	while theta < TAU:
		rig.set("_yaw", theta)
		for _i in range(SETTLE_FRAMES):
			rig.call("_process", FIXED_DT)
		var raw: float = rig.call("_resolve_boom_length")
		var rendered: float = rig.get("_boom")
		raws.append(raw)
		rendereds.append(rendered)
		thetas.append(theta)
		boom_min = minf(boom_min, raw)
		boom_max = maxf(boom_max, raw)
		rendered_min = minf(rendered_min, rendered)
		rendered_max = maxf(rendered_max, rendered)
		poses += 1
		theta += deg_to_rad(SWEEP_STEP_DEG)
	# Attribute, per pose, what stopped the boom. A pose counts as clamped when
	# its resolved length is shorter than the station's free length - measured
	# against the sweep's own maximum, not against a half-blended want.
	var own_clamp := 0
	var other_clamp := 0
	for i in range(raws.size()):
		if float(raws[i]) > boom_max - clamp_tol:
			continue
		rig.set("_yaw", float(thetas[i]))
		for _k in range(6):
			rig.call("_process", FIXED_DT)
		var face := _first_face(rig, boom_max)
		if str(face["owner"]) == "room":
			own_clamp += 1
		else:
			other_clamp += 1
		if OS.get_environment("RB_BOOMROOM_DIAG") != "":
			_diag(float(thetas[i]), float(raws[i]), boom_max, face)
	print("[BoomRoom] station=%s poses=%d want=%.2f free=%.2f raw_min=%.2f raw_max=%.2f rendered_range=%.2f own_clamp=%d other_clamp=%d" % [
			name, poses, want, boom_max, boom_min, boom_max,
			rendered_max - rendered_min, own_clamp, other_clamp])
	if own_clamp > 0:
		failures += 1
		print("[BoomRoom] FAIL station=%s boom pulled in by the room the player is IN on %d poses - the cutaway hides that geometry, so the lens steps with no visible cause" % [
				name, own_clamp])
	if own_clamp > 0 and rendered_max - rendered_min > 0.5:
		print("[BoomRoom] INFO station=%s rendered boom moved %.2f m, all of it own-geometry: this is the reported pump" % [
				name, rendered_max - rendered_min])
	elif rendered_max - rendered_min > 0.5:
		print("[BoomRoom] INFO station=%s rendered boom moved %.2f m on real occlusion to the neighbour (expected, not the bug)" % [
				name, rendered_max - rendered_min])
	player.queue_free()
	rig.queue_free()
	await get_tree().physics_frame


## Walk the boom ray the same way the rig does and describe the first face that
## is NOT stepped over, so a clamp can be attributed to a body rather than
## guessed at from coordinates.
func _first_face(rig: Node3D, want: float) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _world_root.get_world_3d().direct_space_state
	var origin: Vector3 = rig.global_position + Vector3(0, 1.05, 0)
	var wdir: Vector3 = (rig.global_transform.basis \
			* rig.call("_boom_dir_local")).normalized()
	var from := origin
	for _step in range(6):
		var q := PhysicsRayQueryParameters3D.create(from, origin + wdir * (want + 0.45))
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return {"owner": "-", "d": -1.0, "n_y": 0.0, "in_shell": false}
		var hp: Vector3 = hit["position"]
		var ny := (hit["normal"] as Vector3).y
		var owner := _owner_of(hit)
		var in_shell := bool(rig.call("_hit_in_shell", hp, ny))
		# Mirror the rule actually in force (the rig's own _skippable honours
		# RB_CAM_SHELL_OFF), so the face reported here is the one the rig
		# really stopped on - otherwise the A/B attributes its clamps to the
		# wrong body and the comparison is worthless.
		if bool(rig.call("_skippable", hit, hp)):
			from = hp + wdir * 0.04
			continue
		return {"owner": owner, "d": origin.distance_to(hp), "n_y": ny,
				"in_shell": in_shell}
	return {"owner": "shell-only", "d": -2.0, "n_y": 0.0, "in_shell": true}


func _diag(theta: float, raw: float, want: float, face: Dictionary) -> void:
	print("[BoomRoomDiag] yaw=%.1f boom=%.2f want=%.2f owner=%s d=%.2f n_y=%.2f in_shell=%s" % [
			rad_to_deg(theta), raw, want, str(face["owner"]), float(face["d"]),
			float(face["n_y"]), str(face["in_shell"])])
