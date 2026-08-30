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
## Phase M: grabs on feature-tagged shapes (vox_tag meta stamped by
## MeshBatcher.flush_into, e.g. &"awning" street canopies) are classified
## separately - awning_grabs counts them, last_grab_was_awning reports the
## latest, and the follow-through uses a gentler canvas-deck drive speed so
## ground-floor awning chains read as soft, forgiving parkour.

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

# P-C4 wall-run constants
const WALL_DIST_MIN := 0.35
const WALL_DIST_MAX := 0.45
const WALL_HEIGHT_MIN := 2.2
const WALL_LEN_MIN := 3.5
const WALL_YAW_MAX := 35.0
const WALL_FLAT_MAX := 0.08
const WALL_PROBE_HEIGHT := 1.2
const WALL_PROBE_REACH := 0.45
const WALLRUN_SPEED_MIN := 3.2

# P-C2 vault/mantle/hang geometry (ACTIVE-only, reuse balcony/awning/cornice/parapet boxes)
const P2_VAULT_MIN := 0.6
const P2_VAULT_MAX := 0.95
const P2_MANTLE_MIN := 0.9
const P2_MANTLE_MAX := 1.2
const P2_LEDGE_MIN := 1.6
const P2_LEDGE_MAX := 2.2
const P2_HAND_SNAP := 0.04

# Climb follow-through (Phase F): after a grab, briefly steer horizontal
# velocity toward the wall so the body lands ON the ledge, not back at its base.
const CLIMB_FOLLOW_TIME := 0.6         # seconds of assisted drive after a grab
const CLIMB_FOLLOW_STEER := 12.0       # lerp rate toward the drive velocity
const CLIMB_DRIVE_SPEED := 2.2         # m/s toward a plain crate/box ledge
const CORNICE_DRIVE_SPEED := 3.0       # stronger drive onto building rooftops
const AWNING_DRIVE_SPEED := 2.6        # canvas deck: firm but forgiving assist

## Fires on every successful ledge grab. is_building is true when the grabbed
## wall belongs to batched city structure (vox_material == &"concrete"), i.e.
## the survivor mantled onto a rooftop/cornice rather than a crate.
signal ledge_grabbed(is_building: bool)

