class_name SkirtCloth
extends MeshInstance3D
## Position-based garment cloth. Pinned attachment, world-space inertia,
## structural/shear constraints and animated body/world contact.
var radius_top := 0.19
var radius_hem := 0.44
var length := 0.6          # cloth drop from the waist ring
var cols := 10             # ring segments
var rows := 4              # vertical segments below the pinned ring
var ground_local_y := 0.0    # model-local floor clamp (node sits at waist)
var simulating := true
var pin_hem := false

var _pts := PackedVector3Array()
var _prev := PackedVector3Array()
var _rest_v := 0.0
var _rest := PackedVector3Array()
var _last_transform := Transform3D.IDENTITY
var _skeleton: Skeleton3D
var _actor: CollisionObject3D
var _edges: Array[Vector3] = []
var _triangles := PackedInt32Array()
var _capsules: Array[Dictionary] = []
var _rest_h := PackedFloat32Array()   # per-row horizontal rest lengths


func setup(p_top_r: float, p_hem_r: float, p_length: float,
		p_cols: int, p_rows: int, material: StandardMaterial3D) -> void:
	radius_top = p_top_r
	radius_hem = p_hem_r
	length = p_length
	cols = maxi(p_cols, 5)
	rows = maxi(p_rows, 2)
	position = Vector3(0, length + 0.3, 0)   # node origin at the WAIST ring

	var mat := material.duplicate() as StandardMaterial3D
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # cloth shows both sides
	material_override = mat


func _ready() -> void:
	_pts.resize(cols * (rows + 1))
	_prev.resize(cols * (rows + 1))
	_rest_h.resize(rows + 1)
	for r in rows + 1:
		var t := float(r) / float(rows)
		var ring_r := lerpf(radius_top, radius_hem, t)
		_rest_h[r] = 2.0 * ring_r * sin(PI / float(cols))
		for c in cols:
			var ang := TAU * float(c) / float(cols)
			_pts[_idx(r, c)] = Vector3(cos(ang) * ring_r,
					-t * length, sin(ang) * ring_r)
	_prev = _pts.duplicate()
	_rest = _pts.duplicate()
	_rest_v = sqrt(pow(length / rows, 2) + pow((radius_hem - radius_top) / rows, 2))
	for r in rows + 1:
		for c in cols:
			_add_edge(_idx(r, c), _idx(r, c + 1))
			if r < rows:
				_add_edge(_idx(r, c), _idx(r + 1, c))
				_add_edge(_idx(r, c), _idx(r + 1, c + 1))
				_add_edge(_idx(r, c + 1), _idx(r + 1, c))
	_triangles = _indices()
	_last_transform = global_transform
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is Skeleton3D:
			_skeleton = ancestor
		if ancestor is CollisionObject3D:
			_actor = ancestor
		ancestor = ancestor.get_parent()

	mesh = ArrayMesh.new()
	_rebuild_mesh()


func _idx(r: int, c: int) -> int:
	return r * cols + posmod(c, cols)


func set_simulating(on: bool) -> void:
	simulating = on
	set_physics_process(on)


func _pinned(i: int) -> bool:
	return i < cols or (pin_hem and i >= cols * rows)


func _add_edge(a: int, b: int) -> void:
	_edges.append(Vector3(a, b, _rest[a].distance_to(_rest[b])))


