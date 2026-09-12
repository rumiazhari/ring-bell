extends Node
## Room-placement perception pass: renders each storey of a few real buildings
## the way a player sees them (eye height inside a room, plus a dollhouse view
## from above per storey) and audits the room rectangles the INTERIOR PLAN
## hands the builder - rooms poking outside the footprint, slivers, rooms with
## no partition at all, and rooms the entry cannot reach.
## Run: --q3roomperception   (needs a real renderer)

var camera: Camera3D
var output := ""
var failures := 0
var shots := 0
const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")
const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
var _holder: Node3D
var _built := {}
var _chunks := {}
var _batchers := {}

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Room perception capture requires a real renderer")
		get_tree().quit(1)
		return
	run()

func run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	output = "res://.hermes/autopilot/reports/q3-room-perception/%d" % WorldSeed.get_world_seed()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_setup_light()
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	_holder = Node3D.new()
	add_child(_holder)
	var picks := _pick_buildings(plan)
	print("[RoomPerception] picked %d buildings" % picks.size())
	for entry: Dictionary in picks:
		await _pass(plan, world, entry["spec"], str(entry["what"]))
	print("[RoomPerception] finished shots=%d failures=%d output=%s" % [shots, failures, output])
	get_tree().quit(failures)

## One small ordinary house, one merged (large) building and one historic block
## house: the three shapes a player walks through most.
func _pick_buildings(plan: CityPlan) -> Array:
	var small := {}
	var merged := {}
	var historic := {}
	var d_small := INF
	var d_merged := INF
	var d_hist := INF
	for spec: Dictionary in plan.city_buildings():
		if int(spec.get("floors", 1)) < 2:
			continue
		var rect: Rect2 = spec["rect"]
		# Only buildings inside the materialised city core: far-flung plots
		# (10 km out) have no terrain or neighbours when chunk-built here.
		if rect.get_center().length() > 300.0:
			continue
		var d := rect.get_center().length_squared()
		var bid := str(spec.get("id", ""))
		if bid.begins_with("historic_block_"):
			if d < d_hist and rect.size.x >= 7.0:
				d_hist = d
				historic = spec
			continue
		if spec.has("wing_role") and str(spec["wing_role"]) != "front":
			continue
		if rect.size.x >= 12.0:
			if d < d_merged:
				d_merged = d
				merged = spec
		elif rect.size.x >= 5.0 and d < d_small:
			d_small = d
			small = spec
	var out: Array = []
	for pair: Array in [[small, "small_house"], [merged, "merged_block"], [historic, "historic_house"]]:
		if not (pair[0] as Dictionary).is_empty():
			out.append({"spec": pair[0], "what": pair[1]})
	out.append(_pick_role(plan, "side", "side_wing"))
	out.append(_pick_role(plan, "rear", "rear_wing"))
	var kept: Array = []
	for entry: Dictionary in out:
		if not (entry["spec"] as Dictionary).is_empty():
			kept.append(entry)
	return kept


## Nearest city building with the given wing_role, so side/rear wings (the ones
## the player walks into from a courtyard, not the street) are covered too.
func _pick_role(plan: CityPlan, role: String, what: String) -> Dictionary:
	var best := {}
	var best_d := INF
	for spec: Dictionary in plan.city_buildings():
		if int(spec.get("floors", 1)) < 2:
			continue
		if str(spec.get("wing_role", "")) != role:
			continue
		var wr: Rect2 = spec["rect"]
		if wr.get_center().length() > 300.0:
			continue
		var d := wr.get_center().length_squared()
		if d < best_d:
			best_d = d
			best = spec
	return {"spec": best, "what": what}

