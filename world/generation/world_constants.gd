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
# WorldPlan is the only owner of the outdoor Y datum. CityPlan's historic
# market approach uses a local terrace; the larger urban fabric is grounded
# through WorldPlan's realized surface instead of creating a second terrain.
const URBAN_INNER_M := 350.0
const URBAN_OUTER_M := 600.0
const URBAN_CITY_TERRACE_Y := 0.0
## Only the market approach retains a level civic datum. The rest of the
## historic district follows the basin through continuous grading.
const CITY_MARKET_TERRACE_RADIUS_M := 96.0
# Organic city morphology bounds. URBAN_INNER_M remains the land-use and
# rural-exclusion boundary, independent of the smaller civic grading pad.
const CITY_HISTORIC_RADIUS_M := 300.0
## Historic-core plot frontage floor. The Prague grammar allows narrow 6-15 m
## frontages (spec item 3); the generic city fabric assumes a 10 m lot. 6 m is
## still wider than the 4.7 m stair minimum, so narrow houses keep their stairs.
const CITY_HISTORIC_MIN_FRONTAGE_M := 6.0
## Parcel fitting floors. Frontage is preserved and depth yields first, so a deep
## parcel meeting a shallow or oblique block edge loses depth instead of facade.
## The fitter may yield this far; the ACCEPTED lot standard is separate (below) -
## a fitted lot shallower than the district standard is rejected by the gate.
const CITY_LOT_FIT_MIN_FRONTAGE_M := 10.0
const CITY_LOT_FIT_MIN_DEPTH_M := 10.0
## Accepted lot standard for the generic fabric (frontage floor, depth floor).
## The city's generated buildings must satisfy it - see --buildingrepairtest.
const CITY_LOT_MIN_DEPTH_M := 14.0
const CITY_DENSE_RADIUS_M := 820.0
const CITY_BLOCK_RADIUS_M := 930.0
const CITY_MATERIALIZATION_RADIUS_M := 980.0
const CITY_INFLUENCE_RADIUS_M := 1700.0
const CITY_ROAD_SAMPLE_M := 12.0
const CITY_ROAD_WIDTH_PRIMARY := 8.4
const CITY_ROAD_WIDTH_SECONDARY := 5.8
const CITY_ROAD_WIDTH_LOCAL := 3.6
const CITY_ROAD_WIDTH_ALLEY := 1.9
const CITY_ALLEY_WIDTH := 2.1
# G10-P2B-FIX2: parcel/surface realization policy. These values describe
# semantic urban space, not texture variation: road-side sidewalks, intentional
# courtyard/garden residuals, and the threshold for rejecting empty dense faces.
const CITY_SIDEWALK_DEPTH_M := 2.4
const CITY_COURTYARD_MIN_AREA_M2 := 36.0
const CITY_COURTYARD_MAX_SURFACE_AREA_M2 := 2400.0
const CITY_COURTYARD_MAX_REGIONS_PER_BLOCK := 4
const CITY_EMPTY_DENSE_BLOCK_MAX_AREA_M2 := 15000.0
const CITY_FRONTAGE_GAP_MAX_M := 1.2
# --- City greenery: the blank ground between the buildings gets real trees ---
# The city used to carry two kinds of greenery: `_park` blocks (TreeBuilder
# species) and a two-box proxy for the street-garden strips. The core has no
# park blocks at all, so in practice every city tree was a proxy cube and the
# wide paved pavements, courtyards and plaza rims - the city's blank space -
# stayed bare. These values plant the real species there instead. Density is
# bounded by the per-chunk geometry budget in debug/chunk_budget_test.gd, not
# by taste: one CITY-tier tree costs ~175 parts / 5.4k verts, so city planting
# uses the IMPOSTOR tier (~16 parts / 462 verts), which still carries a tapered
# trunk, limbs and clustered foliage rather than one cube.
const CITY_TREE_LATTICE_M := 7.0
const CITY_TREE_LATTICE_JITTER_M := 1.8
const CITY_TREE_WALL_CLEARANCE_M := 1.3
const CITY_TREE_KERB_CLEARANCE_M := 0.6
const CITY_TREE_DOOR_CLEARANCE_M := 2.6
const CITY_TREE_MIN_SPACING_M := 5.6
const CITY_TREE_MAX_PER_CHUNK := 40
## Box ceiling for the planting pass itself. The dense core chunk already spends
## ~27000 of the 30000 the chunk budget allows (debug/chunk_budget_test.gd), so
## the trees buy their coverage out of what is left rather than off the top.
const CITY_TREE_BOX_BUDGET := 2400
const CITY_TREE_BED_HALF_M := 1.5
const CITY_TREE_BED_LIFT_M := 0.03
const CITY_TREE_SCALE_MIN := 0.8
const CITY_TREE_SCALE_MAX := 1.1
const CITY_TREE_ALLEY_CLEARANCE_M := 1.0
# Garden strips are narrow, so their trees are small and scaled to the strip.
const CITY_GARDEN_TREE_SCALE_MIN := 0.5
const CITY_GARDEN_TREE_SCALE_MAX := 0.8
const CITY_GARDEN_TREE_CLEARANCE_M := 1.0
# Plaza trees stand in the band between the paved pedestrian interior and the
# square's edge, clear of the fountain and the market stalls.
const CITY_PLAZA_TREE_INNER := 0.7
const CITY_PLAZA_TREE_FOUNTAIN_CLEARANCE_M := 4.5
const SURFACE_SAMPLE_EPSILON_M := 0.5
const RIVER_BED_DEPTH_M := 2.5
const RIVER_BANK_FREEBOARD_M := 0.65
const RIVER_BANK_BLEND_M := 26.0
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
const ROAD_HIERARCHY_VOCAB: Array[StringName] = [&"primary", &"secondary", &"local", &"alley", &"track"]
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

