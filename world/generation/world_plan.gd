class_name WorldPlan
extends RefCounted
## Thin facade owning one TerrainPlan and exposing stable terrain queries.
## Does not touch scene tree, CityPlan caches, or ProjectSettings after construction.

var seed_used: int
var terrain: TerrainPlan

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed
	terrain = TerrainPlan.new(seed)

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
