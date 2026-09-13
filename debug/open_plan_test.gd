extends Node3D
var failures := 0
var checks := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		if failures < 30:
			print("[OpenPlan] FAIL ", label)

func _ready() -> void:
	var floors := 0
	var enclosed := 0
	for size: Vector2 in [Vector2(10, 14), Vector2(2.5, 5), Vector2(16, 20), Vector2(5.2, 6.6), Vector2(6.4, 15), Vector2(14, 7.6), Vector2(9.4, 11), Vector2(13, 14), Vector2(5.9, 8.7)]:
		for edge in 4:
			for use_val: String in InteriorPlan.ROOM_PROGRAMS:
				var spec := {"id": "test_%s_%d_%s" % [size, edge, use_val], "rect": Rect2(Vector2(-31, 17), size), "floors": 3, "floor_h": 3.0, "door_edge": edge, "use": use_val, "seed_used": 19041207}
				var man := InteriorPlan.build_for_building(spec)
				check(man == InteriorPlan.build_for_building(spec), "determinism " + spec.id)
				var errors := InteriorPlan.validate(man)
				check(errors.is_empty(), "%s %s" % [spec.id, errors])
				for fl: Dictionary in man.floors:
					floors += 1
					check(_walkable(fl, spec), "walkable " + spec.id + " floor " + str(fl.floor_i))
					check(fl.partitions.size() + fl.solid_walls.size() <= 2, "two wall cap")
					var area := 0.0
					var enclosed_toilet := false
					for room: Dictionary in fl.rooms:
						if room.enclosed:
							enclosed += 1
							area += room.rect.get_area()
							if room.kind == &"toilet":
								enclosed_toilet = true
					check(area < spec.rect.get_area() * 0.45, "mostly open floor")
					# Narrow historic service wings cannot fit a private 2.8 m cell
					# without consuming their mandatory entrance/stair route.
					if minf(size.x, size.y) >= 7.0:
						check(enclosed_toilet, "usable floors keep an enclosed toilet")
					for part: Dictionary in fl.partitions:
						check(BuildingBuilder.interior_partition_visible(part, spec, fl.floor_i), "wall clear of real circulation")
						check(part.rect.intersects(part.opening), "real opening")
					check(fl.doors.size() == fl.partitions.size(), "one door per partition")
					for door_i in fl.doors.size():
						var door: Dictionary = fl.doors[door_i]
						var part: Dictionary = fl.partitions[door_i]
						check(door.wall_rect == part.rect, "door belongs to matching wall")
						check(part.opening.has_point(Vector2(door.position.x, door.position.z)), "door sits in matching opening")
						check(door.room_a == part.a and door.room_b == part.b, "door connects partition rooms")
					for item: Dictionary in fl.furniture:
						for route: Rect2 in fl.circulation:
							check(not item.rect.intersects(route), "furniture clears routes")
					for room: Dictionary in fl.rooms:
						if room.kind == &"hall":
							continue
						var furnished := false
						for item: Dictionary in fl.furniture:
							if item.room_id == room.id:
								furnished = true
								break
						if minf(size.x, size.y) >= 7.0:
							check(furnished, "semantic zone has furniture %s %s" % [spec.id, room.kind])
	print("[OpenPlan] floors=%d enclosed rooms=%d checks=%d" % [floors, enclosed, checks])
	check(enclosed > floors / 2, "essential enclosures retained")
	await _traverse_door()
	await _doors()
	print("[OpenPlan] finished with %d failure(s), %d checks" % [failures, checks])
	get_tree().quit(0 if failures == 0 else 1)

