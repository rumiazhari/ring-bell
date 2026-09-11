extends Node
## Anti-abyss recovery harness (player + NPC characters).
##
##   godot --headless --path . -- --abysstest
##   python tools/run_suite.py --abysstest 480
##   python tools/run_suite.py --abysstest 300 --abyssquick   (skip city falls)
##
## Verifies, against the REAL streamed city:
##   1. Every human character carries an abyss guard that keeps ticking while its
##      own body is frozen.
##   2. A character dropped far below the generation datum is recovered onto the
##      verified top-side surface (walkable-ground layer 8, plan/collision within
##      0.35 m) - not on water, not on a roof/wall/prop.
##   3. The recovery point has a CLEAR gameplay capsule, checked twice: in the
##      exact frame the guard applies the teleport (via its `recovered` signal)
##      and again after the body settles - both measured independently of the
##      guard's own report.
##   4. A cancelled fall charges no fall damage and does not kill the character.
##   5. Recovery is exactly once per fall (no duplicate/overlap), even for
##      several falls in a row.
##   6. A normal short fall does NOT trigger recovery (no false positives).
##   7. An NPC character is recovered the same way as the player.
##   8. A character that leaves the world bounds is held (not falling) and is
##      then recovered at the deterministic city-center fallback column.
##
## Exits 0 on success; the honest gate is the printed
## "finished with N failure(s)" marker.

const AbyssScript := preload("res://actors/traversal/abyss_recovery.gd")

var failures := 0
var _quick := false
var _capture := false
var _capture_dir := ""
var _wp: WorldPlan = null
# Instant (same-frame) post-recovery clearance evidence, one per recovery.
var _instant_clear := true
var _instant_note := ""
var _instant_checks := 0
# Where the guard actually placed each body (instance id -> Vector3).
var _last_to_by_body := {}


