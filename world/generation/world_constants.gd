class_name WorldConstants
extends RefCounted
## Authoritative world coordinate contract — single source of truth.
## No builder or test may duplicate these numerics; import this file.

# --- Coordinate axes ---
# X/Z horizontal world coordinates (meters), Y is elevation (meters).
# Vector2 plan points are always (x, z) in world space, never chunk-local.

# --- Partition scales (meters) ---
const CHUNK_SIZE_M := 64
const LANDSCAPE_CELL_M := 256
const MACRO_CELL_M := 1024

# --- World bounds (16 km x 16 km) ---
const WORLD_HALF_EXTENT_M := 8192.0
const WORLD_MIN_M := -8192.0
const WORLD_MAX_M := 8192.0  # exclusive upper bound: [-8192, 8192)
const WORLD_SIZE_M := 16384.0

# --- Vertical datums (meters, Y) ---
# terrain_y: sampled ground elevation at (x,z) — TerrainPlan.height_at
const TERRAIN_DATUM_Y := 0.0
# water_level: future hydrology datum (no water generated in P2) — reference only
const WATER_LEVEL_Y := -2.0
# building_ground_y: derived per-building as terrain_y at footprint center
# lower_city_y: top of lower/underground network (future, not generated)
const LOWER_CITY_Y := -15.0
# upper_civilization_y: lowest altitude of upper survivor network (future)
const UPPER_CIVILIZATION_Y := 120.0
# visual roof/sky dressing upper limit (no gameplay)
const SKY_DRESSING_Y := 500.0

# --- Terrain ranges & tolerances ---
const TERRAIN_MIN_HEIGHT_M := -12.0
const TERRAIN_MAX_HEIGHT_M := 120.0
# Small-frequency surface variation documented amplitude
const TERRAIN_DETAIL_AMPLITUDE_M := 2.5
# Terrain class height thresholds (authoritative; TerrainPlan must use these)
const TERRAIN_UPLAND_HEIGHT_M := 38.0
const TERRAIN_ROLLING_HEIGHT_M := 10.0
# Buildability slope threshold (degrees)
const BUILDABLE_MAX_SLOPE_DEG := 22.0
# Cliff classification slope threshold
const CLIFF_SLOPE_DEG := 35.0
# Normal tolerance for normalized check
const NORMAL_TOLERANCE := 1e-4
# Seam continuity tolerance (finite-difference noise is C0 continuous; allow float epsilon)
const SEAM_CONTINUITY_TOL_M := 0.02
# Boundary smoothing: last N meters toward WORLD_MAX lerp height toward 0
const BOUNDARY_SMOOTH_M := 500.0
# Basin smoothing: within this radius of origin, height lerp toward near-zero
const BASIN_SMOOTH_RADIUS_M := 220.0
const BASIN_SMOOTH_MAX_HEIGHT_M := 6.0

# --- Schema / version ---
const WORLD_SCHEMA_VERSION := 1
# Generator version remains WorldSeed.GENERATOR_VERSION == 2 in P2 (no city manifest change)

# --- Hydrology (P2.2) authoritative numerics — single source of truth ---
# River corridor is deterministic from seed: CX = 620 + S*90, meander 72 sin + 18 coherent.
const HYDRO_CORRIDOR_CX_MEAN := 620.0
const HYDRO_CORRIDOR_JITTER := 90.0
const HYDRO_MEANDER_AMPL := 72.0
const HYDRO_MEANDER_WAVELENGTH := 1350.0
const HYDRO_MEANDER2_AMPL := 18.0
const HYDRO_MEANDER2_CELL := 600.0
const HYDRO_WIDTH_CELL := 900.0
const RIVER_WIDTH_MIN := 38.0
const RIVER_WIDTH_MAX := 50.0
const TRIBUTARY_WIDTH_MIN := 14.0
const TRIBUTARY_WIDTH_MAX := 22.0
const BANK_W := 9.0
const FLOODPLAIN_W := 26.0
const WATER_LEVEL_MEAN := -1.2
const WATER_LEVEL_VAR := 0.6
const WATER_LEVEL_CELL := 800.0
const TRIB_FALL_SLOPE := 0.015
const TRIB_COUNT := 2
# TRIB tributary anchors outside corridor CX +- (260 +-80), upstream Az ~ -2200 + k*1400
const TRIB_ANCHOR_BASE_OFFSET := 260.0
const TRIB_ANCHOR_JITTER := 80.0
const TRIB_UPSTREAM_BASE_Z := -2200.0
const TRIB_UPSTREAM_STEP_Z := 1400.0
const TRIB_UPSTREAM_JITTER_Z := 320.0
# Meander phase seeded via unit_float("hydro_phi")
# --- World-composition and realized-surface contract ---
# WorldPlan is the only owner of the outdoor Y datum. CityPlan uses a flat
# grade only inside this fully materialized urban terrace; the 350-600 m band
# is macro terrain / city-edge composition, never an unbounded second city.
const URBAN_INNER_M := 350.0
const URBAN_OUTER_M := 600.0
const URBAN_CITY_TERRACE_Y := 0.0
const SURFACE_SAMPLE_EPSILON_M := 0.5
const RIVER_BED_DEPTH_M := 2.5
const RIVER_BANK_FREEBOARD_M := 0.65
const QUARRY_FEATURE_CELL_M := 256.0
const QUARRY_FEATURE_RADIUS_M := 72.0
const QUARRY_FEATURE_DEPTH_M := 8.0
const SPAWN_FEET_CLEARANCE_M := 0.06
# Layer 8 is reserved for surfaces a character can stand on. Gameplay bodies
# keep the existing environment layer (1); spawn validation rays use ONLY 8
# so roofs, walls, props and water cannot define "ground".
const COLLISION_WALKABLE_GROUND := 8
# Water is queryable/visible but is not walkable ground. It stays off actor
# masks while preserving its own body for hydrology probes.
const COLLISION_WATER := 16
const FRAME_BUDGET_MS := 12.0