var _survivor: Survivor
var _peak_y := 0.0
var ledge_grabs := 0                   # lifetime counter (tests/HUD)
var rooftop_mantles := 0               # grabs that mounted batched structure
var last_grab_was_building := false    # HUD/test readout of the latest grab
var last_grab_was_awning := false      # latest grab hit a feature-tagged awning
var awning_grabs := 0                  # lifetime counter of awning grabs
var last_stamina_cost := 0.0           # stamina charged by the latest grab
var _vault_probe: Dictionary = {}
var _mantle_probe: Dictionary = {}
var _ledge_probe: Dictionary = {}
var _wall_probe: Dictionary = {}
var _shimmy_probe: Dictionary = {}
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

	# Clear previous P-C2 probes
	_vault_probe = {}
	_mantle_probe = {}
	_ledge_probe = {}
	_wall_probe = {}
	_shimmy_probe = {}

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

	# Determine if survivor has new locomotion (P-C2 state lock) - if so, store probes instead of instant boost
	var has_locomotion: bool = false
	if _survivor.has_method("get_locomotion"):
		var loco = _survivor.get_locomotion()
		if loco != null and is_instance_valid(loco):
			has_locomotion = true

	# V VAULT: knee blocked, waist clear -> P-C2 probe or legacy boost
	if not hit_knee.is_empty() and hit_waist.is_empty():
		# Estimate vault height as ~0.75 mid of vault range; refine via hit position if available
		var vault_h: float = 0.75
		if not hit_knee.is_empty():
			vault_h = clamp(float(hit_knee.position.y) - feet_y + 0.25, P2_VAULT_MIN, P2_VAULT_MAX)
			if vault_h < P2_VAULT_MIN:
				vault_h = 0.75
		_vault_probe = {"height": vault_h, "distance": PROBE_FORWARD_DIST, "has_hit": true, "hit_knee": hit_knee, "hit_waist": hit_waist}
		# Capsule sweep for arc: ensure no penetration (simplified - assume clear if no head hit)
		var sweep_ok: bool = hit_head.is_empty()
		if has_locomotion and sweep_ok:
			return
		if not has_locomotion:
			_survivor.velocity.y = VAULT_UPWARD_BOOST
			_survivor.velocity.x *= VAULT_FORWARD_BOOST
			_survivor.velocity.z *= VAULT_FORWARD_BOOST
		return

	# Wall-run probe (P-C4): when sprinting and moving, check lateral walls
	_try_wall_probe(move_dir)
	# MANTLE: knee + waist blocked, head clear -> climb up
	if not hit_knee.is_empty() and not hit_waist.is_empty() and hit_head.is_empty():
		var mantle_h: float = 1.1
		if not hit_waist.is_empty():
			mantle_h = clamp(float(hit_waist.position.y) - feet_y + 0.1, P2_MANTLE_MIN, P2_MANTLE_MAX)
			if mantle_h < P2_MANTLE_MIN:
				mantle_h = 1.1
		# Also try to find ledge pos for mantle top
		var ledge_at: Vector3 = Vector3.ZERO
		if not hit_waist.is_empty():
			ledge_at = hit_waist.position + Vector3(0, 0.15, 0)
		_mantle_probe = {"height": mantle_h, "distance": PROBE_FORWARD_DIST, "has_hit": true, "ledge_pos": ledge_at, "ledge_normal": -_survivor.facing}
		if has_locomotion:
			return
		_survivor.velocity.y = MANTLE_UPWARD_BOOST
		_survivor.velocity.x *= MANTLE_FORWARD_BOOST
		_survivor.velocity.z *= MANTLE_FORWARD_BOOST
		return


