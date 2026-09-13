extends Node
## Ceiling-cap placement + visibility probe (frontend, player-perceived).
##
## Every interior room gets one thin, horizontal, VISUAL-ONLY box - a "ceiling
## cap" - whose only job is to stop a steep camera reading the room next door
## over a 2.6 m partition. Because it is visual-only it has no collider, so the
## player walks through it.
##
## Measured defect (user report: "stacked flat plane with grey color ... spawning
## out of nowhere ... I can still walk through them ... everywhere in the entire
## city"): caps were emitted WITHOUT the building's `off` offset, while every
## other box in the same function adds it (`b.add_visual_box(off + Vector3(...))`).
## Each cap was therefore thrown clear of its own building - and outside the
## shell nothing occludes it, so it reads as a grey plane hanging in the street,
## stacked one per floor.
##
## This probe rebuilds real chunks and, for every cap, measures how far its XZ
## centre sits OUTSIDE the rest of its own building's boxes (same layer tag):
##   caps            caps emitted in the built chunks
##   outside_own     caps whose centre is > AABB_SLACK_M outside their building
##   drawn_outdoors  caps the layer gate still draws with NO active gate
##                   (player outdoors, or inside another building)
##   drawn_inside    caps the gate draws while the player IS inside that building
##                   (gate active, player standing at the footprint centre of the
##                   cap's own storey). This is the ceiling the player sees from
##                   the dollhouse camera, and it must be 0 for every building and
##                   every floor - user rule 2026-09-13.
##   legacy_inside   what the RETIRED per-room rule would have drawn in the same
##                   state (every room but the one the player stands in). Kept
##                   only as the before/after reference: it is the count of grey
##                   slabs the indoors dollhouse view used to show.
## outside_own, drawn_outdoors and drawn_inside must all be 0; legacy_inside is
## reported, never asserted. A/B it:
##   RB_TAG=caps_before python tools/run_suite.py --q3capprobe 240
##   RB_TAG=caps_after  python tools/run_suite.py --q3capprobe 240
## Add --rendered to also write vantage.png (a high, angled view over the block,
## the angle the user reported from).

const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")
const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
const TerrainChunkBuilderScript = preload("res://world/streaming/terrain_chunk_builder.gd")

const OUT_DIR := "res://.hermes/autopilot/reports/q3-ceiling-caps"
const RING := 1                 # chunks around the core chunk to audit
const AABB_SLACK_M := 0.35      # cap may overhang its building by this much

var failures := 0
var _render := false
var _holder: Node3D = null
var _camera: Camera3D = null
var _audited := {}
## Building specs by id: the indoors audit needs each building's storey count and
## its footprint rect to stand the player on the right floor.
var _specs_by_id := {}
var inside_sample := ""


func _ready() -> void:
	run()


func run() -> void:
	# Headless still gives the numbers (spec positions + the gate rule); a real
	# renderer is needed for the pixels (run_suite.py strips --rendered, so ask
	# DisplayServer instead of the cmdline).
	_render = DisplayServer.get_name() != "headless"
	var out := "%s/%s" % [OUT_DIR, OS.get_environment("RB_TAG")]
	if _render:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	for spec: Dictionary in plan.city_buildings():
		_specs_by_id[str(spec.get("id", ""))] = spec
	_holder = Node3D.new()
	_holder.name = "CapWorld"
	add_child(_holder)
	if _render:
		_setup_light()

	var core := _core_chunk(plan)
	var ring := RING
	var ring_env := OS.get_environment("RB_RING")
	if ring_env != "":
		ring = int(ring_env)
	var caps := 0
	var outside := 0
	var drawn := 0
	var inside := 0
	var legacy := 0
	var plates := 0
	var plates_in := 0
	var plate_samples := ""
	var worst := 0.0
	var sample := ""
	for x in range(core.x - ring, core.x + ring + 1):
		for z in range(core.y - ring, core.y + ring + 1):
			var stats: Dictionary = await _audit_chunk(plan, world, Vector2i(x, z))
			caps += int(stats["caps"])
			outside += int(stats["outside"])
			drawn += int(stats["drawn"])
			inside += int(stats["inside"])
			legacy += int(stats["legacy"])
			plates += int(stats["plate_total"])
			plates_in += int(stats["plates"])
			if plate_samples == "" and str(stats["plate_samples"]) != "":
				plate_samples = str(stats["plate_samples"])
			if float(stats["worst"]) > worst:
				worst = float(stats["worst"])
				sample = str(stats["sample"])
	print("[CapProbe] tag=%s seed=%d chunks=%d caps=%d outside_own=%d worst_m=%.2f drawn_outdoors=%d drawn_inside=%d legacy_inside=%d" % [
		OS.get_environment("RB_TAG"), WorldSeed.get_world_seed(), _audited.size(),
		caps, outside, worst, drawn, inside, legacy])
	print("[CapProbe] plates=%d drawn_over_rooms=%d" % [plates, plates_in])
	if inside > 0:
		failures += 1
		print("[CapProbe] FAIL: %d cap(s) still drawn while the player is inside; sample=%s" % [inside, inside_sample])
	if plates_in > 0:
		failures += 1
		print("[CapProbe] FAIL: %d slab(s) still drawn over a storey the player stands on" % plates_in)
		print("[CapProbe] plates_sample: %s" % plate_samples.replace(" || ", "\n[CapProbe]   "))
	if sample != "":
		print("[CapProbe] worst_cap=%s" % sample)

	if _render:
		await _render_vantage(out, plan, core)
	print("[CapProbe] finished with %d failure(s) output=%s" % [failures, out])
	get_tree().quit(0 if failures == 0 else 1)


