class_name ChunkManager
extends Node3D
## Streams the procedural city in 64 m chunks around the player.
##
## States (chebyshev distance from the player's chunk):
##   ACTIVE (<= ACTIVE_RADIUS)     gameplay-ready geometry + physics
##   WARM   (<= WARM_RADIUS)       resident but outside direct play; zombie
##                                 population despawns to records here
##   COLD    (beyond)              NOT instantiated - only a persistence record
##
## PIPELINE SPLIT: expensive PLAN/BATCH generation runs on WorkerThreadPool
## (pure data; CityPlan caches guarded by plan_mutex); SCENE MATERIALIZATION
## (nodes, meshes, collision shapes, doors) stays on the main thread inside
## the frame budget. A single ~40 ms chunk build therefore never stalls a
## frame. Set `synchronous = true` to build inline (headless tests).
##
## STATE TRANSITIONS are recalculated every streaming update so zombie
## activation/deactivation follows the player. Unload uses a hysteresis ring
## (UNLOAD_RADIUS = WARM_RADIUS + 1) to prevent border thrashing.

signal chunk_loaded(coord: Vector2i)
signal chunk_unloaded(coord: Vector2i)
signal chunk_state_changed(coord: Vector2i, new_state: StringName)

const ACTIVE_RADIUS := 1
const WARM_RADIUS := 2
const UNLOAD_RADIUS := WARM_RADIUS + 1   # hysteresis ring
const FRAME_BUDGET_MS := 12.0         # doors/props materialize alongside mesh
const STREAM_UPDATE_INTERVAL := 0.2      # seconds between full ring recalcs
const MAX_INFLIGHT_BUILDS := 2           # concurrent worker-thread batch jobs

var plan: CityPlan
var world_plan: WorldPlan
var synchronous := false                # tests: build inline, no workers
var _terrain_vertices_total := 0
var _terrain_triangles_total := 0
var _terrain_colliders_total := 0
var _terrain_mat_ms_total := 0.0

var _player: Node3D
var _chunks := {}                      # Vector2i -> record dict (see _materialize)
var _pending: Array[Vector2i] = []
var _inflight := {}                    # Vector2i -> {batcher, task_id}
var _last_player_chunk := Vector2i(99, 99)   # sentinel forces first update
var _records := {}                     # Vector2i -> persistence record
var _events: Array[String] = []        # recent load/unload log (debug)
var _rebuild_queue: Array[Vector2i] = []   # chunks needing mesh re-bakes
var _total_loads := 0
var _total_unloads := 0
var _total_gen_ms := 0.0               # plan/batch data time (threaded)
var _total_mat_ms := 0.0               # materialization time (main thread)
var _stream_timer := STREAM_UPDATE_INTERVAL
var _player_chunk_changed := true


func setup(city_plan: CityPlan) -> void:
	plan = city_plan
	if world_plan == null:
		world_plan = WorldPlan.new(city_plan.seed_used if city_plan != null else WorldSeed.get_world_seed())
	add_to_group(&"chunk_manager")

func setup_world(city_plan: CityPlan, wplan: WorldPlan) -> void:
	plan = city_plan
	world_plan = wplan
	add_to_group(&"chunk_manager")


func set_player(node: Node3D) -> void:
	_player = node


## Drop everything resident/pending/inflight. Used when the world seed
## changes on load: the old geometry belongs to a different city.
func reset_stream() -> void:
	for c: Vector2i in _inflight:
		var job: Dictionary = _inflight[c]
		var task_id: int = job["task_id"]
		if task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(task_id)
	_inflight.clear()
	_terrain_vertices_total = 0
	_terrain_triangles_total = 0
	_terrain_colliders_total = 0
	_terrain_mat_ms_total = 0.0
	for c: Vector2i in _chunks:
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node != null:
			node.queue_free()
	_chunks.clear()
	_pending.clear()
	_records.clear()
	_last_player_chunk = Vector2i(99, 99)
	_player_chunk_changed = true


static func chebyshev_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# --- Streaming loop ----------------------------------------------------------

