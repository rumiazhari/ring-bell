class_name MeshBatcher
extends RefCounted
## Accumulates boxes during chunk generation and flushes them into a MINIMAL
## set of scene nodes: per-LAYER vertex-colored ArrayMeshes (street, building
## storeys, roof dressing - see push_layer) + one StaticBody3D holding every
## collision shape.
##
## WHY: a streamed city produces tens of thousands of decorative boxes; giving
## each its own MeshInstance3D would drown renderer and culler. The batcher
## keeps node counts at ~2 per chunk regardless of prop density, and purely
## decorative objects never get scripted nodes at all.
##
## VOXEL DESTRUCTION: every box is stored as a SPEC with an id; geometry is
## generated lazily at flush time from the spec list. Destroying a box
## (destroy_box) removes it from future meshes AND lets the chunk disable its
## CollisionShape3D - so blasts punch real, walk-through holes in buildings,
## then refresh_meshes() re-bakes the chunk mesh without the missing voxels.
##
## WINDING: verified against BoxMesh.get_mesh_arrays() - Godot front faces wind
## CLOCKWISE seen from outside, so natural CCW quads are emitted index-reversed.
##
## Determinism: entry order -> identical meshes and ids. ChunkBuilder adds
## boxes in plan-derived order only (never iterating unsorted dictionaries).

## Interior wall cut (see reveal_layer_hidden / wall_cut_hidden). An interior
## wall's plaster above the picture rail lives in its own layer keyed
## "<tag>:f<floor>:wallcut:<x_z_w_h>"; the gate cuts it only while the camera
## actually looks through that wall at the player.
const WALL_CUT_PREFIX := "wallcut:"
## Ceiling caps are keyed the same way and hidden only for the room the player
## occupies (see ceiling_cut_hidden).
const CEIL_CUT_PREFIX := "ceilcut:"
## Half-width of the camera's view wedge at the player, in metres. A wall inside
## that wedge blocks the sightline; anything wider cuts walls the camera never
## looks through.
const WALL_CUT_WEDGE_M := 1.4

var _specs: Array[Dictionary] = []     # {id,pos,size,basis,color,collide,roof,material,layer}
var generation_seed: int = WorldSeed.get_world_seed()

func rng_for(purpose: String, parts: Array = []) -> RandomNumberGenerator:
	return WorldSeed.rng_for_seed(generation_seed, purpose, parts)

var _polygon_specs: Array[Dictionary] = [] # visual ground polygons: {points,y,color,layer}
var _prepared_layers: Dictionary = {}
var _box_shapes: Dictionary = {} # immutable size -> BoxShape3D, per batcher
var _inactive_body: StaticBody3D
## Debug switch: print a flush phase breakdown (set by probes only).
static var debug_profile := false

static var _opaque_material: ShaderMaterial
static var _tile_array: Texture2DArray
static var _transparent_material: StandardMaterial3D
static var _paving_materials: Dictionary = {}
var _asset_instances: Array[Dictionary] = [] # {pos,size,color,res_path,scale,has_collision,yaw,layer,building_id,floor_i}
var _asset_nodes: Array[Node3D] = []     # materialized asset nodes, keyed by layer metadata
var _street_lights: Array[Vector3] = []  # Phase S: streamed-city streetlamp OmniLight positions
var _window_glows: Array[Vector3] = []   # Phase U: interior window glow positions
## Post-apocalypse interior lights: gas lamps and hearths inside buildings.
## Each entry: {pos, kind ("gas"|"fire"), dead, flicker, phase}. ChunkBuilder
## turns these into OmniLight3D with a per-chunk cap.
var _interior_lights: Array[Dictionary] = []

# Phase W: flicker/dead-lamp variant — deterministic subset sputters or stays dark.
const STREET_DEAD_PROB := 0.035        # 3.5% dead (within 2-4% spec)
const STREET_FLICKER_PROB := 0.18      # 18% of live historic lamps sputter
const STREET_FLICKER_AMPL := 0.18
const STREET_FLICKER_FREQ := 3.0
var _street_lamp_dead: Array[bool] = []     # parallel to _street_lights: true = dead (dark)
var _street_lamp_flicker: Array[bool] = []  # parallel: true = sputtery
var _street_lamp_phase: Array[float] = []   # parallel: 0-1 phase for flicker
var _destroyed := {}                   # id -> true
var _colliders: Array[Dictionary] = [] # {pos,size,basis,id,material}
var _prop_defs: Array[Dictionary] = [] # dynamic DestructibleProp manifests
var _box_count := 0

var _layers: Array[String] = [""]
var layer_nodes := {}                  # layer key -> MeshInstance3D

var _parent: Node3D
var _shape_nodes: Dictionary = {}      # vox_id -> CollisionShape3D
var _building_transform_stack: Array[Dictionary] = []
## Atlas tiles (must match tools/gen_surface_atlas.py TILE order).
const TILE_PLASTER_FINE := 0
const TILE_PLASTER_COARSE := 1
const TILE_PLASTER_DAMAGED := 2
const TILE_BRICK := 3
const TILE_STONE_RUBBLE := 4
const TILE_WOOD_PALE := 5
const TILE_WOOD_DARK := 6
const TILE_FLOORBOARD := 7
const TILE_TILE_CHECKER := 8
const TILE_COBBLE := 9
const TILE_SLATE := 10
const TILE_RUST_METAL := 11
const TILE_MOSS := 12
const TILE_GRIME := 13
const TILE_GLASS := 14
const TILE_RENDER_GREY := 15
const TILE_SETTS := 16          # street surface: small granite setts
const TILE_PAVING_SLAB := 17    # pavement: large stone slabs
const TILE_DIRT_GROUND := 18    # bare city ground: compacted earth + gravel
const TILE_WALLPAPER := 19      # Victorian wall covering
const TILE_GRASS := 20          # terrain: grazed meadow / lawn
const TILE_MEADOW_DRY := 21     # terrain: dry upland grass
const TILE_SOIL := 22           # terrain: bare / alluvial soil
const TILE_ROCK := 23           # terrain: exposed rock
## Atlas geometry - must match tools/gen_surface_atlas.py.
const ATLAS_COLS := 4
const ATLAS_ROWS := 6
const ATLAS_TILE_PX := 512
const ATLAS_PATH := "res://world/streaming/surface_atlas.png"
## Total tiles in the atlas (4 x 5 grid).
const TILE_COUNT := 24

## How many world metres one atlas tile spans, per tile. Surfaces with fine
## structure (wood grain, rust) tile small; plaster tiles large so it reads as
## a surface rather than noise.
static func tile_span(tile: int) -> float:
	match tile:
		TILE_WOOD_PALE, TILE_WOOD_DARK, TILE_RUST_METAL:
			return 0.9
		TILE_SLATE, TILE_COBBLE:
			return 1.2
		TILE_BRICK, TILE_STONE_RUBBLE, TILE_TILE_CHECKER:
			return 1.8
		TILE_SETTS:
			return 1.2      # 10 setts per tile -> ~12 cm stones
		TILE_PAVING_SLAB:
			return 3.0      # slabs are half a tile -> ~1.5 m slabs
		TILE_DIRT_GROUND:
			return 4.0
		TILE_GRASS, TILE_MEADOW_DRY:
			return 2.2      # clumps read at a human scale, not as a green wash
		TILE_SOIL:
			return 3.0
		TILE_ROCK:
			return 3.2
		TILE_FLOORBOARD, TILE_GLASS, TILE_MOSS:
			return 2.4
		_:
			return 3.2   # plaster / render / grime


## Surface stack: the atlas tile for the geometry currently being generated.
## Builders push the right surface around a group of boxes (roof, floor,
## panelling...); anything without an explicit hint is auto-detected from the
## box colour and role, so untouched call sites still get sensible detail.
var _surface_stack: Array[int] = []


func push_surface(tile: int) -> void:
	_surface_stack.append(tile)


func pop_surface() -> void:
	if not _surface_stack.is_empty():
		_surface_stack.pop_back()


## Pick the atlas tile for a box: explicit hint, else inferred from the spec.
func _tile_for(spec: Dictionary, col: Color) -> int:
	if not _surface_stack.is_empty():
		return _surface_stack.back()
	var mat: StringName = spec["material"]
	if mat == &"glass":
		return TILE_GLASS
	if bool(spec["roof"]):
		return TILE_SLATE
	var layer := String(spec["layer"])
	if layer.contains("pavement"):
		return TILE_PAVING_SLAB
	if layer.contains("setts"):
		return TILE_SETTS
	# Author-declared MATERIAL beats colour guessing. Builders already state the
	# material of what they emit (a veranda deck says "wood", a ramp says
	# "concrete"), and guessing from colour used to hand the mid-grey veranda
	# deck and its near-black posts the RUST METAL tile - so every veranda in
	# the city rendered as a dark rusty slab with floating dark posts.
	var val_hint := col.v
	if mat == &"wood":
		return TILE_WOOD_DARK if val_hint < 0.45 else TILE_WOOD_PALE
	if mat == &"concrete":
		# "concrete" covers both the fabric (facade bands, interior walls) and
		# slabs (floors, foundations, entry decks, ramps). Split by shape: a
		# flat box is a slab and gets paving/stone detail, a tall one is wall
		# fabric and gets render - mapping all concrete to rubble repainted
		# every facade in the city.
		var box: Vector3 = spec["size"]
		return TILE_PAVING_SLAB if box.y <= 0.45 else TILE_RENDER_GREY
	if mat == &"stone":
		return TILE_STONE_RUBBLE
	if mat == &"steel" or mat == &"iron" or mat == &"metal":
		return TILE_RUST_METAL
	if mat == &"brick":
		return TILE_BRICK
	if mat == &"tile":
		return TILE_TILE_CHECKER
	if mat == &"soil" or mat == &"dirt":
		return TILE_DIRT_GROUND
	var sat := col.s
	var val := col.v
	# Greens read as moss/algae; greys as bare stone; very dark greys as iron.
	if sat > 0.18 and col.h > 0.18 and col.h < 0.45:
		return TILE_MOSS
	if sat < 0.13:
		return TILE_RUST_METAL if val < 0.55 else TILE_RENDER_GREY
	# Warm mid-tones are joinery (walnut/oak), pale ones are plaster walls.
	if val < 0.42:
		return TILE_WOOD_DARK
	if val < 0.72:
		return TILE_WOOD_PALE
	return TILE_PLASTER_FINE