# --- World IDs & vocabulary ---
const TERRAIN_CLASSES: Array[StringName] = [&"basin", &"rolling_hill", &"upland", &"cliff"]
const SURFACE_MATERIALS: Array[StringName] = [&"alluvial_soil", &"meadow_soil", &"upland_grass", &"rock"]
const WATER_BODIES: Array[StringName] = [&"sea", &"lake", &"river", &"reservoir"]  # named only; sea not generated in continental Prague basin

# --- Settlement & Road (P4.1) authoritative numerics ---
const SETTLEMENT_VOCAB: Array[StringName] = [&"village", &"hamlet", &"farmstead", &"isolated_farm", &"town"]
const ROAD_HIERARCHY_VOCAB: Array[StringName] = [&"primary", &"secondary", &"track"]
const SETTLEMENT_MACRO_CELL := 1024.0
const SETTLEMENT_LANDSCAPE_CELL := 256.0
const SETTLEMENT_SITE_RADIUS_VILLAGE_MIN := 48.0
const SETTLEMENT_SITE_RADIUS_VILLAGE_MAX := 90.0
const SETTLEMENT_SITE_RADIUS_HAMLET_MIN := 26.0
const SETTLEMENT_SITE_RADIUS_HAMLET_MAX := 46.0
const SETTLEMENT_SITE_RADIUS_FARMSTEAD_MIN := 16.0
const SETTLEMENT_SITE_RADIUS_FARMSTEAD_MAX := 28.0
const SETTLEMENT_SITE_RADIUS_ISOLATED_FARM_MIN := 16.0
const SETTLEMENT_SITE_RADIUS_ISOLATED_FARM_MAX := 28.0
const SETTLEMENT_SPACING_VILLAGE := 700.0
const SETTLEMENT_SPACING_HAMLET := 420.0
const SETTLEMENT_SPACING_FARMSTEAD := 220.0
const SETTLEMENT_MIN_RADIUS_FACTOR := 1.8
const SETTLEMENT_GATE_RADIUS := 18.0
const SETTLEMENT_GATE_COUNT_MIN := 4
const SETTLEMENT_GATE_COUNT_MAX := 8
const ROAD_WIDTH_PRIMARY := 7.0
const ROAD_WIDTH_SECONDARY := 5.0
const ROAD_WIDTH_TRACK := 3.5
const ROAD_LIFT_M := 0.04
const BRIDGE_DECK_LIFT_M := 0.35
const BRIDGE_WIDTH_EXTRA := 0.6
const MAX_ROAD_VERTS_PER_CHUNK := 160
const MAX_ROAD_VERTS_TYPICAL := 96
const MAX_ROAD_TRIS_PER_CHUNK := 96
const MAX_ROAD_TRIS_TYPICAL := 64
const MAX_ROAD_SEGMENTS_PER_CHUNK := 8
const MAX_ACTIVE_ROAD_COLLIDERS := 9
const ROAD_SMOOTH_SAMPLE_M := 12.0

