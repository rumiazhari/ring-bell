class_name ParkourContractTest
extends Node
## Q2 parkour contract: the ONE local ledge-query system, exercised on real
## collision geometry with a real Survivor (not bare-locomotion unit updates).
##
## Geometry convention for every case:
##   * the survivor approaches from +z and the probe direction is (0, 0, -1);
##   * the facade wall is a box spanning z in [-1, 0], so its face is z = 0;
##   * a feature protrudes TOWARD the survivor, i.e. z in [0, depth];
##   * "top" is the world y of the feature's top face;
##   * the probe body stands HOLD_STAND_Z (0.55 m) off the face, inside
##     LEDGE_PROBE_REACH (0.62 m), which is how a body walks up to a wall.
##
## Rule cases (the query is asked directly):
##   blank tall facade      -> no hold
##   storey seam in a wall  -> no hold        (top face is not free air)
##   0.24 m cornice band    -> hold, hang only (wall behind the lip: no standing room)
##   0.08 x 0.10 m trim     -> no hold        (nothing for a hand to hold)
##   0.3 m long block       -> no hold        (usable width below the bar)
##   box buried in the wall -> no hold
##   lip 3.3 m above feet   -> no hold        (out of arm reach, and reachable once lifted)
##   band under a low hood  -> the hood is the hold, the covered band is not
##   awning deck 2.4 m      -> hold, slab     (real standing room on the deck)
##   street -> deck -> cornice -> balcony -> roof: a probe-reachable route
## Driven cases (the survivor's own rays, states and counters):
##   jump at a 2.4 x 0.12 m band latches a verified hold
##   the hold is held as an anchored hang: no sink, no teleport, lip-pinned
##   shimmy stays inside the measured ledge width
## Usage: godot --headless --path . -- --parkourtest

const HOLD_STAND_Z := 0.55        # 0.55 m off the wall face: inside probe reach
const DRIVEN_LIP := 2.6           # cornice band top: inside the jump grab window
const DRIVEN_START_Z := 2.2

var failures := 0
var checks := 0
var _ground: StaticBody3D
var _fixture: StaticBody3D
var _survivor: Survivor
var _parkour: Node


func _check(test_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("[ParkourTest] PASS %s" % test_name)
	else:
		failures += 1
		print("[ParkourTest] FAIL %s (%s)" % [test_name, detail])


# ---------------------------------------------------------------- fixtures

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


## A static body out of {size, center, tag} dictionaries. Batched city cells are
## exactly this: many box shapes on one body, feature tags on the shape owner.
func _body(boxes: Array) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	for b: Dictionary in boxes:
		_box(body, b["size"] as Vector3, b["center"] as Vector3,
				String(b.get("tag", "")), String(b.get("mat", "concrete")))
	return body


## The facade used by most cases: a wall (front face at z = 0) with optional
## protruding features. A feature: {w,h,d,top,tag, x?, z?}.
func _facade(features: Array = [], wall_h := 6.0) -> StaticBody3D:
	var boxes: Array = [
		{"size": Vector3(6.0, wall_h, 1.0), "center": Vector3(0, wall_h * 0.5, -0.5)},
	]
	for f: Dictionary in features:
		var h := float(f.get("h", 0.2))
		var d := float(f.get("d", 0.2))
		var top := float(f.get("top", 1.5))
		boxes.append({
			"size": Vector3(float(f.get("w", 6.0)), h, d),
			"center": Vector3(float(f.get("x", 0.0)), top - h * 0.5,
					float(f.get("z", d * 0.5))),
			"tag": String(f.get("tag", "")),
		})
	return _body(boxes)


func _clear_fixture() -> void:
	if _fixture != null and is_instance_valid(_fixture):
		_fixture.queue_free()
	_fixture = null
	await get_tree().physics_frame


## Teleport the survivor and settle physics before a probe.
func _place(pos: Vector3) -> void:
	var body := _survivor as CharacterBody3D
	_survivor.global_position = pos
	PhysicsServer3D.body_set_state(body.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, _survivor.global_transform)
	_survivor.velocity = Vector3.ZERO
	_survivor.stop_moving()
	for i in 4:
		await get_tree().physics_frame


## Put the body on the floor at `pos` and let it settle: used between a
## question asked from mid-air and a driven attempt, so the counters only
## measure the attempt.
func _settle_on_ground(pos: Vector3) -> void:
	await _place(pos)
	_survivor.stop_moving()
	for i in 40:
		await get_tree().physics_frame


func _probe(dir: Vector3) -> Dictionary:
	return _parkour.call("_probe_ledge", dir) as Dictionary


func _describe(rec: Dictionary) -> String:
	if rec.is_empty():
		return "{}"
	return "kind=%s class=%s rise=%.2f depth=%.3f width=%.2f hang=%s stand=%s" % [
		str(rec.get("kind", "")), str(rec.get("class", "")), float(rec.get("rise", -9.0)),
		float(rec.get("usable_depth", -9.0)), float(rec.get("usable_width", -9.0)),
		str(rec.get("hang_clear", false)), str(rec.get("stand_clear", false))]


# ---------------------------------------------------------------- harness

func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[ParkourTest] WATCHDOG TIMEOUT")
		get_tree().quit(2)
	)
	_run()