## Post-apocalypse weathering: the decay level of the building currently being
## generated. Stamped onto every spec so the mesh pass can weather each face
## deterministically (specs keep the raw colour; only MESH vertices darken, so
## determinism/equality tests on specs() are unaffected).
var _decay_stack: Array[float] = []

# Unified structural-damage records: id -> {damage: float}. Every
# destructible cell accumulates effective damage (raw / MaterialDB strength)
# and is destroyed only when it reaches its integrity. Deterministic - no
# random destruction of untouched geometry.
var _cell_damage := {}                 # id -> accumulated effective damage
var _dirty_layers := {}
var _cracked := {}                     # id -> true (glass visual crack state)


## Raw-damage integrity of one structural cell, scaled by volume so big
## panels need more punishment than small chips. Material toughness comes
## from the strength ladder here (NOT applied twice - callers accumulate
## RAW damage and compare against this threshold):
##   wood 1.0 < concrete 2.6 < steel 4.5, glass special-cased fragile.
## Tuning vs game weapons (ItemDB): an SMG round is 9 raw, a shotgun volley
## ~56 raw, a rocket ~130 raw at the falloff core.
##   - wood wall module (~1.36 m3): ~52 raw  -> ~6 SMG rounds, 1 rocket
##   - concrete module: ~136 raw             -> shrugs off SMGs, needs a
##                                             second rocket to finish
##   - steel module: ~235 raw                -> sustained explosives only
##   - glass pane: fixed 22 raw              -> 1 SMG hit cracks, 3 shatter,
##                                                shotgun volley shatters
static func cell_integrity(size: Vector3, material: StringName) -> float:
	if material == &"glass":
		return 22.0
	var vol := size.x * size.y * size.z
	var base := clampf(sqrt(maxf(vol, 0.01)) * 45.0, 12.0, 160.0)
	return base * float(MaterialDB.get_material(material).get("strength", 1.0))


## DECORATIVE geometry - no physics. Windows, trim, treads, roof tiles,
## small props. If a player must not pass through it, this is the WRONG call.
func add_visual_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, false)


## Add a flat visual polygon in XZ space. Used for clipped irregular city
## blocks/plazas; it carries no collision and remains outside the building
## destruction ledger.
func add_visual_polygon(points: PackedVector2Array, y: float, color: Color) -> void:
	_prepared_layers.clear()
	if points.size() < 3:
		return
	_polygon_specs.append({
		"points": points.duplicate(),
		"y": y,
		"color": color,
		"layer": _layers.back(),
	})


## Ground surfaces follow the realized terrain. A pad emitted FLAT at the
## height of one sample point (a block centre, a polygon centroid, the highest
## corner of a footprint) hangs in the air over its downhill half - the "green
## plate flying above the pavement" defect - and buries its uphill half. The
## polygon is cut to the terrain's own 4 m grid and every cell corner samples
## the terrain, so the pad is the same piecewise linear sheet as the ground it
## lies on, in this chunk and the next.
const GROUND_CELL_M := 4.0


static func polygon_bounds(poly: PackedVector2Array) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	return Rect2(lo, hi - lo)


static func _ground_area(poly: PackedVector2Array) -> float:
	var area := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		area += a.x * b.y - b.x * a.y
	return absf(area) * 0.5


static func add_ground_polygon(b: MeshBatcher, poly: PackedVector2Array,
		world_plan: WorldPlan, lift: float, color: Color) -> void:
	if poly.size() < 3:
		return
	if world_plan == null:
		b.add_visual_polygon(poly, lift, color)
		return
	var bounds := polygon_bounds(poly)
	if bounds.size.x <= GROUND_CELL_M and bounds.size.y <= GROUND_CELL_M:
		add_ground_cell(b, poly, world_plan, lift, color)
		return
	var cell := GROUND_CELL_M
	var cell_poly := PackedVector2Array()
	cell_poly.resize(4)
	var x := floorf(bounds.position.x / cell) * cell
	while x < bounds.end.x:
		var z := floorf(bounds.position.y / cell) * cell
		while z < bounds.end.y:
			cell_poly[0] = Vector2(x, z)
			cell_poly[1] = Vector2(x + cell, z)
			cell_poly[2] = Vector2(x + cell, z + cell)
			cell_poly[3] = Vector2(x, z + cell)
			for piece_variant in Geometry2D.intersect_polygons(poly, cell_poly):
				var piece: PackedVector2Array = piece_variant as PackedVector2Array
				if piece.size() >= 3 and _ground_area(piece) > 0.0005:
					add_ground_cell(b, piece, world_plan, lift, color)
			z += cell
		x += cell


static func add_ground_cell(b: MeshBatcher, poly: PackedVector2Array,
		world_plan: WorldPlan, lift: float, color: Color) -> void:
	var heights := PackedFloat32Array()
	heights.resize(poly.size())
	for i in poly.size():
		heights[i] = world_plan.surface_height_at(poly[i]) + lift
	b.add_visual_polygon_heights(poly, heights, color)


func add_visual_polygon_heights(points: PackedVector2Array, heights: PackedFloat32Array, color: Color) -> void:
	_prepared_layers.clear()
	assert(points.size() == heights.size())
	if points.size() < 3:
		return
	_polygon_specs.append({"points": points.duplicate(), "heights": heights.duplicate(),
		"y": 0.0, "color": color, "layer": _layers.back()})


## Roof dressing (pitched shells, membranes, dormers) - flushed into a
## SEPARATE MeshInstance3D so interiors can be revealed by hiding it while
## the player is inside a building. Never carries collision.
func add_roof_visual_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, false, true)

func add_visual_face(vertices: PackedVector3Array, color: Color) -> void:
	_prepared_layers.clear()
	var world := vertices.duplicate()
	for transform: Dictionary in _building_transform_stack:
		for i in world.size():
			world[i] = transform.basis * (world[i] - transform.origin) + transform.origin
	_polygon_specs.append({"vertices": world, "color": color, "layer": _layers.back(),
		"tile": int(_surface_stack.back()) if not _surface_stack.is_empty() else TILE_SLATE})


## STRUCTURAL geometry - carries collision. Walls, slabs, ramps, landings,
## decks, parapets, railings meant to block, closed barriers.
func add_structural_box(pos: Vector3, size: Vector3, color: Color) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, true)


## DESTRUCTIBLE geometry - carries optional collision, is tracked with an id
## and can be blown out of the chunk mesh at runtime (see damage_box /
## destroy_box). Callers subdivide large surfaces into structural cells
## (0.75-1.25 m modules) so blasts carve believable holes instead of
## deleting whole walls; every cell is its own integrity record.
## owner/floor: optional placement metadata (building id + storey index)
## used by acceptance tests to tie every furniture collider to ITS floor.
func add_destructible_box(pos: Vector3, size: Vector3, color: Color,
		material: StringName, collide := true, owner_tag := "",
		floor_i := -1) -> void:
	_append_spec(pos, size, Basis.IDENTITY, color, collide, false, material,
			owner_tag, floor_i)


## Manifest for a DYNAMIC destructible prop; ChunkBuilder.build() turns
## these into DestructibleProp nodes on the main thread. Deterministic order.
func add_prop_def(def: Dictionary) -> void:
	_prop_defs.append(def)


func add_box(pos: Vector3, size: Vector3, color: Color, collide := false) -> void:
	add_box_rotated(pos, size, Basis.IDENTITY, color, collide)


## Rotated variant used for stair ramps and pitched roof slabs. Basis must be
## a pure rotation (no scaling) or collision shapes will be distorted.
func add_box_rotated(pos: Vector3, size: Vector3, basis: Basis,
		color: Color, collide := false, roof_layer := false,
		material := StringName(""), owner_tag := "", floor_i := -1,
		sway := Vector2.ZERO) -> void:
	_append_spec(pos, size, basis, color, collide, roof_layer, material,
			owner_tag, floor_i, sway)