# --- Rural Building Fabric (P4.2) authoritative numerics ---
const RURAL_BUILDING_VOCAB: Array[StringName] = [&"village_house", &"cottage", &"barn", &"farmhouse", &"stable", &"shed"]
const RURAL_BUILDING_FOOTPRINT_VILLAGE_MIN := Vector2(8, 10)
const RURAL_BUILDING_FOOTPRINT_VILLAGE_MAX := Vector2(10, 12)
const RURAL_BUILDING_FOOTPRINT_COTTAGE_MIN := Vector2(7, 8)
const RURAL_BUILDING_FOOTPRINT_COTTAGE_MAX := Vector2(9, 11)
const RURAL_BUILDING_FOOTPRINT_FARMHOUSE_MIN := Vector2(7, 8)
const RURAL_BUILDING_FOOTPRINT_FARMHOUSE_MAX := Vector2(9, 11)
const RURAL_BUILDING_FOOTPRINT_BARN_MIN := Vector2(8, 10)
const RURAL_BUILDING_FOOTPRINT_BARN_MAX := Vector2(10, 14)
const RURAL_BUILDING_FOOTPRINT_STABLE_MIN := Vector2(8, 10)
const RURAL_BUILDING_FOOTPRINT_STABLE_MAX := Vector2(10, 14)
const RURAL_BUILDING_FOOTPRINT_SHED_MIN := Vector2(6, 8)
const RURAL_BUILDING_FOOTPRINT_SHED_MAX := Vector2(8, 10)
const RURAL_BUILDING_FOOTPRINT_MIN := Vector2(6, 8)
const RURAL_BUILDING_FOOTPRINT_MAX := Vector2(10, 14)
const RURAL_BUILDING_HEIGHT_SINGLE := 4.2
const RURAL_BUILDING_HEIGHT_VILLAGE_TWO_STOREY_EXTRA := 2.9
const RURAL_BUILDING_SPACING_MIN := 8.0
const RURAL_BUILDING_ROAD_SETBACK := 4.0
const RURAL_BUILDING_SETTLEMENT_INNER_CLEARANCE := 6.0
const RURAL_BUILDING_COUNT_VILLAGE_MIN := 4
const RURAL_BUILDING_COUNT_VILLAGE_MAX := 6
const RURAL_BUILDING_COUNT_HAMLET_MIN := 2
const RURAL_BUILDING_COUNT_HAMLET_MAX := 3
const RURAL_BUILDING_COUNT_FARMSTEAD_MIN := 1
const RURAL_BUILDING_COUNT_FARMSTEAD_MAX := 2
const RURAL_BUILDING_COUNTS: Dictionary = {"village": Vector2i(4,6), "hamlet": Vector2i(2,3), "farmstead": Vector2i(1,2), "isolated_farm": Vector2i(1,1)}
const MAX_RURAL_BUILDINGS_PER_CHUNK := 6
const MAX_RURAL_VERTS_PER_CHUNK := 720
const MAX_RURAL_VERTS_TYPICAL := 360
const MAX_RURAL_TRIS_PER_CHUNK := 420
const MAX_RURAL_TRIS_TYPICAL := 280
const MAX_RURAL_COLLIDERS_PER_CHUNK := 1
const MAX_ACTIVE_RURAL_COLLIDERS := 9
const RURAL_DOOR_COUNT_MAX_PER_CHUNK := 6
const RURAL_OVERLAY_LIFT_M := 0.04

# --- Rural Interior & Scavenge (P4.3) authoritative numerics ---
const RURAL_INTERIOR_WALL_THICKNESS := 0.15
const RURAL_INTERIOR_WALL_LENGTH_FRACTION_MIN := 0.55
const RURAL_INTERIOR_WALL_LENGTH_FRACTION_MAX := 0.85
const RURAL_INTERIOR_DOORWAY_GAP_M := 0.95
const RURAL_FURNITURE_VOCAB: Array[StringName] = [&"bed", &"shelf", &"table", &"stove"]
const RURAL_FURNITURE_MAX_PER_BUILDING := 3
const RURAL_FURNITURE_MAX_PER_VILLAGE_CHUNK := 6
const RURAL_FURNITURE_CAP_PER_CHUNK := 6
const RURAL_CRATE_MAX_PER_CHUNK := 3
const RURAL_CRATE_MAX_PER_VILLAGE := 3
const RURAL_CRATE_MAX_PER_HAMLET := 1
const RURAL_CRATE_ITEMS_MIN := 1
const RURAL_CRATE_ITEMS_MAX_VILLAGE := 4
const RURAL_CRATE_ITEMS_MAX_HAMLET := 2

# --- Rural settlement front-end realization (existing hamlet/village concepts) ---
# These are presentation budgets, not new simulation entities. Paths and
# dressing have no physics body; buildings/doors retain their existing body
# budget and interactable contracts.
const RURAL_PATH_MAIN_WIDTH := 2.8
const RURAL_PATH_HAMLET_WIDTH := 2.4
const RURAL_PATH_FOOT_WIDTH := 1.55
const RURAL_PATH_FOOT_HAMLET_WIDTH := 1.35
const RURAL_PATH_LIFT_M := 0.035
const RURAL_YARD_RADIUS_HAMLET := 7.0
const RURAL_YARD_RADIUS_VILLAGE := 10.0
const RURAL_FENCE_HEIGHT_MIN := 1.05
const RURAL_FENCE_HEIGHT_MAX := 1.30
const RURAL_FENCE_MAX_PER_HAMLET := 7
const RURAL_FENCE_MAX_PER_VILLAGE := 10
const RURAL_CLUTTER_MAX_PER_HAMLET := 8
const RURAL_CLUTTER_MAX_PER_VILLAGE := 14
const RURAL_SETTLEMENT_TREES_HAMLET := 8
const RURAL_SETTLEMENT_TREES_VILLAGE := 12
const RURAL_SETTLEMENT_TREE_MIN_SPACING := 4.5
const RURAL_SETTLEMENT_TREE_ROAD_CLEARANCE := 5.0
const RURAL_SETTLEMENT_TREE_PATH_CLEARANCE := 3.5
const RURAL_SETTLEMENT_TREE_BUILDING_CLEARANCE := 5.0
const RURAL_SETTLEMENT_DRESSING_MAX_INSTANCES_PER_CHUNK := 64
const COL_RURAL_PATH_CART := Color("8b7656")
const COL_RURAL_PATH_FOOT := Color("a08a68")
const COL_RURAL_YARD := Color("71814d")
const COL_RURAL_FENCE := Color("6b4b32")
const COL_RURAL_FENCE_CAP := Color("89633f")
const COL_RURAL_TREE_TRUNK := Color("5a402c")
const COL_RURAL_TREE_BEECH := Color("486b3c")
const COL_RURAL_TREE_BIRCH := Color("668653")
const COL_RURAL_TREE_PINE := Color("31553a")

