extends Node
## Interior follow-camera flutter probe (frontend, player-perceived).
##
## User report: "when inside the building, the camera keeps closing in and out
## suddenly without reason."
##
## The rig (camera/follow_camera.gd) is a 6-26 m boom from the player's chest.
## Inside a city building the boom aims up and back, so its ray meets the
## storey slab above the player - geometry the interior cutaway hides - and the
## old rule excused a hit because of the hit's NORMAL ("downward-facing =
## the ceiling, ignore it"). In a real room the first hit flips between that
## slab and a partition / stair/ lintel / neighbour wall the same ray clips, so
## the clamp alternated between MIN_COLLIDE_DISTANCE (lens collapsed onto the
## player) and the full interior presentation: the camera pumping in and out
## while the player just walks.
##
## This probe stands the REAL FollowCamera rig in REAL generated city rooms and
## drives it with a FIXED timestep (reproducible, frame-rate independent).
## Every frame it also casts its OWN ray from chest to the wanted lens position
## - the reading the rig is supposed to satisfy - and records, per frame:
##   hit/normal/blocked_m   what the ray met, and how far away
##   in_shell               whether that hit is inside the building the player
##                          is in (only that geometry is cut away for the
##                          camera; only that geometry may be passed through)
##   leak                   hit is downward-facing (the OLD excuse) but is NOT
##                          in the shell - the case that used to collapse the
##                          boom for no reason
##
## Probes 1-3 walk a real room, probe 4 stands still and swings the camera 360,
## probe 5 walks the street outside the same building (mode is exterior there:
## an unobstructed boom must not lurch).
##
## Run it twice:
##   RB_TAG=flutter_before python tools/run_suite.py --q3intecamflutter 300
##   RB_TAG=flutter_after  python tools/run_suite.py --q3intecamflutter 300

const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")
const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
const FollowCameraScript = preload("res://camera/follow_camera.gd")

const OUT_DIR := "res://.hermes/autopilot/reports/q3-camera-interior"
const FIXED_DT := 1.0 / 60.0
const FLUTTER_M := 0.75            # one-frame boom change that reads as a lurch
const WARMUP_FRAMES := 120         # settle the interior presentation first
const WALK_FRAMES := 180           # 3 s of walking
const TURN_FRAMES := 150           # 2.5 s of camera rotation
const STREET_FRAMES := 180
## Ray geometry mirrors follow_camera.gd (the probe must judge the same ray the
## rig clamps along, not a different one).
const CHEST_H := 1.05
const COLLIDE_ORIGIN_H := 1.05
const COLLIDE_MARGIN := 0.45
const MIN_DIST := 6.0
const MAX_DIST := 26.0
const MIN_COLLIDE_DISTANCE := 1.8   # follow_camera.gd's floor for the lens
const SHELL_MAX_SKIP := 4           # in-shell faces the rig walks past
const INSET_M := 0.02               # follow_camera.gd's SHELL_INSET_M
const WALL_NORMAL_Y := 0.5          # follow_camera.gd's SHELL_WALL_NORMAL_Y
const DOWN_NORMAL_Y := -0.35       # follow_camera.gd's "downward-facing" test
const MIN_FLOORS := 3
const ROOM_PROBES := 3
const STREET_STANDOFF_M := 3.2     # player walking the pavement outside
const STREET_LENGTH_M := 7.0
const DOOR_INSIDE_START_M := 0.9   # just inside the threshold, as you walk in
const DOOR_INSIDE_END_M := 5.0     # ...and by the time you are in the room
const WALL_HUG_M := 0.9            # standing this close to a facade, inside
const WALL_TANGENT_OFFSET_M := 2.6 # along the facade, away from the opening

var failures := 0
var output := OUT_DIR
var _holder: Node3D = null
var _built := {}
var _gate_tag := ""
var _was_inside := false
var _ground_cache := {}


func _ready() -> void:
	run()


## Result lines go to stdout AND to a file in the report directory: a concurrent
## autopilot suite can clobber tools/out_*.txt, and a process killed by its
## timeout loses buffered stdout, but an appended + flushed file survives both.
var _log: FileAccess = null


func _record(line: String) -> void:
	print(line)
	if _log == null:
		return
	_log.store_line(line)
	_log.flush()