## Tapered polygonal segment (frustum) for organic geometry: local +Y is the
## axis, `size.x`/`size.z` are the base diameters on X/Z (so a bough can be
## flattened) and `taper` is the top diameter as a fraction of the base.
## Trees use this instead of boxes: a 5-6 sided taper reads as a branch, a
## 4-5 sided one as a leaf tuft, and a near-zero taper as a root wedge.
func add_prism_rotated(pos: Vector3, size: Vector3, basis: Basis, color: Color,
		sides: int, taper := 1.0, collide := false,
		material := StringName(""), sway := Vector2.ZERO) -> void:
	_append_spec(pos, size, basis, color, collide, false, material,
			"", -1, sway, maxi(sides, 3), taper)


func _append_spec(pos: Vector3, size: Vector3, basis: Basis, color: Color,
		collide: bool, roof_layer: bool, material: StringName,
		owner_tag := "", floor_i := -1, sway := Vector2.ZERO,
		sides := 0, taper := 1.0) -> void:
	_prepared_layers.clear()
	if not _building_transform_stack.is_empty():
		var transform: Dictionary = _building_transform_stack.back()
		var origin: Vector3 = transform["origin"] as Vector3
		var rotation: Basis = transform["basis"] as Basis
		pos = origin + rotation * (pos - origin)
		basis = rotation * basis
	_box_count += 1
	var id := _box_count
	# Glass renders translucent (tinted pane); everything else is opaque.
	var alpha := 0.55 if material == &"glass" else 1.0
	var decay: float = _decay_stack.back() if not _decay_stack.is_empty() else 0.0
	_specs.append({
		"id": id, "pos": pos, "size": size.abs(), "basis": basis,
		"sway": sway, "sides": sides, "taper": taper,
		"decay": decay,
		"color": Color(color, alpha),
		"collide": collide, "roof": roof_layer, "material": material,
		"layer": _layers.back(),
		"building_id": owner_tag, "floor_i": floor_i,
	})
	if collide:
		_colliders.append({"pos": pos, "size": size.abs(), "basis": basis,
				"id": id, "material": material, "tag": owner_tag,
				"layer": _layers.back() if not _layers.is_empty() else ""})


## Apply a city BuildingSpec's local rectangular grammar around its world
## centre.  The builder continues to emit its reference-quality boxes and
## apertures unchanged; this seam only rotates the finished full-quality
## building when a road-frontage parcel carries a deterministic yaw.
func push_decay(value: float) -> void:
	_decay_stack.append(clampf(value, 0.0, 1.0))


func pop_decay() -> void:
	if not _decay_stack.is_empty():
		_decay_stack.pop_back()


func push_building_transform(origin: Vector3, yaw: float) -> void:
	_building_transform_stack.append({
		"origin": origin,
		# Plan-space yaw maps local +X to (cos(yaw), sin(yaw)) in X/Z.
		# Godot's Y basis uses the opposite sign for that mapping.
		"basis": Basis(Vector3.UP, -yaw),
	})


func pop_building_transform() -> void:
	if not _building_transform_stack.is_empty():
		_building_transform_stack.pop_back()


## Start tagging subsequent boxes with `key` (see layer_nodes).
func push_layer(key: String) -> void:
	_layers.append(key)


func pop_layer() -> void:
	if _layers.size() > 1:
		_layers.pop_back()

# --- G9 M2 Asset Pipeline: queue modular wall instances (visual only, 0 collider) ---
# Asset positions/yaws enter in the builder's pre-transform frame. Apply the
# active full-building transform here so GLB and fallback instances cannot
# detach from rotated BuildingSpecs. Preserve the complete reveal ownership
# tuple instead of relying on the generic floor layer alone.
func queue_asset_wall(pos: Vector3, size: Vector3, color: Color, res_path: String,
		scale: float, has_collision: bool, yaw: float = 0.0,
		facade: String = "", facade_sides: Array = [], roof_layer: bool = false) -> void:
	var asset_pos := pos
	var asset_yaw := yaw
	var layer_key: String = _layers.back()
	var building_id := ""
	var floor_i := -1
	var resolved_facade := facade
	var resolved_facades: Array = facade_sides.duplicate()
	var separator := layer_key.find(":")
	if separator >= 0:
		building_id = layer_key.substr(0, separator)
		var suffix := layer_key.substr(separator + 1)
		if suffix.begins_with("f"):
			var floor_text := suffix.substr(1).split(":")[0]
			floor_i = int(floor_text)
			if resolved_facades.is_empty() and suffix.count(":") >= 1:
				resolved_facade = suffix.substr(suffix.find(":") + 1)
				resolved_facades.append(resolved_facade)
	if resolved_facades.is_empty() and resolved_facade != "":
		resolved_facades.append(resolved_facade)
	# Reveal ownership is the structural facade letter: strip material-bucket
	# suffixes (for example N|g from a glass layer) so gate comparisons stay
	# exact no matter which layer queued the asset.
	var facade_pipe := resolved_facade.find("|")
	if facade_pipe >= 0:
		resolved_facade = resolved_facade.substr(0, facade_pipe)
	var clean_sides: Array = []
	for side_variant in resolved_facades:
		var side_name := str(side_variant)
		var side_pipe := side_name.find("|")
		if side_pipe >= 0:
			side_name = side_name.substr(0, side_pipe)
		if side_name != "" and not clean_sides.has(side_name):
			clean_sides.append(side_name)
	resolved_facades = clean_sides
	if not _building_transform_stack.is_empty():
		var transform: Dictionary = _building_transform_stack.back()
		var origin: Vector3 = transform["origin"] as Vector3
		var rotation: Basis = transform["basis"] as Basis
		asset_pos = origin + rotation * (pos - origin)
		asset_yaw = (rotation * Basis(Vector3.UP, yaw)).get_euler().y
	_asset_instances.append({
		"pos": asset_pos, "size": size, "color": color, "res_path": res_path,
		"scale": scale, "has_collision": has_collision, "yaw": asset_yaw,
		"layer": layer_key, "building_id": building_id, "floor_i": floor_i,
		"facade": resolved_facade, "facade_sides": resolved_facades,
		"roof": roof_layer,
	})


## One reveal predicate is shared by structural layer nodes and queued assets.
## Keeping the parser here prevents ChunkManager and test probes from growing
## subtly different floor/facade/roof rules.
##
## `roof_floor` is the deck storey (floor_i == floors, see locked decision 4).
## The ROOF IS EXTERIOR for visibility purposes: it is cut only while the
## player is strictly BELOW the deck. The moment the player stands on the deck
## (or anywhere above it) the complete roof - cap, parapets, bulkhead, props -
## stays visible, because there is no longer a ceiling between the eye and the
## sky. Passing roof_floor < 0 keeps the legacy rule (roof hidden whenever the
## gate is active) for callers that predate the deck.
static func reveal_layer_hidden(layer_key: String, tag: String,
		max_floor: int, faded: Array, roof_floor: int = -1,
		sight_from: Vector2 = Vector2.INF, sight_to: Vector2 = Vector2.INF) -> bool:
	if max_floor < 0 or tag == "" or not layer_key.begins_with(tag + ":"):
		# Ceiling caps are interior occluders: one thin, VISUAL-ONLY (no collider,
		# so the player walks straight through one) box per room per floor, whose
		# only job is to stop a steep camera reading the room next door over a
		# 2.6 m partition. That trade only makes sense while this building's own
		# interior presentation is open. With no gate for it - the player outdoors,
		# or inside a different building - they must not be drawn at all, or the
		# exterior view shows one grey plane per room per floor, floating clear of
		# the shell (measured by --q3capprobe: 3017 of 3017 caps drawn ungated).
		return layer_key.find(":" + CEIL_CUT_PREFIX) >= 0
	var suffix := layer_key.substr(tag.length() + 1)
	if suffix.begins_with("roof"):
		if roof_floor < 0:
			return true
		return max_floor < roof_floor
	if not suffix.begins_with("f"):
		return false
	var rest := suffix.substr(1)
	var colon := rest.find(":")
	if colon < 0:
		return int(rest) > max_floor
	var fl := int(rest.substr(0, colon))
	var facade_name := rest.substr(colon + 1)
	# Material layers may append a bucket suffix (for example N|g for glass),
	# but reveal ownership is always the structural facade letter.
	var bucket_sep := facade_name.find("|")
	if bucket_sep >= 0:
		facade_name = facade_name.substr(0, bucket_sep)
	if fl > max_floor:
		return true
	if fl < max_floor:
		return false
	if facade_name.begins_with(WALL_CUT_PREFIX):
		return wall_cut_hidden(facade_name.substr(WALL_CUT_PREFIX.length()), sight_from, sight_to)
	if facade_name.begins_with(CEIL_CUT_PREFIX):
		return ceiling_cut_hidden(facade_name.substr(CEIL_CUT_PREFIX.length()), sight_to)
	return facade_name == "cutaway" or faded.has(facade_name)


## Parse a "x_z_w_h" layer-key payload into a plan rect (footprint-local metres).
static func _parse_rect_key(rect_key: String) -> Rect2:
	var parts := rect_key.split("_")
	if parts.size() != 4:
		return Rect2()
	return Rect2(parts[0].to_float(), parts[1].to_float(), parts[2].to_float(), parts[3].to_float())


