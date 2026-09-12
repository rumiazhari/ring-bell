class_name HitReaction
extends Node
## Per-actor one-shot hit reaction (see HitReactionLibrary for the clips).
##
## POSING CONTRACT: a reaction and a melee swing both write the skeleton's bone
## rotations, so exactly one of them may own the pose. The actor answers
## `pose_locked()` while a swing is committed; a reaction asked to play then is
## REFUSED (counted, never queued) so an incoming hit cannot visually cancel a
## blow the actor has already thrown. When the reaction does play it takes the
## SAME CharacterLocomotion pose latch the swing uses and releases it when the
## clip ends - so a reaction can never leave the actor frozen mid-reel.
##
## Actors without the articulated rig still count reactions (plays/refusals) but
## report `renders() == false`: no pose is held, nothing is faked.

signal reaction_started(impact: StringName, kind: StringName)
signal reaction_finished(impact: StringName)

## A second hit must wait out this fraction of the current reel before it can
## re-jab, or a crowd of four attackers would resample the clip every frame.
const REJAB_AFTER := 0.35

var actor: Node3D = null
var skeleton: Skeleton3D = null
var locomotion: Node = null
var kind: StringName = HitReactionLibrary.KIND_HUMAN

var plays := 0                 # reactions that actually played
var refusals := 0              # refused because a swing owns the pose
var rejabs := 0                # refused because the reel is still early
var last_impact: StringName = &""
var last_force := 0.0
var last_dir := Vector3.ZERO

var _anim: AnimationPlayer = null
var _rig_ok := false
var _playing := false
var _impact: StringName = &""
var _clip_path := ""
var _t := 0.0
var _length := 0.0
var _speed := 1.0


func setup(p_actor: Node3D, p_skeleton: Skeleton3D, p_locomotion: Node,
		p_kind: StringName) -> void:
	actor = p_actor
	skeleton = p_skeleton
	locomotion = p_locomotion
	kind = p_kind
	set_process(false)
	if locomotion != null and "anim_player" in locomotion:
		_anim = locomotion.get("anim_player") as AnimationPlayer
	if _anim == null or not is_instance_valid(_anim):
		return
	# Only the skeleton rig can be posed; the primitive fallback rig has no
	# bone tracks to drive.
	if skeleton == null or not is_instance_valid(skeleton):
		return
	var articulated: bool = skeleton.get_meta("articulated", false)
	if not _anim.has_animation_library(HitReactionLibrary.LIB_NAME):
		_anim.add_animation_library(HitReactionLibrary.LIB_NAME,
				HitReactionLibrary.build_library(kind, articulated))
	# The locomotion setup normally owns root_node; a reaction registered before
	# it (deferred ordering) still has to point the player at the skeleton.
	if _anim.root_node == NodePath("") and _anim.is_inside_tree() \
			and skeleton.is_inside_tree():
		_anim.root_node = _anim.get_path_to(skeleton)
	_rig_ok = true


## Reaction for a weapon hit. `melee_type` is the weapon class (see MeleeTypes);
## `force` is the dealt damage normalised around a 20-damage reference blow.
func react_to_weapon(melee_type: StringName, dir: Vector3, force := 1.0) -> bool:
	return react_impact(HitReactionLibrary.impact_for(melee_type), dir, force)


## Reaction for an impact family directly (bites, explosions, scripted events).
func react_impact(impact: StringName, dir: Vector3, force := 1.0) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if not HitReactionLibrary.has(kind, impact):
		return false
	if _dead():
		return false
	# A committed swing outranks an incoming hit: never cancel the actor's blow.
	if _pose_locked():
		refusals += 1
		return false
	if _playing and progress() < REJAB_AFTER:
		rejabs += 1
		return false
	_impact = impact
	last_impact = impact
	last_force = force
	last_dir = dir.normalized() if dir.length() > 0.001 else Vector3.ZERO
	plays += 1
	if not _rig_ok:
		reaction_started.emit(impact, kind)
		return true
	_clip_path = HitReactionLibrary.clip_path(kind, impact)
	_length = HitReactionLibrary.clip_length(kind, impact)
	_speed = HitReactionLibrary.speed_scale(force)
	_t = 0.0
	_playing = true
	_suspend(true)
	_anim.play(_clip_path, -1.0, _speed)
	set_process(true)
	reaction_started.emit(impact, kind)
	return true


func _process(delta: float) -> void:
	if not _playing:
		return
	_t += delta
	if _t < _length / maxf(0.01, _speed):
		return
	_stop()


func _stop() -> void:
	_playing = false
	set_process(false)
	if _anim != null and is_instance_valid(_anim) and _anim.current_animation == _clip_path:
		_anim.stop()
	_suspend(false)
	var done := _impact
	_impact = &""
	reaction_finished.emit(done)


## Called by the actor when it dies: releases the pose latch without pretending
## the reel finished.
func cancel() -> void:
	if not _playing:
		return
	_stop()


# --- State -------------------------------------------------------------------

func is_playing() -> bool:
	return _playing


func holds_pose() -> bool:
	return _playing


func current_impact() -> StringName:
	return _impact


func kind_id() -> StringName:
	return kind


## 0..1 through the current reel (1 when idle).
func progress() -> float:
	if not _playing:
		return 1.0
	return clampf(_t / maxf(0.001, _length / maxf(0.01, _speed)), 0.0, 1.0)


## True when the reaction can drive the skeleton (articulated rig present).
func renders() -> bool:
	return _rig_ok


func summary() -> Dictionary:
	return {
		"kind": kind, "plays": plays, "refusals": refusals, "rejabs": rejabs,
		"last_impact": last_impact, "renders": _rig_ok, "playing": _playing,
	}


# --- Internals ---------------------------------------------------------------

func _pose_locked() -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if actor.has_method(&"pose_locked"):
		return bool(actor.call(&"pose_locked"))
	# No actor-level answer: ask the swing component directly, so an actor only
	# has to own a MeleeCombat to be protected from a mid-swing reel.
	var swing = actor.get(&"melee")
	if swing != null and swing.has_method(&"holds_pose"):
		return bool(swing.call(&"holds_pose"))
	return false


func _dead() -> bool:
	var health = actor.get("health")
	if health is HealthComponent:
		return (health as HealthComponent).is_dead
	return false


func _suspend(suspended: bool) -> void:
	if locomotion != null and is_instance_valid(locomotion) \
			and locomotion.has_method(&"suspend_pose_authority"):
		locomotion.call(&"suspend_pose_authority", suspended)
