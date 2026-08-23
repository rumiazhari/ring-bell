class_name ChunkManager
extends Node3D
## Streams the procedural city in 64 m chunks around the player.
##
## States (chebyshev distance from the player's chunk):
##   ACTIVE (<= ACTIVE_RADIUS)     gameplay-ready geometry + physics
##   WARM   (<= WARM_RADIUS)       resident but outside direct play; future
##                                 throttling hooks attach here
##   COLD    (beyond)              NOT instantiated at all - nothing but a
##                                 persistence record survives
##
## Loading is time-budgeted per frame so crossing a chunk border never stalls
## the game. Both rings are fully materialized today; ACTIVE/WARM only differ
## in bookkeeping until simulation throttling lands (Phase G).
##
## PERSISTENCE: deterministic rebuild + deltas. The manager keeps one record
## per DISCOVERED chunk ({discovered: true, deltas: {}}); saves carry records,
## never geometry. Deltas are applied by future passes (Phase F+).

signal chunk_loaded(coord: Vector2i)
signal chunk_unloaded(coord: Vector2i)

const ACTIVE_RADIUS := 1
const WARM_RADIUS := 2
const FRAME_BUDGET_MS := 7.0

var plan: CityPlan

var _player: Node3D
var _chunks := {}                      # Vector2i -> {state:StringName, boxes:int}
var _pending: Array[Vector2i] = []
var _last_player_chunk := Vector2i(99, 99)   # sentinel forces first update
var _records := {}                     # Vector2i -> persistence record
var _events: Array[String] = []        # recent load/unload log (debug)
var _total_loads := 0
var _total_unloads := 0
var _total_gen_ms := 0.0


func setup(city_plan: CityPlan) -> void:
	plan = city_plan
	add_to_group(&"chunk_manager")


func set_player(node: Node3D) -> void:
	_player = node


# --- Streaming loop ----------------------------------------------------------

func _process(_delta: float) -> void:
	var pc := _player_chunk()
	_last_player_chunk = pc
	var desired := _desired_set(pc)
	_enqueue_missing(desired, pc)
	_unload_far(desired)
	_process_queue(pc)


func _player_chunk() -> Vector2i:
	if _player != null and is_instance_valid(_player):
		return WorldSeed.chunk_coord(_player.global_position.x,
				_player.global_position.z)
	return _last_player_chunk


## All coords within the warm ring around `pc` (superset of active).
func _desired_set(pc: Vector2i) -> Dictionary:
	var out := {}
	for dx in range(-WARM_RADIUS, WARM_RADIUS + 1):
		for dy in range(-WARM_RADIUS, WARM_RADIUS + 1):
			out[pc + Vector2i(dx, dy)] = true
	return out


func _enqueue_missing(desired: Dictionary, pc: Vector2i) -> void:
	for c: Vector2i in desired:
		if not _chunks.has(c) and not _pending.has(c):
			_pending.append(c)
	if _pending.is_empty():
		return
	_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - pc).length_squared()
		var db := (b - pc).length_squared()
		return da < db if da != db else a.y * 131 + a.x < b.y * 131 + b.x)


func _unload_far(desired: Dictionary) -> void:
	var doomed: Array[Vector2i] = []
	for c: Vector2i in _chunks:
		if not desired.has(c):
			doomed.append(c)
	for c in doomed:
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node != null:
			node.queue_free()
		_chunks.erase(c)
		_total_unloads += 1
		_log("unload %s" % c)
		chunk_unloaded.emit(c)


func _process_queue(pc: Vector2i) -> void:
	var deadline := Time.get_ticks_usec() + int(FRAME_BUDGET_MS * 1000.0)
	while not _pending.is_empty() and Time.get_ticks_usec() < deadline:
		var c: Vector2i = _pending.pop_front()
		if _chunks.has(c):
			continue
		var stats := ChunkBuilder.build(self, plan, c)
		var dist := maxi(absi(c.x - pc.x), absi(c.y - pc.y))
		_chunks[c] = {
			"state": &"active" if dist <= ACTIVE_RADIUS else &"warm",
			"boxes": int(stats["boxes"]),
			"gen_ms": float(stats["gen_ms"]),
		}
		_total_loads += 1
		_total_gen_ms += float(stats["gen_ms"])
		note_discovered(c)
		_log("load %s (%.1f ms)" % [c, float(stats["gen_ms"])])
		chunk_loaded.emit(c)


func note_discovered(coord: Vector2i) -> void:
	if not _records.has(coord):
		_records[coord] = {"discovered": true, "deltas": {}}


func _log(text: String) -> void:
	_events.append("[%s] %s" % [GameClock.time_string(), text])
	while _events.size() > 8:
		_events.pop_front()


# --- Debug / stats (F3 overlay reads these) ----------------------------------

func active_count() -> int:
	return _count_state(&"active")


func warm_count() -> int:
	return _count_state(&"warm")


func _count_state(state: StringName) -> int:
	var n := 0
	for c in _chunks.values():
		if c["state"] == state:
			n += 1
	return n


func pending_count() -> int:
	return _pending.size()


func last_player_chunk() -> Vector2i:
	return _last_player_chunk


func total_boxes_estimate() -> int:
	var n := 0
	for v in _chunks.values():
		n += int(v["boxes"])
	return n


func avg_gen_ms() -> float:
	return _total_gen_ms / maxf(1.0, float(_total_loads))


func recent_events() -> Array[String]:
	return _events.duplicate()


func debug_lines() -> Array[String]:
	var lines: Array[String] = []
	lines.append("chunk %s | active %d | warm %d | queued %d | loads %d/unloads %d"
			% [str(last_player_chunk()), active_count(), warm_count(),
			pending_count(), _total_loads, _total_unloads])
	lines.append("boxes ~%d | avg gen %.1f ms | resident chunks %d | records %d"
			% [total_boxes_estimate(), avg_gen_ms(), _chunks.size(),
			_records.size()])
	return lines


# --- Persistence contract ----------------------------------------------------

## Records survive saves; geometry is rebuilt deterministically on return.
func save_state() -> Dictionary:
	var recs := {}
	for c: Vector2i in _records:
		recs["%d,%d" % [c.x, c.y]] = _records[c]
	return {"records": recs}


func load_state(data: Dictionary) -> void:
	_records.clear()
	for key: String in data.get("records", {}):
		var parts := key.split(",")
		_records[Vector2i(int(parts[0]), int(parts[1]))] = \
				data["records"][key]
