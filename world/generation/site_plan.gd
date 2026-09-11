class_name SitePlan
extends RefCounted
## Site Envelope Plan (G10-P2C) — decides WHAT outdoor envelope each real plot
## gets, purely and deterministically, from the plans that already own the
## ground: CityPlan's courtyard/garden regions and FringePlan's yards.
##
## This file never draws anything. It answers with canonical SiteSpec
## dictionaries (see world/generation/site_spec.gd) that
## SiteContractValidator can prove and a site builder can later materialize,
## which is the same WHAT/HOW split the building contract uses.
##
## Sources of truth reused instead of invented:
##   - plot polygon   : CityPlan.garden_regions_in_rect() (already clipped
##                      around the houses, so a fence on it cannot cross one)
##   - building + door: the region's nearest city building, whose door
##                      position is already in world space
##   - trees          : FringePlan.trees_in() where the fringe already planted
##                      them; city yards seed their own from the species table
##
## Determinism: every random draw goes through WorldSeed.rng_for_seed() with a
## `site*` domain, so two plans with the same seed agree vertex for vertex and
## a seed change moves trees and fence styles, not the layout.

## RNG domains owned by this layer — registered so a domain audit can see them.
const DOMAINS: Array[StringName] = [
	&"site_variant", &"site_fence", &"site_gate", &"site_tree", &"site_tree_pos",
]

## How far a plot may sit from a building and still count as its yard (m).
const BUILDING_SEARCH_PAD_M := 18.0

## Cached terrain sampler: the site records ground_y when a surface is known,
## so the validator can prove a yard is grounded without owning the terrain.
var surface_fn: Callable = Callable()

var seed_used: int
var city: CityPlan
var fringe: FringePlan

var _stats := {
	"city_regions": 0, "city_sites": 0, "city_skipped": 0,
	"fringe_yards": 0, "fringe_sites": 0, "fringe_skipped": 0,
	"trees": 0, "trees_dropped": 0, "gates": 0, "fenced": 0,
	"sites_capped": 0,
}


func _init(seed_used_: int = WorldSeed.get_world_seed(), city_: CityPlan = null,
		fringe_: FringePlan = null, surface_fn_: Callable = Callable()) -> void:
	seed_used = seed_used_
	city = city_ if city_ != null else CityPlan.new(seed_used)
	fringe = fringe_
	surface_fn = surface_fn_


## Sites intersecting `rect`, sorted by id so callers get a stable order.
## Capped per query: the fence/tree layer is decoration, never a budget owner.
func sites_in_rect(rect: Rect2) -> Array[Dictionary]:
	var all: Array[Dictionary] = []
	all.append_array(city_sites_in(rect))
	all.append_array(fringe_sites_in(rect))
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	var capped: Array[Dictionary] = []
	for s: Dictionary in all:
		if capped.size() >= WorldConstants.SITE_MAX_PER_RECT:
			_stats["sites_capped"] = int(_stats["sites_capped"]) + (all.size() - capped.size())
			break
		capped.append(s)
	var budget := WorldConstants.SITE_MAX_TREES_PER_RECT
	var kept := 0
	for s: Dictionary in capped:
		var trees: Array = SiteSpec.trees_of(s)
		var room := maxi(budget - kept, 0)
		if trees.size() > room:
			_stats["trees_dropped"] = int(_stats["trees_dropped"]) + (trees.size() - room)
			trees = trees.slice(0, room)
			s["trees"] = trees
		kept += trees.size()
	return capped


func stats() -> Dictionary:
	var out := _stats.duplicate()
	out["domains"] = DOMAINS.size()
	return out


func reset_stats() -> void:
	for k: String in _stats.keys():
		_stats[k] = 0


# ------------------------------------------------------------------- city side

## Diagnostic: how many raw CityPlan yard/courtyard regions a walk touches,
## whether or not a plot building claimed them. Distinguishes "no regions here"
## from "regions rejected by the plot rules".
func raw_region_count(rects: Array[Rect2]) -> int:
	var n := 0
	if city == null:
		return 0
	for r: Rect2 in rects:
		n += city.courtyard_regions_in_rect(r).size()
	return n


