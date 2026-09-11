extends Node
## Universal Site Envelope Contract harness -- --sitecontracttest (G10-P2C).
##
##   godot --headless --path . -- --sitecontracttest [--diag]
##
## The site layer is a plot's OUTDOOR envelope: yard surface, fence loop with
## gates, and the trees standing in it. This harness proves the same separation
## the building contract proves: the plan decides WHAT a plot has, the
## validator proves it, the emitters are the only construction path.
##
## Sections:
##   1. Vocabulary     — normalize() defaults and accessors agree.
##   2. Malformed spec — one deliberately broken site per rule; every rule
##                       must fire, and the untouched baseline must pass (so a
##                       mutation is proven meaningful, not vacuous).
##   3. City sites     — real CityPlan courtyards/gardens: every derived site
##                       validates against the real terrain.
##   4. Fringe sites   — real FringePlan yards (residential/inn) validate.
##   5. Determinism    — same seed identical, different seed differs.
##   6. Build evidence — a fence or tree that never reached the emitter, a
##                       missing collider, or grounding drift is caught.
##   7. Ceilings       — per-rect site/tree limits hold.
##
## Judge by the "[SiteContractTest] finished with 0 failure(s)" marker.

var failures := 0
var _checks := 0
var _diag := false
var wp: WorldPlan
var plan: SitePlan
var _surface: Callable
const CHUNK_SPAN := 5


