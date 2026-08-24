class_name SkirtCloth
extends MeshInstance3D
## Verlet-simulated cloth skirt: a ring grid of particles pinned at the waist,
## pulled by gravity, constrained by structural springs and kept outside the
## legs by a radial collision cylinder. Rebuilds its ArrayMesh every physics
## tick - trivial cost at skirt resolution (~50 points).
##
## Lives in LOCAL space under the model root (upright characters only), so
## walking sway comes for free: the pinned ring drags the free rows along.
## When the body dies, CorpseBody freezes the sim and the last drape stays.

var radius_top := 0.19
var radius_hem := 0.44
var length := 0.6          # cloth drop from the waist ring
var cols := 10             # ring segments
var rows := 4              # vertical segments below the pinned ring
var ground_local_y := 0.0    # model-local floor clamp (node sits at waist)
var simulating := true

var _pts := PackedVector3Array()
var _prev := PackedVector3Array()
var _rest_v := 0.0
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
	_rest_v = length / float(rows)

	mesh = ArrayMesh.new()
	_rebuild_mesh()


func _idx(r: int, c: int) -> int:
	return r * cols + (c % cols)


func set_simulating(on: bool) -> void:
	simulating = on
	set_physics_process(on)


func _physics_process(delta: float) -> void:
	if not simulating:
		return
	var dt := minf(delta, 1.0 / 30.0)

	# Verlet integration with gravity and damping.
	for r in range(1, rows + 1):
		for c in cols:
			var i := _idx(r, c)
			var p := _pts[i]
			var vel := (p - _prev[i]) * 0.97
			_prev[i] = p
			_pts[i] = p + vel + Vector3.DOWN * 9.8 * dt * dt

	# Constraint relaxation.
	for iter in 3:
		for r in rows:
			for c in cols:
				_solve_pair(_idx(r, c), _idx(r + 1, c),
						_rest_v * (1.0 if r > 0 else 0.9))
				_solve_pair(_idx(r, c), _idx(r, c + 1), _rest_h[r])
		# Pin the waist ring.
		for c in cols:
			var ang := TAU * float(c) / float(cols)
			_pts[_idx(0, c)] = Vector3(cos(ang) * radius_top, 0.0,
					sin(ang) * radius_top)

	# Collisions: keep clear of the legs, above the floor.
	for r in range(1, rows + 1):
		for c in cols:
			var i := _idx(r, c)
			var p := _pts[i]
			var planar := Vector2(p.x, p.z)
			var d := planar.length()
			if d < 0.17:
				if d < 0.0001:
					planar = Vector2(0.17, 0)
				else:
					planar *= 0.17 / d
				p.x = planar.x
				p.z = planar.y
			if p.y < ground_local_y - position.y:
				p.y = ground_local_y - position.y
			_pts[i] = p

	_rebuild_mesh()


func _solve_pair(a: int, b: int, rest: float) -> void:
	var pa := _pts[a]
	var pb := _pts[b]
	var diff := pb - pa
	var d := diff.length()
	if d < 0.0001:
		return
	var correction := diff * ((d - rest) / d) * 0.5
	# Only the lower point moves when `a` is a pinned upper row.
	if a < cols:
		_pts[b] = pb - correction * 2.0
	else:
		_pts[a] += correction
		_pts[b] -= correction


func _rebuild_mesh() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _pts
	arrays[Mesh.ARRAY_NORMAL] = _normals()
	arrays[Mesh.ARRAY_INDEX] = _indices()
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
			idx.append_array(PackedInt32Array([a, d, e, a, e, b]))
	return idx


func _normals() -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(_pts.size())
	for r in rows + 1:
		for c in cols:
			var tangential := _pts[_idx(r, c + 1)] \
					- _pts[_idx(r, maxi(c - 1, 0))]
			var down := Vector3.DOWN
			var n := tangential.cross(down).normalized()
			normals[_idx(r, c)] = n if n.length_squared() > 0.5 \
					else Vector3.RIGHT
	return normals