func _pass(plan: CityPlan, world: WorldPlan, spec: Dictionary, what: String) -> void:
	var tag := str(spec.get("id", "?"))
	var fp: Rect2 = spec["rect"]
	var yaw := float(spec.get("yaw", 0.0))
	var centre := fp.get_center()
	var coord: Vector2i = spec.get("owner_chunk", WorldSeed.chunk_coord(centre.x, centre.y))
	var holder := _holder
	for x in range(coord.x - 1, coord.x + 2):
		for z in range(coord.y - 1, coord.y + 2):
			var c := Vector2i(x, z)
			if _built.has(c):
				continue
			_built[c] = true
			TerrainChunkBuilder.materialize(holder, TerrainChunkBuilder.build_manifest(world, c))
			var batcher: MeshBatcher = MeshBatcherScript.new()
			ChunkBuilderScript.fill_batcher(batcher, plan, c, world)
			ChunkBuilderScript.build(holder, plan, c, batcher, {}, true, true, world)
			var node: Node3D = holder.get_node_or_null(NodePath("Chunk_%d_%d" % [c.x, c.y]))
			if node != null:
				_chunks[c] = node
				_batchers[c] = batcher
			await get_tree().process_frame
	var chunk: Node3D = _chunks.get(coord, null)
	var batcher: MeshBatcher = _batchers.get(coord, null)
	if chunk == null or batcher == null:
		print("[RoomPerception] %s: chunk %s missing" % [what, str(coord)])
		return
	var plan_data: Dictionary = InteriorPlan.build_for_building(spec)
	var floors: Array = plan_data.get("floors", [])
	var ground := float(spec.get("planned_ground_y", 0.0))
	var fh := float(spec.get("floor_h", 3.0))
	print("[RoomPerception] %s id=%s floors=%d size=%.1fx%.1f fh=%.2f yaw=%.2f at=(%.0f,%.0f) chunk=%s" % [
		what, tag, floors.size(), fp.size.x, fp.size.y, fh, yaw, centre.x, centre.y, str(coord)])
	for fi in range(mini(floors.size(), 3)):
		var fl: Dictionary = floors[fi]
		var rooms: Array = fl.get("rooms", [])
		var parts: Array = fl.get("partitions", [])
		_audit(what, fi, fp, rooms, parts)
		var y := ground + float(fi) * fh
		# Dollhouse: everything above this storey hidden, camera in a tilted
		# bird's-eye (a straight-down look_at is degenerate and renders sky).
		await _gate_and_shot(batcher, chunk, tag, fi, [],
				"%s_f%d_dollhouse" % [what, fi],
				Vector3(centre.x + 7.0, y + 13.0, centre.y + 9.0), Vector3(centre.x, y, centre.y), fi, fp, yaw)
		# Same camera, OLD storey-wide cut rule. This is the comparison the
		# "walls cut in half" complaint is about: every wall on the floor loses
		# its plaster regardless of where the camera is.
		await _gate_and_shot(batcher, chunk, tag, fi, [],
				"%s_f%d_dollhouse_oldrule" % [what, fi],
				Vector3(centre.x + 7.0, y + 13.0, centre.y + 9.0), Vector3(centre.x, y, centre.y),
				fi, fp, yaw, true)
		# Eye height inside the biggest rooms of this storey.
		var ordered: Array = rooms.duplicate()
		ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return (a["rect"] as Rect2).get_area() > (b["rect"] as Rect2).get_area())
		for i in range(mini(ordered.size(), 2)):
			var room: Dictionary = ordered[i]
			var rr: Rect2 = room["rect"]
			var near := _to_world(fp, yaw, rr.position + rr.size * 0.18)
			var far := _to_world(fp, yaw, rr.end - rr.size * 0.18)
			await _shot("%s_f%d_%d_%s" % [what, fi, i, String(room.get("kind", "room"))],
					Vector3(near.x, y + 1.62, near.y), Vector3(far.x, y + 1.25, far.y))
		# Same viewpoint with the gate RELEASED: full geometry including the
		# ceiling/floor above, so "in-game dollhouse look" and "what is really
		# built" can be told apart instead of blamed on each other.
		_release(batcher)
		if not rooms.is_empty():
			var r0: Rect2 = (ordered[0] as Dictionary)["rect"]
			var n0 := _to_world(fp, yaw, r0.position + r0.size * 0.18)
			var f0p := _to_world(fp, yaw, r0.end - r0.size * 0.18)
			await _shot("%s_f%d_full_geometry" % [what, fi],
					Vector3(n0.x, y + 1.62, n0.y), Vector3(f0p.x, y + 1.25, f0p.y))

## Room rectangles as the player experiences them: do they poke out of the
## envelope, pinch to a sliver, sit with no partition at all, or have no way in
## from the entry room?
func _audit(what: String, fi: int, fp: Rect2, rooms: Array, parts: Array) -> void:
	var outside := 0
	var slivers := 0
	var area := 0.0
	var adjacency := {}
	var linked := {}
	for i in range(rooms.size()):
		var ra: Rect2 = rooms[i]["rect"]
		area += ra.get_area()
		if not fp.grow(0.05).encloses(ra):
			outside += 1
			print("[RoomPerception]   OUTSIDE %s f%d room=%s rect=%.2f,%.2f %.2fx%.2f" % [
				what, fi, str(rooms[i]["id"]), ra.position.x, ra.position.y, ra.size.x, ra.size.y])
		if minf(ra.size.x, ra.size.y) < 0.9:
			slivers += 1
			print("[RoomPerception]   SLIVER  %s f%d room=%s %.2fx%.2f" % [
				what, fi, str(rooms[i]["id"]), ra.size.x, ra.size.y])
	for p: Dictionary in parts:
		var a := str(p.get("a", ""))
		var b := str(p.get("b", ""))
		linked[a] = true
		linked[b] = true
		var opening: Variant = p.get("opening", null)
		if opening is Rect2 and (opening as Rect2).get_area() > 0.01:
			if not adjacency.has(a):
				adjacency[a] = []
			if not adjacency.has(b):
				adjacency[b] = []
			adjacency[a].append(b)
			adjacency[b].append(a)
	var orphan := 0
	for room: Dictionary in rooms:
		if not linked.has(str(room["id"])):
			orphan += 1
	var entry_id := ""
	for room: Dictionary in rooms:
		if bool(room.get("entry", false)):
			entry_id = str(room["id"])
	if entry_id == "" and not rooms.is_empty():
		entry_id = str(rooms[0]["id"])
	var seen := {entry_id: true}
	var queue: Array = [entry_id]
	while not queue.is_empty():
		var cur: String = queue.pop_back()
		for nxt: String in (adjacency.get(cur, []) as Array):
			if not seen.has(nxt):
				seen[nxt] = true
				queue.append(nxt)
	var unreachable := 0
	for room: Dictionary in rooms:
		if not seen.has(str(room["id"])):
			unreachable += 1
			print("[RoomPerception]   UNREACHABLE %s f%d room=%s kind=%s" % [
				what, fi, str(room["id"]), String(room.get("kind", "?"))])
	var footprint := fp.get_area()
	print("[RoomPerception]   %s f%d rooms=%d partitions=%d room_area=%.1f (%.0f%% of %.1f) outside=%d slivers=%d no_partition=%d unreachable=%d" % [
		what, fi, rooms.size(), parts.size(), area, 100.0 * area / maxf(footprint, 0.01),
		footprint, outside, slivers, orphan, unreachable])

