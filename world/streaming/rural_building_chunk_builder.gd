class_name RuralBuildingChunkBuilder
extends RefCounted
## Pure rural building chunk manifest + main-thread materialization for P4.2/P4.3.
## Each 64m chunk carries at most one rural collider (0 if dry), verts <=400 (typical <=240) tris <=300 (typical <=180), ACTIVE-only physics.
## P4.3 adds interior partition walls + furniture proxies batched into same mesh + FoodCrate leaves.

const CHUNK_M := 64.0
const RuralArt = preload("res://art/rural_art.gd")
const COL_PLASTER := Color("ddd0c0")
const COL_BRICK := Color("b07a5a")
const COL_TIMBER := Color("7a5a3a")
const COL_ROOF_RED := Color("8a3a2a")
const COL_ROOF_GREY := Color("5a5a5a")
const COL_WALL_DARK_FACTOR := 0.88
const COL_FURNITURE_BED := Color("9e8b6a")
const COL_FURNITURE_SHELF := Color("6b5a4a")
const COL_FURNITURE_TABLE := Color("7a6a5a")
const COL_FURNITURE_STOVE := Color("4a4a4a")
const COL_WELL_WALL := Color("8b7f6e")
const COL_WELL_WATER := Color("2b3a4a")
const COL_WELL_BEAM := Color("6b5a4a")
const COL_FORAGE_BUSH := Color("5a7a3a")
const COL_FORAGE_MUSHROOM := Color("8a6a4a")
const COL_FORAGE_HERB := Color("6a8a5a")

static func _effective_footprint(footprint: Vector2, yaw: float) -> Vector2:
	if is_equal_approx(absf(yaw), PI * 0.5) or is_equal_approx(absf(yaw), PI * 1.5):
		return Vector2(footprint.y, footprint.x)
	return footprint

static func _add_box(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, center: Vector3, size: Vector3, col: Color) -> void:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var x0: float = center.x - hx
	var x1: float = center.x + hx
	var y0: float = center.y - hy
	var y1: float = center.y + hy
	var z0: float = center.z - hz
	var z1: float = center.z + hz
	var corners: Array[Vector3] = [
		Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1),
		Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)
	]
	var faces: Array[Dictionary] = [
		{"idx": [0,1,2,3], "normal": Vector3.DOWN, "color": col},
		{"idx": [4,7,6,5], "normal": Vector3.UP, "color": col},
		{"idx": [0,4,5,1], "normal": Vector3(0,0,-1), "color": col},
		{"idx": [2,6,7,3], "normal": Vector3(0,0,1), "color": col},
		{"idx": [1,5,6,2], "normal": Vector3(1,0,0), "color": col},
		{"idx": [3,7,4,0], "normal": Vector3(-1,0,0), "color": col},
	]
	var base_idx: int = verts.size()
	for f in faces:
		var idxs: Array = f["idx"] as Array
		var n: Vector3 = f["normal"] as Vector3
		var c: Color = f["color"] as Color
		var face_verts: Array[Vector3] = [corners[idxs[0]], corners[idxs[1]], corners[idxs[2]], corners[idxs[3]]]
		for v in face_verts:
			verts.append(v)
			normals.append(n)
			colors.append(c)
		var b0: int = base_idx
		indices.append(b0); indices.append(b0+1); indices.append(b0+2)
		indices.append(b0); indices.append(b0+2); indices.append(b0+3)
		base_idx +=4

static func _clip_segment_to_rect(a: Vector2, b: Vector2, rect: Rect2, pad: float) -> Array[Vector2]:
	var expanded: Rect2 = rect.grow(pad)
	var t0: float = 0.0
	var t1: float = 1.0
	var dx: float = b.x - a.x
	var dz: float = b.y - a.y
	var pvals: Array[float] = [-dx, dx, -dz, dz]
	var qvals: Array[float] = [a.x - expanded.position.x, expanded.end.x - a.x, a.y - expanded.position.y, expanded.end.y - a.y]
	for i in 4:
		var pv: float = pvals[i]
		var qv: float = qvals[i]
		if absf(pv) < 0.000001:
			if qv < 0.0:
				return [] as Array[Vector2]
			continue
		var r: float = qv / pv
		if pv < 0.0:
			if r > t1:
				return [] as Array[Vector2]
			if r > t0:
				t0 = r
		else:
			if r < t0:
				return [] as Array[Vector2]
			if r < t1:
				t1 = r
	if t1 < t0:
		return [] as Array[Vector2]
	return [a.lerp(b, t0), a.lerp(b, t1)] as Array[Vector2]

static func _tree_palette(kind: StringName) -> Array[Color]:
	match kind:
		&"birch":
			return [WorldConstants.COL_RURAL_TREE_TRUNK, WorldConstants.COL_RURAL_TREE_BIRCH, Color("7a9a5f")] as Array[Color]
		&"pine":
			return [WorldConstants.COL_RURAL_TREE_TRUNK, WorldConstants.COL_RURAL_TREE_PINE, Color("426b48")] as Array[Color]
		_:
			return [WorldConstants.COL_RURAL_TREE_TRUNK, WorldConstants.COL_RURAL_TREE_BEECH, Color("5d8048")] as Array[Color]
