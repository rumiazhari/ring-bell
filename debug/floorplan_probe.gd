extends Node
## Floor-plan probe: synthetic buildings across the footprint zoo, planned through
## InteriorPlan's archetype planner, validated, measured and dumped as JSON for
## tools/floorplan_render.py (top-down PNG contact sheet).
##
## Usage: godot --headless --path . -- --floorplanprobe [--fp-seeds N]
##        godot --headless --path . -- --floorplanprobe --fp-render   (PNG sheet)
## Prints per-footprint archetype spread and aggregate metrics, then the suite
## marker line "finished with N failure(s)".

const OUT_DIR := "res://out_floorplans"
const DEFAULT_SEEDS := 6

## Footprint zoo: the shapes the overhaul must serve. Positions are arbitrary
## (the planner works in local frame); sizes are the real variable.
const ZOO := [
	{"name": "narrow_deep_townhouse", "w": 6.4, "d": 15.0, "floors": 4, "edge": 2, "open": [2], "use": "residential"},
	{"name": "wide_shallow", "w": 14.0, "d": 7.6, "floors": 2, "edge": 2, "open": [2], "use": "residential"},
	{"name": "medium_rect", "w": 9.4, "d": 11.0, "floors": 3, "edge": 2, "open": [2], "use": "residential"},
	{"name": "large_residential", "w": 13.0, "d": 14.0, "floors": 4, "edge": 2, "open": [2], "use": "residential"},
	{"name": "corner_two_facade", "w": 10.0, "d": 9.0, "floors": 3, "edge": 3, "open": [2, 3], "use": "residential"},
	{"name": "party_wall_one_facade", "w": 7.0, "d": 12.0, "floors": 3, "edge": 2, "open": [2], "use": "residential"},
	{"name": "retail_shopfront", "w": 11.0, "d": 12.0, "floors": 3, "edge": 2, "open": [2], "use": "retail"},
	{"name": "tavern_front", "w": 10.0, "d": 13.0, "floors": 3, "edge": 2, "open": [2], "use": "tavern"},
	{"name": "office_block", "w": 12.0, "d": 10.0, "floors": 4, "edge": 2, "open": [2], "use": "office"},
	{"name": "workshop_yard", "w": 12.0, "d": 12.0, "floors": 2, "edge": 2, "open": [2], "use": "workshop"},
	{"name": "warehouse", "w": 13.0, "d": 14.0, "floors": 2, "edge": 2, "open": [2], "use": "storage"},
	{"name": "hospital_ward", "w": 13.0, "d": 13.0, "floors": 3, "edge": 2, "open": [2], "use": "hospital"},
	{"name": "police_station", "w": 10.0, "d": 11.0, "floors": 3, "edge": 2, "open": [2], "use": "police"},
	{"name": "government_house", "w": 12.0, "d": 12.0, "floors": 3, "edge": 2, "open": [2], "use": "government"},
	{"name": "caretaker_flat", "w": 8.0, "d": 9.0, "floors": 3, "edge": 2, "open": [2], "use": "caretaker"},
	{"name": "awkward_odd_shape", "w": 5.9, "d": 8.7, "floors": 2, "edge": 3, "open": [2, 3], "use": "residential"},
	{"name": "small_below_threshold", "w": 5.2, "d": 6.6, "floors": 2, "edge": 2, "open": [2], "use": "residential"},
	{"name": "compound_historic", "w": 13.0, "d": 14.0, "floors": 3, "edge": 2, "open": [2], "use": "residential", "compound": true},
]

