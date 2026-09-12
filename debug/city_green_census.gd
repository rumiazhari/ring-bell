extends Node
## Census of the city planting pass (`ChunkBuilder._plant_city_greens`).
##
## The full chunk path (terrain materialization + render + vertex walk) is far
## too slow to iterate on while other tracks are building the same tree, and
## what actually needs checking is the geometry the city trees add against the
## chunk budget. So this harness runs two things per core chunk:
##
##   1. the planting pass ALONE on a bare batcher - one prop_def per tree, so
##      the prop count is the tree count, and the box count is what the trees
##      cost;
##   2. a normal `fill_batcher` - the chunk's total box count with the trees in
##      it, for comparison against the documented budget figure.
##
## Launch: python tools/run_suite.py --citygreencensus 600 0
var _coords: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(0, 1), Vector2i(-1, -1), Vector2i(1, 1), Vector2i(-1, 1),
	Vector2i(1, -1),
]


func _ready() -> void:
	_run()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var plan := CityPlan.new()
	print("[CityGreenCensus] plan_ms=%d" % (Time.get_ticks_msec() - t0))
	var trees_total := 0
	var worst_trees := 0
	var worst_coord := Vector2i.ZERO
	var parts_total := 0
	var beds_total := 0
	var boxes_total := 0
	var worst_boxes := 0
	for coord: Vector2i in _coords:
		# 1. the planting pass alone.
		var only := MeshBatcher.new()
		ChunkBuilder._plant_city_greens(only, plan, WorldSeed.chunk_rect(coord), coord, null)
		var trees := only._prop_defs.size()
		var parts := only._box_count
		var beds := only._polygon_specs.size()
		# 2. the whole chunk's fill, trees included.
		var full := MeshBatcher.new()
		var t1 := Time.get_ticks_msec()
		ChunkBuilder.fill_batcher(full, plan, coord, null)
		var fill_ms := Time.get_ticks_msec() - t1
		trees_total += trees
		parts_total += parts
		beds_total += beds
		boxes_total += full._box_count
		if trees > worst_trees:
			worst_trees = trees
			worst_coord = coord
		worst_boxes = maxi(worst_boxes, full._box_count)
		print("[CityGreenCensus] chunk=%s trees=%d parts=%d pits=%d chunk_boxes=%d chunk_colliders=%d fill_ms=%d" % [
			coord, trees, parts, beds, full._box_count, full._colliders.size(), fill_ms])
	print("[CityGreenCensus] SUMMARY chunks=%d trees=%d mean=%.1f worst=%d (%s) mean_parts=%.1f pits=%d mean_chunk_boxes=%d max_chunk_boxes=%d" % [
		_coords.size(), trees_total, float(trees_total) / _coords.size(), worst_trees,
		worst_coord, float(parts_total) / _coords.size(), beds_total,
		boxes_total / _coords.size(), worst_boxes])
	# Budget the pass has to stay inside (debug/chunk_budget_test.gd). The
	# buildings already own most of it, so the trees have to be cheap: the
	# summary above is the number to hold against these ceilings.
	print("[CityGreenCensus] BUDGET per chunk boxes<=30000 colliders<=13500 verts<=700000 (dense core 2026-09-10: 27162 boxes / 12135 colliders)")
	get_tree().quit(0)
