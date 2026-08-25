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

	# The physical hinge: limits clamp the swing, motor drives it.
	# Godot hinges rotate about the joint's LOCAL Z, so tip that axis up.
	_hinge = HingeJoint3D.new()
	_hinge.name = "Hinge"
	_hinge.rotation_degrees.x = -90.0
	add_child(_hinge)
	_hinge.node_a = _frame.get_path()
	_hinge.node_b = _leaf.get_path()
	# The physical hinge: limits clamp the swing physically. Joint-local
	# angles are NEGATED body yaws (hinge Z tipped up via -90 deg X).
	_hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	_hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER,
			minf(0.0, -_open_angle))
	_hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER,
			maxf(0.0, -_open_angle))

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
	_update_prompt()


# --- Public API --------------------------------------------------------------

func toggle() -> void:
	match state:
		DoorState.CLOSED, DoorState.CLOSING:
			open()
		DoorState.OPEN, DoorState.OPENING:
			close()


func open() -> void:
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
	set_physics_process(true)
	_leaf.freeze = false
	_leaf.collision_layer = LAYER_ENVIRONMENT
	if absf(_leaf.rotation.y - target) <= SETTLE_EPS \
			and _leaf.angular_velocity.length() < 0.05:
		_leaf.freeze = true
		state = DoorState.OPEN if target != 0.0 else DoorState.CLOSED
		_update_prompt()
		return
	_target_angle_cached = target
	_drive_ticks = 0
	_stall_ticks = 0
	_sign_flip = 1.0
	state = DoorState.OPENING if target != 0.0 else DoorState.CLOSING
	set_physics_process(true)
	_update_prompt()


func is_open() -> bool:
	return state == DoorState.OPEN


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
	return state == DoorState.OPEN or state == DoorState.OPENING


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

	if absf(err) <= FINAL_EPS or _drive_ticks >= DRIVE_TICKS_LIMIT:
		var reached := absf(err) <= FINAL_EPS
		if not reached and _target_angle_cached == 0.0:
			# Closing was blocked all the way to the time limit (actor or
			# debris in the sweep): bounce back OPEN instead of freezing a
			# half-shut leaf whose partial collision invites squeezing.
			_bounce_open()
		elif reached and _target_angle_cached != 0.0:
			_leaf.freeze = true
			# P1-10: an open leaf STAYS collidable at its swung position.
			_leaf.collision_layer = LAYER_ENVIRONMENT
			state = DoorState.OPEN
			_update_prompt()
		else:
			_leaf.freeze = true
			_leaf.collision_layer = LAYER_ENVIRONMENT
			state = DoorState.CLOSED
			_update_prompt()
	elif absf(ang - _last_yaw) < 0.002 and absf(err) > SETTLE_EPS:
		# Pinned by contact (actor/prop/geometry): reverse once, then give
		# up - a jammed closing door bounces OPEN, a jammed opening door
		# settles wherever it is; gameplay never wedges on a stuck leaf.
		_stall_ticks += 1
		if _stall_ticks == STALL_TICKS:
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
		var v := clampf(err * 30.0 * _sign_flip, -24.0, 24.0)
		_leaf.angular_velocity = Vector3(0.0, v, 0.0)
	_last_yaw = ang


## Blocked while closing: reopen fully. The leaf stays PHYSICAL at its
## swung position (P1-10) - it juts into the room and that is the point.
func _bounce_open() -> void:
	_leaf.angular_velocity = Vector3.ZERO
	_leaf.freeze = true
	_leaf.collision_layer = LAYER_ENVIRONMENT
	state = DoorState.OPEN
	_update_prompt()


## Jam fallback: declare victory at the current pose. A jammed HALF-OPEN
## door must NOT become intangible - keep the collision on (P1-10).
func _force_settle() -> void:
	_leaf.angular_velocity = Vector3.ZERO
	_leaf.freeze = true
	if state == DoorState.CLOSING:
		state = DoorState.CLOSED
	else:
		state = DoorState.OPEN
	_leaf.collision_layer = LAYER_ENVIRONMENT
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
