extends Node
## Front-door perception pass: stands where a player stands when they walk up
## to a city building's entrance and renders the door three ways (3.4 m out at
## eye height, 1.9 m close, 40 deg off-axis), for the nearest buildings of each
## kind. Alongside each building it dumps every emitted box within 3.2 m of the
## doorway (tag/layer/size/material/offset), so the geometry crowding the
## entrance is identified from the builder's own output instead of guessed.
## Run: --q3frontdoorcap   (needs a real renderer)

const MeshBatcherScript = preload("res://world/streaming/mesh_batcher.gd")
const ChunkBuilderScript = preload("res://world/streaming/chunk_builder.gd")
const BuildingBuilderScript = preload("res://world/generation/building_builder.gd")

var camera: Camera3D
var output := ""
var failures := 0
var shots := 0
var _holder: Node3D
## Ablation: set RB_HIDE_TAGS="awning,portal" to build the same street with those
## named dressing pieces left out, so a capture pair shows exactly what one
## feature contributes to an entrance. RB_TAG names the pair's output suffix.
var _hide_tags := {}
var _doors_done := 0
var _suffix := ""
var _built := {}
var _batchers := {}
const DOOR_NEAR_M := 3.2
const PICKS := 12
const MULTI_SHOT := false

var _probe_only := false

func _ready() -> void:
	# Headless is fine for the geometry part: the near-door inventory that says
	# which dressing pieces crowd an entrance. Rendering needs a real renderer.
	_probe_only = DisplayServer.get_name() == "headless"
	for t: String in OS.get_environment("RB_HIDE_TAGS").split(",", false):
		_hide_tags[t.strip_edges()] = true
	_suffix = OS.get_environment("RB_TAG").strip_edges()
	if not _hide_tags.is_empty() or _suffix != "":
		print("[FrontDoor] ablation hide=%s suffix=%s" % [str(_hide_tags.keys()), _suffix])
	run()

func run() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 800))
	output = "res://.hermes/autopilot/reports/q3-front-door/%d" % WorldSeed.get_world_seed()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	_setup_light()
	var plan := CityPlan.new(WorldSeed.get_world_seed())
	var world := WorldPlan.new(WorldSeed.get_world_seed())
	_holder = Node3D.new()
	add_child(_holder)
	var picks := _pick_buildings(plan)
	print("[FrontDoor] picked %d buildings seed=%d" % [picks.size(), WorldSeed.get_world_seed()])
	for entry: Dictionary in picks:
		await _pass(plan, world, entry["spec"], str(entry["what"]))
	_census(plan)
	print("[FrontDoor] finished shots=%d failures=%d output=%s" % [shots, failures, output])
	get_tree().quit(failures)

