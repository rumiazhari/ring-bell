extends Node
## Q3 reveal capture: reproduces the PLAYER's cutaway/gate scenarios on real
## generated city geometry and writes PNGs, so roof/door behaviour can be
## inspected instead of inferred.
##
## Scenarios (each applies the SAME reveal rules ChunkManager.apply_floor_gate
## uses, via MeshBatcher.reveal_layer_hidden / reveal_asset_hidden):
##   01_inside_f0_camS   player on ground storey, camera south
##   02_inside_f0_camN   player on ground storey, camera north
##   03_top_inside_camS  player on the highest INTERIOR storey, camera south
##   04_deck_across      player on the ROOF DECK (floor_i == floors), level view
##   05_deck_topdown     player on the ROOF DECK, top-down
##   06_street_door      street level, front elevation of the entrance
##   07_building_full    no gate at all (reference: everything visible)
## Run: --q3revealcapture  (requires a real renderer, not headless)

var camera: Camera3D
var output := ""
var shots := 0
var failures := 0

const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")

var _batchers := {}      # Vector2i -> MeshBatcher
var _chunks := {}        # Vector2i -> Node3D


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("[Q3Reveal] real renderer required")
		get_tree().quit(1)
		return
	# Failsafe: a script error must never leave a window hanging around.
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_error("[Q3Reveal] watchdog timeout")
		get_tree().quit(1))
	run()


func run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	output = "res://.hermes/autopilot/reports/q3-reveal/%d" % WorldSeed.get_world_seed()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_setup_light()
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	var spec := _pick_building(plan)
	if spec.is_empty():
		push_error("[Q3Reveal] no suitable city building")
		get_tree().quit(1)
		return
	var tag := str(spec["id"])
	var n: int = int(spec["floors"])
	print("[Q3Reveal] building id=%s floors=%d archetype=%s doors=%d rect=%s yaw=%.3f" % [
		tag, n, str(spec.get("archetype", "?")), (spec.get("doors", []) as Array).size(),
		str(spec["rect"]), float(spec.get("yaw", 0.0))])
	var doors: Array = spec.get("doors", [])
	if doors.size() > 0:
		var d0: Dictionary = doors[0]
		print("[Q3Reveal] door edge=%d width=%.3f height=%.3f pos=%s yaw=%.3f" % [
			int(d0.get("edge", -1)), float(d0.get("width", 0.0)),
			float(d0.get("height", 0.0)), str(d0.get("position", Vector3.ZERO)),
			float(d0.get("yaw", 0.0))])
	for dd: Dictionary in doors:
		# Numeric proof of the kind-based width table, straight off the spec.
		print("[Q3Reveal] door edge=%d width=%.3f height=%.3f kind=%s" % [
			int(dd.get("edge", -1)), float(dd.get("width", 0.0)),
			float(dd.get("height", 0.0)), str(dd.get("kind", "-"))])
	await _ground_owner_chunks(plan, world, spec)
	var centre_coord := WorldSeed.chunk_coord((spec["rect"] as Rect2).get_center().x, (spec["rect"] as Rect2).get_center().y)
	if not _chunks.has(centre_coord):
		push_error("[Q3Reveal] owner chunk %s was not built" % str(centre_coord))
		get_tree().quit(1)
		return
	var chunk_node: Node3D = _chunks[centre_coord]
	var batcher: MeshBatcher = _batchers[centre_coord]
	var ground_y := _ground_y(spec, world)
	var centre: Vector2 = (spec["rect"] as Rect2).get_center()
	var fh := float(spec.get("floor_h", 3.0))
	var roof_y := ground_y + float(n) * fh

	# 07 first: ungated reference.
	await _shot("07_building_full", Vector3(centre.x - 6.0, roof_y + 7.0, centre.y - 9.0),
			Vector3(centre.x, ground_y + float(n) * fh * 0.45, centre.y))

	await _gate_and_shot(batcher, chunk_node, tag, 0, ["S"], "01_inside_f0_camS",
			Vector3(centre.x, ground_y + 6.5, centre.y + 8.0),
			Vector3(centre.x, ground_y + 1.2, centre.y), n)
	await _gate_and_shot(batcher, chunk_node, tag, 0, ["N"], "02_inside_f0_camN",
			Vector3(centre.x, ground_y + 6.5, centre.y - 8.0),
			Vector3(centre.x, ground_y + 1.2, centre.y), n)
	if n >= 2:
		await _gate_and_shot(batcher, chunk_node, tag, n - 1, ["S"], "03_top_inside_camS",
				Vector3(centre.x, ground_y + float(n - 1) * fh + 6.5, centre.y + 8.0),
				Vector3(centre.x, ground_y + float(n - 1) * fh + 1.2, centre.y), n)
	await _gate_and_shot(batcher, chunk_node, tag, n, [], "04_deck_across",
			Vector3(centre.x - 7.0, roof_y + 2.6, centre.y - 9.0),
			Vector3(centre.x + 1.0, roof_y + 0.5, centre.y + 3.0), n)
	await _gate_and_shot(batcher, chunk_node, tag, n, [], "05_deck_topdown",
			Vector3(centre.x, roof_y + 9.0, centre.y + 0.6),
			Vector3(centre.x, roof_y, centre.y), n)
	# Street front elevation of the entrance: outside, gate off, door side on.
	if doors.size() > 0:
		var d: Dictionary = doors[0]
		var dp: Vector3 = d["position"]
		var yaw := float(d.get("yaw", 0.0))
		var out := Vector3(sin(yaw + PI * 0.5), 0.0, cos(yaw + PI * 0.5))
		await _shot("06_street_door",
				Vector3(dp.x, ground_y + 1.65, dp.z) + out * 4.2,
				Vector3(dp.x, ground_y + 1.15, dp.z))
	# Second pass: a FLAT-roof building, whose roof layer carries the parapet
	# ring and the stair bulkhead with its roof-access doorway.
	var flat := _pick_flat_building(plan, tag)
	if not flat.is_empty():
		await _flat_deck_pass(plan, world, flat)
	print("[Q3Reveal] finished shots=%d failures=%d output=%s" % [shots, failures, output])
	get_tree().quit(failures)


