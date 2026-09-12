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
signal guard_started()
signal guard_broken()
signal parried()
signal riposte_started()
signal guard_ended()
signal charge_started()
signal charge_updated(held_seconds: float, heavy: bool)
signal charge_released(held_seconds: float, heavy: bool)

enum State { IDLE, SWING, GUARD, GUARD_BREAK }

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
const HOLD_THRESHOLD := 0.20
const RIPOSTE_WINDOW := 0.60
const GUARD_SPEED_SCALE := 0.45
const GUARD_BREAK_TIME := 0.90
const GUARD_LOCK_TIME := 1.20
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
var _riposte := false
var _cooldown_left := 0.0
var _combo := 0
var _combo_deadline := 0.0
var _swing_dir := Vector3(0, 0, -1)
var _library_ready := false

# Input is deliberately owned by this component so the player controller only
# needs to report the LMB press. AI/tests still call try_attack() directly and
# bypass the input latch.
var _attack_pressed := false
var _attack_aim := Vector3(0, 0, -1)
var _attack_held := 0.0
var _guard_started_at := 0.0
var _guard_lock_left := 0.0
var _riposte_armed_until := 0.0
var _last_guard_result: Dictionary = {}
var _processing_external_damage := false
var _guard_events := 0
var _parry_events := 0
var _guard_break_events := 0


func setup(p_actor: Survivor, skeleton: Skeleton3D,
		locomotion: CharacterLocomotion, animator: HumanoidAnimator) -> void:
	actor = p_actor
	_skeleton = skeleton
	_locomotion = locomotion
	_animator = animator
	if actor.health != null and not actor.health.damaged.is_connected(_on_actor_damaged):
		actor.health.damaged.connect(_on_actor_damaged)
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
	return (_def.get("combo_chain", _def.get("swing_pool", [])) as Array).duplicate()


func combo_definition() -> Dictionary:
	return (_def.get("combo", {}) as Dictionary).duplicate(true)


func light_chain() -> Array:
	return swing_pool()


func heavy_clip() -> StringName:
	return StringName(_def.get("heavy_clip", &""))


func unique_clip() -> StringName:
	return StringName(_def.get("unique_clip", &""))


func guard_clip() -> StringName:
	return StringName(_def.get("guard_clip", &""))


func counter_clip() -> StringName:
	return StringName(_def.get("counter_clip", &""))


## Pure LMB classifier: a tap is light, a hold released at the threshold is
## heavy. Keeping this free of Input and time makes the boundary testable.
static func classify_press(held_s: float) -> bool:
	return held_s >= HOLD_THRESHOLD


func charge_elapsed() -> float:
	return _attack_held if _attack_pressed else 0.0


func charge_ratio() -> float:
	return clampf(charge_elapsed() / HOLD_THRESHOLD, 0.0, 1.0)


func is_charging() -> bool:
	return _attack_pressed


func state() -> int:
	return _state


func is_guarding() -> bool:
	return _state == State.GUARD


func is_guard_broken() -> bool:
	return _state == State.GUARD_BREAK


func guard_stamina() -> float:
	if actor == null or not is_instance_valid(actor):
		return 0.0
	return actor.stamina


func guard_absorb() -> float:
	return float(_def.get("guard_absorb", 0.25))


func parry_window() -> float:
	return float(_def.get("parry_window", 0.0))


func block_cost() -> float:
	return float(_def.get("block_cost", 5.0))


func riposte_armed() -> bool:
	return Time.get_ticks_msec() < _riposte_armed_until


func guard_event_counts() -> Dictionary:
	return {"started": _guard_events, "parried": _parry_events,
		"broken": _guard_break_events}



## IDLE / WINDUP / STRIKE / RECOVER -- readable phase for HUD and tests.
func phase() -> String:
	if _state == State.GUARD:
		return "GUARD"
	if _state == State.GUARD_BREAK:
		return "GUARD_BREAK"
	if _attack_pressed:
		return "CHARGE"
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


