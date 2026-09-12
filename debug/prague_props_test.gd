extends Node
## Independent audit of what the generator hangs on a Prague house, inside and
## out. Nothing here reuses the generator's own "is this placement legal"
## predicate: it takes the emitted plan and the emitted mesh and asks what a
## player standing in the room would see.
##
##   A. facade dressings (shutters, flower boxes, planned aperture trim)
##      does each one actually touch the wall it belongs to, and does it sit
##      beside a REAL window aperture on that wall and floor?
##   B. furniture
##      is every prop inside its room, clear of the door swings, the stair, the
##      partitions and every other prop, and is a wall-hung prop actually hung
##      on a wall rather than floating in the middle of the floor?
##   C. doors
##      does every door open into a room on BOTH sides, and is its clear sweep
##      free of solid geometry and furniture (nothing blocked, nothing blocking)?
##   D. structure
##      is every emitted box CONNECTED to the building — touching the ground,
##      the top of the shell, a wall, or another box that is? A box that is
##      attached to nothing is a floating object, whatever emitted it.
##
## Exit code is the failure count, so tools/run_suite.py can gate on it.
var failures := 0

const SIDE_NAMES: Array[String] = ["N", "E", "S", "W"]
## Props drawn hung on a wall (a clock's dial, a framed print) instead of
## standing on the floor. If one of these is not against a wall it is a
## floating object.
const WALL_HUNG: Array[String] = ["wallclock", "print", "gauge"]
## A wall-mounted prop must sit on its wall, not float in the room: the gap
## between its nearest face and the room wall, in metres.
const WALL_HUNG_MAX_EDGE := 0.14
## Wall thickness the Prague shells are built with. Fixed geometry, not a
## generator predicate: the audit only needs to know how deep the wall band is.
const WALL_T := 0.35
## Wall/partition boards are full storey height and thin; anything else is a
## prop, a slab, a stair or a facade dressing.
const WALL_LIKE_MIN_H := 0.85   # fraction of storey height
const WALL_LIKE_MAX_T := 0.45   # thickness of a wall board
## Boxes bigger than this are site-scale structure, not props.
const BIG_BOX := 30.0

func _ready() -> void:
	var diag := OS.get_cmdline_user_args().has("--diag")
	for seed_value: int in [19041207, 19041208, 19041209]:
		audit(seed_value, diag)
		if OS.get_cmdline_user_args().has("--single"):
			break
	print("[PraguePropsTest] finished with %d failure(s)" % failures)
	get_tree().quit(failures)


