class_name SiteSpec
extends RefCounted
## Universal Site Envelope Spec (G10-P2C) — the canonical shape of a plot's
## outdoor envelope: yard surface, fence loop with gates, standing trees.
##
## WHAT/HOW split, exactly like BuildingSpec vs UniversalBuildingAssembler:
## SitePlan decides what a yard IS (this file), a site builder draws it
## (world/streaming). No site builder may invent its own dictionary shape.
##
## A site always belongs to a plot with a building: the yard is the ground the
## building's occupants walk out into, so `building_id` is mandatory and the
## fence must never cross that building.
##
## Not locked to Rect2: `plot` carries a CCW polygon; the rect fast path is
## only the AABB hull of that polygon.

const QUALITIES: Array[StringName] = [&"FULL_SITE", &"DISTANT_LOD", &"DECOR_ONLY"]

## Yard vocabulary. `street_garden` is the strip between frontage and street;
## `farmyard`/`industrial_yard` carry working yards that may hold props.
const KINDS: Array[StringName] = [
	&"courtyard", &"garden", &"backyard", &"farmyard",
	&"street_garden", &"industrial_yard",
]

## Fence vocabulary. `none` is legal and means open ground — but then no post,
## rail or collider may be emitted for it.
const FENCE_STYLES: Array[StringName] = [
	&"none", &"picket", &"palisade", &"hedge", &"stone_wall", &"wire", &"rail",
]

## Yard ground surfaces (material identity only; the builder picks the colour).
const SURFACES: Array[StringName] = [
	&"grass", &"gravel", &"paving", &"dirt", &"cobble", &"crops",
]

## Default fence style per yard kind — courtyards are walled (Prague reality),
## gardens are picket or hedge, working yards are wire or rail.
const DEFAULT_FENCE := {
	&"courtyard": &"stone_wall",
	&"garden": &"picket",
	&"backyard": &"hedge",
	&"farmyard": &"rail",
	&"street_garden": &"hedge",
	&"industrial_yard": &"wire",
}

## Fence height per style (m) — stone walls and palisades are taller than a
## picket or a wire fence; the planner uses this, the validator only checks the
## band, so a builder cannot pick an absurd height either way.
const STYLE_HEIGHT := {
	&"none": 0.0,
	&"picket": 1.15,
	&"palisade": 2.20,
	&"hedge": 1.60,
	&"stone_wall": 1.85,
	&"wire": 1.25,
	&"rail": 1.10,
}

const DEFAULT_SURFACE := {
	&"courtyard": &"paving",
	&"garden": &"grass",
	&"backyard": &"dirt",
	&"farmyard": &"dirt",
	&"street_garden": &"cobble",
	&"industrial_yard": &"gravel",
}


## Canonicalise a raw site dictionary: fill defaults, coerce types, drop
## nothing. Missing mandatory keys stay missing so the validator can reject
## them by name instead of silently inventing a site.
static func normalize(spec: Dictionary, source: StringName = &"") -> Dictionary:
	var out := spec.duplicate(true)
	out["id"] = str(spec.get("id", ""))
	out["quality"] = StringName(spec.get("quality", &"FULL_SITE"))
	out["kind"] = StringName(spec.get("kind", &""))
	out["building_id"] = str(spec.get("building_id", ""))
	out["surface"] = StringName(spec.get("surface", DEFAULT_SURFACE.get(out["kind"], &"grass")))
	if spec.has("surface"):
		out["surface"] = StringName(spec["surface"])
	if not spec.has("plot"):
		out["plot"] = PackedVector2Array()
	else:
		out["plot"] = _as_polygon(spec["plot"])
	if not spec.has("building_rect"):
		out["building_rect"] = Rect2()
	else:
		out["building_rect"] = _as_rect(spec["building_rect"])
	if spec.has("area_m2"):
		out["area_m2"] = float(spec["area_m2"])
	else:
		out["area_m2"] = polygon_area(out["plot"])
	# fence: normalize the nested dictionary, default the style from the kind.
	var fence_in: Dictionary = spec.get("fence", {}) if spec.get("fence", {}) is Dictionary else {}
	var style := StringName(fence_in.get("style", DEFAULT_FENCE.get(out["kind"], &"none")))
	if not fence_in.has("style"):
		style = StringName(DEFAULT_FENCE.get(out["kind"], &"none"))
	var loop := PackedVector2Array()
	if fence_in.has("loop"):
		loop = _ring(_as_polygon(fence_in["loop"]))
	var gates: Array = []
	if fence_in.has("gates"):
		for g: Variant in fence_in["gates"]:
			if g is Dictionary:
				gates.append(_gate(g))
	out["fence"] = {
		"style": style,
		"height": float(fence_in.get("height", STYLE_HEIGHT.get(style, 1.4))),
		"post_spacing": float(fence_in.get("post_spacing", 2.4)),
		"loop": loop,
		"gates": gates,
	}
	# trees: every entry gets an id, a radius and a sway phase so a builder
	# never has to invent one (phase keeps wind deterministic per tree).
	var trees: Array = []
	var ti := 0
	if spec.has("trees"):
		for t: Variant in spec["trees"]:
			if not (t is Dictionary):
				continue
			var tr: Dictionary = (t as Dictionary).duplicate(true)
			tr["id"] = str(tr.get("id", "%s_tree_%d" % [out["id"], ti]))
			tr["species"] = StringName(tr.get("species", &"linden"))
			tr["pos"] = _as_vec2(tr.get("pos", Vector2.ZERO))
			tr["radius"] = float(tr.get("radius", tree_radius(tr["species"])))
			tr["phase"] = float(tr.get("phase", 0.0))
			trees.append(tr)
			ti += 1
	out["trees"] = trees
	# entrances carried from the building spec: the fence must gate them.
	var ents: Array = []
	if spec.has("entrances"):
		for e: Variant in spec["entrances"]:
			if not (e is Dictionary):
				continue
			var en: Dictionary = e
			ents.append({
				"id": str(en.get("id", "")),
				"pos": _as_vec2(en.get("pos", Vector2.ZERO)),
			})
	out["entrances"] = ents
	if spec.has("ground_y"):
		out["ground_y"] = float(spec["ground_y"])
	if source != &"":
		out["source"] = source
	return out


