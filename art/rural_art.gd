extends RefCounted
## Reusable player-facing rural art primitives.
##
## This module is deliberately geometry-only: it consumes deterministic manifest
## data and appends low-poly surfaces to caller-owned arrays. It never chooses
## positions, touches the scene tree, or owns gameplay state. The silhouettes
## are intentionally distinct by category so rural scenery does not collapse
## into one green placeholder cube vocabulary.

static func _append_quad(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, normal: Vector3 = Vector3.UP) -> void:
	var base: int = verts.size()
	verts.append(a)
	verts.append(b)
	verts.append(c)
	verts.append(d)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)

static func _append_triangle(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, col: Color, normal: Vector3 = Vector3.UP) -> void:
	var base: int = verts.size()
	verts.append(a)
	verts.append(b)
	verts.append(c)
	normals.append(normal)
	normals.append(normal)
	normals.append(normal)
	colors.append(col)
	colors.append(col)
	colors.append(col)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)

static func _append_box(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, size: Vector3, col: Color) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var p: Array[Vector3] = [
		center + Vector3(-hx, -hy, -hz), center + Vector3(hx, -hy, -hz),
		center + Vector3(hx, -hy, hz), center + Vector3(-hx, -hy, hz),
		center + Vector3(-hx, hy, -hz), center + Vector3(hx, hy, -hz),
		center + Vector3(hx, hy, hz), center + Vector3(-hx, hy, hz)
	]
	_append_quad(verts, normals, colors, indices, p[0], p[1], p[2], p[3], col, Vector3.DOWN)
	_append_quad(verts, normals, colors, indices, p[4], p[7], p[6], p[5], col, Vector3.UP)
	_append_quad(verts, normals, colors, indices, p[0], p[4], p[5], p[1], col, Vector3(0, 0, -1))
	_append_quad(verts, normals, colors, indices, p[2], p[6], p[7], p[3], col, Vector3(0, 0, 1))
	_append_quad(verts, normals, colors, indices, p[1], p[5], p[6], p[2], col, Vector3.RIGHT)
	_append_quad(verts, normals, colors, indices, p[3], p[7], p[4], p[0], col, Vector3.LEFT)

static func _append_oriented_box(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, size: Vector3, yaw: float, col: Color) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var local_points: Array[Vector3] = [
		Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz),
		Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)
	]
	var points: Array[Vector3] = []
	var co: float = cos(yaw)
	var si: float = sin(yaw)
	for local_point in local_points:
		var rotated: Vector2 = Vector2(local_point.x * co - local_point.z * si, local_point.x * si + local_point.z * co)
		points.append(center + Vector3(rotated.x, local_point.y, rotated.y))
	_append_quad(verts, normals, colors, indices, points[0], points[1], points[2], points[3], col, Vector3.DOWN)
	_append_quad(verts, normals, colors, indices, points[4], points[7], points[6], points[5], col, Vector3.UP)
	_append_quad(verts, normals, colors, indices, points[0], points[4], points[5], points[1], col, Vector3(0, 0, -1))
	_append_quad(verts, normals, colors, indices, points[2], points[6], points[7], points[3], col, Vector3(0, 0, 1))
	_append_quad(verts, normals, colors, indices, points[1], points[5], points[6], points[2], col, Vector3.RIGHT)
	_append_quad(verts, normals, colors, indices, points[3], points[7], points[4], points[0], col, Vector3.LEFT)

static func _local_to_world(center: Vector2, yaw: float, local: Vector2) -> Vector2:
	var co: float = cos(yaw)
	var si: float = sin(yaw)
	return center + Vector2(local.x * co - local.y * si, local.x * si + local.y * co)

static func _world_to_local(center: Vector2, yaw: float, world: Vector2) -> Vector2:
	var rel: Vector2 = world - center
	var co: float = cos(-yaw)
	var si: float = sin(-yaw)
	return Vector2(rel.x * co - rel.y * si, rel.x * si + rel.y * co)

static func _local_point(center: Vector2, yaw: float, local: Vector3) -> Vector3:
	var q: Vector2 = _local_to_world(center, yaw, Vector2(local.x, local.z))
	return Vector3(q.x, local.y, q.y)