## Geometry census: every box any building emitted, measured against that
## building's own footprint. The defects a player photographs are exactly the
## ones this catches - a slab or dressing piece that leaves the building it
## belongs to, a box that floats above the roof it should sit under, and
## absurdly large boxes.
func _census(plan: CityPlan) -> void:
	var info: Dictionary = {}
	var comp_ref: Dictionary = {}
	for spec: Dictionary in plan.city_buildings():
		var id := str(spec.get("id", ""))
		if id == "":
			continue
		var r: Rect2 = spec["rect"]
		var g := float(spec.get("planned_ground_y", 0.0))
		var cid := str(spec.get("compound_id", ""))
		info[id] = {"rect": r, "centre": r.get_center(), "yaw": float(spec.get("yaw", 0.0)),
			"ground": g, "top": g + float(spec.get("floors", 1)) * float(spec.get("floor_h", 3.0)),
			"compound": cid, "district": str(spec.get("district", ""))}
		if cid != "":
			comp_ref[cid] = r if not comp_ref.has(cid) else (comp_ref[cid] as Rect2).merge(r)
	var over_hi: Array = []
	var above: Array = []
	var giant: Array = []
	# Footprint dump: every building rect + yaw, so an offline pass can test
	# whether a building rotated inside its plot clips its neighbour.
	# Per-building roof/wall coverage: a footprint whose roof layer is missing or
	# smaller than the walls reads to a player as a sliced building with a bare
	# slab on top, especially from a rooftop.
	var cov := {}
	for coord: Vector2i in _batchers.keys():
		for s2: Dictionary in (_batchers[coord] as MeshBatcher)._specs:
			var id2 := str(s2.get("building_id", ""))
			if id2 == "":
				continue
			var lay := str(s2.get("layer", ""))
			var role := ""
			if lay.contains("roof"):
				role = "roof"
			elif lay.contains("wall") and not lay.contains("wallcut"):
				role = "wall"
			if role == "":
				continue
			var c2: Dictionary = cov.get(id2, {})
			for rr2: String in ["roof", "wall"]:
				var cur: Array = c2.get(rr2, [0.0, 0.0, 0.0, 0.0])
				if role == rr2:
					var sp: Vector3 = s2["size"]
					var pp: Vector3 = s2["pos"]
					cur[0] = minf(cur[0], pp.x - sp.x * 0.5)
					cur[1] = maxf(cur[1], pp.x + sp.x * 0.5)
					cur[2] = minf(cur[2], pp.z - sp.z * 0.5)
					cur[3] = maxf(cur[3], pp.z + sp.z * 0.5)
				c2[rr2] = cur
			cov[id2] = c2
	var no_roof: Array = []
	var thin_roof: Array = []
	var eaves: Array = []
	for id2: String in cov.keys():
		var c2: Dictionary = cov[id2]
		var has_r: bool = c2.has("roof")
		var has_w: bool = c2.has("wall")
		if has_w and not has_r:
			no_roof.append(id2)
		if has_r and has_w:
			var r2: Array = c2["roof"]
			var w2: Array = c2["wall"]
			var span_rx: float = r2[1] - r2[0]
			var span_rz: float = r2[3] - r2[2]
			var span_wx: float = w2[1] - w2[0]
			var span_wz: float = w2[3] - w2[2]
			if r2[0] - w2[0] > 0.8 or r2[2] - w2[2] > 0.8 or w2[1] - r2[1] > 0.8 or w2[3] - r2[3] > 0.8:
				thin_roof.append("%s roof=%.1fx%.1f wall=%.1fx%.1f" % [id2, span_rx, span_rz, span_wx, span_wz])
			var inset: float = maxf(maxf(w2[0] - r2[0], r2[1] - w2[1]), maxf(w2[2] - r2[2], r2[3] - w2[3]))
			if inset > 0.8:
				eaves.append("%s wall_inset=%.2f roof=%.1fx%.1f" % [id2, inset, span_rx, span_rz])
	print("[Census] roof_coverage buildings=%d no_roof=%d roof_misaligned=%d eaves=%d" % [cov.size(), no_roof.size(), thin_roof.size(), eaves.size()])
	for x2: String in no_roof.slice(0, 8):
		print("[Census] no_roof %s" % x2)
	for x2: String in thin_roof.slice(0, 8):
		print("[Census] roof_misaligned %s" % x2)
	for x2: String in eaves.slice(0, 8):
		print("[Census] eaves %s" % x2)
	var rf := FileAccess.open("res://.hermes/autopilot/reports/q3-rects.txt", FileAccess.WRITE)
	for spec: Dictionary in plan.city_buildings():
		var rr: Rect2 = spec["rect"]
		rf.store_line("%s|%s|%.3f|%.3f|%.3f|%.3f|%.4f|%d|%.3f|%s|%.3f" % [str(spec.get("id", "")), str(spec.get("kind", "")),
			rr.position.x, rr.position.y, rr.size.x, rr.size.y, float(spec.get("yaw", 0.0)),
			int(spec.get("floors", 1)), float(spec.get("planned_ground_y", 0.0)),
			str(spec.get("compound_id", "")), float(spec.get("floor_h", 3.0))])
	rf.close()
	var n_boxes := 0
	for coord: Vector2i in _batchers.keys():
		var b: MeshBatcher = _batchers[coord]
		for s: Dictionary in b._specs:
			n_boxes += 1
			var id := str(s.get("building_id", ""))
			if not info.has(id):
				continue
			var d: Dictionary = info[id]
			var ref: Rect2 = (comp_ref[d["compound"]] as Rect2) if d["compound"] != "" else (d["rect"] as Rect2)
			var pos: Vector3 = s["pos"]
			var size: Vector3 = s["size"]
			var basis: Basis = s.get("basis", Basis.IDENTITY)
			var yaw := float(d["yaw"])
			var p := CityPlan._rotate_plan_point(d["centre"], Vector2(pos.x, pos.z), -yaw)
			var ax := CityPlan._rotate_plan_vector(Vector2(basis.x.x, basis.x.z), -yaw).abs()
			var ay := CityPlan._rotate_plan_vector(Vector2(basis.y.x, basis.y.z), -yaw).abs()
			var az := CityPlan._rotate_plan_vector(Vector2(basis.z.x, basis.z.z), -yaw).abs()
			var hx := ax.x * size.x * 0.5 + ay.x * size.y * 0.5 + az.x * size.z * 0.5
			var hy := (absf(basis.x.y) * size.x + absf(basis.y.y) * size.y + absf(basis.z.y) * size.z) * 0.5
			var hz := ax.y * size.x * 0.5 + ay.y * size.y * 0.5 + az.y * size.z * 0.5
			var grow := ref.grow(-0.0)
			var ox := maxf(grow.position.x - (p.x - hx), (p.x + hx) - grow.end.x)
			var oz := maxf(grow.position.y - (p.y - hz), (p.y + hz) - grow.end.y)
			var out_m := maxf(ox, oz)
			var rec := {"id": id, "layer": str(s.get("layer", "")), "size": size,
				"plan": p, "over": out_m, "y": pos.y, "ady": pos.y - float(d["ground"])}
			if out_m > 0.6:
				over_hi.append(rec)
			if pos.y - hy > float(d["top"]) + 1.0:
				above.append(rec)
			if maxf(size.x, maxf(size.y, size.z)) > 12.0:
				giant.append(rec)
	print("[Census] boxes=%d buildings=%d out_of_footprint=%d above_roof=%d giant=%d" % [
		n_boxes, info.size(), over_hi.size(), above.size(), giant.size()])
	_dump_worst("out_of_footprint", over_hi)
	_dump_worst("above_roof", above)
	_dump_worst("giant", giant)
	var big_poly: Array = []
	for b2: MeshBatcher in _batchers.values():
		for ps: Dictionary in b2._polygon_specs:
			var pts: PackedVector2Array = ps.get("points", PackedVector2Array())
			if pts.size() < 3:
				continue
			var mn := pts[0]
			var mx := pts[0]
			for q: Vector2 in pts:
				mn = mn.min(q)
				mx = mx.max(q)
			var span := (mx - mn).length()
			if span > 12.0 and float(ps.get("y", 0.0)) > 4.0:
				big_poly.append({"layer": str(ps.get("layer", "")), "span": span, "y": float(ps.get("y", 0.0))})
	print("[Census] big_flat_polygons=%d" % big_poly.size())
	_dump_worst("big_flat_polygon", big_poly)