var plans: Array = []
var failures := 0
var stat := {
	"plans": 0, "floors": 0, "archetypes": {}, "errors": {},
	"rooms": 0, "circ_rooms": 0, "circ_area": 0.0, "room_area": 0.0,
	"slivers": 0, "overlaps": 0, "doors": 0, "sealed": 0, "rejects": {},
	"facade_principal": 0, "principal": 0, "kinds": {}, "legacy_floors": 0,
	# Archetype floors only: the new planner's own quality, measured apart from
	# the legacy floors it is replacing, so "looks better" is a number.
	"a_rooms": 0, "a_principal": 0, "a_facade_principal": 0, "a_slivers": 0,
	"a_overlaps": 0, "a_circ_area": 0.0, "a_room_area": 0.0, "a_doors": 0,
	"a_sealed": 0, "a_kinds": {}, "a_bedroom_doors": 0, "a_bedrooms": 0,
}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var seeds := DEFAULT_SEEDS
	for i in args.size():
		if args[i] == "--fp-seeds" and i + 1 < args.size():
			seeds = maxi(1, int(args[i + 1]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for spec_row: Dictionary in ZOO:
		var spread: Dictionary = {}
		var legacy := 0
		for s in seeds:
			var spec := _spec_for(spec_row, s)
			var man: Dictionary = InteriorPlan.build_for_building(spec)
			var floors: Array = man.get("floors", [])
			stat["plans"] = int(stat["plans"]) + 1
			var errs := InteriorPlan.validate(man)
			if errs.is_empty():
				spread[_floor_arch(floors, 0)] = int(spread.get(_floor_arch(floors, 0), 0)) + 1
			for e: String in errs:
				var key := e.split(" ")[0]
				stat["errors"][key] = int(stat["errors"].get(key, 0)) + 1
			if not errs.is_empty():
				failures += 1
				print("FAIL %s seed=%d : %s" % [spec_row["name"], s, ", ".join(errs).substr(0, 220)])
			for fi in floors.size():
				var fl: Dictionary = floors[fi]
				stat["floors"] = int(stat["floors"]) + 1
				var arch := _floor_arch(floors, fi)
				stat["archetypes"][arch] = int(stat["archetypes"].get(arch, 0)) + 1
				if arch == "legacy":
					legacy += 1
					stat["legacy_floors"] = int(stat["legacy_floors"]) + 1
					var why := FloorPlanPlanner.last_reject
					# One line per DISTINCT reject reason, printed in full: the
					# summary histogram is a dict, so reasons that contain commas
					# (i.e. any reason carrying a cell dump) are unreadable there.
					if not stat["rejects"].has(why):
						print("REJECT-FIRST %s :: %s" % [spec_row["name"], why])
					stat["rejects"][why] = int(stat["rejects"].get(why, 0)) + 1
				_measure(fl, arch != "legacy")
			plans.append({"footprint": spec_row["name"], "seed": s, "spec": _spec_json(spec), "floors": _floors_json(floors), "errors": errs})
		print("%-26s archetypes=%s legacy_floors=%d/%d" % [spec_row["name"], spread, legacy, seeds * int(spec_row["floors"])])
	_report()
	get_tree().quit(0 if failures == 0 else 1)


func _spec_for(row: Dictionary, seed_i: int) -> Dictionary:
	var jitter := float((seed_i * 37) % 13) * 0.05
	var w: float = float(row["w"]) + jitter
	var d: float = float(row["d"]) - jitter
	var spec := {
		"id": "fp_%s_%d" % [row["name"], seed_i],
		"rect": Rect2(500.0 + float(seed_i), 700.0, w, d),
		"floors": int(row["floors"]),
		"floor_h": 3.1,
		"door_edge": int(row["edge"]),
		"open_faces": row["open"],
		"use": row["use"],
		"yaw": 0.0,
		"seed_used": 4242 + seed_i * 977,
	}
	if bool(row.get("compound", false)):
		spec["compound_id"] = "c%d" % seed_i
	return spec


func _floor_arch(floors: Array, fi: int) -> String:
	if fi >= floors.size():
		return "?"
	var fl: Dictionary = floors[fi]
	return str(fl.get("archetype", "legacy"))


func _measure(fl: Dictionary, is_arch := false) -> void:
	var rooms: Array = fl.get("rooms", [])
	var kinds := {}
	var total := 0.0
	var circ := 0.0
	for r: Dictionary in rooms:
		var rc: Rect2 = r.get("rect", Rect2())
		var area := rc.size.x * rc.size.y
		total += area
		var kind := String(r.get("kind", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		stat["kinds"][kind] = int(stat["kinds"].get(kind, 0)) + 1
		stat["rooms"] = int(stat["rooms"]) + 1
		if minf(rc.size.x, rc.size.y) < 1.0:
			stat["slivers"] = int(stat["slivers"]) + 1
			if is_arch:
				stat["a_slivers"] = int(stat["a_slivers"]) + 1
		var circ_room := bool(r.get("circulation", false))
		if circ_room:
			circ += area
			stat["circ_rooms"] = int(stat["circ_rooms"]) + 1
		var tier := _tier(kind)
		if tier <= 1:
			stat["principal"] = int(stat["principal"]) + 1
			if not (r.get("facade_edges", []) as Array).is_empty():
				stat["facade_principal"] = int(stat["facade_principal"]) + 1
			if is_arch:
				stat["a_principal"] = int(stat["a_principal"]) + 1
				if not (r.get("facade_edges", []) as Array).is_empty():
					stat["a_facade_principal"] = int(stat["a_facade_principal"]) + 1
		if is_arch:
			stat["a_rooms"] = int(stat["a_rooms"]) + 1
			stat["a_kinds"][kind] = int(stat["a_kinds"].get(kind, 0)) + 1
	stat["room_area"] = float(stat["room_area"]) + total
	stat["circ_area"] = float(stat["circ_area"]) + circ
	if is_arch:
		stat["a_room_area"] = float(stat["a_room_area"]) + total
		stat["a_circ_area"] = float(stat["a_circ_area"]) + circ
		stat["a_doors"] = int(stat["a_doors"]) + (fl.get("partitions", []) as Array).size()
		stat["a_sealed"] = int(stat["a_sealed"]) + (fl.get("solid_walls", []) as Array).size()
		# A bedroom with more than one door is being used as a corridor: the
		# privacy rule from the design doc, measured instead of assumed.
		var touched := {}
		for p: Dictionary in fl.get("partitions", []):
			var ka := str(p.get("a", ""))
			var kb := str(p.get("b", ""))
			touched[ka] = int(touched.get(ka, 0)) + 1
			touched[kb] = int(touched.get(kb, 0)) + 1
		for r: Dictionary in rooms:
			if String(r.get("kind", "")) != "sleeping":
				continue
			stat["a_bedrooms"] = int(stat["a_bedrooms"]) + 1
			if int(touched.get(str(r.get("id", "")), 0)) > 1:
				stat["a_bedroom_doors"] = int(stat["a_bedroom_doors"]) + 1
	for p: Dictionary in fl.get("partitions", []):
		stat["doors"] = int(stat["doors"]) + 1
	for s in fl.get("solid_walls", []):
		stat["sealed"] = int(stat["sealed"]) + 1
	# overlap audit independent of InteriorPlan.validate
	for i in rooms.size():
		var ra: Rect2 = rooms[i].get("rect")
		for j in range(i + 1, rooms.size()):
			var rb: Rect2 = rooms[j].get("rect")
			var inter := ra.intersection(rb)
			if inter.size.x > 0.05 and inter.size.y > 0.05:
				stat["overlaps"] = int(stat["overlaps"]) + 1
				if is_arch:
					stat["a_overlaps"] = int(stat["a_overlaps"]) + 1


## Room tiers: 0 = the room a building type is named for, 1 = other principal
## rooms, 9 = circulation and service.
func _tier(kind: String) -> int:
	if kind in ["living", "sales", "taproom", "ward", "council", "machine_shop", "warehouse"]:
		return 0
	elif kind in ["sleeping", "kitchen", "office", "reception", "meeting", "workshop", "craft", "surgery"]:
		return 1
	return 9


func _report() -> void:
	var rooms := maxi(1, int(stat["rooms"]))
	var principal := maxi(1, int(stat["principal"]))
	print("--- floor-plan metrics ---")
	print("buildings=%d floors=%d rooms=%d doors=%d sealed_walls=%d" % [int(stat["plans"]), int(stat["floors"]), int(stat["rooms"]), int(stat["doors"]), int(stat["sealed"])])
	print("legacy_floors=%d archetype_distribution=%s" % [int(stat["legacy_floors"]), stat["archetypes"]])
	print("circ_share=%.3f circulation_rooms=%d slivers=%d overlaps=%d" % [float(stat["circ_area"]) / maxf(0.001, float(stat["room_area"])), int(stat["circ_rooms"]), int(stat["slivers"]), int(stat["overlaps"])])
	print("principal_with_facade=%.3f (%d/%d) kinds=%s" % [float(stat["facade_principal"]) / float(principal), int(stat["facade_principal"]), int(stat["principal"]), stat["kinds"]])
	print("validate_error_classes=%s" % stat["errors"])
	print("planner_rejections=%s" % stat["rejects"])
	print("ARCHETYPE_ONLY rooms=%d doors=%d sealed=%d slivers=%d overlaps=%d circ_share=%.3f facade_principal=%.3f (%d/%d) bedroom_as_corridor=%d/%d kinds=%s" % [
		int(stat["a_rooms"]), int(stat["a_doors"]), int(stat["a_sealed"]), int(stat["a_slivers"]),
		int(stat["a_overlaps"]), float(stat["a_circ_area"]) / maxf(0.001, float(stat["a_room_area"])),
		float(stat["a_facade_principal"]) / float(maxi(1, int(stat["a_principal"]))),
		int(stat["a_facade_principal"]), int(stat["a_principal"]),
		int(stat["a_bedroom_doors"]), int(stat["a_bedrooms"]), stat["a_kinds"]])
	var f := FileAccess.open(OUT_DIR + "/plans.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"stats": stat, "plans": plans}))
		f.close()
		print("wrote %s/plans.json (%d plans)" % [OUT_DIR, plans.size()])
	print("floorplan probe finished with %d failure(s)" % failures)


func _spec_json(spec: Dictionary) -> Dictionary:
	var rect: Rect2 = spec["rect"]
	return {"id": spec["id"], "w": rect.size.x, "d": rect.size.y, "floors": spec["floors"],
		"door_edge": spec["door_edge"], "open_faces": spec["open_faces"], "use": spec["use"]}


func _floors_json(floors: Array) -> Array:
	var out: Array = []
	for fl: Dictionary in floors:
		var rooms: Array = []
		for r: Dictionary in fl.get("rooms", []):
			var rj := _rect_json(r.get("rect", Rect2()))
			rj["id"] = str(r.get("id", ""))
			rj["kind"] = String(r.get("kind", ""))
			rj["service"] = bool(r.get("service", false))
			rj["circ"] = bool(r.get("circulation", false))
			rj["facade"] = r.get("facade_edges", [])
			rj["entry"] = bool(r.get("entry", false))
			rooms.append(rj)
		var parts: Array = []
		for p: Dictionary in fl.get("partitions", []):
			parts.append({"id": str(p.get("id", "")), "a": str(p.get("a", "")), "b": str(p.get("b", "")),
				"wall": _rect_array(p.get("rect", Rect2())), "opening": _rect_array(p.get("opening", Rect2()))})
		var solids: Array = []
		for s in fl.get("solid_walls", []):
			solids.append(_rect_array(s))
		out.append({"floor_i": int(fl.get("floor_i", 0)), "archetype": str(fl.get("archetype", "legacy")),
			"topology": str(fl.get("topology", "")), "rooms": rooms, "partitions": parts, "solid_walls": solids,
			"core_rect": _rect_array(fl.get("core_rect", Rect2())), "mirrored": bool(fl.get("mirrored", false))})
	return out


func _rect_json(r: Rect2) -> Dictionary:
	return {"x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y}


func _rect_array(r: Rect2) -> Array:
	return [r.position.x, r.position.y, r.size.x, r.size.y]
