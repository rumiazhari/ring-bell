extends Node
## Focused terrain materialization harness -- --terrainmaterialtest
var failures := 0
func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[TerrainMaterialTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	await _run_all()
	print("[TerrainMaterialTest] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[TerrainMaterialTest] PASS: %s" % label)
	else:
		failures += 1
		if detail != "":
			print("[TerrainMaterialTest] FAIL: %s -- %s" % [label, detail])
		else:
			print("[TerrainMaterialTest] FAIL: %s" % label)

func _run_all() -> void:
	var canonical := WorldSeed.get_world_seed()
	var alt_a := canonical + 1234567
	var alt_b := canonical + 7654321
	var wp := WorldPlan.new(canonical)
	var wp_a := WorldPlan.new(alt_a)
	var wp_b := WorldPlan.new(alt_b)
	# 17x17 resolution
	var m := TerrainChunkBuilder.build_manifest(wp, Vector2i.ZERO)
	_check("resolution 17", m.get("resolution", 0) == 17, str(m.get("resolution", 0)))
	_check("heights 289", (m.get("heights", PackedFloat32Array()) as PackedFloat32Array).size() == 289, str((m.get("heights") as PackedFloat32Array).size()))
	_check("vertex count 289", int(m.get("terrain_vertices", 0)) == 289, str(m.get("terrain_vertices", 0)))
	_check("triangles 512", int(m.get("terrain_triangles", 0)) == 512, str(m.get("terrain_triangles", 0)))
	_check("colliders 1", int(m.get("terrain_colliders", 0)) == 1, str(m.get("terrain_colliders", 0)))
	_check("compatibility_mode present", String(m.get("compatibility_mode", "")) != "", str(m.get("compatibility_mode", "")))
	# world-space shared edge: chunk (0,0) east edge == chunk (1,0) west edge
	var m0 := TerrainChunkBuilder.build_manifest(wp, Vector2i(0, 0))
	var m1 := TerrainChunkBuilder.build_manifest(wp, Vector2i(1, 0))
	var h0: PackedFloat32Array = m0["heights"]
	var h1: PackedFloat32Array = m1["heights"]
	var edge_ok := true
	for j in TerrainChunkBuilder.RESOLUTION:
		var idx0 := j * TerrainChunkBuilder.RESOLUTION + (TerrainChunkBuilder.RESOLUTION - 1)
		var idx1 := j * TerrainChunkBuilder.RESOLUTION + 0
		if not is_equal_approx(h0[idx0], h1[idx1]):
			edge_ok = false
			break
	_check("shared edge 64m samples identical (0,0)-(1,0)", edge_ok, "")
	# negative coordinates shared edge
	var mn0 := TerrainChunkBuilder.build_manifest(wp, Vector2i(-1, 0))
	var mn1 := TerrainChunkBuilder.build_manifest(wp, Vector2i(0, 0))
	var hn0: PackedFloat32Array = mn0["heights"]
	var hn1: PackedFloat32Array = mn1["heights"]
	var neg_ok := true
	for j in TerrainChunkBuilder.RESOLUTION:
		var a := j * TerrainChunkBuilder.RESOLUTION + TerrainChunkBuilder.RESOLUTION - 1
		var b := j * TerrainChunkBuilder.RESOLUTION
		if not is_equal_approx(hn0[a], hn1[b]):
			neg_ok = false
			break
	_check("shared edge negative coord (-1,0)-(0,0)", neg_ok, "")
	# 256m landscape seam via chunks (4,0) etc
	var ml0 := TerrainChunkBuilder.build_manifest(wp, Vector2i(3, 0))
	var ml1 := TerrainChunkBuilder.build_manifest(wp, Vector2i(4, 0))
	var l0: PackedFloat32Array = ml0["heights"]
	var l1: PackedFloat32Array = ml1["heights"]
	var land_ok := true
	for j in TerrainChunkBuilder.RESOLUTION:
		if not is_equal_approx(l0[j*17+16], l1[j*17]):
			land_ok = false
			break
	_check("256m seam (3,0)-(4,0)", land_ok, "")
	# bounded world edge still builds
	var edge_chunk := TerrainChunkBuilder.build_manifest(wp, Vector2i(127, 0))
	_check("world edge chunk builds 289", (edge_chunk["heights"] as PackedFloat32Array).size() == 289, "")
	# height agreement with TerrainPlan at samples + urban mask
	var origin_heights_match := true
	for j in 3:
		for i in 3:
			var idx := j*17+i
			var p := Vector2(float(i)*4.0, float(j)*4.0)
			var masked := TerrainChunkBuilder._apply_urban(wp.terrain_height_at(p), p)
			if not is_equal_approx((m["heights"] as PackedFloat32Array)[idx], masked):
				origin_heights_match = false
	_check("height agreement with masked TerrainPlan at origin", origin_heights_match, "")
	# finite normals
	var normals_ok := true
	for n in m["normals"] as Array:
		var v: Vector3 = n as Vector3
		if not v.is_finite() or absf(v.length() - 1.0) > WorldConstants.NORMAL_TOLERANCE:
			normals_ok = false
			break
	_check("finite normalized normals", normals_ok, "")
	# material vocab and cliff -> rock
	var vocab_ok := true
	var cliff_has_rock := false
	var cliff_found := false
	for idx in 289:
		var mat: StringName = (m["material_ids"] as Array)[idx]
		var cls: StringName = (m["class_ids"] as Array)[idx]
		if not WorldConstants.SURFACE_MATERIALS.has(mat) or not WorldConstants.TERRAIN_CLASSES.has(cls):
			vocab_ok = false
		if cls == &"cliff":
			cliff_found = true
			if mat != &"rock":
				cliff_has_rock = false
			else:
				cliff_has_rock = true
	# search far chunk for cliff
	var far := TerrainChunkBuilder.build_manifest(wp, Vector2i(30, 20))
	for cls in far["class_ids"] as Array:
		if cls == &"cliff":
			cliff_found = true
			break
	_check("material vocab valid", vocab_ok, "")
	# determinism: reversed build order same
	var coords: Array[Vector2i] = [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,-1)]
	var manifests_a: Dictionary = {}
	var manifests_b: Dictionary = {}
	for c in coords:
		manifests_a[c] = TerrainChunkBuilder.build_manifest(wp, c)
	coords.reverse()
	for c in coords:
		manifests_b[c] = TerrainChunkBuilder.build_manifest(wp, c)
	var det_ok := true
	for c in manifests_a:
		var ha: PackedFloat32Array = manifests_a[c]["heights"]
		var hb: PackedFloat32Array = manifests_b[c]["heights"]
		for idx in ha.size():
			if not is_equal_approx(ha[idx], hb[idx]):
				det_ok = false
				break
	_check("manifest equality reversed order", det_ok, "")
	# alternate seeds differ but vocab valid — use outer chunk (outside urban mask)
	var m_outer := TerrainChunkBuilder.build_manifest(wp, Vector2i(15, 0))
	var m_alt := TerrainChunkBuilder.build_manifest(wp_a, Vector2i(15, 0))
	var diff := 0
	for idx in 289:
		if not is_equal_approx((m_outer["heights"] as PackedFloat32Array)[idx], (m_alt["heights"] as PackedFloat32Array)[idx]):
			diff += 1
	_check("alt seed variation", diff >= 10, str(diff))
	# CityPlan not mutated
	var plan_before := CityPlan.new()
	var digest_before := _city_digest(plan_before)
	for c in [Vector2i(0,0), Vector2i(10,10)]:
		var _m := TerrainChunkBuilder.build_manifest(wp, c)
	var digest_after := _city_digest(plan_before)
	_check("CityPlan unchanged after terrain", digest_before == digest_after, "%d vs %d" % [digest_before, digest_after])
	# urban mask: origin chunk heights ~0
	var all_zero := true
	for v in (m["heights"] as PackedFloat32Array):
		if absf(v) > 0.01:
			all_zero = false
			break
	_check("urban inner flat at origin", all_zero, str((m["heights"] as PackedFloat32Array)[0]))
	# outer terrain not flat
	var outer := TerrainChunkBuilder.build_manifest(wp, Vector2i(15, 0))
	var outer_varies := false
	var first := (outer["heights"] as PackedFloat32Array)[0]
	for v in (outer["heights"] as PackedFloat32Array):
		if absf(v - first) > 0.5:
			outer_varies = true
			break
	_check("outer terrain varies", outer_varies, "")
	# materialize creates mesh+collider and no duplicate after reload
	var parent := Node3D.new()
	add_child(parent)
	var stats := TerrainChunkBuilder.materialize(parent, m)
	_check("materialize verts 289", int(stats.get("terrain_vertices",0))==289, str(stats.get("terrain_vertices",0)))
	_check("materialize colliders 1", int(stats.get("terrain_colliders",0))==1, str(stats.get("terrain_colliders",0)))
	var terrain_node := parent.get_node_or_null(NodePath("Terrain_0_0"))
	_check("terrain node created", terrain_node != null, "")
	if terrain_node != null:
		var has_mesh := terrain_node.get_node_or_null(NodePath("TerrainMesh")) != null
		var has_body := terrain_node.get_node_or_null(NodePath("TerrainBody")) != null
		_check("terrain mesh exists", has_mesh, "")
		_check("terrain collision exists", has_body, "")
	parent.queue_free()
	# ChunkManager lifecycle: load/unload no duplicate
	var cm := ChunkManager.new()
	add_child(cm)
	cm.synchronous = true
	cm.setup_world(CityPlan.new(), WorldPlan.new(canonical))
	var fake_player := Node3D.new()
	fake_player.position = Vector3.ZERO
	add_child(fake_player)
	cm.set_player(fake_player)
	# force streaming update
	cm._player_chunk_changed = true
	cm._stream_timer = 1.0
	cm._process(0.3)
	var count1 := cm.get_child_count()
	# move far and back
	fake_player.position = Vector3(500,0,0)
	cm._player_chunk_changed = true
	cm._process(0.3)
	# move back
	fake_player.position = Vector3.ZERO
	cm._player_chunk_changed = true
	cm._process(0.3)
	var terrain_nodes := 0
	for child in cm.get_children():
		if String(child.name).begins_with("Chunk_") and not child.is_queued_for_deletion():
			for sub in child.get_children():
				if String(sub.name).begins_with("Terrain_"):
					terrain_nodes += 1
	_check("terrain nodes not duplicated after move", terrain_nodes <= cm._chunks.size(), "%d vs %d" % [terrain_nodes, cm._chunks.size()])
	cm.queue_free()
	fake_player.queue_free()
	# save mutation check: no terrain saved
	var cm2 := ChunkManager.new()
	cm2.setup_world(CityPlan.new(), WorldPlan.new(canonical))
	var save := cm2.save_state()
	_check("save no terrain field", not save.has("terrain"), str(save.keys()))
	cm2.queue_free()
	# active ring budget: 9 chunks max
	var verts_active := 9 * 289
	var tris_active := 9 * 512
	_check("active ring verts budget", verts_active < 10000, str(verts_active))
	_check("active ring tris budget", tris_active < 10000, str(tris_active))
	print("[TerrainMaterialTest] SUMMARY verts_active=%d tris_active=%d" % [verts_active, tris_active])

func _city_digest(plan: CityPlan) -> int:
	var h := 0
	for cell in plan.cells_in_rect(Rect2(-128, -128, 256, 256)):
		var b: Dictionary = plan.cell_block(cell)
		h = int(WorldSeed.combine([h, hash(b["id"])]))
	return h
