class_name TerrainPlan
extends RefCounted
## Pure terrain plan: elevation, slope, normal, class, material, buildability, profiles.
## No scene access, no mutable caches, no unseeded randomness.

var seed_used: int

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed

# --- Internal heightfield ---

## Raw layered height before smoothing, in meters.
func _raw_height(p: Vector2) -> float:
	# 1. Low-frequency basin/ridge field centered on origin (1200m cell, amp ~60)
	var f1 := WorldSeed.sample_coherent_signed(p, &"terrain", 1200.0, seed_used) * 55.0
	# subtle radial basin bias: pull toward 0 near origin, gentle rise outward
	var dist := p.length()
	var basin_bias := clampf(dist / 3500.0, 0.0, 1.0) * 18.0
	# 2. Valley/depression bias for future Vltava corridor: north-south trough
	# centered near x = -180, width ~800m
	var valley_dist := absf(p.x + 180.0)
	var valley := -maxf(0.0, (1.0 - valley_dist / 800.0)) * 10.0
	# add secondary valley noise to meander
	valley += WorldSeed.sample_coherent_signed(p, &"valley", 600.0, seed_used) * 3.0 * maxf(0.0, 1.0 - valley_dist / 1200.0)
	# 3. Medium rolling hills (280m cell, amp 18) — steeper than before to reach cliff slopes
	var f3 := WorldSeed.sample_coherent_signed(p, &"ridge", 280.0, seed_used) * 18.0
	# 4. Small surface variation (60m cell, within documented 2.5m amp)
	var f4 := WorldSeed.sample_coherent_signed(p, &"soil", 60.0, seed_used) * 1.8
	# 5. Cliff/rough detail: high-frequency geology (48m cell, amp 9) — adds steep gradients outside basin
	var cliff_factor := clampf((dist - 1200.0) / 1800.0, 0.0, 1.0)
	var f5 := WorldSeed.sample_coherent_signed(p, &"geology", 48.0, seed_used) * 9.0 * cliff_factor
	return f1 + basin_bias + valley + f3 + f4 + f5

func _smoothed_height(p: Vector2) -> float:
	var h := _raw_height(p)
	# 5a. Flatten near origin basin so city sits on buildable ground
	var dist := p.length()
	if dist < WorldConstants.BASIN_SMOOTH_RADIUS_M:
		var t := dist / WorldConstants.BASIN_SMOOTH_RADIUS_M
		# smoothstep outward
		var s := t * t * (3.0 - 2.0 * t)
		var target := clampf(h, -1.5, WorldConstants.BASIN_SMOOTH_MAX_HEIGHT_M * 0.6)
		# near origin, pull toward small value
		h = lerpf(target * 0.35, h, s)
	# 5b. Smooth toward boundary (last BOUNDARY_SMOOTH_M)
	var bdist := minf(WorldConstants.WORLD_MAX_M - p.x, WorldConstants.WORLD_MAX_M - p.y)
	bdist = minf(bdist, minf(p.x - WorldConstants.WORLD_MIN_M, p.y - WorldConstants.WORLD_MIN_M))
	# bdist is distance to nearest edge; if < BOUNDARY_SMOOTH_M, lerp height to 0
	if bdist < WorldConstants.BOUNDARY_SMOOTH_M:
		var tb := clampf(bdist / WorldConstants.BOUNDARY_SMOOTH_M, 0.0, 1.0)
		var sb := tb * tb * (3.0 - 2.0 * tb)
		h = lerpf(h * 0.2, h, sb)
	return clampf(h, WorldConstants.TERRAIN_MIN_HEIGHT_M, WorldConstants.TERRAIN_MAX_HEIGHT_M)

# --- Public API ---

func height_at(p: Vector2) -> float:
	return _smoothed_height(p)

