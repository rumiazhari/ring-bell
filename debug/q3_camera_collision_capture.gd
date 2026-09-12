extends Node
## Camera-collision A/B capture (frontend, player-perceived).
##
## The presentation rig (camera/follow_camera.gd) is an elevated boom 6-26 m back
## and up from the player. It had NO collision, so in a dense street the lens
## ends up INSIDE a building and the player's whole frame becomes the interior
## face of that roof/floor slab - "a giant flat slab across the view, nothing
## supporting it, clipping the neighbour".
##
## This harness stands the REAL FollowCamera rig at deterministic street spots
## beside a tall building and renders each one, printing
##   boom  = the length the rig actually rendered
##   occl  = an INDEPENDENT ray from the lens to the player's chest (true means
##           the lens is behind/inside geometry, i.e. the player sees a slab)
##
## Run it twice:
##   RB_TAG=camcoll_off RB_CAM_COLLIDE=0 python tools/run_suite.py --q3camcollcap 240 --rendered
##   RB_TAG=camcoll_on  RB_CAM_COLLIDE=1 python tools/run_suite.py --q3camcollcap 240 --rendered
##
## OFF is the reported defect; ON is the fix. Spot 3 is an open-street control:
## its boom must stay at the full presentation length in BOTH runs.

const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")
const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
const BuildingBuilderScript = preload("res://world/generation/building_builder.gd")

const OUT_DIR := "res://.hermes/autopilot/reports/q3-camera-collision"
const SPOT_COUNT := 3
const STAND_OFF_M := 1.6           # metres outside the facade the player stands
const CHEST_H := 1.05
const MIN_FLOORS := 3

var failures := 0
var shots := 0
var output := OUT_DIR
var _probe_only := false
var _holder: Node3D = null
var _built := {}
var _camera: Camera3D = null


func _ready() -> void:
	run()


func run() -> void:
	_probe_only = not OS.get_cmdline_user_args().has("--rendered")
	output = "%s/%s" % [OUT_DIR, OS.get_environment("RB_TAG")]
	if not _probe_only:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	DisplayServer.window_set_size(Vector2i(1280, 800))
	_setup_light()
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	_holder = Node3D.new()
	_holder.name = "CamCollWorld"
	add_child(_holder)

	var spots := _pick_spots(plan)
	print("[CamColl] collide=%s spots=%d seed=%d" % [
		OS.get_environment("RB_CAM_COLLIDE") if OS.get_environment("RB_CAM_COLLIDE") != "" else "1",
		spots.size(), WorldSeed.get_world_seed()])
	for i in range(spots.size()):
		await _measure(plan, world, spots[i], i + 1)
	print("[CamColl] finished shots=%d failures=%d output=%s" % [shots, failures, output])
	get_tree().quit(0 if failures == 0 else 1)


## Spot 1: in front of a multi-storey building, boom aimed INTO it.
## Spot 2: the same frontage from the other side (boom crosses the facade).
## Spot 3: the plaza/centre anchor - open ground for the control shot.
func _pick_spots(plan: CityPlan) -> Array:
	var out: Array = []
	var near: Array = []
	var centre := Vector2.ZERO
	for spec: Dictionary in plan.city_buildings():
		var fp: Rect2 = spec["rect"]
		if int(spec.get("floors", 1)) < MIN_FLOORS:
			continue
		near.append({"spec": spec, "d": fp.get_center().distance_to(centre)})
	near.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["d"]) < float(b["d"]))
	for entry: Dictionary in near:
		if out.size() >= SPOT_COUNT - 1:
			break
		out.append(entry["spec"])
	if not near.is_empty():
		out.append(near[near.size() - 1]["spec"])   # far edge of the core = control
	return out


func _measure(plan: CityPlan, world: WorldPlan, spec: Dictionary, index: int) -> void:
	var fp: Rect2 = spec["rect"]
	var yaw := float(spec.get("yaw", 0.0))
	var centre := fp.get_center()
	var coord: Vector2i = spec.get("owner_chunk", WorldSeed.chunk_coord(centre.x, centre.y))
	await _build_ring(plan, world, coord)

	var edge := int(spec.get("door_edge", 0))
	var local := BuildingBuilderScript._access_door_local(fp.size.x, fp.size.y, edge)
	var outv := BuildingBuilderScript._access_outward(edge)
	var outward := CityPlan._rotate_plan_vector(outv, yaw).normalized()
	var door_plan := CityPlan._rotate_plan_point(centre, fp.position + local, yaw)
	var ground := float(spec.get("planned_ground_y", 0.0))
	# The player stands just clear of the facade; the boom then reaches back over
	# the building itself, which is what puts the lens inside it.
	var stand := Vector3(door_plan.x, ground, door_plan.y) + Vector3(outward.x, 0, outward.y) * (STAND_OFF_M + 0.9)
	var to_building := Vector3(centre.x - stand.x, 0, centre.y - stand.z).normalized()
	if index == SPOT_COUNT:
		# Control: aim the boom the other way, out over open ground.
		to_building = -to_building

	var dummy := Node3D.new()
	dummy.name = "CamTarget%d" % index
	add_child(dummy)
	dummy.global_position = stand

	var rig: Node3D = load("res://camera/follow_camera.gd").new()
	rig.name = "CamRig%d" % index
	add_child(rig)
	rig.set("target", dummy)
	rig.global_position = stand
	rig.set("_yaw", atan2(to_building.x, to_building.z))
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().process_frame

	var lens: Vector3 = rig.call("camera_world_position")
	var chest := stand + Vector3(0, CHEST_H, 0)
	var space := _holder.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(chest, lens)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	var occluded := not hit.is_empty()
	var blocked_m := 0.0
	if occluded:
		blocked_m = chest.distance_to(hit["position"])
	print("[CamColl] spot=%d id=%s boom=%.2f lens_y=%.2f chest_to_lens=%.2f blocked_at=%.2f occluded=%s" % [
		index, str(spec.get("id", "?")), float(rig.get("_boom")), lens.y,
		chest.distance_to(lens), blocked_m, str(occluded)])
	if _probe_only:
		return
	var cam: Camera3D = rig.get("_camera")
	if cam != null:
		cam.current = true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.save_png("%s/spot%d.png" % [output, index]) != OK:
		failures += 1
		print("[CamColl] FAILED to save spot%d" % index)
	shots += 1
	# One rig at a time: a freed rig cannot steal `current` from the next shot.
	rig.queue_free()
	dummy.queue_free()


func _build_ring(plan: CityPlan, world: WorldPlan, coord: Vector2i) -> void:
	for x in range(coord.x - 1, coord.x + 2):
		for z in range(coord.y - 1, coord.y + 2):
			var c := Vector2i(x, z)
			if _built.has(c):
				continue
			_built[c] = true
			TerrainChunkBuilder.materialize(_holder,
					TerrainChunkBuilder.build_manifest(world, c))
			var batcher: MeshBatcher = MeshBatcherScript.new()
			ChunkBuilderScript.fill_batcher(batcher, plan, c, world)
			# include_collision = true: the rig must collide with the real walls.
			ChunkBuilderScript.build(_holder, plan, c, batcher, {}, true, true, world)
			await get_tree().process_frame


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
