class_name SpawnPoints
extends RefCounted
## Deterministic spawn queries for the Main Menu test spawns.
## Reads WorldPlan / CityPlan only — never writes generation state.
## Used by world/main.gd deferred loading to pick a validated spawn Vector3
## for direct testing of generated biomes without editing generation code.

const SPAWN_KINDS: Array[Dictionary] = [
	{"id": &"city_center", "label": "City Center", "desc": "Dense historic core — plaza + multi-storey"},
	{"id": &"city_gate", "label": "City Gate", "desc": "Where city meets countryside road"},
	{"id": &"village", "label": "Village", "desc": "Village 4-6 houses — well + hearth"},
	{"id": &"hamlet", "label": "Hamlet", "desc": "Hamlet 2-3 houses — tight + hedgerow"},
	{"id": &"farmstead", "label": "Farmstead", "desc": "Isolated farm — quiet + fields"},
	{"id": &"field", "label": "Field — Wheat", "desc": "Tilled wheat parcels 200-600m blocks"},
	{"id": &"orchard", "label": "Orchard", "desc": "Orchard rows — apple/plum rows"},
	{"id": &"forest", "label": "Wilderness — Forest", "desc": "Deep deciduous forest — shady"},
	{"id": &"river_bank", "label": "River Bank", "desc": "Vltava bank — 9m bank + 26m floodplain"},
	{"id": &"bridge", "label": "Bridge", "desc": "Road over river — deck +0.35"},
	{"id": &"hill", "label": "Hill / Ridge", "desc": "High terrain — view over valley"},
	{"id": &"quarry", "label": "Quarry", "desc": "Rocky exposed — limestone"},
	{"id": &"cave", "label": "Cave Entrance", "desc": "Cave potential — fallback to quarry"},
	{"id": &"random", "label": "Random Countryside", "desc": "Any valid countryside point"},
]

static func all_kind_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in SPAWN_KINDS:
		out.append(k["id"] as StringName)
	return out

static func label_for(id: StringName) -> String:
	for k in SPAWN_KINDS:
		if k["id"] == id:
			return k["label"]
	return str(id)

## Main entry — returns Vector3 spawn position (y = terrain + WorldConstants.SPAWN_FEET_CLEARANCE_M).
## world_plan / city_plan may be null — a temporary one is created from
## WorldSeed.get_world_seed() in that case (pure, deterministic).
static func get_spawn_position(kind: StringName, world_plan: WorldPlan = null, city_plan: CityPlan = null) -> Vector3:
	if world_plan == null:
		world_plan = WorldPlan.new(WorldSeed.get_world_seed())
	if city_plan == null:
		city_plan = CityPlan.new()
	match kind:
		&"city_center":
			return _city_center(city_plan, world_plan)
		&"city_gate":
			return _city_gate(world_plan, city_plan)
		&"village":
			return _settlement_kind(&"village", world_plan, city_plan)
		&"hamlet":
			return _settlement_kind(&"hamlet", world_plan, city_plan)
		&"farmstead":
			return _settlement_kind(&"farmstead", world_plan, city_plan)
		&"field":
			return _field_spawn(world_plan, city_plan)
		&"orchard":
			return _orchard_spawn(world_plan, city_plan)
		&"forest":
			return _forest_spawn(world_plan, city_plan)
		&"river_bank":
			return _river_bank_spawn(world_plan, city_plan)
		&"bridge":
			return _bridge_spawn(world_plan, city_plan)
		&"hill":
			return _hill_spawn(world_plan, city_plan)
		&"quarry":
			return _quarry_spawn(world_plan, city_plan)
		&"cave":
			return _cave_spawn(world_plan, city_plan)
		&"random":
			return _random_countryside(world_plan, city_plan)
		_:
			return _city_center(city_plan, world_plan)

# ---------- City ----------