func _physics_process(delta: float) -> void:
	if not simulating or delta <= 0.0:
		return
	var dt := minf(delta, 1.0 / 60.0)
	var current := global_transform
	var transport := current.affine_inverse() * _last_transform
	if current.origin.distance_to(_last_transform.origin) > 2.0:
		_pts = _rest.duplicate()
		_prev = _rest.duplicate()
	else:
		for i in range(cols, _pts.size()):
			_pts[i] = transport * _pts[i]
			_prev[i] = transport * _prev[i]
	_last_transform = current
	var gravity := current.basis.inverse() * (Vector3.DOWN * 9.8)
	for i in range(cols, _pts.size()):
		var p := _pts[i]
		var velocity := (_pts[i] - _prev[i]) * pow(0.97, dt * 60.0)
		_prev[i] = p
		_pts[i] = p + velocity + gravity * dt * dt
	for i in _pts.size():
		if _pinned(i):
			_pts[i] = _rest[i]
	_cache_capsules()
	for iteration in 6:
		for edge in _edges:
			_solve_pair(int(edge.x), int(edge.y), edge.z)
		_body_contacts()
	# World rays sweep each particle's motion and probe a small contact margin.
	if _actor != null:
		var space := get_world_3d().direct_space_state
		for i in range(cols, _pts.size()):
			if _pinned(i):
				continue
			var target := current * _pts[i]
			var start := current * _prev[i] + Vector3.UP * 0.015
			if start.distance_squared_to(target) < 0.000001:
				continue
			var query := PhysicsRayQueryParameters3D.create(start, target - Vector3.UP * 0.015, 1, [_actor.get_rid()])
			var hit := space.intersect_ray(query)
			if not hit.is_empty():
				_pts[i] = current.affine_inverse() * (hit.position + hit.normal * 0.018)
				_prev[i] = _pts[i]
	_rebuild_mesh()


func _cache_capsules() -> void:
	_capsules.clear()
	if _skeleton == null:
		return
	# Bone-driven capsules enclose the visible leg and torso meshes.
	for spec in [["l_thigh", Vector3(0, -0.78, 0), 0.18], ["r_thigh", Vector3(0, -0.78, 0), 0.18], ["spine_upper", Vector3(0, 0.52, 0), 0.24], ["l_upper_arm", Vector3(0, -0.50, 0), 0.065], ["r_upper_arm", Vector3(0, -0.50, 0), 0.065]]:
		var bone := _skeleton.find_bone(spec[0])
		var pose := global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
		var a := pose.origin
		var b: Vector3 = pose * spec[1]
		_capsules.append({"a": a, "b": b, "radius": float(spec[2])})


func _body_contacts() -> void:
	for capsule in _capsules:
		var a: Vector3 = capsule.a
		var b: Vector3 = capsule.b
		var ab := b - a
		for i in range(cols, _pts.size()):
			if _pinned(i):
				continue
			var closest := a + ab * clampf((_pts[i] - a).dot(ab) / maxf(ab.length_squared(), 0.00001), 0.0, 1.0)
			var offset := _pts[i] - closest
			var radius: float = capsule.radius
			if offset.length() < radius:
				_pts[i] = closest + offset.normalized() * radius if offset.length() > 0.00001 else closest + Vector3.RIGHT * radius


func _solve_pair(a: int, b: int, rest: float) -> void:
	var pa := _pts[a]
	var pb := _pts[b]
	var diff := pb - pa
	var d := diff.length()
	if d < 0.0001:
		return
	var wa := 0.0 if _pinned(a) else 1.0
	var wb := 0.0 if _pinned(b) else 1.0
	if wa + wb == 0.0:
		return
	var correction := diff * ((d - rest) / d) / (wa + wb)
	_pts[a] += correction * wa
	_pts[b] -= correction * wb


func _rebuild_mesh() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _pts
	arrays[Mesh.ARRAY_NORMAL] = _normals()
	arrays[Mesh.ARRAY_INDEX] = _triangles
	var am := mesh as ArrayMesh
	am.clear_surfaces()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, material_override)


func _indices() -> PackedInt32Array:
	var idx := PackedInt32Array()
	for r in rows:
		for c in cols:
			var a := _idx(r, c)
			var b := _idx(r, c + 1)
			var d := _idx(r + 1, c)
			var e := _idx(r + 1, c + 1)
			idx.append_array(PackedInt32Array([a, e, d, a, b, e]))
	return idx


func _normals() -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(_pts.size())
	for t in range(0, _triangles.size(), 3):
		var a := _triangles[t]
		var b := _triangles[t + 1]
		var c := _triangles[t + 2]
		var n := (_pts[b] - _pts[a]).cross(_pts[c] - _pts[a])
		normals[a] += n
		normals[b] += n
		normals[c] += n
	for i in normals.size():
		normals[i] = normals[i].normalized()
	return normals