func _dump_worst(kind: String, rows: Array) -> void:
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("over", 0.0)) > float(b.get("over", 0.0)))
	var n := mini(rows.size(), 12)
	for i in n:
		var r: Dictionary = rows[i]
		if r.has("over"):
			print("[Census] %s %s layer=%s size=%.2fx%.2fx%.2f over=%.2f y=%.2f above_ground=%.2f" % [
				kind, str(r["id"]), str(r["layer"]), (r["size"] as Vector3).x, (r["size"] as Vector3).y,
				(r["size"] as Vector3).z, float(r["over"]), float(r["y"]), float(r["ady"])])
		else:
			print("[Census] %s layer=%s span=%.2f y=%.2f" % [kind, str(r["layer"]), float(r["span"]), float(r["y"])])


## Nearest buildings of each kind inside the materialised core, so every capture
## frames real geometry with neighbours standing (not a far-flung empty plot).
## Rooftop sweep target: 6 m in front of the door, at ground level - the
## frontage a player looks down on from a roof.
func body_c2(door_pos: Vector3, fwd: Vector3) -> Vector2:
	return Vector2(door_pos.x + fwd.x * 6.0, door_pos.z + fwd.z * 6.0)

func _pick_buildings(plan: CityPlan) -> Array:
	var only := OS.get_environment("RB_ONLY_ID").strip_edges()
	var cands: Array = []
	for spec: Dictionary in plan.city_buildings():
		if only != "" and str(spec.get("id", "")) != only:
			continue
		var rect: Rect2 = spec["rect"]
		if rect.get_center().length() > 260.0:
			continue
		if spec.has("compound_id") and str(spec.get("wing_role", "")) != "front":
			continue
		var bid := str(spec.get("id", ""))
		var what := "other"
		if bid.begins_with("historic_block_"):
			what = "historic"
		elif rect.size.x >= 12.0:
			what = "merged"
		elif rect.size.x >= 5.0:
			what = "small"
		cands.append({"spec": spec, "what": what, "d": rect.get_center().length_squared()})
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["d"] < b["d"])
	var out: Array = []
	var per_kind := {}
	for c: Dictionary in cands:
		var kind := str(c["what"])
		var n := int(per_kind.get(kind, 0))
		if n >= (3 if MULTI_SHOT else 12):
			continue
		per_kind[kind] = n + 1
		out.append({"spec": c["spec"], "what": "%s_%d" % [kind, n + 1]})
		if out.size() >= PICKS:
			break
	return out

