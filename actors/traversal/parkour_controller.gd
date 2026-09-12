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
# ANTI-STUCK: a grab may only arm after a *genuine* airborne moment. Stepping
# off a stair lip or the head of a flight leaves the floor for a few frames and
# used to latch the player onto the stair edge (HUD "Grabs"), which was a trap.
const LEDGE_MIN_AIR_TIME := 0.30
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

# --- Q2: verified feature holds -------------------------------------------
# A tag CLASSIFIES a hold; the shape's own box geometry VERIFIES it. Every tag
# here is a feature the generator emits as *colliding* structure (see
# BuildingBuilder: cornices, parapets, balconies, scaffolding, bulkhead
# plant/exit boxes). Thin decorative trim is deliberately absent: geometry
# alone must never turn a 0.06 m moulding into a handhold.
const CLIMBABLE_TAGS := [
	&"cornice", &"parapet", &"balcony", &"scaffold", &"awning", &"tower",
	&"pilaster", &"bhplant", &"bhexit", &"bhladder", &"band",
]
const HOLD_CLASS_SLAB := &"slab"       # top surface deep enough to stand on
const HOLD_CLASS_BAR := &"bar"         # slender lip: hang + shimmy only
const HOLD_DEPTH_MIN_SLAB := 0.14      # usable depth for a standable hold
const HOLD_DEPTH_MIN_BAR := 0.05       # usable depth for a hangable one
const HOLD_WIDTH_MIN := 0.45           # usable width along the facade
const HOLD_HEIGHT_MIN := 0.15          # vertical grip face: a 0.08 m moulding has none
const HOLD_DEPTH_WIDE := 0.25          # ...unless the top face is this wide to hook
const HOLD_USABLE_MAX := 1.60          # cap on the inboard probe run
const HOLD_STEP := 0.05                # inboard/outboard probe granularity
const HOLD_SCAN_OFFSETS: Array[float] = [
	0.00, 0.08, -0.12, 0.16, -0.24, 0.24, -0.34, 0.34,
]	# face plane, then inboard/outboard columns
const HOLD_SCAN_MAX_PLANE := 0.45      # scanned lip must sit on the face we hit
const HANG_WALL_OFFSET := 0.45         # body axis -> hold's outer face
const HANG_BODY_DROP := 1.45           # feet sit this far below the lip
const HANG_SNAP_MAX := 0.12            # m/frame: bounded skin, never a teleport
const SHIMMY_DRIVE_SPEED := 0.60       # m/s along the ledge (mirrors the locomotion's SHIMMY_SPEED)
const HANG_RADIUS := 0.30              # hang/stand capsule radius
const HOLD_STAND_OFFSETS: Array[float] = [0.24, 0.36, 0.50, 0.65, 0.85]
const HOLD_STAND_DROP_MAX := 1.00      # how far below the lip a landing may be
const CORNER_RISE_MIN := -0.60
const CORNER_RISE_MAX := 1.30
const LEDGE_CORNER_COOLDOWN := 0.25   # re-arm after a climb leap
const LEDGE_CLIMB_HYSTERESIS := 0.15  # a re-grab must beat the lip we left

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
var _air_time := 0.0
var _last_loco_state := -1             # ANTI-STUCK: previous locomotion state
var _climb_time_left := -1.0           # follow-through window (< 0 = idle)
var _climb_dir := Vector3.ZERO
var _climb_speed := 0.0
# --- Q2 verified holds ----------------------------------------------------
var _hang_hold: Dictionary = {}        # verified record of the hold in hand
var hold_accepts := 0                  # lifetime: holds that passed verification
var hold_rejects := 0                  # lifetime: candidates killed by geometry
var last_reject_reason := &""          # Q2 census: why the last candidate died
var reject_reasons: Dictionary = {}    # Q2 census: rule -> count (bounded set)
var last_hold_kind := &""              # tag/prop/structure of the latest grab
var last_hold_width := 0.0             # measured usable width (m)
var last_hold_depth := 0.0             # measured usable depth (m)
var last_hold_hang_clear := false      # hang capsule had real clearance
var last_hold_stand_clear := false     # a standing spot existed on the lip
var shimmy_ends := 0                   # lifetime: shimmy ran into a ledge end
var corner_handoffs := 0               # lifetime: shimmy walked round a corner
var ledge_climbs := 0                  # lifetime: climb-ups from a hang
var hang_ticks := 0                    # lifetime: frames held by the anchor
var shimmy_driven_ticks := 0           # lifetime: frames the hang drove the shimmy
var last_shimmy_travel := 0.0          # signed travel (m) along the ledge tangent
var _climb_floor_y := -1.0e8           # lip we just left (anti re-catch)