## A fence loop is a RING: the planner emits it implicitly closed, so a
## duplicated final vertex is dropped here. Otherwise every consumer would have
## to guess whether a repeated point is a closure or a zero-length post gap.
static func _ring(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() >= 2 and pts[0].distance_to(pts[pts.size() - 1]) <= WorldConstants.SITE_FENCE_CLOSE_TOL_M:
		var out := PackedVector2Array()
		for i in range(pts.size() - 1):
			out.append(pts[i])
		return out
	return pts


static func _as_polygon(v: Variant) -> PackedVector2Array:
	if v is PackedVector2Array:
		return v
	var out := PackedVector2Array()
	if v is Array:
		for p: Variant in v:
			out.append(_as_vec2(p))
	return out


static func _as_rect(v: Variant) -> Rect2:
	if v is Rect2:
		return v
	if v is Array and (v as Array).size() == 4:
		return Rect2(v[0], v[1], v[2], v[3])
	return Rect2()


static func _as_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Vector3:
		return Vector2((v as Vector3).x, (v as Vector3).z)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(v[0], v[1])
	return Vector2.ZERO


static func _gate(g: Dictionary) -> Dictionary:
	return {
		"id": str(g.get("id", "")),
		"center": _as_vec2(g.get("center", Vector2.ZERO)),
		"width": float(g.get("width", 1.2)),
		"for_entrance": str(g.get("for_entrance", "")),
	}


## Yard ground area (m2) from the plot polygon — the yard IS the plot here;
## a building sitting in it is removed by the plot cutter, not by this maths.
static func polygon_area(pts: PackedVector2Array) -> float:
	return BuildingSpec.polygon_area(pts)


static func yard_area(spec: Dictionary) -> float:
	if spec.has("area_m2"):
		return float(spec["area_m2"])
	return polygon_area(_as_polygon(spec.get("plot", PackedVector2Array())))


## Fence loop perimeter (m); 0.0 when the loop is not a usable ring.
static func fence_perimeter(loop: PackedVector2Array) -> float:
	if loop.size() < 2:
		return 0.0
	var total := 0.0
	for i in range(loop.size()):
		total += loop[i].distance_to(loop[(i + 1) % loop.size()])
	return total


static func fence_of(spec: Dictionary) -> Dictionary:
	return spec.get("fence", {}) if spec.get("fence", {}) is Dictionary else {}


static func fence_style(spec: Dictionary) -> StringName:
	return StringName(fence_of(spec).get("style", &"none"))


static func fence_loop(spec: Dictionary) -> PackedVector2Array:
	return _as_polygon(fence_of(spec).get("loop", PackedVector2Array()))


static func gates_of(spec: Dictionary) -> Array:
	var g: Variant = fence_of(spec).get("gates", [])
	return g if g is Array else []


static func trees_of(spec: Dictionary) -> Array:
	var t: Variant = spec.get("trees", [])
	return t if t is Array else []


static func entrances_of(spec: Dictionary) -> Array:
	var e: Variant = spec.get("entrances", [])
	return e if e is Array else []


## Crown radius a standing tree occupies, from the species table's r_max.
static func tree_radius(species: StringName) -> float:
	var row: Dictionary = TreeBuilder.SPECIES.get(species, {})
	return float(row.get("r_max", 0.30)) * WorldConstants.SITE_TREE_RADIUS_FACTOR


## Species standing in a Czech city yard. `index` is a deterministic slot so
## the same plot always plants the same trees; it must not be a free RNG call.
const YARD_SPECIES: Array[StringName] = [
	&"linden", &"oak", &"maple", &"birch", &"chestnut", &"linden", &"ash", &"beech",
]


static func species_for_slot(index: int) -> StringName:
	if YARD_SPECIES.is_empty():
		return &"linden"
	return YARD_SPECIES[absi(index) % YARD_SPECIES.size()]