func _walkable(fl: Dictionary, spec: Dictionary) -> bool:
	var inner: Rect2 = (spec.rect as Rect2).grow(-0.65)
	var obstacles: Array[Rect2] = []
	for part: Dictionary in fl.partitions:
		obstacles.append_array(BuildingBuilder._rect_subtract(part.rect, part.opening))
	obstacles.append_array(fl.solid_walls)
	for item: Dictionary in fl.furniture:
		obstacles.append(item.rect)
	var free := {}
	var step := 0.15
	for x in int(inner.size.x / step) + 1:
		for y in int(inner.size.y / step) + 1:
			var pt := inner.position + Vector2(x, y) * step
			var clear := true
			for r in obstacles:
				if r.grow(0.30).has_point(pt):
					clear = false
					break
			if clear:
				free[Vector2i(x, y)] = true
	if free.is_empty():
		return false
	var visited := {}
	var start: Vector2i = free.keys()[0]
	for candidate: Vector2i in free:
		if (inner.position + Vector2(candidate) * step).distance_squared_to(inner.get_center()) \
				< (inner.position + Vector2(start) * step).distance_squared_to(inner.get_center()):
			start = candidate
	var queue: Array = [start]
	visited[queue[0]] = true
	var idx := 0
	while idx < queue.size():
		var cell: Vector2i = queue[idx]
		idx += 1
		for offset: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var nb := cell + offset
			if free.has(nb) and not visited.has(nb):
				visited[nb] = true
				queue.append(nb)
	# Every semantic room must offer reachable standing space with a 0.5m body.
	for room: Dictionary in fl.rooms:
		var reached := false
		for cell: Vector2i in visited:
			if (room.rect as Rect2).has_point(inner.position + Vector2(cell) * step):
				reached = true
				break
		if not reached:
			return false
	return true

func _doors() -> void:
	# The same sweep is occupied by actor, wall, furniture and debris bodies.
	for body: PhysicsBody3D in [StaticBody3D.new(), CharacterBody3D.new(), RigidBody3D.new()]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4, 3, 4)
		shape.shape = box
		body.add_child(shape)
		add_child(body)
		if body is RigidBody3D:
			body.freeze = true
	for edge in 4:
		for hinge: String in ["left", "right"]:
			var door := Door.new()
			door.setup({"id": "test", "width": 1.3, "height": 2.25, "edge": edge, "hinge": hinge})
			add_child(door)
			check(door.is_solid(), "closed blocks")
			door.open()
			check(door._leaf.collision_layer == 0 and door._leaf.collision_mask == 0, "moving collision disabled")
			for tick in 40:
				await get_tree().physics_frame
			check(door.is_open() and absf(door._leaf.rotation.y - door._open_angle) < 0.001, "opens despite occupied sweep")
			check(not door.is_solid() and door.is_passage_clear(), "open passage clear")
			door.set_active_enabled(false)
			door.set_active_enabled(true)
			check(door._leaf.collision_layer == 0, "warm reentry cannot solidify open leaf")
			door.close()
			check(door._leaf.collision_layer == 0 and door._leaf.collision_mask == 0, "closing collision disabled")
			for tick in 40:
				await get_tree().physics_frame
			check(door.state == Door.DoorState.CLOSED and door.is_solid(), "closes despite occupied sweep")
			check(door._leaf.collision_layer == 1 and door._leaf.collision_mask == (1 | 16), "fully closed collision restored")
			door.set_active_enabled(false)
			check(door._leaf.collision_layer == 0, "inactive closed collision disabled")
			door.set_active_enabled(true)
			check(door.is_solid(), "active closed collision restored")
			door.load_state({"open": true})
			check(not door.is_solid() and not door.is_physics_processing(), "loaded open collision and idle")
			door.queue_free()
			await get_tree().physics_frame

func _traverse_door() -> void:
	var door := Door.new()
	door.setup({"id": "walk", "width": 1.3, "height": 2.25, "position": Vector3(20, 0, 0)})
	add_child(door)
	var actor := CharacterBody3D.new()
	actor.collision_layer = 2
	actor.collision_mask = 1
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.28
	capsule.height = 1.7
	shape.shape = capsule
	actor.add_child(shape)
	add_child(actor)
	actor.position = Vector3(20, 1, -1.5)
	for tick in 60:
		await get_tree().physics_frame
		actor.velocity = Vector3(0, 0, 3)
		actor.move_and_slide()
	check(actor.position.z < 0, "closed door stops actual capsule movement")
	door.open()
	for tick in 60:
		await get_tree().physics_frame
		actor.velocity = Vector3(0, 0, 3)
		actor.move_and_slide()
	check(actor.position.z > 1.0, "capsule traverses opening without excluding leaf RID")
	door.queue_free()
	actor.queue_free()
	await get_tree().physics_frame
