class_name HydrologyPlan
extends RefCounted
## Pure hydrology plan: primary Vltava-like river + 2 tributaries.
## No Node access, no unseeded randomness, no chunk-local state.
## Every query is deterministic function of seed + world coordinates via WorldSeed helpers.
## Generation contract matches SPEC-C002: CX mean 620+-90, meander 72 sin +18 coherent, width 38-50, etc.

var seed_used: int
var cx_mean: float
var phi: float
var tributaries: Array[Dictionary] = []  # each {id, ax, az, mx, mz, cx, cz, width, half}

static func _unit_float(purpose: String, parts: Array, seed: int) -> float:
	return float(WorldSeed.combine([seed, WorldSeed.str_hash(purpose)] + parts) % 1000003) / 1000003.0

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed
	# Primary corridor mean CX = 620 + S*90 where S = unit_float("hydro_cx")*2-1 => 530-710
	var s := _unit_float("hydro_cx", [], seed_used) * 2.0 - 1.0
	cx_mean = WorldConstants.HYDRO_CORRIDOR_CX_MEAN + s * WorldConstants.HYDRO_CORRIDOR_JITTER
	phi = _unit_float("hydro_phi", [], seed_used) * TAU
	tributaries = []
	for k in WorldConstants.TRIB_COUNT:
		var side := -1.0 if k == 0 else 1.0
		# Alternate sides; seeded jitter could also flip but alternating satisfies outside corridor spec
		var jitter_ax := (_unit_float("hydro_trib_ax", [k], seed_used) * 2.0 - 1.0) * WorldConstants.TRIB_ANCHOR_JITTER
		var ax := cx_mean + side * (WorldConstants.TRIB_ANCHOR_BASE_OFFSET + jitter_ax)
		var jitter_az := (_unit_float("hydro_trib_az", [k], seed_used) * 2.0 - 1.0) * WorldConstants.TRIB_UPSTREAM_JITTER_Z * 0.5
		var az := WorldConstants.TRIB_UPSTREAM_BASE_Z + float(k) * WorldConstants.TRIB_UPSTREAM_STEP_Z + jitter_az
		var jitter_cz := (_unit_float("hydro_trib_cz", [k], seed_used) * 2.0 - 1.0) * 200.0
		# EnsureCz is north of Az (~900m) with jitter
		var cz := az + 900.0 + jitter_cz
		# Confluence X is primary center at cz
		var cx := river_center_x_at(cz)
		var jitter_mid := (_unit_float("hydro_trib_mid", [k], seed_used) * 2.0 - 1.0) * 30.0
		var mx := (ax + cx) * 0.5 + jitter_mid
		var mz := (az + cz) * 0.5
		var w := WorldConstants.TRIBUTARY_WIDTH_MIN + (WorldConstants.TRIBUTARY_WIDTH_MAX - WorldConstants.TRIBUTARY_WIDTH_MIN) * _unit_float("hydro_trib_ax", [k, 99], seed_used)
		# Reuse hydro_trib_ax with extra salt for width variation to keep domain separated but still deterministic
		tributaries.append({
			"id": "trib_%d" % k,
			"ax": ax, "az": az,
			"mx": mx, "mz": mz,
			"cx": cx, "cz": cz,
			"width": w,
			"half": w * 0.5,
		})

# --- Primary corridor queries ---

func river_center_x_at(z: float) -> float:
	# MX(z) = A*sin(z/W + phi) + 18*sample_coherent_signed(Vector2(0,z), hydro_meander2, 600)
	var meander := WorldConstants.HYDRO_MEANDER_AMPL * sin(z / WorldConstants.HYDRO_MEANDER_WAVELENGTH + phi)
	var secondary := WorldConstants.HYDRO_MEANDER2_AMPL * WorldSeed.sample_coherent_signed(Vector2(0, z), &"hydro_meander2", WorldConstants.HYDRO_MEANDER2_CELL, seed_used)
	return cx_mean + meander + secondary

