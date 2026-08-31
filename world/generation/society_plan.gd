class_name SocietyPlan
extends RefCounted
## Pure settlement society work schedule — deterministic hamlet worker 06:00-18:00.
## No Node, no scene tree, no unseeded RNG. Same seed+coords → same worker→site mapping
## regardless of query order or worker scheduling. Handles negative coords via floori.
## Generation contract: each hamlet gets 0-1 worker (never village this slice) where
## nearest workbench/granary/field parcel within SOCIETY_WORK_RADIUS_M (90). Worker id
## stable soc_worker_<hamlet_id>. Pure, no collider, no persistence.

var seed_used: int
var settlement: SettlementPlan
var rural_building: RuralBuildingPlan
var biome: BiomePlan
var _world_plan: RefCounted

var _workers: Array[Dictionary] = []
var _by_settlement: Dictionary = {} # settlement_id -> worker Dictionary
var _by_id: Dictionary = {} # worker_id -> worker Dictionary

static var _cache: Dictionary = {} # seed -> {workers, by_settlement, by_id}

static func _unit_float_with_seed(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

func _init(seed: int = WorldSeed.get_world_seed(), terrain_plan: TerrainPlan = null, hydrology_plan: HydrologyPlan = null, geology_plan: GeologyPlan = null, biome_plan: BiomePlan = null, settlement_plan: SettlementPlan = null, road_network_plan: RoadNetworkPlan = null, rural_building_plan: RuralBuildingPlan = null) -> void:
	seed_used = seed
	# Accept explicit plans if provided (like CavePlan). Otherwise defer to lazy generation.
	if settlement_plan != null:
		settlement = settlement_plan
	if rural_building_plan != null:
		rural_building = rural_building_plan
	if biome_plan != null:
		biome = biome_plan
	# If we were given a full world-like set, also try to keep reference for consistency.
	# Do not generate yet — _ensure_generated will use _world_plan if set via set_world_refs,
	# otherwise will create temporary individual plans for pure determinism.
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		_workers = (cached.get("workers", []) as Array[Dictionary]).duplicate()
		_by_settlement = (cached.get("by_settlement", {}) as Dictionary).duplicate()
		_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()
		return
	# else defer generation until first query (ensures biome.set_world_refs already called if world_plan exists)

func set_world_refs(world_plan) -> void:
	_world_plan = world_plan
	settlement = world_plan.settlement
	rural_building = world_plan.rural_building
	biome = world_plan.biome
	# Invalidate any previously cached empty generation so next query regenerates with correct refs.
	# If we already have cached workers for this seed, keep them (pure function of seed).
	if _workers.is_empty() and _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		_workers = (cached.get("workers", []) as Array[Dictionary]).duplicate()
		_by_settlement = (cached.get("by_settlement", {}) as Dictionary).duplicate()
		_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()

func _ensure_generated() -> void:
	if not _workers.is_empty():
		return
	if _cache.has(seed_used):
		var cached: Dictionary = _cache[seed_used] as Dictionary
		_workers = (cached.get("workers", []) as Array[Dictionary]).duplicate()
		_by_settlement = (cached.get("by_settlement", {}) as Dictionary).duplicate()
		_by_id = (cached.get("by_id", {}) as Dictionary).duplicate()
		if not _workers.is_empty():
			return
	# Need to generate
	_generate()

func _generate() -> void:
	_workers.clear()
	_by_settlement.clear()
	_by_id.clear()
	var use_settlement: SettlementPlan = settlement
	var use_rural: RuralBuildingPlan = rural_building
	var use_biome: BiomePlan = biome
	var wp = _world_plan
	if wp != null:
		use_settlement = wp.settlement
		use_rural = wp.rural_building
		use_biome = wp.biome
	if use_settlement == null or use_rural == null or use_biome == null:
		# Create temporary individual plans without WorldPlan to avoid circular dependency
		var tmp_terrain := TerrainPlan.new(seed_used)
		var tmp_hydro := HydrologyPlan.new(seed_used)
		var tmp_geo := GeologyPlan.new(seed_used)
		var tmp_biome := BiomePlan.new(seed_used, tmp_terrain, tmp_hydro, tmp_geo)
		var tmp_settlement := SettlementPlan.new(seed_used, tmp_terrain, tmp_hydro, tmp_geo, tmp_biome)
		var tmp_road := RoadNetworkPlan.new(seed_used, tmp_terrain, tmp_hydro, tmp_geo, tmp_biome, tmp_settlement)
		var tmp_rural := RuralBuildingPlan.new(seed_used, tmp_terrain, tmp_hydro, tmp_geo, tmp_biome, tmp_settlement, tmp_road)
		tmp_biome.set_world_refs(tmp_settlement, tmp_road, tmp_rural)
		use_settlement = tmp_settlement
		use_rural = tmp_rural
		use_biome = tmp_biome
		settlement = use_settlement
		rural_building = use_rural
		biome = use_biome
	var anchors: Array[Dictionary] = use_settlement.settlement_anchors()
	for anchor in anchors:
		var kind: StringName = anchor.get("kind", &"") as StringName
		if kind != &"hamlet":
			continue
		var sid: String = String(anchor.get("id", ""))
		var home_pos: Vector2 = anchor.get("center", Vector2.ZERO) as Vector2
		if home_pos.length() < WorldConstants.URBAN_INNER_M - 1e-6:
			continue
		var h: int = WorldSeed.str_hash(sid)
		var roll: float = WorldSeed.unit_float("society_work", [h])
		# roll is deterministic but not gating; site existence gates worker (spec: hamlet always 1 if site within 90 else 0)
		var search_rect := Rect2(home_pos - Vector2(WorldConstants.SOCIETY_WORK_RADIUS_M, WorldConstants.SOCIETY_WORK_RADIUS_M), Vector2(WorldConstants.SOCIETY_WORK_RADIUS_M * 2.0, WorldConstants.SOCIETY_WORK_RADIUS_M * 2.0))
		var candidates: Array[Dictionary] = []
		# workbenches
		if use_rural != null:
			var wbs: Array[Dictionary] = use_rural.rural_workbenches_in(search_rect)
			for wb in wbs:
				var c: Vector2 = wb.get("center", Vector2.ZERO) as Vector2
				var d: float = home_pos.distance_to(c)
				if d <= WorldConstants.SOCIETY_WORK_RADIUS_M + 1e-6:
					candidates.append({"id": String(wb.get("id", "")), "center": c, "pos": c, "kind": &"workbench", "distance": d, "aabb": wb.get("aabb", Rect2(c - Vector2(0.6, 0.3), Vector2(1.2, 0.6))), "raw": wb})
			var grs: Array[Dictionary] = use_rural.rural_granaries_in(search_rect)
			for gr in grs:
				var c2: Vector2 = gr.get("center", Vector2.ZERO) as Vector2
				var d2: float = home_pos.distance_to(c2)
				if d2 <= WorldConstants.SOCIETY_WORK_RADIUS_M + 1e-6:
					candidates.append({"id": String(gr.get("id", "")), "center": c2, "pos": c2, "kind": &"granary", "distance": d2, "aabb": gr.get("aabb", Rect2(c2 - Vector2(0.6, 0.4), Vector2(1.2, 0.8))), "raw": gr})
		if use_biome != null:
			var fps: Array[Dictionary] = use_biome.field_parcels_in(search_rect)
			for fp in fps:
				var c3: Vector2 = fp.get("center", fp.get("pos", Vector2.ZERO)) as Vector2
				var d3: float = home_pos.distance_to(c3)
				if d3 <= WorldConstants.SOCIETY_WORK_RADIUS_M + 1e-6:
					candidates.append({"id": String(fp.get("id", "")), "center": c3, "pos": c3, "kind": &"field_parcel", "distance": d3, "aabb": fp.get("aabb", Rect2(c3 - Vector2(9, 7), Vector2(18, 14))), "raw": fp})
			var ops: Array[Dictionary] = use_biome.orchard_parcels_in(search_rect)
			for op in ops:
				var c4: Vector2 = op.get("center", op.get("pos", Vector2.ZERO)) as Vector2
				var d4: float = home_pos.distance_to(c4)
				if d4 <= WorldConstants.SOCIETY_WORK_RADIUS_M + 1e-6:
					candidates.append({"id": String(op.get("id", "")), "center": c4, "pos": c4, "kind": &"field_parcel", "distance": d4, "aabb": op.get("aabb", Rect2(c4 - Vector2(10, 8), Vector2(20, 16))), "raw": op})
		if candidates.is_empty():
			continue
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da: float = float(a["distance"])
			var db: float = float(b["distance"])
			if not is_equal_approx(da, db):
				return da < db
			return String(a["id"]) < String(b["id"])
		)
		var chosen: Dictionary = candidates[0]
		var worker_id: String = "soc_worker_%s" % sid
		var work_pos: Vector2 = chosen["center"] as Vector2
		var work_site_id: String = String(chosen["id"])
		var work_kind: StringName = chosen["kind"] as StringName
		var dist: float = float(chosen["distance"])
		var aabb: Rect2 = chosen["aabb"] as Rect2
		var worker: Dictionary = {
			"id": worker_id,
			"worker_id": worker_id,
			"settlement_id": sid,
			"settlement_kind": kind,
			"home_pos": home_pos,
			"home_center": home_pos,
			"work_site_id": work_site_id,
			"work_site_kind": work_kind,
			"work_pos": work_pos,
			"work_center": work_pos,
			"work_aabb": aabb,
			"distance": dist,
			"roll": roll,
		}
		_workers.append(worker)
		_by_settlement[sid] = worker
		_by_id[worker_id] = worker
	_workers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	_cache[seed_used] = {"workers": _workers.duplicate(), "by_settlement": _by_settlement.duplicate(), "by_id": _by_id.duplicate()}

