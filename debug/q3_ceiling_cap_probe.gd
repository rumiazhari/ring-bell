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
## Both outside_own and drawn_outdoors must be 0. A/B it:
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
	_holder = Node3D.new()
	_holder.name = "CapWorld"
	add_child(_holder)
	if _render:
		_setup_light()

	var core := _core_chunk(plan)
	var caps := 0
	var outside := 0
	var drawn := 0
	var worst := 0.0
	var sample := ""
	for x in range(core.x - RING, core.x + RING + 1):
		for z in range(core.y - RING, core.y + RING + 1):
			var stats: Dictionary = await _audit_chunk(plan, world, Vector2i(x, z))
			caps += int(stats["caps"])
			outside += int(stats["outside"])
			drawn += int(stats["drawn"])
			if float(stats["worst"]) > worst:
				worst = float(stats["worst"])
				sample = str(stats["sample"])
	print("[CapProbe] tag=%s seed=%d chunks=%d caps=%d outside_own=%d worst_m=%.2f drawn_outdoors=%d" % [
		OS.get_environment("RB_TAG"), WorldSeed.get_world_seed(), _audited.size(),
		caps, outside, worst, drawn])
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
	for entry: Dictionary in _specs_of(coord):
		var layer := str(entry.get("layer", ""))
		var tag := layer.get_slice(":", 0)
		var pos: Vector3 = entry["pos"]
		var size: Vector3 = entry["size"]
		var lo := Vector2(pos.x - size.x * 0.5, pos.z - size.z * 0.5)
		var hi := Vector2(pos.x + size.x * 0.5, pos.z + size.z * 0.5)
		if layer.contains(":" + MeshBatcherScript.CEIL_CUT_PREFIX):
			caps.append({"tag": tag, "c": Vector2(pos.x, pos.z), "y": pos.y,
					"size": size, "layer": layer})
		else:
			var e: Dictionary = aabb.get(tag, {"lo": lo, "hi": hi})
			e["lo"] = Vector2(minf(e["lo"].x, lo.x), minf(e["lo"].y, lo.y))
			e["hi"] = Vector2(maxf(e["hi"].x, hi.x), maxf(e["hi"].y, hi.y))
			aabb[tag] = e

	var out_n := 0
	var drawn := 0
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
	return {"caps": caps.size(), "outside": out_n, "drawn": drawn,
			"worst": worst, "sample": sample}


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