func audit(seed_value: int, diag: bool) -> void:
	var started := Time.get_ticks_msec()
	var city := CityPlan.new(seed_value)
	var blocks := city.city_blocks()
	var fr := _audit_fringe(seed_value, blocks)

	var buildings := 0
	var floors_seen := 0
	var diag_done := 0

	# A. facade dressings
	var dressing := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var buried := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var floating := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var no_window := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var off_window := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var on_party := {"shutter": 0, "flowerbox": 0, "trim": 0, "sill": 0}
	var dress_candidates := 0     # buildings the dressings are even allowed on
	var planned_facades := 0
	var worst_attach := 0.0
	var worst_attach_what := ""
	var worst_miss := 0.0
	var worst_miss_what := ""

	# B. furniture
	var items := 0
	var kind_census := {}
	var out_of_room := 0
	var overlap := 0
	var on_door := 0
	var on_stair := 0
	var in_wall := 0
	var wall_hung_floating := 0
	var over_ceiling := 0
	var item_samples: Array[String] = []

	# C. doors
	var doors := 0
	var door_to_nowhere := 0
	var door_sweep_blocked := 0
	var door_sweep_furniture := 0
	var door_no_partition := 0
	var door_outside := 0
	var door_wrong_rooms := 0
	var door_samples: Array[String] = []

	# D. structure connectivity
	var boxes := 0
	var loose_boxes := 0
	var loose_by_tag := {}
	var loose_class := {}
	var loose_samples: Array[String] = []
	var loose_buildings := 0

	for block: Dictionary in blocks:
		if not bool(block.get("historic_compound", false)) or block.kind != &"built":
			continue
		var specs: Array = block.get("buildings", []) as Array
		for spec: Dictionary in specs:
			buildings += 1
			var fp: Rect2 = spec["rect"] as Rect2
			var rects: Array[Rect2] = []
			for other: Dictionary in specs:
				rects.append(other["rect"] as Rect2)
			if spec.has("facade_plan"):
				planned_facades += 1
			elif str(spec.get("district", "")) == "historic":
				dress_candidates += 1
			var manifest := InteriorPlan.build_for_building(spec)
			if manifest.is_empty():
				failures += 1
				print("[PraguePropsTest] FAIL seed=%d %s produced no interior manifest" % [seed_value, str(spec.get("id", "?"))])
				continue
			var fh := float(spec.get("floor_h", 3.0))
			for fl: Dictionary in manifest.get("floors", []) as Array:
				floors_seen += 1
				# ---- B. furniture ------------------------------------------------
				var furn: Array = fl.get("furniture", []) as Array
				var placed: Array[Rect2] = []
				var solid: Array[Rect2] = []
				for sw: Rect2 in fl.get("solid_walls", []) as Array:
					solid.append(sw)
				for part: Dictionary in fl.get("partitions", []) as Array:
					solid.append(part.get("rect", Rect2()))
				var sweep_rects: Array[Rect2] = []
				for door: Dictionary in fl.get("doors", []) as Array:
					sweep_rects.append(_door_sweep(door))
				var room_of := {}
				for room: Dictionary in fl.get("rooms", []) as Array:
					room_of[str(room.get("id", ""))] = room
				var stair_zone := Rect2()
				if BuildingBuilder.has_stairs_for(fp.size, fh, int(spec.get("floors", 1))):
					stair_zone = _stair_zone_local(spec)
				for item: Dictionary in furn:
					items += 1
					var kind := String(item.get("kind", ""))
					kind_census[kind] = int(kind_census.get(kind, 0)) + 1
					var size: Vector3 = item.get("size", Vector3.ZERO)
					var ir: Rect2 = item.get("rect", Rect2())
					var room: Dictionary = room_of.get(str(item.get("room_id", "")), {})
					var rr: Rect2 = room.get("rect", Rect2())
					if rr.size.x > 0.0 and not rr.grow(0.06).encloses(ir):
						out_of_room += 1
						if item_samples.size() < 8:
							item_samples.append("out_of_room %s %s in %s" % [kind, str(ir), str(rr)])
					for other_rect: Rect2 in placed:
						var inter := ir.intersection(other_rect)
						if inter.size.x > 0.02 and inter.size.y > 0.02:
							overlap += 1
							if item_samples.size() < 8:
								item_samples.append("overlap %s %s vs %s" % [kind, str(ir), str(other_rect)])
							break
					placed.append(ir)
					for sr: Rect2 in sweep_rects:
						if ir.intersection(sr).get_area() > 0.05:
							on_door += 1
							if item_samples.size() < 8:
								item_samples.append("on_door %s %s vs %s" % [kind, str(ir), str(sr)])
							break
					if stair_zone.size.x > 0.0 and ir.intersects(stair_zone):
						on_stair += 1
						if item_samples.size() < 8:
							item_samples.append("on_stair %s %s vs %s" % [kind, str(ir), str(stair_zone)])
					for sr2: Rect2 in solid:
						var it2 := ir.intersection(sr2)
						if it2.size.x > 0.02 and it2.size.y > 0.02:
							in_wall += 1
							if item_samples.size() < 8:
								item_samples.append("in_wall %s %s vs %s" % [kind, str(ir), str(sr2)])
							break
					if kind in WALL_HUNG and rr.size.x > 0.0:
						var gap := minf(
							minf(ir.position.x - rr.position.x, rr.end.x - ir.end.x),
							minf(ir.position.y - rr.position.y, rr.end.y - ir.end.y))
						if gap > WALL_HUNG_MAX_EDGE:
							wall_hung_floating += 1
							if item_samples.size() < 8:
								item_samples.append("wall_hung_floating %s rect=%s room=%s gap=%.2f" % [kind, str(ir), str(rr), gap])
					if size.y > fh - 0.05:
						over_ceiling += 1
						if item_samples.size() < 8:
							item_samples.append("over_ceiling %s h=%.2f fh=%.2f" % [kind, size.y, fh])
				# ---- C. doors ----------------------------------------------------
				var parts: Array = fl.get("partitions", []) as Array
				door_no_partition += absi(parts.size() - sweep_rects.size())
				for door: Dictionary in fl.get("doors", []) as Array:
					doors += 1
					var dc := _door_plan_point(door)
					var yaw := float(door.get("yaw", 0.0))
					var dw := float(door.get("width", 1.2))
					var horizontal := absf(yaw) < 0.01   # opening runs along X
					var half := dw * 0.5 + 0.05
					var side_ok := 0
					for sgn: float in [-1.0, 1.0]:
						var probe: Vector2 = dc + (Vector2(0.0, 1.0) if horizontal else Vector2(1.0, 0.0)) * (0.42 * sgn)
						for room: Dictionary in fl.get("rooms", []) as Array:
							var rr2: Rect2 = room.get("rect", Rect2())
							if rr2.grow(-0.03).has_point(probe):
								side_ok += 1
								break
					if side_ok < 2:
						door_to_nowhere += 1
						if door_samples.size() < 8:
							door_samples.append("to_nowhere %s sides_ok=%d at %s" % [str(door.get("id", "?")), side_ok, str(dc)])
					# The door's own partition rect still spans the doorway (the
					# opening is a separate rect), so drop the host wall first —
					# otherwise every door in the city reports as blocked. What
					# must stay clear is every *other* wall crossing the opening.
					var aperture := _sweep_rect(dc, horizontal, half, 0.55)
					var a_id := String(door.get("room_a", ""))
					var b_id := String(door.get("room_b", ""))
					var dir := Vector2(0.0, 1.0) if horizontal else Vector2(1.0, 0.0)
					var p_room := _room_at(fl, dc + dir * 0.42)
					var m_room := _room_at(fl, dc - dir * 0.42)
					var paired := (p_room == a_id and m_room == b_id) or (p_room == b_id and m_room == a_id)
					if not paired:
						door_wrong_rooms += 1
						if door_samples.size() < 8:
							door_samples.append("rooms_mismatch %s a=%s b=%s found=%s|%s" % [str(door.get("id", "?")), a_id, b_id, p_room, m_room])
					var core := _sweep_rect(dc, horizontal, maxf(0.12, dw * 0.5 - 0.28), 0.32)
					for sr3: Rect2 in solid:
						if sr3.grow(0.06).has_point(dc) and minf(sr3.size.x, sr3.size.y) <= 0.30:
							continue   # the host wall this door sits in
						if core.intersection(sr3).get_area() > 0.08:
							door_sweep_blocked += 1
							if door_samples.size() < 8:
								door_samples.append("blocked_by_solid %s aperture=%s vs %s" % [str(door.get("id", "?")), str(aperture), str(sr3)])
							break
					var swing := _sweep_rect(dc, horizontal, half, 0.85)
					for item2: Dictionary in furn:
						var ir2: Rect2 = item2.get("rect", Rect2())
						if swing.intersection(ir2).get_area() > 0.05:
							door_sweep_furniture += 1
							if door_samples.size() < 8:
								door_samples.append("blocked_by_furniture %s swing=%s vs %s" % [str(door.get("id", "?")), str(swing), str(ir2)])
							break
					if not fp.grow(0.05).has_point(dc):
						door_outside += 1
						if door_samples.size() < 8:
							door_samples.append("door_outside %s at %s footprint=%s" % [str(door.get("id", "?")), str(dc), str(fp)])
			# ---- A + D: the emitted mesh ---------------------------------------
			var b := MeshBatcher.new()
			BuildingBuilder.build(b, spec)
			var mesh_specs := b.specs()
			boxes += mesh_specs.size()
			# A. dressings
			for s in mesh_specs:
				var bid := String(s.get("building_id", ""))
				if not dressing.has(bid):
					continue
				dressing[bid] = int(dressing[bid]) + 1
				var pos: Vector3 = s.get("pos", Vector3.ZERO)
				var size: Vector3 = s.get("size", Vector3.ZERO)
				var side := _side_of_local(spec, _to_local(spec, pos))
				var fi := int(s.get("floor_i", 0))
				var stand := _standoff(spec, _to_local(spec, pos), _local_size(spec, size), side)
				if stand < -0.005:
					buried[bid] = int(buried[bid]) + 1
					if absf(stand) > absf(worst_attach):
						worst_attach = stand
						worst_attach_what = "%s buried %.3fm seed=%d" % [bid, stand, seed_value]
				elif stand > 0.60:
					floating[bid] = int(floating[bid]) + 1
					if stand > worst_attach:
						worst_attach = stand
						worst_attach_what = "%s floating %.3fm seed=%d" % [bid, stand, seed_value]
				var length := fp.size.x if (side == 0 or side == 2) else fp.size.y
				var is_entrance := side == int(spec.get("door_edge", 0)) and fi == 0
				var apertures: Array[Dictionary] = BuildingSpec.city_window_openings(length, is_entrance, spec, fi, side)
				var glass_count := 0
				for ap2: Dictionary in apertures:
					if bool(ap2.get("glass", true)):
						glass_count += 1
				var t := _along_local(side, _to_local(spec, pos))
				var best := 1.0e9
				for ap: Dictionary in apertures:
					if not bool(ap.get("glass", true)):
						continue
					var c := float(ap.get("c", 0.0))
					var wd := float(ap.get("wd", 1.0))
					best = minf(best, maxf(absf(t - (c - wd * 0.5)), absf(t - (c + wd * 0.5))))
				if glass_count == 0:
					no_window[bid] = int(no_window[bid]) + 1
				elif best > 1.0:
					off_window[bid] = int(off_window[bid]) + 1
					if best > worst_miss:
						worst_miss = best
						worst_miss_what = "%s %.2fm from any aperture seed=%d" % [bid, best, seed_value]
				if _on_party_wall(spec, rects, side):
					on_party[bid] = int(on_party[bid]) + 1
			# D. connectivity: every box must be attached to something that is
			var loose := _loose_boxes(spec, mesh_specs, fh)
			if not loose.is_empty():
				loose_buildings += 1
				loose_boxes += loose.size()
				for entry: Dictionary in loose:
					var tg := String(entry.get("tag", ""))
					loose_by_tag[tg] = int(loose_by_tag.get(tg, 0)) + 1
					var ls: Vector3 = entry.get("size", Vector3.ZERO)
					var cls := "%s %.1fx%.1fx%.1f" % [tg, ls.x, ls.y, ls.z]
					loose_class[cls] = int(loose_class.get(cls, 0)) + 1
					if loose_samples.size() < 10:
						loose_samples.append("tag='%s' pos=%s size=%s floor=%d" % [tg, str(entry.get("pos", Vector3.ZERO)), str(entry.get("size", Vector3.ZERO)), int(entry.get("floor_i", -1))])
			if diag and diag_done < 2:
				diag_done += 1
				_print_diag(seed_value, spec, mesh_specs, fh)

	var parts_out: Array[String] = []
	parts_out.append("seed=%d ms=%d buildings=%d floors=%d planned_facades=%d dress_candidates=%d" % [
		seed_value, Time.get_ticks_msec() - started, buildings, floors_seen, planned_facades, dress_candidates])
	var names: Array[String] = ["shutter", "flowerbox", "trim", "sill"]
	for n: String in names:
		parts_out.append("%s=%d buried=%d floating=%d no_window=%d off_window=%d on_party=%d" % [
			n, dressing[n], buried[n], floating[n], no_window[n], off_window[n], on_party[n]])
	parts_out.append("props=%d out_of_room=%d overlap=%d on_door=%d on_stair=%d in_wall=%d wall_hung_floating=%d over_ceiling=%d" % [
		items, out_of_room, overlap, on_door, on_stair, in_wall, wall_hung_floating, over_ceiling])
	parts_out.append("doors=%d to_nowhere=%d sweep_solid=%d sweep_furniture=%d no_partition=%d outside=%d wrong_rooms=%d" % [
		doors, door_to_nowhere, door_sweep_blocked, door_sweep_furniture, door_no_partition, door_outside, door_wrong_rooms])
	parts_out.append("boxes=%d loose_boxes=%d in %d buildings" % [boxes, loose_boxes, loose_buildings])
	parts_out.append("legacy_dress sample=%d emitted=%d bad_attach=%d bad_window=%d" % [
		int(fr["counted"]), int(fr["emitted"]), int(fr["bad_attach"]), int(fr["bad_window"])])
	print("[PraguePropsTest] %s" % " ".join(parts_out))
	if worst_attach_what != "":
		print("[PraguePropsTest] worst_attach %s" % worst_attach_what)
	if worst_miss_what != "":
		print("[PraguePropsTest] worst_miss %s" % worst_miss_what)
	var census_rows: Array[String] = []
	for k: String in kind_census.keys():
		census_rows.append("%s=%d" % [k, kind_census[k]])
	census_rows.sort()
	print("[PraguePropsTest] prop_kinds %s" % " ".join(census_rows))
	var tag_rows: Array[String] = []
	for k2: String in loose_by_tag.keys():
		tag_rows.append("'%s'=%d" % [k2, loose_by_tag[k2]])
	tag_rows.sort()
	if not tag_rows.is_empty():
		print("[PraguePropsTest] loose_by_tag %s" % " ".join(tag_rows.slice(0, 12)))
	var class_rows: Array[String] = []
	for k3: String in loose_class.keys():
		class_rows.append("%08d|%s" % [int(loose_class[k3]), k3])
	class_rows.sort()
	class_rows.reverse()
	for row3: String in class_rows.slice(0, 10):
		print("[PraguePropsTest]   loose_class %s" % row3.replace("|", " x "))
	for smp: String in loose_samples:
		print("[PraguePropsTest]   loose: %s" % smp)
	for smp1: String in item_samples:
		print("[PraguePropsTest]   prop: %s" % smp1)
	for smp2: String in door_samples:
		print("[PraguePropsTest]   door: %s" % smp2)

	var total_dress := 0
	for n2: String in names:
		total_dress += int(dressing[n2])
	var total_bad_attach := 0
	var total_bad_place := 0
	for n3: String in names:
		total_bad_attach += int(buried[n3]) + int(floating[n3]) + int(on_party[n3])
		total_bad_place += int(no_window[n3]) + int(off_window[n3])
	check(check_dressing_scope(total_dress, dress_candidates, seed_value),
		"seed=%d facade dressings are actually emitted where they are allowed (%d dressings, %d candidate buildings)" % [seed_value, total_dress, dress_candidates])
	check(total_dress == 0 or total_bad_attach * 100 <= total_dress,
		"seed=%d every facade dressing touches its wall (%d of %d bad)" % [seed_value, total_bad_attach, total_dress])
	check(total_dress == 0 or total_bad_place * 100 <= total_dress,
		"seed=%d every facade dressing sits beside a real window (%d of %d bad)" % [seed_value, total_bad_place, total_dress])
	check(items == 0 or out_of_room == 0, "seed=%d every prop stands inside its own room (%d bad of %d)" % [seed_value, out_of_room, items])
	check(items == 0 or overlap == 0, "seed=%d no prop is placed inside another prop (%d bad of %d)" % [seed_value, overlap, items])
	check(items == 0 or in_wall == 0, "seed=%d no prop is buried in a partition or solid wall (%d bad of %d)" % [seed_value, in_wall, items])
	check(items == 0 or on_door == 0, "seed=%d no prop blocks a door opening (%d bad of %d)" % [seed_value, on_door, items])
	check(items == 0 or on_stair == 0, "seed=%d no prop stands in the stair column (%d bad of %d)" % [seed_value, on_stair, items])
	check(items == 0 or wall_hung_floating == 0, "seed=%d every wall-hung prop is hung on a wall (%d floating of %d)" % [seed_value, wall_hung_floating, items])
	check(items == 0 or over_ceiling * 100 <= items, "seed=%d no prop is taller than its storey (%d of %d)" % [seed_value, over_ceiling, items])
	check(doors == 0 or door_to_nowhere == 0, "seed=%d every door opens into a room on both sides (%d bad of %d)" % [seed_value, door_to_nowhere, doors])
	check(doors == 0 or door_sweep_blocked == 0, "seed=%d no door aperture is blocked by solid geometry (%d bad of %d)" % [seed_value, door_sweep_blocked, doors])
	check(doors == 0 or door_sweep_furniture == 0, "seed=%d no door swing is blocked by furniture (%d bad of %d)" % [seed_value, door_sweep_furniture, doors])
	check(doors == 0 or door_wrong_rooms == 0, "seed=%d every door sits on the wall between the two rooms it claims (%d bad of %d)" % [seed_value, door_wrong_rooms, doors])
	check(doors == 0 or door_outside == 0, "seed=%d every door stands inside its building (%d bad of %d)" % [seed_value, door_outside, doors])
	check(boxes == 0 or loose_boxes * 10000 <= boxes, "seed=%d nothing is emitted floating detached from the building (%d loose of %d boxes)" % [seed_value, loose_boxes, boxes])
	check(int(fr["counted"]) == 0 or int(fr["emitted"]) == 0 or int(fr["bad_attach"]) == 0,
		"seed=%d every legacy window dressing touches its wall (%d bad of %d)" % [seed_value, int(fr["bad_attach"]), int(fr["emitted"])])
	check(int(fr["counted"]) == 0 or int(fr["emitted"]) == 0 or int(fr["bad_window"]) == 0,
		"seed=%d every legacy window dressing sits beside a real opening (%d bad of %d)" % [seed_value, int(fr["bad_window"]), int(fr["emitted"])])


