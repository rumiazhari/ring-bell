class_name AnimSolo
extends Node
## Minimal isolation probe: floor + ONE male survivor, no zombie, no tree extras.
## Usage: godot --headless --path . -- --animsolo

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		get_tree().quit(2)
	)
	_run()

func _run() -> void:
	print("[AnimSolo] start pid=%d" % OS.get_process_id())
	await get_tree().process_frame
	var floor_body := StaticBody3D.new()
	add_child(floor_body)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	floor_body.add_child(col)
	var s := Survivor.new()
	s.configure({"is_player": false, "female": false})
	add_child(s)
	s.global_position = Vector3(0, 0.6, 0)
	print("[AnimSolo] spawned at %s parent=%s" % [str(s.global_position), str(s.get_parent().name)])
	for i in 20:
		await get_tree().physics_frame
		print("[AnimSolo] f%d pos=%s vel=%s floor=%s" % [
			i, str(s.global_position), str(s.velocity), str(s.is_on_floor())])
	print("[AnimSolo] done")
	get_tree().quit(0)
