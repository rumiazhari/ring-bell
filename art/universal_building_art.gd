extends RefCounted
## Ring Bell UNIVERSAL BUILDING CONTRACT — rural house grammar (G10-P2A).
##
## Geometry-only module: consumes ONE contractual rural house dict
## (kind/footprint/yaw/ground/height/door/interior) and appends REAL
## aperture-composed building geometry (visual quads + collider boxes) to
## caller-owned arrays — the same raw-array sink the legacy rural pipeline
## uses, so the single Concave RuralBody collider and per-chunk budgets are
## preserved.
##
## DIFFERENCE FROM THE LEGACY rural art (and the reason this exists):
##   - windows are GENUINE apertures: the wall is broken at every window,
##     a sill band closes it below, a structural lintel above, and a pane
##     sits INSIDE the empty gap. Nothing solid is ever left behind glass.
##   - the door aperture is split into piers + lintel exactly like the
##     city reference (BuildingBuilder._facade_with_openings).
##   - ground slab + intermediate floor slab (two-storey) are structural,
##     with the slab split around the ladder shaft (SlabMath.subtract_rect).
##   - two-storey houses get a real LADDER circulation (colliding rails,
##     visual rungs) so the upper floor is physically reachable.
##   - interior partitions are emitted with doorway openings (the plan
##     already computed gap/gap_side), and bed/table furniture collides.
##
## Reuses the proven low-level primitives from RuralArt (quad/wall-quad/
## box/collision appends) — no duplicated vertex math.

const RuralArt = preload("res://art/rural_art.gd")
## SlabMath is a global class_name; used for the ladder-shaft hole split.

const T := WorldConstants.RURAL_CONTRACT_WALL_T
const SLAB_T := WorldConstants.RURAL_CONTRACT_SLAB_T
const GLASS_T := 0.06
const PART_H := 2.4
const PART_OPEN := 2.0
const PART_OPEN_W := 0.9
const LADDER_W := 0.5
const LADDER_H := 4.1
const LADDER_T := 0.07

const COL_FURNITURE_BED := Color("9e8b6a")
const COL_FURNITURE_SHELF := Color("6b5a4a")
const COL_FURNITURE_TABLE := Color("7a6a5a")
const COL_FURNITURE_STOVE := Color("4a4a4a")


