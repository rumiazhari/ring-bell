extends Node
const UrbanBlockPlan = preload("res://world/generation/urban_block_plan.gd")
const HistoricStreets = preload("res://world/generation/historic_street_plan.gd")
const ParcelPlanScript = preload("res://world/generation/parcel_plan.gd")

## Distribution seed used when no --dist flag is given: the standard praguetest
## run still measures real-city morphology so the harness can never go dormant.
const DIST_SEED := 19041207
const DIST_SEEDS := [19041207, 19041208, 19041209]
const STAIR_SAMPLE := 24
const TRACE_PATH := "res://.hermes/autopilot/reports/prague-dist-trace.txt"

var failures := 0
var _trace_file = null

## Live progress trace with flush(): the runner's stdout is block-buffered when
## redirected, so without this a stalled morphology run is invisible until exit.
func _trace(message: String) -> void:
	print("[PragueTest] " + message)
	if _trace_file == null:
		_trace_file = FileAccess.open(TRACE_PATH, FileAccess.WRITE)
	if _trace_file != null:
		_trace_file.store_line("%dms %s" % [Time.get_ticks_msec(), message])
		_trace_file.flush()

func _ready() -> void:
	var boundary := PackedVector2Array([Vector2(-60, -40), Vector2(60, -35),
		Vector2(55, 60), Vector2(-50, 55), Vector2(-60, -40)])
	var edges: Array = [{"id": "rim", "width": 6.0, "polyline": boundary},
		{"id": "cross", "width": 4.0, "polyline": PackedVector2Array([Vector2(-80, 0), Vector2(80, 0)])},
		{"id": "end", "width": 4.0, "polyline": PackedVector2Array([Vector2(0, 0), Vector2(0, 25)])}]
	var graph := UrbanBlockPlan.build(edges)
	_check(graph.faces.size() == 2, "crossing splits two street-bounded faces; dead end creates no false block")
	var area := 0.0
	for face: Dictionary in graph.faces:
		area += float(face.area_m2)
	_check(absf(area - UrbanBlockPlan.signed_area(boundary)) < 0.1, "planar faces conserve enclosed area")
	var reverse := edges.duplicate(true)
	reverse.reverse()
	var other := UrbanBlockPlan.build(reverse)
	_check(other.faces.size() == graph.faces.size(), "input query order preserves topology")
	var fixture := CityPlan.new(19041207)
	var fixture_block := {"id": "fixture", "cell": Vector2i(-2, -3), "polygon": PackedVector2Array([Vector2(-40, -60), Vector2(40, -60), Vector2(40, 60), Vector2(-40, 60)]), "kind": &"built", "district": &"historic"}
	fixture._ensure_support_plans()
	var specs := fixture._historic_buildings_for_block(fixture_block)
	_check(specs.size() > 4, "fixture produces compound wings")
	var fixture_frontages: Array[float] = []
	for plot: Dictionary in fixture_block.get("plots", []):
		fixture_frontages.append(float(plot.get("frontage_m", 0.0)))
	print("[PragueTest] fixture_plots=%d frontage_p0=%.1f p50=%.1f pmax=%.1f"
		% [fixture_frontages.size(), _pct(fixture_frontages, 0.0), _pct(fixture_frontages, 0.5), _pct(fixture_frontages, 1.0)])
	for spec: Dictionary in specs.slice(0, 12):
		var interior := InteriorPlan.build_for_building(spec)
		var errors := InteriorPlan.validate(interior)
		_check(errors.is_empty(), "%s floor geometry and connectivity: %s" % [spec.id, errors])
		var batch := MeshBatcher.new()
		UniversalBuildingAssembler.build_into(batch, spec)
		var build_errors := BuildingContractValidator.validate_build(spec, batch)
		_check(build_errors.is_empty(), "%s materialized building contract: %s" % [spec.id, build_errors])
	if OS.get_cmdline_user_args().has("--full"):
		var city := CityPlan.new(WorldSeed.get_world_seed())
		var blocks := city.city_blocks()
		var plots := 0
		var wings := 0
		for block: Dictionary in blocks:
			plots += (block.get("plots", []) as Array).size()
			if bool(block.get("historic_compound", false)):
				wings += (block.buildings as Array).size()
		print("[PragueTest] generated blocks=%d historic plots=%d wings=%d" % [blocks.size(), plots, wings])
		_check(plots > 100 and wings > plots, "real city contains reserved plots and multi-wing compounds")
	if OS.get_cmdline_user_args().has("--city"):
		var city := CityPlan.new(WorldSeed.get_world_seed())
		var started := Time.get_ticks_msec()
		city._ensure_support_plans()
		city._generate_landmarks()
		city._generate_city_roads()
		if OS.get_cmdline_user_args().has("--new"):
			city._city_edges = HistoricStreets.generate(city.seed_used, city._city_edges, city._landmarks).edges
		var real_graph := UrbanBlockPlan.build(city._city_edges)
		var histogram := [0, 0, 0, 0, 0]
		for face: Dictionary in real_graph.faces:
			var a := float(face.area_m2)
			var bin := 0 if a < 1000 else (1 if a < 3000 else (2 if a < 10000 else (3 if a < 20000 else 4)))
			histogram[bin] += 1
		print("[PragueTest] real faces=%d areas(<1k,3k,10k,20k,larger)=%s time=%dms" % [real_graph.faces.size(), histogram, Time.get_ticks_msec() - started])
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-350 -350 700 700" width="1050" height="1050"><rect x="-350" y="-350" width="700" height="700" fill="#20272d"/>'
		for face: Dictionary in real_graph.faces:
			var points := ""
			for p: Vector2 in face.polygon:
				points += "%f,%f " % [p.x, p.y]
			svg += '<polygon points="%s" fill="#bdab89" stroke="#20272d" stroke-width="4"/>' % points
		for edge: Dictionary in city._city_edges:
			var points := ""
			for p: Vector2 in edge.polyline:
				points += "%f,%f " % [p.x, p.y]
			svg += '<polyline points="%s" fill="none" stroke="#ddd6c4" stroke-width="%f"/>' % [points, edge.width]
		var file := FileAccess.open("res://.hermes/autopilot/reports/prague-street-faces.svg", FileAccess.WRITE)
		file.store_string(svg + "</svg>")
		var raster := Image.new()
		raster.load_svg_from_string(svg + "</svg>")
		raster.save_png("res://.hermes/autopilot/reports/prague-street-faces.png")
	if OS.get_cmdline_user_args().has("--fixtures-only"):
		print("[PragueTest] finished with %d failure(s)" % failures)
		get_tree().quit(failures)
		return
	if OS.get_cmdline_user_args().has("--dist"):
		for s: int in DIST_SEEDS:
			_distribution(s)
	else:
		_distribution(DIST_SEED)
	print("[PragueTest] finished with %d failure(s)" % failures)
	get_tree().quit(failures)


