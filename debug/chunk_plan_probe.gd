extends Node
## One-off profiler: phase breakdown of city plan generation for a chunk.
##   godot --headless --path . -- --chunkplanprobe 0 0
func _ready() -> void:
	var coord := Vector2i(0, 0)
	var args := OS.get_cmdline_user_args()
	if args.size() >= 3:
		coord = Vector2i(int(args[1]), int(args[2]))
	ChunkBuilder.debug_profile = true
	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	var b := MeshBatcher.new()
	ChunkBuilder.fill_batcher(b, plan, coord, world_plan)
	print("[ChunkPlan] probe done for ", str(coord))
	get_tree().quit(0)