## Called by PlayerController on LMB press, or directly by AI/tests. A real
## player press is latched until release so the same LMB produces a tap light or
## a charged heavy without exposing a second mouse action.
func try_attack(aim_dir := Vector3.ZERO, want_heavy := false) -> bool:
	if actor != null and actor.is_player() and not want_heavy:
		if InputMap.has_action(&"attack") and Input.is_action_just_pressed(&"attack"):
			return _begin_attack_press(aim_dir)
		if _attack_pressed:
			return false
	return _begin_attack(aim_dir, want_heavy)


func _begin_attack(aim_dir := Vector3.ZERO, want_heavy := false) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if actor.health.is_dead or actor.needs.sleeping:
		_refuse("dead_or_asleep")
		return false
	if _state == State.GUARD:
		_refuse("guarding")
		return false
	if _state == State.GUARD_BREAK:
		_refuse("guard_break")
		return false
	if _cooldown_left > 0.0:
		_refuse("cooldown")
		return false
	if _state == State.SWING:
		if not _struck or _t < _clip_time * CANCEL_FROM:
			_refuse("mid_swing")
			return false

	last_downgraded = false
	_committed = false
	_riposte = false
	var combo: Dictionary = _def.get("combo", {}) as Dictionary
	var chain: Array = combo.get("chain", []) as Array
	var next_step := _next_combo_step(chain.size())
	var step: Dictionary = MeleeCombos.step_for(combo, next_step)
	var heavy := want_heavy
	var cost := float(step.get("stamina", _def.get("stamina_cost", 5.0)))
	var heavy_name := heavy_clip()
	if heavy:
		if heavy_name == &"":
			heavy = false
			_committed = true
		elif actor.stamina < float(_def.get("stamina_cost", cost)) * HEAVY_STAMINA_SCALE:
			# Not enough stamina for the charged move: preserve the input as a
			# light step rather than eating the press.
			heavy = false
			last_downgraded = true
	if heavy:
		cost = float(_def.get("stamina_cost", cost)) * HEAVY_STAMINA_SCALE
	elif want_heavy and heavy_name == &"":
		_committed = true
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

	var now := Time.get_ticks_msec()
	if not heavy and counter_clip() != &"" and now < _riposte_armed_until:
		_clip = counter_clip()
		_riposte = true
		_riposte_armed_until = 0
	elif heavy:
		_clip = heavy_name
	else:
		_clip = chain[(next_step - 1) % chain.size()] as StringName if not chain.is_empty() else \
			MeleeSwingLibrary.direction_for(swing_local, _def.get("swing_pool", []), false)
	_heavy = heavy


	if _state == State.SWING:
		_close_swing()   # interrupt: same bookkeeping as a natural finish

	var speed := float(_def.get("clip_speed", 1.0))
	if not heavy:
		speed *= float(step.get("speed_scale", 1.0))
	speed *= HEAVY_SPEED_SCALE if heavy else 1.0
	speed *= COMMITTED_SPEED_SCALE if _committed else 1.0
	if _riposte:
		speed *= 1.10
	_clip_time = MeleeSwingLibrary.clip_length(_clip) / maxf(0.1, speed)
	_strike_at = MeleeSwingLibrary.hit_time(_clip) / maxf(0.1, speed)
	_t = 0.0
	_struck = false
	_cooldown_left = float(_def.get("cooldown", 0.7))

	actor.stamina = maxf(0.0, actor.stamina - cost)
	if heavy:
		_combo = 0
	elif _riposte:
		_combo = 1
	else:
		_combo = next_step
	_combo_deadline = Time.get_ticks_msec() + int((_clip_time + COMBO_WINDOW) * 1000.0)

	last_swing = _clip
	_state = State.SWING
	_play_clip()
	if _riposte:
		riposte_started.emit()
	swing_started.emit(_clip, heavy or _committed)
	return true