# ── Item 18: real-city morphology distributions ───────────────────────────────
# Bands come from the overhaul spec (.hermes/plans/2026-09-10_prague-overhaul-
# goal-spec.md). They assert plausible distributions and structural invariants
# over real generated blocks, never one exact map.

func _distribution(seed: int) -> void:
	WorldSeed.set_world_seed(seed)
	var t0 := Time.get_ticks_msec()
	ParcelPlanScript.reset_stats()
	var city := CityPlan.new(seed)
	var blocks := city.city_blocks()
	var gen_ms := Time.get_ticks_msec() - t0
	_trace("DIST seed=%d city generation %dms" % [seed, gen_ms])
	var core: Array[Dictionary] = []
	var plots: Array[Dictionary] = []
	var specs: Array[Dictionary] = []
	for block: Dictionary in blocks:
		var is_core := bool(block.get("historic_compound", false))
		for plot: Dictionary in block.get("plots", []):
			if is_core:
				plots.append(plot)
		for spec: Dictionary in block.get("buildings", []):
			if is_core:
				specs.append(spec)
		if is_core:
			core.append(block)
	print("[PragueTest] DIST seed=%d gen=%dms blocks=%d historic_blocks=%d plots=%d wings=%d"
		% [seed, gen_ms, blocks.size(), core.size(), plots.size(), specs.size()])
	_check(core.size() > 40, "seed %d: historic core has real street-derived blocks (%d)" % [seed, core.size()])
	_check(plots.size() > 100, "seed %d: historic core reserves plots" % seed)
	_check(specs.size() > plots.size(), "seed %d: compounds produce more wings than plots" % seed)
	var section := Time.get_ticks_msec()
	_streets(city, seed)
	_trace("DIST seed=%d streets done %dms" % [seed, Time.get_ticks_msec() - section])
	section = Time.get_ticks_msec()
	_junctions(city, seed)
	_trace("DIST seed=%d junctions done %dms" % [seed, Time.get_ticks_msec() - section])
	section = Time.get_ticks_msec()
	_blocks(core, seed)
	_trace("DIST seed=%d blocks done %dms" % [seed, Time.get_ticks_msec() - section])
	section = Time.get_ticks_msec()
	_plots(plots, core, seed)
	_trace("DIST seed=%d plots done %dms" % [seed, Time.get_ticks_msec() - section])
	section = Time.get_ticks_msec()
	_wings(specs, seed)
	_trace("DIST seed=%d wings done %dms" % [seed, Time.get_ticks_msec() - section])
	section = Time.get_ticks_msec()
	_stairs(specs, seed)
	_trace("DIST seed=%d stairs done %dms" % [seed, Time.get_ticks_msec() - section])
	if seed == DIST_SEED and not OS.get_cmdline_user_args().has("--fast"):
		_determinism(seed)


