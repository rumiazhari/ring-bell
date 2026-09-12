extends Node
## Measure the city's BLANK space per chunk, and the geometry cost of the
## tree system, so "fill blank space with trees" is designed against measured
## numbers instead of a guess.
##
##   godot --headless --path . -- --citygreenprobe [radius]
##
## Reports, per chunk: block area by kind, building footprint, courtyard area,
## passage area, and the remaining OPEN ground a tree could stand on (block
## polygon minus buildings grown by a clearance, minus courtyards, minus
## passages), plus how many trees that supports at a given spacing. Then the
## per-species part/vertex cost at each TreeBuilder detail tier.

const OUT_TSV := "res://captures/city-green/open_ground.tsv"

var _rows: Array[Dictionary] = []


func _ready() -> void:
	var radius := 2
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--citygreenprobe" and i + 1 < args.size():
			radius = maxi(0, mini(3, int(args[i + 1])))

	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()

	_measure_chunks(plan, world_plan, radius)
	_probe_road_profile(plan, world_plan, radius)
	_measure_tree_cost()
	_write_tsv()
	get_tree().quit(0)


## Where does the pavement live relative to the block polygons? Sample points
## perpendicular to every street at increasing offsets from the centreline and
## report which surface each lands on, so the tree pass plants in a band that
## really exists instead of one assumed from the block comment.
func _probe_road_profile(plan: CityPlan, _world_plan: WorldPlan, radius: int) -> void:
	const OFFSETS := [0.2, 1.2, 2.2, 3.2, 4.2]
	print("[GreenProbe] === street cross-section (offset beyond road half-width) ===")
	var buckets := {}
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := Vector2i(dx, dz)
			var rect := WorldSeed.chunk_rect(coord)
			for edge: Dictionary in plan.city_road_segments_in(rect):
				var poly: PackedVector2Array = edge["polyline"] as PackedVector2Array
				var half_w := float(edge["width"]) * 0.5
				for i in range(1, poly.size()):
					var a: Vector2 = poly[i - 1]
					var c: Vector2 = poly[i]
					var seg := c - a
					if seg.length() < 0.001:
						continue
					var n := Vector2(-seg.y, seg.x).normalized()
					var mid := (a + c) * 0.5
					for side: float in [-1.0, 1.0]:
						for off: float in OFFSETS:
							var p := mid + n * side * (half_w + off)
							var key := "%.1f" % off
							if not buckets.has(key):
								buckets[key] = {"n": 0, "built": 0, "plaza": 0, "park": 0,
									"none": 0, "building": 0, "court": 0}
							var bkt: Dictionary = buckets[key]
							bkt["n"] = int(bkt["n"]) + 1
							var block := _block_at(plan, p)
							if block.is_empty():
								bkt["none"] = int(bkt["none"]) + 1
								continue
							var kind := String(block.get("kind", &""))
							if kind == "built" or kind == "plaza" or kind == "park":
								bkt[kind] = int(bkt[kind]) + 1
							else:
								bkt["none"] = int(bkt["none"]) + 1
							if _in_building(block, p):
								bkt["building"] = int(bkt["building"]) + 1
							if _in_court(block, p):
								bkt["court"] = int(bkt["court"]) + 1
	for key: String in ["0.2", "1.2", "2.2", "3.2", "4.2"]:
		var bkt: Dictionary = buckets.get(key, {})
		if bkt.is_empty():
			continue
		print("[GreenProbe] +%sm n=%d built=%d plaza=%d park=%d none=%d | inBuilding=%d inCourt=%d" % [
			key, bkt["n"], bkt["built"], bkt["plaza"], bkt["park"], bkt["none"],
			bkt["building"], bkt["court"]])


func _block_at(plan: CityPlan, p: Vector2) -> Dictionary:
	for cell in plan.cells_in_rect(Rect2(p - Vector2.ONE, Vector2(2, 2))):
		var block := plan.cell_block(cell)
		if block.is_empty():
			continue
		var poly: PackedVector2Array = block.get("polygon",
			PackedVector2Array()) as PackedVector2Array
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
			return block
	return {}


func _in_building(block: Dictionary, p: Vector2) -> bool:
	for spec_variant in block.get("buildings", []) as Array:
		var spec: Dictionary = spec_variant as Dictionary
		if CityPlan._spec_world_bounds(spec).has_point(p):
			return true
	return false


func _in_court(block: Dictionary, p: Vector2) -> bool:
	for region_variant in block.get("courtyard_regions", []) as Array:
		var region: Dictionary = region_variant as Dictionary
		var poly: PackedVector2Array = region.get("polygon",
			PackedVector2Array()) as PackedVector2Array
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