# --- Rural settlement front-end realization (hamlet/village composition) ---
# Presentation budgets, not new simulation entities. Paths/dressing have no physics body; buildings/doors retain existing body/budget contracts.
const RURAL_PATH_MAIN_WIDTH := 2.8
const RURAL_PATH_HAMLET_WIDTH := 2.4
const RURAL_PATH_FOOT_WIDTH := 1.55
const RURAL_PATH_FOOT_HAMLET_WIDTH := 1.35
const RURAL_PATH_LIFT_M := 0.035
const RURAL_YARD_RADIUS_HAMLET := 10.0
const RURAL_YARD_RADIUS_VILLAGE := 13.0
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
const COL_RURAL_YARD := Color("5b8a42")
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
# Hearth shares furniture mesh vertices (24 verts /12 tris already counted), so MAX_RURAL 480/360 280/210 unchanged.
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
const COL_FIELD_WHEAT := Color("a18a4e")
const COL_FIELD_BARLEY := Color("789456")
const COL_FIELD_POTATO := Color("75634c")
const COL_FIELD_BEET := Color("6f965b")
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
const MAX_CAVE_VERTS_PER_CHUNK := 48 # 24 entrance +24 chamber (G10 M1), 0 collider
const MAX_CAVE_TRIS_PER_CHUNK := 24 # 12 entrance +12 chamber
const MAX_ACTIVE_CAVE_COLLIDERS := 0 # Area3D only, no collider counted toward 54 peak
const CAVE_ENTRANCE_SPACING_MIN := 32.0
const CAVE_ENTRANCE_BUILDING_GAP_MIN := 8.0
const CAVE_ENTRANCE_WELL_GAP_MIN := 8.0
const CAVE_ENTRANCE_FORAGE_GAP_MIN := 8.0
const CAVE_ENTRANCE_ROAD_SETBACK := 4.0
const CAVE_ENTRANCE_WATER_GAP := 11.0 # BANK_W 9 + 2
const CAVE_ENTRANCE_LIFT_M := 0.01
const QUARRY_SUITABILITY_CAVE_THRESHOLD := 0.72
const CAVE_SLOPE_MIN_DEG := 28.0
# --- Cave Chamber Proxy (G10 M1) authoritative numerics — 5x5x3 vault at entrance -2m ---
const CAVE_CHAMBER_VOCAB: Array[StringName] = [&"cave_chamber"]
const CAVE_CHAMBER_SIZE := Vector3(5, 3, 5)
const CAVE_CHAMBER_OFFSET := Vector3(0, -2, 0)
const CAVE_CHAMBER_LIFT_M := -2.0
const COL_CAVE_CHAMBER := Color("4a3a2a")
const CAVE_CHAMBER_COLOR := Color("4a3a2a")
const CAVE_CHAMBER_DARK := Color("3a2a1a")
const CAVE_CHAMBER_SPACING_MIN := 32.0
const CAVE_CHAMBER_ROAD_SETBACK := 4.0
const CAVE_CHAMBER_WATER_GAP := 11.0
const CAVE_CHAMBER_BUILDING_GAP_MIN := 8.0
const CAVE_CHAMBER_FOOTPRINT := Vector2(5, 5)
const CAVE_CHAMBER_HEIGHT := 3.0
const CAVE_CHAMBER_RADIUS := 2.5
const CAVE_CHAMBER_MAX_PER_CHUNK := 1
const CAVE_CHAMBER_SLOPE_MAX_DEG := 22.0
const MAX_CAVE_ENTRANCES_PER_CHUNK := 1
const MAX_CAVE_CHAMBERS_PER_CHUNK := 1
const MAX_CAVE_ENTRANCE_VERTS_PER_CHUNK := 24
const MAX_CAVE_ENTRANCE_TRIS_PER_CHUNK := 12
const MAX_CAVE_CHAMBER_VERTS_PER_CHUNK := 24
const MAX_CAVE_CHAMBER_TRIS_PER_CHUNK := 12

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
## Height of the picture rail above the storey floor. Single authority for the
## dollhouse cut line: interior plaster above it goes into the wall's cut layer
## (BuildingBuilder._interior_wall_box) and a door leaf is cut on the same line,
## so a cut wall and the leaf hung in it always lose the same band.
const PICTURE_RAIL_H := 1.05
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

