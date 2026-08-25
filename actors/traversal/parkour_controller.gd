class_name ParkourController
extends Node
## Jump intent + fall-damage tracking + vault/mantle + ledge grab for one Survivor body.
##
## Phase E slice 1: jump + fall damage. Phase E slice 2: knee/waist/head ray
## casts for automatic vault (knee hit, waist clear) and mantle (knee+waist hit,
## head clear) on low obstacles. Phase E slice 3: while falling, chest-height
## horizontal probes detect a broad wall face; a downward probe finds a ledge
## lip within arm reach (0.9-2.1 m above feet). If found, climb boost is applied
## and _peak_y is reset so the arrested fall does not inflict fall damage.
## Phase F: every successful grab emits ledge_grabbed(is_building) - the
## player's HUD flashes a cue - and a short assisted horizontal drive carries
## the body OVER the lip onto the surface (deterministic rooftop mantles when
## the grabbed wall is batched building structure, detected via the
## vox_material collider meta stamped by MeshBatcher.flush_into).
## Phase F slice 2: a radial compass fan finds graspable lips in ANY direction
## (NPCs chased off rooftops flee with their back to the parapet), and the
## stamina cost scales with lip height instead of being flat.

const JUMP_SPEED := 6.4                # apex ~1.14 m: clears crates, not walls
const JUMP_STAMINA_COST := 6.0
const FALL_SAFE_HEIGHT := 3.5          # meters: no damage within this drop
const FALL_DAMAGE_PER_M := 9.0         # damage per meter beyond safe height

# Vault/mantle probe geometry (capsule radius=0.35, height=1.7, center_y=0.85)
const PROBE_KNEE_HEIGHT := 0.5         # y from feet
const PROBE_WAIST_HEIGHT := 1.0        # y from feet
const PROBE_HEAD_HEIGHT := 1.6         # y from feet
const PROBE_FORWARD_DIST := 1.0        # meters ahead of capsule center
const VAULT_UPWARD_BOOST := 4.5        # velocity.y added for vault
const VAULT_FORWARD_BOOST := 1.3       # velocity.xz multiplier for vault
const MANTLE_UPWARD_BOOST := 6.0       # velocity.y added for mantle
const MANTLE_FORWARD_BOOST := 1.2      # velocity.xz multiplier for mantle

# Ledge-grab probes (Phase E slice 3): catch a ledge top while falling.
const LEDGE_FALL_SPEED_MIN := -0.5     # must be descending
const LEDGE_PROBE_HEIGHT := 1.2        # chest height from feet
const LEDGE_PROBE_OFFSET := 0.18       # lateral offset of left/right probes
const LEDGE_PROBE_REACH := 0.62        # forward ray length (radius 0.35 + margin)
const LEDGE_TOP_MIN := 0.9             # ledge must sit at least this far above feet
const LEDGE_REACH_ABOVE := 2.1         # arm reach: max ledge height above feet
const LEDGE_SURFACE_NORMAL_Y := 0.6    # down-probe must find a top surface
const LEDGE_CLIMB_CLEARANCE := 0.35    # extra rise beyond the ledge lip
const LEDGE_CLIMB_BOOST_MIN := 4.5
const LEDGE_CLIMB_BOOST_MAX := 9.5
const LEDGE_FORWARD_MULT := 1.35
const LEDGE_COOLDOWN := 0.9
# Phase F slice 2: pull-up effort scales with lip height (cheap low lips,
# demanding full-reach lips) - an exhausted survivor can still catch a low
# cornice but cannot chain maximum-reach mantles for free.
const LEDGE_STAMINA_COST_LOW := 2.0   # lip at LEDGE_TOP_MIN above the feet
const LEDGE_STAMINA_COST_HIGH := 6.0  # lip at full LEDGE_REACH_ABOVE
# Radial ledge-seek: when the intended move/facing direction finds no wall,
# sweep this many evenly spaced compass rays for any graspable lip. Survivors
# chased off an edge (facing AWAY from the building) still catch the parapet
# they are falling alongside - NPC zombie-chase escape hatch.
const LEDGE_SEEK_RAYS := 8

