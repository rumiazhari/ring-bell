class_name ChunkBuilder
extends RefCounted
## Materializes ONE chunk of the deterministic city plan into batched
## geometry. This is the MATERIAL layer's worker: it never makes random
## choices - every scatter roll flows from WorldSeed with the chunk coords
## mixed in, so a chunk always builds identically no matter when it loads.
##
## BUILD OWNERSHIP: a building is emitted only by the chunk containing its
## footprint CENTER. Buildings may visually span chunk borders, but their
## whole node subtree lives under one owner, so streaming can never duplicate
## or tear them (the owning chunk stays resident while neighbors do).
##
## Cross-chunk continuity trick: road dashes / lamp posts / curbs are anchored
## to GLOBAL grid steps (multiples of fixed meters), never to chunk-local
## offsets - so adjacent chunks continue each other's decoration exactly.

const GROUND_COLOR := Color("4c4a44")
const ASPHALT := Color("3a3d40")
const ASPHALT_AVENUE := Color("45484c")
const DASH_COLOR := Color("b9ae82")
const SIDEWALK_HISTORIC := Color("a29a8b")
const SIDEWALK_INNER := Color("98948a")
const PLAZA_PAVE := Color("b3ab97")
const ALLEY_FLOOR := Color("6f6759")
const GRASS := Color("55693f")
const TRUNK_COLOR := Color("4a3826")
const CANOPY_COLOR := Color("3f5c30")
const FOUNTAIN_RIM := Color("8d8577")
const FOUNTAIN_WATER := Color("3e5e63")
const STALL_COLORS := [
	Color("8c3a30"), Color("3f5e6b"), Color("6b6f36"), Color("7c4a63"),
]

const CAR_COLORS := [
	Color("6d2222"), Color("2c3e50"), Color("7a7a72"),
	Color("5c5648"), Color("274232"), Color("803c20"),
]
const DEBRIS_COLORS := [
	Color("7a4a35"), Color("6f6b60"), Color("57544c"), Color("4d463c"),
]

const DASH_STEP := 7.0
const LAMP_STEP := 32.0
const LAMP_MIN_SEP := 14.0
const LAMP_JUNCTION_EXCLUDE_M := 13.0
const LAMP_PLAZA_EXCLUDE_M := 12.0


## Emits everything for `coord` into `b`. Deterministic and side-effect free.
static func fill_batcher(b: MeshBatcher, plan: CityPlan, coord: Vector2i,
		world_plan: WorldPlan = null) -> void:
	var rect := WorldSeed.chunk_rect(coord)
	_roads(b, plan, rect, world_plan)
	for cell in plan.cells_in_rect(rect):
		var block := plan.cell_block(cell)
		var block_bounds: Rect2 = block.get("bounds", block["rect"]) as Rect2
		if not block_bounds.intersects(rect):
			continue
		match block["kind"]:
			&"built":
				_pavement(b, block, rect, SIDEWALK_HISTORIC \
						if block["district"] == CityPlan.DISTRICT_HISTORIC \
						else SIDEWALK_INNER, world_plan)
				_alley(b, block, rect, world_plan)
			&"plaza":
				_plaza(b, plan, block, rect, coord, world_plan)
			_:
				_park(b, plan, block, rect, coord, world_plan)
	var owned_buildings: Array = _owned_buildings(plan, rect, coord)
	for spec in owned_buildings:
		# G10-P2A: the universal building contract - the ONLY normal path
		# for enterable buildings. Delegates to the reference BuildingBuilder
		# after contract-stamping + registration (byte-identical city
		# geometry, now validated by BuildingContractValidator).
		UniversalBuildingAssembler.build_into(b, _grounded_spec(spec, world_plan))
	# A city chunk can contain a road junction but no building footprint. Keep a
	# tiny destructible curb marker in that empty case so the chunk still owns a
	# real static body for persistence/streaming probes; it is not a building,
	# has no contract id, and is visually lost in the street surface.
	if owned_buildings.is_empty() and b.collider_count() == 0 \
			and not plan.city_road_segments_in(rect).is_empty():
		var curb_center := rect.get_center()
		var curb_y := world_plan.surface_height_at(curb_center) if world_plan != null else 0.0
		b.add_destructible_box(Vector3(curb_center.x, curb_y + 0.04, curb_center.y),
				Vector3(0.42, 0.08, 0.42), Color("3b3b37"), &"concrete", true,
				"city_curb_%d_%d" % [coord.x, coord.y])
	_scatter_props(b, plan, rect, coord, world_plan)