## Flat-roof (non-historic) city building with the most storeys, nearest the
## origin, so the roof layer has a parapet ring and a bulkhead doorway.
func _pick_flat_building(plan: CityPlan, exclude_id: String) -> Dictionary:
	var best := {}
	var score := INF
	for spec: Dictionary in plan.city_buildings():
		if str(spec["id"]) == exclude_id:
			continue
		if int(spec.get("floors", 1)) < 3:
			continue
		var style: Dictionary = spec.get("style", {})
		if style.get("roof_plan") != null or bool(style.get("attic", false)):
			continue
		var rect: Rect2 = spec["rect"]
		if rect.size.x < 6.0 or rect.size.y < 6.0:
			continue
		var distance := rect.get_center().length_squared()
		if distance < score:
			score = distance
			best = spec
	return best


## Deck shots for a flat-roof building: on the deck (roof must stay) and one
## storey below the deck (roof must hide so the dollhouse view works).
func _flat_deck_pass(plan: CityPlan, world: WorldPlan, spec: Dictionary) -> void:
	var tag := str(spec["id"])
	var n: int = mini(int(spec["floors"]), 8)
	var centre: Vector2 = (spec["rect"] as Rect2).get_center()
	var coord := WorldSeed.chunk_coord(centre.x, centre.y)
	if not _chunks.has(coord):
		await _ground_owner_chunks(plan, world, spec)
	if not _chunks.has(coord):
		print("[Q3Reveal] flat-roof building %s has no chunk" % tag)
		return
	var ground_y := _ground_y(spec, world)
	var fh := float(spec.get("floor_h", 3.0))
	var roof_y := ground_y + float(n) * fh
	print("[Q3Reveal] flat-roof building id=%s floors=%d archetype=%s" % [
		tag, n, str(spec.get("archetype", "?"))])
	var b: MeshBatcher = _batchers[coord]
	var c: Node3D = _chunks[coord]
	await _gate_and_shot(b, c, tag, n, [], "08_flat_deck_across",
			Vector3(centre.x - 6.0, roof_y + 2.4, centre.y - 8.0),
			Vector3(centre.x, roof_y + 0.6, centre.y), n)
	await _gate_and_shot(b, c, tag, n, [], "09_flat_deck_topdown",
			Vector3(centre.x, roof_y + 9.0, centre.y + 0.6),
			Vector3(centre.x, roof_y, centre.y), n)
	await _gate_and_shot(b, c, tag, n - 1, ["S"], "10_flat_below_deck",
			Vector3(centre.x, ground_y + float(n - 1) * fh + 6.5, centre.y + 8.0),
			Vector3(centre.x, ground_y + float(n - 1) * fh + 1.2, centre.y), n)


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
	camera = Camera3D.new()
	camera.current = true
	camera.fov = 78
	add_child(camera)