## Yards behind the city street wall: enclosed courtyards and street gardens.
func city_sites_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if city == null:
		return out
	for region: Dictionary in city.courtyard_regions_in_rect(rect):
		_stats["city_regions"] = int(_stats["city_regions"]) + 1
		var site := _city_site(region)
		if site.is_empty():
			_stats["city_skipped"] = int(_stats["city_skipped"]) + 1
			continue
		_stats["city_sites"] = int(_stats["city_sites"]) + 1
		out.append(site)
	return out


func _city_site(region: Dictionary) -> Dictionary:
	var plot: PackedVector2Array = region.get("polygon", PackedVector2Array()) as PackedVector2Array
	if plot.size() < 3:
		return {}
	var area := float(region.get("area_m2", absf(BuildingSpec.polygon_area(plot))))
	if area < WorldConstants.SITE_MIN_YARD_AREA_M2:
		return {}
	var center: Vector2 = region.get("center", _centroid(plot)) as Vector2

	# The plot's building: nearest city house whose door is close enough to
	# serve this yard. A residual with no house behind it is not a site.
	var box := _aabb(plot).grow(BUILDING_SEARCH_PAD_M)
	var best := {}
	var best_d := INF
	for b: Dictionary in city.buildings_in_rect(box):
		var doors: Array = b.get("doors", []) as Array
		if doors.is_empty():
			continue
		var d: Dictionary = doors[0] as Dictionary
		var dp := _door_pos(d)
		var dist := dp.distance_to(center)
		if dist < best_d:
			best_d = dist
			best = b
	if best.is_empty() or best_d > BUILDING_SEARCH_PAD_M + maxf(area, 1.0) * 0.25:
		return {}
	var bid := str(best.get("id", ""))
	if bid == "":
		return {}

	var kind := _city_kind(region)
	var style := StringName(SiteSpec.DEFAULT_FENCE.get(kind, &"stone_wall"))
	var loop := SiteSpec._ring(plot)
	var gates := _gates_for(loop, _doors_of(best), area)
	var site := {
		"id": "site_%s" % bid,
		"quality": &"FULL_SITE",
		"kind": kind,
		"building_id": bid,
		"building_rect": _world_rect(best),
		"plot": plot,
		"area_m2": area,
		"surface": SiteSpec.DEFAULT_SURFACE.get(kind, &"grass"),
		"fence": {
			"style": style,
			"height": float(SiteSpec.STYLE_HEIGHT.get(style, 1.4)),
			"post_spacing": 1.6 if style == &"picket" else 2.4,
			"loop": loop,
			"gates": gates,
		},
		"trees": _city_trees(plot, center, area, best, bid),
		"entrances": _entrances_of(best),
	}
	if surface_fn.is_valid():
		site["ground_y"] = float(surface_fn.call(center))
	_stats["fenced"] = int(_stats["fenced"]) + (1 if style != &"none" else 0)
	_stats["gates"] = int(_stats["gates"]) + gates.size()
	_stats["trees"] = int(_stats["trees"]) + (site["trees"] as Array).size()
	return SiteSpec.normalize(site, &"city_region")


func _city_kind(region: Dictionary) -> StringName:
	if StringName(region.get("access_kind", &"")) == &"street_garden":
		return &"street_garden"
	var k := StringName(region.get("kind", &"courtyard"))
	if k == &"garden":
		return &"garden"
	return &"courtyard"


