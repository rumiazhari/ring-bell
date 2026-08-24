extends Node
## Central havoc-physics service: debris spawning, gravity fragments and
## explosions.
##
## Owns every DebrisPiece in the scene so counts stay bounded (oldest pieces
## are culled first). Explosions are radial damage+impulse events that feed
## back into EVERY system: destructible structures erode by material,
## rigid debris gets bounced away, characters are knocked back, static
## geometry chips, zombies hear the blast and come investigating.

const MAX_ACTIVE_PIECES := 170
const PIECE_BASE_SIZE := 0.22       # target voxel edge length for bursts
const CHIP_RAYS := 10               # static-geometry chipping probes
const CHARACTER_KNOCK := 5.5        # explosion knockback scale on actors

var _pieces: Array[DebrisPiece] = []


func _ready() -> void:
	pass


# --- Debris ------------------------------------------------------------------

func spawn_piece(pos: Vector3, size: Vector3, color: Color,
		material_id: StringName, impulse: Vector3) -> DebrisPiece:
	var piece := DebrisPiece.new()
	get_tree().current_scene.add_child(piece)
	piece.global_position = pos
	piece.setup(size, color, material_id, impulse)
	_pieces.append(piece)
	# Pieces free THEMSELVES when their lifetime ends; drop the stale
	# reference here or the cull below later pops a freed instance into a
	# typed variable (hard script error -> error flood -> game freeze).
	piece.tree_exited.connect(func() -> void: _pieces.erase(piece))
	while _pieces.size() > MAX_ACTIVE_PIECES:
		var oldest = _pieces.pop_front()   # untyped: may already be freed
		if oldest is DebrisPiece and is_instance_valid(oldest):
			oldest.queue_free()
	return piece


## Shatter a box-shaped object into `count` voxel fragments. Pieces inherit
## the object's volume footprint, fly outward from its center and then fall
## under normal gravity - the core "havoc" look.
func burst_box(center: Vector3, size: Vector3, color: Color,
		material_id: StringName, count: int, energy := 2.5) -> void:
	var mat := MaterialDB.get_material(material_id)
	var scatter := float(mat.get("debris_energy", 1.0))
	var half := Vector3(size.abs()) * 0.5
	for i: int in maxi(count, 1):
		# Semi-grid sampling inside the original volume keeps a voxel look.
		var offset := Vector3(
				randf_range(-half.x * 0.85, half.x * 0.85),
				randf_range(-half.y * 0.85, half.y * 0.85),
				randf_range(-half.z * 0.85, half.z * 0.85))
		var edge := clampf(minf(minf(half.x, half.y), half.z) * randf_range(
				0.6, 1.4), PIECE_BASE_SIZE * 0.55, PIECE_BASE_SIZE * 1.9)
		var dir := (offset * 2.0 + Vector3(randf_range(-0.4, 0.4),
				randf_range(0.6, 1.4), randf_range(-0.4, 0.4))).normalized()
		var impulse := dir * energy * scatter * randf_range(0.5, 1.2)
		spawn_piece(center + offset, Vector3.ONE * edge,
				color.lightened(randf_range(-0.06, 0.12)), material_id,
				impulse)


# --- Explosions --------------------------------------------------------------

## Radius-zone explosion: distance-falloff structural damage, actor damage +
## knockback, debris impulses, static chipping, light/sphere VFX, camera
## shake and a zombie-audible noise event.
func explosion(pos: Vector3, radius: float, damage: float,
		source_id: StringName = &"", material_hint: StringName = &"concrete") -> void:
	_explosion_vfx(pos, radius)

	# Structures (doors, props, crates) erode by their material strength.
	for node in get_tree().get_nodes_in_group(&"destructibles"):
		var body := node as Node3D
		if body == null or not is_instance_valid(body):
			continue
		var d := body.global_position.distance_to(pos)
		if d > radius:
			continue
		var falloff := 1.0 - d / radius
		if body.has_method("take_structural_damage"):
			body.take_structural_damage(damage * falloff * 1.6, source_id)

	# Living actors: damage plus radial knockback.
	for group in [&"survivors", &"zombies"]:
		for node in get_tree().get_nodes_in_group(group):
			var actor := node as Node3D
			if actor == null or not is_instance_valid(actor):
				continue
			var d := actor.global_position.distance_to(pos)
			if d > radius * 1.25 or not actor.has_method("take_damage"):
				continue
			var falloff := 1.0 - d / (radius * 1.25)
			actor.take_damage(damage * falloff, source_id)
			# Keep blasts mostly HORIZONTAL: a shallow radial push reads as
			# a shockwave, while a strong vertical component just launches
			# bodies balloon-like into the sky.
			var away := (actor.global_position - pos)
			away.y = maxf(away.y * 0.25, 0.3)
			if actor.has_method("apply_knockback"):
				actor.apply_knockback(away.normalized()
						* CHARACTER_KNOCK * falloff)

	_bounce_rigid_bodies(pos, radius, damage)
	_chip_static_geometry(pos, radius, material_hint, damage)

	EventBus.attack_performed.emit(pos)      # zombie hearing reuses noise cue
	EventBus.explosion_occurred.emit(pos)