## The chunk with the most multi-storey city buildings in the core block.
func _core_chunk(plan: CityPlan) -> Vector2i:
	var count := {}
	var best := Vector2i.ZERO
	var best_n := -1
	for spec: Dictionary in plan.city_buildings():
		if int(spec.get("floors", 1)) < 2:
			continue
		var coord: Vector2i = spec.get("owner_chunk", WorldSeed.chunk_coord(
				(spec["rect"] as Rect2).get_center().x, (spec["rect"] as Rect2).get_center().y))
		count[coord] = int(count.get(coord, 0)) + 1
		if int(count[coord]) > best_n:
			best_n = int(count[coord])
			best = coord
	return best


func _audit_chunk(plan: CityPlan, world: WorldPlan, coord: Vector2i) -> Dictionary:
	if not _audited.has(coord):
		_audited[coord] = true
		TerrainChunkBuilderScript.materialize(_holder,
				TerrainChunkBuilderScript.build_manifest(world, coord))
		var b: MeshBatcher = MeshBatcherScript.new()
		ChunkBuilderScript.fill_batcher(b, plan, coord, world)
		ChunkBuilderScript.build(_holder, plan, coord, b, {}, true, true, world)
		await get_tree().process_frame
		_store(coord, b)

	var aabb: Dictionary = {}
	var caps: Array = []
	var plates: Array = []
	var cap_y := {}
	for entry: Dictionary in _specs_of(coord):
		var layer := str(entry.get("layer", ""))
		var tag := layer.get_slice(":", 0)
		var pos: Vector3 = entry["pos"]
		var size: Vector3 = entry["size"]
		var lo := Vector2(pos.x - size.x * 0.5, pos.z - size.z * 0.5)
		var hi := Vector2(pos.x + size.x * 0.5, pos.z + size.z * 0.5)
		if layer.contains(":" + MeshBatcherScript.CEIL_CUT_PREFIX):
			var cfl := _cap_floor(layer, tag)
			caps.append({"tag": tag, "c": Vector2(pos.x, pos.z), "y": pos.y,
					"size": size, "layer": layer,
					"floor": cfl,
					"rect": _cap_rect_key(layer)})
			# Reference height: a cap's centre is the storey's ceiling plane, so a
			# plate at the same height roofs that storey, and one a storey lower is
			# that storey's own floor slab (harmless).
			cap_y["%s|%d" % [tag, cfl]] = pos.y
		elif _is_wide_slab(tag, size, pos):
			plates.append({"tag": tag, "c": Vector2(pos.x, pos.z), "y": pos.y,
					"size": size, "layer": layer,
					"col": _col_of(entry), "roof": bool(entry.get("roof", false))})
		else:
			var e: Dictionary = aabb.get(tag, {"lo": lo, "hi": hi})
			e["lo"] = Vector2(minf(e["lo"].x, lo.x), minf(e["lo"].y, lo.y))
			e["hi"] = Vector2(maxf(e["hi"].x, hi.x), maxf(e["hi"].y, hi.y))
			aabb[tag] = e

	var out_n := 0
	var drawn := 0
	var ins := 0
	var leg := 0
	var worst := 0.0
	var sample := ""
	for cap: Dictionary in caps:
		var e: Dictionary = aabb.get(cap["tag"], {})
		if not e.is_empty():
			var d := _outside_dist(cap["c"], e["lo"], e["hi"])
			if d > AABB_SLACK_M:
				out_n += 1
			if d > worst:
				worst = d
				sample = "tag=%s y=%.2f pos=(%.1f,%.1f) size=(%.1f,%.1f) out_m=%.2f layer=%s" % [
					cap["tag"], cap["y"], cap["c"].x, cap["c"].y,
					cap["size"].x, cap["size"].z, d, cap["layer"]]
		# An outdoor state has no gate for this building: the gate must hide it.
		if not MeshBatcherScript.reveal_layer_hidden(cap["layer"], "", -1, []):
			drawn += 1
		# INDOORS state (user rule 2026-09-13): the gate is active for this cap's
		# own building and the player stands on the cap's own storey, at the
		# footprint centre - the vantage the dollhouse camera looks down from. No
		# ceiling may be drawn anywhere: every building, every floor.
		var spec: Dictionary = _specs_by_id.get(cap["tag"], {})
		if spec.is_empty():
			continue
		var fl_i := int(cap["floor"])
		var n_floors := int(spec.get("floors", 1))
		var fp: Rect2 = spec["rect"]
		var centre_local: Vector2 = fp.size * 0.5
		if not MeshBatcherScript.reveal_layer_hidden(cap["layer"], cap["tag"], fl_i, [],
				n_floors, Vector2.INF, centre_local):
			ins += 1
			if inside_sample == "":
				inside_sample = "tag=%s floor=%d pos=(%.1f,%.1f) size=(%.1f,%.1f) layer=%s" % [
					cap["tag"], fl_i, cap["c"].x, cap["c"].y,
					cap["size"].x, cap["size"].z, cap["layer"]]
		# What the RETIRED per-room rule would have drawn in that same state:
		# every room on the player's storey but the one the player stands in.
		if not MeshBatcherScript.ceiling_cut_hidden(str(cap["rect"]), centre_local):
			leg += 1

	# PLATES: any wide thin slab sitting on the ceiling plane of a storey, in a
	# layer the gate still DRAWS while the player stands on that storey. This is
	# the general form of the user's rule - it names every emitter that roofs an
	# interior, not just the ceiling caps retired above.
	var pl_in := 0
	var plate_samples: Array = []
	for plate: Dictionary in plates:
		var pspec: Dictionary = _specs_by_id.get(plate["tag"], {})
		if pspec.is_empty():
			continue
		var pfp: Rect2 = pspec["rect"]
		var p_centre: Vector2 = pfp.size * 0.5
		var p_n := int(pspec.get("floors", 1))
		var top: float = plate["y"] + plate["size"].y * 0.5
		# The player can stand on ANY storey of the building; a lid for storey `fi`
		# is a compact slab whose TOP face sits ON that storey's ceiling plane - the
		# measured cap height, not a guessed floor height (the cap was emitted from
		# the same `off` as every other box in the building, so it is terrain-proof).
		# Platforms, landings and mezzanines sit BELOW the ceiling plane and are
		# real architecture, not ceilings: the band stays tight on purpose.
		# A roof deck lands on the ceiling plane of the top storey too, and the
		# gate is asked with the same roof_floor (spec floors) the game passes.
		for fi in p_n:
			var c: Variant = cap_y.get("%s|%d" % [plate["tag"], fi], null)
			if c == null:
				continue
			var ceil_y: float = float(c) + 0.05
			if absf(top - ceil_y) > CEIL_BAND_M:
				continue
			# The gate the game itself calls: same predicate, same roof_floor
			# (spec floors) and same measured ceiling plane.
			if MeshBatcherScript.reveal_layer_hidden(plate["layer"], plate["tag"], fi, [],
					p_n, Vector2.INF, p_centre):
				continue
			pl_in += 1
			if plate_samples.size() < 5:
				plate_samples.append("layer=%s size=(%.2f,%.2f,%.2f) c=(%.1f,%.1f,%.1f) col=%s roof=%s stand_f=%d top_vs_ceil=%.2f" % [
					plate["layer"], plate["size"].x, plate["size"].y, plate["size"].z,
					plate["c"].x, plate["y"], plate["c"].y, plate["col"], plate["roof"], fi,
					top - ceil_y])
			break
	return {"caps": caps.size(), "outside": out_n, "drawn": drawn, "inside": ins,
			"legacy": leg, "worst": worst, "sample": sample, "plates": pl_in,
			"plate_samples": " || ".join(plate_samples), "plate_total": plates.size()}


