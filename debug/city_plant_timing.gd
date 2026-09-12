extends Node
## Where does a city chunk's planting time actually go? Flushes each phase to a
## file, so a timeout kill cannot swallow the measurements.
##
##   godot --headless --path . -- --cityplanttime

const OUT := "res://captures/city-green/timetest.txt"

var _f: FileAccess


func _log(msg: String) -> void:
	print("[CityPlantTime] %s" % msg)
	if _f != null:
		_f.store_line("%d %s" % [Time.get_ticks_msec(), msg])
		_f.flush()


func _ready() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f != null:
		_f = f
	_log("start")
	var t := Time.get_ticks_msec()
	var wp := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	_log("plan %d ms" % (Time.get_ticks_msec() - t))

	var coord := Vector2i(0, 0)
	var rect := WorldSeed.chunk_rect(coord)
	var step: float = WorldConstants.CITY_TREE_LATTICE_M

	t = Time.get_ticks_msec()
	var specs := plan.buildings_in_rect(rect.grow(8.0))
	_log("buildings_in_rect %d ms -> %d specs" % [Time.get_ticks_msec() - t, specs.size()])

	t = Time.get_ticks_msec()
	var tiny := plan.buildings_in_rect(Rect2(0.0, 0.0, 4.0, 4.0))
	_log("buildings_in_rect(4 m) %d ms -> %d specs" % [Time.get_ticks_msec() - t, tiny.size()])

	t = Time.get_ticks_msec()
	var edges := plan.city_road_segments_in(rect.grow(12.0))
	_log("city_road_segments_in %d ms -> %d edges" % [Time.get_ticks_msec() - t, edges.size()])

	t = Time.get_ticks_msec()
	var cells := plan.cells_in_rect(rect.grow(step))
	_log("cells_in_rect %d ms -> %d cells" % [Time.get_ticks_msec() - t, cells.size()])

	t = Time.get_ticks_msec()
	var b := MeshBatcher.new()
	ChunkBuilder._plant_city_greens(b, plan, rect, coord, wp)
	_log("plant_city_greens %d ms boxes=%d" % [Time.get_ticks_msec() - t, int(b._box_count)])

	t = Time.get_ticks_msec()
	ChunkBuilder._plant_garden_trees(b, plan, rect, wp)
	_log("plant_garden_trees %d ms boxes=%d" % [Time.get_ticks_msec() - t, int(b._box_count)])

	t = Time.get_ticks_msec()
	ChunkBuilder._roads(b, plan, rect, wp)
	_log("roads %d ms boxes=%d" % [Time.get_ticks_msec() - t, int(b._box_count)])

	t = Time.get_ticks_msec()
	var layers := b._build_layers()
	_log("build_layers %d ms layers=%d" % [Time.get_ticks_msec() - t, layers.size()])
	get_tree().quit(0)