func _process(delta: float) -> void:
	_flush_rebuilds()

	_stream_timer += delta
	var pc := _player_chunk()
	if pc != _last_player_chunk:
		_last_player_chunk = pc
		_player_chunk_changed = true

	if _stream_timer < STREAM_UPDATE_INTERVAL and not _player_chunk_changed:
		return
	_stream_timer = 0.0
	_player_chunk_changed = false

	var desired := _desired_set(pc)
	_enqueue_missing(desired, pc)
	_launch_batch_jobs()
	_collect_finished_jobs(pc)
	_unload_far(desired, pc)
	_update_chunk_states(pc)


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
		if not _chunks.has(c) and not _pending.has(c) \
				and not _inflight.has(c):
			_pending.append(c)
	if _pending.is_empty():
		return
	_pending.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - pc).length_squared()
		var db := (b - pc).length_squared()
		return da < db if da != db else a.y * 131 + a.x < b.y * 131 + b.x)


func _launch_batch_jobs() -> void:
	while not _pending.is_empty() and _inflight.size() < MAX_INFLIGHT_BUILDS:
		var c: Vector2i = _pending.pop_front()
		if _chunks.has(c) or _inflight.has(c):
			continue
		var batcher := MeshBatcher.new()
		var terrain_manifest: Dictionary = {}
		if world_plan != null:
			# Terrain manifest is pure and worker-safe (private WorldPlan)
			var local_world := WorldPlan.new(world_plan.seed_used)
			terrain_manifest = TerrainChunkBuilder.build_manifest(local_world, c)
		if synchronous:
			var t0 := Time.get_ticks_usec()
			_fill_job(batcher, c)
			_inflight[c] = {"batcher": batcher, "terrain": terrain_manifest, "task_id": -1,
					"gen_ms": float(Time.get_ticks_usec() - t0) / 1000.0}
		else:
			var t0 := Time.get_ticks_usec()
			var task_id := WorkerThreadPool.add_task(
					_fill_job.bind(batcher, c), false,
					"chunk_%d_%d" % [c.x, c.y])
			_inflight[c] = {"batcher": batcher, "terrain": terrain_manifest, "task_id": task_id,
					"gen_ms": float(Time.get_ticks_usec() - t0) / 1000.0}


## Pure plan->batcher data generation for ONE chunk.
##
## THREAD SAFETY: this job builds its own PRIVATE CityPlan copy instead of
## sharing `plan`. Every CityPlan query is a pure function of the world seed,
## so results are identical - but the lazy caches are plain Dictionaries, and
## sharing them between a worker and main-thread queries (zombie road
## sampling, spawn lookups) corrupted them under load. Private copies cost a
## few ms of recompute and remove the entire locking problem.
func _fill_job(batcher: MeshBatcher, coord: Vector2i) -> void:
	var local_plan := CityPlan.new()
	ChunkBuilder.fill_batcher(batcher, local_plan, coord)


func _collect_finished_jobs(pc: Vector2i) -> void:
	if _inflight.is_empty():
		return
	var done: Array[Vector2i] = []
	for c: Vector2i in _inflight:
		var task_id: int = _inflight[c]["task_id"]
		if task_id < 0 or WorkerThreadPool.is_task_completed(task_id):
			done.append(c)
	for c in done:
		var job: Dictionary = _inflight[c]
		if job["task_id"] >= 0:
			WorkerThreadPool.wait_for_task_completion(job["task_id"])
		_inflight.erase(c)
		# Stale job? Player moved on while the data was cooking.
		if chebyshev_distance(c, pc) > UNLOAD_RADIUS or _chunks.has(c):
			continue
		_materialize(c, job["batcher"], job["terrain"], job["gen_ms"], pc)