## The Prague core plans every facade, so the legacy shutter / flowerbox /
## lintel families never fire inside it — a zero there would say nothing about
## whether a window dressing hangs on its wall. They still dress the rest of the
## historic radius, so sample those buildings and check the dressings there.
const FRINGE_SAMPLE := 250


func _audit_fringe(seed_value: int, blocks: Array) -> Dictionary:
	var ready: Array[Dictionary] = []
	for block: Dictionary in blocks:
		if bool(block.get("historic_compound", false)) or block.kind != &"built":
			continue
		for spec: Dictionary in block.get("buildings", []) as Array:
			if String(spec.get("district", "")) != "historic" or spec.has("facade_plan"):
				continue
			ready.append(spec)
			if ready.size() >= FRINGE_SAMPLE:
				break
		if ready.size() >= FRINGE_SAMPLE:
			break
	var emitted := 0
	var bad_attach := 0
	var bad_window := 0
	var samples: Array[String] = []
	for spec: Dictionary in ready:
		var b := MeshBatcher.new()
		BuildingBuilder.build(b, spec)
		for s in b.specs():
			var bid := String(s.get("building_id", ""))
			if not (bid == "shutter" or bid == "flowerbox" or bid == "trim" or bid == "sill"):
				continue
			emitted += 1
			var pos: Vector3 = s.get("pos", Vector3.ZERO)
			var size: Vector3 = s.get("size", Vector3.ZERO)
			var local := _to_local(spec, pos)
			var side := _side_of_local(spec, local)
			var stand := _standoff(spec, local, _local_size(spec, size), side)
			if stand < -0.005 or stand > 0.60:
				bad_attach += 1
				if samples.size() < 6:
					samples.append("legacy %s standoff=%.3f at %s" % [bid, stand, str(local)])
			var fp: Rect2 = spec["rect"]
			var length := fp.size.x if (side == 0 or side == 2) else fp.size.y
			var is_entrance := side == int(spec.get("door_edge", 0)) and int(s.get("floor_i", 0)) == 0
			var apertures: Array[Dictionary] = BuildingSpec.city_window_openings(length, is_entrance, spec, int(s.get("floor_i", 0)), side)
			var glass := 0
			for ap: Dictionary in apertures:
				if bool(ap.get("glass", true)):
					glass += 1
			var t := _along_local(side, local)
			var best := 1.0e9
			for ap2: Dictionary in apertures:
				if not bool(ap2.get("glass", true)):
					continue
				var c := float(ap2.get("c", 0.0))
				var wd := float(ap2.get("wd", 1.0))
				best = minf(best, maxf(absf(t - (c - wd * 0.5)), absf(t - (c + wd * 0.5))))
			if glass == 0 or best > 1.0:
				bad_window += 1
				if samples.size() < 12:
					samples.append("legacy %s windows=%d nearest=%.2f at %s" % [bid, glass, best, str(local)])
	for line: String in samples:
		print("[PraguePropsTest]   %s" % line)
	return {"counted": ready.size(), "emitted": emitted, "bad_attach": bad_attach, "bad_window": bad_window}


