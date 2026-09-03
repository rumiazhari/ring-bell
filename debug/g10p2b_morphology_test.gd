extends Node
## Focused, headless-safe G10-P2B morphology acceptance probe.
## It validates the plan/contract layer; visual acceptance uses the live capture probe.

var _failures: Array[String] = []


func _ready() -> void:
	var seed_a := 19041207
	var seed_b := 19041208
	var plan_a := CityPlan.new(seed_a)
	var plan_a_repeat := CityPlan.new(seed_a)
	var plan_b := CityPlan.new(seed_b)
	_check_plan(plan_a, "A")
	_check_plan(plan_a_repeat, "A-repeat")
	_check_plan(plan_b, "B")
	_check_surface_datum(plan_a, "A")
	_check_surface_datum(plan_b, "B")
	_check_foundation_access(plan_a, "A")
	_check_foundation_access(plan_b, "B")
	_check_same_seed(plan_a, plan_a_repeat)
	_check_different_seed(plan_a, plan_b)
	_check_triangulation(plan_a, "A")
	_check_triangulation(plan_b, "B")
	_check_hub_distribution(plan_a, "A")
	_check_hub_distribution(plan_b, "B")
	_check_lamp_spacing(plan_a, "A")
	_check_lamp_spacing(plan_b, "B")
	if _failures.is_empty():
		print("[G10P2BMorphology] PASS all focused checks")
	else:
		for failure in _failures:
			print("[G10P2BMorphology] FAIL ", failure)
	get_tree().quit(_failures.size())


func _check_plan(plan: CityPlan, label: String) -> void:
	var graph: Dictionary = plan.road_graph()
	var nodes: Array = graph.get("nodes", []) as Array
	var edges: Array = graph.get("edges", []) as Array
	var blocks: Array[Dictionary] = plan.city_blocks()
	var buildings: Array[Dictionary] = plan.city_buildings()
	_expect(nodes.size() >= 60, label + " road nodes >= 60")
	_expect(edges.size() >= 70, label + " road edges >= 70")
	_expect(_is_connected(graph), label + " road graph connected")
	var primary := 0
	var secondary := 0
	var local := 0
	var alley := 0
	var bridges := 0
	var curved := 0
	var diagonal_segments := 0
	var core_fine_routes := 0
	var core_alleys := 0
	var node_tangents: Dictionary = {}
	for edge: Dictionary in edges:
		match edge.get("hierarchy", &""):
			&"primary": primary += 1
			&"secondary": secondary += 1
			&"local": local += 1
			&"alley": alley += 1
		if bool(edge.get("is_bridge", false)):
			bridges += 1
		var a_center: Vector2 = edge.get("a_center", Vector2.INF) as Vector2
		var b_center: Vector2 = edge.get("b_center", Vector2.INF) as Vector2
		var edge_hierarchy: StringName = edge.get("hierarchy", &"") as StringName
		if a_center.length() < 300.0 and b_center.length() < 300.0:
			if edge_hierarchy == &"local" or edge_hierarchy == &"alley":
				core_fine_routes += 1
			if edge_hierarchy == &"alley":
				core_alleys += 1
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() >= 3:
			curved += 1
		if poly.size() >= 2:
			var tangent := (poly[1] - poly[0]).normalized()
			if absf(tangent.x) > 0.12 and absf(tangent.y) > 0.12:
				diagonal_segments += 1
			var a_id := str(edge.get("a", ""))
			var b_id := str(edge.get("b", ""))
			node_tangents.get_or_add(a_id, []).append(tangent)
			node_tangents.get_or_add(b_id, []).append((poly[poly.size() - 2] - poly[poly.size() - 1]).normalized())
	var non_right := 0
	for directions_variant in node_tangents.values():
		var directions: Array = directions_variant as Array
		for i in range(directions.size()):
			for j in range(i + 1, directions.size()):
				if absf((directions[i] as Vector2).dot(directions[j] as Vector2)) < 0.94:
					non_right += 1
	_expect(primary >= 12, label + " primary radial routes")
	_expect(secondary >= 15, label + " secondary connectors")
	_expect(local >= 20, label + " local streets")
	_expect(alley >= 10, label + " historic alleys")
	_expect(bridges >= 2, label + " river crossings")
	_expect(curved >= 20, label + " curved routes")
	_expect(diagonal_segments >= 10, label + " diagonal route segments")
	_expect(non_right >= 20, label + " non-90-degree bends/junction approach")
	print("[G10P2BMorphology] ", label, " core_fine_routes=", core_fine_routes,
			" core_alleys=", core_alleys)
	_expect(core_fine_routes >= 14, label + " historic core fine routes")
	_expect(core_alleys >= 6, label + " historic core narrow alleys")
	_expect(blocks.size() >= 160, label + " irregular blocks")
	var irregular := 0
	for block: Dictionary in blocks:
		var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
		if poly.size() >= 5:
			irregular += 1
	_expect(irregular >= 80, label + " blocks have non-rectangular footprints")
	_expect(buildings.size() >= 700, label + " dense building fabric")
	_check_frontage_density(plan, label)
	_check_block_ownership(plan, label)
	for spec: Dictionary in buildings:
		_expect(spec.get("quality", WorldConstants.BUILDING_QUALITY_FULL_BUILDING) == WorldConstants.BUILDING_QUALITY_FULL_BUILDING, label + " building is full quality")
		var archetype: StringName = spec.get("archetype", &"") as StringName
		_expect(archetype == &"house" or archetype == &"tenement" or archetype == &"shop_house", label + " building has current city archetype")
		if not plan._lot_clear_of_city_roads(spec.get("rect", Rect2()) as Rect2,
					float(spec.get("yaw", 0.0))):
			_failures.append(label + " building/road clearance " + str(spec.get("id", "")))
			break
	var extent := plan.city_extent()
	print("[G10P2BMorphology] ", label, " nodes=", nodes.size(), " edges=", edges.size(),
			" blocks=", blocks.size(), " buildings=", buildings.size(), " extent=", extent)
	_expect(float(extent.get("dense_radius_m", 0.0)) >= 600.0, label + " dense radius target")
	_expect(float(extent.get("influence_radius_m", 0.0)) >= 1300.0, label + " influence radius target")
	_check_fabric_metrics(plan, label)
	_expect(plan.validate_area(Rect2(-950.0, -950.0, 1900.0, 1900.0)).is_empty(), label + " no block/building overlaps")


