class_name MeshBatcher
extends RefCounted
## Accumulates boxes during chunk generation and flushes them into a MINIMAL
## set of scene nodes: per-LAYER vertex-colored ArrayMeshes (street, building
## storeys, roof dressing - see push_layer) + one StaticBody3D holding every
## collision shape.
##
## WHY: a streamed city produces tens of thousands of decorative boxes; giving
## each its own MeshInstance3D would drown renderer and culler. The batcher
## keeps node counts at ~2 per chunk regardless of prop density, and purely
## decorative objects never get scripted nodes at all.
##
## VOXEL DESTRUCTION: every box is stored as a SPEC with an id; geometry is
## generated lazily at flush time from the spec list. Destroying a box
## (destroy_box) removes it from future meshes AND lets the chunk disable its
## CollisionShape3D - so blasts punch real, walk-through holes in buildings,
## then refresh_meshes() re-bakes the chunk mesh without the missing voxels.
##
## WINDING: verified against BoxMesh.get_mesh_arrays() - Godot front faces wind
## CLOCKWISE seen from outside, so natural CCW quads are emitted index-reversed.
##
## Determinism: entry order -> identical meshes and ids. ChunkBuilder adds
## boxes in plan-derived order only (never iterating unsorted dictionaries).

var _specs: Array[Dictionary] = []     # {id,pos,size,basis,color,collide,roof,material,layer}
var _destroyed := {}                   # id -> true
var _colliders: Array[Dictionary] = [] # {pos,size,basis,id,material}
var _prop_defs: Array[Dictionary] = [] # dynamic DestructibleProp manifests
var _box_count := 0

var _layers: Array[String] = [""]
var layer_nodes := {}                  # layer key -> MeshInstance3D

var _parent: Node3D
var _shape_nodes: Dictionary = {}      # vox_id -> CollisionShape3D

# Window damage tracking: id -> accumulated damage
var _vox_damage := {}                  # id -> float
var _cracked := {}                     # id -> true (cracked state)
var _destroy_threshold_mult := 14.0    # strength multiplier for destruction
var _crack_threshold_mult := 5.0       # strength multiplier for cracking


## DECORATIVE geometry - no physics. Windows, trim, treads, roof tiles,
## small props. If a player must not pass through it, this is the WRONG call.
func add_visual_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, false)


## Roof dressing (pitched shells, membranes, dormers) - flushed into a
## SEPARATE MeshInstance3D so interiors can be revealed by hiding it while
## the player is inside a building. Never carries collision.
func add_roof_visual_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, false, true)


## STRUCTURAL geometry - carries collision. Walls, slabs, ramps, landings,
## decks, parapets, railings meant to block, closed barriers.
func add_structural_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, true)


## DESTRUCTIBLE geometry - carries optional collision, is tracked with an id
## and can be blown out of the chunk mesh at runtime (see destroy_box).
func add_destructible_box(pos: Vector3, size: Vector3, color: Color,
		material: StringName, collide := true) -> void:
	_append_spec(pos, size, Basis.IDENTITY, color, collide, false, material)


## Manifest for a DYNAMIC destructible prop; ChunkBuilder.build() turns
## these into DestructibleProp nodes on the main thread. Deterministic order.
func add_prop_def(def: Dictionary) -> void:
	_prop_defs.append(def)


func add_box(pos: Vector3, size: Vector3, color: Color, collide := false) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, collide)


## Rotated variant used for stair ramps and pitched roof slabs. Basis must be
## a pure rotation (no scaling) or collision shapes will be distorted.
func add_box_rotated(pos: Vector3, size: Vector3, basis: Basis,
		color: Color, collide := false, roof_layer := false,
		material := &"") -> void:
	_append_spec(pos, size, basis, color, collide, roof_layer, material)


func _append_spec(pos: Vector3, size: Vector3, basis: Basis, color: Color,
		collide: bool, roof_layer: bool, material: StringName) -> void:
	_box_count += 1
	var id := _box_count
	# Glass renders translucent (tinted pane); everything else is opaque.
	var alpha := 0.55 if material == &"glass" else 1.0
	_specs.append({
		"id": id, "pos": pos, "size": size.abs(), "basis": basis,
		"color": Color(color, alpha),
		"collide": collide, "roof": roof_layer, "material": material,
		"layer": _layers.back(),
	})
	if collide:
		_colliders.append({"pos": pos, "size": size.abs(), "basis": basis,
				"id": id, "material": material})


## Start tagging subsequent boxes with `key` (see layer_nodes).
func push_layer(key: String) -> void:
	_layers.append(key)


func pop_layer() -> void:
	if _layers.size() > 1:
		_layers.pop_back()


func props() -> Array[Dictionary]:
	return _prop_defs


func box_count() -> int:
	return _box_count


func collider_count() -> int:
	return _colliders.size()


## Full deterministic record of everything added (for --citytest equality).
func manifest() -> Dictionary:
	return {"boxes": _box_count, "colliders": _colliders.duplicate(true),
			"group_keys": _group_keys(), "props": _prop_defs.duplicate(true)}


func _group_keys() -> Array:
	return _specs.map(func(s: Dictionary) -> String:
			return (s["color"] as Color).to_html())


