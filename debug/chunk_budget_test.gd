extends Node
## Per-chunk materialization BUDGET harness.
##
##   godot --headless --path . -- --chunkbudget
##
## Why this exists: when building/interior dressing grows too heavy, the cost
## does not show up as a row of milliseconds anywhere - it shows up as
## "owner chunk never returned" inside city_runtime_test's 60 s persistence
## wait, which looks like a streaming bug and wastes hours. This test names the
## cost directly so interior work can be held to an explicit budget:
##
##   * boxes, colliders and mesh vertices per chunk
##   * wall-clock ms to build a chunk (plan -> batcher -> flushed mesh)
##   * interior OmniLights created per chunk (lighting is the priciest add)
##
## It measures the CANONICAL seed city chunks around the origin, prints a
## summary, and fails if any chunk exceeds the budget constants below.
##
## Exits 0 on success, 1 otherwise. Does not touch the save file.

## Budget for a chunk build ONCE THE PLAN IS WARM. The first chunk pays a
## one-time CityPlan generation (measured 45-85 s for the canonical seed) which
## is reported separately below rather than hidden inside this mean.
## The persistence gate gives 60 s for a chunk to regenerate while the rest of
## the ring also rebuilds, so the steady-state per-chunk cost must stay small.
const BUDGET_MS := 3500.0
## Regression guard on the ONE-TIME CityPlan generation (plan -> blocks ->
## buildings). Measured 45-85 s on the canonical seed; the guard exists so a
## future change that makes it worse fails here loudly instead of surfacing as
## "owner chunk never returned" inside the streaming persistence gate.
const BUDGET_WARM_MS := 120000.0
## Ceilings on geometry per chunk, set just above the MEASURED cost of the
## dense core chunk (2026-09-10: 27,162 boxes / 12,135 colliders / 264 lights)
## so the guard catches a real regression without failing on current content.
## Note how close a dense core chunk sits to these: interior dressing is a
## small slice of the total (the base buildings dominate), which is why the
## box count is the number to watch when the city fabric grows.
const BUDGET_BOXES := 30000
const BUDGET_COLLIDERS := 13500
const BUDGET_VERTS := 700000
## Real lights per chunk - the most expensive thing to add to a streamed chunk.
const BUDGET_LIGHTS := 300

var failures := 0

var _coords: Array[Vector2i] = [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1),
	Vector2i(-1, 1),
]


func _ready() -> void:
	_run()