static func build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var origin := Vector2(coord) * CHUNK_M
	var size := Vector2(CHUNK_M, CHUNK_M)
	var rect := Rect2(origin, size)
	var center := origin + size * 0.5
	var suppress := false
	if origin.length() < WorldConstants.URBAN_INNER_M:
		var gate_near := false
		var gates: Array[Dictionary] = world_plan.city_gates()
		for g in gates:
			var gc: Vector2 = g["center"] as Vector2
			if center.distance_to(gc) < 90.0 or origin.distance_to(gc) < 90.0:
				gate_near = true
				break
		if not gate_near:
			suppress = true
	var raw_buildings: Array[Dictionary] = []
	if not suppress:
		raw_buildings = world_plan.rural_buildings_in(rect)
	var owned: Array[Dictionary] = []
	for b in raw_buildings:
		var b_center: Vector2 = b["center"] as Vector2
		if rect.has_point(b_center):
			if b_center.length() < WorldConstants.URBAN_INNER_M - 0.5:
				if not bool(b.get("allow_gate_barn", false)):
					continue
			owned.append(b)
	if owned.size() > WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK:
		owned = owned.slice(0, WorldConstants.MAX_RURAL_BUILDINGS_PER_CHUNK)
	owned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	var has_rural: bool = owned.size() > 0
	var door_manifests: Array[Dictionary] = []
	for b in owned:
		var bid: String = String(b["id"])
		var dpos: Vector2 = b["door_pos"] as Vector2
		var dyaw: float = float(b["door_yaw"])
		var normal := Vector2(cos(dyaw), sin(dyaw))
		var edge: int = 0
		if absf(normal.x) > absf(normal.y):
			edge = 1 if normal.x > 0 else 3
		else:
			edge = 0 if normal.y > 0 else 2
		var wall_yaw: float = 0.0 if edge == 0 or edge == 2 else PI * 0.5
		var hid: int = WorldSeed.str_hash(bid)
		var hinge_r: float = float(WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_building_palette"), hid]) % 1000003) / 1000003.0
		var hinge_left: bool = hinge_r < 0.5
		var ground_y: float = world_plan.surface_height_at(b.get("center", dpos) as Vector2) + WorldConstants.RURAL_OVERLAY_LIFT_M
		var door_width: float = 1.0
		var door_height: float = 2.1
		if String(b["kind"]) == "barn" or String(b["kind"]) == "stable":
			door_width = 1.2
			door_height = 2.2
		var dm: Dictionary = {
			"id": "rural_door_%s_0" % bid,
			"building_id": bid,
			"position": Vector3(dpos.x, ground_y, dpos.y),
			"yaw": wall_yaw,
			"edge": edge,
			"width": door_width,
			"height": door_height,
			"hinge": "left" if hinge_left else "right",
			"locked": false,
			"open_angle": 95.0,
			"swing": -1.0 if edge == 0 or edge == 3 else 1.0,
			"kind": &"rural_house",
			"door_pos": dpos,
			"door_yaw": wall_yaw,
		}
		door_manifests.append(dm)
	if door_manifests.size() > WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK:
		door_manifests = door_manifests.slice(0, WorldConstants.RURAL_DOOR_COUNT_MAX_PER_CHUNK)
	# Interior walls & furniture & crates
	var interior_walls: Array[Dictionary] = []
	var furniture_anchors: Array[Dictionary] = []
	var crate_manifests: Array[Dictionary] = []
	# G10-P2A: contract houses carry their own interior (partitions with
	# openings + furniture) inside the universal grammar — exclude their
	# walls/furniture from the generic legacy appends.
	var contract_ids: Dictionary = {}
	for b in owned:
		if RuralBuildingPlan.is_contract_house(b):
			contract_ids[str(b.get("id", ""))] = true
	for b in owned:
		var bid: String = String(b["id"])
		var interior: Dictionary = b.get("interior", {}) as Dictionary
		if interior.is_empty():
			continue
		var walls: Array = interior.get("walls", []) as Array
		for w in walls:
			var wd: Dictionary = w as Dictionary
			if contract_ids.has(String(wd.get("building_id", ""))):
				continue
			interior_walls.append(wd)
		var furn: Array = interior.get("furniture", []) as Array
		for f in furn:
			var fd: Dictionary = f as Dictionary
			if contract_ids.has(String(fd.get("building_id", ""))):
				continue
			furniture_anchors.append(fd)
		var crate: Dictionary = interior.get("crate", {}) as Dictionary
		if not crate.is_empty():
			# build crate manifest with world position height
			var cpos2: Vector2 = crate.get("pos", Vector2.ZERO) as Vector2
			var cyaw: float = float(crate.get("yaw", 0.0))
			var contents: Dictionary = crate.get("contents", {}) as Dictionary
			var ground: float = world_plan.surface_height_at(cpos2) + 0.01
			var pos3: Vector3 = Vector3(cpos2.x, ground+0.45, cpos2.y)
			var cm: Dictionary = {
				"id": crate.get("id", "rural_crate_%s" % bid),
				"building_id": bid,
				"pos": cpos2,
				"position": pos3,
				"yaw": cyaw,
				"contents": contents,
				"kind": &"rural_crate",
				"aabb": crate.get("aabb", Rect2(cpos2 - Vector2(0.5,0.5), Vector2(1,1))),
			}
			crate_manifests.append(cm)
	# Enforce per chunk caps
	# Furniture cap 6 per village chunk else 4
	var has_village := false
	for b in owned:
		if String(b["settlement_kind"]) == "village":
			has_village = true
			break
	var furn_cap: int = WorldConstants.RURAL_FURNITURE_MAX_PER_VILLAGE_CHUNK if has_village else 4
	# also cap by WorldConstants.RURAL_FURNITURE_CAP_PER_CHUNK
	furn_cap = mini(furn_cap, WorldConstants.RURAL_FURNITURE_CAP_PER_CHUNK)
	if furniture_anchors.size() > furn_cap:
		# deterministic sort by pos string
		furniture_anchors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("kind","")) < String(b.get("kind","")) or (String(a.get("kind",""))==String(b.get("kind","")) and Vector2(a.get("pos",Vector2.ZERO)).x < Vector2(b.get("pos",Vector2.ZERO)).x)
		)
		furniture_anchors = furniture_anchors.slice(0, furn_cap)
	# Crate cap 3
	if crate_manifests.size() > WorldConstants.RURAL_CRATE_MAX_PER_CHUNK:
		crate_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"])
		)
		crate_manifests = crate_manifests.slice(0, WorldConstants.RURAL_CRATE_MAX_PER_CHUNK)
	crate_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	interior_walls.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Vector2(a.get("pos",Vector2.ZERO)).x < Vector2(b.get("pos",Vector2.ZERO)).x
	)
	# Wells & forage manifests clipped to chunk rect (center ownership)
	var well_manifests: Array[Dictionary] = []
	var forage_manifests: Array[Dictionary] = []
	if not suppress:
		var raw_wells: Array[Dictionary] = world_plan.rural_wells_in(rect)
		var raw_forage: Array[Dictionary] = world_plan.rural_forage_patches_in(rect)
		# Build per-chunk ownership by center/pos
		for w in raw_wells:
			var wpos: Vector2 = w["pos"] as Vector2
			if rect.has_point(wpos):
				# urban suppression for wells already handled in plan, but double-check gate exception
				if wpos.length() < WorldConstants.URBAN_INNER_M - 0.5:
					var is_gate := false
					var gates2: Array[Dictionary] = world_plan.city_gates()
					for g in gates2:
						var gc: Vector2 = g["center"] as Vector2
						if wpos.distance_to(gc) < 140.0:
							is_gate = true
							break
					if not is_gate:
						continue
				var ground_w: float = world_plan.surface_height_at(wpos) + 0.01
				var pos3: Vector3 = Vector3(wpos.x, ground_w, wpos.y)
				var wm: Dictionary = {
					"id": w["id"],
					"pos": wpos,
					"position": pos3,
					"yaw": float(w.get("yaw", 0.0)),
					"radius": float(w.get("radius", WorldConstants.RURAL_WELL_RADIUS)),
					"height": float(w.get("height", WorldConstants.RURAL_WELL_HEIGHT)),
					"kind": w.get("kind", &"village_well"),
					"settlement_id": w.get("settlement_id", ""),
				}
				well_manifests.append(wm)
		for f in raw_forage:
			var fpos: Vector2 = f["pos"] as Vector2
			if rect.has_point(fpos):
				if fpos.length() < WorldConstants.URBAN_INNER_M - 0.5:
					continue
				var ground_f: float = world_plan.surface_height_at(fpos) + 0.01
				var pos3f: Vector3 = Vector3(fpos.x, ground_f, fpos.y)
				var fm: Dictionary = {
					"id": f["id"],
					"pos": fpos,
					"position": pos3f,
					"yaw": float(f.get("yaw", 0.0)),
					"kind": f.get("kind", &"bush_berry"),
					"settlement_id": f.get("settlement_id", ""),
					"contents": f.get("contents", {&"canned_food": 1}),
				}
				forage_manifests.append(fm)
	# Enforce per-chunk caps
	if well_manifests.size() > WorldConstants.RURAL_WELL_MAX_PER_CHUNK:
		well_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		well_manifests = well_manifests.slice(0, WorldConstants.RURAL_WELL_MAX_PER_CHUNK)
	if forage_manifests.size() > WorldConstants.RURAL_FORAGE_MAX_PER_CHUNK:
		forage_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		forage_manifests = forage_manifests.slice(0, WorldConstants.RURAL_FORAGE_MAX_PER_CHUNK)
	well_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	forage_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	var has_well: bool = well_manifests.size() > 0
	var has_forage: bool = forage_manifests.size() > 0
	# Hearth manifests (stove/bed) reusing furniture anchors — 0 extra verts/colliders, clipped by hearth pos
	var hearth_manifests: Array[Dictionary] = []
	var stove_manifests: Array[Dictionary] = []
	var bed_manifests: Array[Dictionary] = []
	if not suppress:
		for b in owned:
			var interior: Dictionary = b.get("interior", {}) as Dictionary
			var hearth_dict: Dictionary = interior.get("hearth", {}) as Dictionary
			for hk in hearth_dict.keys():
				var h: Dictionary = hearth_dict[hk] as Dictionary
				var hpos: Vector2 = h.get("pos", Vector2.ZERO) as Vector2
				if not rect.has_point(hpos):
					continue
				if hpos.length() < WorldConstants.URBAN_INNER_M - 0.5:
					var is_gate_h := false
					var gates_h: Array[Dictionary] = world_plan.city_gates()
					for g in gates_h:
						var gc: Vector2 = g["center"] as Vector2
						if hpos.distance_to(gc) < 140.0:
							is_gate_h = true
							break
					if not is_gate_h:
						continue
				var ground_h: float = world_plan.surface_height_at(hpos) + 0.01
				var sz: Vector3 = h.get("size", Vector3(0.8, 0.8, 0.9)) as Vector3
				var pos3h: Vector3 = Vector3(hpos.x, ground_h + sz.y * 0.5, hpos.y)
				var hm: Dictionary = {
					"id": h.get("id", "rural_%s_%s" % [str(h.get("kind", hk)), b["id"]]),
					"building_id": b["id"],
					"kind": StringName(str(h.get("kind", hk))),
					"pos": hpos,
					"position": pos3h,
					"yaw": float(h.get("yaw", 0.0)),
					"size": sz,
					"settlement_id": h.get("settlement_id", b.get("settlement_id", "")),
					"interior_pos": h.get("interior_pos", Vector2.ZERO),
					"aabb": h.get("aabb", Rect2()),
				}
				hearth_manifests.append(hm)
				if String(hm["kind"]) == "stove":
					stove_manifests.append(hm)
				elif String(hm["kind"]) == "bed":
					bed_manifests.append(hm)
		# Enforce per-chunk caps: stoves <=2 beds <=2 hearth <=4
		if stove_manifests.size() > WorldConstants.RURAL_STOVE_MAX_PER_CHUNK:
			stove_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
			stove_manifests = stove_manifests.slice(0, WorldConstants.RURAL_STOVE_MAX_PER_CHUNK)
		if bed_manifests.size() > WorldConstants.RURAL_BED_MAX_PER_CHUNK:
			bed_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
			bed_manifests = bed_manifests.slice(0, WorldConstants.RURAL_BED_MAX_PER_CHUNK)
		# Rebuild hearth_manifests from capped stove+bed
		hearth_manifests = []
		hearth_manifests.append_array(stove_manifests)
		hearth_manifests.append_array(bed_manifests)
		hearth_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		if hearth_manifests.size() > WorldConstants.RURAL_HEARTH_MAX_PER_CHUNK:
			hearth_manifests = hearth_manifests.slice(0, WorldConstants.RURAL_HEARTH_MAX_PER_CHUNK)
			# re-derive stove/bed from capped hearth
			stove_manifests = []
			bed_manifests = []
			for h in hearth_manifests:
				if String(h["kind"]) == "stove":
					stove_manifests.append(h)
				elif String(h["kind"]) == "bed":
					bed_manifests.append(h)
	var has_hearth: bool = hearth_manifests.size() > 0
	var has_stove: bool = stove_manifests.size() > 0
	var has_bed: bool = bed_manifests.size() > 0
	# Workbench manifests (village barn mill/press, hamlet 0-1 via plan, clipped center ownership)
	var workbench_manifests: Array[Dictionary] = []
	if not suppress:
		var raw_wb: Array[Dictionary] = world_plan.rural_workbenches_in(rect)
		for w in raw_wb:
			var wpos: Vector2 = w["pos"] as Vector2
			if not rect.has_point(wpos):
				continue
			if wpos.length() < WorldConstants.URBAN_INNER_M - 0.5:
				var is_gate_wb := false
				var gates_wb: Array[Dictionary] = world_plan.city_gates()
				for g in gates_wb:
					var gc: Vector2 = g["center"] as Vector2
					if wpos.distance_to(gc) < 140.0:
						is_gate_wb = true
						break
				if not is_gate_wb:
					continue
			var ground_wb: float = world_plan.surface_height_at(wpos) + WorldConstants.WORKBENCH_LIFT_M
			var pos3wb: Vector3 = Vector3(wpos.x, ground_wb + WorldConstants.RURAL_WORKBENCH_SIZE.y*0.5, wpos.y)