## Ceiling caps: a room keeps its own ceiling unless the PLAYER is standing in
## it. The camera has to see into that one room (it is the only room the player
## is in, and the only room the cut is allowed to open); every other room stays
## roofed, so a steep top-down camera cannot read the neighbours over the tops
## of their walls.
static func ceiling_cut_hidden(rect_key: String, player_local: Vector2) -> bool:
	if not player_local.is_finite():
		return false
	var r := _parse_rect_key(rect_key)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return false
	return r.grow(0.08).has_point(player_local)


## Layer-key payload for one interior wall box: its plan rect in the same
## footprint-local frame the partition rects use ("x_z_w_h", metres to the
## centimetre). Single authority for the format - wall_cut_hidden splits the
## same four fields back out.
static func wall_cut_key(pos: Vector3, size: Vector3) -> String:
	return "%.2f_%.2f_%.2f_%.2f" % [
			pos.x - size.x * 0.5, pos.z - size.z * 0.5, size.x, size.z]


## Interior-wall cut decision (camera-driven, not storey-driven).
##
## Locked interior-perception rule: an interior wall is NOT cut unless it
## obstructs the camera view of the player. The layer key carries the wall's own
## plan rect ("wallcut:x_z_w_h", footprint-local metres) and the gate hands in
## the camera->player sightline in the same frame, so only the walls standing
## inside the camera's view wedge lose their plaster above the picture rail.
## Every other wall in the building keeps full height, which is also what keeps
## rooms the player is not in from being seen through a forest of half walls.
static func wall_cut_hidden(rect_key: String, sight_from: Vector2, sight_to: Vector2) -> bool:
	if not sight_from.is_finite() or not sight_to.is_finite():
		return false
	var r := _parse_rect_key(rect_key)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return false
	var dir := sight_to - sight_from
	if dir.length_squared() < 0.04:
		return false
	var side := Vector2(-dir.y, dir.x).normalized() * WALL_CUT_WEDGE_M
	var apex := sight_from
	var left := sight_to + side
	var right := sight_to - side
	var bb := Rect2(apex, Vector2.ZERO)
	bb = bb.expand(left)
	bb = bb.expand(right)
	if not bb.intersects(r):
		return false
	var tri := PackedVector2Array([apex, left, right])
	var corners := PackedVector2Array([
			r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	for i in corners.size():
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % corners.size()]
		if Geometry2D.segment_intersects_segment(apex, left, a, b) != null:
			return true
		if Geometry2D.segment_intersects_segment(apex, right, a, b) != null:
			return true
		if Geometry2D.segment_intersects_segment(left, right, a, b) != null:
			return true
	return Geometry2D.is_point_in_polygon(r.get_center(), tri)


## A door leaf must never outlive the wall it is hung in. Exterior leaves carry
## the facade side they sit on (stamped by ChunkBuilder from the door manifest
## edge), so an entrance is retired together with its wall instead of lingering
## as a floating panel once the cutaway removes that facade. A leaf with no
## side is an interior partition door: it is exactly the dollhouse content the
## gate exists to expose, so it only follows the storey rule.
##
## The test below is deliberately the same expression as reveal_layer_hidden for
## a facade layer key, so a leaf and its wall can never disagree: same storey,
## same facade letter. A leaf one storey below the cutaway keeps its wall and
## must therefore stay too.
static func door_hidden(building_id: String, floor_i: int, facade_side: String,
		tag: String, max_floor: int, faded: Array) -> bool:
	if max_floor < 0 or tag == "" or building_id != tag:
		return false
	if floor_i > max_floor:
		return true
	if facade_side == "" or floor_i != max_floor:
		return false
	return faded.has(facade_side)


static func reveal_asset_hidden(asset: Dictionary, tag: String,
		max_floor: int, faded: Array, roof_floor: int = -1) -> bool:
	# An explicitly keyed asset is always a child of the same structural layer.
	# Interior wall modules use the generic f<floor> layer and therefore also
	# carry facade_sides below.
	if reveal_layer_hidden(str(asset.get("layer", "")), tag, max_floor, faded, roof_floor):
		return true
	if max_floor < 0 or tag == "" \
			or str(asset.get("building_id", "")) != tag:
		return false
	var asset_floor := int(asset.get("floor_i", -1))
	if asset_floor < 0:
		return false
	if asset_floor > max_floor:
		return true
	if bool(asset.get("roof", false)):
		# Roof dressing is exterior: it follows the roof layer rule, so it
		# survives while the player is standing on the deck.
		if roof_floor < 0:
			return true
		return max_floor < roof_floor
	if asset_floor != max_floor:
		return false
	var sides: Array = asset.get("facade_sides", []) as Array
	if sides.is_empty():
		var one_side := str(asset.get("facade", ""))
		if one_side != "":
			sides = [one_side]
	for side_variant in sides:
		var side_name := str(side_variant)
		var side_pipe := side_name.find("|")
		if side_pipe >= 0:
			side_name = side_name.substr(0, side_pipe)
		if faded.has(side_name):
			return true
	return false

func asset_instance_count() -> int:
	return _asset_instances.size()

func asset_instances() -> Array[Dictionary]:
	return _asset_instances.duplicate(true)

func asset_nodes() -> Array[Node3D]:
	return _asset_nodes.duplicate()

func clear_asset_instances() -> void:
	_asset_instances.clear()


func props() -> Array[Dictionary]:
	return _prop_defs


## Phase S: streamed-city streetlamp light positions (OmniLight3D per _lamp_post).
## Phase W: deterministic dead/flicker variant (gated to historic district).
func add_street_lamp(pos: Vector3) -> void:
	_street_lights.append(pos)
	var dead := false
	var flicker := false
	var phase := 0.0
	var p2 := Vector2(pos.x, pos.z)
	if _lamp_is_historic(p2):
		var qx := int(round(pos.x * 10.0))
		var qz := int(round(pos.z * 10.0))
		var r_dead := WorldSeed.unit_float("lamp_dead", [qx, qz])
		if r_dead < STREET_DEAD_PROB:
			dead = true
		elif WorldSeed.unit_float("lamp_flicker", [qx, qz]) < STREET_FLICKER_PROB:
			flicker = true
			phase = WorldSeed.unit_float("lamp_phase", [qx, qz])
	_street_lamp_dead.append(dead)
	_street_lamp_flicker.append(flicker)
	_street_lamp_phase.append(phase)

## Register an interior light source (gas lamp or hearth) for ChunkBuilder.
func add_interior_light(pos: Vector3, kind: String, tag: String) -> void:
	var h: int = absi(int(WorldSeed.str_hash(tag + kind + str(int(pos.x)) + str(int(pos.z)))))
	_interior_lights.append({
		"pos": pos,
		"kind": kind,
		"dead": h % 6 == 0,
		"flicker": h % 3 != 0,
		"phase": float(h % 628) / 100.0,
	})


func interior_lights() -> Array[Dictionary]:
	return _interior_lights


func street_lights() -> Array[Vector3]:
	return _street_lights

func street_light_dead(idx: int) -> bool:
	return _street_lamp_dead[idx] if idx >= 0 and idx < _street_lamp_dead.size() else false

func street_light_flicker(idx: int) -> bool:
	return _street_lamp_flicker[idx] if idx >= 0 and idx < _street_lamp_flicker.size() else false

func street_light_phase(idx: int) -> float:
	return _street_lamp_phase[idx] if idx >= 0 and idx < _street_lamp_phase.size() else 0.0

func street_dead_flags() -> Array[bool]:
	return _street_lamp_dead

func street_flicker_flags() -> Array[bool]:
	return _street_lamp_flicker

func street_flicker_phases() -> Array[float]:
	return _street_lamp_phase

## Historic gating helper — mirrors CityPlan.district_at_point without needing a plan.
static func _lamp_is_historic(p: Vector2) -> bool:
	var dist := p.length()
	if dist < 190.0:
		return true
	var cell := Vector2i((p / 128.0).floor())
	var dc := WorldSeed.combine([cell.x, cell.y])
	var roll := WorldSeed.unit_float("district", [dc])
	var inner_reach := 420.0 + 140.0 * WorldSeed.unit_float("dreach", [dc])
	if dist < inner_reach:
		return roll < 0.72
	return false

## Phase U: interior window glow positions (warm OmniLight per intact window).
func add_window_glow(pos: Vector3) -> void:
	_window_glows.append(pos)

func window_glows() -> Array[Vector3]:
	return _window_glows


## Live spec list (tests / persistence readers). Treat as read-only.
func specs() -> Array[Dictionary]:
	return _specs


func is_destroyed(id: int) -> bool:
	return _destroyed.has(id)


func box_count() -> int:
	return _box_count


func collider_count() -> int:
	return _colliders.size()


## Test/introspection helper: applies the SAME visibility rules as
## ChunkManager.apply_floor_gate() directly to this batcher's layer nodes,
## writing the resulting visibility into `out` ({key: visible}) instead of
## requiring a live ChunkManager. Keeps the gate contract unit-testable
## against REAL generated layer_nodes (flush_into must have run).
func apply_floor_gate_probe(tag: String, max_floor: int, faded: Array,
		out: Dictionary) -> void:
	for key: String in layer_nodes.keys():
		var hide := reveal_layer_hidden(key, tag, max_floor, faded)
		out[key] = not hide
	for asset_i in _asset_instances.size():
		out["asset:%d" % asset_i] = not reveal_asset_hidden(
			_asset_instances[asset_i], tag, max_floor, faded)


## Full deterministic record of everything added (for --citytest equality).
func manifest() -> Dictionary:
	return {"boxes": _box_count, "colliders": _colliders.duplicate(true),
			"group_keys": _group_keys(), "props": _prop_defs.duplicate(true),
			"street_lights": _street_lights.duplicate(),
			"window_glows": _window_glows.duplicate(),
			"street_lamp_dead": _street_lamp_dead.duplicate(),
			"street_lamp_flicker": _street_lamp_flicker.duplicate(),
			"street_lamp_phase": _street_lamp_phase.duplicate(),
			"asset_instances": _asset_instances.duplicate(true),
			"polygons": _polygon_specs.duplicate(true)}


# --- Universal Building Contract (G10-P2A): registration -------------------
# The UniversalBuildingAssembler registers every FULL_BUILDING id it
# assembles here. BuildingContractValidator.unregistered_structural() and
# the test harness use this to prove no subsystem bypassed the assembler.

var _contract_buildings: Dictionary = {}   # id -> spec snapshot


func register_contract_building(id: String, spec: Dictionary) -> void:
	_contract_buildings[id] = spec


func contract_building_ids() -> Array[String]:
	var ids: Array[String] = []
	for k in _contract_buildings.keys():
		ids.append(str(k))
	ids.sort()
	return ids


func contract_building(id: String) -> Dictionary:
	return _contract_buildings.get(id, {})


func _group_keys() -> Array:
	return _specs.map(func(s: Dictionary) -> String:
			return (s["color"] as Color).to_html())


## Builds nodes under `parent`: one MeshInstance3D per reveal LAYER (see
## layer_nodes) + "Static" StaticBody3D holding every collision shape.
## PERSISTENCE CONTRACT: cells already marked destroyed NEVER regain a
## CollisionShape3D here, so mesh and collision state always agree on
## first materialization (restored deltas are applied BEFORE this flush).
func flush_into(parent: Node3D, body_layer := 1,
		include_collision := true) -> Dictionary:
	_parent = parent
	_asset_nodes.clear()
	var stats := {"mesh_nodes": 0, "colliders": _colliders.size()}

	var _f0 := Time.get_ticks_usec()
	var groups := _prepared_layers if not _prepared_layers.is_empty() else _build_layers()
	_prepared_layers = {}
	var _f1 := Time.get_ticks_usec()
	for key: String in groups.keys():
		var mi := MeshInstance3D.new()
		mi.name = "L_%s" % (key.replace(":", "_").replace("|", "_")
				if key != "" else "street")
		mi.mesh = _mesh_from({key: groups[key]})
		parent.add_child(mi)
		# A layer's first state is the UNGATED state, which is the only state most
		# chunks are ever in: ChunkManager replays a real gate onto the single
		# chunk the player is inside, and nothing touches the rest. Without this
		# every materialised interior kept its ceiling caps drawn forever (see
		# reveal_layer_hidden).
		mi.visible = not reveal_layer_hidden(key, "", -1, [])
		layer_nodes[key] = mi
		stats["mesh_nodes"] += 1

	var _f2 := Time.get_ticks_usec()
	if include_collision:
		_flush_collision_into(parent, body_layer)
	var _f3 := Time.get_ticks_usec()
	# G9 M2 Asset Pipeline: instantiate queued modular walls (visual only, 0 collider, scale 1.0)
	# Each asset is a MeshInstance from wall_2m.glb or fallback BoxMesh if GLB missing/invalid.
	# ACTIVE-only visual: ChunkManager disables via queue_free on unload; warm retains visuals disabled.
	var asset_count := 0
	var asset_scenes: Dictionary = {}
	for a in _asset_instances:
		var res_path: String = a.get("res_path", "") as String
		var a_pos: Vector3 = a.get("pos", Vector3.ZERO) as Vector3
		var a_size: Vector3 = a.get("size", Vector3(2.0, 2.05, 0.18)) as Vector3
		var a_color: Color = a.get("color", Color("a8a090")) as Color
		var a_scale: float = float(a.get("scale", 1.0))
		var a_yaw: float = float(a.get("yaw", 0.0))
		var scene: PackedScene = null
		if not asset_scenes.has(res_path):
			if FileAccess.file_exists(res_path) or ResourceLoader.exists(res_path, "PackedScene"):
				var loaded = ResourceLoader.load(res_path)
				if loaded is PackedScene:
					scene = loaded as PackedScene
			asset_scenes[res_path] = scene
		else:
			scene = asset_scenes[res_path]
		var node3d: Node3D = null
		if scene != null:
			var inst = scene.instantiate()
			if inst is Node3D:
				node3d = inst as Node3D
				node3d.position = a_pos
				node3d.scale = Vector3.ONE * a_scale
				if not is_zero_approx(a_yaw):
					node3d.rotation.y = a_yaw
				# Tag for test/debugging, reveal gating, and ownership audits.
				node3d.set_meta("asset_wall_2m", true)
				node3d.set_meta("asset_layer_key", str(a.get("layer", "")))
				node3d.set_meta("asset_building_id", str(a.get("building_id", "")))
				node3d.set_meta("asset_floor_i", int(a.get("floor_i", -1)))
				node3d.set_meta("asset_facade", str(a.get("facade", "")))
				node3d.set_meta("asset_facade_sides", (a.get("facade_sides", []) as Array).duplicate())
				node3d.set_meta("asset_roof", bool(a.get("roof", false)))
				node3d.add_to_group("asset_wall")
				_asset_nodes.append(node3d)
				parent.add_child(node3d)
				asset_count += 1
				continue
			else:
				if inst != null:
					inst.queue_free()
		# Fallback: vertex-colored box at same position/size (a8a090) — keeps 0 extra collider
		var mi_fb := MeshInstance3D.new()
		mi_fb.name = "AssetFallback_%d" % asset_count
		var box := BoxMesh.new()
		box.size = a_size
		mi_fb.mesh = box
		mi_fb.position = a_pos
		mi_fb.scale = Vector3.ONE * a_scale
		if not is_zero_approx(a_yaw):
			mi_fb.rotation.y = a_yaw
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = false
		mat.albedo_color = a_color
		mi_fb.material_override = mat
		mi_fb.set_meta("asset_wall_2m", true)
		mi_fb.set_meta("asset_fallback", true)
		mi_fb.set_meta("asset_layer_key", str(a.get("layer", "")))
		mi_fb.set_meta("asset_building_id", str(a.get("building_id", "")))
		mi_fb.set_meta("asset_floor_i", int(a.get("floor_i", -1)))
		mi_fb.set_meta("asset_facade", str(a.get("facade", "")))
		mi_fb.set_meta("asset_facade_sides", (a.get("facade_sides", []) as Array).duplicate())
		mi_fb.set_meta("asset_roof", bool(a.get("roof", false)))
		mi_fb.add_to_group("asset_wall")
		_asset_nodes.append(mi_fb)
		parent.add_child(mi_fb)
		asset_count += 1
	stats["asset_instances"] = asset_count
	if debug_profile:
		print("[Flush] layers=%.0f mesh=%.0f collision=%.0f assets=%.0f ms boxes=%d specs=%d" % [
			float(_f1 - _f0) / 1000.0, float(_f2 - _f1) / 1000.0,
			float(_f3 - _f2) / 1000.0, float(Time.get_ticks_usec() - _f3) / 1000.0,
			box_count(), _specs.size()])
	return stats


## Add the batched city collision for a chunk that has entered the ACTIVE ring.
## Warm chunks keep their visual mesh and batcher data but do not spend one
## physics shape per generated cell while they are outside direct play.
func enable_collision(body_layer := 1) -> void:
	if _parent == null or not is_instance_valid(_parent):
		return
	var existing := _parent.get_node_or_null(NodePath("Static"))
	if existing != null:
		if existing.is_queued_for_deletion():
			existing.free()
		else:
			return
	if _inactive_body != null:
		for id: int in _destroyed:
			if _shape_nodes.has(id):
				var shape_node: CollisionShape3D = _shape_nodes[id]
				_shape_nodes.erase(id)
				shape_node.free()
		_inactive_body.collision_layer = body_layer
		_parent.add_child(_inactive_body)
		_inactive_body = null
		return
	_flush_collision_into(_parent, body_layer)


## Release the heavy batched city collision when a chunk leaves ACTIVE.
## Destructible metadata stays in the RefCounted batcher for persistence and
## is rebuilt if the chunk becomes active again.
func disable_collision() -> void:
	if _parent == null or not is_instance_valid(_parent):
		return
	var body := _parent.get_node_or_null(NodePath("Static"))
	if body != null:
		if body.get_parent() != null:
			body.get_parent().remove_child(body)
		_inactive_body = body


## Warm collision is detached from the scene/physics world, ready for reuse.
## Cold/unloaded chunks transfer it to the manager's budgeted disposal queue.
func release_collision_cache() -> StaticBody3D:
	var body := _inactive_body
	_inactive_body = null
	if body != null:
		_shape_nodes.clear()
	return body


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _inactive_body != null:
		_inactive_body.free()


func _flush_collision_into(parent: Node3D, body_layer := 1) -> void:
	_parent = parent
	if _colliders.is_empty():
		return
	var existing := parent.get_node_or_null(NodePath("Static"))
	if existing != null:
		return
	var body := StaticBody3D.new()
	body.name = "Static"
	body.collision_layer = body_layer
	body.collision_mask = 0
	for col in _colliders:
		if _destroyed.has(int(col["id"])):
			continue   # destroyed cell: no collider resurrection
		var shape_node := CollisionShape3D.new()
		var size: Vector3 = col["size"]
		if not _box_shapes.has(size):
			var shared_shape := BoxShape3D.new()
			shared_shape.size = size
			_box_shapes[size] = shared_shape
		var shape: BoxShape3D = _box_shapes[size]
		shape_node.shape = shape
		shape_node.position = col["pos"]
		shape_node.basis = col["basis"]
		# Only EXPLICITLY destructible materials carry a vox id:
		# plain structural boxes (ground plane, floor slabs, stair
		# ramps/landings) stay indestructible so nobody falls into
		# an abyss through a blasted-out floor.
		if StringName(col["material"]) != &"":
			shape_node.set_meta("vox_id", int(col["id"]))
			shape_node.set_meta("vox_material",
					StringName(col["material"]))
		# Diagnostic: which emitter produced this collider. Bare CollisionShape3D
		# nodes made a blocked walkway impossible to attribute; the layer stack
		# already knows, so ride it along and let audits name the rule.
		if col.has("layer"):
			shape_node.set_meta("src_layer", str(col["layer"]))
		# Phase M: known feature tags ride along as vox_tag so the
		# parkour controller can classify WHAT it grabbed, not just
		# whether the wall is batched structure. Building-id owner
		# tags are deliberately not stamped.
		var feat_tag := String(col["tag"])
		if feat_tag in ["awning", "balcony", "tower", "bhplant",
				"bhladder", "bhexit", "scaffold", "cornice", "pilaster"]:
			shape_node.set_meta("vox_tag", StringName(feat_tag))
		_shape_nodes[int(col["id"])] = shape_node
		body.add_child(shape_node)
	# Register the complete body once, rather than mutating live physics
	# registration for each of its thousands of collision children.
	parent.add_child(body)


# --- Destruction -------------------------------------------------------------

## Marks a box destroyed. Returns its spec ({pos,size,color,...}) so callers
## can spawn matching debris, or {} when the id is unknown/gone.
func destroy_box(id: int) -> Dictionary:
	_prepared_layers.clear()
	if _destroyed.has(id):
		return {}
	if id <= 0 or id > _specs.size():
		return {}
	_destroyed[id] = true
	var spec: Dictionary = _specs[id - 1]
	_dirty_layers[_layer_key(spec)] = true
	return spec.duplicate()


## Stable, materialization-order-independent cell key: quantized world
## position + size. Two rebuilds of the same chunk under the same seed
## produce identical keys for identical geometry, so destroyed-cell sets
## round-trip through saves regardless of emission order.
static func cell_key(pos: Vector3, size: Vector3) -> String:
	return "%d:%d:%d|%d:%d:%d" % [
		roundi(pos.x * 20.0), roundi(pos.y * 20.0), roundi(pos.z * 20.0),
		roundi(size.x * 20.0), roundi(size.y * 20.0), roundi(size.z * 20.0),
	]


func cell_key_for_id(id: int) -> String:
	if id <= 0 or id > _specs.size():
		return ""
	var spec: Dictionary = _specs[id - 1]
	return cell_key(spec["pos"], spec["size"])


## Damage snapshot for persistence: {cell_key: {"damage": float}} for every
## partially damaged, still-standing cell.
func damage_state() -> Dictionary:
	var out := {}
	for id: int in _cell_damage.keys():
		if _destroyed.has(id):
			continue
		var key := cell_key_for_id(id)
		if key != "":
			out[key] = {"damage": float(_cell_damage[id])}
	return out


## Restore partial-damage state after a chunk rebuild (keys as produced by
## damage_state()). Values are ACCUMULATED RAW damage; also re-marks any
## cells whose restored raw damage already meets their integrity as
## destroyed WITHOUT spawning debris again.
func load_damage_state(data: Dictionary) -> void:
	if not data.is_empty():
		_prepared_layers.clear()
	_cell_damage.clear()
	_cracked.clear()
	for spec in _specs:
		var key := cell_key(spec["pos"], spec["size"])
		if not data.has(key):
			continue
		var id := int(spec["id"])
		var dmg := float(data[key].get("damage", 0.0))
		if dmg >= cell_integrity(spec["size"], spec["material"]):
			if not _destroyed.has(id):
				_destroyed[id] = true
		else:
			_cell_damage[id] = dmg
			if spec["material"] == &"glass" and dmg >= cell_integrity(spec["size"], &"glass") * 0.4:
				_cracked[id] = true


## Applies damage to a structural cell. `amount` is the RAW incoming
## damage; material toughness enters exactly ONCE via this comparison
## against cell_integrity() (which is scaled by MaterialDB strength):
##   total_raw >= integrity -> destroyed.
## Glass additionally flips to a cracked visual at >= 40% of its integrity.
## Returns {} when nothing changed; otherwise
##   {shattered: true, ...spec}      - cell destroyed this hit
##   {cracked: true, ...spec}        - glass crossed the crack threshold
func damage_box(id: int, amount: float) -> Dictionary:
	if _destroyed.has(id) or amount <= 0.0:
		return {}
	if id <= 0 or id > _specs.size():
		return {}
	var spec: Dictionary = _specs[id - 1]
	var material: StringName = spec["material"]
	if material == &"":
		return {}   # indestructible plain structural box
	# Accumulate RAW damage; the strength ladder lives only in
	# cell_integrity(), so concrete/wood/steel differ by their
	# thresholds instead of a double-applied divisor.
	var total := float(_cell_damage.get(id, 0.0)) + amount
	_cell_damage[id] = total
	var integ := cell_integrity(spec["size"], material)
	if total >= integ:
		var info := destroy_box(id)
		info["shattered"] = true
		return info
	# Cracked-glass visual feedback only.
	if material == &"glass" and not _cracked.has(id) \
			and total >= integ * 0.4:
		_cracked[id] = true
		_dirty_layers[_layer_key(spec)] = true
		_prepared_layers.clear()
		var info2: Dictionary = spec.duplicate()
		info2["cracked"] = true
		return info2
	return {"damaged": true}



## Re-bakes only damaged material/facade layers from live specs. Deferred by
## the caller so several boxes destroyed in one frame cost ONE rebuild.
## Also removes destroyed CollisionShape3D nodes from the scene tree.
func refresh_meshes() -> void:
	if _parent == null or not is_instance_valid(_parent):
		return
	if _dirty_layers.is_empty():
		return
	# Clean up destroyed collision shapes so they don't accumulate.
	for id: int in _destroyed:
		if _shape_nodes.has(id):
			var shape_node: CollisionShape3D = _shape_nodes[id]
			if is_instance_valid(shape_node):
				shape_node.queue_free()
			_shape_nodes.erase(id)
	var groups := _build_layers(_dirty_layers)
	for key: String in layer_nodes.keys():
		if not _dirty_layers.has(key):
			continue
		var mi: MeshInstance3D = layer_nodes[key]
		if not is_instance_valid(mi):
			continue
		if groups.has(key):
			mi.mesh = _mesh_from({key: groups[key]})
		else:
			mi.queue_free()   # every box in this layer was destroyed
			layer_nodes.erase(key)

	_dirty_layers.clear()

# --- Geometry generation -----------------------------------------------------

## Groups live specs into vertex buffers, split by reveal LAYER (street,
## per-building storeys, per-building roof dressing). Glass gets its own
## surface per layer for transparency.
## Pure packed-array work, called by the chunk's exclusive worker before
## handoff. Scene objects and rendering/physics resources stay main-thread.
func prepare_mesh_data() -> void:
	_prepared_layers = _build_layers()


func _layer_key(spec: Dictionary) -> String:
	return String(spec["layer"]) + ("|g" if spec["material"] == &"glass" else ("|r" if spec["roof"] else ""))


func _build_layers(only: Dictionary = {}) -> Dictionary:
	var groups := {}
	for spec in _specs:
		if _destroyed.has(spec["id"]):
			continue
		# Composite key: building/floor tag + separate bucket for roof
		# dressing so legacy roof hiding keeps working within a tag.
		# Glass gets its own bucket ("|g") so it can use a transparent material.
		var key := _layer_key(spec)
		if not only.is_empty() and not only.has(key):
			continue
		if not groups.has(key):
			groups[key] = {"color": spec["color"], "verts": PackedVector3Array(),
				"normals": PackedVector3Array(), "colors": PackedColorArray(),
				"uvs": PackedVector2Array(), "uv2s": PackedVector2Array(),
				"idx": PackedInt32Array()}
		var buf: Dictionary = groups[key]
		var verts_before: int = (buf["verts"] as PackedVector3Array).size()
		_emit_box(buf, spec)
		_fill_uv2(buf, spec, verts_before)
	for polygon: Dictionary in _polygon_specs:
		var polygon_key: String = String(polygon.get("layer", ""))
		if not only.is_empty() and not only.has(polygon_key):
			continue
		if not groups.has(polygon_key):
			groups[polygon_key] = {"color": polygon.get("color", Color.WHITE), "verts": PackedVector3Array(),
				"normals": PackedVector3Array(), "colors": PackedColorArray(),
				"uvs": PackedVector2Array(), "uv2s": PackedVector2Array(),
				"idx": PackedInt32Array()}
		var polygon_buf: Dictionary = groups[polygon_key]
		_emit_polygon(polygon_buf, polygon)
	return groups


func _emit_polygon(buf: Dictionary, polygon: Dictionary) -> void:
	if polygon.has("vertices"):
		var face: PackedVector3Array = polygon.vertices
		var base: int = buf.verts.size()
		var normal := (face[2] - face[0]).cross(face[1] - face[0]).normalized()
		for vertex in face:
			buf.verts.append(vertex)
			buf.normals.append(normal)
			buf.colors.append(polygon.color)
			buf.uvs.append(Vector2(float(polygon.tile), tile_span(int(polygon.tile))))
		_fill_uv2(buf, {}, base)
		for i in range(1, face.size() - 1):
			buf.idx.append_array(PackedInt32Array([base, base + i, base + i + 1]))
		return
	var points: PackedVector2Array = polygon.get("points", PackedVector2Array()) as PackedVector2Array
	if points.size() < 3:
		return
	var verts: PackedVector3Array = buf["verts"]
	var normals: PackedVector3Array = buf["normals"]
	var colors: PackedColorArray = buf["colors"]
	var uvs: PackedVector2Array = buf["uvs"]
	var base := verts.size()
	var poly_tile := float(_surface_stack.back()) if not _surface_stack.is_empty() else float(TILE_COBBLE)
	var y: float = float(polygon.get("y", 0.0))
	var heights: PackedFloat32Array = polygon.get("heights", PackedFloat32Array())
	var col: Color = polygon.get("color", Color.WHITE) as Color
	for point_i in points.size():
		var p := points[point_i]
		verts.append(Vector3(p.x, heights[point_i] if heights.size() == points.size() else y, p.y))
		normals.append(Vector3.UP)
		colors.append(col)
		# Ground polygons carry the same packed (tile, span) attribute.
		uvs.append(Vector2(poly_tile, tile_span(int(poly_tile))))
	_fill_uv2(buf, {}, base)
	# NOTE: never `(buf["verts"] as PackedVector3Array).append(...)` — the
	# `as` cast copies the packed array, so appends are silently lost and the
	# polygon renders nothing. Typed locals above share the stored array.
	var tris := Geometry2D.triangulate_polygon(points)
	if tris.is_empty():
		return
	for ti in range(0, tris.size(), 3):
		var ta: int = tris[ti]
		var tb: int = tris[ti + 1]
		var tc: int = tris[ti + 2]
		# CCW XY triangles become clockwise when viewed from above in XZ.
		# Godot uses clockwise front faces; reversing here hides ground paving.
		buf["idx"].append_array(PackedInt32Array([
			base + ta, base + tb, base + tc,
		]))


func _emit_box(buf: Dictionary, spec: Dictionary) -> void:
	# Prisms come through the same entry point: trees emit tapered polygonal
	# segments so trunks, limbs and boughs read as round-ish, never as cuboids.
	if int(spec.get("sides", 0)) > 2:
		_emit_prism(buf, spec)
		return
	var half := (spec["size"] as Vector3) * 0.5
	var basis: Basis = spec["basis"]
	var pos: Vector3 = spec["pos"]
	var verts: PackedVector3Array = buf["verts"]
	# Cracked glass: lighter and more opaque
	var col: Color = spec["color"]
	if spec["material"] == &"glass" and _cracked.has(spec["id"]):
		col = col.lightened(0.35)
		col.a = 0.8
	# Grim decay: soot, damp and mould mottling. One hash per box (not per
	# vertex) keeps the cost off the streaming budget; the vertical gradient is
	# plain arithmetic. Low corners of a box go dampest, top edges sootiest.
	var decay: float = float(spec.get("decay", 0.0))
	var tile := _tile_for(spec, col)
	var mould := 0.0
	if decay > 0.001:
		mould = decay * _hash01(pos + Vector3(7.3, 1.7, 13.1))
	for f: Array in _face_defs():
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = n.cross(u)
		var hn: Vector3 = basis * (n * _axis_half(half, n))
		var hu: Vector3 = basis * (u * _axis_half(half, u))
		var hv: Vector3 = basis * (v * _axis_half(half, v))
		var c := pos + hn
		# CCW quad around n ...
		var corners: Array[Vector3] = [
			c - hu - hv, c + hu - hv, c + hu + hv, c - hu + hv,
		]
		var base := verts.size()
		var wn := basis * n
		for p in corners:
			verts.append(p)
			buf["normals"].append(wn)
			# Single packed attribute: (atlas tile, metres per tile). The shader
			# derives the planar pattern coords from world position, so no second
			# UV array is needed - vertex bytes are the streaming budget here.
			buf["uvs"].append(Vector2(float(tile), tile_span(tile)))
			var vcol := col
			if decay > 0.001:
				# Per-vertex grime: patchy soot + vertical damp streaks (streak is
				# constant in Y, so it reads as staining running down a wall),
				# heavier at the base where damp rises.
				var patch := _hash01(p)
				var streak := _hash01(Vector3(p.x, 0.0, p.z))
				var damp := clampf(1.0 - (p.y - pos.y + half.y) / 2.2, 0.0, 1.0)
				var soot := clampf(((p.y - pos.y + half.y) - 2.1) / 1.6, 0.0, 1.0)
				var grime := decay * (0.24 * patch + 0.30 * streak + 0.20 * damp + 0.18 * soot)
				vcol = col.darkened(clampf(grime, 0.0, 0.62))
				if patch > 0.62 and damp > 0.3:
					vcol = vcol.lerp(Color("38402b"), clampf((patch - 0.62) * decay * 1.1, 0.0, 0.34))
			buf["colors"].append(vcol)
		# ... reversed into Godot's clockwise front-face winding.
		buf["idx"].append_array(PackedInt32Array([
			base, base + 2, base + 1,
			base, base + 3, base + 2,
		]))


## Tapered prism. Sides are flat-shaded quads (4 vertices each, same budget
## accounting as a box face) plus a fan cap at each end; the top cap is skipped
## when the segment comes to a point, which is also what saves the vertices.
func _emit_prism(buf: Dictionary, spec: Dictionary) -> void:
	var size: Vector3 = spec["size"]
	var basis: Basis = spec["basis"]
	var pos: Vector3 = spec["pos"]
	var sides: int = maxi(int(spec.get("sides", 5)), 3)
	var taper: float = clampf(float(spec.get("taper", 1.0)), 0.02, 1.0)
	var hy: float = size.y * 0.5
	var rx: float = maxf(size.x * 0.5, 0.008)
	var rz: float = maxf(size.z * 0.5, 0.008)
	var tx: float = rx * taper
	var tz: float = rz * taper
	var col: Color = spec["color"]
	var tile := _tile_for(spec, col)
	var sway: Vector2 = spec.get("sway", Vector2.ZERO) as Vector2
	for i in sides:
		var a0: float = TAU * float(i) / float(sides)
		var a1: float = TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * rx, -hy, sin(a0) * rz)
		var b1 := Vector3(cos(a1) * rx, -hy, sin(a1) * rz)
		var t0 := Vector3(cos(a0) * tx, hy, sin(a0) * tz)
		var t1 := Vector3(cos(a1) * tx, hy, sin(a1) * tz)
		var am: float = (a0 + a1) * 0.5
		_poly_quad(buf, pos, basis, [b0, b1, t1, t0],
			Vector3(cos(am), 0.0, sin(am)), tile, col, sway)
	if taper >= 0.25:
		var top_ring: Array = []
		for i in sides:
			var a: float = TAU * float(i) / float(sides)
			top_ring.append(Vector3(cos(a) * tx, hy, sin(a) * tz))
		_poly_fan(buf, pos, basis, Vector3(0, hy, 0), top_ring, Vector3.UP, tile, col, sway)
	var bot_ring: Array = []
	for i in sides:
		var a: float = TAU * float(i) / float(sides)
		bot_ring.append(Vector3(cos(a) * rx, -hy, sin(a) * rz))
	_poly_fan(buf, pos, basis, Vector3(0, -hy, 0), bot_ring, Vector3.DOWN, tile, col, sway)