func _ready() -> void:
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[SiteContractTest] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	for a: String in OS.get_cmdline_user_args():
		if a == "--diag":
			_diag = true
	_run_all()
	print("[SiteContractTest] finished with %d failure(s) over %d checks" % [failures, _checks])
	get_tree().quit(0 if failures == 0 else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("[SiteContractTest] PASS: %s" % label)
	else:
		failures += 1
		print("[SiteContractTest] FAIL: %s -- %s" % [label, detail])


func _report(label: String, errs: Array[String]) -> void:
	if _diag and not errs.is_empty():
		print("[SiteContractTest]   %s -> %s" % [label, errs])


func _run_all() -> void:
	var seed_used := WorldSeed.get_world_seed()
	wp = WorldPlan.new(seed_used)
	_surface = func(p: Vector2) -> float: return wp.surface_height_at(p)
	plan = SitePlan.new(seed_used, wp.city_plan, wp.fringe, _surface)
	_check("world plan ready (city + fringe)", wp.city_plan != null and wp.fringe != null)
	_section_vocabulary()
	_section_malformed()
	_section_city()
	_section_fringe()
	_section_determinism(seed_used)
	_section_build_evidence()
	_section_ceilings()


# --- 1. vocabulary -------------------------------------------------------

func _section_vocabulary() -> void:
	print("[SiteContractTest] --- section 1: spec vocabulary")
	var plot := PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	var s := SiteSpec.normalize({"id": "v1", "plot": plot})
	_check("normalize defaults quality to FULL_SITE", s.get("quality", &"") == &"FULL_SITE", str(s.get("quality")))
	_check("normalize defaults fence to none", SiteSpec.fence_style(s) == &"none", str(SiteSpec.fence_style(s)))
	_check("yard area derives from the plot ring", absf(SiteSpec.yard_area(s) - 100.0) < 0.01, str(SiteSpec.yard_area(s)))
	_check("fence perimeter derives from the loop",
		absf(SiteSpec.fence_perimeter(plot) - 40.0) < 0.01, str(SiteSpec.fence_perimeter(plot)))
	_check("species slot returns a yard species",
		SiteSpec.YARD_SPECIES.has(SiteSpec.species_for_slot(3)), str(SiteSpec.species_for_slot(3)))
	_check("linden has a crown radius", SiteSpec.tree_radius(&"linden") > 0.0, str(SiteSpec.tree_radius(&"linden")))
	_check("style heights stay inside the contract band",
		float(SiteSpec.STYLE_HEIGHT[&"picket"]) >= WorldConstants.SITE_MIN_FENCE_H
		and float(SiteSpec.STYLE_HEIGHT[&"palisade"]) <= WorldConstants.SITE_MAX_FENCE_H,
		"picket=%s palisade=%s" % [SiteSpec.STYLE_HEIGHT[&"picket"], SiteSpec.STYLE_HEIGHT[&"palisade"]])


# --- 2. malformed matrix ------------------------------------------------

func _base_site() -> Dictionary:
	var plot := PackedVector2Array([Vector2.ZERO, Vector2(20, 0), Vector2(20, 20), Vector2(0, 20)])
	return SiteSpec.normalize({
		"id": "t_site",
		"kind": &"garden",
		"building_id": "b1",
		"building_rect": Rect2(12, 12, 6, 6),
		"plot": plot,
		"fence": {
			"style": &"picket", "height": 1.2, "post_spacing": 2.0,
			"loop": plot, "gates": [{"center": Vector2(20, 10), "width": 1.2, "for_entrance": ""}],
		},
		"trees": [{"id": "t1", "species": &"linden", "pos": Vector2(5, 5), "radius": 3.0}],
		"entrances": [],
	})


## Every mutation is written as explicit statements: a lambda pass worked but
## buried each case in call syntax, which hid which line broke a rule.
func _reject(site: Dictionary, what: String) -> void:
	var errs: Array[String] = SiteContractValidator.validate_spec(site, _surface)
	_report(what, errs)
	_check("malformed rejected: %s" % what, not errs.is_empty(), "validator accepted it")


func _section_malformed() -> void:
	print("[SiteContractTest] --- section 2: malformed spec matrix")
	var base := _base_site()
	var base_errs: Array[String] = SiteContractValidator.validate_spec(base, _surface)
	_report("baseline", base_errs)
	_check("untouched baseline site validates", base_errs.is_empty(), str(base_errs))

	var s := _base_site()
	s["kind"] = &"helipad"
	_reject(s, "unknown yard kind")

	s = _base_site()
	s["quality"] = &"SUPER"
	_reject(s, "unknown quality")

	s = _base_site()
	s["building_id"] = ""
	_reject(s, "site without a plot building")

	s = _base_site()
	s["plot"] = PackedVector2Array([Vector2.ZERO, Vector2(2, 0), Vector2(2, 2), Vector2(0, 2)])
	_reject(s, "plot below minimum area")

	s = _base_site()
	var f: Dictionary = s["fence"]
	f["height"] = 6.0
	_reject(s, "absurd fence height")

	s = _base_site()
	(s["fence"] as Dictionary)["height"] = 0.2
	_reject(s, "ankle fence height")

	s = _base_site()
	(s["fence"] as Dictionary)["post_spacing"] = 12.0
	_reject(s, "unsupported rails")

	s = _base_site()
	(s["fence"] as Dictionary)["loop"] = PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)])
	_reject(s, "fence line that encloses no ground")

	s = _base_site()
	(s["fence"] as Dictionary)["loop"] = PackedVector2Array(
		[Vector2(0, 0), Vector2(20, 0), Vector2(20, 20), Vector2(0, 20)])
	s["building_rect"] = Rect2(15, -4, 4, 12)
	_reject(s, "fence crossing the building")

	s = _base_site()
	(s["fence"] as Dictionary)["gates"] = []
	_reject(s, "fenced yard with no gate")

	s = _base_site()
	(s["fence"] as Dictionary)["gates"] = [{"center": Vector2(20, 10), "width": 0.25}]
	_reject(s, "undersized gate")

	s = _base_site()
	(s["fence"] as Dictionary)["gates"] = [{"center": Vector2(10, 10), "width": 1.2}]
	_reject(s, "gate away from the fence line")

	s = _base_site()
	s["quality"] = &"DISTANT_LOD"
	_reject(s, "DISTANT_LOD without lod_of")

	s = _base_site()
	s["quality"] = &"DECOR_ONLY"
	s["decor_of"] = "b1"
	_reject(s, "DECOR_ONLY yard carrying standing trees")

	s = _base_site()
	var t0: Dictionary = (s["trees"] as Array)[0]
	t0["species"] = &"banana"
	_reject(s, "unknown tree species")

	s = _base_site()
	var t1: Dictionary = (s["trees"] as Array)[0]
	t1["pos"] = Vector2(26, 1)
	_reject(s, "tree outside the plot")

	s = _base_site()
	var t2: Dictionary = (s["trees"] as Array)[0]
	t2["pos"] = Vector2(14, 14)
	_reject(s, "tree standing inside the house")

	s = _base_site()
	var t3: Dictionary = (s["trees"] as Array)[0]
	t3["pos"] = Vector2(13, 5)
	(s["trees"] as Array).append({"id": "t2", "species": &"oak", "pos": Vector2(13.5, 5.4), "radius": 3.0})
	_reject(s, "two trees in the same hole")

	s = _base_site()
	var many: Array = []
	for i in range(WorldConstants.SITE_MAX_TREES_PER_SITE + 4):
		many.append({"id": "m%d" % i, "species": &"oak",
			"pos": Vector2(2 + i * 2, 18), "radius": 3.0})
	s["trees"] = many
	_reject(s, "more trees than a yard may hold")


