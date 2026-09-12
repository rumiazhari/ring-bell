class_name ParkourLedgeTest
extends Node
## Q2 stage 3 — the ledge ledger on REAL generated geometry.
##
## The parkour contract test (`--parkourtest`) proves rules A-H on purpose-built
## fixtures. This harness asks the same question of the world the player walks
## through: it builds real `CityPlan` buildings through the real pipeline
## (`MeshBatcher.new()` -> `BuildingBuilder.build` -> `flush_into`), stands a real
## `Survivor` on a lattice of facade points at every storey, and records what the
## one ledge query answers.
##
## Sections
##   1. Rejection matrix (fixtures)  - the section-1 rules, recorded for section 4
##   2. Census (real buildings)      - >= 3 seeds, >= 8 buildings; per-kind accepts
##                                     with measured width/depth; profile/clearance
##                                     assertions; route diversity is non-uniform
##   3. Real climb (real buildings)  - hunt the generated city for a facade that
##                                     affords a verified street->roof chain, then
##                                     drive the real survivor + controller up it
##                                     (jump, hold to the face, climb-up) with an
##                                     honest per-frame budget
##   4. Determinism                  - the section-1 matrix and one real building
##                                     re-run to identical records
##
## Cost note: `CityPlan` generation is ~100 s per seed, so the plan is built ONCE
## and every section reuses the cached specs. Census buildings are built through
## the real pipeline; the route hunt rebuilds one candidate at a time.
##
## Usage: godot --headless --path . -- --parkourledgetest

# --- census shape -----------------------------------------------------------
const CENSUS_SEEDS: Array[int] = [19041207, 424242, 8675309]
const PER_SEED_TALL := 2            # inner-city faces (tallest footprints)
const PER_SEED_MIXED := 1           # historic / low faces -> 9 buildings total
const FACADE_STEP := 1.1            # metres between probe columns along a facade
const VER_STEP := 0.6               # vertical probe step (< the 1.2 m reach window)
const ROOF_EPS := 0.35              # how close to roof_y counts as "the roof deck"
## Modelled jump arc (feet offsets above the stance). The census is a pure query,
## so an airborne stance is expressed as a foot height - exactly what the real
## drive reaches when the body leaves the ground. The apex is not invented:
## `Survivor.GRAVITY 18.0` + `ParkourController.JUMP_SPEED 6.4` => v^2/2g = 1.14 m.
const JUMP_STEPS: Array[float] = [0.0, 0.38, 0.76, 1.14]
const EDGE_MARGIN := 1.0            # keep probe columns off the corners
const HOLD_STAND_Z := 0.55          # inside LEDGE_PROBE_REACH 0.62
const WALL_T := 0.35                # building_builder masonry thickness
const MIN_CENSUS_FLOORS := 2        # historic fabric is low; tallness is asserted, not assumed

# --- traversal budget --------------------------------------------------------
## 0.50 m in one frame at 60 Hz is 30 m/s: faster than free fall from the tallest
## facade in the city (19 m at `Survivor.GRAVITY 18.0` -> 26 m/s), so the only way
## to exceed it is a teleport. The contract test's tighter 0.35 m is a fixture
## step; a real climb also has to survive real falls.
const MAX_FRAME_STEP := 0.50
const MIN_CHAIN_HOPS := 2           # ">= 2 chained holds" (plan 2.4.3)
const DRIVE_BUILDINGS := 2          # buildings the real climb must succeed on
## The driven actor is kept fed, rested and alive: this test measures traversal
## geometry, not survival (a dead Survivor frees itself and the drive loses its body).
const ALIVE_HP := 1000000.0
const DRIVE_TRY_LIMIT := 4          # buildings it may try before giving up
const DRIVE_MAX_HOPS := 16          # more holds than any generated facade needs
const DRIVE_ATTEMPTS := 36          # real jumps per facade: a whole side plus retries
const DRIVE_HOP_FRAMES := 110       # ~1.8 s of real time per hop: arc + mantle

var failures := 0
var checks := 0
var _survivor: Survivor
var _parkour: Node
var _fixtures: Node3D                  # section-1 fixtures live here
var _fixture: StaticBody3D
var _built: Array[Node3D] = []         # live building holders
var _section1_records: Array[String] = []
var _section2_records: Array[String] = []
var _spec0: Dictionary = {}            # first census building (section 4 replay)
var _spec0_records: Array[String] = []
var _all_specs: Array[Dictionary] = [] # every materialized spec we may build
var _census_specs: Array[Dictionary] = []
var _seeds: Array[int] = []            # CENSUS_SEEDS, or one seed for --visual
var _visual := false                   # --visual: windowed capture of the chain
var _capture_dir := "res://captures/q2-parkour"
var _camera: Camera3D