func _streets(city: CityPlan, seed: int) -> void:
	var boundary: PackedVector2Array = city._historic.get("boundary", PackedVector2Array())
	var bands := [0, 0, 0, 0, 0]
	var total := 0
	var shared := 0
	var lengths: Array[float] = []
	var street_length_total := 0.0
	for edge: Dictionary in city._city_edges:
		if str(edge.get("influence", "")) != "historic_fabric":
			continue
		var line: PackedVector2Array = edge.polyline
		var mid: Vector2 = (line[0] + line[line.size() - 1]) * 0.5
		if boundary.size() >= 3 and not Geometry2D.is_point_in_polygon(mid, boundary):
			continue
		total += 1
		if bool(edge.get("shared_surface", false)):
			shared += 1
		var width := float(edge.width)
		if width < 5.5:
			bands[0] += 1
		elif width < 8.0:
			bands[1] += 1
		elif width < 11.0:
			bands[2] += 1
		elif width <= 16.0:
			bands[3] += 1
		else:
			bands[4] += 1
		for i in range(line.size() - 1):
			var seg := line[i].distance_to(line[i + 1])
			lengths.append(seg)
			street_length_total += seg
	_check(total > 60, "seed %d: historic core has a real street network (%d streets)" % [seed, total])
	if total == 0:
		return
	var shares := []
	for count: int in bands:
		shares.append(float(count) / float(total))
	print("[PragueTest] DIST seed=%d streets=%d lanes=%.2f ordinary=%.2f important=%.2f wide=%.2f oversize=%.2f shared=%.2f seg_p10=%.1f seg_median=%.1f seg_p90=%.1f"
		% [seed, total, shares[0], shares[1], shares[2], shares[3], shares[4], float(shared) / float(total), _pct(lengths, 0.1), _pct(lengths, 0.5), _pct(lengths, 0.9)])
	_check(absf(shares[0] - 0.30) <= 0.12, "seed %d: narrow lanes 3.5-5.5 m share %.2f vs target 0.30" % [seed, shares[0]])
	_check(absf(shares[1] - 0.45) <= 0.12, "seed %d: ordinary streets 5.5-8 m share %.2f vs target 0.45" % [seed, shares[1]])
	_check(absf(shares[2] - 0.20) <= 0.10, "seed %d: important streets 8-11 m share %.2f vs target 0.20" % [seed, shares[2]])
	_check(shares[3] + shares[4] <= 0.12, "seed %d: wide 12-16 m+ streets share %.2f vs target 0.05" % [seed, shares[3] + shares[4]])
	_check(shared == total, "seed %d: historic streets are shared surface / cobbled" % seed)
	_check(_pct(lengths, 0.5) <= 40.0, "seed %d: street segments stay street-scale (median %.1f m)" % [seed, _pct(lengths, 0.5)])
	_check(_pct(lengths, 0.9) <= 70.0, "seed %d: no marathon blocks between junctions (p90 %.1f m)" % [seed, _pct(lengths, 0.9)])


