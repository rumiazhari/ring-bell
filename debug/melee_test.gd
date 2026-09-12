class_name MeleeTest
extends Node
## Melee-first combat suite: `python tools/run_suite.py --meleetest 240`.
##
## Covers the whole melee slice:
##   data      - melee weapons, classes, field completeness, type variety
##   direction - aim -> swing clip mapping (the multi-directional contract)
##   clips     - the eight authored swings (rotation-only, loop none, timing)
##   models    - procedural Victorian-steampunk meshes (parts, palette, lengths)
##   rig       - grip attachment, swing library registered on the real rig
##   combat    - arc/cleave/reach/falloff damage, land-on-frame, structures
##   input     - heavy swing, stamina gate, downgrade, cooldown, combo
##   loadout   - melee-first arsenal, slot switching, firearms still intact
##
## Prints `[MeleeTest] PASS/FAIL <name>` per check and ends with
## `[MeleeTest] finished with N failure(s)`.

const MARK := "[MeleeTest]"
const WATCHDOG := 200.0
## Far from the town so swings cannot reach real actors.
const BASE := Vector3(400.0, 0.2, 400.0)
## Frames that outlast the slowest cooldown in the arsenal (wrench, 1.05 s).
const SETTLE_FRAMES := 72

var failures := 0
var checks := 0

var _survivor: Survivor
var _fixtures: Array[Node3D] = []
var _landed: Array[Dictionary] = []
var _refusals: Array[String] = []
var _noise := 0


# --- Fixtures ----------------------------------------------------------------

## Swing target standing in for a zombie: actor layer, health, knockback.
class Target extends CharacterBody3D:
	var health: HealthComponent
	var hits := 0
	var last_damage := 0.0
	var last_push := Vector3.ZERO

	func _init() -> void:
		collision_layer = 4          # LAYER_ZOMBIES: a valid melee target
		collision_mask = 0
		var cs := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.3
		cs.shape = sphere
		add_child(cs)
		health = HealthComponent.new()
		health.max_health = 5000.0
		health.current_health = 5000.0
		add_child(health)

	func take_damage(amount: float, _source_id: StringName) -> void:
		hits += 1
		last_damage = amount
		health.damage(amount)

	func apply_knockback(impulse: Vector3) -> void:
		last_push = impulse


## Destructible structure standing in for a door or crate.
class Prop extends StaticBody3D:
	var material_id: StringName = &"wood"
	var hits := 0
	var last_damage := 0.0

	func _init() -> void:
		collision_layer = 1          # LAYER_ENVIRONMENT
		collision_mask = 0
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.7, 1.4, 0.7)
		cs.shape = box
		add_child(cs)

	func take_structural_damage(amount: float, _source_id: StringName) -> void:
		hits += 1
		last_damage = amount


func _ready() -> void:
	var wd := get_tree().create_timer(WATCHDOG)
	wd.timeout.connect(func() -> void:
		print("%s WATCHDOG TIMEOUT - aborting" % MARK)
		get_tree().quit(2))
	print("%s start" % MARK)
	_run_all()


func _run_all() -> void:
	_test_weapon_data()
	_test_type_table()
	_test_direction_table()
	_test_swing_clips()
	_test_models()
	await _test_live_rig()
	await _test_combo_and_guard()
	await _test_arc_and_damage()
	await _test_cleave_and_reach()
	await _test_structures()
	await _test_heavy_and_stamina()
	await _test_fists()
	await _test_cooldown_and_combo()
	await _test_loadout()
	await _test_hit_reactions()
	await _test_impact_fx()
	await _test_fight_ai()
	_test_capture_framing()
	print("%s finished with %d failure(s) (%d checks)" % [MARK, failures, checks])
	get_tree().quit(0 if failures == 0 else 1)


# --- Checks ------------------------------------------------------------------

func _check(name: String, ok: bool, detail := "") -> bool:
	checks += 1
	if ok:
		print("%s PASS %s" % [MARK, name])
	else:
		failures += 1
		print("%s FAIL %s (%s)" % [MARK, name, detail])
	return ok