func _run() -> void:
	print("[ParkourTest] start pid=%d" % OS.get_process_id())
	await get_tree().process_frame
	_ground = _body([{"size": Vector3(80.0, 1.0, 80.0),
			"center": Vector3(0, -0.5, 0), "mat": ""}])
	var holder := Node3D.new()
	holder.name = "Holder"
	add_child(holder)
	_survivor = Survivor.new()
	_survivor.configure({"is_player": false, "female": false})
	holder.add_child(_survivor)
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	_parkour = _survivor.get("parkour") as Node
	_check("survivor exposes a parkour controller", _parkour != null)
	if _parkour == null:
		get_tree().quit(1)
		return

	await _case_blank_facade()
	await _case_storey_seam()
	await _case_cornice()
	await _case_tiny_trim()
	await _case_short_block()
	await _case_buried_box()
	await _case_out_of_reach()
	await _case_hooded_lip()
	await _case_awning_deck()
	await _case_route_chain()
	await _case_driven_hang()
	await _case_driven_shimmy()

	var report: Dictionary = _parkour.call("get_hold_report") as Dictionary
	print("[ParkourTest] hold report: %s" % JSON.stringify(report))
	print("[ParkourTest] finished with %d failure(s) in %d checks" % [failures, checks])
	get_tree().quit(0 if failures == 0 else 1)


# ---------------------------------------------------------------- rule cases

func _case_blank_facade() -> void:
	_clear_fixture()
	_fixture = _facade()
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("blank tall facade is not a hold", rec.is_empty(), _describe(rec))
	await _clear_fixture()


func _case_storey_seam() -> void:
	_clear_fixture()
	_fixture = _body([
		{"size": Vector3(6.0, 1.6, 1.0), "center": Vector3(0, 0.8, -0.5)},
		{"size": Vector3(6.0, 4.4, 1.0), "center": Vector3(0, 3.8, -0.5)},
	])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("storey seam in a facade is not a hold", rec.is_empty(), _describe(rec))
	await _clear_fixture()


