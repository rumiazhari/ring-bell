class_name MeshBatcher
extends RefCounted
## Accumulates boxes during chunk generation and flushes them into a MINIMAL
## set of scene nodes: one merged vertex-colored ArrayMesh + one StaticBody3D
## holding every collision shape.
##
## WHY: a streamed city produces tens of thousands of decorative boxes; giving
## each its own MeshInstance3D would drown renderer and culler. The batcher
## keeps node counts at ~2 per chunk regardless of prop density, and purely
## decorative objects never get scripted nodes at all.
##
## WINDING: verified against BoxMesh.get_mesh_arrays() - Godot front faces wind
## CLOCKWISE seen from outside, so natural CCW quads are emitted index-reversed.
##
## Determinism: entry order -> identical meshes. ChunkBuilder adds boxes in
## plan-derived order only (never iterating unsorted dictionaries).

var _groups := {}                      # color html string -> face buffers
var _colliders: Array[Dictionary] = [] # {pos, size, basis}
var _box_count := 0


func add_box(pos: Vector3, size: Vector3, color: Color, collide := false) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, collide)


## Rotated variant used for stair ramps and pitched roof slabs. Basis must be
## a pure rotation (no scaling) or collision shapes will be distorted.
func add_box_rotated(pos: Vector3, size: Vector3, basis: Basis,
		color: Color, collide := false) -> void:
	_box_count += 1
	# Force full opacity: scalar color math elsewhere can dim alpha, which
	# would leak through geometry and fragment the batch groups.
	color.a = 1.0
	var key := color.to_html()
	var buf: Dictionary = _groups.get_or_add(key, {
		"color": color,
		"verts": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"colors": PackedColorArray(),
		"idx": PackedInt32Array(),
	})
	var half := size.abs() * 0.5
	var verts: PackedVector3Array = buf["verts"]
	for f: Array in _face_defs():
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = n.cross(u)
		var hn: Vector3 = basis * (n * _axis_half(half, n))
		var hu: Vector3 = basis * (u * _axis_half(half, u))
		var hv: Vector3 = basis * (v * _axis_half(half, v))
		var c := pos + hn
		# CCW quad around n ...
		var corners: Array[Vector3] = [
			c - hu - hv, c + hu - hv, c + hu + hv, c - hu + hv,
		]
		var base := verts.size()
		for p in corners:
			verts.append(p)
			buf["normals"].append(basis * n)
			buf["colors"].append(color)
		# ... reversed into Godot's clockwise front-face winding.
		buf["idx"].append_array(PackedInt32Array([
			base, base + 2, base + 1,
			base, base + 3, base + 2,
		]))

	if collide:
		_colliders.append({"pos": pos, "size": size.abs(), "basis": basis})


## Half extent along the dominant axis of unit vector d (d is +/- one axis).
static func _axis_half(half: Vector3, d: Vector3) -> float:
	if absf(d.x) > 0.5:
		return half.x
	if absf(d.y) > 0.5:
		return half.y
	return half.z


## Six outward normals with tangent partners chosen so that u.cross(v) == n.
static func _face_defs() -> Array:
	return [
		[Vector3(1, 0, 0), Vector3(0, 1, 0)],    # +X  v=Z
		[Vector3(-1, 0, 0), Vector3(0, 0, 1)],   # -X  v=Y
		[Vector3(0, 1, 0), Vector3(0, 0, 1)],    # +Y  v=X
		[Vector3(0, -1, 0), Vector3(1, 0, 0)],   # -Y  v=Z
		[Vector3(0, 0, 1), Vector3(1, 0, 0)],    # +Z  v=Y
		[Vector3(0, 0, -1), Vector3(0, 1, 0)],   # -Z  v=X
	]


func box_count() -> int:
	return _box_count


func collider_count() -> int:
	return _colliders.size()


## Full deterministic record of everything added (for --citytest equality).
func manifest() -> Dictionary:
	return {"boxes": _box_count, "colliders": _colliders.duplicate(true),
			"group_keys": _groups.keys()}


## Builds nodes under `parent`: "Merged" MeshInstance3D + "Static" StaticBody3D.
## Returns stats. Safe to call standalone (nodes simply not in tree yet).
func flush_into(parent: Node3D, body_layer := 1) -> Dictionary:
	var stats := {"mesh_nodes": 0, "colliders": _colliders.size()}
	if not _groups.is_empty():
		var mi := MeshInstance3D.new()
		mi.name = "Merged"
		mi.mesh = _build_array_mesh()
		parent.add_child(mi)
		stats["mesh_nodes"] += 1

	if not _colliders.is_empty():
		var body := StaticBody3D.new()
		body.name = "Static"
		body.collision_layer = body_layer
		body.collision_mask = 0
		parent.add_child(body)
		for col in _colliders:
			var shape_node := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = col["size"]
			shape_node.shape = shape
			shape_node.position = col["pos"]
			shape_node.basis = col["basis"]
			body.add_child(shape_node)
	return stats


func _build_array_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key: String in _groups.keys():
		var buf: Dictionary = _groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf["verts"]
		arrays[Mesh.ARRAY_NORMAL] = buf["normals"]
		arrays[Mesh.ARRAY_COLOR] = buf["colors"]
		arrays[Mesh.ARRAY_INDEX] = buf["idx"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _shared_material())
	return mesh


static func _shared_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0
	return mat
