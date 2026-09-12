class_name SkirtCloth
extends MeshInstance3D
const Proportions = preload("res://actors/player_proportions.gd")
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
# Optional authored garment profiles. Defaults preserve legacy NPC skirts.
var oval := Vector2.ONE
var gather := 0.0
var profile := PackedFloat32Array()
var trim_color := Color.WHITE
var trim_start := 1.1
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()

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
var bending := 0.0
var open_panel := false
var hem_bone := ""
var hem_offset := Vector3.ZERO
var _bends: Array[Vector3] = []
var _rest_h := PackedFloat32Array()   # per-row horizontal rest lengths

# --- cost control -----------------------------------------------------------------
# Every cloth particle used to fire a swept world raycast against the whole streamed
# space on every physics step, and the mesh was rebuilt even when nothing moved.
# These bounds keep the same solver and the same visual result while removing the
# per-step ray budget: only particles that actually MOVED are swept, in a rotating
# slice, and the mesh is only re-uploaded when the cloth really changed shape.
const SIM_INTERVAL := 3          # solve at 20 Hz on a 60 Hz physics step
const RAY_BUDGET := 12           # swept-contact rays per solve (round-robin slice)
const RAY_MIN_SWEEP := 0.02      # below this the particle is inside the contact margin
const FAR_CULL := 26.0           # metres: past this a hem is not visible
const MESH_EPS := 0.0015         # mesh re-upload threshold (metres)
var _sim_accum := 0.0
var _ray_cursor := 0
var _specs_plain: Array = []
var _specs_artic: Array = []
var _mesh_pts := PackedVector3Array()


func setup(p_top_r: float, p_hem_r: float, p_length: float,
		p_cols: int, p_rows: int, material: StandardMaterial3D) -> void:
	radius_top = p_top_r
	radius_hem = p_hem_r
	length = p_length
	cols = maxi(p_cols, 5)
	rows = maxi(p_rows, 2)
	position = Vector3(0, length + 0.3, 0)   # node origin at the WAIST ring

	var mat := material.duplicate() as StandardMaterial3D
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # cloth shows both sides
	material_override = mat


func _ready() -> void:
	_pts.resize(cols * (rows + 1))
	_prev.resize(cols * (rows + 1))
	_rest_h.resize(rows + 1)
	_colors.resize(_pts.size())
	_uvs.resize(_pts.size())
	for r in rows + 1:
		var t := float(r) / float(rows)
		var ring_r := lerpf(radius_top, radius_hem, t)
		if profile.size() == rows + 1:
			ring_r = profile[r]
		_rest_h[r] = 2.0 * ring_r * sin(PI / float(cols))
		for c in cols:
			var ang := TAU * float(c) / float(cols)
			var folded := ring_r + gather * sin(ang * 8.0) * sin(t * PI * 0.85)
			_pts[_idx(r, c)] = Vector3(cos(ang) * folded * oval.x,
					-t * length, sin(ang) * folded * oval.y)
			if open_panel:
				_pts[_idx(r, c)] = Vector3((float(c) / (cols - 1) - 0.5) * ring_r * 2.0, -t * length, gather * sin(t * PI * 2.0))
			_uvs[_idx(r, c)] = Vector2(float(c) / cols, t)
			var shade := 1.0 if gather == 0.0 else 0.91 + 0.09 * cos(ang * 8.0)
			_colors[_idx(r, c)] = (trim_color if t >= trim_start else Color.WHITE) * Color(shade, shade, shade, 1.0)
	_prev = _pts.duplicate()
	_rest = _pts.duplicate()
	_rest_v = sqrt(pow(length / rows, 2) + pow((radius_hem - radius_top) / rows, 2))
	for r in rows + 1:
		for c in cols:
			if open_panel and c == cols - 1:
				if r < rows:
					_add_edge(_idx(r, c), _idx(r + 1, c))
				continue
			_add_edge(_idx(r, c), _idx(r, c + 1))
			if bending > 0.0 and (not open_panel or c + 2 < cols):
				var a := _idx(r, c)
				var b := _idx(r, c + 2)
				_bends.append(Vector3(a, b, _rest[a].distance_to(_rest[b])))
				if r + 2 <= rows:
					b = _idx(r + 2, c)
					_bends.append(Vector3(a, b, _rest[a].distance_to(_rest[b])))
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


func pin_position(i: int) -> Vector3:
	if pin_hem and i >= cols * rows and not hem_bone.is_empty() and _skeleton != null:
		var bone := _skeleton.find_bone(hem_bone)
		if bone >= 0:
			var frame := global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
			return frame * (_rest[i] + Vector3.UP * length + hem_offset)
	return _rest[i]


func _add_edge(a: int, b: int) -> void:
	_edges.append(Vector3(a, b, _rest[a].distance_to(_rest[b])))