func river_width_at(z: float) -> float:
	# 38 + 12*sample_coherent(Vector2(0,z), hydro_width, 900) => 38-50
	var t := WorldSeed.sample_coherent(Vector2(0, z), &"hydro_width", WorldConstants.HYDRO_WIDTH_CELL, seed_used)
	return WorldConstants.RIVER_WIDTH_MIN + (WorldConstants.RIVER_WIDTH_MAX - WorldConstants.RIVER_WIDTH_MIN) * t

func river_half_width_at(z: float) -> float:
	return river_width_at(z) * 0.5

func river_confluence_x_at(z: float) -> float:
	return river_center_x_at(z)

# --- Water level ---

func water_level_at(p: Vector2) -> float:
	# Mean -1.2 +-0.6 along flow axis, constant across width within chunk (depends only on z)
	var lvl := WorldConstants.WATER_LEVEL_MEAN + WorldConstants.WATER_LEVEL_VAR * WorldSeed.sample_coherent_signed(Vector2(0, p.y), &"hydro_level", WorldConstants.WATER_LEVEL_CELL, seed_used)
	# If inside tributary, inherit primary level minus small fall 0.015*(Cz - z)
	var body := water_body_at(p)
	if body == &"tributary":
		var trib: Variant = _nearest_tributary(p)
		if trib != null:
			lvl -= WorldConstants.TRIB_FALL_SLOPE * (float(trib["cz"]) - p.y)
	return lvl

# --- Water body classification ---

func water_body_at(p: Vector2) -> StringName:
	var river_dist := _river_signed_distance(p)
	if river_dist <= 0.0:
		return &"river"
	# Check tributaries
	var nearest_trib_dist := INF
	for trib in tributaries:
		var d := _tributary_signed_distance(p, trib)
		if d < nearest_trib_dist:
			nearest_trib_dist = d
	if nearest_trib_dist <= 0.0:
		return &"tributary"
	return &""

func water_body_id_at(p: Vector2) -> String:
	var body := water_body_at(p)
	if body == &"river":
		return "river_main"
	if body == &"tributary":
		var best := ""
		var best_dist := INF
		for trib in tributaries:
			var d := _tributary_signed_distance(p, trib)
			if d < best_dist:
				best_dist = d
				best = String(trib["id"])
		if best_dist <= 0.0:
			return best
		# If point is near tributary but outside width, still return nearest trib id for debugging?
		return best if best != "" else ""
	return ""

func _river_signed_distance(p: Vector2) -> float:
	var cx := river_center_x_at(p.y)
	var half := river_half_width_at(p.y)
	return absf(p.x - cx) - half

func _tributary_signed_distance(p: Vector2, trib: Dictionary) -> float:
	var closest := _tributary_closest_point(p, trib)
	var dcenter := p.distance_to(closest)
	return dcenter - float(trib["half"])

func _tributary_closest_point(p: Vector2, trib: Dictionary) -> Vector2:
	# Quadratic bezier P0->P1->P2, sample search for closest t
	var p0 := Vector2(float(trib["ax"]), float(trib["az"]))
	var p1 := Vector2(float(trib["mx"]), float(trib["mz"]))
	var p2 := Vector2(float(trib["cx"]), float(trib["cz"]))
	var best_t := 0.0
	var best_d2 := INF
	# Coarse sampling 24 steps
	for i in 25:
		var t := float(i) / 24.0
		var b := _bezier2(p0, p1, p2, t)
		var d2 := p.distance_squared_to(b)
		if d2 < best_d2:
			best_d2 = d2
			best_t = t
	# Refine around best_t
	for _iter in 8:
		var t0 := clampf(best_t - 0.06, 0.0, 1.0)
		var t1 := clampf(best_t + 0.06, 0.0, 1.0)
		var b0 := _bezier2(p0, p1, p2, t0)
		var b1 := _bezier2(p0, p1, p2, best_t)
		var b2 := _bezier2(p0, p1, p2, t1)
		var d0 := p.distance_squared_to(b0)
		var d1 := p.distance_squared_to(b1)
		var d2 := p.distance_squared_to(b2)
		if d0 < d1 and d0 < d2:
			best_t = t0
			best_d2 = d0
		elif d2 < d1 and d2 < d0:
			best_t = t1
			best_d2 = d2
		else:
			# shrink step
			# keep best_t, break if no improvement
			break
	return _bezier2(p0, p1, p2, best_t)