func _bounce_rigid_bodies(pos: Vector3, radius: float, damage: float) -> void:
	var space := _space()
	if space == null:
		return
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, pos)
	params.collision_mask = 16   # debris layer
	for hit in space.intersect_shape(params, 48):
		var body := hit.get("collider") as RigidBody3D
		if body != null and is_instance_valid(body):
			var dist := body.global_position.distance_to(pos)
			var away := (body.global_position - pos)
			# Boost the vertical component AFTER measuring distance: the
			# lengthened vector used to overshoot `radius` for bodies near
			# the edge, making falloff NEGATIVE and sucking debris inward.
			away.y = maxf(away.y * 0.5 + 0.6, 1.0)
			var falloff := clampf(1.0 - dist / radius, 0.0, 1.0)
			if falloff <= 0.0 or away.length_squared() < 0.0001:
				continue
			body.apply_central_impulse(
					away.normalized() * damage * falloff * 0.12 * body.mass)


## The batched city mesh is voxel-destructible: blasts carve the hit boxes
## out of the chunk (collision off + mesh re-bake) and spawn matching debris
## in their place. Weak hits only chip dust off the surface.
func _chip_static_geometry(pos: Vector3, radius: float,
		material_hint: StringName, damage := 0.0) -> void:
	var space := _space()
	if space == null:
		return
	var mat := MaterialDB.get_material(material_hint)
	var color: Color = mat.get("debris_color")
	var energy := damage_to_energy(damage_for_radius(radius))
	for i in CHIP_RAYS:
		var dir := Vector3(randf_range(-1, 1), randf_range(-0.35, 0.75),
				randf_range(-1, 1)).normalized()
		var q := PhysicsRayQueryParameters3D.create(pos,
				pos + dir * radius * 1.6, 1)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		if damage >= 40.0:
			var info := _resolve_voxel(hit)
			if not info.is_empty():
				_voxel_debris(info, energy)
				continue
		var point: Vector3 = hit["position"]
		var normal: Vector3 = hit["normal"]
		spawn_piece(point + normal * 0.08,
				Vector3.ONE * randf_range(0.09, 0.2),
				color.lightened(randf_range(-0.05, 0.15)), material_hint,
				(normal + Vector3.UP * 0.7).normalized() * energy * 0.5)


## Bullet-grade static hits: glass cracks and shatters by damage level;
## other materials just chip dust. Buildings are only fully destructible
func bullet_hit_static(hit: Dictionary, damage: float) -> void:
	var info: Dictionary = _voxel_info(hit)
	if not info.is_empty() and info.get("material", &"") == &"glass":
		# Glass windows crack and shatter by damage level
		var managers := get_tree().get_nodes_in_group(&"chunk_manager")
		if not managers.is_empty():
			var mgr: ChunkManager = managers[0]
			var res: Dictionary = mgr.damage_box(info["node"], damage)
			if res.get("shattered", false):
				# Shattered: spawn glass shards
				_voxel_debris(info, damage_to_energy(damage))
			elif res.get("cracked", false):
				# Cracked: small shard puff to sell the hit
				spawn_piece(
						(hit["position"] as Vector3) + hit["normal"] * 0.05,
						Vector3.ONE * randf_range(0.05, 0.12),
						Color("d0d8e0"), &"glass", hit["normal"] * 1.2)
		return
	# Non-glass: just a cosmetic dust chip
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	spawn_piece((hit["position"] as Vector3) + normal * 0.06,
			Vector3.ONE * randf_range(0.07, 0.13), Color("7d7a70"),
			&"concrete", (normal * 0.7 + Vector3.UP * 0.5) * 1.6)