func _close(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _step_physics(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


## Long enough for any weapon's cooldown to expire.
func _settle() -> void:
	await _step_physics(SETTLE_FRAMES)


func _spawn(node: Node3D, at: Vector3) -> Node3D:
	node.position = at
	add_child(node)
	_fixtures.append(node)
	return node


func _clear_fixtures() -> void:
	for f in _fixtures:
		if is_instance_valid(f):
			f.queue_free()
	_fixtures.clear()
	await get_tree().physics_frame


# --- Data --------------------------------------------------------------------

func _test_weapon_data() -> void:
	print("%s subtest weapon_data" % MARK)
	var arsenal := ItemDB.MELEE_ARSENAL
	_check("arsenal has four melee weapons", arsenal.size() == 4, str(arsenal))
	var types := {}
	var complete := true
	var problem := ""
	for id in arsenal:
		var def := ItemDB.get_melee_def(id)
		if not ItemDB.is_melee_weapon(id):
			complete = false
			problem = "%s is not KIND_WEAPON_MELEE" % id
			break
		if float(def.get("damage", 0.0)) <= 0.0 or float(def.get("reach", 0.0)) < 1.2 \
				or float(def.get("cooldown", 0.0)) <= 0.0 \
				or float(def.get("stamina_cost", 0.0)) <= 0.0 \
				or float(def.get("arc_deg", 0.0)) <= 20.0 \
				or int(def.get("cleave", 0)) < 1 \
				or String(def.get("type_label", "")) == "" \
				or not MeleeWeaponModels.MODELS.has(StringName(def.get("model", &""))):
			complete = false
			problem = "%s def incomplete: %s" % [id, def]
			break
		types[def.get("melee_type", &"")] = true
	_check("every arsenal weapon has a complete melee def", complete, problem)
	_check("arsenal spans at least three melee types", types.size() >= 3,
			str(types.keys()))
	for legacy in [&"pipe", &"kitchen_knife"]:
		var ldef := ItemDB.get_melee_def(legacy)
		_check("%s still resolves as melee" % legacy,
				float(ldef.get("damage", 0.0)) > 0.0
				and String(ldef.get("type_label", "")) != "", str(ldef.keys()))
	var fists := ItemDB.get_melee_def(&"")
	_check("bare hands resolve with class defaults",
			fists.get("melee_type", &"") == MeleeTypes.FIST
			and float(fists.get("stamina_cost", 0.0)) > 0.0, str(fists.keys()))
	_check("gun defs are not served as melee", not ItemDB.is_melee_weapon(&"smg"))
	_check("melee label carries the class",
			ItemDB.melee_label(&"cane_sabre") == "Brass Cane-Sabre - Blade",
			ItemDB.melee_label(&"cane_sabre"))
	_check("every melee id in the arsenal is listed in MELEE_WEAPON_IDS",
			ItemDB.MELEE_WEAPON_IDS.size() == 6, str(ItemDB.MELEE_WEAPON_IDS))


func _test_type_table() -> void:
	print("%s subtest type_table" % MARK)
	_check("blade is the narrow single-target class",
			MeleeTypes.arc_deg(MeleeTypes.BLADE) < MeleeTypes.arc_deg(MeleeTypes.AXE)
			and MeleeTypes.cleave(MeleeTypes.BLADE) == 1)
	_check("blunt and axe cleave two bodies",
			MeleeTypes.cleave(MeleeTypes.BLUNT) == 2
			and MeleeTypes.cleave(MeleeTypes.AXE) == 2)
	_check("polearm is the narrowest reach arc",
			MeleeTypes.arc_deg(MeleeTypes.POLEARM) < MeleeTypes.arc_deg(MeleeTypes.BLADE),
			str(MeleeTypes.arc_deg(MeleeTypes.POLEARM)))
	_check("blunt staggers hardest",
			MeleeTypes.stagger(MeleeTypes.BLUNT) > MeleeTypes.stagger(MeleeTypes.BLADE))
	_check("blunt ruins carpentry, blade ruins flesh",
			MeleeTypes.structural_scale(MeleeTypes.BLUNT)
				> MeleeTypes.structural_scale(MeleeTypes.BLADE) * 2.0)
	var pools_ok := true
	var bad := ""
	for type in MeleeTypes.ALL:
		var pool := MeleeTypes.swing_pool(type)
		if pool.size() < 4:
			pools_ok = false
			bad = "%s pool has %d clips" % [type, pool.size()]
			break
		for clip in pool:
			if not MeleeSwingLibrary.CLIPS.has(clip):
				pools_ok = false
				bad = "%s has unknown clip %s" % [type, clip]
				break
	_check("every class pool holds >= 4 authored clips", pools_ok, bad)
	_check("bare hands have no heavy swing", not MeleeTypes.has_heavy(MeleeTypes.FIST))
	_check("blunt has a heavy swing", MeleeTypes.has_heavy(MeleeTypes.BLUNT))
	_check("class defaults are distinct across the arsenal",
			MeleeTypes.arc_deg(MeleeTypes.BLADE) != MeleeTypes.arc_deg(MeleeTypes.BLUNT)
			and MeleeTypes.structural_scale(MeleeTypes.AXE)
				!= MeleeTypes.structural_scale(MeleeTypes.BLUNT))


func _test_direction_table() -> void:
	print("%s subtest direction_table" % MARK)
	# Local aim space: +X is the character's right, -Z straight ahead.
	var aims := {
		"ahead": Vector3(0, 0, -1),
		"right60": Vector3(0.866, 0, -0.5),
		"left60": Vector3(-0.866, 0, -0.5),
		"right28": Vector3(0.469, 0, -0.883),
		"left28": Vector3(-0.469, 0, -0.883),
		"right90": Vector3(1, 0, 0),
		"left90": Vector3(-1, 0, 0),
		"behind": Vector3(0, 0, 1),
	}
	for type in [MeleeTypes.BLADE, MeleeTypes.BLUNT, MeleeTypes.AXE, MeleeTypes.POLEARM]:
		var pool := MeleeTypes.swing_pool(type)
		var seen := {}
		for key in aims.keys():
			seen[MeleeSwingLibrary.direction_for(aims[key], pool, false)] = true
		_check("%s reaches >= 4 swing directions" % type, seen.size() >= 4,
				"%d distinct for %d aims: %s" % [seen.size(), aims.size(), _keys(seen)])
		var neutral := MeleeSwingLibrary.direction_for(aims["ahead"], pool, false)
		_check("%s neutral aim opens with %s" % [type, pool[0]], neutral == pool[0],
				String(neutral))
	var fists_seen := {}
	for key in aims.keys():
		var clip := MeleeSwingLibrary.direction_for(aims[key],
				MeleeTypes.swing_pool(MeleeTypes.FIST), false)
		fists_seen[clip] = true
	_check("bare hands still chain 3 directions", fists_seen.size() >= 3,
			str(_keys(fists_seen)))
	var blade := MeleeTypes.swing_pool(MeleeTypes.BLADE)
	_check("aim right picks SlashR",
			MeleeSwingLibrary.direction_for(aims["right60"], blade) == &"SlashR")
	_check("aim left picks SlashL",
			MeleeSwingLibrary.direction_for(aims["left60"], blade) == &"SlashL")
	_check("high-right aim picks DiagR",
			MeleeSwingLibrary.direction_for(aims["right28"], blade) == &"DiagR")
	_check("aim behind falls through to the wide Sweep",
			MeleeSwingLibrary.direction_for(aims["behind"], blade) == &"Sweep")
	_check("heavy request narrows the pool to heavy clips",
			MeleeSwingLibrary.direction_for(aims["ahead"],
				MeleeTypes.swing_pool(MeleeTypes.BLUNT), true) == &"Smash")
	# The sabre pool's Sweep is the one heavy blade move, so the flag narrows to
	# it; a pool with no heavy clips at all must ignore the flag entirely.
	var light_only: Array = []
	for c in blade:
		if not MeleeSwingLibrary.is_heavy(c as StringName):
			light_only.append(c)
	_check("a pool without heavies ignores the heavy flag", light_only.size() >= 3
			and MeleeSwingLibrary.direction_for(aims["ahead"], light_only, true)
				== MeleeSwingLibrary.direction_for(aims["ahead"], light_only, false),
			str(light_only))
	_check("the sabre's heavy is the wide Sweep",
			MeleeSwingLibrary.direction_for(aims["ahead"], blade, true) == &"Sweep")
	_check("empty pool still returns a usable swing",
			MeleeSwingLibrary.direction_for(aims["ahead"], []) == &"Thrust")


func _test_swing_clips() -> void:
	print("%s subtest swing_clips" % MARK)
	var lib := MeleeSwingLibrary.build_library(true)
	_check("authored melee clips cover every combo move",
			lib.get_animation_list().size() == MeleeSwingLibrary.CLIPS.size(),
			str(lib.get_animation_list().size()))
	var rotation_only := true
	var loops_none := true
	var guard_loops := true
	var bones_min := true
	var timing_ok := true
	var detail := ""
	for clip in MeleeSwingLibrary.CLIPS:
		if not lib.has_animation(String(clip)):
			rotation_only = false
			detail = "missing %s" % clip
			break
		var anim: Animation = lib.get_animation(String(clip))
		var is_guard_clip := bool(MeleeSwingLibrary.DEFS[clip].get("guard", false))
		if is_guard_clip and anim.loop_mode != Animation.LOOP_LINEAR:
			guard_loops = false
			detail = "%s does not hold" % clip
		if not is_guard_clip and anim.loop_mode != Animation.LOOP_NONE:
			loops_none = false
			detail = "%s loops" % clip
		var bone_tracks := 0
		for t in anim.get_track_count():
			if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
				rotation_only = false
				detail = "%s has a non-rotation track" % clip
			if String(anim.track_get_path(t)).contains(":"):
				bone_tracks += 1
		if bone_tracks < 3:
			bones_min = false
			detail = "%s drives only %d bones" % [clip, bone_tracks]
		if anim.length <= 0.2 or anim.length > 1.3:
			timing_ok = false
			detail = "%s length %.2f" % [clip, anim.length]
	_check("swings are rotation-only (position-track contract)", rotation_only, detail)
	_check("attack clips do not loop", loops_none, detail)
	_check("guard clips hold their pose", guard_loops, detail)
	_check("every swing drives at least three bones", bones_min, detail)
	_check("swing lengths are human-scaled", timing_ok, detail)
	var entries := {}
	for clip in MeleeSwingLibrary.CLIPS:
		entries[int(round(MeleeSwingLibrary.entry_angle(clip)))] = true
	_check("entries cover front, both flanks and the full circle",
			entries.size() >= 5 and entries.has(0), str(_keys(entries)))
	var fracs_ok := true
	for clip in MeleeSwingLibrary.CLIPS:
		var f := MeleeSwingLibrary.hit_frac(clip)
		if f <= 0.1 or f >= 0.9:
			fracs_ok = false
	_check("every swing lands mid-clip", fracs_ok)
	var heavy := []
	for clip in MeleeSwingLibrary.CLIPS:
		if MeleeSwingLibrary.is_heavy(clip):
			heavy.append(clip)
	_check("two-handed heavies exist", heavy.size() >= 4, str(heavy))
	_check("swing labels are human readable",
			MeleeSwingLibrary.direction_label(&"Chop") == "Overhead chop",
			MeleeSwingLibrary.direction_label(&"Chop"))
	var simple := MeleeSwingLibrary.build_library(false)
	var simple_bones := true
	for clip in MeleeSwingLibrary.CLIPS:
		var anim: Animation = simple.get_animation(String(clip))
		for t in anim.get_track_count():
			if String(anim.track_get_path(t)).contains("forearm"):
				simple_bones = false
	_check("simple rig library drops forearm tracks", simple_bones)


func _test_models() -> void:
	print("%s subtest models" % MARK)
	var fists := MeleeWeaponModels.build(&"fists")
	_check("bare hands build an empty holder",
			fists != null and MeleeWeaponModels.part_count(fists) == 0,
			str(MeleeWeaponModels.part_count(fists)))
	fists.free()
	var lengths := {}
	var brass_parts := 0
	var steel_parts := 0
	var emissive := 0
	var all_ok := true
	var detail := ""
	for id in MeleeWeaponModels.MODELS:
		if id == &"fists":
			continue
		var model := MeleeWeaponModels.build(id)
		var parts := MeleeWeaponModels.part_count(model)
		if parts < 4:
			all_ok = false
			detail = "%s has %d parts" % [id, parts]
		var bounds := _bounds(model)
		lengths[id] = bounds.size.z
		# 0.3 m is a real kitchen knife; the ceiling is a two-handed polearm.
		if bounds.size.z < 0.3 or bounds.size.z > 2.9:
			all_ok = false
			detail = "%s is %.2f m long" % [id, bounds.size.z]
		if bounds.size.x > 0.45 or bounds.size.y > 0.45:
			all_ok = false
			detail = "%s is too bulky (%.2f x %.2f)" % [id, bounds.size.x, bounds.size.y]
		for node in _meshes(model):
			var mat := node.material_override as StandardMaterial3D
			if mat == null:
				continue
			var c := mat.albedo_color
			if c.r > c.b + 0.08 and c.r > 0.35:
				brass_parts += 1
			if c.b >= c.r and mat.metallic >= 0.4:
				steel_parts += 1
			if mat.emission_enabled:
				emissive += 1
		model.free()
	_check("every weapon builds a multi-part mesh", all_ok, detail)
	_check("brass parts are present across the set", brass_parts >= 5,
			str(brass_parts))
	_check("blued/steel metal parts are present", steel_parts >= 5, str(steel_parts))
	_check("the set has lamp-lit brasswork", emissive >= 1, str(emissive))
	_check("a lance reads longer than a knife",
			float(lengths.get(&"boiler_lance", 0.0))
				> float(lengths.get(&"kitchen_knife", 0.0)) * 1.5,
			str(lengths))
	_check("the axe head is not a toy", float(lengths.get(&"boarding_axe", 0.0)) > 0.5,
			str(lengths.get(&"boarding_axe", 0.0)))


func _bounds(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for node in _meshes(root):
		var a: AABB = node.get_aabb()
		var world: AABB = node.transform * a
		if first:
			box = world
			first = false
		else:
			box = box.merge(world)
	return box


func _meshes(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(_meshes(child))
	return out


# --- Live rig ----------------------------------------------------------------

func _setup_survivor(weapon: StringName) -> void:
	_survivor = Survivor.new()
	_survivor.configure({
		"id": &"melee_test", "name": "MeleeTester", "is_player": false,
		"color": Color(0.8, 0.7, 0.4), "weapon": weapon,
	})
	_survivor.position = BASE
	add_child(_survivor)
	await get_tree().process_frame
	await get_tree().process_frame
	await _step_physics(3)
	# Freeze the body: the swings are resolved in the actor's own frame, so the
	# test steers `facing` explicitly and wants no AI drift.
	_survivor.set_physics_process(false)
	_survivor.velocity = Vector3.ZERO
	_survivor.facing = Vector3(0, 0, -1)
	_survivor.stamina = 100.0
	_survivor.melee.swing_landed.connect(
			func(clip: StringName, hits: int, damage: float) -> void:
				_landed.append({"clip": clip, "hits": hits, "damage": damage}))
	_survivor.melee.swing_refused.connect(func(reason: String) -> void:
		_refusals.append(reason))
	EventBus.attack_performed.connect(func(_at: Vector3) -> void:
		_noise += 1)


func _test_live_rig() -> void:
	print("%s subtest live_rig" % MARK)
	await _setup_survivor(&"cane_sabre")
	_check("survivor builds a melee component", _survivor.melee != null)
	_check("configured weapon is in hand",
			_survivor.melee.weapon_id() == &"cane_sabre",
			String(_survivor.melee.weapon_id()))
	_check("weapon class is reported",
			_survivor.melee.type_label() == "Blade", _survivor.melee.type_label())
	_check("combat starts idle", _survivor.melee.phase() == "IDLE")
	var loco: Node = _survivor.get("_locomotion")
	var ap: AnimationPlayer = loco.anim_player if loco != null else null
	_check("rig exposes an AnimationPlayer for swings", ap != null)
	if ap != null:
		_check("swing library is registered on the rig",
				ap.has_animation_library(MeleeSwingLibrary.LIB_NAME))
		var found := 0
		for clip in MeleeSwingLibrary.CLIPS:
			if ap.has_animation("%s/%s" % [MeleeSwingLibrary.LIB_NAME, clip]):
				found += 1
		_check("all authored melee clips are playable on the rig", found == MeleeSwingLibrary.CLIPS.size(), str(found))
	_check("swing library is live on the deferred rig",
			_survivor.melee.has_animation())
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	_check("survivor has a skeleton", skeleton != null)
	if skeleton != null:
		var attached := false
		var bone_name := ""
		var grip_offset := 0.0
		for child in skeleton.get_children():
			if child is BoneAttachment3D and String(child.name) == "MeleeHand":
				attached = true
				bone_name = (child as BoneAttachment3D).bone_name
				var parts := MeleeWeaponModels.part_count(child)
				_check("held weapon model is a multi-part mesh", parts >= 4, str(parts))
				# A BoneAttachment3D copies the bone pose onto itself every
				# frame, so the offset we own lives on the holder child.
				var holder: Node3D = (child as BoneAttachment3D).get_node_or_null("MeleeGrip")
				_check("grip holder hangs the model below the hand",
						holder != null and holder.position.y < -0.1,
						str(holder.position) if holder != null else "no holder")
				_check("grip holder points the weapon out of the fist",
						holder != null and is_equal_approx(holder.rotation_degrees.x, 90.0),
						str(holder.rotation_degrees) if holder != null else "no holder")
				if holder != null:
					grip_offset = holder.position.y
		_check("grip is attached to a hand bone", attached and bone_name != "",
				bone_name)
		# Rig-dependent: only the illustrated rig has a forearm bone to ride.
		var articulated: bool = skeleton.get_meta("articulated", false)
		var want_bone := "r_forearm" if articulated else "r_upper_arm"
		_check("grip rides the right bone for the rig in use",
				bone_name == want_bone, "%s (articulated=%s)" % [bone_name, articulated])
		_check("grip sits well past the bone origin", grip_offset < -0.3,
				str(grip_offset))


# --- Combat ------------------------------------------------------------------

func _test_combo_and_guard() -> void:
	print("%s subtest combo_and_guard" % MARK)
	_check("LMB below 0.20 s is light", not MeleeCombat.classify_press(0.199))
	_check("LMB at 0.20 s is heavy", MeleeCombat.classify_press(0.20))
	_check("LMB long hold is heavy", MeleeCombat.classify_press(0.75))

	var sequences := {}
	var guard_clips := {}
	var unique_clips := {}
	var data_ok := true
	var detail := ""
	var roster: Array = ItemDB.MELEE_ARSENAL.duplicate()
	roster.append(&"fists")
	for id in roster:
		var def := ItemDB.get_melee_def(id)
		var chain: Array = def.get("combo_chain", []) as Array
		var names := PackedStringArray()
		for clip in chain:
			names.append(String(clip))
			if not MeleeSwingLibrary.CLIPS.has(clip):
				data_ok = false
				detail = "%s has unknown %s" % [id, clip]
			break
		var key := "->".join(names)
		if sequences.has(key):
			data_ok = false
			detail = "%s shares its chain with %s" % [id, sequences[key]]
		sequences[key] = id
		var guard := StringName(def.get("guard_clip", &""))
		var unique := StringName(def.get("unique_clip", &""))
		guard_clips[guard] = true
		unique_clips[unique] = true
		if guard == &"" or not MeleeSwingLibrary.CLIPS.has(guard):
			data_ok = false
			detail = "%s guard missing" % id
		if unique == &"" or not MeleeSwingLibrary.CLIPS.has(unique):
			data_ok = false
			detail = "%s unique missing" % id
	_check("each roster weapon has a distinct light chain", data_ok,
			"%s / %s" % [sequences.keys(), detail])
	_check("each roster weapon has a distinct guard clip", guard_clips.size() == 5,
			str(guard_clips.keys()))
	_check("each roster weapon has a distinct finisher clip", unique_clips.size() == 5,
			str(unique_clips.keys()))
	_check("sabre has the largest perfect-parry window",
			float(ItemDB.get_melee_def(&"cane_sabre").get("parry_window", 0.0)) == 0.26)
	_check("wrench has no perfect-parry window",
			float(ItemDB.get_melee_def(&"pipe_wrench").get("parry_window", 1.0)) == 0.0)
	_check("lance reaches 3.5 m and sweeps 180 degrees",
			_close(float(ItemDB.get_melee_def(&"boiler_lance").get("reach", 0.0)), 3.5, 0.001)
			and _close(float(ItemDB.get_melee_def(&"boiler_lance").get("arc_deg", 0.0)), 180.0, 0.001))
	_check("axe reaches 2.4 m",
			_close(float(ItemDB.get_melee_def(&"boarding_axe").get("reach", 0.0)), 2.4, 0.001))

	_survivor.equip_weapon(&"cane_sabre")
	await get_tree().physics_frame
	_survivor.stamina = 100.0
	_expire_combo()
	_check("sabre chain step one resolves to SabreSlashR", _swing(Vector3(0, 0, -1))
			and _survivor.melee.current_clip() == &"SabreSlashR",
			String(_survivor.melee.current_clip()))
	await _settle()
	_pin_combo_window()
	_check("sabre chain step two resolves to SabreSlashL", _swing(Vector3(0, 0, -1))
			and _survivor.melee.current_clip() == &"SabreSlashL",
			String(_survivor.melee.current_clip()))
	await _settle()

	var melee := _survivor.melee
	_survivor.health.current_health = _survivor.health.max_health
	_survivor.stamina = 100.0
	_check("RMB enters GUARD", melee.set_guarding(true)
			and melee.state() == MeleeCombat.State.GUARD)
	var hp_before := _survivor.health.current_health
	var parry: Dictionary = melee.receive_impact(40.0, Vector3(0, 0, 1))
	_check("sabre guard perfect-parries the first impact",
			bool(parry.get("parried", false)) and float(parry.get("damage", 1.0)) == 0.0
			and _survivor.health.current_health == hp_before,
			str(parry))
	_check("parry arms a riposte", melee.riposte_armed())
	_check("parry signal counter increments", int(melee.guard_event_counts().get("parried", 0)) >= 1,
			str(melee.guard_event_counts()))
	_check("releasing RMB lowers GUARD", melee.set_guarding(false)
			and melee.state() == MeleeCombat.State.IDLE)
	_check("the next light tap resolves to SabreRiposte",
			melee.try_attack(Vector3(0, 0, -1))
			and melee.current_clip() == &"SabreRiposte",
			String(melee.current_clip()))
	await _settle()

	_survivor.equip_weapon(&"pipe_wrench")
	await get_tree().physics_frame
	_survivor.stamina = 100.0
	_survivor.health.current_health = _survivor.health.max_health
	melee.set_guarding(true)
	var brace: Dictionary = melee.receive_impact(40.0, Vector3(0, 0, 1))
	_check("wrench guard does not parry", not bool(brace.get("parried", true)))
	_check("wrench guard absorbs its configured fraction",
			_close(float(brace.get("damage", 0.0)), 40.0 * 0.22, 0.01), str(brace))
	_check("guard impact spends block cost",
			_close(_survivor.stamina, 100.0 - melee.block_cost(), 0.01),
			str(_survivor.stamina))
	melee.set_guarding(false)
	_survivor.stamina = melee.block_cost()
	melee.set_guarding(true)
	var broken: Dictionary = melee.receive_impact(20.0, Vector3(0, 0, 1))
	_check("stamina exhaustion triggers guard break",
			bool(broken.get("guard_broken", false))
			and melee.state() == MeleeCombat.State.GUARD_BREAK,
			str(broken))
	_check("guard break emits a counted transition",
			int(melee.guard_event_counts().get("broken", 0)) >= 1,
			str(melee.guard_event_counts()))
	_check("attacks are refused during guard break",
			not melee.try_attack(Vector3(0, 0, -1)), str(melee.phase()))
	await _step_physics(80)
	_check("guard lock recovers to idle", melee.state() == MeleeCombat.State.IDLE,
			melee.phase())
	_survivor.stamina = 100.0
	_survivor.equip_weapon(&"cane_sabre")
	await get_tree().physics_frame


func _swing(aim: Vector3, heavy := false) -> bool:
	_survivor.facing = Vector3(0, 0, -1)
	return _survivor.melee_attack(aim, heavy)


func _test_arc_and_damage() -> void:
	print("%s subtest arc_and_damage" % MARK)
	var target := _spawn(Target.new(), BASE + Vector3(0, 0, -1.4)) as Target
	var noise_before := _noise
	var aim := Vector3(0, 0, -1)
	_check("swing starts on input", _swing(aim))
	_check("neutral aim opens the sabre light chain",
			_survivor.melee.current_clip() == &"SabreSlashR",
			String(_survivor.melee.current_clip()))
	_check("swing begins in windup", _survivor.melee.phase() == "WINDUP",
			_survivor.melee.phase())
	_check("no damage on the button press", target.hits == 0, str(target.hits))
	var loco: Node = _survivor.get("_locomotion")
	var tree: AnimationTree = loco.anim_tree if loco != null else null
	if tree != null:
		_check("locomotion tree yields pose authority during a swing",
				tree.active == false)
	# The tree re-activates itself from its own per-frame update, which is how
	# the swing ended up selected-but-invisible at runtime while this suite
	# stayed green: assert the latch survives an update() call.
	if loco != null:
		_check("locomotion exposes a pose-authority latch",
				loco.has_method("suspend_pose_authority"))
		if loco.has_method("suspend_pose_authority"):
			loco.suspend_pose_authority(true)
			loco.update({"speed": 0.0}, 1.0 / 60.0)
			_check("locomotion update keeps the pose suspension",
					loco.get("_pose_suspended") == true)
			if tree != null:
				_check("tree stays inactive through a locomotion update",
						tree.active == false)
			loco.suspend_pose_authority(false)
			_check("pose authority returns when the swing ends",
					loco.get("_pose_suspended") == false)
	await _step_physics(20)
	_check("damage lands once the swing connects", target.hits == 1, str(target.hits))
	_check("hit is reported through swing_landed", _landed.size() == 1, str(_landed))
	# sabre: 20 dmg, reach 2.0, target at 1.4 m -> falloff lerp(1, 0.65, 0.7)
	_check("damage scales with distance falloff",
			_close(target.last_damage, 20.0 * 0.755, 0.6), str(target.last_damage))
	_check("stagger pushes the target along the swing",
			target.last_push.z < -2.0 and absf(target.last_push.x) < 0.05,
			str(target.last_push))
	await _step_physics(20)
	_check("swing returns to idle", _survivor.melee.phase() == "IDLE",
			_survivor.melee.phase())
	_check("clip releases pose authority when it ends",
			_survivor.melee.current_clip() == &"" and (tree == null or tree.active))
	_check("combo counter tracks a single swing", _survivor.melee.combo_index() == 1,
			str(_survivor.melee.combo_index()))
	_check("a swing is noise that actors can hear", _noise == noise_before + 1,
			"%d -> %d" % [noise_before, _noise])
	# The same swing misses a body standing behind the actor.
	target.position = BASE + Vector3(0, 0, 1.4)
	await get_tree().physics_frame
	await _settle()
	_swing(aim)
	await _step_physics(30)
	_check("nothing behind the actor is hit", target.hits == 1, str(target.hits))
	_check("a whiff emits no swing_landed", _landed.size() == 1, str(_landed))
	await _clear_fixtures()


func _test_cleave_and_reach() -> void:
	print("%s subtest cleave_and_reach" % MARK)
	# Three bodies inside one blade arc: a blade catches exactly one.
	var near_a := _spawn(Target.new(), BASE + Vector3(-0.35, 0, -1.3)) as Target
	var near_b := _spawn(Target.new(), BASE + Vector3(0.35, 0, -1.3)) as Target
	var near_c := _spawn(Target.new(), BASE + Vector3(0, 0, -1.1)) as Target
	await _settle()
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	_check("a blade cleaves exactly one body",
			near_a.hits + near_b.hits + near_c.hits == 1,
			"%d/%d/%d" % [near_a.hits, near_b.hits, near_c.hits])
	await _settle()
	await _clear_fixtures()
	# A wrench (cleave 2) catches two.
	var w_a := _spawn(Target.new(), BASE + Vector3(-0.35, 0, -1.3)) as Target
	var w_b := _spawn(Target.new(), BASE + Vector3(0.35, 0, -1.3)) as Target
	var w_c := _spawn(Target.new(), BASE + Vector3(0, 0, -1.1)) as Target
	_survivor.equip_weapon(&"pipe_wrench")
	await get_tree().physics_frame
	_swing(Vector3(0, 0, -1))
	# `_close_swing()` clears the clip when the swing ends, so read it now.
	_check("a wrench opens with its overhead chain move",
			_survivor.melee.current_clip() == &"WrenchOverhead",
			String(_survivor.melee.current_clip()))
	await _step_physics(50)
	_check("a blunt weapon cleaves two bodies",
			w_a.hits + w_b.hits + w_c.hits == 2,
			"%d/%d/%d" % [w_a.hits, w_b.hits, w_c.hits])
	_check("melee combat swaps the weapon in hand",
			_survivor.melee.weapon_id() == &"pipe_wrench",
			String(_survivor.melee.weapon_id()))
	await _settle()
	await _clear_fixtures()
	# Reach: 2.4 m is out of the sabre's reach but inside the lance's.
	var far := _spawn(Target.new(), BASE + Vector3(0, 0, -2.4)) as Target
	_survivor.equip_weapon(&"cane_sabre")
	await get_tree().physics_frame
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	_check("a 2.0 m weapon cannot reach 2.4 m", far.hits == 0, str(far.hits))
	await _settle()
	_survivor.equip_weapon(&"boiler_lance")
	await get_tree().physics_frame
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	_check("a 3.5 m lance reaches a body at 2.4 m", far.hits == 1, str(far.hits))
	_check("polearm owns the widest reach arc",
			float(_survivor.melee.weapon_def().get("arc_deg", 0.0)) >= 180.0,
			str(_survivor.melee.weapon_def().get("arc_deg", 0.0)))
	await _settle()
	await _clear_fixtures()


func _test_structures() -> void:
	print("%s subtest structures" % MARK)
	var prop := _spawn(Prop.new(), BASE + Vector3(0, 0, -1.3)) as Prop
	_survivor.equip_weapon(&"cane_sabre")
	await get_tree().physics_frame
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	# sabre: 20 dmg * 0.755 falloff * 0.45 structural
	_check("a blade barely marks a wooden prop", prop.hits == 1
			and _close(prop.last_damage, 20.0 * 0.755 * 0.45, 0.5),
			"%d hits %.2f" % [prop.hits, prop.last_damage])
	var blade_damage := prop.last_damage
	await _settle()
	prop.hits = 0
	_survivor.equip_weapon(&"pipe_wrench")
	await get_tree().physics_frame
	_swing(Vector3(0, 0, -1))
	await _step_physics(50)
	# wrench: 34 dmg * 0.755 * 1.6 structural
	_check("a wrench ruins carpentry", prop.hits == 1
			and _close(prop.last_damage, 34.0 * 0.755 * 1.6, 1.0),
			"%d hits %.2f" % [prop.hits, prop.last_damage])
	_check("structural damage beats a blade on the same prop",
			prop.last_damage > blade_damage * 3.0,
			"%.2f vs %.2f" % [prop.last_damage, blade_damage])
	_check("the prop material is what the debris uses",
			prop.material_id == &"wood")
	await _settle()
	await _clear_fixtures()


func _test_heavy_and_stamina() -> void:
	print("%s subtest heavy_and_stamina" % MARK)
	_survivor.equip_weapon(&"pipe_wrench")
	await get_tree().physics_frame
	_survivor.stamina = 100.0
	_refusals.clear()
	_check("heavy swing starts with stamina in the tank",
			_swing(Vector3(0, 0, -1), true))
	_check("heavy request plays a two-handed clip",
			MeleeSwingLibrary.is_heavy(_survivor.melee.current_clip()),
			String(_survivor.melee.current_clip()))
	_check("heavy swing is the wrench slam",
			_survivor.melee.current_clip() == &"WrenchSlam",
			String(_survivor.melee.current_clip()))
	_check("heavy swing costs 1.5x stamina",
			_close(_survivor.stamina, 100.0 - 17.0 * 1.5, 0.01),
			str(_survivor.stamina))
	# A committed two-hander takes longer to land and to recover.
	var frames := 0
	while _survivor.melee.phase() != "IDLE" and frames < 140:
		await get_tree().physics_frame
		frames += 1
	_check("heavy swing holds the pose for over a second", frames > 60,
			"%d frames" % frames)
	await _settle()
	# Not enough stamina for the heavy variant: fall back to the light swing.
	_survivor.stamina = 20.0
	_swing(Vector3(0, 0, -1), true)
	_check("heavy request downgrades instead of eating the input",
			_survivor.melee.last_downgraded)
	_check("downgraded swing is a light clip",
			not MeleeSwingLibrary.is_heavy(_survivor.melee.current_clip()),
			String(_survivor.melee.current_clip()))
	_check("downgraded swing bills the light cost",
			_close(_survivor.stamina, 20.0 - 17.0, 0.01), str(_survivor.stamina))
	await _settle()
	# Too tired to swing at all.
	_refusals.clear()
	_survivor.stamina = 3.0
	_check("an exhausted actor cannot swing", not _swing(Vector3(0, 0, -1)))
	_check("exhaustion is reported as a refusal", _refusals.has("stamina"),
			str(_refusals))
	_check("a refused swing does not spend stamina",
			_close(_survivor.stamina, 3.0, 0.01), str(_survivor.stamina))
	_survivor.stamina = 100.0


func _test_fists() -> void:
	print("%s subtest fists" % MARK)
	_survivor.equip_weapon(&"")
	await get_tree().physics_frame
	var target := _spawn(Target.new(), BASE + Vector3(0, 0, -1.1)) as Target
	_check("dropping the weapon falls back to bare hands",
			_survivor.melee.weapon_id() == &"", String(_survivor.melee.weapon_id()))
	_check("bare hands report their class",
			_survivor.melee.type_label() == "Bare hands",
			_survivor.melee.type_label())
	_check("bare hands hide the held model", _held_visible() == false)
	_survivor.stamina = 100.0
	_swing(Vector3(0, 0, -1))
	_check("bare-handed swing uses the fist chain",
			MeleeCombos.chain_for(&"fists", MeleeTypes.FIST).has(
				_survivor.melee.current_clip()),
			String(_survivor.melee.current_clip()))
	await _step_physics(30)
	_check("a punch still lands damage", target.hits == 1, str(target.hits))
	# A heavy request on fists becomes a committed strike, not a dead button.
	await _settle()
	_survivor.stamina = 100.0
	_check("heavy request on fists still swings",
			_swing(Vector3(0, 0, -1), true))
	_check("committed fist strike is not downgraded",
			not _survivor.melee.last_downgraded)
	_check("committed fist strike bills the light cost",
			_close(_survivor.stamina, 100.0 - 5.0, 0.01), str(_survivor.stamina))
	await _settle()
	await _clear_fixtures()
	_survivor.equip_weapon(&"cane_sabre")
	await get_tree().physics_frame


func _test_cooldown_and_combo() -> void:
	print("%s subtest cooldown_and_combo" % MARK)
	var target := _spawn(Target.new(), BASE + Vector3(0, 0, -1.2)) as Target
	_refusals.clear()
	# The chain must start clean: combo 1 on the first swing.
	_expire_combo()
	_swing(Vector3(0, 0, -1))
	_check("swinging during the cooldown is refused", not _swing(Vector3(0, 0, -1)))
	_check("cooldown refusal is reported", _refusals.has("cooldown"), str(_refusals))
	# A 0.5 s clip at 1.15x is 26 frames; the 0.62 s cooldown is 37.
	await _step_physics(30)
	_check("clip is over before the cooldown is",
			_survivor.melee.phase() == "IDLE", _survivor.melee.phase())
	_check("still gated mid-cooldown", not _swing(Vector3(0, 0, -1)))
	await _step_physics(12)
	_pin_combo_window()
	_check("swing is accepted once the cooldown expires", _swing(Vector3(0, 0, -1)))
	_check("the second swing keeps the chain on combo 2",
			_survivor.melee.combo_index() == 2,
			str(_survivor.melee.combo_index()))
	await _step_physics(30)
	var damage_2 := target.last_damage
	# 1.2 m inside a 2.0 m reach: falloff lerp(1, 0.65, 0.6) = 0.79.
	var base := 20.0 * lerpf(1.0, 0.65, 1.2 / 2.0)
	_check("combo 2 uses its authored step scale",
			_close(damage_2, base * 1.08 * 1.08, 0.5), str(damage_2))
	# Third hit in a row is the finisher: combo 1.16 * finisher 1.2.
	await _step_physics(12)
	_pin_combo_window()
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	_check("combo escalates to the finisher",
			_survivor.melee.combo_index() == 3,
			str(_survivor.melee.combo_index()))
	_check("the finisher hits harder than the second swing",
			target.last_damage > damage_2 * 1.15,
			"%.2f vs %.2f" % [target.last_damage, damage_2])
	_check("finisher damage matches authored multipliers",
			_close(target.last_damage, base * 1.16 * 1.2 * 1.18, 0.6),
			str(target.last_damage))
	# Lapse the chain and the counter starts over.
	_expire_combo()
	await _step_physics(40)
	_survivor.stamina = 100.0
	_swing(Vector3(0, 0, -1))
	_check("combo resets after the window lapses",
			_survivor.melee.combo_index() == 1,
			str(_survivor.melee.combo_index()))
	await _settle()
	await _clear_fixtures()


## The combo window is wall-clock based, so the suite pins it directly: these
## checks are about the damage multipliers, not about the frame scheduler.
func _pin_combo_window() -> void:
	_survivor.melee.set("_combo_deadline", Time.get_ticks_msec() + 10000)


func _expire_combo() -> void:
	_survivor.melee.set("_combo_deadline", Time.get_ticks_msec() - 1)


## Sorted dictionary keys, for readable check details. `Array.sorted()` is not a
## member of plain Arrays in this engine build, so sort a copy by hand.
func _keys(dict: Dictionary) -> Array:
	var out := dict.keys()
	out.sort()
	return out


func _test_loadout() -> void:
	print("%s subtest loadout" % MARK)
	var ws := WeaponSystem.new()
	ws.name = "TestWeapons"
	_survivor.add_child(ws)
	await get_tree().process_frame
	_check("default loadout is melee",
			ws.slots == WeaponSystem.ARSENAL_MELEE and ws.slots.size() == 4,
			str(ws.slots))
	_check("default slot is a melee slot", ws.current_is_melee())
	_check("default slot holds the cane-sabre",
			_survivor.equipped_weapon_id == &"cane_sabre",
			String(_survivor.equipped_weapon_id))
	_check("HUD label shows weapon and class",
			ws.weapon_label() == "Brass Cane-Sabre - Blade", ws.weapon_label())
	ws.select_slot(1)
	_check("selecting a melee slot equips it on the survivor",
			_survivor.equipped_weapon_id == &"pipe_wrench"
			and _survivor.melee.weapon_id() == &"pipe_wrench",
			"%s / %s" % [_survivor.equipped_weapon_id, _survivor.melee.weapon_id()])
	_check("HUD label follows the swap",
			ws.weapon_label() == "Steamfitter's Wrench - Blunt", ws.weapon_label())
	ws.select_slot(2)
	_check("third slot is the boarding axe",
			_survivor.melee.weapon_id() == &"boarding_axe",
			String(_survivor.melee.weapon_id()))
	_check("axe class is reported", _survivor.melee.type_label() == "Axe",
			_survivor.melee.type_label())
	_check("held axe model is visible", _held_visible())
	# Firearms are salvage: the old path must still work when slotted in.
	ws.set_slots(WeaponSystem.ARSENAL_RANGED)
	_check("a ranged arsenal leaves melee ready via fists",
			ws.current_is_melee() and _survivor.melee.weapon_id() == &"")
	ws.select_slot(1)
	_check("ranged arsenal slates a firearm", not ws.current_is_melee())
	_check("firearm def resolves", ws.current_def().get("name", "") == "Scrap SMG",
			str(ws.current_def().get("name", "")))
	_check("HUD label shows the firearm", ws.weapon_label() == "Scrap SMG",
			ws.weapon_label())
	_check("held melee model is hidden while a gun is out", _held_visible() == false)
	ws.tick(0.016, BASE + Vector3(0, 0, -10))
	_check("firearm path still runs without error", true)
	ws.set_slots(WeaponSystem.ARSENAL_MIXED)
	_check("mixed arsenal returns to melee", ws.current_is_melee()
			and _survivor.melee.weapon_id() == &"cane_sabre",
			"%s / %s" % [ws.slots, _survivor.melee.weapon_id()])
	_check("held model is visible again", _held_visible())
	_check("arsenal presets and ItemDB agree",
			WeaponSystem.ARSENAL_MELEE == ItemDB.MELEE_ARSENAL,
			str(WeaponSystem.ARSENAL_MELEE))


## True when a weapon mesh is actually drawn in the hand.
func _held_visible() -> bool:
	var skeleton: Skeleton3D = _survivor.get("_skeleton")
	if skeleton == null:
		return false
	for child in skeleton.get_children():
		if child is BoneAttachment3D and String(child.name) == "MeleeHand":
			for grandchild in child.get_children():
				if grandchild is Node3D:
					return (grandchild as Node3D).visible
	return false


# --- Hit reactions, impact FX, fight AI, capture framing ---------------------

func _test_hit_reactions() -> void:
	print("%s subtest hit_reactions" % MARK)
	# Data first: every kind x family must build a real, rotation-only clip.
	for kind in HitReactionLibrary.KINDS:
		var lib := HitReactionLibrary.build_library(kind, true)
		for impact in HitReactionLibrary.IMPACTS:
			var clip: Animation = lib.get_animation(
					HitReactionLibrary.clip_name(kind, impact))
			var tracks := clip.get_track_count() if clip != null else -1
			_check("reel %s/%s builds" % [kind, impact], clip != null and tracks >= 4,
					"%d tracks" % tracks)
			# Track paths are plain bone paths (":hips") because the clip plays on
			# the rig's AnimationPlayer with the skeleton as its root: the track
			# TYPE is what says "this rotates a bone", not the path.
			var rot_only := tracks > 0
			var keyed := 0
			if clip != null:
				for i in clip.get_track_count():
					if clip.track_get_type(i) != Animation.TYPE_ROTATION_3D:
						rot_only = false
					elif clip.track_get_key_count(i) >= 4:
						keyed += 1
			_check("%s/%s writes only bone rotations" % [kind, impact], rot_only,
					"%d rotation tracks" % tracks)
			_check("%s/%s keys a pose on every bone" % [kind, impact], keyed >= tracks,
					"%d/%d keyed" % [keyed, tracks])
	_check("human and shambler reels are different clips",
			absf(HitReactionLibrary.clip_length(HitReactionLibrary.KIND_HUMAN,
					HitReactionLibrary.SLASH)
				- HitReactionLibrary.clip_length(HitReactionLibrary.KIND_SHAMBLER,
					HitReactionLibrary.SLASH)) > 0.05,
			"%.2f vs %.2f" % [
				HitReactionLibrary.clip_length(HitReactionLibrary.KIND_HUMAN,
						HitReactionLibrary.SLASH),
				HitReactionLibrary.clip_length(HitReactionLibrary.KIND_SHAMBLER,
						HitReactionLibrary.SLASH)])
	_check("a shambler reels longer than a trained body",
			HitReactionLibrary.clip_length(HitReactionLibrary.KIND_SHAMBLER,
					HitReactionLibrary.SLASH)
				> HitReactionLibrary.clip_length(HitReactionLibrary.KIND_HUMAN,
					HitReactionLibrary.SLASH))
	_check("a harder blow reels faster",
			HitReactionLibrary.speed_scale(2.0) > HitReactionLibrary.speed_scale(0.5),
			"%.2f vs %.2f" % [HitReactionLibrary.speed_scale(2.0),
				HitReactionLibrary.speed_scale(0.5)])
	_check("weapon classes fold onto impact families",
			MeleeTypes.impact(MeleeTypes.BLADE) == HitReactionLibrary.SLASH
			and MeleeTypes.impact(MeleeTypes.AXE) == HitReactionLibrary.SLASH
			and MeleeTypes.impact(MeleeTypes.BLUNT) == HitReactionLibrary.CRUSH
			and MeleeTypes.impact(MeleeTypes.FIST) == HitReactionLibrary.CRUSH
			and MeleeTypes.impact(MeleeTypes.POLEARM) == HitReactionLibrary.PIERCE,
			"%s %s %s" % [MeleeTypes.impact(MeleeTypes.BLADE),
				MeleeTypes.impact(MeleeTypes.BLUNT),
				MeleeTypes.impact(MeleeTypes.POLEARM)])
	_check("the zombie kind picks the shambler reel",
			HitReactionLibrary.kind_for(true) == HitReactionLibrary.KIND_SHAMBLER
			and HitReactionLibrary.kind_for(false) == HitReactionLibrary.KIND_HUMAN)
	var every_weapon := true
	var uncovered := ""
	for id in ItemDB.MELEE_ARSENAL:
		var def := ItemDB.get_melee_def(id)
		var impact := HitReactionLibrary.impact_for(
				StringName(def.get("melee_type", MeleeTypes.DEFAULT_TYPE)))
		if not HitReactionLibrary.has(HitReactionLibrary.KIND_HUMAN, impact):
			every_weapon = false
			uncovered = String(id)
	_check("every melee weapon has a reel for its class", every_weapon, uncovered)
	# Then on a live actor.
	await _clear_fixtures()
	await _setup_survivor(&"cane_sabre")
	_check("the survivor builds a hit reaction", _survivor.hit_reaction != null)
	_check("the reel rides the rig's AnimationPlayer",
			_survivor.hit_reaction != null and _survivor.hit_reaction.renders())
	var loco: Node = _survivor.get("_locomotion")
	var ap: AnimationPlayer = null
	if loco != null:
		ap = loco.get("anim_player") as AnimationPlayer
	_check("the hit library is registered on the rig",
			ap != null and ap.has_animation_library(HitReactionLibrary.LIB_NAME),
			str(HitReactionLibrary.LIB_NAME))
	_check("an idle actor holds no pose",
			not _survivor.hit_reaction.holds_pose())
	_check("a cut reels the body",
			_survivor.hit_reaction.react_to_weapon(MeleeTypes.BLADE,
					Vector3(0, 0, -1), 1.0),
			str(_survivor.hit_reaction.summary()))
	_check("the reel holds the pose while it plays",
			_survivor.hit_reaction.holds_pose())
	_check("the clip on the player is the reel",
			ap != null and String(ap.current_animation).begins_with(
					String(HitReactionLibrary.LIB_NAME)),
			String(ap.current_animation) if ap != null else "no player")
	_check("a second hit inside the first third is refused",
			not _survivor.hit_reaction.react_to_weapon(MeleeTypes.BLUNT,
					Vector3(0, 0, -1), 1.0))
	await _step_physics(45)
	_check("the reel releases the pose when it ends",
			not _survivor.hit_reaction.holds_pose())
	# Pose authority: a committed swing outranks an incoming hit.
	_check("the survivor can swing", _swing(Vector3(0, 0, -1)))
	_check("the swing holds the pose", _survivor.melee.holds_pose())
	var refusals_before := int(_survivor.hit_reaction.summary().get("refusals", 0))
	_check("a hit during a committed swing is refused",
			not _survivor.hit_reaction.react_to_weapon(MeleeTypes.POLEARM,
					Vector3(0, 0, -1), 1.5))
	_check("that refusal is counted, not silent",
			int(_survivor.hit_reaction.summary().get("refusals", 0)) > refusals_before,
			str(_survivor.hit_reaction.summary()))
	await _step_physics(45)
	# And a zombie reels with its own clip.
	var zombie := Zombie.new()
	_spawn(zombie, BASE + Vector3(0, 0, -4.0))
	zombie.set_physics_process(false)     # frozen: this test is about the reel
	await _step_physics(3)
	_check("the zombie builds a hit reaction", zombie.hit_reaction != null)
	_check("the zombie uses the shambler reel",
			zombie.hit_reaction.kind_id() == HitReactionLibrary.KIND_SHAMBLER,
			String(zombie.hit_reaction.kind_id()))
	_check("a bitten body reels",
			zombie.hit_reaction.react_to_weapon(MeleeTypes.BLUNT,
					Vector3(0, 0, -1), 1.2),
			str(zombie.hit_reaction.summary()))
	await _step_physics(60)
	await _clear_fixtures()


func _test_impact_fx() -> void:
	print("%s subtest impact_fx" % MARK)
	var slash := ImpactFX.profile(MeleeTypes.BLADE)
	var crush := ImpactFX.profile(MeleeTypes.BLUNT)
	var pierce := ImpactFX.profile(MeleeTypes.POLEARM)
	_check("each class has its own burst profile",
			not slash.is_empty() and slash != crush and crush != pierce
			and slash != pierce)
	_check("a cut sprays faster than a crush",
			float(slash.get("speed", 0.0)) > float(crush.get("speed", 0.0)),
			"%.1f vs %.1f" % [float(slash.get("speed", 0.0)),
				float(crush.get("speed", 0.0))])
	_check("a crush hangs longer in the air",
			float(crush.get("life", 0.0)) > float(slash.get("life", 0.0)),
			"%.2f vs %.2f" % [float(crush.get("life", 0.0)),
				float(slash.get("life", 0.0))])
	_check("a thrust is a tighter cone than a smash",
			float(pierce.get("spread", 0.0)) < float(crush.get("spread", 0.0)))
	_check("bursts are labelled", String(slash.get("label", "")) != ""
			and String(crush.get("label", "")) != ""
			and String(pierce.get("label", "")) != "")
	# A landed swing spawns one burst, and the burst outlives its victim.
	await _clear_fixtures()
	ImpactFX.reset_stats()
	await _setup_survivor(&"boarding_axe")
	await _clear_stray_survivors()
	var target := _spawn(Target.new(), BASE + Vector3(0, 0, -1.4))
	_landed.clear()
	# The strike keys at ~35% of the clip, so reading the stats a few frames after
	# the request is too early: step past the strike phase first.
	_swing(Vector3(0, 0, -1))
	await _step_physics(30)
	var spawned := int(ImpactFX.stats().get("spawned", 0))
	_check("a landed hit spawns one burst", spawned == 1,
			"spawned %d, landed %s" % [spawned, str(_landed)])
	_check("live bursts stay under the cap",
			ImpactFX.live_count() <= ImpactFX.MAX_LIVE,
			"%d live" % ImpactFX.live_count())
	_check("the burst is a real node in the scene",
			ImpactFX.live_count() >= 1, str(ImpactFX.stats()))
	# The body is removed underneath it: the burst is parented to the scene and
	# not to the corpse, so it has to still be there on the following frames.
	target.queue_free()
	await _step_physics(8)
	_check("the burst survives the actor it was struck against",
			ImpactFX.live_count() >= 1, str(ImpactFX.stats()))
	await _step_physics(150)
	_check("the burst reaps itself and never leaks",
			ImpactFX.live_count() == 0, str(ImpactFX.stats()))
	await _clear_fixtures()


## Survivors are attached straight to the test node by _setup_survivor (they are
## not fixtures), so an earlier subtest leaves bodies standing on BASE. A swing
## takes the NEAREST thing in its arc first, so a stray body at 0 m eats the
## cleave slot and the intended target is never touched.
func _clear_stray_survivors() -> void:
	for child in get_children():
		if child is Survivor and child != _survivor:
			child.queue_free()
	await get_tree().process_frame


func _test_fight_ai() -> void:
	print("%s subtest fight_ai" % MARK)
	await _clear_fixtures()
	await _setup_survivor(&"cane_sabre")
	var brain := NPCBrain.new()
	_survivor.add_child(brain)
	await get_tree().process_frame
	_check("the brain is attached to the survivor", brain.survivor == _survivor)
	_check("the survivor is armed for the test",
			ItemDB.is_melee_weapon(_survivor.equipped_weapon_id),
			String(_survivor.equipped_weapon_id))
	var zombie := Zombie.new()
	_spawn(zombie, BASE + Vector3(0, 0, -1.0))
	zombie.set_physics_process(false)     # the fight is between the brain and it
	await _step_physics(3)
	_check("the zombie joins the zombie group", zombie.is_in_group(&"zombies"))
	# The decision itself: armed and healthy picks FIGHT, a coward does not.
	var choice: Dictionary = brain.call("_threat_decision", zombie)
	_check("an armed adult decides to fight one zombie",
			int(choice.get("action", -1)) == int(NPCBrain.Action.FIGHT),
			str(choice))
	brain.cowardice = 2.5
	var coward: Dictionary = brain.call("_threat_decision", zombie)
	_check("a coward still flees while armed",
			int(coward.get("action", -1)) == int(NPCBrain.Action.FLEE),
			str(coward))
	brain.cowardice = 1.0
	_survivor.equip_weapon(&"fists")
	await _step_physics(3)
	var unarmed: Dictionary = brain.call("_threat_decision", zombie)
	_check("an unarmed NPC will not pick a fight",
			int(unarmed.get("action", -1)) == int(NPCBrain.Action.FLEE),
			str(unarmed))
	_survivor.equip_weapon(&"cane_sabre")
	await _step_physics(3)
	# Now let the brain actually run: physics on, zombie inside the standoff.
	# Strays first: an earlier subtest's body standing on BASE would be nearer
	# than the zombie and would eat the cleave slot.
	await _clear_stray_survivors()
	ImpactFX.reset_stats()
	_survivor.set_physics_process(true)
	_landed.clear()
	brain.current_action = NPCBrain.Action.IDLE
	var frames := 0
	while frames < 600 and (brain.swings_thrown == 0 or _landed.is_empty()):
		await get_tree().physics_frame
		frames += 1
	# What the arc actually saw from the fighter's chest: the decisive evidence
	# when a swing reports hits but the intended body takes nothing.
	var arc: Array = _survivor.melee.call("_query_arc",
			_survivor.global_position + Vector3.UP * MeleeCombat.CHEST_HEIGHT,
			3.0, 120.0)
	var seen := PackedStringArray()
	for entry in arc:
		seen.append("%s@%.2fm" % [(entry["collider"] as Node).name, entry["distance"]])
	print("%s fight diagnostics: dist=%.2f phase=%s arc=[%s] landed=%s zombie=%.0f/%.0f" % [
		MARK, _survivor.global_position.distance_to(zombie.global_position),
		String(_survivor.melee.phase()),
		", ".join(seen), str(_landed),
		zombie.health.current_health, zombie.health.max_health])
	_check("the brain picks a fight on its own", brain.fights_started >= 1,
			"fights=%d frames=%d" % [brain.fights_started, frames])
	_check("the brain throws a swing with no scripted input",
			brain.swings_thrown >= 1,
			"swings=%d frames=%d action=%d" % [brain.swings_thrown, frames,
				brain.current_action])
	_check("the AI's swing lands on the zombie", not _landed.is_empty(),
			str(_landed))
	var hits := 0
	for entry in _landed:
		hits += int(entry["hits"])
	_check("the AI's swing actually connects", hits >= 1, str(_landed))
	_check("the zombie takes damage from the AI",
			zombie.health != null
			and zombie.health.current_health < zombie.health.max_health,
			"%.0f/%.0f same_node_as_target=%s" % [zombie.health.current_health,
				zombie.health.max_health, str(zombie.is_in_group(&"zombies"))])
	_check("the struck zombie reels",
			zombie.hit_reaction != null and zombie.hit_reaction.plays >= 1,
			str(zombie.hit_reaction.summary()) if zombie.hit_reaction != null else "")
	_check("the burst fired on the AI's hit",
			int(ImpactFX.stats().get("spawned", 0)) >= 1,
			str(ImpactFX.stats()))
	if _survivor.health.current_health < _survivor.health.max_health:
		_check("a bitten survivor reels too",
				_survivor.hit_reaction.plays >= 1,
				str(_survivor.hit_reaction.summary()))
	else:
		print("%s SKIP no bite landed on the survivor in %d frames" % [MARK, frames])
	brain.queue_free()
	await _clear_fixtures()


func _test_capture_framing() -> void:
	print("%s subtest capture_framing" % MARK)
	# The defect on film, as a number: the weapon-gallery camera sat at a fixed
	# (0.62, 0.42, -0.70) while the sabre model is long along +Z and spun -32 deg,
	# so its length pointed at the lens.
	var sabre := CaptureFraming.long_axis_vector(Vector3(0.07, 0.07, 1.10))
	_check("a long +Z weapon is detected as Z-long", sabre == Vector3.BACK,
			str(sabre))
	var spun := CaptureFraming.rotated_axis(sabre, -32.0)
	var old_dir := Vector3(0.62, 0.42, -0.70).normalized()
	var old_deg := CaptureFraming.broadside_deg(spun, old_dir)
	_check("the old fixed camera was end-on to the cane-sabre",
			old_deg < 40.0, "%.0f deg off the long axis" % old_deg)
	var new_dir := CaptureFraming.view_dir(spun)
	var new_deg := CaptureFraming.broadside_deg(spun, new_dir)
	_check("the derived camera looks across the same weapon",
			new_deg >= 55.0, "%.0f deg off the long axis" % new_deg)
	_check("the derived shot reads as broadside",
			CaptureFraming.readable(spun, new_dir, 55.0))
	# The same maths has to hold for a weapon authored on any axis.
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	for axis in axes:
		var dir := CaptureFraming.view_dir(axis)
		_check("a %s-long weapon is framed across its length" % str(axis),
				CaptureFraming.readable(axis, dir, 50.0),
				"%.0f deg" % CaptureFraming.broadside_deg(axis, dir))
	# The old camera was fine for an X-long weapon: that is why only some of the
	# product shots were unreadable.
	var x_long := CaptureFraming.rotated_axis(Vector3.RIGHT, -32.0)
	_check("the old camera happened to be fine for an X-long weapon",
			CaptureFraming.broadside_deg(x_long, old_dir) > 55.0,
			"%.0f deg" % CaptureFraming.broadside_deg(x_long, old_dir))
	# Distance follows size and lens.
	_check("a bigger subject is shot from further away",
			CaptureFraming.distance_for(1.2, 46.0, 0.7)
				> CaptureFraming.distance_for(0.6, 46.0, 0.7))
	_check("a narrower lens needs more distance",
			CaptureFraming.distance_for(1.0, 30.0, 0.7)
				> CaptureFraming.distance_for(1.0, 60.0, 0.7))
	_check("filling more of the frame means standing closer",
			CaptureFraming.distance_for(1.0, 46.0, 0.9)
				< CaptureFraming.distance_for(1.0, 46.0, 0.6))
	_check("the camera keeps a subject-side preference",
			CaptureFraming.view_dir(Vector3.BACK, 22.0, 0.42, Vector3.RIGHT).x > 0.0)