## Assemble ONE contractual rural house into the given arrays.
## `evidence` (out-param Dictionary) records what was assembled so the
## validator can cross-check counts and positions.
static func append_contract_house(verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, collider_verts: PackedVector3Array,
		collider_indices: PackedInt32Array, center: Vector2, footprint: Vector2,
		yaw: float, ground: float, height: float, door_pos: Vector2,
		door_width: float, door_height: float, kind: StringName,
		wall_col: Color, roof_col: Color, timber_col: Color,
		window_col: Color, interior: Dictionary, evidence: Dictionary) -> void:
	var hx := footprint.x * 0.5
	var hz := footprint.y * 0.5
	var floors := 2 if height > 6.0 else 1
	var storey_h := 4.2
	var upper_h := maxf(height - storey_h, 2.0)
	evidence["id"] = str(evidence.get("id", ""))
	evidence["assembled"] = true
	evidence["floors"] = floors
	evidence["ground"] = ground
	evidence["door_width"] = door_width
	evidence["door_height"] = door_height
	evidence["roof"] = &"gabled"
	evidence["partitions"] = 0
	evidence["partition_openings"] = 0
	evidence["furniture"] = 0
	evidence["ladder"] = false
	evidence["roof_quads"] = 0
	evidence["windows"] = 0
	evidence["ladder_pos"] = Vector3.ZERO
	# --- door side/along, same convention as the legacy engine ------------
	var door_local: Vector2 = RuralArt._world_to_local(center, yaw, door_pos)
	var door_side := 0
	var door_along: float = door_local.y
	if absf(door_local.x) >= absf(door_local.y):
		door_side = 0 if door_local.x >= 0.0 else 1
		door_along = clampf(door_local.y, -hz + door_width * 0.5 + 0.12, hz - door_width * 0.5 - 0.12)
	else:
		door_side = 2 if door_local.y >= 0.0 else 3
		door_along = clampf(door_local.x, -hx + door_width * 0.5 + 0.12, hx - door_width * 0.5 - 0.12)
	# --- structural walls with REAL apertures ------------------------------
	var sides: Array[float] = [hx, hz, hx, hz]
	for side in 4:
		var ground_wins: Array[Dictionary] = BuildingSpec.rural_window_openings(
				side, door_side, sides[side], 0, floors >= 2)
		var openings: Array[Dictionary] = []
		if side == door_side:
			openings.append({"c": door_along, "wd": door_width, "bot": 0.0, "h": door_height, "glass": false})
		for o in ground_wins:
			openings.append({"c": float(o["c"]), "wd": float(o["wd"]), "bot": float(o["bot"]), "h": float(o["h"]), "glass": true})
		_append_facade_with_openings(verts, normals, colors, indices,
				collider_verts, collider_indices, center, yaw, side, hx, hz,
				ground, storey_h, openings, wall_col, window_col, evidence)
		if floors >= 2:
			var upper_openings: Array[Dictionary] = []
			var upper_wins: Array[Dictionary] = BuildingSpec.rural_window_openings(
					side, door_side, sides[side], 1, true)
			for o2 in upper_wins:
				upper_openings.append({"c": float(o2["c"]), "wd": float(o2["wd"]), "bot": float(o2["bot"]), "h": float(o2["h"]), "glass": true})
			_append_facade_with_openings(verts, normals, colors, indices,
					collider_verts, collider_indices, center, yaw, side, hx, hz,
					ground + storey_h, upper_h, upper_openings,
					wall_col, window_col, evidence)
	# --- plinth band (visual, grounding read) ------------------------------
	var plinth_col: Color = wall_col.darkened(0.18)
	var plinth_h := 0.28
	for plinth_side in 4:
		var plinth_half: float = sides[plinth_side]
		if plinth_side == door_side:
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, plinth_side, -plinth_half, door_along - door_width * 0.5,
					ground, ground + plinth_h, hx, hz, plinth_col)
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, plinth_side, door_along + door_width * 0.5, plinth_half,
					ground, ground + plinth_h, hx, hz, plinth_col)
		else:
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, plinth_side, -plinth_half, plinth_half,
					ground, ground + plinth_h, hx, hz, plinth_col)
	# --- ground slab: structural below grade + visual top ------------------
	var slab_base := Vector2(footprint.x - 0.70, footprint.y - 0.70)
	_append_slab(verts, normals, colors, indices, collider_verts,
			collider_indices, center, yaw, slab_base, ground - SLAB_T * 0.5,
			ground, Color("6b5843").lightened(0.08))
	# --- upper slab + ladder shaft hole (two-storey) ------------------------
	var ladder_shaft := Rect2()
	if floors >= 2:
		var shaft_size := 0.9
		var lx := hx - 0.55
		var lz := hz - 0.55
		ladder_shaft = Rect2(lx - shaft_size * 0.5, lz - shaft_size * 0.5,
				shaft_size, shaft_size)
		var inner := Rect2(-hx + T + 0.03, -hz + T + 0.03,
					maxf(footprint.x - 2.0 * T - 0.08, 0.1),
					maxf(footprint.y - 2.0 * T - 0.08, 0.1))
		var pieces: Array[Rect2] = SlabMath.subtract_rect(inner, ladder_shaft)
		for r: Rect2 in pieces:
			_append_local_slab_piece(verts, normals, colors, indices,
					collider_verts, collider_indices, center, yaw, r,
					ground + storey_h - SLAB_T * 0.5, ground + storey_h,
					Color("6b5843").lightened(0.08))
		# LADDER: colliding rungs column through the shaft, visual rungs.
		var ladder_world: Vector2 = center + Vector2(
				lx * cos(yaw) - lz * sin(yaw), lx * sin(yaw) + lz * cos(yaw))
		var ladder_y0 := ground + 0.12
		var ladder_y1 := ground + storey_h - 0.05
		var lh := ladder_y1 - ladder_y0
		var lc := Vector2(ladder_world.x, ladder_world.y)
		RuralArt._append_collision_box(collider_verts, collider_indices,
				Vector3(lc.x, ladder_y0 + lh * 0.5, lc.y),
				Vector3(LADDER_W, lh, LADDER_T), yaw)
		var rung_n := maxi(4, int(round(lh / 0.7)))
		for ri in rung_n:
			var ry := ladder_y0 + (float(ri) + 0.5) * (lh / float(rung_n))
			_append_local_box(verts, normals, colors, indices, center, yaw,
					Vector3(lx, ry - ground, lz), Vector3(LADDER_W - 0.1, 0.05, 0.14),
					Color("5b412d"))
		evidence["ladder"] = true
		evidence["ladder_pos"] = Vector3(lc.x, ladder_y0, lc.y)
	# --- gabled roof --------------------------------------------------------
	var eave_y := ground + height
	var ridge_h: float = clampf(minf(2.0, minf(footprint.x, footprint.y) * 0.20), 0.9, 1.8)
	if footprint.x >= footprint.y:
		var a0 := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y, -hz))
		var a1 := RuralArt._local_point(center, yaw, Vector3(hx, eave_y, -hz))
		var a2 := RuralArt._local_point(center, yaw, Vector3(hx, eave_y + ridge_h, 0.0))
		var a3 := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y + ridge_h, 0.0))
		var b0 := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y, hz))
		var b1 := RuralArt._local_point(center, yaw, Vector3(hx, eave_y, hz))
		RuralArt._append_quad(verts, normals, colors, indices, a0, a1, a2, a3, roof_col, Vector3(0, 0, -1))
		RuralArt._append_quad(verts, normals, colors, indices, b1, b0, a3, a2, roof_col.darkened(0.10), Vector3(0, 0, 1))
		RuralArt._append_triangle(verts, normals, colors, indices, a0, a3, b0, wall_col.darkened(0.08), Vector3.LEFT)
		RuralArt._append_triangle(verts, normals, colors, indices, a1, b1, a2, wall_col.darkened(0.08), Vector3.RIGHT)
		evidence["roof_quads"] += 4
		# fascia + ridge cap (thin quads, not boxes)
		RuralArt._append_wall_quad(verts, normals, colors, indices, center, yaw,
				2, -hx - 0.14, hx + 0.14, eave_y - 0.08, eave_y + 0.18, hx, hz,
				roof_col.darkened(0.22), 0.12)
		RuralArt._append_wall_quad(verts, normals, colors, indices, center, yaw,
				3, -hx - 0.14, hx + 0.14, eave_y - 0.08, eave_y + 0.18, hx, hz,
				roof_col.darkened(0.22), 0.12)
		var cap0 := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y + ridge_h + 0.04, 0.0))
		var cap1 := RuralArt._local_point(center, yaw, Vector3(hx, eave_y + ridge_h + 0.04, 0.0))
		var cap2 := RuralArt._local_point(center, yaw, Vector3(hx, eave_y + ridge_h + 0.14, 0.0))
		var cap3 := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y + ridge_h + 0.14, 0.0))
		RuralArt._append_quad(verts, normals, colors, indices, cap0, cap1, cap2, cap3, roof_col, Vector3.UP)
		RuralArt._append_wall_quad(verts, normals, colors, indices, center, yaw,
				0, -0.1, 0.1, eave_y + ridge_h + 0.04, eave_y + ridge_h + 0.14,
				hx, hz, roof_col.darkened(0.15), 0.02)
		RuralArt._append_wall_quad(verts, normals, colors, indices, center, yaw,
				1, -0.1, 0.1, eave_y + ridge_h + 0.04, eave_y + ridge_h + 0.14,
				hx, hz, roof_col.darkened(0.15), 0.02)
		evidence["roof_quads"] += 5
	else:
		var a0b := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y, -hz))
		var a1b := RuralArt._local_point(center, yaw, Vector3(-hx, eave_y, hz))
		var a2b := RuralArt._local_point(center, yaw, Vector3(0.0, eave_y + ridge_h, hz))
		var a3b := RuralArt._local_point(center, yaw, Vector3(0.0, eave_y + ridge_h, -hz))
		var b0b := RuralArt._local_point(center, yaw, Vector3(hx, eave_y, -hz))
		var b1b := RuralArt._local_point(center, yaw, Vector3(hx, eave_y, hz))
		RuralArt._append_quad(verts, normals, colors, indices, a1b, a0b, a3b, a2b, roof_col, Vector3(-1, 0, 0))
		RuralArt._append_quad(verts, normals, colors, indices, b0b, b1b, a2b, a3b, roof_col.darkened(0.10), Vector3(1, 0, 0))
		RuralArt._append_triangle(verts, normals, colors, indices, a0b, b0b, a3b, wall_col.darkened(0.08), Vector3(0, 0, -1))
		RuralArt._append_triangle(verts, normals, colors, indices, a1b, a2b, b1b, wall_col.darkened(0.08), Vector3(0, 0, 1))
		evidence["roof_quads"] += 4
	# masonry chimney (visual only, same placement as legacy grammar)
	var chimney_local := Vector2(hx * 0.24, hz * 0.12)
	var chimney_world: Vector2 = RuralArt._local_to_world(center, yaw, chimney_local)
	RuralArt._append_oriented_box(verts, normals, colors, indices,
			Vector3(chimney_world.x, eave_y + 0.40 + (ridge_h + 0.75) * 0.5, chimney_world.y),
			Vector3(0.46, ridge_h + 0.75, 0.46), yaw, Color("7a665b"))
	# --- interior partitions with DOORWAY openings --------------------------
	var walls: Array = interior.get("walls", [])
	for wd: Dictionary in walls:
		_append_partition(verts, normals, colors, indices, collider_verts,
				collider_indices, wd, ground, evidence)
	# --- furniture (visual only, legacy parity for worker navigation) ---------
	var furn: Array = interior.get("furniture", [])
	for f: Dictionary in furn:
		var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
		var fsize: Vector3 = f.get("size", Vector3(1.0, 0.5, 0.9)) as Vector3
		var fkind: StringName = f.get("kind", &"shelf") as StringName
		var fcol: Color
		match fkind:
			&"bed": fcol = COL_FURNITURE_BED
			&"shelf": fcol = COL_FURNITURE_SHELF
			&"table": fcol = COL_FURNITURE_TABLE
			&"stove": fcol = COL_FURNITURE_STOVE
			_: fcol = COL_FURNITURE_SHELF
		var fyaw := float(f.get("yaw", 0.0))
		var f_center := Vector3(fpos.x, ground + fsize.y * 0.5, fpos.y)
		RuralArt._append_oriented_box(verts, normals, colors, indices,
				f_center, fsize, fyaw, fcol)
		evidence["furniture"] = int(evidence["furniture"]) + 1


