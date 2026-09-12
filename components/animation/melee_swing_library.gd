class_name MeleeSwingLibrary
extends RefCounted
## Procedural multi-directional melee swing clips.
##
## Eight direction-authored attack animations. Same authoring contract as
## LocomotionLibrary: rotation tracks only (never position), no root bone track,
## explicit key times, LOOP_NONE.
##
## Rig signs were verified empirically with debug/melee_axis_probe.gd
## (`--meleeprobe`), not assumed:
##   arm  X+  = swing FORWARD (X+150 = overhead-forward), X- = back
##   arm  Z+  = abduct toward the character's RIGHT -- identical for BOTH arms
##              (the rig does not mirror arm bones, so a symmetric pose uses
##              +Z on the right arm and -Z on the left)
##   arm  Y   = twist
##   forearm X+ = elbow curl (hand toward the shoulder)
##   spine_upper X- = lean FORWARD, Y+ = right shoulder swings FORWARD
##   hips Y+ = hips rotate with the right side forward
##
## Aim space for direction resolution: local -Z is forward, +X is the
## character's right, so `atan2(aim.x, -aim.z)` gives 0 deg straight ahead,
## +90 deg to the right, -90 deg to the left.

## Canonical direction ids (also the clip names).
const CLIPS: Array[StringName] = [
	&"SlashR", &"SlashL", &"Chop", &"Thrust", &"DiagR", &"DiagL",
	&"Smash", &"Sweep",
	# Cane-sabre
	&"SabreSlashR", &"SabreSlashL", &"SabreDiagR", &"SabreThrust",
	&"SabreWhirl", &"SabreGuardHold", &"SabreRiposte",
	# Pipe wrench
	&"WrenchOverhead", &"WrenchBackhand", &"WrenchCrush", &"WrenchSlam",
	&"WrenchHookPull", &"WrenchGuardHold", &"WrenchCounter",
	# Boarding axe
	&"AxeChopR", &"AxeChopL", &"AxeCleave", &"AxeHookDrag", &"AxeRend",
	&"AxeGuardHold", &"AxeCounter",
	# Boiler lance
	&"LanceThrustHigh", &"LanceThrustLow", &"LanceWideSweep", &"LanceCharge",
	&"LanceSpiralSweep", &"LanceGuardHold", &"LanceCounter",
	# Bare hands
	&"JabR", &"JabL", &"HookR", &"Shove", &"FistsGuardHold",
]

const LIB_NAME := &"melee"

## Bones every swing drives. Forearms are appended only for articulated rigs.
const BASE_BONES: Array[String] = ["hips", "spine_upper", "r_upper_arm", "l_upper_arm"]
const FORE_BONES: Array[String] = ["r_forearm", "l_forearm"]
const THIGH_BONES: Array[String] = ["l_thigh", "r_thigh"]