## A gate is cut on the loop at the point nearest a door the yard serves: the
## fence opens where people actually walk out.
func _gates_for(loop: PackedVector2Array, doors: Array, area: float) -> Array:
	var gates: Array = []
	if loop.size() < 3:
		return gates
	var used := {}
	for d: Variant in doors:
		var dp := _door_pos(d as Dictionary)
		var at := _nearest_loop_point(loop, dp)
		var key := "%d_%d" % [roundi(at.x), roundi(at.y)]
		if used.has(key):
			continue
		used[key] = true
		gates.append({
			"id": "gate_%s" % key,
			"center": at,
			"width": 1.2,
			"for_entrance": str((d as Dictionary).get("id", "")),
		})
	if gates.is_empty():
		# A walled yard with no house door on it still needs a way in: open it
		# on the loop point farthest from the plot centre, i.e. the street side.
		var c := _centroid(loop)
		var far := _nearest_loop_point(loop, c + Vector2(area, area))
		gates.append({"id": "gate_entry", "center": far, "width": 1.2, "for_entrance": ""})
	return gates


## Yard trees: seeded from the species table, accepted only when they clear the
## house and each other, so the validator's spacing rules hold by construction.
func _city_trees(plot: PackedVector2Array, center: Vector2, area: float,
		building: Dictionary, bid: String) -> Array:
	var trees: Array = []
	var want := clampi(int(area / WorldConstants.SITE_TREE_AREA_PER_TREE_M2), 0,
		WorldConstants.SITE_MAX_TREES_PER_SITE)
	if want <= 0:
		return trees
	var rng := _rng("site_tree_pos", [bid])
	var rect := _world_rect(building)
	var reach := 0.0
	for p in plot:
		reach = maxf(reach, center.distance_to(p))
	for i in range(want):
		var placed := false
		for attempt in range(24):
			var r := sqrt(rng.randf()) * reach * 0.92
			var a := rng.randf() * TAU
			var p := center + Vector2(cos(a), sin(a)) * r
			if not Geometry2D.is_point_in_polygon(p, plot):
				continue
			if rect.get_area() > 0.0 and _dist_point_rect(p, rect) < WorldConstants.SITE_TREE_BUILDING_CLEAR_M:
				continue
			var ok := true
			for t: Variant in trees:
				var tp := SiteSpec._as_vec2((t as Dictionary)["pos"])
				if p.distance_to(tp) - float((t as Dictionary)["radius"]) - 0.4 < WorldConstants.SITE_TREE_TREE_CLEAR_M - 0.4:
					ok = false
					break
			if not ok:
				continue
			var species := SiteSpec.species_for_slot(rng.randi_range(0, 7))
			var tree := {
				"id": "%s_tree_%d" % [bid, i],
				"species": species,
				"pos": p,
				"radius": SiteSpec.tree_radius(species),
				"phase": _rng("site_tree", [bid, i]).randf(),
			}
			if surface_fn.is_valid():
				tree["ground_y"] = float(surface_fn.call(p))
			trees.append(tree)
			placed = true
			break
		if not placed:
			continue
	return trees


# ----------------------------------------------------------------- fringe side

