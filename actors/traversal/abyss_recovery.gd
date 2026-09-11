class_name AbyssRecovery
extends Node
## Anti-abyss safety net for every human character (player + NPC survivors).
##
## A character that falls OUT of the realized world - below the terrain datum,
## outside the world bounds, or straight through a chunk whose collision has not
## materialized yet - is put back on TOP of the surface, verified, instead of
## falling forever.
##
## CONTRACT (verified recovery, never a blind teleport):
##   1. The candidate column is the fall column first, then a deterministic
##      expanding ring of neighbours. Water, non-ACTIVE chunks and
##      plan-vs-collision surface mismatches are rejected using the SAME
##      walkable-ground (layer 8) contract as ChunkManager.verify_spawn_surface()
##      and SpawnPoints: only a materialized TerrainBody/RoadBody counts as
##      "the top side" - never a roof, wall, prop or water.
##   2. The 0.35 x 1.7 gameplay capsule must be CLEAR of structural collision
##      before the body is placed (anti-clipping gate); if the column is inside
##      geometry the position is lifted in bounded steps, then the next ring
##      candidate is tried.
##   3. While nothing verifies yet (chunk still streaming) the body is held
##      frozen - PROCESS_MODE_DISABLED, exactly like Main's spawn gate - instead
##      of accumulating gravity, and this guard keeps ticking
##      (PROCESS_MODE_ALWAYS) until the surface exists. A bounded timeout falls
##      back to the deterministic city-center spawn column.
##   4. Landing clears velocity, knockback, parkour fall tracking and locomotion
##      locks, so the recovered body cannot take phantom fall damage on the next
##      frame or stay stuck in a vault/hang/slide state.

## Emitted once per successful recovery (from, to, reason).
signal recovered(from: Vector3, to: Vector3, reason: StringName)

## Below this the character is definitively out of the world: the generation
## datum floor (TERRAIN_MIN_HEIGHT_M) minus a safety margin that clears the
## deepest legitimate feature (quarry -8 m, river bed -2.5 m, cave chambers -2 m
## relative to their entrance).
const ABYSS_MARGIN_M := 24.0
const ABYSS_FALL_Y := WorldConstants.TERRAIN_MIN_HEIGHT_M - ABYSS_MARGIN_M
## Grace beyond the world bounds (16 km square) before recovery triggers.
const BOUNDS_GRACE_M := 8.0

## Horizontal search rings (m) around the fall column, nearest first.
const CANDIDATE_RINGS: Array[float] = [0.0, 2.0, 4.0, 8.0, 16.0, 32.0]
const RING_DIRECTIONS := 8
## Bounded lifts (m) tried when the column is blocked by structure.
const LIFT_STEPS: Array[float] = [0.0, 0.5, 1.0, 2.0]
const GROUND_RAY_UP_M := 24.0
const GROUND_RAY_DOWN_M := 32.0
const SURFACE_TOL_M := 0.35
const CAPSULE_RADIUS := 0.35
const CAPSULE_HEIGHT := 1.7
## How long the body is held frozen waiting for a verified surface at the fall
## column before the deterministic city-center fallback is used. A fall inside
## the world resolves at ring 0 within one frame, so this only matters for a
## column that cannot exist (outside the world bounds).
const HOLD_TIMEOUT_S := 3.0
## Hard stop: after this the character is released at the best planned position
## in the fall column so it can never be frozen forever.
const HARD_RELEASE_S := 40.0
## Hover (m) above the planned datum used when the frozen body is relocated to
## the deterministic fallback column for streaming.
const FALLBACK_HOVER_M := 2.0

var recovery_count := 0
var last_reason: StringName = &""
var last_from := Vector3.ZERO
var last_position := Vector3.ZERO
var last_lift := 0.0
var attempts := 0

var _survivor: Survivor = null
var _resolving := false
var _held_time := 0.0
var _stall_reported := false
var _recover_from := Vector3.ZERO
var _recover_reason: StringName = &""


func setup(survivor: Survivor) -> void:
	_survivor = survivor


func _ready() -> void:
	# Keep ticking while the body itself is frozen (PROCESS_MODE_DISABLED is
	# inherited by children; ALWAYS opts this node out of that inheritance).
	process_mode = Node.PROCESS_MODE_ALWAYS


func _physics_process(delta: float) -> void:
	if _survivor == null or not is_instance_valid(_survivor) or not _survivor.is_inside_tree():
		return
	if _survivor.health == null or _survivor.health.is_dead:
		return
	if _resolving:
		_tick_resolution(delta)
		return
	# An external freeze (Main's spawn gate holds the player until its chunk has
	# collision) is not a fall: never fight it.
	if _survivor.process_mode == Node.PROCESS_MODE_DISABLED:
		return
	var pos: Vector3 = _survivor.global_position
	var reason := abyss_reason(pos)
	if reason != &"":
		_begin(reason, pos)


