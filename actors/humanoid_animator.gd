class_name HumanoidAnimator
extends Node3D
## Code-driven character animation for HumanoidModel bodies: walk/run cycles,
## idle breathing, airborne (jump/blast) poses and attack swings - no
## skeleton needed, joints are simple pivots rotated procedurally.
##
## Attach as the PARENT of the model root:
##   visual_root -> HumanoidAnimator -> Model
## The animator adds body bob, lean and shamble sway on itself; limb motion
## is applied to the joint pivots from meta "anim_limbs".
##
## Owners feed it every frame with set_motion(); attacks via play_attack().

const RUN_SPEED_REF := 6.4          # Survivor.RUN_SPEED mirror for normalization
const WALK_FREQ := 6.2              # stride cycles/s at walking pace
const RUN_FREQ := 11.0              # at full sprint
const ATTACK_TIME := 0.38

var speed := 0.0                    # xz velocity length, set every frame
var airborne := false

var _limbs := {}
var _base := {}                     # pivot -> resting rotation (rad)
var _phase := randf() * TAU
var _idle_t := 0.0
var _attack_t := -1.0
var _bob := 0.0

# Flavor flags.
var shamble := false                # zombie gait: sway + dragging leg
var _sway_sign := 1.0
var _drag := 1.0


func configure(limbs: Dictionary, opts: Dictionary = {}) -> void:
	_limbs = limbs
	shamble = bool(opts.get("shamble", false))
	_sway_sign = -1.0 if randf() < 0.5 else 1.0
	_drag = randf_range(0.3, 0.65)
	for key: String in limbs:
		var pivot: Node3D = limbs[key]
		_base[key] = pivot.rotation


func play_attack() -> void:
	_attack_t = 0.0


func stop() -> void:
	set_process(false)


func set_motion(xz_speed: float, is_airborne: bool) -> void:
	speed = xz_speed
	airborne = is_airborne


func _process(delta: float) -> void:
	_idle_t += delta
	if _attack_t >= 0.0:
		_attack_t += delta
		if _attack_t >= ATTACK_TIME + 0.1:
			_attack_t = -1.0

	if not is_inside_tree():
		return

	if airborne:
		_pose_air()
	elif speed > 0.2:
		var run_ratio := clampf(speed / RUN_SPEED_REF, 0.15, 1.0)
		_phase += lerpf(WALK_FREQ, RUN_FREQ, run_ratio) * delta
		_pose_walk(run_ratio)
	else:
		_pose_idle()

	_apply_attack_overlay()
	_body_flair(delta, clampf(speed / RUN_SPEED_REF, 0.0, 1.0))


# --- Poses -------------------------------------------------------------------

func _swing(key: String, angle_rad: float) -> void:
	var pivot: Node3D = _limbs.get(key)
	if pivot == null:
		return
	var base: Vector3 = _base.get(key, Vector3.ZERO)
	pivot.rotation = Vector3(base.x + angle_rad, base.y, base.z)


func _pose_walk(run_ratio: float) -> void:
	var amp := deg_to_rad(lerpf(24.0, 46.0, run_ratio))
	var swing := sin(_phase) * amp
	var drag_mul := _drag if shamble else 1.0
	_swing("l_leg", swing * drag_mul)
	_swing("r_leg", -swing)
	# Arms counter-swing; zombies keep them reaching forward-ish.
	var arm_amp := amp * (0.35 if shamble else 0.8)
	var reach := deg_to_rad(-70.0) if shamble else 0.0
	_swing("l_arm", -swing * arm_mul() + reach * 0.9)
	_swing("r_arm", swing * arm_mul() + reach)
	_swing("upper", lerpf(deg_to_rad(4.0), deg_to_rad(14.0), run_ratio))


func arm_mul() -> float:
	return 0.55 if shamble else 1.0


func _pose_idle() -> void:
	_phase = 0.0
	var breathe := sin(_idle_t * 1.7) * deg_to_rad(2.2)
	var sway := sin(_idle_t * 1.3 + 1.0) * deg_to_rad(1.6)
	_swing("upper", breathe * 0.6)
	_swing("l_arm", breathe + sway)
	_swing("r_arm", -breathe - sway)
	_swing("l_leg", 0.0)
	_swing("r_leg", 0.0)
	position.y = lerpf(position.y, 0.0, 8.0 * get_process_delta_time())


func _pose_air() -> void:
	# Jump/blast pose: legs tucked split, arms flung up-back.
	var flutter := sin(_idle_t * 14.0) * deg_to_rad(6.0)
	_swing("l_leg", deg_to_rad(-52.0))
	_swing("r_leg", deg_to_rad(28.0))
	_swing("l_arm", deg_to_rad(-135.0) + flutter)
	_swing("r_arm", deg_to_rad(-125.0) - flutter)
	_swing("upper", deg_to_rad(-8.0))
	position.y = lerpf(position.y, 0.06, 8.0 * get_process_delta_time())


## Attack overrides the right arm (humans: overhead chop; zombies: both
## arms lunge forward for the grab).
func _apply_attack_overlay() -> void:
	if _attack_t < 0.0:
		return
	var p := clampf(_attack_t / ATTACK_TIME, 0.0, 1.0)
	if shamble:
		var reach_p := 1.0 - absf(p * 2.0 - 1.0)   # out and back
		var reach := deg_to_rad(-95.0) * ease(reach_p, 0.5)
		_swing("l_arm", reach)
		_swing("r_arm", reach)
		_swing("upper", deg_to_rad(10.0) * reach_p)
	else:
		# Windup back high, then chop down through the target.
		var ang: float
		if p < 0.35:
			ang = lerpf(deg_to_rad(70.0), deg_to_rad(95.0), p / 0.35)
		else:
			var q := (p - 0.35) / 0.65
			ang = lerpf(deg_to_rad(95.0), deg_to_rad(-150.0),
					ease(q, 0.35))
		_swing("r_arm", ang)
		_swing("l_arm", -ang * 0.25)
		_swing("upper", deg_to_rad(lerpf(-4.0, 16.0, p)))


## Whole-body touches on the animator node itself: bob, lean roll, shamble.
func _body_flair(_delta: float, run_ratio: float) -> void:
	if not shamble:
		rotation.z = 0.0
		return
	# Zombie lurch: side-to-side roll synced to the stride plus stagger.
	rotation.z = sin(_phase * 0.5 + 0.4) * deg_to_rad(5.0) * _sway_sign \
			+ sin(_idle_t * 0.9) * deg_to_rad(1.5)