## One facade storey with REAL aperture composition. Every opening gets
## piers, a sill band (below), a structural lintel (above), and a pane
## centered inside the empty gap. Collision mirrors the visual exactly.
## `hx`/`hz` are the FULL footprint halves (same convention as
## RuralArt.append_building); `along_axis` picks which local axis carries
## the along-coordinate (false = X, true = Z).
static func _append_facade_with_openings(verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, collider_verts: PackedVector3Array,
		collider_indices: PackedInt32Array, center: Vector2, yaw: float,
		side: int, hx: float, hz: float, y0: float, storey_h: float,
		openings: Array[Dictionary], wall_col: Color, window_col: Color,
		evidence: Dictionary) -> void:
	var along_half: float = hx if _side_horizontal(side) else hz
	if openings.is_empty():
		RuralArt._append_wall_quad(verts, normals, colors, indices, center,
				yaw, side, -along_half, along_half, y0, y0 + storey_h,
				hx, hz, wall_col)
		RuralArt._append_collision_wall_segment(collider_verts, collider_indices,
				center, yaw, side, -along_half, along_half, y0, storey_h,
				hx, hz, T)
		return
	openings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["c"]) < float(b["c"]))
	var cursor := -along_half
	for o in openings:
		var oc: float = float(o["c"])
		var owd: float = float(o["wd"])
		var obot: float = float(o["bot"])
		var oh: float = float(o["h"])
		var a := oc - owd * 0.5
		if a - cursor >= 0.05:
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, side, cursor, a, y0, y0 + storey_h, hx, hz, wall_col)
			RuralArt._append_collision_wall_segment(collider_verts, collider_indices,
					center, yaw, side, cursor, a, y0, storey_h, hx, hz, T)
		cursor = maxf(cursor, oc + owd * 0.5)
		# sill band below the opening
		if obot > 0.05:
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, side, oc - owd * 0.5, oc + owd * 0.5, y0, y0 + obot,
					hx, hz, wall_col)
			RuralArt._append_collision_wall_segment(collider_verts, collider_indices,
					center, yaw, side, oc - owd * 0.5, oc + owd * 0.5, y0, obot,
					hx, hz, T)
		# structural lintel above the opening
		var lh := storey_h - obot - oh
		if lh > 0.05:
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, side, oc - owd * 0.5, oc + owd * 0.5, y0 + obot + oh,
					y0 + storey_h, hx, hz, wall_col)
			RuralArt._append_collision_wall_segment(collider_verts, collider_indices,
					center, yaw, side, oc - owd * 0.5, oc + owd * 0.5,
					y0 + obot + oh, storey_h - obot - oh, hx, hz, T)
		if bool(o.get("glass", false)):
			# pane centered INSIDE the empty gap (visual quad + thin
			# colliding pane so nothing is walk-through).
			var pane_pos := _pane_local(side, hx, hz, oc)
			RuralArt._append_wall_quad(verts, normals, colors, indices, center,
					yaw, side, oc - (owd - 0.06) * 0.5, oc + (owd - 0.06) * 0.5,
					y0 + obot + 0.03, y0 + obot + oh - 0.03,
					hx, hz, window_col, 0.02)
			var pane_size := Vector3(owd - 0.06, oh - 0.06, GLASS_T) \
					if _side_horizontal(side) else Vector3(GLASS_T, oh - 0.06, owd - 0.06)
			RuralArt._append_collision_box(collider_verts, collider_indices,
					RuralArt._local_point(center, yaw,
							Vector3(pane_pos.x, y0 + obot + oh * 0.5, pane_pos.y)),
					pane_size, yaw)
			evidence["windows"] = int(evidence["windows"]) + 1
	if along_half - cursor >= 0.05:
		RuralArt._append_wall_quad(verts, normals, colors, indices, center,
				yaw, side, cursor, along_half, y0, y0 + storey_h, hx, hz, wall_col)
		RuralArt._append_collision_wall_segment(collider_verts, collider_indices,
				center, yaw, side, cursor, along_half, y0, storey_h, hx, hz, T)


