class_name WorldPlan
extends RefCounted
## Thin facade owning one TerrainPlan and one HydrologyPlan and exposing stable queries.
## Does not touch scene tree, CityPlan caches, or ProjectSettings after construction.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan
var geology: GeologyPlan
var biome: BiomePlan
var settlement: SettlementPlan
var road_network: RoadNetworkPlan
var rural_building: RuralBuildingPlan
var cave: CavePlan
var vertical: VerticalNetworkPlan
var society: SocietyPlan

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed
	terrain = TerrainPlan.new(seed)
	hydrology = HydrologyPlan.new(seed)
	geology = GeologyPlan.new(seed)
	biome = BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	road_network = RoadNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement)
	rural_building = RuralBuildingPlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network)
	cave = CavePlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network, rural_building)
	vertical = VerticalNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network, rural_building)
	society = SocietyPlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network, rural_building)
	if biome.has_method("set_world_refs"):
		biome.set_world_refs(settlement, road_network, rural_building)
	if society.has_method("set_world_refs"):
		society.set_world_refs(self)

func terrain_height_at(p: Vector2) -> float:
	return terrain.height_at(p)

# --- Authoritative realized outdoor surface ---------------------------------
# `terrain_height_at()` remains the raw macro query used when plans choose
# sites. Every renderer/collider/grounded runtime object uses this surface API.
func urban_weight_at(p: Vector2) -> float:
	var d := p.length()
	if d <= WorldConstants.URBAN_INNER_M:
		return 0.0
	if d >= WorldConstants.URBAN_OUTER_M:
		return 1.0
	var t := (d - WorldConstants.URBAN_INNER_M) / (WorldConstants.URBAN_OUTER_M - WorldConstants.URBAN_INNER_M)
	return t * t * (3.0 - 2.0 * t)