func _check_surface_datum(plan: CityPlan, label: String) -> void:
	# City buildings and roads must share WorldPlan's realized outdoor surface.
	# This samples an outer building where terrain is non-flat, then inspects
	# the actual universal-assembler slab and city-road ribbon boxes.
	var world := WorldPlan.new(plan.seed_used)
	var river_x := world.hydrology.river_center_x_at(0.0)
	var river_half := world.hydrology.river_half_width_at(0.0)
	var bank_inner := Vector2(river_x + river_half + WorldConstants.BANK_W - 0.05, 0.0)
	var bank_outer := Vector2(river_x + river_half + WorldConstants.BANK_W + 0.05, 0.0)
	var bank_jump := absf(world.surface_height_at(bank_inner) - world.surface_height_at(bank_outer))
	_expect(bank_jump <= 0.35,
			label + " river-bank surface is continuous (%.3f m)" % bank_jump)
	var target: Dictionary = {}
	for spec: Dictionary in plan.city_buildings():
		var center: Vector2 = (spec["rect"] as Rect2).get_center()
		if absf(world.surface_height_at(center)) > 0.4:
			target = spec
			break
	_expect(not target.is_empty(), label + " non-flat city building sample")
	if target.is_empty():
		return
	var grounded: Dictionary = ChunkBuilder._grounded_spec(target, world)
	var batcher := MeshBatcher.new()
	UniversalBuildingAssembler.build_into(batcher, grounded)
	var tag := str(target["id"])
	var expected_ground := float(grounded.get("building_ground_y", grounded["ground_y"]))
	var slab_found := false
	var slab_error := INF
	for s: Dictionary in batcher.specs():
		if str(s.get("layer", "")) != tag + ":f0":
			continue
		var size: Vector3 = s["size"] as Vector3
		if absf(size.y - BuildingBuilder.SLAB_T) > 0.001:
			continue
		var pos: Vector3 = s["pos"] as Vector3
		slab_found = true
		slab_error = absf(pos.y + size.y * 0.5 - (expected_ground - 0.02))
		break
	_expect(slab_found, label + " grounded city slab exists")
	if slab_found:
		_expect(slab_error <= 0.05,
				label + " city building slab follows surface (%.3f m)" % slab_error)

	var graph: Dictionary = plan.city_road_graph()
	var edges: Array = graph.get("edges", []) as Array
	var road_samples := 0
	var road_max_error := 0.0
	var road_max_endpoint_error := 0.0
	for edge: Dictionary in edges:
		if bool(edge.get("is_bridge", false)):
			continue
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var coord := WorldSeed.chunk_coord(poly[0].x, poly[0].y)
		var road_batch := MeshBatcher.new()
		ChunkBuilder._roads(road_batch, plan, WorldSeed.chunk_rect(coord), world)
		for rs: Dictionary in road_batch.specs():
			if bool(rs.get("collide", false)):
				continue
			var rsize: Vector3 = rs["size"] as Vector3
			if absf(rsize.y - 0.11) > 0.01:
				continue
			var rpos: Vector3 = rs["pos"] as Vector3
			var road_p := Vector2(rpos.x, rpos.z)
			var nearest_edge_distance := INF
			var nearest_is_bridge := false
			for candidate: Dictionary in edges:
				var candidate_poly: PackedVector2Array = candidate.get("polyline", PackedVector2Array()) as PackedVector2Array
				var candidate_distance := CityPlan._distance_to_polyline(road_p, candidate_poly)
				if candidate_distance < nearest_edge_distance:
					nearest_edge_distance = candidate_distance
					nearest_is_bridge = bool(candidate.get("is_bridge", false))
			if nearest_is_bridge:
				continue
			road_max_error = maxf(road_max_error,
					absf(rpos.y - (world.surface_height_at(road_p) + 0.055)))
			var basis: Basis = rs["basis"] as Basis
			var half_length := maxf(rsize.z * 0.5 - 0.06, 0.0)
			var half_vector := basis * Vector3(0.0, 0.0, half_length)
			for endpoint: Vector3 in [rpos - half_vector, rpos + half_vector]:
				var endpoint_p := Vector2(endpoint.x, endpoint.z)
				road_max_endpoint_error = maxf(road_max_endpoint_error,
						absf(endpoint.y - (world.surface_height_at(endpoint_p) + 0.055)))
			road_samples += 1
			if road_samples >= 4:
				break
		if road_samples >= 4:
			break
	_expect(road_samples >= 4, label + " city road Y samples")
	_expect(road_max_error <= 0.08,
			label + " city road centers follow surface (%.3f m)" % road_max_error)
	_expect(road_max_endpoint_error <= 0.35,
			label + " city road endpoints follow surface (%.3f m)" % road_max_endpoint_error)
	print("[G10P2BMorphology] ", label, " surface_y building_error=", slab_error,
			" road_samples=", road_samples, " road_error=", road_max_error,
			" road_endpoint_error=", road_max_endpoint_error)


