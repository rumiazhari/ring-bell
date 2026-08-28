# World Coordinate Contract

Authoritative contract for Ring Bell macro-world coordinates. The
single source of numeric constants is `world/generation/world_constants.gd`.

## 1. Axes and units

- Units are meters.
- X and Z are horizontal world coordinates; Y is elevation.
- `Vector2` plan points are always `(x, z)` in **world space**, never chunk-local.
  Example: `Vector2(128, -64)` means world X=128 m, world Z=-64 m.
- Chunk-local coordinates never appear in plan APIs; builders convert via `chunk_rect`.

## 2. Partition scales

| Partition | Size | Purpose |
|---|---|---|
| Simulation/render chunk | 64 m (`CHUNK_SIZE_M`) | streaming, physics, mesh batching |
| Landscape cell | 256 m (`LANDSCAPE_CELL_M`) | terrain field lattice |
| Macro cell | 1024 m (`MACRO_CELL_M`) | future settlement/biome regions |

These are coordinate partitions, not independent random worlds.

## 3. Origin and bounds

- World origin `(0,0)` is the Prague-basin reference origin (city center).
- Initial bounded playable world: 16 km x 16 km = `[-8192, 8192)` on both X and Z.
- Queries outside the boundary are legal (future expansion) but `is_buildable` rejects them and materialization outside is not part of the initial boundary.
- Edge handling is deterministic; no sea is generated in this slice.
- Example inside: `Vector2(8191, 0)` is inside; `Vector2(8192, 0)` is outside.

## 4. Vertical datums (Y, meters)

| Datum | Value | Notes |
|---|---|---|
| `terrain_y` | sampled per `(x,z)` in `[-12, 120]` | `TerrainPlan.height_at` |
| `water_level` | -2.0 | hydrology datum (no water in P2) |
| `building_ground_y` | `terrain_y` at footprint center | per-building derived |
| `lower_city_y` | -15.0 | future underground network top |
| `upper_civilization_y` | 120.0 | future upper network floor |
| `sky_dressing` | 500.0 | visual only |

This slice defines datums without materializing water, underground, or upper-city geometry.

## 5. Determinism and ownership

- Plans (`CityPlan`, `TerrainPlan`, `WorldPlan`) are **pure**: no Node/scene access, no unseeded randomness, no chunk-local state.
- Chunks (`ChunkBuilder`, `ChunkManager`, `MeshBatcher`) materialize plan data; only they create nodes/meshes/collision.
- Every terrain query is a function of explicit seed + world coordinates; chunk build order, query order, and worker scheduling cannot change results.
- Stable IDs use domain + world coordinates/region identity; `GENERATOR_VERSION` remains 2 in P2.

## 6. Stable IDs and versions

- Building IDs: `b_<cell>_<edge><k>` (existing CityPlan, unchanged).
- Terrain has no per-sample persistent ID; cells are identified by world coordinate.
- `WORLD_SCHEMA_VERSION = 1`; `GENERATOR_VERSION = 2` (unchanged — terrain is additive).

## 7. Setting and continental decision

- Setting: continental Prague/Czech-inspired basin. Schema may name `sea|lake|river|reservoir`, but **no sea is generated** in the initial 16 km world — the Czech basin is landlocked. Future hydrology will place Vltava-like river, tributaries, lakes/reservoirs only.

## 8. Slope, class, and buildability

- Slope is in **degrees** derived from `normal_at` / finite differences.
- `CLIFF_SLOPE_DEG = 35°` → `terrain_class = cliff`; `BUILDABLE_MAX_SLOPE_DEG = 22°`.
- Classes: `basin | rolling_hill | upland | cliff`; materials: `alluvial_soil | meadow_soil | upland_grass | rock`.
- `is_buildable` rejects out-of-bounds origins/footprints and footprints whose sampled slope exceeds the threshold (configurable via `constraints`).
- Class height thresholds: `TERRAIN_ROLLING_HEIGHT_M = 10.0` -> rolling_hill, `TERRAIN_UPLAND_HEIGHT_M = 38.0` -> upland (below 10 = basin; cliff overrides height via slope). Authoritative values live in `WorldConstants`.

## 9. Sampling contract

- Stateless lattice sampling with floor-based indexing and smoothstep interpolation; continuous at lattice and chunk boundaries within `SEAM_CONTINUITY_TOL_M`.
- Domain-separated (terrain, ridge, valley, soil, moisture, temperature, geology, settlement); no RNG sharing between queries; never uses `String.hash()`, time, scene state, or visit order.
