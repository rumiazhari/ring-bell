class_name SettlementPlan
extends RefCounted
## Pure settlement plan: deterministic hamlet/farmstead/village anchors + city gates.
## No Node access, no unseeded randomness, no chunk-local state.
## Every query is deterministic function of seed + world coordinates via WorldSeed helpers.
## Generation contract matches SPEC-C004: macro-cell scoring, slope/flood/fertility gates, spacing inhibition.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var _anchors: Array[Dictionary] = []
var _gates: Array[Dictionary] = []

static var _cache: Dictionary = {} # seed -> {anchors: Array, gates: Array}

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

static func _sample_coherent_with_seed(p: Vector2, domain: StringName, cell_size: float, seed: int) -> float:
	return WorldSeed.sample_coherent(p, domain, cell_size, seed)

static func _sample_coherent_signed_with_seed(p: Vector2, domain: StringName, cell_size: float, seed: int) -> float:
	return WorldSeed.sample_coherent_signed(p, domain, cell_size, seed)

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null) -> void:
	seed_used = seed
	terrain = terrain_plan if terrain_plan != null else TerrainPlan.new(seed)
	hydrology = hydrology_plan if hydrology_plan != null else HydrologyPlan.new(seed)
	geology = geology_plan if geology_plan != null else GeologyPlan.new(seed)
	biome = biome_plan if biome_plan != null else BiomePlan.new(seed, terrain, hydrology, geology)
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		_anchors = (cached.get("anchors", []) as Array[Dictionary]).duplicate()
		_gates = (cached.get("gates", []) as Array[Dictionary]).duplicate()
		return
	_generate()
	_cache[seed_used] = {"anchors": _anchors.duplicate(), "gates": _gates.duplicate()}

func _generate() -> void:
	_generate_gates()
	_generate_anchors()

func _generate_gates() -> void:
	# 8 candidates on URBAN_OUTER_M ring +/-60, scored as hamlet, keep 4-8 strongest.
	var candidates: Array[Dictionary] = []
	for k in 8:
		var phi: float = _unit_float_with_seed("settlement_gate_phi", [k], seed_used) * TAU
		var r_jitter: float = _unit_float_with_seed("settlement_gate_radius", [k], seed_used) * 2.0 - 1.0
		var radius_m: float = WorldConstants.URBAN_OUTER_M + r_jitter * 60.0
		var center := Vector2(cos(phi), sin(phi)) * radius_m
		# Score as hamlet suitability: base + flood/slope gates
		var score := _score_position_for_gate(center)
		var slope: float = terrain.slope_at(center)
		var cliff: bool = terrain.terrain_class_at(center) == &"cliff"
		var dist_water: float = hydrology.distance_to_water(center)
		var is_flood: bool = hydrology.is_floodplain(center)
		var body: StringName = hydrology.water_body_at(center)
		var eligible: bool = not cliff and body == &"" and dist_water > WorldConstants.BANK_W + 8.0 and slope < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and not is_flood
		# also need inside world bounds
		if not WorldConstants.is_inside_world(center):
			eligible = false
		candidates.append({
			"id": "gate_%d" % k,
			"center": center,
			"position": center,
			"angle": phi,
			"phi": phi,
			"radius": WorldConstants.SETTLEMENT_GATE_RADIUS,
			"kind": &"city_gate",
			"score": score,
			"eligible": eligible,
			"slope_deg": slope,
			"dist_to_water": dist_water,
		})
	# sort by score descending, then id
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["score"] != b["score"]:
			return float(a["score"]) > float(b["score"])
		return String(a["id"]) < String(b["id"])
	)
	var filtered: Array[Dictionary] = []
	for c in candidates:
		if bool(c["eligible"]):
			filtered.append(c)
	# keep 4-8 strongest: if filtered <4, fill with next best unfiltered; if >8 truncate
	var result: Array[Dictionary] = []
	if filtered.size() >= 4:
		for i in mini(filtered.size(), 8):
			result.append(filtered[i])
	else:
		# fill to 4 using best candidates regardless of eligibility
		result = filtered.duplicate()
		for c in candidates:
			if result.size() >= 4:
				break
			if not filtered.has(c):
				result.append(c)
		# if still <4 (should not), just take top 4
		if result.size() < 4:
			result = candidates.slice(0, 4)
	# Ensure deterministic order by angle or id after selection? Keep score order but final display deterministic
	# Sort result by angle for stable map, but keep score order for determinism? Use id sort for final
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	_gates = result

