extends RefCounted
## Reusable Czech temperate forest art — distinct low-poly silhouettes for each vegetation class.
## Generates lit, vertex-colored meshes that react to world lighting (PER_PIXEL, not UNSHADED)
## and match the city's stylized language. All meshes are centered at trunk-base origin (0,0,0)
## with Y up, suitable as MultiMesh mesh. No Node access, deterministic.
## Silhouettes:
##  - beech: tall slender trunk, ovoid 8-lobe canopy (2 variants)
##  - oak: broader, irregular 10-lobe canopy with lower branching
##  - birch: slender pale trunk, narrow high canopy with light value variation
##  - spruce: stacked-cone vertical silhouette (3 tiers)
##  - sapling: small 2-lobe canopy
##  - bush: low rounded 6-lobe clump, no distinct trunk
##  - grass: 3 crossing quads (12 tris) at ground
##  - log: horizontal cylinder (fallen deadwood)

static var _CACHE := {}

static func _append_cylinder(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, radius: float, height: float, sides: int, col: Color, col_alt: Color = Color.TRANSPARENT) -> void:
	var base: int = verts.size()
	var alt: bool = col_alt != Color.TRANSPARENT
	for ring in 2:
		var y: float = center.y - height * 0.5 if ring == 0 else center.y + height * 0.5
		for i in sides:
			var a: float = TAU * float(i) / float(sides)
			var nx: float = cos(a)
			var nz: float = sin(a)
			verts.append(Vector3(center.x + nx * radius, y, center.z + nz * radius))
			normals.append(Vector3(nx, 0.0, nz))
			if alt and (i % 2 == 1):
				colors.append(col_alt)
			else:
				colors.append(col)
	for i in sides:
		var n: int = (i + 1) % sides
		indices.append(base + i)
		indices.append(base + n)
		indices.append(base + sides + n)
		indices.append(base + i)
		indices.append(base + sides + n)
		indices.append(base + sides + i)

static func _append_cylinder_between(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector3, b: Vector3, radius: float, sides: int, col: Color, col_alt: Color = Color.TRANSPARENT) -> void:
	## Low-poly branch cylinder along an arbitrary axis; used for readable forks.
	var axis := b - a
	var length := axis.length()
	if length < 0.01:
		return
	var forward := axis / length
	var reference := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var side_axis := forward.cross(reference).normalized()
	var up_axis := forward.cross(side_axis).normalized()
	var base := verts.size()
	var has_alt := col_alt != Color.TRANSPARENT
	for end in 2:
		var c := a if end == 0 else b
		for i in sides:
			var angle := TAU * float(i) / float(sides)
			var radial := side_axis * cos(angle) + up_axis * sin(angle)
			verts.append(c + radial * radius)
			normals.append(radial)
			colors.append(col_alt if has_alt and i % 2 == 1 else col)
	for i in sides:
		var n := (i + 1) % sides
		indices.append(base + i); indices.append(base + n); indices.append(base + sides + n)
		indices.append(base + i); indices.append(base + sides + n); indices.append(base + sides + i)