func _pick_building(plan: CityPlan) -> Dictionary:
	var best := {}
	var score := INF
	for spec: Dictionary in plan.city_buildings():
		if (spec.get("doors", []) as Array).is_empty():
			continue
		if int(spec.get("floors", 1)) < 2:
			continue
		var rect: Rect2 = spec["rect"]
		if rect.size.x < 6.0 or rect.size.y < 6.0:
			continue
		var distance := rect.get_center().length_squared()
		if distance < score:
			score = distance
			best = spec
	return best


func _ground_y(spec: Dictionary, world: WorldPlan) -> float:
	if spec.has("planned_ground_y"):
		return float(spec["planned_ground_y"])
	var c: Vector2 = (spec["rect"] as Rect2).get_center()
	return world.surface_height_at(c)


func _ground_owner_chunks(plan: CityPlan, world: WorldPlan, spec: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "Q3RevealHolder"
	add_child(holder)
	var centre: Vector2 = (spec["rect"] as Rect2).get_center()
	var owner := WorldSeed.chunk_coord(centre.x, centre.y)
	for x in range(owner.x - 1, owner.x + 2):
		for z in range(owner.y - 1, owner.y + 2):
			var coord := Vector2i(x, z)
			TerrainChunkBuilder.materialize(holder, TerrainChunkBuilder.build_manifest(world, coord))
			var batcher: MeshBatcher = MeshBatcherScript.new()
			ChunkBuilderScript.fill_batcher(batcher, plan, coord, world)
			ChunkBuilderScript.build(holder, plan, coord, batcher, {}, true, true, world)
			var chunk: Node3D = holder.get_node_or_null(NodePath("Chunk_%d_%d" % [coord.x, coord.y]))
			if chunk == null:
				push_error("[Q3Reveal] chunk missing %s" % str(coord))
				continue
			_chunks[coord] = chunk
			_batchers[coord] = batcher
			await get_tree().process_frame


## Applies the exact ChunkManager gate rules for one scenario, prints what the
## rules decided, and captures the resulting view.
func _gate_and_shot(batcher: MeshBatcher, chunk_node: Node3D, tag: String, max_floor: int,
		faded: Array, label: String, cam_pos: Vector3, cam_target: Vector3,
		roof_floor: int = -1) -> void:
	var hidden_layers: Array[String] = []
	for key: String in batcher.layer_nodes.keys():
		var hide := MeshBatcher.reveal_layer_hidden(key, tag, max_floor, faded, roof_floor)
		var node: Node = batcher.layer_nodes[key]
		if node != null and is_instance_valid(node):
			# ChunkManager.apply_floor_gate: structure hidden from the camera
			# keeps casting shadows instead of being switched off.
			var mi := node as MeshInstance3D
			if mi != null:
				mi.cast_shadow = MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
						if hide else MeshInstance3D.SHADOW_CASTING_SETTING_ON
				mi.visible = true
		if hide:
			hidden_layers.append(key)
	var doors_hidden := 0
	for child in chunk_node.get_children():
		if child is Node3D and child.has_meta("interior_floor"):
			var dfloor := int(child.get_meta("interior_floor"))
			var dfacade := str(child.get_meta("door_facade_side", ""))
			var vis := not MeshBatcher.door_hidden(str(child.get_meta("interior_building_id", "")),
					dfloor, dfacade, tag, max_floor, faded)
			(child as Node3D).visible = vis
			if not vis:
				doors_hidden += 1
	var roof_keys: Array[String] = []
	for key: String in batcher.layer_nodes.keys():
		if key.begins_with(tag + ":") and key.substr(tag.length() + 1).begins_with("roof"):
			roof_keys.append(key)
	print("[Q3Reveal] %s max_floor=%d faded=%s hidden_layers=%d/%d hidden_roof_layers=%d roof_keys=%s doors_hidden=%d" % [
		label, max_floor, str(faded), hidden_layers.size(), batcher.layer_nodes.size(),
		_count_present(roof_keys, hidden_layers), str(roof_keys), doors_hidden])
	await _shot(label, cam_pos, cam_target)


func _count_present(needles: Array[String], hay: Array[String]) -> int:
	var total := 0
	for k in needles:
		if hay.has(k):
			total += 1
	return total


func _shot(label: String, position: Vector3, target: Vector3) -> void:
	camera.position = position
	camera.look_at(target)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image.save_png(output + "/" + label + ".png") != OK:
		failures += 1
		print("[Q3Reveal] FAILED to save %s" % label)
	shots += 1
	print("[Q3Reveal] saved %s cam=%s target=%s" % [label, str(position), str(target)])