# --- Rural Homestead Renewables (P4.4) authoritative numerics ---
const RURAL_FORAGE_VOCAB: Array[StringName] = [&"bush_berry", &"mushroom_cluster", &"herb_patch"]
const RURAL_WELL_RADIUS := 0.9
const RURAL_WELL_HEIGHT := 1.8
const RURAL_WELL_MAX_PER_CHUNK := 2
const RURAL_WELL_MAX_PER_VILLAGE := 2
const RURAL_WELL_MAX_PER_HAMLET := 1
const RURAL_WELL_MAX_PER_FARMSTEAD := 1
const RURAL_WELL_COLOR_WALL := Color("8b7f6e")
const RURAL_WELL_COLOR_WATER := Color("2b3a4a")
const RURAL_WELL_COLOR_BEAM := Color("6b5a4a")
const RURAL_FORAGE_COLOR_BUSH := Color("5a7a3a")
const RURAL_FORAGE_COLOR_MUSHROOM := Color("8a6a4a")
const RURAL_FORAGE_COLOR_HERB := Color("6a8a5a")
const RURAL_FORAGE_MAX_PER_CHUNK := 4
const RURAL_FORAGE_MAX_PER_VILLAGE_VICINITY := 5
const RURAL_FORAGE_MAX_PER_HAMLET_VICINITY := 3
const RURAL_FORAGE_VICINITY_M := 120.0
const RURAL_RESOURCE_VICINITY_M := 120.0
const RURAL_FORAGE_ALLOW_BIOMES: Array[StringName] = [&"arable_field", &"pasture", &"pasture_orchard", &"orchard", &"deciduous_forest", &"mixed_upland_forest", &"wet_meadow", &"industrial_corridor"]
const RURAL_WELL_SPACING_MIN := 6.0
const RURAL_WELL_BUILDING_GAP_MIN := 8.0
const RURAL_FORAGE_SPACING_MIN := 4.0
const RURAL_FORAGE_BUILDING_GAP_MIN := 6.0
const RURAL_FORAGE_WELL_GAP_MIN := 6.0
const RURAL_FORAGE_ROAD_SETBACK := 2.0
const RURAL_WELL_ROAD_SETBACK := 4.0
const RURAL_FORAGE_WELL_SPACING := 4.0

# --- Rural Hearth Habitation (P4.5) authoritative numerics — hearth reuses furniture anchors, no new mesh/collider budget ---
# Unified collider peak is now 54 (9 city+9 terrain+9 water+9 biome+9 road+9 rural where rural is single shell+well Concave) not 63
# Well is baked into same Concave (no second WellBody); forage/hearth are Area3D monitorable ACTIVE-only, no collider.
# Hearth shares furniture mesh vertices (24 verts /12 tris already counted), so MAX_RURAL 720/420 360/280 dense/typical.
const RURAL_HEARTH_VOCAB: Array[StringName] = [&"stove", &"bed"] # subset of RURAL_FURNITURE_VOCAB, deterministic reuse
const RURAL_STOVE_MAX_PER_CHUNK := 2
const RURAL_BED_MAX_PER_CHUNK := 2
const RURAL_HEARTH_MAX_PER_CHUNK := 4
const RURAL_HEARTH_MAX_PER_VILLAGE_CHUNK := 4
const RURAL_HEARTH_MAX_PER_HAMLET := 2 # at most 1 stove +1 bed via furniture cap 2
const COL_FURNITURE_STOVE := Color("4a4a4a")
const COL_FURNITURE_BED := Color("9e8b6a")
const STOVE_HUNGER_REDUCTION := 40.0 # via NeedsComponent.eat (spec says 40 raw, 50 cooked; keep 40 deterministic)
const BED_FATIGUE_REDUCTION := 40.0
const BED_SLEEP_MINUTES := 480.0 # 8h to next 06:00
const WELL_REFILL_HOUR := 4 # 04:00 next day
const FORAGE_REGROW_DAYS := 2

