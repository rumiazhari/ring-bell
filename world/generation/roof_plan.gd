class_name RoofPlan
extends RefCounted
const Streets = preload("res://world/generation/historic_street_plan.gd")
## Convex planar faces in wing-local coordinates, independently owned by
## each wing. Materialization cannot choose a different shape or ridge.

static func for_wing(spec: Dictionary) -> Dictionary:
	var size: Vector2 = (spec.rect as Rect2).size
	var along_depth := str(spec.get("wing_role", "front")) == "side"
	var w := size.y if along_depth else size.x
	var d := size.x if along_depth else size.y
	var u := Streets.unit(int(spec.seed_used), "historic_roof", [WorldSeed.str_hash(spec.id)])
	var kind := &"gable" if u < 0.60 else (&"hip" if u < 0.90 else &"mansard")
	var rise := clampf(d * 0.38, 1.2, 3.8)
	var faces: Array[PackedVector3Array] = []
	var e := 0.12
	var x0 := -e
	var x1 := w + e
	var z0 := -e
	var z1 := d + e
	var base := 0.0
	if kind == &"mansard":
		var inset := minf(1.25, minf(w, d) * 0.2)
		base = minf(2.0, rise * 0.65)
		var lower := PackedVector3Array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)])
		var upper := PackedVector3Array([Vector3(x0 + inset, base, z0 + inset), Vector3(x1 - inset, base, z0 + inset), Vector3(x1 - inset, base, z1 - inset), Vector3(x0 + inset, base, z1 - inset)])
		for i in 4:
			faces.append(PackedVector3Array([lower[i], lower[(i + 1) % 4], upper[(i + 1) % 4], upper[i]]))
		x0 += inset
		x1 -= inset
		z0 += inset
		z1 -= inset
	var hip := 0.0 if kind == &"gable" else minf((x1 - x0) * 0.35, (z1 - z0) * 0.5)
	var a := Vector3(x0, base, z0)
	var b := Vector3(x1, base, z0)
	var c := Vector3(x1, base, z1)
	var dpoint := Vector3(x0, base, z1)
	var r0 := Vector3(x0 + hip, rise, (z0 + z1) * 0.5)
	var r1 := Vector3(x1 - hip, rise, (z0 + z1) * 0.5)
	faces.append(PackedVector3Array([a, b, r1, r0]))
	faces.append(PackedVector3Array([c, dpoint, r0, r1]))
	faces.append(PackedVector3Array([dpoint, a, r0]))
	faces.append(PackedVector3Array([b, c, r1]))
	if along_depth:
		for fi in faces.size():
			var face: PackedVector3Array = faces[fi]
			for i in face.size():
				face[i] = Vector3(face[i].z, face[i].y, w - face[i].x)
			faces[fi] = face
	return {"id": str(spec.id) + "_roof", "kind": kind, "faces": faces,
		"ridge_axis": &"depth" if along_depth else &"frontage", "rise": rise,
		"attic": {"id": str(spec.id) + "_attic", "use": &"storage", "access": &"main_stair", "floor_i": int(spec.floors)},
		"chimney": Vector3(size.x * 0.68, rise + 0.5, size.y * 0.5),
		"dormer": Vector3(size.x * 0.3, rise * 0.55, size.y * 0.27) if size.x >= 9.0 and u < 0.5 else Vector3.INF}