## A "plate" is wide, thin, horizontal geometry whose TOP face sits on the ceiling
## plane of the storey its layer is tagged to - i.e. a slab that roofs that storey.
## Ceiling caps are one family of plate; a storey slab emitted under the storey it
## roofs is another, and that is what still hung over the user's rooms once the
## caps were retired. Plate area and band are deliberately loose: the audit must
## catch ANY emitter, not the ones we happen to know about. Who counts as a lid is
## defined in _is_wide_slab: a COMPACT slab sitting ON a storey's ceiling plane.
const PLATE_MIN_AREA := 6.0
const LID_MIN_SIDE := 1.0
const CEIL_BAND_M := 0.55


## Hex of a spec entry's colour, so a plate sample names its emitter by palette.
func _col_of(entry: Dictionary) -> String:
	var c: Variant = entry.get("color", null)
	if c is Color:
		return (c as Color).to_html(false)
	return "-"


## A wide, thin, slab-like box: the shape that roofs a storey. Storey slabs, roof
## decks and ceiling caps all match; the caller decides which storey's ceiling
## plane the box actually sits on.
##
## A lid must be a COMPACT slab, not a long thin moulding: a cornice band running
## 24 m along a wall passes the area test while covering no room at all. Both
## horizontal dimensions must therefore clear LID_MIN_SIDE.
func _is_wide_slab(tag: String, size: Vector3, pos: Vector3) -> bool:
	if size.x * size.z < PLATE_MIN_AREA or size.y > 0.6:
		return false
	if minf(size.x, size.z) < LID_MIN_SIDE:
		return false
	var spec: Dictionary = _specs_by_id.get(tag, {})
	if spec.is_empty():
		return false
	var fp: Rect2 = spec["rect"]
	return fp.grow(0.75).has_point(Vector2(pos.x, pos.z))