func _junctions(city: CityPlan, seed: int) -> void:
	var manifest := UrbanBlockPlan.graph_manifest(city._city_edges)
	var by_degree := {}
	for node: Dictionary in manifest.nodes:
		var d := int(node.degree)
		by_degree[d] = int(by_degree.get(d, 0)) + 1
	var nodes: int = manifest.nodes.size()
	if nodes == 0:
		_check(false, "seed %d: street graph has nodes" % seed)
		return
	var dead := int(by_degree.get(1, 0))
	var three := int(by_degree.get(3, 0))
	var four := int(by_degree.get(4, 0))
	print("[PragueTest] DIST seed=%d graph_nodes=%d dead_ends=%.3f T_Y=%.3f cross=%.3f"
		% [seed, nodes, float(dead) / float(nodes), float(three) / float(nodes), float(four) / float(nodes)])
	_check(dead > 0, "seed %d: the network contains dead ends" % seed)
	_check(float(dead) / float(nodes) >= 0.02, "seed %d: dead ends are a real share of the network (%.3f)" % [seed, float(dead) / float(nodes)])
	_check(float(dead) / float(nodes) <= 0.30, "seed %d: dead ends stay occasional, not the norm (%.3f)" % [seed, float(dead) / float(nodes)])
	_check(three > four, "seed %d: T/Y junctions outnumber four-ways (%d vs %d)" % [seed, three, four])


func _blocks(core: Array[Dictionary], seed: int) -> void:
	var areas: Array[float] = []
	var aspects: Array[float] = []
	var fills: Array[float] = []
	var edge_counts: Array[float] = []
	var right := 0
	var vertices := 0
	var small := 0
	var edge_lens: Array[float] = []
	for block: Dictionary in core:
		var poly: PackedVector2Array = block.polygon
		if poly.size() < 3:
			continue
		var min_x := INF
		var min_z := INF
		var max_x := -INF
		var max_z := -INF
		for p: Vector2 in poly:
			min_x = minf(min_x, p.x)
			min_z = minf(min_z, p.y)
			max_x = maxf(max_x, p.x)
			max_z = maxf(max_z, p.y)
		var w := max_x - min_x
		var h := max_z - min_z
		if w <= 0.0 or h <= 0.0:
			continue
		var poly_area := absf(UrbanBlockPlan.signed_area(poly))
		areas.append(poly_area)
		if poly_area < 110.0:
			small += 1
		aspects.append(maxf(w, h) / minf(w, h))
		fills.append(poly_area / (w * h))
		edge_counts.append(float(poly.size()))
		for i in poly.size():
			var prev: Vector2 = poly[posmod(i - 1, poly.size())]
			var next: Vector2 = poly[(i + 1) % poly.size()]
			edge_lens.append(poly[i].distance_to(next))
			var ang := absf((prev - poly[i]).angle_to(next - poly[i]))
			vertices += 1
			if absf(ang - PI * 0.5) < 0.18:
				right += 1
	var right_share := float(right) / float(maxi(vertices, 1))
	# What the spec forbids is a global orthogonal grid, not locally perpendicular
	# corners: two streets meeting at a right angle is normal historic fabric. So
	# measure how much of the block fabric is aligned to WORLD X/Z (grid-like) and
	# keep the local corner share as reported evidence.
	var axis_edges := 0
	var axis_total := 0
	for block: Dictionary in core:
		var poly: PackedVector2Array = block.polygon
		for i in poly.size():
			var dir := (poly[(i + 1) % poly.size()] - poly[i])
			if dir.length_squared() < 0.0001:
				continue
			axis_total += 1
			var ang := absf(fposmod(dir.angle(), PI * 0.5))
			if ang < 0.105 or ang > PI * 0.5 - 0.105:
				axis_edges += 1
	var axis_share := float(axis_edges) / float(maxi(axis_total, 1))
	var five_plus := 0.0
	for count: float in edge_counts:
		if count >= 5.0:
			five_plus += 1.0
	five_plus = five_plus / float(maxi(edge_counts.size(), 1))
	print("[PragueTest] DIST seed=%d block_median_area=%.0fm2 aspect_median=%.2f fill_median=%.2f right_angle_share=%.2f world_axis_share=%.2f edges>=5 share=%.2f slivers=%d edge_p10=%.1f edge_p50=%.1f edge_p90=%.1f"
		% [seed, _pct(areas, 0.5), _pct(aspects, 0.5), _pct(fills, 0.5), right_share, axis_share, five_plus, small,
		_pct(edge_lens, 0.1), _pct(edge_lens, 0.5), _pct(edge_lens, 0.9)])
	_check(_pct(aspects, 0.5) >= 1.15, "seed %d: blocks are not near-square (median aspect %.2f)" % [seed, _pct(aspects, 0.5)])
	_check(_pct(fills, 0.5) <= 0.88, "seed %d: blocks are irregular, not rectangles (median fill %.2f)" % [seed, _pct(fills, 0.5)])
	_check(right_share < 0.70, "seed %d: block corners are not exclusively right angles (%.2f)" % [seed, right_share])
	_check(axis_share < 0.45, "seed %d: the core is not aligned to a world X/Z grid (%.2f of edges)" % [seed, axis_share])
	_check(five_plus >= 0.20, "seed %d: many-sided blocks are common (%.2f)" % [seed, five_plus])