static func _append_wall_quad(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, along_min: float, along_max: float, y_min: float, y_max: float, hx: float, hz: float, col: Color, face_offset: float = 0.0) -> void:
	if along_max <= along_min or y_max <= y_min:
		return
	var a: Vector3
	var b: Vector3
	var c: Vector3
	var d: Vector3
	var face_x: float = hx + face_offset if side == 0 else -hx - face_offset if side == 1 else 0.0
	var face_z: float = hz + face_offset if side == 2 else -hz - face_offset if side == 3 else 0.0
	match side:
		0: # +X, increasing Z
			a = _local_point(center, yaw, Vector3(face_x, y_min, along_min))
			b = _local_point(center, yaw, Vector3(face_x, y_min, along_max))
			c = _local_point(center, yaw, Vector3(face_x, y_max, along_max))
			d = _local_point(center, yaw, Vector3(face_x, y_max, along_min))
		1: # -X
			a = _local_point(center, yaw, Vector3(face_x, y_min, along_max))
			b = _local_point(center, yaw, Vector3(face_x, y_min, along_min))
			c = _local_point(center, yaw, Vector3(face_x, y_max, along_min))
			d = _local_point(center, yaw, Vector3(face_x, y_max, along_max))
		2: # +Z, increasing X
			a = _local_point(center, yaw, Vector3(along_min, y_min, face_z))
			b = _local_point(center, yaw, Vector3(along_max, y_min, face_z))
			c = _local_point(center, yaw, Vector3(along_max, y_max, face_z))
			d = _local_point(center, yaw, Vector3(along_min, y_max, face_z))
		_: # -Z
			a = _local_point(center, yaw, Vector3(along_max, y_min, face_z))
			b = _local_point(center, yaw, Vector3(along_min, y_min, face_z))
			c = _local_point(center, yaw, Vector3(along_min, y_max, face_z))
			d = _local_point(center, yaw, Vector3(along_max, y_max, face_z))
	var n: Vector3 = Vector3.UP
	if side == 0:
		n = Vector3.RIGHT
	elif side == 1:
		n = Vector3.LEFT
	elif side == 2:
		n = Vector3(0, 0, 1)
	else:
		n = Vector3(0, 0, -1)
	_append_quad(verts, normals, colors, indices, a, b, c, d, col, n)

static func _append_window(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, along: float, y_center: float, width: float, height: float, hx: float, hz: float, col: Color) -> void:
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, along - width * 0.5, along + width * 0.5, y_center - height * 0.5, y_center + height * 0.5, hx, hz, col, 0.018)

static func _append_window_trim(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, along: float, y_center: float, width: float, height: float, hx: float, hz: float, trim_col: Color) -> void:
	var trim: float = 0.10
	var y0: float = y_center - height * 0.5
	var y1: float = y_center + height * 0.5
	var side_offset: float = 0.042
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, along - width * 0.5 - trim, along - width * 0.5, y0 - trim, y1 + trim, hx, hz, trim_col, side_offset)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, along + width * 0.5, along + width * 0.5 + trim, y0 - trim, y1 + trim, hx, hz, trim_col, side_offset)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, along - width * 0.5, along + width * 0.5, y0 - trim, y0, hx, hz, trim_col, side_offset)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, along - width * 0.5, along + width * 0.5, y1, y1 + trim, hx, hz, trim_col, side_offset)

static func _append_door_trim(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, door_along: float, door_width: float, door_height: float, ground: float, hx: float, hz: float, col: Color) -> void:
	var jamb: float = 0.12
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, door_along - door_width * 0.5 - jamb, door_along - door_width * 0.5, ground, ground + door_height, hx + 0.015 if side == 0 else hx, hz, col)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, door_along + door_width * 0.5, door_along + door_width * 0.5 + jamb, ground, ground + door_height, hx + 0.015 if side == 0 else hx, hz, col)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, door_along - door_width * 0.5 - jamb, door_along + door_width * 0.5 + jamb, ground + door_height - jamb, ground + door_height, hx + 0.015 if side == 0 else hx, hz, col)

static func _append_roof_tile_bands(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, footprint: Vector2, eave_y: float, ridge_h: float, col: Color) -> void:
	# Two restrained contrasting courses create a tiled-roof read without a
	# texture dependency. They are visual-only strips laid just above the roof.
	var hx: float = footprint.x * 0.5
	var hz: float = footprint.y * 0.5
	var band: float = 0.028
	var lift: float = 0.026
	var tile_col: Color = col.darkened(0.30)
	for t in [0.24, 0.46, 0.68]:
		var lo: float = t - band
		var hi: float = t + band
		if footprint.x >= footprint.y:
			var z0: float = -hz + lo * hz
			var z1: float = -hz + hi * hz
			var y0: float = eave_y + lo * ridge_h + lift
			var y1: float = eave_y + hi * ridge_h + lift
			_append_quad(verts, normals, colors, indices, _local_point(center, yaw, Vector3(-hx - 0.04, y0, z0)), _local_point(center, yaw, Vector3(hx + 0.04, y0, z0)), _local_point(center, yaw, Vector3(hx + 0.04, y1, z1)), _local_point(center, yaw, Vector3(-hx - 0.04, y1, z1)), tile_col, Vector3(0, 0, -1))
			var bz0: float = hz - hi * hz
			var bz1: float = hz - lo * hz
			_append_quad(verts, normals, colors, indices, _local_point(center, yaw, Vector3(hx + 0.04, eave_y + hi * ridge_h + lift, bz0)), _local_point(center, yaw, Vector3(-hx - 0.04, eave_y + hi * ridge_h + lift, bz0)), _local_point(center, yaw, Vector3(-hx - 0.04, eave_y + lo * ridge_h + lift, bz1)), _local_point(center, yaw, Vector3(hx + 0.04, eave_y + lo * ridge_h + lift, bz1)), tile_col, Vector3(0, 0, 1))
		else:
			var x0: float = -hx + lo * hx
			var x1: float = -hx + hi * hx
			var y0b: float = eave_y + lo * ridge_h + lift
			var y1b: float = eave_y + hi * ridge_h + lift
			_append_quad(verts, normals, colors, indices, _local_point(center, yaw, Vector3(x0, y0b, -hz - 0.04)), _local_point(center, yaw, Vector3(x0, y0b, hz + 0.04)), _local_point(center, yaw, Vector3(x1, y1b, hz + 0.04)), _local_point(center, yaw, Vector3(x1, y1b, -hz - 0.04)), tile_col, Vector3(-1, 0, 0))
			var bx0: float = hx - hi * hx
			var bx1: float = hx - lo * hx
			_append_quad(verts, normals, colors, indices, _local_point(center, yaw, Vector3(bx0, eave_y + hi * ridge_h + lift, hz + 0.04)), _local_point(center, yaw, Vector3(bx0, eave_y + hi * ridge_h + lift, -hz - 0.04)), _local_point(center, yaw, Vector3(bx1, eave_y + lo * ridge_h + lift, -hz - 0.04)), _local_point(center, yaw, Vector3(bx1, eave_y + lo * ridge_h + lift, hz + 0.04)), tile_col, Vector3(1, 0, 0))

