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

# Unified structural-damage records: id -> {damage: float}. Every
# destructible cell accumulates effective damage (raw / MaterialDB strength)
# and is destroyed only when it reaches its integrity. Deterministic - no
# random destruction of untouched geometry.
var _cell_damage := {}                 # id -> accumulated effective damage
var _cracked := {}                     # id -> true (glass visual crack state)


## Raw-damage integrity of one structural cell, scaled by volume so big
## panels need more punishment than small chips. Material toughness comes
## from the strength ladder here (NOT applied twice - callers accumulate
## RAW damage and compare against this threshold):
##   wood 1.0 < concrete 2.6 < steel 4.5, glass special-cased fragile.
## Tuning vs game weapons (ItemDB): an SMG round is 9 raw, a shotgun volley
## ~56 raw, a rocket ~130 raw at the falloff core.
##   - wood wall module (~1.36 m3): ~52 raw  -> ~6 SMG rounds, 1 rocket
##   - concrete module: ~136 raw             -> shrugs off SMGs, needs a
##                                             second rocket to finish
##   - steel module: ~235 raw                -> sustained explosives only
##   - glass pane: fixed 22 raw              -> 1 SMG hit cracks, 3 shatter,
##                                                shotgun volley shatters
static func cell_integrity(size: Vector3, material: StringName) -> float:
	if material == &"glass":
		return 22.0
	var vol := size.x * size.y * size.z
	var base := clampf(sqrt(maxf(vol, 0.01)) * 45.0, 12.0, 160.0)
	return base * float(MaterialDB.get_material(material).get("strength", 1.0))


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
## and can be blown out of the chunk mesh at runtime (see damage_box /
## destroy_box). Callers subdivide large surfaces into structural cells
## (0.75-1.25 m modules) so blasts carve believable holes instead of
## deleting whole walls; every cell is its own integrity record.
## owner/floor: optional placement metadata (building id + storey index)
## used by acceptance tests to tie every furniture collider to ITS floor.
func add_destructible_box(pos: Vector3, size: Vector3, color: Color,
		material: StringName, collide := true, owner_tag := "",
		floor_i := -1) -> void:
	_append_spec(pos, size, Basis.IDENTITY, color, collide, false, material,
			owner_tag, floor_i)


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
		material := StringName(""), owner_tag := "", floor_i := -1) -> void:
	_append_spec(pos, size, basis, color, collide, roof_layer, material,
			owner_tag, floor_i)


func _append_spec(pos: Vector3, size: Vector3, basis: Basis, color: Color,
		collide: bool, roof_layer: bool, material: StringName,
		owner_tag := "", floor_i := -1) -> void:
	_box_count += 1
	var id := _box_count
	# Glass renders translucent (tinted pane); everything else is opaque.
	var alpha := 0.55 if material == &"glass" else 1.0
	_specs.append({
		"id": id, "pos": pos, "size": size.abs(), "basis": basis,
		"color": Color(color, alpha),
		"collide": collide, "roof": roof_layer, "material": material,
		"layer": _layers.back(),
		"building_id": owner_tag, "floor_i": floor_i,
	})
	if collide:
		_colliders.append({"pos": pos, "size": size.abs(), "basis": basis,
				"id": id, "material": material, "tag": owner_tag})


## Start tagging subsequent boxes with `key` (see layer_nodes).
func push_layer(key: String) -> void:
	_layers.append(key)


func pop_layer() -> void:
	if _layers.size() > 1:
		_layers.pop_back()


func props() -> Array[Dictionary]:
	return _prop_defs


## Live spec list (tests / persistence readers). Treat as read-only.
func specs() -> Array[Dictionary]:
	return _specs


func is_destroyed(id: int) -> bool:
	return _destroyed.has(id)


func box_count() -> int:
	return _box_count


func collider_count() -> int:
	return _colliders.size()


## Test/introspection helper: applies the SAME visibility rules as
## ChunkManager.apply_floor_gate() directly to this batcher's layer nodes,
## writing the resulting visibility into `out` ({key: visible}) instead of
## requiring a live ChunkManager. Keeps the gate contract unit-testable
## against REAL generated layer_nodes (flush_into must have run).
func apply_floor_gate_probe(tag: String, max_floor: int, faded: Array,
		out: Dictionary) -> void:
	for key: String in layer_nodes.keys():
		var hide := false
		if max_floor >= 0 and tag != "" and key.begins_with(tag + ":"):
			var suffix := key.substr(tag.length() + 1)
			if suffix.begins_with("roof"):
				hide = true
			elif suffix.begins_with("f"):
				var rest := suffix.substr(1)
				var colon := rest.find(":")
				if colon >= 0:
					var fl := int(rest.substr(0, colon))
					var facade := rest.substr(colon + 1)
					hide = fl > max_floor \
							or (fl == max_floor and faded.has(facade))
				else:
					hide = int(rest) > max_floor
		out[key] = not hide