func _plots(plots: Array[Dictionary], core: Array[Dictionary], seed: int) -> void:
	var frontages: Array[float] = []
	var depths: Array[float] = []
	var fractions: Array[float] = []
	var narrow := 0
	var wide := 0
	var with_court := 0
	var passage_total := 0
	var without_passage := 0
	var multi_passage := 0
	var passage_kinds := {}
	var no_cellar := 0
	var materialized_cellars := 0
	var layers := {}
	for plot: Dictionary in plots:
		var f := float(plot.get("frontage_m", 0.0))
		var d := float(plot.get("depth_m", 0.0))
		var rect: Rect2 = plot.get("rect", Rect2())
		frontages.append(f)
		depths.append(d)
		if f >= 6.0 and f < 9.0:
			narrow += 1
		if f > 15.0:
			wide += 1
		var courts: Array = plot.get("courtyards", [])
		if not courts.is_empty():
			with_court += 1
			var court_area := float((courts[0] as Dictionary).get("area_m2", 0.0))
			if rect.get_area() > 0.0:
				fractions.append(court_area / rect.get_area())
		passage_total += (plot.get("passages", []) as Array).size()
		var plot_passages := (plot.get("passages", []) as Array).size()
		if plot_passages == 0:
			without_passage += 1
		elif plot_passages >= 2:
			multi_passage += 1
		var kind_seen := {}
		for passage: Dictionary in plot.get("passages", []):
			kind_seen[str(passage.get("kind", ""))] = true
			passage_kinds[str(passage.get("kind", ""))] = true
		var cellars: Array = plot.get("cellars", [])
		if cellars.is_empty():
			no_cellar += 1
		for cellar: Dictionary in cellars:
			if bool(cellar.get("materialized", true)):
				materialized_cellars += 1
		var layer := str(plot.get("historical_layer", "none"))
		layers[layer] = int(layers.get(layer, 0)) + 1
	var impermeable_blocks := 0
	for block: Dictionary in core:
		var any := false
		for plot: Dictionary in block.get("plots", []):
			if not (plot.get("passages", []) as Array).is_empty():
				any = true
				break
		if not any:
			impermeable_blocks += 1
	var count := float(maxi(plots.size(), 1))
	var in_band := 0
	for f: float in frontages:
		if f >= 6.0 and f <= 15.0:
			in_band += 1
	var depth_in_band := 0
	for d: float in depths:
		if d >= 25.0 and d <= 45.0:
			depth_in_band += 1
	print("[PragueTest] DIST seed=%d frontage_median=%.1f narrow(6-9)=%.2f over15=%.2f in_band(6-15)=%.2f depth_median=%.1f depth_in_band(25-45)=%.2f courts=%.2f court_frac_median=%.2f passages/plot=%.2f impermeable_blocks=%.2f layers=%s"
		% [seed, _pct(frontages, 0.5), float(narrow) / count, float(wide) / count, float(in_band) / count,
		_pct(depths, 0.5), float(depth_in_band) / count, float(with_court) / count, _pct(fractions, 0.5),
		float(passage_total) / count, float(impermeable_blocks) / float(maxi(core.size(), 1)), layers])
	print("[PragueTest] DIST seed=%d passages=%d plots_without_passage=%.2f plots_with_two_plus=%.2f passage_kinds=%s"
		% [seed, passage_total, float(without_passage) / count, float(multi_passage) / count, passage_kinds])
	_check(_pct(frontages, 0.5) >= 6.0 and _pct(frontages, 0.5) <= 15.0, "seed %d: median frontage sits in the historic 6-15 m band (%.1f)" % [seed, _pct(frontages, 0.5)])
	_check(float(in_band) / count >= 0.60, "seed %d: frontages concentrate in 6-15 m (%.2f)" % [seed, float(in_band) / count])
	_check(float(narrow) / count >= 0.08, "seed %d: narrow 6-9 m frontages are real (%.2f of plots)" % [seed, float(narrow) / count])
	_check(without_passage > 0, "seed %d: some plots are sealed from their court (%d)" % [seed, without_passage])
	_check(multi_passage > 0, "seed %d: some courts carry more than one access (%d)" % [seed, multi_passage])
	_check(passage_kinds.size() >= 2, "seed %d: passage kinds vary (%s)" % [seed, passage_kinds])
	print("[PragueTest] DIST seed=%d frontage_p0=%.1f p10=%.1f p25=%.1f p75=%.1f p90=%.1f pmax=%.1f plots=%d parcel_allocation=%s"
		% [seed, _pct(frontages, 0.0), _pct(frontages, 0.1), _pct(frontages, 0.25), _pct(frontages, 0.75), _pct(frontages, 0.9), _pct(frontages, 1.0), plots.size(), ParcelPlanScript.stats])
	_check(with_court < plots.size(), "seed %d: some plots are built solid, without a courtyard (%d of %d)" % [seed, with_court, plots.size()])
	_check(_pct(depths, 0.5) >= 12.0, "seed %d: plots are deeper than they are wide (median %.1f m)" % [seed, _pct(depths, 0.5)])
	_check(float(with_court) / count >= 0.50, "seed %d: courtyards are a first-class feature (%.2f of plots)" % [seed, float(with_court) / count])
	_check(_pct(fractions, 0.5) >= 0.04 and _pct(fractions, 0.5) <= 0.45, "seed %d: courtyard area fraction is credible (%.2f)" % [seed, _pct(fractions, 0.5)])
	_check(float(passage_total) / count >= 0.40, "seed %d: passages give a secondary network (%.2f per plot)" % [seed, float(passage_total) / count])
	_check(float(passage_total) / count <= 1.20, "seed %d: passages are not overgenerated (%.2f per plot)" % [seed, float(passage_total) / count])
	# The spec asks that some blocks stay impermeable and that permeability varies -
	# not for a particular rate. Plot-level variation is asserted separately
	# (plots without a passage, plots with two or more).
	_check(impermeable_blocks >= 2 and impermeable_blocks * 2 <= core.size(),
		"seed %d: some blocks stay impermeable, not most (%d of %d)" % [seed, impermeable_blocks, core.size()])
	_check(no_cellar == 0, "seed %d: every plot carries a cellar manifest (%d missing)" % [seed, no_cellar])
	_check(materialized_cellars == 0, "seed %d: cellars stay plan-only, nothing materialized unsafely (%d)" % [seed, materialized_cellars])
	_check(layers.size() >= 2, "seed %d: historical layers vary across the core (%s)" % [seed, layers])