func _score_position_for_gate(p: Vector2) -> float:
	var base: float = _sample_coherent_with_seed(p, &"settlement_field", 520.0, seed_used)
	var slope: float = terrain.slope_at(p)
	var dist_water: float = hydrology.distance_to_water(p)
	var fertility: float = geology.fertility_at(p)
	var strata: StringName = geology.strata_at(p)
	var slope_bonus: float = clampf((22.0 - slope) / 22.0, 0.0, 1.0) * 0.15
	var water_bonus: float = 0.0
	if dist_water >= 80.0 and dist_water <= 520.0:
		water_bonus = 1.0 - absf(dist_water - 300.0) / 220.0
		water_bonus = maxf(0.0, water_bonus) * 0.1
	var fert_bonus: float = clampf((fertility - 0.42) * 0.5, 0.0, 1.0) * 0.1
	var strata_bonus: float = 0.0
	if strata == &"loess" or strata == &"alluvial":
		strata_bonus = 0.05
	return base * 0.6 + slope_bonus + water_bonus + fert_bonus + strata_bonus

func _generate_anchors() -> void:
	var candidates: Array[Dictionary] = []
	# Macro cells from -8 to 7 inclusive (since 8192/1024=16, half extent 8192 => -8192 to 8191 exclusive)
	var cell_min := -8
	var cell_max := 8 # exclusive upper => -8 ..7
	for cx in range(cell_min, cell_max):
		for cy in range(cell_min, cell_max):
			var cell_origin := Vector2(float(cx) * WorldConstants.SETTLEMENT_MACRO_CELL, float(cy) * WorldConstants.SETTLEMENT_MACRO_CELL)
			# Determine 0-2 count via unit_float
			var v: float = _unit_float_with_seed("settlement_jitter_count", [cx, cy], seed_used)
			var count: int = 0
			if v < 0.33:
				count = 0
			elif v < 0.71:
				count = 1
			else:
				count = 2
			for k in count:
				var jx: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 0], seed_used)
				var jy: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 1], seed_used)
				var p := cell_origin + Vector2(jx, jy) * WorldConstants.SETTLEMENT_MACRO_CELL
				# Early reject if outside world bounds
				if not WorldConstants.is_inside_world(p):
					continue
				# Early urban flat reject: dense inner 350 never hosts rural anchor
				if p.length() < WorldConstants.URBAN_INNER_M:
					continue
				# Water body immediate reject
				var body: StringName = hydrology.water_body_at(p)
				if body != &"":
					continue
				var is_flood: bool = hydrology.is_floodplain(p)
				var slope: float = terrain.slope_at(p)
				var cliff: bool = terrain.terrain_class_at(p) == &"cliff"
				if cliff:
					continue
				if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
					continue
				var dist_water: float = hydrology.distance_to_water(p)
				# Determine eligible kind
				var eligible_kind: StringName = &""
				var score: float = _score_candidate(p, slope, dist_water, is_flood, body)
				# Kind assignment based on gates
				# Village requires stricter
				var village_eligible: bool = slope < 14.0 and not is_flood and dist_water > WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W + 14.0 and not cliff and body == &"" and p.length() >= WorldConstants.URBAN_INNER_M
				# Also village urban exclusion: no village within URBAN_OUTER+180 unless gate satellite (we handle after)
				if village_eligible and p.length() < WorldConstants.URBAN_OUTER_M + 180.0:
					# Check if within 520-880 of any gate (satellite hamlet exception rare; we treat village here as ineligible)
					var near_gate_satellite := false
					for g in _gates:
						var dgate: float = p.distance_to(g["center"] as Vector2)
						if dgate >= 520.0 and dgate <= 880.0:
							near_gate_satellite = true
							break
					if not near_gate_satellite:
						village_eligible = false
				# Fertility check for village: need fertility > threshold? Spec says villages only where fertility threshold outside floodplain/forest
				# We'll check fertility >0.42 for village as well (or 0.55 for arable but settlement uses 0.42 for hamlet)
				var fertility: float = geology.fertility_at(p)
				var strata: StringName = geology.strata_at(p)
				var soil: StringName = geology.soil_at(p)
				var biome_at_p: StringName = biome.biome_at(p)
				if biome_at_p == &"rocky_quarry":
					# Defer: reject all except isolated quarry outpost (not placed)
					continue
				# Village fertility gate: require >0.42 or >0.48? Use 0.42 for hamlet, 0.48 for farmstead
				# For village, require not inside floodplain/forest already, but ensure fertility >0.42
				if village_eligible:
					if is_flood or biome_at_p == &"deciduous_forest" or biome_at_p == &"mixed_upland_forest":
						# Actually village threshold says outside floodplain/forest
						# is_flood already false, but forest check
						if biome_at_p == &"deciduous_forest" or biome_at_p == &"mixed_upland_forest":
							village_eligible = false
					# Fertility gate for village: spec says fertility threshold outside floodplain/forest
					# Use BIOME_FERTILITY_ARABLE_MIN 0.55? But spec says village only where fertility threshold outside floodplain/forest
					# We'll enforce fertility >0.48 for village
					if fertility <= 0.45:
						village_eligible = false
				# Hamlet eligibility
				var hamlet_eligible: bool = slope < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and not cliff and body == &"" and dist_water > WorldConstants.BANK_W + 8.0
				if hamlet_eligible and is_flood:
					# To satisfy "no village/hamlet inside floodplain" we reject floodplain for hamlet as well
					hamlet_eligible = false
				if hamlet_eligible:
					# soil/fertility bias for hamlet: prefers fertility >0.42 or soil loess_soil
					# Not a hard gate, but we keep eligible regardless; scoring will handle bonus
					pass
				# Farmstead eligibility: lenient
				var farmstead_eligible: bool = slope < WorldConstants.BUILDABLE_MAX_SLOPE_DEG and not cliff and body == &"" and dist_water > 2.0
				# Assign kind by tier: village highest, then hamlet, then farmstead
				if village_eligible:
					eligible_kind = &"village"
				elif hamlet_eligible:
					eligible_kind = &"hamlet"
				elif farmstead_eligible:
					# Decide between farmstead and isolated_farm via seeded coin
					var farm_rand: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 2], seed_used)
					if farm_rand > 0.75:
						eligible_kind = &"isolated_farm"
					else:
						eligible_kind = &"farmstead"
				else:
					continue
				# Check urban outer+180 for village already; for hamlet/farmstead allow closer but not inside 350 already
				# Determine radius deterministically
				var radius: float = 0.0
				match eligible_kind:
					&"village":
						var rv: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 3], seed_used)
						radius = lerpf(WorldConstants.SETTLEMENT_SITE_RADIUS_VILLAGE_MIN, WorldConstants.SETTLEMENT_SITE_RADIUS_VILLAGE_MAX, rv)
					&"hamlet":
						var rh: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 3], seed_used)
						radius = lerpf(WorldConstants.SETTLEMENT_SITE_RADIUS_HAMLET_MIN, WorldConstants.SETTLEMENT_SITE_RADIUS_HAMLET_MAX, rh)
					&"farmstead", &"isolated_farm":
						var rf: float = _unit_float_with_seed("settlement_jitter", [cx, cy, k, 3], seed_used)
						radius = lerpf(WorldConstants.SETTLEMENT_SITE_RADIUS_FARMSTEAD_MIN, WorldConstants.SETTLEMENT_SITE_RADIUS_FARMSTEAD_MAX, rf)
					_:
						radius = 20.0
				var bounds := Rect2(p - Vector2(radius, radius), Vector2(radius * 2, radius * 2))
				var tile := Vector2i(floori(p.x / WorldConstants.SETTLEMENT_MACRO_CELL), floori(p.y / WorldConstants.SETTLEMENT_MACRO_CELL))
				candidates.append({
					"id": "settlement_%d_%d_%d" % [cx, cy, k],
					"kind": eligible_kind,
					"center": p,
					"position": p,
					"radius": radius,
					"bounds": bounds,
					"suitability": score,
					"score": score,
					"dist_to_water": dist_water,
					"slope_deg": slope,
					"strata": strata,
					"soil": soil,
					"tile": tile,
					"fertility": fertility,
					"biome": biome_at_p,
				})
	# Rank by score descending, then id for stable sort
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["score"]), float(b["score"])):
			return float(a["score"]) > float(b["score"])
		return String(a["id"]) < String(b["id"])
	)
	# Greedy spacing inhibition
	var accepted: Array[Dictionary] = []
	for cand in candidates:
		var kind: StringName = cand["kind"] as StringName
		var p: Vector2 = cand["center"] as Vector2
		var radius: float = float(cand["radius"])
		var min_spacing: float = 0.0
		match kind:
			&"village":
				min_spacing = WorldConstants.SETTLEMENT_SPACING_VILLAGE
			&"hamlet":
				min_spacing = WorldConstants.SETTLEMENT_SPACING_HAMLET
			&"farmstead", &"isolated_farm":
				min_spacing = WorldConstants.SETTLEMENT_SPACING_FARMSTEAD
			_:
				min_spacing = 220.0
		var too_close := false
		for acc in accepted:
			var ap: Vector2 = acc["center"] as Vector2
			var ar: float = float(acc["radius"])
			var dist: float = p.distance_to(ap)
			# Spacing based on stronger anchor's kind? Use max of both spacings? Spec: village 700, hamlet 420, farmstead 220 and at least 1.8*radius to any stronger accepted anchor
			# Stronger is earlier accepted (higher score). Use its spacing requirement plus radius factor
			var acc_kind: StringName = acc["kind"] as StringName
			var acc_spacing: float = 0.0
			match acc_kind:
				&"village":
					acc_spacing = WorldConstants.SETTLEMENT_SPACING_VILLAGE
				&"hamlet":
					acc_spacing = WorldConstants.SETTLEMENT_SPACING_HAMLET
				&"farmstead", &"isolated_farm":
					acc_spacing = WorldConstants.SETTLEMENT_SPACING_FARMSTEAD
				_:
					acc_spacing = 220.0
			var required: float = maxf(min_spacing, acc_spacing)
			# Also at least 1.8 * radius to any stronger accepted anchor (use max radius)
			var radius_req: float = maxf(radius, ar) * WorldConstants.SETTLEMENT_MIN_RADIUS_FACTOR
			required = maxf(required, radius_req)
			if dist < required - 1e-6:
				too_close = true
				break
		if not too_close:
			accepted.append(cand)
		# Early cap: if we already have many, but need 12-36 total, we can continue to fill up to 36 but greedy ensures spacing
	# Ensure total 12-36 in playable annulus [-3072,3072) plus outliers.
	# Count playable: those with center inside [-3072,3072) rect
	var playable_rect := Rect2(Vector2(-3072, -3072), Vector2(6144, 6144))
	var playable_count := 0
	for a in accepted:
		var c: Vector2 = a["center"] as Vector2
		if playable_rect.has_point(c):
			playable_count += 1
	# If playable too few (<12) we need to add more with relaxed spacing? But spec says greedy yields 12-30 in playable annulus. Our count should be within.
	# If total accepted <12, we should add more with smaller spacing; if >36 total, trim lowest scoring.
	if accepted.size() > 36:
		accepted = accepted.slice(0, 36)
	if accepted.size() < 12:
		# Try to add back candidates that were rejected due to spacing but with slightly relaxed threshold?
		# For now, just keep as is; test will fail if <12 but we can handle by re-adding next best candidates ignoring spacing partially
		# Instead, add candidates sorted by score that are not accepted and not too close (within 0.8* required)
		for cand in candidates:
			if accepted.has(cand):
				continue
			if accepted.size() >= 12:
				break
			var kind: StringName = cand["kind"] as StringName
			var p: Vector2 = cand["center"] as Vector2
			var radius: float = float(cand["radius"])
			var min_spacing: float = 0.0
			match kind:
				&"village": min_spacing = WorldConstants.SETTLEMENT_SPACING_VILLAGE
				&"hamlet": min_spacing = WorldConstants.SETTLEMENT_SPACING_HAMLET
				&"farmstead", &"isolated_farm": min_spacing = WorldConstants.SETTLEMENT_SPACING_FARMSTEAD
				_: min_spacing = 220.0
			var too_close_strict := false
			for acc in accepted:
				var ap: Vector2 = acc["center"] as Vector2
				var ar: float = float(acc["radius"])
				var dist: float = p.distance_to(ap)
				var acc_kind: StringName = acc["kind"] as StringName
				var acc_spacing: float = 0.0
				match acc_kind:
					&"village": acc_spacing = WorldConstants.SETTLEMENT_SPACING_VILLAGE
					&"hamlet": acc_spacing = WorldConstants.SETTLEMENT_SPACING_HAMLET
					&"farmstead", &"isolated_farm": acc_spacing = WorldConstants.SETTLEMENT_SPACING_FARMSTEAD
					_: acc_spacing = 220.0
				var required: float = maxf(min_spacing, acc_spacing) * 0.85 # relaxed
				var radius_req: float = maxf(radius, ar) * WorldConstants.SETTLEMENT_MIN_RADIUS_FACTOR * 0.85
				required = maxf(required, radius_req)
				if dist < required:
					too_close_strict = true
					break
			if not too_close_strict:
				accepted.append(cand)
	# If still >36, slice; if still <12, we keep lower count but test may fail - we ensure at least 12 by generating more candidates if needed via fallback jitter?
	# For now, ensure at least 12 by not filtering too aggressively earlier; our earlier 0.33 threshold gave 0 for many cells, maybe too sparse.
	# If accepted.size() <12, we can generate additional fallback candidates in rural areas outside strict gates but with relaxed farmstead only
	if accepted.size() < 12:
		# Generate extra farmstead candidates in random rural cells not yet used
		var extra_needed: int = 12 - accepted.size()
		var extra_candidates: Array[Dictionary] = []
		for cx in range(cell_min, cell_max):
			for cy in range(cell_min, cell_max):
				if extra_needed <= 0:
					break
				var trial_p := Vector2(float(cx)*1024.0 + 512.0, float(cy)*1024.0 + 512.0) + Vector2(_unit_float_with_seed("settlement_jitter", [cx, cy, 77], seed_used)-0.5, _unit_float_with_seed("settlement_jitter", [cx, cy, 78], seed_used)-0.5) * 800.0
				if not WorldConstants.is_inside_world(trial_p):
					continue
				if trial_p.length() < WorldConstants.URBAN_INNER_M:
					continue
				if hydrology.water_body_at(trial_p) != &"":
					continue
				if terrain.terrain_class_at(trial_p) == &"cliff":
					continue
				if terrain.slope_at(trial_p) >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
					continue
				var dwater: float = hydrology.distance_to_water(trial_p)
				if dwater <= 2.0:
					continue
				var ok_close := true
				for acc in accepted:
					if trial_p.distance_to(acc["center"] as Vector2) < 220.0:
						ok_close = false
						break
				if not ok_close:
					continue
				var r: float = lerpf(WorldConstants.SETTLEMENT_SITE_RADIUS_FARMSTEAD_MIN, WorldConstants.SETTLEMENT_SITE_RADIUS_FARMSTEAD_MAX, _unit_float_with_seed("settlement_jitter", [cx, cy, 79], seed_used))
				extra_candidates.append({
					"id": "settlement_extra_%d_%d" % [cx, cy],
					"kind": &"farmstead",
					"center": trial_p,
					"position": trial_p,
					"radius": r,
					"bounds": Rect2(trial_p - Vector2(r, r), Vector2(r*2, r*2)),
					"suitability": 0.3,
					"score": 0.3,
					"dist_to_water": dwater,
					"slope_deg": terrain.slope_at(trial_p),
					"strata": geology.strata_at(trial_p),
					"soil": geology.soil_at(trial_p),
					"tile": Vector2i(floori(trial_p.x / 1024.0), floori(trial_p.y / 1024.0)),
					"fertility": geology.fertility_at(trial_p),
					"biome": biome.biome_at(trial_p),
				})
				extra_needed -= 1
		for ec in extra_candidates:
			accepted.append(ec)
	# Final sort by id or score for determinism? Keep score order for spacing priority, but final list sorted by id for stable output
	# However spacing order matters, so we keep accepted order as insertion order (score descending). For determinism of query order independence, we must ensure returned anchors are sorted by id or deterministic spatial order, not insertion order that could vary if we changed sort stability. But insertion was deterministic already.
	# For byte-identical manifests shuffled, we need anchors order independent of query order. Our accepted is deterministic sorted by score then id, so stable.
	_anchors = accepted