## Full deterministic record of everything added (for --citytest equality).
func manifest() -> Dictionary:
	return {"boxes": _box_count, "colliders": _colliders.duplicate(true),
			"group_keys": _group_keys(), "props": _prop_defs.duplicate(true)}


func _group_keys() -> Array:
	return _specs.map(func(s: Dictionary) -> String:
			return (s["color"] as Color).to_html())


## Builds nodes under `parent`: one MeshInstance3D per reveal LAYER (see
## layer_nodes) + "Static" StaticBody3D holding every collision shape.
## PERSISTENCE CONTRACT: cells already marked destroyed NEVER regain a
## CollisionShape3D here, so mesh and collision state always agree on
## first materialization (restored deltas are applied BEFORE this flush).
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
			if _destroyed.has(int(col["id"])):
				continue   # destroyed cell: no collider resurrection
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
			# Phase M: known feature tags ride along as vox_tag so the
			# parkour controller can classify WHAT it grabbed, not just
			# whether the wall is batched structure. Building-id owner
			# tags are deliberately not stamped.
			var feat_tag := String(col["tag"])
			if feat_tag in ["awning", "balcony", "tower", "bhplant",
					"bhladder", "bhexit", "scaffold"]:
				shape_node.set_meta("vox_tag", StringName(feat_tag))
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


## Stable, materialization-order-independent cell key: quantized world
## position + size. Two rebuilds of the same chunk under the same seed
## produce identical keys for identical geometry, so destroyed-cell sets
## round-trip through saves regardless of emission order.
static func cell_key(pos: Vector3, size: Vector3) -> String:
	return "%d:%d:%d|%d:%d:%d" % [
		roundi(pos.x * 20.0), roundi(pos.y * 20.0), roundi(pos.z * 20.0),
		roundi(size.x * 20.0), roundi(size.y * 20.0), roundi(size.z * 20.0),
	]


func cell_key_for_id(id: int) -> String:
	for spec in _specs:
		if int(spec["id"]) == id:
			return cell_key(spec["pos"], spec["size"])
	return ""


## Damage snapshot for persistence: {cell_key: {"damage": float}} for every
## partially damaged, still-standing cell.
func damage_state() -> Dictionary:
	var out := {}
	for id: int in _cell_damage.keys():
		if _destroyed.has(id):
			continue
		var key := cell_key_for_id(id)
		if key != "":
			out[key] = {"damage": float(_cell_damage[id])}
	return out


## Restore partial-damage state after a chunk rebuild (keys as produced by
## damage_state()). Values are ACCUMULATED RAW damage; also re-marks any
## cells whose restored raw damage already meets their integrity as
## destroyed WITHOUT spawning debris again.
func load_damage_state(data: Dictionary) -> void:
	_cell_damage.clear()
	for spec in _specs:
		var key := cell_key(spec["pos"], spec["size"])
		if not data.has(key):
			continue
		var id := int(spec["id"])
		var dmg := float(data[key].get("damage", 0.0))
		if dmg >= cell_integrity(spec["size"], spec["material"]):
			if not _destroyed.has(id):
				_destroyed[id] = true
		else:
			_cell_damage[id] = dmg


## Applies damage to a structural cell. `amount` is the RAW incoming
## damage; material toughness enters exactly ONCE via this comparison
## against cell_integrity() (which is scaled by MaterialDB strength):
##   total_raw >= integrity -> destroyed.
## Glass additionally flips to a cracked visual at >= 40% of its integrity.
## Returns {} when nothing changed; otherwise
##   {shattered: true, ...spec}      - cell destroyed this hit
##   {cracked: true, ...spec}        - glass crossed the crack threshold
func damage_box(id: int, amount: float) -> Dictionary:
	if _destroyed.has(id) or amount <= 0.0:
		return {}
	for spec in _specs:
		if int(spec["id"]) == id:
			var material: StringName = spec["material"]
			if material == &"":
				return {}   # indestructible plain structural box
			# Accumulate RAW damage; the strength ladder lives only in
			# cell_integrity(), so concrete/wood/steel differ by their
			# thresholds instead of a double-applied divisor.
			var total := float(_cell_damage.get(id, 0.0)) + amount
			_cell_damage[id] = total
			var integ := cell_integrity(spec["size"], material)
			if total >= integ:
				var info := destroy_box(id)
				info["shattered"] = true
				return info
			# Cracked-glass visual feedback only.
			if material == &"glass" and not _cracked.has(id) \
					and total >= integ * 0.4:
				_cracked[id] = true
				var info2: Dictionary = spec.duplicate()
				info2["cracked"] = true
				return info2
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