static func _append_gable_detail(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, hx: float, hz: float, eave_y: float, ridge_h: float, col: Color) -> void:
	# A pair of restrained timber members makes each end unmistakably a
	# vernacular gable while remaining visual-only and very low-cost.
	var along_half: float = hx if side == 2 or side == 3 else hz
	var beam_y: float = eave_y + ridge_h * 0.46
	var beam_half: float = minf(along_half * 0.52, along_half - 0.18)
	if beam_half > 0.25:
		_append_wall_quad(verts, normals, colors, indices, center, yaw, side, -beam_half, beam_half, beam_y - 0.07, beam_y + 0.07, hx, hz, col, 0.05)
	_append_wall_quad(verts, normals, colors, indices, center, yaw, side, -0.06, 0.06, eave_y + 0.10, eave_y + ridge_h * 0.82, hx, hz, col, 0.05)

static func append_building(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, footprint: Vector2, yaw: float, ground: float, height: float, door_pos: Vector2, door_width: float, door_height: float, kind: StringName, wall_col: Color, roof_col: Color, timber_col: Color, window_col: Color, facade_detail: bool = true) -> void:
	var hx: float = footprint.x * 0.5
	var hz: float = footprint.y * 0.5
	var door_local: Vector2 = _world_to_local(center, yaw, door_pos)
	var door_side: int = 0
	var door_along: float = door_local.y
	if absf(door_local.x) >= absf(door_local.y):
		if door_local.x >= 0.0:
			door_side = 0
		else:
			door_side = 1
		door_along = clampf(door_local.y, -hz + door_width * 0.5 + 0.12, hz - door_width * 0.5 - 0.12)
	else:
		if door_local.y >= 0.0:
			door_side = 2
		else:
			door_side = 3
		door_along = clampf(door_local.x, -hx + door_width * 0.5 + 0.12, hx - door_width * 0.5 - 0.12)
	var sides: Array[float] = [hx, hz, hx, hz]
	for side in 4:
		var half_along: float = sides[side]
		if side == door_side:
			_append_wall_quad(verts, normals, colors, indices, center, yaw, side, -half_along, door_along - door_width * 0.5, ground, ground + height, hx, hz, wall_col)
			_append_wall_quad(verts, normals, colors, indices, center, yaw, side, door_along + door_width * 0.5, half_along, ground, ground + height, hx, hz, wall_col)
			_append_wall_quad(verts, normals, colors, indices, center, yaw, side, door_along - door_width * 0.5, door_along + door_width * 0.5, ground + door_height, ground + height, hx, hz, wall_col)
		else:
			_append_wall_quad(verts, normals, colors, indices, center, yaw, side, -half_along, half_along, ground, ground + height, hx, hz, wall_col)
	# A low plinth gives the wall a readable base and masks tiny terrain
	# sampling differences without altering the walkable surface.
	var plinth_col: Color = wall_col.darkened(0.18)
	var plinth_h: float = 0.28
	for plinth_side in 4:
		var plinth_half: float = sides[plinth_side]
		if plinth_side == door_side:
			_append_wall_quad(verts, normals, colors, indices, center, yaw, plinth_side, -plinth_half, door_along - door_width * 0.5, ground, ground + plinth_h, hx, hz, plinth_col)
			_append_wall_quad(verts, normals, colors, indices, center, yaw, plinth_side, door_along + door_width * 0.5, plinth_half, ground, ground + plinth_h, hx, hz, plinth_col)
		else:
			_append_wall_quad(verts, normals, colors, indices, center, yaw, plinth_side, -plinth_half, plinth_half, ground, ground + plinth_h, hx, hz, plinth_col)
	_append_door_trim(verts, normals, colors, indices, center, yaw, door_side, door_along, door_width, door_height, ground, hx, hz, timber_col)
	var eave_y: float = ground + height
	# Gabled roof: a real ridge rather than a flat box top.
	var ridge_h: float = clampf(minf(2.0, minf(footprint.x, footprint.y) * 0.20), 0.9, 1.8)
	if footprint.x >= footprint.y:
		var a0: Vector3 = _local_point(center, yaw, Vector3(-hx, eave_y, -hz))
		var a1: Vector3 = _local_point(center, yaw, Vector3(hx, eave_y, -hz))
		var a2: Vector3 = _local_point(center, yaw, Vector3(hx, eave_y + ridge_h, 0.0))
		var a3: Vector3 = _local_point(center, yaw, Vector3(-hx, eave_y + ridge_h, 0.0))
		var b0: Vector3 = _local_point(center, yaw, Vector3(-hx, eave_y, hz))
		var b1: Vector3 = _local_point(center, yaw, Vector3(hx, eave_y, hz))
		_append_quad(verts, normals, colors, indices, a0, a1, a2, a3, roof_col, Vector3(0, 0, -1))
		_append_quad(verts, normals, colors, indices, b1, b0, a3, a2, roof_col.darkened(0.10), Vector3(0, 0, 1))
		_append_triangle(verts, normals, colors, indices, a0, a3, b0, wall_col.darkened(0.08), Vector3.LEFT)
		_append_triangle(verts, normals, colors, indices, a1, b1, a2, wall_col.darkened(0.08), Vector3.RIGHT)
	else:
		var a0b: Vector3 = _local_point(center, yaw, Vector3(-hx, eave_y, -hz))
		var a1b: Vector3 = _local_point(center, yaw, Vector3(-hx, eave_y, hz))
		var a2b: Vector3 = _local_point(center, yaw, Vector3(0.0, eave_y + ridge_h, hz))
		var a3b: Vector3 = _local_point(center, yaw, Vector3(0.0, eave_y + ridge_h, -hz))
		var b0b: Vector3 = _local_point(center, yaw, Vector3(hx, eave_y, -hz))
		var b1b: Vector3 = _local_point(center, yaw, Vector3(hx, eave_y, hz))
		_append_quad(verts, normals, colors, indices, a1b, a0b, a3b, a2b, roof_col, Vector3(-1, 0, 0))
		_append_quad(verts, normals, colors, indices, b0b, b1b, a2b, a3b, roof_col.darkened(0.10), Vector3(1, 0, 0))
		_append_triangle(verts, normals, colors, indices, a0b, b0b, a3b, wall_col.darkened(0.08), Vector3(0, 0, -1))
		_append_triangle(verts, normals, colors, indices, a1b, a2b, b1b, wall_col.darkened(0.08), Vector3(0, 0, 1))
	# Thin fascia and a ridge cap give the roof a visible edge/thickness at
	# gameplay distance without turning the rural mesh into a dense asset.
	var fascia_col: Color = roof_col.darkened(0.22)
	var fascia_h: float = 0.18
	var overhang: float = 0.14
	if footprint.x >= footprint.y:
		_append_wall_quad(verts, normals, colors, indices, center, yaw, 2, -hx - overhang, hx + overhang, eave_y - 0.08, eave_y + fascia_h, hx, hz, fascia_col, 0.12)
		_append_wall_quad(verts, normals, colors, indices, center, yaw, 3, -hx - overhang, hx + overhang, eave_y - 0.08, eave_y + fascia_h, hx, hz, fascia_col, 0.12)
		_append_oriented_box(verts, normals, colors, indices, _local_point(center, yaw, Vector3(0.0, eave_y + ridge_h + 0.04, 0.0)), Vector3(footprint.x + 0.18, 0.12, 0.16), yaw, fascia_col)
	else:
		_append_wall_quad(verts, normals, colors, indices, center, yaw, 0, -hz - overhang, hz + overhang, eave_y - 0.08, eave_y + fascia_h, hx, hz, fascia_col, 0.12)
		_append_wall_quad(verts, normals, colors, indices, center, yaw, 1, -hz - overhang, hz + overhang, eave_y - 0.08, eave_y + fascia_h, hx, hz, fascia_col, 0.12)
		_append_oriented_box(verts, normals, colors, indices, _local_point(center, yaw, Vector3(0.0, eave_y + ridge_h + 0.04, 0.0)), Vector3(0.16, 0.12, footprint.y + 0.18), yaw, fascia_col)
	# Windows and shutters are visual cues, not collision bodies.
	if facade_detail:
		_append_roof_tile_bands(verts, normals, colors, indices, center, yaw, footprint, eave_y, ridge_h, roof_col)
	if kind != &"barn" and kind != &"stable" and kind != &"shed":
		var window_side: int = 2 if door_side != 2 else 3
		var window_half: float = hx if window_side == 2 or window_side == 3 else hz
		var window_along: float = clampf(0.0, -window_half + 0.8, window_half - 0.8)
		var wy: float = ground + minf(2.5, height * 0.58)
		_append_window(verts, normals, colors, indices, center, yaw, window_side, window_along, wy, 1.15, 0.88, hx, hz, window_col)
		_append_window_trim(verts, normals, colors, indices, center, yaw, window_side, window_along, wy, 1.15, 0.88, hx, hz, timber_col)
		var other_side: int = 3 if door_side == 0 or door_side == 1 else 0
		_append_window(verts, normals, colors, indices, center, yaw, other_side, 0.0, wy, 1.05, 0.82, hx, hz, window_col)
		_append_window_trim(verts, normals, colors, indices, center, yaw, other_side, 0.0, wy, 1.05, 0.82, hx, hz, timber_col)
		# Give the remaining side a window as well. This keeps a house readable
		# from a three-quarter camera without adding any physics geometry.
		for extra_side in 4:
			if extra_side == door_side or extra_side == window_side or extra_side == other_side:
				continue
			_append_window(verts, normals, colors, indices, center, yaw, extra_side, 0.0, wy, 0.86, 0.76, hx, hz, window_col.darkened(0.08))
			_append_window_trim(verts, normals, colors, indices, center, yaw, extra_side, 0.0, wy, 0.86, 0.76, hx, hz, timber_col)
			break
		# A second small window on the entrance facade makes the doorway read
		# as part of a house rather than an isolated brown rectangle.
		var front_half: float = hx if door_side == 2 or door_side == 3 else hz
		var left_window: float = door_along - door_width * 0.5 - 0.72
		var right_window: float = door_along + door_width * 0.5 + 0.72
		if left_window - 0.36 > -front_half + 0.28:
			_append_window(verts, normals, colors, indices, center, yaw, door_side, left_window, wy, 0.72, 0.72, hx, hz, window_col.darkened(0.12))
			_append_window_trim(verts, normals, colors, indices, center, yaw, door_side, left_window, wy, 0.72, 0.72, hx, hz, timber_col)
		if right_window + 0.36 < front_half - 0.28:
			_append_window(verts, normals, colors, indices, center, yaw, door_side, right_window, wy, 0.72, 0.72, hx, hz, window_col.darkened(0.12))
			_append_window_trim(verts, normals, colors, indices, center, yaw, door_side, right_window, wy, 0.72, 0.72, hx, hz, timber_col)
		if facade_detail:
			var gable_side_a: int = 0 if footprint.x >= footprint.y else 2
			var gable_side_b: int = 1 if footprint.x >= footprint.y else 3
			_append_gable_detail(verts, normals, colors, indices, center, yaw, gable_side_a, hx, hz, eave_y, ridge_h, timber_col.darkened(0.05))
			_append_gable_detail(verts, normals, colors, indices, center, yaw, gable_side_b, hx, hz, eave_y, ridge_h, timber_col.darkened(0.05))
	else:
		# Barns/stables get one high loft vent instead of house windows. The
		# small dark opening plus timber casing preserves their farm identity
		# without adding a second prop or a physics body.
		var loft_side: int = 2 if door_side != 2 else 3
		var loft_y: float = ground + height * 0.72
		_append_window(verts, normals, colors, indices, center, yaw, loft_side, 0.0, loft_y, 0.86, 0.62, hx, hz, window_col.darkened(0.18))
		_append_window_trim(verts, normals, colors, indices, center, yaw, loft_side, 0.0, loft_y, 0.86, 0.62, hx, hz, timber_col)
	# One masonry chimney is a strong period/household cue and gives the roof
	# a readable vertical anchor. It remains visual-only; the building body is
	# still the single aggregated collision source.
	var chimney_local: Vector2 = Vector2(hx * 0.24, hz * 0.12)
	var chimney_world: Vector2 = _local_to_world(center, yaw, chimney_local)
	var chimney_base: float = eave_y + 0.40
	var chimney_height: float = ridge_h + 0.75
	_append_oriented_box(verts, normals, colors, indices, Vector3(chimney_world.x, chimney_base + chimney_height * 0.5, chimney_world.y), Vector3(0.46, chimney_height, 0.46), yaw, Color("7a665b"))
	_append_oriented_box(verts, normals, colors, indices, Vector3(chimney_world.x, chimney_base + chimney_height + 0.05, chimney_world.y), Vector3(0.56, 0.10, 0.56), yaw, Color("4e4742"))