## Flat-shaded quad in the prism's local frame. `want` only orients the facet
## (its stored normal is the true facet normal), so convex prisms never end up
## back-facing whichever way the taper tilts them.
static func _poly_quad(buf: Dictionary, pos: Vector3, basis: Basis, corners: Array,
		want: Vector3, tile: float, col: Color, sway: Vector2) -> void:
	var cs: Array = corners
	var wn := _quad_normal(cs)
	if wn.dot(want) < 0.0:
		cs = [corners[0], corners[3], corners[2], corners[1]]
		wn = -wn
	var verts: PackedVector3Array = buf["verts"]
	var base := verts.size()
	var world_n := (basis * wn).normalized()
	for c in cs:
		verts.append(pos + basis * (c as Vector3))
		buf["normals"].append(world_n)
		buf["uvs"].append(Vector2(float(tile), tile_span(tile)))
		buf["colors"].append(col)
	buf["idx"].append_array(PackedInt32Array([
		base, base + 2, base + 1,
		base, base + 3, base + 2,
	]))


static func _quad_normal(c: Array) -> Vector3:
	# Normal of the two triangles actually emitted by _poly_quad.
	var n := ((c[2] as Vector3) - (c[0] as Vector3)).cross((c[1] as Vector3) - (c[2] as Vector3))
	if n.length_squared() < 1e-12:
		return Vector3.UP
	return n.normalized()