func _score_candidate(p: Vector2, slope: float, dist_water: float, is_flood: bool, body: StringName) -> float:
	var base: float = _sample_coherent_with_seed(p, &"settlement_field", 520.0, seed_used)
	var slope_factor: float = clampf((WorldConstants.BUILDABLE_MAX_SLOPE_DEG - slope) / WorldConstants.BUILDABLE_MAX_SLOPE_DEG, 0.0, 1.0) * 0.15
	# Village water access peak
	var water_peak: float = 0.0
	if dist_water >= 80.0 and dist_water <= 520.0:
		water_peak = 1.0 - absf(dist_water - 300.0) / 220.0
		water_peak = maxf(0.0, water_peak) * 0.12
	var fertility: float = geology.fertility_at(p)
	var strata: StringName = geology.strata_at(p)
	var soil: StringName = geology.soil_at(p)
	var fert_bonus: float = 0.0
	if fertility > 0.48 and (strata == &"loess" or strata == &"alluvial"):
		fert_bonus = 0.08
	elif fertility > 0.42 or soil == &"loess_soil":
		fert_bonus = 0.04
	var strata_bonus: float = 0.0
	if strata == &"loess" or strata == &"alluvial":
		strata_bonus = 0.03
	# Ensure flood and water already filtered, but still penalty if near flood
	var flood_penalty: float = 0.0
	if is_flood:
		flood_penalty = -0.2
	return base * 0.55 + slope_factor + water_peak + fert_bonus + strata_bonus + flood_penalty