func _bezier2(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * p0 + 2.0 * u * t * p1 + t * t * p2

func _bezier2_tangent(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	# derivative: 2(1-t)(P1-P0) +2t(P2-P1)
	return 2.0 * (1.0 - t) * (p1 - p0) + 2.0 * t * (p2 - p1)

func _nearest_tributary(p: Vector2) -> Variant:
	var best = null
	var best_d := INF
	for trib in tributaries:
		var d := absf(_tributary_signed_distance(p, trib))
		# For water_level we want the containing trib if inside; otherwise nearest
		var signed := _tributary_signed_distance(p, trib)
		# Prefer inside
		if signed <= 0.0:
			return trib
		if d < best_d:
			best_d = d
			best = trib
	return best

# --- Distance queries ---

func distance_to_water(p: Vector2) -> float:
	# Signed distance to nearest water edge (negative inside)
	var rd := _river_signed_distance(p)
	var best := rd
	for trib in tributaries:
		var td := _tributary_signed_distance(p, trib)
		if td < best:
			best = td
	return best

func bank_distance_at(p: Vector2) -> float:
	# Distance to nearest bank line (0 at water edge)
	return absf(distance_to_water(p))

func is_floodplain(p: Vector2) -> bool:
	# Floodplain when abs(dist_to_center) in (half+bank, half+bank+flood] and terrain class != cliff
	# Determine nearest water body: use river for simplicity unless tributary nearer
	var rd := _river_signed_distance(p)
	var dist_to_center_river := absf(p.x - river_center_x_at(p.y))
	var half_river := river_half_width_at(p.y)
	# Compute floodplain for river
	if dist_to_center_river > half_river + WorldConstants.BANK_W and dist_to_center_river <= half_river + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W:
		return true
	# Also check tributaries
	for trib in tributaries:
		var cp := _tributary_closest_point(p, trib)
		var dcenter := p.distance_to(cp)
		var half := float(trib["half"])
		if dcenter > half + WorldConstants.BANK_W and dcenter <= half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W:
			return true
	return false

# --- Flow direction ---

func flow_direction_at(p: Vector2) -> Vector2:
	var body := water_body_at(p)
	if body == &"tributary":
		# Find nearest trib and its tangent
		var trib = null
		var best_d := INF
		var best_t := 0.0
		for t in tributaries:
			# Find closest t by sampling
			var p0 := Vector2(float(t["ax"]), float(t["az"]))
			var p1 := Vector2(float(t["mx"]), float(t["mz"]))
			var p2 := Vector2(float(t["cx"]), float(t["cz"]))
			var bt := 0.0
			var bd2 := INF
			for i in 25:
				var tt := float(i) / 24.0
				var b := _bezier2(p0, p1, p2, tt)
				var d2 := p.distance_squared_to(b)
				if d2 < bd2:
					bd2 = d2
					bt = tt
			if bd2 < best_d:
				best_d = bd2
				trib = t
				best_t = bt
		if trib != null:
			var p0 := Vector2(float(trib["ax"]), float(trib["az"]))
			var p1 := Vector2(float(trib["mx"]), float(trib["mz"]))
			var p2 := Vector2(float(trib["cx"]), float(trib["cz"]))
			var tang := _bezier2_tangent(p0, p1, p2, best_t)
			if tang.length_squared() < 1e-6:
				tang = Vector2(0, 1)
			return tang.normalized()
	# Default primary flow: northward with meander wobble
	var z := p.y
	var dx := (river_center_x_at(z + 1.0) - river_center_x_at(z - 1.0)) * 0.5
	# Tangent along center: (dx, 1)
	var dir := Vector2(dx, 1.0)
	if dir.length_squared() < 1e-6:
		return Vector2(0, 1)
	return dir.normalized()

# --- Crossing candidates ---

func crossing_candidates(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# At least one per ~800m along primary where |distance_to_water| < bank+floodplain and terrain slope < BUILDABLE_MAX_SLOPE_DEG
	# We need terrain slope info; we can approximate using a temporary TerrainPlan if needed, but spec says pure query without terrain node.
	# For hydrology pure we can assume slope check is external; we will filter using TerrainPlan internally: create private TerrainPlan with same seed to test slope.
	var terrain := TerrainPlan.new(seed_used)
	var y0 := rect.position.y
	var y1 := rect.end.y
	# Align to ~800m grid seeded deterministically: step 400 for dense candidates, ensure at least one per 800
	var step := 400.0
	var start_z := floorf(y0 / step) * step
	var end_z := ceilf(y1 / step) * step
	var idx := 0
	for z in range(int(start_z), int(end_z) + 1, int(step)):
		var zf := float(z)
		var cx := river_center_x_at(zf)
		var center := Vector2(cx, zf)
		# Check if center within rect expanded by floodplain+banks (~35m) and half width
		var half := river_half_width_at(zf)
		var margin := half + WorldConstants.BANK_W + WorldConstants.FLOODPLAIN_W + 10.0
		if center.x < rect.position.x - margin or center.x > rect.end.x + margin:
			continue
		if center.y < rect.position.y - 20.0 or center.y > rect.end.y + 20.0:
			continue
		# Slope check: terrain slope at center < BUILDABLE_MAX_SLOPE_DEG (use TerrainPlan.slope_at)
		# If slope too steep, skip (no crossing there)
		var slope := terrain.slope_at(center)
		if slope >= WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
			# Try offset slightly along river?
			continue
		# |distance_to_water| at candidate center is 0 (on river). Check expanded rect includes floodplain?
		# Our spec: where |distance_to_water| < bank+floodplain -> includes river and banks. Our center qualifies.
		var water_id := "river_main"
		var width := river_width_at(zf)
		# Determine axis: crossing axis perpendicular to flow (approx east-west)
		var flow := flow_direction_at(center)
		var axis := Vector2(-flow.y, flow.x)  # perpendicular
		# Use axis as normalized vector
		out.append({
			"id": "cross_%d_%d" % [int(center.x), int(center.y)],
			"center": center,
			"width": width,
			"axis": axis,
			"water_id": water_id,
		})
		idx += 1
	# Ensure at least one per 800m if rect tall: if out empty and rect height > 400, try fallback at rect center
	if out.is_empty() and rect.size.y >= 400:
		var mid_z := rect.get_center().y
		var cxm := river_center_x_at(mid_z)
		var centerm := Vector2(cxm, mid_z)
		if centerm.x >= rect.position.x - 100.0 and centerm.x <= rect.end.x + 100.0:
			var slopem := terrain.slope_at(centerm)
			if slopem < WorldConstants.BUILDABLE_MAX_SLOPE_DEG:
				out.append({
					"id": "cross_fallback_%d_%d" % [int(centerm.x), int(centerm.y)],
					"center": centerm,
					"width": river_width_at(mid_z),
					"axis": Vector2(1,0),
					"water_id": "river_main",
				})
	return out

# --- Helpers for tests ---

func tributary_info(k: int) -> Dictionary:
	if k < 0 or k >= tributaries.size():
		return {}
	return tributaries[k]

func all_tributaries() -> Array[Dictionary]:
	return tributaries.duplicate()

