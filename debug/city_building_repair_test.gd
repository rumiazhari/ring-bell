extends Node3D

var failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		failures += 1
		print("[BuildingRepair] FAIL: ", label)

func _ready() -> void:
	_run()

func _run() -> void:
	if OS.get_cmdline_user_args().has("--city-plan-check"):
		var city := CityPlan.new()
		var uses := {}
		var buildings := city.city_buildings()
		for spec: Dictionary in buildings:
			var size: Vector2 = (spec["rect"] as Rect2).size
			check("generated minimum footprint " + str(spec["id"]), size.x >= 10.0 and size.y >= 14.0)
			uses[str(spec["use"])] = true
		for use: String in InteriorPlan.ROOM_PROGRAMS:
			check("city generates " + use, uses.has(use))
		print("[BuildingRepair] city buildings=%d uses=%s" % [buildings.size(), str(uses.keys())])
	var light := DirectionalLight3D.new()
	# Horror pass: the audit captures were lit like a bright showroom, which made
	# decayed surfaces read as "clean". Captures now use a bleak, overcast
	# late-dusk key so grime, damp and the failing gaslight pools are visible.
	# This is FIXTURE lighting only - gameplay lighting stays with
	# DayNightController (sun/moon/ambient/fog) and is not changed here.
	light.rotation_degrees = Vector3(-62, -38, 0)
	light.light_energy = 0.45
	light.light_color = Color(0.58, 0.63, 0.72)
	add_child(light)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(10, 25, 21)
	camera.look_at(Vector3(8, 0, 10))
	camera.current = true
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("2b3138")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Cold, low ambient so the gaslight pools (below) carry the interior.
	environment.environment.ambient_light_color = Color(0.52, 0.58, 0.68)
	environment.environment.ambient_light_energy = 0.16
	environment.environment.fog_enabled = true
	environment.environment.fog_light_color = Color("31363c")
	environment.environment.fog_density = 0.012
	add_child(environment)
	for use: String in InteriorPlan.ROOM_PROGRAMS:
		for edge in 4:
			var small_spec := {"id": "minimum_" + use, "rect": Rect2(0, 0, 10, 14), "floors": 2, "floor_h": 3.1, "door_edge": edge, "use": use}
			var small_manifest := InteriorPlan.build_for_building(small_spec)
			check(use + " minimum valid edge %d" % edge, InteriorPlan.validate(small_manifest).is_empty())
			for fl: Dictionary in small_manifest["floors"]:
				for room: Dictionary in fl["rooms"]:
					var found: bool = room["kind"] == &"hall"
					for item: Dictionary in fl["furniture"]:
						if item["room_id"] == room["id"]:
							found = true
					check(use + " minimum furniture " + String(room["kind"]) + " edge %d" % edge, found)
	for use: String in InteriorPlan.ROOM_PROGRAMS:
		var spec := {"id": "repair_" + use, "rect": Rect2(0, 0, 16, 20), "floors": 2, "floor_h": 3.1, "door_edge": 0, "use": use, "district": &"historic", "style": {"room_type": use, "wall": 0, "roof": 0}, "doors": [], "ruin_override": 1.0, "dress_override": 1.0}
		var manifest := InteriorPlan.build_for_building(spec)
		check(use + " deterministic", manifest == InteriorPlan.build_for_building(spec))
		check(use + " valid room graph", InteriorPlan.validate(manifest).is_empty())
		# G10 steering: ground floor is a lobby + toilet; use-program rooms live
		# on upper floors, so program-kind coverage is checked across ALL floors.
		var room_kinds: Array = []
		for floor_data: Dictionary in manifest["floors"]:
			for room: Dictionary in floor_data["rooms"]:
				room_kinds.append(String(room["kind"]))
				var found := false
				for item: Dictionary in floor_data["furniture"]:
					if item["room_id"] != room["id"]:
						continue
					found = true
					check(use + " furniture contained", (room["rect"] as Rect2).encloses(item["rect"]))
					check(use + " bed restricted", item["kind"] != "bed" or String(room["kind"]) in ["sleeping", "ward"])
				check(use + " furnished " + String(room["kind"]), found or room["kind"] in [&"hall", &"lobby", &"toilet"])
		for kind in InteriorPlan.ROOM_PROGRAMS[use]:
			check(use + " includes " + String(kind), room_kinds.has(String(kind)))
		for floor_data: Dictionary in manifest["floors"]:
			var items: Array = floor_data["furniture"]
			for i in items.size():
				for j in range(i + 1, items.size()):
					check(use + " furniture overlap", not (items[i]["rect"] as Rect2).intersects(items[j]["rect"]))
		var holder := Node3D.new()
		add_child(holder)
		var batcher := MeshBatcher.new()
		BuildingBuilder.build(batcher, spec)
		batcher.flush_into(holder)
		# Mirror ChunkBuilder's interior lighting so captures show the real
		# gaslight/hearth pools (the repair harness does not stream chunks).
		var lit := 0
		for entry: Dictionary in batcher.interior_lights():
			if lit >= 40:
				break
			var il := OmniLight3D.new()
			il.name = "InteriorLight_%d" % lit
			il.position = entry["pos"]
			var is_fire: bool = entry["kind"] == "fire"
			il.omni_range = 10.5 if is_fire else 9.0
			il.omni_attenuation = 1.6
			il.light_energy = 2.6 if is_fire else 2.2
			il.light_color = Color(1.0, 0.55, 0.22) if is_fire else Color(1.0, 0.78, 0.42)
			il.shadow_enabled = false
			# Mirror the runtime rule: hearths burn day or night, gas only at night.
			il.visible = is_fire or GameClock.is_night()
			holder.add_child(il)
			lit += 1
		print("[BuildingRepair] %s interior lights=%d" % [use, lit])
		var live_doors: Array[Door] = []
		for dm: Dictionary in manifest["floors"][0]["doors"]:
			var leaf := Door.new()
			leaf.setup(dm)
			holder.add_child(leaf)
			leaf.open()
			live_doors.append(leaf)
		for tick in 100:
			await get_tree().physics_frame
		for leaf: Door in live_doors:
			check(use + " room doorway physically clears " + str(leaf.manifest["id"]), leaf.is_passage_clear())
		for key: String in batcher.layer_nodes:
			batcher.layer_nodes[key].visible = not MeshBatcher.reveal_layer_hidden(key, spec["id"], 0, ["S"])
		await get_tree().process_frame
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var dir := "res://captures/building-repair"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			get_viewport().get_texture().get_image().save_png(dir + "/" + use + ".png")
			# Eye-level interior view so wall dressing (wainscot/ochre/gaslamp)
			# is judged as the player sees it, not from the top-down audit cam.
			# Aimed slightly UP so the ceiling line (cornice + joists) is in
			# frame together with the far wall and door casing.
			camera.position = Vector3(7.2, 1.6, 15.2)
			camera.look_at(Vector3(10.5, 2.6, 2.6))
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(dir + "/" + use + "_eye.png")
			camera.position = Vector3(10, 25, 21)
			camera.look_at(Vector3(8, 0, 10))
		holder.queue_free()
		await get_tree().process_frame
	# Ground datum and rotated footprints.
	var elevated := {"rect": Rect2(0, 0, 16, 20), "floor_h": 3.1, "floors": 3, "building_ground_y": 8.0, "yaw": 0.6}
	check("raised building ground floor", InteriorProbe.evaluate(Vector2(8, 10), 8.0, elevated, false)["floor"] == 0)
	check("below raised building outside", not InteriorProbe.evaluate(Vector2(8, 10), 0, elevated, false)["inside"])
	# Window damage must preserve the resources of unrelated layers.
	var holder := Node3D.new()
	add_child(holder)
	var batcher := MeshBatcher.new()
	batcher.push_layer("wall")
	batcher.add_structural_box(Vector3.ZERO, Vector3.ONE, Color.WHITE)
	batcher.pop_layer()
	batcher.push_layer("pane")
	batcher.add_destructible_box(Vector3(2, 0, 0), Vector3(1, 1, 0.05), Color.WHITE, &"glass")
	batcher.pop_layer()
	batcher.flush_into(holder)
	var old_wall: Mesh = batcher.layer_nodes["wall"].mesh
	var pane_id := int(batcher.specs().back()["id"])
	batcher.damage_box(pane_id, 10.0)
	var saved_damage := batcher.damage_state()
	batcher.load_damage_state(saved_damage)
	check("cracked pane state restored", batcher.get("_cracked").has(pane_id))
	batcher.refresh_meshes()
	check("crack preserves unrelated mesh", batcher.layer_nodes["wall"].mesh == old_wall)
	batcher.damage_box(pane_id, 20.0)
	batcher.refresh_meshes()
	check("shatter preserves unrelated mesh", batcher.layer_nodes["wall"].mesh == old_wall)
	check("shattered pane removed", not batcher.layer_nodes.has("pane|g"))
	holder.queue_free()
	# All hinge sides and facade edges must physically open and close.
	for edge in 4:
		for hinge in ["left", "right"]:
			var door := Door.new()
			door.setup({"id": "test_door", "position": Vector3.ZERO, "width": 1.5, "height": 2.25, "edge": edge, "yaw": edge * PI * 0.5, "hinge": hinge})
			add_child(door)
			check("closed aperture blocks", not door.is_passage_clear())
			door.open()
			for tick in 100:
				await get_tree().physics_frame
			check("door opens edge %d %s" % [edge, hinge], door.is_open() and door.is_passage_clear())
			door.close()
			for tick in 100:
				await get_tree().physics_frame
			check("door closes edge %d %s" % [edge, hinge], not door.is_open() and not door.is_passage_clear())
			door.queue_free()
			await get_tree().physics_frame
	print("[BuildingRepair] finished with %d failure(s)" % failures)
	get_tree().quit(0 if failures == 0 else 1)