# --- Field-Parcel Cultivation (P5.1) authoritative numerics ---
const FIELD_PARCEL_VOCAB: Array[StringName] = [&"wheat", &"barley", &"potato", &"beet"]
const CROP_VOCAB: Array[StringName] = [&"wheat", &"barley", &"potato", &"beet"]
const FIELD_PARCEL_SIZE_MIN := Vector2(18, 14)
const FIELD_PARCEL_SIZE_MAX := Vector2(64, 48)
const FIELD_PARCEL_MAX_PER_LANDSCAPE_CELL := 3
const FIELD_PARCEL_MAX_PER_CHUNK := 4
const FIELD_DENSITY_MIN := 0.38
const FIELD_CROP_MAX_PER_CHUNK := 4
const FIELD_PARCEL_ROAD_SETBACK := 3.0
const FIELD_PARCEL_BUILDING_GAP := 8.0
const FIELD_PARCEL_SPACING_MIN := 4.0
const FIELD_PARCEL_WELL_FORAGE_GAP := 6.0
const CROP_GROW_DAYS := 2
const CROP_REGROW_DAYS := 2
const FIELD_PARCEL_LIFT_M := 0.04
const HEDGEROW_HEIGHT := 0.6
const FIELD_PARCEL_HEDGEROW_COLOR := Color("5a7a3a")
const HEDGEROW_TRUE_LENGTH := 2.0
const HEDGEROW_TRUE_WIDTH := 0.4
const HEDGEROW_TRUE_HEIGHT_MIN := 0.45
const HEDGEROW_TRUE_HEIGHT_MAX := 0.75
const HEDGEROW_TRUE_COLOR := Color("5a7a3a")
const HEDGEROW_WIDTH := 0.4
const FIELD_PARCEL_HEDGEROW_WIDTH := 0.4
const COL_FIELD_WHEAT := Color("c2b280")
const COL_FIELD_BARLEY := Color("8faa6a")
const COL_FIELD_POTATO := Color("6e635a")
const COL_FIELD_BEET := Color("6a8a5a")
const MAX_FIELD_VERTS_PER_CHUNK := 96
const MAX_FIELD_TRIS_PER_CHUNK := 64
const FIELD_HEDGEROW_MAX_PER_CHUNK := 8
const FIELD_PARCEL_AABB_GAP := 4.0
const FIELD_PARCEL_HEIGHT_VARIANCE_MAX := 0.8

# --- Orchard-Parcel Cultivation (P5.2) authoritative numerics ---
const ORCHARD_PARCEL_VOCAB: Array[StringName] = [&"apple", &"plum", &"pear", &"cherry"]
const FRUIT_VOCAB: Array[StringName] = [&"apple", &"plum", &"pear", &"cherry"]
const ORCHARD_PARCEL_SIZE_MIN := Vector2(20, 16)
const ORCHARD_PARCEL_SIZE_MAX := Vector2(68, 52)
const ORCHARD_PARCEL_MAX_PER_LANDSCAPE_CELL := 2
const ORCHARD_PARCEL_MAX_PER_CHUNK := 3
const ORCHARD_DENSITY_MIN := 0.42
const ORCHARD_CROP_MAX_PER_CHUNK := 3
const FRUIT_MAX_PER_CHUNK := 3
const ORCHARD_PARCEL_ROAD_SETBACK := 3.0
const ORCHARD_PARCEL_BUILDING_GAP := 8.0
const ORCHARD_PARCEL_SPACING_MIN := 4.0
const ORCHARD_PARCEL_AABB_GAP := 4.0
const ORCHARD_WELL_FORAGE_GAP := 6.0
const ORCHARD_PARCEL_HEIGHT_VARIANCE_MAX := 0.9
const FRUIT_GROW_DAYS := 3
const FRUIT_REGROW_DAYS := 3
const ORCHARD_PARCEL_LIFT_M := 0.04
const ORCHARD_TREE_SPACING := 5.0
const ORCHARD_ROW_SPACING := 5.5
const ORCHARD_MAX_SLOPE_DEG := 14.0
const COL_TRUNK := Color("6b5a4a")
const COL_ORCHARD_APPLE := Color("3a7a3a")
const COL_ORCHARD_PLUM := Color("4a6a4a")
const COL_ORCHARD_PEAR := Color("6a8a5a")
const COL_ORCHARD_CHERRY := Color("7a5a6a")
const COL_CANOPY_APPLE := Color("3a7a3a")
const COL_CANOPY_PLUM := Color("4a6a4a")
const COL_CANOPY_PEAR := Color("6a8a5a")
const COL_CANOPY_CHERRY := Color("7a5a6a")
const ORCHARD_HEDGEROW_MAX_PER_CHUNK := 6
const MAX_ORCHARD_VERTS_PER_CHUNK := 0
const MAX_ORCHARD_TRIS_PER_CHUNK := 0
const MAX_ORCHARD_INSTANCES_PER_CHUNK := 12
const ORCHARD_TRUNK_SIZE := Vector3(0.35, 1.8, 0.35)
const ORCHARD_CANOPY_SIZE := Vector3(1.4, 1.0, 1.4)

# --- Rural Workbench Economy (P5.3) authoritative numerics -- hardened P5.4 aabb_gap explicit ---
const RURAL_WORKBENCH_MAX_PER_CHUNK := 2
const RURAL_WORKBENCH_MAX_PER_VILLAGE := 1
const RURAL_WORKBENCH_MAX_PER_HAMLET := 1
const RURAL_WORKBENCH_MAX_PER_FARMSTEAD := 0
const RURAL_WORKBENCH_SPACING_MIN := 8.0
const RURAL_WORKBENCH_BUILDING_GAP_MIN := 1.0
const RURAL_WORKBENCH_SIZE := Vector3(1.2, 0.9, 0.6)
const COL_WORKBENCH := Color("7a6a5a")
const WORKBENCH_LIFT_M := 0.04
const RURAL_WORKBENCH_WELL_GAP_MIN := 6.0
const RURAL_WORKBENCH_FORAGE_GAP_MIN := 6.0
const RURAL_WORKBENCH_ROAD_SETBACK := 3.0