## A dressing family that is allowed on N buildings but emitted on none of them
## is dead code pretending to be a feature; report it as a finding rather than
## letting a zero read as a pass.
func check_dressing_scope(total_dress: int, candidates: int, seed_value: int) -> bool:
	if candidates == 0:
		return true
	return total_dress > 0


## ---- D. structural connectivity -------------------------------------------
## Union-find over the emitted boxes: two boxes are joined when their AABBs are
## within `tol` of each other. A cluster is attached when it touches the ground,
## reaches the top of the shell, or holds a wall board. Anything left over is a
## box hanging in the air.
func _loose_boxes(spec: Dictionary, specs: Array[Dictionary], fh: float) -> Array[Dictionary]:
	var n := specs.size()
	if n == 0:
		return []
	var parent := PackedInt32Array()
	parent.resize(n)
	for i in n:
		parent[i] = i
	# spatial hash on a 1 m grid
	var grid := {}
	var base_min := 1.0e9
	var top_max := -1.0e9
	for i in n:
		var s: Dictionary = specs[i]
		var p: Vector3 = s.get("pos", Vector3.ZERO)
		var sz: Vector3 = s.get("size", Vector3.ZERO)
		base_min = minf(base_min, p.y - sz.y * 0.5)
		top_max = maxf(top_max, p.y + sz.y * 0.5)
		if maxf(sz.x, sz.z) > BIG_BOX:
			continue
		var lo := Vector2i(int(floor((p.x - sz.x * 0.5) / 1.0)), int(floor((p.z - sz.z * 0.5) / 1.0)))
		var hi := Vector2i(int(floor((p.x + sz.x * 0.5) / 1.0)), int(floor((p.z + sz.z * 0.5) / 1.0)))
		var x0 := clampi(lo.x, -4096, 4096)
		var x1 := clampi(hi.x, -4096, 4096)
		var y0 := clampi(lo.y, -4096, 4096)
		var y1 := clampi(hi.y, -4096, 4096)
		# a box spanning a whole facade would multiply pair checks; those are
		# wall boards, which anchor a cluster anyway.
		if (x1 - x0 + 1) * (y1 - y0 + 1) > 64:
			continue
		for cx in range(x0, x1 + 1):
			for cy in range(y0, y1 + 1):
				var key := Vector2i(cx, cy)
				if not grid.has(key):
					grid[key] = []
				(grid[key] as Array).append(i)
	var pairs := 0
	for key2: Vector2i in grid.keys():
		var bucket: Array = grid[key2]
		for a in bucket.size():
			for b in range(a + 1, bucket.size()):
				pairs += 1
				var i2: int = bucket[a]
				var j2: int = bucket[b]
				if _gap(specs[i2], specs[j2]) <= 0.03:
					_union(parent, i2, j2)
	# Wall boards and slabs anchor their cluster from 0.45 m away: a sill or
	# lintel band sits inside an aperture that has no wall box of its own, and a
	# hung prop sits just off the plaster rather than inside it.
	for key3: Vector2i in grid.keys():
		var bucket3: Array = grid[key3]
		for a3 in bucket3.size():
			for b3 in range(a3 + 1, bucket3.size()):
				var i3: int = bucket3[a3]
				var j3: int = bucket3[b3]
				if not (_anchor_box(specs[i3], fh) or _anchor_box(specs[j3], fh)):
					continue
				if _gap(specs[i3], specs[j3]) <= 0.45:
					_union(parent, i3, j3)
	# roots that touch the ground or the top of the shell
	var attached := {}
	for i4 in n:
		var r := _find(parent, i4)
		if attached.has(r):
			continue
		var s4: Dictionary = specs[i4]
		var p4: Vector3 = s4.get("pos", Vector3.ZERO)
		var sz4: Vector3 = s4.get("size", Vector3.ZERO)
		if p4.y - sz4.y * 0.5 <= base_min + 0.05 or p4.y + sz4.y * 0.5 >= top_max - 0.05:
			attached[r] = true
		elif p4.y - sz4.y * 0.5 <= 0.06:
			attached[r] = true   # stands on the ground plane itself
	for i5 in n:
		if _wall_like(specs[i5], fh):
			attached[_find(parent, i5)] = true
	# A box inside the wall band (or protruding outward from a facade) is mounted
	# on the wall by construction — a pane in an opening, a sill band, a balcony.
	# A box deep inside a room is not, and that is the thing we are hunting.
	var out: Array[Dictionary] = []
	var stair: Rect2 = BuildingBuilder.stair_zone_world(spec).grow(0.35)
	var fp: Rect2 = spec["rect"] as Rect2
	var bigs: Array[Rect2] = _big_boxes(specs)
	for i6 in n:
		if attached.has(_find(parent, i6)):
			continue
		var s6: Dictionary = specs[i6]
		# Anything standing on or inside site-scale structure (a roof prism, a
		# chimney breast, a blocked-out mass) is carried by it.
		if _inside_any(s6, bigs):
			continue
		# The staircase is an assembly, not a prop: its treads and handrail are
		# separate boxes that do not overlap each other by design.
		if stair.has_point(fp.position + _to_local(spec, s6.get("pos", Vector3.ZERO))):
			continue
		if _in_wall_band(spec, s6):
			continue
		out.append({
			"tag": String(s6.get("building_id", "")),
			"pos": s6.get("pos", Vector3.ZERO),
			"size": s6.get("size", Vector3.ZERO),
			"floor_i": int(s6.get("floor_i", -1)),
		})
	return out


