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
const LEDGE_STAMINA_COST := 4.0
const LEDGE_COOLDOWN := 0.9

var _survivor: Survivor
var _peak_y := 0.0
var ledge_grabs := 0                   # lifetime counter (tests/HUD)
var _ledge_cooldown := 0.0


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
## grab it and climb. Two lateral chest-height rays confirm a broad wall,
## a downward probe finds the lip. Returns true when a grab fired.
func _try_ledge_grab(move_dir: Vector3) -> void:
	if _ledge_cooldown > 0.0 or _survivor.stamina < LEDGE_STAMINA_COST:
		return
	if _survivor.velocity.y > LEDGE_FALL_SPEED_MIN:
		return
	var dir := move_dir if move_dir.length_squared() > 0.01 else _survivor.facing
	dir.y = 0.0
	dir = dir.normalized()
	if dir.length_squared() < 0.5:
		return
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
		return
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
		return
	if float(lip.normal.y) < LEDGE_SURFACE_NORMAL_Y:
		return
	var lip_y: float = lip.position.y
	var rise := lip_y - feet.y
	if rise < LEDGE_TOP_MIN or rise > LEDGE_REACH_ABOVE:
		return
	# GRAB: pay stamina, launch into the climb, reset fall peak so the
	# arrested descent does not charge fall damage.
	_survivor.stamina -= LEDGE_STAMINA_COST
	var need := rise + LEDGE_CLIMB_CLEARANCE
	var boost: float = sqrt(2.0 * _survivor.GRAVITY * need)
	boost = clampf(boost, LEDGE_CLIMB_BOOST_MIN, LEDGE_CLIMB_BOOST_MAX)
	_survivor.velocity.y = boost
	_survivor.velocity.x *= LEDGE_FORWARD_MULT
	_survivor.velocity.z *= LEDGE_FORWARD_MULT
	_ledge_cooldown = LEDGE_COOLDOWN
	_peak_y = _survivor.global_position.y
	ledge_grabs += 1


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