# --- City Fringe Composition System (Part 1) authoritative numerics — Prague 1900 inner/outer/peri-urban transition 300-1200 m ---
# Four overlapping bands deformed by road proximity, terrain, water, noise; deterministic sparse landmarks; road surface transition; visual density via coherent built form.
const FRINGE_INNER_START_M := 300.0
const FRINGE_INNER_END_M := 550.0
const FRINGE_OUTER_START_M := 450.0
const FRINGE_OUTER_END_M := 800.0
const FRINGE_PERI_START_M := 650.0
const FRINGE_PERI_END_M := 1200.0
const FRINGE_MAX_M := 1300.0
const FRINGE_INNER_DENSITY_THRESHOLD := 0.52
const FRINGE_OUTER_DENSITY_THRESHOLD := 0.28
const FRINGE_PERI_DENSITY_THRESHOLD := 0.10
const FRINGE_DENSITY_NOISE_CELL := 280.0
const FRINGE_DENSITY_NOISE_AMPL := 0.32
const FRINGE_ROAD_INFLUENCE_M := 120.0
const FRINGE_ROAD_SETBACK_INNER := 3.0
const FRINGE_ROAD_SETBACK_OUTER := 4.5
const FRINGE_ROAD_SETBACK_PERI := 5.5
const FRINGE_SLOPE_MAX_DEG_INNER := 18.0
const FRINGE_SLOPE_MAX_DEG_OUTER := 22.0
const FRINGE_SLOPE_MAX_DEG_PERI := 22.0
const FRINGE_WATER_GAP := 11.0 # BANK 9 + 2
const FRINGE_BUILDING_GAP_INNER := 1.0
const FRINGE_BUILDING_GAP_OUTER := 6.0
const FRINGE_BUILDING_GAP_PERI := 10.0
const FRINGE_MAX_BUILDINGS_PER_CHUNK_INNER := 8
const FRINGE_MAX_BUILDINGS_PER_CHUNK_OUTER := 6
const FRINGE_MAX_BUILDINGS_PER_CHUNK_PERI := 4
const FRINGE_MAX_BUILDINGS_PER_CHUNK := 8
const FRINGE_MAX_VERTS_PER_CHUNK := 2800
const FRINGE_MAX_TRIS_PER_CHUNK := 3600
const FRINGE_MAX_VERTS_TYPICAL := 1600
const FRINGE_MAX_TRIS_TYPICAL := 2200
const FRINGE_OVERLAP_LIFT_M := 0.015
const FRINGE_ARCHETYPES: Array[StringName] = [&"worker_row_house", &"small_tenement", &"detached_cottage", &"workshop", &"warehouse", &"small_factory", &"industrial_shed", &"courtyard_house", &"roadside_inn", &"utility_building"]
const FRINGE_ARCHETYPE_FOOTPRINTS := {
	&"worker_row_house": [Vector2(6.5, 10.0), Vector2(8.5, 13.0)],
	&"small_tenement": [Vector2(9.0, 12.0), Vector2(11.5, 15.5)],
	&"detached_cottage": [Vector2(7.0, 8.5), Vector2(9.0, 11.0)],
	&"workshop": [Vector2(10.0, 9.0), Vector2(13.0, 12.5)],
	&"warehouse": [Vector2(14.0, 12.0), Vector2(18.0, 16.0)],
	&"small_factory": [Vector2(16.0, 14.0), Vector2(22.0, 18.0)],
	&"industrial_shed": [Vector2(12.0, 12.0), Vector2(16.0, 20.0)],
	&"courtyard_house": [Vector2(10.0, 10.0), Vector2(13.5, 13.5)],
	&"roadside_inn": [Vector2(10.0, 9.0), Vector2(12.5, 11.5)],
	&"utility_building": [Vector2(4.2, 5.0), Vector2(6.0, 7.0)],
}
const FRINGE_ARCHETYPE_FLOORS := {
	&"worker_row_house": Vector2i(2, 3),
	&"small_tenement": Vector2i(3, 4),
	&"detached_cottage": Vector2i(1, 2),
	&"workshop": Vector2i(1, 1),
	&"warehouse": Vector2i(1, 2),
	&"small_factory": Vector2i(2, 3),
	&"industrial_shed": Vector2i(1, 1),
	&"courtyard_house": Vector2i(1, 2),
	&"roadside_inn": Vector2i(2, 2),
	&"utility_building": Vector2i(1, 1),
}
const FRINGE_ARCHETYPE_FLOOR_H := {
	&"worker_row_house": 3.05,
	&"small_tenement": 3.15,
	&"detached_cottage": 3.0,
	&"workshop": 3.6,
	&"warehouse": 4.2,
	&"small_factory": 4.0,
	&"industrial_shed": 4.5,
	&"courtyard_house": 3.1,
	&"roadside_inn": 3.15,
	&"utility_building": 2.9,
}
const FRINGE_LANDMARK_VOCAB: Array[StringName] = [&"factory_compound", &"warehouse_yard", &"industrial_chimney", &"mill", &"large_workshop", &"brick_wall_lot", &"worker_court", &"market_garden", &"cemetery_edge", &"roadside_landmark_inn"]
const FRINGE_LANDMARK_DENSITY_THRESHOLD := 0.38
const FRINGE_LANDMARK_CHANCE := 0.18
const FRINGE_LANDMARK_SPACING_MIN := 180.0
const FRINGE_LANDMARK_MAX_PER_CHUNK := 1
const FRINGE_LANDMARK_SIZE_FACTORY := Vector2(36, 28)
const FRINGE_CHIMNEY_HEIGHT := 14.0
const FRINGE_WALL_HEIGHT := 2.2
const FRINGE_MAX_LANDMARK_VERTS_PER_CHUNK := 520
const FRINGE_MAX_LANDMARK_TRIS_PER_CHUNK := 360
const FRINGE_ROAD_SURFACE_BLEND_INNER := 0.0
const FRINGE_ROAD_SURFACE_BLEND_OUTER := 0.5
const FRINGE_ROAD_SURFACE_BLEND_PERI := 1.0
const FRINGE_WALL_FENCE_MAX_PER_CHUNK := 8
const FRINGE_DECOR_MAX_PER_CHUNK := 16
const FRINGE_TREE_MAX_PER_CHUNK := 12
const FRINGE_TREE_MIN_SPACING := 4.0
const FRINGE_TREE_ROAD_CLEARANCE := 3.0
const FRINGE_TREE_BUILDING_CLEARANCE := 4.0
const FRINGE_DRESSING_MAX_INSTANCES_PER_CHUNK := 48
const FRINGE_LANDMARK_MAX_VERTS := 520
const FRINGE_LANDMARK_MAX_TRIS := 360
const FRINGE_MAX_FRINGE_COLLIDERS_PER_CHUNK := 1
const FRINGE_MAX_ACTIVE_FRINGE_COLLIDERS := 9
const COL_FRINGE_WALL_BRICK := Color("8a3a2a")
const COL_FRINGE_FENCE_WOOD := Color("6b4b32")
const COL_FRINGE_YARD_DIRT := Color("8b7656")
const COL_ROAD_COBBLE := Color("7a7878")
const COL_ROAD_MIXED := Color("857a6b")
const COL_ROAD_DIRT_PACKED := Color("6e5d4b")
const COL_ROAD_DIRTY_STONE := Color("7d756a")

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