## Storey index carried by a cap layer key ("<tag>:f<fi>:ceilcut:<rect>").
func _cap_floor(layer: String, tag: String) -> int:
	var suffix := layer.substr(tag.length() + 1)
	var head := suffix.split(":", true, 1)[0]
	if not head.begins_with("f"):
		return 0
	return maxi(0, int(head.substr(1)))


## The "x_z_w_h" plan rect a cap layer key carries, in footprint-local metres.
func _cap_rect_key(layer: String) -> String:
	var idx := layer.find(":" + MeshBatcherScript.CEIL_CUT_PREFIX)
	if idx < 0:
		return ""
	return layer.substr(idx + MeshBatcherScript.CEIL_CUT_PREFIX.length() + 1)


## Distance from `p` to the rect `lo..hi`; 0.0 when p is inside it.
func _outside_dist(p: Vector2, lo: Vector2, hi: Vector2) -> float:
	var dx := maxf(maxf(lo.x - p.x, p.x - hi.x), 0.0)
	var dz := maxf(maxf(lo.y - p.y, p.y - hi.y), 0.0)
	return sqrt(dx * dx + dz * dz)


func _store(coord: Vector2i, b: MeshBatcher) -> void:
	_specs[coord] = b.specs().duplicate()


var _specs := {}


func _specs_of(coord: Vector2i) -> Array:
	return _specs.get(coord, [])


## A WIDE, FIXED view over the core block. Fixed on purpose: the same frame in
## both runs, so the before/after images are directly comparable. Wide and high
## enough to catch the caps the missing `off` threw tens of metres clear of their
## own buildings into the streets around them.
func _render_vantage(out: String, plan: CityPlan, core: Vector2i) -> void:
	var rect: Rect2 = WorldSeed.chunk_rect(core)
	var focus := Vector3(rect.get_center().x, 6.0, rect.get_center().y)
	_camera = Camera3D.new()
	_camera.name = "CapVantage"
	_camera.fov = 62.0
	_camera.near = 0.1
	_camera.far = 900.0
	add_child(_camera)
	_camera.global_position = focus + Vector3(-52.0, 58.0, -78.0)
	_camera.look_at(focus, Vector3.UP)
	_camera.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.save_png("%s/vantage.png" % out) != OK:
		failures += 1
		print("[CapProbe] FAILED to save vantage.png")
	else:
		print("[CapProbe] vantage=%s/vantage.png" % out)
	# Second, fixed street-level shot: the vantage the report came from ("top
	# right", eye height, looking along the block). Same camera in both runs.
	_camera.global_position = focus + Vector3(-30.0, 1.7, -44.0)
	_camera.look_at(focus + Vector3(0.0, 4.0, 0.0), Vector3.UP)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var simg := get_viewport().get_texture().get_image()
	if simg.save_png("%s/street.png" % out) != OK:
		failures += 1
		print("[CapProbe] FAILED to save street.png")
	else:
		print("[CapProbe] street=%s/street.png" % out)


func _setup_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("81909e")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("d1d9e0")
	env.environment.ambient_light_energy = 0.7
	add_child(env)