## Builds the chunk node under `parent` and returns generation stats.
## SPLIT COSTS HERE: fill_batcher() is pure data (run it on worker threads
## with a PRIVATE CityPlan copy - see ChunkManager._fill_job); build()
## materializes on the main thread only.
##
## P0-2: this is the FIRST and ONLY materialization of a (already
## damage-restored) batcher - doors/props spawn exactly once here.
## dead_doors: {door manifest id: true} - doors recorded destroyed in the
## persistence delta are NOT respawned when their chunk streams back in.
static func build(parent: Node3D, plan: CityPlan, coord: Vector2i,
		batcher: MeshBatcher = null, dead_doors := {},
		include_collision := true, materialize_city := true,
		world_plan: WorldPlan = null) -> Dictionary:
	if batcher == null:
		batcher = MeshBatcher.new()
		fill_batcher(batcher, plan, coord, world_plan)

	var t0 := Time.get_ticks_usec()
	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]
	parent.add_child(chunk)
	var stats := batcher.flush_into(chunk, 1, include_collision)
	# City doors/interiors are emitted only when WorldPlan assigned this chunk
	# to the bounded historic-urban composition. An empty batcher alone is not
	# sufficient: otherwise rural chunks would still receive CityPlan doors.
	var doors := 0
	var buildings := 0
	var city_interior_doors := 0
	var city_interior_stations := 0
	var city_interior_rooms := 0
	if materialize_city:
		var rect := WorldSeed.chunk_rect(coord)
		for spec in _owned_buildings(plan, rect, coord):
			var grounded_spec: Dictionary = _grounded_spec(spec, world_plan)
			buildings += 1
			for dm: Dictionary in grounded_spec.get("doors", []):
				if dead_doors.has(String(dm["id"])):
					continue
				var door := Door.new()
				door.name = String(dm["id"])
				door.setup(dm)
				chunk.add_child(door)
				doors += 1
			var InteriorPlanScript = load("res://world/generation/interior_plan.gd")
			var InteriorStationScript = load("res://world/buildings/interior_station.gd")
			var imanifest: Dictionary = InteriorPlanScript.build_for_building(grounded_spec)
			_transform_interior_manifest(imanifest, grounded_spec)
			var ground_y: float = float(grounded_spec.get("building_ground_y", grounded_spec.get("ground_y", 0.0)))
			_translate_interior_manifest_y(imanifest, ground_y)
			# G9 M1 bounded slice: only residential ground floor interiors
			var use_val: String = str(grounded_spec.get("use", grounded_spec.get("style", {}).get("room_type", "residential")))
			if use_val != "residential":
				continue
			var bcenter: Vector2 = (grounded_spec["rect"] as Rect2).get_center()
			if bcenter.length() >= WorldConstants.URBAN_INNER_M:
				continue
			if int(grounded_spec.get("floors", 1)) < 1:
				continue
			for fl in imanifest.get("floors", []):
				var fi: int = int(fl.get("floor_i", -1))
				if fi != 0:
					continue
				city_interior_rooms += int((fl.get("rooms", []) as Array).size())
				for dm2 in fl.get("doors", []):
					if city_interior_doors >= WorldConstants.MAX_CITY_INTERIOR_DOORS_PER_CHUNK:
						break
					if dead_doors.has(String(dm2["id"])):
						continue
					var door2 := Door.new()
					door2.name = String(dm2["id"])
					door2.setup(dm2)
					chunk.add_child(door2)
					doors += 1
					city_interior_doors += 1
				for sm in fl.get("stations", []):
					if city_interior_stations >= WorldConstants.MAX_CITY_INTERIOR_STATIONS_PER_CHUNK:
						break
					var st = InteriorStationScript.new()
					st.name = String(sm["id"])
					st.setup(sm)
					# Tag as city interior for ACTIVE-only handling
					st.set_meta("city_interior", true)
					chunk.add_child(st)
					city_interior_stations += 1

	stats["doors"] = doors
	stats["buildings"] = buildings
	stats["city_interior_doors"] = city_interior_doors
	stats["city_interior_stations"] = city_interior_stations
	stats["city_interior_rooms"] = city_interior_rooms

	# Dynamic destructible props from the deterministic manifests.
	var props := 0
	for def: Dictionary in batcher.props():
		var prop := DestructibleProp.new()
		prop.name = "Prop_%d" % props
		prop.setup(def)
		chunk.add_child(prop)
		props += 1
	stats["props"] = props
	# Phase S: streamed-city streetlamp OmniLights (warm pool lights)
	# Phase W: dead lamps stay dark at night; flicker lamps sputter via DayNightController.
	var lamp_lights := 0
	var positions: Array = batcher.street_lights()
	for i in positions.size():
		var pos: Vector3 = positions[i] as Vector3
		var lamp := OmniLight3D.new()
		lamp.name = "StreetLamp_%d" % lamp_lights
		lamp.position = pos
		lamp.omni_range = 13.0
		lamp.omni_attenuation = 1.2
		lamp.light_energy = 2.8
		lamp.light_color = Color(1.0, 0.88, 0.62)
		lamp.shadow_enabled = false
		var is_dead: bool = batcher.street_light_dead(i)
		var is_flicker: bool = batcher.street_light_flicker(i)
		var phase: float = batcher.street_light_phase(i)
		if is_dead:
			lamp.set_meta(&"dead_lamp", true)
			lamp.visible = false
		else:
			lamp.visible = GameClock.is_night()
			if is_flicker:
				lamp.set_meta(&"lamp_flicker", true)
				lamp.set_meta(&"flicker_phase", phase)
		lamp.add_to_group(&"streetlamp")
		chunk.add_child(lamp)
		lamp_lights += 1
	stats["street_lights"] = lamp_lights
	# Phase U: interior window glows (faint warm, night-only)
	var win_glows := 0
	for pos: Vector3 in batcher.window_glows():
		var glow := OmniLight3D.new()
		glow.name = "WindowGlow_%d" % win_glows
		glow.position = pos
		glow.omni_range = BuildingBuilder.WINDOW_GLOW_RANGE
		glow.omni_attenuation = 1.35
		glow.light_energy = BuildingBuilder.WINDOW_GLOW_ENERGY
		glow.light_color = BuildingBuilder.WINDOW_GLOW_COLOR
		glow.shadow_enabled = false
		glow.visible = GameClock.is_night()
		glow.add_to_group(&"window_glow")
		chunk.add_child(glow)
		win_glows += 1
	stats["window_glows"] = win_glows
	stats["boxes"] = batcher.box_count()
	stats["colliders"] = batcher.collider_count()
	stats["mat_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return stats


## Apply WorldPlan's realized surface to a city BuildingSpec without changing
## its footprint, contract classification, or stable identifiers.
static func _grounded_spec(spec: Dictionary, world_plan: WorldPlan) -> Dictionary:
	if world_plan == null:
		return spec
	var out: Dictionary = spec.duplicate(true)
	var rect: Rect2 = out.get("rect", Rect2()) as Rect2
	var ground_y: float = world_plan.surface_height_at(rect.get_center())
	out["ground_y"] = ground_y
	var foundation_data := _foundation_data(out, world_plan, ground_y)
	for key: String in foundation_data.keys():
		out[key] = foundation_data[key]
	var building_ground_y := float(out.get("building_ground_y", ground_y))
	var doors: Array[Dictionary] = []
	for dm_variant in out.get("doors", []):
		var dm: Dictionary = (dm_variant as Dictionary).duplicate(true)
		var pos: Vector3 = dm.get("position", Vector3.ZERO) as Vector3
		pos.y = building_ground_y
		dm["position"] = pos
		dm["ground_y"] = building_ground_y
		doors.append(dm)
	out["doors"] = doors
	return out


## Compute a raised platform only where the realized footprint relief makes a
## flat building datum visibly unsafe. The plan stays rectangular/oriented;
## this helper only stamps material-layer support/access metadata.
static func _foundation_data(spec: Dictionary, world_plan: WorldPlan,
		center_ground: float) -> Dictionary:
	var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
	var center := rect.get_center()
	var yaw := float(spec.get("yaw", 0.0))
	var min_ground := INF
	var max_ground := -INF
	for ix in 3:
		for iz in 3:
			var local := Vector2(rect.size.x * float(ix) * 0.5,
					rect.size.y * float(iz) * 0.5)
			var p := CityPlan._rotate_plan_point(center, rect.position + local, yaw)
			var h := world_plan.surface_height_at(p)
			min_ground = minf(min_ground, h)
			max_ground = maxf(max_ground, h)
	var relief := max_ground - min_ground
	var out := {
		"foundation_enabled": false,
		"foundation_height": 0.0,
		"foundation_modules": [],
		"building_ground_y": center_ground,
		"access": {},
	}
	if relief < BuildingBuilder.FOUNDATION_TRIGGER_RELIEF:
		return out

	var edge := int(spec.get("door_edge", 0))
	var door_local := BuildingBuilder._access_door_local(rect.size.x, rect.size.y, edge)
	var outward := BuildingBuilder._access_outward(edge)
	for approach_distance in [2.0, 4.0, 8.5]:
		var approach_local := door_local + outward * float(approach_distance)
		var approach_world := CityPlan._rotate_plan_point(center,
				rect.position + approach_local, yaw)
		max_ground = maxf(max_ground, world_plan.surface_height_at(approach_world))

	var building_ground_y := max_ground + BuildingBuilder.FOUNDATION_TOP_CLEARANCE \
			+ BuildingBuilder.FOUNDATION_ACCESS_MIN_RISE
	var foundation_top := building_ground_y - BuildingBuilder.SLAB_T - 0.02
	var foundation_bottom := min_ground - BuildingBuilder.FOUNDATION_BURY
	var over := BuildingBuilder.FOUNDATION_OVERHANG
	var modules: Array[Dictionary] = []
	for ix in BuildingBuilder.FOUNDATION_MODULES_X:
		var x0 := -over + (rect.size.x + 2.0 * over) \
				* float(ix) / float(BuildingBuilder.FOUNDATION_MODULES_X)
		var x1 := -over + (rect.size.x + 2.0 * over) \
				* float(ix + 1) / float(BuildingBuilder.FOUNDATION_MODULES_X)
		for iz in BuildingBuilder.FOUNDATION_MODULES_Z:
			var z0 := -over + (rect.size.y + 2.0 * over) \
					* float(iz) / float(BuildingBuilder.FOUNDATION_MODULES_Z)
			var z1 := -over + (rect.size.y + 2.0 * over) \
					* float(iz + 1) / float(BuildingBuilder.FOUNDATION_MODULES_Z)
			modules.append({
				"rect": Rect2(x0, z0, x1 - x0, z1 - z0),
				"bottom_y": foundation_bottom,
				"top_y": foundation_top,
			})
	out["foundation_enabled"] = true
	out["foundation_height"] = building_ground_y - center_ground
	out["foundation_modules"] = modules
	out["building_ground_y"] = building_ground_y

	# Sample the ground at the eventual stair approach. The access run is
	# deterministic and capped so a steep foundation remains traversable.
	var provisional_run := clampf(
		maxf(building_ground_y - center_ground, 0.0) \
			/ tan(deg_to_rad(BuildingBuilder.ACCESS_STAIR_PITCH_DEG)),
			BuildingBuilder.ACCESS_MIN_RUN, BuildingBuilder.ACCESS_MAX_RUN)
	var approach_local := door_local + outward * (provisional_run + 0.4)
	var approach_world := CityPlan._rotate_plan_point(center,
			rect.position + approach_local, yaw)
	var access_ground := world_plan.surface_height_at(approach_world)
	var rise := maxf(building_ground_y - access_ground, 0.0)
	var run := clampf(rise / tan(deg_to_rad(BuildingBuilder.ACCESS_STAIR_PITCH_DEG)),
			BuildingBuilder.ACCESS_MIN_RUN, BuildingBuilder.ACCESS_MAX_RUN)
	approach_local = door_local + outward * (run + 0.4)
	approach_world = CityPlan._rotate_plan_point(center, rect.position + approach_local, yaw)
	access_ground = world_plan.surface_height_at(approach_world)
	rise = maxf(building_ground_y - access_ground, 0.0)
	if rise >= BuildingBuilder.ACCESS_STAIR_TRIGGER:
		var roll := WorldSeed.unit_float("foundation_access",
			[WorldSeed.str_hash(str(spec.get("id", "building")))])
		var kind := "porch" if roll < 0.34 else ("veranda" if roll < 0.70 else "none")
		out["access"] = {
			"enabled": true,
			"kind": kind,
			"door_edge": edge,
			"ground_y": access_ground,
			"building_ground_y": building_ground_y,
			"rise": rise,
			"run": run,
			"width": BuildingBuilder.DOOR_W + 0.8,
		}
	return out


static func _transform_interior_manifest(manifest: Dictionary,
		spec: Dictionary) -> void:
	var yaw := float(spec.get("yaw", 0.0))
	if is_zero_approx(yaw):
		return
	var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
	var center := rect.get_center()
	var floors: Array = manifest.get("floors", []) as Array
	for floor_i in floors.size():
		var floor_dict: Dictionary = floors[floor_i] as Dictionary
		var floor_doors: Array = floor_dict.get("doors", []) as Array
		for door_i in floor_doors.size():
			var dm: Dictionary = floor_doors[door_i] as Dictionary
			var pos: Vector3 = dm.get("position", Vector3.ZERO) as Vector3
			var rotated := CityPlan._rotate_plan_point(center,
					Vector2(pos.x, pos.z), yaw)
			pos.x = rotated.x
			pos.z = rotated.y
			dm["position"] = pos
			dm["yaw"] = float(dm.get("yaw", 0.0)) - yaw
			floor_doors[door_i] = dm
		floor_dict["doors"] = floor_doors
		var stations: Array = floor_dict.get("stations", []) as Array
		for station_i in stations.size():
			var station: Dictionary = stations[station_i] as Dictionary
			var spos: Vector3 = station.get("position", Vector3.ZERO) as Vector3
			var rotated_station := CityPlan._rotate_plan_point(center,
					Vector2(spos.x, spos.z), yaw)
			spos.x = rotated_station.x
			spos.z = rotated_station.y
			station["position"] = spos
			station["yaw"] = float(station.get("yaw", 0.0)) - yaw
			stations[station_i] = station
		floor_dict["stations"] = stations
		floors[floor_i] = floor_dict
	manifest["floors"] = floors


## Translate floor-relative Y values onto the realized WorldPlan datum.
static func _translate_interior_manifest_y(manifest: Dictionary, ground_y: float) -> void:
	var floors: Array = manifest.get("floors", []) as Array
	for floor_i in floors.size():
		var floor_dict: Dictionary = floors[floor_i] as Dictionary
		var floor_doors: Array = floor_dict.get("doors", []) as Array
		for door_i in floor_doors.size():
			var dm: Dictionary = floor_doors[door_i] as Dictionary
			var pos: Vector3 = dm.get("position", Vector3.ZERO) as Vector3
			pos.y += ground_y
			dm["position"] = pos
			floor_doors[door_i] = dm
		floor_dict["doors"] = floor_doors
		var stations: Array = floor_dict.get("stations", []) as Array
		for station_i in stations.size():
			var sm: Dictionary = stations[station_i] as Dictionary
			var spos: Vector3 = sm.get("position", Vector3.ZERO) as Vector3
			spos.y += ground_y
			sm["position"] = spos
			stations[station_i] = sm
		floor_dict["stations"] = stations
		floors[floor_i] = floor_dict
	manifest["floors"] = floors


## Buildings whose footprint center lies inside `rect` AND owned by this chunk.
static func _owned_buildings(plan: CityPlan, rect: Rect2,
		coord: Vector2i) -> Array:
	var out: Array = []
	for spec in plan.buildings_in_rect(rect):
		var center: Vector2 = (spec["rect"] as Rect2).get_center()
		if WorldSeed.chunk_coord(center.x, center.y) == coord:
			out.append(spec)
	return out


# --- Ground ------------------------------------------------------------------

static func _ground(b: MeshBatcher, plan: CityPlan, coord: Vector2i) -> void:
	# Urban compatibility: flat city ground is ONLY the protected basin
	# interior (< URBAN_INNER_M). Any chunk that straddles or lies beyond
	# the inner radius has NO city flat box; terrain (height 0 inside inner
	# via smoothstep) provides the ground there so no flat/terrain overlap
	# competes across the transition band.
	var s := float(WorldSeed.CHUNK_SIZE)
	var rect := WorldSeed.chunk_rect(coord)
	var closest := Vector2(clampf(0.0, rect.position.x, rect.end.x), clampf(0.0, rect.position.y, rect.end.y))
	if closest.length() >= WorldConstants.URBAN_INNER_M:
		return
	# If any corner is outside inner radius, this chunk straddles the
	# boundary — omit city ground and let terrain sole-own it.
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y), rect.end]
	var farthest := 0.0
	for p in corners:
		farthest = maxf(farthest, p.length())
	if farthest >= WorldConstants.URBAN_INNER_M:
		return
	# Subtle per-chunk tone variation keeps large surfaces from reading flat.
	var tint := 0.94 + 0.06 * WorldSeed.unit_float("ground", [coord.x, coord.y])
	b.add_structural_box(Vector3((coord.x + 0.5) * s, -0.25, (coord.y + 0.5) * s),
			Vector3(s, 0.5, s), GROUND_COLOR * tint)