# --- G10-P1 Forest Vegetation Rebuild (typed vegetation, forest composition, lit pipeline) ---
# Placeholder BoxMesh forest has been removed. Typed vegetation groups provide
# genuinely distinct meshes/silhouettes per class, batched by type via MultiMesh.
# Budgets are raised intelligently: interior dense 56 trees + 20 bush + 18 grass + 4 log
# stays batched, total <=96 per forest interior chunk (edge/sparse lower). Countryside
# roadside/hedgerow/solitary remain restrained but visible. All rural vegetation uses
# lit StandardMaterial3D (vertex_color_use_as_albedo, roughness 0.85-1.0, Per-Pixel),
# never UNSHADED, matching city renderer stylized language.
const VEGETATION_VOCAB: Array[StringName] = [&"beech", &"oak", &"birch", &"spruce", &"sapling", &"bush", &"grass", &"log", &"leaf_litter", &"stone", &"dead_branch", &"hedgerow", &"roadside_shrub", &"solitary_oak"]
const FOREST_TREE_VOCAB: Array[StringName] = [&"beech", &"oak", &"birch", &"spruce"]
const FOREST_UNDERSTORY_VOCAB: Array[StringName] = [&"bush", &"grass", &"log", &"leaf_litter", &"stone", &"dead_branch", &"sapling"]
const COUNTRYSIDE_VOCAB: Array[StringName] = [&"hedgerow", &"roadside_shrub", &"solitary_oak"]
# Caps for typed groups — total per-chunk never exceeds MAX_BIOME_INSTANCES_PER_CHUNK (96)
const MAX_FOREST_TREES_PER_CHUNK := 56
const MAX_FOREST_SAPLING_PER_CHUNK := 12
const MAX_FOREST_BUSH_PER_CHUNK := 20
const MAX_FOREST_GRASS_PER_CHUNK := 18
const MAX_FOREST_LOG_PER_CHUNK := 4
const MAX_FOREST_LEAF_LITTER_PER_CHUNK := 8
const MAX_FOREST_STONE_PER_CHUNK := 4
const MAX_FOREST_DEAD_BRANCH_PER_CHUNK := 3
const MAX_UNDERSTORY_PER_CHUNK := 36 # bush+grass+log+floor dressing combined bound for dense interior
const MAX_COUNTRYSIDE_VEG_PER_CHUNK := 32 # field/hedge/roadside/solitary dressing; global biome cap remains 96
const MAX_FOREST_INSTANCES_PER_CHUNK := 96 # total forest+understory+floor budget for dense interior
# Per-chunk typed MultiMesh budget: tree families, understory, and floor dressing are separate groups.
const MAX_VEGETATION_MULTIMESH_PER_CHUNK := 24
# Geometry authoritative sizes — trunk/crown proportions tuned for Czech temperate silhouette
const TREE_TRUNK_RADIUS_BEECH := 0.22
const TREE_TRUNK_RADIUS_OAK := 0.26
const TREE_TRUNK_RADIUS_BIRCH := 0.18
const TREE_TRUNK_RADIUS_SPRUCE := 0.24
const TREE_TRUNK_HEIGHT_BEECH_MIN := 3.2
const TREE_TRUNK_HEIGHT_BEECH_MAX := 5.0
const TREE_TRUNK_HEIGHT_OAK_MIN := 3.0
const TREE_TRUNK_HEIGHT_OAK_MAX := 4.6
const TREE_TRUNK_HEIGHT_BIRCH_MIN := 3.8
const TREE_TRUNK_HEIGHT_BIRCH_MAX := 5.6
const TREE_TRUNK_HEIGHT_SPRUCE_MIN := 4.2
const TREE_TRUNK_HEIGHT_SPRUCE_MAX := 6.5
const TREE_CANOPY_RADIUS_BEECH := 1.9
const TREE_CANOPY_RADIUS_OAK := 2.2
const TREE_CANOPY_RADIUS_BIRCH := 1.4
const TREE_CANOPY_RADIUS_SPRUCE_BASE := 1.5
const TREE_SCALE_MIN := 0.92
const TREE_SCALE_MAX := 1.58
const BUSH_SIZE_MIN := 0.90
const BUSH_SIZE_MAX := 1.80
const GRASS_CLUMP_SIZE := 0.72
const LOG_LENGTH := 3.8
const LOG_RADIUS := 0.34
const FOREST_TREE_MIN_SPACING := 2.35
const FOREST_UNDERSTORY_MIN_SPACING := 1.6
const FOREST_FLOOR_LIFT_M := 0.02
const FOREST_UNDERSTORY_LIFT_M := 0.10
const FOREST_CLEARING_PROBABILITY := 0.07
const FOREST_EDGE_FALLOFF_RADIUS := 18.0
const COUNTRYSIDE_ROADSIDE_INTERVAL := 12.0
const COUNTRYSIDE_SOLITARY_CHANCE := 0.18
# Lit pipeline: rural vegetation must NOT use SHADING_MODE_UNSHADED. Matches city StandardMaterial3D
# vertex_color_use_as_albedo true, roughness 0.85-1.0, metallic 0, shading Per-Pixel, cull disabled for foliage.
const VEGETATION_MATERIAL_ROUGHNESS := 0.85
const VEGETATION_SHADING_MODE := 0 # BaseMaterial3D.SHADING_MODE_PER_PIXEL (0), not UNSHADED (2)
const VEGETATION_TRUNK_ROUGHNESS := 0.92
const COL_FOREST_CANOPY_BEECH := Color("3a6b2a")
const COL_FOREST_CANOPY_BEECH_ALT := Color("4a7a30")
const COL_FOREST_CANOPY_OAK := Color("345a1e")
const COL_FOREST_CANOPY_OAK_ALT := Color("3d6b24")
const COL_FOREST_CANOPY_BIRCH := Color("5a8a3e")
const COL_FOREST_CANOPY_BIRCH_ALT := Color("6a9a4a")
const COL_FOREST_CANOPY_SPRUCE := Color("2a4a2a")
const COL_FOREST_CANOPY_SPRUCE_ALT := Color("2f5a30")
const COL_FOREST_TRUNK_BEECH := Color("5e4a32")
const COL_FOREST_TRUNK_OAK := Color("5a402c")
const COL_FOREST_TRUNK_BIRCH := Color("7a6a55")
const COL_FOREST_TRUNK_SPRUCE := Color("4a3a2a")
const COL_FOREST_BUSH := Color("6f9138")
const COL_FOREST_BUSH_ALT := Color("8aa74a")
const COL_FOREST_GRASS := Color("9abf50")
const COL_FOREST_GRASS_ALT := Color("b9d865")
const COL_FOREST_LOG := Color("5c4a32")
const COL_FOREST_LOG_DARK := Color("3e352a")
const COL_FOREST_FLOOR_LITTER := Color("3a3d2a")
const COL_FOREST_FLOOR_GRASS := Color("3e5a2a")
# Biome & Geology (P3.1) authoritative numerics (preserved for test compatibility — instance caps raised for visual density)
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
const BIOME_ORCHARD_THRESHOLD := 0.55
const QUARRY_SUITABILITY_THRESHOLD := 0.72
const QUARRY_SLOPE_MIN_DEG := 28.0
const ARABLE_MAX_SLOPE_DEG := 12.0
const PASTURE_MAX_SLOPE_DEG := 14.0
const BIOME_OVERLAY_RESOLUTION := 9
const BIOME_OVERLAY_VERTS := 81
const BIOME_OVERLAY_TRIS_MAX := 128
const BIOME_OVERLAY_LIFT_M := 0.03
const BIOME_INSTANCE_CAP_FOREST := 56 # raised from 48 to support dense interior + edge sapling (was placeholder budget)
const BIOME_INSTANCE_CAP_FIELD := 12
const BIOME_INSTANCE_CAP_QUARRY := 6
const MAX_BIOME_INSTANCES_PER_CHUNK := 96 # raised from 48 to accommodate typed forest + understory + countryside without sacrificing density (verified 96 peak, still batched)