func _ready() -> void:
	_quick = OS.get_cmdline_user_args().has("--abyssquick")
	_capture = OS.get_cmdline_user_args().has("--abysscapture")
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[AbyssTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	_run()


func _run() -> void:
	var mgr: ChunkManager = await _await_manager(90.0)
	_check("chunk manager present", mgr != null)
	if mgr == null:
		return _finish()
	var player: Survivor = await _await_player(60.0)
	_check("player present", player != null)
	if player == null:
		return _finish()
	var ring_ok := await _until(func() -> bool:
		return mgr.active_count() >= 9, 90.0)
	_check("active streamed ring present", ring_ok,
			"active=%d" % mgr.active_count())
	_wp = mgr.world_plan
	_check("world plan present", _wp != null)
	if _wp == null:
		return _finish()

	var guard: Node = player.get_node_or_null("AbyssRecovery")
	_check("player carries an abyss guard", guard != null)
	if guard == null:
		return _finish()
	_check("abyss guard keeps ticking while its body is frozen",
			int(guard.process_mode) == int(Node.PROCESS_MODE_ALWAYS))
	_check("abyss guard starts clean", int(guard.get("recovery_count")) == 0)
	# Same-frame clearance evidence for every recovery this run.
	guard.recovered.connect(_on_instant_recovered.bind(player))

	if _capture:
		await _capture_sequence(mgr, player, guard)
		return _finish()

	# --- 0. The placement contract itself (same probe the guard uses) --------
	var here_xz := Vector2(player.global_position.x, player.global_position.z)
	var probe: Dictionary = AbyssScript.find_recovery_position(_space(player), _wp, mgr, here_xz)
	_check("placement probe verifies a walkable top surface at the player column",
			bool(probe.get("ok", false)), String(probe.get("reason", "")))
	if bool(probe.get("ok", false)):
		var probe_pos: Vector3 = probe.get("position", Vector3.ZERO)
		_check("probe keeps the fall column when the column is valid",
				Vector2(probe_pos.x, probe_pos.z).distance_to(here_xz) < 0.01)
		_check("probe reports a verified position",
				bool(probe.get("verified", false)))
	var anchor: Vector3 = SpawnPoints.get_spawn_position(&"city_center", _wp, mgr.plan)
	var anchor_probe: Dictionary = AbyssScript.find_recovery_position(
			_space(player), _wp, mgr, Vector2(anchor.x, anchor.z))
	print("[AbyssTest]   diag city-center fallback column probe: ok=%s reason=%s"
			% [str(anchor_probe.get("ok", false)),
			String(anchor_probe.get("reason", "verified"))])

	# --- 1..3. Falls in the city, three different columns --------------------
	var base_xz := here_xz
	var offsets: Array[Vector2] = [Vector2.ZERO, Vector2(40.0, 0.0), Vector2(-40.0, 40.0)]
	if _quick:
		print("[AbyssTest]   --abyssquick: skipping the three city falls")
	for i in offsets.size():
		if _quick:
			break
		var fall_xz := base_xz + offsets[i]
		await _player_fall(mgr, player, guard, fall_xz, "city fall #%d" % (i + 1))

	if not _quick:
		# --- 4. Negative control: a short fall must not recover --------------
		var count_before := int(guard.get("recovery_count"))
		var health_before: float = player.health.current_health
		var stand_xz := Vector2(player.global_position.x, player.global_position.z)
		player.global_position = Vector3(stand_xz.x,
				player.global_position.y + 3.0, stand_xz.y)
		player.velocity = Vector3.ZERO
		await _wait(2.5)
		_check("short fall does not trigger recovery",
				int(guard.get("recovery_count")) == count_before)
		_check("short fall charges no fall damage",
				absf(player.health.current_health - health_before) < 0.01)
		_check("short fall leaves the character alive", not player.health.is_dead)

	# --- 5. NPC characters are covered too ----------------------------------
	await _npc_fall(mgr, player)

	# --- 6. Out-of-bounds fall: held, then deterministic fallback -----------
	await _out_of_bounds_recovery(mgr, player, guard)

	_check("every recovery was clipping-free in the recovery frame itself",
			_instant_clear and _instant_checks > 0,
			"%d check(s); %s" % [_instant_checks, _instant_note])

	_finish()


## Same-frame evidence: the guard emits this from inside its physics tick, right
## after it placed the body. Measure the landing point NOW, before physics can
## push the body anywhere.
func _on_instant_recovered(_from: Vector3, to: Vector3, _reason: StringName,
		body: Node3D) -> void:
	var space := _space(body)
	if space == null:
		return
	_instant_checks += 1
	_last_to_by_body[body.get_instance_id()] = to
	var xz := Vector2(to.x, to.z)
	var report := _ground_report(space, _wp, xz)
	var clear := bool(report.get("clear", false))
	var body_name := String(report.get("body", ""))
	var dry := _wp.water_body_at(xz) == &""
	var feet_err := 999.0
	if bool(report.get("hit", false)):
		feet_err = absf(to.y - (float(report["surface_y"])
				+ WorldConstants.SPAWN_FEET_CLEARANCE_M))
	var ok := clear and dry and feet_err <= 0.15 \
			and body_name in ["TerrainBody", "RoadBody"]
	print("[AbyssTest]   instant post-recovery: body=%s clear=%s water=%s feet_err=%.3f at (%.2f, %.2f, %.2f)"
			% [body_name, str(clear), str(not dry), feet_err, to.x, to.y, to.z])
	if not ok:
		_instant_clear = false
		_instant_note = "at (%.2f, %.2f, %.2f) body=%s clear=%s dry=%s feet_err=%.3f overlap=[%s]" % [
				to.x, to.y, to.z, body_name, str(clear), str(dry), feet_err,
				", ".join(_overlap_names(space, to))]


## Windowed capture sequence (run with --rendered):
##   python tools/run_suite.py --abysstest 300 --rendered --abysscapture
## Frames: standing on the surface -> the void the bug produced -> recovered on
## the surface at the same column. The guard is paused ONLY for the middle frame
## so the abyss state can be photographed at all (it recovers within one frame).
func _capture_sequence(mgr: ChunkManager, player: Survivor, guard: Node) -> void:
	_capture_dir = ProjectSettings.globalize_path("res://captures/abyss_guard")
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	await _wait(2.0)
	await _snap("01_standing_on_the_surface")
	var xz := Vector2(player.global_position.x, player.global_position.z)
	var ground := _ground_report(_space(player), _wp, xz)
	print("[AbyssTest] capture column xz=(%.1f, %.1f) planned=%.2f surface=%.2f clear=%s body=%s"
			% [xz.x, xz.y, float(ground.get("planned", 0.0)),
			float(ground.get("surface_y", 0.0)), str(ground.get("clear", false)),
			String(ground.get("body", ""))])
	# Middle frame: hold the guard off so the fall into the void is visible.
	guard.process_mode = Node.PROCESS_MODE_DISABLED
	player.global_position = Vector3(xz.x, -220.0, xz.y)
	player.velocity = Vector3(0.0, -30.0, 0.0)
	await _wait(1.0)
	await _snap("02_fallen_into_the_abyss")
	guard.process_mode = Node.PROCESS_MODE_ALWAYS
	var count_before := int(guard.get("recovery_count"))
	var recovered := await _until(func() -> bool:
		return int(guard.get("recovery_count")) >= count_before + 1, 40.0)
	await _wait(1.6)
	await _snap("03_recovered_on_the_surface")
	_check("capture: recovery happened", recovered)
	var pos: Vector3 = player.global_position
	print("[AbyssTest] capture after: pos=(%.2f, %.2f, %.2f) on_floor=%s recovery_count=%d"
			% [pos.x, pos.y, pos.z, str(player.is_on_floor()),
			int(guard.get("recovery_count"))])
	print("[AbyssTest] captures written to captures/abyss_guard/")


## Save one genuine rendered frame of the real windowed game.
func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	var path: String = _capture_dir.path_join(name + ".png")
	var err := image.save_png(path)
	print("[AbyssTest] capture %s -> %s (err=%d, %dx%d)"
			% [name, path, err, image.get_width(), image.get_height()])
	await _wait(0.25)


## One abyss fall at `fall_xz`, with the full acceptance set.
func _player_fall(mgr: ChunkManager, player: Survivor, guard: Node,
		fall_xz: Vector2, label: String) -> void:
	var count_before := int(guard.get("recovery_count"))
	var health_before: float = player.health.current_health
	player.global_position = Vector3(fall_xz.x, -220.0, fall_xz.y)
	player.velocity = Vector3(0.0, -30.0, 0.0)
	var recovered := await _until(func() -> bool:
		return int(guard.get("recovery_count")) >= count_before + 1, 40.0)
	_check("%s: recovered out of the abyss" % label, recovered,
			"y=%.1f" % player.global_position.y)
	if not recovered:
		return
	await _assert_on_verified_surface(mgr, player, guard, fall_xz, label,
			count_before, health_before, true)


## The NPC path: a real Survivor built the normal way, dropped out of the world.
func _npc_fall(mgr: ChunkManager, player: Survivor) -> void:
	var npc := Survivor.new()
	npc.configure({
		"id": &"abyss_probe_npc",
		"name": "Abyss Probe",
		"occupation": "scout",
		"is_player": false,
		"color": Color(0.55, 0.5, 0.45),
		"items": {},
	})
	add_child(npc)
	npc.global_position = Vector3(player.global_position.x + 3.0,
			player.global_position.y + 1.0, player.global_position.z + 2.0)
	for i in 4:
		await get_tree().physics_frame
	var npc_guard: Node = npc.get_node_or_null("AbyssRecovery")
	_check("npc character carries an abyss guard", npc_guard != null)
	if npc_guard == null:
		npc.queue_free()
		return
	npc_guard.recovered.connect(_on_instant_recovered.bind(npc))
	var npc_xz := Vector2(npc.global_position.x, npc.global_position.z)
	npc.global_position = Vector3(npc_xz.x, -190.0, npc_xz.y)
	npc.velocity = Vector3(0.0, -25.0, 0.0)
	var recovered := await _until(func() -> bool:
		return int(npc_guard.get("recovery_count")) >= 1, 40.0)
	_check("npc: recovered out of the abyss", recovered,
			"y=%.1f" % npc.global_position.y)
	if recovered:
		await _assert_on_verified_surface(mgr, npc, npc_guard, npc_xz,
				"npc fall", 0, npc.health.current_health, true)
	npc.queue_free()
	for i in 3:
		await get_tree().process_frame


## A character outside the world bounds cannot be placed in its own column: it
## must be held (not falling) and then recovered at the city-center column.
func _out_of_bounds_recovery(mgr: ChunkManager, player: Survivor,
		guard: Node) -> void:
	var count_before := int(guard.get("recovery_count"))
	var health_before: float = player.health.current_health
	player.global_position = Vector3(WorldConstants.WORLD_MAX_M + 60.0, 0.0, 40.0)
	player.velocity = Vector3(0.0, -20.0, 0.0)
	var held := await _until(func() -> bool:
		return int(player.process_mode) == int(Node.PROCESS_MODE_DISABLED), 5.0)
	_check("out-of-bounds fall is held (body frozen) instead of falling", held)
	var y_held: float = player.global_position.y
	await _wait(1.5)
	_check("held character does not keep falling",
			absf(player.global_position.y - y_held) < 0.01,
			"dy=%.3f" % (player.global_position.y - y_held))

	var waited := 0.0
	var next_diag := 0.0
	while int(guard.get("recovery_count")) < count_before + 1 and waited < 70.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited >= next_diag:
			next_diag = waited + 6.0
			var xz := Vector2(player.global_position.x, player.global_position.z)
			var coord := WorldSeed.chunk_coord(xz.x, xz.y)
			var st := mgr.state_of(coord)
			var pr: Dictionary = AbyssScript.find_recovery_position(
					_space(player), _wp, mgr, xz)
			print("[AbyssTest]   hold t=%.0fs xz=(%.1f, %.1f) y=%.1f coord=(%d, %d) state=%s probe=%s"
					% [waited, xz.x, xz.y, player.global_position.y,
					coord.x, coord.y, String(st),
					String(pr.get("reason", "ok"))])
	var recovered := int(guard.get("recovery_count")) >= count_before + 1
	_check("out-of-bounds fall ends in a recovery", recovered,
			"waited=%.0fs" % waited)
	if not recovered:
		return
	var anchor: Vector3 = SpawnPoints.get_spawn_position(&"city_center", _wp, mgr.plan)
	var xz := Vector2(player.global_position.x, player.global_position.z)
	var d_anchor := xz.distance_to(Vector2(anchor.x, anchor.z))
	_check("out-of-bounds recovery lands at the city-center fallback column",
			d_anchor < 140.0, "d=%.1f" % d_anchor)
	await _assert_on_verified_surface(mgr, player, guard,
			Vector2(anchor.x, anchor.z), "out-of-bounds fall",
			count_before, health_before, false)


## Shared acceptance set for one recovery.
func _assert_on_verified_surface(mgr: ChunkManager, body: Survivor, guard: Node,
		fall_xz: Vector2, label: String, count_before: int,
		health_before: float, expect_same_column: bool) -> void:
	var on_floor := await _until(func() -> bool: return body.is_on_floor(), 4.0)
	_check("%s: character stands on the surface afterwards" % label, on_floor)
	# Let a duplicate/jittered second recovery surface if there were one.
	await _wait(1.2)
	_check("%s: exactly one recovery for that fall" % label,
			int(guard.get("recovery_count")) == count_before + 1,
			"count=%d expected=%d" % [int(guard.get("recovery_count")),
					count_before + 1])
	_check("%s: cancelled fall charges no fall damage" % label,
			absf(body.health.current_health - health_before) < 0.01,
			"hp %.2f -> %.2f" % [health_before, body.health.current_health])
	_check("%s: character survives the recovery" % label,
			not body.health.is_dead)
	_check("%s: released back to normal physics processing" % label,
			int(body.process_mode) != int(Node.PROCESS_MODE_DISABLED))

	var pos: Vector3 = body.global_position
	var xz := Vector2(pos.x, pos.z)
	_check("%s: recovered above the abyss line" % label,
			pos.y > AbyssScript.ABYSS_FALL_Y, "y=%.1f" % pos.y)
	var lateral := xz.distance_to(fall_xz)
	_check("%s: recovery point stays bounded near the fall column" % label,
			lateral < 45.0, "d=%.1f" % lateral)
	# Independent re-measurement of the landing point (never trusting the guard).
	var space := _space(body)
	if expect_same_column:
		# The guard keeps the fall column when it is a valid place to stand; when
		# the column is blocked (inside a building/prop) it must walk out to a
		# real feet-level surface instead of floating the character on a lift.
		var col := _ground_report(space, _wp, fall_xz)
		var col_ok := bool(col.get("hit", false)) and bool(col.get("clear", false))
		if col_ok:
			_check("%s: valid fall column is kept" % label,
					lateral < 2.0, "d=%.2f" % lateral)
		else:
			_check("%s: blocked fall column relocates to a real surface" % label,
					lateral > 0.5 and lateral < 45.0, "d=%.2f" % lateral)

	_check("%s: recovery point is dry land" % label,
			_wp.water_body_at(xz) == &"")
	var report := _ground_report(space, _wp, xz)
	_check("%s: landing point is materialized walkable ground" % label,
			bool(report.get("hit", false)), String(report.get("reason", "")))
	if bool(report.get("hit", false)):
		_check("%s: landing body is TerrainBody/RoadBody (never a roof/prop)" % label,
				String(report.get("body", "")) in ["TerrainBody", "RoadBody"],
				String(report.get("body", "")))
		_check("%s: collision surface matches the plan datum" % label,
				absf(float(report["surface_y"]) - float(report["planned"])) <= 0.35,
				"planned=%.2f surface=%.2f" % [float(report["planned"]),
						float(report["surface_y"])])
		var feet_expected: float = float(report["surface_y"]) \
				+ WorldConstants.SPAWN_FEET_CLEARANCE_M
		_check("%s: character is not sunk into the ground" % label,
				pos.y >= feet_expected - 0.25,
				"y=%.2f ground_feet=%.2f support=%s" % [pos.y, feet_expected,
						_support_report(space, body)])
		_check("%s: no structural clipping around the settled character" % label,
				_structural_overlap_names(space, pos).is_empty(),
				"overlap=[%s]" % ", ".join(_overlap_names(space, pos)))
	# The recovery POINT itself (where the guard placed the body) must still be
	# clipping-free after the body settled - re-measured at the guard's column.
	var to: Vector3 = _last_to_by_body.get(body.get_instance_id(), pos)
	var to_report := _ground_report(space, _wp, Vector2(to.x, to.z))
	_check("%s: recovery point stays clipping-free once settled" % label,
			bool(to_report.get("clear", false)),
			"at (%.2f, %.2f, %.2f) overlap=[%s]" % [to.x, to.y, to.z,
					", ".join(_overlap_names(space, to))])


## What is the character actually standing on (mask: environment | survivors |
## zombies)? Diagnostic only - a survivor standing on another actor is normal
## gameplay, standing inside terrain is not.
func _support_report(space: PhysicsDirectSpaceState3D, body: Node3D) -> String:
	if space == null:
		return "?"
	var from := body.global_position + Vector3(0, 0.35, 0)
	var q := PhysicsRayQueryParameters3D.create(
			from, from + Vector3(0, -3.0, 0), 1 | 2 | 4)
	q.exclude = [body.get_rid()]
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return "nothing"
	var collider: Node = hit.get("collider")
	var dist := from.y - (hit.get("position", Vector3.ZERO) as Vector3).y
	return "%s(%.2f m below)" % [collider.name if collider != null else "?",
			dist]


## Names (+ batcher ids) of every collider overlapping a standing gameplay
## capsule at `at`. Used as failure detail, never as a pass criterion.
func _overlap_names(space: PhysicsDirectSpaceState3D, at: Vector3,
		skip_ground := false) -> Array:
	if space == null:
		return []
	var capsule := CapsuleShape3D.new()
	capsule.radius = AbyssScript.CAPSULE_RADIUS
	capsule.height = AbyssScript.CAPSULE_HEIGHT
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = capsule
	q.transform = Transform3D(Basis.IDENTITY,
			at + Vector3(0, AbyssScript.CAPSULE_HEIGHT * 0.5, 0))
	q.collision_mask = 1
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var out: Array = []
	for hit in space.intersect_shape(q, 8):
		var collider: Node = hit.get("collider")
		if collider == null:
			continue
		if skip_ground and collider.name in [&"TerrainBody", &"RoadBody"]:
			# The floor the character is standing on - resting contact with it is
			# not clipping.
			continue
		var meta := ""
		if collider.has_meta("vox_id"):
			meta = "#%s/%s" % [str(collider.get_meta("vox_id")),
					str(collider.get_meta("vox_material"))]
		out.append("%s(%s)%s" % [collider.name, collider.get_class(), meta])
	return out


## Structural (non-ground) overlaps only: the objects a respawned character must
## never be inside - walls, slabs, props, roofs.
func _structural_overlap_names(space: PhysicsDirectSpaceState3D,
		at: Vector3) -> Array:
	return _overlap_names(space, at, true)


## Ground truth for a column: walkable-ground ray + capsule clearance.
func _ground_report(space: PhysicsDirectSpaceState3D, wp: WorldPlan,
		xz: Vector2) -> Dictionary:
	var planned: float = wp.surface_height_at(xz)
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(xz.x, planned + 24.0, xz.y),
			Vector3(xz.x, planned - 32.0, xz.y),
			WorldConstants.COLLISION_WALKABLE_GROUND)
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return {"hit": false, "reason": "no walkable ground", "planned": planned}
	var body := hit.get("collider") as StaticBody3D
	var surface_y: float = (hit.get("position", Vector3.ZERO) as Vector3).y
	var at := Vector3(xz.x, surface_y + WorldConstants.SPAWN_FEET_CLEARANCE_M, xz.y)
	var exclude: Array = []
	if body != null:
		exclude.append(body.get_rid())
	return {
		"hit": true,
		"planned": planned,
		"surface_y": surface_y,
		"body": String(body.name) if body != null else "",
		"clear": AbyssScript.capsule_clear(space, at, exclude),
	}


func _space(body: Node3D) -> PhysicsDirectSpaceState3D:
	if body.get_world_3d() == null:
		return null
	return body.get_world_3d().direct_space_state


func _await_manager(timeout: float) -> ChunkManager:
	await _until(func() -> bool:
		return not get_tree().get_nodes_in_group(&"chunk_manager").is_empty(),
		timeout)
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	if managers.is_empty():
		return null
	return managers[0] as ChunkManager


func _await_player(timeout: float) -> Survivor:
	await _until(func() -> bool:
		return ActorRegistry.get_actor(&"player") != null, timeout)
	return ActorRegistry.get_actor(&"player") as Survivor


func _until(predicate: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if predicate.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return predicate.call()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _check(test_name: String, condition: bool, detail := "") -> void:
	if condition:
		print("[AbyssTest] PASS  %s" % test_name)
	else:
		failures += 1
		print("[AbyssTest] FAIL  %s   (%s)" % [test_name, detail])


func _finish() -> void:
	print("[AbyssTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