## Per-clip definition. `entry` is the aim angle (deg) the swing naturally
## covers from the character's own frame, `tol` how wide that coverage is.
## Poses are authored as windup / strike / follow; every clip settles to rest.
const DEFS := {
	&"SlashR": {
		"length": 0.46, "hit": 0.42, "entry": 60.0, "tol": 45.0,
		"heavy": false, "upper_only": true, "label": "Right to left",
		"wind": {
			"spine_upper": Vector3(-4, 26, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3(34, 0, 0),
			"l_upper_arm": Vector3(10, 0, -16),
		},
		"strike": {
			"spine_upper": Vector3(2, -30, 0), "hips": Vector3(0, -16, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3(10, 0, 0),
			"l_upper_arm": Vector3(2, 0, 26),
		},
		"follow": {
			"spine_upper": Vector3(6, -40, 0), "hips": Vector3(0, -22, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3(26, 0, 0),
			"l_upper_arm": Vector3(-4, 0, 34),
		},
	},
	&"SlashL": {
		"length": 0.46, "hit": 0.42, "entry": -60.0, "tol": 45.0,
		"heavy": false, "label": "Left to right",
		"wind": {
			"spine_upper": Vector3(-4, 26, 0), "hips": Vector3(0, 14, 0),
			"l_upper_arm": Vector3(-12, 0, -62), "l_forearm": Vector3(34, 0, 0),
			"r_upper_arm": Vector3(10, 0, 16),
		},
		"strike": {
			"spine_upper": Vector3(2, -30, 0), "hips": Vector3(0, -16, 0),
			"l_upper_arm": Vector3(56, 0, 34), "l_forearm": Vector3(10, 0, 0),
			"r_upper_arm": Vector3(2, 0, -26),
		},
		"follow": {
			"spine_upper": Vector3(6, -40, 0), "hips": Vector3(0, -22, 0),
			"l_upper_arm": Vector3(46, 0, 58), "l_forearm": Vector3(26, 0, 0),
			"r_upper_arm": Vector3(-4, 0, -34),
		},
	},
	&"Chop": {
		"length": 0.55, "hit": 0.40, "entry": 0.0, "tol": 24.0,
		"heavy": false, "upper_only": true, "label": "Overhead chop",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3(48, 0, 0),
			"l_upper_arm": Vector3(142, 0, -12),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(22, 0, -6),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3(18, 0, 0),
			"l_upper_arm": Vector3(6, 0, -4),
		},
	},
	&"Thrust": {
		"length": 0.50, "hit": 0.38, "entry": 0.0, "tol": 20.0,
		"heavy": false, "label": "Forward thrust",
		"wind": {
			"spine_upper": Vector3(-6, -20, 0), "hips": Vector3(0, -10, 0),
			"r_upper_arm": Vector3(-26, 0, 10), "r_forearm": Vector3(92, 0, 0),
			"l_upper_arm": Vector3(14, 0, -10),
		},
		"strike": {
			"spine_upper": Vector3(-10, 16, 0), "hips": Vector3(0, 12, 0),
			"r_upper_arm": Vector3(84, 0, -4), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(-10, 0, 16),
		},
		"follow": {
			"spine_upper": Vector3(-6, 20, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(80, 0, -6), "r_forearm": Vector3(12, 0, 0),
			"l_upper_arm": Vector3(-12, 0, 20),
		},
	},
	&"DiagR": {
		"length": 0.50, "hit": 0.40, "entry": 28.0, "tol": 22.0,
		"heavy": false, "label": "High right to low left",
		"wind": {
			"spine_upper": Vector3(-12, -20, 0), "hips": Vector3(-4, -10, 0),
			"r_upper_arm": Vector3(128, 0, 48), "r_forearm": Vector3(40, 0, 0),
			"l_upper_arm": Vector3(24, 0, -18),
		},
		"strike": {
			"spine_upper": Vector3(6, 26, 0), "hips": Vector3(4, 14, 0),
			"r_upper_arm": Vector3(46, 0, -34), "r_forearm": Vector3(8, 0, 0),
			"l_upper_arm": Vector3(4, 0, 20),
		},
		"follow": {
			"spine_upper": Vector3(10, 32, 0), "hips": Vector3(6, 18, 0),
			"r_upper_arm": Vector3(18, 0, -48), "r_forearm": Vector3(20, 0, 0),
			"l_upper_arm": Vector3(-2, 0, 26),
		},
	},
	&"DiagL": {
		"length": 0.50, "hit": 0.40, "entry": -28.0, "tol": 22.0,
		"heavy": false, "label": "High left to low right",
		"wind": {
			"spine_upper": Vector3(-12, 20, 0), "hips": Vector3(-4, 10, 0),
			"l_upper_arm": Vector3(128, 0, -48), "l_forearm": Vector3(40, 0, 0),
			"r_upper_arm": Vector3(24, 0, 18),
		},
		"strike": {
			"spine_upper": Vector3(6, -26, 0), "hips": Vector3(4, -14, 0),
			"l_upper_arm": Vector3(46, 0, 34), "l_forearm": Vector3(8, 0, 0),
			"r_upper_arm": Vector3(4, 0, -20),
		},
		"follow": {
			"spine_upper": Vector3(10, -32, 0), "hips": Vector3(6, -18, 0),
			"l_upper_arm": Vector3(18, 0, 48), "l_forearm": Vector3(20, 0, 0),
			"r_upper_arm": Vector3(-2, 0, -26),
		},
	},
	&"Smash": {
		"length": 1.05, "hit": 0.46, "entry": 0.0, "tol": 26.0,
		"heavy": true, "label": "Two-handed overhead smash",
		"wind": {
			"spine_upper": Vector3(-24, 0, 0), "hips": Vector3(-10, 0, 0),
			"r_upper_arm": Vector3(158, 0, 14), "r_forearm": Vector3(56, 0, 0),
			"l_upper_arm": Vector3(152, 0, -14), "l_forearm": Vector3(52, 0, 0),
			"l_thigh": Vector3(10, 0, 0), "r_thigh": Vector3(10, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(26, 0, 0), "hips": Vector3(10, 0, 0),
			"r_upper_arm": Vector3(32, 0, 4), "r_forearm": Vector3(4, 0, 0),
			"l_upper_arm": Vector3(26, 0, -4), "l_forearm": Vector3(4, 0, 0),
			"l_thigh": Vector3(20, 0, 0), "r_thigh": Vector3(20, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(30, 0, 0), "hips": Vector3(12, 0, 0),
			"r_upper_arm": Vector3(10, 0, 0), "r_forearm": Vector3(22, 0, 0),
			"l_upper_arm": Vector3(8, 0, 0), "l_forearm": Vector3(20, 0, 0),
			"l_thigh": Vector3(14, 0, 0), "r_thigh": Vector3(14, 0, 0),
		},
	},
	&"Sweep": {
		"length": 0.80, "hit": 0.46, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Wide horizontal sweep",
		"wind": {
			"spine_upper": Vector3(-8, -54, 0), "hips": Vector3(0, -24, 0),
			"r_upper_arm": Vector3(24, 0, 78), "r_forearm": Vector3(30, 0, 0),
			"l_upper_arm": Vector3(16, 0, -34),
		},
		"strike": {
			"spine_upper": Vector3(4, 62, 0), "hips": Vector3(0, 26, 0),
			"r_upper_arm": Vector3(26, 0, -66), "r_forearm": Vector3(14, 0, 0),
			"l_upper_arm": Vector3(10, 0, -52),
		},
		"follow": {
			"spine_upper": Vector3(8, 78, 0), "hips": Vector3(0, 34, 0),
			"r_upper_arm": Vector3(14, 0, -84), "r_forearm": Vector3(28, 0, 0),
			"l_upper_arm": Vector3(2, 0, -60),
		},
	},
	&"SabreSlashR": {
		"length": 0.44, "hit": 0.38, "entry": 52.0, "tol": 34.0,
		"heavy": false, "upper_only": true, "label": "Sabre right cut",
		"wind": {
			"spine_upper": Vector3(-4, 26, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, -12),
		},
		"strike": {
			"spine_upper": Vector3(2, -30, 0), "hips": Vector3(0, -16, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(2, 0, 22),
		},
		"follow": {
			"spine_upper": Vector3(6, -40, 0), "hips": Vector3(0, -22, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-4, 0, 30),
		},
	},
	&"SabreSlashL": {
		"length": 0.44, "hit": 0.40, "entry": -52.0, "tol": 34.0,
		"heavy": false, "upper_only": true, "label": "Sabre left cut",
		"wind": {
			"spine_upper": Vector3(-4, 26, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, 12),
		},
		"strike": {
			"spine_upper": Vector3(2, -30, 0), "hips": Vector3(0, -16, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(2, 0, -22),
		},
		"follow": {
			"spine_upper": Vector3(6, -40, 0), "hips": Vector3(0, -22, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-4, 0, -30),
		},
	},
	&"SabreDiagR": {
		"length": 0.48, "hit": 0.39, "entry": 26.0, "tol": 24.0,
		"heavy": false, "label": "Sabre rising diagonal",
		"wind": {
			"spine_upper": Vector3(-11, 20, 0), "hips": Vector3(-3, 8, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(20, 0, -16),
		},
		"strike": {
			"spine_upper": Vector3(7, -25, 0), "hips": Vector3(4, -13, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(4, 0, 18),
		},
		"follow": {
			"spine_upper": Vector3(12, -34, 0), "hips": Vector3(6, -18, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-2, 0, 25),
		},
	},
	&"SabreThrust": {
		"length": 0.72, "hit": 0.48, "entry": 0.0, "tol": 26.0,
		"heavy": true, "label": "Sabre committed thrust",
		"wind": {
			"spine_upper": Vector3(-12, 24, 0), "hips": Vector3(-3, 12, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(24, 0, -16),
		},
		"strike": {
			"spine_upper": Vector3(-14, -18, 0), "hips": Vector3(2, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-18, 0, 22),
		},
		"follow": {
			"spine_upper": Vector3(-8, -26, 0), "hips": Vector3(4, -18, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-20, 0, 26),
		},
	},
	&"SabreWhirl": {
		"length": 0.86, "hit": 0.53, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Sabre full whirl",
		"wind": {
			"spine_upper": Vector3(-8, -54, 0), "hips": Vector3(0, -24, 0),
			"r_upper_arm": Vector3(24, 0, 78), "r_forearm": Vector3(30, 0, 0),
			"l_upper_arm": Vector3(16, 0, -30),
		},
		"strike": {
			"spine_upper": Vector3(4, 62, 0), "hips": Vector3(0, 26, 0),
			"r_upper_arm": Vector3(26, 0, -66), "r_forearm": Vector3(14, 0, 0),
			"l_upper_arm": Vector3(12, 0, -48),
		},
		"follow": {
			"spine_upper": Vector3(8, 78, 0), "hips": Vector3(0, 34, 0),
			"r_upper_arm": Vector3(14, 0, -84), "r_forearm": Vector3(28, 0, 0),
			"l_upper_arm": Vector3(4, 0, -58),
		},
	},
	&"SabreGuardHold": {
		"length": 0.72, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": false, "hold": true, "guard": true, "label": "Sabre guard",
		"wind": {
			"spine_upper": Vector3(-4, -8, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-34, 0, 30), "r_forearm": Vector3(82, 0, 0),
			"l_upper_arm": Vector3(42, 0, -22),
		},
		"strike": {
			"spine_upper": Vector3(-4, -8, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-34, 0, 30), "r_forearm": Vector3(82, 0, 0),
			"l_upper_arm": Vector3(42, 0, -22),
		},
		"follow": {
			"spine_upper": Vector3(-4, -8, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-34, 0, 30), "r_forearm": Vector3(82, 0, 0),
			"l_upper_arm": Vector3(42, 0, -22),
		},
	},
	&"SabreRiposte": {
		"length": 0.42, "hit": 0.36, "entry": 0.0, "tol": 28.0,
		"heavy": false, "label": "Sabre riposte",
		"wind": {
			"spine_upper": Vector3(-8, -18, 0), "hips": Vector3(0, -8, 0),
			"r_upper_arm": Vector3(-26, 0, 12), "r_forearm": Vector3(76, 0, 0),
			"l_upper_arm": Vector3(16, 0, -10),
		},
		"strike": {
			"spine_upper": Vector3(-8, 16, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(88, 0, -2), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(-12, 0, 14),
		},
		"follow": {
			"spine_upper": Vector3(-4, 22, 0), "hips": Vector3(0, 14, 0),
			"r_upper_arm": Vector3(72, 0, -8), "r_forearm": Vector3(14, 0, 2),
			"l_upper_arm": Vector3(-14, 0, 18),
		},
	},
	&"WrenchOverhead": {
		"length": 0.78, "hit": 0.44, "entry": 0.0, "tol": 28.0,
		"heavy": false, "label": "Wrench overhead",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(134, 0, -18),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(24, 0, -5),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, -8),
		},
	},
	&"WrenchBackhand": {
		"length": 0.82, "hit": 0.46, "entry": -46.0, "tol": 42.0,
		"heavy": false, "label": "Wrench backhand",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(16, 0, 18),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, -22),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(0, 0, -30),
		},
	},
	&"WrenchCrush": {
		"length": 0.94, "hit": 0.48, "entry": 0.0, "tol": 30.0,
		"heavy": false, "label": "Wrench crushing blow",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(148, 0, -10),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(20, 0, -4),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(4, 0, -6),
		},
	},
	&"WrenchSlam": {
		"length": 1.12, "hit": 0.50, "entry": 0.0, "tol": 32.0,
		"heavy": true, "label": "Wrench ground slam",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(158, 0, -18), "l_forearm": Vector3(56, 0, 0),
			"l_thigh": Vector3(12, 0, 0), "r_thigh": Vector3(12, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(22, 0, -4), "l_forearm": Vector3(4, 0, 0),
			"l_thigh": Vector3(24, 0, 0), "r_thigh": Vector3(24, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(6, 0, 0), "l_forearm": Vector3(24, 0, 0),
			"l_thigh": Vector3(16, 0, 0), "r_thigh": Vector3(16, 0, 0),
		},
	},
	&"WrenchHookPull": {
		"length": 0.98, "hit": 0.47, "entry": 38.0, "tol": 68.0,
		"heavy": true, "label": "Wrench hook pull",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(30, 0, -22),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(16, 0, 26),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, 32),
		},
	},
	&"WrenchGuardHold": {
		"length": 0.74, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": false, "hold": true, "guard": true, "label": "Wrench brace",
		"wind": {
			"spine_upper": Vector3(-10, -10, 0), "hips": Vector3(0, -5, 0),
			"r_upper_arm": Vector3(-44, 0, 26), "r_forearm": Vector3(64, 0, 0),
			"l_upper_arm": Vector3(48, 0, -20),
		},
		"strike": {
			"spine_upper": Vector3(-10, -10, 0), "hips": Vector3(0, -5, 0),
			"r_upper_arm": Vector3(-44, 0, 26), "r_forearm": Vector3(64, 0, 0),
			"l_upper_arm": Vector3(48, 0, -20),
		},
		"follow": {
			"spine_upper": Vector3(-10, -10, 0), "hips": Vector3(0, -5, 0),
			"r_upper_arm": Vector3(-44, 0, 26), "r_forearm": Vector3(64, 0, 0),
			"l_upper_arm": Vector3(48, 0, -20),
		},
	},
	&"WrenchCounter": {
		"length": 0.58, "hit": 0.40, "entry": 0.0, "tol": 50.0,
		"heavy": false, "label": "Wrench brace counter",
		"wind": {
			"spine_upper": Vector3(-16, -18, 0), "hips": Vector3(-4, -8, 0),
			"r_upper_arm": Vector3(112, 0, 28), "r_forearm": Vector3(34, 0, 0),
			"l_upper_arm": Vector3(34, 0, -16),
		},
		"strike": {
			"spine_upper": Vector3(12, 22, 0), "hips": Vector3(4, 12, 0),
			"r_upper_arm": Vector3(46, 0, -34), "r_forearm": Vector3(8, 0, 0),
			"l_upper_arm": Vector3(10, 0, 20),
		},
		"follow": {
			"spine_upper": Vector3(18, 30, 0), "hips": Vector3(6, 16, 0),
			"r_upper_arm": Vector3(20, 0, -48), "r_forearm": Vector3(22, 0, 0),
			"l_upper_arm": Vector3(2, 0, 28),
		},
	},
	&"AxeChopR": {
		"length": 0.70, "hit": 0.43, "entry": 18.0, "tol": 38.0,
		"heavy": false, "label": "Axe right chop",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(128, 0, -22),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(22, 0, 10),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(6, 0, 18),
		},
	},
	&"AxeChopL": {
		"length": 0.72, "hit": 0.45, "entry": -24.0, "tol": 42.0,
		"heavy": false, "label": "Axe left chop",
		"wind": {
			"spine_upper": Vector3(-18, 18, 0), "hips": Vector3(-8, 8, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(128, 0, 22),
		},
		"strike": {
			"spine_upper": Vector3(18, -24, 0), "hips": Vector3(8, -12, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(22, 0, -10),
		},
		"follow": {
			"spine_upper": Vector3(28, -34, 0), "hips": Vector3(12, -18, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(6, 0, -18),
		},
	},
	&"AxeCleave": {
		"length": 0.92, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Axe wide hook cleave",
		"wind": {
			"spine_upper": Vector3(-10, -50, 0), "hips": Vector3(-2, -22, 0),
			"r_upper_arm": Vector3(36, 0, 82), "r_forearm": Vector3(34, 0, 0),
			"l_upper_arm": Vector3(28, 0, -42),
		},
		"strike": {
			"spine_upper": Vector3(8, 64, 0), "hips": Vector3(4, 28, 0),
			"r_upper_arm": Vector3(34, 0, -72), "r_forearm": Vector3(14, 0, 0),
			"l_upper_arm": Vector3(16, 0, -58),
		},
		"follow": {
			"spine_upper": Vector3(16, 78, 0), "hips": Vector3(6, 36, 0),
			"r_upper_arm": Vector3(20, 0, -96), "r_forearm": Vector3(28, 0, 0),
			"l_upper_arm": Vector3(4, 0, -70),
		},
	},
	&"AxeHookDrag": {
		"length": 1.02, "hit": 0.52, "entry": 18.0, "tol": 70.0,
		"heavy": true, "label": "Axe hook drag",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(42, 0, -28),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(20, 0, 30),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(8, 0, 38),
		},
	},
	&"AxeRend": {
		"length": 1.08, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Axe double rend",
		"wind": {
			"spine_upper": Vector3(-24, -58, 0), "hips": Vector3(-8, -26, 0),
			"r_upper_arm": Vector3(42, 0, 88), "r_forearm": Vector3(44, 0, 0),
			"l_upper_arm": Vector3(32, 0, -50),
		},
		"strike": {
			"spine_upper": Vector3(20, 66, 0), "hips": Vector3(8, 30, 0),
			"r_upper_arm": Vector3(28, 0, -82), "r_forearm": Vector3(14, 0, 0),
			"l_upper_arm": Vector3(18, 0, -66),
		},
		"follow": {
			"spine_upper": Vector3(30, 82, 0), "hips": Vector3(12, 40, 0),
			"r_upper_arm": Vector3(14, 0, -104), "r_forearm": Vector3(30, 0, 0),
			"l_upper_arm": Vector3(2, 0, -78),
		},
	},
	&"AxeGuardHold": {
		"length": 0.78, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": false, "hold": true, "guard": true, "label": "Axe guard",
		"wind": {
			"spine_upper": Vector3(-8, -14, 0), "hips": Vector3(0, -6, 0),
			"r_upper_arm": Vector3(-48, 0, 34), "r_forearm": Vector3(78, 0, 0),
			"l_upper_arm": Vector3(56, 0, -26),
		},
		"strike": {
			"spine_upper": Vector3(-8, -14, 0), "hips": Vector3(0, -6, 0),
			"r_upper_arm": Vector3(-48, 0, 34), "r_forearm": Vector3(78, 0, 0),
			"l_upper_arm": Vector3(56, 0, -26),
		},
		"follow": {
			"spine_upper": Vector3(-8, -14, 0), "hips": Vector3(0, -6, 0),
			"r_upper_arm": Vector3(-48, 0, 34), "r_forearm": Vector3(78, 0, 0),
			"l_upper_arm": Vector3(56, 0, -26),
		},
	},
	&"AxeCounter": {
		"length": 0.62, "hit": 0.42, "entry": 0.0, "tol": 55.0,
		"heavy": false, "label": "Axe counter chop",
		"wind": {
			"spine_upper": Vector3(-18, -22, 0), "hips": Vector3(-4, -10, 0),
			"r_upper_arm": Vector3(126, 0, 34), "r_forearm": Vector3(40, 0, 0),
			"l_upper_arm": Vector3(38, 0, -18),
		},
		"strike": {
			"spine_upper": Vector3(14, 28, 0), "hips": Vector3(4, 14, 0),
			"r_upper_arm": Vector3(44, 0, -38), "r_forearm": Vector3(8, 0, 0),
			"l_upper_arm": Vector3(8, 0, 22),
		},
		"follow": {
			"spine_upper": Vector3(22, 36, 0), "hips": Vector3(6, 18, 0),
			"r_upper_arm": Vector3(16, 0, -58), "r_forearm": Vector3(24, 0, 0),
			"l_upper_arm": Vector3(0, 0, 30),
		},
	},
	&"LanceThrustHigh": {
		"length": 0.76, "hit": 0.42, "entry": 0.0, "tol": 26.0,
		"heavy": false, "label": "Lance high thrust",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(12, 0, -14),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-10, 0, 14),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-12, 0, 20),
		},
	},
	&"LanceThrustLow": {
		"length": 0.82, "hit": 0.46, "entry": 0.0, "tol": 24.0,
		"heavy": false, "label": "Lance low thrust",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(28, 0, -12),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-2, 0, 16),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(-6, 0, 22),
		},
	},
	&"LanceWideSweep": {
		"length": 0.98, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Lance one-eighty sweep",
		"wind": {
			"spine_upper": Vector3(-8, -62, 0), "hips": Vector3(0, -28, 0),
			"r_upper_arm": Vector3(30, 0, 92), "r_forearm": Vector3(42, 0, 0),
			"l_upper_arm": Vector3(26, 0, -42),
		},
		"strike": {
			"spine_upper": Vector3(4, 70, 0), "hips": Vector3(2, 30, 0),
			"r_upper_arm": Vector3(28, 0, -82), "r_forearm": Vector3(16, 0, 0),
			"l_upper_arm": Vector3(16, 0, -60),
		},
		"follow": {
			"spine_upper": Vector3(10, 88, 0), "hips": Vector3(2, 40, 0),
			"r_upper_arm": Vector3(14, 0, -108), "r_forearm": Vector3(32, 0, 0),
			"l_upper_arm": Vector3(4, 0, -76),
		},
	},
	&"LanceCharge": {
		"length": 1.24, "hit": 0.56, "entry": 0.0, "tol": 30.0,
		"heavy": true, "label": "Lance charge",
		"wind": {
			"spine_upper": Vector3(-5, 22, 0), "hips": Vector3(0, 10, 0),
			"r_upper_arm": Vector3(10, 0, 16), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(14, 0, -12), "l_forearm": Vector3(92, 0, 0),
			"l_thigh": Vector3(-8, 0, 0), "r_thigh": Vector3(8, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(2, -28, 0), "hips": Vector3(0, -14, 0),
			"r_upper_arm": Vector3(2, 0, -26), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(78, 0, 2), "l_forearm": Vector3(6, 0, 0),
			"l_thigh": Vector3(18, 0, 0), "r_thigh": Vector3(18, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(6, -38, 0), "hips": Vector3(0, -20, 0),
			"r_upper_arm": Vector3(-4, 0, -34), "r_forearm": Vector3.ZERO,
			"l_upper_arm": Vector3(70, 0, -4), "l_forearm": Vector3(16, 0, 0),
			"l_thigh": Vector3(10, 0, 0), "r_thigh": Vector3(10, 0, 0),
		},
	},
	&"LanceSpiralSweep": {
		"length": 1.22, "hit": 0.54, "entry": 0.0, "tol": 180.0,
		"heavy": true, "label": "Lance spiral sweep",
		"wind": {
			"spine_upper": Vector3(-14, -54, 0), "hips": Vector3(-6, -24, 0),
			"r_upper_arm": Vector3(42, 0, 84), "r_forearm": Vector3(54, 0, 0),
			"l_upper_arm": Vector3(34, 0, -46), "l_forearm": Vector3(38, 0, 0),
			"l_thigh": Vector3(8, 0, 0), "r_thigh": Vector3(8, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(10, 68, 0), "hips": Vector3(4, 32, 0),
			"r_upper_arm": Vector3(36, 0, -78), "r_forearm": Vector3(18, 0, 0),
			"l_upper_arm": Vector3(22, 0, -64), "l_forearm": Vector3(14, 0, 0),
			"l_thigh": Vector3(20, 0, 0), "r_thigh": Vector3(20, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(18, 92, 0), "hips": Vector3(8, 44, 0),
			"r_upper_arm": Vector3(16, 0, -112), "r_forearm": Vector3(34, 0, 0),
			"l_upper_arm": Vector3(6, 0, -84), "l_forearm": Vector3(28, 0, 0),
			"l_thigh": Vector3(14, 0, 0), "r_thigh": Vector3(14, 0, 0),
		},
	},
	&"LanceGuardHold": {
		"length": 0.84, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": false, "hold": true, "guard": true, "label": "Lance guard hold",
		"wind": {
			"spine_upper": Vector3(-10, -20, 0), "hips": Vector3(-2, -8, 0),
			"r_upper_arm": Vector3(-42, 0, 20), "r_forearm": Vector3(108, 0, 0),
			"l_upper_arm": Vector3(26, 0, -12), "l_forearm": Vector3(72, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(-10, -20, 0), "hips": Vector3(-2, -8, 0),
			"r_upper_arm": Vector3(-42, 0, 20), "r_forearm": Vector3(108, 0, 0),
			"l_upper_arm": Vector3(26, 0, -12), "l_forearm": Vector3(72, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(-10, -20, 0), "hips": Vector3(-2, -8, 0),
			"r_upper_arm": Vector3(-42, 0, 20), "r_forearm": Vector3(108, 0, 0),
			"l_upper_arm": Vector3(26, 0, -12), "l_forearm": Vector3(72, 0, 0),
		},
	},
	&"LanceCounter": {
		"length": 0.56, "hit": 0.38, "entry": 0.0, "tol": 40.0,
		"heavy": false, "label": "Lance counter thrust",
		"wind": {
			"spine_upper": Vector3(-12, -22, 0), "hips": Vector3(-4, -10, 0),
			"r_upper_arm": Vector3(-24, 0, 16), "r_forearm": Vector3(106, 0, 0),
			"l_upper_arm": Vector3(20, 0, -12),
		},
		"strike": {
			"spine_upper": Vector3(-8, 18, 0), "hips": Vector3(0, 12, 0),
			"r_upper_arm": Vector3(88, 0, -4), "r_forearm": Vector3(6, 0, 0),
			"l_upper_arm": Vector3(-12, 0, 16),
		},
		"follow": {
			"spine_upper": Vector3(-2, 26, 0), "hips": Vector3(2, 16, 0),
			"r_upper_arm": Vector3(78, 0, -8), "r_forearm": Vector3(16, 0, 2),
			"l_upper_arm": Vector3(-14, 0, 22),
		},
	},
	&"JabR": {
		"length": 0.34, "hit": 0.40, "entry": 18.0, "tol": 46.0,
		"heavy": false, "label": "Right jab",
		"wind": {
			"spine_upper": Vector3(-4, -10, 0), "hips": Vector3(0, -5, 0),
			"r_upper_arm": Vector3(-22, 0, 12), "r_forearm": Vector3(56, 0, 0),
			"l_upper_arm": Vector3(8, 0, -8),
		},
		"strike": {
			"spine_upper": Vector3(-2, 10, 0), "hips": Vector3(0, 6, 0),
			"r_upper_arm": Vector3(58, 0, -4), "r_forearm": Vector3(4, 0, 0),
			"l_upper_arm": Vector3(-6, 0, 12),
		},
		"follow": {
			"spine_upper": Vector3(0, 14, 0), "hips": Vector3(0, 8, 0),
			"r_upper_arm": Vector3(48, 0, -8), "r_forearm": Vector3(10, 0, 0),
			"l_upper_arm": Vector3(-8, 0, 16),
		},
	},
	&"JabL": {
		"length": 0.34, "hit": 0.42, "entry": -18.0, "tol": 46.0,
		"heavy": false, "label": "Left jab",
		"wind": {
			"spine_upper": Vector3(-4, 10, 0), "hips": Vector3(0, 5, 0),
			"r_upper_arm": Vector3(-22, 0, -12), "r_forearm": Vector3(56, 0, -2),
			"l_upper_arm": Vector3(8, 0, 8),
		},
		"strike": {
			"spine_upper": Vector3(-2, -10, 0), "hips": Vector3(0, -6, 0),
			"r_upper_arm": Vector3(58, 0, 4), "r_forearm": Vector3(4, 0, 0),
			"l_upper_arm": Vector3(-6, 0, -12),
		},
		"follow": {
			"spine_upper": Vector3(0, -14, 0), "hips": Vector3(0, -8, 0),
			"r_upper_arm": Vector3(48, 0, 8), "r_forearm": Vector3(10, 0, 2),
			"l_upper_arm": Vector3(-8, 0, -16),
		},
	},
	&"HookR": {
		"length": 0.46, "hit": 0.44, "entry": 42.0, "tol": 50.0,
		"heavy": false, "label": "Right hook",
		"wind": {
			"spine_upper": Vector3(-8, -28, 0), "hips": Vector3(-2, -10, 0),
			"r_upper_arm": Vector3(34, 0, 66), "r_forearm": Vector3(28, 0, 0),
			"l_upper_arm": Vector3(12, 0, -14),
		},
		"strike": {
			"spine_upper": Vector3(6, 34, 0), "hips": Vector3(2, 16, 0),
			"r_upper_arm": Vector3(46, 0, -58), "r_forearm": Vector3(8, 0, 0),
			"l_upper_arm": Vector3(2, 0, 20),
		},
		"follow": {
			"spine_upper": Vector3(10, 42, 0), "hips": Vector3(4, 20, 0),
			"r_upper_arm": Vector3(34, 0, -70), "r_forearm": Vector3(18, 0, 0),
			"l_upper_arm": Vector3(-2, 0, 26),
		},
	},
	&"Shove": {
		"length": 0.52, "hit": 0.48, "entry": 0.0, "tol": 70.0,
		"heavy": false, "label": "Two-hand shove",
		"wind": {
			"spine_upper": Vector3(-12, -16, 0), "hips": Vector3(-4, -8, 0),
			"r_upper_arm": Vector3(-18, 0, 16), "r_forearm": Vector3(66, 0, 0),
			"l_upper_arm": Vector3(-18, 0, -16), "l_forearm": Vector3(62, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(-4, 12, 0), "hips": Vector3(0, 8, 0),
			"r_upper_arm": Vector3(64, 0, -4), "r_forearm": Vector3(4, 0, 0),
			"l_upper_arm": Vector3(58, 0, 4), "l_forearm": Vector3(4, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(2, 18, 0), "hips": Vector3(2, 10, 0),
			"r_upper_arm": Vector3(52, 0, -8), "r_forearm": Vector3(12, 0, 0),
			"l_upper_arm": Vector3(48, 0, 8), "l_forearm": Vector3(10, 0, 0),
		},
	},
	&"FistsGuardHold": {
		"length": 0.60, "hit": 0.50, "entry": 0.0, "tol": 180.0,
		"heavy": false, "hold": true, "guard": true, "label": "Fists guard",
		"wind": {
			"spine_upper": Vector3(-6, -10, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-50, 0, 34), "r_forearm": Vector3(54, 0, 0),
			"l_upper_arm": Vector3(-46, 0, -34), "l_forearm": Vector3(50, 0, 0),
		},
		"strike": {
			"spine_upper": Vector3(-6, -10, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-50, 0, 34), "r_forearm": Vector3(54, 0, 0),
			"l_upper_arm": Vector3(-46, 0, -34), "l_forearm": Vector3(50, 0, 0),
		},
		"follow": {
			"spine_upper": Vector3(-6, -10, 0), "hips": Vector3(0, -4, 0),
			"r_upper_arm": Vector3(-50, 0, 34), "r_forearm": Vector3(54, 0, 0),
			"l_upper_arm": Vector3(-46, 0, -34), "l_forearm": Vector3(50, 0, 0),
		},
	},
}


static func build_library(articulated := true) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip in CLIPS:
		lib.add_animation(clip, build_clip(clip, articulated))
	return lib


static func build_clip(clip: StringName, articulated := true) -> Animation:
	var def: Dictionary = DEFS[clip]
	var length := float(def["length"])
	var hit := float(def["hit"])
	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if bool(def.get("hold", false)) else Animation.LOOP_NONE
	anim.set_meta(&"hit_frac", hit)
	anim.set_meta(&"heavy", bool(def.get("heavy", false)))
	anim.set_meta(&"guard", bool(def.get("guard", false)))
	anim.set_meta(&"entry_angle", float(def.get("entry", 0.0)))
	anim.set_meta(&"tolerance", float(def.get("tol", 0.0)))
	anim.set_meta(&"direction_label", String(def.get("label", "")))
	anim.set_meta(&"direction", clip)

	# Key times: rest -> windup -> strike (hit) -> follow -> settle at rest.
	var t_wind := hit * 0.5
	var t_strike := hit
	var t_follow := hit + (1.0 - hit) * 0.5
	var bones: Array[String] = BASE_BONES.duplicate()
	if articulated:
		for fore_bone in FORE_BONES:
			if not bool(def.get("upper_only", false)) or fore_bone != "r_forearm":
				bones.append(fore_bone)
	# Thigh keys are authored only for the heavy, grounded swings.
	for b in THIGH_BONES:
		if def["wind"].has(b) or def["strike"].has(b) or def["follow"].has(b):
			bones.append(b)

	for bone in bones:
		var settle_pose := Vector3.ZERO
		if bool(def.get("hold", false)):
			settle_pose = _pose(def["follow"], bone)
		var keys: Array = [
			[0.0 * length, Vector3.ZERO],
			[t_wind * length, _pose(def["wind"], bone)],
			[t_strike * length, _pose(def["strike"], bone)],
			[t_follow * length, _pose(def["follow"], bone)],
			[1.0 * length, settle_pose],
		]
		_add_rotation_track(anim, bone, keys)
	return anim


## Rig-facing correction. Every pose number above is written in the rig's own
## bone axes, and this rig's TRUE front is +Z: actors/humanoid_model.gd authors
## the nose -- "Nose bump doubles as the facing cue (+Z)" -- at z=+0.125 and the
## face panel at +Z, and survivor.gd turns the visual root with
## atan2(facing.x, facing.z), which aims that nose along `facing`.
##
## The DEFS tables were authored against debug/melee_axis_probe.gd, which tags a
## hand direction "FORWARD" when `d.z < -0.35` -- the character's BACK. The
## author's whole mental model of the rig is therefore turned 180 degrees about
## Y, and every X (fwd/back) and Z (side) sign written from it is mirrored.
## Measured, not guessed: debug/melee_swing_direction_probe.gd
## (--meleedirprobe) reported 7 of 8 clips sending the blade AWAY from the aim
## (SlashL dot=-1.00, DiagL -0.99, SlashR +0.69 on a noisy sample, Thrust -0.88).
##
## A 180 degree turn about Y conjugates a rotation as
##   R_y(pi) . R . R_y(pi)^-1  =>  Rx(t)->Rx(-t), Ry(t)->Ry(t), Rz(t)->Rz(-t)
## so X and Z flip and the authored Y twist survives untouched. Correcting in
## this one accessor (instead of re-typing eight pose tables) keeps the DEFS
## numbers readable exactly as authored, and it is the single place to revert.
static func _pose(dict: Dictionary, bone: String) -> Vector3:
	var v: Vector3 = dict.get(bone, Vector3.ZERO) as Vector3
	return Vector3(-v.x, v.y, -v.z)


static func _add_rotation_track(anim: Animation, bone: String,
		keys: Array) -> void:
	var t := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t, NodePath(":%s" % bone))
	for k in keys:
		anim.track_insert_key(t, float(k[0]), _quat_from_euler_deg(k[1] as Vector3))


static func _quat_from_euler_deg(deg: Vector3) -> Quaternion:
	return Quaternion.from_euler(Vector3(deg_to_rad(deg.x), deg_to_rad(deg.y),
			deg_to_rad(deg.z)))


# --- Direction resolution ----------------------------------------------------

static func entry_angle(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("entry", 0.0))


static func tolerance(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("tol", 0.0))


static func is_heavy(clip: StringName) -> bool:
	return bool(DEFS.get(clip, {}).get("heavy", false))


static func clip_length(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("length", 0.4))


static func hit_frac(clip: StringName) -> float:
	return float(DEFS.get(clip, {}).get("hit", 0.4))


static func hit_time(clip: StringName) -> float:
	return clip_length(clip) * hit_frac(clip)


static func direction_label(clip: StringName) -> String:
	return String(DEFS.get(clip, {}).get("label", ""))


## Aim direction in the character's own frame -> swing id.
## `available` is the weapon's ordered swing pool; earlier entries win ties.
##
## Selection is two-pass so that the wide fallback swing never swallows the
## directional moves:
##   1. the *most specific* clip that actually covers the aim (narrowest
##      tolerance wins, then the closest entry). A 180 deg Sweep covers every
##      aim, so it can only win where no aimed swing reaches.
##   2. if nothing covers the aim, the least out-of-reach swing wins, and the
##      widest arc breaks that tie.
## With `prefer_heavy` the pool is narrowed to heavy swings when it has any,
## which is how RMB turns a light weapon into a committed two-handed blow.
static func direction_for(aim_local: Vector3, available: Array,
		prefer_heavy := false) -> StringName:
	var pool: Array = available
	if prefer_heavy:
		var heavy_pool: Array = []
		for c in available:
			if is_heavy(c as StringName):
				heavy_pool.append(c)
		if not heavy_pool.is_empty():
			pool = heavy_pool
	if pool.is_empty():
		return &"Thrust"
	var aim_deg := 0.0
	if aim_local.length_squared() > 0.000001:
		aim_deg = rad_to_deg(atan2(aim_local.x, -aim_local.z))

	# Pass 1: the tightest authored swing that covers this aim.
	var best: StringName = pool[0] as StringName
	var best_tol := INF
	var best_delta := INF
	var covered := false
	for c in pool:
		var clip := c as StringName
		var tol := tolerance(clip)
		var delta := _delta_deg(clip, aim_deg)
		if delta > tol:
			continue
		if not covered or tol < best_tol - 0.0001 \
				or (absf(tol - best_tol) <= 0.0001 and delta < best_delta - 0.0001):
			covered = true
			best_tol = tol
			best_delta = delta
			best = clip
	if covered:
		return best

	# Pass 2: nothing covers the aim, so take the least out-of-reach swing and
	# let the widest arc win a tie.
	best = pool[0] as StringName
	var best_cost := INF
	var best_wide := -1.0
	for c in pool:
		var clip := c as StringName
		var tol := tolerance(clip)
		var cost := _delta_deg(clip, aim_deg) - tol
		if cost < best_cost - 0.0001 \
				or (absf(cost - best_cost) <= 0.0001 and tol > best_wide):
			best_cost = cost
			best_wide = tol
			best = clip
	return best


## Shortest angle between a clip's entry direction and the aim, in degrees.
static func _delta_deg(clip: StringName, aim_deg: float) -> float:
	return absf(rad_to_deg(angle_difference(
			deg_to_rad(entry_angle(clip)), deg_to_rad(aim_deg))))
