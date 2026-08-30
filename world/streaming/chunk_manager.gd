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
const MAX_MATERIALIZATIONS_PER_FRAME := 1 # never burst several completed chunks into one render frame
const STREAM_UPDATE_INTERVAL := 0.1      # seconds between full ring recalcs (was 0.2, reduced for P3.1 to keep 300s budget)
const MAX_INFLIGHT_BUILDS := 6           # concurrent worker-thread batch jobs (was 2, increased for P3.1 biome+water+terrain to keep 300s budget)

var plan: CityPlan
var world_plan: WorldPlan
var synchronous := false                # tests: build inline, no workers
var _terrain_vertices_total := 0
var _terrain_triangles_total := 0
var _terrain_colliders_total := 0
var _terrain_mat_ms_total := 0.0
var _water_vertices_total := 0
var _water_triangles_total := 0
var _water_colliders_total := 0
var _water_mat_ms_total := 0.0
var _biome_vertices_total := 0
var _biome_triangles_total := 0
var _biome_colliders_total := 0
var _biome_instances_total := 0
var _biome_mat_ms_total := 0.0
var _road_vertices_total := 0
var _road_triangles_total := 0
var _road_colliders_total := 0
var _road_bridges_total := 0
var _road_mat_ms_total := 0.0
var _rural_vertices_total := 0
var _rural_triangles_total := 0
var _rural_colliders_total := 0
var _rural_doors_total := 0
var _rural_buildings_total := 0
var _rural_crates_total := 0
var _rural_furniture_total := 0
var _rural_wells_total := 0
var _rural_forage_total := 0
var _rural_mat_ms_total := 0.0

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
var _total_terrain_gen_ms := 0.0        # terrain manifest generation (measured inside worker)
var _total_water_gen_ms := 0.0          # water manifest generation
var _total_biome_gen_ms := 0.0          # biome manifest generation
var _total_road_gen_ms := 0.0           # road manifest generation
var _total_rural_gen_ms := 0.0          # rural manifest generation
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
	_total_terrain_gen_ms = 0.0
	_water_vertices_total = 0
	_water_triangles_total = 0
	_water_colliders_total = 0
	_water_mat_ms_total = 0.0
	_total_water_gen_ms = 0.0
	_biome_vertices_total = 0
	_biome_triangles_total = 0
	_biome_colliders_total = 0
	_biome_instances_total = 0
	_biome_mat_ms_total = 0.0
	_total_biome_gen_ms = 0.0
	_road_vertices_total = 0
	_road_triangles_total = 0
	_road_colliders_total = 0
	_road_bridges_total = 0
	_road_mat_ms_total = 0.0
	_total_road_gen_ms = 0.0
	_rural_vertices_total = 0
	_rural_triangles_total = 0
	_rural_colliders_total = 0
	_rural_doors_total = 0
	_rural_buildings_total = 0
	_rural_crates_total = 0
	_rural_furniture_total = 0
	_rural_wells_total = 0
	_rural_forage_total = 0
	_rural_mat_ms_total = 0.0
	_total_rural_gen_ms = 0.0
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

	# Workers can finish together; admit at most one main-thread mesh/physics
	# materialization before considering the periodic streaming update. This
	# keeps the player-visible frame from absorbing a completed-job burst.
	_collect_finished_jobs(pc)

	if _stream_timer < STREAM_UPDATE_INTERVAL and not _player_chunk_changed:
		return
	_stream_timer = 0.0
	_player_chunk_changed = false

	var desired := _desired_set(pc)
	_enqueue_missing(desired, pc)
	_launch_batch_jobs()
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
		var holder: Dictionary = {}
		if world_plan != null:
			holder["terrain"] = {}
			holder["terrain_gen_ms"] = 0.0
			holder["water"] = {}
			holder["water_gen_ms"] = 0.0
			holder["biome"] = {}
			holder["biome_gen_ms"] = 0.0
			holder["road"] = {}
			holder["road_gen_ms"] = 0.0
			holder["rural"] = {}
			holder["rural_gen_ms"] = 0.0
			holder["gen_ms"] = 0.0
		var seed_used: int = world_plan.seed_used if world_plan != null else 0
		if synchronous:
			_thread_build(batcher, c, holder, seed_used)
			var gen_ms: float = float(holder.get("gen_ms", 0.0))
			var t_gen: float = float(holder.get("terrain_gen_ms", 0.0))
			var w_gen: float = float(holder.get("water_gen_ms", 0.0))
			var b_gen: float = float(holder.get("biome_gen_ms", 0.0))
			var r_gen: float = float(holder.get("road_gen_ms", 0.0))
			var ru_gen: float = float(holder.get("rural_gen_ms", 0.0))
			_inflight[c] = {"batcher": batcher, "terrain": holder.get("terrain", {}), "water": holder.get("water", {}), "biome": holder.get("biome", {}), "road": holder.get("road", {}), "rural": holder.get("rural", {}), "task_id": -1,
					"gen_ms": gen_ms, "terrain_gen_ms": t_gen, "water_gen_ms": w_gen, "biome_gen_ms": b_gen, "road_gen_ms": r_gen, "rural_gen_ms": ru_gen}
		else:
			var task_id := WorkerThreadPool.add_task(
					_thread_build.bind(batcher, c, holder, seed_used), false,
					"chunk_%d_%d" % [c.x, c.y])
			_inflight[c] = {"batcher": batcher, "terrain_holder": holder, "task_id": task_id,
					"gen_ms": 0.0, "terrain_gen_ms": 0.0, "water_gen_ms": 0.0, "biome_gen_ms": 0.0, "road_gen_ms": 0.0, "rural_gen_ms": 0.0}


