class_name MeleeCombat
extends Node
## Melee-first combat component: one actor, one held weapon, eight swing
## directions.
##
## Design
##   * The *aim* picks the swing: MeleeSwingLibrary.direction_for() maps the aim
##     direction in the actor's own frame onto the weapon class's swing pool, so
##     the same button slashes right, slashes left, chops, thrusts or sweeps
##     depending on where the player points.
##   * Reach/arc/cleave/stagger/structural damage come from the weapon class
##     (MeleeTypes) with per-weapon overrides (ItemDB).
##   * Damage lands once, at the authored frame of the swing (hit_frac), not on
##     the button press -- swings can be whiffed by moving.
##   * Positional animation contract is respected: we never touch bone poses
##     directly, we play authored rotation tracks.
##
## Animation handoff
##   The rig is driven by a locomotion AnimationTree. Playing a one-shot swing
##   would be overwritten by the tree every frame, so a swing deactivates the
##   tree and plays the clip on the same AnimationPlayer (single pose authority
##   at any instant: the tree OR the swing, never both), then reactivates it
##   when the clip ends. A hard timeout guarantees the tree comes back even if
##   the finished signal is missed, so an actor can never be wedged in a pose.

signal swing_started(clip: StringName, heavy: bool)
signal swing_landed(clip: StringName, hits: int, damage: float)
signal swing_refused(reason: String)
signal weapon_changed(weapon_id: StringName, type_label: String)

enum State { IDLE, SWING }

const HIT_MASK := 1 | 2 | 4          # environment | survivors | zombies
const CHEST_HEIGHT := 1.15
const HAND_BONE_ARTICULATED := "r_forearm"
const HAND_BONE_SIMPLE := "r_upper_arm"
## Fallback grip distance for the simple (non-articulated) arm rig, measured
## from the arm bone origin; the articulated rig measures its own forearm.
const SIMPLE_GRIP_DISTANCE := 0.62
const GRIP_PAST_HAND := 0.08
## Recovery fraction of a swing after which a new swing may interrupt it.
const CANCEL_FROM := 0.72
## Grace period after the clip ends during which the next swing keeps a combo.
const COMBO_WINDOW := 0.28
const HEAVY_STAMINA_SCALE := 1.5
const HEAVY_DAMAGE_SCALE := 1.25
const HEAVY_SPEED_SCALE := 0.85
## Unavailable heavy swing (bare hands): same clip, committed, harder.
const COMMITTED_DAMAGE_SCALE := 1.2
const COMMITTED_SPEED_SCALE := 0.88
const FALLOFF_MIN := 0.65
const COMBO_MULT_STEP := 0.08
const COMBO_MULT_CAP := 1.35
const FINISHER_EVERY := 3
const FINISHER_BONUS := 1.2

## Damage a "reference" blow deals. Hit reactions and impact bursts scale their
## force around this number, so a knife jab and an axe smash do not read alike.
const REFERENCE_DAMAGE := 20.0

var actor: Survivor
var last_swing: StringName = &""
var last_downgraded := false
var last_hits := 0

var _skeleton: Skeleton3D
var _locomotion: CharacterLocomotion
var _animator: HumanoidAnimator
var _hand: BoneAttachment3D
var _grip: Node3D
var _mesh: Node3D

var _weapon_id: StringName = &""
var _def := {}
var _state := State.IDLE
var _t := 0.0
var _clip := &""
var _clip_time := 0.0
var _strike_at := 0.0
var _struck := false
var _heavy := false
var _committed := false
var _cooldown_left := 0.0
var _combo := 0
var _combo_deadline := 0.0
var _swing_dir := Vector3(0, 0, -1)
var _library_ready := false


func setup(p_actor: Survivor, skeleton: Skeleton3D,
		locomotion: CharacterLocomotion, animator: HumanoidAnimator) -> void:
	actor = p_actor
	_skeleton = skeleton
	_locomotion = locomotion
	_animator = animator
	_ensure_library()
	_attach_hand()
	equip(p_actor.equipped_weapon_id)


