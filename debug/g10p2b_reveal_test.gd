extends Node
## Focused FIX3 regression: a materialized modular wall follows the exact
## building/floor/facade reveal decision of its structural owner.

var _failures := 0


func _ready() -> void:
	var batcher := MeshBatcher.new()
	batcher.push_layer("reveal_probe:f0:N|g")
	batcher.add_visual_box(Vector3.ZERO, Vector3.ONE, Color.WHITE)
	batcher.queue_asset_wall(Vector3(2.0, 1.0, 3.0),
			Vector3(2.0, 2.05, 0.18), WorldConstants.COL_ASSET_FALLBACK,
			"res://art/modules/wall_2m.glb", 1.0, false, PI * 0.5,
			"N", ["N"])
	batcher.pop_layer()
	var manifest: Dictionary = batcher.asset_instances()[0]
	_check(str(manifest.get("building_id", "")) == "reveal_probe",
			"queued asset keeps building id")
	_check(int(manifest.get("floor_i", -1)) == 0,
			"queued asset keeps floor")
	_check(str(manifest.get("facade", "")) == "N" and
			(manifest.get("facade_sides", []) as Array).has("N"),
			"queued asset keeps N facade ownership")
	_check(MeshBatcher.reveal_layer_hidden("reveal_probe:f0:N",
			"reveal_probe", 0, ["N"]),
			"structural N facade hides")
	_check(MeshBatcher.reveal_layer_hidden("reveal_probe:f0:N|g",
			"reveal_probe", 0, ["N"]),
			"composite N|g facade hides as structural N")
	_check(MeshBatcher.reveal_asset_hidden(manifest, "reveal_probe", 0, ["N"]),
			"matching wall_2m hides with structural N facade")
	_check(not MeshBatcher.reveal_asset_hidden(manifest, "reveal_probe", 0, ["E"]),
			"unrelated E facade does not hide N wall")

	var holder := Node3D.new()
	add_child(holder)
	batcher.flush_into(holder, 1, false)
	var gate_state := {}
	batcher.apply_floor_gate_probe("reveal_probe", 0, ["N"], gate_state)
	_check(not bool(gate_state.get("reveal_probe:f0:N|g", true)),
			"materialized composite layer hides with owning structural facade")
	_check(not bool(gate_state.get("asset:0", true)),
			"materialized wall_2m hides with owning structural facade")

	# Exercise the real materialization seam: the gate is requested before the
	# chunk record exists, then _materialize replaces that record with fresh
	# layer and asset nodes. The stored request must be applied to both.
	var manager := ChunkManager.new()
	add_child(manager)
	manager.set_process(false)
	var gated_coord := Vector2i(0, 0)
	manager.apply_floor_gate(gated_coord, "reveal_probe", 0, ["N"])
	var fresh_batcher := MeshBatcher.new()
	fresh_batcher.push_layer("reveal_probe:f0:N|g")
	fresh_batcher.add_visual_box(Vector3.ZERO, Vector3.ONE, Color.WHITE)
	fresh_batcher.queue_asset_wall(Vector3(2.0, 1.0, 3.0),
			Vector3(2.0, 2.05, 0.18), WorldConstants.COL_ASSET_FALLBACK,
			"res://art/modules/wall_2m.glb", 1.0, false, PI * 0.5,
			"N", ["N"])
	fresh_batcher.pop_layer()
	manager._materialize(gated_coord, fresh_batcher, {}, 0.0, Vector2i(2, 2))
	var fresh_rec: Dictionary = manager._chunks.get(gated_coord, {}) as Dictionary
	var fresh_layers: Dictionary = fresh_rec.get("layers", {}) as Dictionary
	var fresh_layer: MeshInstance3D = fresh_layers.get("reveal_probe:f0:N|g", null) as MeshInstance3D
	_check(fresh_layer != null and not fresh_layer.visible,
			"materialization reapplies stored gate to fresh composite layer")
	var fresh_assets: Array = fresh_rec.get("asset_nodes", []) as Array
	var fresh_asset: Node3D = null
	if not fresh_assets.is_empty():
		fresh_asset = fresh_assets[0] as Node3D
	_check(fresh_asset != null and not fresh_asset.visible,
			"materialization reapplies stored gate to fresh wall_2m")
	manager.free()
	holder.free()
	print("[G10P2BRevealTest] finished with %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[G10P2BRevealTest] PASS ", message)
	else:
		_failures += 1
		print("[G10P2BRevealTest] FAIL ", message)