# --- Universal Building Contract (G10-P2A) authoritative numerics ---
const BUILDING_CONTRACT_VERSION := "1.0.0"
const BUILDING_QUALITY_FULL_BUILDING := &"FULL_BUILDING"
const BUILDING_QUALITY_DISTANT_LOD := &"DISTANT_LOD"
const BUILDING_QUALITY_PROP_STRUCTURE := &"PROP_STRUCTURE"
const BUILDING_QUALITIES: Array[StringName] = [
	BUILDING_QUALITY_FULL_BUILDING, BUILDING_QUALITY_DISTANT_LOD,
	BUILDING_QUALITY_PROP_STRUCTURE,
]
## Minimum footprint area (m^2) a FULL_BUILDING may claim.
const CONTRACT_MIN_FOOTPRINT_AREA_M2 := 12.0
## Minimum footprint side (m) either axis.
const CONTRACT_MIN_FOOTPRINT_SIDE_M := 2.5
const CONTRACT_FLOOR_H_MIN := 2.2
const CONTRACT_FLOOR_H_MAX := 4.6
const CONTRACT_MAX_FLOORS := 8
## Door aperture human-scale band (m).
const CONTRACT_DOOR_W_MIN := 0.8
const CONTRACT_DOOR_W_MAX := 2.0
const CONTRACT_DOOR_H_MIN := 1.9
const CONTRACT_DOOR_H_MAX := 2.8

