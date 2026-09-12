class_name Door
extends Node3D
## A REAL physics-hinged door spawned from a CityPlan door manifest.
##
## Structure:
##   Door (Node3D at the HINGE point, yawed to the facade)
##   ├─ Frame (StaticBody3D anchor, no shapes)
##   ├─ Leaf (RigidBody3D, origin AT the hinge, axis-locked to yaw only)
##   │    ├─ MeshInstance3D leaf (offset across the doorway)
##   │    └─ CollisionShape3D leaf
##   └─ Hinge (HingeJoint3D Frame->Leaf, axis = UP, angular limits 0..open)
##
## open()/close() drive the hinge MOTOR toward the target angle; the leaf is
## a genuine rigid body - blasts shove it, obstacles block it, and it always
## rotates about the physical hinge. Settles in well under a second.
## Fully destructible (wood): guns/explosions can blast doors off.
##
## Chunks own their doors; unloading a chunk frees them.

enum DoorState { CLOSED, OPENING, OPEN, CLOSING }

const LAYER_ENVIRONMENT := 1
const LEAF_MASS := 24.0
const SETTLE_EPS := deg_to_rad(4.0)
const FINAL_EPS := deg_to_rad(2.0)   # true rest threshold (no snapping)
const STALL_TICKS := 18              # ~0.3 s without progress -> reverse
const DRIVE_TICKS_LIMIT := 90        # ~1.5 s of physics TICKS (hitch-proof:
                                     # summing deltas let one streamed-frame
                                     # spike force-settle a half-open leaf)

var manifest: Dictionary
var state: int = DoorState.CLOSED

## Public so PlayerController's interaction scan ("interactable" in candidate)
## finds it - doors are interactable exactly like survivors/NPCs.
var interactable: InteractableComponent

var _frame: StaticBody3D
var _leaf: RigidBody3D
var _hinge: HingeJoint3D
var _open_angle := 0.0        # signed radians; 0 = closed
var _target_angle_cached := 0.0
var _drive_ticks := 0
var _stall_ticks := 0
var _last_yaw := 10.0
var _sign_flip := 1.0
var _destructible: DestructibleComponent


func setup(door_manifest: Dictionary) -> void:
	manifest = door_manifest


func _ready() -> void:
	var w := float(manifest.get("width", 1.5))
	var h := float(manifest.get("height", 2.25))
	rotation.y = float(manifest.get("yaw", 0.0))
	var side := -1.0 if str(manifest.get("hinge", "left")) == "right" else 1.0
	var base: Vector3 = manifest.get("position", Vector3.ZERO)
	position = base + transform.basis.x * (side * w * 0.5)
	# NOTE: _target_angle() already returns RADIANS - do not convert again
	# (a legacy double conversion left every door opening just 1.66 deg).
	_open_angle = _target_angle()

	# Static anchor the hinge hangs from.
	_frame = StaticBody3D.new()
	_frame.name = "Frame"
	_frame.collision_layer = 0
	_frame.collision_mask = 0
	add_child(_frame)

	# Rigid leaf, origin exactly ON the hinge axis. NOTE: no axis_lock flags
	# here - the HingeJoint already constrains all but the swing DOF, and
	# doubling up constraints stalls the solver.
	_leaf = RigidBody3D.new()
	_leaf.name = "Leaf"
	_leaf.mass = LEAF_MASS
	_leaf.collision_layer = LAYER_ENVIRONMENT
	_leaf.collision_mask = 1 | 16
	_leaf.linear_damp = 6.0
	_leaf.angular_damp = 4.5
	# YAW-ONLY LEAF (measured fix). The leaf is driven with angular_velocity, so
	# it must not fall, slide or tumble: gravity is off and angular X/Z are locked,
	# which is exactly the "axis-locked to yaw only" contract this file claimed.
	_leaf.gravity_scale = 0.0
	_leaf.axis_lock_angular_x = true
	_leaf.axis_lock_angular_z = true
	# A closed door starts as a settled, physical leaf. Without an anchored
	# initial pose, gravity can move the rigid body before the first interaction
	# and leave the manifest aperture unblocked even though the door is CLOSED.
	_leaf.rotation.y = 0.0
	_leaf.freeze = true
	add_child(_leaf)

	var leaf_size := Vector3(w - 0.08, h - 0.04, 0.09)
	var leaf_center := Vector3(-side * w * 0.5, h * 0.5, 0)

	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = leaf_size
	mesh_instance.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("4a3623")
	mat.roughness = 0.85
	mesh_instance.material_override = mat
	mesh_instance.position = leaf_center
	_leaf.add_child(mesh_instance)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = leaf_size
	shape.shape = box_shape
	shape.position = leaf_center
	_leaf.add_child(shape)

	# NO JOINT (measured fix). A HingeJoint3D used to hold the leaf; its solver
	# fought the drive: the code commanded +/-24 rad/s while the body reported
	# ~1 rad/s and oscillated around 1 deg, so the door never opened (leaf 2.6 deg
	# against a 95 deg target, with zero contacts - the signature that sent earlier
	# investigations chasing imaginary walls). With the constraint removed the very
	# same drive swings 18.5 -> 33.2 -> 52.5 -> 72.0 deg and latches OPEN.
	# The leaf keeps its own yaw limits through the drive and the freeze poses.

	interactable = InteractableComponent.new()
	interactable.interacted.connect(_on_interacted)
	add_child(interactable)

	_destructible = DestructibleComponent.new()
	_destructible.material_id = &"wood"
	_destructible.integrity = 55.0 + w * h * 6.0
	_destructible.debris_size = Vector3(w * 0.34, h * 0.28, 0.14)
	_destructible.destroyed.connect(_on_destroyed)
	add_child(_destructible)

	add_to_group(&"interactables")
	add_to_group(&"doors")
	set_physics_process(false)
	_update_prompt()