func _materialize(coord: Vector2i, batcher: MeshBatcher, terrain_manifest: Dictionary, gen_ms: float,
		pc: Vector2i) -> void:
	# PERSISTENCE-FIRST PIPELINE (P0-2): this chunk's destruction delta is
	# re-applied to the FRESH worker batcher BEFORE any scene work, so the
	# first and ONLY materialization below already omits destroyed cells
	# (MeshBatcher.flush_into skips them for BOTH mesh and collision) and
	# no second destructive rebake is needed during a chunk load.
	var rec: Dictionary = _records.get(coord, {})
	var delta: Dictionary = rec.get("deltas", {})
	batcher.load_damage_state(delta.get("damage", {}))
	var destroyed_keys: Array = delta.get("destroyed", [])
	if not destroyed_keys.is_empty():
		for spec in batcher.specs():
			var key := batcher.cell_key_for_id(int(spec["id"]))
			if key != "" and destroyed_keys.has(key):
				batcher.destroy_box(int(spec["id"]))
	# Doors recorded destroyed must never respawn when the chunk returns.
	var dstates: Dictionary = delta.get("doors", {})
	var dead_doors := {}
	for did: String in dstates.keys():
		if bool(dstates[did].get("destroyed", false)):
			dead_doors[did] = true
	# Exactly ONE materialization: flush meshes/static body + doors + props.
	var stats := ChunkBuilder.build(self, plan, coord, batcher, dead_doors)
	# Materialize terrain under same chunk if manifest present
	var tstats := {}
	if not terrain_manifest.is_empty():
		var chunk_node := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node != null:
			tstats = TerrainChunkBuilder.materialize(chunk_node, terrain_manifest)
	# Restore surviving doors' saved logical state (open pose / lock).
	if not dstates.is_empty():
		var chunk := get_node_or_null(
				NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk != null:
			for child in chunk.get_children():
				if child is Door and dstates.has(String(child.name)):
					(child as Door).load_state(dstates[String(child.name)])
	var dist := chebyshev_distance(coord, pc)
	var state: StringName = &"active" if dist <= ACTIVE_RADIUS else &"warm"
	var terrain_verts := int(tstats.get("terrain_vertices", 0))
	var terrain_tris := int(tstats.get("terrain_triangles", 0))
	var terrain_cols := int(tstats.get("terrain_colliders", 0))
	_chunks[coord] = {
		"state": state,
		"boxes": int(stats["boxes"]),
		"colliders": int(stats["colliders"]),
		"doors": int(stats["doors"]),
		"buildings": int(stats["buildings"]),
		"props": int(stats.get("props", 0)),
		"terrain_vertices": terrain_verts,
		"terrain_triangles": terrain_tris,
		"terrain_colliders": terrain_cols,
		"terrain_manifest": terrain_manifest,
		"layers": batcher.layer_nodes,
		"batcher": batcher,
		"static": get_node_or_null(
				NodePath("Chunk_%d_%d/Static" % [coord.x, coord.y])),
		"rebuild_queued": false,
		"gen_ms": gen_ms,
		"mat_ms": float(stats["mat_ms"]),
		"terrain_mat_ms": float(tstats.get("terrain_mat_ms", 0.0)),
	}
	_terrain_vertices_total += terrain_verts
	_terrain_triangles_total += terrain_tris
	_terrain_colliders_total += terrain_cols
	_terrain_mat_ms_total += float(tstats.get("terrain_mat_ms", 0.0))
	_total_loads += 1
	_total_gen_ms += gen_ms
	_total_mat_ms += float(stats["mat_ms"])
	# Unload adjustment: subtract on unload
	note_discovered(coord)
	_log("load %s (%.1f+%.1f ms, %s)"
			% [coord, gen_ms, float(stats["mat_ms"]), state])
	chunk_loaded.emit(coord)
	chunk_state_changed.emit(coord, state)


func _unload_far(desired: Dictionary, pc: Vector2i) -> void:
	var doomed: Array[Vector2i] = []
	for c: Vector2i in _chunks:
		if not desired.has(c) \
				and chebyshev_distance(c, pc) > UNLOAD_RADIUS:
			doomed.append(c)
	for c in doomed:
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node != null:
			node.queue_free()
		var rec: Dictionary = _chunks[c]
		_terrain_vertices_total -= int(rec.get("terrain_vertices", 0))
		_terrain_triangles_total -= int(rec.get("terrain_triangles", 0))
		_terrain_colliders_total -= int(rec.get("terrain_colliders", 0))
		_terrain_mat_ms_total -= float(rec.get("terrain_mat_ms", 0.0))
		_chunks.erase(c)
		_total_unloads += 1
		_log("unload %s" % c)
		chunk_unloaded.emit(c)


## Recalculate ACTIVE/WARM/COLD labels for all loaded chunks.
func _update_chunk_states(pc: Vector2i) -> void:
	for coord: Vector2i in _chunks:
		var d := chebyshev_distance(coord, pc)
		var desired_state: StringName
		if d <= ACTIVE_RADIUS:
			desired_state = &"active"
		elif d <= WARM_RADIUS:
			desired_state = &"warm"
		else:
			desired_state = &"cold"

		if _chunks[coord]["state"] != desired_state:
			_chunks[coord]["state"] = desired_state
			chunk_state_changed.emit(coord, desired_state)


func note_discovered(coord: Vector2i) -> void:
	if not _records.has(coord):
		_records[coord] = {"discovered": true, "deltas": {}}


# --- Destruction deltas (persistence, P1) ------------------------------------

## Append one destroyed-cell key to a chunk's delta record. Keys are stable
## quantized geometry keys (MeshBatcher.cell_key), independent of
## materialization order, so they survive chunk reloads AND save/load.
func _record_destroyed(coord: Vector2i, cell_key: String) -> void:
	if cell_key == "":
		return
	note_discovered(coord)
	var delta: Dictionary = _records[coord]["deltas"]
	if not delta.has("destroyed"):
		delta["destroyed"] = []
	if not (delta["destroyed"] as Array).has(cell_key):
		(delta["destroyed"] as Array).append(cell_key)


## Replace the partial-damage snapshot for a chunk.
func _record_damage(coord: Vector2i, damage: Dictionary) -> void:
	note_discovered(coord)
	_records[coord]["deltas"]["damage"] = damage


## Destroyed-cell keys + partial damage + door states for one chunk
## (debug/tests).
func chunk_delta(coord: Vector2i) -> Dictionary:
	return _records.get(coord, {}).get("deltas", {})


## Append/update the persisted state of one door (stable key = door manifest
## id). Destroyed doors never respawn when their chunk reloads; surviving
## doors restore their saved logical state.
func _record_door(coord: Vector2i, door_id: String, state: Dictionary) -> void:
	if door_id == "":
		return
	note_discovered(coord)
	var doors: Dictionary = _records[coord]["deltas"].get("doors", {})
	doors[door_id] = state.duplicate()
	_records[coord]["deltas"]["doors"] = doors


## Persisted door states for one chunk ({door_id: {open, destroyed, ...}}).
func door_states(coord: Vector2i) -> Dictionary:
	return _records.get(coord, {}).get("deltas", {}).get("doors", {})


# --- Interior reveal ---------------------------------------------------------

## Hides the building layers ABOVE the player's current storey (upper walls,
## slabs, roof dressing) so the elevated camera sees a top-down cutaway of
## the resident level. Optionally fades the CAMERA-FACING facade(s) of the
## resident storey (sector suffix ":N"/":E"/":S"/":W" on wall sublayers) so
## the near wall no longer blocks the room; far walls stay visible to
## preserve the room shape. Collision is never touched - hidden layers keep
## blocking, they are just invisible.
##
## tag: "<building id>" from the CityPlan spec; max_floor: the player's
## storey index. Pass max_floor < 0 to reveal everything again.
## faded: list of facade letters ("N","E","S","W") to hide on the resident
## storey. Rotation updates the set every frame; transitions are instant
## per-layer but the SET changes only when the camera sector changes, which
## reads as a smooth swap rather than flicker.
func apply_floor_gate(coord: Vector2i, tag: String, max_floor: int,
		faded: Array = []) -> void:
	if not _chunks.has(coord):
		return
	var rec: Dictionary = _chunks[coord]
	var applied: Dictionary = rec.get("layer_hidden", {})
	var changed := false
	for key: Variant in rec.get("layers", {}).keys():
		var layer_key := String(key)
		var hide := false
		if max_floor >= 0 and tag != "" \
				and layer_key.begins_with(tag + ":"):
			var suffix := layer_key.substr(tag.length() + 1)
			if suffix.begins_with("roof"):
				hide = true   # covers "roof" and "roof|r" (visual dressing)
			elif suffix.begins_with("f"):
				var rest := suffix.substr(1)
				# EXPLICIT facade ownership: "f<storey>:<N/E/S/W>" (the
				# builder pushes "<building>:f<i>:<facade>" directly - no
				# nesting tricks), plus the composite glass/roof buckets
				# MeshBatcher appends ("|g"/"|r").
				var colon := rest.find(":")
				if colon >= 0:
					var fl := int(rest.substr(0, colon))
					var facade := rest.substr(colon + 1)
					hide = fl > max_floor \
							or (fl == max_floor and faded.has(facade))
				else:
					hide = int(rest) > max_floor
		if bool(applied.get(layer_key, false)) != hide:
			applied[layer_key] = hide
			changed = true
			var node: Node = rec["layers"][layer_key]
			if node != null and is_instance_valid(node):
				(node as MeshInstance3D).visible = not hide
	if changed or not rec.has("layer_hidden"):
		rec["layer_hidden"] = applied


# --- Voxel destruction -------------------------------------------------------

## Blows a single batched box out of the city. `shape_node` is the
## CollisionShape3D under a chunk's Static body (meta vox_id set by the
## batcher). Disables its collision immediately and queues ONE deferred mesh
## re-bake for the whole chunk. Returns the box spec so callers can spawn
## matching debris; {} when the shape is not destructible.
func destroy_box(shape_node: Node3D) -> Dictionary:
	if not shape_node.has_meta("vox_id"):
		return {}
	var body := shape_node.get_parent()
	for c: Vector2i in _chunks:
		var rec: Dictionary = _chunks[c]
		var st: Node = rec.get("static")
		if st == null or not is_instance_valid(st) or st != body:
			continue
		var batcher: MeshBatcher = rec.get("batcher")
		if batcher == null:
			return {}
		var info := batcher.destroy_box(int(shape_node.get_meta("vox_id")))
		if info.is_empty():
			return {}
		(shape_node as CollisionShape3D).set_deferred("disabled", true)
		_record_destroyed(c, batcher.cell_key_for_id(
				int(shape_node.get_meta("vox_id"))))
		if not bool(rec.get("rebuild_queued", false)):
			rec["rebuild_queued"] = true
			_rebuild_queue.append(c)
		return {
			"pos": info["pos"], "size": info["size"],
			"color": info["color"], "material": info["material"],
		}
	return {}


## Applies bullet/impact damage to a voxel box (glass crack/shatter ladder).
## Returns {shattered, cracked, pos, size, color, material} or {}.
func damage_box(shape_node: Node3D, amount: float) -> Dictionary:
	if not shape_node.has_meta("vox_id"):
		return {}
	var body := shape_node.get_parent()
	for c: Vector2i in _chunks:
		var rec: Dictionary = _chunks[c]
		var st: Node = rec.get("static")
		if st == null or not is_instance_valid(st) or st != body:
			continue
		var batcher: MeshBatcher = rec.get("batcher")
		if batcher == null:
			return {}
		var id := int(shape_node.get_meta("vox_id"))
		var res := batcher.damage_box(id, amount)
		if res.is_empty():
			return {}
		# Cracked (visual change) or shattered (hole) both need a re-bake.
		if res.get("cracked", false) or res.get("shattered", false):
			if not bool(rec.get("rebuild_queued", false)):
				rec["rebuild_queued"] = true
				_rebuild_queue.append(c)
		if res.get("shattered", false):
			(shape_node as CollisionShape3D).set_deferred("disabled", true)
			_record_destroyed(c, batcher.cell_key_for_id(id))
		else:
			# Partial damage: keep the accumulated record fresh for saves.
			_record_damage(c, batcher.damage_state())
		return {
			"shattered": res.get("shattered", false),
			"cracked": res.get("cracked", false),
			"pos": res.get("pos", Vector3.ZERO),
			"size": res.get("size", Vector3.ONE),
			"color": res.get("color", Color.WHITE),
			"material": res.get("material", &""),
		}
	return {}


## Re-bake at most a couple of chunk meshes per frame - explosions often
## destroy several boxes at once, but one refresh covers them all.
func _flush_rebuilds() -> void:
	var budget := 2
	while not _rebuild_queue.is_empty() and budget > 0:
		budget -= 1
		var coord: Vector2i = _rebuild_queue.pop_front()
		if not _chunks.has(coord):
			continue
		var rec: Dictionary = _chunks[coord]
		rec["rebuild_queued"] = false
		var batcher: MeshBatcher = rec.get("batcher")
		if batcher != null:
			batcher.refresh_meshes()


func _log(text: String) -> void:
	_events.append("[%s] %s" % [GameClock.time_string(), text])
	while _events.size() > 8:
		_events.pop_front()


# --- Debug / stats (F3 overlay reads these) ----------------------------------

func active_count() -> int:
	return _count_state(&"active")


func warm_count() -> int:
	return _count_state(&"warm")


func cold_count() -> int:
	return _count_state(&"cold")


func _count_state(state: StringName) -> int:
	var n := 0
	for c in _chunks.values():
		if c["state"] == state:
			n += 1
	return n


func pending_count() -> int:
	return _pending.size() + _inflight.size()


func last_player_chunk() -> Vector2i:
	return _last_player_chunk


func total_boxes_estimate() -> int:
	var n := 0
	for v in _chunks.values():
		n += int(v["boxes"])
	return n


func collision_shapes_total() -> int:
	var n := 0
	for v in _chunks.values():
		n += int(v["colliders"])
	return n


func doors_total() -> int:
	var n := 0
	for v in _chunks.values():
		n += int(v["doors"])
	return n


func buildings_total() -> int:
	var n := 0
	for v in _chunks.values():
		n += int(v["buildings"])
	return n


func avg_gen_ms() -> float:
	return _total_gen_ms / maxf(1.0, float(_total_loads))


func avg_mat_ms() -> float:
	return _total_mat_ms / maxf(1.0, float(_total_loads))


func is_resident(coord: Vector2i) -> bool:
	return _chunks.has(coord)


func state_of(coord: Vector2i) -> StringName:
	return _chunks[coord]["state"] if _chunks.has(coord) else &""


func recent_events() -> Array[String]:
	return _events.duplicate()


func debug_lines() -> Array[String]:
	var lines: Array[String] = []
	lines.append("chunk %s | active %d | warm %d | queued %d | loads %d/unloads %d"
			% [str(last_player_chunk()), active_count(), warm_count(),
			pending_count(), _total_loads, _total_unloads])
	lines.append("boxes ~%d | colliders %d | doors %d | buildings %d | records %d"
			% [total_boxes_estimate(), collision_shapes_total(),
			doors_total(), buildings_total(), _records.size()])
	lines.append("gen %.1f ms | materialize %.1f ms | resident chunks %d (cold %d)"
			% [avg_gen_ms(), avg_mat_ms(), _chunks.size(), cold_count()])
	lines.append("terrain verts %d | tris %d | colliders %d | t_mat %.1f ms | active terrain %d"
			% [_terrain_vertices_total, _terrain_triangles_total, _terrain_colliders_total, _terrain_mat_ms_total, terrain_active_count()])
	return lines

func terrain_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if int(v.get("terrain_colliders", 0)) > 0:
			n += 1
	return n


# --- Persistence contract ----------------------------------------------------

## Records survive saves; geometry is rebuilt deterministically on return.
## Destruction deltas (destroyed cell keys + partial damage + door states)
## ride inside the per-chunk records, so destroyed geometry stays destroyed
## after reload. Resident doors are snapshotted HERE so saves always carry
## their current open/closed state.
func save_state() -> Dictionary:
	_snapshot_resident_doors()
	var recs := {}
	for c: Vector2i in _records:
		recs["%d,%d" % [c.x, c.y]] = _records[c]
	return {"records": recs}


## Capture every resident Door's live state into its chunk record. Stable
## key is the door manifest id (= the Door node name).
func _snapshot_resident_doors() -> void:
	for c: Vector2i in _chunks:
		var node := get_node_or_null(
				NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node == null:
			continue
		for child in node.get_children():
			if child is Door and not (child as Door).is_queued_for_deletion():
				var st: Dictionary = (child as Door).save_state()
				_record_door(c, String(st.get("id", String(child.name))), st)


## Public hook for Door nodes recording their own state changes / death.
func record_door_state(coord: Vector2i, door_id: String,
		state: Dictionary) -> void:
	_record_door(coord, door_id, state)


func load_state(data: Dictionary) -> void:
	_records.clear()
	for key: String in data.get("records", {}):
		var parts := key.split(",")
		var rec: Dictionary = data["records"][key]
		# Guarantee the delta shape even for older saves.
		if not rec.has("deltas") or not (rec["deltas"] is Dictionary):
			rec["deltas"] = {}
		_records[Vector2i(int(parts[0]), int(parts[1]))] = rec