## Working yards of the fringe: the residential yards behind fringe houses and
## the inn yards, which already carry planted trees.
func fringe_sites_in(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if fringe == null:
		return out
	for yard: Dictionary in fringe.yards_in(rect):
		_stats["fringe_yards"] = int(_stats["fringe_yards"]) + 1
		var site := _fringe_site(yard)
		if site.is_empty():
			_stats["fringe_skipped"] = int(_stats["fringe_skipped"]) + 1
			continue
		_stats["fringe_sites"] = int(_stats["fringe_sites"]) + 1
		out.append(site)
	return out


func _fringe_site(yard: Dictionary) -> Dictionary:
	var r: Rect2 = yard.get("rect", Rect2()) as Rect2
	if r.get_area() < WorldConstants.SITE_MIN_YARD_AREA_M2:
		return {}
	var kind := StringName(yard.get("kind", &"residential_yard"))
	var site_kind := &"backyard"
	if kind == &"inn_yard" or kind == &"courtyard":
		site_kind = &"courtyard"
	elif kind != &"residential_yard":
		return {}
	var owner := str(yard.get("building_id", yard.get("landmark_id", "")))
	if owner == "":
		return {}
	var plot := PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
	])
	var style := StringName(SiteSpec.DEFAULT_FENCE.get(site_kind, &"hedge"))
	var loop := SiteSpec._ring(plot)
	var building := _fringe_building_for(yard)
	var gates := _gates_for(loop, _doors_of(building), r.get_area())
	var trees := _fringe_trees(yard, r, building, owner)
	var site := {
		"id": "site_%s" % str(yard.get("id", owner)),
		"quality": &"FULL_SITE",
		"kind": site_kind,
		"building_id": owner,
		"building_rect": _world_rect(building) if not building.is_empty() else Rect2(),
		"plot": plot,
		"area_m2": r.get_area(),
		"surface": SiteSpec.DEFAULT_SURFACE.get(site_kind, &"dirt"),
		"fence": {
			"style": style,
			"height": float(SiteSpec.STYLE_HEIGHT.get(style, 1.4)),
			"post_spacing": 2.6,
			"loop": loop,
			"gates": gates,
		},
		"trees": trees,
		"entrances": _entrances_of(building),
	}
	if surface_fn.is_valid():
		site["ground_y"] = float(surface_fn.call(r.get_center()))
	_stats["fenced"] = int(_stats["fenced"]) + (1 if style != &"none" else 0)
	_stats["gates"] = int(_stats["gates"]) + gates.size()
	_stats["trees"] = int(_stats["trees"]) + trees.size()
	return SiteSpec.normalize(site, &"fringe_yard")


func _fringe_building_for(yard: Dictionary) -> Dictionary:
	if fringe == null:
		return {}
	var bid := str(yard.get("building_id", ""))
	if bid != "":
		var b := fringe.building_for_id(bid)
		if not b.is_empty():
			return b
	var center: Vector2 = yard.get("center", (yard.get("rect", Rect2()) as Rect2).get_center()) as Vector2
	var lm := str(yard.get("landmark_id", ""))
	if lm != "":
		for landmark: Dictionary in fringe.landmarks_in(Rect2(center - Vector2(40, 40), Vector2(80, 80))):
			if str(landmark.get("id", "")) == lm:
				return landmark
	return {}


## Trees the fringe already planted inside this yard keep their species; any
## that violate the clearance rules are dropped rather than moved, so the
## site never contradicts the planting pass that made them.
func _fringe_trees(yard: Dictionary, r: Rect2, building: Dictionary, owner: String) -> Array:
	var trees: Array = []
	if fringe == null:
		return trees
	var rect := _world_rect(building) if not building.is_empty() else Rect2()
	for t: Dictionary in fringe.trees_in(r):
		if str(t.get("yard_id", str(yard.get("id", "")))) != str(yard.get("id", "")):
			continue
		var p := SiteSpec._as_vec2(t.get("pos", Vector2.ZERO))
		if not r.has_point(p):
			continue
		if rect.get_area() > 0.0 and _dist_point_rect(p, rect) < WorldConstants.SITE_TREE_BUILDING_CLEAR_M:
			_stats["trees_dropped"] = int(_stats["trees_dropped"]) + 1
			continue
		var species := StringName(t.get("kind", &"beech"))
		if not TreeBuilder.SPECIES.has(species):
			species = &"beech"
		var radius := SiteSpec.tree_radius(species)
		var clash := false
		for o: Variant in trees:
			var op := SiteSpec._as_vec2((o as Dictionary)["pos"])
			if p.distance_to(op) - radius - float((o as Dictionary)["radius"]) < WorldConstants.SITE_TREE_TREE_CLEAR_M - radius - float((o as Dictionary)["radius"]):
				clash = true
				break
		if clash:
			_stats["trees_dropped"] = int(_stats["trees_dropped"]) + 1
			continue
		if trees.size() >= WorldConstants.SITE_MAX_TREES_PER_SITE:
			_stats["trees_dropped"] = int(_stats["trees_dropped"]) + 1
			continue
		var tree := {
			"id": str(t.get("id", "fringe_tree")),
			"species": species,
			"pos": p,
			"radius": radius,
			"phase": _rng("site_tree", [str(yard.get("id", owner)), trees.size()]).randf(),
		}
		if surface_fn.is_valid():
			tree["ground_y"] = float(surface_fn.call(p))
		trees.append(tree)
	return trees


