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

# --- World IDs & vocabulary ---
const TERRAIN_CLASSES: Array[StringName] = [&"basin", &"rolling_hill", &"upland", &"cliff"]
const SURFACE_MATERIALS: Array[StringName] = [&"alluvial_soil", &"meadow_soil", &"upland_grass", &"rock"]
const WATER_BODIES: Array[StringName] = [&"sea", &"lake", &"river", &"reservoir"]  # named only; no sea generated in P2

static func is_inside_world(p: Vector2) -> bool:
	return p.x >= WORLD_MIN_M and p.x < WORLD_MAX_M and p.y >= WORLD_MIN_M and p.y < WORLD_MAX_M

static func footprint_inside_world(origin: Vector2, footprint: Vector2) -> bool:
	var rect := Rect2(origin - footprint * 0.5, footprint)
	return rect.position.x >= WORLD_MIN_M and rect.end.x <= WORLD_MAX_M and rect.position.y >= WORLD_MIN_M and rect.end.y <= WORLD_MAX_M