static func _append_ellipsoid(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, radii: Vector3, sides: int, col: Color, col_alt: Color, variant: int = 0) -> void:
	## Closed, faceted foliage lobe. Multiple lobes form irregular non-spherical crowns.
	var base := verts.size()
	var ring_scale: Array[float] = [0.58, 1.0, 0.62]
	var has_alt := col_alt != Color.TRANSPARENT
	for ring in 3:
		var y_unit := -1.0 + float(ring)
		for i in sides:
			var angle := TAU * float(i) / float(sides) + float(variant % 2) * 0.11
			var radial_scale: float = ring_scale[ring]
			var x := cos(angle) * radii.x * radial_scale
			var z := sin(angle) * radii.z * radial_scale
			var y := y_unit * radii.y
			verts.append(center + Vector3(x, y, z))
			var normal := Vector3(x / maxf(0.01, radii.x), y / maxf(0.01, radii.y), z / maxf(0.01, radii.z)).normalized()
			normals.append(normal)
			colors.append(col_alt if has_alt and ((i + ring + variant) % 4 == 0) else col)
	for ring in 2:
		for i in sides:
			var n := (i + 1) % sides
			var a := base + ring * sides + i
			var b := base + ring * sides + n
			var c := base + (ring + 1) * sides + n
			var d := base + (ring + 1) * sides + i
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(a); indices.append(c); indices.append(d)
	var bottom_center := verts.size()
	verts.append(center - Vector3(0, radii.y, 0))
	normals.append(Vector3.DOWN); colors.append(col)
	var top_center := verts.size()
	verts.append(center + Vector3(0, radii.y, 0))
	normals.append(Vector3.UP); colors.append(col_alt if has_alt else col)
	for i in sides:
		var n := (i + 1) % sides
		indices.append(bottom_center); indices.append(base + n); indices.append(base + i)
		indices.append(top_center); indices.append(base + 2 * sides + i); indices.append(base + 2 * sides + n)


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
	var quads: Array = [
		[0,1,2,3, Vector3.DOWN],
		[4,7,6,5, Vector3.UP],
		[0,4,5,1, Vector3(0,0,-1)],
		[2,6,7,3, Vector3(0,0,1)],
		[1,5,6,2, Vector3.RIGHT],
		[3,7,4,0, Vector3.LEFT]
	]
	for q in quads:
		var base: int = verts.size()
		verts.append(p[int(q[0])]); verts.append(p[int(q[1])]); verts.append(p[int(q[2])]); verts.append(p[int(q[3])])
		normals.append(q[4]); normals.append(q[4]); normals.append(q[4]); normals.append(q[4])
		colors.append(col); colors.append(col); colors.append(col); colors.append(col)
		indices.append(base); indices.append(base+1); indices.append(base+2)
		indices.append(base); indices.append(base+2); indices.append(base+3)

static func _append_quad(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, normal: Vector3) -> void:
	var base: int = verts.size()
	verts.append(a); verts.append(b); verts.append(c); verts.append(d)
	normals.append(normal); normals.append(normal); normals.append(normal); normals.append(normal)
	colors.append(col); colors.append(col); colors.append(col); colors.append(col)
	indices.append(base); indices.append(base+1); indices.append(base+2)
	indices.append(base); indices.append(base+2); indices.append(base+3)

static func _build_array_mesh(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, mat: StandardMaterial3D = null) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mat != null:
		mesh.surface_set_material(0, mat)
	return mesh

