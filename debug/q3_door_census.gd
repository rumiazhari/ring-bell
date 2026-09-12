extends Node
## Fast probe: census of city buildings vs chunk composition, no chunk builds.
## Run: Godot_v4.7.2-stable_win64.exe --headless --path . res://debug/q3_door_census.tscn

func _ready() -> void:
	var seed_used := WorldSeed.get_world_seed()
	var t0 := Time.get_ticks_msec()
	var plan := CityPlan.new(seed_used)
	var world := WorldPlan.new(seed_used)
	print("[Census] seed=%d plan=%d ms" % [seed_used, Time.get_ticks_msec() - t0])
	var builds: Array = plan.city_buildings()
	print("[Census] city_buildings=%d" % builds.size())
	var city_chunks := {}
	var shown := 0
	var city_ok := 0
	var multi := 0
	var multi_city := 0
	for spec: Dictionary in builds:
		var rect: Rect2 = spec["rect"]
		var c: Vector2 = rect.get_center()
		var coord := WorldSeed.chunk_coord(c.x, c.y)
		var comp: Dictionary = world.chunk_composition(coord)
		var is_city := bool(comp.get("city_materialized", false))
		city_chunks[coord] = is_city
		if is_city:
			city_ok += 1
		var floors := int(spec.get("floors", 1))
		var doors: Array = spec.get("doors", [])
		if floors >= 2 and not doors.is_empty():
			multi += 1
			if is_city:
				multi_city += 1
		if shown < 12:
			shown += 1
			print("[Census] b=%s rect=%s floors=%d doors=%d city=%s at=%s" % [
				str(spec.get("id", "?")), str(rect), floors, doors.size(),
				str(is_city), str(c)])
	var keys := city_chunks.keys()
	var hot := 0
	for k: Vector2i in keys:
		if bool(city_chunks[k]):
			hot += 1
	print("[Census] buildings_in_city_chunks=%d chunks=%d hot_chunks=%d multi_storey_with_doors=%d of_them_in_city=%d"
			% [city_ok, keys.size(), hot, multi, multi_city])
	var hc := 0
	for k: Vector2i in keys:
		if bool(city_chunks[k]) and hc < 8:
			hc += 1
			print("[Census] hot chunk %s composition=%s" % [str(k), str(world.chunk_composition(k))])
	_dump_interior(plan, world)
	get_tree().quit(0)


## Interior manifest for the first usable building: do interior leaves actually
## carry a wall rect the gate can key on?
func _dump_interior(plan: CityPlan, world: WorldPlan) -> void:
	var InteriorPlanScript = load("res://world/generation/interior_plan.gd")
	var picked := 0
	for spec: Dictionary in plan.city_buildings():
		if (spec.get("doors", []) as Array).is_empty():
			continue
		if int(spec.get("floors", 1)) < 2:
			continue
		var rect: Rect2 = spec["rect"]
		var c: Vector2 = rect.get_center()
		if not bool(world.chunk_composition(WorldSeed.chunk_coord(c.x, c.y)).get("city_materialized", false)):
			continue
		picked += 1
		var grounded: Dictionary = ChunkBuilder._grounded_spec(spec, world)
		var im: Dictionary = InteriorPlanScript.build_for_building(grounded)
		var gpos: Vector2 = (grounded["rect"] as Rect2).position
		print("[Census] interior for %s floors=%d ground=%s groundpos=%s local_pos=%s" % [
			str(spec.get("id", "?")), (im.get("floors", []) as Array).size(),
			str(grounded.get("building_ground_y", grounded.get("ground_y", 0.0))),
			str(gpos), str((spec["rect"] as Rect2).position)])
		for fl: Dictionary in im.get("floors", []):
			var fol: int = int(fl.get("floor_i", -1))
			var dcount := (fl.get("doors", []) as Array).size()
			var pcount := (fl.get("partitions", []) as Array).size()
			var key := "-"
			var vis := "-"
			if dcount > 0:
				var dm2: Dictionary = fl["doors"][0]
				var wr: Rect2 = dm2.get("wall_rect", Rect2()) as Rect2
				var idx: int = (fl["doors"] as Array).find(dm2)
				wr.position -= gpos
				key = MeshBatcher.door_wall_cut_key(wr)
				if idx < pcount:
					vis = str(BuildingBuilder.interior_partition_visible(
							(fl["partitions"] as Array)[idx], grounded, fol))
			print("[Census]   floor_i=%d partitions=%d doors=%d wall_key=%s visible=%s" % [
				fol, pcount, dcount, key, vis])
		if picked >= 2:
			break