func run() -> void:
	output = "%s/%s" % [OUT_DIR, OS.get_environment("RB_TAG")]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_log = FileAccess.open("%s/probe.txt" % output, FileAccess.WRITE)
	_setup_light()
	var seed_value := WorldSeed.get_world_seed()
	var plan := CityPlan.new(seed_value)
	var world := WorldPlan.new(seed_value)
	_holder = Node3D.new()
	_holder.name = "IntFlutterWorld"
	add_child(_holder)
	print("[IntFlutter] seed=%d tag=%s out=%s" % [
			seed_value, OS.get_environment("RB_TAG"), output])

	var rooms := _pick_rooms(plan)
	var used := mini(rooms.size(), ROOM_PROBES)
	# RB_INTFLUTTER_ONLY=walk|turn|door|street narrows the run while iterating.
	var only := OS.get_environment("RB_INTFLUTTER_ONLY")
	if only == "" or only == "walk":
		for i in range(used):
			await _interior_probe(plan, world, rooms[i], i + 1, "walk")
	if used > 0:
		if only == "" or only == "turn":
			await _interior_probe(plan, world, rooms[0], used + 1, "turn")
		if only == "" or only == "door":
			await _interior_probe(plan, world, rooms[0], used + 2, "door")
		if only == "" or only == "wall":
			await _interior_probe(plan, world, rooms[0], used + 3, "wall")
		if only == "" or only == "street":
			await _street_probe(plan, world, rooms[0], 90)
	_record("[IntFlutter] finished probes=%d failures=%d output=%s" % [
			used + 4, failures, output])
	get_tree().quit(0 if failures == 0 else 1)


## Deterministic room picks: multi-storey city buildings near the core, biggest
## footprint first (a big footprint has real partitions to walk between).
func _pick_rooms(plan: CityPlan) -> Array:
	var out: Array = []
	for spec: Dictionary in plan.city_buildings():
		if int(spec.get("floors", 1)) < MIN_FLOORS:
			continue
		var fp: Rect2 = spec["rect"]
		out.append({"spec": spec, "area": fp.size.x * fp.size.y,
				"d": fp.get_center().length()})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["d"]) - float(b["d"])) > 60.0:
			return float(a["d"]) < float(b["d"])
		return float(a["area"]) > float(b["area"]))
	return out