static func _lit_material(albedo: Color = Color.WHITE, roughness: float = 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = roughness
	m.metallic = 0.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if albedo != Color.WHITE:
		m.albedo_color = albedo
	return m

static func _trunk_color(kind: StringName) -> Color:
	match kind:
		&"beech":
			return WorldConstants.COL_FOREST_TRUNK_BEECH
		&"oak":
			return WorldConstants.COL_FOREST_TRUNK_OAK
		&"birch":
			return WorldConstants.COL_FOREST_TRUNK_BIRCH
		&"spruce":
			return WorldConstants.COL_FOREST_TRUNK_SPRUCE
		&"sapling":
			return WorldConstants.COL_FOREST_TRUNK_BEECH.lightened(0.08)
		_:
			return WorldConstants.COL_FOREST_TRUNK_OAK

static func _canopy_colors(kind: StringName) -> Array[Color]:
	match kind:
		&"beech":
			return [WorldConstants.COL_FOREST_CANOPY_BEECH, WorldConstants.COL_FOREST_CANOPY_BEECH_ALT]
		&"oak":
			return [WorldConstants.COL_FOREST_CANOPY_OAK, WorldConstants.COL_FOREST_CANOPY_OAK_ALT]
		&"birch":
			return [WorldConstants.COL_FOREST_CANOPY_BIRCH, WorldConstants.COL_FOREST_CANOPY_BIRCH_ALT]
		&"spruce":
			return [WorldConstants.COL_FOREST_CANOPY_SPRUCE, WorldConstants.COL_FOREST_CANOPY_SPRUCE_ALT]
		&"bush":
			return [WorldConstants.COL_FOREST_BUSH, WorldConstants.COL_FOREST_BUSH_ALT]
		&"grass":
			return [WorldConstants.COL_FOREST_GRASS, WorldConstants.COL_FOREST_GRASS_ALT]
		_:
			return [WorldConstants.COL_FOREST_CANOPY_BEECH, WorldConstants.COL_FOREST_CANOPY_BEECH_ALT]

# ---- Specific mesh factories (variant 0,1 deterministic jitter) ----

static func _canopy_octal_points(center_y: float, radius: float, height_scale: float, variant: int, jagged: float = 0.0) -> Array[Vector3]:
	## Returns canopy polyhedron points for beech/oak/birch: top, bottom, 4 cardinals, 2 diagonals
	## variant introduces deterministic asymmetry so two beech variants are genuinely distinct.
	var cy: float = center_y
	var r: float = radius
	# Variant jitter via small offset table deterministic
	var v0: float = 0.0
	var v1: float = 0.0
	if variant == 1:
		v0 = 0.18
		v1 = -0.14
	elif variant == 2:
		v0 = -0.22
		v1 = 0.20
	if jagged > 0.0:
		r *= (1.0 + v0 * jagged)
	var pts: Array[Vector3] = []
	# top/bottom
	pts.append(Vector3(0, cy + 1.05 * height_scale, 0))
	pts.append(Vector3(0, cy - 0.88 * height_scale, 0))
	# cardinals
	pts.append(Vector3(r * (1.0 + v0*0.35), cy + 0.06 * height_scale, 0))
	pts.append(Vector3(-r * (1.0 - v0*0.28), cy + v0 * 0.3, 0))
	pts.append(Vector3(0, cy + v1*0.22, r * 0.96))
	pts.append(Vector3(0, cy - v1*0.18, -r * 0.92))
	# diagonals
	pts.append(Vector3(r * 0.62 + v0*0.2, cy + 0.32 * height_scale + v1*0.1, r * 0.36 + v1*0.08))
	pts.append(Vector3(-r * 0.58 + v1*0.12, cy + 0.26 * height_scale - v0*0.09, -r * 0.36 + v0*0.07))
	return pts

static func create_beech_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var trunk_col := _trunk_color(&"beech")
	var canopy_cols := _canopy_colors(&"beech")
	var th: float = lerpf(WorldConstants.TREE_TRUNK_HEIGHT_BEECH_MIN, WorldConstants.TREE_TRUNK_HEIGHT_BEECH_MAX, 0.42 + float(variant) * 0.20)
	_append_cylinder(verts, normals, colors, indices, Vector3(0, th * 0.5, 0), WorldConstants.TREE_TRUNK_RADIUS_BEECH, th, 7, trunk_col)
	# Beech crown: three overlapping upright lobes on visible forked branches.
	var fork := Vector3(0, th * 0.58, 0)
	# Two low lateral arms remain visible below the crown silhouette.
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(-2.35, th * 0.82, 0.18), 0.145, 5, trunk_col.darkened(0.08))
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(2.35, th * 0.84, -0.16), 0.145, 5, trunk_col.darkened(0.08))
	var shift := 0.16 if variant == 1 else -0.08
	var centers: Array[Vector3] = [
		Vector3(0.0, th + 1.62, 0.0),
		Vector3(-0.92 + shift, th + 1.42, 0.12),
		Vector3(0.88 - shift, th + 1.48, -0.10),
	]
	var radii: Array[Vector3] = [
		Vector3(1.92, 1.48, 1.78),
		Vector3(1.56, 1.20, 1.46),
		Vector3(1.62, 1.26, 1.50),
	]
	for i in centers.size():
		var lobe: Vector3 = centers[i]
		_append_cylinder_between(verts, normals, colors, indices, fork, lobe - Vector3(0, 0.42, 0), 0.115, 5, trunk_col.darkened(0.08))
		_append_ellipsoid(verts, normals, colors, indices, lobe, radii[i], 7, canopy_cols[0], canopy_cols[1], variant + i)
	var mat := _lit_material(Color.WHITE, WorldConstants.VEGETATION_MATERIAL_ROUGHNESS)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_oak_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var trunk_col := _trunk_color(&"oak")
	var canopy_cols := _canopy_colors(&"oak")
	var th: float = lerpf(WorldConstants.TREE_TRUNK_HEIGHT_OAK_MIN, WorldConstants.TREE_TRUNK_HEIGHT_OAK_MAX, 0.36 + float(variant) * 0.22)
	_append_cylinder(verts, normals, colors, indices, Vector3(0, th * 0.5, 0), WorldConstants.TREE_TRUNK_RADIUS_OAK, th, 7, trunk_col)
	# Oak: low, wide crown made from four offset lobes and a heavy branching fork.
	var fork := Vector3(0, th * 0.48, 0)
	# Oak limbs spread below the broad low crown for an unmistakable branching silhouette.
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(-2.75, th * 0.78, 0.28), 0.18, 5, trunk_col.darkened(0.10))
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(2.75, th * 0.80, -0.24), 0.18, 5, trunk_col.darkened(0.10))
	var shift := 0.18 if variant == 1 else -0.12
	var centers: Array[Vector3] = [
		Vector3(0.0, th + 1.34, 0.0),
		Vector3(-1.00 + shift, th + 1.10, 0.20),
		Vector3(1.02 - shift, th + 1.18, -0.16),
		Vector3(0.0, th + 1.06, 0.92 if variant == 0 else -0.86),
	]
	var radii: Array[Vector3] = [
		Vector3(2.15, 1.38, 2.06),
		Vector3(1.70, 1.14, 1.62),
		Vector3(1.78, 1.18, 1.70),
		Vector3(1.62, 1.08, 1.48),
	]
	for i in centers.size():
		var lobe: Vector3 = centers[i]
		_append_cylinder_between(verts, normals, colors, indices, fork, lobe - Vector3(0, 0.34, 0), 0.14, 5, trunk_col.darkened(0.10))
		_append_ellipsoid(verts, normals, colors, indices, lobe, radii[i], 7, canopy_cols[0], canopy_cols[1], variant + i + 1)
	var mat := _lit_material(Color.WHITE, WorldConstants.VEGETATION_MATERIAL_ROUGHNESS)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_birch_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var trunk_col := _trunk_color(&"birch")
	var trunk_alt := Color("2a2a2a")
	var canopy_cols := _canopy_colors(&"birch")
	var th: float = lerpf(WorldConstants.TREE_TRUNK_HEIGHT_BIRCH_MIN, WorldConstants.TREE_TRUNK_HEIGHT_BIRCH_MAX, 0.42 + float(variant) * 0.18)
	_append_cylinder(verts, normals, colors, indices, Vector3(0, th * 0.5, 0), WorldConstants.TREE_TRUNK_RADIUS_BIRCH, th, 5, trunk_col, trunk_alt)
	# Birch: narrow pale trunk with a high, airy three-lobe crown.
	var fork := Vector3(0, th * 0.68, 0)
	# Birch branches are thinner but still break the straight-trunk read.
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(-1.65, th * 0.88, 0.12), 0.09, 5, trunk_col.darkened(0.08))
	_append_cylinder_between(verts, normals, colors, indices, fork, Vector3(1.65, th * 0.90, -0.10), 0.09, 5, trunk_col.darkened(0.08))
	var side := -0.12 if variant == 0 else 0.16
	var centers: Array[Vector3] = [
		Vector3(0.0, th + 1.52, 0.0),
		Vector3(-0.48 + side, th + 1.20, 0.10),
		Vector3(0.52 - side, th + 1.34, -0.08),
	]
	var radii: Array[Vector3] = [
		Vector3(1.30, 1.54, 1.16),
		Vector3(1.02, 1.24, 0.94),
		Vector3(1.08, 1.32, 0.98),
	]
	for i in centers.size():
		var lobe: Vector3 = centers[i]
		_append_cylinder_between(verts, normals, colors, indices, fork, lobe - Vector3(0, 0.46, 0), 0.075, 5, trunk_col.darkened(0.08))
		_append_ellipsoid(verts, normals, colors, indices, lobe, radii[i], 6, canopy_cols[0], canopy_cols[1], variant + i)
	var mat := _lit_material(Color.WHITE, WorldConstants.VEGETATION_MATERIAL_ROUGHNESS)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_spruce_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var trunk_col := _trunk_color(&"spruce")
	var canopy_col := WorldConstants.COL_FOREST_CANOPY_SPRUCE
	var canopy_alt := WorldConstants.COL_FOREST_CANOPY_SPRUCE_ALT
	var th: float = lerpf(WorldConstants.TREE_TRUNK_HEIGHT_SPRUCE_MIN, WorldConstants.TREE_TRUNK_HEIGHT_SPRUCE_MAX, 0.42 + float(variant)*0.16)
	_append_cylinder(verts, normals, colors, indices, Vector3(0, th*0.5, 0), WorldConstants.TREE_TRUNK_RADIUS_SPRUCE, th, 6, trunk_col)
	# Stacked cones vertical silhouette — distinct from deciduous ovoid
	var base_y: float = th * 0.62
	var tier_h: Array[float] = [1.9, 1.5, 1.1]
	var tier_r: Array[float] = [2.25, 1.72, 1.16]
	# Jitter tier radius by variant
	for ti in 3:
		var r: float = tier_r[ti] * (1.0 + float(variant)*0.04 - float(ti)*0.02)
		var h: float = tier_h[ti]
		var y0: float = base_y + float(ti)*0.85
		var y1: float = y0 + h
		# Create cone as 6-sided pyramid using triangles
		var base_c: int = verts.size()
		var apex := Vector3(0, y1, 0)
		verts.append(apex); normals.append(Vector3.UP); colors.append(canopy_col if ti %2==0 else canopy_alt)
		for i in 6:
			var ang: float = TAU * float(i) / 6.0
			var px: float = cos(ang) * r
			var pz: float = sin(ang) * r
			verts.append(Vector3(px, y0, pz))
			# Normal approx outward+up
			var n := Vector3(px, h*0.35, pz).normalized()
			normals.append(n)
			colors.append(canopy_col if ti %2==0 else canopy_alt)
		# sides
		for i in 6:
			var n_idx: int = (i+1)%6
			indices.append(base_c); indices.append(base_c+1+i); indices.append(base_c+1+n_idx)
		# bottom cap (not needed, trunk covers, but add for completeness when seen from below)
		# trunk already covers center, skip
	var mat := _lit_material(Color.WHITE, WorldConstants.VEGETATION_MATERIAL_ROUGHNESS)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_sapling_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var trunk_col := _trunk_color(&"sapling")
	var canopy_cols := _canopy_colors(&"beech")
	var th: float = 1.35 + float(variant) * 0.24
	_append_cylinder(verts, normals, colors, indices, Vector3(0, th * 0.5, 0), 0.09, th, 5, trunk_col)
	var fork := Vector3(0, th * 0.54, 0)
	var centers: Array[Vector3] = [
		Vector3(-0.24, th + 0.34, 0.0),
		Vector3(0.26, th + 0.44, 0.06),
	]
	for i in centers.size():
		var lobe: Vector3 = centers[i]
		_append_cylinder_between(verts, normals, colors, indices, fork, lobe - Vector3(0, 0.12, 0), 0.045, 5, trunk_col.darkened(0.08))
		_append_ellipsoid(verts, normals, colors, indices, lobe, Vector3(0.52, 0.46, 0.48), 6, canopy_cols[0], canopy_cols[1], variant + i)
	var mat := _lit_material(Color.WHITE, WorldConstants.VEGETATION_MATERIAL_ROUGHNESS)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_bush_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var bush_cols := _canopy_colors(&"bush")
	var bush0: Color = bush_cols[0].lightened(0.18)
	var bush1: Color = bush_cols[1].lightened(0.12)
	var size: float = 1.25 + float(variant) * 0.18
	# Bush is a low cluster of three overlapping lobes, not one ball.
	var centers: Array[Vector3] = [
		Vector3(-size * 0.46, size * 0.62, 0.0),
		Vector3(size * 0.42, size * 0.70, 0.08),
		Vector3(0.0, size * 0.92, size * 0.38),
	]
	var radii: Array[Vector3] = [
		Vector3(size * 0.70, size * 0.62, size * 0.62),
		Vector3(size * 0.68, size * 0.66, size * 0.64),
		Vector3(size * 0.56, size * 0.54, size * 0.52),
	]
	for i in centers.size():
		_append_ellipsoid(verts, normals, colors, indices, centers[i], radii[i], 6, bush0, bush1, variant + i)
	var mat := _lit_material(Color.WHITE, 0.92)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_hedgerow_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var hedge_col := Color("3f9f34")
	var hedge_alt := Color("8ccc4c")
	var shift: float = 0.10 if variant == 1 else -0.06
	# A longer irregular strip makes field boundaries read as hedges from the
	# player camera rather than as three isolated bushes.
	var centers: Array[Vector3] = [
		Vector3(-3.30 + shift, 0.78, 0.0),
		Vector3(-1.65, 0.98, 0.03),
		Vector3(0.0, 1.08, 0.04),
		Vector3(1.62, 0.92, -0.02),
		Vector3(3.25 - shift, 0.80, -0.06),
	]
	var radii: Array[Vector3] = [
		Vector3(1.40, 0.78, 0.34),
		Vector3(1.34, 0.90, 0.36),
		Vector3(1.30, 1.02, 0.38),
		Vector3(1.36, 0.86, 0.35),
		Vector3(1.42, 0.80, 0.34),
	]
	# Continuous low base keeps the hedge legible at field distance while the
	# lobes above it preserve an irregular, natural silhouette.
	_append_ellipsoid(verts, normals, colors, indices, Vector3(0.0, 0.35, 0.0), Vector3(4.3, 0.36, 0.42), 8, Color("236b29"), Color("5db542"), variant)
	for i in centers.size():
		_append_ellipsoid(verts, normals, colors, indices, centers[i], radii[i], 7, hedge_col, hedge_alt, variant + i)
	var mat := _lit_material(Color.WHITE, 0.92)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_grass_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var grass_cols := _canopy_colors(&"grass")
	var h: float = 1.95 + float(variant) * 0.34
	var w: float = WorldConstants.GRASS_CLUMP_SIZE * (3.15 + float(variant) * 0.24)
	var col0: Color = grass_cols[0].lightened(0.24)
	var col1: Color = grass_cols[1].lightened(0.18)
	# Broad triangular blades read from the game's high player camera; each blade
	# is double-sided and fans outward instead of disappearing edge-on.
	for k in 7:
		var ang: float = float(k) * TAU / 7.0 + float(variant) * 0.16
		var co: float = cos(ang)
		var si: float = sin(ang)
		var side_x: float = -si * w * 0.23
		var side_z: float = co * w * 0.23
		var base_center := Vector3(co * w * 0.12, 0.03, si * w * 0.12)
		var left := base_center + Vector3(side_x, 0.0, side_z)
		var right := base_center - Vector3(side_x, 0.0, side_z)
		var tip := Vector3(co * w * 0.46, h, si * w * 0.46)
		var base: int = verts.size()
		verts.append(left); verts.append(right); verts.append(tip)
		var blade_normal := Vector3(co * 0.22, 0.96, si * 0.22).normalized()
		normals.append(blade_normal); normals.append(blade_normal); normals.append(blade_normal)
		colors.append(col0 if k % 2 == 0 else col1); colors.append(col0); colors.append(col1)
		indices.append(base); indices.append(base + 1); indices.append(base + 2)
		indices.append(base + 1); indices.append(base); indices.append(base + 2)
	# Four low rosette leaves fill the ground immediately around the tuft.
	for k in 4:
		var ang: float = float(k) * PI * 0.5 + float(variant) * 0.25
		var co: float = cos(ang)
		var si: float = sin(ang)
		var base: int = verts.size()
		verts.append(Vector3(0, 0.034, 0))
		verts.append(Vector3(co * w * 0.60, 0.045, si * w * 0.60))
		verts.append(Vector3(-si * w * 0.20, 0.040, co * w * 0.20))
		normals.append(Vector3.UP); normals.append(Vector3.UP); normals.append(Vector3.UP)
		colors.append(col0); colors.append(col1); colors.append(col0)
		indices.append(base); indices.append(base + 1); indices.append(base + 2)
		indices.append(base + 2); indices.append(base + 1); indices.append(base)
	# A compact faceted fern crown keeps grass readable from the player camera.
	_append_ellipsoid(verts, normals, colors, indices, Vector3(0, 0.24, 0), Vector3(w * 0.34, 0.24, w * 0.30), 6, col0, col1, variant)
	var mat := _lit_material(Color.WHITE, 1.0)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_log_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var col: Color = WorldConstants.COL_FOREST_LOG
	var col_dark: Color = WorldConstants.COL_FOREST_LOG_DARK
	var length: float = WorldConstants.LOG_LENGTH * (0.85 + float(variant)*0.12)
	var radius: float = WorldConstants.LOG_RADIUS * (0.9 + float(variant)*0.08)
	# Horizontal cylinder along X, centered at origin with base at y=radius
	var center := Vector3(0, radius, 0)
	# Cylinder along X axis -> we use _append_cylinder with yaw  PI*0.5 but that still assumes Y up.
	# So manually build horizontal cylinder
	var sides: int = 6
	var base: int = verts.size()
	for s in 2:
		var x: float = -length*0.5 if s==0 else length*0.5
		for i in sides:
			var ang: float = TAU * float(i) / float(sides)
			var y: float = center.y + cos(ang) * radius
			var z: float = sin(ang) * radius
			verts.append(Vector3(x, y, z))
			normals.append(Vector3(0, cos(ang), sin(ang)))
			colors.append(col if (i%2==0) else col_dark)
	for i in sides:
		var n: int = (i+1)%sides
		indices.append(base + i); indices.append(base + n); indices.append(base + sides + n)
		indices.append(base + i); indices.append(base + sides + n); indices.append(base + sides + i)
	# End caps
	var cap_center0 := Vector3(-length*0.5, radius, 0)
	var cap_center1 := Vector3(length*0.5, radius, 0)
	for cap in 2:
		var cx: float = cap_center0.x if cap==0 else cap_center1.x
		var cap_base: int = verts.size()
		verts.append(Vector3(cx, radius, 0)); normals.append(Vector3(-1 if cap==0 else 1,0,0)); colors.append(col_dark)
		for i in sides:
			var ang: float = TAU * float(i) / float(sides)
			var y: float = radius + cos(ang) * radius
			var z: float = sin(ang) * radius
			verts.append(Vector3(cx, y, z))
			normals.append(Vector3(-1 if cap==0 else 1,0,0)); colors.append(col_dark)
		for i in sides:
			var n_idx: int = (i+1)%sides
			if cap==0:
				indices.append(cap_base); indices.append(cap_base+1+n_idx); indices.append(cap_base+1+i)
			else:
				indices.append(cap_base); indices.append(cap_base+1+i); indices.append(cap_base+1+n_idx)
	var mat := _lit_material(Color.WHITE, 0.95)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_leaf_litter_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var col0 := Color("96633a")
	var col1 := Color("c58a48")
	var rx: float = 3.15 + float(variant) * 0.60
	var rz: float = 2.45 + float(variant) * 0.42
	var sides := 7
	# Irregular low patch breaks up the uniform biome plane without adding nodes.
	verts.append(Vector3(0, 0.018, 0))
	normals.append(Vector3.UP); colors.append(col0)
	for i in sides:
		var angle := TAU * float(i) / float(sides) + float(variant) * 0.13
		var jitter := 0.84 + float((i * 3 + variant) % 5) * 0.06
		verts.append(Vector3(cos(angle) * rx * jitter, 0.022 + float(i % 2) * 0.004, sin(angle) * rz * jitter))
		normals.append(Vector3.UP)
		colors.append(col1 if (i + variant) % 3 == 0 else col0)
	for i in sides:
		var n := (i + 1) % sides
		indices.append(0); indices.append(1 + i); indices.append(1 + n)
	# Three slightly raised leaf mounds make this a readable forest-floor object,
	# not a nearly invisible decal on the biome plane.
	var mound_col0 := col0.lightened(0.02)
	var mound_col1 := col1.lightened(0.10)
	for i in 3:
		var ma: float = TAU * float(i) / 3.0 + float(variant) * 0.4
		var mc := Vector3(cos(ma) * rx * 0.36, 0.14 + float(i) * 0.02, sin(ma) * rz * 0.34)
		_append_ellipsoid(verts, normals, colors, indices, mc, Vector3(0.82, 0.20, 0.58), 6, mound_col0, mound_col1, (variant + i) % 2)
	for i in 8:
		var angle: float = TAU * float(i) / 8.0 + float(variant) * 0.17
		var leaf_r: float = 0.42 + float((i * 7 + variant) % 5) * 0.12
		var leaf_center := Vector3(cos(angle) * rx * 0.46 + sin(angle) * 0.22, 0.09 + float(i % 2) * 0.018, sin(angle) * rz * 0.46)
		var leaf_tip := leaf_center + Vector3(cos(angle) * leaf_r, 0.07 + float(i % 3) * 0.018, sin(angle) * leaf_r * 0.62)
		var leaf_side := Vector3(-sin(angle), 0.0, cos(angle)) * 0.11
		_append_quad(verts, normals, colors, indices, leaf_center - leaf_side, leaf_center + leaf_side, leaf_tip + leaf_side * 0.16, leaf_tip - leaf_side * 0.16, col1 if i % 2 == 0 else col0.lightened(0.12), Vector3.UP)
	var mat := _lit_material(Color.WHITE, 1.0)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_stone_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var stone0 := Color("77715f")
	var stone1 := Color("928a72")
	var radius := 0.48 + float(variant) * 0.12
	_append_ellipsoid(verts, normals, colors, indices, Vector3(0, radius * 0.55, 0), Vector3(radius * 1.20, radius * 0.72, radius), 6, stone0, stone1, variant)
	var mat := _lit_material(Color.WHITE, 0.96)
	return _build_array_mesh(verts, normals, colors, indices, mat)