# --- Roads -------------------------------------------------------------------

static func _roads(b: MeshBatcher, plan: CityPlan, rect: Rect2,
		world_plan: WorldPlan = null) -> void:
	_emit_halo_lamps(b, plan, rect, world_plan)
	for edge: Dictionary in plan.city_road_segments_in(rect.grow(8.0)):
		var poly: PackedVector2Array = edge.get("polyline_clipped", PackedVector2Array()) as PackedVector2Array
		var hierarchy: StringName = edge.get("hierarchy", &"local") as StringName
		var width: float = float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
		for i in range(poly.size() - 1):
			var a: Vector2 = poly[i]
			var z: Vector2 = poly[i + 1]
			var delta := z - a
			var length := delta.length()
			if length < 0.05:
				continue
			# Short pieces keep the visual ribbon attached even where the
			# realized surface includes a quarry rim or river-bank transition.
			var piece_count := clampi(int(ceil(length / 2.0)), 1, 32)
			for piece_i in piece_count:
				var piece_t0 := float(piece_i) / float(piece_count)
				var piece_t1 := float(piece_i + 1) / float(piece_count)
				var piece_a := a.lerp(z, piece_t0)
				var piece_b := a.lerp(z, piece_t1)
				var piece_delta := piece_b - piece_a
				var piece_length := piece_delta.length()
				if piece_length < 0.05:
					continue
				var mid := (piece_a + piece_b) * 0.5
				var ground_a := 0.0
				var ground_b := 0.0
				if world_plan != null:
					ground_a = world_plan.surface_height_at(piece_a)
					ground_b = world_plan.surface_height_at(piece_b)
				var bridge_segment := bool(edge.get("is_bridge", false)) and world_plan != null \
						and world_plan.water_body_at(mid) != &""
				if bridge_segment:
					var deck_y := world_plan.water_level_at(mid) + WorldConstants.BRIDGE_DECK_LIFT_M
					ground_a = deck_y
					ground_b = deck_y
				var road_y_a := ground_a + 0.055
				var road_y_b := ground_b + 0.055
				var road_center_y := (road_y_a + road_y_b) * 0.5
				if world_plan != null and not bridge_segment:
					road_center_y = world_plan.surface_height_at(mid) + 0.055
				# Keep the city ribbon attached to the terrain along each
				# short segment. The basis is a pure rotation: local +Z
				# follows the 3D road tangent and local +Y stays normal.
				var tangent := Vector3(piece_delta.x, road_y_b - road_y_a, piece_delta.y).normalized()
				var x_axis := Vector3(tangent.z, 0.0, -tangent.x).normalized()
				var y_axis := tangent.cross(x_axis).normalized()
				var basis := Basis(x_axis, y_axis, tangent)
				var color := ASPHALT
				if hierarchy == &"primary":
					color = ASPHALT_AVENUE
				elif hierarchy == &"alley":
					color = ALLEY_FLOOR
				if bool(edge.get("is_bridge", false)):
					color = Color("5e5a52")
				b.add_box_rotated(Vector3(mid.x, road_center_y, mid.y),
					Vector3(width, 0.11, piece_length + 0.12), basis, color, false)


