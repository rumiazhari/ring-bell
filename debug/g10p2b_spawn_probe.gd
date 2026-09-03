extends Node
func _ready() -> void:
	var world:=WorldPlan.new(WorldSeed.get_world_seed())
	var city:=CityPlan.new(WorldSeed.get_world_seed())
	var city_default:=CityPlan.new()
	print("[G10P2BDefault] seed_global=",WorldSeed.get_world_seed(),"explicit=",city.seed_used,"default=",city_default.seed_used,"default_find=",city_default.find_spawn_point())
	var spawn:=SpawnPoints.get_spawn_position(&"city_center",world,city)
	var p:=Vector2(spawn.x,spawn.z)
	var coord:=WorldSeed.chunk_coord(spawn.x,spawn.z)
	print("[G10P2BSpawn] city_find=",city.find_spawn_point(),"spawn=",spawn,"p=",p,"coord=",coord,"materialized=",world.should_materialize_city(coord),"comp=",world.chunk_composition(coord),"buildings=",city.buildings_in_rect(Rect2(p-Vector2(90,90),Vector2(180,180))).size())
	get_tree().quit(0)