static func _append_collision_box(verts: PackedVector3Array, indices: PackedInt32Array, center: Vector3, size: Vector3, yaw: float = 0.0) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var local_points: Array[Vector3] = [
		Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz),
		Vector3(-hx, hy, -hz), Vector3(hx, hy, -hz), Vector3(hx, hy, hz), Vector3(-hx, hy, hz)
	]
	var base: int = verts.size()
	for local_point in local_points:
		var q: Vector2 = Vector2(local_point.x, local_point.z)
		var co: float = cos(yaw)
		var si: float = sin(yaw)
		var rotated: Vector2 = Vector2(q.x * co - q.y * si, q.x * si + q.y * co)
		verts.append(Vector3(center.x + rotated.x, center.y + local_point.y, center.z + rotated.y))
	var faces: Array[Array] = [[0, 1, 2, 3], [4, 7, 6, 5], [0, 4, 5, 1], [2, 6, 7, 3], [1, 5, 6, 2], [3, 7, 4, 0]]
	for face in faces:
		indices.append(base + int(face[0]))
		indices.append(base + int(face[1]))
		indices.append(base + int(face[2]))
		indices.append(base + int(face[0]))
		indices.append(base + int(face[2]))
		indices.append(base + int(face[3]))

static func _append_collision_wall_segment(verts: PackedVector3Array, indices: PackedInt32Array, center: Vector2, yaw: float, side: int, along_min: float, along_max: float, ground: float, height: float, hx: float, hz: float, thickness: float = 0.18) -> void:
	if along_max <= along_min:
		return
	var local_center: Vector2
	var size: Vector3
	match side:
		0:
			local_center = Vector2(hx - thickness * 0.5, (along_min + along_max) * 0.5)
			size = Vector3(thickness, height, along_max - along_min)
		1:
			local_center = Vector2(-hx + thickness * 0.5, (along_min + along_max) * 0.5)
			size = Vector3(thickness, height, along_max - along_min)
		2:
			local_center = Vector2((along_min + along_max) * 0.5, hz - thickness * 0.5)
			size = Vector3(along_max - along_min, height, thickness)
		_:
			local_center = Vector2((along_min + along_max) * 0.5, -hz + thickness * 0.5)
			size = Vector3(along_max - along_min, height, thickness)
	var co: float = cos(yaw)
	var si: float = sin(yaw)
	var rotated: Vector2 = Vector2(local_center.x * co - local_center.y * si, local_center.x * si + local_center.y * co)
	_append_collision_box(verts, indices, Vector3(center.x + rotated.x, ground + height * 0.5, center.y + rotated.y), size, yaw)