# --- 3. city conformance ------------------------------------------------

func _chunk_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for cx in range(-CHUNK_SPAN, CHUNK_SPAN + 1):
		for cz in range(-CHUNK_SPAN, CHUNK_SPAN + 1):
			out.append(WorldSeed.chunk_rect(Vector2i(cx, cz)))
	return out


## Coarse rects over a wider span. The city core is ~930 m across and the
## historic fabric is not necessarily centred on the origin, so discovery walks
## outwards instead of assuming where the yards are.
func _span_rects(span: int, step: int = 1) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for cx in range(-span, span + 1, step):
		for cz in range(-span, span + 1, step):
			out.append(WorldSeed.chunk_rect(Vector2i(cx, cz)))
	return out


func _section_city() -> void:
	print("[SiteContractTest] --- section 3: city courtyard/garden conformance")
	var sites := 0
	var passing := 0
	var bad := 0
	for rect: Rect2 in _chunk_rects():
		for site: Dictionary in plan.city_sites_in(rect):
			sites += 1
			var errs: Array[String] = SiteContractValidator.validate_spec(site, _surface)
			if errs.is_empty():
				passing += 1
			elif bad < 6:
				bad += 1
				_report("city site %s" % str(site.get("id", "?")), errs)
				_check("city site %s valid" % str(site.get("id", "?")), false, str(errs))
	print("[SiteContractTest] city sites=%d passing=%d regions=%d skipped=%d"
		% [sites, passing, int(plan.stats().get("city_regions", 0)), int(plan.stats().get("city_skipped", 0))])
	print("[SiteContractTest] raw grid regions in the walk: %d"
		% plan.raw_region_count(_chunk_rects()))
	var extent := plan.block_extent()
	print("[SiteContractTest] city fabric: blocks=%d courtyard_regions=%d extent=%s"
		% [plan.block_count(), plan.region_total(), str(extent)])
	for span: int in [10, 20, 30, 40]:
		print("[SiteContractTest] region discovery span=%d step=3 -> %d regions"
			% [span, plan.raw_region_count(_span_rects(span, 3))])
	_check("city walk found real sites (>=20)", sites >= 20, "found %d (regions=%d skipped=%d)"
		% [sites, int(plan.stats().get("city_regions", 0)), int(plan.stats().get("city_skipped", 0))])
	_check("every city site passes the site contract", passing == sites,
		"%d/%d passing" % [passing, sites])


# --- 4. fringe conformance ----------------------------------------------

func _section_fringe() -> void:
	print("[SiteContractTest] --- section 4: fringe yard conformance")
	var yards := 0
	var passing := 0
	var coords: Array[Vector2i] = []
	for cx in range(-18, 19, 3):
		for cz in range(-18, 19, 3):
			coords.append(Vector2i(cx, cz))
	for coord: Vector2i in coords:
		for site: Dictionary in plan.fringe_sites_in(WorldSeed.chunk_rect(coord)):
			yards += 1
			var errs: Array[String] = SiteContractValidator.validate_spec(site, _surface)
			if errs.is_empty():
				passing += 1
			elif yards - passing <= 4:
				_report("fringe site %s" % str(site.get("id", "?")), errs)
	print("[SiteContractTest] fringe yards=%d passing=%d" % [yards, passing])
	_check("fringe walk found real yards (>=1)", yards >= 1, "found %d" % yards)
	_check("every fringe yard passes the site contract", passing == yards,
		"%d/%d passing" % [passing, yards])


# --- 5. determinism ------------------------------------------------------

func _section_determinism(seed_used: int) -> void:
	print("[SiteContractTest] --- section 5: determinism")
	var rect := WorldSeed.chunk_rect(Vector2i.ZERO)
	var a := SitePlan.new(seed_used, wp.city_plan, wp.fringe, _surface)
	var b := SitePlan.new(seed_used, wp.city_plan, wp.fringe, _surface)
	var c := SitePlan.new(seed_used + 7919, wp.city_plan, wp.fringe, _surface)
	var sa := str(a.sites_in_rect(rect))
	var sb := str(b.sites_in_rect(rect))
	var sc := str(c.sites_in_rect(rect))
	_check("same seed produces identical sites", sa == sb, "%d vs %d bytes" % [sa.length(), sb.length()])
	_check("different seed produces different sites", sa != sc, "identical output for a different seed")
	_check("sites_in_rect counts city and fringe", a.sites_in_rect(rect).size()
		== a.city_sites_in(rect).size() + a.fringe_sites_in(rect).size(),
		"%d vs %d + %d" % [a.sites_in_rect(rect).size(), a.city_sites_in(rect).size(), a.fringe_sites_in(rect).size()])


