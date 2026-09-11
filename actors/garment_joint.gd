class_name GarmentJoint
extends MeshInstance3D
## A sewn trouser knee bridge, deformed by both adjacent bones.
## No rigid gap at knee flexion; the overlap stays inside the trouser sections.
var upper_bone := "l_thigh"
var lower_bone := "l_calf"
var _sk: Skeleton3D
var _triangles := PackedInt32Array()

func _ready() -> void:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is Skeleton3D:
			_sk = ancestor
		ancestor = ancestor.get_parent()
	for r in 6:
		for c in 20:
			var a := r * 20 + c
			var b := r * 20 + (c + 1) % 20
			_triangles.append_array(PackedInt32Array([a, a + 20, b + 20, a, b + 20, b]))
	mesh = ArrayMesh.new()
	_physics_process(0.0)

func _physics_process(_delta: float) -> void:
	if _sk == null:
		return
	var upper := _sk.get_bone_global_pose(_sk.find_bone(upper_bone))
	var lower := _sk.get_bone_global_pose(_sk.find_bone(lower_bone))
	var relative := lower.affine_inverse() * upper
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	for r in 7:
		var t := r / 6.0
		var y := lerpf(0.12, -0.13, t)
		var weight := smoothstep(0.0, 1.0, t)
		var radius := 0.103 + 0.004 * sin(t * PI)
		for c in 20:
			var a := TAU * c / 20.0
			var p := Vector3(cos(a) * radius, y, sin(a) * radius)
			vertices.append((relative * (p + Vector3(0, -0.42, 0))).lerp(p, weight))
			uv.append(Vector2(c / 20.0, t))
	normals.resize(vertices.size())
	for i in range(0, _triangles.size(), 3):
		var a := _triangles[i]
		var b := _triangles[i + 1]
		var c := _triangles[i + 2]
		var n := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
		normals[a] += n
		normals[b] += n
		normals[c] += n
	for i in normals.size():
		normals[i] = normals[i].normalized()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = _triangles
	var target := mesh as ArrayMesh
	target.clear_surfaces()
	target.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
