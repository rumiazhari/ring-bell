extends Node
func _ready() -> void:
	var world:=WorldPlan.new(WorldSeed.get_world_seed())
	var city:=CityPlan.new(WorldSeed.get_world_seed())
	var spawn:=SpawnPoints.get_spawn_position(&"city_center",world,city)
	var coord:=WorldSeed.chunk_coord(spawn.x,spawn.z)
	var manager:=ChunkManager.new()
	add_child(manager)
	manager.setup_world(city,world)
	manager.set_process(false)
	var batcher:=MeshBatcher.new()
	var holder:Dictionary={"terrain":{},"water":{},"biome":{},"road":{},"rural":{},"fringe":{},"cave":{},"vertical":{},"composition":{}}
	manager._thread_build(batcher,coord,holder,world.seed_used)
	var comp:Dictionary=holder.get("composition",{}) as Dictionary
	manager._materialize(coord,batcher,holder.get("terrain",{}),float(holder.get("gen_ms",0.0)),coord,float(holder.get("terrain_gen_ms",0.0)),holder.get("water",{}),float(holder.get("water_gen_ms",0.0)),holder.get("biome",{}),float(holder.get("biome_gen_ms",0.0)),holder.get("road",{}),float(holder.get("road_gen_ms",0.0)),holder.get("rural",{}),float(holder.get("rural_gen_ms",0.0)),holder.get("fringe",{}),float(holder.get("fringe_gen_ms",0.0)),comp,holder.get("cave",{}),float(holder.get("cave_gen_ms",0.0)),holder.get("vertical",{}),float(holder.get("vertical_gen_ms",0.0)))
	await get_tree().process_frame
	var rec:Dictionary=manager._chunks.get(coord,{}) as Dictionary
	print("[G10P2BStream] spawn=",spawn,"coord=",coord,"comp=",comp,"rec_city=",rec.get("city_materialized",false),"rec_buildings=",rec.get("buildings",0),"batch_specs=",batcher.specs().size())
	get_tree().quit(0)
