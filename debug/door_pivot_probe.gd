extends Node3D
## DOOR PIVOT PROBE — proves the swinging leaf turns about its HINGE (the
## aperture edge), not about its own centre.
##
## Method (pure measurement, no tuning):
##   - spawn ONE Door from a manifest whose aperture centre is WORLD ORIGIN,
##     hinge "left", width 1.0, open_angle 95 deg;
##   - the Door node itself sits AT the hinge, and the leaf body's origin is
##     meant to coincide with it;
##   - open() the door and sample every physics tick, recording how far the
##     LEAF BODY ORIGIN (the hinge point) drifts from the hinge anchor;
##   - a hinge-pivoted door keeps that drift ~0 while its tip sweeps a
##     quarter-circle; a centre-pivoted door (rotation about the body's
##     centre of mass) walks the hinge point around a ~1.2 m circle.
##
## Prints PASS/FAIL lines and a machine-readable summary.

const TICKS := 150
const HINGE_TOL := 0.06   # 6 cm: hinge may jitter, it must not orbit
const YAW_TOL := deg_to_rad(12.0)

var _fails := 0


func _check(label: String, ok: bool, detail: String) -> void:
	if ok:
		print("[DoorPivotProbe] PASS %s (%s)" % [label, detail])
	else:
		_fails += 1
		print("[DoorPivotProbe] FAIL %s (%s)" % [label, detail])


func _ready() -> void:
	var w := 1.0
	var open_angle := 95.0
	var manifest := {
		"id": "probe_door",
		"building_id": "probe",
		"position": Vector3.ZERO,      # aperture CENTRE = world origin
		"yaw": 0.0,
		"edge": 0,
		"width": w,
		"height": 2.25,
		"hinge": "left",
		"locked": false,
		"open_angle": open_angle,
	}
	var door := Door.new()
	door.name = "ProbeDoor"
	door.setup(manifest)
	add_child(door)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var hinge: Vector3 = door.global_position
	var leaf: RigidBody3D = door._pivot_ref()
	var side := 1.0
	var leaf_center_local := Vector3(-side * w * 0.5, 1.125, 0.0)
	var leaf_center0: Vector3 = leaf.global_transform * leaf_center_local
	var leaf_origin0: Vector3 = leaf.global_position

	# Sanity: the leaf body's own origin must sit ON the hinge anchor.
	_check("leaf origin on hinge at rest",
		leaf_origin0.distance_to(hinge) < 0.02,
		"gap %.3f m" % leaf_origin0.distance_to(hinge))
	_check("leaf centre sits half width across the doorway",
		absf(Vector2(leaf_center0.x - hinge.x, leaf_center0.z - hinge.z).length() - w * 0.5) < 0.05,
		"%.3f m" % Vector2(leaf_center0.x - hinge.x, leaf_center0.z - hinge.z).length())

	door.open()

	var max_hinge_drift := 0.0
	var max_center_hold := 0.0
	for i in TICKS:
		await get_tree().physics_frame
		if not is_instance_valid(leaf):
			break
		var drift: float = leaf.global_position.distance_to(hinge)
		max_hinge_drift = maxf(max_hinge_drift, drift)
		max_center_hold = maxf(max_center_hold, leaf_center0.distance_to(leaf.global_position))

	var final_yaw := rad_to_deg(wrapf(leaf.rotation.y, -PI, PI))
	var leaf_center1: Vector3 = leaf.global_transform * leaf_center_local
	var tip_dir := leaf.global_transform * Vector3(-side * w, 1.125, 0.0)
	var tip_sweep := tip_dir.distance_to(Vector3(-side * w, 1.125, 0.0))

	print("[DoorPivotProbe] hinge=%s leaf_origin_final=%s drift_max=%.3f centre_final=%s yaw_final=%.1f deg state=%d" % [
		str(hinge.snapped(Vector3(0.001, 0.001, 0.001))),
		str(leaf.global_position.snapped(Vector3(0.001, 0.001, 0.001))),
		max_hinge_drift,
		str(leaf_center1.snapped(Vector3(0.001, 0.001, 0.001))),
		final_yaw, door.state])

	_check("leaf swings to commanded angle",
		absf(final_yaw - open_angle) <= rad_to_deg(YAW_TOL),
		"%.1f deg vs %.1f deg" % [final_yaw, open_angle])
	_check("hinge stays put through the swing (<%.2f m)" % HINGE_TOL,
		max_hinge_drift < HINGE_TOL,
		"max drift %.3f m" % max_hinge_drift)
	_check("leaf centre travels an arc about the hinge",
		leaf_center1.distance_to(leaf_center0) > 0.25,
		"centre moved %.3f m (held-to-origin %.3f m)" % [
			leaf_center1.distance_to(leaf_center0), max_center_hold])
	_check("opened leaf clears the aperture",
		door.is_passage_clear(),
		"is_passage_clear=%s" % str(door.is_passage_clear()))

	print("[DoorPivotProbe] finished with %d failure(s)" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