## Walk a straight line across a real room, walk in through its own doorway,
## stand hugging a wall and sweep the camera, or stand still and swing it.
## `kind` is "walk" | "door" | "wall" | "turn".
func _interior_probe(plan: CityPlan, world: WorldPlan, entry: Dictionary,
		index: int, kind: String) -> void:
	# "turn" and "wall" sweep the camera; "walk" and "door" translate it.
	var sweeping := kind == "turn" or kind == "wall"
	var spec: Dictionary = entry["spec"]
	var grounded: Dictionary = ChunkBuilderScript._grounded_spec(spec, world)
	var fp: Rect2 = grounded["rect"]
	var yaw := float(grounded.get("yaw", 0.0))
	var gy := _ground_y(grounded)
	var centre := fp.get_center()
	await _build_ring(plan, world, _owner_chunk(spec, centre))

	# Walk the room's LONG axis, both ends kept clear of the wall band so the
	# player really is inside for the whole run.
	var along := Vector2(1, 0) if fp.size.x >= fp.size.y else Vector2(0, 1)
	var half := maxf((minf(fp.size.x, fp.size.y) * 0.5 - 1.0) * 0.5, 0.6)
	var start_world := CityPlan._rotate_plan_point(centre, centre - along * half, yaw)
	var end_world := CityPlan._rotate_plan_point(centre, centre + along * half, yaw)
	var aim := atan2(end_world.x - start_world.x, end_world.y - start_world.y)
	if kind == "door" or kind == "wall":
		# Real entrance pose: the boom points back at the facade above the door,
		# which is the ray the player actually lives with indoors.
		var edge := int(grounded.get("door_edge", 0))
		var door_local := fp.position + BuildingBuilder._access_door_local(
				fp.size.x, fp.size.y, edge)
		var door := CityPlan._rotate_plan_point(centre, door_local, yaw)
		# _access_outward points out of the building; walk the other way.
		var inward := -CityPlan._rotate_plan_vector(
				BuildingBuilder._access_outward(edge), yaw).normalized()
		if kind == "wall":
			# HUGGING the wall: 0.9 m inside it, a couple of metres along from
			# the door so the boom lands on solid facade rather than the
			# opening, camera sweeping as the player turns on the spot.
			var tangent := Vector2(1, 0) if (edge == 0 or edge == 2) else Vector2(0, 1)
			var span: float = fp.size.x if (edge == 0 or edge == 2) else fp.size.y
			var off := clampf(WALL_TANGENT_OFFSET_M, 0.0, maxf(span * 0.5 - 1.4, 0.0))
			start_world = door + CityPlan._rotate_plan_vector(tangent, yaw).normalized() * off \
					+ inward * WALL_HUG_M
			end_world = start_world
			aim = 0.0
			print("[IntFlutter] wall id=%s edge=%d fp=%s yaw=%.3f gy=%.2f station=%s inward=%s off=%.2f" % [
				str(spec.get("id", "?")), edge, str(fp), yaw, gy,
				str(start_world), str(inward), off])
		else:
			var depth: float = fp.size.y if (edge == 0 or edge == 2) else fp.size.x
			var run := clampf(DOOR_INSIDE_END_M,
					DOOR_INSIDE_START_M + 0.6, maxf(depth - 1.2, DOOR_INSIDE_START_M + 0.6))
			start_world = door + inward * DOOR_INSIDE_START_M
			end_world = door + inward * run
			aim = atan2(inward.x, inward.y)
			print("[IntFlutter] door id=%s edge=%d fp=%s yaw=%.3f gy=%.2f door=%s inward=%s run=%.2f" % [
				str(spec.get("id", "?")), edge, str(fp), yaw, gy, str(door),
				str(inward), run])
	elif sweeping:
		end_world = start_world
		aim = 0.0
	var base := Vector3(start_world.x, gy + 0.05, start_world.y)
	var frames := TURN_FRAMES if sweeping else WALK_FRAMES
	var shell := CityInteriorState.shell_of(grounded)
	var nav := _make_rig(base, aim, index)
	var dummy: Node3D = nav["dummy"]
	var rig: Node3D = nav["rig"]
	var stepper := func(f: int) -> bool:
		if sweeping:
			dummy.global_position = base
			rig.set("_yaw", TAU * float(f) / float(maxi(TURN_FRAMES - 1, 1)))
		else:
			var t := float(f) / float(maxi(frames - 1, 1))
			dummy.global_position = Vector3(lerpf(start_world.x, end_world.x, t),
					base.y, lerpf(start_world.y, end_world.y, t))
		return _apply_interior(rig, plan, world, dummy.global_position)
	# Warm up so the interior presentation has settled before recording.
	for _f in range(WARMUP_FRAMES):
		_apply_interior(rig, plan, world, dummy.global_position)
		if sweeping:
			rig.set("_yaw", 0.0)
		rig.call("_process", FIXED_DT)
	if OS.get_environment("RB_INTFLUTTER_DIAG") != "":
		_diag_shell(rig, shell)
	var m := await _measure(rig, frames, stepper, true, shell)
	var stats := _stats(m)
	_record("[IntFlutter] probe=%d kind=%s id=%s floors=%d frames=%d inside=%.2f boom_min=%.2f boom_max=%.2f range=%.2f lurks=%d lurk_hidden=%d reversals=%d closed_clear=%d hidden_clamp=%d hidden_flat=%d over_clamp=%d vis_clamp=%d lens_visible=%d" % [
			index, kind, str(spec.get("id", "?")), int(spec.get("floors", 1)), frames,
			float(m["inside"]) / float(frames), stats["min"], stats["max"],
			stats["max"] - stats["min"], int(stats["lurks"]),
			int(stats["lurk_hidden"]), int(stats["reversals"]), int(m["closed_clear"]),
			int(m["hidden_clamp"]), int(m["hidden_flat"]), int(m["over_clamp"]),
			int(m["visible_clamp"]), int(m["lens_visible"])])
	# Player-facing contract: while inside, the boom may only be shortened by
	# geometry the player CAN SEE, it must not pump, and the lens must never sit
	# inside visible geometry.
	if int(m["hidden_clamp"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom pulled in by hidden geometry on %d frames (flat in-shell hit on %d)" % [
			index, int(m["hidden_clamp"]), int(m["hidden_flat"])])
	if int(m["over_clamp"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom shorter than the visible face requires on %d frames (in-shell face still bit)" % [
			index, int(m["over_clamp"])])
	if int(stats["lurk_hidden"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom jumped > %.2f m with only hidden geometry near it, %d times" % [
			index, FLUTTER_M, int(stats["lurk_hidden"])])
	if int(m["closed_clear"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom closed in with a clear path on %d frames" % [
			index, int(m["closed_clear"])])
	if int(stats["reversals"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom pumps in/out %d times while indoors" % [
			index, int(stats["reversals"])])
	if int(stats["lurks"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d boom jumps > %.2f m in one frame %d times" % [
			index, FLUTTER_M, int(stats["lurks"])])
	if int(m["lens_visible"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d lens inside visible geometry on %d frames" % [
			index, int(m["lens_visible"])])
	_teardown(nav)


