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

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed
	terrain = TerrainPlan.new(seed)
	hydrology = HydrologyPlan.new(seed)
	geology = GeologyPlan.new(seed)
	biome = BiomePlan.new(seed, terrain, hydrology, geology)
	settlement = SettlementPlan.new(seed, terrain, hydrology, geology, biome)
	road_network = RoadNetworkPlan.new(seed, terrain, hydrology, geology, biome, settlement)
	rural_building = RuralBuildingPlan.new(seed, terrain, hydrology, geology, biome, settlement, road_network)

func terrain_height_at(p: Vector2) -> float:
	return terrain.height_at(p)

func terrain_slope_at(p: Vector2) -> float:
	return terrain.slope_at(p)

func terrain_class_at(p: Vector2) -> StringName:
	return terrain.terrain_class_at(p)

func surface_material_at(p: Vector2) -> StringName:
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

func moisture_at(p: Vector2) -> float:
	return biome.moisture_at(p)

func temperature_at(p: Vector2) -> float:
	return biome.temperature_at(p)

func biome_density_at(p: Vector2) -> float:
	return biome.biome_density_at(p)

func surface_tint_at(p: Vector2) -> Color:
	return biome.surface_tint_at(p)

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