func _wings(specs: Array[Dictionary], seed: int) -> void:
	var storeys := {}
	var front_storeys := {}
	var annex_storeys := {}
	var uses := {}
	var roofs := {}
	var roles := {}
	var mixed := 0
	var counted := 0
	var owners := {}
	var owner_conflicts := 0
	var circulation_missing := 0
	var front_count := 0
	var front_max := 0
	var annex_max := 0
	var front_mixed := 0
	var commercial_ground := 0
	for spec: Dictionary in specs:
		var floors := int(spec.get("floors", 0))
		storeys[floors] = int(storeys.get(floors, 0)) + 1
		var role := str(spec.get("wing_role", "?"))
		roles[role] = int(roles.get(role, 0)) + 1
		if role == "front":
			front_storeys[floors] = int(front_storeys.get(floors, 0)) + 1
			front_count += 1
			front_max = maxi(front_max, floors)
		else:
			annex_storeys[floors] = int(annex_storeys.get(floors, 0)) + 1
			annex_max = maxi(annex_max, floors)
		counted += 1
		var ground := str(spec.get("use", ""))
		uses[ground] = int(uses.get(ground, 0)) + 1
		var floor_uses: Array = spec.get("floor_uses", [])
		# Mixed use = more than one distinct use inside the building (spec 8),
		# not merely a commercial ground floor under flats.
		var distinct := {}
		for u: String in floor_uses:
			distinct[u] = true
		if distinct.size() >= 2:
			mixed += 1
			if role == "front":
				front_mixed += 1
		if not floor_uses.is_empty() and str(floor_uses[0]) != "residential":
			commercial_ground += 1
		var style: Dictionary = spec.get("style", {})
		if style.has("roof_plan"):
			var kind := str((style.roof_plan as Dictionary).get("kind", "?"))
			roofs[kind] = int(roofs.get(kind, 0)) + 1
		var compound := str(spec.get("compound_id", ""))
		if compound != "":
			var chunk: Vector2i = spec.get("owner_chunk", Vector2i.ZERO)
			if owners.has(compound) and owners[compound] != chunk:
				owner_conflicts += 1
			owners[compound] = chunk
			if floors > 1 and str((spec.get("circulation", {}) as Dictionary).get("kind", "")) != "stairs":
				circulation_missing += 1
	# Storey bands apply to STREET (front) wings: the Prague-like building is the
	# front house. Courtyard annexes are legitimately lower (rear wing / one-storey
	# side wings), so they are asserted as an annex invariant instead.
	var floor_share := 0.0
	for key: int in front_storeys:
		if key >= 3 and key <= 6:
			floor_share += float(front_storeys[key])
	floor_share = floor_share / float(maxi(front_count, 1))
	var roof_max := 0.0
	for key: String in roofs:
		roof_max = maxf(roof_max, float(roofs[key]) / float(maxi(counted, 1)))
	var mixed_front_share := float(front_mixed) / float(maxi(front_count, 1))
	var commercial_share := float(commercial_ground) / float(maxi(counted, 1))
	print("[PragueTest] DIST seed=%d wings_storeys=%s front_storeys=%s annex_storeys=%s roof_kinds=%s roles=%s ground_uses=%s front_mixed=%.2f commercial_ground=%.2f compounds=%d owner_conflicts=%d"
		% [seed, storeys, front_storeys, annex_storeys, roofs, roles, uses, mixed_front_share, commercial_share, owners.size(), owner_conflicts])
	_check(floor_share >= 0.98, "seed %d: street wings sit in the historic 3-6 storey range (%.2f)" % [seed, floor_share])
	_check(front_count >= 100, "seed %d: street wings are the backbone (%d)" % [seed, front_count])
	_check(annex_max <= front_max, "seed %d: courtyard annexes never out-top the street wing (annex %d vs front %d)" % [seed, annex_max, front_max])
	_check(uses.size() >= 4, "seed %d: ground-floor programs vary across the core (%s)" % [seed, uses.keys()])
	_check(mixed_front_share >= 0.95, "seed %d: street houses are mixed-use, not single-use (%.2f)" % [seed, mixed_front_share])
	_check(commercial_share >= 0.50, "seed %d: most ground floors carry a working use (%.2f)" % [seed, commercial_share])
	_check(roofs.size() >= 3, "seed %d: the roofscape mixes gable/hip/mansard (%s)" % [seed, roofs])
	_check(roof_max <= 0.85, "seed %d: no single roof form dominates (%.2f)" % [seed, roof_max])
	_check(owner_conflicts == 0, "seed %d: every compound has one stable owner chunk (%d conflicts)" % [seed, owner_conflicts])
	_check(circulation_missing == 0, "seed %d: every multi-storey wing declares stair circulation (%d missing)" % [seed, circulation_missing])
	_check(int(roles.get("front", 0)) >= 100, "seed %d: street wings are the backbone (%s)" % [seed, roles])
	_check(int(roles.get("side", 0)) + int(roles.get("rear", 0)) > 0, "seed %d: compounds grow rear/side wings (%s)" % [seed, roles])


