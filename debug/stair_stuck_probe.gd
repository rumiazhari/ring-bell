extends Node3D
## STAIR / STEP WEDGE AUDIT  ->  `--stairstucktest`
##
## Reproduces "player stuck on a stairs edge" as a measurable defect and names
## the emitter that causes it, so a geometry fix is verified, never eyeballed.
##
## WHAT IT DOES
##   1. Picks REAL enterable buildings out of the real CityPlan, assembles them
##      with the REAL universal assembler and flushes the REAL colliders.
##   2. Finds walkable surfaces by casting down onto them (ramps, landings,
##      storey floors) - no hand-modelled expectations.
##   3. For each sampled surface point: settles a walker on it, then drives it
##      for ~0.7 s along each compass heading, exactly like a player holding
##      WASD.
##   4. Classifies every run:
##        MOVED      travelled >= MOVE_MIN ................. OK
##        WALL       blocked, chest-height ray agrees ...... OK (real wall)
##        LOW_BLOCK  chest ray CLEAR, low ray hits, cannot move
##                   -> a lip / step edge / rail foot jams the capsule.
##                      This is the reported "stairs edge" defect.
##        JAM        nothing at any height, cannot move .... hard wedge
##        LOCKED     a parkour state owned the frames ..... not a wedge
##   Only LOW_BLOCK and JAM fail the run.
##
## ENV KNOBS (all optional)
##   RB_STUCK_BUILDINGS   buildings to audit (default 2)
##   RB_STUCK_MODE        stairs | interior | all ....... (default stairs)
##   RB_STUCK_BODY        probe | survivor ............. (default probe)
##   RB_STUCK_LEVELS      storey pairs sampled (default 2)
##   RB_STUCK_ZSTEP       sample spacing along the shaft (default 0.4)
##   RB_STUCK_XSTEP       sample spacing across lane (default 0.625)
##   RB_STUCK_ISTEP       spacing for the interior carpet (default 1.6)
##   RB_STUCK_BATCH       walkers per physics timeline (default 64)
##   RB_STUCK_TIMESCALE   physics speed-up (default 20, real 1/60 s steps)

const WALKER := preload("res://debug/stuck_probe_walker.gd")

const MOVE_MIN := 0.22          # m travelled during the measured window
const CHEST_REACH := 0.62       # capsule radius 0.35 + clearance
const LOW_REACH := 0.50
const PRUNE_REACH := 0.42       # already touching a wall -> uninteresting
const SETTLE_FRAMES := 12
const DRIVE_FRAMES := 44
const FLIGHT_FRAMES := 260        # 4.3 s of walking: covers any flight + landings
const MEASURE_FROM := 20
const ENV_LAYER := 1
const CAPSULE_R := 0.35         # Survivor capsule radius (kept in sync)
const CAPSULE_H := 1.7          # Survivor capsule height
const CAPSULE_MID := 0.85
const LOW_H := 0.24
const FOOT_H := 0.06
const RAY_HEIGHTS: Array[float] = [0.06, 0.24, 0.45, 0.70, 0.85]
const WALL_TOP := 0.45          # blocker at/above this is a wall, not a lip

const LOCKS: Array = [
	CharacterLocomotion.State.VAULT, CharacterLocomotion.State.MANTLE,
	CharacterLocomotion.State.HANG, CharacterLocomotion.State.CLIMB_UP,
	CharacterLocomotion.State.SLIDE, CharacterLocomotion.State.WALL_RUN_L,
	CharacterLocomotion.State.WALL_RUN_R, CharacterLocomotion.State.SHIMMY,
	CharacterLocomotion.State.DROP2HANG,
]

var _checks := 0
var _fails := 0
var _runs := 0
var _moved := 0
var _counts: Dictionary = {}
var _defects: Array[String] = []
var _holder: Node3D
var _wp: WorldPlan
var _city: CityPlan
var _building_root: Node3D
var _static: StaticBody3D
var _use_survivor := false
var _synth := false


func _ready() -> void:
	Engine.max_physics_steps_per_frame = 256
	Engine.time_scale = _env_float("RB_STUCK_TIMESCALE", 20.0)
	_use_survivor = OS.get_environment("RB_STUCK_BODY") == "survivor"
	_synth = OS.get_environment("RB_STUCK_SYNTH") == "1"
	_holder = Node3D.new()
	_holder.name = "StuckProbeHolder"
	add_child(_holder)
	var specs: Array[Dictionary] = []
	if _synth:
		specs.append(_synth_spec())
	else:
		_wp = WorldPlan.new(WorldSeed.get_world_seed())
		_city = CityPlan.new()
		specs = _pick_specs()
	print("[StairStuckTest] buildings to audit: %d (body=%s)" % [
		specs.size(), "survivor" if _use_survivor else "probe"])
	for spec in specs:
		await _audit_building(spec)
	_holder.queue_free()
	_report()


# ---------------------------------------------------------------- yaw space
#
# THE COORDINATE SPACE TRAP (Q1 open question D): `stair_zone_world()` returns
# the shaft zone in BUILD space - the unrotated plan frame. Every city parcel
# that carries a yaw is emitted rotated by UniversalBuildingAssembler about
# `Vector3(rect.get_center().x, 0, rect.get_center().y)` with
# Basis(UP, -yaw) (mesh_batcher.push_building_transform:461). A probe that
# walks the build-space zone inside a yawed parcel is walking a lane that is
# not there, and any "stall" it reports is its own bug, not the game's.
# So: derive in BUILD space, then map every point and heading through _w()/_wd()
# before touching physics, and map world results back with _b().