func _river_surface_height_at(p: Vector2, base_height: float) -> float:
	var d: float = distance_to_water(p)
	if d > WorldConstants.BANK_W:
		return base_height
	var water_y: float = water_level_at(p)
	var bed_y: float = minf(base_height, water_y - WorldConstants.RIVER_BED_DEPTH_M)
	if d <= 0.0:
		return bed_y
	# A real earth bank joins the excavated bed to dry ground rather than
	# laying water on an unrelated macro hill.
	var dry_bank_y: float = maxf(base_height, water_y + WorldConstants.RIVER_BANK_FREEBOARD_M)
	var t := clampf(d / WorldConstants.BANK_W, 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	return lerpf(bed_y, dry_bank_y, t)

func quarry_feature_at(p: Vector2) -> Dictionary:
	var cell := Vector2i(floori(p.x / WorldConstants.QUARRY_FEATURE_CELL_M), floori(p.y / WorldConstants.QUARRY_FEATURE_CELL_M))
	var h := WorldSeed.combine([seed_used, WorldSeed.str_hash("quarry_feature"), cell.x, cell.y])
	var ux := float(h % 1000003) / 1000003.0
	var uz := float(WorldSeed.combine([h, 71]) % 1000003) / 1000003.0
	var origin := Vector2(cell) * WorldConstants.QUARRY_FEATURE_CELL_M
	var center := origin + Vector2(lerpf(72.0, 184.0, ux), lerpf(72.0, 184.0, uz))
	var eligible := biome_at(center) == &"rocky_quarry" \
		or quarry_suitability_at(center) >= WorldConstants.QUARRY_SUITABILITY_THRESHOLD + 0.08
	if center.length() < WorldConstants.URBAN_OUTER_M:
		eligible = false
	var radius := WorldConstants.QUARRY_FEATURE_RADIUS_M
	var distance := p.distance_to(center)
	var inside := eligible and distance <= radius
	var t := clampf(distance / radius, 0.0, 1.0)
	# Broad pit floor plus a smooth bench/ramp toward the existing terrain.
	var rim := t * t * (3.0 - 2.0 * t)
	var depth := WorldConstants.QUARRY_FEATURE_DEPTH_M * (1.0 - rim)
	return {
		"id": "quarry_%d_%d" % [cell.x, cell.y],
		"center": center,
		"radius": radius,
		"inside": inside,
		"depth": depth if inside else 0.0,
		"spoil_center": center + Vector2(radius * 0.72, -radius * 0.35),
	}

func surface_height_at(p: Vector2) -> float:
	var surface := lerpf(WorldConstants.URBAN_CITY_TERRACE_Y, terrain_height_at(p), urban_weight_at(p))
	# CityPlan is constrained to the terrace; all macro features are composed
	# into the physical terrain outside it, never layered over city geometry.
	if p.length() >= WorldConstants.URBAN_INNER_M:
		surface = _river_surface_height_at(p, surface)
		var quarry := quarry_feature_at(p)
		if bool(quarry.get("inside", false)):
			surface -= float(quarry.get("depth", 0.0))
	return surface

func surface_normal_at(p: Vector2) -> Vector3:
	var e := WorldConstants.SURFACE_SAMPLE_EPSILON_M
	var dx := (surface_height_at(p + Vector2(e, 0.0)) - surface_height_at(p - Vector2(e, 0.0))) / (2.0 * e)
	var dz := (surface_height_at(p + Vector2(0.0, e)) - surface_height_at(p - Vector2(0.0, e))) / (2.0 * e)
	var normal := Vector3(-dx, 1.0, -dz)
	if normal.length_squared() < 1e-8 or not normal.is_finite():
		return Vector3.UP
	return normal.normalized()

func surface_slope_at(p: Vector2) -> float:
	return rad_to_deg(acos(clampf(surface_normal_at(p).dot(Vector3.UP), -1.0, 1.0)))

func surface_class_at(p: Vector2) -> StringName:
	if surface_slope_at(p) >= WorldConstants.CLIFF_SLOPE_DEG:
		return &"cliff"
	var h := surface_height_at(p)
	if h >= WorldConstants.TERRAIN_UPLAND_HEIGHT_M:
		return &"upland"
	if h >= WorldConstants.TERRAIN_ROLLING_HEIGHT_M:
		return &"rolling_hill"
	return &"basin"

func surface_material_at(p: Vector2) -> StringName:
	match surface_class_at(p):
		&"cliff": return &"rock"
		&"upland": return &"upland_grass"
		&"rolling_hill": return &"meadow_soil"
		_: return &"alluvial_soil"

# --- World composition -------------------------------------------------------
func land_use_at(p: Vector2) -> StringName:
	if p.length() < WorldConstants.URBAN_INNER_M:
		return &"historic_urban"
	if water_body_at(p) != &"" or distance_to_water(p) <= WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W:
		return &"river_corridor"
	if bool(quarry_feature_at(p).get("inside", false)):
		return &"quarry"
	var site := settlement_at(p)
	if not site.is_empty():
		return StringName(str(site.get("kind", "rural")))
	var b := biome_at(p)
	if b == &"deciduous_forest" or b == &"mixed_upland_forest":
		return &"forest"
	if b == &"rocky_quarry":
		return &"quarry_upland"
	if b == &"arable_field" or b == &"pasture" or b == &"pasture_orchard" or b == &"orchard":
		return &"rural_agriculture"
	return &"rural"

func should_materialize_city(coord: Vector2i) -> bool:
	var rect := WorldSeed.chunk_rect(coord)
	for p in [rect.position, Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y), rect.end]:
		if p.length() >= WorldConstants.URBAN_INNER_M:
			return false
	return true

func chunk_composition(coord: Vector2i) -> Dictionary:
	var rect := WorldSeed.chunk_rect(coord)
	var center := rect.get_center()
	var city := should_materialize_city(coord)
	var feature := quarry_feature_at(center)
	return {
		"coord": coord,
		"primary_land_use": &"historic_urban" if city else land_use_at(center),
		"city_materialized": city,
		"urban_weight": urban_weight_at(center),
		"water_corridor": water_body_at(center) != &"" or distance_to_water(center) <= WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W,
		"quarry_feature": bool(feature.get("inside", false)),
		"quarry_id": feature.get("id", ""),
		"surface_contract": &"world_plan_surface_v1",
	}

func terrain_slope_at(p: Vector2) -> float:
	return terrain.slope_at(p)

func terrain_class_at(p: Vector2) -> StringName:
	return terrain.terrain_class_at(p)

func terrain_surface_material_at(p: Vector2) -> StringName:
	return terrain.surface_material_at(p)

func is_buildable(p: Vector2, footprint: Vector2, constraints: Dictionary = {}) -> bool:
	return terrain.is_buildable(p, footprint, constraints)

# --- Hydrology forwarding (pure, deterministic) ---

func river_center_x_at(z: float) -> float:
	return hydrology.river_center_x_at(z)

func river_width_at(z: float) -> float:
	return hydrology.river_width_at(z)

func water_level_at(p: Vector2) -> float:
	return hydrology.water_level_at(p)

func water_body_at(p: Vector2) -> StringName:
	return hydrology.water_body_at(p)