## Is this box sitting in the wall band of one of its building's four facades
## (or standing proud of it)? Those are mounted on the wall by construction.
func _in_wall_band(spec: Dictionary, s: Dictionary) -> bool:
	var fp: Rect2 = spec["rect"]
	var band := WALL_T + 0.02
	var p: Vector3 = s.get("pos", Vector3.ZERO)
	var sz: Vector3 = s.get("size", Vector3.ZERO)
	var basis: Basis = s.get("basis", Basis())
	var lo := Vector2(1.0e9, 1.0e9)
	var hi := Vector2(-1.0e9, -1.0e9)
	for sx: float in [-1.0, 1.0]:
		for szn: float in [-1.0, 1.0]:
			var corner: Vector3 = p + basis * Vector3(sz.x * 0.5 * sx, 0.0, sz.z * 0.5 * szn)
			var l := _to_local(spec, corner)
			lo = Vector2(minf(lo.x, l.x), minf(lo.y, l.y))
			hi = Vector2(maxf(hi.x, l.x), maxf(hi.y, l.y))
	if lo.x <= band or lo.y <= band:
		return true
	if hi.x >= fp.size.x - band or hi.y >= fp.size.y - band:
		return true
	return false


## Which room (by id) contains this plan point, if any.
func _room_at(fl: Dictionary, point: Vector2) -> String:
	for room: Dictionary in fl.get("rooms", []) as Array:
		var rr: Rect2 = room.get("rect", Rect2())
		if rr.grow(-0.03).has_point(point):
			return String(room.get("id", ""))
	return ""


