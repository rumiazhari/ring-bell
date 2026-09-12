class_name CaptureFraming
extends RefCounted
## Camera framing maths for the debug capture harnesses (debug/melee_capture.gd,
## and anything else that has to photograph an object and prove it is readable).
##
## WHY THIS EXISTS: the weapon-gallery pass used one fixed camera direction for
## every model. A model's long axis can be X, Y or Z depending on how it was
## authored (a sabre is drawn along +Z, a boarding axe along Y), so a fixed
## direction is broadside to some weapons and exactly end-on to others - which is
## how the cane-sabre capture ended up showing a stub instead of a cane.
##
## The fix is to derive the camera FROM the model's long axis instead of
## hard-coding it, and to report the resulting angle so the shot is judged by a
## number (`broadside_deg`, 90 = fully side-on) and not only by eye.

## Index of the box's largest extent: 0 = X, 1 = Y, 2 = Z.
static func long_axis(size: Vector3) -> int:
	if size.x >= size.y and size.x >= size.z:
		return 0
	return 1 if size.y >= size.z else 2


## Unit vector of the box's long axis in the box's own frame.
static func long_axis_vector(size: Vector3) -> Vector3:
	match long_axis(size):
		0:
			return Vector3.RIGHT
		1:
			return Vector3.UP
		_:
			return Vector3.BACK


## A yaw-only rotation applied to `axis` (i.e. the long axis after the model has
## been spun about Y for presentation).
static func rotated_axis(axis: Vector3, yaw_deg: float) -> Vector3:
	return axis.normalized().rotated(Vector3.UP, deg_to_rad(yaw_deg))


## Camera direction (unit vector from the object's centre TO the camera) that
## looks ACROSS `long`, so the object's length runs over the frame instead of
## coming at the lens:
##   - horizontal component perpendicular to `long` (broadside),
##   - rotated by `twist_deg` for a three-quarter read,
##   - raised by `elev` (fraction of the horizontal component) to look down on it.
## `prefer_side` (optional) flips the shot to the given side of the object: pass
## the direction from the body to the weapon so a held weapon is not shot
## through its owner.
static func view_dir(long: Vector3, twist_deg := 22.0, elev := 0.42,
		prefer_side := Vector3.ZERO) -> Vector3:
	var axis := long.normalized()
	if axis.length_squared() < 0.5:
		axis = Vector3.BACK
	var flat := Vector3(axis.x, 0.0, axis.z)
	var horiz: Vector3
	if flat.length() < 0.25:
		# Long axis is (near) vertical: every horizontal camera is broadside, so
		# fall back to a fixed three-quarter direction.
		horiz = Vector3(0.70, 0.0, -0.71)
	else:
		horiz = flat.normalized().cross(Vector3.UP).normalized()
		horiz = horiz.rotated(Vector3.UP, deg_to_rad(twist_deg))
	if prefer_side.length_squared() > 0.0001 and horiz.dot(prefer_side) < 0.0:
		horiz = -horiz
	return (Vector3(horiz.x, 0.0, horiz.z).normalized() + Vector3.UP * elev).normalized()


## Angle between `long` and the view axis (camera -> object): 90 deg means fully
## broadside and readable, 0 deg means end-on, i.e. a stub.
static func broadside_deg(long: Vector3, cam_dir: Vector3) -> float:
	if long.length_squared() < 0.0001 or cam_dir.length_squared() < 0.0001:
		return 0.0
	return rad_to_deg(long.normalized().angle_to(-cam_dir.normalized()))


## Readability gate for a capture: a weapon is only legible away from end-on.
static func readable(long: Vector3, cam_dir: Vector3, min_deg := 55.0) -> bool:
	return broadside_deg(long, cam_dir) >= min_deg


## Distance that makes a body of `radius` (half its bounding diagonal) fill
## roughly `fill` of the frame height at the given vertical FOV.
static func distance_for(radius: float, fov_deg: float, fill := 0.70) -> float:
	var half := deg_to_rad(clampf(fov_deg, 10.0, 120.0) * 0.5)
	return maxf(0.35, radius / (tan(half) * clampf(fill, 0.2, 1.0)))


## Screen-space report for a capture, used as the machine-checkable half of the
## framing verdict: `inside` is false when any box corner projects outside the
## viewport (a cropped subject), and `fill` is the larger of the two axis
## fractions the subject covers (0.5 = half the frame).
static func frame_coverage(cam: Camera3D, box: AABB) -> Dictionary:
	var out := {"inside": false, "fill": 0.0, "behind": false, "min": Vector2.ZERO,
			"max": Vector2.ZERO}
	if cam == null or not is_instance_valid(cam) or not cam.is_inside_tree():
		return out
	var viewport := cam.get_viewport()
	if viewport == null:
		return out
	var rect := viewport.get_visible_rect().size
	if rect.x <= 0.0 or rect.y <= 0.0:
		return out
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for i in 8:
		var corner := box.get_endpoint(i)
		if cam.is_position_behind(corner):
			out["behind"] = true
			return out
		var p := cam.unproject_position(corner)
		mn = mn.min(p)
		mx = mx.max(p)
	out["min"] = mn
	out["max"] = mx
	out["fill"] = maxf((mx.x - mn.x) / rect.x, (mx.y - mn.y) / rect.y)
	out["inside"] = mn.x >= 0.0 and mn.y >= 0.0 and mx.x <= rect.x and mx.y <= rect.y
	return out