func _check_foundation_access(plan: CityPlan, label: String) -> void:
	var world := WorldPlan.new(plan.seed_used)
	var grounded_target: Dictionary = {}
	var elevated_count := 0
	var access_count := 0
	var porch_count := 0
	var veranda_count := 0
	var plain_count := 0
	for spec: Dictionary in plan.city_buildings():
		var grounded := ChunkBuilder._grounded_spec(spec, world)
		var modules: Array = grounded.get("foundation_modules", []) as Array
		if not bool(grounded.get("foundation_enabled", false)) or modules.size() < 4:
			continue
		elevated_count += 1
		if grounded_target.is_empty():
			grounded_target = grounded
		var candidate_access: Dictionary = grounded.get("access", {}) as Dictionary
		if not bool(candidate_access.get("enabled", false)):
			continue
		access_count += 1
		match str(candidate_access.get("kind", "")):
			"porch": porch_count += 1
			"veranda": veranda_count += 1
			"none": plain_count += 1
	_expect(elevated_count > 0, label + " has elevated foundation targets")
	_expect(access_count == elevated_count,
			label + " every foundation has exterior access (%d/%d)" % [access_count, elevated_count])
	_expect(porch_count + veranda_count + plain_count == access_count,
			label + " access modes are porch/veranda/none")
	if grounded_target.is_empty():
		return
	var id := str(grounded_target["id"])
	var building_ground := float(grounded_target.get("building_ground_y", 0.0))
	var natural_ground := float(grounded_target.get("ground_y", 0.0))
	_expect(building_ground > natural_ground + BuildingBuilder.FOUNDATION_TOP_CLEARANCE - 0.01,
			label + " foundation raises building datum")
	var batcher := MeshBatcher.new()
	UniversalBuildingAssembler.build_into(batcher, grounded_target)
	var build_errors: Array[String] = BuildingContractValidator.validate_build(grounded_target, batcher)
	_expect(build_errors.is_empty(), label + " elevated building passes full contract: " + str(build_errors))
	var foundation_count := 0
	var foundation_top_error := 0.0
	for built: Dictionary in batcher.specs():
		var layer := str(built.get("layer", ""))
		if layer != id + ":foundation":
			continue
		foundation_count += 1
		var pos: Vector3 = built["pos"] as Vector3
		var size: Vector3 = built["size"] as Vector3
		foundation_top_error = maxf(foundation_top_error,
				absf(pos.y + size.y * 0.5 - (building_ground - BuildingBuilder.SLAB_T - 0.02)))
	_expect(foundation_count >= 4, label + " emits four foundation modules")
	_expect(foundation_top_error <= 0.05,
			label + " foundation tops support slab (%.3f m)" % foundation_top_error)

	var access: Dictionary = grounded_target.get("access", {}) as Dictionary
	_expect(bool(access.get("enabled", false)), label + " elevated building has exterior access")
	var kind := str(access.get("kind", ""))
	_expect(kind == "porch" or kind == "veranda" or kind == "none",
			label + " access kind is deterministic porch/veranda/none")
	var access_ramps := 0
	for built2: Dictionary in batcher.specs():
		if not str(built2.get("layer", "")).begins_with(id + ":access"):
			continue
		if not bool(built2.get("collide", false)):
			continue
		if built2.get("material", &"") != &"concrete":
			continue
		var ramp_size: Vector3 = built2["size"] as Vector3
		var ramp_basis: Basis = built2["basis"] as Basis
		if ramp_size.z >= BuildingBuilder.ACCESS_MIN_RUN - 0.05 and ramp_basis != Basis.IDENTITY:
			access_ramps += 1
	_expect(access_ramps >= 1, label + " exterior access ramp collides")
	for dm: Dictionary in grounded_target.get("doors", []):
		var door_pos: Vector3 = dm.get("position", Vector3.ZERO) as Vector3
		_expect(absf(door_pos.y - building_ground) <= 0.05,
				label + " elevated entrance uses building datum")
	print("[G10P2BMorphology] ", label, " foundation modules=", foundation_count,
			" elevated_count=", elevated_count, " access_count=", access_count,
			" porch=", porch_count, " veranda=", veranda_count, " none=", plain_count,
			" access=", kind, " ramp_count=", access_ramps,
			" building_ground=", building_ground, " natural_ground=", natural_ground)