func _measure_chunks(plan: CityPlan, world_plan: WorldPlan, radius: int) -> void:
	var totals := {
		"blocks": 0, "block_area": 0.0, "built_area": 0.0, "plaza_area": 0.0,
		"park_area": 0.0, "building_area": 0.0, "courtyard_area": 0.0,
		"passage_area": 0.0, "open_area": 0.0,
	}
	var kinds := {}
	var open_total := 0.0
	var chunks := 0
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := Vector2i(dx, dz)
			var rect := WorldSeed.chunk_rect(coord)
			var row := {
				"coord": str(coord), "block_area": 0.0, "building": 0.0,
				"courtyard": 0.0, "passage": 0.0, "open": 0.0,
				"open_polys": 0, "trees_6m": 0, "trees_8m": 0,
			}
			chunks += 1
			var door_pts: Array[Vector2] = []
			for spec in plan.buildings_in_rect(rect.grow(8.0)):
				for dm in spec.get("doors", []):
					var dp: Vector3 = dm["position"]
					door_pts.append(Vector2(dp.x, dp.z))
			for cell in plan.cells_in_rect(rect):
				var block := plan.cell_block(cell)
				if block.is_empty():
					continue
				var bounds: Rect2 = block.get("bounds", block.get("rect", Rect2())) as Rect2
				if not bounds.intersects(rect):
					continue
				var kind := String(block.get("kind", &""))
				kinds[kind] = int(kinds.get(kind, 0)) + 1
				totals["blocks"] = int(totals["blocks"]) + 1
				var poly: PackedVector2Array = block.get("polygon",
					PackedVector2Array()) as PackedVector2Array
				var clipped := ChunkBuilder._clip_polygon_to_rect(poly, rect)
				var chunk_block_area := ChunkBuilder._polygon_area(clipped) \
					if clipped.size() >= 3 else 0.0
				row["block_area"] = float(row["block_area"]) + chunk_block_area
				totals["block_area"] = float(totals["block_area"]) + chunk_block_area
				if kind == "built":
					totals["built_area"] = float(totals["built_area"]) + chunk_block_area
				elif kind == "plaza":
					totals["plaza_area"] = float(totals["plaza_area"]) + chunk_block_area
				else:
					totals["park_area"] = float(totals["park_area"]) + chunk_block_area
				if kind != "built":
					continue
				# Building footprints, grown by the tree clearance.
				var footprints: Array[Rect2] = []
				for spec_variant in block.get("buildings", []) as Array:
					var spec: Dictionary = spec_variant as Dictionary
					var fp := CityPlan._spec_world_bounds(spec).grow(2.0)
					footprints.append(fp)
					var rarea0 := _rect_clipped_area(fp, rect)
					row["building"] = float(row["building"]) + rarea0
					totals["building_area"] = float(totals["building_area"]) + rarea0
				var courts: Array = []
				for region_variant in block.get("courtyard_regions", []) as Array:
					var region: Dictionary = region_variant as Dictionary
					var rpoly: PackedVector2Array = region.get("polygon",
						PackedVector2Array()) as PackedVector2Array
					var rclip := ChunkBuilder._clip_polygon_to_rect(rpoly, rect)
					if rclip.size() < 3:
						continue
					courts.append(rpoly)
					var rarea := ChunkBuilder._polygon_area(rclip)
					row["courtyard"] = float(row["courtyard"]) + rarea
					totals["courtyard_area"] = float(totals["courtyard_area"]) + rarea
				var passage: Dictionary = block.get("passage", {}) as Dictionary
				var ppoly: PackedVector2Array = passage.get("polygon",
					PackedVector2Array()) as PackedVector2Array
				if ppoly.size() >= 3:
					var pclip := ChunkBuilder._clip_polygon_to_rect(ppoly, rect)
					if pclip.size() >= 3:
						var parea := ChunkBuilder._polygon_area(pclip)
						row["passage"] = float(row["passage"]) + parea
						totals["passage_area"] = float(totals["passage_area"]) + parea
				if clipped.size() < 3:
					continue
				row["open_polys"] = int(row["open_polys"]) + 1
				_count_open(rect, clipped, footprints, courts, ppoly, door_pts, row)
			totals["open_area"] = float(totals["open_area"]) + float(row["open"])
			open_total += float(row["open"])
			_rows.append(row)
			print("[GreenProbe] %s block=%.0f build=%.0f court=%.0f passage=%.0f open=%.0f trees@6m=%d trees@8m=%d" % [
				row["coord"], row["block_area"], row["building"], row["courtyard"],
				row["passage"], row["open"], row["trees_6m"], row["trees_8m"]])
	print("[GreenProbe] === TOTALS over %d chunks ===" % chunks)
	print("[GreenProbe] blocks %d area=%.0f built=%.0f plaza=%.0f park=%.0f" % [
		totals["blocks"], totals["block_area"], totals["built_area"],
		totals["plaza_area"], totals["park_area"]])
	print("[GreenProbe] building=%.0f courtyard=%.0f passage=%.0f OPEN=%.0f" % [
		totals["building_area"], totals["courtyard_area"], totals["passage_area"],
		totals["open_area"]])
	print("[GreenProbe] kinds %s   open mean per chunk %.0f m2" % [
		JSON.stringify(kinds), open_total / maxf(1.0, float(chunks))])


