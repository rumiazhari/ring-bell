extends SceneTree
func _init() -> void:
	var seed0 := WorldSeed.get_world_seed()
	print("[ChamberQuick] seed %d" % seed0)
	var wp := WorldPlan.new(seed0)
	var cp: CavePlan = wp.cave
	var rect := Rect2(Vector2(-1000,-1000), Vector2(2000,2000))
	var entrances: Array[Dictionary] = cp.cave_entrances_in(rect)
	var chambers: Array[Dictionary] = cp.cave_chambers_in(rect)
	print("[ChamberQuick] entrances %d chambers %d in rect" % [entrances.size(), chambers.size()])
	# Check each chamber at entrance+offset size 5x5x3
	var ok := true
	for ch in chambers:
		var pos: Vector2 = ch.get("pos", Vector2.ZERO) as Vector2
		var size: Vector3 = ch.get("size", Vector3.ZERO) as Vector3
		var eid: String = String(ch.get("entrance_id",""))
		var id: String = String(ch.get("id",""))
		if not id.begins_with("cave_chamber_"):
			print("[ChamberQuick] FAIL id %s" % id)
			ok = false
		if not eid.begins_with("cave_entrance_"):
			print("[ChamberQuick] FAIL eid %s" % eid)
			ok = false
		if not size.is_equal_approx(WorldConstants.CAVE_CHAMBER_SIZE):
			print("[ChamberQuick] FAIL size %s vs %s" % [size, WorldConstants.CAVE_CHAMBER_SIZE])
			ok = false
		# Check pos same as entrance pos
		var found := false
		for e in entrances:
			if String(e.get("id","")) == eid:
				var epos: Vector2 = e.get("pos", Vector2.ZERO) as Vector2
				if not epos.is_equal_approx(pos):
					print("[ChamberQuick] FAIL pos mismatch %s vs %s" % [pos, epos])
					ok = false
				found = true
				break
		if not found:
			print("[ChamberQuick] FAIL no entrance for chamber %s" % id)
			ok = false
		# Check offset y -2
		var h: float = wp.terrain.height_at(pos)
		var expected_y: float = h + WorldConstants.CAVE_CHAMBER_OFFSET.y + WorldConstants.CAVE_CHAMBER_SIZE.y * 0.5
		var pos3: Vector3 = ch.get("pos3", Vector3.ZERO) as Vector3
		if absf(pos3.y - expected_y) > 0.01:
			print("[ChamberQuick] FAIL y %.2f vs expected %.2f h %.2f" % [pos3.y, expected_y, h])
			ok = false
	# Determinism shuffled
	var cp2 := CavePlan.new(seed0, wp.terrain, wp.hydrology, wp.geology, wp.biome, wp.settlement, wp.road_network, wp.rural_building)
	var chambers2: Array[Dictionary] = cp2.cave_chambers_in(rect)
	if chambers.size() != chambers2.size():
		print("[ChamberQuick] FAIL determinism size %d vs %d" % [chambers.size(), chambers2.size()])
		ok = false
	else:
		for i in chambers.size():
			if String(chambers[i].get("id","")) != String(chambers2[i].get("id","")):
				print("[ChamberQuick] FAIL determinism id mismatch")
				ok = false
				break
	# Different seed differs
	var wp_alt := WorldPlan.new(seed0 + 7919)
	var chambers_alt: Array[Dictionary] = wp_alt.cave.cave_chambers_in(rect)
	if chambers.size() == chambers_alt.size():
		var same := true
		for i in mini(chambers.size(), chambers_alt.size()):
			if String(chambers[i].get("id","")) != String(chambers_alt[i].get("id","")):
				same = false
				break
			var p1: Vector2 = chambers[i].get("pos", Vector2.ZERO) as Vector2
			var p2: Vector2 = chambers_alt[i].get("pos", Vector2.ZERO) as Vector2
			if p1.distance_to(p2) > 1.0:
				same = false
				break
		if same and chambers.size() > 0:
			print("[ChamberQuick] WARN same chambers across seeds, but may be same positions")
	# Check at least 1 chamber total world
	var all_chambers: Array[Dictionary] = cp.cave_chambers()
	print("[ChamberQuick] world chambers %d" % all_chambers.size())
	if all_chambers.size() < 3:
		print("[ChamberQuick] FAIL at least 3 expected in world, got %d" % all_chambers.size())
		ok = false
	# Check budgets via builder
	var coord := Vector2i(0,0)
	# Find a chunk with cave
	var found_chunk: Vector2i = Vector2i(0,0)
	var found := false
	for e in all_chambers:
		var p: Vector2 = e.get("pos", Vector2.ZERO) as Vector2
		var c: Vector2i = WorldSeed.chunk_coord(p.x, p.y)
		var m: Dictionary = UndergroundChunkBuilder.build_manifest(wp, c)
		if int(m.get("cave_vertices",0)) > 0:
			found_chunk = c
			found = true
			print("[ChamberQuick] chunk %s verts %d tris %d chambers %d entrances %d" % [c, m.get("cave_vertices",0), m.get("cave_triangles",0), (m.get("cave_chambers",[]) as Array).size(), (m.get("cave_entrances",[]) as Array).size()])
			if int(m.get("cave_vertices",0)) > WorldConstants.MAX_CAVE_VERTS_PER_CHUNK:
				print("[ChamberQuick] FAIL verts %d > max %d" % [m.get("cave_vertices",0), WorldConstants.MAX_CAVE_VERTS_PER_CHUNK])
				ok = false
			if int(m.get("cave_triangles",0)) > WorldConstants.MAX_CAVE_TRIS_PER_CHUNK:
				print("[ChamberQuick] FAIL tris")
				ok = false
			if int(m.get("cave_colliders",0)) != 0:
				print("[ChamberQuick] FAIL colliders not 0")
				ok = false
			break
	if not found:
		print("[ChamberQuick] FAIL no chunk with chamber found")
		ok = false
	# Check negative coords
	var neg_rect := Rect2(Vector2(-2000,-2000), Vector2(1000,1000))
	var neg_chambers: Array[Dictionary] = cp.cave_chambers_in(neg_rect)
	print("[ChamberQuick] neg chambers %d" % neg_chambers.size())
	# Check spacing
	var world_chambers: Array[Dictionary] = cp.cave_chambers()
	var spacing_ok := true
	for i in world_chambers.size():
		for j in range(i+1, world_chambers.size()):
			var pi: Vector2 = world_chambers[i].get("pos", Vector2.ZERO) as Vector2
			var pj: Vector2 = world_chambers[j].get("pos", Vector2.ZERO) as Vector2
			if pi.distance_to(pj) < WorldConstants.CAVE_CHAMBER_SPACING_MIN - 0.01:
				print("[ChamberQuick] FAIL spacing %.1f between %s and %s" % [pi.distance_to(pj), world_chambers[i].get("id",""), world_chambers[j].get("id","")])
				spacing_ok = false
				break
		if not spacing_ok:
			break
	if spacing_ok:
		print("[ChamberQuick] spacing OK")
	print("[ChamberQuick] %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