func _check_frontage_density(plan: CityPlan, label: String) -> void:
	var core_area := 0.0
	var inner_area := 0.0
	var core_footprints := 0.0
	var inner_footprints := 0.0
	var core_buildings := 0
	var inner_buildings := 0
	var core_near_road := 0
	var inner_near_road := 0
	var core_block_areas: Array[float] = []
	var inner_block_areas: Array[float] = []
	for block: Dictionary in plan.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		var block_area := absf(_polygon_area(block.get("polygon", PackedVector2Array()) as PackedVector2Array))
		if center.length() < WorldConstants.CITY_HISTORIC_RADIUS_M:
			core_area += block_area
			core_block_areas.append(block_area)
		elif center.length() < 600.0:
			inner_area += block_area
			inner_block_areas.append(block_area)
	for spec: Dictionary in plan.city_buildings():
		var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
		var radius := rect.get_center().length()
		var footprint := rect.size.x * rect.size.y
		if radius < WorldConstants.CITY_HISTORIC_RADIUS_M:
			core_footprints += footprint
			core_buildings += 1
			if plan._distance_to_city_road_raw(rect.get_center()) <= 20.0:
				core_near_road += 1
		elif radius < 600.0:
			inner_footprints += footprint
			inner_buildings += 1
			if plan._distance_to_city_road_raw(rect.get_center()) <= 20.0:
				inner_near_road += 1
	var core_ratio := core_footprints / maxf(core_area, 1.0)
	var inner_ratio := inner_footprints / maxf(inner_area, 1.0)
	var core_road_ratio := float(core_near_road) / maxf(float(core_buildings), 1.0)
	var inner_road_ratio := float(inner_near_road) / maxf(float(inner_buildings), 1.0)
	core_block_areas.sort()
	inner_block_areas.sort()
	var core_median_area: float = core_block_areas[int(core_block_areas.size() * 0.5)] if not core_block_areas.is_empty() else INF
	var inner_median_area: float = inner_block_areas[int(inner_block_areas.size() * 0.5)] if not inner_block_areas.is_empty() else INF
	print("[G10P2BMorphology] ", label, " frontage_coverage core=", core_ratio,
			" inner=", inner_ratio, " road_frontage core=", core_road_ratio,
			" inner=", inner_road_ratio, " block_median_area core=", core_median_area,
			" inner=", inner_median_area)
	_print_block_coherence(plan, label)
	_expect(core_ratio >= 0.20, label + " historic frontage coverage >= 20%")
	_expect(inner_ratio >= 0.12, label + " inner frontage coverage >= 12%")
	_expect(core_road_ratio >= 0.55, label + " historic road frontage >= 55%")
	_expect(inner_road_ratio >= 0.55, label + " inner road frontage >= 55%")
	_expect(core_block_areas.size() >= 40, label + " historic block count >= 40")
	_expect(core_median_area <= 8000.0, label + " historic median block area <= 8000 m2")
	_expect(inner_median_area <= 10000.0, label + " inner median block area <= 10000 m2")


func _print_block_coherence(plan: CityPlan, label: String) -> void:
	# P2B-FIX diagnostic (print-only this round): per-block building counts
	# and mega-face census drive next round's hard thresholds.
	var hist := [0, 0, 0, 0]  # historic built blocks with 0/1/2/3+ buildings
	var megaface := 0
	var megaface_ids: Array[String] = []
	var dense_kind_counts: Dictionary = {}
	var dense_kind_areas: Dictionary = {}
	for block: Dictionary in plan.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if center.length() < 600.0:
			var kind_name := str(block.get("kind", &"built"))
			var dense_area := absf(_polygon_area(
				block.get("polygon", PackedVector2Array()) as PackedVector2Array))
			dense_kind_counts[kind_name] = int(dense_kind_counts.get(kind_name, 0)) + 1
			dense_kind_areas[kind_name] = float(dense_kind_areas.get(kind_name, 0.0)) + dense_area
		if (block.get("kind", &"") as StringName) != &"built":
			continue
		if center.length() >= 600.0:
			continue
		var area := absf(_polygon_area(
			block.get("polygon", PackedVector2Array()) as PackedVector2Array))
		var nb: int = (block.get("buildings", []) as Array).size()
		if center.length() < WorldConstants.CITY_HISTORIC_RADIUS_M:
			hist[mini(nb, 3)] += 1
		if area > 6000.0 and nb < 4:
			megaface += 1
			if megaface_ids.size() < 4:
				megaface_ids.append("%s:%.0f/%d" % [
					str(block.get("id", "")), area, nb])
	print("[G10P2BMorphology] ", label, " historic_block_hist_0/1/2/3+=",
		hist, " megaface_6k=", megaface, " ", megaface_ids,
		" dense_kind_counts=", dense_kind_counts,
		" dense_kind_areas=", dense_kind_areas)