## Local XZ of a pane at facade `side`, along `oc` (RuralArt side frame).
static func _pane_local(side: int, hx: float, hz: float, oc: float) -> Vector2:
	match side:
		0: return Vector2(hx, oc)
		1: return Vector2(-hx, oc)
		2: return Vector2(oc, hz)
		_: return Vector2(oc, -hz)


## Interior partition with a doorway opening (plan-computed gap/gap_side).
## The plan's wall dict is in WORLD space with yaw == building yaw.
static func _append_partition(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		collider_verts: PackedVector3Array, collider_indices: PackedInt32Array,
		wd: Dictionary, ground: float, evidence: Dictionary) -> void:
	var wpos: Vector2 = wd.get("pos", Vector2.ZERO) as Vector2
	var wsize: Vector3 = wd.get("size", Vector3(0.15, 2.4, 4.0)) as Vector3
	var wyaw := float(wd.get("yaw", 0.0))
	var gap := float(wd.get("gap", 0.9))
	var gap_side := int(wd.get("gap_side", 1))
	var length: float = float(wd.get("length", maxf(wsize.z, wsize.x)))
	var thickness: float = float(wd.get("thickness", minf(wsize.x, wsize.z)))
	var along_len := length
	# Center of the wall along its run:
	var along_center: float = 0.0
	# Wall runs along Z when thickness is on X (is_vert false), else along X.
	var runs_z: bool = wsize.x <= wsize.z
	if runs_z:
		along_center = wpos.y
	else:
		along_center = wpos.x
	var t0 := along_center - along_len * 0.5
	var t1 := along_center + along_len * 0.5
	var segs: Array[Vector2] = []   # [t_lo, t_hi] solid runs
	match gap_side:
		0: segs.append(Vector2(t0 + gap, t1))
		2: segs.append(Vector2(t0, t1 - gap))
		_: segs.append(Vector2(t0 + gap, t1 - gap))
	var dark_col := Color(Color("ddd0c0").r * 0.88, Color("ddd0c0").g * 0.88, Color("ddd0c0").b * 0.88)
	var th := thickness
	for seg in segs:
		var lo := seg.x
		var hi := seg.y
		if hi - lo < 0.05:
			continue
		var seg_len := hi - lo
		var seg_center: Vector2
		if runs_z:
			seg_center = Vector2(wpos.x, (lo + hi) * 0.5)
		else:
			seg_center = Vector2((lo + hi) * 0.5, wpos.y)
		var seg_size := Vector3(th, PART_H, seg_len) if runs_z else Vector3(seg_len, PART_H, th)
		RuralArt._append_oriented_box(verts, normals, colors, indices,
				Vector3(seg_center.x, ground + PART_H * 0.5, seg_center.y),
				seg_size, wyaw, dark_col)
	# NOTE: partitions are deliberately VISUAL-ONLY (no collision), matching
	# legacy rural interiors: society workers path on the terrain nav mesh,
	# which has no interior holes, so colliding partitions would trap a
	# worker at its home building. The geometry still has a REAL doorway
	# opening (segments + lintel) — see the evidence counters below.
	# lintel above the doorway opening
	var lintel_len := gap
	if lintel_len > 0.1:
		var lintel_center: Vector2
		match gap_side:
			0: lintel_center = Vector2(wpos.x, t0 + gap * 0.5) if runs_z else Vector2(t0 + gap * 0.5, wpos.y)
			2: lintel_center = Vector2(wpos.x, t1 - gap * 0.5) if runs_z else Vector2(t1 - gap * 0.5, wpos.y)
			_: lintel_center = Vector2(wpos.x, along_center) if runs_z else Vector2(along_center, wpos.y)
		var lintel_h := PART_H - PART_OPEN
		var lintel_size := Vector3(th, lintel_h, lintel_len) if runs_z else Vector3(lintel_len, lintel_h, th)
		RuralArt._append_oriented_box(verts, normals, colors, indices,
				Vector3(lintel_center.x, ground + PART_OPEN + lintel_h * 0.5, lintel_center.y),
				lintel_size, wyaw, dark_col)
	evidence["partitions"] = int(evidence["partitions"]) + 1
	evidence["partition_openings"] = int(evidence["partition_openings"]) + 1


