class_name ParkourController
extends Node
## Jump intent + fall-damage tracking + vault/mantle for one Survivor body.
##
## Phase E slice 1: jump + fall damage. Phase E slice 2: knee/waist/head ray
## casts for automatic vault (knee hit, waist clear) and mantle (knee+waist hit,
## head clear) on low obstacles. No trigger volumes — pure geometry probes.

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

var _survivor: Survivor
var _peak_y := 0.0


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


## Vault/mantle probes: call from Survivor._physics_process BEFORE move_and_slide().
## Detects knee/waist/head obstacles ahead in move_dir; applies velocity boosts.
func process_traversal(move_dir: Vector3, _delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if not _survivor.is_on_floor():
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