## Triangle fan for the prism end caps: one shared centre vertex plus the ring,
## so an n-gon cap costs n+1 vertices instead of 3n. Each triangle's winding is
## checked against the intended outward direction, which is what keeps caps
## visible from both ends of a drooping bough.
static func _poly_fan(buf: Dictionary, pos: Vector3, basis: Basis, center: Vector3,
		ring: Array, want: Vector3, tile: float, col: Color, sway: Vector2) -> void:
	var n: int = ring.size()
	if n < 3:
		return
	var verts: PackedVector3Array = buf["verts"]
	var base := verts.size()
	var world_n := (basis * want.normalized()).normalized()
	verts.append(pos + basis * center)
	buf["normals"].append(world_n)
	buf["uvs"].append(Vector2(float(tile), tile_span(tile)))
	buf["colors"].append(col)
	for p in ring:
		verts.append(pos + basis * (p as Vector3))
		buf["normals"].append(world_n)
		buf["uvs"].append(Vector2(float(tile), tile_span(tile)))
		buf["colors"].append(col)
	for i in n:
		var i0: int = base + 1 + i
		var i1: int = base + 1 + ((i + 1) % n)
		var outward := (verts[i0] - verts[base]).cross(verts[i1] - verts[i0])
		if outward.dot(world_n) >= 0.0:
			buf["idx"].append_array(PackedInt32Array([base, i0, i1]))
		else:
			buf["idx"].append_array(PackedInt32Array([base, i1, i0]))