## Wire to the owning body. Call once, right after add_child().
func setup(survivor: Survivor) -> void:
	_survivor = survivor
	_peak_y = survivor.global_position.y


## Called by PlayerController once per jump-input press.
func try_jump() -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	# Q2: a jump press while hanging off a verified hold is a CLIMB, not a
	# jump - mantle onto the lip when a standing spot was measured there,
	# otherwise leap for a higher hold.
	if _is_hanging_state(_loco_state()):
		_try_hang_climb()
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
	# ANTI-STUCK: when a HANG/SHIMMY/DROP2HANG ends (auto-release, let-go input or
	# landing), hold off re-grabbing for a full cooldown. Without this the body
	# re-catches the very lip it just released and loops forever - still stuck.
	if _survivor.has_method("get_locomotion"):
		var loco_r = _survivor.get_locomotion()
		if loco_r != null and is_instance_valid(loco_r):
			var st_r := int(loco_r.state)
			var was_hang := _last_loco_state == CharacterLocomotion.State.HANG \
					or _last_loco_state == CharacterLocomotion.State.SHIMMY \
					or _last_loco_state == CharacterLocomotion.State.DROP2HANG
			if was_hang and _last_loco_state != st_r:
				_ledge_cooldown = maxf(_ledge_cooldown, LEDGE_COOLDOWN)
			_last_loco_state = st_r
	if _survivor.is_on_floor():
		_air_time = 0.0
	else:
		_air_time += delta
	if not _survivor.is_on_floor():
		if _air_time >= LEDGE_MIN_AIR_TIME:
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
	# Phase F slice 2: intended direction first, then evenly spaced fallback
	# rays around the body - every one of them now goes through the verified
	# hold query, so a blank facade cell cannot latch the player.
	var dirs: Array[Vector3] = [primary]
	for i in range(1, LEDGE_SEEK_RAYS):
		var ang := TAU * float(i) / float(LEDGE_SEEK_RAYS)
		dirs.append(Vector3(cos(ang), 0.0, sin(ang)))
	for d in dirs:
		var probe := _probe_ledge(d)
		if probe.is_empty():
			continue
		if _commit_grab(d, probe):
			return