## Grid-sample a built block's open ground: accept a point when it is inside the
## block and this chunk, clear of buildings/courtyards/passages/doors, and at
## least `spacing` from the previous accept.
func _count_open(rect: Rect2, poly: PackedVector2Array, footprints: Array[Rect2],
		courts: Array, ppoly: PackedVector2Array, door_pts: Array[Vector2],
		row: Dictionary) -> void:
	for spec: Dictionary in [
			{"spacing": 6.0, "key": "trees_6m"}, {"spacing": 8.0, "key": "trees_8m"}]:
		var spacing := float(spec["spacing"])
		var rng := WorldSeed.rng_for("open_probe",
			[int(rect.position.x), int(rect.position.y), int(spacing * 10.0)])
		var accepted: Array[Vector2] = []
		var x := rect.position.x + 1.0
		while x < rect.end.x - 1.0:
			var z := rect.position.y + 1.0
			while z < rect.end.y - 1.0:
				var p := Vector2(x + rng.randf_range(-1.4, 1.4), z + rng.randf_range(-1.4, 1.4))
				z += spacing
				if not Geometry2D.is_point_in_polygon(p, poly):
					continue
				if WorldSeed.chunk_coord(p.x, p.y) != WorldSeed.chunk_coord(
						rect.position.x + 0.5, rect.position.y + 0.5):
					continue
				var blocked := false
				for fp: Rect2 in footprints:
					if fp.has_point(p):
						blocked = true
						break
				if blocked:
					continue
				for cpoly: PackedVector2Array in courts:
					if Geometry2D.is_point_in_polygon(p, cpoly):
						blocked = true
						break
				if blocked:
					continue
				if ppoly.size() >= 3 and Geometry2D.is_point_in_polygon(p, ppoly):
					continue
				for d: Vector2 in door_pts:
					if d.distance_to(p) < 2.6:
						blocked = true
						break
				if blocked:
					continue
				var too_close := false
				for q: Vector2 in accepted:
					if q.distance_to(p) < spacing:
						too_close = true
						break
				if too_close:
					continue
				accepted.append(p)
			x += spacing
		if spacing == 6.0:
			row["open"] = float(accepted.size()) * spacing * spacing
		row[spec["key"]] = maxi(int(row[spec["key"]]), accepted.size())


func _rect_clipped_area(r: Rect2, clip: Rect2) -> float:
	var i := r.intersection(clip)
	return maxf(0.0, i.size.x) * maxf(0.0, i.size.y)


## Per-species geometry cost at each detail tier, measured by generating the
## real parts (not read off the caps table).
func _measure_tree_cost() -> void:
	print("[GreenProbe] === tree geometry cost ===")
	for detail: int in [TreeBuilder.Detail.IMPOSTOR, TreeBuilder.Detail.CITY,
			TreeBuilder.Detail.FEATURE]:
		var parts_total := 0
		var verts_total := 0
		var n := 0
		var worst_parts := 0
		var worst_verts := 0
		var worst_species := ""
		for species: StringName in TreeBuilder.PARK_MIX:
			for i in 6:
				var seed_v := int(WorldSeed.combine([species.hash(), i, detail]))
				var b := MeshBatcher.new()
				var stats := TreeBuilder.build(b, Vector3.ZERO, species,
					{"seed": seed_v, "detail": detail})
				var parts := int(stats["parts"])
				parts_total += parts
				verts_total += int(stats["verts"])
				n += 1
				if parts > worst_parts:
					worst_parts = parts
					worst_verts = int(stats["verts"])
					worst_species = String(species)
		var label: String = ["IMPOSTOR", "CITY", "FEATURE"][detail]
		print("[GreenProbe] %s avg parts=%.1f verts=%.0f | worst %s parts=%d verts=%d" % [
			label, float(parts_total) / float(n), float(verts_total) / float(n),
			worst_species, worst_parts, worst_verts])


func _write_tsv() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
		OUT_TSV.get_base_dir()))
	var f := FileAccess.open(OUT_TSV, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("coord\tblock_area\tbuilding\tcourtyard\tpassage\topen\ttrees_6m\ttrees_8m")
	for row: Dictionary in _rows:
		f.store_line("%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d" % [
			row["coord"], row["block_area"], row["building"], row["courtyard"],
			row["passage"], row["open"], row["trees_6m"], row["trees_8m"]])
	f.close()
	print("[GreenProbe] wrote %s" % OUT_TSV)
