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
# --- Urban compatibility (authoritative, shared across terrain/water/biome) ---
const URBAN_INNER_M := 350.0
const URBAN_OUTER_M := 600.0
const FRAME_BUDGET_MS := 12.0

# --- World IDs & vocabulary ---
const TERRAIN_CLASSES: Array[StringName] = [&"basin", &"rolling_hill", &"upland", &"cliff"]
const SURFACE_MATERIALS: Array[StringName] = [&"alluvial_soil", &"meadow_soil", &"upland_grass", &"rock"]
const WATER_BODIES: Array[StringName] = [&"sea", &"lake", &"river", &"reservoir"]  # named only; sea not generated in continental Prague basin

# --- Biome & Geology (P3.1) authoritative numerics ---
const BIOME_VOCAB: Array[StringName] = [&"urban_basin", &"river_floodplain", &"wet_meadow", &"arable_field", &"pasture_orchard", &"pasture", &"orchard", &"deciduous_forest", &"mixed_upland_forest", &"rocky_quarry"]
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
const BIOME_INSTANCE_CAP_FOREST := 48
const BIOME_INSTANCE_CAP_FIELD := 12
const BIOME_INSTANCE_CAP_QUARRY := 6
const MAX_BIOME_INSTANCES_PER_CHUNK := 48

static func is_inside_world(p: Vector2) -> bool:
	return p.x >= WORLD_MIN_M and p.x < WORLD_MAX_M and p.y >= WORLD_MIN_M and p.y < WORLD_MAX_M

static func footprint_inside_world(origin: Vector2, footprint: Vector2) -> bool:
	var rect := Rect2(origin - footprint * 0.5, footprint)
	return rect.position.x >= WORLD_MIN_M and rect.end.x <= WORLD_MAX_M and rect.position.y >= WORLD_MIN_M and rect.end.y <= WORLD_MAX_M