func _check_block_ownership(plan: CityPlan, label: String) -> void:
	var blocks_by_id: Dictionary = {}
	for block: Dictionary in plan.city_blocks():
		blocks_by_id[str(block.get("id", ""))] = block
	var outside := 0
	var missing_owner := 0
	var far_from_road := 0
	var source_counts: Dictionary = {}
	var district_counts: Dictionary = {}
	var total := 0
	for spec: Dictionary in plan.city_buildings():
		total += 1
		var block_id := str(spec.get("block_id", ""))
		var block: Dictionary = blocks_by_id.get(block_id, {}) as Dictionary
		if block.is_empty():
			missing_owner += 1
			continue
		var source := "global_road" if int(spec.get("front_edge", -1)) < 1000 else "block_road"
		source_counts[source] = int(source_counts.get(source, 0)) + 1
		var district := str(spec.get("district", ""))
		district_counts[district] = int(district_counts.get(district, 0)) + 1
		var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
		var yaw := float(spec.get("yaw", 0.0))
		var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
		if not plan._lot_inside_polygon(lot, yaw, poly):
			outside += 1
		var nearest := plan._distance_to_city_road_raw(lot.get_center())
		if nearest > 28.0:
			far_from_road += 1
	print("[G10P2BMorphology] ", label, " ownership total=", total,
			" outside=", outside, " missing_owner=", missing_owner,
			" far_from_road=", far_from_road,
			" source_counts=", source_counts, " district_counts=", district_counts)
	_expect(outside == 0, label + " every building inside owning block")
	_expect(missing_owner == 0, label + " every building has owning block")


## G10-P2B-FIX2 acceptance telemetry. This is deliberately separate from the
## older footprint-area ratio: it measures whether normal road samples have a
## nearby parcel chain, and whether dense open area is classified as a park,
## plaza, courtyard, or garden instead of an unexplained empty face.
func _check_fabric_metrics(plan: CityPlan, label: String) -> void:
	var frontage_by_edge: Dictionary = {}
	var corner_lots := 0
	for spec: Dictionary in plan.city_buildings():
		var edge_id := str(spec.get("frontage_edge_id", ""))
		if edge_id != "":
			var centers: Array = frontage_by_edge.get(edge_id, []) as Array
			var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
			centers.append(spec.get("frontage_center", rect.get_center()) as Vector2)
			frontage_by_edge[edge_id] = centers
		if str(spec.get("frontage_role", "street")) == "corner":
			corner_lots += 1

	var junctions: Array[Vector2] = []
	for node: Dictionary in plan.city_nodes():
		if int(node.get("degree", 0)) < 3:
			continue
		var node_center: Vector2 = node.get("center", Vector2.ZERO) as Vector2
		if node_center.length() < 620.0:
			junctions.append(node_center)
	var samples := 0
	var covered := 0
	var considered_edges := 0
	var covered_edges := 0
	var uncovered_edge_ids: Array[String] = []
	for edge: Dictionary in plan.road_graph().get("edges", []) as Array:
		var hierarchy: StringName = edge.get("hierarchy", &"") as StringName
		if hierarchy == &"alley" or bool(edge.get("is_bridge", false)):
			continue
		var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var edge_samples := 0
		var edge_hits := 0
		var edge_id := str(edge.get("id", ""))
		var centers: Array = frontage_by_edge.get(edge_id, []) as Array
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[i + 1]
			var length := a.distance_to(b)
			if length < 2.0:
				continue
			var step_count := maxi(1, int(ceil(length / 8.0)))
			for step in step_count:
				var p := a.lerp(b, (float(step) + 0.5) / float(step_count))
				if p.length() >= 600.0 or _near_junction(p, junctions, 13.0):
					continue
				samples += 1
				edge_samples += 1
				var hit := false
				for frontage_center_variant in centers:
					if p.distance_to(frontage_center_variant as Vector2) <= 8.5:
						hit = true
						break
				if hit:
					covered += 1
					edge_hits += 1
		if edge_samples >= 2:
			considered_edges += 1
			if edge_hits > 0:
				covered_edges += 1
			else:
				uncovered_edge_ids.append(edge_id + ":" + _edge_context(plan, edge))
	var sample_ratio := float(covered) / maxf(float(samples), 1.0)
	var edge_ratio := float(covered_edges) / maxf(float(considered_edges), 1.0)

	var dense_area := 0.0
	var unclassified_empty_area := 0.0
	var empty_dense_blocks := 0
	var dense_blocks := 0
	var purposeful_open_area := 0.0
	for block: Dictionary in plan.city_blocks():
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if center.length() >= 600.0:
			continue
		var area := absf(_polygon_area(block.get("polygon", PackedVector2Array()) as PackedVector2Array))
		if area < 1.0:
			continue
		dense_area += area
		dense_blocks += 1
		var kind: StringName = block.get("kind", &"built") as StringName
		var buildings: Array = block.get("buildings", []) as Array
		if kind == &"park" or kind == &"plaza":
			purposeful_open_area += area
			continue
		if buildings.is_empty():
			var empty_courtyard := float(block.get("courtyard_area_m2", 0.0))
			if empty_courtyard >= WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
				purposeful_open_area += minf(empty_courtyard, area)
			else:
				empty_dense_blocks += 1
				unclassified_empty_area += area
			continue
		var occupied := 0.0
		for spec_variant in buildings:
			var spec: Dictionary = spec_variant as Dictionary
			var lot: Rect2 = spec.get("rect", Rect2()) as Rect2
			occupied += lot.size.x * lot.size.y
		var courtyard := float(block.get("courtyard_area_m2", 0.0))
		purposeful_open_area += minf(maxf(area - occupied, 0.0), courtyard)
		# Any large residual without a semantic courtyard/garden region is
		# exactly the blank-block failure this task is meant to prevent.
		if area - occupied > 0.55 * area and courtyard < WorldConstants.CITY_COURTYARD_MIN_AREA_M2:
			unclassified_empty_area += area - occupied
	var empty_ratio := float(empty_dense_blocks) / maxf(float(dense_blocks), 1.0)
	var unclassified_ratio := unclassified_empty_area / maxf(dense_area, 1.0)
	print("[G10P2BMorphology] ", label, " frontage_samples=", samples,
		" covered=", covered, " sample_ratio=", sample_ratio,
		" edge_ratio=", edge_ratio, " edges=", covered_edges, "/", considered_edges,
		" corner_lots=", corner_lots, " empty_dense_block_ratio=", empty_ratio,
		" unclassified_void_ratio=", unclassified_ratio,
		" uncovered_edges=", uncovered_edge_ids,
		" purposeful_open_area=", purposeful_open_area)
	# A majority of ordinary street samples must have a frontage candidate.
	# Junction mouths and alleys are excluded above; edge_ratio separately
	# catches a whole road edge that lost all of its parcels.
	_expect(sample_ratio >= 0.55, label + " frontage sample continuity >= 55%")
	_expect(edge_ratio >= 0.60, label + " normal road-edge continuity >= 60%")
	_expect(corner_lots >= 4, label + " intentional corner frontage lots")
	_expect(empty_ratio <= 0.08, label + " empty dense-block ratio <= 8%")
	_expect(unclassified_ratio <= 0.10, label + " unclassified dense void ratio <= 10%")