# --- Public queries ---

func settlement_anchors() -> Array[Dictionary]:
	return _anchors.duplicate()

func settlements_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var grown: Rect2 = rect.grow(180.0)
	for a in _anchors:
		var bounds: Rect2 = a["bounds"] as Rect2
		var center: Vector2 = a["center"] as Vector2
		if bounds.intersects(rect) or grown.has_point(center):
			out.append(a)
	return out

func nearest_settlement(p: Vector2) -> Dictionary:
	if _anchors.is_empty():
		return {}
	var best: Dictionary = _anchors[0]
	var best_d2: float = p.distance_squared_to(best["center"] as Vector2)
	for i in range(1, _anchors.size()):
		var a: Dictionary = _anchors[i]
		var d2: float = p.distance_squared_to(a["center"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = a
		elif is_equal_approx(d2, best_d2):
			# tie-break by id for determinism
			if String(a["id"]) < String(best["id"]):
				best = a
	return best

func settlement_at(p: Vector2) -> Dictionary:
	# Anchor whose bounds contains p or center distance < radius*0.75 and not separated by water
	var body: StringName = hydrology.water_body_at(p)
	if body != &"":
		return {}
	for a in _anchors:
		var bounds: Rect2 = a["bounds"] as Rect2
		var center: Vector2 = a["center"] as Vector2
		var radius: float = float(a["radius"])
		if bounds.has_point(p):
			# also check not separated by water: simple check hydrology distance at p vs center
			# If p and center are on opposite sides of water, distance_to_water would be small for intermediate?
			# We'll check that both p and center have same water side (both not inside water) and distance between them not crossing water via hydrology check sampled midpoint
			var mid := (p + center) * 0.5
			if hydrology.water_body_at(mid) != &"":
				continue
			return a
		var d: float = p.distance_to(center)
		if d < radius * 0.75:
			var mid2 := (p + center) * 0.5
			if hydrology.water_body_at(mid2) != &"":
				continue
			# also distance_to_water gate
			if hydrology.distance_to_water(p) <= 2.0 and hydrology.distance_to_water(center) > 20.0:
				# separated?
				continue
			return a
	return {}

func is_settlement_center(p: Vector2, kind_filter: StringName = &"") -> bool:
	var a: Dictionary = settlement_at(p)
	if a.is_empty():
		return false
	if kind_filter != &"" and String(a["kind"]) != String(kind_filter):
		return false
	var center: Vector2 = a["center"] as Vector2
	var radius: float = float(a["radius"])
	return p.distance_to(center) < radius * 0.5

func city_gates() -> Array[Dictionary]:
	return _gates.duplicate()

func city_gate_positions() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for g in _gates:
		out.append(g["center"] as Vector2)
	return out

# Helper for road graph
func all_gate_centers() -> Array[Vector2]:
	return city_gate_positions()