func _try_wall_probe(move_dir: Vector3) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	if move_dir.length_squared() < 0.01:
		return
	var space := _survivor.get_world_3d().direct_space_state
	if space == null:
		return
	var facing: Vector3 = _survivor.facing
	if facing.length_squared() < 0.1:
		return
	var speed: float = Vector2(_survivor.velocity.x, _survivor.velocity.z).length()
	# Need sprint and speed >=3.2 to be eligible, but still store probe for gate check
	var probe_side := ""
	var best_hit: Dictionary = {}
	var best_dist: float = 1.0
	var best_normal: Vector3 = Vector3.ZERO
	var best_side: String = ""
	for side_mul in [-1.0, 1.0]:
		var side_dir: Vector3 = Vector3(-facing.z, 0, facing.x) * side_mul
		var origin: Vector3 = _survivor.global_position + Vector3(0, WALL_PROBE_HEIGHT, 0)
		var q := PhysicsRayQueryParameters3D.create(origin, origin + side_dir * WALL_PROBE_REACH)
		q.exclude = [_survivor]
		q.collide_with_areas = false
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var dist: float = origin.distance_to(hit.position as Vector3)
			if dist >= WALL_DIST_MIN - 0.05 and dist <= WALL_DIST_MAX + 0.05:
				if dist < best_dist:
					best_dist = dist
					best_hit = hit
					best_normal = hit.normal as Vector3
					best_side = "L" if side_mul < 0 else "R"
	if best_hit.is_empty():
		return
	# Height check: 3 vertical samples
	var wall_pos: Vector3 = best_hit.position as Vector3
	var wall_normal: Vector3 = best_normal
	var hits_height: int = 0
	for h in [0.5, 1.2, 1.9]:
		var org_h: Vector3 = wall_pos + Vector3(0, h - 1.2, 0) + wall_normal * 0.15
		var qh := PhysicsRayQueryParameters3D.create(org_h, org_h - wall_normal * 0.3)
		qh.exclude = [_survivor]
		qh.collide_with_areas = false
		qh.collision_mask = 1
		var hh := space.intersect_ray(qh)
		if not hh.is_empty():
			hits_height += 1
	if hits_height < 2:
		return
	var height_est: float = 2.5 if hits_height == 3 else 2.2
	# Length check: 2 horizontal rays at ends
	var tangent: Vector3 = wall_normal.cross(Vector3.UP).normalized()
	if tangent.length() < 0.1:
		tangent = Vector3(1,0,0)
	var hits_len: int = 0
	for off in [-1.7, 1.7]:
		var org_l: Vector3 = wall_pos + tangent * off + Vector3(0, 0, 0) + wall_normal * 0.15
		var ql := PhysicsRayQueryParameters3D.create(org_l, org_l - wall_normal * 0.3)
		ql.exclude = [_survivor]
		ql.collide_with_areas = false
		ql.collision_mask = 1
		var hl := space.intersect_ray(ql)
		if not hl.is_empty():
			hits_len += 1
	if hits_len < 1:
		return
	var length_est: float = 4.0 if hits_len == 2 else 3.5
	# Flatness: sample normal variance at 0.5 intervals
	var flat_ok: bool = true
	var first_n: Vector3 = wall_normal
	for off2 in [-1.0, 0.0, 1.0]:
		var org_f: Vector3 = wall_pos + tangent * off2 + Vector3(0, 0, 0) + wall_normal * 0.15
		var qf := PhysicsRayQueryParameters3D.create(org_f, org_f - wall_normal * 0.3)
		qf.exclude = [_survivor]
		qf.collide_with_areas = false
		qf.collision_mask = 1
		var hf := space.intersect_ray(qf)
		if not hf.is_empty():
			var n2: Vector3 = hf.normal as Vector3
			if n2.distance_to(first_n) > WALL_FLAT_MAX:
				flat_ok = false
				break
	if not flat_ok:
		return
	# Yaw check
	var wall_tangent: Vector3 = tangent
	var facing_flat: Vector3 = Vector3(facing.x, 0, facing.z).normalized()
	var tangent_flat: Vector3 = Vector3(wall_tangent.x, 0, wall_tangent.z).normalized()
	var yaw: float = rad_to_deg(abs(acos(clampf(facing_flat.dot(tangent_flat), -1.0, 1.0))))
	# yaw_to_wall is angle between facing and wall_tangent, need <35; our yaw is between facing and tangent, but wall parallel so facing should be ~30deg off parallel
	# Convert to yaw_to_wall as min(yaw, 180-yaw) to get smallest angle to wall line
	yaw = min(yaw, 180.0 - yaw)
	# Build wall probe dict
	_wall_probe = {"wall_pos": wall_pos, "wall_normal": wall_normal, "wall_tangent": wall_tangent, "wall_side": best_side, "wall_height": height_est, "wall_length": length_est, "wall_dist": best_dist, "yaw_to_wall": yaw, "flat": 0.02, "has_hit": true}
	# Shimmy probe: if ledge nearby, estimate length
	var ledge_rise: float = 1.9
	var shim_len: float = 3.5
	# Simple shimmy eligibility: if wall exists and ledge probe has hit with length >=2, provide shimmy
	if not _ledge_probe.is_empty() and bool(_ledge_probe.get("has_hit", false)):
		var ll: float = float(_ledge_probe.get("ledge_length", _ledge_probe.get("wall_length", 2.5)))
		if ll >= 2.0:
			_shimmy_probe = {"ledge_pos": _ledge_probe.get("ledge_pos", Vector3.ZERO), "ledge_normal": _ledge_probe.get("ledge_normal", Vector3(0,0,-1)), "ledge_length": ll, "has_hit": true}
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
	# P-C2: check if has locomotion to store ledge probe instead of instant grab
	var has_locomotion: bool = false
	if _survivor.has_method("get_locomotion"):
		var loco = _survivor.get_locomotion()
		if loco != null and is_instance_valid(loco):
			has_locomotion = true
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
		# P-C2: store ledge probe for locomotion HANG
		var wall: Dictionary = probe["wall"]
		var rise: float = float(probe["rise"])
		# Build ledge_probe dict for locomotion
		var lip_pos: Vector3 = Vector3.ZERO
		var lip_norm: Vector3 = Vector3(0,1,0)
		if wall.has("position"):
			# Use wall hit position plus small offset for lip
			lip_pos = wall.position as Vector3
			# Try to get lip height from rise
			lip_pos.y = _survivor.global_position.y + rise
		if wall.has("normal"):
			lip_norm = -d
		_ledge_probe = {"rise": rise, "ledge_pos": lip_pos, "ledge_normal": lip_norm, "has_hit": true, "wall": wall, "dir": d}
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
	# Phase M: feature-tagged grabs (street awnings today) count as their
	# own soft-structure class - gentler follow-through than a concrete
	# cornice, own lifetime counter for tests/HUD.
	last_grab_was_awning = _hit_vox_tag(wall_hit) == &"awning"
	if last_grab_was_awning:
		awning_grabs += 1
	_climb_dir = dir
	_climb_speed = CORNICE_DRIVE_SPEED if is_building else CLIMB_DRIVE_SPEED
	if last_grab_was_awning:
		_climb_speed = AWNING_DRIVE_SPEED
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
	return _hit_meta(hit, "vox_material") == &"concrete"