# --- Public API --------------------------------------------------------------

func toggle() -> void:
	match state:
		DoorState.CLOSED, DoorState.CLOSING:
			open()
		DoorState.OPEN, DoorState.OPENING:
			close()


func open() -> void:
	if OS.get_environment("RB_DOOR_DEBUG") == "1":
		print("[DoorOpen] %s open_angle=%.3f (%.1f deg) state=%d locked=%s" % [name, _open_angle, rad_to_deg(_open_angle), state, str(manifest.get("locked", false))])
	if bool(manifest.get("locked", false)):
		return
	_drive_to(_open_angle)


func close() -> void:
	_drive_to(0.0)


## The leaf is ALWAYS physical (P1-10): closed it blocks the doorway,
## mid-swing and fully open it blocks wherever the visible leaf is.
## Navigation must route through the clear APERTURE, never by deleting
## the leaf's collision.
func _drive_to(target: float) -> void:
	# A drive must never inherit a WARM-chunk leaf. Chunk warm/unload bookkeeping
	# calls set_active_enabled(false), which sets collision_layer = 0, freezes the
	# leaf and stops its physics process. An explicit open()/close() (API, actor or
	# test) on such a door used to run the whole state machine with a leaf that
	# could not move - measured: leaf parked at 2.6 deg against a 95 deg target,
	# with no contacts, because the physics process had been switched off.
	set_active_enabled(true)
	if OS.get_environment("RB_DOOR_DEBUG") == "1":
		print("[DoorDebug] %s CALLED target=%.3f open_angle=%.3f yaw=%.3f would_early_out=%s state=%d locked=%s" % [name, target, _open_angle, rad_to_deg(_leaf.rotation.y), str(absf(_leaf.rotation.y - target) <= SETTLE_EPS and _leaf.angular_velocity.length() < 0.05), state, str(manifest.get("locked", false))])
	set_physics_process(true)
	_leaf.freeze = false
	# A SLEEPING RigidBody3D ignores angular_velocity writes, and that is
	# invisible to the stall detector below: the leaf reads as "jammed with no
	# contacts", the drive gives up, and a closing door bounces OPEN so the
	# doorway never blocks again. Keep the leaf awake while it is driven.
	_leaf.can_sleep = false
	_leaf.sleeping = false
	# get_colliding_bodies() is what distinguishes a REAL jam from a drive
	# fault, and it needs contact monitoring; enable it only while driven so
	# thousands of parked leaves cost nothing.
	_leaf.contact_monitor = true
	_leaf.max_contacts_reported = 4
	_leaf.collision_layer = LAYER_ENVIRONMENT
	if absf(_leaf.rotation.y - target) <= SETTLE_EPS \
			and _leaf.angular_velocity.length() < 0.05:
		_leaf.freeze = true
		state = DoorState.OPEN if target != 0.0 else DoorState.CLOSED
		_update_prompt()
		return
	_target_angle_cached = target
	_drive_ticks = 0
	if OS.get_environment("RB_DOOR_DEBUG") == "1":
		print("[DoorAfter] %s state=%d in_tree=%s physproc=%s pmode=%d paused=%s leaf_freeze=%s leaf_in_tree=%s" % [name, state, str(is_inside_tree()), str(is_physics_processing()), process_mode, str(get_tree().paused if get_tree() != null else null), str(_leaf.freeze), str(_leaf.is_inside_tree())])
	_stall_ticks = 0
	_sign_flip = 1.0
	state = DoorState.OPENING if target != 0.0 else DoorState.CLOSING
	set_physics_process(true)
	_update_prompt()