func _pass(plan: CityPlan, world: WorldPlan, spec: Dictionary, what: String) -> void:
	var fp: Rect2 = spec["rect"]
	var yaw := float(spec.get("yaw", 0.0))
	var centre := fp.get_center()
	var coord: Vector2i = spec.get("owner_chunk", WorldSeed.chunk_coord(centre.x, centre.y))
	for x in range(coord.x - 1, coord.x + 2):
		for z in range(coord.y - 1, coord.y + 2):
			var c := Vector2i(x, z)
			if _built.has(c):
				continue
			_built[c] = true
			TerrainChunkBuilder.materialize(_holder, TerrainChunkBuilder.build_manifest(world, c))
			var batcher: MeshBatcher = MeshBatcherScript.new()
			ChunkBuilderScript.fill_batcher(batcher, plan, c, world)
			if not _hide_tags.is_empty():
				var kept: Array[Dictionary] = []
				for spec_s: Dictionary in batcher._specs:
					if _hide_tags.has(str(spec_s.get("building_id", ""))):
						continue
					kept.append(spec_s)
				batcher._specs = kept
			ChunkBuilderScript.build(_holder, plan, c, batcher, {}, true, true, world)
			_batchers[c] = batcher
			await get_tree().process_frame
	var batcher: MeshBatcher = _batchers.get(coord, null)
	if batcher == null:
		print("[FrontDoor] %s: no batcher for chunk %s" % [what, str(coord)])
		return
	var edge := int(spec.get("door_edge", 0))
	var local := BuildingBuilderScript._access_door_local(fp.size.x, fp.size.y, edge)
	var outv := BuildingBuilderScript._access_outward(edge)
	var door_plan := CityPlan._rotate_plan_point(centre, fp.position + local, yaw)
	var outward := CityPlan._rotate_plan_vector(outv, yaw).normalized()
	var ground := float(spec.get("planned_ground_y", 0.0))
	var door_y := ground + 1.05
	var door_pos := Vector3(door_plan.x, door_y, door_plan.y)
	print("[FrontDoor] %s id=%s district=%s edge=%d gate=%s at=(%.1f,%.1f) ground=%.2f floors=%d size=%.1fx%.1f" % [
		what, str(spec.get("id", "?")), str(spec.get("district", "?")), edge,
		str(spec.get("gate_kind", "-")), door_plan.x, door_plan.y, ground,
		int(spec.get("floors", 1)), fp.size.x, fp.size.y])
	_dump_near_door(batcher, door_plan, ground, outward)
	var fwd := Vector3(outward.x, 0.0, outward.y)
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	await _shot("%s_a_front" % what, door_pos + fwd * 3.4 + Vector3(0, 0.55, 0), door_pos)
	await _shot("%s_d_lookup%s" % [what, _suffix], door_pos + fwd * 2.4 + Vector3(0, 0.28, 0), door_pos + Vector3(0, 0.95, 0))
	_doors_done += 1
	if _doors_done <= 4:
		# Whole-building + aerial: the vantage a player gets standing on the
		# street or on a roof, where a mis-gated storey reads as a bare slab.
		var up_h := float(spec.get("floors", 1)) * float(spec.get("floor_h", 3.0))
		var body_c := CityPlan._rotate_plan_point(centre, fp.position + fp.size * 0.5, yaw)
		var body := Vector3(body_c.x, ground + up_h * 0.5, body_c.y)
		await _shot("%s_e_wide" % what, door_pos + fwd * 9.0 + Vector3(0, 4.5, 0), body)
		await _shot("%s_f_air" % what, door_pos + fwd * 7.0 + Vector3(0, up_h + 6.0, 0),
			Vector3(body_c.x, ground, body_c.y))
	if _doors_done <= 2:
		await _shot("%s_g_entrance" % what, door_pos + fwd * 5.0 + Vector3(0, 1.1, 0), door_pos + Vector3(0, -0.3, 0))
		await _shot("%s_h_roofview" % what, door_pos + fwd * 11.0 + Vector3(0, 13.0, 0),
			Vector3(body_c2(door_pos, fwd).x, ground + 1.0, body_c2(door_pos, fwd).y))
	if MULTI_SHOT or _doors_done <= 3:
		await _shot("%s_b_close" % what, door_pos + fwd * 1.9 + Vector3(0, 0.35, 0), door_pos + Vector3(0, 0.15, 0))
		await _shot("%s_c_offaxis" % what, door_pos + fwd * 3.2 + side * 2.4 + Vector3(0, 0.6, 0), door_pos)