static func append_building_collision(verts: PackedVector3Array, indices: PackedInt32Array, center: Vector2, footprint: Vector2, yaw: float, ground: float, height: float, door_pos: Vector2, door_width: float, door_height: float) -> void:
	var hx: float = footprint.x * 0.5
	var hz: float = footprint.y * 0.5
	var door_local: Vector2 = _world_to_local(center, yaw, door_pos)
	var door_side: int = 0
	var door_along: float = door_local.y
	if absf(door_local.x) >= absf(door_local.y):
		door_side = 0 if door_local.x >= 0.0 else 1
		door_along = clampf(door_local.y, -hz + door_width * 0.5 + 0.12, hz - door_width * 0.5 - 0.12)
	else:
		door_side = 2 if door_local.y >= 0.0 else 3
		door_along = clampf(door_local.x, -hx + door_width * 0.5 + 0.12, hx - door_width * 0.5 - 0.12)
	var sides: Array[float] = [hx, hz, hx, hz]
	for side in 4:
		var half_along: float = sides[side]
		if side == door_side:
			_append_collision_wall_segment(verts, indices, center, yaw, side, -half_along, door_along - door_width * 0.5, ground, height, hx, hz)
			_append_collision_wall_segment(verts, indices, center, yaw, side, door_along + door_width * 0.5, half_along, ground, height, hx, hz)
			_append_collision_wall_segment(verts, indices, center, yaw, side, door_along - door_width * 0.5, door_along + door_width * 0.5, ground + door_height, height - door_height, hx, hz)
		else:
			_append_collision_wall_segment(verts, indices, center, yaw, side, -half_along, half_along, ground, height, hx, hz)