## Outside control: walk the pavement past the same building. The mode is
## exterior here, so a clear boom must not lurch at all.
func _street_probe(plan: CityPlan, world: WorldPlan, entry: Dictionary,
		index: int) -> void:
	var grounded: Dictionary = ChunkBuilderScript._grounded_spec(entry["spec"], world)
	var fp: Rect2 = grounded["rect"]
	var yaw := float(grounded.get("yaw", 0.0))
	var gy := _ground_y(grounded)
	var centre := fp.get_center()
	var edge := int(grounded.get("door_edge", 0))
	var local := BuildingBuilder._access_door_local(fp.size.x, fp.size.y, edge)
	var outward := CityPlan._rotate_plan_vector(
			BuildingBuilder._access_outward(edge), yaw).normalized()
	var door := CityPlan._rotate_plan_point(centre, fp.position + local, yaw)
	var along := Vector2(-outward.y, outward.x)
	var start := door + outward * STREET_STANDOFF_M - along * (STREET_LENGTH_M * 0.5)
	var end := start + along * STREET_LENGTH_M
	var base := Vector3(start.x, gy + 0.05, start.y)
	var nav := _make_rig(base, atan2(outward.x, outward.y), index)
	var dummy: Node3D = nav["dummy"]
	var rig: Node3D = nav["rig"]
	var stepper := func(f: int) -> bool:
		var t := float(f) / float(maxi(STREET_FRAMES - 1, 1))
		dummy.global_position = Vector3(lerpf(start.x, end.x, t), base.y,
				lerpf(start.y, end.y, t))
		rig.call("set_interior", false)
		return false
	for _f in range(WARMUP_FRAMES):
		rig.call("set_interior", false)
		rig.call("_process", FIXED_DT)
	var shell := CityInteriorState.shell_of(grounded)
	var m := await _measure(rig, STREET_FRAMES, stepper, false, shell)
	var stats := _stats(m)
	_record("[IntFlutter] probe=%d kind=street id=%s frames=%d boom_min=%.2f boom_max=%.2f range=%.2f lurks=%d lurch_clear=%d lurk_hidden=%d reversals=%d closed_clear=%d lens_visible=%d" % [
		index, str(entry["spec"].get("id", "?")), STREET_FRAMES, stats["min"],
		stats["max"], stats["max"] - stats["min"], int(stats["lurks"]),
		int(stats["lurch_clear"]), int(stats["lurk_hidden"]),
		int(stats["reversals"]), int(m["closed_clear"]), int(m["lens_visible"])])
	if int(stats["lurch_clear"]) > 0 or int(m["closed_clear"]) > 0 \
			or int(stats["lurk_hidden"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d exterior boom moved with a clear path: lurch=%d hidden=%d closed=%d" % [
			index, int(stats["lurch_clear"]), int(stats["lurk_hidden"]),
			int(m["closed_clear"])])
	if int(m["lens_visible"]) > 0:
		failures += 1
		print("[IntFlutter] FAIL probe=%d lens inside visible geometry on %d frames" % [
			index, int(m["lens_visible"])])
	_teardown(nav)