## Site-scale boxes are left out of the contact grid (a roof prism would fill
## every cell it spans), so a chimney standing on one looks detached. Collect
## them so containment can be tested directly.
func _big_boxes(specs: Array[Dictionary]) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for s in specs:
		var sz: Vector3 = s.get("size", Vector3.ZERO)
		var p: Vector3 = s.get("pos", Vector3.ZERO)
		if maxf(sz.x, sz.z) > BIG_BOX or bool(s.get("roof", false)):
			out.append(Rect2(p.x - sz.x * 0.5, p.z - sz.z * 0.5, sz.x, sz.z))
	return out


func _inside_any(s: Dictionary, bigs: Array[Rect2]) -> bool:
	var sz: Vector3 = s.get("size", Vector3.ZERO)
	var p: Vector3 = s.get("pos", Vector3.ZERO)
	var r := Rect2(p.x - sz.x * 0.5, p.z - sz.z * 0.5, sz.x, sz.z)
	for b: Rect2 in bigs:
		if b.grow(0.05).encloses(r):
			return true
	return false


## A wall board is full storey height and thin; a slab is flat and wide. Either
## one carries whatever is fixed to it.
func _anchor_box(s: Dictionary, fh: float) -> bool:
	if _wall_like(s, fh):
		return true
	var sz: Vector3 = s.get("size", Vector3.ZERO)
	return sz.y <= 0.4 and maxf(sz.x, sz.z) >= 1.0