## Weapon in hand right now ("" is bare hands via ItemDB.FISTS).
func equip(weapon_id: StringName) -> void:
	_weapon_id = weapon_id
	_def = ItemDB.get_melee_def(weapon_id)
	_refresh_model()
	weapon_changed.emit(_weapon_id, String(_def.get("type_label", "")))


func weapon_id() -> StringName:
	return _weapon_id


func weapon_def() -> Dictionary:
	return _def


func type_label() -> String:
	return String(_def.get("type_label", ""))


func swing_pool() -> Array:
	return (_def.get("swing_pool", []) as Array).duplicate()


func state() -> int:
	return _state


## IDLE / WINDUP / STRIKE / RECOVER -- readable phase for HUD and tests.
func phase() -> String:
	if _state == State.IDLE:
		return "IDLE"
	if not _struck:
		return "WINDUP"
	if _t < _strike_at + 0.08:
		return "STRIKE"
	return "RECOVER"


func combo_index() -> int:
	return _combo


func current_clip() -> StringName:
	return _clip


func swing_direction() -> Vector3:
	return _swing_dir


## Single visibility switch for "is anything drawn in the hand". `_grip` is the
## node the player actually sees, so it is the one to toggle.
func set_weapon_visible(visible_now: bool) -> void:
	if _grip != null and is_instance_valid(_grip):
		_grip.visible = visible_now
	elif _mesh != null and is_instance_valid(_mesh):
		_mesh.visible = visible_now


## One swing attempt. `aim_dir` is a world-space direction; its projection on
## the ground plane decides the swing direction. Returns true if a swing began.
func try_attack(aim_dir := Vector3.ZERO, want_heavy := false) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if actor.health.is_dead or actor.needs.sleeping:
		_refuse("dead_or_asleep")
		return false
	if _cooldown_left > 0.0:
		_refuse("cooldown")
		return false
	if _state == State.SWING:
		if not _struck or _t < _clip_time * CANCEL_FROM:
			_refuse("mid_swing")
			return false

	last_downgraded = false
	var heavy := want_heavy
	var cost := float(_def.get("stamina_cost", 5.0))
	if heavy:
		if not MeleeTypes.has_heavy(StringName(_def.get("melee_type", &"fist"))):
			heavy = false
			_committed = true
		elif actor.stamina < cost * HEAVY_STAMINA_SCALE:
			# Not enough wind for the big swing: fall back to the light one
			# rather than eating the input.
			heavy = false
			last_downgraded = true
	if not heavy:
		_committed = want_heavy and not MeleeTypes.has_heavy(
				StringName(_def.get("melee_type", &"fist")))
	if actor.stamina < cost:
		if _combo > 0:
			_combo = 0
		_refuse("stamina")
		return false

	var swing_local := _local_aim(aim_dir)
	# Aim angle in the actor's frame: 0 = straight ahead, +90 = its right.
	_swing_dir = _frame() * swing_local
	_swing_dir.y = 0.0
	_swing_dir = _swing_dir.normalized() if _swing_dir.length_squared() > 0.0001 \
			else _forward()

	_clip = MeleeSwingLibrary.direction_for(swing_local,
			_def.get("swing_pool", []), heavy)
	_heavy = heavy

	if _state == State.SWING:
		_close_swing()   # interrupt: same bookkeeping as a natural finish

	var speed := float(_def.get("clip_speed", 1.0))
	speed *= HEAVY_SPEED_SCALE if heavy else 1.0
	speed *= COMMITTED_SPEED_SCALE if _committed else 1.0
	_clip_time = MeleeSwingLibrary.clip_length(_clip) / maxf(0.1, speed)
	_strike_at = MeleeSwingLibrary.hit_time(_clip) / maxf(0.1, speed)
	_t = 0.0
	_struck = false
	_cooldown_left = float(_def.get("cooldown", 0.7))

	actor.stamina = maxf(0.0, actor.stamina - cost * (
			HEAVY_STAMINA_SCALE if heavy else 1.0))
	_combo = _combo + 1 if Time.get_ticks_msec() < _combo_deadline else 1
	_combo_deadline = Time.get_ticks_msec() + int((_clip_time + COMBO_WINDOW) * 1000.0)

	last_swing = _clip
	_state = State.SWING
	_play_clip()
	swing_started.emit(_clip, heavy or _committed)
	return true