var _yaw := 0.0
var _yaw_origin := Vector3.ZERO

func _yawed() -> bool:
	return not is_zero_approx(_yaw)

## Build space -> world (point).
func _w(p: Vector3) -> Vector3:
	if not _yawed():
		return p
	return _yaw_origin + Basis(Vector3.UP, -_yaw) * (p - _yaw_origin)

## Build space -> world (plan x/z only).
func _w2(x: float, z: float) -> Vector2:
	var p := _w(Vector3(x, 0.0, z))
	return Vector2(p.x, p.z)

## Build space -> world (direction; no translation).
func _wd(d: Vector3) -> Vector3:
	if not _yawed():
		return d
	return Basis(Vector3.UP, -_yaw) * d

## World -> build space (point).
func _b(p: Vector3) -> Vector3:
	if not _yawed():
		return p
	return _yaw_origin + Basis(Vector3.UP, -_yaw).inverse() * (p - _yaw_origin)


# ---------------------------------------------------------------- selection

func _env_float(key: String, fallback: float) -> float:
	var raw := OS.get_environment(key)
	if raw.is_valid_float():
		return raw.to_float()
	return fallback


func _env_int(key: String, fallback: int) -> int:
	var raw := OS.get_environment(key)
	if raw.is_valid_int():
		return raw.to_int()
	return fallback


## Synthetic stand-in spec: same generator path, no 48 s CityPlan bake. The
## rect/floor height/pitch come from the real city building the bug was seen
## in; only the plan's choice of plot is skipped.
func _synth_spec() -> Dictionary:
	return {
		"id": "stuck_synth",
		"rect": Rect2(0.0, 0.0, _env_float("RB_STUCK_W", 12.8), _env_float("RB_STUCK_D", 13.8)),
		"style": {"wall": 1, "roof": 1},
		"floor_h": _env_float("RB_STUCK_FH", 3.1),
		"floors": _env_int("RB_STUCK_N", 3),
		"door_edge": _env_int("RB_STUCK_EDGE", 0),
		"ground_y": 0.0,
		"building_ground_y": 0.0,
		"yaw": 0.0,
		"district": &"historic",
	}


## Real, enterable, staired city buildings with entrance edges spread out.
func _pick_specs() -> Array[Dictionary]:
	var want := _env_int("RB_STUCK_BUILDINGS", 2)
	var scan := _env_int("RB_STUCK_CHUNKS", 2)
	var by_edge: Dictionary = {}
	var used: Dictionary = {}
	var pool: Array[Dictionary] = []
	for cx in range(-scan, scan + 1):
		for cz in range(-scan, scan + 1):
			var coord := Vector2i(cx, cz)
			var rect := WorldSeed.chunk_rect(coord)
			for spec_variant in _city.buildings_in_rect(rect):
				var spec: Dictionary = spec_variant
				var fp: Rect2 = spec.get("rect", Rect2()) as Rect2
				if fp.size.x <= 0.0:
					continue
				if WorldSeed.chunk_coord(fp.get_center().x, fp.get_center().y) != coord:
					continue
				if (spec.get("quality", WorldConstants.BUILDING_QUALITY_FULL_BUILDING) as StringName) \
						!= WorldConstants.BUILDING_QUALITY_FULL_BUILDING:
					continue
				var fh := float(spec.get("floor_h", 0.0))
				var n := int(spec.get("floors", 0))
				if fh <= 0.0 or not BuildingBuilder.has_stairs_for(fp.size, fh, n):
					continue
				var id := str(spec.get("id", "?"))
				if used.has(id):
					continue
				used[id] = true
				pool.append(spec)
				var edge := int(spec.get("door_edge", 0))
				if not by_edge.has(edge):
					by_edge[edge] = spec
	# One building per entrance edge first (entrance spread), then fill from the
	# rest: a single parcel proves nothing about "stuck", so a sweep has to cover
	# many real buildings with different floors/fh/edges/yaw.
	var out: Array[Dictionary] = []
	var used_out: Dictionary = {}
	for edge: int in by_edge.keys():
		out.append(by_edge[edge])
		used_out[str((by_edge[edge] as Dictionary).get("id", "?"))] = true
	for spec in pool:
		if out.size() >= want:
			break
		var id2 := str(spec.get("id", "?"))
		if used_out.has(id2):
			continue
		used_out[id2] = true
		out.append(spec)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	print("[StairStuckTest] picked %d building(s) from %d staired candidate(s) over %d chunk(s)" % [
		out.size(), pool.size(), (scan * 2 + 1) * (scan * 2 + 1)])
	return out


# ---------------------------------------------------------------- one building