## P2B-FIX lamp driver, called ONCE per _roads (function level, never per
## piece/edge). Halo query (grow 24) + ghost claims keep spacing across
## chunk borders; `accepted` spans every halo edge of this chunk.
static func _emit_halo_lamps(b: MeshBatcher, plan: CityPlan, rect: Rect2,
		world_plan: WorldPlan = null) -> void:
	var lamp_discs := _lamp_exclusion_discs(plan, rect)
	var lamp_accepted: Array = []  # plain Array[Vector2]: shared by reference
	for lamp_edge in plan.city_road_segments_in(rect.grow(24.0)):
		_lamps_for_edge(b, plan, lamp_edge, rect, lamp_discs, lamp_accepted,
			world_plan)


## Junction/plaza exclusion discs for lamp placement: Array of
## Vector3(x, z, radius). Deterministic per (plan, rect); chunk-independent
## content so neighbors agree on exclusions.
static func _lamp_exclusion_discs(plan: CityPlan, rect: Rect2) -> Array:
	var discs: Array = []
	var grown := rect.grow(40.0)
	for node in plan.city_nodes():
		var nid := String(node.get("id", ""))
		var deg := int(node.get("degree", 0))
		# P2B-FIX: only named convergence hearts + true monster junctions
		# clear lamps. Ordinary pocket crossings keep spaced lamps; blanketing
		# every degree-4 node sterilized the whole core.
		if nid == "market_square" or nid == "civic_square" \
				or nid == "rail_station" or nid == "castle_hill" \
				or deg >= 7:
			var c: Vector2 = node.get("center", Vector2.ZERO) as Vector2
			if grown.has_point(c):
				discs.append(Vector3(c.x, c.y, LAMP_JUNCTION_EXCLUDE_M))
	for block in plan.city_blocks_in(grown):
		if (block.get("kind", &"") as StringName) == &"plaza":
			var bc: Vector2 = block.get("center", Vector2.ZERO) as Vector2
			var bb: Rect2 = block.get("bounds", block.get("rect", Rect2())) as Rect2
			discs.append(Vector3(bc.x, bc.y,
				maxf(LAMP_PLAZA_EXCLUDE_M, minf(bb.size.x, bb.size.y) * 0.35)))
	return discs