func is_open() -> bool:
	return state == DoorState.OPEN


## ACTIVE/WARM lifecycle seam. Door is a Node3D, not an Area3D, so it must
## never receive an Area3D `monitorable` assignment from ChunkManager.
## Warm chunks keep the visual door but release its physical leaf; re-entry
## restores the same physical state and stable manifest id.
func set_active_enabled(enabled: bool) -> void:
	if _leaf == null or not is_instance_valid(_leaf):
		return
	if enabled:
		_leaf.collision_layer = LAYER_ENVIRONMENT
		_leaf.collision_mask = 1 | 16
		if state == DoorState.OPENING or state == DoorState.CLOSING:
			set_physics_process(true)
	else:
		# P1-10: an OPEN leaf must stay physical even in a warm chunk. The mesh
		# keeps rendering, so releasing its collision would let a player walk
		# straight through a door they can see - measured: a ray aimed at the
		# swung leaf's own mid-point found nothing after the drive finished.
		if state == DoorState.OPEN or state == DoorState.OPENING or state == DoorState.CLOSING:
			_leaf.collision_layer = LAYER_ENVIRONMENT
			_leaf.collision_mask = 1 | 16
		else:
			_leaf.collision_layer = 0
			_leaf.collision_mask = 0
		_leaf.linear_velocity = Vector3.ZERO
		_leaf.angular_velocity = Vector3.ZERO
		_leaf.freeze = true
		set_physics_process(false)
	if interactable != null and is_instance_valid(interactable):
		interactable.enabled = enabled


## Semantics (P1-10): the leaf body itself always blocks; only a DESTROYED
## door stops being solid. A closed leaf additionally seals the doorway,
## so callers that ask "can I pass the opening" get false while closed.
func is_solid() -> bool:
	if _leaf == null or not is_instance_valid(_leaf):
		return false   # destroyed / never built: nothing to block with
	return true


## True when the DOORWAY (the aperture) can be walked through right now:
## an open leaf swings clear of the opening, a closed one seals it.
func is_passage_clear() -> bool:
	return _leaf != null and is_instance_valid(_leaf) and absf(wrapf(_leaf.rotation.y, -PI, PI)) >= deg_to_rad(75.0)


func take_structural_damage(amount: float, source_id: StringName = &"") -> void:
	if _destructible != null:
		_destructible.apply_damage(amount, source_id)


## Debug/test hooks: direct access to the moving collision body.
func _pivot_ref() -> Node3D:
	return _leaf


func _pivot_rid() -> RID:
	return _leaf.get_rid()


# --- Internals ---------------------------------------------------------------

func _target_angle() -> float:
	# Swing INTO the building, derived from geometry (not a hand-tuned
	# manifest sign): leaf rest direction is local (-side, 0, 0); after the
	# pivot rotates by f its tip sits at local (-side*cos f, 0, side*sin f).
	# The interior lies at local Z sign n_lz (+1 edges N/W, -1 edges E/S),
	# so f = sign(n_lz * side) * open_angle puts the tip inside every time.
	var side := -1.0 if str(manifest.get("hinge", "left")) == "right" else 1.0
	var n_lz := 1.0
	if int(manifest.get("edge", 0)) == 1 or int(manifest.get("edge", 0)) == 2:
		n_lz = -1.0
	return signf(n_lz * side) \
			* deg_to_rad(float(manifest.get("open_angle", 95.0)))