func _audit_building(spec: Dictionary) -> void:
	var grounded: Dictionary = spec if _synth else ChunkBuilder._grounded_spec(spec, _wp)
	var batcher := MeshBatcher.new()
	UniversalBuildingAssembler.build_into(batcher, grounded)
	if batcher.collider_count() <= 0:
		_check("building %s emitted colliders" % str(spec.get("id", "?")), false)
		return
	var building_id := str(grounded.get("id", "?"))
	_building_root = Node3D.new()
	_building_root.name = "STUCK_%s" % building_id
	_holder.add_child(_building_root)
	batcher.flush_into(_building_root, ENV_LAYER, true)
	_static = _building_root.get_node_or_null(NodePath("Static")) as StaticBody3D
	var fh := float(grounded["floor_h"])
	var n := int(grounded["floors"])
	var base := float(grounded.get("building_ground_y", grounded.get("ground_y", 0.0)))
	var zone := BuildingBuilder.stair_zone_world(grounded)
	var fp: Rect2 = grounded["rect"] as Rect2
	_yaw = float(grounded.get("yaw", 0.0))
	_yaw_origin = Vector3(fp.get_center().x, 0.0, fp.get_center().y)
	print("[StairStuckTest] --- %s edge=%d fh=%.2f n=%d fp=%.1fx%.1f base=%.2f yaw=%.1fdeg zone=(%.2f,%.2f %.2fx%.2f)" % [
		building_id, int(grounded.get("door_edge", 0)), fh, n,
		fp.size.x, fp.size.y, base, rad_to_deg(_yaw), zone.position.x,
		zone.position.y, zone.size.x, zone.size.y])
	await get_tree().physics_frame

	var wanted := OS.get_environment("RB_STUCK_MODE")
	if wanted.is_empty():
		wanted = "stairs"
	var samples: Array[Dictionary] = []
	if wanted == "stairs" or wanted == "all":
		samples.append_array(_sample_shaft(grounded, zone, base, fh))
	if wanted == "interior" or wanted == "all":
		samples.append_array(_sample_interior(grounded, zone, base, fh))
	# A sample the player could not physically stand at is not a trap: nothing can
	# depenetrate a capsule spawned inside a wall. The carpet grids the whole
	# footprint, shaft edges included, so prune by real clearance first and only
	# then call a non-moving run a defect.
	var kept: Array[Dictionary] = []
	var pruned := 0
	for sample in samples:
		if _clearance(sample["pos"] as Vector3) < 0.02:
			pruned += 1
			continue
		kept.append(sample)
	if pruned > 0:
		print("[StairStuckTest] %s: pruned %d spawn(s) without capsule clearance" % [
			building_id, pruned])
	samples = kept
	print("[StairStuckTest] %s: %d walkable samples (mode=%s)" % [building_id, samples.size(), wanted])
	if wanted == "dump" or wanted == "all":
		_dump_zone(zone, base, fh, n, building_id)
	var flights: Array[Dictionary] = []
	var walk_flights := wanted == "flights" or wanted == "all"
	if walk_flights:
		flights = await _walk_flights(grounded, zone, base, fh, n)
		print("[StairStuckTest] %s: walked %d flight(s) end to end, %d catch(es)" % [
			building_id, n * 2, flights.size()])

	var build_start := Time.get_ticks_msec()
	var runs: Array[Dictionary] = []
	for sample in samples:
		for h in range(8):
			runs.append({
				"pos": sample["pos"] as Vector3,
				"level": int(sample["level"]),
				"heading": _heading_vec(h),
				"key": "%d:%.2f:%.2f" % [int(sample["level"]),
						(sample["pos"] as Vector3).x, (sample["pos"] as Vector3).z],
			})
	var defects: Array[Dictionary] = []
	var pts: Dictionary = {}
	var stats: Dictionary = {"moved": 0, "wall": 0, "lip": 0, "jam": 0,
			"inside": 0, "locked": 0, "skipped": 0}
	var batch := _env_int("RB_STUCK_BATCH", 64)
	var i := 0
	while i < runs.size():
		var slice_in := runs.slice(i, mini(i + batch, runs.size()))
		await _run_batch(slice_in, defects, stats, pts)
		i += batch
	_runs += runs.size()
	_moved += int(stats["moved"])
	for key in stats:
		_counts[key] = int(_counts.get(key, 0)) + int(stats[key])
	# A POINT is a trap when no compass heading gets the walker moving again:
	# that is the literal player report ("I am stuck"), not "a wall is in front".
	var traps: Array[Dictionary] = []
	for k in pts:
		var rec: Dictionary = pts[k]
		if int(rec["moved"]) == 0 and int(rec["blocked"]) > 0:
			traps.append(rec)
	var secs := float(Time.get_ticks_msec() - build_start) / 1000.0
	print("[StairStuckTest] %s: runs=%d moved=%d wall=%d locked=%d skipped=%d wedge=%d  (%.1fs)" % [
		building_id, runs.size(), int(stats["moved"]), int(stats["wall"]),
		int(stats["locked"]), int(stats["skipped"]), defects.size(), secs])
	for d in traps:
		var tp: Vector3 = d["pos"] as Vector3
		print("[StairStuckTest] TRAP building=%s level=%d at=(%.2f,%.2f,%.2f) blocked=%d/moved=%d cls=%s\n    inside=%s\n    near=%s" % [
			building_id, int(d["level"]), tp.x, tp.y, tp.z,
			int(d["blocked"]), int(d["moved"]), str(d["cls"]),
			str(d["ins"]), _near_emitters(tp)])
	for d in defects:
		_report_defect(d, grounded)
	for w in flights:
		var st: Vector3 = w["stop"] as Vector3
		var sd: Vector3 = w["start"] as Vector3
		print("[StairStuckTest] FLIGHT-CATCH building=%s %s level=%d start=(%.2f,%.2f,%.2f) stop=(%.2f,%.2f,%.2f) stall_frame=%d\n    dy=%.2f want_dy=%.2f travel=%.2f run=%.2f floor=%s vel=%s\n    contract_y=%.2f stopped_at_y=%.2f floor_normal=%s slides=%d\n    inside=%s\n    near=%s" % [
			building_id, str(w["kind"]), int(w["level"]), sd.x, sd.y, sd.z,
			st.x, st.y, st.z, int(w["stall"]), float(w["dy"]), float(w["want_dy"]),
			float(w["travel"]), float(w["want_dz"]), str(w["floor"]),
			str(w["vel"]), float(w["contract_y"]), st.y, str(w["fnormal"]),
			int(w["slides"]), str(w["inside"]), _near_emitters(st)])
	if walk_flights:
		_check("every flight is walkable end to end in %s (%d walks)" % [building_id, n * 2],
			flights.is_empty(), "%d unreachable flight(s)" % flights.size())
	_check("no stair/step wedge in %s (%d runs)" % [building_id, runs.size()],
		traps.is_empty() and defects.is_empty(),
		"%d trap point(s), %d wedged run(s)" % [traps.size(), defects.size()])
	_building_root.queue_free()
	await get_tree().physics_frame