## Door widths are KIND-BASED (locked decision 2). This table is the single
## authority: the aperture, the leaf, the frame, the collider and the
## player-capsule clearance all read it, so no module may invent its own width.
## Values sit inside CONTRACT_DOOR_W_MIN..MAX on purpose - the historical
## 2.6 m carriage-passage entrance was outside human scale.
const DOOR_W_PERSON := 1.05       # residential / historic single leaf
const DOOR_W_SERVICE := 0.95      # service door, interior partition, cellar
const DOOR_W_RETAIL := 1.2        # shop door with glazing
const DOOR_W_GRAND := 1.7         # intentional double / industrial leaf pair
const DOOR_H_PERSON := 2.2
const DOOR_H_SERVICE := 2.1
const DOOR_H_RETAIL := 2.35
const DOOR_H_GRAND := 2.5
const DOOR_KIND_W := {
	&"person": DOOR_W_PERSON,
	&"service": DOOR_W_SERVICE,
	&"retail": DOOR_W_RETAIL,
	&"grand": DOOR_W_GRAND,
}
## Height follows the same kind: a grand opening is a tall carriage arch, not a
## scaled-up person door.
const DOOR_KIND_H := {
	&"person": DOOR_H_PERSON,
	&"service": DOOR_H_SERVICE,
	&"retail": DOOR_H_RETAIL,
	&"grand": DOOR_H_GRAND,
}