func _physics_process(delta: float) -> void:
	_ensure_rig()
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_guard_lock_left = maxf(0.0, _guard_lock_left - delta)

	if actor != null and is_instance_valid(actor) and actor.is_player():
		if InputMap.has_action(&"attack") and Input.is_action_just_pressed(&"attack"):
			if not _attack_pressed:
				_begin_attack_press(actor.facing)
		if _attack_pressed:
			_attack_held += delta
			charge_updated.emit(_attack_held, classify_press(_attack_held))
			if Input.is_action_just_released(&"attack"):
				_release_attack()
		var block_held := InputMap.has_action(&"block") and Input.is_action_pressed(&"block")
		if block_held:
			set_guarding(true)
		elif _state == State.GUARD:
			set_guarding(false)

	if _state == State.GUARD_BREAK:
		if _guard_lock_left <= 0.0:
			_state = State.IDLE
			_clip = &""
			_resume_pose()
		return
	if _state == State.GUARD:
		_apply_guard_movement_cap()
		return
	if _state != State.SWING:
		return
	_t += delta
	if not _struck and _t >= _strike_at:
		_strike()
	if _t >= _clip_time:
		_close_swing()


func _begin_attack_press(aim_dir: Vector3) -> bool:
	if _state != State.IDLE or _cooldown_left > 0.0:
		_refuse("guarding" if _state == State.GUARD else "cooldown" if _cooldown_left > 0.0 else "mid_swing")
		return false
	_attack_pressed = true
	_attack_aim = aim_dir
	_attack_held = 0.0
	charge_started.emit()
	return true


func _release_attack() -> void:
	if not _attack_pressed:
		return
	var held := _attack_held
	var heavy := classify_press(held)
	_attack_pressed = false
	_attack_held = 0.0
	charge_released.emit(held, heavy)
	_begin_attack(_attack_aim, heavy)


func _next_combo_step(chain_size: int) -> int:
	if chain_size <= 0 or Time.get_ticks_msec() >= _combo_deadline:
		return 1
	var next := _combo + 1
	return 1 if next > chain_size else next


## Explicit guard control is used by the input loop and by headless combat
## tests. Holding guard never consumes stamina by itself; impacts do.
func set_guarding(want_guard: bool) -> bool:
	if want_guard:
		if _state == State.GUARD:
			return true
		if _state != State.IDLE or _guard_lock_left > 0.0:
			return false
		if actor == null or not is_instance_valid(actor):
			return false
		_state = State.GUARD
		_guard_started_at = float(Time.get_ticks_msec()) / 1000.0
		_clip = guard_clip()
		_guard_events += 1
		_play_clip()
		guard_started.emit()
		return true
	if _state != State.GUARD:
		return false
	_state = State.IDLE
	_clip = &""
	_resume_pose()
	guard_ended.emit()
	return true


func _apply_guard_movement_cap() -> void:
	if actor == null or not is_instance_valid(actor):
		return
	# Survivor applies its requested move before this child ticks. Clamp the
	# request for the next frame while preserving direction, then cap current
	# velocity so guard never gives one unscaled frame of movement.
	var move: Variant = actor.get("_move_dir")
	if move is Vector3 and (move as Vector3).length_squared() > 0.0001:
		actor.set("_move_dir", (move as Vector3).normalized() * GUARD_SPEED_SCALE)
	var velocity := actor.velocity
	velocity.x *= GUARD_SPEED_SCALE
	velocity.z *= GUARD_SPEED_SCALE
	actor.velocity = velocity