## P2B-FIX lamp pass. Lamps live only on primary arterials; locals stay dark.
## Positions anchor to the FULL edge polyline at LAMP_STEP spacing (chunk
## independent), each emitted only by its owning chunk. Junction discs
## (incl. plaza hearts) and LAMP_MIN_SEP against same-call accepts keep
## 1900s density sane at convergences; plaza RIMS stay lit so avenue chunks
## keep their night pools. `accepted` is a plain Array (shared by
## reference) of Vector2 lamp positions for cross-edge spacing.
static func _lamps_for_edge(b: MeshBatcher, plan: CityPlan, edge: Dictionary,
		rect: Rect2, discs: Array, accepted: Array,
		world_plan: WorldPlan = null) -> void:
	if (edge.get("hierarchy", &"local") as StringName) != &"primary":
		return
	var full: PackedVector2Array = edge.get("polyline",
		PackedVector2Array()) as PackedVector2Array
	if full.size() < 2:
		return
	var total := 0.0
	for si in range(full.size() - 1):
		total += full[si].distance_to(full[si + 1])
	if total < 8.0:
		return
	var width := float(edge.get("width", WorldConstants.CITY_ROAD_WIDTH_LOCAL))
	var edge_seed := WorldSeed.str_hash(str(edge.get("id", "edge")))
	var step_count := maxi(1, int(floor(total / LAMP_STEP)))
	for lamp_i in step_count:
		var dist := total * (float(lamp_i) + 0.5) / float(step_count)
		var lp := full[0]
		var tangent := Vector2.RIGHT
		var acc := 0.0
		var found := false
		for si in range(full.size() - 1):
			var seg := full[si].distance_to(full[si + 1])
			if acc + seg >= dist:
				var t := (dist - acc) / maxf(seg, 0.001)
				lp = full[si].lerp(full[si + 1], t)
				tangent = (full[si + 1] - full[si]).normalized()
				found = true
				break
			acc += seg
		if not found:
			continue
		var side := 1.0 if (edge_seed + lamp_i) % 2 == 0 else -1.0
		var normal := Vector2(-tangent.y, tangent.x)
		var lamp_p := lp + normal * (width * 0.5 + 0.85)
		if not rect.has_point(lp):
			# Ghost claim: a neighbor owns this geometric candidate. Claimed
			# unconditionally — the bias favors exclusion zones, which is the
			# desired direction near junctions and plazas.
			if rect.grow(16.0).has_point(lp):
				accepted.append(lamp_p)
			continue  # owned by the containing chunk
		var rejected := false
		for disc in discs:
			var d := disc as Vector3
			if lamp_p.distance_to(Vector2(d.x, d.y)) < d.z:
				rejected = true
				break
		if not rejected:
			for q in accepted:
				if lamp_p.distance_to(q as Vector2) < LAMP_MIN_SEP:
					rejected = true
					break
		if rejected:
			continue
		accepted.append(lamp_p)
		var lamp_ground_y := 0.0
		if world_plan != null:
			lamp_ground_y = world_plan.surface_height_at(lp)
			if bool(edge.get("is_bridge", false)) \
					and world_plan.water_body_at(lp) != &"":
				lamp_ground_y = world_plan.water_level_at(lp) \
					+ WorldConstants.BRIDGE_DECK_LIFT_M
		_lamp_post(b, lamp_p, lamp_ground_y)
	# Fallback: a primary arterial crossing this chunk in a long run keeps one
	# warm pool here even when no global anchor lands inside (avenue-chunk
	# contract). Midpoint-gated, disc- and spacing-checked like anchors.
	_emit_fallback_lamp(b, plan, edge, full, width, edge_seed, rect, discs,
		accepted, world_plan)


