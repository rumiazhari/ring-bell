class_name BuildingContractValidator
extends RefCounted
## Ring Bell UNIVERSAL BUILDING CONTRACT — validator (G10-P2A).
##
## Rejects invalid FULL_BUILDING specs AND invalid builds. Every rule is a
## pure static function returning Array[String] (empty = valid), so the
## headless harness can drive malformed-spec matrices without a scene tree.
##
## Rule categories:
##   SPEC level   identity, classification, footprint, entrances,
##                circulation feasibility, room geometry/connectivity,
##                grounding.
##   BUILD level  (city box path)  aperture clearance (no solid geometry
##                behind doors/windows), structural walls per storey,
##                ground/storey slabs, roof, stairs materialized,
##                grounding, registration (no bypass of the universal
##                assembler).
##   BUILD level  (rural raw path) door aperture free in the collider soup,
##                one structural wall per side, ground/upper slab, roof
##                evidence, interior (partition+opening or furniture),
##                ladder materialization for two-storey houses.
##   BYPASS       unregistered_structural(): colliding geometry tagged with
##                a layer key that belongs to no registered contract
##                building id.
##
## The one mandatory path: UniversalBuildingAssembler (city: MeshBatcher +
## BuildingBuilder delegate; rural: contract house grammar). Direct
## primitive construction stays legal ONLY for props, debug visualisation,
## distant LOD, and non-building scenery.

const QUALITIES: Array[StringName] = WorldConstants.BUILDING_QUALITIES
const FULL := WorldConstants.BUILDING_QUALITY_FULL_BUILDING
const LOD := WorldConstants.BUILDING_QUALITY_DISTANT_LOD
const PROP := WorldConstants.BUILDING_QUALITY_PROP_STRUCTURE

const WALL_CELL := WorldConstants.CONTRACT_WALL_CELL
const EPS := 0.02


# ---------------------------------------------------------------------------
# SPEC-level rules
# ---------------------------------------------------------------------------

## Validate the universal spec. `surface_fn` (optional Callable(p:Vector2) ->
## float) enables the grounding rule; without it the rule is skipped.
static func validate_spec(spec: Dictionary, surface_fn: Callable = Callable()) -> Array[String]:
	var errs: Array[String] = []
	var id := str(spec.get("id", ""))
	if id == "":
		errs.append("missing id")
	var quality: StringName = spec.get("quality", &"") as StringName
	if not QUALITIES.has(quality):
		errs.append("invalid quality %s" % quality)
	var archetype: StringName = spec.get("archetype", &"") as StringName
	if not BuildingArchetype.has(archetype):
		errs.append("unknown archetype %s" % archetype)
		errs = _append_all(errs, validate_classification(spec))
		return errs
	# Classification must hold at EVERY quality — a house stamped PROP is
	# rejected before any FULL_BUILDING invariant runs.
	errs = _append_all(errs, validate_classification(spec))
	if quality == LOD and str(spec.get("lod_of", "")) == "":
		errs.append("DISTANT_LOD requires lod_of reference")
	if quality != FULL:
		return errs
	# Footprint scale rules (rect | rural center+footprint | polygon).
	var area := 0.0
	var min_side := 0.0
	if spec.has("rect"):
		var r: Rect2 = spec["rect"] as Rect2
		area = r.size.x * r.size.y
		min_side = minf(r.size.x, r.size.y)
	elif spec.has("footprint"):
		var fp: Vector2 = spec["footprint"] as Vector2
		area = fp.x * fp.y
		min_side = minf(fp.x, fp.y)
	else:
		var pts: PackedVector2Array = spec.get("points", PackedVector2Array()) as PackedVector2Array
		area = BuildingSpec.polygon_area(pts)
		min_side = sqrt(area) if area > 0.0 else 0.0
	if area < WorldConstants.CONTRACT_MIN_FOOTPRINT_AREA_M2:
		errs.append("footprint too small (%.1f m2 < %.1f)" % [area, WorldConstants.CONTRACT_MIN_FOOTPRINT_AREA_M2])
	if min_side < WorldConstants.CONTRACT_MIN_FOOTPRINT_SIDE_M:
		errs.append("footprint side too narrow (%.2f < %.1f)" % [min_side, WorldConstants.CONTRACT_MIN_FOOTPRINT_SIDE_M])
	var floors: int = int(spec.get("floors", 1))
	if floors < 1 or floors > WorldConstants.CONTRACT_MAX_FLOORS:
		errs.append("floors %d outside [1, %d]" % [floors, WorldConstants.CONTRACT_MAX_FLOORS])
	var fh: float = float(spec.get("floor_h", 0.0))
	if fh < WorldConstants.CONTRACT_FLOOR_H_MIN or fh > WorldConstants.CONTRACT_FLOOR_H_MAX:
		errs.append("floor_h %.2f outside [%.1f, %.1f]" % [fh, WorldConstants.CONTRACT_FLOOR_H_MIN, WorldConstants.CONTRACT_FLOOR_H_MAX])
	# Entrances: human scale, on the footprint boundary.
	var entrances := _entrances_of(spec)
	if entrances.is_empty():
		errs.append("missing entrance")
	elif spec.has("rect"):
		errs = _append_all(errs, _check_city_entrances(spec, entrances))
	else:
		errs = _append_all(errs, _check_rural_entrance(spec, entrances))
	# Circulation: upper floors must be reachable.
	var circ: Dictionary = spec.get("circulation", {})
	var circ_kind: StringName = circ.get("kind", &"none") as StringName
	if floors >= 2:
		if spec.has("rect"):
			if circ_kind != &"stairs":
				errs.append("unreachable upper floors: floors>=2 without stairs circulation")
			elif not BuildingBuilder.has_stairs_for(
					(spec["rect"] as Rect2).size, fh, floors):
				errs.append("unreachable upper floors: stairs do not fit footprint")
		else:
			if circ_kind != &"ladder" and circ_kind != &"stairs":
				errs.append("unreachable upper floors: floors>=2 without ladder/stairs circulation")
	# Rooms / connectivity / interior program.
	errs = _append_all(errs, _rooms_rules(spec))
	# Grounding (optional surface authority). Enforced only when the spec
	# COMMITS a ground_y claim: pure plan dictionaries get their ground
	# baked at materialization time (the chunk layer stamps ground_y from
	# WorldPlan.surface_height_at), so an unstamped spec is not yet a
	# floating building.
	if surface_fn.is_valid() and spec.has("ground_y"):
		var center := _spec_center(spec)
		var ground: float = float(spec.get("ground_y", 0.0))
		var surf: float = surface_fn.call(center)
		if absf(ground - surf) > 1.0:
			errs.append("grounding violated: ground_y %.2f vs surface %.2f at %s" % [ground, surf, center])
	return errs