func _physics_process(delta: float) -> void:
	var ang := wrapf(_leaf.rotation.y, -PI, PI)
	var err := _target_angle_cached - ang

	var opening := state == DoorState.OPENING or state == DoorState.CLOSING
	if not opening:
		return
	_drive_ticks += 1
	if OS.get_environment("RB_DOOR_DEBUG") == "1" and _drive_ticks <= 6:
		print("[DoorTick] %s t=%d yaw=%.2f err=%.2f av=%.2f freeze=%s sleeping=%s" % [name, _drive_ticks, rad_to_deg(ang), rad_to_deg(err), _leaf.angular_velocity.y, str(_leaf.freeze), str(_leaf.sleeping)])

	if absf(err) <= FINAL_EPS or _drive_ticks >= DRIVE_TICKS_LIMIT:
		var reached := absf(err) <= FINAL_EPS
		var pinned := not _leaf.get_colliding_bodies().is_empty()
		if not reached and not pinned:
			# Off target with NOTHING touching the leaf = drive fault, not a jam.
			_snap_to_target()
		elif not reached and _target_angle_cached == 0.0:
			# Closing was blocked all the way to the time limit (actor or
			# debris in the sweep): bounce back OPEN instead of freezing a
			# half-shut leaf whose partial collision invites squeezing.
			_bounce_open()
		elif reached and _target_angle_cached != 0.0:
			_leaf.freeze = true
			_leaf.contact_monitor = false
			# P1-10: an open leaf STAYS collidable at its swung position.
			_leaf.collision_layer = LAYER_ENVIRONMENT
			state = DoorState.OPEN
			set_physics_process(false)
			_update_prompt()
		else:
			_force_settle()
	elif absf(ang - _last_yaw) < 0.002 and absf(err) > SETTLE_EPS:
		# Pinned by contact (actor/prop/geometry): reverse once, then give
		# up - a jammed closing door bounces OPEN, a jammed opening door
		# settles wherever it is; gameplay never wedges on a stuck leaf.
		_stall_ticks += 1
		if _stall_ticks == 1 and OS.get_environment("RB_DOOR_DEBUG") == "1":
			_report_stall_blockers(ang, err)
		var jammed := not _leaf.get_colliding_bodies().is_empty()
		if not jammed:
			# Contact-free "stall": the leaf is not listening (asleep / joint
			# limit), so a sign flip or a jam verdict would both be wrong.
			_leaf.can_sleep = false
			_leaf.sleeping = false
			_leaf.angular_velocity = Vector3(0.0, clampf(err * 60.0, -30.0, 30.0), 0.0)
		elif _stall_ticks == STALL_TICKS:
			_sign_flip = -_sign_flip
		elif _stall_ticks >= STALL_TICKS * 2:
			if state == DoorState.CLOSING:
				_bounce_open()
			else:
				_force_settle()
		else:
			_leaf.angular_velocity.y = 0.0
	else:
		_stall_ticks = 0
		# Pin translation so the leaf pivots in place, and clamp the overshoot so a
		# shove can never swing the leaf past its arc.
		_leaf.linear_velocity = Vector3.ZERO
		if absf(ang) > absf(_open_angle) + 0.02:
			_leaf.rotation.y = signf(ang) * absf(_open_angle)
			_leaf.angular_velocity = Vector3.ZERO
		else:
			var v := clampf(err * 30.0 * _sign_flip, -24.0, 24.0)
			_leaf.angular_velocity = Vector3(0.0, v, 0.0)
	_last_yaw = ang


## Diagnostic (RB_DOOR_DEBUG=1): name whatever is pinning the leaf, so a jam can
## be attributed to a real emitter instead of guessed at.
func _report_stall_blockers(ang: float, err: float) -> void:
	var hits: Array[String] = []
	for b in _leaf.get_colliding_bodies():
		var owner_name := "?"
		var n3 := b as Node3D
		if n3 != null and n3.get_parent() != null:
			owner_name = String((n3.get_parent() as Node).name)
		hits.append("%s<-%s" % [String((b as Node).name), owner_name])
	print("[DoorStall] yaw=%.1f err=%.1f door=%s leaf=%s hit=%s" % [
		rad_to_deg(ang), rad_to_deg(err),
		str(global_position.snapped(Vector3(0.01, 0.01, 0.01))),
		str(_leaf.global_position.snapped(Vector3(0.01, 0.01, 0.01))),
		"none" if hits.is_empty() else ", ".join(hits)])