# Climb follow-through (Phase F): after a grab, briefly steer horizontal
# velocity toward the wall so the body lands ON the ledge, not back at its base.
const CLIMB_FOLLOW_TIME := 0.6         # seconds of assisted drive after a grab
const CLIMB_FOLLOW_STEER := 12.0       # lerp rate toward the drive velocity
const CLIMB_DRIVE_SPEED := 2.2         # m/s toward a plain crate/box ledge
const CORNICE_DRIVE_SPEED := 3.0       # stronger drive onto building rooftops

## Fires on every successful ledge grab. is_building is true when the grabbed
## wall belongs to batched city structure (vox_material == &"concrete"), i.e.
## the survivor mantled onto a rooftop/cornice rather than a crate.
signal ledge_grabbed(is_building: bool)

var _survivor: Survivor
var _peak_y := 0.0
var ledge_grabs := 0                   # lifetime counter (tests/HUD)
var rooftop_mantles := 0               # grabs that mounted batched structure
var last_grab_was_building := false    # HUD/test readout of the latest grab
var last_stamina_cost := 0.0           # stamina charged by the latest grab
var _ledge_cooldown := 0.0
var _climb_time_left := -1.0           # follow-through window (< 0 = idle)
var _climb_dir := Vector3.ZERO
var _climb_speed := 0.0


## Wire to the owning body. Call once, right after add_child().
func setup(survivor: Survivor) -> void:
	_survivor = survivor
	_peak_y = survivor.global_position.y


## Called by PlayerController once per jump-input press.
func try_jump() -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if not _survivor.is_on_floor():
		return
	if _survivor.needs.sleeping or _survivor.exhausted:
		return
	if _survivor.stamina < JUMP_STAMINA_COST:
		return
	_survivor.stamina -= JUMP_STAMINA_COST
	_survivor.velocity.y = JUMP_SPEED