## Q2 verified hold query for one direction. Returns {} or a hold record:
## {kind, tag, class, shape_node, lip, wall_normal, tangent, rise, box_depth,
##  usable_depth, usable_width, usable_half_width, hang_clear, stand_clear,
##  stand_offset, wall, dir}
##
## The rule is: a climbable tag CLASSIFIES the hold, the shape's own box
## geometry VERIFIES it, and "free air above the top face" is what separates a
## real projection (cornice, parapet, balcony deck, awning, crate, bulkhead)
## from a blank facade cell or a storey seam. The pre-Q2 probe pushed a
## downward ray a fixed 0.45 m past the wall face, so only boxes deeper than
## 0.45 m were ever grabbable - every shallower feature (the 0.2 m cornice,
## the 0.28 m parapet ring) was invisible to the hands.
func _probe_ledge(dir: Vector3) -> Dictionary:
	if _survivor == null or _survivor.get_world_3d() == null:
		return {}
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 0.01:
		return {}
	d = d.normalized()
	var space := _survivor.get_world_3d().direct_space_state
	if space == null:
		return {}
	var feet := _survivor.global_position
	var side := Vector3(-d.z, 0.0, d.x)
	# 1. A face we can climb: chest-height rays must hit a surface facing us.
	var wall_hit := {}
	for off: float in [-LEDGE_PROBE_OFFSET, 0.0, LEDGE_PROBE_OFFSET]:
		var org := Vector3(feet.x, feet.y + LEDGE_PROBE_HEIGHT, feet.z) + side * off
		var hit := _ray_to(space, org, org + d * LEDGE_PROBE_REACH)
		if hit.is_empty():
			continue
		var hn := hit.normal as Vector3
		hn.y = 0.0
		if hn.length_squared() < 0.01 or hn.normalized().dot(d) > -0.5:
			continue
		wall_hit = hit
		break
	if wall_hit.is_empty():
		return _reject(&"no_face")
	var face_plane := (wall_hit.position as Vector3).dot(d)
	# 2. The shape the chest rays hit is the first candidate (shared table
	#    edges, crates, low cornices).
	var rec := _verify_hold(space, _hit_shape_node(wall_hit), d, side, feet, face_plane)
	if not rec.is_empty():
		rec["wall"] = wall_hit
		rec["dir"] = d
		return rec
	# 3. Bounded outward scan: the cornice/parapet band sits above or just
	#    outside the face we hit, and a lip shallower than LEDGE_PROBE_OFFSET
	#    can never be found by a fixed-offset probe.
	var base := wall_hit.position as Vector3
	var top_y := feet.y + LEDGE_REACH_ABOVE + 0.15
	var bot_y := feet.y + LEDGE_TOP_MIN - 0.05
	for off: float in HOLD_SCAN_OFFSETS:
		var probe_pt := base + d * off
		var hit2 := _ray_to(
			space,
			Vector3(probe_pt.x, top_y, probe_pt.z),
			Vector3(probe_pt.x, bot_y, probe_pt.z))
		if hit2.is_empty():
			continue
		var rec2 := _verify_hold(space, _hit_shape_node(hit2), d, side, feet, face_plane)
		if rec2.is_empty():
			continue
		rec2["wall"] = hit2
		rec2["dir"] = d
		rec2["scan_offset"] = off
		return rec2
	return {}