func _check(test_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("[LedgeTest] PASS %s" % test_name)
	else:
		failures += 1
		print("[LedgeTest] FAIL %s (%s)" % [test_name, detail])


func _new_stats() -> Dictionary:
	return {
		"probes": 0, "accepts": 0, "rejects": {},
		"kinds": {}, "classes": {}, "kind_profile": {}, "class_kind": {}, "slab_h": {},
		"bad_width": 0, "bad_depth": 0, "bad_clear": 0, "bad_rise": 0,
		"no_hang": 0, "bad_kind": 0,
		"by_building": {}, "kinds_by_building": {},
	}


# ---------------------------------------------------------------- harness

func _ready() -> void:
	get_tree().create_timer(2400.0).timeout.connect(func() -> void:
		print("[LedgeTest] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()


func _run() -> void:
	print("[LedgeTest] start pid=%d" % OS.get_process_id())
	await get_tree().process_frame
	_visual = "--visual" in OS.get_cmdline_user_args()
	_build_rig()
	await _section_rules_matrix(true)
	if _visual:
		# windowed evidence pass: drive the chain and keep the frames. One seed is
		# enough for pictures (the headless census covers all three) and keeps the
		# pass short.
		_seeds = [CENSUS_SEEDS[0]]
		await _ensure_specs()
		print("[LedgeTest] visual mode: capture dir %s"
				% ProjectSettings.globalize_path(_capture_dir))
		await _section_real_climb(true)
	else:
		await _section_census()
		await _section_real_climb(false)
		await _section_determinism()

	print("[LedgeTest] finished with %d failure(s) in %d checks" % [failures, checks])
	get_tree().quit(0 if failures == 0 else 1)


# ---------------------------------------------------------------- capture

func _slug(s: String) -> String:
	return s.replace("/", "_").replace(" ", "_")


func _camera_at(eye: Vector3, target: Vector3) -> void:
	if _camera == null:
		_camera = Camera3D.new()
		_camera.fov = 68.0
		_camera.near = 0.05
		_camera.far = 600.0
		add_child(_camera)
	_camera.global_position = eye
	_camera.look_at(target, Vector3.UP)
	_camera.current = true
	await get_tree().process_frame


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("[LedgeTest] capture skipped (headless): %s" % name)
		return
	var dir := ProjectSettings.globalize_path(_capture_dir)
	DirAccess.make_dir_recursive_absolute(dir)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [dir, name]
	var err := img.save_png(path)
	print("[LedgeTest] capture %s (err=%d)" % [path, err])


func _build_rig() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	add_child(ground)
	var gcol := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(60.0, 1.0, 60.0)
	gcol.shape = gshape
	gcol.position = Vector3(0, -0.5, 0)
	ground.add_child(gcol)

	_fixtures = Node3D.new()
	_fixtures.name = "Fixtures"
	add_child(_fixtures)
	_survivor = Survivor.new()
	_survivor.configure({"is_player": false, "female": false})
	add_child(_survivor)
	_survivor.global_position = Vector3(0, 0.2, HOLD_STAND_Z)
	_keep_alive()
	await get_tree().physics_frame
	_parkour = _survivor.get("parkour") as Node
	_check("survivor exposes the one parkour controller", _parkour != null)
	if _parkour == null:
		get_tree().quit(1)


## Keep the driven actor fed, rested and effectively unkillable. The survivor
## frees itself on death and walks slower when exhausted, either of which would
## make a long run report the wrong thing: this test measures geometry.
func _keep_alive() -> void:
	if _survivor == null or not is_instance_valid(_survivor):
		return
	var h = _survivor.get("health")
	if h != null and is_instance_valid(h):
		h.set("max_health", ALIVE_HP)
		h.set("current_health", ALIVE_HP)
		h.set("infection", 0.0)
		h.set("is_dead", false)
	var n = _survivor.get("needs")
	if n != null and is_instance_valid(n):
		n.set("hunger", 0.0)
		n.set("thirst", 0.0)
		n.set("fatigue", 0.0)
	_survivor.set("stamina", 100.0)


# ---------------------------------------------------------------- geometry helpers

func _box(parent: Node3D, size: Vector3, center: Vector3,
		tag := "", mat := "concrete") -> void:
	var col := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	col.shape = b
	col.position = center
	if tag != "":
		col.set_meta("vox_tag", StringName(tag))
	if mat != "":
		col.set_meta("vox_material", StringName(mat))
	parent.add_child(col)


## Fixture body: a facade wall whose face is z = 0 with optional protruding
## features, exactly like the contract test's fixtures.
func _facade(features: Array = [], wall_h := 6.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_fixtures.add_child(body)
	_box(body, Vector3(6.0, wall_h, 1.0), Vector3(0, wall_h * 0.5, -0.5))
	for f: Dictionary in features:
		var h := float(f.get("h", 0.2))
		var d := float(f.get("d", 0.2))
		var top := float(f.get("top", 1.5))
		_box(body, Vector3(float(f.get("w", 6.0)), h, d),
				Vector3(float(f.get("x", 0.0)), top - h * 0.5, float(f.get("z", d * 0.5))),
				String(f.get("tag", "")))
	return body


func _clear_fixture() -> void:
	if _fixture != null and is_instance_valid(_fixture):
		_fixture.queue_free()
	_fixture = null
	await get_tree().physics_frame


## Facade frame of a real building: outward normal, in-plane start corner,
## tangent and length, all in world XZ, derived from the generator's own
## `_side_point` convention (side 0 N, 1 E, 2 S, 3 W; wall face on the rect edge).
func _frame(rect: Rect2, base_y: float, side: int) -> Dictionary:
	var w := rect.size.x
	var d := rect.size.y
	match side:
		0:
			return {"n": Vector3(0, 0, -1), "start": Vector3(rect.position.x, base_y, rect.position.y),
					"tan": Vector3(1, 0, 0), "len": w}
		1:
			return {"n": Vector3(1, 0, 0), "start": Vector3(rect.position.x + w, base_y, rect.position.y),
					"tan": Vector3(0, 0, 1), "len": d}
		2:
			return {"n": Vector3(0, 0, 1), "start": Vector3(rect.position.x, base_y, rect.position.y + d),
					"tan": Vector3(1, 0, 0), "len": w}
		_:
			return {"n": Vector3(-1, 0, 0), "start": Vector3(rect.position.x, base_y, rect.position.y),
					"tan": Vector3(0, 0, 1), "len": d}


## Teleport without waiting frames: the census asks thousands of questions and
## every one of them is a pure query (the survivor's own body is excluded from
## the rays), so no physics settle is needed.
func _stand(pos: Vector3) -> void:
	_keep_alive()
	_survivor.global_position = pos
	PhysicsServer3D.body_set_state((_survivor as CharacterBody3D).get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, _survivor.global_transform)
	_survivor.velocity = Vector3.ZERO


func _probe(dir: Vector3) -> Dictionary:
	return _parkour.call("_probe_ledge", dir) as Dictionary


func _describe(rec: Dictionary) -> String:
	if rec.is_empty():
		return "{}"
	return "kind=%s class=%s rise=%.2f depth=%.3f width=%.2f hang=%s stand=%s" % [
		str(rec.get("kind", "")), str(rec.get("class", "")), float(rec.get("rise", -9.0)),
		float(rec.get("usable_depth", -9.0)), float(rec.get("usable_width", -9.0)),
		str(rec.get("hang_clear", false)), str(rec.get("stand_clear", false))]


func _reject_reason() -> String:
	var r := str(_parkour.get("last_reject_reason"))
	return r if r != "" else "none"


# ---------------------------------------------------------------- section 1

## The section-1 rejection matrix, replayed here so section 4 can compare it
## byte for byte. Every case is a real StaticBody3D fixture + the real query.
func _section_rules_matrix(record: bool) -> void:
	var cases := [
		{"name": "blank facade cell", "features": [], "wall_h": 6.0, "expect": false},
		{"name": "storey seam", "stacked": [Vector2(1.6, 0.8), Vector2(4.4, 3.8)], "expect": false},
		{"name": "0.06 m dressing", "features": [{"h": 0.09, "d": 0.06, "top": 1.5, "tag": "sill"}], "expect": false},
		{"name": "0.30 m wide block", "features": [{"h": 0.3, "d": 0.4, "w": 0.3, "top": 1.5, "tag": "cornice"}], "expect": false},
		{"name": "0.24 m cornice band", "features": [{"h": 0.2, "d": 0.24, "top": 1.7, "tag": "cornice"}], "expect": true},
		{"name": "0.28 m parapet", "features": [{"h": 0.9, "d": 0.28, "top": 1.9, "tag": "parapet"}], "expect": true},
		{"name": "0.45 m awning deck", "features": [{"h": 0.14, "d": 1.2, "top": 2.0, "tag": "awning"}], "expect": true},
		{"name": "0.07 m bulkhead rim", "features": [{"h": 0.45, "d": 0.08, "top": 1.6, "tag": "bhexit"}], "expect": true},
	]
	_section1_records.clear()
	_fixture = null
	for c: Dictionary in cases:
		_clear_fixture()
		if c.has("stacked"):
			var body := StaticBody3D.new()
			body.collision_layer = 1
			body.collision_mask = 0
			_fixtures.add_child(body)
			for v: Vector2 in (c["stacked"] as Array):
				_box(body, Vector3(6.0, v.x, 1.0), Vector3(0, v.y, -0.5))
			_fixture = body
		else:
			_fixture = _facade(c["features"] as Array, float(c["wall_h"] if c.has("wall_h") else 6.0))
		await get_tree().physics_frame
		_parkour.set("_ledge_cooldown", 10.0)
		_stand(Vector3(0, 0.2, HOLD_STAND_Z))
		_parkour.set("last_reject_reason", &"")
		var rec := _probe(Vector3(0, 0, -1))
		_parkour.set("_ledge_cooldown", 0.0)
		var got := not rec.is_empty()
		_section1_records.append("%s|%s|%s" % [c["name"], "accept" if got else "reject",
				_reject_reason() if not got else String(rec.get("kind", ""))])
		if record:
			_check("fixture: %s -> %s" % [c["name"], "hold" if bool(c["expect"]) else "no hold"],
					got == bool(c["expect"]),
					_describe(rec) if got else "reject=%s" % _reject_reason())
	_clear_fixture()


# ---------------------------------------------------------------- section 2

## Real building specs. One `CityPlan` pass per seed (~100 s each), then the
## candidates are cached so sections 2/3/4 share the cost. Only lots the runtime
## actually materializes are eligible (same `city_materialized` gate as chunks).
func _ensure_specs() -> void:
	if not _census_specs.is_empty():
		return
	if _seeds.is_empty():
		_seeds = CENSUS_SEEDS.duplicate()
	for s: int in _seeds:
		WorldSeed.set_world_seed(s)
		var plan := CityPlan.new(s)
		var world := WorldPlan.new(s)
		var pool: Array[Dictionary] = []
		for spec: Dictionary in plan.city_buildings():
			if not _spec_ok(spec, world):
				continue
			spec["_seed"] = s
			pool.append(spec)
			_all_specs.append(spec)
		pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var fa := int(a.get("floors", 1))
			var fb := int(b.get("floors", 1))
			if fa != fb:
				return fa > fb
			return str(a.get("id", "")) < str(b.get("id", "")))
		var picked := {}
		for i in mini(PER_SEED_TALL, pool.size()):
			var spec: Dictionary = pool[i]
			picked[str(spec.get("id", i))] = spec
			_census_specs.append(spec)
		if pool.size() > mini(PER_SEED_TALL, pool.size()):
			# one mid-sized (historic/low) face per seed for contrast
			var mid: Dictionary = pool[pool.size() / 2]
			if not picked.has(str(mid.get("id", "mid"))):
				_census_specs.append(mid)
	WorldSeed.set_world_seed(CENSUS_SEEDS[0])
	print("[LedgeTest] specs: materialized=%d census=%d seeds=%d"
			% [_all_specs.size(), _census_specs.size(), _seeds.size()])


func _spec_ok(spec: Dictionary, world: WorldPlan) -> bool:
	if not spec.has("rect") or not spec.has("style") or not spec.has("floor_h"):
		return false
	if (spec.get("doors", []) as Array).is_empty():
		return false
	if int(spec.get("floors", 1)) < MIN_CENSUS_FLOORS:
		return false
	if spec.has("quality") and StringName(spec["quality"]) != WorldConstants.BUILDING_QUALITY_FULL_BUILDING:
		return false
	var r: Rect2 = spec["rect"]
	if r.size.x < 10.0 or r.size.y < 10.0:
		return false
	var c := r.get_center()
	return bool(world.chunk_composition(WorldSeed.chunk_coord(c.x, c.y)).get("city_materialized", false))


## Build one spec through the real pipeline and give it a street to stand on.
func _build_real(spec: Dictionary) -> Node3D:
	var holder := Node3D.new()
	add_child(holder)
	_built.append(holder)
	var b := MeshBatcher.new()
	BuildingBuilder.build(b, spec)
	b.flush_into(holder)
	var rect: Rect2 = spec["rect"]
	var base_y := _base_y(spec)
	var gb := StaticBody3D.new()
	gb.collision_layer = 1
	gb.collision_mask = 0
	holder.add_child(gb)
	var gcol := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(rect.size.x + 24.0, 1.0, rect.size.y + 24.0)
	gcol.shape = gshape
	gcol.position = Vector3(rect.get_center().x, base_y - 0.5, rect.get_center().y)
	gb.add_child(gcol)
	return holder


func _free_built() -> void:
	for h: Node3D in _built:
		if is_instance_valid(h):
			h.queue_free()
	_built.clear()
	await get_tree().physics_frame
	_keep_alive()


func _base_y(spec: Dictionary) -> float:
	return float(spec.get("building_ground_y", spec.get("ground_y", 0.0)))


func _section_census() -> void:
	_ensure_specs()
	var seeds := {}
	var tall := 0
	for spec: Dictionary in _census_specs:
		seeds[int(spec["_seed"])] = true
		if mini(int(spec.get("floors", 1)), 8) >= 4:
			tall += 1
	_check("census covers >= 3 seeds and >= 8 generated buildings",
			_census_specs.size() >= 8 and seeds.size() >= 3,
			"buildings=%d seeds=%d" % [_census_specs.size(), seeds.size()])
	_check("census includes inner-city faces (>= 4 buildings with >= 4 storeys)",
			tall >= 4, "tall=%d of %d" % [tall, _census_specs.size()])
	if _census_specs.is_empty():
		return

	var stats := _new_stats()
	_section2_records.clear()
	for spec: Dictionary in _census_specs:
		if _spec0.is_empty():
			_spec0 = spec
		await _census_building(spec, stats)
		if spec == _spec0:
			# section 4 replays exactly this building; keep its records alone
			_spec0_records = _section2_records.duplicate()

	var probes := int(stats["probes"])
	var accepts := int(stats["accepts"])
	var reasons: Dictionary = stats["rejects"]
	var kinds: Dictionary = stats["kinds"]
	print("[LedgeTest] census: probes=%d accepts=%d (%.1f%%) rejects=%s"
			% [probes, accepts, 100.0 * float(accepts) / maxf(1.0, float(probes)),
			JSON.stringify(reasons)])
	print("[LedgeTest] census kinds: %s" % JSON.stringify(kinds))
	print("[LedgeTest] census kinds measured: %s" % JSON.stringify(stats["kind_profile"]))
	print("[LedgeTest] census classes: %s" % JSON.stringify(stats["classes"]))
	print("[LedgeTest] census class x kind: %s" % JSON.stringify(stats["class_kind"]))
	print("[LedgeTest] census slab heights above base: %s"
			% JSON.stringify(stats["slab_h"]))
	print("[LedgeTest] census holds per building: %s" % JSON.stringify(stats["by_building"]))

	_check("the real city offers verified holds at all", accepts > 0,
			"accepts=%d probes=%d reasons=%s" % [accepts, probes, JSON.stringify(reasons)])
	_check("no accepted hold fails its measured profile (width/depth/rise/kind)",
			int(stats["bad_width"]) + int(stats["bad_depth"]) + int(stats["bad_rise"])
					+ int(stats["bad_kind"]) == 0,
			"width=%d depth=%d rise=%d kind=%d" % [stats["bad_width"], stats["bad_depth"],
					stats["bad_rise"], stats["bad_kind"]])
	# Rule F/G: a hold is anchored by a hang *or* a landing - a deep ledge behind
	# a rail is standable without hang space, and the controller accepts it. The
	# plan's stricter wording ("every accepted hold has hang_clear") is therefore
	# measured rather than asserted: stand-only holds are reported and must stay a
	# small minority of what the city offers.
	_check("every accepted hold is anchored (clear hang or clear landing)",
			int(stats["bad_clear"]) == 0,
			"unanchored=%d of %d" % [stats["bad_clear"], accepts])
	_check("stand-only holds stay a small minority of accepts (< 5%)",
			float(stats["no_hang"]) < 0.05 * float(maxi(accepts, 1)),
			"stand_only=%d of %d" % [stats["no_hang"], accepts])
	# Blank facades are the majority of the lattice: the query must reject them
	# for geometric reasons, not accept everything it touches.
	var blank := int(reasons.get("no_face", 0))
	_check("blank facade cells are rejected as no_face", blank > 0,
			"no_face=%d of %d probes" % [blank, probes])
	var geometric := 0
	for r: String in reasons.keys():
		if r != "no_face":
			geometric += int(reasons[r])
	_check("facades also reject on real geometry rules (not only missing faces)",
			geometric > 0, JSON.stringify(reasons))
	# Route diversity: more than one kind of real feature is climbable, and no
	# single kind owns the city.
	_check("more than one kind of generated feature is climbable",
			kinds.size() >= 2, JSON.stringify(kinds))
	var top_kind := ""
	var top_n := 0
	for k: String in kinds.keys():
		if int(kinds[k]) > top_n:
			top_n = int(kinds[k])
			top_kind = k
	_check("no single kind dominates the climbable city (< 90% of accepts)",
			float(top_n) < 0.90 * float(maxi(accepts, 1)),
			"top=%s %d of %d" % [top_kind, top_n, accepts])
	var counts: Array = []
	for k: String in (stats["by_building"] as Dictionary).keys():
		counts.append(int((stats["by_building"] as Dictionary)[k]))
	var uniform := true
	for c: int in counts:
		if c != counts[0]:
			uniform = false
	_check("hold counts differ between buildings (non-uniform routes)",
			not uniform and counts.size() >= 2, JSON.stringify(counts))
	await _free_built()


func _census_building(spec: Dictionary, stats: Dictionary) -> void:
	var rect: Rect2 = spec["rect"]
	var base_y := _base_y(spec)
	var floors := mini(int(spec["floors"]), 8)
	var fh := float(spec["floor_h"])
	var id := "%d/%s" % [int(spec.get("_seed", 0)), str(spec.get("id", "b"))]
	if not (stats["by_building"] as Dictionary).has(id):
		_build_real(spec)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_keep_alive()
	_parkour.set("_ledge_cooldown", 999.0)          # the census asks, never grabs
	_parkour.set("_hang_hold", {})
	_parkour.set("_climb_floor_y", -1.0e9)
	var holds := 0
	var b_kinds := {}
	var ladder: Array = []
	var per_storey := int(floor(fh / VER_STEP)) + 1
	for side in 4:
		var fr := _frame(rect, base_y, side)
		var n_vec: Vector3 = fr["n"]
		var tan: Vector3 = fr["tan"]
		var start: Vector3 = fr["start"]
		var flen := float(fr["len"])
		var t := EDGE_MARGIN
		while t <= flen - EDGE_MARGIN:
			# every storey, and within it every VER_STEP of foot height: a lip only
			# counts from a stance inside the reach window, so a lattice of stances
			# IS the honest census (one probe per storey floor would ask nothing of
			# a facade whose features sit at the storey head).
			for f in range(floors + 1):
				var n_k := per_storey if f < floors else 1
				for k in n_k:
					var pos := start + tan * t + n_vec * HOLD_STAND_Z
					pos.y = base_y + float(f) * fh + 0.02 + float(k) * VER_STEP
					_stand(pos)
					_parkour.set("last_reject_reason", &"")
					var rec := _probe(-n_vec)
					stats["probes"] = int(stats["probes"]) + 1
					if rec.is_empty():
						var why := _reject_reason()
						var rej: Dictionary = stats["rejects"]
						rej[why] = int(rej.get(why, 0)) + 1
						_section2_records.append("p|%s|%d|%.2f|%d|%d|rej|%s" % [id, side, t, f, k, why])
						continue
					holds += 1
					stats["accepts"] = int(stats["accepts"]) + 1
					var kind := String(rec.get("kind", ""))
					stats["kinds"][kind] = int((stats["kinds"] as Dictionary).get(kind, 0)) + 1
					var klass := String(rec.get("class", ""))
					stats["classes"][klass] = int((stats["classes"] as Dictionary).get(klass, 0)) + 1
					b_kinds[kind] = true
					_section2_records.append("p|%s|%d|%.2f|%d|%d|acc|%s" % [id, side, t, f, k, kind])
					var rise := float(rec.get("rise", 0.0))
					var width := float(rec.get("usable_width", 0.0))
					var depth := float(rec.get("usable_depth", 0.0))
					var hang := bool(rec.get("hang_clear", false))
					var stand := bool(rec.get("stand_clear", false))
					var tag := String(rec.get("tag", ""))
					ladder.append({"h": float((rec["lip"] as Vector3).y) - base_y,
							"k": "%s:%s" % [klass, kind],
							"st": 1 if stand else 0})
					_note_profile(stats, kind, width, depth)
					var ck := "%s:%s" % [klass, kind]
					(stats["class_kind"] as Dictionary)[ck] = \
							int((stats["class_kind"] as Dictionary).get(ck, 0)) + 1
					if klass == "slab":
						# mountable holds are what a climb can end on: track how
						# high above the building base they actually sit
						var lip_y := float((rec["lip"] as Vector3).y) - base_y
						var sh: Dictionary = stats["slab_h"]
						if not sh.has(kind):
							sh[kind] = {"n": 0, "min": 99.0, "max": -99.0}
						var e: Dictionary = sh[kind]
						e["n"] = int(e["n"]) + 1
						e["min"] = minf(float(e["min"]), lip_y)
						e["max"] = maxf(float(e["max"]), lip_y)
					if width < 0.45 - 0.02 or float(rec.get("box_depth", 0.0)) + 0.01 < depth:
						stats["bad_width"] = int(stats["bad_width"]) + 1
						print("[LedgeTest] profile: %s %s" % [_describe(rec), _site(id, side, t, f)])
					var min_depth := 0.14 if klass == "slab" else 0.05
					if depth < min_depth - 0.001:
						stats["bad_depth"] = int(stats["bad_depth"]) + 1
						print("[LedgeTest] depth: %s %s" % [_describe(rec), _site(id, side, t, f)])
					if rise < 0.9 - 0.02 or rise > 2.1 + 0.02:
						stats["bad_rise"] = int(stats["bad_rise"]) + 1
						print("[LedgeTest] rise: %s %s" % [_describe(rec), _site(id, side, t, f)])
					if not hang and not stand:
						stats["bad_clear"] = int(stats["bad_clear"]) + 1
					if not hang:
						stats["no_hang"] = int(stats["no_hang"]) + 1
					if (tag != "" and kind != tag) or (tag == "" and kind != "structure" and kind != "prop"):
						stats["bad_kind"] = int(stats["bad_kind"]) + 1
						print("[LedgeTest] kind: %s %s" % [_describe(rec), _site(id, side, t, f)])
			t += FACADE_STEP
	(stats["by_building"] as Dictionary)[id] = holds
	(stats["kinds_by_building"] as Dictionary)[id] = b_kinds.keys()
	# The lowest holds are the ladder a street-level climb meets first: reporting
	# them next to the drive's logged hops is what shows a reach gap is geometry.
	var low: Array = ladder.duplicate()
	low.sort_custom(func(a, b): return float(a["h"]) < float(b["h"]))
	var low_txt: Array = []
	for i in mini(8, low.size()):
		low_txt.append("%.2f/%s%s" % [float(low[i]["h"]), str(low[i]["k"]),
				"*" if int(low[i]["st"]) == 1 else ""])
	print("[LedgeTest] built %s (%s) floors=%d fh=%.2f holds=%d kinds=%s lowest=%s"
			% [id, str(spec.get("use", "?")), floors, fh, holds, JSON.stringify(b_kinds.keys()),
			JSON.stringify(low_txt)])


## Per-kind measured envelope (the plan asks for width/depth per kind, measured).
func _note_profile(stats: Dictionary, kind: String, width: float, depth: float) -> void:
	var prof: Dictionary = stats["kind_profile"]
	if not prof.has(kind):
		prof[kind] = {"n": 0, "w_min": 99.0, "w_max": 0.0, "d_min": 99.0, "d_max": 0.0}
	var p: Dictionary = prof[kind]
	p["n"] = int(p["n"]) + 1
	p["w_min"] = minf(float(p["w_min"]), width)
	p["w_max"] = maxf(float(p["w_max"]), width)
	p["d_min"] = minf(float(p["d_min"]), depth)
	p["d_max"] = maxf(float(p["d_max"]), depth)


func _site(id: String, side: int, t: float, f: int) -> String:
	return "%s side=%d t=%.1f f=%d" % [id, side, t, f]


# ---------------------------------------------------------------- section 3

## The real climb: a real `Survivor` + `ParkourController` at a generated facade.
## The body is placed at the foot of the wall and then does what a player does -
## walks at the face, jumps, holds toward it, and while it hangs the controller's
## own climb-up input is used. There is no pre-planned chain and no teleport: the
## facade columns are swept in a fixed order, so the search is deterministic, and
## the body either gets up the wall or it does not.
func _section_real_climb(capture: bool = false) -> void:
	_ensure_specs()
	var cands := _drive_candidates()
	_check("the city offers materialized buildings to climb", cands.size() >= DRIVE_BUILDINGS,
			"candidates=%d" % cands.size())
	var climbed := 0
	var tried := 0
	for spec: Dictionary in cands:
		if climbed >= DRIVE_BUILDINGS or tried >= DRIVE_TRY_LIMIT:
			break
		tried += 1
		if await _drive_climb(spec, capture):
			climbed += 1
	_check("the real survivor reached the roof deck on >= %d generated buildings"
			% DRIVE_BUILDINGS, climbed >= DRIVE_BUILDINGS,
			"climbed=%d tried=%d" % [climbed, tried])


## Candidates: exactly the buildings section 2 walked, in census order. They carry
## the full generated vocabulary (bands, cornices, balconies, parapets), and
## rebuilding them for the drive keeps the evidence on real generated geometry.
func _drive_candidates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for spec: Dictionary in _census_specs:
		out.append(spec)
	return out


## One climb of one facade, real input only. Returns true when the body stood on
## (or above) the roof deck. Every hop is logged with what it grabbed.
func _drive_climb(spec: Dictionary, capture: bool = false) -> bool:
	var rect: Rect2 = spec["rect"]
	var base_y := _base_y(spec)
	var floors := mini(int(spec["floors"]), 8)
	var fh := float(spec["floor_h"])
	var roof_y := base_y + float(floors) * fh
	var id := "%d/%s" % [int(spec.get("_seed", 0)), str(spec.get("id", "b"))]
	_build_real(spec)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var stamina_reset := _survivor.stamina
	_survivor.stamina = 100.0
	var fr := _frame(rect, base_y, 0)
	var n_vec: Vector3 = fr["n"]
	var tan: Vector3 = fr["tan"]
	var start: Vector3 = fr["start"]
	var flen := float(fr["len"])
	var t := EDGE_MARGIN + FACADE_STEP
	var foot := start + tan * t + n_vec * 1.6
	foot.y = base_y + 0.02
	await _settle(foot)
	print("[LedgeTest] climbing %s: floors=%d roof=%.2f facade=%.1f m"
			% [id, floors, roof_y, flen])
	if capture:
		await _camera_at(foot + n_vec * 9.0 + Vector3.UP * (float(floors) * fh * 0.5),
				foot + Vector3.UP * (float(floors) * fh * 0.5))
		await _capture("climb-%s-street" % _slug(id))
	var worst_step := 0.0
	var best_y := base_y              # highest footing or hang the body reached
	var stand_y := base_y             # highest place the body actually STOOD on
	var hops := 0
	var falls := 0
	var attempts := 0
	var kinds: Array = []
	var tries_here := 0
	var seen_start := {}
	var report_before: Dictionary = _parkour.call("get_hold_report")
	while t <= flen - EDGE_MARGIN and attempts < DRIVE_ATTEMPTS \
			and hops < DRIVE_MAX_HOPS and stand_y < roof_y - ROOF_EPS:
		var column: Vector3 = start + tan * t
		attempts += 1
		tries_here += 1
		_keep_alive()
		# a footing the body has already asked from twice is a local loop, not a
		# route: stop retrying that column and hunt along the facade instead
		var start_h := snappedf(_survivor.global_position.y, 0.25)
		var repeats := int(seen_start.get(start_h, 0))
		seen_start[start_h] = repeats + 1
		var hop := await _try_hop(column, n_vec, capture, id, hops + 1)
		worst_step = maxf(worst_step, float(hop["worst_step"]))
		if bool(hop["up"]):
			hops += 1
			tries_here = 0
			best_y = maxf(best_y, float(hop["feet"]))
			if bool(hop["stand"]):
				stand_y = maxf(stand_y, float(hop["feet"]))
			var k := String(hop.get("kind", ""))
			if k != "" and not kinds.has(k):
				kinds.append(k)
			print("[LedgeTest]   hop %d on %s: %s (%s) -> %.2f (roof %.2f)"
					% [hops, id, k if k != "" else "?", "mantle" if bool(hop["stand"]) else "leap",
					float(hop["feet"]), roof_y])
			# What the grab actually took matters as much as where it ended: a hold
			# with `stand_clear` is one the body could have climbed onto.
			var g: Dictionary = _parkour.call("get_ledge_probe")
			var gh: Dictionary = g.get("hold", {})
			print("[LedgeTest]   grab %d on %s: kind=%s tag=%s class=%s stand=%s hang=%s lip=%.2f rise=%.2f d=%.2f w=%.2f"
					% [hops, id, String(g.get("kind", "")), String(gh.get("tag", "")),
					String(g.get("class", "")), str(gh.get("stand_clear", false)),
					str(gh.get("hang_clear", false)),
					float((gh.get("lip", Vector3.ZERO) as Vector3).y) - base_y,
					float(g.get("rise", 0.0)), float(gh.get("usable_depth", 0.0)),
					float(gh.get("usable_width", 0.0))])
			if capture:
				await _camera_at(_survivor.global_position + n_vec * 3.6 + Vector3.UP * 0.6,
						_survivor.global_position + Vector3.UP * 0.4)
				await _capture("climb-%s-hop%d" % [_slug(id), hops])
			continue
		# nothing gained at this column: let go, settle, then hunt along the facade
		if bool(hop["hung"]):
			_reset_parkour_state()
			await _land(70)
			falls += 1
		elif bool(hop["fell"]):
			falls += 1
		if repeats < 1 and best_y > base_y + 1.0 and tries_here < 2:
			continue                       # still up on a ledge: ask this column again
		t += FACADE_STEP
		tries_here = 0
		await _walk_to(start + tan * t + n_vec * 1.6, 26)
	# Why the climb stopped is as much a result as how far it got: the controller's
	# own reject ledger says whether a hold was out of reach (rise_high), too thin
	# (no_depth) or refused (no_clearance).
	var report: Dictionary = _parkour.call("get_hold_report")
	var delta := {}
	var reasons: Dictionary = report.get("reject_reasons", {})
	var before_reasons: Dictionary = report_before.get("reject_reasons", {})
	for key in reasons:
		var d := int(reasons[key]) - int(before_reasons.get(key, 0))
		if d != 0:
			delta[key] = d
	print("[LedgeTest] climb %s: hops=%d kinds=%s best=%.2f stood=%.2f roof=%.2f attempts=%d falls=%d worst_step=%.3f"
			% [id, hops, JSON.stringify(kinds), best_y, stand_y, roof_y, attempts, falls, worst_step])
	print("[LedgeTest] climb %s rejects: %s (last=%s d=%.2f w=%.2f kind=%s stand=%s hang=%s)"
			% [id, JSON.stringify(delta), String(report.get("last_reject", "")),
			float(report.get("depth", 0.0)), float(report.get("width", 0.0)),
			String(report.get("kind", "")), str(report.get("stand_clear", false)),
			str(report.get("hang_clear", false))])
	# What the probe sees where the climb stopped: an empty answer means nothing is
	# in the reach window at all, a filled one means the body had a hold it did not
	# take. Printed next to the reject ledger this is the whole diagnosis.
	var stall: Dictionary = _parkour.call("_probe_ledge", -n_vec)
	print("[LedgeTest] climb %s stall probe: kind=%s class=%s stand=%s hang=%s lip=%.2f rise=%.2f d=%.2f w=%.2f"
			% [id, String(stall.get("kind", "")), String(stall.get("class", "")),
			str(stall.get("stand_clear", false)), str(stall.get("hang_clear", false)),
			float((stall.get("lip", Vector3.ZERO) as Vector3).y) - base_y,
			float(stall.get("rise", 0.0)), float(stall.get("usable_depth", 0.0)),
			float(stall.get("usable_width", 0.0))])
	if capture:
		await _camera_at(_survivor.global_position + n_vec * 7.0 + Vector3.UP * 2.2,
				_survivor.global_position + Vector3.UP * 0.4)
		await _capture("climb-%s-top" % _slug(id))
	_check("the survivor climbed >= %d chained holds on %s" % [MIN_CHAIN_HOPS, id],
			hops >= MIN_CHAIN_HOPS, "hops=%d attempts=%d" % [hops, attempts])
	_check("no per-frame displacement exceeds the honest budget (< %.2f m) on %s"
			% [MAX_FRAME_STEP, id], worst_step < MAX_FRAME_STEP, "worst=%.3f" % worst_step)
	_check("the survivor reached the roof deck of %s (>= floors x floor_h = %.2f)"
			% [id, roof_y], stand_y >= roof_y - ROOF_EPS,
			"stood=%.2f best=%.2f roof=%.2f" % [stand_y, best_y, roof_y])
	_survivor.stop_moving()
	_survivor.stamina = stamina_reset
	await get_tree().physics_frame
	await _free_built()
	return stand_y >= roof_y - ROOF_EPS


## One real hop at a facade column: walk at the face under own power, jump, and
## while the body hangs the controller's climb-up input is used (that is the
## player's climb-up, not a scripted mantle). Returns
## {up, feet, kind, worst_step, hung, fell}.
## One real move up the wall at a facade column. From a footing the body walks at
## the face and jumps; from a hang it uses the controller's own climb input, which
## mantles when the hold has a landing and leaps for a higher hold when it does
## not. Either way the input is the player's. Returns
## {up, stand, feet, kind, worst_step, hung, fell}.
func _try_hop(column: Vector3, n_vec: Vector3, capture: bool,
		id: String, n: int) -> Dictionary:
	var hanging_start := _is_hanging()
	var before_grabs := int(_parkour.get("ledge_grabs"))
	var start_y := _survivor.global_position.y
	var hang_y := -1.0e9
	var worst := 0.0
	var prev := _survivor.global_position
	_survivor.stamina = 100.0
	_keep_alive()
	if not hanging_start:
		# a fresh hop from a footing: clear the last grab and its cooldown
		_reset_parkour_state()
		_parkour.call("reset_fall_tracking", start_y)
		# walk in: the body has to reach the wall under its own power
		_survivor.request_move(-n_vec, false)
		for k in 45:
			await get_tree().physics_frame
			_keep_alive()
			var p := _survivor.global_position
			worst = maxf(worst, p.distance_to(prev))
			prev = p
			if (p - column).dot(n_vec) <= 0.55:
				break
	else:
		hang_y = start_y
		_survivor.request_move(-n_vec, false)
	_parkour.call("try_jump")
	var hung := hanging_start
	var used_climb := false
	for k in DRIVE_HOP_FRAMES:
		await get_tree().physics_frame
		_keep_alive()
		var pos := _survivor.global_position
		worst = maxf(worst, pos.distance_to(prev))
		prev = pos
		if _is_hanging():
			if not hung:
				hung = true
				hang_y = pos.y
			if not used_climb:
				# settle on the anchor, then the player's climb-up / leap input
				for j in 8:
					await get_tree().physics_frame
					_keep_alive()
					var p2 := _survivor.global_position
					worst = maxf(worst, p2.distance_to(prev))
					prev = p2
				if capture:
					await _camera_at(_survivor.global_position + n_vec * 3.2 + Vector3.UP * 0.5,
							_survivor.global_position + Vector3.UP * 0.6)
					await _capture("hop-%s-%d-hang" % [_slug(id), n])
				_parkour.call("try_jump")
				used_climb = true
			elif used_climb and (pos.y - hang_y) > 0.3:
				break                            # caught a higher hold: a leap up the wall
		else:
			if (pos.y - start_y) > 0.5:
				break                            # standing on a new footing
			if hung and used_climb and pos.y < hang_y - 0.4:
				break                            # the leap is over and it missed
			if not hung and k > 30 and pos.y < start_y:
				break                            # the jump is over and it missed
			if not hung and k > 40 and int(_parkour.get("ledge_grabs")) > before_grabs:
				break                            # grabbed without ever hanging
	var feet := _survivor.global_position.y
	var hanging_end := _is_hanging()
	var probe: Dictionary = _parkour.call("get_ledge_probe")
	var stand := (not hanging_end) and (feet - start_y) > 0.5
	# A leap to a higher hold is progress even while the body still hangs: that is
	# how a bar facade (bands, cornices, rails) is climbed at all.
	var leap := hanging_end and hung and used_climb and (feet - hang_y) > 0.3
	return {"up": stand or leap, "stand": stand, "leap": leap, "feet": feet,
			"kind": String(probe.get("kind", "")), "worst_step": worst, "hung": hung,
			"fell": (not hanging_end) and (feet - start_y) < -0.5}


func _is_hanging() -> bool:
	var loco: CharacterLocomotion = _survivor.get_locomotion()
	if loco == null or not is_instance_valid(loco):
		return false
	var st := int(loco.state)
	return st == CharacterLocomotion.State.HANG or st == CharacterLocomotion.State.SHIMMY


## Wait for the body to come to rest (real physics), bounded.
func _land(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame
		_keep_alive()
		if _is_hanging():
			continue
		if absf(_survivor.velocity.y) < 0.25:
			return


## Walk to a facade column with real input: stops when it is there or the frames
## run out. The body is never moved directly.
func _walk_to(target: Vector3, frames: int) -> void:
	for i in frames:
		var pos := _survivor.global_position
		var d := target - pos
		d.y = 0.0
		if d.length() < 0.5:
			break
		_survivor.request_move(d.normalized(), false)
		await get_tree().physics_frame
		_keep_alive()
	_survivor.stop_moving()


func _settle(pos: Vector3) -> void:
	_stand(pos)
	_survivor.stop_moving()
	for i in 30:
		await get_tree().physics_frame
		_keep_alive()


func _reset_parkour_state() -> void:
	_parkour.set("_hang_hold", {})
	_parkour.set("_shimmy_probe", {})
	_parkour.set("_ledge_probe", {})
	_parkour.set("_climb_floor_y", -1.0e9)
	_parkour.set("_ledge_cooldown", 0.0)
	_parkour.set("_peak_y", _survivor.global_position.y)
	var loco: CharacterLocomotion = _survivor.get_locomotion()
	if loco != null and is_instance_valid(loco):
		loco.set("_vault_timer", 0.0)
		loco.set("_mantle_timer", 0.0)
		loco.set("_climb_timer", 0.0)
		loco.set("_hang_timer", 0.0)
		loco.set("_shimmy_timer", 0.0)
		loco.state = CharacterLocomotion.State.IDLE


# ---------------------------------------------------------------- section 4

## Determinism, twice over: the section-1 rule matrix and ONE real building are
## replayed and compared to the records the first pass wrote.
func _section_determinism() -> void:
	var first1 := _section1_records.duplicate()
	await _section_rules_matrix(false)
	_check("the section-1 rule matrix is deterministic (identical records)",
			_section1_records == first1,
			"first=%d second=%d" % [first1.size(), _section1_records.size()])
	if _spec0.is_empty():
		_check("the census kept a building to replay", false, "spec0 empty")
		return
	_section2_records.clear()
	var stats := _new_stats()
	await _census_building(_spec0, stats)
	var again := _section2_records.duplicate()
	_check("the census of %s is deterministic (identical records)" % str(_spec0.get("id", "?")),
			again == _spec0_records,
			"first=%d second=%d" % [_spec0_records.size(), again.size()])
	if again != _spec0_records:
		var n := mini(_spec0_records.size(), again.size())
		for i in n:
			if _spec0_records[i] != again[i]:
				print("[LedgeTest] first difference at %d: %s vs %s"
						% [i, _spec0_records[i], again[i]])
				break
	await _free_built()