func _stairs(specs: Array[Dictionary], seed: int) -> void:
	var candidates: Array[Dictionary] = []
	for spec: Dictionary in specs:
		if int(spec.get("floors", 0)) >= 2:
			candidates.append(spec)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float((a.get("rect", Rect2()) as Rect2).size.x) < float((b.get("rect", Rect2()) as Rect2).size.x))
	# Sample the NARROWEST wings first: stair reachability and room geometry break
	# there first, and an evenly-spaced sample would look healthier than reality.
	var picked: Array[Dictionary] = []
	for spec: Dictionary in candidates.slice(0, STAIR_SAMPLE / 2):
		picked.append(spec)
	var stride := maxi(1, int(candidates.size() / STAIR_SAMPLE))
	var cursor := 0
	while picked.size() < STAIR_SAMPLE and cursor < candidates.size():
		picked.append(candidates[cursor])
		cursor += stride
	var checked := 0
	var bad := 0
	var unreachable := 0
	var narrow_checked := 0
	var narrowest := INF
	for spec: Dictionary in picked:
		checked += 1
		var width := float((spec.get("rect", Rect2()) as Rect2).size.x)
		narrowest = minf(narrowest, width)
		if width < 9.0:
			narrow_checked += 1
		var interior := InteriorPlan.build_for_building(spec)
		var errors := InteriorPlan.validate(interior)
		if not errors.is_empty():
			bad += 1
			if bad <= 2:
				print("[PragueTest] DIST seed=%d stair sample %s (w=%.1f): %s" % [seed, spec.id, width, errors])
		var first_bad := ""
		for floor: Dictionary in interior.get("floors", []):
			var kinds := []
			for room: Dictionary in floor.get("rooms", []):
				kinds.append(str(room.get("kind", "")))
			if floor.get("floor_i") != 0 and not (kinds.has("landing") or kinds.has("stair_hall")):
				unreachable += 1
				if first_bad == "":
					first_bad = "%s w=%.1f depth=%.1f floor=%d kinds=%s" % [spec.id, width,
						float((spec.get("rect", Rect2()) as Rect2).size.y), int(floor.get("floor_i")), str(kinds)]
		if first_bad != "":
			print("[PragueTest] DIST seed=%d stair-unreachable %s" % [seed, first_bad])
	print("[PragueTest] DIST seed=%d stair_samples=%d narrowest=%.1fm narrow_sampled=%d invalid=%d floors_without_stair_access=%d"
		% [seed, checked, narrowest, narrow_checked, bad, unreachable])
	_check(checked >= 8, "seed %d: stair reachability is sampled across the core (%d wings)" % [seed, checked])
	_check(bad == 0, "seed %d: sampled interiors validate (geometry + connectivity)" % seed)
	_check(unreachable == 0, "seed %d: every sampled upper floor has stair access (%d without)" % [seed, unreachable])