func _physics_process(delta: float) -> void:
	_ensure_rig()
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if _state != State.SWING:
		return
	_t += delta
	if not _struck and _t >= _strike_at:
		_strike()
	if _t >= _clip_time:
		_close_swing()


## Skeleton and locomotion are wired deferred by the Survivor, so the grip and
## the swing library are (re)tried until the rig exists. Idempotent.
func _ensure_rig() -> void:
	if _locomotion != null and not _library_ready:
		_ensure_library()
	if _hand == null:
		_attach_hand()
		if _hand != null:
			_refresh_model()


## True once the swing clips are registered on the rig's AnimationPlayer.
func has_animation() -> bool:
	return _library_ready


# --- Animation ---------------------------------------------------------------

func _ensure_library() -> void:
	if _library_ready or _locomotion == null or _locomotion.anim_player == null:
		return
	var ap := _locomotion.anim_player
	if not ap.has_animation_library(MeleeSwingLibrary.LIB_NAME):
		ap.add_animation_library(MeleeSwingLibrary.LIB_NAME,
				MeleeSwingLibrary.build_library(_skeleton != null))
	if not ap.animation_finished.is_connected(_on_clip_finished):
		ap.animation_finished.connect(_on_clip_finished)
	_library_ready = true


func _play_clip() -> void:
	if _locomotion != null and _locomotion.anim_player != null:
		var ap := _locomotion.anim_player
		if _locomotion.anim_tree != null:
			# The locomotion tree re-activates itself every frame, so the latch
			# has to live there -- flipping anim_tree.active here alone is
			# stomped before the first rendered frame of the swing.
			_locomotion.suspend_pose_authority(true)
		ap.speed_scale = 1.0
		ap.play("%s/%s" % [MeleeSwingLibrary.LIB_NAME, _clip])
		return
	# Rigs with no skeleton (primitive animator) fall back to the existing
	# single-pose attack cue; the directional clips need bones.
	if _animator != null:
		_animator.play_attack()


func _on_clip_finished(anim_name: StringName) -> void:
	if _state != State.SWING:
		return
	if String(anim_name).begins_with("%s/" % MeleeSwingLibrary.LIB_NAME):
		_close_swing()


## Return pose authority to the locomotion tree.
func _close_swing() -> void:
	_state = State.IDLE
	_struck = false
	_clip = &""
	if _locomotion != null and _locomotion.anim_player != null:
		var ap := _locomotion.anim_player
		ap.speed_scale = 1.0
		if _locomotion.anim_tree != null:
			_locomotion.suspend_pose_authority(false)


# --- Hit resolution ----------------------------------------------------------

func _strike() -> void:
	_struck = true
	var reach := float(_def.get("reach", 1.5))
	var arc := float(_def.get("arc_deg", 100.0))
	var cleave := int(_def.get("cleave", 1))
	var damage := float(_def.get("damage", 8.0))
	var stagger := float(_def.get("stagger", 2.0))
	var structural := float(_def.get("structural_scale", 1.0))

	damage *= _combo_multiplier()
	if _heavy or _committed:
		damage *= HEAVY_DAMAGE_SCALE if _heavy else COMMITTED_DAMAGE_SCALE
		stagger *= 1.3 if _heavy else 1.15

	var origin := actor.global_position + Vector3.UP * CHEST_HEIGHT
	var hits := _query_arc(origin, reach, arc)
	var applied := 0
	var total := 0.0
	for entry in hits:
		if applied >= cleave:
			break
		var collider: Node3D = entry["collider"]
		var dist: float = entry["distance"]
		var falloff := lerpf(1.0, FALLOFF_MIN, clampf(dist / maxf(0.01, reach), 0.0, 1.0))
		var dealt := damage * falloff
		if _damage_actor(collider, dealt, origin, stagger, entry["to_dir"]):
			applied += 1
			total += dealt
		elif _damage_structure(collider, dealt, structural, entry["point"]):
			applied += 1
	last_hits = applied
	if applied > 0:
		swing_landed.emit(_clip, applied, total)
	# Noise: zombies and other listeners react to swings, not to button presses.
	EventBus.attack_performed.emit(actor.global_position)