## Builds nodes under `parent`: one MeshInstance3D per reveal LAYER (see
## layer_nodes) + "Static" StaticBody3D holding every collision shape.
func flush_into(parent: Node3D, body_layer := 1) -> Dictionary:
	_parent = parent
	var stats := {"mesh_nodes": 0, "colliders": _colliders.size()}

	var groups := _build_layers()
	for key: String in groups.keys():
		var mi := MeshInstance3D.new()
		mi.name = "L_%s" % (key.replace(":", "_").replace("|", "_")
				if key != "" else "street")
		mi.mesh = _mesh_from({key: groups[key]})
		parent.add_child(mi)
		layer_nodes[key] = mi
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
			# Only EXPLICITLY destructible materials carry a vox id:
			# plain structural boxes (ground plane, floor slabs, stair
			# ramps/landings) stay indestructible so nobody falls into
			# an abyss through a blasted-out floor.
			if StringName(col["material"]) != &"":
				shape_node.set_meta("vox_id", int(col["id"]))
				shape_node.set_meta("vox_material",
						StringName(col["material"]))
			_shape_nodes[int(col["id"])] = shape_node
			body.add_child(shape_node)
	return stats


# --- Destruction -------------------------------------------------------------

## Marks a box destroyed. Returns its spec ({pos,size,color,...}) so callers
## can spawn matching debris, or {} when the id is unknown/gone.
func destroy_box(id: int) -> Dictionary:
	if _destroyed.has(id):
		return {}
	_destroyed[id] = true
	for spec in _specs:
		if int(spec["id"]) == id:
			return spec.duplicate()
	return {}


## Applies bullet/impact damage to a voxel box (for glass cracking).
## For glass: accumulates damage, cracks at 5x material strength, shatters
## at 14x. Returns info dict with state.
## Non-glass materials are not damaged via this path (bullets don't erode them).
func damage_box(id: int, amount: float) -> Dictionary:
	if _destroyed.has(id):
		return {}
	for spec in _specs:
		if int(spec["id"]) == id:
			if spec["material"] != &"glass":
				return {}
			var total := float(_vox_damage.get(id, 0.0)) + amount
			_vox_damage[id] = total
			var mat := MaterialDB.get_material(&"glass")
			var strength := float(mat.get("strength", 1.0))
			var crack_thresh := strength * _crack_threshold_mult
			var destroy_thresh := strength * _destroy_threshold_mult
			if total >= destroy_thresh:
				# Shatter: destroy the box
				var info := destroy_box(id)
				info["shattered"] = true
				return info
			elif total >= crack_thresh and not _cracked.has(id):
				# Crack: mark for visual change, trigger rebuild
				_cracked[id] = true
				var info := spec.duplicate()
				info["cracked"] = true
				return info
			return {}
	return {}


## Re-bakes EVERY layer mesh from live (non-destroyed) specs. Deferred by
## the caller so several boxes destroyed in one frame cost ONE rebuild.
## Also removes destroyed CollisionShape3D nodes from the scene tree.
func refresh_meshes() -> void:
	if _parent == null or not is_instance_valid(_parent):
		return
	# Clean up destroyed collision shapes so they don't accumulate.
	for id: int in _destroyed:
		if _shape_nodes.has(id):
			var shape_node: CollisionShape3D = _shape_nodes[id]
			if is_instance_valid(shape_node):
				shape_node.queue_free()
			_shape_nodes.erase(id)
	var groups := _build_layers()
	for key: String in layer_nodes.keys():
		var mi: MeshInstance3D = layer_nodes[key]
		if not is_instance_valid(mi):
			continue
		if groups.has(key):
			mi.mesh = _mesh_from({key: groups[key]})
		else:
			mi.queue_free()   # every box in this layer was destroyed
			layer_nodes.erase(key)


# --- Geometry generation -----------------------------------------------------

## Groups live specs into vertex buffers, split by reveal LAYER (street,
## per-building storeys, per-building roof dressing). Glass gets its own
## surface per layer for transparency.
func _build_layers() -> Dictionary:
	var groups := {}
	for spec in _specs:
		if _destroyed.has(spec["id"]):
			continue
		# Composite key: building/floor tag + separate bucket for roof
		# dressing so legacy roof hiding keeps working within a tag.
		# Glass gets its own bucket ("|g") so it can use a transparent material.
		var key: String = spec["layer"]
		key += "|g" if spec["material"] == &"glass" \
				else ("|r" if spec["roof"] else "")
		var buf: Dictionary = groups.get_or_add(key, {
			"color": spec["color"],
			"verts": PackedVector3Array(),
			"normals": PackedVector3Array(),
			"colors": PackedColorArray(),
			"idx": PackedInt32Array(),
		})
		_emit_box(buf, spec)
	return groups


func _emit_box(buf: Dictionary, spec: Dictionary) -> void:
	var half := (spec["size"] as Vector3) * 0.5
	var basis: Basis = spec["basis"]
	var pos: Vector3 = spec["pos"]
	var verts: PackedVector3Array = buf["verts"]
	# Cracked glass: lighter and more opaque
	var col: Color = spec["color"]
	if spec["material"] == &"glass" and _cracked.has(spec["id"]):
		col = col.lightened(0.35)
		col.a = 0.8
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
			buf["colors"].append(col)
		# ... reversed into Godot's clockwise front-face winding.
		buf["idx"].append_array(PackedInt32Array([
			base, base + 2, base + 1,
			base, base + 3, base + 2,
		]))


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


func _mesh_from(groups: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key: String in groups.keys():
		var buf: Dictionary = groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf["verts"]
		arrays[Mesh.ARRAY_NORMAL] = buf["normals"]
		arrays[Mesh.ARRAY_COLOR] = buf["colors"]
		arrays[Mesh.ARRAY_INDEX] = buf["idx"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surf_idx := mesh.get_surface_count() - 1
		if key.ends_with("|g"):
			mesh.surface_set_material(surf_idx, _glass_material())
		else:
			mesh.surface_set_material(surf_idx, _shared_material())
	return mesh


static func _shared_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0
	return mat


static func _glass_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.1
	mat.metallic = 0.0
	return mat