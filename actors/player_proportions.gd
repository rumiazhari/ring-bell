class_name PlayerProportions
extends RefCounted
## Representative adult woman, metres in the unscaled player skeleton.
## Stature includes thin boot soles; these are character dimensions, not universal ratios.
const STATURE := 1.70
const HIP_Y := 0.90
const SPINE_Y := 0.99
const SHOULDER_Y := 1.40
const SHOULDER_HALF_WIDTH := 0.18
const KNEE_Y := 0.49
const ANKLE_Y := 0.08
const THIGH_LENGTH := HIP_Y - KNEE_Y
const CALF_LENGTH := KNEE_Y - ANKLE_Y
const UPPER_ARM := 0.29
const FOREARM := 0.25
const HAND := 0.17
const ARM_REACH := UPPER_ARM + FOREARM + HAND
const HEAD_CENTER := 1.565
const HEAD_SCALE := Vector3(0.78, 0.82, 0.78)