## Everything inside the swing arc, nearest first.
func _query_arc(origin: Vector3, reach: float, arc_deg: float) -> Array:
	var space := actor.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = reach
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, origin)
	params.collision_mask = HIT_MASK
	params.exclude = [actor.get_rid()]

	var half_arc := arc_deg * 0.5
	var seen := {}
	var hits: Array = []
	for hit in space.intersect_shape(params, 24):
		var collider = hit.get("collider")
		if collider == null or collider == actor:
			continue
		if not (collider is Node3D) or not is_instance_valid(collider):
			continue
		if not _is_swingable(collider):
			continue
		var cid: int = (collider as Node3D).get_instance_id()
		if seen.has(cid):
			continue
		var to_dir: Vector3 = (collider as Node3D).global_position - origin
		to_dir.y = 0.0
		var dist := to_dir.length()
		if dist > reach:
			continue
		var to_norm := to_dir.normalized() if dist > 0.001 else _swing_dir
		var angle := rad_to_deg(to_norm.angle_to(_swing_dir))
		if angle > half_arc:
			continue
		seen[cid] = true
		hits.append({
			"collider": collider,
			"distance": dist,
			"to_dir": to_norm,
			"point": origin + to_norm * minf(dist, reach),
		})
	hits.sort_custom(func(a, b): return a["distance"] < b["distance"])
	return hits


## Corpses, debris and dropped items are not valid swing targets.
func _is_swingable(collider: Node) -> bool:
	var health = collider.get("health")
	if health is HealthComponent:
		return not (health as HealthComponent).is_dead
	return collider.has_method(&"take_structural_damage")


func _damage_actor(target: Node3D, damage: float, origin: Vector3,
		stagger: float, to_dir: Vector3) -> bool:
	var health = target.get("health")
	if not (health is HealthComponent) or (health as HealthComponent).is_dead:
		return false
	if not target.has_method(&"take_damage"):
		return false
	target.call(&"take_damage", damage, actor.identity.persistent_id)
	if target.has_method(&"apply_knockback"):
		var push := _swing_dir * stagger + to_dir * stagger * 0.35
		push.y = maxf(push.y, 0.0)
		target.call(&"apply_knockback", push)
	var point := target.global_position + Vector3.UP * CHEST_HEIGHT * 0.6
	DebrisManager.burst_box(point, Vector3.ONE * 0.16,
			MaterialDB.get_material(&"flesh").get("debris_color"), &"flesh", 2, 1.4)
	# Per-type read: the burst and the reel are both scaled by how hard the blow
	# was, so a knife jab and an axe smash do not look like the same event.
	var force := clampf(damage / REFERENCE_DAMAGE, 0.5, 2.0)
	ImpactFX.spawn(ImpactFX.parent_for(target), point, _swing_dir, melee_type(), force)
	var react := target.get_node_or_null(^"HitReaction") as HitReaction
	if react != null:
		react.react_to_weapon(melee_type(), _swing_dir, force)
	return true


func _damage_structure(target: Node3D, damage: float, structural: float,
		point: Vector3) -> bool:
	if not target.has_method(&"take_structural_damage"):
		return false
	target.call(&"take_structural_damage", damage * structural,
			actor.identity.persistent_id)
	DebrisManager.burst_box(point, Vector3.ONE * 0.14,
			MaterialDB.get_material(_structure_material(target)).get("debris_color"),
			_structure_material(target), 2, 1.2)
	# A wall cannot reel, but the hit still has to read: the burst keeps the
	# weapon family's motion and borrows the material's colour.
	ImpactFX.spawn_structure(ImpactFX.parent_for(target), point, _swing_dir,
			melee_type(), _structure_material(target), 1.0)
	return true