func _case_cornice() -> void:
	_clear_fixture()
	_fixture = _facade([{"h": 0.2, "d": 0.24, "top": 1.7, "tag": "cornice"}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("0.24 m cornice band is a hold", not rec.is_empty(), _describe(rec))
	if not rec.is_empty():
		_check("cornice is classified by its tag",
				String(rec["kind"]) == "cornice", _describe(rec))
		_check("cornice rise is the measured lip height",
				absf(float(rec["rise"]) - 1.5) < 0.15, _describe(rec))
		_check("cornice against a wall is a handhold, not a floor",
				String(rec["class"]) == "bar" and not bool(rec["stand_clear"]),
				_describe(rec))
		_check("cornice keeps its measured width",
				float(rec["usable_width"]) > 5.0, _describe(rec))
	await _clear_fixture()


func _case_tiny_trim() -> void:
	_clear_fixture()
	_fixture = _facade([{"h": 0.08, "d": 0.10, "top": 1.55, "tag": "cornice"}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("0.08 x 0.10 m decorative trim is not a hold", rec.is_empty(), _describe(rec))
	await _clear_fixture()


func _case_short_block() -> void:
	_clear_fixture()
	_fixture = _facade([{"h": 0.3, "d": 0.4, "w": 0.3, "top": 1.5, "tag": "cornice"}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("0.3 m long block has no usable width", rec.is_empty(), _describe(rec))
	await _clear_fixture()


func _case_buried_box() -> void:
	_clear_fixture()
	_fixture = _facade([{"h": 0.3, "d": 0.2, "top": 1.6, "tag": "cornice",
			"z": -0.25}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("box buried in the wall is not a hold", rec.is_empty(), _describe(rec))
	await _clear_fixture()


func _case_out_of_reach() -> void:
	_clear_fixture()
	# A 0.4 m deep band, top at 3.5 m: 3.3 m above street feet, so out of reach.
	_fixture = _facade([{"h": 0.2, "d": 0.4, "top": 3.5, "tag": "cornice"}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var ground_rec := _probe(Vector3(0, 0, -1))
	_check("lip 3.3 m above the feet is out of reach", ground_rec.is_empty(),
			_describe(ground_rec))
	# The same lip with the body lifted 2 m: reach, not missing geometry, was
	# the reason it failed.
	await _place(Vector3(0, 2.2, HOLD_STAND_Z))
	var lifted := _probe(Vector3(0, 0, -1))
	_check("the same lip verifies once the body is tall enough",
			not lifted.is_empty() and String(lifted.get("kind", "")) == "cornice",
			_describe(lifted))
	await _clear_fixture()


func _case_hooded_lip() -> void:
	_clear_fixture()
	# A 0.24 m band at 1.7 m covered by a 0.8 m slab at 2.1 m. The band's top
	# face is covered, so the only honest hold on this wall is the slab.
	_fixture = _facade([
		{"h": 0.2, "d": 0.24, "top": 1.7, "tag": "cornice"},
		{"h": 0.3, "d": 0.8, "top": 2.1, "tag": "balcony"},
	])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("covered band is not surfaced as a hold",
			rec.is_empty() or String(rec.get("kind", "")) != "cornice",
			_describe(rec))
	_check("the hold found is the slab that covers it",
			not rec.is_empty() and String(rec.get("kind", "")) == "balcony"
			and absf(float(rec.get("rise", -9.0)) - 1.9) < 0.20, _describe(rec))
	await _clear_fixture()


func _case_awning_deck() -> void:
	_clear_fixture()
	_fixture = _facade([{"h": 0.2, "d": 2.4, "top": 2.2, "tag": "awning"}])
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var rec := _probe(Vector3(0, 0, -1))
	_check("awning deck is a hold", not rec.is_empty(), _describe(rec))
	if not rec.is_empty():
		_check("awning deck is classified by its tag",
				String(rec["kind"]) == "awning", _describe(rec))
		_check("awning deck is a standable slab (mantle target)",
				String(rec["class"]) == "slab" and bool(rec["stand_clear"]),
				_describe(rec))
		_check("awning deck usable depth is measured, not assumed",
				float(rec["usable_depth"]) > 1.0, _describe(rec))
	await _clear_fixture()


## The route that matters: can a body that starts in the street reach the roof
## through verified holds only? Each step probes from the honest place the
## previous hold leaves the body (standing on the deck, standing on the
## balcony), and the hops have to add up to the wall.
func _case_route_chain() -> void:
	_clear_fixture()
	_fixture = _facade([
		{"h": 0.2, "d": 2.4, "top": 2.2, "tag": "awning"},      # street -> 2.2
		{"h": 0.2, "d": 0.24, "top": 3.8, "tag": "cornice"},    # fall-catch band
		{"h": 0.2, "d": 2.4, "top": 4.3, "tag": "balcony"},     # deck   -> 4.3
	], 5.9)                                                     # balcony-> roof 5.9
	var hops: Array[float] = []
	# step 1: from the street (feet 0.2) to the awning deck.
	await _place(Vector3(0, 0.2, HOLD_STAND_Z))
	var s1 := _probe(Vector3(0, 0, -1))
	_check("route 1: street -> awning deck",
			not s1.is_empty() and String(s1.get("kind", "")) == "awning",
			_describe(s1))
	_check("route 1 lands on a standable deck", bool(s1.get("stand_clear", false)),
			_describe(s1))
	if not s1.is_empty():
		hops.append(float(s1["rise"]))
	# step 2: standing on the deck (feet 2.2).
	await _place(Vector3(0, 2.2, HOLD_STAND_Z))
	var s2 := _probe(Vector3(0, 0, -1))
	_check("route 2: deck -> next hold above (balcony)",
			not s2.is_empty() and String(s2.get("kind", "")) == "balcony",
			_describe(s2))
	_check("route 2 is a mantle target, not a bare hang",
			bool(s2.get("stand_clear", false)), _describe(s2))
	if not s2.is_empty():
		hops.append(float(s2["rise"]))
	# step 3: standing on the balcony (feet 4.3) -> the roof edge (wall top 5.9).
	await _place(Vector3(0, 4.3, HOLD_STAND_Z))
	var s3 := _probe(Vector3(0, 0, -1))
	_check("route 3: balcony -> roof edge",
			not s3.is_empty() and absf(float(s3.get("rise", -9.0)) - 1.6) < 0.20,
			_describe(s3))
	_check("route 3 roof edge is standable (mantle onto the roof)",
			bool(s3.get("stand_clear", false)), _describe(s3))
	if not s3.is_empty():
		hops.append(float(s3["rise"]))
	# The route is only real if the hops are each inside arm reach and together
	# cover the whole street-to-roof climb.
	var total := 0.0
	var worst := 0.0
	for h in hops:
		total += h
		worst = maxf(worst, h)
	_check("route hops are each inside one arm reach (<= 2.1 m)",
			hops.size() == 3 and worst <= 2.1 + 0.01,
			"hops=%s worst=%.2f" % [str(hops), worst])
	_check("route hops add up to the street-to-roof climb (5.7 m)",
			absf(total - 5.7) < 0.45, "total=%.2f hops=%s" % [total, str(hops)])
	print("[ParkourTest] route: hops=%s total=%.2f" % [str(hops), total])
	await _clear_fixture()


# ---------------------------------------------------------------- driven cases

func _hang_fixture() -> void:
	# A 2.4 m long, 0.12 m deep cornice band at 2.6 m: long enough for a shimmy,
	# too slender to stand on with the wall right behind it.
	_fixture = _facade([{"h": 0.2, "d": 0.12, "w": 2.4, "top": DRIVEN_LIP,
			"tag": "cornice"}])


func _walk_in(frames: int) -> void:
	_survivor.request_move(Vector3(0, 0, -1), false)
	for i in frames:
		await get_tree().physics_frame


## A fresh driven case must not inherit the previous grab's hang, cooldown or
## anti-recatch floor (all of which are correct in play, and all of which would
## silently suppress the next grab in a test).
func _reset_parkour_state() -> void:
	_parkour.set("_hang_hold", {})
	_parkour.set("_shimmy_probe", {})
	_parkour.set("_ledge_probe", {})
	_parkour.set("_climb_floor_y", -1.0e9)
	_parkour.set("_ledge_cooldown", 0.0)
	_parkour.set("_peak_y", _survivor.global_position.y)
	# Scenario isolation: the previous case leaves the state machine parked
	# mid-parkour (tearing the fixture down cannot tell it the hill is gone), so
	# put it back at IDLE with clean timers, else the walk-in never happens and
	# the case measures nothing. The state machine's own transitions are
	# --animclimb's job; here the survivor only has to be a drivable body.
	var loco: CharacterLocomotion = _survivor.get_locomotion()
	if loco != null and is_instance_valid(loco):
		loco.set("_vault_timer", 0.0)
		loco.set("_mantle_timer", 0.0)
		loco.set("_climb_timer", 0.0)
		loco.set("_hang_timer", 0.0)
		loco.set("_slide_timer", 0.0)
		loco.set("_standup_timer", 0.0)
		loco.set("_wallrun_timer", 0.0)
		loco.set("_shimmy_timer", 0.0)
		loco.set("_drop_timer", 0.0)
		loco.state = CharacterLocomotion.State.IDLE


func _case_driven_hang() -> void:
	_clear_fixture()
	_hang_fixture()
	await _place(Vector3(0, 0.2, DRIVEN_START_Z))
	_survivor.stamina = 100.0        # each driven case is an independent climb
	_reset_parkour_state()
	# The fixture has to verify: ask from a mid-jump pose (feet 1.3 m), which is
	# where a jump at this band actually asks the question (the chest plane then
	# sits on the band's own face). The grab path is muted while the question is
	# asked - a live grab would latch the body and leave the scenario dirty for
	# the driven attempt - while the probe itself stays a pure query.
	_parkour.set("_ledge_cooldown", 10.0)
	await _place(Vector3(0, 1.3, 0.4))
	var probe := _probe(Vector3(0, 0, -1))
	_check("driven fixture verifies as a hang-only cornice",
			not probe.is_empty() and String(probe.get("class", "")) == "bar"
			and not bool(probe.get("stand_clear", false)), _describe(probe))
	# Unmute and settle on the ground: the counted grab below then has to come
	# from the jump, not from the question.
	_parkour.set("_ledge_cooldown", 0.0)
	_reset_parkour_state()
	await _settle_on_ground(Vector3(0, 0.2, DRIVEN_START_Z))
	await _walk_in(30)
	var grabs_before := int(_parkour.get("ledge_grabs"))
	var hang_frames := 0
	var worst_step := 0.0
	var worst_dy_settled := 0.0
	var worst_lip_gap := 0.0
	var y_at_hang_start := 1.0e9
	var y_at_hang_end := 1.0e9
	_parkour.call("try_jump")
	var prev := _survivor.global_position
	for i in 220:
		await get_tree().physics_frame
		var pos := _survivor.global_position
		var loco: CharacterLocomotion = _survivor.get_locomotion()
		var st := -1
		if loco != null and is_instance_valid(loco):
			st = int(loco.state)
		if st == CharacterLocomotion.State.HANG or st == CharacterLocomotion.State.SHIMMY:
			hang_frames += 1
			if hang_frames == 1:
				y_at_hang_start = pos.y
			y_at_hang_end = pos.y
			if hang_frames > 10:
				# Settled hang: no per-frame sink.
				worst_dy_settled = maxf(worst_dy_settled, absf(pos.y - prev.y))
			worst_lip_gap = maxf(worst_lip_gap, absf(pos.y - (DRIVEN_LIP - 1.45)))
		worst_step = maxf(worst_step, pos.distance_to(prev))
		prev = pos
	var grabs_after := int(_parkour.get("ledge_grabs"))
	var drift := absf(y_at_hang_end - y_at_hang_start)
	print("[ParkourTest] driven: grabs %d->%d hang_frames=%d worst_step=%.3f worst_dy=%.3f drift=%.3f lip_gap=%.3f"
			% [grabs_before, grabs_after, hang_frames, worst_step, worst_dy_settled,
			drift, worst_lip_gap])
	_check("jump at a cornice band latches a verified hold",
			grabs_after > grabs_before, "grabs %d->%d" % [grabs_before, grabs_after])
	_check("the hold is held as a hang", hang_frames > 5, "frames=%d" % hang_frames)
	_check("no teleport while hanging (worst step < 0.35 m)", worst_step < 0.35,
			"worst=%.3f" % worst_step)
	_check("no sink while hanging (settled dy/frame < 0.02 m)",
			worst_dy_settled < 0.02, "worst=%.3f" % worst_dy_settled)
	_check("no progressive sink (total hang drift < 0.20 m)", drift < 0.20,
			"drift=%.3f" % drift)
	_check("the hang is pinned to the verified lip (gap < 0.25 m)",
			worst_lip_gap < 0.25, "worst=%.3f" % worst_lip_gap)
	var hold: Dictionary = _parkour.get("_hang_hold") as Dictionary
	_check("the recorded hold is the verified cornice band",
			String(hold.get("kind", "")) == "cornice"
			and absf(float((hold.get("lip") as Vector3).y) - DRIVEN_LIP) < 0.05,
			str(hold.get("kind", "")) + " lip=" + str(hold.get("lip", Vector3.ZERO)))
	_check("the recorded hold is anchored (no free standing spot)",
			bool(hold.get("anchored", false)) and not bool(hold.get("stand_clear", true)),
			"stand_clear=" + str(hold.get("stand_clear", true)))
	_check("the hang pinning really ran on the hold",
			int(_parkour.get("hang_ticks")) > 0,
			"hang_ticks=%d" % int(_parkour.get("hang_ticks")))
	_survivor.stop_moving()
	await get_tree().physics_frame


func _case_driven_shimmy() -> void:
	_clear_fixture()
	_hang_fixture()
	await _place(Vector3(0, 0.2, DRIVEN_START_Z))
	_survivor.stamina = 100.0        # each driven case is an independent climb
	_reset_parkour_state()
	_parkour.set("_ledge_cooldown", 10.0)
	await _place(Vector3(0, 1.3, 0.4))
	var probe := _probe(Vector3(0, 0, -1))
	_check("shimmy fixture verifies a wide band",
			not probe.is_empty() and float(probe.get("usable_half_width", 0.0)) >= 0.95,
			_describe(probe))
	if probe.is_empty():
		_reset_parkour_state()
		await _clear_fixture()
		return
	var lip := probe["lip"] as Vector3
	var wall_n := probe["wall_normal"] as Vector3
	var half_w := float(probe.get("usable_half_width", 0.0))
	# The survivor's own right-hand axis on this wall (the record's `tangent` is
	# its mirror; both are measured, this one is signed the way the body moves).
	var tangent := (-wall_n).cross(Vector3.UP).normalized()
	_parkour.set("_ledge_cooldown", 0.0)
	_reset_parkour_state()
	await _settle_on_ground(Vector3(0, 0.2, DRIVEN_START_Z))
	await _walk_in(30)
	var at_wall := _probe(Vector3(0, 0, -1))
	var loco0: CharacterLocomotion = _survivor.get_locomotion()
	print("[ParkourTest] shimmy setup: z=%.2f state=%d stamina=%.1f exhausted=%s near=%s"
			% [_survivor.global_position.z,
			-1 if loco0 == null or not is_instance_valid(loco0) else int(loco0.state),
			_survivor.stamina, str(_survivor.exhausted), _describe(at_wall)])
	var grabs_before := int(_parkour.get("ledge_grabs"))
	var hang_frames := 0
	var shimmy_frames := 0
	var moved := false
	_parkour.call("try_jump")
	for i in 200:
		await get_tree().physics_frame
		var loco: CharacterLocomotion = _survivor.get_locomotion()
		if loco == null or not is_instance_valid(loco):
			continue
		var st := int(loco.state)
		if st == CharacterLocomotion.State.HANG:
			hang_frames += 1
		elif st == CharacterLocomotion.State.SHIMMY:
			shimmy_frames += 1
		if hang_frames + shimmy_frames > 4:
			# Keep asking for the lateral move: that is what a shimmy is.
			_survivor.request_move(Vector3(1, 0, 0), false)
			moved = true
	var travel := absf((_survivor.global_position - lip).dot(tangent))
	var ends := int(_parkour.get("shimmy_ends"))
	print("[ParkourTest] shimmy: hang=%d shimmy=%d travel=%.3f half_width=%.3f ends=%d grabs %d->%d"
			% [hang_frames, shimmy_frames, travel, half_w, ends, grabs_before,
			int(_parkour.get("ledge_grabs"))])
	_check("a jump at a 2.4 m band latches a hold (shimmy case)",
			int(_parkour.get("ledge_grabs")) > grabs_before,
			"grabs %d->%d" % [grabs_before, int(_parkour.get("ledge_grabs"))])
	_check("hang state really runs on the band", hang_frames + shimmy_frames > 5,
			"hang=%d shimmy=%d" % [hang_frames, shimmy_frames])
	_check("the band is measured wide enough to shimmy",
			half_w >= 0.95, "half_w=%.3f" % half_w)
	_check("shimmy stays inside the measured ledge",
			travel <= half_w + 0.35, "travel=%.3f half_w=%.3f" % [travel, half_w])
	_check("shimmy made real lateral progress",
			travel > 0.20, "travel=%.3f moved=%s" % [travel, str(moved)])
	_survivor.stop_moving()
	await _clear_fixture()