static func _city_center(city_plan: CityPlan, world_plan: WorldPlan) -> Vector3:
	if city_plan != null and city_plan.has_method("find_spawn_point"):
		var p2: Vector2 = city_plan.find_spawn_point()
		# The plaza search can legitimately pick a city-edge square. Default
		# play must instead begin in a chunk that WorldPlan authorizes for the
		# flat historic building datum.
		if world_plan != null and not world_plan.should_materialize_city(WorldSeed.chunk_coord(p2.x, p2.y)):
			p2 = Vector2(city_plan.line_pos(0, 0), city_plan.line_pos(1, 0))
		var h: float = world_plan.surface_height_at(p2) if world_plan != null else 0.0
		return Vector3(p2.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p2.y)
	return Vector3(-96.5, WorldConstants.SPAWN_FEET_CLEARANCE_M, -44.0)

static func _city_gate(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan != null:
		var gates: Array = world_plan.city_gates()
		if not gates.is_empty():
			# pick most central gate to stay near playable area
			var best: Dictionary = gates[0]
			var best_d2 := (best["position"] as Vector2).length_squared()
			for g in gates:
				var d2 := (g["position"] as Vector2).length_squared()
				if d2 < best_d2:
					best_d2 = d2
					best = g
			var p: Vector2 = best["position"] as Vector2
			# step 6m outside along radial to avoid wall intersection
			var dir: Vector2 = p.normalized()
			if dir.length_squared() < 1e-6:
				dir = Vector2(1, 0)
			var outside: Vector2 = p + dir * 6.0
			var h: float = world_plan.surface_height_at(outside)
			if world_plan.water_body_at(outside) == &"":
				return Vector3(outside.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, outside.y)
			return Vector3(p.x, world_plan.surface_height_at(p) + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	return _city_center(city_plan, world_plan)

# ---------- Settlements ----------

static func _settlement_kind(kind: StringName, world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	var anchors: Array = world_plan.settlement_anchors()
	var filtered: Array = []
	for a in anchors:
		if a["kind"] == kind:
			filtered.append(a)
	if filtered.is_empty():
		# fallback: any hamlet/village
		for a in anchors:
			if a["kind"] == &"hamlet" or a["kind"] == &"village":
				filtered.append(a)
	if filtered.is_empty():
		return _random_countryside(world_plan, city_plan)
	# pick deterministic — seeded shuffle by id, first valid with no water
	filtered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for a in filtered:
		var p: Vector2 = a["center"] as Vector2
		if world_plan.water_body_at(p) != &"":
			continue
		if world_plan.is_floodplain(p):
			continue
		var h: float = world_plan.surface_height_at(p)
		# offset 4m from center to stand on street, not inside building aabb
		var gates: Array = a.get("gates", [])
		if not gates.is_empty():
			var gp: Vector2 = gates[0]["position"] as Vector2 if gates[0].has("position") else p
			return Vector3(gp.x, world_plan.surface_height_at(gp) + WorldConstants.SPAWN_FEET_CLEARANCE_M, gp.y)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	var p0: Vector2 = filtered[0]["center"] as Vector2
	return Vector3(p0.x, world_plan.surface_height_at(p0) + WorldConstants.SPAWN_FEET_CLEARANCE_M, p0.y)

# ---------- Field / Orchard ----------

static func _field_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	# search across seeded field parcels globally, pick one deterministically
	var all: Array = world_plan.field_parcels()
	if all.is_empty():
		return _settlement_kind(&"village", world_plan, city_plan)
	# sort by id for determinism
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for parcel in all:
		var p: Vector2 = parcel["center"] as Vector2 if parcel.has("center") else parcel["pos"] as Vector2 if parcel.has("pos") else Vector2.ZERO
		if p == Vector2.ZERO:
			continue
		if p.length() < WorldConstants.URBAN_OUTER_M + 40.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		if world_plan.is_floodplain(p):
			continue
		var h: float = world_plan.surface_height_at(p)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	var p: Vector2 = all[0]["center"] as Vector2
	return Vector3(p.x, world_plan.surface_height_at(p) + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)

static func _orchard_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	var all: Array = []
	if world_plan.has_method("orchard_parcels"):
		all = world_plan.orchard_parcels()
	if all.is_empty():
		# fallback to field or forest
		return _field_spawn(world_plan, city_plan)
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	for parcel in all:
		var p: Vector2 = parcel["center"] as Vector2 if parcel.has("center") else parcel["pos"] as Vector2 if parcel.has("pos") else Vector2.ZERO
		if p.length() < WorldConstants.URBAN_OUTER_M + 40.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		var h: float = world_plan.surface_height_at(p)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	var p: Vector2 = all[0]["center"] as Vector2
	return Vector3(p.x, world_plan.surface_height_at(p) + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)

# ---------- Forest ----------

static func _forest_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	# deterministic ring search 900-2400m
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_forest", [seed_used & 0xFFFF])
	for _i in 200:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(900.0, 2400.0, rng.randf())
		var p := Vector2(cos(ang), sin(ang)) * dist
		if p.length() < WorldConstants.URBAN_OUTER_M + 100.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		if world_plan.is_floodplain(p):
			continue
		var biome: StringName = world_plan.biome_at(p)
		if biome != &"deciduous_forest" and biome != &"mixed_upland_forest":
			continue
		var slope: float = world_plan.surface_slope_at(p)
		if slope > WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
			continue
		var h: float = world_plan.surface_height_at(p)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	return _random_countryside(world_plan, city_plan)

# ---------- River Bank ----------

static func _river_bank_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_riverbank", [seed_used & 0xFFFF, 1])
	# sample along river at various z, offset from center by width/2 + bank
	for _i in 300:
		var z: float = rng.randf_range(-2500.0, 2500.0)
		var cx: float = world_plan.river_center_x_at(z)
		var w: float = world_plan.river_width_at(z)
		var side: float = 1.0 if rng.randf() < 0.5 else -1.0
		var bank_offset: float = w * 0.5 + WorldConstants.BANK_W + rng.randf_range(4.0, 10.0)
		var p := Vector2(cx + side * bank_offset, z)
		if p.length() < WorldConstants.URBAN_INNER_M + 80.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		# want near water but not in it, and not floodplain is okay for bank
		var dist_w: float = world_plan.distance_to_water(p)
		if dist_w > 22.0 or dist_w < 1.0:
			continue
		var slope: float = world_plan.surface_slope_at(p)
		if slope > 18.0:
			continue
		var h: float = world_plan.surface_height_at(p)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	return _random_countryside(world_plan, city_plan)

# ---------- Bridge ----------

static func _bridge_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _river_bank_spawn(world_plan, city_plan)
	var cands: Array = []
	if world_plan.has_method("road_segments_in"):
		# search across seeded rects near river corridor
		var rect := Rect2(Vector2(200, -3000), Vector2(900, 6000))
		var segs: Array = world_plan.road_segments_in(rect)
		for s in segs:
			if s.get("is_bridge", false):
				var pos: Vector2 = s.get("center", Vector2.ZERO) as Vector2
				if pos == Vector2.ZERO:
					pos = s.get("pos", Vector2.ZERO) as Vector2
				if pos == Vector2.ZERO and s.has("a"):
					var a: Vector2 = s["a"] as Vector2
					var b: Vector2 = s["b"] as Vector2
					pos = (a + b) * 0.5
				if pos != Vector2.ZERO:
					cands.append(pos)
	if not cands.is_empty():
		cands.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			return a.length_squared() < b.length_squared())
		for p in cands:
			if p.length() < WorldConstants.URBAN_OUTER_M:
				continue
			var h: float = world_plan.surface_height_at(p as Vector2)
			# bridge deck is terrain + BRIDGE_DECK_LIFT, but player stands on deck
			return Vector3((p as Vector2).x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M + WorldConstants.BRIDGE_DECK_LIFT_M, (p as Vector2).y)
		var p0: Vector2 = cands[0] as Vector2
		return Vector3(p0.x, world_plan.surface_height_at(p0) + WorldConstants.SPAWN_FEET_CLEARANCE_M + WorldConstants.BRIDGE_DECK_LIFT_M, p0.y)
	return _river_bank_spawn(world_plan, city_plan)

# ---------- Hill / Quarry / Cave ----------

static func _hill_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_hill", [seed_used & 0xFFFF, 2])
	var best_p := Vector2.ZERO
	var best_h := -INF
	for _i in 300:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(800.0, 3000.0, rng.randf())
		var p := Vector2(cos(ang), sin(ang)) * dist
		if p.length() < WorldConstants.URBAN_OUTER_M + 80.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		if world_plan.is_floodplain(p):
			continue
		var h: float = world_plan.surface_height_at(p)
		var slope: float = world_plan.surface_slope_at(p)
		if slope > 20.0:
			continue
		if h > best_h:
			best_h = h
			best_p = p
	if best_p != Vector2.ZERO and best_h > 18.0:
		return Vector3(best_p.x, best_h + WorldConstants.SPAWN_FEET_CLEARANCE_M, best_p.y)
	if best_p != Vector2.ZERO:
		return Vector3(best_p.x, best_h + WorldConstants.SPAWN_FEET_CLEARANCE_M, best_p.y)
	return _random_countryside(world_plan, city_plan)

static func _quarry_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _hill_spawn(world_plan, city_plan)
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_quarry", [seed_used & 0xFFFF, 3])
	# Ask the WorldPlan for an actual excavated feature footprint, not merely a
	# rocky biome label. The chosen point is on the flat pit floor/bench.
	for _i in 400:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(1000.0, 3200.0, rng.randf())
		var probe := Vector2(cos(ang), sin(ang)) * dist
		var feature := world_plan.quarry_feature_at(probe)
		var p: Vector2 = feature.get("center", probe) as Vector2
		var resolved := world_plan.quarry_feature_at(p)
		if not bool(resolved.get("inside", false)):
			continue
		if world_plan.water_body_at(p) != &"" or world_plan.surface_slope_at(p) > 12.0:
			continue
		return Vector3(p.x, world_plan.surface_height_at(p) + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	return _hill_spawn(world_plan, city_plan)

static func _cave_spawn(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _quarry_spawn(world_plan, city_plan)
	# until Phase 5 caves land, use cave_potential as proxy near quarry/hill
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_cave", [seed_used & 0xFFFF, 4])
	var best_p := Vector2.ZERO
	var best_pot := -INF
	for _i in 400:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(900.0, 3000.0, rng.randf())
		var p := Vector2(cos(ang), sin(ang)) * dist
		if p.length() < WorldConstants.URBAN_OUTER_M + 60.0:
			continue
		if world_plan.water_body_at(p) != &"":
			continue
		var pot: float = world_plan.cave_potential_at(p) if world_plan.has_method("cave_potential_at") else 0.0
		if pot > best_pot:
			best_pot = pot
			best_p = p
		if pot > 0.62:
			var h: float = world_plan.surface_height_at(p)
			return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	if best_p != Vector2.ZERO and best_pot > 0.45:
		return Vector3(best_p.x, world_plan.surface_height_at(best_p) + WorldConstants.SPAWN_FEET_CLEARANCE_M, best_p.y)
	return _quarry_spawn(world_plan, city_plan)

static func _random_countryside(world_plan: WorldPlan, city_plan: CityPlan) -> Vector3:
	if world_plan == null:
		return _city_center(city_plan, world_plan)
	var seed_used: int = world_plan.seed_used
	var rng := WorldSeed.rng_for("spawn_random", [seed_used & 0xFFFF, 9])
	for _i in 500:
		var ang: float = rng.randf() * TAU
		var dist: float = lerpf(WorldConstants.URBAN_OUTER_M + 120.0, 3000.0, rng.randf())
		var p := Vector2(cos(ang), sin(ang)) * dist
		if world_plan.water_body_at(p) != &"":
			continue
		if world_plan.is_floodplain(p):
			continue
		var slope: float = world_plan.surface_slope_at(p)
		if slope > WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
			continue
		var h: float = world_plan.surface_height_at(p)
		return Vector3(p.x, h + WorldConstants.SPAWN_FEET_CLEARANCE_M, p.y)
	return _city_center(city_plan, world_plan)