## Material of a destructible so the splinters match what was hit.
func _structure_material(target: Node) -> StringName:
	if "material_id" in target:
		return StringName(target.get("material_id"))
	return &"wood"


func _combo_multiplier() -> float:
	var step := clampf(1.0 + COMBO_MULT_STEP * float(maxi(0, _combo - 1)),
			1.0, COMBO_MULT_CAP)
	if _combo > 0 and _combo % FINISHER_EVERY == 0:
		step *= FINISHER_BONUS
	return step


# --- Frames and aims ---------------------------------------------------------

## Actor frame: X = its right, Y = up, -Z = its facing (matches the rig, where
## local -Z is forward).
func _frame() -> Basis:
	var f := _forward()
	var right := f.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	return Basis(right.normalized(), Vector3.UP, -f)


func _forward() -> Vector3:
	if actor == null:
		return Vector3(0, 0, -1)
	var f := actor.facing
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return Vector3(0, 0, -1)
	return f.normalized()


## World aim -> the actor's own frame, flattened to the ground plane.
func _local_aim(aim_dir: Vector3) -> Vector3:
	var flat := aim_dir
	flat.y = 0.0
	if flat.length_squared() < 0.0001:
		return Vector3(0, 0, -1)
	return _frame().transposed() * flat.normalized()


func _refuse(reason: String) -> void:
	swing_refused.emit(reason)


# --- Held model --------------------------------------------------------------

func _attach_hand() -> void:
	if _skeleton == null or _hand != null:
		return
	var bone := HAND_BONE_ARTICULATED
	var idx := _skeleton.find_bone(bone)
	if idx < 0:
		bone = HAND_BONE_SIMPLE
		idx = _skeleton.find_bone(bone)
	if idx < 0:
		return
	var grip := SIMPLE_GRIP_DISTANCE
	if bone == HAND_BONE_ARTICULATED:
		grip = _skeleton.get_bone_rest(idx).origin.length() + GRIP_PAST_HAND
	var att := BoneAttachment3D.new()
	att.name = "MeleeHand"
	att.bone_name = bone
	# BoneAttachment3D copies the bone pose onto itself every frame, so anything
	# set on the attachment is overwritten by the animation. The grip offset and
	# the carry angle therefore live on a child holder that we own.
	var holder := Node3D.new()
	holder.name = "MeleeGrip"
	holder.position = Vector3(0, -grip, 0)
	# Weapons are modelled along +Z; rotating the holder +90 deg about X points
	# that axis down the arm, i.e. out of the fist, which is how a blade or a
	# wrench is actually carried.
	holder.rotation_degrees = Vector3(90, 0, 0)
	att.add_child(holder)
	_skeleton.add_child(att)
	_hand = att
	_grip = holder


func _refresh_model() -> void:
	if _mesh != null and is_instance_valid(_mesh):
		_mesh.queue_free()
	_mesh = null
	if _grip == null:
		return
	_mesh = MeleeWeaponModels.build(StringName(_def.get("model", &"fists")))
	_grip.add_child(_mesh)
	# Bare hands draw nothing at all: the fists model is an empty placeholder.
	_grip.visible = _weapon_id != &""


# --- Readouts ----------------------------------------------------------------

## Melee class of the equipped weapon (see MeleeTypes): the impact family, hit
## reaction and burst profile are all chosen from this.
func melee_type() -> StringName:
	return StringName(_def.get("melee_type", &"fist"))


## True while this swing owns the skeleton pose. A hit reaction must not start
## while this is true - both drive the same bones, so a reel fired mid-swing
## would have the two clips overwrite each other key by key.
func holds_pose() -> bool:
	return _state == State.SWING