# --- Public pure API ---
func workers() -> Array[Dictionary]:
	_ensure_generated()
	return _workers.duplicate()

func workers_in(rect: Rect2) -> Array[Dictionary]:
	_ensure_generated()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return [] as Array[Dictionary]
	var out: Array[Dictionary] = []
	for w in _workers:
		var home: Vector2 = w["home_pos"] as Vector2
		if rect.has_point(home):
			out.append(w)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return out

func worker_for_settlement(settlement_id: String) -> Dictionary:
	_ensure_generated()
	if _by_settlement.has(settlement_id):
		return _by_settlement[settlement_id] as Dictionary
	return {}

func worker_for_settlement_name(settlement_id: StringName) -> Dictionary:
	return worker_for_settlement(String(settlement_id))

func nearest_worker(p: Vector2) -> Dictionary:
	_ensure_generated()
	if _workers.is_empty():
		return {}
	var best: Dictionary = _workers[0]
	var best_d2: float = p.distance_squared_to(best["home_pos"] as Vector2)
	for i in range(1, _workers.size()):
		var w: Dictionary = _workers[i]
		var d2: float = p.distance_squared_to(w["home_pos"] as Vector2)
		if d2 < best_d2 - 1e-6:
			best_d2 = d2
			best = w
		elif is_equal_approx(d2, best_d2):
			if String(w["id"]) < String(best["id"]):
				best = w
	return best

func work_site_for_worker(worker_id: String) -> Dictionary:
	_ensure_generated()
	if _by_id.has(worker_id):
		var w: Dictionary = _by_id[worker_id] as Dictionary
		# Return a site-like dict for compatibility
		return {
			"id": String(w.get("work_site_id", "")),
			"work_site_id": String(w.get("work_site_id", "")),
			"kind": w.get("work_site_kind", &""),
			"work_site_kind": w.get("work_site_kind", &""),
			"pos": w.get("work_pos", Vector2.ZERO),
			"center": w.get("work_pos", Vector2.ZERO),
			"work_pos": w.get("work_pos", Vector2.ZERO),
			"aabb": w.get("work_aabb", Rect2()),
			"distance": w.get("distance", 0.0),
			"settlement_id": w.get("settlement_id", ""),
		}
	return {}

func workers_count() -> int:
	_ensure_generated()
	return _workers.size()