## Width in metres for a door kind. Unknown kinds fall back to the person door
## rather than silently becoming a random extra-wide opening.
static func door_kind_width(kind: StringName) -> float:
	return float(DOOR_KIND_W.get(kind, DOOR_KIND_W[&"person"]))


static func door_kind_height(kind: StringName) -> float:
	return float(DOOR_KIND_H.get(kind, DOOR_KIND_H[&"person"]))


## The door kind a generated building entrance should use. A Prague house with a
## carriage passage needs the one wide opening (grand); a shop front gets glass,
## a back/service entrance stays narrow.
static func door_kind_for_entrance(use: String, has_passage: bool,
		frontage_m: float, service: bool = false) -> StringName:
	if service:
		return &"service"
	if has_passage and frontage_m >= 9.0:
		return &"grand"
	match use:
		"retail", "shop", "workshop":
			return &"retail"
		"tavern":
			return &"grand"
	return &"person"
## Window aperture human-scale band (m).
const CONTRACT_WIN_W_MIN := 0.6
const CONTRACT_WIN_W_MAX := 1.6
const CONTRACT_WIN_H_MIN := 0.6
const CONTRACT_WIN_H_MAX := 1.6
## Grounding tolerance: lowest structural geometry may sit this far below
## the world surface (slab burial), never higher above it.
const CONTRACT_GROUND_BURY_TOL_M := 1.2
const CONTRACT_GROUND_FLOAT_TOL_M := 0.35
## Aperture clearance epsilon when scanning batcher colliders (m).
const CONTRACT_APERTURE_CLEAR_M := 0.35
## Rural contract house storey height (m) — matches legacy rural 4.2 slab.
const RURAL_CONTRACT_FLOOR_H := 4.2
const RURAL_CONTRACT_WALL_T := 0.18
const RURAL_CONTRACT_SLAB_T := 0.22
const RURAL_CONTRACT_DOOR_W := 1.0
const RURAL_CONTRACT_DOOR_H := 2.1
const RURAL_CONTRACT_WIN_W := 1.05
const RURAL_CONTRACT_WIN_H := 0.82
const RURAL_CONTRACT_WIN_SILL := 1.15
const RURAL_CONTRACT_SECOND_WIN_W := 0.72
const RURAL_CONTRACT_SECOND_WIN_H := 0.72
## Pillar/wall module target (m) — vertical courses stay full storey, same
## compromise as the city builder; keeps collider counts linear.
const CONTRACT_WALL_CELL := 1.25