## Vault/mantle/ledge-grab probes: call from Survivor._physics_process BEFORE move_and_slide().
## Detects obstacles ahead in move_dir; grounded -> vault/mantle, airborne -> ledge grab.
func process_traversal(move_dir: Vector3, delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	_ledge_cooldown = maxf(0.0, _ledge_cooldown - delta)
	_tick_climb_follow(delta)
	if not _survivor.is_on_floor():
		_try_ledge_grab(move_dir)
		return
	if move_dir.length_squared() < 0.01:
		return
	# Only act when moving forward relative to facing (dot > 0.7)
	if move_dir.dot(_survivor.facing) < 0.7:
		return

	var space := _survivor.get_world_3d().direct_space_state
	var feet_y := _survivor.global_position.y
	var origin_base := _survivor.global_position + _survivor.facing * PROBE_FORWARD_DIST

	# Three horizontal ray casts at knee, waist, head heights
	var hit_knee: Dictionary
	var hit_waist: Dictionary
	var hit_head: Dictionary
	for h in [PROBE_KNEE_HEIGHT, PROBE_WAIST_HEIGHT, PROBE_HEAD_HEIGHT]:
		var org := Vector3(origin_base.x, feet_y + h, origin_base.z)
		var q := PhysicsRayQueryParameters3D.create(org, org + _survivor.facing * 0.3)
		q.exclude = [_survivor]
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if h == PROBE_KNEE_HEIGHT:
			hit_knee = hit
		elif h == PROBE_WAIST_HEIGHT:
			hit_waist = hit
		else:
			hit_head = hit

	# V VAULT: knee blocked, waist clear -> hop up and forward
	if not hit_knee.is_empty() and hit_waist.is_empty():
		_survivor.velocity.y = VAULT_UPWARD_BOOST
		_survivor.velocity.x *= VAULT_FORWARD_BOOST
		_survivor.velocity.z *= VAULT_FORWARD_BOOST
		return

	# MANTLE: knee + waist blocked, head clear -> climb up
	if not hit_knee.is_empty() and not hit_waist.is_empty() and hit_head.is_empty():
		_survivor.velocity.y = MANTLE_UPWARD_BOOST
		_survivor.velocity.x *= MANTLE_FORWARD_BOOST
		_survivor.velocity.z *= MANTLE_FORWARD_BOOST
		return


## Falling alongside a wall whose graspable top is within arm reach ->
## grab it and climb. The intended move/facing direction is probed first;
## if no broad wall is found there, a radial compass fan sweeps for any
## graspable lip - an NPC chased off an edge (back to the building) still
## catches the parapet it is falling alongside.
func _try_ledge_grab(move_dir: Vector3) -> void:
	if _ledge_cooldown > 0.0 or _survivor.exhausted:
		return
	if _survivor.velocity.y > LEDGE_FALL_SPEED_MIN:
		return
	var primary := move_dir if move_dir.length_squared() > 0.01 else _survivor.facing
	primary.y = 0.0
	primary = primary.normalized()
	if primary.length_squared() < 0.5:
		return
	# Phase F slice 2: intended direction first (unchanged behaviour for
	# intentional grabs), then evenly spaced fallback rays around the body.
	var dirs: Array[Vector3] = [primary]
	for i in range(1, LEDGE_SEEK_RAYS):
		var ang := TAU * float(i) / float(LEDGE_SEEK_RAYS)
		dirs.append(Vector3(cos(ang), 0.0, sin(ang)))
	for d in dirs:
		var probe := _probe_ledge(d)
		if probe.is_empty():
			continue
		if _commit_grab(d, probe["wall"], probe["rise"]):
			return


## Ray probes for one direction: two lateral chest-height rays confirm a
## broad wall face, then a downward probe finds the lip. Returns
## {"wall": Dictionary, "rise": float} or {} when nothing is graspable here.
func _probe_ledge(dir: Vector3) -> Dictionary:
	var space := _survivor.get_world_3d().direct_space_state
	var feet := _survivor.global_position
	var side := Vector3(-dir.z, 0.0, dir.x)
	var chest_org := Vector3(feet.x, feet.y + LEDGE_PROBE_HEIGHT, feet.z)
	var wall_hit := {}
	for off: float in [-LEDGE_PROBE_OFFSET, LEDGE_PROBE_OFFSET]:
		var org := chest_org + side * off
		var q := PhysicsRayQueryParameters3D.create(org, org + dir * LEDGE_PROBE_REACH)
		q.exclude = [_survivor]
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			wall_hit = hit
			break
	if wall_hit.is_empty():
		return {}
	# Downward probe from above expected reach to find the ledge lip.
	var push := dir * 0.45
	var start_x: float = float(wall_hit.position.x) + push.x
	var start_z: float = float(wall_hit.position.z) + push.z
	var start_y := feet.y + LEDGE_REACH_ABOVE + 0.1
	var end_y := feet.y + LEDGE_TOP_MIN - 0.05
	var q2 := PhysicsRayQueryParameters3D.create(
		Vector3(start_x, start_y, start_z),
		Vector3(start_x, end_y, start_z))
	q2.exclude = [_survivor]
	q2.collide_with_areas = false
	var lip := space.intersect_ray(q2)
	if lip.is_empty():
		return {}
	if float(lip.normal.y) < LEDGE_SURFACE_NORMAL_Y:
		return {}
	var rise := float(lip.position.y) - feet.y
	if rise < LEDGE_TOP_MIN or rise > LEDGE_REACH_ABOVE:
		return {}
	return {"wall": wall_hit, "rise": rise}


## Apply a confirmed grab in direction dir. Returns false (no side effects)
## when the survivor lacks the stamina this particular lip demands.
func _commit_grab(dir: Vector3, wall_hit: Dictionary, rise: float) -> bool:
	var cost := _ledge_stamina_cost(rise)
	if _survivor.stamina < cost:
		return false
	# GRAB: pay stamina, launch into the climb, reset fall peak so the
	# arrested descent does not charge fall damage.
	_survivor.stamina -= cost
	last_stamina_cost = cost
	var need := rise + LEDGE_CLIMB_CLEARANCE
	var boost: float = sqrt(2.0 * _survivor.GRAVITY * need)
	boost = clampf(boost, LEDGE_CLIMB_BOOST_MIN, LEDGE_CLIMB_BOOST_MAX)
	_survivor.velocity.y = boost
	_survivor.velocity.x *= LEDGE_FORWARD_MULT
	_survivor.velocity.z *= LEDGE_FORWARD_MULT
	_ledge_cooldown = LEDGE_COOLDOWN
	_peak_y = _survivor.global_position.y
	ledge_grabs += 1
	# Phase F: classify the wall (batched building structure vs plain prop),
	# announce it, and arm the assisted drive that carries us over the lip.
	var is_building := _hit_is_concrete(wall_hit)
	last_grab_was_building = is_building
	if is_building:
		rooftop_mantles += 1
	_climb_dir = dir
	_climb_speed = CORNICE_DRIVE_SPEED if is_building else CLIMB_DRIVE_SPEED
	_climb_time_left = CLIMB_FOLLOW_TIME
	ledge_grabbed.emit(is_building)
	return true


## Pull-up stamina demand for a lip `rise` meters above the feet: linearly
## between LEDGE_STAMINA_COST_LOW at LEDGE_TOP_MIN and LEDGE_STAMINA_COST_HIGH
## at LEDGE_REACH_ABOVE (clamped outside the window).
func _ledge_stamina_cost(rise: float) -> float:
	var t := clampf(
			(rise - LEDGE_TOP_MIN)
					/ maxf(0.001, LEDGE_REACH_ABOVE - LEDGE_TOP_MIN),
			0.0, 1.0)
	return lerpf(LEDGE_STAMINA_COST_LOW, LEDGE_STAMINA_COST_HIGH, t)


## True when a ray hit's shape belongs to batched building structure. Walls,
## parapets and bulkheads are emitted as destructible cells carrying the
## vox_material meta (see MeshBatcher.flush_into); plain props, ground slabs
## and ad-hoc test boxes have no such meta.
func _hit_is_concrete(hit: Dictionary) -> bool:
	var collider: Object = hit.get("collider")
	if not (collider is CollisionObject3D):
		return false
	var body := collider as CollisionObject3D
	var shape_idx := int(hit.get("shape", -1))
	if shape_idx < 0:
		return false
	var shape_node := body.shape_owner_get_owner(
			body.shape_find_owner(shape_idx)) as CollisionShape3D
	if shape_node == null:
		return false
	return StringName(shape_node.get_meta("vox_material", &"")) == &"concrete"


## Phase F follow-through: for a short window after a grab, steer horizontal
## velocity toward the grabbed wall so the ballistic arc lands ON the ledge
## top instead of dropping back at its base. Ends early on touchdown.
func _tick_climb_follow(delta: float) -> void:
	if _climb_time_left < 0.0 or _survivor == null:
		return
	_climb_time_left -= delta
	if _climb_time_left < 0.0 or _survivor.is_on_floor():
		_climb_time_left = -1.0
		return
	var target := _climb_dir * _climb_speed
	var k: float = minf(1.0, CLIMB_FOLLOW_STEER * delta)
	_survivor.velocity.x = lerpf(_survivor.velocity.x, target.x, k)
	_survivor.velocity.z = lerpf(_survivor.velocity.z, target.z, k)


## Track airtime peaks; charge fall damage on hard landings.
## Call from Survivor._physics_process AFTER move_and_slide().
func tick(_delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if _survivor.is_on_floor():
		var drop := _peak_y - _survivor.global_position.y
		if drop > FALL_SAFE_HEIGHT:
			_survivor.take_damage(
				(drop - FALL_SAFE_HEIGHT) * FALL_DAMAGE_PER_M, &"fall")
		_peak_y = _survivor.global_position.y
	else:
		_peak_y = maxf(_peak_y, _survivor.global_position.y)