## Everything the builder emitted within DOOR_NEAR_M of the doorway: the pieces
## that decide what an entrance looks like. Largest first.
func _dump_near_door(batcher: MeshBatcher, door_plan: Vector2, ground: float, outward: Vector2) -> void:
	var specs: Array = batcher._specs
	var near: Array = []
	for s: Dictionary in specs:
		var pos: Vector3 = s["pos"]
		var flat := Vector2(pos.x, pos.z).distance_to(door_plan)
		if flat > DOOR_NEAR_M:
			continue
		var rel_y := pos.y - ground
		if rel_y < -0.6 or rel_y > 4.2:
			continue
		var size: Vector3 = s["size"]
		var vol := size.x * size.y * size.z
		near.append({
			"vol": vol, "layer": str(s.get("layer", "")), "tag": str(s.get("building_id", "")),
			"size": size, "rel": Vector3(pos.x - door_plan.x, rel_y, pos.z - door_plan.y),
			"mat": str(s.get("material", "")), "collide": bool(s.get("collide", false)),
			"roof": bool(s.get("roof", false)),
		})
	near.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["vol"] > b["vol"])
	# Per-tag summary: what each named feature occupies beside the doorway.
	# `out` is metres outward from the facade plane through the door - the number
	# that decides whether a piece is pressed to the wall or hangs over the walk.
	var by_tag := {}
	for n: Dictionary in near:
		var k := str(n["tag"]) if str(n["tag"]) != "" else "(unnamed)"
		if not by_tag.has(k):
			by_tag[k] = {"n": 0, "y0": 99.0, "y1": -99.0, "o0": 99.0, "o1": -99.0, "v": 0.0}
		var e: Dictionary = by_tag[k]
		var rl: Vector3 = n["rel"]
		var out_m := Vector2(rl.x, rl.z).dot(outward)
		var sz: Vector3 = n["size"]
		e["n"] = int(e["n"]) + 1
		e["y0"] = minf(float(e["y0"]), rl.y)
		e["y1"] = maxf(float(e["y1"]), rl.y)
		e["o0"] = minf(float(e["o0"]), out_m)
		e["o1"] = maxf(float(e["o1"]), out_m)
		e["v"] = maxf(float(e["v"]), sz.x * sz.y * sz.z)
	var tags: Array = by_tag.keys()
	tags.sort_custom(func(a: String, b: String) -> bool: return int(by_tag[a]["n"]) > int(by_tag[b]["n"]))
	for t: String in tags:
		var e: Dictionary = by_tag[t]
		print("[FrontDoor]   %-26s n=%-3d y=%.2f..%.2f out=%+.2f..%+.2f maxvol=%.2f" % [
			t, int(e["n"]), float(e["y0"]), float(e["y1"]), float(e["o0"]), float(e["o1"]), float(e["v"])])
	# Entrance clearance: a box that leaves the wall face over the opening at
	# canopy height (2.0-2.9 m) is a marquee hanging over the front door - the
	# exact defect this pass exists to keep out.
	var tangent := Vector2(-outward.y, outward.x)
	var over: Array = []
	for n: Dictionary in near:
		var rl2: Vector3 = n["rel"]
		var sz2: Vector3 = n["size"]
		var out_m2 := Vector2(rl2.x, rl2.z).dot(outward)
		var lat := absf(Vector2(rl2.x, rl2.z).dot(tangent))
		if out_m2 < 0.35 or lat > 0.9:
			continue
		if rl2.y + sz2.y * 0.5 < 2.0 or rl2.y - sz2.y * 0.5 > 2.9:
			continue
		over.append("%s out=%+.2f y=%+.2f %.2fx%.2fx%.2f" % [
			(str(n["tag"]) if str(n["tag"]) != "" else "?"), out_m2, rl2.y, sz2.x, sz2.y, sz2.z])
	print("[FrontDoor]   overhang over doorway: %d %s" % [over.size(), over.slice(0, 3)])
	print("[FrontDoor]   %d boxes within %.1f m of the door" % [near.size(), DOOR_NEAR_M])
	for i in range(mini(near.size(), 4)):
		var n: Dictionary = near[i]
		var sz: Vector3 = n["size"]
		var rl: Vector3 = n["rel"]
		print("[FrontDoor]   #%02d layer=%-28s tag=%-22s size=%.2fx%.2fx%.2f off=(%+.2f,%+.2f,%+.2f) mat=%s collide=%s roof=%s" % [
			i, n["layer"].substr(0, 28), n["tag"].substr(0, 22),
			sz.x, sz.y, sz.z, rl.x, rl.y, rl.z, n["mat"], str(n["collide"]), str(n["roof"])])

func _shot(label: String, pos: Vector3, target: Vector3) -> void:
	if _probe_only:
		return
	camera.position = pos
	camera.look_at(target)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.save_png(output + "/" + label + ".png") != OK:
		failures += 1
		print("[FrontDoor] FAILED to save %s" % label)
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