## Deterministic 0..1 spatial hash (integer mixing - no transcendentals, so
## it stays cheap at 24 vertices per box). Lattice is 0.35 m, fine enough that
## one big wall box still shows patchy soot and damp rather than one flat tone.
static func _hash01(p: Vector3) -> float:
	var ix := int(floor(p.x * 2.857))
	var iy := int(floor(p.y * 2.857))
	var iz := int(floor(p.z * 2.857))
	var h: int = ix * 374761393 + iy * 668265263 + iz * 1442695041
	h = (h ^ (h >> 13)) * 1274126177
	return float(absi(h % 65536)) / 65536.0


## Half extent along the dominant axis of unit vector d (d is +/- one axis).
static func _axis_half(half: Vector3, d: Vector3) -> float:
	if absf(d.x) > 0.5:
		return half.x
	if absf(d.y) > 0.5:
		return half.y
	return half.z


## Six outward normals with tangent partners chosen so that u.cross(v) == n.
static func _face_defs() -> Array:
	return [
		[Vector3(1, 0, 0), Vector3(0, 1, 0)],    # +X  v=Z
		[Vector3(-1, 0, 0), Vector3(0, 0, 1)],   # -X  v=Y
		[Vector3(0, 1, 0), Vector3(0, 0, 1)],    # +Y  v=X
		[Vector3(0, -1, 0), Vector3(1, 0, 0)],   # -Y  v=Z
		[Vector3(0, 0, 1), Vector3(1, 0, 0)],    # +Z  v=Y
		[Vector3(0, 0, -1), Vector3(0, 1, 0)],   # -Z  v=X
	]