static func create_dead_branch_mesh(variant: int = 0) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var col := WorldConstants.COL_FOREST_LOG_DARK
	var alt := WorldConstants.COL_FOREST_LOG
	var length := 1.15 + float(variant) * 0.30
	var a := Vector3(-length * 0.5, 0.12, 0)
	var b := Vector3(length * 0.5, 0.18, 0.10 if variant == 0 else -0.12)
	_append_cylinder_between(verts, normals, colors, indices, a, b, 0.075, 5, col, alt)
	_append_cylinder_between(verts, normals, colors, indices, Vector3(0.12, 0.15, 0.02), Vector3(0.40, 0.42, 0.22), 0.045, 5, col)
	var mat := _lit_material(Color.WHITE, 0.96)
	return _build_array_mesh(verts, normals, colors, indices, mat)

# ---- Public cache ----

static func get_mesh(kind: StringName, variant: int = 0) -> ArrayMesh:
	var key: String = "%s_%d" % [String(kind), variant % 3]
	if _CACHE.has(key):
		return _CACHE[key] as ArrayMesh
	var mesh: ArrayMesh
	match kind:
		&"beech":
			mesh = create_beech_mesh(variant % 2)
		&"oak":
			mesh = create_oak_mesh(variant % 2)
		&"birch":
			mesh = create_birch_mesh(variant % 2)
		&"spruce":
			mesh = create_spruce_mesh(variant % 2)
		&"sapling":
			mesh = create_sapling_mesh(variant % 2)
		&"bush":
			mesh = create_bush_mesh(variant % 2)
		&"hedgerow":
			mesh = create_hedgerow_mesh(variant % 2)
		&"grass":
			mesh = create_grass_mesh(variant % 2)
		&"log":
			mesh = create_log_mesh(variant % 2)
		&"leaf_litter":
			mesh = create_leaf_litter_mesh(variant % 2)
		&"stone":
			mesh = create_stone_mesh(variant % 2)
		&"dead_branch":
			mesh = create_dead_branch_mesh(variant % 2)
		_:
			mesh = create_beech_mesh(0)
	_CACHE[key] = mesh
	return mesh

static func all_tree_kinds() -> Array[StringName]:
	return [&"beech", &"oak", &"birch", &"spruce", &"sapling"]

static func all_understory_kinds() -> Array[StringName]:
	return [&"bush", &"grass", &"log", &"leaf_litter", &"stone", &"dead_branch", &"sapling"]