func _wall_like(s: Dictionary, fh: float) -> bool:
	var sz: Vector3 = s.get("size", Vector3.ZERO)
	if sz.y < fh * WALL_LIKE_MIN_H:
		return false
	if sz.x > BIG_BOX or sz.z > BIG_BOX:
		return true   # site structure anchors everything it touches
	return minf(sz.x, sz.z) <= WALL_LIKE_MAX_T


## Distance between two axis-aligned boxes: 0 when they touch or overlap.
func _gap(a: Dictionary, b: Dictionary) -> float:
	var pa: Vector3 = a.get("pos", Vector3.ZERO)
	var sa: Vector3 = a.get("size", Vector3.ZERO)
	var pb: Vector3 = b.get("pos", Vector3.ZERO)
	var sb: Vector3 = b.get("size", Vector3.ZERO)
	var g := 0.0
	for axis in 3:
		var amin: float = pa[axis] - sa[axis] * 0.5
		var amax: float = pa[axis] + sa[axis] * 0.5
		var bmin: float = pb[axis] - sb[axis] * 0.5
		var bmax: float = pb[axis] + sb[axis] * 0.5
		g = maxf(g, maxf(amin - bmax, bmin - amax))
	return g


func _find(parent: PackedInt32Array, i: int) -> int:
	var r := i
	while parent[r] != r:
		r = parent[r]
	while parent[i] != r:
		var nxt := parent[i]
		parent[i] = r
		i = nxt
	return r


func _union(parent: PackedInt32Array, i: int, j: int) -> void:
	var ri := _find(parent, i)
	var rj := _find(parent, j)
	if ri != rj:
		parent[ri] = rj


## ---- frame helpers --------------------------------------------------------
## Interior plans and the builder both work in a frame where the footprint's
## min corner is the origin, the wall's OUTER face is the footprint edge and
## the wall occupies WALL_T inward. Emitted mesh boxes are rotated about the
## building centre by its parcel yaw, so undo that before comparing.
func _to_local(spec: Dictionary, pos: Vector3) -> Vector2:
	var fp: Rect2 = spec["rect"] as Rect2
	var c := fp.get_center()
	var yaw := float(spec.get("yaw", 0.0))
	var rel := Vector2(pos.x - c.x, pos.z - c.y)
	var ca := cos(yaw)
	var sa := sin(yaw)
	# Inverse of the batcher's building transform (plan-space yaw maps local +X
	# to (cos, sin) in X/Z). Using the forward rotation here instead put every
	# quarter-turned building's boxes in the wrong frame, which showed up as
	# thousands of "detached" trim bands that are in fact inside their wall.
	var lx := rel.x * ca + rel.y * sa
	var ly := -rel.x * sa + rel.y * ca
	return Vector2(lx + fp.size.x * 0.5, ly + fp.size.y * 0.5)


func _local_size(spec: Dictionary, size: Vector3) -> Vector3:
	var yaw := float(spec.get("yaw", 0.0))
	var swapped := absf(sin(yaw)) > 0.5   # a quarter turn swaps x and z spans
	return Vector3(size.z, size.y, size.x) if swapped else size


