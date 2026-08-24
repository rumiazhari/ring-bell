class_name DestructibleComponent
extends Node
## Structural integrity for ONE destructible body (door leaf, prop, crate).
##
## Incoming raw damage is converted by MaterialDB strength (steel shrugs off
## bullets that shred wood), accumulates as structural damage, and progressively
## sheds voxel debris at damage thresholds. At 100% the object is destroyed:
## a full burst of gravity-ruled debris replaces it and `destroyed` fires so
## the owner can free/convert itself.
##
## The owning Node3D must be in group "destructibles" (added here via parent).

signal damaged(amount: float, source_id: StringName)
signal destroyed()

@export var material_id: StringName = &"wood"
@export var integrity := 50.0            # effective-damage capacity
@export var debris_size := Vector3(1, 1, 1)
@export var debris_color := Color(0, 0, 0)   # black -> use MaterialDB color

var structural_damage := 0.0             # 0..integrity
var is_destroyed := false

var _meshes: Array[MeshInstance3D] = []
var _base_colors := {}


func _ready() -> void:
	var parent := get_parent()
	if parent != null and parent is CollisionObject3D:
		parent.add_to_group(&"destructibles")
	_collect_meshes(get_parent())


func _collect_meshes(root: Node) -> void:
	if root == null:
		return
	for child in root.get_children():
		if child is MeshInstance3D \
				and (child as MeshInstance3D).mesh != null:
			_meshes.append(child)
			_base_colors[child] = Color.BLACK
			var override := (child as MeshInstance3D).material_override
			if override is StandardMaterial3D:
				_base_colors[child] = (override as StandardMaterial3D).albedo_color
		_collect_meshes(child)


func apply_damage(raw_amount: float, source_id: StringName = &"") -> void:
	if is_destroyed or raw_amount <= 0.0:
		return
	var effective := MaterialDB.effective_damage(raw_amount, material_id)
	structural_damage += effective
	damaged.emit(effective, source_id)

	var fraction := structural_damage / maxf(integrity, 1.0)
	if fraction >= 1.0:
		_destroy(source_id)
		return
	if fraction >= 0.75 and randf() < 0.5:
		_shed(2, 1.6)
	elif fraction >= 0.4 and randf() < 0.35:
		_shed(1, 1.2)
	_tint_damage(fraction)


## Small partial spall - chips fly but the object stands.
func _shed(count: int, energy: float) -> void:
	var center := _owner_center()
	if center == Vector3.INF:
		return
	DebrisManager.burst_box(center, debris_size * 0.45, _color(),
			material_id, count, energy)


func _destroy(_source_id: StringName) -> void:
	is_destroyed = true
	var center := _owner_center()
	if center != Vector3.INF:
		var volume := debris_size.x * debris_size.y * debris_size.z
		var count := clampi(int(volume * 26.0), 6, 22)
		DebrisManager.burst_box(center, debris_size, _color(),
				material_id, count, 3.2)
	destroyed.emit()


func _tint_damage(fraction: float) -> void:
	for mesh in _meshes:
		if not is_instance_valid(mesh):
			continue
		var base: Color = _base_colors.get(mesh, Color(0.5, 0.5, 0.5))
		if base == Color.BLACK:
			base = MaterialDB.get_material(material_id).get("debris_color")
		if mesh.material_override is StandardMaterial3D:
			(mesh.material_override as StandardMaterial3D).albedo_color = \
					base.lerp(Color(0.16, 0.13, 0.1), fraction * 0.65)


func _color() -> Color:
	if debris_color != Color.BLACK:
		return debris_color
	return MaterialDB.get_material(material_id).get("debris_color")


func _owner_center() -> Vector3:
	var parent := get_parent()
	if parent is Node3D:
		return (parent as Node3D).global_position \
				+ Vector3.UP * debris_size.y * 0.25
	return Vector3.INF