## Resolve a physics hit to its batched box spec and destroy it via the
## owning ChunkManager.
func _resolve_voxel(hit: Dictionary) -> Dictionary:
	var body: Object = hit.get("collider")
	if body is StaticBody3D and hit.has("shape"):
		var sb := body as StaticBody3D
		var owner_id := sb.shape_find_owner(int(hit["shape"]))
		var node := sb.shape_owner_get_owner(owner_id)
		if node is Node3D and (node as Node3D).has_meta("vox_id"):
			for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
				if mgr.has_method(&"destroy_box"):
					var info: Dictionary = mgr.destroy_box(node)
					if not info.is_empty():
						return info
	return {}


## Resolves a physics hit to its batched box spec WITHOUT destroying it.
## Returns info dict with {node, pos, size, color, material} or {}.
func _voxel_info(hit: Dictionary) -> Dictionary:
	var body: Object = hit.get("collider")
	if body is StaticBody3D and hit.has("shape"):
		var sb := body as StaticBody3D
		var owner_id := sb.shape_find_owner(int(hit["shape"]))
		var node := sb.shape_owner_get_owner(owner_id)
		if node is Node3D and (node as Node3D).has_meta("vox_id"):
			var id := int((node as Node3D).get_meta("vox_id"))
			for mgr in get_tree().get_nodes_in_group(&"chunk_manager"):
				if mgr.has_method("damage_box"):
					# Find the chunk that owns this static body
					for c: Vector2i in mgr._chunks:
						var rec: Dictionary = mgr._chunks[c]
						var st: Node = rec.get("static")
						if st == null or not is_instance_valid(st) \
								or st != node.get_parent():
							continue
						var batcher: MeshBatcher = rec.get("batcher")
						if batcher == null:
							continue
						for spec in batcher._specs:
							if int(spec["id"]) == id:
								return {
									"node": node,
									"pos": spec["pos"],
									"size": spec["size"],
									"color": spec["color"],
									"material": spec["material"],
								}
	return {}


func _voxel_debris(info: Dictionary, energy: float) -> void:
	var size: Vector3 = info["size"]
	var mat_id: StringName = info.get("material", &"")
	if mat_id == &"":
		mat_id = &"concrete"
	_burst_voxel(info["pos"], size, info["color"], mat_id, energy)


func _burst_voxel(center: Vector3, size: Vector3, color: Color,
		material_id: StringName, energy: float) -> void:
	var volume: float = size.x * size.y * size.z
	burst_box(center, size.clamp(Vector3.ONE * 0.2, Vector3.ONE * 2.5),
			color, material_id,
			clampi(int(volume * 22.0), 4, 14),
			clampf(energy * 0.55, 1.5, 7.0))


func damage_to_energy(damage: float) -> float:
	return clampf(sqrt(maxf(damage, 1.0)) * 0.8, 1.0, 8.0)


func damage_for_radius(radius: float) -> float:
	# Inverse of the rocket's tuning: used only for chip energies.
	return radius * radius * 5.0


func _explosion_vfx(pos: Vector3, radius: float) -> void:
	var root := get_tree().current_scene
	if root == null:
		return

	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.72, 0.35)
	flash.light_energy = 6.0
	flash.omni_range = radius * 3.0
	flash.position = pos + Vector3.UP * 0.6
	root.add_child(flash)

	var fireball := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	fireball.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.2, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fireball.material_override = mat
	fireball.position = pos
	root.add_child(fireball)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(fireball, "scale", Vector3.ONE * radius * 1.8, 0.28)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.32)
	tween.parallel().tween_property(flash, "light_energy", 0.0, 0.34)
	tween.chain().tween_callback(func() -> void:
		fireball.queue_free()
		flash.queue_free())

	for rig in get_tree().get_nodes_in_group(&"camera_rig"):
		if rig.has_method(&"add_shake"):
			rig.call(&"add_shake",
					clampf(radius * 0.14, 0.15, 0.9))


func _space() -> PhysicsDirectSpaceState3D:
	var scene := get_tree().current_scene
	if scene == null or not scene.is_inside_tree():
		return null
	return scene.get_world_3d().direct_space_state