## Pure plan->batcher data generation for ONE chunk (worker-safe).
## Builds city batcher + terrain manifest (if holder has terrain key) using private plans.
func _thread_build(batcher: MeshBatcher, coord: Vector2i, holder: Dictionary, seed_used: int) -> void:
	var t_all := Time.get_ticks_usec()
	var local_plan := CityPlan.new()
	ChunkBuilder.fill_batcher(batcher, local_plan, coord)
	var shared_world: WorldPlan = null
	if holder.has("terrain") or holder.has("water") or holder.has("biome") or holder.has("road") or holder.has("rural"):
		shared_world = WorldPlan.new(seed_used)
	if holder.has("terrain"):
		var t0 := Time.get_ticks_usec()
		var m := TerrainChunkBuilder.build_manifest(shared_world, coord)
		holder["terrain"] = m
		holder["terrain_gen_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	else:
		holder["terrain"] = {}
		holder["terrain_gen_ms"] = 0.0
	if holder.has("water"):
		var tw0 := Time.get_ticks_usec()
		var wm := WaterChunkBuilder.build_manifest(shared_world, coord)
		holder["water"] = wm
		holder["water_gen_ms"] = float(Time.get_ticks_usec() - tw0) / 1000.0
	else:
		holder["water"] = {}
		holder["water_gen_ms"] = 0.0
	if holder.has("biome"):
		var tb0 := Time.get_ticks_usec()
		var bm := BiomeChunkBuilder.build_manifest(shared_world, coord)
		holder["biome"] = bm
		holder["biome_gen_ms"] = float(Time.get_ticks_usec() - tb0) / 1000.0
	else:
		holder["biome"] = {}
		holder["biome_gen_ms"] = 0.0
	if holder.has("road"):
		var tr0 := Time.get_ticks_usec()
		var rm := RoadChunkBuilder.build_manifest(shared_world, coord)
		holder["road"] = rm
		holder["road_gen_ms"] = float(Time.get_ticks_usec() - tr0) / 1000.0
	else:
		holder["road"] = {}
		holder["road_gen_ms"] = 0.0
	if holder.has("rural"):
		var tru0 := Time.get_ticks_usec()
		var rum := RuralBuildingChunkBuilder.build_manifest(shared_world, coord)
		holder["rural"] = rum
		holder["rural_gen_ms"] = float(Time.get_ticks_usec() - tru0) / 1000.0
	else:
		holder["rural"] = {}
		holder["rural_gen_ms"] = 0.0
	holder["gen_ms"] = float(Time.get_ticks_usec() - t_all) / 1000.0

## Legacy helper kept for direct sync tests
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
	var materialized := 0
	# Synchronous mode is the deterministic harness contract: it builds and
	# drains inline. Runtime streaming stays capped so completed worker jobs
	# cannot turn one player-visible frame into a materialization burst.
	var materialization_limit := done.size() if synchronous else MAX_MATERIALIZATIONS_PER_FRAME
	for c in done:
		var job: Dictionary = _inflight[c]
		var stale := chebyshev_distance(c, pc) > UNLOAD_RADIUS or _chunks.has(c)
		# Discard stale completions immediately, but leave valid completions in
		# the worker-complete set for a later frame once this frame's single
		# materialization slot has been consumed.
		if not stale and materialized >= materialization_limit:
			continue
		if job["task_id"] >= 0:
			WorkerThreadPool.wait_for_task_completion(job["task_id"])
		_inflight.erase(c)
		if stale:
			continue
		var terrain_manifest: Dictionary = {}
		var terrain_gen_ms: float = float(job.get("terrain_gen_ms", 0.0))
		var gen_ms: float = float(job.get("gen_ms", 0.0))
		var water_manifest: Dictionary = {}
		var water_gen_ms: float = float(job.get("water_gen_ms", 0.0))
		var biome_manifest: Dictionary = {}
		var biome_gen_ms: float = float(job.get("biome_gen_ms", 0.0))
		var road_manifest: Dictionary = {}
		var road_gen_ms: float = float(job.get("road_gen_ms", 0.0))
		var rural_manifest: Dictionary = {}
		var rural_gen_ms: float = float(job.get("rural_gen_ms", 0.0))
		if job.has("terrain"):
			terrain_manifest = job["terrain"]
			water_manifest = job.get("water", {})
			biome_manifest = job.get("biome", {})
			road_manifest = job.get("road", {})
			rural_manifest = job.get("rural", {})
		elif job.has("terrain_holder"):
			var holder: Dictionary = job["terrain_holder"]
			terrain_manifest = holder.get("terrain", {})
			terrain_gen_ms = float(holder.get("terrain_gen_ms", 0.0))
			water_manifest = holder.get("water", {})
			water_gen_ms = float(holder.get("water_gen_ms", 0.0))
			biome_manifest = holder.get("biome", {})
			biome_gen_ms = float(holder.get("biome_gen_ms", 0.0))
			road_manifest = holder.get("road", {})
			road_gen_ms = float(holder.get("road_gen_ms", 0.0))
			rural_manifest = holder.get("rural", {})
			rural_gen_ms = float(holder.get("rural_gen_ms", 0.0))
			gen_ms = float(holder.get("gen_ms", 0.0))
		_materialize(c, job["batcher"], terrain_manifest, gen_ms, pc, terrain_gen_ms, water_manifest, water_gen_ms, biome_manifest, biome_gen_ms, road_manifest, road_gen_ms, rural_manifest, rural_gen_ms)
		materialized += 1


func _materialize(coord: Vector2i, batcher: MeshBatcher, terrain_manifest: Dictionary, gen_ms: float,
		pc: Vector2i, terrain_gen_ms: float = 0.0, water_manifest: Dictionary = {}, water_gen_ms: float = 0.0, biome_manifest: Dictionary = {}, biome_gen_ms: float = 0.0, road_manifest: Dictionary = {}, road_gen_ms: float = 0.0, rural_manifest: Dictionary = {}, rural_gen_ms: float = 0.0) -> void:
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
	var include_collision := chebyshev_distance(coord, pc) <= ACTIVE_RADIUS
	var stats := ChunkBuilder.build(self, plan, coord, batcher, dead_doors,
			include_collision)
	# Materialize terrain under same chunk if manifest present
	var tstats := {}
	if not terrain_manifest.is_empty():
		var chunk_node := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node != null:
			tstats = TerrainChunkBuilder.materialize(chunk_node, terrain_manifest)
	# Materialize water under same chunk if manifest present
	var wstats := {}
	if not water_manifest.is_empty():
		var chunk_node_w := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node_w != null:
			wstats = WaterChunkBuilder.materialize(chunk_node_w, water_manifest)
			# ACTIVE-only water physics: disable warm water colliders
			if not include_collision:
				var wb := chunk_node_w.get_node_or_null(NodePath("Water_%d_%d/WaterBody" % [coord.x, coord.y]))
				if wb != null and is_instance_valid(wb):
					(wb as StaticBody3D).collision_layer = 0
	# Materialize biome under same chunk if manifest present
	var bstats := {}
	if not biome_manifest.is_empty():
		var chunk_node_b := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node_b != null:
			bstats = BiomeChunkBuilder.materialize(chunk_node_b, biome_manifest)
			# ACTIVE-only biome physics: disable warm biome colliders (visual MultiMesh retained)
			if not include_collision:
				var bb := chunk_node_b.get_node_or_null(NodePath("Biome_%d_%d/BiomeBody" % [coord.x, coord.y]))
				if bb != null and is_instance_valid(bb):
					(bb as StaticBody3D).collision_layer = 0
	# Materialize road under same chunk if manifest present
	var rstats := {}
	if not road_manifest.is_empty():
		var chunk_node_r := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node_r != null:
			rstats = RoadChunkBuilder.materialize(chunk_node_r, road_manifest)
			# ACTIVE-only road physics: disable warm road colliders (visual ribbon retained)
			if not include_collision:
				var rb := chunk_node_r.get_node_or_null(NodePath("Road_%d_%d/RoadBody" % [coord.x, coord.y]))
				if rb != null and is_instance_valid(rb):
					(rb as StaticBody3D).collision_layer = 0
	# Materialize rural under same chunk if manifest present
	var rustats := {}
	if not rural_manifest.is_empty():
		# Apply crate deltas before materialize (persistence-first)
		var c_deltas: Dictionary = {}
		if _records.has(coord):
			var c_delta: Dictionary = (_records[coord].get("deltas", {}) as Dictionary).get("crates", {}) as Dictionary
			if c_delta is Dictionary:
				c_deltas = c_delta
		if not c_deltas.is_empty():
			var cms: Array = rural_manifest.get("crate_manifests", []) as Array
			var patched: Array[Dictionary] = []
			for cm in cms:
				var cd: Dictionary = cm as Dictionary
				var cid: String = String(cd.get("id",""))
				if c_deltas.has(cid):
					var saved: Dictionary = c_deltas[cid] as Dictionary
					var new_contents: Dictionary = {}
					for k in saved.keys():
						new_contents[StringName(str(k))] = int(saved[k])
					cd = cd.duplicate()
					cd["contents"] = new_contents
				patched.append(cd)
			rural_manifest["crate_manifests"] = patched
		# Apply wells/forage deltas before materialize and handle refill/regrow via GameClock
		if _records.has(coord):
			var deltas: Dictionary = _records[coord].get("deltas", {}) as Dictionary
			# Wells deltas: {well_id: {depleted, depleted_at_day}}
			var w_deltas: Dictionary = deltas.get("wells", {}) as Dictionary
			var f_deltas: Dictionary = deltas.get("forage", {}) as Dictionary
			# Wells refill check: if depleted_at_day *1440+240 <= GameClock.total_minutes, clear depleted
			var cur_total: float = GameClock.total_minutes if GameClock != null else 0.0
			var cur_day: int = GameClock.get_day() if GameClock != null else 1
			if not w_deltas.is_empty():
				var patched_w := {}
				for wid in w_deltas.keys():
					var ws: Dictionary = w_deltas[wid] as Dictionary
					var dep: bool = bool(ws.get("depleted", false))
					var dep_day: int = int(ws.get("depleted_at_day", -1))
					if dep:
						var refill_min: float = float(dep_day * 1440 + 240)
						if cur_total >= refill_min:
							# refilled, skip persisting depleted
							continue
					patched_w[wid] = ws
				# update record if some refilled
				if patched_w.size() != w_deltas.size():
					deltas["wells"] = patched_w
					_records[coord]["deltas"] = deltas
			if not f_deltas.is_empty():
				var patched_f := {}
				for fid in f_deltas.keys():
					var fs: Dictionary = f_deltas[fid] as Dictionary
					var dep_f: bool = bool(fs.get("depleted", false))
					var dep_day_f: int = int(fs.get("depleted_at_day", -1))
					if dep_f and cur_day >= dep_day_f + 2:
						continue
					patched_f[fid] = fs
				if patched_f.size() != f_deltas.size():
					deltas["forage"] = patched_f
					_records[coord]["deltas"] = deltas
		var chunk_node_ru := get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk_node_ru != null:
			rustats = RuralBuildingChunkBuilder.materialize(chunk_node_ru, rural_manifest)
			# Apply well/forage depleted states after materialize (re-apply deltas before interactability)
			if _records.has(coord):
				var deltas2: Dictionary = _records[coord].get("deltas", {}) as Dictionary
				var w_deltas2: Dictionary = deltas2.get("wells", {}) as Dictionary
				var f_deltas2: Dictionary = deltas2.get("forage", {}) as Dictionary
				if not w_deltas2.is_empty() or not f_deltas2.is_empty():
					_apply_rural_well_forage_states(chunk_node_ru, coord, w_deltas2, f_deltas2)
			# ACTIVE-only rural physics: disable warm rural colliders (visual retained) and crate/well/forage interactability
			if not include_collision:
				var rub := chunk_node_ru.get_node_or_null(NodePath("Rural_%d_%d/RuralBody" % [coord.x, coord.y]))
				if rub != null and is_instance_valid(rub):
					(rub as StaticBody3D).collision_layer = 0
				_set_rural_crates_enabled(chunk_node_ru, coord, false)
				_set_rural_wells_enabled(chunk_node_ru, coord, false)
				_set_rural_forage_enabled(chunk_node_ru, coord, false)
			else:
				_set_rural_crates_enabled(chunk_node_ru, coord, true)
				_set_rural_wells_enabled(chunk_node_ru, coord, true)
				_set_rural_forage_enabled(chunk_node_ru, coord, true)
	# Restore surviving doors' saved logical state (open pose / lock).
	if not dstates.is_empty():
		var chunk := get_node_or_null(
				NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
		if chunk != null:
			_restore_doors_recursive(chunk, dstates)
	var dist := chebyshev_distance(coord, pc)
	var state: StringName = &"active" if dist <= ACTIVE_RADIUS else &"warm"
	var terrain_verts := int(tstats.get("terrain_vertices", 0))
	var terrain_tris := int(tstats.get("terrain_triangles", 0))
	var terrain_cols := int(tstats.get("terrain_colliders", 0))
	var water_verts := int(wstats.get("water_vertices", 0))
	var water_tris := int(wstats.get("water_triangles", 0))
	var water_cols := int(wstats.get("water_colliders", 0))
	var biome_verts := int(bstats.get("biome_vertices", 0))
	var biome_tris := int(bstats.get("biome_triangles", 0))
	var biome_cols := int(bstats.get("biome_colliders", 0))
	var biome_instances := int(bstats.get("biome_instances", 0))
	var road_verts := int(rstats.get("road_vertices", 0))
	var road_tris := int(rstats.get("road_triangles", 0))
	var road_cols := int(rstats.get("road_colliders", 0))
	var road_bridges := int(rstats.get("bridge_vertices", 0) > 0 or rstats.get("has_bridge", false) as bool)
	var rural_verts := int(rustats.get("rural_vertices", 0))
	var rural_tris := int(rustats.get("rural_triangles", 0))
	var rural_cols := int(rustats.get("rural_colliders", 0))
	var rural_doors := int(rustats.get("rural_doors", 0))
	var rural_buildings := int(rustats.get("rural_buildings", 0))
	var rural_crates := int(rustats.get("rural_crates", 0))
	var rural_furniture := int(rustats.get("rural_furniture", 0))
	var rural_wells := int(rustats.get("rural_wells", 0))
	var rural_forage := int(rustats.get("rural_forage", 0))
	_chunks[coord] = {
		"state": state,
		"boxes": int(stats["boxes"]),
		"colliders": int(stats["colliders"]) if include_collision else 0,
		"planned_colliders": int(stats["colliders"]),
		"doors": int(stats["doors"]),
		"buildings": int(stats["buildings"]),
		"props": int(stats.get("props", 0)),
		"terrain_vertices": terrain_verts,
		"terrain_triangles": terrain_tris,
		"terrain_colliders": terrain_cols,
		"terrain_manifest": terrain_manifest,
		"water_vertices": water_verts,
		"water_triangles": water_tris,
		"water_colliders": water_cols,
		"water_manifest": water_manifest,
		"biome_vertices": biome_verts,
		"biome_triangles": biome_tris,
		"biome_colliders": biome_cols,
		"biome_colliders_active": biome_cols if include_collision else 0,
		"biome_instances": biome_instances,
		"biome_manifest": biome_manifest,
		"road_vertices": road_verts,
		"road_triangles": road_tris,
		"road_colliders": road_cols,
		"road_colliders_active": road_cols if include_collision else 0,
		"road_bridges": road_bridges,
		"road_manifest": road_manifest,
		"rural_vertices": rural_verts,
		"rural_triangles": rural_tris,
		"rural_colliders": rural_cols,
		"rural_colliders_active": rural_cols if include_collision else 0,
		"rural_doors": rural_doors,
		"rural_buildings": rural_buildings,
		"rural_crates": rural_crates,
		"rural_furniture": rural_furniture,
		"rural_wells": rural_wells,
		"rural_forage": rural_forage,
		"rural_crates_active": rural_crates if include_collision else 0,
		"rural_wells_active": rural_wells if include_collision else 0,
		"rural_forage_active": rural_forage if include_collision else 0,
		"rural_manifest": rural_manifest,
		"layers": batcher.layer_nodes,
		"batcher": batcher,
		"static": get_node_or_null(
				NodePath("Chunk_%d_%d/Static" % [coord.x, coord.y])),
		"rebuild_queued": false,
		"gen_ms": gen_ms,
		"mat_ms": float(stats["mat_ms"]),
		"terrain_gen_ms": terrain_gen_ms,
		"terrain_mat_ms": float(tstats.get("terrain_mat_ms", 0.0)),
		"water_gen_ms": water_gen_ms,
		"water_mat_ms": float(wstats.get("water_mat_ms", 0.0)),
		"biome_gen_ms": biome_gen_ms,
		"biome_mat_ms": float(bstats.get("biome_mat_ms", 0.0)),
		"road_gen_ms": road_gen_ms,
		"road_mat_ms": float(rstats.get("road_mat_ms", 0.0)),
		"rural_gen_ms": rural_gen_ms,
		"rural_mat_ms": float(rustats.get("rural_mat_ms", 0.0)),
	}
	_terrain_vertices_total += terrain_verts
	_terrain_triangles_total += terrain_tris
	_terrain_colliders_total += terrain_cols
	_terrain_mat_ms_total += float(tstats.get("terrain_mat_ms", 0.0))
	_water_vertices_total += water_verts
	_water_triangles_total += water_tris
	_water_colliders_total += water_cols
	_water_mat_ms_total += float(wstats.get("water_mat_ms", 0.0))
	_biome_vertices_total += biome_verts
	_biome_triangles_total += biome_tris
	_biome_colliders_total += biome_cols
	_biome_instances_total += biome_instances
	_biome_mat_ms_total += float(bstats.get("biome_mat_ms", 0.0))
	_road_vertices_total += road_verts
	_road_triangles_total += road_tris
	_road_colliders_total += road_cols
	_road_bridges_total += road_bridges
	_road_mat_ms_total += float(rstats.get("road_mat_ms", 0.0))
	_rural_vertices_total += rural_verts
	_rural_triangles_total += rural_tris
	_rural_colliders_total += rural_cols
	_rural_doors_total += rural_doors
	_rural_buildings_total += rural_buildings
	_rural_crates_total += rural_crates
	_rural_furniture_total += rural_furniture
	_rural_wells_total += rural_wells
	_rural_forage_total += rural_forage
	_rural_mat_ms_total += float(rustats.get("rural_mat_ms", 0.0))
	_total_loads += 1
	_total_gen_ms += gen_ms
	_total_mat_ms += float(stats["mat_ms"])
	_total_terrain_gen_ms += terrain_gen_ms
	_total_water_gen_ms += water_gen_ms
	_total_biome_gen_ms += biome_gen_ms
	_total_road_gen_ms += road_gen_ms
	_total_rural_gen_ms += rural_gen_ms
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
		var rec: Dictionary = _chunks[c]
		var batcher: MeshBatcher = rec.get("batcher")
		if batcher != null:
			batcher.disable_collision()
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node != null:
			node.queue_free()
		_terrain_vertices_total -= int(rec.get("terrain_vertices", 0))
		_terrain_triangles_total -= int(rec.get("terrain_triangles", 0))
		_terrain_colliders_total -= int(rec.get("terrain_colliders", 0))
		_terrain_mat_ms_total -= float(rec.get("terrain_mat_ms", 0.0))
		_total_terrain_gen_ms -= float(rec.get("terrain_gen_ms", 0.0))
		_water_vertices_total -= int(rec.get("water_vertices", 0))
		_water_triangles_total -= int(rec.get("water_triangles", 0))
		_water_colliders_total -= int(rec.get("water_colliders", 0))
		_water_mat_ms_total -= float(rec.get("water_mat_ms", 0.0))
		_total_water_gen_ms -= float(rec.get("water_gen_ms", 0.0))
		_biome_vertices_total -= int(rec.get("biome_vertices", 0))
		_biome_triangles_total -= int(rec.get("biome_triangles", 0))
		_biome_colliders_total -= int(rec.get("biome_colliders", 0))
		_biome_instances_total -= int(rec.get("biome_instances", 0))
		_biome_mat_ms_total -= float(rec.get("biome_mat_ms", 0.0))
		_total_biome_gen_ms -= float(rec.get("biome_gen_ms", 0.0))
		_road_vertices_total -= int(rec.get("road_vertices", 0))
		_road_triangles_total -= int(rec.get("road_triangles", 0))
		_road_colliders_total -= int(rec.get("road_colliders", 0))
		_road_bridges_total -= int(rec.get("road_bridges", 0))
		_road_mat_ms_total -= float(rec.get("road_mat_ms", 0.0))
		_total_road_gen_ms -= float(rec.get("road_gen_ms", 0.0))
		_rural_vertices_total -= int(rec.get("rural_vertices", 0))
		_rural_triangles_total -= int(rec.get("rural_triangles", 0))
		_rural_colliders_total -= int(rec.get("rural_colliders", 0))
		_rural_doors_total -= int(rec.get("rural_doors", 0))
		_rural_buildings_total -= int(rec.get("rural_buildings", 0))
		_rural_crates_total -= int(rec.get("rural_crates", 0))
		_rural_furniture_total -= int(rec.get("rural_furniture", 0))
		_rural_wells_total -= int(rec.get("rural_wells", 0))
		_rural_forage_total -= int(rec.get("rural_forage", 0))
		_rural_mat_ms_total -= float(rec.get("rural_mat_ms", 0.0))
		_total_rural_gen_ms -= float(rec.get("rural_gen_ms", 0.0))
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
			var previous_state: StringName = _chunks[coord]["state"]
			var rec: Dictionary = _chunks[coord]
			var batcher: MeshBatcher = rec.get("batcher")
			if batcher != null and desired_state == &"active":
				batcher.enable_collision()
				rec["static"] = get_node_or_null(
						NodePath("Chunk_%d_%d/Static" % [coord.x, coord.y]))
				rec["colliders"] = int(rec.get("planned_colliders", 0)) \
						if rec["static"] != null else 0
			elif batcher != null and previous_state == &"active":
				batcher.disable_collision()
				rec["static"] = null
				rec["colliders"] = 0
			# Water ACTIVE-only physics: warm retains WaterMesh visual but disables collision
			var water_body := get_node_or_null(NodePath("Chunk_%d_%d/Water_%d_%d/WaterBody" % [coord.x, coord.y, coord.x, coord.y]))
			if water_body != null and is_instance_valid(water_body):
				if desired_state == &"active":
					(water_body as StaticBody3D).collision_layer = 1
				elif previous_state == &"active":
					(water_body as StaticBody3D).collision_layer = 0
			# Biome ACTIVE-only physics: warm retains BiomeMesh + MultiMesh visuals but disables BiomeBody collision
			var biome_body := get_node_or_null(NodePath("Chunk_%d_%d/Biome_%d_%d/BiomeBody" % [coord.x, coord.y, coord.x, coord.y]))
			if biome_body != null and is_instance_valid(biome_body):
				if desired_state == &"active":
					(biome_body as StaticBody3D).collision_layer = 1
				elif previous_state == &"active":
					(biome_body as StaticBody3D).collision_layer = 0
			# Road ACTIVE-only physics: warm retains RoadMesh visual but disables RoadBody collision
			var road_body := get_node_or_null(NodePath("Chunk_%d_%d/Road_%d_%d/RoadBody" % [coord.x, coord.y, coord.x, coord.y]))
			if road_body != null and is_instance_valid(road_body):
				if desired_state == &"active":
					(road_body as StaticBody3D).collision_layer = 1
				elif previous_state == &"active":
					(road_body as StaticBody3D).collision_layer = 0
			# Rural ACTIVE-only physics: warm retains RuralMesh visual but disables RuralBody collision
			var rural_body := get_node_or_null(NodePath("Chunk_%d_%d/Rural_%d_%d/RuralBody" % [coord.x, coord.y, coord.x, coord.y]))
			if rural_body != null and is_instance_valid(rural_body):
				if desired_state == &"active":
					(rural_body as StaticBody3D).collision_layer = 1
				elif previous_state == &"active":
					(rural_body as StaticBody3D).collision_layer = 0
			# Rural crates/wells/forage ACTIVE-only
			if desired_state == &"active" and previous_state != &"active":
				var rural_node_active := get_node_or_null(NodePath("Chunk_%d_%d/Rural_%d_%d" % [coord.x, coord.y, coord.x, coord.y]))
				if rural_node_active != null:
					_set_rural_crates_enabled(rural_node_active, coord, true)
					_set_rural_wells_enabled(rural_node_active, coord, true)
					_set_rural_forage_enabled(rural_node_active, coord, true)
			elif desired_state != &"active" and previous_state == &"active":
				var rural_node_warm := get_node_or_null(NodePath("Chunk_%d_%d/Rural_%d_%d" % [coord.x, coord.y, coord.x, coord.y]))
				if rural_node_warm != null:
					_set_rural_crates_enabled(rural_node_warm, coord, false)
					_set_rural_wells_enabled(rural_node_warm, coord, false)
					_set_rural_forage_enabled(rural_node_warm, coord, false)
			rec["state"] = desired_state
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

func avg_terrain_gen_ms() -> float:
	return _total_terrain_gen_ms / maxf(1.0, float(_total_loads))

func avg_water_gen_ms() -> float:
	return _total_water_gen_ms / maxf(1.0, float(_total_loads))

func avg_water_mat_ms() -> float:
	return _water_mat_ms_total / maxf(1.0, float(maxi(1, _water_vertices_total)))  # per-chunk mat approx

func avg_biome_gen_ms() -> float:
	return _total_biome_gen_ms / maxf(1.0, float(_total_loads))

func avg_biome_mat_ms() -> float:
	return _biome_mat_ms_total / maxf(1.0, float(maxi(1, _biome_vertices_total)))

func avg_road_gen_ms() -> float:
	return _total_road_gen_ms / maxf(1.0, float(_total_loads))

func avg_road_mat_ms() -> float:
	return _road_mat_ms_total / maxf(1.0, float(maxi(1, _road_vertices_total)))

func avg_rural_gen_ms() -> float:
	return _total_rural_gen_ms / maxf(1.0, float(_total_loads))

func avg_rural_mat_ms() -> float:
	return _rural_mat_ms_total / maxf(1.0, float(maxi(1, _rural_vertices_total)))

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
	lines.append("terrain verts %d | tris %d | colliders %d | t_gen %.1f ms | t_mat_total %.1f ms | active terrain %d (warm %d)"
			% [_terrain_vertices_total, _terrain_triangles_total, _terrain_colliders_total, avg_terrain_gen_ms(), _terrain_mat_ms_total, terrain_active_count(), terrain_warm_count()])
	lines.append("water verts %d | tris %d | colliders %d | t_water_gen %.1f ms | t_water_mat %.1f ms | active water %d (warm %d)"
			% [_water_vertices_total, _water_triangles_total, _water_colliders_total, avg_water_gen_ms(), _water_mat_ms_total, water_active_count(), water_warm_count()])
	lines.append("biome verts %d | tris %d | colliders %d | instances %d | t_biome_gen %.1f ms | t_biome_mat %.1f ms | active biome %d (warm %d)"
			% [_biome_vertices_total, _biome_triangles_total, _biome_colliders_total, _biome_instances_total, avg_biome_gen_ms(), _biome_mat_ms_total, biome_active_count(), biome_warm_count()])
	lines.append("road verts %d | tris %d | colliders %d | bridges %d | t_road_gen %.1f ms | t_road_mat %.1f ms | active road %d (warm %d)"
			% [_road_vertices_total, _road_triangles_total, _road_colliders_total, _road_bridges_total, avg_road_gen_ms(), _road_mat_ms_total, road_active_count(), road_warm_count()])
	lines.append("rural verts %d | tris %d | colliders %d | doors %d | buildings %d | crates %d | furniture %d | wells %d | forage %d | t_rural_gen %.1f ms | t_rural_mat %.1f ms | active rural %d (warm %d)"
			% [_rural_vertices_total, _rural_triangles_total, _rural_colliders_total, _rural_doors_total, _rural_buildings_total, _rural_crates_total, _rural_furniture_total, _rural_wells_total, _rural_forage_total, avg_rural_gen_ms(), _rural_mat_ms_total, rural_active_count(), rural_warm_count()])
	return lines

func terrain_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"active" and int(v.get("terrain_colliders", 0)) > 0:
			n += 1
	return n

func terrain_warm_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"warm" and int(v.get("terrain_colliders", 0)) > 0:
			n += 1
	return n

func water_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"active" and int(v.get("water_colliders", 0)) > 0:
			n += 1
	return n

func water_warm_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"warm" and int(v.get("water_colliders", 0)) > 0:
			n += 1
	return n

func biome_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"active" and int(v.get("biome_colliders", 0)) > 0:
			n += 1
	return n

func biome_warm_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"warm" and int(v.get("biome_colliders", 0)) > 0:
			n += 1
	return n

func road_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"active" and int(v.get("road_colliders", 0)) > 0:
			n += 1
	return n

func road_warm_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"warm" and int(v.get("road_colliders", 0)) > 0:
			n += 1
	return n

func rural_active_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"active" and int(v.get("rural_colliders", 0)) > 0:
			n += 1
	return n

func rural_warm_count() -> int:
	var n := 0
	for v in _chunks.values():
		if v.get("state", "") == &"warm" and int(v.get("rural_colliders", 0)) > 0:
			n += 1
	return n


func _set_rural_crates_enabled(rural_parent: Node, coord: Vector2i, enabled: bool) -> void:
	var rural_node: Node = rural_parent
	if rural_parent.name.begins_with("Chunk_"):
		rural_node = rural_parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
		if rural_node == null:
			return
	for child in rural_node.get_children():
		if child is FoodCrate:
			var crate: FoodCrate = child as FoodCrate
			if is_instance_valid(crate):
				crate.collision_layer = 1 if enabled else 0
				var inter = crate.get("_interactable")
				if inter != null and is_instance_valid(inter):
					inter.enabled = enabled and not crate.is_empty()
				else:
					var inter2 = crate.get("interactable")
					if inter2 != null and is_instance_valid(inter2):
						inter2.enabled = enabled and not crate.is_empty()
				for sub in crate.get_children():
					if sub is CollisionShape3D:
						var sb := sub.get_parent()
						if sb is StaticBody3D:
							(sb as StaticBody3D).collision_layer = 1 if enabled else 0
	for child in rural_node.get_children():
		if child is FoodCrate:
			continue
		for sub in child.get_children():
			if sub is FoodCrate:
				var crate2: FoodCrate = sub as FoodCrate
				if is_instance_valid(crate2):
					crate2.collision_layer = 1 if enabled else 0

func _set_rural_wells_enabled(rural_parent: Node, coord: Vector2i, enabled: bool) -> void:
	var rural_node: Node = rural_parent
	if rural_parent.name.begins_with("Chunk_"):
		rural_node = rural_parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
		if rural_node == null:
			return
	for child in rural_node.get_children():
		if child is Well:
			var well: Well = child as Well
			if is_instance_valid(well):
				if is_instance_valid(well.get_node_or_null(NodePath("CollisionShape3D"))):
					# well body layer handled via itself
					well.collision_layer = 1 if enabled else 0
				var inter = well.get("interactable")
				if inter != null and is_instance_valid(inter):
					# need to check depleted state: if depleted, keep disabled even when active
					var dep: bool = well.depleted if "depleted" in well else false
					# _try_refill will be called via _update_prompt
					if well.has_method("_try_refill"):
						well.call("_try_refill")
						dep = well.depleted
					inter.enabled = enabled and not dep

func _set_rural_forage_enabled(rural_parent: Node, coord: Vector2i, enabled: bool) -> void:
	var rural_node: Node = rural_parent
	if rural_parent.name.begins_with("Chunk_"):
		rural_node = rural_parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
		if rural_node == null:
			return
	for child in rural_node.get_children():
		if child is ForagePatch:
			var patch: ForagePatch = child as ForagePatch
			if is_instance_valid(patch):
				var inter = patch.get("interactable")
				var dep: bool = patch.depleted if "depleted" in patch else false
				if patch.has_method("_try_regrow"):
					patch.call("_try_regrow")
					dep = patch.depleted
				if inter != null and is_instance_valid(inter):
					inter.enabled = enabled and not dep
				patch.monitorable = enabled and not dep

func _apply_rural_well_forage_states(parent: Node, coord: Vector2i, wells: Dictionary, forage: Dictionary) -> void:
	# parent is Chunk_X_Y, need to find Rural node
	var rural_node: Node = parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
	if rural_node == null:
		# maybe parent is already Rural node
		if parent.name.begins_with("Rural_"):
			rural_node = parent
		else:
			return
	for child in rural_node.get_children():
		if child is Well:
			var wid: String = String(child.name)
			if wells.has(wid):
				(child as Well).load_state(wells[wid] as Dictionary)
		elif child is ForagePatch:
			var fid: String = String(child.name)
			if forage.has(fid):
				(child as ForagePatch).load_state(forage[fid] as Dictionary)

func _record_well(coord: Vector2i, well_id: String, state: Dictionary) -> void:
	if well_id == "":
		return
	note_discovered(coord)
	var wells: Dictionary = _records[coord]["deltas"].get("wells", {})
	wells[well_id] = state.duplicate()
	_records[coord]["deltas"]["wells"] = wells

func _record_forage(coord: Vector2i, forage_id: String, state: Dictionary) -> void:
	if forage_id == "":
		return
	note_discovered(coord)
	var forage: Dictionary = _records[coord]["deltas"].get("forage", {})
	forage[forage_id] = state.duplicate()
	_records[coord]["deltas"]["forage"] = forage

func _snapshot_resident_wells_forage() -> void:
	for c: Vector2i in _chunks:
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node == null:
			continue
		_collect_wells_forage_recursive(node, c)

func _collect_wells_forage_recursive(n: Node, coord: Vector2i) -> void:
	for child in n.get_children():
		if child is Well and not (child as Well).is_queued_for_deletion():
			if String(child.name).begins_with("rural_well_"):
				var st: Dictionary = (child as Well).save_state()
				_record_well(coord, String(child.name), st)
		elif child is ForagePatch and not (child as ForagePatch).is_queued_for_deletion():
			if String(child.name).begins_with("rural_forage_"):
				var st: Dictionary = (child as ForagePatch).save_state()
				_record_forage(coord, String(child.name), st)
		if child.get_child_count() > 0:
			_collect_wells_forage_recursive(child, coord)

func _record_crate(coord: Vector2i, crate_id: String, state: Dictionary) -> void:
	if crate_id == "":
		return
	note_discovered(coord)
	var crates: Dictionary = _records[coord]["deltas"].get("crates", {})
	crates[crate_id] = state.duplicate()
	_records[coord]["deltas"]["crates"] = crates

func _snapshot_resident_crates() -> void:
	for c: Vector2i in _chunks:
		var node := get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
		if node == null:
			continue
		_collect_crates_recursive(node, c)

func _collect_crates_recursive(n: Node, coord: Vector2i) -> void:
	for child in n.get_children():
		if child is FoodCrate and not (child as FoodCrate).is_queued_for_deletion():
			if String(child.name).begins_with("rural_crate_"):
				var st: Dictionary = (child as FoodCrate).save_state()
				_record_crate(coord, String(child.name), st)
		if child.get_child_count() > 0:
			_collect_crates_recursive(child, coord)

func _restore_crates_recursive(n: Node, cstates: Dictionary) -> void:
	for child in n.get_children():
		if child is FoodCrate and cstates.has(String(child.name)):
			(child as FoodCrate).load_state(cstates[String(child.name)])
		if child.get_child_count() > 0:
			_restore_crates_recursive(child, cstates)

# --- Persistence contract ----------------------------------------------------

## Records survive saves; geometry is rebuilt deterministically on return.
## Destruction deltas (destroyed cell keys + partial damage + door states)
## ride inside the per-chunk records, so destroyed geometry stays destroyed
## after reload. Resident doors are snapshotted HERE so saves always carry
## their current open/closed state.
func save_state() -> Dictionary:
	_snapshot_resident_doors()
	_snapshot_resident_crates()
	_snapshot_resident_wells_forage()
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
		_collect_doors_recursive(node, c)

func _collect_doors_recursive(n: Node, coord: Vector2i) -> void:
	for child in n.get_children():
		if child is Door and not (child as Door).is_queued_for_deletion():
			var st: Dictionary = (child as Door).save_state()
			_record_door(coord, String(st.get("id", String(child.name))), st)
		# recurse into Rural etc
		if child.get_child_count() > 0:
			_collect_doors_recursive(child, coord)

func _restore_doors_recursive(n: Node, dstates: Dictionary) -> void:
	for child in n.get_children():
		if child is Door and dstates.has(String(child.name)):
			(child as Door).load_state(dstates[String(child.name)])
		if child.get_child_count() > 0:
			_restore_doors_recursive(child, dstates)


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