## Drives the rig with a fixed timestep and records, per frame, the boom the rig
## rendered plus an INDEPENDENT reading of the ray it is supposed to satisfy.
## The reading walks the ray past the player's OWN (camera-hidden) shell the same
## way the rig walks it, so the counters below judge what the PLAYER sees:
##   hidden_clamp  nothing the player can see is in the way, yet the boom is
##                 short of the presentation length - "closing in with no reason"
##   hidden_flat   the same, and the blocking face is NOT downward-facing: the
##                 exact pose the old normal test failed to excuse
##   over_clamp    a visible face is in the way, but the boom is shorter than that
##                 face requires - an in-shell face still bit
##   lens_visible  the boom left the lens inside geometry the player CAN see
func _measure(rig: Node3D, frames: int, stepper: Callable, interior: bool,
		shell: Dictionary) -> Dictionary:
	var booms := PackedFloat32Array()
	var clear := []
	var hidden := []
	var modes := []
	var hidden_clamp := 0
	var hidden_flat := 0
	var over_clamp := 0
	var visible_clamp := 0
	var lens_visible := 0
	var inside := 0
	var closed_clear := 0
	for f in range(frames):
		var mode: bool = stepper.call(f)
		rig.call("_process", FIXED_DT)
		var boom := float(rig.get("_boom"))
		var want := clampf(float(rig.get("_presentation_distance")), MIN_DIST, MAX_DIST)
		var probe := _line_of_sight(rig, shell)
		var vis := float(probe["vis_m"])
		var was_clear := vis > want + COLLIDE_MARGIN
		booms.append(boom)
		clear.append(was_clear)
		hidden.append(was_clear)
		modes.append(mode)
		if mode:
			inside += 1
		if not bool(probe["raw_hit"]) and boom < want - 0.5:
			closed_clear += 1
		if was_clear:
			if boom < want - 0.5:
				hidden_clamp += 1
				if float(probe["raw_normal_y"]) >= DOWN_NORMAL_Y:
					hidden_flat += 1
		else:
			visible_clamp += 1
			var expected := clampf(vis - COLLIDE_MARGIN, MIN_COLLIDE_DISTANCE, want)
			if boom < expected - 0.5:
				over_clamp += 1
			elif boom > expected + 0.5:
				lens_visible += 1
	return {"booms": booms, "clear": clear, "hidden": hidden, "modes": modes,
			"hidden_clamp": hidden_clamp, "hidden_flat": hidden_flat,
			"over_clamp": over_clamp, "visible_clamp": visible_clamp,
			"lens_visible": lens_visible, "inside": inside,
			"closed_clear": closed_clear}


func _stats(m: Dictionary) -> Dictionary:
	var booms: PackedFloat32Array = m["booms"]
	var clear: Array = m["clear"]
	var hidden: Array = m["hidden"]
	var modes: Array = m["modes"]
	var out := {"min": 0.0, "max": 0.0, "lurks": 0, "lurch_clear": 0,
			"lurk_hidden": 0, "reversals": 0, "travel": 0.0}
	if booms.is_empty():
		return out
	out["min"] = booms[0]
	out["max"] = booms[0]
	for b in booms:
		out["min"] = minf(out["min"], b)
		out["max"] = maxf(out["max"], b)
	var prev_sign := 0
	for i in range(1, booms.size()):
		var step := booms[i] - booms[i - 1]
		out["travel"] = float(out["travel"]) + absf(step)
		# A frame where the mode itself flipped (the player crossed the
		# threshold) legitimately re-aims the boom: not a flutter.
		if bool(modes[i]) != bool(modes[i - 1]):
			prev_sign = 0
			continue
		if absf(step) > FLUTTER_M:
			out["lurks"] = int(out["lurks"]) + 1
			if bool(clear[i]) and bool(clear[i - 1]):
				out["lurch_clear"] = int(out["lurch_clear"]) + 1
			elif bool(hidden[i]) and bool(hidden[i - 1]):
				out["lurk_hidden"] = int(out["lurk_hidden"]) + 1
		if absf(step) > FLUTTER_M * 0.5:
			var sign_now := 1 if step > 0.0 else -1
			if prev_sign != 0 and sign_now != prev_sign:
				out["reversals"] = int(out["reversals"]) + 1
			prev_sign = sign_now
	return out