# alternatively use pos3 from plan
			var wpos3: Vector3 = pos3wb
			if wpos3 == Vector3.ZERO:
				wpos3 = pos3wb
			var wm: Dictionary = {
				"id": w["id"],
				"workbench_id": w.get("workbench_id", w["id"]),
				"building_id": w["building_id"],
				"settlement_id": w["settlement_id"],
				"settlement_kind": w.get("settlement_kind", &"village"),
				"building_kind": w.get("building_kind", &"barn"),
				"pos": wpos,
				"position": wpos3,
				"pos3": wpos3,
				"aabb": w.get("aabb", Rect2(wpos - Vector2(0.6,0.3), Vector2(1.2,0.6))),
				"center": w.get("center", wpos),
				"yaw": float(w.get("yaw", 0.0)),
				"size": w.get("size", WorldConstants.RURAL_WORKBENCH_SIZE),
			}
			workbench_manifests.append(wm)
	if workbench_manifests.size() > WorldConstants.RURAL_WORKBENCH_MAX_PER_CHUNK:
		workbench_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		workbench_manifests = workbench_manifests.slice(0, WorldConstants.RURAL_WORKBENCH_MAX_PER_CHUNK)
	workbench_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	var has_workbench: bool = workbench_manifests.size() > 0
	# Granary manifests (village barn cache, hamlet 0-1 30% via plan, clipped center ownership)
	var granary_manifests: Array[Dictionary] = []
	if not suppress:
		var raw_gr: Array[Dictionary] = world_plan.rural_granaries_in(rect)
		for g in raw_gr:
			var gpos: Vector2 = g["pos"] as Vector2
			if not rect.has_point(gpos):
				continue
			if gpos.length() < WorldConstants.URBAN_INNER_M - 0.5:
				var is_gate_gr := false
				var gates_gr: Array[Dictionary] = world_plan.city_gates()
				for gg in gates_gr:
					var gc: Vector2 = gg["center"] as Vector2
					if gpos.distance_to(gc) < 140.0:
						is_gate_gr = true
						break
				if not is_gate_gr:
					continue
			var ground_gr: float = world_plan.surface_height_at(gpos) + WorldConstants.GRANARY_LIFT_M
			var pos3gr: Vector3 = Vector3(gpos.x, ground_gr + WorldConstants.RURAL_GRANARY_SIZE.y*0.5, gpos.y)
			var gpos3: Vector3 = pos3gr
			if gpos3 == Vector3.ZERO:
				gpos3 = pos3gr
			var gm: Dictionary = {
				"id": g["id"],
				"granary_id": g.get("granary_id", g["id"]),
				"building_id": g["building_id"],
				"settlement_id": g["settlement_id"],
				"settlement_kind": g.get("settlement_kind", &"village"),
				"building_kind": g.get("building_kind", &"barn"),
				"pos": gpos,
				"position": gpos3,
				"pos3": gpos3,
				"aabb": g.get("aabb", Rect2(gpos - Vector2(0.6,0.4), Vector2(1.2,0.8))),
				"center": g.get("center", gpos),
				"yaw": float(g.get("yaw", 0.0)),
				"size": g.get("size", WorldConstants.RURAL_GRANARY_SIZE),
				"capacity": int(g.get("capacity", WorldConstants.RURAL_GRANARY_CAPACITY)),
			}
			granary_manifests.append(gm)
	if granary_manifests.size() > WorldConstants.RURAL_GRANARY_MAX_PER_CHUNK:
		granary_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
		granary_manifests = granary_manifests.slice(0, WorldConstants.RURAL_GRANARY_MAX_PER_CHUNK)
	granary_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	var has_granary: bool = granary_manifests.size() > 0
	# Settlement dressing is a separate visual mesh: it has no StaticBody and
	# therefore cannot inflate the existing ACTIVE rural collider budget.
	var dressing_verts := PackedVector3Array()
	var dressing_normals := PackedVector3Array()
	var dressing_colors := PackedColorArray()
	var dressing_indices := PackedInt32Array()
	var dressing_instances: int = 0
	if not suppress and world_plan != null:
		for path in world_plan.settlement_paths_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var pa: Vector2 = path.get("a", Vector2.ZERO) as Vector2
			var pb: Vector2 = path.get("b", Vector2.ZERO) as Vector2
			var pw: float = float(path.get("width", WorldConstants.RURAL_PATH_FOOT_WIDTH))
			var clipped: Array[Vector2] = _clip_segment_to_rect(pa, pb, rect, pw * 0.5 + 0.1)
			if clipped.size() < 2:
				continue
			var path_col: Color = WorldConstants.COL_RURAL_PATH_CART if StringName(str(path.get("kind", &"footpath"))) == &"cart_track" else WorldConstants.COL_RURAL_PATH_FOOT
			RuralArt.append_path(dressing_verts, dressing_normals, dressing_colors, dressing_indices, clipped[0], clipped[1], world_plan.surface_height_at(clipped[0]) + WorldConstants.RURAL_PATH_LIFT_M, world_plan.surface_height_at(clipped[1]) + WorldConstants.RURAL_PATH_LIFT_M, pw, path_col)
			dressing_instances += 1
		for yard in world_plan.settlement_yards_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var yard_center: Vector2 = yard.get("center", Vector2.ZERO) as Vector2
			if not rect.has_point(yard_center):
				continue
			RuralArt.append_yard(dressing_verts, dressing_normals, dressing_colors, dressing_indices, yard_center, world_plan.surface_height_at(yard_center) + WorldConstants.RURAL_PATH_LIFT_M, float(yard.get("radius", WorldConstants.RURAL_YARD_RADIUS_HAMLET)), WorldConstants.COL_RURAL_YARD)
			dressing_instances += 1
		# Low visual-only growth softens the maintained yard into the surrounding
		# rural edge. It shares this batch and is excluded from collision.
		for yard in world_plan.settlement_yards_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var yard_center: Vector2 = yard.get("center", Vector2.ZERO) as Vector2
			var yard_radius: float = float(yard.get("radius", WorldConstants.RURAL_YARD_RADIUS_HAMLET))
			var yard_seed: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_yard_undergrowth"), int(yard_center.x), int(yard_center.y)])
			for ui in 8:
				if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
					break
				var angle: float = float(yard_seed % 1000) / 1000.0 * TAU + float(ui) * 2.05
				var radius_factor: float = 0.62 + float((absi(yard_seed / (ui + 1)) % 24)) / 100.0
				var under_pos: Vector2 = yard_center + Vector2(cos(angle), sin(angle)) * yard_radius * radius_factor
				if not rect.has_point(under_pos) or world_plan.water_body_at(under_pos) != &"":
					continue
				var under_y: float = world_plan.surface_height_at(under_pos) + WorldConstants.RURAL_PATH_LIFT_M
				var under_scale: float = 1.05 + float((absi(yard_seed / (ui + 3)) % 35)) / 100.0
				RuralArt.append_undergrowth(dressing_verts, dressing_normals, dressing_colors, dressing_indices, Vector3(under_pos.x, under_y, under_pos.y), under_scale, angle, ui)
				dressing_instances += 1
		# Ensure every materialized rural building has a readable maintained edge,
		# even when its shared settlement yard anchor falls in a neighbor chunk.
		for settle_b in owned:
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var settle_center: Vector2 = settle_b.get("center", Vector2.ZERO) as Vector2
			var settle_door: Vector2 = settle_b.get("door_pos", settle_center) as Vector2
			var settle_outward: Vector2 = (settle_door - settle_center).normalized()
			if settle_outward.length_squared() < 0.01:
				settle_outward = Vector2.RIGHT
			var building_yard: Vector2 = settle_door + settle_outward * 3.0
			if world_plan.water_body_at(building_yard) != &"":
				continue
			var building_yard_y: float = world_plan.surface_height_at(building_yard) + WorldConstants.RURAL_PATH_LIFT_M
			RuralArt.append_yard(dressing_verts, dressing_normals, dressing_colors, dressing_indices, building_yard, building_yard_y, 12.0, WorldConstants.COL_RURAL_YARD)
			dressing_instances += 1
			var settle_side: Vector2 = Vector2(-settle_outward.y, settle_outward.x)
			var settle_aabb: Rect2 = settle_b.get("aabb", Rect2()) as Rect2
			var settle_seed: int = WorldSeed.combine([world_plan.seed_used, WorldSeed.str_hash("rural_building_edge_growth"), int(settle_center.x), int(settle_center.y)])
			for settle_i in 4:
				if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
					break
				var settle_angle: float = float(settle_seed % 1000) / 1000.0 * TAU + float(settle_i) * 1.57
				var settle_pos: Vector2 = building_yard + Vector2(cos(settle_angle), sin(settle_angle)) * (3.8 + float(settle_i % 2) * 0.8)
				if settle_aabb.grow(1.0).has_point(settle_pos):
					continue
				if world_plan.water_body_at(settle_pos) != &"" or world_plan.is_floodplain(settle_pos):
					continue
				var settle_y: float = world_plan.surface_height_at(settle_pos) + WorldConstants.RURAL_PATH_LIFT_M
				RuralArt.append_undergrowth(dressing_verts, dressing_normals, dressing_colors, dressing_indices, Vector3(settle_pos.x, settle_y, settle_pos.y), 1.05 + float(settle_i % 3) * 0.12, settle_angle, settle_i)
				dressing_instances += 1
		for fence in world_plan.settlement_fences_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var fa: Vector2 = fence.get("a", Vector2.ZERO) as Vector2
			var fb: Vector2 = fence.get("b", Vector2.ZERO) as Vector2
			var fh: float = float(fence.get("height", WorldConstants.RURAL_FENCE_HEIGHT_MIN))
			var fence_clip: Array[Vector2] = _clip_segment_to_rect(fa, fb, rect, 0.15)
			if fence_clip.size() < 2:
				continue
			RuralArt.append_fence(dressing_verts, dressing_normals, dressing_colors, dressing_indices, fence_clip[0], fence_clip[1], world_plan.surface_height_at((fence_clip[0] + fence_clip[1]) * 0.5) + WorldConstants.RURAL_PATH_LIFT_M, fh, WorldConstants.COL_RURAL_FENCE, WorldConstants.COL_RURAL_FENCE_CAP)
			dressing_instances += 1
		for prop in world_plan.settlement_clutter_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var prop_pos: Vector2 = prop.get("pos", Vector2.ZERO) as Vector2
			if not rect.has_point(prop_pos):
				continue
			var prop_center := Vector3(prop_pos.x, world_plan.surface_height_at(prop_pos) + WorldConstants.RURAL_PATH_LIFT_M, prop_pos.y)
			RuralArt.append_clutter(dressing_verts, dressing_normals, dressing_colors, dressing_indices, prop.get("kind", &"barrel") as StringName, prop_center, float(prop.get("scale", 1.0)), float(prop.get("yaw", 0.0)))
			dressing_instances += 1
		for tree in world_plan.settlement_trees_in(rect):
			if dressing_instances >= WorldConstants.RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK:
				break
			var tree_pos: Vector2 = tree.get("pos", Vector2.ZERO) as Vector2
			if not rect.has_point(tree_pos):
				continue
			var palette: Array[Color] = _tree_palette(tree.get("kind", &"beech") as StringName)
			var tree_center := Vector3(tree_pos.x, world_plan.surface_height_at(tree_pos) + WorldConstants.RURAL_PATH_LIFT_M, tree_pos.y)
			RuralArt.append_tree(dressing_verts, dressing_normals, dressing_colors, dressing_indices, tree_center, float(tree.get("scale", 1.0)), float(tree.get("yaw", 0.0)), palette[0], palette[1], palette[2])
			dressing_instances += 1
	var dressing_vertices: int = dressing_verts.size()
	var dressing_triangles: int = dressing_indices.size() / 3
	# has_rural now true if buildings/resources/dressing are present.
	var has_any_visual: bool = has_rural or has_well or has_forage or has_workbench or has_granary or dressing_vertices > 0
	var has_collider: bool = has_rural or has_well
	# Generate batched mesh geometry
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var vert_count := 0
	var tri_count := 0
	var aabbs: Array[Rect2] = []
	var building_colors: Array[Color] = []
	var building_ground_by_id: Dictionary = {}
	# For collider we need separate verts for shell+wall only
	var collider_verts := PackedVector3Array()
	var collider_indices := PackedInt32Array()
	var collider_offset := 0
	var contract_buildings: Array[Dictionary] = []
	for b in owned:
		var b_center: Vector2 = b["center"] as Vector2
		var footprint: Vector2 = b["footprint"] as Vector2
		var yaw: float = float(b["yaw"])
		var height: float = float(b["height"])
		var wall_col: Color = b.get("color", COL_PLASTER) as Color
		var roof_col: Color = b.get("roof_color", COL_ROOF_RED) as Color
		var ground: float = world_plan.surface_height_at(b_center) + WorldConstants.RURAL_OVERLAY_LIFT_M
		b["ground_y"] = ground
		building_ground_by_id[String(b.get("id", ""))] = ground
		var door_width: float = 1.2 if b.get("kind", &"") == &"barn" or b.get("kind", &"") == &"stable" else 1.0
		var door_height: float = 2.2 if door_width > 1.0 else 2.1
		var visual_before: int = verts.size()
		var visual_tri_before: int = indices.size()
		# G10-P2A Universal Building Contract: migrated house family goes
		# through the universal assembler (aperture-composed walls, real
		# windows, slabs, ladder, interior with openings). Everything else
		# stays on the legacy rural art path, explicitly tracked as pending
		# migration in docs/world/BUILDING-CONTRACT.md.
		var evidence: Dictionary = {}
		var assembled: bool = UniversalBuildingAssembler.build_rural_into(
				verts, normals, colors, indices, collider_verts,
				collider_indices, b, world_plan, evidence)
		if not assembled:
			RuralArt.append_building(verts, normals, colors, indices, b_center, footprint, yaw, ground, height, b.get("door_pos", b_center) as Vector2, door_width, door_height, b.get("kind", &"cottage") as StringName, wall_col, roof_col, COL_TIMBER, Color("415a60"), owned.size() <= 3)
			RuralArt.append_building_collision(collider_verts, collider_indices, b_center, footprint, yaw, ground, height, b.get("door_pos", b_center) as Vector2, door_width, door_height)
		else:
			contract_buildings.append(evidence)
		vert_count += verts.size() - visual_before
		tri_count += (indices.size() - visual_tri_before) / 3
		aabbs.append(b["aabb"] as Rect2)
		building_colors.append(wall_col)
	# Interior walls
	var interior_vertices := 0
	var interior_triangles := 0
	for w in interior_walls:
		var wpos: Vector2 = w.get("pos", Vector2.ZERO) as Vector2
		var wsize: Vector3 = w.get("size", Vector3(0.15,2.4,4.0)) as Vector3
		var wyaw: float = float(w.get("yaw", 0.0))
		# Determine wall color darker plaster
		var base_col: Color = COL_PLASTER
		# Try to find building color for wall's building? Use darkened
		var dark_col: Color = Color(base_col.r*COL_WALL_DARK_FACTOR, base_col.g*COL_WALL_DARK_FACTOR, base_col.b*COL_WALL_DARK_FACTOR)
		var owner_id: String = String(w.get("building_id", ""))
		var ground_w: float = float(building_ground_by_id.get(owner_id, world_plan.surface_height_at(wpos) + WorldConstants.RURAL_OVERLAY_LIFT_M))
		var wall_center: Vector3 = Vector3(wpos.x, ground_w + wsize.y*0.5, wpos.y)
		RuralArt._append_oriented_box(verts, normals, colors, indices, wall_center, wsize, wyaw, dark_col)
		# Keep the same oriented wall in the single aggregated structural body.
		var c_verts_before: int = collider_verts.size()
		RuralArt._append_collision_box(collider_verts, collider_indices, wall_center, wsize, wyaw)
		interior_vertices +=24
		interior_triangles +=12
	# Furniture proxies (visual only, not in collider)
	for f in furniture_anchors:
		var fpos: Vector2 = f.get("pos", Vector2.ZERO) as Vector2
		var fsize: Vector3 = f.get("size", Vector3(1.0,0.5,0.9)) as Vector3
		var fkind: StringName = f.get("kind", &"shelf") as StringName
		var fcol: Color
		match fkind:
			&"bed":
				fcol = COL_FURNITURE_BED
			&"shelf":
				fcol = COL_FURNITURE_SHELF
			&"table":
				fcol = COL_FURNITURE_TABLE
			&"stove":
				fcol = COL_FURNITURE_STOVE
			_:
				fcol = COL_FURNITURE_SHELF
		var owner_id_f: String = String(f.get("building_id", ""))
		var ground_f: float = float(building_ground_by_id.get(owner_id_f, world_plan.surface_height_at(fpos) + WorldConstants.RURAL_OVERLAY_LIFT_M))
		var f_center: Vector3 = Vector3(fpos.x, ground_f + fsize.y * 0.5, fpos.y)
		RuralArt._append_oriented_box(verts, normals, colors, indices, f_center, fsize, float(f.get("yaw", 0.0)), fcol)
		interior_vertices += 24
		interior_triangles += 12
	# Wells (batched into same mesh, also into collider)
	var well_vertices := 0
	var well_triangles := 0
	for w in well_manifests:
		var wpos: Vector2 = w["pos"] as Vector2
		var ground_w: float = world_plan.surface_height_at(wpos) + 0.01
		var wpos3: Vector3 = Vector3(wpos.x, ground_w + WorldConstants.RURAL_WELL_HEIGHT*0.5, wpos.y)
		var wsize: Vector3 = Vector3(WorldConstants.RURAL_WELL_RADIUS*2, WorldConstants.RURAL_WELL_HEIGHT, WorldConstants.RURAL_WELL_RADIUS*2)
		var well_visual_before: int = verts.size()
		var well_tri_before: int = indices.size()
		RuralArt.append_well(verts, normals, colors, indices, Vector3(wpos.x, ground_w, wpos.y), 1.0, float(w.get("yaw", 0.0)))
		# Collider remains a single conservative well box baked into RuralBody.
		_add_box(collider_verts, PackedVector3Array(), PackedColorArray(), collider_indices, wpos3, wsize, COL_WELL_WALL)
		well_vertices += verts.size() - well_visual_before
		well_triangles += (indices.size() - well_tri_before) / 3
	# Forage patches (visual only, not in collider)
	var forage_vertices := 0
	var forage_triangles := 0
	for f in forage_manifests:
		var fpos: Vector2 = f["pos"] as Vector2
		var fkind: StringName = f["kind"] as StringName
		var fcol2: Color
		match fkind:
			&"bush_berry":
				fcol2 = COL_FORAGE_BUSH
			&"mushroom_cluster":
				fcol2 = COL_FORAGE_MUSHROOM
			&"herb_patch":
				fcol2 = COL_FORAGE_HERB
			_:
				fcol2 = COL_FORAGE_BUSH
		var ground_fo: float = world_plan.surface_height_at(fpos) + 0.01
		var f_center: Vector3 = Vector3(fpos.x, ground_fo + 0.4, fpos.y)
		var f_size: Vector3 = Vector3(0.8, 0.6, 0.8)
		if fkind == &"mushroom_cluster":
			f_size = Vector3(0.4, 0.3, 0.4)
		elif fkind == &"herb_patch":
			f_size = Vector3(0.6, 0.35, 0.6)
		_add_box(verts, normals, colors, indices, f_center, f_size, fcol2)
		forage_vertices +=24
		forage_triangles +=12
	# Enforce budget: if verts >480, drop furniture iteratively then forage then wells? Keep at least one well if possible
	var contract_present: bool = contract_buildings.size() > 0
	# NOTE: blind tail-truncation would corrupt aperture-composed contract
	# geometry; contract chunks stay within budget by construction and are
	# measured by --buildingcontracttest / --ruraltest.
	while verts.size() > WorldConstants.MAX_RURAL_VERTS_PER_CHUNK and furniture_anchors.size() >0 and not contract_present:
		# remove last furniture
		# For simplicity, we already added, so need to recalc: remove last furniture box (24 verts = 24*? each box 24 verts, 6 faces*4)
		# Remove last 24 verts and 36 indices (12 tris *3)
		verts.resize(verts.size()-24)
		normals.resize(normals.size()-24)
		colors.resize(colors.size()-24)
		indices.resize(indices.size()-36)
		furniture_anchors = furniture_anchors.slice(0, furniture_anchors.size()-1)
		interior_vertices -=24
		interior_triangles -=12
	var total_verts: int = verts.size()
	var total_tris: int = indices.size() / 3
	var colliders: int = 1 if has_collider else 0
	var rural_doors: int = door_manifests.size()
	var rural_crates: int = crate_manifests.size()
	var rural_furniture: int = furniture_anchors.size()
	var rural_wells: int = well_manifests.size()
	var rural_forage: int = forage_manifests.size()
	var rural_hearths: int = hearth_manifests.size()
	var rural_stoves: int = stove_manifests.size()
	var rural_beds: int = bed_manifests.size()
	var rural_workbenches: int = workbench_manifests.size()
	var rural_granaries: int = granary_manifests.size()
	var gen_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	door_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	hearth_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	stove_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	bed_manifests.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"])
	)
	return {
		"coord": coord,
		"origin": origin,
		"size": size,
		"rural_buildings": owned,
		"contract_buildings": contract_buildings,
		"rural_contract_houses": contract_buildings.size(),
		"door_manifests": door_manifests,
		"interior_walls": interior_walls,
		"furniture_anchors": furniture_anchors,
		"crate_manifests": crate_manifests,
		"well_manifests": well_manifests,
		"forage_manifests": forage_manifests,
		"hearth_manifests": hearth_manifests,
		"stove_manifests": stove_manifests,
		"bed_manifests": bed_manifests,
		"rural_vertices": total_verts,
		"rural_triangles": total_tris,
		"rural_colliders": colliders,
		"rural_doors": rural_doors,
		"rural_crates": rural_crates,
		"rural_furniture": rural_furniture,
		"rural_wells": rural_wells,
		"rural_forage": rural_forage,
		"rural_hearths": rural_hearths,
		"rural_stoves": rural_stoves,
		"rural_beds": rural_beds,
		"rural_workbenches": rural_workbenches,
		"rural_granaries": rural_granaries,
		"workbench_manifests": workbench_manifests,
		"workbenches": rural_workbenches,
		"granary_manifests": granary_manifests,
		"granaries": rural_granaries,
		"well_vertices": well_vertices,
		"well_triangles": well_triangles,
		"forage_vertices": forage_vertices,
		"forage_triangles": forage_triangles,
		"interior_vertices": interior_vertices,
		"interior_triangles": interior_triangles,
		"has_rural": has_any_visual,
		"has_well": has_well,
		"has_forage": has_forage,
		"has_hearth": has_hearth,
		"has_stove": has_stove,
		"has_bed": has_bed,
		"has_workbench": has_workbench,
		"has_granary": has_granary,
		"rural_gen_ms": gen_ms,
		"rural_mat_ms": 0.0,
		"aabbs": aabbs,
		"colors": colors,
		"verts": verts,
		"normals": normals,
		"indices": indices,
		"collider_verts": collider_verts,
		"collider_indices": collider_indices,
		"settlement_path_count": world_plan.settlement_paths_in(rect).size() if world_plan != null else 0,
		"settlement_yard_count": world_plan.settlement_yards_in(rect).size() if world_plan != null else 0,
		"settlement_fence_count": world_plan.settlement_fences_in(rect).size() if world_plan != null else 0,
		"settlement_clutter_count": world_plan.settlement_clutter_in(rect).size() if world_plan != null else 0,
		"settlement_tree_count": world_plan.settlement_trees_in(rect).size() if world_plan != null else 0,
		"dressing_instances": dressing_instances,
		"dressing_vertices": dressing_vertices,
		"dressing_triangles": dressing_triangles,
		"dressing_verts": dressing_verts,
		"dressing_normals": dressing_normals,
		"dressing_colors": dressing_colors,
		"dressing_indices": dressing_indices,
	}