func _physics_process(delta: float) -> void:
	if not simulating or delta <= 0.0:
		return
	# Distance cull: a hem is not visible past a few metres and each cloth costs a
	# solver plus swept rays. Far cloths keep their last pose, so nothing pops.
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_to(global_position) > FAR_CULL:
		return
	_sim_accum += delta
	if _sim_accum < float(SIM_INTERVAL) / 60.0:
		return
	var dt := minf(_sim_accum, 4.0 / 60.0)
	_sim_accum = 0.0
	var current := global_transform
	var transport := current.affine_inverse() * _last_transform
	if current.origin.distance_to(_last_transform.origin) > 2.0 or current.basis.get_rotation_quaternion().angle_to(_last_transform.basis.get_rotation_quaternion()) > PI * 0.65:
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
			_pts[i] = pin_position(i)
	_cache_capsules()
	for iteration in 6:
		for edge in _edges:
			_solve_pair(int(edge.x), int(edge.y), edge.z)
		if iteration % 2 == 1:
			for edge in _bends:
				_solve_pair(int(edge.x), int(edge.y), edge.z, minf(bending * 1.5, 1.0))
		if iteration == 2 or iteration == 5:
			_body_contacts()
	# World rays sweep each particle's motion and probe a small contact margin. Only
	# particles that moved more than the margin are swept, and only RAY_BUDGET of them
	# per solve (a rotating slice): a settled cloth costs zero rays, and a moving one
	# keeps every particle constrained within a few solves while staying FPS-independent.
	if _actor != null:
		var space := get_world_3d().direct_space_state
		var free_count := _pts.size() - cols
		if free_count > 0:
			var budget := mini(RAY_BUDGET, free_count)
			for k in budget:
				var i := cols + ((_ray_cursor + k) % free_count)
				if _pinned(i):
					continue
				var target := current * _pts[i]
				var start := current * _prev[i] + Vector3.UP * 0.015
				var sweep := start.distance_squared_to(target)
				if sweep < RAY_MIN_SWEEP * RAY_MIN_SWEEP:
					continue
				var query := PhysicsRayQueryParameters3D.create(start, target - Vector3.UP * 0.015, 1, [_actor.get_rid()])
				var hit := space.intersect_ray(query)
				if not hit.is_empty():
					_pts[i] = current.affine_inverse() * (hit.position + hit.normal * 0.018)
					_prev[i] = _pts[i]
			_ray_cursor = (_ray_cursor + budget) % free_count
	if _moved_enough_to_redraw():
		_mesh_pts = _pts.duplicate()
		_rebuild_mesh()


func _moved_enough_to_redraw() -> bool:
	## Re-uploading a cloth surface every physics step was pure waste: a hanging or
	## standing cloth barely moves between solves. Sample every third particle.
	if _mesh_pts.size() != _pts.size():
		return true
	var eps2 := MESH_EPS * MESH_EPS
	var i := 0
	while i < _pts.size():
		if _mesh_pts[i].distance_squared_to(_pts[i]) > eps2:
			return true
		i += 3
	return false


func _cache_capsules() -> void:
	_capsules.clear()
	if _skeleton == null:
		return
	# Bone-driven capsules enclose the visible leg and torso meshes.
	# Built once: this used to re-allocate the whole nested spec array on every
	# physics step, for every cloth, which is pure GC churn on a hot path.
	if _specs_plain.is_empty():
		_specs_plain = [["l_thigh", Vector3(0, -0.78, 0), 0.18], ["r_thigh", Vector3(0, -0.78, 0), 0.18], ["spine_upper", Vector3(0, 0.52, 0), 0.24], ["l_upper_arm", Vector3(0, -0.50, 0), 0.065], ["r_upper_arm", Vector3(0, -0.50, 0), 0.065]]
		_specs_artic = [["l_thigh", Vector3(0, -Proportions.THIGH_LENGTH, 0), 0.12], ["r_thigh", Vector3(0, -Proportions.THIGH_LENGTH, 0), 0.12], ["l_calf", Vector3(0, -0.36, 0), 0.10], ["r_calf", Vector3(0, -0.36, 0), 0.10], ["spine_upper", Vector3(0, 0.25, 0), 0.165], ["l_upper_arm", Vector3(0, -Proportions.UPPER_ARM, 0), 0.058], ["r_upper_arm", Vector3(0, -Proportions.UPPER_ARM, 0), 0.058], ["l_forearm", Vector3(0, -Proportions.FOREARM, 0), 0.043], ["r_forearm", Vector3(0, -Proportions.FOREARM, 0), 0.043], ["spine_upper", Vector3(0, 0.384, 0), 0.10, Vector3(0, 0.28, 0)], ["spine_upper", Vector3(0, 0.288, -0.2254), 0.12, Vector3(0, 0.032, -0.2254)]]
	var articulated: bool = _skeleton.get_meta("articulated", false)
	var specs: Array = _specs_artic if articulated else _specs_plain
	for spec in specs:
		var bone := _skeleton.find_bone(spec[0])
		var pose := global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)
		var a: Vector3 = pose * spec[3] if spec.size() > 3 else pose.origin
		var b: Vector3 = pose * spec[1]
		_capsules.append({"a": a, "b": b, "radius": float(spec[2])})


func _body_contacts() -> void:
	for capsule in _capsules:
		var a: Vector3 = capsule.a
		var b: Vector3 = capsule.b
		var ab := b - a
		var denominator := maxf(ab.length_squared(), 0.00001)
		for i in range(cols, _pts.size()):
			if _pinned(i):
				continue
			var closest := a + ab * clampf((_pts[i] - a).dot(ab) / denominator, 0.0, 1.0)
			var offset := _pts[i] - closest
			var radius: float = capsule.radius
			if offset.length() < radius:
				_pts[i] = closest + offset.normalized() * radius if offset.length() > 0.00001 else closest + Vector3.RIGHT * radius


func _solve_pair(a: int, b: int, rest: float, strength := 1.0) -> void:
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
	var correction := diff * ((d - rest) / d) / (wa + wb) * strength
	_pts[a] += correction * wa
	_pts[b] -= correction * wb


func _rebuild_mesh() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _pts
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_NORMAL] = _normals()
	arrays[Mesh.ARRAY_INDEX] = _triangles
	var am := mesh as ArrayMesh
	am.clear_surfaces()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, material_override)


func _indices() -> PackedInt32Array:
	var idx := PackedInt32Array()
	for r in rows:
		for c in (cols - 1 if open_panel else cols):
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