func _run() -> void:
	MeshBatcher.debug_profile = true
	var world_plan := WorldPlan.new(WorldSeed.get_world_seed())
	var plan := CityPlan.new()
	var holder := Node3D.new()
	add_child(holder)

	# Warm-up: the FIRST city chunk build also pays the one-time CityPlan
	# generation. Time it separately so the per-chunk budget below measures
	# steady state, and so a regression in generation time is visible as its
	# own number instead of poisoning the mean.
	var warm := MeshBatcher.new()
	var t_warm := Time.get_ticks_usec()
	ChunkBuilder.fill_batcher(warm, plan, _coords[0], world_plan)
	var warm_ms := float(Time.get_ticks_usec() - t_warm) / 1000.0
	print("[ChunkBudget] plan+first-chunk warm-up: %.0f ms (one-time city generation)" % warm_ms)

	var samples: Array[Dictionary] = []
	for coord: Vector2i in _coords:
		var t0 := Time.get_ticks_usec()
		var batcher := MeshBatcher.new()
		ChunkBuilder.fill_batcher(batcher, plan, coord, world_plan)
		var fill_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		var t1 := Time.get_ticks_usec()
		var stats := ChunkBuilder.build(holder, plan, coord, batcher, {}, true, true, world_plan)
		var build_ms := float(Time.get_ticks_usec() - t1) / 1000.0
		var chunk: Node3D = holder.get_child(holder.get_child_count() - 1)
		var verts := _count_verts(chunk)
		var lights := _count_lights(chunk)
		samples.append({
			"coord": coord, "ms": fill_ms + build_ms, "boxes": int(stats.get("boxes", 0)),
			"colliders": int(stats.get("colliders", 0)), "verts": verts, "lights": lights,
			"buildings": int(stats.get("buildings", 0)),
			"interior_doors": int(stats.get("city_interior_doors", 0)),
		})
		print("[ChunkBudget] %s total_ms=%.0f plan_ms=%.0f flush_ms=%.0f boxes=%d colliders=%d verts=%d lights=%d bldgs=%d intdoors=%d" % [
			str(coord), samples[-1]["ms"], fill_ms, float(stats.get("mat_ms", 0.0)),
			samples[-1]["boxes"], samples[-1]["colliders"],
			samples[-1]["verts"], lights, samples[-1]["buildings"], samples[-1]["interior_doors"]])

	if samples.is_empty():
		_check("sampled at least one chunk", false, "no samples")
		return _finish()

	var total_ms := 0.0
	var max_ms := 0.0
	var max_boxes := 0
	var max_colliders := 0
	var max_verts := 0
	var max_lights := 0
	var worst := ""
	for s: Dictionary in samples:
		total_ms += float(s["ms"])
		if float(s["ms"]) > max_ms:
			max_ms = float(s["ms"])
			worst = str(s["coord"])
		max_boxes = maxi(max_boxes, int(s["boxes"]))
		max_colliders = maxi(max_colliders, int(s["colliders"]))
		max_verts = maxi(max_verts, int(s["verts"]))
		max_lights = maxi(max_lights, int(s["lights"]))
	var mean_ms := total_ms / float(samples.size())
	print("[ChunkBudget] SUMMARY chunks=%d mean_ms=%.0f max_ms=%.0f (worst %s) max_boxes=%d max_colliders=%d max_verts=%d max_lights=%d" % [
		samples.size(), mean_ms, max_ms, worst, max_boxes, max_colliders, max_verts, max_lights])
	print("[ChunkBudget] BUDGET ms<=%.0f boxes<=%d colliders<=%d verts<=%d lights<=%d" % [
		BUDGET_MS, BUDGET_BOXES, BUDGET_COLLIDERS, BUDGET_VERTS, BUDGET_LIGHTS])

	# Regression guard on the one-time generation: it is large today, so this
	# threshold documents the current cost rather than pretending it is fine.
	_check("one-time city generation <= %.0f ms (regression guard)" % BUDGET_WARM_MS,
			warm_ms <= BUDGET_WARM_MS, "warm-up=%.0f ms" % warm_ms)
	_check("mean chunk build <= %.0f ms" % BUDGET_MS, mean_ms <= BUDGET_MS,
			"mean=%.0f ms" % mean_ms)
	_check("worst chunk build <= %.0f ms" % (BUDGET_MS * 2.0), max_ms <= BUDGET_MS * 2.0,
			"%s=%.0f ms" % [worst, max_ms])
	_check("boxes per chunk <= %d" % BUDGET_BOXES, max_boxes <= BUDGET_BOXES, "max=%d" % max_boxes)
	_check("colliders per chunk <= %d" % BUDGET_COLLIDERS, max_colliders <= BUDGET_COLLIDERS,
			"max=%d" % max_colliders)
	_check("mesh verts per chunk <= %d" % BUDGET_VERTS, max_verts <= BUDGET_VERTS, "max=%d" % max_verts)
	_check("real lights per chunk <= %d" % BUDGET_LIGHTS, max_lights <= BUDGET_LIGHTS,
			"max=%d" % max_lights)
	_finish()


func _count_verts(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for si in mesh.get_surface_count():
			total += mesh.surface_get_array_len(si)
	for child in node.get_children():
		total += _count_verts(child)
	return total


func _count_lights(node: Node) -> int:
	var total := 1 if node is OmniLight3D else 0
	for child in node.get_children():
		total += _count_lights(child)
	return total


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[ChunkBudget] PASS  %s" % label)
	else:
		failures += 1
		print("[ChunkBudget] FAIL  %s   (%s)" % [label, detail])


func _finish() -> void:
	print("[ChunkBudget] finished with %d failure(s)" % failures)
	get_tree().quit(1 if failures > 0 else 0)