# --- Rural Granary & Provisioning Cache (P5.4) authoritative numerics ---
const RURAL_GRANARY_MAX_PER_CHUNK := 2
const RURAL_GRANARY_MAX_PER_VILLAGE := 1
const RURAL_GRANARY_MAX_PER_HAMLET := 1
const RURAL_GRANARY_MAX_PER_FARMSTEAD := 0
const RURAL_GRANARY_SPACING_MIN := 8.0
const RURAL_GRANARY_BUILDING_GAP_MIN := 8.0
const RURAL_GRANARY_SIZE := Vector3(1.2, 0.6, 0.8)
const COL_GRANARY := Color("6b4a3a")
const GRANARY_LIFT_M := 0.04
const RURAL_GRANARY_CAPACITY := 8
const RURAL_GRANARY_WELL_GAP_MIN := 6.0
const RURAL_GRANARY_FORAGE_GAP_MIN := 6.0
const RURAL_GRANARY_WORKBENCH_GAP_MIN := 1.0
const RURAL_GRANARY_ROAD_SETBACK := 3.0
const RURAL_GRANARY_FURNITURE_GAP_MIN := 0.9
const RURAL_GRANARY_DOOR_SWING_GAP := 1.0

# --- Cave Entrance Foundation (G8 M1) authoritative numerics ---
const CAVE_ENTRANCE_VOCAB: Array[StringName] = [&"cave_entrance"]
const CAVE_ENTRANCE_HEIGHT := 2.2
const CAVE_ENTRANCE_RADIUS := 1.8
const CAVE_ENTRANCE_FOOTPRINT := Vector2(3.6, 3.6)
const CAVE_ENTRANCE_SIZE := Vector3(3.6, 2.2, 3.6)
const COL_CAVE_ENTRANCE := Color("5a4a3a")
const CAVE_ENTRANCE_MAX_PER_CHUNK := 1
const CAVE_ENTRANCE_MAX_PER_LANDSCAPE_CELL := 1
const MAX_CAVE_VERTS_PER_CHUNK := 96
const MAX_CAVE_TRIS_PER_CHUNK := 48
const MAX_ACTIVE_CAVE_COLLIDERS := 1 # one aggregated room body per active cave chunk
const CAVE_ENTRANCE_SPACING_MIN := 32.0
const CAVE_ENTRANCE_BUILDING_GAP_MIN := 8.0
const CAVE_ENTRANCE_WELL_GAP_MIN := 8.0
const CAVE_ENTRANCE_FORAGE_GAP_MIN := 8.0
const CAVE_ENTRANCE_ROAD_SETBACK := 4.0
const CAVE_ENTRANCE_WATER_GAP := 11.0 # BANK_W 9 + 2
const CAVE_ENTRANCE_LIFT_M := 0.01
const QUARRY_SUITABILITY_CAVE_THRESHOLD := 0.72
const CAVE_SLOPE_MIN_DEG := 28.0

# --- Playable cave slice (direct continuation of an existing entrance) ---
const CAVE_SLICE_SIZE := Vector3(8.0, 3.2, 8.0)
const CAVE_SLICE_FLOOR_OFFSET_M := -4.0
const CAVE_SLICE_ENTRY_OFFSET_M := 1.5
const CAVE_SLICE_WALL_THICKNESS := 0.30
const CAVE_SLICE_DOOR_WIDTH := 2.2
const CAVE_SLICE_DOOR_HEIGHT := 2.2
const CAVE_SLICE_ROCK_COLOR := Color("49392f")
const CAVE_SLICE_ROCK_DARK := Color("2b2521")
const CAVE_SLICE_FLOOR_COLOR := Color("5b4938")
const CAVE_SLICE_EXIT_COLOR := Color("6e5842")
const CAVE_SLICE_MAX_PER_CHUNK := 1
const CAVE_SLICE_COLLIDERS_PER_CHUNK := 1

# --- Vertical Survivor Network (G8 M4) authoritative numerics — roof bridge prototype ---
const VERTICAL_BRIDGE_VOCAB: Array[StringName] = [&"roof_bridge"]
const VERTICAL_BRIDGE_SPAN_MIN := 8.0
const VERTICAL_BRIDGE_SPAN_MAX := 14.0
const VERTICAL_BRIDGE_WIDTH := 1.2
const VERTICAL_BRIDGE_THICKNESS := 0.18
const VERTICAL_BRIDGE_LIFT_M := 1.2
const VERTICAL_BRIDGE_HEIGHT_OFFSET := 1.2
const VERTICAL_BRIDGE_MAX_PER_CHUNK := 1
const MAX_VERTICAL_VERTS_PER_CHUNK := 24
const MAX_VERTICAL_TRIS_PER_CHUNK := 12
const VERTICAL_BRIDGE_SPACING_MIN := 16.0
const VERTICAL_BRIDGE_BUILDING_GAP_MIN := 1.0
const VERTICAL_BRIDGE_ROAD_SETBACK := 2.0
const VERTICAL_BRIDGE_WATER_GAP := 11.0
const VERTICAL_BRIDGE_URBAN_INNER_SUPPRESS := 350.0
const VERTICAL_BRIDGE_SLOPE_MAX_DEG := 22.0
const COL_VERTICAL_BRIDGE := Color("8b7f6e")
const COL_VERTICAL_DARK := Color("6b5a4a")