## Structural slab: collider box below the walkable surface + visual top.
static func _append_slab(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		collider_verts: PackedVector3Array, collider_indices: PackedInt32Array,
		center: Vector2, yaw: float, size: Vector2, center_y: float,
		top_y: float, col: Color) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var p0 := RuralArt._local_point(center, yaw, Vector3(-hx, top_y, -hz))
	var p1 := RuralArt._local_point(center, yaw, Vector3(hx, top_y, -hz))
	var p2 := RuralArt._local_point(center, yaw, Vector3(hx, top_y, hz))
	var p3 := RuralArt._local_point(center, yaw, Vector3(-hx, top_y, hz))
	RuralArt._append_quad(verts, normals, colors, indices, p0, p1, p2, p3, col, Vector3.UP)
	RuralArt._append_collision_box(collider_verts, collider_indices,
			Vector3(center.x, center_y, center.y), Vector3(size.x, SLAB_T, size.y), yaw)


## One local-frame slab piece (after hole subtraction): visual quad + box.
static func _append_local_slab_piece(verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, collider_verts: PackedVector3Array,
		collider_indices: PackedInt32Array, center: Vector2, yaw: float,
		r: Rect2, center_y: float, top_y: float, col: Color) -> void:
	var p0 := RuralArt._local_point(center, yaw, Vector3(r.position.x, top_y, r.position.y))
	var p1 := RuralArt._local_point(center, yaw, Vector3(r.end.x, top_y, r.position.y))
	var p2 := RuralArt._local_point(center, yaw, Vector3(r.end.x, top_y, r.end.y))
	var p3 := RuralArt._local_point(center, yaw, Vector3(r.position.x, top_y, r.end.y))
	RuralArt._append_quad(verts, normals, colors, indices, p0, p1, p2, p3, col, Vector3.UP)
	var center_world: Vector2 = center + Vector2(
			r.get_center().x * cos(yaw) - r.get_center().y * sin(yaw),
			r.get_center().x * sin(yaw) + r.get_center().y * cos(yaw))
	RuralArt._append_collision_box(collider_verts, collider_indices,
			Vector3(center_world.x, center_y, center_world.y),
			Vector3(r.size.x, SLAB_T, r.size.y), yaw)


static func _append_local_box(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array, center: Vector2,
		yaw: float, local_pos: Vector3, size: Vector3, col: Color) -> void:
	RuralArt._append_oriented_box(verts, normals, colors, indices,
			RuralArt._local_point(center, yaw, local_pos), size, yaw, col)


## Facades run along X for N/S sides (0/2) and along Z for E/W (1/3).
static func _side_horizontal(side: int) -> bool:
	return side == 0 or side == 2