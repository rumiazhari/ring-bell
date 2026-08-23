extends Node
## Visual verification probe (--shot): captures gameplay view plus a
## top-down diagnostic overview around the player, prints ChunkManager stats,
## quits. Runs in CITY world mode only. Never used by validation suites.

const OUT_DIR := "C:/Users/rumia/AppData/Local/Temp/opencode"


func _ready() -> void:
	_run()


func _run() -> void:
	await _wait(4.0)
	_snap("rb_city_spawn.png")
	await _overview("rb_overview.png")

	var player := ActorRegistry.get_actor(&"player")
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	if player != null and managers.size() > 0:
		var mgr: ChunkManager = managers[0]
		# Street-level shot beside a real building front, at noon light.
		var spawn := mgr.plan.find_spawn_point()
		var specs := mgr.plan.buildings_in_rect(
				Rect2(spawn - Vector2(90, 90), Vector2(180, 180)))
		if not specs.is_empty():
			var lr: Rect2 = specs[0]["rect"]
			var front := ChunkBuilder._front_of(lr, int(specs[0]["door_edge"]), 0.5)
			GameClock.advance(300.0)   # ~07:00 -> ~12:00
			player.global_position = Vector3(front.x, 0.15, front.y)
			await _wait(3.5)
			_snap("rb_street.png")
			await _overview("rb_overview2.png")
		# Far teleport: prove streaming across distance.
		player.global_position += Vector3(300, 0.5, 140)
		await _wait(4.0)
		_snap("rb_city_far.png")
		for line in mgr.debug_lines():
			print("[ShotProbe] %s" % line)
		print("[ShotProbe] resident chunk nodes: %d" % mgr.get_child_count())
	get_tree().quit()


## Spawns a temporary straight-down camera above the player.
func _overview(file_name: String) -> void:
	var player := ActorRegistry.get_actor(&"player")
	if player == null:
		return
	var old_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.position = Vector3(player.global_position.x, 70.0,
			player.global_position.z)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.fov = 75
	add_child(cam)
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame
	_snap(file_name)
	if old_cam != null and is_instance_valid(old_cam):
		old_cam.make_current()
	cam.queue_free()
	await get_tree().process_frame


func _snap(file_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var path := OUT_DIR + "/" + file_name
	img.save_png(path)
	print("[ShotProbe] saved ", path)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