# --- City Interior Program (G9 M1) authoritative numerics — residential ground floor semantics ---
const CITY_INTERIOR_VOCAB: Array[StringName] = [&"residential"]
const CITY_ROOM_VOCAB: Array[StringName] = [&"entry", &"kitchen", &"sleeping", &"toilet"]
const CITY_INTERIOR_WALL_T := 0.18
const CITY_INTERIOR_OPEN_W := 0.95
const CITY_INTERIOR_OPEN_H := 2.05
const CITY_INTERIOR_FURNITURE_VOCAB: Array[StringName] = [&"bed", &"shelf", &"table"]
const CITY_INTERIOR_MAX_PARTITIONS_PER_BUILDING := 2
const MAX_CITY_INTERIOR_VERTS_PER_CHUNK := 320
const MAX_CITY_INTERIOR_TRIS_PER_CHUNK := 240
const MAX_CITY_INTERIOR_DOORS_PER_CHUNK := 6
const MAX_CITY_INTERIOR_STATIONS_PER_CHUNK := 4
const CITY_INTERIOR_LIFT_M := 0.01
const COL_CITY_INTERIOR_WALL := Color("a8a090")
const COL_CITY_INTERIOR_WALL_ALT := Color("b5aca0")
const COL_CITY_BED := Color("9e8b6a")
const COL_CITY_TABLE := Color("7a6a5a")
const COL_CITY_SHELF := Color("6b5a4a")
const CITY_FURNITURE_SIZE_BED := Vector3(1.8, 0.4, 0.9)
const CITY_FURNITURE_SIZE_SHELF := Vector3(0.9, 0.9, 0.6)
const CITY_FURNITURE_SIZE_TABLE := Vector3(0.9, 0.7, 0.9)
const CITY_STATION_SIZE_BED := Vector3(1.8, 0.4, 0.9)
const CITY_STATION_SIZE_COUNTER := Vector3(0.9, 0.9, 0.6)
# City interior budgets additive to base city mesh (base typ 1180/2240, capped 1500/2480)
const MAX_CITY_VERTS_BASE := 1180
const MAX_CITY_TRIS_BASE := 2240
const MAX_CITY_VERTS_WITH_INTERIOR := 1500
const MAX_CITY_TRIS_WITH_INTERIOR := 2480
const MAX_CITY_INTERIOR_ROOMS_PER_CHUNK := 12
const CITY_INTERIOR_ROOMS_MIN := 3
const CITY_INTERIOR_ROOMS_MAX := 4

# --- Asset Pipeline Opening (G9 M2) authoritative numerics — single wall_2m probe ---
# Fallback policy: missing file → vertex-colored box a8a090 (COL_CITY_INTERIOR_WALL / COL_ASSET_FALLBACK).
# Scale/collision policy: scale 1.0, visual only unless has_collision true (this slice false, 0 collider, keeps 54 peak).
# Caps: at most 4 meshes per chunk, rest fallback to box, slice ≤2ms within FRAME_BUDGET_MS 12.
const ASSET_CATEGORIES: Array[StringName] = [&"wall", &"roof", &"door", &"prop"]
const ASSET_VOCAB_WALL_2M: StringName = &"wall_2m"
const ASSET_MODULES_PATH: String = "res://art/modules/"
const COL_ASSET_FALLBACK: Color = Color("a8a090")
const ASSET_FALLBACK_COLOR_WALL: Color = Color("a8a090")
const ASSET_SCALE_DEFAULT: float = 1.0
const ASSET_HAS_COLLISION_DEFAULT: bool = false
const MAX_ASSET_RESOLVES_PER_CHUNK: int = 4
const ASSET_LIFT_M: float = 0.01
const ASSET_CATALOG_VERSION: int = 1

# --- Settlement Society Work Schedule (G9 M3) authoritative numerics — hamlet worker 06:00-18:00 at workbench/granary/field ---
# Deterministic work schedule overlay: each hamlet gets 0-1 worker (never village this slice) assigned to nearest
# workbench / granary / field parcel within SOCIETY_WORK_RADIUS_M. Shift 06:00-18:00 via GameClock.total_minutes % 1440,
# hunger/fatigue gates 70 override work, travel speed 2.2 no teleport. Pure, no collider, no persistence of position.
const SOCIETY_WORK_START_MIN := 360 # 06:00 inclusive
const SOCIETY_WORK_END_MIN := 1080 # 18:00 exclusive
const SOCIETY_WORK_RADIUS_M := 90.0
const SOCIETY_HUNGER_WORK_THRESHOLD := 70.0
const SOCIETY_FATIGUE_WORK_THRESHOLD := 70.0
const SOCIETY_WORK_SPEED := 2.2
const SOCIETY_MAX_WORKERS_PER_HAMLET := 1
const SOCIETY_MAX_WORKERS_PER_VILLAGE := 0 # bounded slice: villages 0, hamlets 1
const SOCIETY_WORKER_ARRIVE_DISTANCE := 1.8 # stop working within this radius of work_pos
const SOCIETY_DOMAINS: Array[StringName] = [&"society_work", &"society_work_site"]