func _heading_vec(i: int) -> Vector3:
	var ang := TAU * float(i) / 8.0
	return Vector3(cos(ang), 0.0, sin(ang))


# ---------------------------------------------------------------- sampling

## Stairwell surfaces: fine grid over the shaft, both flight parities.
func _sample_shaft(spec: Dictionary, zone: Rect2, base: float, fh: float) -> Array[Dictionary]:
	var n := int(spec["floors"])
	var pairs := mini(_env_int("RB_STUCK_LEVELS", 2), maxi(n - 1, 1))
	var xstep := _env_float("RB_STUCK_XSTEP", 0.625)
	var zstep := _env_float("RB_STUCK_ZSTEP", 0.4)
	var out: Array[Dictionary] = []
	for level in range(pairs):
		var ceiling := base + float(level + 1) * fh - 0.06
		var x := zone.position.x + 0.16
		while x < zone.position.x + zone.size.x - 0.16:
			var z := zone.position.y + 0.16
			while z < zone.position.y + zone.size.y - 0.16:
				var wp := _w2(x, z)
				var s := _surface_at(wp.x, wp.y, ceiling, level)
				if not s.is_empty():
					out.append(s)
				z += zstep
			x += xstep
	return out


## Coarse carpet over the rest of the ground floor footprint (circulation,
## doorways, room corners) so "stuck somewhere in the building" is covered too.
func _sample_interior(spec: Dictionary, zone: Rect2, base: float, fh: float) -> Array[Dictionary]:
	var fp: Rect2 = spec["rect"] as Rect2
	var step := _env_float("RB_STUCK_ISTEP", 1.6)
	var ceiling := base + fh - 0.06
	var out: Array[Dictionary] = []
	var x := fp.position.x + 0.6
	while x < fp.position.x + fp.size.x - 0.6:
		var z := fp.position.y + 0.6
		while z < fp.position.y + fp.size.y - 0.6:
			if not zone.has_point(Vector2(x, z)):
				var wp := _w2(x, z)
				var s := _surface_at(wp.x, wp.y, ceiling, 0)
				if not s.is_empty():
					out.append(s)
			z += step
		x += step
	return out