static func validate_classification(spec: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var quality: StringName = spec.get("quality", &"") as StringName
	var archetype: StringName = spec.get("archetype", &"") as StringName
	if not BuildingArchetype.has(archetype):
		errs.append("unknown archetype %s" % archetype)
		return errs
	var min_q: StringName = BuildingArchetype.min_quality(archetype)
	if _quality_rank(quality) < _quality_rank(min_q):
		errs.append("invalid classification: %s may not be %s (min %s)" % [archetype, quality, min_q])
	if quality == PROP and not BuildingArchetype.is_bulk(archetype):
		var entry: Dictionary = BuildingArchetype.ARCHETYPES.get(archetype, {})
		if String(entry.get("family", "")) != "utility":
			errs.append("invalid classification: %s is not an explicitly non-enterable structure" % archetype)
	return errs


static func _quality_rank(q: StringName) -> int:
	match q:
		FULL: return 3
		LOD: return 2
		PROP: return 1
	return 0


static func _entrances_of(spec: Dictionary) -> Array[Dictionary]:
	if spec.has("rect"):
		return BuildingSpec.city_entrances(spec)
	var ground := float(spec.get("ground_y", spec.get("ground", 0.0)))
	return BuildingSpec.rural_entrance(spec, ground)


static func _check_city_entrances(spec: Dictionary, ents: Array[Dictionary]) -> Array[String]:
	var errs: Array[String] = []
	var r: Rect2 = spec["rect"] as Rect2
	var door_edge: int = int(spec.get("door_edge", 0))
	var yaw := float(spec.get("yaw", 0.0))
	var center := r.get_center()
	for e in ents:
		var w: float = float(e.get("width", 0.0))
		var h: float = float(e.get("height", 0.0))
		if w < WorldConstants.CONTRACT_DOOR_W_MIN or w > WorldConstants.CONTRACT_DOOR_W_MAX:
			errs.append("entrance width %.2f outside human scale" % w)
		if h < WorldConstants.CONTRACT_DOOR_H_MIN or h > WorldConstants.CONTRACT_DOOR_H_MAX:
			errs.append("entrance height %.2f outside human scale" % h)
		var p_world: Vector2 = e.get("pos", Vector2.ZERO) as Vector2
		var p := _rotate_plan_point(center, p_world, -yaw)
		# Door manifests are world-space; validate the declared local facade.
		var on_edge := false
		match door_edge:
			0: on_edge = absf(p.y - r.position.y) < 0.8
			1: on_edge = absf(p.x - r.end.x) < 0.8
			2: on_edge = absf(p.y - r.end.y) < 0.8
			_: on_edge = absf(p.x - r.position.x) < 0.8
		if not on_edge:
			errs.append("entrance %s not on door_edge %d" % [str(e.get("pos", "")), door_edge])
		if not r.grow(2.0).has_point(p):
			errs.append("entrance %s outside footprint" % str(e.get("pos", "")))
	return errs


static func _check_rural_entrance(spec: Dictionary, ents: Array[Dictionary]) -> Array[String]:
	var errs: Array[String] = []
	var fp: Vector2 = spec.get("footprint", Vector2(8, 10)) as Vector2
	var yaw := float(spec.get("yaw", 0.0))
	var center: Vector2 = spec.get("center", Vector2.ZERO) as Vector2
	var hx := fp.x * 0.5
	var hz := fp.y * 0.5
	for e in ents:
		var w: float = float(e.get("width", 0.0))
		var h: float = float(e.get("height", 0.0))
		if w < WorldConstants.CONTRACT_DOOR_W_MIN or w > WorldConstants.CONTRACT_DOOR_W_MAX:
			errs.append("entrance width %.2f outside human scale" % w)
		if h < WorldConstants.CONTRACT_DOOR_H_MIN or h > WorldConstants.CONTRACT_DOOR_H_MAX:
			errs.append("entrance height %.2f outside human scale" % h)
		var p: Vector2 = e.get("pos", Vector2.ZERO) as Vector2
		var rel := p - center
		var co := cos(-yaw)
		var si := sin(-yaw)
		var local := Vector2(rel.x * co - rel.y * si, rel.x * si + rel.y * co)
		var on_edge := absf(absf(local.x) - hx) < 0.8 or absf(absf(local.y) - hz) < 0.8
		if not on_edge:
			errs.append("entrance %s not on footprint edge" % str(p))
		if absf(local.x) > hx + 0.8 or absf(local.y) > hz + 0.8:
			errs.append("entrance %s outside footprint" % str(p))
	return errs


static func _rooms_rules(spec: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var archetype: StringName = spec.get("archetype", &"") as StringName
	# City specs: the authoritative room manifest is InteriorPlan's (the
	# reference builder materialises exactly this).
	if spec.has("rect"):
		if not spec.has("style"):
			errs.append("city spec missing style")
			return errs
		if spec.get("use", "") != "" or (spec.get("style", {}) as Dictionary).get("room_type", "") != "":
			var InteriorPlanScript = load("res://world/generation/interior_plan.gd")
			var manifest: Dictionary = InteriorPlanScript.build_for_building(spec)
			for e: String in validate_interior_manifest(manifest):
				errs.append("interior: %s" % e)
		return errs
	# Rural specs: plan-produced interior (walls with doorway gaps, furniture).
	var interior: Dictionary = spec.get("interior", {})
	var walls: Array = interior.get("walls", [])
	var furn: Array = interior.get("furniture", [])
	var has_partition := false
	var has_opening := false
	for wd in walls:
		if not has_partition:
			has_partition = true
		if float(wd.get("gap", 0.0)) >= 0.85:
			has_opening = true
	if BuildingArchetype.is_bulk(archetype):
		if walls.is_empty() and furn.is_empty():
			errs.append("bulk building has no interior")
		return errs
	# Non-bulk (house/cottage): real interior program expected. A partition
	# with a doorway opening splits the house into connected rooms; a small
	# one-room cottage is valid when it still carries furniture.
	if has_partition:
		if not has_opening:
			errs.append("interior partition has no doorway opening (rooms disconnected)")
	elif furn.is_empty():
		errs.append("house has no meaningful interior (partition+opening or furniture)")
	return errs


## Rooms/connectivity rules over an InteriorPlan manifest (tamperable in
## tests without touching the spec). Mirrors InteriorPlan.validate plus the
## contract's entry-room reachability reading.
static func validate_interior_manifest(manifest: Dictionary) -> Array[String]:
	var InteriorPlanScript = load("res://world/generation/interior_plan.gd")
	var errs: Array[String] = InteriorPlanScript.validate(manifest)
	# Contract addition: the ENTRANCE floor's rooms must anchor at an entry
	# room; upper floors connect through their own partition graph (no
	# entry flag exists there by construction of InteriorPlan).
	for fl: Dictionary in manifest.get("floors", []):
		if int(fl.get("floor_i", -1)) != 0:
			continue
		var rooms: Array = fl.get("rooms", [])
		if rooms.is_empty():
			continue
		var has_entry := false
		for r in rooms:
			if bool(r.get("entry", false)):
				has_entry = true
				break
		if not has_entry:
			errs.append("floor 0 has no entry room")
	return errs


static func _spec_center(spec: Dictionary) -> Vector2:
	if spec.has("rect"):
		return (spec["rect"] as Rect2).get_center()
	return spec.get("center", Vector2.ZERO) as Vector2


# ---------------------------------------------------------------------------
# BUILD-level rules — city MeshBatcher path
# ---------------------------------------------------------------------------

## Validate one FULL_BUILDING city spec against a filled MeshBatcher.
static func validate_build(spec: Dictionary, b: MeshBatcher) -> Array[String]:
	var errs: Array[String] = []
	var id := str(spec["id"])
	if not b.contract_building_ids().has(id):
		errs.append("FULL_BUILDING %s bypassed the universal assembler (not registered)" % id)
		return errs
	var r: Rect2 = spec["rect"] as Rect2
	var w := r.size.x
	var d := r.size.y
	var floors: int = int(spec.get("floors", 1))
	var fh: float = float(spec.get("floor_h", 3.0))
	var total_h := floors * fh
	var ground: float = float(spec.get("building_ground_y", spec.get("ground_y", 0.0)))
	var inner_w := maxf(w - 2.0 * 0.35, 0.0)
	var inner_d := maxf(d - 2.0 * 0.35, 0.0)
	# --- apertures: no solid geometry behind doors/windows -----------------
	# A sealing violation is a colliding piece whose along-coverage and
	# height-coverage of the aperture both exceed 80% AND whose center lies
	# in the wall band — i.e. real masonry across the opening. Facade
	# dressing (awnings, balconies, pilasters, cornices) projects outside
	# the band or covers less than 80% of the opening, so it never trips.
	var ents: Array[Dictionary] = BuildingSpec.city_entrances(spec)
	for e in ents:
		var region := _aabb_of_entrance(e, spec)
		for s in _building_specs_local(b, id, spec):
			if not bool(s.get("collide", false)):
				continue
			if s.get("material", &"") == &"glass":
				continue
			if _seals_aperture(s, region.center, region.size):
				errs.append("solid geometry behind door %s (box id %d)" % [id, int(s.get("id", -1))])
				break
	# Window apertures (derived with the reference formula).
	var facades_i := [0, 1, 2, 3]
	var horiz := [true, false, true, false]
	for f in floors:
		for side in 4:
			var length := w if horiz[side] else d
			var is_entrance := side == int(spec.get("door_edge", 0)) and f == 0
			var opens: Array[Dictionary] = BuildingSpec.city_window_openings(length, is_entrance)
			for o in opens:
				var oc: float = float(o["c"])
				var wp := BuildingBuilder._side_point(side, w, d, oc)
				var y0 := f * fh
				# _side_point returns BUILDING-LOCAL coords. Keep that point
				# in the local frame used by _building_specs_local(); unlike a
				# door manifest, it has not been rotated into world space.
				var local_region_plan := Vector2(r.position.x + wp.x, r.position.y + wp.y)
				var region_center := Vector3(local_region_plan.x,
						y0 + float(o["bot"]) + float(o["h"]) * 0.5,
						local_region_plan.y)
				var region_size := Vector3(float(o["wd"]) + 0.1, float(o["h"]) - EPS, 0.75)
				if side == 1 or side == 3:
					region_size = Vector3(0.75, float(o["h"]) - EPS, float(o["wd"]) + 0.1)
				for s in _building_specs_local(b, id, spec):
					if not bool(s.get("collide", false)):
						continue
					if s.get("material", &"") == &"glass":
						continue
					if _seals_aperture(s, region_center, region_size):
						errs.append("solid geometry behind window f%d side %d (box id %d)" % [f, side, int(s.get("id", -1))])
						break
	# --- structural walls: >= 4 colliding segments per storey --------------
	for f in floors:
		var wall_count := 0
		var seen_sides := {}
		for s in _building_specs_local(b, id, spec):
			if not bool(s.get("collide", false)):
				continue
			if not _on_storey_layer(b, s, id, f):
				continue
			var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
			if sz.y < fh - 0.3:
				continue
			if sz.y > total_h + 0.3:
				continue
			var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
			var cx := pos.x - r.position.x
			var cz := pos.z - r.position.y
			var side_i := -1
			if absf(cz - 0.175) < 0.35 and sz.z > 0.2:
				side_i = 0
			elif absf(cz - (d - 0.175)) < 0.35 and sz.z > 0.2:
				side_i = 2
			elif absf(cx - (w - 0.175)) < 0.35 and sz.x > 0.2:
				side_i = 1
			elif absf(cx - 0.175) < 0.35 and sz.x > 0.2:
				side_i = 3
			if side_i >= 0:
				wall_count += 1
				seen_sides[side_i] = true
		if wall_count < 4 or seen_sides.size() < 4:
			errs.append("storey %d missing structural walls (%d segments, sides %s)" % [f, wall_count, seen_sides.keys()])
	# --- floor slabs --------------------------------------------------------
	var ground_cover := 0.0
	for s in _building_specs_local(b, id, spec):
		if not bool(s.get("collide", false)):
			continue
		var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
		if absf(sz.y - 0.22) > 0.1:
			continue
		var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
		if absf(pos.y + sz.y * 0.5 - ground) < 0.3:
			ground_cover += sz.x * sz.z
	if ground_cover < 0.55 * inner_w * inner_d:
		errs.append("ground slab missing/insufficient (%.0f%% covered)" % [100.0 * ground_cover / maxf(inner_w * inner_d, 0.01)])
	for lvl in range(1, floors + 1):
		var cover := 0.0
		var cy := ground + lvl * fh
		for s in _building_specs_local(b, id, spec):
			if not bool(s.get("collide", false)):
				continue
			var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
			if absf(sz.y - 0.22) > 0.1:
				continue
			var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
			if absf(pos.y + sz.y * 0.5 - cy) < 0.35:
				cover += sz.x * sz.z
		if cover < 0.38 * inner_w * inner_d:
			errs.append("storey %d slab missing/insufficient (%.0f%% covered)" % [lvl, 100.0 * cover / maxf(inner_w * inner_d, 0.01)])
	# --- roof ---------------------------------------------------------------
	var roof_found := false
	for s in b.specs():
		var layer := str(s.get("layer", ""))
		if layer.begins_with(id + ":roof"):
			roof_found = true
			break
		if bool(s.get("roof", false)):
			var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
			var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
			if pos.y + sz.y * 0.5 > total_h - 0.5:
				roof_found = true
				break
	if not roof_found:
		errs.append("roof missing")
	# --- stairs materialised -------------------------------------------------
	if floors >= 2:
		var ramps := 0
		for s in _building_specs_local(b, id, spec):
			if not bool(s.get("collide", false)):
				continue
			if s.get("material", &"") != &"concrete":
				continue
			var basis: Basis = s.get("basis", Basis.IDENTITY) as Basis
			if basis == Basis.IDENTITY:
				continue
			var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
			if sz.y < 0.15 or sz.z < 2.0:
				continue
			ramps += 1
		if ramps < floors:
			errs.append("stairs not materialised (%d ramps for %d storeys)" % [ramps, floors])
	# --- grounding -----------------------------------------------------------
	var bottom_min := INF
	var top_slab := false
	for s in _building_specs_local(b, id, spec):
		var layer := str(s.get("layer", ""))
		if layer.begins_with(id + ":foundation") or layer.begins_with(id + ":access"):
			continue
		if not bool(s.get("collide", false)):
			continue
		var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
		var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
		bottom_min = minf(bottom_min, pos.y - sz.y * 0.5)
		if absf(sz.y - 0.22) < 0.1 and absf(pos.y + sz.y * 0.5 - ground) < 0.35:
			top_slab = true
	if not top_slab:
		errs.append("structure not touching ground (no grade-flush slab)")
	elif bottom_min < ground - WorldConstants.CONTRACT_GROUND_BURY_TOL_M:
		errs.append("structure buried %.2f m below grade" % (ground - bottom_min))
	elif bottom_min > ground + WorldConstants.CONTRACT_GROUND_FLOAT_TOL_M:
		errs.append("structure floating %.2f m above grade" % (bottom_min - ground))
	return errs


static func _on_storey_layer(b: MeshBatcher, s: Dictionary, id: String, f: int) -> bool:
	var layer := str(s.get("layer", ""))
	var match_key := "%s:f%d" % [id, f]
	if layer == match_key:
		return true
	return layer.begins_with(match_key + ":")


static func _rotate_plan_vector(v: Vector2, yaw: float) -> Vector2:
	var c := cos(yaw)
	var s := sin(yaw)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)


static func _rotate_plan_point(center: Vector2, p: Vector2, yaw: float) -> Vector2:
	return center + _rotate_plan_vector(p - center, yaw)


static func _building_specs_local(b: MeshBatcher, id: String,
		building_spec: Dictionary) -> Array:
	var raw: Array = _building_specs(b, id)
	var yaw := float(building_spec.get("yaw", 0.0))
	if is_zero_approx(yaw):
		return raw
	var rect: Rect2 = building_spec.get("rect", Rect2()) as Rect2
	var center := rect.get_center()
	var origin := Vector3(center.x, 0.0, center.y)
	var inverse_basis := Basis(Vector3.UP, yaw)
	var out: Array = []
	for value in raw:
		var copy: Dictionary = (value as Dictionary).duplicate(true)
		var pos: Vector3 = copy.get("pos", Vector3.ZERO) as Vector3
		copy["pos"] = origin + inverse_basis * (pos - origin)
		var basis: Basis = copy.get("basis", Basis.IDENTITY) as Basis
		copy["basis"] = inverse_basis * basis
		out.append(copy)
	return out


static func _building_specs(b: MeshBatcher, id: String) -> Array:
	var out: Array = []
	for s in b.specs():
		var layer := str(s.get("layer", ""))
		if layer == id or layer.begins_with(id + ":"):
			out.append(s)
	return out


static func _aabb_of_entrance(e: Dictionary, building_spec: Dictionary = {}) -> Dictionary:
	var pos: Vector2 = e.get("pos", Vector2.ZERO) as Vector2
	var w: float = float(e.get("width", 1.5))
	var h: float = float(e.get("height", 2.1))
	var ground: float = float(e.get("ground_y", 0.0))
	var clear := WorldConstants.CONTRACT_APERTURE_CLEAR_M
	var edge := int(e.get("edge", 0))
	# Wall thickness runs along Z for N/S facades, along X for E/W facades.
	var along := Vector3(w + 0.25 * clear, maxf(h - 0.1, 1.0), 0.75)
	if edge == 1 or edge == 3:
		along = Vector3(0.75, maxf(h - 0.1, 1.0), w + 0.25 * clear)
	# Emitted building boxes are normalized into the spec's local frame before
	# aperture scanning. Normalize the manifest point into that same frame.
	if not building_spec.is_empty():
		var r: Rect2 = building_spec.get("rect", Rect2()) as Rect2
		var yaw := float(building_spec.get("yaw", 0.0))
		pos = _rotate_plan_point(r.get_center(), pos, -yaw)
	return {
		"center": Vector3(pos.x, ground + (h - 0.1) * 0.5 + 0.05, pos.y),
		"size": along,
	}


## True when a colliding box SEALS an aperture: its along-coverage and
## height-coverage both exceed 80% AND its thickness interval STRADDLES
## the wall plane (the box's own volume crosses the plane the aperture is
## cut in). Interior partitions, stair rails, balconies and awnings sit
## off-plane or below the coverage thresholds, so they never trip.
static func _seals_aperture(s: Dictionary, center: Vector3, size: Vector3) -> bool:
	var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
	var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
	var basis: Basis = s.get("basis", Basis.IDENTITY) as Basis
	var hx := absf(basis.x.x) * sz.x * 0.5 + absf(basis.z.x) * sz.z * 0.5 \
			+ absf(basis.y.x) * sz.y * 0.5
	var hy := absf(basis.x.y) * sz.x * 0.5 + absf(basis.z.y) * sz.z * 0.5 \
			+ absf(basis.y.y) * sz.y * 0.5
	var hz := absf(basis.x.z) * sz.x * 0.5 + absf(basis.z.z) * sz.z * 0.5 \
			+ absf(basis.y.z) * sz.y * 0.5
	var ox := maxf(0.0, minf(pos.x + hx, center.x + size.x * 0.5) \
			- maxf(pos.x - hx, center.x - size.x * 0.5))
	var oz := maxf(0.0, minf(pos.z + hz, center.z + size.z * 0.5) \
			- maxf(pos.z - hz, center.z - size.z * 0.5))
	var oy := maxf(0.0, minf(pos.y + hy, center.y + size.y * 0.5) \
			- maxf(pos.y - hy, center.y - size.y * 0.5))
	var cov_x := ox / maxf(size.x, 0.001)
	var cov_z := oz / maxf(size.z, 0.001)
	var cov_y := oy / maxf(size.y, 0.001)
	# The ALONG axis is the region's long axis (the aperture's width); the
	# short axis is wall thickness. Taking max() across both would let a
	# corner pier or slab panel — which spans the thickness direction —
	# masquerade as a seal.
	var along_is_x := size.x >= size.z
	var cov_along := cov_x if along_is_x else cov_z
	if cov_along < 0.8 or cov_y < 0.8:
		return false
	# The thickness axis is the region's SHORT axis — the wall's depth
	# direction — and the box must straddle the wall plane on THAT axis.
	# (Do not reuse X for long-axis/thickness: N/S apertures are wide on X,
	# E/W apertures are wide on Z.)
	var thickness_axis := 0 if not along_is_x else 2
	var off: float = pos.z - center.z if thickness_axis == 2 \
			else pos.x - center.x
	var half_t: float = hz if thickness_axis == 2 else hx
	return off - half_t <= 0.08 and off + half_t >= -0.08


static func _aabb_overlaps(s: Dictionary, center: Vector3, size: Vector3) -> bool:
	var pos: Vector3 = s.get("pos", Vector3.ZERO) as Vector3
	var sz: Vector3 = s.get("size", Vector3.ZERO) as Vector3
	var basis: Basis = s.get("basis", Basis.IDENTITY) as Basis
	# Walls/piers/sills/lintels/slabs are axis-aligned; rotated boxes are
	# handled conservatively with their rotated half-extents on XZ.
	var hx := sz.x * 0.5
	var hz := sz.z * 0.5
	if basis != Basis.IDENTITY:
		var b: Basis = basis
		var vx: Vector3 = b.x * sz.x * 0.5
		var vz: Vector3 = b.z * sz.z * 0.5
		hx = absf(vx.x) + absf(vz.x)
		hz = absf(vx.z) + absf(vz.z)
	return absf(pos.x - center.x) < hx + size.x * 0.5 \
			and absf(pos.y - center.y) < sz.y * 0.5 + size.y * 0.5 \
			and absf(pos.z - center.z) < hz + size.z * 0.5


# ---------------------------------------------------------------------------
# BUILD-level rules — rural raw-array path
# ---------------------------------------------------------------------------

## Validate one migrated rural contract house. `evidence` is produced by
## UniversalBuildingAssembler.build_rural_into; the collider arrays are the
## real ConcavePolygonShape face soup, so the door-aperture and wall rules
## scan actual vertices, never just assembler claims.
static func validate_rural_build(b: Dictionary, evidence: Dictionary,
		collider_verts: PackedVector3Array) -> Array[String]:
	var errs: Array[String] = []
	var id := str(b.get("id", ""))
	if not bool(evidence.get("assembled", false)):
		errs.append("FULL_BUILDING %s bypassed the universal assembler (no evidence)" % id)
		return errs
	var center: Vector2 = b.get("center", Vector2.ZERO) as Vector2
	var fp: Vector2 = b.get("footprint", Vector2(8, 10)) as Vector2
	var yaw := float(b.get("yaw", 0.0))
	var ground := float(evidence.get("ground", 0.0))
	var hx := fp.x * 0.5
	var hz := fp.y * 0.5
	var floors := int(evidence.get("floors", b.get("floors", 1)))
	# Door aperture must be EMPTY of collider vertices (world -> local).
	var door_pos: Vector2 = b.get("door_pos", Vector2.ZERO) as Vector2
	var door_w := float(evidence.get("door_width", 1.0))
	var door_h := float(evidence.get("door_height", 2.1))
	var dl := _to_local(door_pos - center, yaw)
	var door_side := 0
	var door_along: float = dl.y
	if absf(dl.x) >= absf(dl.y):
		door_side = 0 if dl.x >= 0.0 else 1
		door_along = dl.y
	else:
		door_side = 2 if dl.y >= 0.0 else 3
		door_along = dl.x
	var aperture := _local_aperture(door_side, door_along, door_w, door_h)
	var plane_perp: float = hx if door_side == 0 else -hx if door_side == 1 \
			else hz if door_side == 2 else -hz
	for v in collider_verts:
		var lv := _to_local(Vector2(v.x, v.z) - center, yaw)
		var perp: float = lv.x if door_side == 0 or door_side == 1 else lv.y
		# Only geometry AT the doorway counts: the wall band plus the leaf
		# swing/approach zone just inside. Deep interior dividers and the
		# opposite facade are legitimately outside the aperture volume.
		if absf(perp - plane_perp) > 1.7 or absf(perp) > maxf(hx, hz) + 0.4:
			continue
		if _point_in_aperture(door_side, lv, v.y, aperture, ground, 0.04):
			errs.append("solid collider geometry inside door aperture of %s (vtx local=(%.3f, %.3f) y=%.3f)" % [id, lv.x, lv.y, v.y])
			break
	# One structural wall per side (collider vertices in each wall band,
	# spanning human height).
	for side in 4:
		var found := false
		for v in collider_verts:
			var lv := _to_local(Vector2(v.x, v.z) - center, yaw)
			if not _in_wall_band(lv, side, hx, hz):
				continue
			var y := v.y - ground
			if y > 0.3 and y < 2.4:
				found = true
				break
		if not found:
			errs.append("side %d missing structural wall" % side)
	# Ground slab: collider vertices on the slab's outer corner ring at
	# grade (slab inset is 0.35 from the footprint, top flush with ground).
	var ground_cover := 0.0
	var upper_cover := 0.0
	var corner_targets: Array[Vector2] = []
	var upper_targets: Array[Vector2] = []
	for sx in [-1.0, 1.0]:
		for sz2 in [-1.0, 1.0]:
			corner_targets.append(Vector2(sx * (hx - 0.35), sz2 * (hz - 0.35)))
			upper_targets.append(Vector2(sx * (hx - 0.21), sz2 * (hz - 0.21)))
	for v in collider_verts:
		var lv := _to_local(Vector2(v.x, v.z) - center, yaw)
		if absf(v.y - ground - (-0.11)) <= 0.25:
			for ct in corner_targets:
				if absf(lv.x - ct.x) < 0.12 and absf(lv.y - ct.y) < 0.12:
					ground_cover += 1.0
					break
		if floors >= 2 and absf(v.y - ground - (4.2 - 0.11)) <= 0.25:
			for ct in upper_targets:
				if absf(lv.x - ct.x) < 0.12 and absf(lv.y - ct.y) < 0.12:
					upper_cover += 1.0
					break
	if ground_cover < 2.0:
		errs.append("ground slab missing (%s)" % id)
	if floors >= 2 and upper_cover < 2.0:
		errs.append("upper floor slab missing (%s)" % id)
	# Roof + interior + ladder evidence.
	if str(evidence.get("roof", "")) != "gabled" or int(evidence.get("roof_quads", 0)) < 2:
		errs.append("roof missing on %s" % id)
	if int(evidence.get("partitions", 0)) < 1 or int(evidence.get("partition_openings", 0)) < 1:
		if int(evidence.get("furniture", 0)) < 1:
			var interior: Dictionary = b.get("interior", {})
			if (interior.get("walls", []) as Array).is_empty() \
					and (interior.get("furniture", []) as Array).is_empty():
				errs.append("no interior program on %s" % id)
	if floors >= 2 and not bool(evidence.get("ladder", false)):
		errs.append("two-storey house missing ladder circulation on %s" % id)
	return errs


static func _to_local(p: Vector2, yaw: float) -> Vector2:
	var co := cos(-yaw)
	var si := sin(-yaw)
	return Vector2(p.x * co - p.y * si, p.x * si + p.y * co)


static func _local_aperture(side: int, along: float, w: float, h: float) -> Dictionary:
	# Returns {a0, a1, y0, y1} in the facade's own local convention
	# (along measured perpendicular to the wall normal axis).
	var half := w * 0.5
	return {"a0": along - half, "a1": along + half, "y0": 0.0, "y1": h}


## True when local vertex (lv, world y) falls inside the door aperture
## volume. Along-axis depends on the facade side; the perpendicular axis
## may be anywhere inside the footprint (a solid piece spanning the room
## at the doorway still counts as blocked).
static func _point_in_aperture(side: int, lv: Vector2, y: float, ap: Dictionary,
		ground: float, eps: float) -> bool:
	var along: float = lv.y if (side == 0 or side == 1) else lv.x
	return along > ap["a0"] + eps and along < ap["a1"] - eps \
			and y > ground + ap["y0"] + 0.05 and y < ground + ap["y1"] - 0.05


static func _in_wall_band(lv: Vector2, side: int, hx: float, hz: float) -> bool:
	match side:
		0: return absf(lv.x - hx) < 0.30 and absf(lv.y) <= hz + 0.05
		1: return absf(lv.x + hx) < 0.30 and absf(lv.y) <= hz + 0.05
		2: return absf(lv.y - hz) < 0.30 and absf(lv.x) <= hx + 0.05
		_: return absf(lv.y + hz) < 0.30 and absf(lv.x) <= hx + 0.05


# ---------------------------------------------------------------------------
# BYPASS detection (anti-trash rule)
# ---------------------------------------------------------------------------

## Scan a city MeshBatcher for colliding geometry tagged with a layer key
## that belongs to NO registered contract building and is not the shared
## infrastructure layer (""). Any hit means some subsystem constructed a
## colliding structure outside the universal assembler.
static func unregistered_structural(b: MeshBatcher,
		registered_ids: Array[String]) -> Array[String]:
	var errs: Array[String] = []
	for s in b.specs():
		if not bool(s.get("collide", false)):
			continue
		var layer := str(s.get("layer", ""))
		if layer == "":
			continue
		var owned := false
		for rid in registered_ids:
			if layer == rid or layer.begins_with(rid + ":"):
				owned = true
				break
		if not owned:
			errs.append("unregistered structural geometry on layer '%s' (box id %d)" % [layer, int(s.get("id", -1))])
	return errs


static func _append_all(errs: Array[String], more: Array[String]) -> Array[String]:
	for e: String in more:
		errs.append(e)
	return errs