# --- Industrial Corridor (G8 M2) authoritative numerics ---
const BIOME_VOCAB: Array[StringName] = [&"urban_basin", &"river_floodplain", &"wet_meadow", &"arable_field", &"pasture_orchard", &"pasture", &"orchard", &"deciduous_forest", &"mixed_upland_forest", &"rocky_quarry", &"industrial_corridor"]
const INDUSTRIAL_CORRIDOR_VOCAB: Array[StringName] = [&"industrial_corridor"]
const INDUSTRIAL_ROAD_DISTANCE_MAX := 80.0
const INDUSTRIAL_QUARRY_SUITABILITY_MIN := 0.52
const INDUSTRIAL_SLOPE_MAX_DEG := 22.0
const INDUSTRIAL_MIN_PARCEL_M := 48.0
const INDUSTRIAL_CORRIDOR_LIFT_M := 0.03
const COL_INDUSTRIAL_CORRIDOR := Color("7a6a6a")
const COL_INDUSTRIAL_DARK := Color("5e5850")
const INDUSTRIAL_PALETTE_VARIANT := 0.08
const INDUSTRIAL_ROAD_SETBACK := 0.0
const INDUSTRIAL_BUILDING_GAP := 4.0
const MAX_INDUSTRIAL_INSTANCES := 6
const INDUSTRIAL_CORRIDOR_DENSITY_CELL := 480.0
const INDUSTRIAL_CORRIDOR_DENSITY_THRESHOLD := 0.48

# --- Biome & Geology (P3.1) authoritative numerics ---
const GEOLOGY_STRATA_VOCAB: Array[StringName] = [&"alluvial", &"loess", &"limestone", &"sandstone", &"granite_like"]
const GEOLOGY_SOIL_VOCAB: Array[StringName] = [&"alluvial_soil", &"loess_soil", &"limestone_soil", &"sandstone_soil", &"granite_soil"]
const WATER_DISTRICT_HINTS: Array[StringName] = [&"urban_basin", &"rural_plateau", &"river_valley"]
const GEOLOGY_CELL := 700.0
const GEOLOGY_RIDGE_CELL := 380.0
const SOIL_CELL := 220.0
const BIOME_MOISTURE_CELL := 360.0
const BIOME_TEMP_CELL := 520.0
const BIOME_FOREST_FIELD_CELL := 420.0
const BIOME_FIELD_EDGE_CELL := 180.0
const BIOME_ORCHARD_CELL := 300.0
const BIOME_DENSITY_CELL := 180.0
const BIOME_MOISTURE_WET_MEADOW_THRESHOLD := 0.62
const BIOME_FOREST_FIELD_THRESHOLD := 0.52
const BIOME_FERTILITY_ARABLE_MIN := 0.55
const BIOME_FERTILITY_PASTURE_MIN := 0.42
const BIOME_DENSITY_FOREST_MIN := 0.48
const FOREST_ART_CANDIDATE_SPACING := 13.0
const FOREST_ART_MIN_SPACING := 8.5
const FOREST_ART_MAX_SLOPE_DEG := 30.0
const FOREST_CLEARING_CELL_M := 96.0
const FOREST_CLEARING_MIN := 0.28
const BIOME_TREE_LIFT_M := 0.04
const BIOME_ORCHARD_THRESHOLD := 0.55
const QUARRY_SUITABILITY_THRESHOLD := 0.72
const QUARRY_SLOPE_MIN_DEG := 28.0
const ARABLE_MAX_SLOPE_DEG := 12.0
const PASTURE_MAX_SLOPE_DEG := 14.0
const BIOME_OVERLAY_RESOLUTION := 9
const BIOME_OVERLAY_VERTS := 81
const BIOME_OVERLAY_TRIS_MAX := 128
const BIOME_OVERLAY_LIFT_M := 0.03
const BIOME_INSTANCE_CAP_FOREST := 48
const BIOME_INSTANCE_CAP_FIELD := 12
const BIOME_INSTANCE_CAP_QUARRY := 6
const MAX_BIOME_INSTANCES_PER_CHUNK := 48

static func is_inside_world(p: Vector2) -> bool:
	return p.x >= WORLD_MIN_M and p.x < WORLD_MAX_M and p.y >= WORLD_MIN_M and p.y < WORLD_MAX_M

static func footprint_inside_world(origin: Vector2, footprint: Vector2) -> bool:
	var rect := Rect2(origin - footprint * 0.5, footprint)
	return rect.position.x >= WORLD_MIN_M and rect.end.x <= WORLD_MAX_M and rect.position.y >= WORLD_MIN_M and rect.end.y <= WORLD_MAX_M