## Classify + verify one candidate collision shape as a climbable hold.
## `d` points from the player into the wall, `side` is the facade tangent.
func _verify_hold(space: PhysicsDirectSpaceState3D, node: CollisionShape3D,
		d: Vector3, side: Vector3, feet: Vector3, face_plane: float) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return _reject(&"no_shape")
	var shape := node.shape
	if not (shape is BoxShape3D):
		return _reject(&"not_box")
	var box := shape as BoxShape3D
	var xf := node.global_transform
	if absf(xf.basis.y.normalized().dot(Vector3.UP)) < 0.99:
		return _reject(&"tilted")                   # tilted: no honest top face
	var ex := xf.basis.x.normalized() * box.size.x * 0.5
	var ez := xf.basis.z.normalized() * box.size.z * 0.5
	var half_d: float = absf(ex.dot(d)) + absf(ez.dot(d))
	var half_s: float = absf(ex.dot(side)) + absf(ez.dot(side))
	var c := xf.origin
	var top := c.y + box.size.y * 0.5
	var rise := top - feet.y
	if rise < LEDGE_TOP_MIN or rise > LEDGE_REACH_ABOVE:
		return _reject(&"rise_low" if rise < LEDGE_TOP_MIN else &"rise_high")
	var edge := c - d * half_d                       # top edge facing the player
	edge.y = top
	if edge.dot(d) > face_plane + HOLD_SCAN_MAX_PLANE:
		return _reject(&"buried")                    # buried inside the wall
	var tag := StringName(node.get_meta("vox_tag", &""))
	var material := StringName(node.get_meta("vox_material", &""))
	var tagged := CLIMBABLE_TAGS.has(tag)
	# Usable depth: how far inboard from the front edge the top face stays
	# free. A facade cell has the wall continuing above it (0 m), a 0.085 m
	# string course gives 0.085 m, a cornice/parapet/crate gives its depth.
	var usable := 0.0
	var span: float = minf(half_d * 2.0, HOLD_USABLE_MAX)
	while usable + HOLD_STEP <= span:
		var pt := edge + d * (usable + HOLD_STEP)
		pt.y = top
		if not _air_above(space, pt):
			break
		usable += HOLD_STEP
	var min_depth := HOLD_DEPTH_MIN_BAR if tagged else HOLD_DEPTH_MIN_SLAB
	if usable < min_depth:
		return _reject(&"no_depth")
	# A lip has to offer a hand something: either a vertical face tall enough to
	# hook (cornice/parapet/sill) or a top face wide enough to lay a hand over
	# (scaffold plank, deck). A 0.08 x 0.10 m string course offers neither, so
	# decorative trim stays scenery no matter what it is tagged.
	if box.size.y < HOLD_HEIGHT_MIN and usable < HOLD_DEPTH_WIDE:
		return _reject(&"thin_member")
	# Usable width along the facade, measured both ways from the probe column:
	# this single honest number decides shimmy travel and mantle room.
	var half_free := 0.0
	while half_free + HOLD_STEP <= half_s:
		var off := half_free + HOLD_STEP
		var pl := edge + side * off
		var pr := edge - side * off
		if not _air_above(space, Vector3(pl.x, top, pl.z)):
			break
		if not _air_above(space, Vector3(pr.x, top, pr.z)):
			break
		half_free = off
	if half_free * 2.0 < HOLD_WIDTH_MIN:
		return _reject(&"no_width")
	var kind := tag
	if kind == &"":
		kind = &"structure" if material != &"" else &"prop"
	var w_dir := -d                                  # outward, toward the player
	var lip := edge                                  # outer edge of the top face
	var out_face := c - d * half_d
	var rec := {
		"kind": kind,
		"tag": tag,
		"shape_node": node,
		"lip": lip,
		"outer_face": out_face,
		"wall_normal": w_dir,
		"tangent": side,
		"rise": rise,
		"box_depth": half_d * 2.0,
		"usable_depth": usable,
		"usable_width": half_free * 2.0,
		"usable_half_width": half_free,
	}
	# Clearance is measured, not assumed: a hang needs room for a 0.30 m
	# radius body at HANG_WALL_OFFSET out from the face, and a mantle needs an
	# actual standing spot on the lip.
	var hang_pt := lip + w_dir * HANG_WALL_OFFSET
	rec["hang_clear"] = _capsule_clear(space, hang_pt, top - HANG_BODY_DROP, HANG_RADIUS, 1.62)
	var stand := _stand_search(space, rec)
	rec["stand_clear"] = bool(stand["clear"])
	rec["stand_offset"] = float(stand["offset"])
	# A hold with nowhere to put the body is not a hold: the hang capsule is
	# blocked AND the lip has no standing spot, so a grab would only clip.
	if not bool(rec["hang_clear"]) and not bool(rec["stand_clear"]):
		return _reject(&"no_clearance")
	# A slab is a top surface the body can stand on, so it needs both the usable
	# depth and a real standing spot (a 0.24 m cornice against a wall measures
	# deep enough but is a handhold: hang + shimmy only).
	rec["class"] = HOLD_CLASS_SLAB \
			if (usable >= HOLD_DEPTH_MIN_SLAB and bool(rec["stand_clear"])) \
			else HOLD_CLASS_BAR
	hold_accepts += 1
	return rec


## A verified standing spot on the lip. A mantle ends ON the hold, so the
## candidate points walk INBOARD from the front edge and each one must
##  - fit the body capsule without overlapping structure (this is what keeps a
##    0.2 m cornice a handhold: inboard of its lip is solid wall), and
##  - have a surface to land on within HOLD_STAND_DROP_MAX (the lip's own top
##    face, or the roof behind a parapet the body pulls over).
## Without the second test a body would be declared able to stand on a lip with
## nothing under it, and the pull-up would leave it in mid-air.
func _stand_search(space: PhysicsDirectSpaceState3D, rec: Dictionary) -> Dictionary:
	var lip: Vector3 = rec["lip"]
	var inboard: Vector3 = -(rec["wall_normal"] as Vector3)
	var usable := float(rec.get("usable_depth", 0.0))
	var feet_y := lip.y + 0.02
	for off: float in HOLD_STAND_OFFSETS:
		# A slender member can still have a real floor BEHIND it: an awning lip
		# is a 0.45 m railing standing on a 2.4 m deck, so the landing is one
		# step over the railing, not on the railing. The cap only exists to stop
		# us claiming a landing past the top face of a *slab* we measured
		# (a 0.24 m cornice has wall where a landing would be); for anything
		# thinner the capsule test and the floor test below are the real gate,
		# and they reject the cornice case on their own (capsule inside wall).
		if off > usable + 0.10 and usable >= HOLD_DEPTH_MIN_SLAB:
			break
		var pt := lip + inboard * off
		if not _capsule_clear(space, pt, feet_y, HANG_RADIUS - 0.02, 1.62):
			continue
		if not _floor_below(space, pt, feet_y):
			continue
		return {"clear": true, "offset": off}
	return {"clear": false, "offset": 0.0}