## --- Universal site envelope contract (G10-P2C) --------------------------
## A plot's outdoor envelope: yard surface, fence loop with gates, trees.
## Same WHAT/HOW split as buildings: SitePlan decides, a site builder draws.
##
## Minimum yard share of a plot: below this the ground is not an outdoor room.
const SITE_MIN_YARD_FRACTION := 0.25
## Smallest yard that may carry a fence, gates and trees (m2).
const SITE_MIN_YARD_AREA_M2 := 24.0
## Smallest plot a site may be generated for (m2) — below this it is a gap.
const SITE_MIN_PLOT_AREA_M2 := 20.0
## Fence height band (m) — human scale, same authority as building walls.
const SITE_MIN_FENCE_H := 0.75
const SITE_MAX_FENCE_H := 2.6
## Post spacing ceiling (m): beyond this a rail spans unsupported and reads
## as floating geometry.
const SITE_MAX_POST_SPACING := 3.5
## Posts also have a floor, or the fence is a solid low wall with no rhythm.
const SITE_MIN_POST_SPACING := 0.8
## Gate width band (m) and how close a gate must sit to the doorway it serves.
const SITE_MIN_GATE_W := 1.0
const SITE_MAX_GATE_W := 4.0
const SITE_GATE_ALIGN_M := 3.0
## Grounding authority for fence lines and tree roots (m), as buildings.
const SITE_GROUND_TOL_M := 1.0
## Tree placement: crown radius from species r_max, clearances (m).
const SITE_TREE_RADIUS_FACTOR := 0.5
const SITE_TREE_BUILDING_CLEAR_M := 1.5
const SITE_TREE_TREE_CLEAR_M := 2.0
const SITE_TREE_AREA_PER_TREE_M2 := 45.0
const SITE_MAX_TREES_PER_SITE := 6
## Fence loop must come within this of closing, measured in perimeter (m).
const SITE_FENCE_CLOSE_TOL_M := 0.25
## Per-rect ceilings so the fence/tree layer cannot blow the chunk budget.
const SITE_MAX_PER_RECT := 12
const SITE_MAX_TREES_PER_RECT := 24
## Fence collision stays linear in perimeter: one collider per this length (m).
const SITE_FENCE_COLLIDER_MODULE_M := 2.5

static func is_inside_world(p: Vector2) -> bool:
	return p.x >= WORLD_MIN_M and p.x < WORLD_MAX_M and p.y >= WORLD_MIN_M and p.y < WORLD_MAX_M

static func footprint_inside_world(origin: Vector2, footprint: Vector2) -> bool:
	var rect := Rect2(origin - footprint * 0.5, footprint)
	return rect.position.x >= WORLD_MIN_M and rect.end.x <= WORLD_MAX_M and rect.position.y >= WORLD_MIN_M and rect.end.y <= WORLD_MAX_M