## True when this position is out of the world: non-finite, below the datum
## margin, or outside the world bounds.
static func abyss_reason(pos: Vector3) -> StringName:
	if not pos.is_finite():
		return &"non_finite"
	if pos.y < ABYSS_FALL_Y:
		return &"below_world"
	if pos.x < WorldConstants.WORLD_MIN_M - BOUNDS_GRACE_M \
			or pos.x > WorldConstants.WORLD_MAX_M + BOUNDS_GRACE_M \
			or pos.z < WorldConstants.WORLD_MIN_M - BOUNDS_GRACE_M \
			or pos.z > WorldConstants.WORLD_MAX_M + BOUNDS_GRACE_M:
		return &"outside_bounds"
	return &""


func _begin(reason: StringName, from: Vector3) -> void:
	_resolving = true
	_held_time = 0.0
	attempts = 0
	_stall_reported = false
	_recover_from = from
	_recover_reason = reason
	# Freeze the body: no further gravity accumulation while we look for the
	# surface, and no half-fallen physics state after the teleport.
	_survivor.velocity = Vector3.ZERO
	_survivor.stop_moving()
	_survivor.process_mode = Node.PROCESS_MODE_DISABLED


func _tick_resolution(delta: float) -> void:
	_held_time += delta
	attempts += 1
	var cm := _chunk_manager()
	var wp: WorldPlan = cm.world_plan if cm != null and cm.world_plan != null else null
	var space: PhysicsDirectSpaceState3D = null
	if _survivor.get_world_3d() != null:
		space = _survivor.get_world_3d().direct_space_state
	var origin := Vector2(_recover_from.x, _recover_from.z)
	if _held_time >= HOLD_TIMEOUT_S:
		# Nothing near the fall column verifies (e.g. the character left the
		# world bounds, where no chunk will ever exist). Move the frozen body -
		# and with it the streaming focus - to the deterministic city-center
		# spawn column and keep verifying THERE. The body stays frozen, so this
		# relocation can never become a fall.
		var anchor := _fallback_anchor(wp, cm)
		if anchor != Vector3.ZERO:
			var anchor_xz := Vector2(anchor.x, anchor.z)
			var here := Vector2(_survivor.global_position.x, _survivor.global_position.z)
			if here.distance_to(anchor_xz) > 1.0:
				_survivor.global_position = Vector3(anchor.x,
						anchor.y + FALLBACK_HOVER_M, anchor.z)
			origin = anchor_xz
	var res := find_recovery_position(space, wp, cm, origin)
	if not bool(res.get("ok", false)):
		if _held_time >= HARD_RELEASE_S:
			# Last resort: never leave a character frozen forever - but only
			# release when the column's chunk is actually materialized. If the
			# world is genuinely absent there (e.g. the whole area was streamed
			# out), releasing would just drop the body through empty space and
			# re-arm the guard, so the honest behaviour is to keep holding.
			if _column_active(cm, origin):
				var planned := wp.surface_height_at(origin) if wp != null else 0.0
				_apply({"position": Vector3(origin.x,
						planned + WorldConstants.SPAWN_FEET_CLEARANCE_M, origin.y),
						"lift": 0.0, "verified": false})
			elif not _stall_reported:
				_stall_reported = true
				print("[AbyssGuard] %s holding frozen: no walkable ground materialized at (%.1f, %.1f) after %.0f s"
						% [_survivor.name, origin.x, origin.y, _held_time])
		return
	_apply(res)


## True when the chunk owning this column is materialized.
func _column_active(cm: ChunkManager, xz: Vector2) -> bool:
	if cm == null or not cm.has_method(&"state_of"):
		return false
	return cm.state_of(WorldSeed.chunk_coord(xz.x, xz.y)) == &"active"


## Deterministic fallback column: the city-center spawn anchor.
func _fallback_anchor(wp: WorldPlan, cm: ChunkManager) -> Vector3:
	if wp == null:
		return Vector3.ZERO
	var city_plan: CityPlan = cm.plan if cm != null and cm.plan != null else null
	return SpawnPoints.get_spawn_position(&"city_center", wp, city_plan)


func _apply(res: Dictionary) -> void:
	var target: Vector3 = res.get("position", _survivor.global_position)
	var from := _recover_from
	_survivor.global_position = target
	# Clear every motion source before physics resumes: knockback, parkour peak
	# (no phantom fall damage for a fall that was cancelled), locomotion locks
	# and the capsule (a slid/crouched capsule would stand the body up inside
	# geometry).
	if _survivor.has_method(&"reset_motion_after_recovery"):
		_survivor.call(&"reset_motion_after_recovery", target.y)
	else:
		_survivor.velocity = Vector3.ZERO
	_survivor.process_mode = Node.PROCESS_MODE_INHERIT
	_resolving = false
	recovery_count += 1
	last_reason = _recover_reason
	last_from = from
	last_position = target
	last_lift = float(res.get("lift", 0.0))
	print("[AbyssGuard] %s recovered %s from (%.1f, %.1f, %.1f) -> (%.1f, %.1f, %.1f) lift=%.2f attempts=%d verified=%s"
			% [_survivor.name, String(_recover_reason), from.x, from.y, from.z,
			target.x, target.y, target.z, last_lift, attempts,
			str(res.get("verified", true))])
	recovered.emit(from, target, _recover_reason)