func normal_at(p: Vector2) -> Vector3:
	var e := 0.5
	var hx1 := _smoothed_height(p + Vector2(e, 0))
	var hx0 := _smoothed_height(p - Vector2(e, 0))
	var hz1 := _smoothed_height(p + Vector2(0, e))
	var hz0 := _smoothed_height(p - Vector2(0, e))
	var dx := (hx1 - hx0) / (2.0 * e)
	var dz := (hz1 - hz0) / (2.0 * e)
	var n := Vector3(-dx, 1.0, -dz)
	var len := n.length()
	if len < 1e-6 or not n.is_finite():
		return Vector3.UP
	return n / len

func slope_at(p: Vector2) -> float:
	var n := normal_at(p)
	var d := clampf(n.dot(Vector3.UP), -1.0, 1.0)
	return rad_to_deg(acos(d))

func terrain_class_at(p: Vector2) -> StringName:
	var slope := slope_at(p)
	if slope >= WorldConstants.CLIFF_SLOPE_DEG:
		return &"cliff"
	var h := height_at(p)
	if h >= WorldConstants.TERRAIN_UPLAND_HEIGHT_M:
		return &"upland"
	elif h >= WorldConstants.TERRAIN_ROLLING_HEIGHT_M:
		return &"rolling_hill"
	else:
		return &"basin"

func surface_material_at(p: Vector2) -> StringName:
	var cls := terrain_class_at(p)
	match cls:
		&"cliff":
			return &"rock"
		&"upland":
			return &"upland_grass"
		&"rolling_hill":
			return &"meadow_soil"
		_:
			return &"alluvial_soil"

func is_buildable(p: Vector2, footprint: Vector2, constraints: Dictionary = {}) -> bool:
	var max_slope: float = constraints.get("max_slope_deg", WorldConstants.BUILDABLE_MAX_SLOPE_DEG)
	var allow_cliff: bool = constraints.get("allow_cliff", false)
	var margin: float = constraints.get("boundary_margin", 0.0)
	# bounds check with optional margin
	var half := footprint * 0.5 + Vector2(margin, margin)
	var rect := Rect2(p - half, footprint + Vector2(margin * 2.0, margin * 2.0))
	if rect.position.x < WorldConstants.WORLD_MIN_M or rect.end.x > WorldConstants.WORLD_MAX_M:
		return false
	if rect.position.y < WorldConstants.WORLD_MIN_M or rect.end.y > WorldConstants.WORLD_MAX_M:
		return false
	if not WorldConstants.is_inside_world(p):
		return false
	# cliff rejection unless allowed
	if not allow_cliff and terrain_class_at(p) == &"cliff":
		return false
	# slope sampling: center + 4 corners + edge mids (9 points) max must be within threshold
	var pts: Array[Vector2] = [p]
	var hx := footprint.x * 0.5
	var hz := footprint.y * 0.5
	pts.append(p + Vector2(-hx, -hz))
	pts.append(p + Vector2(hx, -hz))
	pts.append(p + Vector2(hx, hz))
	pts.append(p + Vector2(-hx, hz))
	pts.append(p + Vector2(0, -hz))
	pts.append(p + Vector2(0, hz))
	pts.append(p + Vector2(-hx, 0))
	pts.append(p + Vector2(hx, 0))
	for q in pts:
		if slope_at(q) > max_slope + 1e-6:
			return false
		if not allow_cliff and terrain_class_at(q) == &"cliff":
			return false
	return true

func terrain_profile(rect: Rect2, sample_step: float) -> PackedFloat32Array:
	if sample_step <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return PackedFloat32Array()
	var nx := int(ceil(rect.size.x / sample_step)) + 1
	var ny := int(ceil(rect.size.y / sample_step)) + 1
	# cap to avoid huge allocations
	if nx * ny > 100000:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(nx * ny)
	var idx := 0
	for j in ny:
		for i in nx:
			var x := rect.position.x + float(i) * sample_step
			var y := rect.position.y + float(j) * sample_step
			# clamp last sample to rect.end to keep deterministic
			if x > rect.end.x:
				x = rect.end.x
			if y > rect.end.y:
				y = rect.end.y
			out[idx] = height_at(Vector2(x, y))
			idx += 1
	return out