func _side_of_local(spec: Dictionary, local: Vector2) -> int:
	var fp: Rect2 = spec["rect"] as Rect2
	var dl := absf(local.y)
	var dr := absf(local.y - fp.size.y)
	var db := absf(local.x)
	var dt := absf(local.x - fp.size.x)
	var best := dl
	var side := 0
	if dr < best:
		best = dr
		side = 2
	if db < best:
		best = db
		side = 3
	if dt < best:
		side = 1
	return side


func _along_local(side: int, local: Vector2) -> float:
	return local.x if (side == 0 or side == 2) else local.y


## How far the dressing protrudes BEYOND the outer wall face (positive =
## standing off the wall, negative = buried in it), measured normal to the
## facade it hangs on.
func _standoff(spec: Dictionary, local: Vector2, size: Vector3, side: int) -> float:
	var fp: Rect2 = spec["rect"] as Rect2
	match side:
		0:
			return local.y - size.z * 0.5
		2:
			return (fp.size.y - local.y) - size.z * 0.5
		1:
			return (fp.size.x - local.x) - size.x * 0.5
		_:
			return local.x - size.x * 0.5


## InteriorPlan stores door positions with the plan's 2D coordinates in (x, z),
## exactly as BuildingBuilder reads them.
func _door_plan_point(door: Dictionary) -> Vector2:
	var dp: Vector3 = door.get("position", Vector3.ZERO)
	return Vector2(dp.x, dp.z)


func _stair_zone_local(spec: Dictionary) -> Rect2:
	var fp: Rect2 = spec["rect"] as Rect2
	var zone: Rect2 = BuildingBuilder.stair_zone_world(spec)
	var centre := fp.get_center()
	return Rect2(zone.position - Vector2(centre.x, centre.y) + fp.size * 0.5, zone.size)


## Clear rectangle on both sides of a door opening: `half` along the opening,
## `deep` across it (each side), in the door's own frame.
func _sweep_rect(c: Vector2, horizontal: bool, half: float, deep: float) -> Rect2:
	if horizontal:
		return Rect2(c.x - half, c.y - deep, half * 2.0, deep * 2.0)
	return Rect2(c.x - deep, c.y - half, deep * 2.0, half * 2.0)


func _door_sweep(door: Dictionary) -> Rect2:
	var yaw := float(door.get("yaw", 0.0))
	var dw := float(door.get("width", 1.2))
	return _sweep_rect(_door_plan_point(door), absf(yaw) < 0.01, dw * 0.5 + 0.06, 0.55)


## Print, for one building, the emitted box count by owner tag plus the local
## span of the shell — the measurement the connectivity verdict rests on.
func _print_diag(seed_value: int, spec: Dictionary, specs: Array[Dictionary], fh: float) -> void:
	var by_tag := {}
	var ymin := 1.0e9
	var ymax := -1.0e9
	for s in specs:
		var tg := String(s.get("building_id", ""))
		by_tag[tg] = int(by_tag.get(tg, 0)) + 1
		var p: Vector3 = s.get("pos", Vector3.ZERO)
		var sz: Vector3 = s.get("size", Vector3.ZERO)
		ymin = minf(ymin, p.y - sz.y * 0.5)
		ymax = maxf(ymax, p.y + sz.y * 0.5)
	var rows: Array[String] = []
	for k: String in by_tag.keys():
		rows.append("'%s'=%d" % [k, by_tag[k]])
	rows.sort()
	print("[PraguePropsTest] diag seed=%d %s fp=%s yaw=%.3f facade_plan=%s y=[%.2f,%.2f] tags=%s" % [
		seed_value, str(spec.get("id", "?")), str(spec["rect"]), float(spec.get("yaw", 0.0)),
		str(spec.has("facade_plan")), ymin, ymax, " ".join(rows)])
	print("[PraguePropsTest] diag   loose_found=%d" % _loose_boxes(spec, specs, fh).size())


## True when this facade is a shared face: another footprint in the same block
## stands within 0.25 m of it and overlaps its span. Nobody hangs shutters on a
## party wall.
func _on_party_wall(spec: Dictionary, rects: Array[Rect2], side: int) -> bool:
	var fp: Rect2 = spec["rect"] as Rect2
	for r: Rect2 in rects:
		if r.position.is_equal_approx(fp.position) and r.size.is_equal_approx(fp.size):
			continue
		match side:
			0:
				if absf(r.end.y - fp.position.y) < 0.25 and _span_overlap(r.position.x, r.end.x, fp.position.x, fp.end.x):
					return true
			2:
				if absf(r.position.y - fp.end.y) < 0.25 and _span_overlap(r.position.x, r.end.x, fp.position.x, fp.end.x):
					return true
			3:
				if absf(r.end.x - fp.position.x) < 0.25 and _span_overlap(r.position.y, r.end.y, fp.position.y, fp.end.y):
					return true
			_:
				if absf(r.position.x - fp.end.x) < 0.25 and _span_overlap(r.position.y, r.end.y, fp.position.y, fp.end.y):
					return true
	return false


func _span_overlap(a0: float, a1: float, b0: float, b1: float) -> bool:
	return minf(a1, b1) - maxf(a0, b0) > 0.5


func check(ok: bool, label: String) -> void:
	if ok:
		return
	failures += 1
	print("[PraguePropsTest] FAIL %s" % label)