## Is there a top surface to land on within HOLD_STAND_DROP_MAX below the
## candidate feet?
func _floor_below(space: PhysicsDirectSpaceState3D, pt: Vector3, feet_y: float) -> bool:
	var hit := _ray_to(space,
			Vector3(pt.x, feet_y + 0.06, pt.z),
			Vector3(pt.x, feet_y - HOLD_STAND_DROP_MAX, pt.z))
	if hit.is_empty():
		return false
	var n := hit.normal as Vector3
	return n.dot(Vector3.UP) > LEDGE_SURFACE_NORMAL_Y


## Is the space above `pt` (a point on a top face) free? This is the test that
## makes a top face a HOLD: blank facade cells and storey seams have the wall
## continuing above them, so they always answer false.
func _air_above(space: PhysicsDirectSpaceState3D, pt: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(
		pt + Vector3(0.0, 0.02, 0.0),
		pt + Vector3(0.0, LEDGE_PROBE_HEIGHT, 0.0))
	q.exclude = [_survivor]
	q.collide_with_areas = false
	# A ray that STARTS inside solid structure must read as "not air": that is
	# exactly the storey seam / buried cell case. Without this, Godot skips a
	# body it starts inside and a blank facade cell looks like a deep ledge.
	q.hit_from_inside = true
	return space.intersect_ray(q).is_empty()


## Capsule clearance test used by both the hang and the stand verification.
func _capsule_clear(space: PhysicsDirectSpaceState3D, xz_pt: Vector3,
		feet_y: float, radius: float, height: float) -> bool:
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = maxf(height, radius * 2.0 + 0.02)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = Transform3D(Basis.IDENTITY, Vector3(xz_pt.x, feet_y + height * 0.5, xz_pt.z))
	q.collision_mask = 1
	q.exclude = [_survivor.get_rid()]
	q.collide_with_areas = false
	return space.intersect_shape(q, 1).is_empty()


func _ray_to(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [_survivor]
	q.collide_with_areas = false
	return space.intersect_ray(q)


## CollisionShape3D behind a ray/shape hit (a batched cell is many shapes on
## one body, and the metas live on the shape owner).
func _hit_shape_node(hit: Dictionary) -> CollisionShape3D:
	if hit.is_empty():
		return null
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is CollisionObject3D):
		return null
	var co := collider as CollisionObject3D
	var idx := int(hit.get("shape", -1))
	if idx < 0:
		return null
	var owner := co.shape_owner_get_owner(co.shape_find_owner(idx))
	if owner is CollisionShape3D:
		return owner as CollisionShape3D
	return null


## Apply a confirmed grab (the verified record from _probe_ledge). Returns
## false (no side effects) when the survivor lacks the stamina this lip
## demands. Two honest outcomes:
##  - stand_clear: assisted mantle, as before (boost + drive over the lip).
##  - otherwise: an anchored hang on the measured lip - no boost, no clip, no
##    silent sink; the body is pinned to the hold and can shimmy it, climb it
##    when a real standing spot exists, or drop.
func _commit_grab(dir: Vector3, rec: Dictionary) -> bool:
	var rise := float(rec["rise"])
	# Anti re-catch: after a climb leap the same edge must not be grabbed
	# again on the way down - the hands need real progress.
	if _climb_floor_y > -1.0e7:
		var lip_y := float((rec["lip"] as Vector3).y)
		if lip_y <= _climb_floor_y + LEDGE_CLIMB_HYSTERESIS:
			return false
	var cost := _ledge_stamina_cost(rise)
	if _survivor.stamina < cost:
		return false
	_survivor.stamina -= cost
	last_stamina_cost = cost
	_ledge_cooldown = LEDGE_COOLDOWN
	_peak_y = _survivor.global_position.y
	ledge_grabs += 1
	var wall_hit: Dictionary = rec.get("wall", {})
	var node: CollisionShape3D = rec.get("shape_node") as CollisionShape3D
	var tag := StringName(rec.get("tag", &""))
	var is_building := _hit_is_concrete(wall_hit)
	if not is_building and node != null:
		is_building = StringName(node.get_meta("vox_material", &"")) == &"concrete"
	last_grab_was_building = is_building
	if is_building:
		rooftop_mantles += 1
	last_grab_was_awning = tag == &"awning"
	if last_grab_was_awning:
		awning_grabs += 1
	last_hold_kind = StringName(rec.get("kind", &""))
	last_hold_width = float(rec.get("usable_width", 0.0))
	last_hold_depth = float(rec.get("usable_depth", 0.0))
	last_hold_hang_clear = bool(rec.get("hang_clear", false))
	last_hold_stand_clear = bool(rec.get("stand_clear", false))
	# Honest hands: the LEDGE PROBE the locomotion hangs from is the verified
	# lip and its real normal, not a point 0.45 m out in the air.
	_ledge_probe = {
		"rise": rise,
		"ledge_pos": rec["lip"],
		"ledge_normal": rec["wall_normal"],
		"has_hit": true,
		"ledge_length": float(rec.get("usable_width", 0.0)),
		"class": String(rec.get("class", &"")),
		"kind": String(rec.get("kind", &"")),
		"wall": wall_hit,
		"dir": dir,
		"hold": rec,
	}
	# Shimmy only exists where the ledge was measured long enough for it.
	if float(rec.get("usable_width", 0.0)) >= 2.0 - 0.05:
		_shimmy_probe = {
			"has_hit": true,
			"ledge_length": float(rec.get("usable_width", 0.0)),
			"wall_length": float(rec.get("usable_width", 0.0)),
			"ledge_pos": rec["lip"],
			"ledge_normal": rec["wall_normal"],
			"tangent": rec["tangent"],
			"half_width": float(rec.get("usable_half_width", 0.0)),
		}
	else:
		_shimmy_probe = {}
	_hang_hold = rec.duplicate(false)
	_hang_hold["anchored"] = not last_hold_stand_clear
	_hang_hold["travel"] = 0.0
	if last_hold_stand_clear:
		var need := rise + LEDGE_CLIMB_CLEARANCE
		var boost: float = clampf(
			sqrt(2.0 * _survivor.GRAVITY * need),
			LEDGE_CLIMB_BOOST_MIN, LEDGE_CLIMB_BOOST_MAX)
		_survivor.velocity.y = maxf(_survivor.velocity.y, boost)
		_survivor.velocity.x *= LEDGE_FORWARD_MULT
		_survivor.velocity.z *= LEDGE_FORWARD_MULT
		_climb_dir = dir
		_climb_speed = CORNICE_DRIVE_SPEED if is_building else CLIMB_DRIVE_SPEED
		if last_grab_was_awning:
			_climb_speed = AWNING_DRIVE_SPEED
		_climb_time_left = CLIMB_FOLLOW_TIME
	else:
		_survivor.velocity = Vector3.ZERO
		_climb_time_left = -1.0
		_climb_speed = 0.0
	_climb_floor_y = -1.0e8
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


## Anti-abyss recovery: a cancelled fall must not charge fall damage on the
## next landing, and a half-finished ledge follow-through must not steer the
## body after the teleport.
func reset_fall_tracking(feet_y: float) -> void:
	_peak_y = feet_y
	_climb_time_left = -1.0
	_climb_dir = Vector3.ZERO


## Track airtime peaks; charge fall damage on hard landings.
## Call from Survivor._physics_process AFTER move_and_slide().
func tick(_delta: float) -> void:
	if _survivor == null or _survivor.health.is_dead:
		return
	# Q2: hold a hang on its verified lip (bounded, after the physics step).
	_tick_anchored_hang(_delta)
	if _survivor.is_on_floor():
		_climb_floor_y = -1.0e8
		var drop := _peak_y - _survivor.global_position.y
		if drop > FALL_SAFE_HEIGHT:
			_survivor.take_damage(
				(drop - FALL_SAFE_HEIGHT) * FALL_DAMAGE_PER_M, &"fall")
		_peak_y = _survivor.global_position.y
	else:
		_peak_y = maxf(_peak_y, _survivor.global_position.y)

## Q2: the owning locomotion state as an int (-1 when there is no locomotion).
func _loco_state() -> int:
	if _survivor == null or not _survivor.has_method("get_locomotion"):
		return -1
	var loco = _survivor.get_locomotion()
	if loco == null or not is_instance_valid(loco):
		return -1
	return int(loco.state)


func _is_hanging_state(st: int) -> bool:
	return st == CharacterLocomotion.State.HANG \
			or st == CharacterLocomotion.State.SHIMMY \
			or st == CharacterLocomotion.State.DROP2HANG


## Q2 anchored hang. While the locomotion hangs off a verified hold that has no
## standing spot on it, gravity used to drag the body down the facade every
## frame - the pre-Q2 "sink". Here the body is held at the measured lip:
##  - wall-normal offset and height follow the lip (hands where they were put),
##  - tangential travel stays free (that is the shimmy the survivor drives) but
##    is clamped to the ledge width we actually measured,
##  - every correction is capped at HANG_SNAP_MAX per frame, so this is a
##    bounded skin and never a teleport,
##  - the hold is released the instant the state leaves the hang set.
func _tick_anchored_hang(delta: float) -> void:
	if _hang_hold.is_empty() or _survivor == null or _survivor.health.is_dead:
		return
	if not bool(_hang_hold.get("anchored", false)):
		return
	var st := _loco_state()
	if st == CharacterLocomotion.State.DROP2HANG:
		_hang_hold = {}                        # deliberate let-go: no pinning
		return
	if st == CharacterLocomotion.State.CLIMB_UP:
		return                              # mantle in flight: hands are free
	if not _is_hanging_state(st):
		_hang_hold = {}
		return
	hang_ticks += 1
	var lip: Vector3 = _hang_hold["lip"]
	var w_dir: Vector3 = _hang_hold["wall_normal"]
	# Q2 shimmy axis: the survivor's own right-hand axis on the hold's wall. The
	# stored `tangent` is its mirror, and the body's strafe recipe cannot carry a
	# shimmy at all - it turns to face its own input, so its strafe reads 0 on the
	# very next frame and the old hands walked nowhere. The travel is therefore
	# driven here, along the width this hold was measured to have.
	var tan: Vector3 = (-w_dir).cross(Vector3.UP).normalized()
	var half_w := float(_hang_hold.get("usable_half_width", 0.0))
	var pos := _survivor.global_position
	var travel := (pos - lip).dot(tan)
	travel = _drive_shimmy(travel, tan, half_w, delta)
	# Walking into the end of the measured ledge: offer the corner once.
	if absf(travel) >= half_w - 0.02 and not bool(_hang_hold.get("handoff_tried", false)):
		_hang_hold["handoff_tried"] = true
		if _try_corner_handoff(tan * signf(travel), lip):
			return
	if absf(travel) >= half_w - 0.02 and int(_hang_hold.get("ends_counted", 0)) == 0:
		_hang_hold["ends_counted"] = 1
		shimmy_ends += 1
	var want := clampf(travel, -half_w, half_w)
	_hang_hold["travel"] = want
	var target := lip + w_dir * HANG_WALL_OFFSET + tan * want
	target.y = lip.y - HANG_BODY_DROP
	pos += (target - pos).limit_length(HANG_SNAP_MAX)
	_survivor.global_position = pos
	# Hands carry the weight: no downward drift while anchored.
	_survivor.velocity.y = maxf(_survivor.velocity.y, 0.0)


## Q2 shimmy drive. One honest number decides the travel: the usable half-width
## measured on the hold in hand. The locomotion's strafe recipe cannot carry a
## shimmy (see _tick_anchored_hang), so the anchored hang advances the hands
## along the ledge by the player's tangential intent and clamps them to that
## measured width - the shimmy ends where the geometry ends, never in mid-air.
func _drive_shimmy(travel: float, tan: Vector3, half_w: float, delta: float) -> float:
	if half_w <= 0.0:
		return clampf(travel, -half_w, half_w)
	var md: Variant = _survivor.get("_move_dir")
	var intent := 0.0
	if md is Vector3:
		intent = clampf((md as Vector3).dot(tan), -1.0, 1.0)
	if absf(intent) <= 0.15:
		return clampf(travel, -half_w, half_w)
	shimmy_driven_ticks += 1
	last_shimmy_travel = clampf(travel + intent * SHIMMY_DRIVE_SPEED * delta, -half_w, half_w)
	return last_shimmy_travel


## Q2 corner handoff: the shimmy reached the end of the measured ledge while
## still pushing outward, so look round the corner (perpendicular to the ledge
## tangent) for a fresh verified hold at a sane height and, when there is one,
## hand the body over to it instead of dead-stopping against the end.
func _try_corner_handoff(corner_dir: Vector3, from_lip: Vector3) -> bool:
	var rec := _probe_ledge(corner_dir)
	if rec.is_empty():
		return false
	var dy := float((rec["lip"] as Vector3).y) - from_lip.y
	if dy < CORNER_RISE_MIN or dy > CORNER_RISE_MAX:
		return false
	if not _commit_grab(corner_dir, rec):
		return false
	corner_handoffs += 1
	return true


## Q2 climb-from-hang (jump input while hanging). With a measured standing spot
## on the lip: mantle onto it. Without one: leap for a higher hold - the falling
## grab re-arms off the lip we left (LEDGE_CLIMB_HYSTERESIS), so the same edge
## cannot be caught twice in a row.
func _try_hang_climb() -> void:
	if _hang_hold.is_empty() or _survivor == null or _survivor.exhausted:
		return
	var rise := float(_hang_hold.get("rise", 1.0))
	var cost := _ledge_stamina_cost(rise)
	if _survivor.stamina < cost:
		return
	_survivor.stamina -= cost
	last_stamina_cost = cost
	var lip: Vector3 = _hang_hold["lip"]
	var w_dir: Vector3 = _hang_hold["wall_normal"]
	ledge_climbs += 1
	if bool(_hang_hold.get("stand_clear", false)):
		var need: float = maxf(
			0.40, lip.y - _survivor.global_position.y + LEDGE_CLIMB_CLEARANCE)
		_survivor.velocity.y = clampf(
			sqrt(2.0 * _survivor.GRAVITY * need),
			LEDGE_CLIMB_BOOST_MIN, LEDGE_CLIMB_BOOST_MAX)
		_climb_dir = -w_dir                      # drive onto the top face
		_climb_speed = CORNICE_DRIVE_SPEED
		_climb_time_left = CLIMB_FOLLOW_TIME
		_ledge_cooldown = LEDGE_COOLDOWN
	else:
		_survivor.velocity.y = maxf(_survivor.velocity.y, JUMP_SPEED * 0.9)
		_ledge_cooldown = LEDGE_CORNER_COOLDOWN
		_climb_floor_y = lip.y
	_hang_hold = {}


## Q2 census: name the rule that killed a candidate, so a headless sweep of
## generated geometry can report WHY a facade cell is not climbable instead of
## only counting rejects. Bounded rule set, no unbounded log growth, and the
## reject paths stay single-exit so no reason can drift from its counter.
func _reject(reason: StringName) -> Dictionary:
	hold_rejects += 1
	last_reject_reason = reason
	reject_reasons[reason] = int(reject_reasons.get(reason, 0)) + 1
	return {}


## Q2 hold report for tests, HUD and debug overlays.
func get_hold_report() -> Dictionary:
	return {
		"accepts": hold_accepts,
		"rejects": hold_rejects,
		"last_reject": String(last_reject_reason),
		"reject_reasons": reject_reasons.duplicate(),
		"kind": String(last_hold_kind),
		"width": last_hold_width,
		"depth": last_hold_depth,
		"hang_clear": last_hold_hang_clear,
		"stand_clear": last_hold_stand_clear,
		"shimmy_ends": shimmy_ends,
		"corner_handoffs": corner_handoffs,
		"climbs": ledge_climbs,
		"hang_ticks": hang_ticks,
		"shimmy_ticks": shimmy_driven_ticks,
		"shimmy_travel": last_shimmy_travel,
	}