func _chunk_manager() -> ChunkManager:
	var managers := get_tree().get_nodes_in_group(&"chunk_manager")
	for node in managers:
		var cm := node as ChunkManager
		if cm != null and is_instance_valid(cm):
			return cm
	return null


# --- Static placement contract (also used directly by the harness) ------------

## Find a verified "top side" position for a character that fell out of the
## world at `origin_xz`. Returns {ok, position, ground_y, lift, verified,
## candidate, ground_body} or {ok=false, reason}.
##
## Two passes: first only feet-level (lift 0) placements across every ring, so a
## blocked column (inside a building) makes the search walk OUT to a real
## surface instead of floating the character 2 m above an obstruction; only if
## no ring offers a clean feet-level column are lifts allowed.
static func find_recovery_position(space: PhysicsDirectSpaceState3D, wp: WorldPlan,
		cm: ChunkManager, origin_xz: Vector2) -> Dictionary:
	if space == null or wp == null:
		return {"ok": false, "reason": "world unavailable"}
	for pass_index in 2:
		var allow_lift := pass_index == 1
		for ring: float in CANDIDATE_RINGS:
			var count := 1 if ring <= 0.0 else RING_DIRECTIONS
			for i in count:
				var angle := TAU * float(i) / float(RING_DIRECTIONS)
				var cand := origin_xz + Vector2(cos(angle), sin(angle)) * ring
				var res := _probe_candidate(space, wp, cm, cand, allow_lift)
				if bool(res.get("ok", false)):
					res["candidate"] = cand
					res["ring"] = ring
					return res
	return {"ok": false, "reason": "no verified surface"}


## Verify one column: inside world, not water, chunk ACTIVE, walkable-ground
## collision at the planned surface, and a clear gameplay capsule. With
## `allow_lift` false the capsule must be clear AT THE SURFACE (a real place to
## stand); with it true the position may be lifted in bounded steps.
static func _probe_candidate(space: PhysicsDirectSpaceState3D, wp: WorldPlan,
		cm: ChunkManager, cand: Vector2, allow_lift := true) -> Dictionary:
	if not WorldConstants.is_inside_world(cand):
		return {"ok": false, "reason": "outside world"}
	if wp.water_body_at(cand) != &"":
		return {"ok": false, "reason": "water"}
	if cm != null and cm.has_method(&"state_of"):
		var coord := WorldSeed.chunk_coord(cand.x, cand.y)
		if cm.state_of(coord) != &"active":
			return {"ok": false, "reason": "chunk not active"}
	var planned: float = wp.surface_height_at(cand)
	var from := Vector3(cand.x, planned + GROUND_RAY_UP_M, cand.y)
	var to := Vector3(cand.x, planned - GROUND_RAY_DOWN_M, cand.y)
	var q := PhysicsRayQueryParameters3D.create(
			from, to, WorldConstants.COLLISION_WALKABLE_GROUND)
	q.collide_with_bodies = true
	q.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return {"ok": false, "reason": "no walkable ground"}
	var body := hit.get("collider") as StaticBody3D
	if body == null or body.name not in [&"TerrainBody", &"RoadBody"]:
		return {"ok": false, "reason": "non-ground collider"}
	var ground_y: float = (hit.get("position", Vector3.ZERO) as Vector3).y
	if absf(ground_y - planned) > SURFACE_TOL_M:
		return {"ok": false, "reason": "surface mismatch",
				"planned_y": planned, "surface_y": ground_y}
	var feet_y := ground_y + WorldConstants.SPAWN_FEET_CLEARANCE_M
	if not allow_lift:
		if capsule_clear(space, Vector3(cand.x, feet_y, cand.y), [body.get_rid()]):
			return {"ok": true, "position": Vector3(cand.x, feet_y, cand.y),
					"ground_y": ground_y, "lift": 0.0, "verified": true,
					"ground_body": String(body.name)}
		return {"ok": false, "reason": "capsule blocked"}
	for lift: float in LIFT_STEPS:
		var at := Vector3(cand.x, feet_y + lift, cand.y)
		if capsule_clear(space, at, [body.get_rid()]):
			return {"ok": true, "position": at, "ground_y": ground_y,
					"lift": lift, "verified": true,
					"ground_body": String(body.name)}
	return {"ok": false, "reason": "capsule blocked"}


## True when a standing gameplay capsule at `at` overlaps no structural
## collision (layer 1). Ground bodies must be passed in `exclude` so the floor
## itself is not mistaken for an obstruction.
static func capsule_clear(space: PhysicsDirectSpaceState3D, at: Vector3,
		exclude: Array = []) -> bool:
	if space == null:
		return false
	var capsule := CapsuleShape3D.new()
	capsule.radius = CAPSULE_RADIUS
	capsule.height = CAPSULE_HEIGHT
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = capsule
	q.transform = Transform3D(Basis.IDENTITY, at + Vector3(0, CAPSULE_HEIGHT * 0.5, 0))
	q.collision_mask = 1
	q.exclude = exclude
	q.collide_with_bodies = true
	q.collide_with_areas = false
	return space.intersect_shape(q, 1).is_empty()