static func _append_cylinder(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, radius: float, height: float, sides: int, col: Color, yaw: float = 0.0) -> void:
	var base: int = verts.size()
	for ring in 2:
		var y: float = center.y - height * 0.5 if ring == 0 else center.y + height * 0.5
		for i in sides:
			var a: float = yaw + TAU * float(i) / float(sides)
			verts.append(Vector3(center.x + cos(a) * radius, y, center.z + sin(a) * radius))
			normals.append(Vector3(cos(a), 0.0, sin(a)))
			colors.append(col)
	for i in sides:
			var n: int = (i + 1) % sides
			indices.append(base + i)
			indices.append(base + n)
			indices.append(base + sides + n)
			indices.append(base + i)
			indices.append(base + sides + n)
			indices.append(base + sides + i)

static func append_tree(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, scale: float, yaw: float, trunk_col: Color, canopy_col: Color, canopy_alt: Color) -> void:
	# A readable trunk/crown silhouette is more valuable than dense foliage at
	# streamed-chunk distance, so keep the same low-poly budget but enlarge the
	# crown slightly around a clearly visible trunk.
	_append_cylinder(verts, normals, colors, indices, center + Vector3(0.0, 0.90 * scale, 0.0), 0.20 * scale, 1.8 * scale, 6, trunk_col, yaw)
	var cy: float = center.y + 1.95 * scale
	var r: float = 1.12 * scale
	var base: int = verts.size()
	var points: Array[Vector3] = [
		Vector3(center.x, cy + 0.95 * scale, center.z),
		Vector3(center.x, cy - 0.85 * scale, center.z),
		Vector3(center.x + r, cy, center.z),
		Vector3(center.x - r, cy, center.z),
		Vector3(center.x, cy, center.z + r * 0.92),
		Vector3(center.x, cy, center.z - r * 0.92),
		Vector3(center.x + r * 0.62, cy + 0.35 * scale, center.z + r * 0.35),
		Vector3(center.x - r * 0.58, cy + 0.28 * scale, center.z - r * 0.36)
	]
	for p in points:
		verts.append(p)
		normals.append((p - Vector3(center.x, cy, center.z)).normalized())
		colors.append(canopy_col if verts.size() % 3 != 0 else canopy_alt)
	var faces: Array[Array] = [
		[0, 2, 6], [0, 6, 4], [0, 4, 7], [0, 7, 3], [0, 3, 5], [0, 5, 2],
		[1, 6, 2], [1, 4, 6], [1, 7, 4], [1, 3, 7], [1, 5, 3], [1, 2, 5]
	]
	for f in faces:
		indices.append(base + int(f[0]))
		indices.append(base + int(f[1]))
		indices.append(base + int(f[2]))