static func materialize(parent: Node3D, manifest: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var coord: Vector2i = manifest.get("coord", Vector2i.ZERO) as Vector2i
	var has_rural: bool = bool(manifest.get("has_rural", false))
	var has_well: bool = bool(manifest.get("has_well", false))
	var has_forage: bool = bool(manifest.get("has_forage", false))
	var has_hearth: bool = bool(manifest.get("has_hearth", false))
	var has_workbench: bool = bool(manifest.get("has_workbench", false))
	var has_granary: bool = bool(manifest.get("has_granary", false))
	var has_any: bool = has_rural or has_well or has_forage or has_hearth or has_workbench or has_granary
	var existing := parent.get_node_or_null(NodePath("Rural_%d_%d" % [coord.x, coord.y]))
	if existing != null:
		parent.remove_child(existing)
		existing.free()
	if not has_any:
		var mat_ms_empty: float = float(Time.get_ticks_usec() - t0) / 1000.0
		return {
			"rural_vertices": 0,
			"rural_triangles": 0,
			"rural_colliders": 0,
			"rural_doors": 0,
			"rural_crates": 0,
			"rural_furniture": 0,
			"rural_wells": 0,
			"rural_forage": 0,
			"rural_hearths": 0,
			"rural_stoves": 0,
			"rural_beds": 0,
			"rural_workbenches": 0,
			"rural_granaries": 0,
			"rural_buildings": 0,
			"has_rural": false,
			"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
			"rural_mat_ms": mat_ms_empty,
		}
	var verts: PackedVector3Array = manifest.get("verts", PackedVector3Array()) as PackedVector3Array
	var normals: Variant = manifest.get("normals", PackedVector3Array())
	var colors: PackedColorArray = manifest.get("colors", PackedColorArray()) as PackedColorArray
	var indices: PackedInt32Array = manifest.get("indices", PackedInt32Array()) as PackedInt32Array
	var collider_verts: PackedVector3Array = manifest.get("collider_verts", verts) as PackedVector3Array
	var collider_indices: PackedInt32Array = manifest.get("collider_indices", indices) as PackedInt32Array
	var door_manifests: Array = manifest.get("door_manifests", []) as Array
	var crate_manifests: Array = manifest.get("crate_manifests", []) as Array
	var well_manifests: Array = manifest.get("well_manifests", []) as Array
	var forage_manifests: Array = manifest.get("forage_manifests", []) as Array
	var hearth_manifests: Array = manifest.get("hearth_manifests", []) as Array
	var stove_manifests: Array = manifest.get("stove_manifests", []) as Array
	var bed_manifests: Array = manifest.get("bed_manifests", []) as Array
	var workbench_manifests: Array = manifest.get("workbench_manifests", manifest.get("workbenches", [])) as Array
	var granary_manifests: Array = manifest.get("granary_manifests", manifest.get("granaries", [])) as Array
	var rural_node := Node3D.new()
	rural_node.name = "Rural_%d_%d" % [coord.x, coord.y]
	parent.add_child(rural_node)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var norms_arr := PackedVector3Array()
	if normals is PackedVector3Array:
		norms_arr = normals as PackedVector3Array
	else:
		norms_arr.resize(verts.size())
		var arr: Array = normals as Array
		for i in verts.size():
			if i < arr.size():
				norms_arr[i] = arr[i] as Vector3
			else:
				norms_arr[i] = Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = norms_arr
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	if indices.size() >= 3 and verts.size() >= 3:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		mat.metallic = 0.0
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "RuralMesh"
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		rural_node.add_child(mi)
	# Paths, yards, fences, clutter, and tree edges share one visual mesh but
	# stay outside the structural RuralBody. Their category colors and
	# low-poly silhouettes are authored by RuralArt, not a shared green cube.
	var dressing_verts: PackedVector3Array = manifest.get("dressing_verts", PackedVector3Array()) as PackedVector3Array
	var dressing_normals: PackedVector3Array = manifest.get("dressing_normals", PackedVector3Array()) as PackedVector3Array
	var dressing_colors: PackedColorArray = manifest.get("dressing_colors", PackedColorArray()) as PackedColorArray
	var dressing_indices: PackedInt32Array = manifest.get("dressing_indices", PackedInt32Array()) as PackedInt32Array
	if dressing_verts.size() >= 3 and dressing_indices.size() >= 3:
		var dressing_arrays := []
		dressing_arrays.resize(Mesh.ARRAY_MAX)
		dressing_arrays[Mesh.ARRAY_VERTEX] = dressing_verts
		dressing_arrays[Mesh.ARRAY_NORMAL] = dressing_normals
		dressing_arrays[Mesh.ARRAY_COLOR] = dressing_colors
		dressing_arrays[Mesh.ARRAY_INDEX] = dressing_indices
		var dressing_mesh := ArrayMesh.new()
		dressing_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, dressing_arrays)
		var dressing_mat := StandardMaterial3D.new()
		dressing_mat.vertex_color_use_as_albedo = true
		dressing_mat.roughness = 0.88
		dressing_mat.metallic = 0.0
		dressing_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		dressing_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		dressing_mesh.surface_set_material(0, dressing_mat)
		var dressing_instance := MeshInstance3D.new()
		dressing_instance.name = "SettlementDressingMesh"
		dressing_instance.mesh = dressing_mesh
		dressing_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		rural_node.add_child(dressing_instance)

	var has_collider: bool = has_rural or has_well
	if has_collider:
		var body := StaticBody3D.new()
		body.name = "RuralBody"
		body.collision_layer = 1
		body.collision_mask = 0
		rural_node.add_child(body)
		var concave := ConcavePolygonShape3D.new()
		concave.backface_collision = true
		var faces := PackedVector3Array()
		# Use collider verts/indices for physics
		var c_verts: PackedVector3Array = collider_verts
		var c_indices: PackedInt32Array = collider_indices
		faces.resize(c_indices.size())
		for idx in c_indices.size():
			var vi: int = c_indices[idx]
			if vi >= 0 and vi < c_verts.size():
				faces[idx] = c_verts[vi]
		concave.data = faces
		var coll := CollisionShape3D.new()
		coll.shape = concave
		body.add_child(coll)
	var door_count := 0
	for dm in door_manifests:
		var d: Dictionary = dm as Dictionary
		var door := Door.new()
		door.name = String(d["id"])
		door.setup(d)
		rural_node.add_child(door)
		door_count += 1
	var crate_count := 0
	for cm in crate_manifests:
		var c: Dictionary = cm as Dictionary
		var crate := FoodCrate.new()
		crate.name = String(c["id"])
		# position
		var pos3: Vector3 = c.get("position", Vector3.ZERO) as Vector3
		crate.position = pos3
		crate.rotation.y = float(c.get("yaw", 0.0))
		var contents: Dictionary = c.get("contents", {}) as Dictionary
		# contents keys are StringName -> int, need to ensure StringName
		var conv: Dictionary = {}
		for k in contents.keys():
			conv[StringName(str(k))] = int(contents[k])
		crate.contents = conv
		# Ensure prompt update after _ready? _ready will call _update_prompt, but contents set after _ready may not update. Call load_state
		# Use load_state to set contents and update prompt
		# Need to defer until after _ready? We can set contents before add_child, then _ready will use it. So set before add.
		# Actually we already set contents before add, but crate.contents was empty at _ready. So we need to call _update_prompt after.
		rural_node.add_child(crate)
		# After _ready, update prompt
		if crate.has_method("_update_prompt"):
			crate.call("_update_prompt")
		else:
			# fallback call via load_state
			crate.load_state(conv)
		crate_count += 1
	var well_count := 0
	for wm in well_manifests:
		var w: Dictionary = wm as Dictionary
		var well := Well.new()
		well.name = String(w["id"])
		var pos3: Vector3 = w.get("position", Vector3.ZERO) as Vector3
		well.position = pos3
		well.rotation.y = float(w.get("yaw", 0.0))
		well.well_id = String(w["id"])
		# Ensure depleted state will be applied via manager after, but set initial not depleted
		well.depleted = false
		well.depleted_at_day = -1
		rural_node.add_child(well)
		if well.has_method("_update_prompt"):
			well.call("_update_prompt")
		well_count += 1
	var forage_count := 0
	for fm in forage_manifests:
		var f: Dictionary = fm as Dictionary
		var patch := ForagePatch.new()
		patch.name = String(f["id"])
		var pos3: Vector3 = f.get("position", Vector3.ZERO) as Vector3
		patch.position = pos3
		patch.rotation.y = float(f.get("yaw", 0.0))
		patch.patch_id = String(f["id"])
		patch.forage_kind = StringName(str(f.get("kind", &"bush_berry")))
		var cont: Dictionary = f.get("contents", {}) as Dictionary
		var conv2: Dictionary = {}
		for k in cont.keys():
			conv2[StringName(str(k))] = int(cont[k])
		patch.contents = conv2
		patch.depleted = false
		patch.depleted_at_day = -1
		rural_node.add_child(patch)
		if patch.has_method("_update_prompt"):
			patch.call("_update_prompt")
		forage_count += 1
	var hearth_count := 0
	var stove_count := 0
	var bed_count := 0
	for hm in hearth_manifests:
		var h: Dictionary = hm as Dictionary
		var kind: StringName = h.get("kind", &"stove") as StringName
		var pos3h: Vector3 = h.get("position", Vector3.ZERO) as Vector3
		if kind == &"stove":
			var stove := Stove.new()
			stove.name = String(h["id"])
			stove.position = pos3h
			stove.rotation.y = float(h.get("yaw", 0.0))
			stove.stove_id = String(h["id"])
			rural_node.add_child(stove)
			if stove.has_method("_update_prompt"):
				stove.call("_update_prompt", null)
			stove_count += 1
			hearth_count += 1
		elif kind == &"bed":
			var bed := Bed.new()
			bed.name = String(h["id"])
			bed.position = pos3h
			bed.rotation.y = float(h.get("yaw", 0.0))
			bed.bed_id = String(h["id"])
			rural_node.add_child(bed)
			if bed.has_method("_update_prompt"):
				bed.call("_update_prompt")
			bed_count += 1
			hearth_count += 1
		else:
			# fallback treat as stove
			var stove2 := Stove.new()
			stove2.name = String(h["id"])
			stove2.position = pos3h
			stove2.rotation.y = float(h.get("yaw", 0.0))
			stove2.stove_id = String(h["id"])
			rural_node.add_child(stove2)
			if stove2.has_method("_update_prompt"):
				stove2.call("_update_prompt", null)
			stove_count += 1
			hearth_count += 1
	var workbench_count := 0
	for wm in workbench_manifests:
		var w: Dictionary = wm as Dictionary
		var pos3w: Vector3 = w.get("position", w.get("pos3", Vector3.ZERO)) as Vector3
		if pos3w == Vector3.ZERO:
			var p2: Vector2 = w.get("pos", Vector2.ZERO) as Vector2
			pos3w = Vector3(p2.x, pos3w.y, p2.y)
		var wb = load("res://world/workbench.gd").new()
		wb.name = String(w["id"])
		wb.position = pos3w
		wb.rotation.y = float(w.get("yaw", 0.0))
		wb.workbench_id = String(w["id"])
		wb.building_id = String(w.get("building_id", ""))
		rural_node.add_child(wb)
		if wb.has_method("_update_prompt"):
			wb.call("_update_prompt", null)
		workbench_count += 1
	var granary_count := 0
	for gm in granary_manifests:
		var g: Dictionary = gm as Dictionary
		var pos3g: Vector3 = g.get("position", g.get("pos3", Vector3.ZERO)) as Vector3
		if pos3g == Vector3.ZERO:
			var p2: Vector2 = g.get("pos", Vector2.ZERO) as Vector2
			pos3g = Vector3(p2.x, pos3g.y, p2.y)
		var gc = load("res://world/granary_chest.gd").new()
		gc.name = String(g["id"])
		gc.position = pos3g
		gc.rotation.y = float(g.get("yaw", 0.0))
		gc.granary_id = String(g["id"])
		gc.building_id = String(g.get("building_id", ""))
		gc.settlement_id = String(g.get("settlement_id", ""))
		rural_node.add_child(gc)
		if gc.has_method("_update_prompt"):
			gc.call("_update_prompt", null)
		granary_count += 1
	var mat_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var has_collider_flag: bool = has_rural or has_well
	return {
		"rural_vertices": verts.size(),
		"rural_triangles": indices.size() / 3,
		"rural_colliders": 1 if has_collider_flag else 0,
		"rural_doors": door_count,
		"rural_crates": crate_count,
		"rural_wells": well_count,
		"rural_forage": forage_count,
		"rural_hearths": hearth_count,
		"rural_stoves": stove_count,
		"rural_beds": bed_count,
		"rural_workbenches": workbench_count,
		"rural_granaries": granary_count,
		"workbenches": workbench_count,
		"workbench_manifests": workbench_count,
		"granaries": granary_count,
		"granary_manifests": granary_count,
		"rural_furniture": int(manifest.get("rural_furniture", 0)),
		"rural_buildings": int((manifest.get("rural_buildings", []) as Array).size()),
		"rural_contract_houses": int(manifest.get("rural_contract_houses", 0)),
		"settlement_paths": int(manifest.get("settlement_path_count", 0)),
		"settlement_yards": int(manifest.get("settlement_yard_count", 0)),
		"settlement_fences": int(manifest.get("settlement_fence_count", 0)),
		"settlement_clutter": int(manifest.get("settlement_clutter_count", 0)),
		"settlement_trees": int(manifest.get("settlement_tree_count", 0)),
		"dressing_instances": int(manifest.get("dressing_instances", 0)),
		"dressing_vertices": int(manifest.get("dressing_vertices", 0)),
		"dressing_triangles": int(manifest.get("dressing_triangles", 0)),
		"has_rural": true,
		"rural_gen_ms": float(manifest.get("rural_gen_ms", 0.0)),
		"rural_mat_ms": mat_ms,
	}