func _edge_context(plan: CityPlan, edge: Dictionary) -> String:
	var poly: PackedVector2Array = edge.get("polyline", PackedVector2Array()) as PackedVector2Array
	if poly.size() < 2:
		return "degenerate"
	var a: Vector2 = poly[0]
	var z: Vector2 = poly[1]
	var tangent := (z - a).normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	var width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
	var contexts: Array[String] = []
	var mid := (a + z) * 0.5
	for side in [-1.0, 1.0]:
		var sample: Vector2 = mid + normal * side * (width * 0.5 + 4.0)
		var context := "none"
		for block: Dictionary in plan.city_blocks():
			var block_poly: PackedVector2Array = block.get("polygon",
					PackedVector2Array()) as PackedVector2Array
			if not Geometry2D.is_point_in_polygon(sample, block_poly):
				continue
			var buildings: Array = block.get("buildings", []) as Array
			var area := absf(_polygon_area(block_poly))
			context = "%s/%d/%.0f" % [str(block.get("kind", &"built")),
				buildings.size(), area]
			break
		contexts.append(context)
	return "|".join(contexts)


func _near_junction(p: Vector2, junctions: Array[Vector2], radius: float) -> bool:
	for junction: Vector2 in junctions:
		if p.distance_to(junction) < radius:
			return true
	return false


func _polygon_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return area * 0.5


func _is_connected(graph: Dictionary) -> bool:
	var nodes: Array = graph.get("nodes", []) as Array
	var edges: Array = graph.get("edges", []) as Array
	if nodes.is_empty():
		return false
	var adjacency: Dictionary = {}
	for node: Dictionary in nodes:
		adjacency[str(node.get("id", ""))] = []
	for edge: Dictionary in edges:
		var a := str(edge.get("a", ""))
		var b := str(edge.get("b", ""))
		if not adjacency.has(a) or not adjacency.has(b):
			return false
		(adjacency[a] as Array).append(b)
		(adjacency[b] as Array).append(a)
	var seen: Dictionary = {}
	var queue: Array[String] = [str(nodes[0].get("id", ""))]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if seen.has(current):
			continue
		seen[current] = true
		for next_id in adjacency.get(current, []):
			if not seen.has(str(next_id)):
				queue.append(str(next_id))
	return seen.size() == nodes.size()


func _check_same_seed(a: CityPlan, b: CityPlan) -> void:
	_expect(JSON.stringify(a.road_graph()) == JSON.stringify(b.road_graph()), "same seed graph digest")
	_expect(JSON.stringify(a.city_blocks()) == JSON.stringify(b.city_blocks()), "same seed block digest")
	_expect(JSON.stringify(a.city_buildings()) == JSON.stringify(b.city_buildings()), "same seed building digest")