## The ray the rig is meant to satisfy, cast independently from the chest toward
## the wanted lens position and walked past faces of the player's OWN shell, the
## same way the rig walks them. `vis_m` is the first face the player can actually
## SEE (INF when nothing visible is in the way); raw_* describe the first face
## regardless, for attribution.
func _line_of_sight(rig: Node3D, shell: Dictionary) -> Dictionary:
	var want := clampf(float(rig.get("_presentation_distance")), MIN_DIST, MAX_DIST)
	var pitch := float(rig.get("_pitch"))
	var dir: Vector3 = (rig.global_transform.basis * Vector3(0, 0, 1).rotated(
			Vector3.RIGHT, deg_to_rad(pitch))).normalized()
	var origin := rig.global_position + Vector3(0, COLLIDE_ORIGIN_H, 0)
	var space := _holder.get_world_3d().direct_space_state
	var reach := want + COLLIDE_MARGIN
	var from := origin
	var out := {"raw_hit": false, "raw_normal_y": 0.0, "raw_in_shell": false,
			"vis_m": INF}
	for _i in range(SHELL_MAX_SKIP + 2):
		var q := PhysicsRayQueryParameters3D.create(from, origin + dir * reach)
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		var pos: Vector3 = hit["position"]
		var d := origin.distance_to(pos)
		var in_shell := _in_shell(pos, shell, (hit["normal"] as Vector3).y)
		if not bool(out["raw_hit"]):
			out["raw_hit"] = true
			out["raw_normal_y"] = float((hit["normal"] as Vector3).y)
			out["raw_in_shell"] = in_shell
		if not in_shell:
			out["vis_m"] = d
			break
		from = pos + dir * 0.04
	return out


## Is a world point inside the building the player is in (its footprint, from
## the foundation to the top of its parapet)? Only this geometry is hidden from
## the camera by the cutaway, so only this geometry may be passed through.
## A VERTICAL face on the boundary is the party wall shared with the neighbour
## (not cut away, so not in-shell); a FLAT one is the room's own ceiling corner
## (in-shell). Mirrors follow_camera.gd's `_hit_in_shell`.
func _in_shell(p: Vector3, shell: Dictionary, normal_y: float) -> bool:
	if shell.is_empty():
		return false
	var rect: Rect2 = shell["rect"]
	var band: Vector2 = shell["y"]
	if p.y < band.x or p.y > band.y:
		return false
	var local := CityPlan._rotate_plan_point(rect.get_center(),
			Vector2(p.x, p.z), -float(shell["yaw"]))
	var inset := INSET_M if absf(normal_y) < WALL_NORMAL_Y else 0.0
	return rect.grow(-inset).has_point(local)


## Diagnostic (RB_INTFLUTTER_DIAG): stand on the station and sweep the camera,
## settling the rig at each pose, then walk the boom ray face by face. Prints the
## rig's own boom next to the first face it RAWS on and the first face the player
## can actually SEE (first hit outside the player's own shell), so a clamp can be
## attributed instead of guessed at.
func _diag_shell(rig: Node3D, shell: Dictionary) -> void:
	print("[IntFlutterDiag] rig_interior=%s shell_rect=%s yaw=%.3f band=%s want=%.2f" % [
			str(rig.get("_interior")), str(rig.get("_shell_rect")),
			float(rig.get("_shell_yaw")), str(rig.get("_shell_y")),
			clampf(float(rig.get("_presentation_distance")), MIN_DIST, MAX_DIST)])
	for i in range(8):
		var yaw := TAU * float(i) / 8.0
		for _k in range(40):
			rig.set("_yaw", yaw)
			rig.call("_process", FIXED_DT)
		var faces := _ray_faces(rig, shell, 5)
		var raw := "none"
		if not faces.is_empty():
			raw = "d=%.2f n_y=%.2f in_shell=%s" % [faces[0]["d"], faces[0]["n_y"],
					str(faces[0]["in_shell"])]
		var vis := "none"
		for face: Dictionary in faces:
			if not bool(face["in_shell"]):
				vis = "d=%.2f n_y=%.2f" % [face["d"], face["n_y"]]
				break
		print("[IntFlutterDiag] pose yaw=%.3f boom=%.2f | raw %s | visible %s" % [
				yaw, float(rig.get("_boom")), raw, vis])
	rig.set("_yaw", 0.0)