static func append_path(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector2, b: Vector2, y_a: float, y_b: float, width: float, col: Color) -> void:
	var d: Vector2 = b - a
	if d.length_squared() < 0.0001:
		return
	var side: Vector2 = Vector2(-d.y, d.x).normalized() * width * 0.5
	_append_quad(verts, normals, colors, indices,
		Vector3(a.x + side.x, y_a, a.y + side.y),
		Vector3(b.x + side.x, y_b, b.y + side.y),
		Vector3(b.x - side.x, y_b, b.y - side.y),
		Vector3(a.x - side.x, y_a, a.y - side.y), col, Vector3.UP)

static func append_yard(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector2, y: float, radius: float, col: Color) -> void:
	var base: int = verts.size()
	verts.append(Vector3(center.x, y, center.y))
	normals.append(Vector3.UP)
	colors.append(col)
	for i in 9:
		var a: float = TAU * float(i) / 8.0
		var rr: float = radius * (0.86 + 0.10 * sin(float(i) * 2.3))
		verts.append(Vector3(center.x + cos(a) * rr, y, center.y + sin(a) * rr))
		normals.append(Vector3.UP)
		colors.append(col)
	for i in 8:
		indices.append(base)
		indices.append(base + i + 1)
		indices.append(base + i + 2)

static func append_fence(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector2, b: Vector2, y: float, height: float, col: Color, cap_col: Color) -> void:
	var d: Vector2 = b - a
	if d.length_squared() < 0.01:
		return
	var mid: Vector2 = (a + b) * 0.5
	var length: float = d.length()
	var yaw: float = atan2(d.y, d.x)
	_append_oriented_box(verts, normals, colors, indices, Vector3(a.x, y + height * 0.5, a.y), Vector3(0.14, height, 0.14), 0.0, cap_col)
	_append_oriented_box(verts, normals, colors, indices, Vector3(b.x, y + height * 0.5, b.y), Vector3(0.14, height, 0.14), 0.0, cap_col)
	_append_oriented_box(verts, normals, colors, indices, Vector3(mid.x, y + height * 0.33, mid.y), Vector3(length, 0.10, 0.12), yaw, col)
	_append_oriented_box(verts, normals, colors, indices, Vector3(mid.x, y + height * 0.72, mid.y), Vector3(length, 0.10, 0.12), yaw, col)
static func append_well(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, ground_center: Vector3, scale: float, yaw: float) -> void:
	var stone: Color = WorldConstants.RURAL_WELL_COLOR_WALL
	var water: Color = WorldConstants.RURAL_WELL_COLOR_WATER
	var timber: Color = WorldConstants.RURAL_WELL_COLOR_BEAM
	_append_cylinder(verts, normals, colors, indices, ground_center + Vector3(0.0, 0.42 * scale, 0.0), 0.90 * scale, 0.84 * scale, 8, stone, yaw)
	append_yard(verts, normals, colors, indices, Vector2(ground_center.x, ground_center.z), ground_center.y + 0.86 * scale, 0.58 * scale, water)
	_append_oriented_box(verts, normals, colors, indices, ground_center + Vector3(0.0, 1.50 * scale, 0.0), Vector3(0.14 * scale, 1.20 * scale, 0.14 * scale), yaw, timber)
	_append_oriented_box(verts, normals, colors, indices, ground_center + Vector3(0.0, 2.05 * scale, 0.0), Vector3(2.0 * scale, 0.14 * scale, 0.14 * scale), yaw, timber)