## Cast down from just under a storey ceiling; accept floor-like hits only.
func _surface_at(x: float, z: float, from_y: float, level: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(
			Vector3(x, from_y, z), Vector3(x, from_y - 12.0, z), ENV_LAYER)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {}
	var n: Vector3 = hit["normal"]
	if n.dot(Vector3.UP) < 0.55:
		return {}
	var p: Vector3 = hit["position"]
	return {"pos": p + Vector3.UP * 0.03, "level": level, "normal": n}


# ---------------------------------------------------------------- zone dump

## Inventory of EVERY collider the emitter put inside the shaft zone, sorted by
## height. The contract says a shaft contains: the ramp of exactly one lane per
## storey, one landing plate per lane per end, and NOTHING else. Anything extra
## found here is an intruder that a walking body can press against.
func _dump_zone(zone: Rect2, base: float, fh: float, n: int,
		building_id: String) -> void:
	var top := base + float(n + 1) * fh
	var aabb := AABB(Vector3(zone.position.x - 0.30, base - 1.0, zone.position.y - 0.30),
			Vector3(zone.size.x + 0.60, top - base + 2.0, zone.size.y + 0.60))
	var rows: Array[Dictionary] = []
	for child in _static.get_children():
		var cs := child as CollisionShape3D
		if cs == null:
			continue
		var bs := cs.shape as BoxShape3D
		if bs == null:
			continue
		var xf := cs.global_transform
		var h := bs.size * 0.5   # global_transform already carries cs.scale
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		var blo := Vector3(INF, INF, INF)
		var bhi := Vector3(-INF, -INF, -INF)
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var w := xf * Vector3(h.x * sx, h.y * sy, h.z * sz)
					lo = Vector3(minf(lo.x, w.x), minf(lo.y, w.y), minf(lo.z, w.z))
					hi = Vector3(maxf(hi.x, w.x), maxf(hi.y, w.y), maxf(hi.z, w.z))
					var bw := _b(w)
					blo = Vector3(minf(blo.x, bw.x), minf(blo.y, bw.y), minf(blo.z, bw.z))
					bhi = Vector3(maxf(bhi.x, bw.x), maxf(bhi.y, bw.y), maxf(bhi.z, bw.z))
		# Zone membership is a BUILD-space question: flip the collider's corners
		# back through the parcel yaw, then test against the unrotated zone.
		var box := AABB(blo, bhi - blo)
		if not box.intersects(aabb):
			continue
		var tilted := absf(cs.rotation.x) > 0.01 or absf(cs.rotation.z) > 0.01
		# Note: sizes are printed as shape*scale (the true box), corners come
		# from global_transform alone - multiplying by scale here double-counts.
		rows.append({
			"y0": lo.y, "y1": hi.y, "x0": lo.x, "x1": hi.x, "z0": lo.z, "z1": hi.z,
			"size": bs.size * cs.scale, "tilt": tilted,
			"layer": str(cs.get_meta("src_layer", cs.name)),
			"name": cs.name,
		})
	rows.sort_custom(func(a, b2):
		if absf(float(a.y0) - float(b2.y0)) > 0.01:
			return float(a.y0) < float(b2.y0)
		return float(a.z0) < float(b2.z0))
	print("[StairStuckTest] ZONE-DUMP %s: %d collider(s) intersect the shaft  zone=(x %.2f..%.2f z %.2f..%.2f) base=%.2f fh=%.2f n=%d" % [
		building_id, rows.size(), zone.position.x, zone.end.x, zone.position.y,
		zone.end.y, base, fh, n])
	for r in rows:
		print("    y %6.2f..%6.2f  x %7.2f..%7.2f  z %7.2f..%7.2f  size=(%.2f,%.2f,%.2f)%s  %s" % [
			float(r.y0), float(r.y1), float(r.x0), float(r.x1), float(r.z0),
			float(r.z1), (r.size as Vector3).x, (r.size as Vector3).y,
			(r.size as Vector3).z, "  TILTED" if bool(r.tilt) else "",
			str(r.layer)])


# ---------------------------------------------------------------- flight walk

## Walk each flight of the switchback END TO END, both ways, exactly like a
## player holding a key: board on the lower landing, climb the real ramp, and
## require arrival on the upper landing. A stall mid-run is the reported
## "stuck on a stairs edge" - and the stall point names the emitter.
func _walk_flights(spec: Dictionary, zone: Rect2, base: float,
		fh: float, n: int) -> Array[Dictionary]:
	var z_n := zone.position.y
	var z_s := zone.end.y
	var lane_w := BuildingBuilder.LANE_W
	var run_len := BuildingBuilder.flight_run(fh)
	var board := mini(0.55, BuildingBuilder.LAND * 0.5)
	var walks: Array[Dictionary] = []
	for k in range(n):
		var asc := k % 2 == 0
		var lane_c := zone.position.x + (lane_w * 0.5 if asc else lane_w * 1.5)
		var y0 := base + float(k) * fh
		var up_start := _w(Vector3(lane_c, y0 + 0.08,
				(z_n + board) if asc else (z_s - board)))
		var down_start := _w(Vector3(lane_c, y0 + fh + 0.08,
				(z_s - board) if asc else (z_n + board)))
		var up_dir := _wd(Vector3(0.0, 0.0, 1.0 if asc else -1.0))
		walks.append({"kind": "UP", "level": k, "start": up_start,
				"heading": up_dir, "dy": fh, "dz": run_len})
		walks.append({"kind": "DOWN", "level": k, "start": down_start,
				"heading": -up_dir, "dy": -fh, "dz": run_len})
	var out: Array[Dictionary] = []
	var bodies: Array[Node3D] = []
	for w in walks:
		var b: Node3D = _make_walker()
		_building_root.add_child(b)
		b.global_position = w["start"] as Vector3
		b.velocity = Vector3.ZERO
		b.set("move_dir", Vector3.ZERO)
		# Probe bodies must not collide with each other: two walkers sharing a
		# stair lane would stop each other head-on and fake a wedge. Environment
		# layer only, exactly like the solo player.
		b.collision_layer = ENV_LAYER
		b.collision_mask = ENV_LAYER
		bodies.append(b)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	for i in bodies.size():
		var hd: Vector3 = walks[i]["heading"] as Vector3
		if _use_survivor:
			(bodies[i] as Survivor).request_move(hd, false)
		else:
			bodies[i].set("move_dir", hd)
	var trail: Array[Array] = []
	for i in bodies.size():
		trail.append([bodies[i].global_position])
	for f in FLIGHT_FRAMES:
		await get_tree().physics_frame
		if _use_survivor and f % 5 == 0 and not bodies.is_empty():
			var s0 := bodies[0] as Survivor
			if s0 != null:
				var dead := false
				var sleeping := false
				var ls := -1
				var lc: Variant = s0.get("_locomotion")
				if lc != null and is_instance_valid(lc):
					ls = int(lc.state)
				var hc: Variant = s0.get("health")
				dead = bool(hc.is_dead) if hc != null else false
				var nc: Variant = s0.get("needs")
				sleeping = bool(nc.sleeping) if nc != null else false
				print("[FltDiag] f=%d loco=%d vel=%v floor=%s mdlen=%.2f dead=%s sleep=%s phys=%s in_tree=%s pmode=%d layer=%d paused=%s steps=%d pos=%v" % [f, ls, s0.velocity, str(s0.is_on_floor()), (s0.get("_move_dir") as Vector3).length(), str(dead), str(sleeping), str(s0.is_physics_processing()), str(s0.is_inside_tree()), int(s0.process_mode), s0.collision_layer, str(s0.get_tree().paused if s0.get_tree() != null else false), int(s0.get("step_up_count")), s0.global_position])
		for i in bodies.size():
			(trail[i] as Array).append(bodies[i].global_position)
	for i in bodies.size():
		var b := bodies[i] as CharacterBody3D
		var w: Dictionary = walks[i]
		var start: Vector3 = w["start"]
		var end := b.global_position
		var dy := end.y - start.y
		var along := (end - start)
		along.y = 0.0
		var travel := along.length()
		var ok_final := false
		if w["kind"] == "UP":
			ok_final = dy >= float(w["dy"]) * 0.75 and travel >= run_len * 0.55
		else:
			ok_final = dy <= float(w["dy"]) * 0.75 and travel >= run_len * 0.55
		if not ok_final:
			# Where did it stop moving? First frame whose step is < 5 mm and
			# whose NEXT 8 frames stay put: the stall, not a slide.
			var pts: Array = trail[i]
			var stall := -1
			for f in range(1, pts.size()):
				var moved_last := (pts[f] as Vector3).distance_to(pts[f - 1] as Vector3)
				var ahead := 0.0
				for g in range(f, mini(f + 8, pts.size())):
					ahead = maxf(ahead, (pts[g] as Vector3).distance_to(pts[f] as Vector3))
				if moved_last < 0.005 and ahead < 0.02:
					stall = f
					break
			var stop: Vector3 = (pts[stall] as Vector3) if stall >= 0 else end
			out.append({
				"kind": str(w["kind"]), "level": int(w["level"]), "start": start,
				"stop": stop, "stall": stall, "dy": dy, "travel": travel,
				"want_dy": float(w["dy"]), "want_dz": run_len,
				"slides": b.get_slide_collision_count(), "slide": _slide_evidence(b),
				"inside": _overlaps(stop), "floor": b.is_on_floor(),
				"fnormal": b.get_floor_normal(), "vel": b.velocity,
				"contract_y": BuildingBuilder.ramp_height_at(_b(stop).z, base + float(w["level"]) * fh, fh, z_n),
				"zone_y": z_n, "zone_h": zone.size.y, "lane_x": start.x,
			})
		b.queue_free()
	await get_tree().physics_frame
	return out


# ---------------------------------------------------------------- run batch

func _run_batch(slice_in: Array[Dictionary], defects: Array[Dictionary],
		stats: Dictionary, pts: Dictionary = {}) -> void:
	# Prune runs whose chest ray is already inside a wall: those are WALL by
	# construction and cost a full drive to prove.
	var live: Array[Dictionary] = []
	for run in slice_in:
		var pos: Vector3 = run["pos"]
		var heading: Vector3 = run["heading"]
		var chest := _cast(pos + Vector3.UP * CAPSULE_MID, heading, PRUNE_REACH)
		if chest >= 0.0:
			stats["wall"] = int(stats["wall"]) + 1
			stats["skipped"] = int(stats["skipped"]) + 1
			continue
		live.append(run)
	if live.is_empty():
		return

	var bodies: Array[Node3D] = []
	for run in live:
		var body: Node3D = _make_walker()
		if body == null:
			continue
		_building_root.add_child(body)
		body.global_position = run["pos"] as Vector3
		body.velocity = Vector3.ZERO
		body.set("move_dir", Vector3.ZERO)
		body.collision_layer = ENV_LAYER
		body.collision_mask = ENV_LAYER
		bodies.append(body)

	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	for i in bodies.size():
		var hd: Vector3 = live[i]["heading"]
		if _use_survivor:
			(bodies[i] as Survivor).request_move(hd, false)
		else:
			(bodies[i] as Node3D).set("move_dir", hd)

	var marks: Array[Vector3] = []
	for i in DRIVE_FRAMES:
		await get_tree().physics_frame
		if _use_survivor and i % 15 == 0 and not bodies.is_empty():
			var s0 := bodies[0] as Survivor
			if s0 != null:
				var dead := false
				var sleeping := false
				var ls := -1
				var lc: Variant = s0.get("_locomotion")
				if lc != null and is_instance_valid(lc):
					ls = int(lc.state)
				var rc := -1
				var ab: Variant = s0.get("abyss")
				if ab != null and is_instance_valid(ab):
					rc = int(ab.recovery_count)
				print("[SurvDiag] f=%d md=%v vel=%v floor=%s dead=%s loco=%d abyss=%d sleep=%s pm=%d y=%.2f" % [i, s0.get("_move_dir"), s0.velocity, str(s0.is_on_floor()), str(s0.health.is_dead), ls, rc, str(s0.needs.sleeping), int(s0.process_mode), s0.global_position.y])
		if i == MEASURE_FROM - 1:
			for b in bodies:
				marks.append(b.global_position)

	var idx := 0
	for b in bodies:
		var run: Dictionary = live[idx]
		var start: Vector3 = marks[idx] if idx < marks.size() else b.global_position
		var mid: Vector3 = b.global_position
		var done := Vector2(mid.x - start.x, mid.z - start.z).length()
		var state := -1
		var loco: Variant = b.get("_locomotion")
		var locked := false
		if loco != null and is_instance_valid(loco):
			state = int(loco.state)
			locked = LOCKS.has(loco.state)
		var cls := _classify(b, run, done, locked)
		var k := str(run.get("key", ""))
		var rec: Dictionary = pts.get(k, {"moved": 0, "blocked": 0, "cls": {} as Dictionary,
				"pos": run["pos"], "level": int(run["level"]), "ins": "none"})
		if cls == "MOVED":
			rec["moved"] = int(rec["moved"]) + 1
		else:
			rec["blocked"] = int(rec["blocked"]) + 1
			var cc: Dictionary = rec["cls"]
			cc[cls] = int(cc.get(cls, 0)) + 1
			if str(rec["ins"]) == "none" and str(_overlaps(b.global_position)) != "none":
				rec["ins"] = _overlaps(b.global_position)
		pts[k] = rec
		if cls == "MOVED":
			stats["moved"] = int(stats["moved"]) + 1
		elif cls == "WALL":
			stats["wall"] = int(stats["wall"]) + 1
		elif cls == "LOCKED":
			stats["locked"] = int(stats["locked"]) + 1
		else:
			var key := "lip" if cls == "LIP" else ("inside" if cls == "INSIDE" else "jam")
			stats[key] = int(stats[key]) + 1
			defects.append({
				"pos": b.global_position, "heading": run["heading"] as Vector3,
				"level": int(run["level"]), "cls": cls, "disp": done,
				"state": state, "chest": _cast(b.global_position + Vector3.UP * CAPSULE_MID,
					run["heading"] as Vector3, CHEST_REACH),
				"floor": b.is_on_floor(), "fnormal": b.get_floor_normal(),
				"vel": b.velocity, "slides": b.get_slide_collision_count(),
				"inside": _overlaps(b.global_position),
				"slide": _slide_evidence(b),
			})
		b.queue_free()
		idx += 1
	await get_tree().physics_frame


func _make_walker() -> Node3D:
	if _use_survivor:
		var s := Survivor.new()
		s.configure({"id": &"", "name": "StuckProbe", "is_player": false})
		return s
	return WALKER.new()


func _classify(b: Node3D, run: Dictionary, done: float, locked: bool) -> String:
	if done >= MOVE_MIN:
		return "MOVED"
	if not b.is_on_floor():
		return "MOVED"    # fell off a ledge: not a wedge
	if locked:
		return "LOCKED"
	if _inside_any(b.global_position):
		return "INSIDE"     # capsule overlaps real structure: hard wedge
	var heading: Vector3 = run["heading"]
	var origin := b.global_position
	# Vertical fan: the blocker's HEIGHT decides, not a fixed probe height. A
	# guard rail reaching chest height is a wall; a lip under the knee that
	# still stops the capsule is the "stairs edge" defect.
	var highest := -1.0
	var top := -1.0
	for h: float in RAY_HEIGHTS:
		var d := _cast(origin + Vector3.UP * h, heading, LOW_REACH)
		if d < 0.0:
			continue
		if d > highest:
			highest = d
		top = maxf(top, h)
	if top >= WALL_TOP:
		return "WALL"
	if top >= 0.0:
		return "LIP"
	return "JAM"


## True when the standing capsule overlaps any batched box. move_and_slide
## cannot depenetrate a spawned overlap, so this is a hard wedge, not a wall.
func _inside_any(point: Vector3) -> bool:
	return _overlaps(point) != "none"


## Gap (m) between the standing capsule at `pt` and one collider box, measured in
## the BOX's own frame. An axis-aligned test is wrong here: the stair ramps and
## the wallcut slabs are TILTED, and the world AABB of a tilted 0.22 m slab is a
## tall block that swallows every sample standing on it - which is how a probe
## ends up calling a clean stairwell "inside" 1231 times.
## Negative = penetration. Alternating projection (exact for a segment vs a box).
func _capsule_gap(pt: Vector3, cs: CollisionShape3D, box: BoxShape3D) -> float:
	var h := box.size * 0.5
	var inv: Transform3D = cs.transform.affine_inverse()
	var lo: Vector3 = inv * (pt + Vector3.UP * CAPSULE_R)
	var hi: Vector3 = inv * (pt + Vector3.UP * (CAPSULE_H - CAPSULE_R))
	var ab := hi - lo
	var len2 := maxf(ab.length_squared(), 0.000001)
	var best := 99.0
	for i in 13:
		var t := float(i) / 12.0
		for _pass in 3:
			var p := lo + ab * t
			var q := Vector3(clampf(p.x, -h.x, h.x), clampf(p.y, -h.y, h.y),
					clampf(p.z, -h.z, h.z))
			t = clampf(ab.dot(q - lo) / len2, 0.0, 1.0)
		var pe := lo + ab * t
		var qe := Vector3(clampf(pe.x, -h.x, h.x), clampf(pe.y, -h.y, h.y),
				clampf(pe.z, -h.z, h.z))
		best = minf(best, (pe - qe).length() - CAPSULE_R)
	return best


## Smallest gap between the standing capsule at `pt` and any batched collider.
## < 0 means the capsule is already inside structure (unrecoverable spawn).
func _clearance(pt: Vector3) -> float:
	if _static == null or not is_instance_valid(_static):
		return 99.0
	var best := 99.0
	for shape in _static.get_children():
		var cs := shape as CollisionShape3D
		if cs == null:
			continue
		var box := cs.shape as BoxShape3D
		if box == null:
			continue
		best = minf(best, _capsule_gap(pt, cs, box))
		if best < -0.05:
			break
	return best


## What move_and_slide is actually pressed against when the run ends: the
## direct evidence for "why can I not move", independent of ray guesses.
func _slide_evidence(b: CharacterBody3D) -> String:
	if b.get_slide_collision_count() <= 0:
		return "-"
	var c := b.get_slide_collision(0)
	var col := c.get_collider()
	var parts: Array[String] = ["n=(%.2f,%.2f,%.2f)" % [c.get_normal().x, c.get_normal().y, c.get_normal().z],
			"p=(%.2f,%.2f,%.2f)" % [c.get_position().x, c.get_position().y, c.get_position().z]]
	if col is CollisionObject3D:
		var shp := c.get_collider_shape()
		var body := col as CollisionObject3D
		for node in body.get_children():
			var cs := node as CollisionShape3D
			if cs == null or (shp != null and cs.shape != shp):
				continue
			var bx := cs.shape as BoxShape3D
			parts.append("box=%s at=(%.2f,%.2f,%.2f)%s" % [
				str(bx.size) if bx != null else str(cs.shape),
				cs.transform.origin.x, cs.transform.origin.y, cs.transform.origin.z,
				" layer=" + str(cs.get_meta("src_layer", "?")) if cs.has_meta("src_layer") else ""])
			break
	return " ".join(parts)


func _cast(origin: Vector3, dir: Vector3, dist: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * dist, ENV_LAYER)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return -1.0
	return origin.distance_to(hit["position"] as Vector3)


# ---------------------------------------------------------------- reporting

func _check(label: String, ok: bool, detail := "") -> void:
	_checks += 1
	if ok:
		print("[StairStuckTest] PASS %s" % label)
	else:
		_fails += 1
		print("[StairStuckTest] FAIL %s  <%s>" % [label, detail])


func _report_defect(d: Dictionary, spec: Dictionary) -> void:
	var pos: Vector3 = d["pos"]
	var hd: Vector3 = d["heading"]
	var line := "building=%s edge=%d level=%d cls=%s disp=%.3f state=%d at=(%.2f,%.2f,%.2f) heading=(%.2f,%.2f) chest=%.2f near=%s" % [
		str(spec.get("id", "?")), int(spec.get("door_edge", 0)), int(d["level"]),
		str(d["cls"]), float(d["disp"]), int(d["state"]),
		pos.x, pos.y, pos.z, hd.x, hd.z, float(d["chest"]),
		_near_emitters(pos)]
	line += "\n    floor=%s fn=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) slides=%d inside=%s" % [
		str(d.get("floor", false)),
		(d.get("fnormal", Vector3.UP) as Vector3).x,
		(d.get("fnormal", Vector3.UP) as Vector3).y,
		(d.get("fnormal", Vector3.UP) as Vector3).z,
		(d.get("vel", Vector3.ZERO) as Vector3).x,
		(d.get("vel", Vector3.ZERO) as Vector3).y,
		(d.get("vel", Vector3.ZERO) as Vector3).z,
		int(d.get("slides", 0)), str(d.get("inside", "-"))]
	line += "\n    slide=%s" % str(d.get("slide", "-"))
	_defects.append(line)
	print("[StairStuckTest] DEFECT %s" % line)


## List the axes-aligned volumes whose AABB overlaps the standing capsule. A
## JAM with a clear ray and a non-empty overlap list means the body spawned (or
## slid) INTO batched structure: move_and_slide cannot depenetrate that, which
## is exactly the "cannot move at all" report.
func _overlaps(point: Vector3) -> String:
	if _static == null or not is_instance_valid(_static):
		return "-"
	var out: Array[String] = []
	var count := 0
	for shape in _static.get_children():
		var cs := shape as CollisionShape3D
		if cs == null:
			continue
		var box := cs.shape as BoxShape3D
		if box == null:
			continue
		var gap := _capsule_gap(point, cs, box)
		if gap >= -0.005:
			continue
		count += 1
		if out.size() < 5:
			out.append("size=(%.2f,%.2f,%.2f) at=(%.2f,%.2f,%.2f) gap=%.3f%s" % [
				box.size.x, box.size.y, box.size.z,
				cs.transform.origin.x, cs.transform.origin.y, cs.transform.origin.z, gap,
				" layer=" + str(cs.get_meta("src_layer", "?")) if cs.has_meta("src_layer") else ""])
	if count == 0:
		return "none"
	return "%d: %s" % [count, " | ".join(out)]


## Name the boxes around a stuck point so the fix can be aimed at an emitter.
func _near_emitters(point: Vector3, radius := 1.3) -> String:
	if _static == null or not is_instance_valid(_static):
		return "-"
	var found: Array[String] = []
	for shape in _static.get_children():
		var cs := shape as CollisionShape3D
		if cs == null or not (cs.shape is BoxShape3D):
			continue
		var d := point.distance_to(cs.global_position)
		if d > radius:
			continue
		var box := cs.shape as BoxShape3D
		var layer := str(cs.get_meta("src_layer", "?"))
		found.append("%s size=(%.2f,%.2f,%.2f) at=(%.2f,%.2f,%.2f) dist=%.2f" % [
			layer, box.size.x, box.size.y, box.size.z,
			cs.global_position.x, cs.global_position.y, cs.global_position.z, d])
	found.sort()
	return " | ".join(found)


func _report() -> void:
	print("[StairStuckTest] totals runs=%d moved=%d wall=%d locked=%d skipped=%d low_block=%d jam=%d" % [
		_runs, _moved, int(_counts.get("wall", 0)), int(_counts.get("locked", 0)),
		int(_counts.get("skipped", 0)), int(_counts.get("low_block", 0)),
		int(_counts.get("jam", 0))])
	for line in _defects:
		print("[StairStuckTest] WEDGE %s" % line)
	print("[StairStuckTest] %s  checks=%d fails=%d" % [
		"ALL CLEAR" if _fails == 0 else "STUCK POINTS FOUND", _checks, _fails])
	print("[StairStuckTest] finished with %d failure(s)" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