## Each face the ray meets, in order, with its distance, normal Y and whether it
## belongs to the player's own (camera-hidden) shell. Walks past in-shell faces
## the way the rig's own resolver does.
func _ray_faces(rig: Node3D, shell: Dictionary, limit: int) -> Array:
	var want := clampf(float(rig.get("_presentation_distance")), MIN_DIST, MAX_DIST)
	var pitch := float(rig.get("_pitch"))
	var dir: Vector3 = (rig.global_transform.basis * Vector3(0, 0, 1).rotated(
			Vector3.RIGHT, deg_to_rad(pitch))).normalized()
	var origin := rig.global_position + Vector3(0, COLLIDE_ORIGIN_H, 0)
	var space := _holder.get_world_3d().direct_space_state
	var out: Array = []
	var from := origin
	for _i in range(limit):
		var q := PhysicsRayQueryParameters3D.create(from, origin + dir * (want + COLLIDE_MARGIN))
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		var pos: Vector3 = hit["position"]
		out.append({"d": origin.distance_to(pos),
				"n_y": float((hit["normal"] as Vector3).y),
				"in_shell": _in_shell(pos, shell, (hit["normal"] as Vector3).y)})
		from = pos + dir * 0.04
	return out


func _make_rig(base: Vector3, aim: float, index: int) -> Dictionary:
	var dummy := Node3D.new()
	dummy.name = "IntTarget%d" % index
	add_child(dummy)
	dummy.global_position = base
	var rig: Node3D = FollowCameraScript.new()
	rig.name = "IntRig%d" % index
	add_child(rig)
	rig.set("target", dummy)
	rig.global_position = base
	rig.set("_yaw", aim)
	rig.set_process(false)          # stepped manually, fixed delta
	return {"dummy": dummy, "rig": rig}


func _teardown(nav: Dictionary) -> void:
	var rig: Node3D = nav["rig"]
	var dummy: Node3D = nav["dummy"]
	rig.set_process(false)
	rig.queue_free()
	dummy.queue_free()


## The real main.gd signal: same authority, same hysteresis, same shell.
func _apply_interior(rig: Node3D, plan: CityPlan, world: WorldPlan,
		p3: Vector3) -> bool:
	var state := CityInteriorState.evaluate(plan, world, p3, _was_inside,
			_gate_tag, _ground_cache)
	_was_inside = bool(state["inside"])
	var active := _was_inside and not (state["spec"] as Dictionary).is_empty()
	rig.call("set_interior", active)
	# The rig learns WHICH shell it may pass through. Guarded so the harness can
	# also measure a rig revision that predates the shell argument (baseline).
	if active and rig.has_method("set_interior_shell"):
		var shell := CityInteriorState.shell_of(state["spec"])
		rig.call("set_interior_shell", shell["rect"], float(shell["yaw"]), shell["y"])
	if active:
		_gate_tag = str((state["spec"] as Dictionary).get("id", ""))
	else:
		_gate_tag = ""
	return active


func _ground_y(grounded: Dictionary) -> float:
	return float(grounded.get("building_ground_y",
			grounded.get("ground_y", 0.0)))


func _owner_chunk(spec: Dictionary, centre: Vector2) -> Vector2i:
	return spec.get("owner_chunk",
			WorldSeed.chunk_coord(centre.x, centre.y))


func _build_ring(plan: CityPlan, world: WorldPlan, coord: Vector2i) -> void:
	for x in range(coord.x - 1, coord.x + 2):
		for z in range(coord.y - 1, coord.y + 2):
			var c := Vector2i(x, z)
			if _built.has(c):
				continue
			_built[c] = true
			TerrainChunkBuilder.materialize(_holder,
					TerrainChunkBuilder.build_manifest(world, c))
			var batcher: MeshBatcher = MeshBatcherScript.new()
			ChunkBuilderScript.fill_batcher(batcher, plan, c, world)
			# include_collision = true: the boom must collide with real walls.
			ChunkBuilderScript.build(_holder, plan, c, batcher, {}, true, true, world)
			await get_tree().process_frame


func _setup_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.light_energy = 1.15
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("81909e")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("d1d9e0")
	env.environment.ambient_light_energy = 0.7
	add_child(env)