## Pad the second UV channel (wind sway) up to the current vertex count.
## `sway` is Vector2(weight, phase); polygons and every non-tree box contribute
## (0,0) so the channel stays aligned with ARRAY_VERTEX. See WindSystem.
static func _fill_uv2(buf: Dictionary, spec: Dictionary, from_vert: int) -> void:
	var verts: PackedVector3Array = buf["verts"]
	var uv2s: PackedVector2Array = buf["uv2s"]
	var sway: Vector2 = spec.get("sway", Vector2.ZERO) as Vector2
	while uv2s.size() < from_vert:
		uv2s.append(Vector2.ZERO)
	while uv2s.size() < verts.size():
		uv2s.append(sway)


func _mesh_from(groups: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key: String in groups.keys():
		var buf: Dictionary = groups[key]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = buf["verts"]
		arrays[Mesh.ARRAY_NORMAL] = buf["normals"]
		arrays[Mesh.ARRAY_COLOR] = buf["colors"]
		arrays[Mesh.ARRAY_TEX_UV] = buf["uvs"]
		# Wind sway weights ride in UV2. Only emitted when something in this
		# layer actually carries sway data, so pure ground layers stay lean.
		var uv2s: PackedVector2Array = buf["uv2s"]
		if uv2s.size() > 0:
			var vcount: int = (buf["verts"] as PackedVector3Array).size()
			if uv2s.size() < vcount:
				uv2s.resize(vcount)
			arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		arrays[Mesh.ARRAY_INDEX] = buf["idx"]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var surf_idx := mesh.get_surface_count() - 1
		if key.ends_with("|g"):
			mesh.surface_set_material(surf_idx, _glass_material())
		elif key == "street_setts" or key == "street_pavement":
			# Streets and pavements used a bespoke procedural paving shader; the
			# surface atlas now owns ground texture (granite setts / stone slabs,
			# selectable per layer), so they share the one city material instead
			# of a second shader with its own stone pattern.
			mesh.surface_set_material(surf_idx, _shared_material())
		else:
			mesh.surface_set_material(surf_idx, _shared_material())
	return mesh


## Opaque city material: the surface-detail atlas multiplied by vertex colour.
## Vertex colour still carries the whole building palette and the decay
## weathering; the atlas only adds the surface structure that flat vertex
## colours could not express (grain, mortar, plaster, rust).
static func _shared_material() -> ShaderMaterial:
	if _opaque_material != null:
		return _opaque_material
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://world/streaming/surface_atlas.gdshader")
	var tiles := _atlas_texture_array()
	if tiles != null:
		mat.set_shader_parameter("surface_tiles", tiles)
	mat.set_shader_parameter("surface_roughness", 0.95)
	mat.set_shader_parameter("metallic_hint", 0.0)
	# A/B capture support: RB_NO_SURFACE_TILES=1 renders the same scene with
	# plain vertex colour so the lighting cost of the detail can be measured.
	if OS.get_environment("RB_NO_SURFACE_TILES") == "1":
		mat.set_shader_parameter("detail_strength", 0.0)
	_opaque_material = mat
	return mat


## Slice the generated atlas into a Texture2DArray, one layer per tile.
##
## A texture array is used rather than sampling the atlas image directly: mip
## levels of an atlas average NEIGHBOURING TILES together, so distant surfaces
## blur into a grey smear (the first attempt's "blurry buildings"). Per-layer
## mips cannot bleed, and repeat wrapping stays correct per layer.
static func _atlas_texture_array() -> Texture2DArray:
	if _tile_array != null:
		return _tile_array
	var tex := load(ATLAS_PATH) as Texture2D
	if tex == null:
		push_warning("surface atlas missing: %s" % ATLAS_PATH)
		return null
	var src := tex.get_image()
	if src == null:
		return null
	if src.has_mipmaps():
		src.clear_mipmaps()      # mips are generated per tile, never across
	# Derive the tile size from what was ACTUALLY imported rather than trusting
	# the expected constant. A stale .ctex (Godot only re-imports assets on an
	# ENGINE-level `--import`, not on the project's `-- --import` boot flag) once
	# left a 1024x1024 copy of an older atlas on disk: slicing 512 px tiles out
	# of it produced wrong regions and empty layers, which the player saw as
	# black/untextured surfaces everywhere.
	if src.get_width() % ATLAS_COLS != 0 or src.get_height() % ATLAS_ROWS != 0:
		push_warning("surface atlas %dx%d does not divide into a %dx%d grid - textures disabled"
				% [src.get_width(), src.get_height(), ATLAS_COLS, ATLAS_ROWS])
		return null
	var tile_px := src.get_width() / ATLAS_COLS
	if tile_px != ATLAS_TILE_PX or src.get_height() / ATLAS_ROWS != tile_px:
		push_warning("surface atlas tile is %d px, expected %d (stale import?) - using the actual size"
				% [tile_px, ATLAS_TILE_PX])
	var images: Array[Image] = []
	for i in TILE_COUNT:
		var col := i % ATLAS_COLS
		var row := i / ATLAS_COLS
		var tile := src.get_region(Rect2i(col * tile_px, row * tile_px,
				tile_px, tile_px))
		if tile == null:
			continue
		if tile.get_format() != Image.FORMAT_RGBA8:
			tile.convert(Image.FORMAT_RGBA8)
		tile.generate_mipmaps()
		images.append(tile)
	if images.is_empty():
		return null
	var arr := Texture2DArray.new()
	var err := arr.create_from_images(images)
	if err != OK:
		push_warning("surface tile array build failed (%d)" % err)
		return null
	_tile_array = arr
	return arr


static func _glass_material() -> StandardMaterial3D:
	if _transparent_material != null:
		return _transparent_material
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.1
	mat.metallic = 0.0
	_transparent_material = mat
	return mat