## Resolve an incoming blow against the guard. Attackers may pass themselves so
## a perfect parry can stagger them; null is valid for environmental tests.
func receive_impact(amount: float, attack_dir := Vector3.ZERO,
		attacker: Node = null) -> Dictionary:
	var result := {"blocked": false, "parried": false, "guard_broken": false,
		"damage": maxf(0.0, amount), "stamina_cost": 0.0}
	if actor == null or not is_instance_valid(actor) or not is_guarding():
		return result
	var now_s := float(Time.get_ticks_msec()) / 1000.0
	var guard_age := now_s - _guard_started_at
	var parry := parry_window()
	var impact_dir := attack_dir
	impact_dir.y = 0.0
	if impact_dir.length_squared() < 0.0001:
		impact_dir = -_forward()
	else:
		impact_dir = impact_dir.normalized()
	if parry > 0.0 and guard_age <= parry:
		_riposte_armed_until = Time.get_ticks_msec() + int(RIPOSTE_WINDOW * 1000.0)
		_parry_events += 1
		result["blocked"] = true
		result["parried"] = true
		result["damage"] = 0.0
		result["riposte_until"] = _riposte_armed_until
		if attacker != null and is_instance_valid(attacker):
			if attacker.has_method(&"apply_knockback"):
				attacker.call(&"apply_knockback", -impact_dir * 2.5)
			if attacker.has_method(&"apply_stagger"):
				attacker.call(&"apply_stagger", GUARD_BREAK_TIME)
		parried.emit()
		_last_guard_result = result.duplicate()
		return result

	var cost := block_cost()
	actor.stamina = maxf(0.0, actor.stamina - cost)
	result["blocked"] = true
	result["stamina_cost"] = cost
	if actor.stamina <= 0.0001:
		_trigger_guard_break()
		result["guard_broken"] = true
		_apply_guard_damage_once(amount, impact_dir)
		result["damage"] = amount
	else:
		var mitigated := amount * (1.0 - guard_absorb())
		_apply_guard_damage_once(mitigated, impact_dir)
		result["damage"] = mitigated
	_last_guard_result = result.duplicate()
	return result


## Survivors and zombies use HealthComponent directly for legacy damage paths.
## Reconcile those hits here so RMB guarding also protects against bites and
## other non-melee callers without making every attacker know MeleeCombat.
func _on_actor_damaged(amount: float, source_id: StringName) -> void:
	if _processing_external_damage or not is_guarding() or amount <= 0.0:
		return
	var attacker: Node = null
	if source_id != &"":
		var found: Node3D = ActorRegistry.get_actor(source_id)
		if found != null and is_instance_valid(found):
			attacker = found
	_processing_external_damage = true
	var result := receive_impact(amount, -_forward(), attacker)
	_processing_external_damage = false
	var restored := amount - float(result.get("damage", amount))
	if restored > 0.0 and actor.health != null and not actor.health.is_dead:
		actor.health.heal(restored)


func _apply_guard_damage_once(amount: float, impact_dir: Vector3) -> void:
	if _processing_external_damage:
		return
	_processing_external_damage = true
	_apply_guard_damage(amount, impact_dir)
	_processing_external_damage = false


func _apply_guard_damage(amount: float, impact_dir: Vector3) -> void:
	if amount > 0.0 and actor.health != null:
		actor.health.damage(amount, &"guarded_attack")
	if actor.has_method(&"apply_knockback"):
		actor.call(&"apply_knockback", impact_dir * 0.35)


func _trigger_guard_break() -> void:
	if _state == State.GUARD_BREAK:
		return
	_state = State.GUARD_BREAK
	_guard_lock_left = GUARD_LOCK_TIME
	_clip = &""
	_guard_break_events += 1
	_resume_pose()
	guard_broken.emit()


## Stop the held guard pose and let locomotion own the skeleton again.
func _resume_pose() -> void:
	if _locomotion != null and _locomotion.anim_player != null:
		_locomotion.anim_player.stop()
		_locomotion.anim_player.speed_scale = 1.0
		if _locomotion.anim_tree != null:
			_locomotion.suspend_pose_authority(false)


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
	_riposte = false
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
	if not _heavy and not _riposte:
		var combo: Dictionary = _def.get("combo", {}) as Dictionary
		var step: Dictionary = MeleeCombos.step_for(combo, maxi(1, _combo))
		damage *= float(step.get("damage_scale", 1.0))
	if _riposte:
		damage *= 1.6
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
	return _state == State.SWING or _state == State.GUARD