func _to_world(fp: Rect2, yaw: float, local: Vector2) -> Vector2:
	return CityPlan._rotate_plan_point(fp.get_center(), local, yaw)

func _find_chunk_unused(holder: Node3D, coord: Vector2i) -> Node3D:
	var want := "Chunk_%d_%d" % [coord.x, coord.y]
	for child in holder.get_children():
		if child.name == want:
			return child as Node3D
	return null

## Same reveal rules ChunkManager.apply_floor_gate uses, via MeshBatcher — the
## camera->player sightline included, so interior walls are cut exactly the way
## they are cut in game. legacy_cut_all reproduces the OLD storey-wide rule (every
## interior wall on the player's floor cut above the picture rail, wherever the
## camera is) so the two rules can be photographed from one camera.
func _gate_and_shot(batcher: MeshBatcher, chunk_node: Node3D, tag: String, max_floor: int,
		faded: Array, label: String, cam_pos: Vector3, cam_target: Vector3,
		roof_floor: int = -1, fp: Rect2 = Rect2(), yaw: float = 0.0,
		legacy_cut_all: bool = false) -> void:
	var sight_from := Vector2.INF
	var sight_to := Vector2.INF
	if fp.size != Vector2.ZERO:
		var fc := fp.get_center()
		sight_from = CityPlan._rotate_plan_point(fc, Vector2(cam_pos.x, cam_pos.z), -yaw) - fp.position
		sight_to = CityPlan._rotate_plan_point(fc, Vector2(cam_target.x, cam_target.z), -yaw) - fp.position
	var hidden := 0
	var wallcuts := 0
	var wallcuts_cut := 0
	var caps := 0
	var caps_cut := 0
	for key: String in batcher.layer_nodes.keys():
		var hide := MeshBatcher.reveal_layer_hidden(key, tag, max_floor, faded, roof_floor,
				sight_from, sight_to)
		var is_wall := key.contains(MeshBatcher.WALL_CUT_PREFIX)
		var is_cap := key.contains(MeshBatcher.CEIL_CUT_PREFIX)
		if legacy_cut_all and is_wall and key.begins_with(tag + ":f%d:" % max_floor):
			hide = true
		if is_wall:
			wallcuts += 1
			if hide:
				wallcuts_cut += 1
		if is_cap:
			caps += 1
			if hide:
				caps_cut += 1
		var node: Node = batcher.layer_nodes[key]
		if node != null and is_instance_valid(node):
			var mi := node as MeshInstance3D
			if mi != null:
				mi.cast_shadow = MeshInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
						if hide else MeshInstance3D.SHADOW_CASTING_SETTING_ON
				mi.visible = true
		if hide:
			hidden += 1
	print("[RoomPerception] %s max_floor=%d hidden_layers=%d/%d walls_cut=%d/%d ceiling_caps_cut=%d/%d" % [
		label, max_floor, hidden, batcher.layer_nodes.size(),
		wallcuts_cut, wallcuts, caps_cut, caps])
	await _shot(label, cam_pos, cam_target)

## Gate released: every layer draws again (shadows-only flag cleared), so the
## full built geometry — ceiling and storey above included — is visible.
func _release(batcher: MeshBatcher) -> void:
	for key: String in batcher.layer_nodes.keys():
		var node: Node = batcher.layer_nodes[key]
		if node != null and is_instance_valid(node):
			var mi := node as MeshInstance3D
			if mi != null:
				mi.cast_shadow = MeshInstance3D.SHADOW_CASTING_SETTING_ON
				mi.visible = true

func _shot(label: String, pos: Vector3, target: Vector3) -> void:
	camera.position = pos
	camera.look_at(target)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.save_png(output + "/" + label + ".png") != OK:
		failures += 1
		print("[RoomPerception] FAILED to save %s" % label)
	shots += 1

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