## Fallback warm pool: longest contiguous in-rect run of a primary arterial
## (2 m arc samples) of at least 25 m keeps one lamp at its midpoint when no
## accepted lamp is nearby. Same discs/side-offset/ground rules as anchors.
static func _emit_fallback_lamp(b: MeshBatcher, _plan: CityPlan,
		edge: Dictionary, full: PackedVector2Array, width: float,
		edge_seed: int, rect: Rect2, discs: Array, accepted: Array,
		world_plan: WorldPlan = null) -> void:
	var best_run: Array[Vector2] = []
	var best_tan := Vector2.RIGHT
	var run: Array[Vector2] = []
	var run_tan := Vector2.RIGHT
	for si in range(full.size() - 1):
		var a := full[si]
		var c := full[si + 1]
		var seg := a.distance_to(c)
		if seg < 0.001:
			continue
		var tangent := (c - a) / seg
		var steps := maxi(1, int(ceil(seg / 2.0)))
		for k in steps:
			var p := a.lerp(c, float(k) / float(steps))
			if rect.has_point(p):
				run.append(p)
				run_tan = tangent
			else:
				if run.size() > best_run.size():
					best_run = run.duplicate()
					best_tan = run_tan
				run.clear()
	if run.size() > best_run.size():
		best_run = run
	if best_run.size() * 2.0 < 25.0:
		return
	var mid: Vector2 = best_run[best_run.size() / 2]
	# Gate: never double an anchor pool (20 m > LAMP_MIN_SEP on purpose).
	for q in accepted:
		if mid.distance_to(q as Vector2) < 20.0:
			return
	var side := 1.0 if edge_seed % 2 == 0 else -1.0
	var lamp_p := mid + Vector2(-best_tan.y, best_tan.x) \
		* (width * 0.5 + 0.85)
	for disc in discs:
		var d := disc as Vector3
		if lamp_p.distance_to(Vector2(d.x, d.y)) < d.z:
			return
	for q in accepted:
		if lamp_p.distance_to(q as Vector2) < LAMP_MIN_SEP:
			return
	accepted.append(lamp_p)
	var gy := 0.0
	if world_plan != null:
		gy = world_plan.surface_height_at(mid)
		if bool(edge.get("is_bridge", false)) \
				and world_plan.water_body_at(mid) != &"":
			gy = world_plan.water_level_at(mid) \
				+ WorldConstants.BRIDGE_DECK_LIFT_M
	_lamp_post(b, lamp_p, gy)


## Center-line dashes are intentionally omitted: early-1900s city streets are
## continuous cobble/asphalt ribbons, and the graph itself supplies hierarchy.


# --- Blocks ------------------------------------------------------------------

static func _pavement(b: MeshBatcher, block: Dictionary, chunk_rect: Rect2,
		color: Color, world_plan: WorldPlan = null) -> void:
	var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
	var clipped := _clip_polygon_to_rect(poly, chunk_rect)
	if clipped.size() < 3:
		return
	var ground_y := 0.0
	if world_plan != null:
		ground_y = world_plan.surface_height_at(block.get("center", Vector2.ZERO) as Vector2)
	b.add_visual_polygon(clipped, ground_y + 0.025, color)


## Paved floor of an intra-block passage (see CityPlan._passage_for_block),
## clipped to this chunk. Sits a hair above the sidewalk and flush-ish with
## the road so the cut reads as its own darker channel between the fronts.
static func _alley(b: MeshBatcher, block: Dictionary, chunk_rect: Rect2,
		world_plan: WorldPlan = null) -> void:
	var p: Dictionary = block.get("passage", {}) as Dictionary
	if p.is_empty():
		return
	var band: Rect2 = (p["rect"] as Rect2).intersection(chunk_rect)
	if band.size.x <= 0.01 or band.size.y <= 0.01:
		return
	var ground_y := 0.0
	if world_plan != null:
		ground_y = world_plan.surface_height_at(band.get_center())
	b.add_visual_box(Vector3(band.get_center().x, ground_y + 0.055,
			band.get_center().y),
			Vector3(band.size.x, 0.09, band.size.y), ALLEY_FLOOR)


static func _plaza(b: MeshBatcher, plan: CityPlan, block: Dictionary,
		chunk_rect: Rect2, coord: Vector2i, world_plan: WorldPlan = null) -> void:
	var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
	var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
	# Scale the convex block polygon around its centroid to leave a framed
	# pedestrian interior; this preserves irregular square outlines.
	var interior_poly := PackedVector2Array()
	for p: Vector2 in poly:
		interior_poly.append(center.lerp(p, 0.58))
	var clipped := _clip_polygon_to_rect(interior_poly, chunk_rect)
	if clipped.size() < 3:
		return
	var ground_y := 0.0
	if world_plan != null:
		ground_y = world_plan.surface_height_at(center)
	b.add_visual_polygon(clipped, ground_y + 0.045, PLAZA_PAVE)
	if WorldSeed.chunk_coord(center.x, center.y) != coord:
		return
	var bounds := _polygon_bounds(interior_poly)
	if bounds.size.x < 20.0 or bounds.size.y < 20.0:
		return
	# Octagonal fountain basin at square center.
	for i in 8:
		var ang := TAU * float(i) / 8.0 + TAU / 16.0
		var dir := Vector2(cos(ang), sin(ang))
		var basis := Basis(Vector3.UP, -ang - TAU * 0.25)
		b.add_box_rotated(
				Vector3(center.x + dir.x * 2.3, ground_y + 0.28, center.y + dir.y * 2.3),
				Vector3(1.95, 0.56, 0.42), basis, FOUNTAIN_RIM, true)
	b.add_visual_box(Vector3(center.x, ground_y + 0.16, center.y), Vector3(4.0, 0.32, 4.0),
			FOUNTAIN_WATER)
	b.add_structural_box(Vector3(center.x, ground_y + 0.62, center.y),
			Vector3(0.9, 0.92, 0.9), FOUNTAIN_RIM)
	# Market stalls in the four quadrants (abandoned market area).
	var rng := WorldSeed.rng_for("market", [coord.x, coord.y])
	var stall_count := rng.randi_range(3, 6)
	var half := Vector2(minf(14.0, bounds.size.x * 0.32),
			minf(14.0, bounds.size.y * 0.32))
	for i in stall_count:
		var qx := -1.0 if i % 2 == 0 else 1.0
		var qy := -1.0 if (i >> 1) % 2 == 0 else 1.0
		var p := center + Vector2(qx * rng.randf_range(6.5, half.x),
				qy * rng.randf_range(6.5, half.y))
		if not _point_in_polygon(interior_poly, p):
			continue
		if p.distance_to(center) < 7.0:
			continue
		_market_stall(b, p, rng, ground_y)