func _determinism(seed: int) -> void:
	var a := CityPlan.new(seed)
	var first := _id_hash(a.city_blocks())
	var repeat := _id_hash(CityPlan.new(seed).city_blocks())
	var other := _id_hash(CityPlan.new(seed + 7).city_blocks())
	print("[PragueTest] DIST determinism seed=%d same_seed_equal=%s different_seed_differs=%s"
		% [seed, str(first == repeat), str(first != other)])
	_check(first == repeat, "seed %d: two generations of the same seed produce identical ids" % seed)
	_check(first != other, "seed %d: a different seed produces a different city" % seed)


func _id_hash(blocks: Array[Dictionary]) -> String:
	var ids := PackedStringArray()
	for block: Dictionary in blocks:
		ids.append(str(block.get("id", "")))
		for plot: Dictionary in block.get("plots", []):
			ids.append(str(plot.get("id", "")))
		for spec: Dictionary in block.get("buildings", []):
			ids.append(str(spec.get("id", "")))
	ids.sort()
	return str(hash("|".join(ids)))


func _pct(values: Array, p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted_values: Array = values.duplicate()
	sorted_values.sort()
	var index := clampi(int(round(float(sorted_values.size() - 1) * p)), 0, sorted_values.size() - 1)
	return float(sorted_values[index])


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
	print("[PragueTest] %s %s" % ["PASS" if ok else "FAIL", message])