# --- 6. build evidence ---------------------------------------------------

func _evidence_for(site: Dictionary, scale: float = 1.0) -> Dictionary:
	var loop := SiteSpec.fence_loop(site)
	var posts := 0
	if loop.size() > 0:
		var spacing := maxf(float(SiteSpec.fence_of(site).get("post_spacing", 2.0)), 0.5)
		posts = int(ceil(SiteSpec.fence_perimeter(loop) / spacing)) + 1
	posts = int(round(posts * scale))
	return {
		"fence_posts": posts,
		"fence_segments": maxi(posts - 1, 0),
		"gate_leaves": SiteSpec.gates_of(site).size(),
		"fence_colliders": maxi(posts, 1) if posts > 0 else 0,
		"tree_trunks": SiteSpec.trees_of(site).size(),
		"ground_y": float(site.get("ground_y", 0.0)),
	}


func _section_build_evidence() -> void:
	print("[SiteContractTest] --- section 6: build evidence (what the emitters must produce)")
	var site := _base_site()
	site["ground_y"] = float(wp.surface_height_at(Vector2(10, 10)))
	var good := _evidence_for(site)
	var gerrs: Array[String] = SiteContractValidator.validate_build(site, good)
	_report("baseline evidence", gerrs)
	_check("baseline evidence is accepted", gerrs.is_empty(), str(gerrs))

	var cases := {
		"fence built without posts": {"fence_posts": 0, "fence_segments": 0},
		"fence built without colliders": {"fence_colliders": 0},
		"fence built without gate leaves": {"gate_leaves": 0},
		"trees missing their trunks": {"tree_trunks": 0},
		"grounding drift": {"ground_y": float(site["ground_y"]) + 9.0},
	}
	for label: String in cases.keys():
		var ev := good.duplicate(true)
		var mut: Dictionary = cases[label]
		for k: String in mut.keys():
			ev[k] = mut[k]
		var errs: Array[String] = SiteContractValidator.validate_build(site, ev)
		_report(label, errs)
		_check("build evidence rejected: %s" % label, not errs.is_empty(), "evidence accepted")

	# An open yard (style none) that nevertheless reports posts is an invisible
	# fence: geometry with no spec behind it.
	var open_site := SiteSpec.normalize({"id": "t_open", "kind": &"garden",
		"building_id": "b1", "plot": (site["plot"] as PackedVector2Array).duplicate()})
	var ev2 := {"fence_posts": 12, "fence_segments": 11, "gate_leaves": 0,
		"fence_colliders": 12, "tree_trunks": 0, "ground_y": float(open_site.get("ground_y", 0.0))}
	var errs2: Array[String] = SiteContractValidator.validate_build(open_site, ev2)
	_report("invisible fence (posts on a style-less site)", errs2)
	_check("build evidence rejected: invisible fence (posts on a style-less site)",
		not errs2.is_empty(), "evidence accepted")


# --- 7. ceilings ---------------------------------------------------------

func _section_ceilings() -> void:
	print("[SiteContractTest] --- section 7: per-rect ceilings")
	var worst_sites := 0
	var worst_trees := 0
	for rect: Rect2 in _chunk_rects():
		var sites: Array[Dictionary] = plan.sites_in_rect(rect)
		worst_sites = maxi(worst_sites, sites.size())
		var trees := 0
		for site: Dictionary in sites:
			trees += SiteSpec.trees_of(site).size()
		worst_trees = maxi(worst_trees, trees)
	print("[SiteContractTest] worst per chunk: sites=%d (cap %d) trees=%d (cap %d)"
		% [worst_sites, WorldConstants.SITE_MAX_PER_RECT, worst_trees, WorldConstants.SITE_MAX_TREES_PER_RECT])
	_check("sites per rect within cap", worst_sites <= WorldConstants.SITE_MAX_PER_RECT,
		"%d > %d" % [worst_sites, WorldConstants.SITE_MAX_PER_RECT])
	_check("trees per rect within cap", worst_trees <= WorldConstants.SITE_MAX_TREES_PER_RECT,
		"%d > %d" % [worst_trees, WorldConstants.SITE_MAX_TREES_PER_RECT])