func water_body_id_at(p: Vector2) -> String:
	return hydrology.water_body_id_at(p)

func distance_to_water(p: Vector2) -> float:
	return hydrology.distance_to_water(p)

func bank_distance_at(p: Vector2) -> float:
	return hydrology.bank_distance_at(p)

func is_floodplain(p: Vector2) -> bool:
	return hydrology.is_floodplain(p)

func flow_direction_at(p: Vector2) -> Vector2:
	return hydrology.flow_direction_at(p)

func crossing_candidates(rect: Rect2) -> Array[Dictionary]:
	return hydrology.crossing_candidates(rect)

func tributary_info(k: int) -> Dictionary:
	return hydrology.tributary_info(k)

func all_tributaries() -> Array[Dictionary]:
	return hydrology.all_tributaries()

# --- Geology forwarding (pure, deterministic) ---

func strata_at(p: Vector2) -> StringName:
	return geology.strata_at(p)

func soil_at(p: Vector2) -> StringName:
	return geology.soil_at(p)

func quarry_suitability_at(p: Vector2) -> float:
	return geology.quarry_suitability_at(p)

func fertility_at(p: Vector2) -> float:
	return geology.fertility_at(p)

func cave_potential_at(p: Vector2) -> float:
	return geology.cave_potential_at(p)

func geology_profile(rect: Rect2, step: float) -> Dictionary:
	return geology.geology_profile(rect, step)

# --- Biome forwarding (pure, deterministic) ---

func biome_at(p: Vector2) -> StringName:
	return biome.biome_at(p)

func biome_id_at(p: Vector2) -> String:
	return biome.biome_id_at(p)

func is_forest(p: Vector2) -> bool:
	return biome.is_forest(p)

func is_field(p: Vector2) -> bool:
	return biome.is_field(p)

func is_floodplain_biome(p: Vector2) -> bool:
	return biome.is_floodplain(p)

func is_quarry(p: Vector2) -> bool:
	return biome.is_quarry(p)

func is_industrial(p: Vector2) -> bool:
	return biome.is_industrial(p)

func moisture_at(p: Vector2) -> float:
	return biome.moisture_at(p)

func temperature_at(p: Vector2) -> float:
	return biome.temperature_at(p)

func biome_density_at(p: Vector2) -> float:
	return biome.biome_density_at(p)

func surface_tint_at(p: Vector2) -> Color:
	return biome.surface_tint_at(p)

func field_parcels_in(rect: Rect2) -> Array[Dictionary]:
	return biome.field_parcels_in(rect)

func field_parcels() -> Array[Dictionary]:
	return biome.field_parcels()

func nearest_field_parcel(p: Vector2) -> Dictionary:
	return biome.nearest_field_parcel(p)

func crop_patch_for_parcel(parcel_id: String) -> Dictionary:
	return biome.crop_patch_for_parcel(parcel_id)

func orchard_parcels_in(rect: Rect2) -> Array[Dictionary]:
	return biome.orchard_parcels_in(rect)

func orchard_parcels() -> Array[Dictionary]:
	return biome.orchard_parcels()

func nearest_orchard_parcel(p: Vector2) -> Dictionary:
	return biome.nearest_orchard_parcel(p)

func fruit_patch_for_parcel(parcel_id: String) -> Dictionary:
	return biome.fruit_patch_for_parcel(parcel_id)

# --- Settlement forwarding (pure, deterministic) ---

func settlement_anchors() -> Array[Dictionary]:
	return settlement.settlement_anchors()

func settlements_in(rect: Rect2) -> Array[Dictionary]:
	return settlement.settlements_in(rect)

func nearest_settlement(p: Vector2) -> Dictionary:
	return settlement.nearest_settlement(p)

func settlement_at(p: Vector2) -> Dictionary:
	return settlement.settlement_at(p)

func is_settlement_center(p: Vector2, kind_filter: StringName = &"") -> bool:
	return settlement.is_settlement_center(p, kind_filter)

func city_gates() -> Array[Dictionary]:
	return settlement.city_gates()

func city_gate_positions() -> Array[Vector2]:
	return settlement.city_gate_positions()

# --- Road forwarding (pure, deterministic) ---

func road_graph() -> Dictionary:
	return road_network.road_graph()

func road_segments_in(rect: Rect2) -> Array[Dictionary]:
	return road_network.road_segments_in(rect)

func road_hierarchy_at(p: Vector2) -> StringName:
	return road_network.road_hierarchy_at(p)

func distance_to_road(p: Vector2) -> float:
	return road_network.distance_to_road(p)