static func _market_stall(b: MeshBatcher, p: Vector2,
		rng: RandomNumberGenerator, ground_y := 0.0) -> void:
	var yaw := PI * 0.5 * float(rng.randi_range(0, 1)) \
			+ rng.randf_range(-0.08, 0.08)
	var basis := Basis(Vector3.UP, -yaw)
	var canopy_c: Color = STALL_COLORS[rng.randi_range(0, STALL_COLORS.size() - 1)]
	var parts: Array = []
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var off := basis * Vector3(corner.x * 1.15, 0, corner.y * 1.05)
		parts.append({
			"offset": Vector3(off.x, 1.1, off.z),
			"size": Vector3(0.12, 2.2, 0.12),
			"color": Color("5c5148"),
			"collide": true,
		})
	parts.append({
		"offset": Vector3(0, 0.45, 0),
		"size": Vector3(2.3, 0.9, 1.0),
		"color": Color("6b5a41"),
		"collide": true,
	})
	# Canopy rides along visually (no collision) so nothing floats when the
	# stall is blasted apart.
	parts.append({
		"offset": Vector3(0, 2.28, 0),
		"size": Vector3(2.7, 0.16, 2.5),
		"color": canopy_c,
		"collide": false,
	})
	b.add_prop_def({
		"position": Vector3(p.x, ground_y, p.y),
		"yaw": yaw,
		"material": &"wood",
		"parts": parts,
	})
	# Scattered wares under the canopy.
	for j in rng.randi_range(1, 3):
		var off := basis * Vector3(rng.randf_range(-0.9, 0.9), 0,
				rng.randf_range(-0.35, 0.35))
		b.add_box(Vector3(p.x + off.x, ground_y + 1.02, p.y + off.z),
			Vector3(rng.randf_range(0.25, 0.5), rng.randf_range(0.15, 0.3),
				rng.randf_range(0.25, 0.5)),
			Color("8c7b5a").lightened(rng.randf() * 0.25))


static func _park(b: MeshBatcher, plan: CityPlan, block: Dictionary,
		chunk_rect: Rect2, coord: Vector2i, world_plan: WorldPlan = null) -> void:
	_pavement(b, block, chunk_rect, GRASS, world_plan)
	var rng := WorldSeed.rng_for("park_trees",
			[int(WorldSeed.combine([str(block["id"]).hash()]))])
	var poly: PackedVector2Array = block.get("polygon", PackedVector2Array()) as PackedVector2Array
	var center: Vector2 = block.get("center", Vector2.ZERO) as Vector2
	var ground_y := 0.0
	if world_plan != null:
		ground_y = world_plan.surface_height_at(center)
	var bounds := _polygon_bounds(poly)
	var count := 4 + int(rng.randf() * 5.0)
	for i in count:
		var p := Vector2(
			rng.randf_range(bounds.position.x + 2.5, bounds.end.x - 2.5),
			rng.randf_range(bounds.position.y + 2.5, bounds.end.y - 2.5))
		if WorldSeed.chunk_coord(p.x, p.y) != coord or not _point_in_polygon(poly, p):
			continue
		var h := rng.randf_range(1.9, 2.6)
		# One destructible wood prop: trunk (collides) + canopy (visual).
		b.add_prop_def({
			"position": Vector3(p.x, ground_y, p.y),
			"material": &"wood",
			"parts": [
				{"offset": Vector3(0, h * 0.5, 0),
						"size": Vector3(0.42, h, 0.42),
						"color": TRUNK_COLOR, "collide": true},
				{"offset": Vector3(0, h + 0.7, 0),
						"size": Vector3(rng.randf_range(1.9, 2.6), 1.6,
							rng.randf_range(1.9, 2.6)),
						"color": CANOPY_COLOR, "collide": false},
			],
		})


# --- Props / apocalypse decoration pass v0 ------------------------------------

static func _scatter_props(b: MeshBatcher, plan: CityPlan, rect: Rect2,
		coord: Vector2i, world_plan: WorldPlan = null) -> void:
	var rng := WorldSeed.rng_for("props", [coord.x, coord.y])

	# Colliding props must never spawn inside a door's swing arc - the
	# physical door leaf would jam against them.
	var door_pts: Array[Vector2] = []
	for spec in plan.buildings_in_rect(rect.grow(8.0)):
		for dm in spec.get("doors", []):
			var dp: Vector3 = dm["position"]
			door_pts.append(Vector2(dp.x, dp.z))

	# Wrecked cars follow actual city road tangents, never legacy X/Z lines.
	var road_segments := plan.city_road_segments_in(rect.grow(10.0))
	var car_count := rng.randi_range(0, 3)
	for i in car_count:
		if road_segments.is_empty():
			break
		var edge: Dictionary = road_segments[rng.randi_range(0, road_segments.size() - 1)]
		var poly: PackedVector2Array = edge.get("polyline_clipped", PackedVector2Array()) as PackedVector2Array
		if poly.size() < 2:
			continue
		var seg_i := rng.randi_range(0, poly.size() - 2)
		var a: Vector2 = poly[seg_i]
		var z: Vector2 = poly[seg_i + 1]
		var tangent := (z - a).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var p := a.lerp(z, rng.randf()) + normal * rng.randf_range(-1.5, 1.5)
		if _inside_any_building(plan, p) or _near_door(door_pts, p):
			continue
		var ground_y := world_plan.surface_height_at(p) if world_plan != null else 0.0
		_car(b, p, rng, CAR_COLORS[rng.randi_range(0, CAR_COLORS.size() - 1)],
				tangent, ground_y)

	# Debris piles.
	for i in rng.randi_range(4, 10):
		var p := Vector2(rng.randf_range(rect.position.x, rect.end.x),
			rng.randf_range(rect.position.y, rect.end.y))
		if _inside_any_building(plan, p):
			continue
		var ground_y := world_plan.surface_height_at(p) if world_plan != null else 0.0
		var base_c: Color = DEBRIS_COLORS[rng.randi_range(0, DEBRIS_COLORS.size() - 1)]
		for j in rng.randi_range(2, 4):
			var off := Vector2(rng.randf_range(-0.9, 0.9),
				rng.randf_range(-0.9, 0.9))
			b.add_box(Vector3(p.x + off.x, ground_y + rng.randf_range(0.12, 0.3),
					p.y + off.y),
					Vector3(rng.randf_range(0.4, 1.1), rng.randf_range(0.2, 0.5),
							rng.randf_range(0.4, 1.1)),
					base_c.lightened(rng.randf() * 0.18))

	# Trash bins / bags near building fronts.
	for i in rng.randi_range(2, 6):
		var specs := plan.buildings_in_rect(rect)
		if specs.is_empty():
			break
		var spec: Dictionary = specs[rng.randi_range(0, specs.size() - 1)]
		var lr: Rect2 = spec["rect"]
		var side := int(spec["door_edge"])
		var p := _front_of(lr, side, rng.randf_range(0.25, 0.75))
		p += Vector2(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2))
		if _near_door(door_pts, p):
			continue
		var ground_y := world_plan.surface_height_at(p) if world_plan != null else 0.0
		b.add_prop_def({
			"position": Vector3(p.x, ground_y, p.y),
			"yaw": rng.randf_range(0.0, TAU),
			"material": &"steel",
			"parts": [{
				"offset": Vector3(0, 0.28, 0),
				"size": Vector3(rng.randf_range(0.5, 0.8), 0.56,
						rng.randf_range(0.5, 0.8)),
				"color": Color("30332e").lightened(rng.randf() * 0.2),
				"collide": true,
			}],
		})