## Phase M: feature tag stamped by MeshBatcher.flush_into (vox_tag meta,
## e.g. &"awning") - lets traversal classify WHAT it grabbed. &"" when the
## shape carries no tag (plain props, untagged structure, test boxes).
func _hit_vox_tag(hit: Dictionary) -> StringName:
	return _hit_meta(hit, "vox_tag")


func wallrun_sweep_ok(start: Vector3, end: Vector3) -> bool:
	if _survivor == null or _survivor.get_world_3d() == null:
		return true
	var space := _survivor.get_world_3d().direct_space_state
	if space == null:
		return true
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.7
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.collision_mask = 1
	params.exclude = [_survivor.get_rid()]
	var dir: Vector3 = (end - start).normalized()
	var dist: float = start.distance_to(end)
	var steps: int = int(dist / 0.5) + 1
	for i in steps:
		var t: float = float(i) / float(max(1, steps-1))
		var pos: Vector3 = start.lerp(end, t) + Vector3(0, 0.85, 0)
		params.transform = Transform3D(Basis.IDENTITY, pos)
		var hits: Array = space.intersect_shape(params, 1)
		if not hits.is_empty():
			return false
	return true

## Shared shape-meta lookup for a physics ray hit: resolves the hit's
## CollisionShape3D and reads one StringName meta (&"" when absent).
func _hit_meta(hit: Dictionary, meta: String) -> StringName:
	var collider: Object = hit.get("collider")
	if not (collider is CollisionObject3D):
		return &""
	var body := collider as CollisionObject3D
	var shape_idx := int(hit.get("shape", -1))
	if shape_idx < 0:
		return &""
	var shape_node := body.shape_owner_get_owner(
			body.shape_find_owner(shape_idx)) as CollisionShape3D
	if shape_node == null:
		return &""
	return StringName(shape_node.get_meta(meta, &""))


# P-C2 probe accessors for CharacterLocomotion
func get_vault_probe() -> Dictionary:
	return _vault_probe

func get_mantle_probe() -> Dictionary:
	return _mantle_probe

func get_ledge_probe() -> Dictionary:
	return _ledge_probe

func get_wall_probe() -> Dictionary:
	return _wall_probe

func get_shimmy_probe() -> Dictionary:
	return _shimmy_probe

func clear_probes() -> void:
	_vault_probe = {}
	_mantle_probe = {}
	_ledge_probe = {}
	_wall_probe = {}
	_shimmy_probe = {}


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