func nearest_crossing(p: Vector2) -> Dictionary:
	return road_network.nearest_crossing(p)

func road_width_at(p: Vector2) -> float:
	return road_network.road_width_at(p)

# --- Rural building forwarding (pure, deterministic) ---

func rural_buildings() -> Array[Dictionary]:
	return rural_building.rural_buildings()

func rural_buildings_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_buildings_in(rect)

func nearest_rural_building(p: Vector2) -> Dictionary:
	return rural_building.nearest_rural_building(p)

func rural_building_at(p: Vector2) -> Dictionary:
	return rural_building.rural_building_at(p)

func settlement_buildings(settlement_id: String) -> Array[Dictionary]:
	return rural_building.settlement_buildings(settlement_id)

func rural_wells() -> Array[Dictionary]:
	return rural_building.rural_wells()

func rural_wells_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_wells_in(rect)

func nearest_rural_well(p: Vector2) -> Dictionary:
	return rural_building.nearest_rural_well(p)

func rural_forage_patches() -> Array[Dictionary]:
	return rural_building.rural_forage_patches()

func rural_forage_patches_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_forage_patches_in(rect)

func nearest_rural_forage(p: Vector2) -> Dictionary:
	return rural_building.nearest_rural_forage(p)

func rural_hearths_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_hearths_in(rect)

func nearest_rural_hearth(p: Vector2, kind: StringName = &"") -> Dictionary:
	return rural_building.nearest_rural_hearth(p, kind)

func rural_workbenches() -> Array[Dictionary]:
	return rural_building.rural_workbenches()

func rural_workbenches_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_workbenches_in(rect)

func nearest_rural_workbench(p: Vector2) -> Dictionary:
	return rural_building.nearest_rural_workbench(p)

func workbench_for_building(building_id: String) -> Dictionary:
	return rural_building.workbench_for_building(building_id)

func rural_granaries() -> Array[Dictionary]:
	return rural_building.rural_granaries()

func rural_granaries_in(rect: Rect2) -> Array[Dictionary]:
	return rural_building.rural_granaries_in(rect)

func nearest_rural_granary(p: Vector2) -> Dictionary:
	return rural_building.nearest_rural_granary(p)

func granary_for_building(building_id: String) -> Dictionary:
	return rural_building.granary_for_building(building_id)

# --- Cave entrance forwarding (pure, deterministic) ---

func cave_entrances() -> Array[Dictionary]:
	return cave.cave_entrances()

func cave_entrances_in(rect: Rect2) -> Array[Dictionary]:
	return cave.cave_entrances_in(rect)

func nearest_cave_entrance(p: Vector2) -> Dictionary:
	return cave.nearest_cave_entrance(p)

func cave_entrance_at(p: Vector2) -> Dictionary:
	var rect := Rect2(p - Vector2(2,2), Vector2(4,4))
	var cands: Array[Dictionary] = cave.cave_entrances_in(rect)
	for c in cands:
		var aabb: Rect2 = c.get("aabb", Rect2()) as Rect2
		if aabb.has_point(p):
			return c
	return nearest_cave_entrance(p) if not cands.is_empty() else {}

# --- Vertical bridge forwarding (pure, deterministic) ---

func vertical_bridges() -> Array[Dictionary]:
	return vertical.vertical_bridges()

func vertical_bridges_in(rect: Rect2) -> Array[Dictionary]:
	return vertical.vertical_bridges_in(rect)

func nearest_vertical_bridge(p: Vector2) -> Dictionary:
	return vertical.nearest_vertical_bridge(p)

func vertical_bridge_at(p: Vector2) -> Dictionary:
	var rect := Rect2(p - Vector2(2,2), Vector2(4,4))
	var cands: Array[Dictionary] = vertical.vertical_bridges_in(rect)
	for c in cands:
		var aabb: Rect2 = c.get("aabb", Rect2()) as Rect2
		if aabb.has_point(p):
			return c
	return nearest_vertical_bridge(p) if not cands.is_empty() else {}


# --- Society work schedule forwarding (pure, deterministic) ---

func society_workers() -> Array[Dictionary]:
	return society.workers()

func society_workers_in(rect: Rect2) -> Array[Dictionary]:
	return society.workers_in(rect)

func nearest_society_worker(p: Vector2) -> Dictionary:
	return society.nearest_worker(p)

func society_worker_for_settlement(settlement_id: String) -> Dictionary:
	return society.worker_for_settlement(settlement_id)

func society_work_site_for_worker(worker_id: String) -> Dictionary:
	return society.work_site_for_worker(worker_id)