func _check_different_seed(a: CityPlan, b: CityPlan) -> void:
	_expect(JSON.stringify(a.road_graph()) != JSON.stringify(b.road_graph()), "different seed graph variation")
	_expect(JSON.stringify(a.city_buildings()) != JSON.stringify(b.city_buildings()), "different seed building variation")


func _check_triangulation(plan: CityPlan, label: String) -> void:
	# P2B-FIX: concave polygons must triangulate strictly inside.
	# L-shape is concave at (4,4); fan from vertex 0 escapes the notch.
	var l_shape := PackedVector2Array([
		Vector2(0, 0), Vector2(8, 0), Vector2(8, 4),
		Vector2(4, 4), Vector2(4, 8), Vector2(0, 8),
	])
	_check_polygon_inside(l_shape, label + " L-shape triangulation inside")
	var arrow := PackedVector2Array([
		Vector2(0, 0), Vector2(6, 0), Vector2(6, 2), Vector2(10, -2),
		Vector2(6, -6), Vector2(6, -4), Vector2(0, -4),
	])
	_check_polygon_inside(arrow, label + " arrow-notch triangulation inside")
	# One real road-derived historic block with >= 6 verts, if present.
	for block: Dictionary in plan.city_blocks():
		var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 6:
			continue
		var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
		if center.length() >= WorldConstants.CITY_HISTORIC_RADIUS_M:
			continue
		if not bool(block.get("road_derived", false)):
			continue
		_check_polygon_inside(poly, label + " historic road-derived block inside " + str(block.get("id", "")))
		break


func _check_polygon_inside(poly: PackedVector2Array, message: String) -> void:
	if poly.size() < 3:
		_expect(false, message + " (degenerate)")
		return
	# Wiring check: the REAL MeshBatcher path must stay inside too, not just
	# a local Geometry2D call (guards silent fan regressions).
	var batcher := MeshBatcher.new()
	batcher.add_visual_polygon(poly, 0.0, Color.WHITE)
	var groups: Dictionary = batcher._build_layers()
	var buf: Dictionary = groups.get("", {})
	var verts: PackedVector3Array = buf.get("verts", PackedVector3Array())
	var idx: PackedInt32Array = buf.get("idx", PackedInt32Array())
	_expect(not idx.is_empty(), message + " (batcher emits indices)")
	if idx.is_empty():
		return
	_expect(idx.size() % 3 == 0, message + " (batcher index multiple of 3)")
	for ti in range(0, idx.size(), 3):
		var a := Vector2(verts[idx[ti]].x, verts[idx[ti]].z)
		var b := Vector2(verts[idx[ti + 1]].x, verts[idx[ti + 1]].z)
		var c := Vector2(verts[idx[ti + 2]].x, verts[idx[ti + 2]].z)
		var centroid := (a + b + c) / 3.0
		if not Geometry2D.is_point_in_polygon(centroid, poly):
			_failures.append(message + " batcher centroid outside")
			return
	var tris := Geometry2D.triangulate_polygon(poly)
	_expect(not tris.is_empty(), message + " (triangulates)")
	if tris.is_empty():
		return
	_expect(tris.size() % 3 == 0, message + " (index multiple of 3)")
	var area := absf(_polygon_area(poly))
	var tri_area := 0.0
	var max_dim := 0.0
	for i in poly.size():
		for j in range(i + 1, poly.size()):
			max_dim = maxf(max_dim, poly[i].distance_to(poly[j]))
	for ti in range(0, tris.size(), 3):
		var a: Vector2 = poly[tris[ti]]
		var b: Vector2 = poly[tris[ti + 1]]
		var c: Vector2 = poly[tris[ti + 2]]
		tri_area += absf((b - a).cross(c - a)) * 0.5
		var centroid := (a + b + c) / 3.0
		if not Geometry2D.is_point_in_polygon(centroid, poly):
			_failures.append(message + " centroid outside")
			return
		for e in [a.distance_to(b), b.distance_to(c), c.distance_to(a)]:
			if e > max_dim + 0.01:
				_failures.append(message + " shard edge %.1f > max_dim %.1f" % [e, max_dim])
				return
	_expect(absf(tri_area - area) / maxf(area, 1.0) <= 0.01, message + " area match")