# -------------------------------------------------------------------- helpers

func _rng(domain: String, parts: Array = []) -> RandomNumberGenerator:
	# WorldSeed.combine() mixes INTEGERS only (`for p: int in parts`), so a raw
	# String part (a plot or building id) is a type error that poisons the seed.
	# Hash string parts instead of handing them over.
	var ints: Array = []
	for p: Variant in parts:
		if p is int:
			ints.append(p)
		elif p is String or p is StringName:
			ints.append(WorldSeed.str_hash(String(p)))
		else:
			ints.append(int(p))
	return WorldSeed.rng_for_seed(seed_used, domain, ints)


## Diagnostic: block fabric extent, so a caller can tell "the city is not where
## I am looking" from "the city has no courtyard regions at all".
func block_extent() -> Rect2:
	if city == null:
		return Rect2()
	var blocks: Array = city._blocks
	if blocks.is_empty():
		return Rect2()
	var first: Vector2 = (blocks[0] as Dictionary).get("center", Vector2.ZERO) as Vector2
	var box := Rect2(first, Vector2.ZERO)
	var regions := 0
	for b: Dictionary in blocks:
		box = box.expand(b.get("center", Vector2.ZERO) as Vector2)
		regions += (b.get("courtyard_regions", []) as Array).size()
	_last_block_count = blocks.size()
	_last_region_total = regions
	return box

var _last_block_count := 0
var _last_region_total := 0

func block_count() -> int:
	return _last_block_count

func region_total() -> int:
	return _last_region_total


func _doors_of(building: Dictionary) -> Array:
	var d: Variant = building.get("doors", [])
	if d is Array and not (d as Array).is_empty():
		return d
	var single: Variant = building.get("door", {})
	if single is Dictionary and not (single as Dictionary).is_empty():
		return [single]
	return []


func _door_pos(door: Dictionary) -> Vector2:
	var p: Variant = door.get("position", door.get("pos", Vector2.ZERO))
	if p is Vector3:
		return Vector2((p as Vector3).x, (p as Vector3).z)
	return SiteSpec._as_vec2(p)


func _entrances_of(building: Dictionary) -> Array:
	var out: Array = []
	for d: Variant in _doors_of(building):
		var dd: Dictionary = d
		out.append({
			"id": str(dd.get("id", "door")),
			"pos": _door_pos(dd),
		})
	return out


## World-space AABB of a building spec (rect + yaw), matching how the plan
## itself places lots: rotate the lot corners about the lot centre.
func _world_rect(spec: Dictionary) -> Rect2:
	if spec.is_empty():
		return Rect2()
	var r: Rect2 = spec.get("rect", Rect2()) as Rect2
	if r.get_area() <= 0.0:
		return Rect2()
	var yaw := float(spec.get("yaw", 0.0))
	var c := r.get_center()
	var pts := PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
	])
	if is_zero_approx(yaw):
		return r
	var out := PackedVector2Array()
	for p in pts:
		out.append(c + (p - c).rotated(yaw))
	return _aabb(out)


func _aabb(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


func _centroid(pts: PackedVector2Array) -> Vector2:
	if pts.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in pts:
		sum += p
	return sum / float(pts.size())


func _nearest_loop_point(loop: PackedVector2Array, p: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_d := INF
	for i in range(loop.size()):
		var a := loop[i]
		var b := loop[(i + 1) % loop.size()]
		var near := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := near.distance_to(p)
		if d < best_d:
			best_d = d
			best = near
	return best


func _dist_point_rect(p: Vector2, r: Rect2) -> float:
	if r.has_point(p):
		return 0.0
	var dx := maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dy := maxf(maxf(r.position.y - p.y, 0.0), p.y - r.end.y)
	return Vector2(dx, dy).length()
