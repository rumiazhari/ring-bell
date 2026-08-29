class_name WorldPlan
extends RefCounted
## Thin facade owning one TerrainPlan and one HydrologyPlan and exposing stable queries.
## Does not touch scene tree, CityPlan caches, or ProjectSettings after construction.

var seed_used: int
var terrain: TerrainPlan
var hydrology: HydrologyPlan

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed
	terrain = TerrainPlan.new(seed)
	hydrology = HydrologyPlan.new(seed)

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