func _check_hub_distribution(plan: CityPlan, label: String) -> void:
	# P2B-FIX: no central starburst. market_square must not terminate every
	# gate/bridge/landmark route. Radials enter via inner connectors and a
	# historic pocket ring instead.
	var graph: Dictionary = plan.road_graph()
	var nodes: Array = graph.get("nodes", []) as Array
	var edges: Array = graph.get("edges", []) as Array
	var kind_by_id := {}
	for n: Dictionary in nodes:
		kind_by_id[str(n.get("id", ""))] = str(n.get("kind", ""))
	var hub_degree := 0
	var hub_primaries := 0
	var direct_gate_hub := 0
	var direct_crossing_hub := 0
	var ring_edges := 0
	for e: Dictionary in edges:
		var a := str(e.get("a", ""))
		var b := str(e.get("b", ""))
		var touches_hub := a == "market_square" or b == "market_square"
		if touches_hub:
			hub_degree += 1
			if str(e.get("hierarchy", "")) == "primary":
				hub_primaries += 1
		var other := b if a == "market_square" else (a if b == "market_square" else "")
		if other != "":
			if kind_by_id.get(other, "") == "city_gate":
				direct_gate_hub += 1
			if kind_by_id.get(other, "") == "river_crossing":
				direct_crossing_hub += 1
		if a.begins_with("historic_pocket_") and b.begins_with("historic_pocket_"):
			ring_edges += 1
	print("[G10P2BMorphology] ", label, " hub_degree=", hub_degree,
		" hub_primaries=", hub_primaries, " direct_gate_hub=", direct_gate_hub,
		" direct_crossing_hub=", direct_crossing_hub, " ring_edges=", ring_edges)
	_expect(hub_degree <= 6, label + " bounded central-node degree (got %d)" % hub_degree)
	_expect(hub_primaries <= 2, label + " hub primaries <= 2 (got %d)" % hub_primaries)
	_expect(direct_gate_hub == 0, label + " no gate routes directly to hub")
	_expect(direct_crossing_hub == 0, label + " no bridge approaches directly to hub")
	_expect(ring_edges >= 8, label + " historic pocket ring intact (got %d)" % ring_edges)


func _check_lamp_spacing(plan: CityPlan, label: String) -> void:
	# P2B-FIX lamp test: global-anchor spacing, no junction/plaza stacking.
	# World-free on purpose: only x/z positions are asserted.
	# Plaza HEARTS and junction zones stay dark; rims and ring arterials carry
	# spaced lamps. Spacing is asserted per-chunk in the 130-380 m ring band
	# where primary arterials run through buildable fabric.
	var all: Array[Vector2] = []
	var chunks_sampled := 0
	for cx in range(-5, 6):
		for cz in range(-5, 6):
			var coord := Vector2i(cx, cz)
			var r := WorldSeed.chunk_rect(coord).get_center().length()
			if r < 130.0 or r > 380.0:
				continue
			chunks_sampled += 1
			var batch := MeshBatcher.new()
			ChunkBuilder._roads(batch, plan, WorldSeed.chunk_rect(coord), null)
			var group: Array[Vector2] = []
			for v in batch.street_lights():
				var p := Vector2((v as Vector3).x, (v as Vector3).z)
				group.append(p)
				all.append(p)
			for i in group.size():
				for j in range(i + 1, group.size()):
					if group[i].distance_to(group[j]) < 10.0:
						_failures.append(label + " lamp pair <10m in chunk "
							+ str(coord))
						break
	var core_count := 0
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			var batch := MeshBatcher.new()
			ChunkBuilder._roads(batch, plan,
				WorldSeed.chunk_rect(Vector2i(cx, cz)), null)
			core_count += batch.street_lights().size()
	print("[G10P2BMorphology] ", label, " lamp_ring_3x3=",
		chunks_sampled, " ring_lamps=", all.size(),
		" core_lamps=", core_count)
	_expect(all.size() > 10, label + " ring arterials carry lamps")
	var global_min := INF
	for i in all.size():
		for j in range(i + 1, all.size()):
			global_min = minf(global_min, all[i].distance_to(all[j]))
	if all.size() >= 2:
		_expect(global_min >= 6.0,
			label + " no lamp stacking (global min %.1f)" % global_min)
		print("[G10P2BMorphology] ", label, " lamp_global_min=", global_min)
	var junctions: Array[Vector2] = []
	for node in plan.city_nodes():
		var nid := String(node.get("id", ""))
		var deg := int(node.get("degree", 0))
		if nid == "market_square" or nid == "civic_square" \
				or nid == "rail_station" or nid == "castle_hill" \
				or deg >= 7:
			var c: Vector2 = node.get("center", Vector2.ZERO) as Vector2
			if Rect2(Vector2(-96, -96), Vector2(256, 256)).has_point(c):
				junctions.append(c)
	for lamp in all:
		for j in junctions:
			if lamp.distance_to(j) < 10.0:
				_failures.append(label + " lamp inside junction zone")
				break
		for block in plan.city_blocks():
			if (block.get("kind", &"") as StringName) != &"plaza":
				continue
			# Mirror of the implementation's plaza-heart disc: rims stay lit.
			var bc: Vector2 = block.get("center", Vector2.ZERO) as Vector2
			var bb: Rect2 = block.get("bounds",
				block.get("rect", Rect2())) as Rect2
			var prad := maxf(12.0, minf(bb.size.x, bb.size.y) * 0.35)
			if lamp.distance_to(bc) < prad - 0.05:
				_failures.append(label + " lamp inside plaza heart "
					+ str(block.get("id", "")))
				break


func _expect(value: bool, message: String) -> void:
	if not value:
		_failures.append(message)