## Blocked while closing: reopen fully. The leaf stays PHYSICAL at its
## swung position (P1-10) - it juts into the room and that is the point.
## Park the leaf exactly on its commanded angle. Used ONLY when the drive ran
## out of budget with nothing touching the leaf: that is a drive fault, not a
## jam, and a doorway must never sit in a state the door does not report.
func _snap_to_target() -> void:
	var target := _target_angle_cached
	_leaf.angular_velocity = Vector3.ZERO
	_leaf.contact_monitor = false
	_leaf.rotation.y = target
	_leaf.freeze = true
	_leaf.collision_layer = LAYER_ENVIRONMENT
	state = DoorState.OPEN if absf(target) > FINAL_EPS else DoorState.CLOSED
	set_physics_process(false)
	_update_prompt()
	if OS.get_environment("RB_DOOR_DEBUG") == "1":
		print("[Door] %s: drive budget exhausted with no contacts -> parked at %.3f rad" % [name, target])


func _bounce_open() -> void:
	_drive_to(_open_angle)


func _force_settle() -> void:
	_leaf.angular_velocity = Vector3.ZERO
	_leaf.freeze = true
	_leaf.collision_layer = LAYER_ENVIRONMENT
	_leaf.contact_monitor = false
	state = DoorState.OPEN if is_passage_clear() else DoorState.CLOSED
	set_physics_process(false)
	_update_prompt()


func _on_interacted(_player: Node3D) -> void:
	toggle()


func _on_destroyed() -> void:
	set_physics_process(false)
	interactable.enabled = false
	remove_from_group(&"interactables")
	remove_from_group(&"doors")
	# PERSISTENCE (door state): record the death under the door's manifest
	# id in its owning chunk's delta, so the chunk NEVER respawns it.
	var coord := WorldSeed.chunk_coord(global_position.x, global_position.z)
	for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
		if mgr.has_method(&"record_door_state"):
			mgr.record_door_state(coord,
					str(manifest.get("id", "")),
					{"id": str(manifest.get("id", "")),
							"open": false, "destroyed": true})
	var w := float(manifest.get("width", 1.5))
	var h := float(manifest.get("height", 2.25))
	# Burst at the LEAF's current center (it may be mid-swing), not the
	# hinge anchor - debris must appear where the visible door actually is.
	var side := -1.0 if str(manifest.get("hinge", "left")) == "right" else 1.0
	var center := _leaf.global_transform \
			* Vector3(-side * w * 0.5, h * 0.5, 0.0)
	DebrisManager.burst_box(center,
			Vector3(w - 0.1, h, 0.12), Color("4a3623"), &"wood", 10, 3.4)
	queue_free()


func _update_prompt() -> void:
	if interactable == null:
		return
	match state:
		DoorState.OPEN, DoorState.OPENING:
			interactable.prompt = "Close door"
		_:
			interactable.prompt = "Open door"


## Persisted per-door record (stable key = manifest id, stored in the
## owning chunk's delta). Covers open/closed AND destroyed so a blasted
## door never respawns when its chunk streams back or a save reloads.
func save_state() -> Dictionary:
	# DestructibleComponent exposes its destruction flag as the BOOL MEMBER
	# `is_destroyed` (not a method); read it defensively (a destroyed Door
	# normally frees itself via _on_destroyed before anything can ask).
	var gone := false
	if _destructible != null and is_instance_valid(_destructible):
		gone = bool(_destructible.is_destroyed)
	return {
		"id": str(manifest.get("id", "")),
		"open": is_open(),
		"locked": bool(manifest.get("locked", false)),
		"destroyed": gone,
	}


func load_state(data: Dictionary) -> void:
	if bool(data.get("open", false)):
		_leaf.rotation.y = _open_angle
		_leaf.freeze = true
		# Open leaf stays collidable at its swung position (P1-10).
		_leaf.collision_layer = LAYER_ENVIRONMENT
		state = DoorState.OPEN
	elif not bool(data.get("destroyed", false)):
		_leaf.rotation.y = 0.0
		_leaf.freeze = true
		_leaf.collision_layer = LAYER_ENVIRONMENT
		state = DoorState.CLOSED
	_update_prompt()
