class_name DestructibleProp
extends StaticBody3D
## A standalone destructible world object emitted by ChunkBuilder instead of
## baked static boxes: wrecked cars, lamp posts, trees, market stalls, trash
## bins.
##
## Built from a manifest dict so generation stays deterministic:
##   { position: Vector3,          # ground anchor
##     yaw: float,                 # rotation around Y
##     material: StringName,       # MaterialDB id (steel > concrete > wood)
##     integrity: float,           # optional explicit capacity
##     parts: [ { offset: Vector3, # local CENTER of this box (y included)
##                size: Vector3, color: Color, collide: bool } ] }
##
## Guns/explosions erode it by material strength; total failure replaces the
## whole object with voxel debris that falls and piles under real gravity,
## and explosion impulses bounce surviving pieces away.

var _destructible: DestructibleComponent

## Highest surface of any part above the anchor - lets targeting logic
## distinguish shootable-height props (trees, posts) from floor clutter.
var top_height := 0.0


func setup(def: Dictionary) -> void:
	position = def.get("position", Vector3.ZERO)
	rotation.y = float(def.get("yaw", 0.0))
	var material_id: StringName = def.get("material", &"wood")

	collision_layer = 1
	collision_mask = 0

	var bounds_min := Vector3.INF
	var bounds_max := -Vector3.INF
	var volume := 0.0
	for part: Dictionary in def.get("parts", []):
		var size: Vector3 = part["size"]
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = part["color"]
		mat.roughness = 0.95
		mat.metallic = 0.35 if material_id == &"steel" else 0.0
		mi.material_override = mat
		mi.position = part["offset"]
		add_child(mi)

		if bool(part.get("collide", true)):
			var shape := CollisionShape3D.new()
			var box_shape := BoxShape3D.new()
			box_shape.size = size
			shape.shape = box_shape
			shape.position = part["offset"]
			add_child(shape)

		bounds_min = bounds_min.min(part["offset"] - size * 0.5)
		bounds_max = bounds_max.max(part["offset"] + size * 0.5)
		volume += size.x * size.y * size.z
		top_height = maxf(top_height, part["offset"].y + size.y * 0.5)

	if bounds_min == Vector3.INF:
		return

	_destructible = DestructibleComponent.new()
	_destructible.material_id = material_id
	var bounds := bounds_max - bounds_min
	_destructible.integrity = float(def.get("integrity",
			_default_integrity(volume, material_id)))
	_destructible.debris_size = bounds.clamp(Vector3.ONE * 0.25,
			Vector3.ONE * 2.6)
	_destructible.destroyed.connect(queue_free)
	add_child(_destructible)


## Tougher materials multiply the capacity: an SMG mag kills a trash bin, a
## shotgun blast fells a lamp post or tree, and only rockets (or sustained
## fire) kill a car.
func _default_integrity(total_volume: float, material_id: StringName) -> float:
	return clampf(sqrt(maxf(total_volume, 0.05)) * 24.0, 14.0, 140.0) \
			* float(MaterialDB.get_material(material_id).get("strength", 1.0)) \
			* 0.55


func take_structural_damage(amount: float, source_id: StringName = &"") -> void:
	if _destructible != null:
		_destructible.apply_damage(amount, source_id)