static func _car(b: MeshBatcher, p: Vector2, rng: RandomNumberGenerator,
		color: Color, road_dir := Vector2.ZERO, ground_y := 0.0) -> void:
	var yaw := atan2(road_dir.x, road_dir.y) if road_dir.length_squared() > 0.01 \
			else rng.randf_range(-0.12, 0.12) + (PI * 0.5 if rng.randf() < 0.5 else 0.0)
	# Cars align across streets: orient with the actual road tangent.
	var basis := Basis(Vector3.UP, yaw)
	# One destructible steel prop: body + cabin. Explosions bounce surviving
	# debris off the blast center; sustained fire wrecks it in place.
	var body_off: Vector3 = basis * Vector3(0, 0.45, 0)
	var cabin_off: Vector3 = basis * Vector3(0, 1.05, 0)
	b.add_prop_def({
		"position": Vector3(p.x, ground_y, p.y),
		"yaw": yaw,
		"material": &"steel",
		"parts": [
			{"offset": body_off, "size": Vector3(1.85, 0.7, 4.2),
					"color": color, "collide": true},
			{"offset": cabin_off, "size": Vector3(1.65, 0.55, 2.1),
					"color": color.darkened(0.25), "collide": true},
		],
	})


static func _lamp_post(b: MeshBatcher, p: Vector2, ground_y := 0.0) -> void:
	b.add_prop_def({
		"position": Vector3(p.x, ground_y, p.y),
		"material": &"steel",
		"parts": [
			{"offset": Vector3(0, 2.3, 0), "size": Vector3(0.16, 4.6, 0.16),
					"color": Color("33363a"), "collide": true},
			{"offset": Vector3(0, 4.65, 0), "size": Vector3(0.5, 0.18, 0.5),
					"color": Color("d8cf9f"), "collide": false},
		],
	})
	# Phase S: real streetlamp spill light — DayNightController toggles these
	# at night so pools of warm light punctuate genuine darkness.
	b.add_street_lamp(Vector3(p.x, ground_y + 4.1, p.y))


static func _clip_polygon_to_rect(poly: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
	var out := poly
	out = _clip_polygon_axis(out, 0, rect.position.x, true)
	out = _clip_polygon_axis(out, 0, rect.end.x, false)
	out = _clip_polygon_axis(out, 1, rect.position.y, true)
	out = _clip_polygon_axis(out, 1, rect.end.y, false)
	return out


static func _clip_polygon_axis(poly: PackedVector2Array, axis: int,
		bound: float, keep_greater: bool) -> PackedVector2Array:
	if poly.size() < 3:
		return PackedVector2Array()
	var out := PackedVector2Array()
	for i in poly.size():
		var a: Vector2 = poly[i]
		var z: Vector2 = poly[(i + 1) % poly.size()]
		var av := a.x if axis == 0 else a.y
		var zv := z.x if axis == 0 else z.y
		var in_a := av >= bound - 0.001 if keep_greater else av <= bound + 0.001
		var in_z := zv >= bound - 0.001 if keep_greater else zv <= bound + 0.001
		if in_a:
			out.append(a)
		if in_a != in_z:
			var denom := zv - av
			if absf(denom) > 1e-8:
				var t := (bound - av) / denom
				out.append(a.lerp(z, t))
	return out


static func _polygon_bounds(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for p: Vector2 in poly:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


static func _point_in_polygon(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	if poly.size() < 3:
		return false
	var j := poly.size() - 1
	for i in poly.size():
		var a: Vector2 = poly[i]
		var z: Vector2 = poly[j]
		if (a.y > p.y) != (z.y > p.y):
			var denom := z.y - a.y
			if absf(denom) > 1e-8:
				var x_at_y := (z.x - a.x) * (p.y - a.y) / denom + a.x
				if p.x < x_at_y:
					inside = not inside
		j = i
	return inside


static func _inside_any_building(plan: CityPlan, p: Vector2) -> bool:
	for spec in plan.buildings_in_rect(Rect2(p - Vector2.ONE, Vector2(2, 2))):
		if (spec["rect"] as Rect2).has_point(p):
			return true
	return false


## Point just outside a footprint's facade midpoint (t in [0,1] along it).
static func _front_of(lr: Rect2, door_edge: int, t: float) -> Vector2:
	match door_edge:
		0: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.position.y - 1.4)
		1: return Vector2(lr.end.x + 1.4, lerpf(lr.position.y, lr.end.y, t))
		2: return Vector2(lerpf(lr.position.x, lr.end.x, t), lr.end.y + 1.4)
		_: return Vector2(lr.position.x - 1.4, lerpf(lr.position.y, lr.end.y, t))


## True when `p` sits inside any door's swing clearance.
static func _near_door(door_pts: Array[Vector2], p: Vector2) -> bool:
	for d in door_pts:
		if p.distance_to(d) < 2.4:
			return true
	return false