static func append_barrel(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, scale: float, col: Color, band_col: Color) -> void:
	_append_cylinder(verts, normals, colors, indices, center + Vector3(0, 0.38 * scale, 0), 0.38 * scale, 0.76 * scale, 8, col)
	_append_cylinder(verts, normals, colors, indices, center + Vector3(0, 0.22 * scale, 0), 0.40 * scale, 0.06 * scale, 8, band_col)
	_append_cylinder(verts, normals, colors, indices, center + Vector3(0, 0.58 * scale, 0), 0.40 * scale, 0.06 * scale, 8, band_col)

static func append_wood_pile(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, scale: float, log_col: Color, end_col: Color) -> void:
	for i in 3:
		var off: float = (float(i) - 1.0) * 0.28 * scale
		_append_cylinder(verts, normals, colors, indices, center + Vector3(off, 0.26 * scale + float(i % 2) * 0.22 * scale, 0), 0.18 * scale, 1.35 * scale, 6, log_col, PI * 0.5)
		_append_cylinder(verts, normals, colors, indices, center + Vector3(off, 0.26 * scale + float(i % 2) * 0.22 * scale, 0.68 * scale), 0.185 * scale, 0.03 * scale, 6, end_col, PI * 0.5)

static func append_cart(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, scale: float, yaw: float, wood_col: Color, wheel_col: Color, cloth_col: Color) -> void:
	var co: float = cos(yaw)
	var si: float = sin(yaw)
	var local_body: Vector2 = Vector2(0, 0)
	var world_body: Vector2 = _local_to_world(Vector2(center.x, center.z), yaw, local_body)
	_append_box(verts, normals, colors, indices, Vector3(world_body.x, center.y + 0.44 * scale, world_body.y), Vector3(1.5 * scale, 0.48 * scale, 0.9 * scale), wood_col)
	_append_box(verts, normals, colors, indices, Vector3(world_body.x + co * 1.05 * scale, center.y + 0.45 * scale, world_body.y + si * 1.05 * scale), Vector3(0.9 * scale, 0.18 * scale, 0.18 * scale), wood_col)
	_append_cylinder(verts, normals, colors, indices, Vector3(center.x - si * 0.58 * scale, center.y + 0.32 * scale, center.z + co * 0.58 * scale), 0.43 * scale, 0.12 * scale, 8, wheel_col, yaw + PI * 0.5)
	_append_cylinder(verts, normals, colors, indices, Vector3(center.x + si * 0.58 * scale, center.y + 0.32 * scale, center.z - co * 0.58 * scale), 0.43 * scale, 0.12 * scale, 8, wheel_col, yaw + PI * 0.5)
	_append_box(verts, normals, colors, indices, Vector3(center.x - si * 0.1 * scale, center.y + 0.82 * scale, center.z + co * 0.1 * scale), Vector3(1.15 * scale, 0.08 * scale, 0.72 * scale), cloth_col)

static func append_signpost(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, scale: float, yaw: float, post_col: Color, sign_col: Color) -> void:
	_append_box(verts, normals, colors, indices, center + Vector3(0, 0.8 * scale, 0), Vector3(0.14 * scale, 1.6 * scale, 0.14 * scale), post_col)
	var p: Vector2 = _local_to_world(Vector2(center.x, center.z), yaw, Vector2(0, 0))
	_append_box(verts, normals, colors, indices, Vector3(p.x, center.y + 1.35 * scale, p.y), Vector3(0.95 * scale, 0.38 * scale, 0.10 * scale), sign_col)

static func append_clutter(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, kind: StringName, center: Vector3, scale: float, yaw: float) -> void:
	match kind:
		&"barrel":
			append_barrel(verts, normals, colors, indices, center, scale, Color("725038"), Color("40382c"))
		&"wood_pile":
			append_wood_pile(verts, normals, colors, indices, center, scale, Color("795538"), Color("b48b5e"))
		&"cart":
			append_cart(verts, normals, colors, indices, center, scale, yaw, Color("68462f"), Color("3e352a"), Color("8c7659"))
		&"signpost":
			append_signpost(verts, normals, colors, indices, center, scale, yaw, Color("5b412d"), Color("c1a06a"))
		&"hay_stack":
			_append_cylinder(verts, normals, colors, indices, center + Vector3(0, 0.55 * scale, 0), 0.75 * scale, 1.1 * scale, 8, Color("b9975a"), yaw)
			_append_cylinder(verts, normals, colors, indices, center + Vector3(0, 1.15 * scale, 0), 0.35 * scale, 0.30 * scale, 8, Color("9a7545"), yaw)
		&"tool_rack":
			_append_box(verts, normals, colors, indices, center + Vector3(0, 0.75 * scale, 0), Vector3(1.25 * scale, 1.5 * scale, 0.12 * scale), Color("65472f"))
			for i in 3:
				_append_box(verts, normals, colors, indices, center + Vector3((float(i) - 1.0) * 0.30 * scale, 1.1 * scale, -0.12 * scale), Vector3(0.08 * scale, 0.75 * scale, 0.08 * scale), Color("827052"))
		_:
			_append_box(verts, normals, colors, indices, center + Vector3(0, 0.35 * scale, 0), Vector3(0.7 * scale, 0.7 * scale, 0.7 * scale), Color("806044"))
