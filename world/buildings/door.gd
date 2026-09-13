class_name Door
extends Node3D
## Deterministic hinged animation. Only a settled closed leaf blocks passage.
## Moving/open leaves have no collision, so actors and debris cannot jam them.
## Destruction, interaction, cutaway and chunk persistence retain the same API.

enum DoorState { CLOSED, OPENING, OPEN, CLOSING }

const LAYER_ENVIRONMENT := 1
const LEAF_MASS := 24.0
const FINAL_EPS := 0.001
const SWING_SPEED := 3.5 # radians per second

var manifest: Dictionary
var state: int = DoorState.CLOSED

## Public so PlayerController's interaction scan ("interactable" in candidate)
## finds it - doors are interactable exactly like survivors/NPCs.
var interactable: InteractableComponent

var _frame: StaticBody3D
var _leaf: RigidBody3D
var _leaf_lower: MeshInstance3D      # below the picture rail - never removed
var _leaf_upper: MeshInstance3D      # above it - the band the cutaway may drop
var _view_cut := false
var _view_hidden := false
var _open_angle := 0.0        # signed radians; 0 = closed
var _target_angle_cached := 0.0
var _active_enabled := true
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

	# Keep the existing body/RID API; the frozen body follows the hinge animation.
	_leaf = RigidBody3D.new()
	_leaf.name = "Leaf"
	_leaf.mass = LEAF_MASS
	_leaf.collision_layer = LAYER_ENVIRONMENT
	_leaf.collision_mask = 1 | 16
	_leaf.gravity_scale = 0.0
	_leaf.rotation.y = 0.0
	_leaf.freeze = true
	add_child(_leaf)

	var leaf_size := Vector3(w - 0.08, h - 0.04, 0.09)
	var leaf_center := Vector3(-side * w * 0.5, h * 0.5, 0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("4a3623")
	mat.roughness = 0.85
	# TWO PIECES, one cut line. The leaf is split at the picture rail so the
	# dollhouse cutaway can drop the band above it exactly like the wall the leaf
	# is hung in (see set_view_cut) instead of retiring the whole door. The piece
	# below the rail is never removed by any camera state.
	var leaf_bottom := leaf_center.y - leaf_size.y * 0.5
	var leaf_top := leaf_center.y + leaf_size.y * 0.5
	var cut_y := clampf(WorldConstants.PICTURE_RAIL_H, leaf_bottom, leaf_top)
	_leaf_lower = _leaf_piece(_leaf, mat, leaf_center.x, leaf_size.x, leaf_size.z,
		leaf_bottom, cut_y, "LeafLower")
	if leaf_top - cut_y > 0.02:
		_leaf_upper = _leaf_piece(_leaf, mat, leaf_center.x, leaf_size.x, leaf_size.z,
			cut_y, leaf_top, "LeafUpper")

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = leaf_size
	shape.shape = box_shape
	shape.position = leaf_center
	_leaf.add_child(shape)

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

## One slab of the leaf between two heights (metres, leaf-local). Hung under the
## physics body, so every piece swings with the door.
static func _leaf_piece(parent: Node3D, mat: StandardMaterial3D, center_x: float,
		width: float, depth: float, y0: float, y1: float, piece_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = piece_name
	var box := BoxMesh.new()
	box.size = Vector3(width, maxf(y1 - y0, 0.01), depth)
	mi.mesh = box
	mi.material_override = mat
	mi.position = Vector3(center_x, (y0 + y1) * 0.5, 0.0)
	parent.add_child(mi)
	return mi


# --- Public API --------------------------------------------------------------

## Dollhouse cutaway: drop the leaf's band above the picture rail, exactly like
## the wall the leaf is hung in. The lower band and every physical property
## (collision, mass, swing, passthrough, prompt) are untouched, so a CUT door
## still blocks the player and still swings open.
func set_view_cut(cut: bool) -> void:
	# A leaf that ends below the rail has no band to drop - the cut is a no-op
	# rather than a claim about geometry that does not exist.
	cut = cut and _leaf_upper != null
	if _view_cut == cut:
		return
	_view_cut = cut
	_apply_view_state()


## The door's whole storey sits above the cutaway plane: no leaf at all. This is
## the ONLY state that retires a door - it is never used to clear a sightline.
func set_view_hidden(hidden: bool) -> void:
	if _view_hidden == hidden:
		return
	_view_hidden = hidden
	_apply_view_state()


## Render state only. A cut leaf keeps CASTING SHADOWS for the band it lost - the
## same treatment hidden structure gets (locked decision 3) - so the dollhouse
## interior stays lit exactly like the full building.
func _apply_view_state() -> void:
	visible = not _view_hidden
	if _leaf_upper != null:
		_leaf_upper.cast_shadow = (
			MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if _view_cut
			else MeshInstance3D.SHADOW_CASTING_SETTING_ON)


## Read-back for probes/tests: "full", "cut" or "hidden".
func view_state_name() -> String:
	if _view_hidden:
		return "hidden"
	return "cut" if _view_cut else "full"

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


func _drive_to(target: float) -> void:
	_target_angle_cached = target
	_leaf.freeze = true
	_leaf.linear_velocity = Vector3.ZERO
	_leaf.angular_velocity = Vector3.ZERO
	state = DoorState.OPENING if target != 0.0 else DoorState.CLOSING
	_sync_collision()
	set_physics_process(_active_enabled)
	_update_prompt()


func is_open() -> bool:
	return state == DoorState.OPEN


## Warm chunks retain pose and animation target, but release physics.
func set_active_enabled(enabled: bool) -> void:
	_active_enabled = enabled
	if not is_instance_valid(_leaf):
		return
	_sync_collision()
	set_physics_process(enabled and state in [DoorState.OPENING, DoorState.CLOSING])
	if is_instance_valid(interactable):
		interactable.enabled = enabled


func _sync_collision() -> void:
	var blocking := _active_enabled and state == DoorState.CLOSED
	_leaf.collision_layer = LAYER_ENVIRONMENT if blocking else 0
	_leaf.collision_mask = (1 | 16) if blocking else 0


func is_solid() -> bool:
	return is_instance_valid(_leaf) and _active_enabled and state == DoorState.CLOSED


func is_passage_clear() -> bool:
	return is_instance_valid(_leaf) and state != DoorState.CLOSED


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
	_leaf.rotation.y = move_toward(_leaf.rotation.y, _target_angle_cached, SWING_SPEED * delta)
	if absf(_leaf.rotation.y - _target_angle_cached) <= FINAL_EPS:
		_leaf.rotation.y = _target_angle_cached
		state = DoorState.CLOSED if _target_angle_cached == 0.0 else DoorState.OPEN
		_sync_collision()
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
		"open": state in [DoorState.OPEN, DoorState.OPENING],
		"locked": bool(manifest.get("locked", false)),
		"destroyed": gone,
	}


func load_state(data: Dictionary) -> void:
	if bool(data.get("destroyed", false)):
		queue_free()
		return
	manifest["locked"] = bool(data.get("locked", manifest.get("locked", false)))
	state = DoorState.OPEN if bool(data.get("open", false)) else DoorState.CLOSED
	_target_angle_cached = _open_angle if state == DoorState.OPEN else 0.0
	_leaf.rotation.y = _target_angle_cached
	_leaf.freeze = true
	_sync_collision()
	set_physics_process(false)
	_update_prompt()
