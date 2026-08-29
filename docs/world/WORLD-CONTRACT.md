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
| `water_level` | `-1.2 +-0.6` mean/variation along flow axis | `HydrologyPlan.water_level_at`; datum `WATER_LEVEL_Y=-2.0` retained as legacy reference |
| `building_ground_y` | `terrain_y` at footprint center | per-building derived |
| `lower_city_y` | -15.0 | future underground network top |
| `upper_civilization_y` | 120.0 | future upper network floor |
| `sky_dressing` | 500.0 | visual only |

Water surface Y is deterministic per world `z` via `WATER_LEVEL_MEAN + WATER_LEVEL_VAR * sample_coherent_signed(Vector2(0,z), hydro_level, 800)` and is constant across width within a chunk; tributaries subtract `TRIB_FALL_SLOPE * (Cz - z)` northward fall.

## 5. Determinism and ownership
- Plans (`CityPlan`, `TerrainPlan`, `HydrologyPlan`, `GeologyPlan`, `BiomePlan`, `SettlementPlan`, `RoadNetworkPlan`, `WorldPlan`) are **pure**: no Node/scene access, no unseeded randomness, no chunk-local state.
- Chunks (`ChunkBuilder`, `ChunkManager`, `MeshBatcher`, `TerrainChunkBuilder`, `WaterChunkBuilder`, `BiomeChunkBuilder`, `RoadChunkBuilder`) materialize plan data; only they create nodes/meshes/collision.
- Every terrain, hydrology, biome, settlement and road query is a function of explicit seed + world coordinates via `WorldSeed.sample_coherent*` or `unit_float`; chunk build order, query order, and worker scheduling cannot change results.
- Stable IDs use domain + world coordinates/region identity; `GENERATOR_VERSION` remains 2 in P2, P2.2, P3.1 and P4.1 (settlement/road additive, outside dense core).
- `WorldSeed` domain separation: terrain/ridge/valley/soil/moisture/temperature/geology/settlement/hydro/hydro_cx/hydro_phi/hydro_meander2/hydro_width/hydro_level/hydro_trib_*/biome_*/geology_*/road/settlement_*/hydro_*.

## 6. Stable IDs and versions
- Building IDs: `b_<cell>_<edge><k>` (existing CityPlan, unchanged).
- Terrain has no per-sample persistent ID; cells are identified by world coordinate.
- Hydrology bodies: `river_main` and `trib_0`, `trib_1` via `water_body_id_at`; vocabulary subset of `WorldConstants.WATER_BODIES` (`sea|lake|river|reservoir`) plus empty dry.
- Settlement anchors: `settlement_<cx>_<cy>_<k>` plus `gate_<k>` plus `crossing_<id>` for road crossing nodes; road edges `edge_<a>_<b>` (lexicographic), villages 700/hamlet 420/farmstead 220 spacing.
- Road edges: `edge_<a>_<b>` with `hierarchy` primary/secondary/track, `is_bridge` true only at `crossing_candidates`.
- `WORLD_SCHEMA_VERSION = 1`; `GENERATOR_VERSION = 2` (unchanged — terrain, hydrology, biome, settlement, road are additive, not serialized).

## 7. Setting and continental decision
- Setting: continental Prague/Czech-inspired basin. Schema may name `sea|lake|river|reservoir`, but **no sea is generated** in the initial 16 km world — the Czech basin is landlocked. P2.2 hydrology places one deterministic Vltava-like primary river plus 2 tributaries east of the historic core; sea remains explicitly excluded. Future hydrology may add lakes/reservoirs only as placeholder vocabulary in this slice.
- The river is the first landscape-scale landmark beyond buildings and constrains future farms/roads/settlements and crossing choices.

## 8. Slope, class, and buildability
- Slope is in **degrees** derived from `normal_at` / finite differences.
- `CLIFF_SLOPE_DEG = 35°` → `terrain_class = cliff`; `BUILDABLE_MAX_SLOPE_DEG = 22°`.
- Classes: `basin | rolling_hill | upland | cliff`; materials: `alluvial_soil | meadow_soil | upland_grass | rock`.
- `is_buildable` rejects out-of-bounds origins/footprints and footprints whose sampled slope exceeds the threshold (configurable via `constraints`).
- Class height thresholds: `TERRAIN_ROLLING_HEIGHT_M = 10.0` -> rolling_hill, `TERRAIN_UPLAND_HEIGHT_M = 38.0` -> upland (below 10 = basin; cliff overrides height via slope). Authoritative values live in `WorldConstants`.
- No water is placed on cliff-class slopes or ridge hilltops except an explicit lake placeholder; `HydrologyPlan` floodplain check excludes cliff samples (sample 200 random points: any `slope >= CLIFF_SLOPE_DEG` and `terrain_class==cliff` is dry).

## 9. Sampling contract
- Stateless lattice sampling with floor-based indexing and smoothstep interpolation; continuous at lattice and chunk boundaries within `SEAM_CONTINUITY_TOL_M=0.02`.
- Domain-separated (terrain, ridge, valley, soil, moisture, temperature, geology, settlement, hydro, hydro_meander2, hydro_width, hydro_level, hydro_trib_*, biome_*, geology_*, road_*, settlement_*); no RNG sharing between queries; never uses `String.hash()`, time, scene state, or visit order.
- Negative world coordinates are fully supported via `floori` lattice indexing.
- Settlement/road domains: `settlement`, `settlement_field`, `settlement_jitter`, `settlement_gate_phi`, `road`, `road_mid`, `road_width`, `road_hierarchy` etc., seed-separated from terrain/hydro/geology/biome.

## 10. Terrain materialization (P2-TERRAIN-MATERIALIZATION)
- Chunk terrain manifest is 17x17 height samples per 64 m chunk (4 m spacing), world-space shared edges, deterministic for `(seed, coord)` via `TerrainChunkBuilder.build_manifest(WorldPlan, coord)`.
- Heights sampled from `TerrainPlan.height_at` then urban-compatibility masked; normals finite normalized; class/material per sample from masked height+slope (`basin/rolling_hill/upland/cliff` -> `alluvial_soil/meadow_soil/upland_grass/rock`, cliff forces rock).
- Manifest keys: `coord, origin, size, resolution=17, heights, normals, material_ids, class_ids, colors, indices, compatibility_mode, terrain_vertices/triangles/colliders/material_samples/gen_ms`.
- Materialization (`materialize(parent, manifest)`) creates one `TerrainMesh` + one `TerrainBody/ConcavePolygonShape` per chunk under `Terrain_X_Y`; mesh and collision share same X/Z extent.
- Collision budget: at most 1 collider per chunk; active 3x3 ring = 9 terrain colliders max. Vertices 289 / chunk, triangles 512 / chunk.
- Urban compatibility rule: deterministic radial mask centered at world origin — `URBAN_INNER_M=350` flat (height 0), transition `URBAN_OUTER_M=600` smoothstep to real terrain; owned by `TerrainChunkBuilder`; does not mutate `CityPlan`. Terrain height at any world point is `lerp(0, raw_height, smoothstep((d-350)/250))`.
- Ground ownership: flat city ground (`ChunkBuilder._ground`) is emitted only where the chunk rect is wholly inside `URBAN_INNER_M` (every corner distance < 350); any chunk that straddles the radius or lies beyond 350 emits no city flat box and is terrain-only, preventing any competing flat/terrain surfaces at the boundary. Beyond 600 m terrain is at full height.
- Terrain generation runs in the worker-safe data phase (`ChunkManager._thread_build`) with private `WorldPlan`; `terrain_gen_ms` measured inside worker, `terrain_mat_ms` on main thread; stats exposed via `ChunkManager` debug lines (`t_gen`, `t_mat`, `active terrain` filtered to ACTIVE state).
- Generator version remains 2; terrain is additive, not serialized in saves.

## 11. Hydrology slice P2.2 (Vltava-anchored river corridor)

### 11.1 Corridor, meander, width, level
- Primary corridor is deterministic from seed: mean center `CX = HYDRO_CORRIDOR_CX_MEAN 620 + S*HYDRO_CORRIDOR_JITTER 90` where `S = unit_float("hydro_cx")*2-1` so `CX 530-710 m` east of origin, clearly outside `URBAN_OUTER_M=600` for most length and never revisiting the spawn plaza.
- Meander `MX(z) = HYDRO_MEANDER_AMPL 72 * sin(z/HYDRO_MEANDER_WAVELENGTH 1350 + phi) + HYDRO_MEANDER2_AMPL 18 * sample_coherent_signed(Vector2(0,z), hydro_meander2, HYDRO_MEANDER2_CELL 600)`. `phi` seeded via `unit_float("hydro_phi") * TAU`. Keeps the river readable, out of the historic core, continuous across every 64 m chunk seam within `SEAM_CONTINUITY_TOL_M`.
- Width varies smoothly: `38 + 12 * sample_coherent(Vector2(0,z), hydro_width, HYDRO_WIDTH_CELL 900)` → `RIVER_WIDTH_MIN 38` to `RIVER_WIDTH_MAX 50` full width (19-25 half). Entrusted to `WorldConstants`.
- Water level `WATER_LEVEL_MEAN -1.2 +- WATER_LEVEL_VAR 0.6` along flow axis via `sample_coherent_signed(Vector2(0,z), hydro_level, WATER_LEVEL_CELL 800)`; constant across width within a chunk.
- Valley alignment: `HydrologyPlan` owns the river; `TerrainPlan` remains unchanged this cycle (valley depression at `x=-180` stays as small decorative bias, not forced to match the new `CX~620` corridor). `WaterChunkBuilder` visually spans banks/floodplain over existing terrain height; a full terrain trench carve through the basin is explicitly deferred.

### 11.2 Tributaries, banks, floodplain, flow
- `TRIB_COUNT = 2` seeded streams. Each anchor `Ax` outside corridor `CX ± (TRIB_ANCHOR_BASE_OFFSET 260 ± TRIB_ANCHOR_JITTER 80)`, upstream `Az ~ TRIB_UPSTREAM_BASE_Z -2200 + k*TRIB_UPSTREAM_STEP_Z 1400` plus seeded jitter `TRIB_UPSTREAM_JITTER_Z 320`, confluence `Cz` deterministically where the anchor line approaches the primary within 180 m (`Az + 900 +-200` and `cx = river_center_x_at(Cz)`). Centerline is a quadratic bezier anchor→mid→confluence, width `TRIBUTARY_WIDTH_MIN 14` to `TRIBUTARY_WIDTH_MAX 22`, mid jittered `+-30`. Water level inherits primary level minus `TRIB_FALL_SLOPE 0.015 * (Cz - z)` northward fall.
- Banks `BANK_W 9.0`, floodplain `FLOODPLAIN_W 26.0` (authoritative in `WorldConstants`). `is_floodplain(p)` when `abs(dist_to_center) in (half+BANK_W, half+BANK_W+FLOOD_W]` and `terrain_class != cliff`. Bank/floodplain distances are monotonic from center.
- Flow `flow_direction_at(p)` is unit length, northward `Vector2.y > 0.35` on the primary and `dot(tributary_flow, direction_to_confluence) > 0.45` for tributaries, using real `WorldConstants` thresholds.
- Sea is explicitly not generated in this continental basin slice; `WATER_BODIES` vocabulary remains `sea|lake|river|reservoir` but only `river`, `tributary`, and empty are materialized (lake placeholder allowed as vocabulary check only).
- No in-city river carving, no road bridges, no lakes/reservoirs beyond placeholder, no underground water, and no terrain-trench rework inside the 350 m historic core in this slice — all deferred.

### 11.3 Water chunk manifest and materialization
- Per-chunk manifest via `WaterChunkBuilder.build_manifest(WorldPlan, coord)` at **9x9 resolution** (81 samples at 8 m spacing over the 64 m rect; justified low-cost choice documented versus alternative 17x17 289/512). Keys: `coord, origin, size, resolution=9, heights (water Y per sample, NAN if dry), normals, material_ids (river|tributary|""), class_ids (water|dry), colors, indices, is_wet, water_vertices, water_triangles, water_colliders, has_water, water_gen_ms`. Deterministic for `(seed, coord)` and byte-identical across shuffled builds.
- Sampling uses world-space shared edges matching terrain's world-space edge handling so adjacent chunks agree on the centerline sampling within `SEAM_CONTINUITY_TOL_M 0.02` at both positive and negative boundaries.
- Visual `ArrayMesh` per wet chunk: vertices at `(x, water_y, z)` interpolated bilinearly across the wet polygon, clipped to chunk rect (water outside rect omitted). Vertex colors via `WorldConstants` water palette (muted Vltava teal `4a7a94`, tributary dark `3a5a74`). Indices share the same winding rule as terrain; bank ribbon along water edge is a 1.5 m visual color transition (no extra collider) to hide Z-fighting.
- Collision budget: at most **one `ConcavePolygonShape3D` per wet chunk** (`backface_collision=true`, on `environment` layer 1, `collision_mask 0`), `0` if dry. No per-sample or per-triangle bodies, no per-waypoint volumes. Wet chunk budget: **81 verts / <=128 tris / 1 collider**; dry chunk `0/0/0`. `water_mat_ms` measured per chunk on the main thread. ACTIVE 3x3 ring carries at most **9 active water colliders**.
- Urban compatibility: water manifests are generated for all chunks, but the primary corridor at `>530 m` keeps the spawn chunk `0,0` dry; no building footprint overlap check is required this slice. If any future in-city water would intersect a city block, that handling is explicitly deferred.

### 11.4 Streaming, telemetry, persistence, compatibility
- `ChunkManager` mirrors the terrain pipeline: new counters `_water_vertices_total/_water_triangles_total/_water_colliders_total/_water_mat_ms_total`, per-chunk record fields `water_vertices/water_triangles/water_colliders/water_manifest/layers_water`, stats keys `water_vertices/water_triangles/water_colliders` and timings `t_water_gen/t_water_mat` (measured inside worker via private `WorldPlan` and on main thread respectively). `holder["water"]` and `water_gen_ms` are measured inside `_thread_build`; `materialize` creates `Water_X_Y/WaterMesh/WaterBody` under `Chunk_X_Y` and measures `water_mat_ms`.
- ACTIVE-ring rule: water collider counted toward `active water` only when chunk state ACTIVE, analogous to terrain; warm retains visual `WaterMesh` but collision is disabled (`collision_layer=0`) if builder chooses active-only (documented as intentional budgeted optimization). At most 9 active water colliders (3x3).
- `ChunkManager.save_state()` persists only `seed/version/discovery/deltas` — never generated water geometry, vertices, or collision shapes. Hydrology manifests are deterministic from `seed+coord` and survive unload/reload of water chunks (same vertex/triangle/collider counts after regeneration). `WorldPlan` remains pure, `CityPlan` deterministic IDs unchanged, `GENERATOR_VERSION` stays 2; old saves follow the existing mismatch warning + regeneration path and never reinterpret water delta keys.
- `compatibility_mode` string is present on terrain manifests; water manifests carry `resolution` and `has_water` for forward compatibility. `WORLD_SCHEMA_VERSION` may be noted but `GENERATOR_VERSION` stays 2. No new autoload, project setting, or large asset import is authorized beyond the hydrology constants and water streaming stats already described.
- Telemetry: `ChunkManager.debug_lines()` exposes `water verts | tris | colliders | t_water_gen | t_water_mat | active water (warm)` alongside terrain and city lines; per-chunk `water_gen_ms`/`water_mat_ms` are reported and budgeted within `FRAME_BUDGET_MS 12.0` combined with city/terrain.
- Bank ribbon choice: 1.5 m earth bank ribbon remains a vertex-color transition without extra geometry as the budgeted choice for this slice, keeping 81 verts / <=128 tris / 1 collider wet-chunk budget. A narrow earth-geometry strip will be evaluated when/if terrain trench carve through the historic basin is designed (deferred truthfully, not silently omitted).

## 12. Biome & Geology slice P3.1 (Czech rural mosaic)

### 12.1 Vocab and constants (authoritative in `WorldConstants`)
- Biome vocab `BIOME_VOCAB`: `urban_basin`, `river_floodplain`, `wet_meadow`, `arable_field`, `pasture_orchard`, `pasture`, `orchard`, `deciduous_forest`, `mixed_upland_forest`, `rocky_quarry` (subset enforced).
- Geology strata vocab `GEOLOGY_STRATA_VOCAB`: `alluvial`, `loess`, `limestone`, `sandstone`, `granite_like`; soil vocab `GEOLOGY_SOIL_VOCAB`: `alluvial_soil`, `loess_soil`, `limestone_soil`, `sandstone_soil`, `granite_soil`.
- Cell sizes: `GEOLOGY_CELL 700`, `GEOLOGY_RIDGE_CELL 380`, `SOIL_CELL 220`, `BIOME_MOISTURE_CELL 360`, `BIOME_TEMP_CELL 520`, `BIOME_FOREST_FIELD_CELL 420`, `BIOME_FIELD_EDGE_CELL 180`, `BIOME_ORCHARD_CELL 300`, `BIOME_DENSITY_CELL 180`, `LANDSCAPE_CELL_M 256`, `MACRO_CELL_M 1024`.
- Thresholds: `BIOME_MOISTURE_WET_MEADOW_THRESHOLD 0.62`, `BIOME_FOREST_FIELD_THRESHOLD 0.52`, `BIOME_FERTILITY_ARABLE_MIN 0.55`, `BIOME_FERTILITY_PASTURE_MIN 0.42`, `BIOME_DENSITY_FOREST_MIN 0.48`, `BIOME_ORCHARD_THRESHOLD 0.55`, `QUARRY_SUITABILITY_THRESHOLD 0.72`, `QUARRY_SLOPE_MIN_DEG 28`, `ARABLE_MAX_SLOPE_DEG 12`, `PASTURE_MAX_SLOPE_DEG 14`, `BUILDABLE_MAX_SLOPE_DEG 22`, `CLIFF_SLOPE_DEG 35`, `TERRAIN_UPLAND_HEIGHT_M 38`.
- Budgets: overlay `BIOME_OVERLAY_RESOLUTION 9` -> `81 verts / <=128 tris` per chunk (9x9 at 8 m), lift `BIOME_OVERLAY_LIFT_M 0.03`, instance caps `BIOME_INSTANCE_CAP_FOREST 48` / `FIELD_EDGE 12` / `QUARRY 6` with global `MAX_BIOME_INSTANCES_PER_CHUNK 48` and at most 1 biome collider per chunk (0 if no forest/quarry), at most 9 active biome colliders (3x3), `FRAME_BUDGET_MS 12`.

### 12.2 Generation contract (macro 256 m contiguity, hydrology/slope/geology gates)
- GeologyPlan pure: strata, soil, quarry_suitability high on limestone/sandstone uplands and steep/cliff masks via high-frequency 48 m geology noise, fertility high on loess/alluvial, cave_potential deterministic. Bands are sample_coherent-driven not hard-coded per-chunk art; handles negative coords via floori; GENERATOR_VERSION stays 2.
- BiomePlan pure Czech mosaic reading TerrainPlan + HydrologyPlan + GeologyPlan plus moisture/temperature/density fields. Micro rules override macro: water/bank/floodplain -> river_floodplain, 0-16 m outside floodplain where moisture>0.62 and slope<22 and not cliff -> wet_meadow, within URBAN_INNER_M 350 -> urban_basin, quarry_suitability>0.72 and (slope>=28 or cliff or limestone upland >=15) -> rocky_quarry. Macro: forest_field blended with landscape tendency 256 m for contiguity >=256 m; forest_field>0.52 on suitable slope<35 biases forest belts, else fields/pasture. Mixed only on upland >=38. Contiguity rule ensures parcels >=1 landscape cell, transitions at most one-sample wide at 4-8 m; 40 probes along 512 m show run-length >=192 m with no speckling.

### 12.3 Biome chunk manifest and materialization (9x9 vs 17x17 justification)
- Per-chunk manifest via BiomeChunkBuilder.build_manifest at 9x9 resolution (81 samples at 8 m). Keys: coord, origin, size, resolution=9, biome_ids, material_ids, class_ids, colors, heights (terrain+0.03), indices, biome_gen_ms, density, instance_count, instances, has_forest, has_field, has_quarry, is_wet_margin, biome_vertices, biome_triangles, biome_colliders, biome_nodes. Deterministic byte-identical across shuffled builds. World-space shared edges, vocab agreement >=7/9.
- Visual ground overlay: vertices at (x, terrain_height+0.03, z), vertex colors = surface_tint_at, StandardMaterial vertex_color_use_as_albedo. 81/128 budgets. Instanced dressing: forest up to 1 tree per cell where density>0.48 capped 48/12, field hedgerow 1-2 Box proxies max 12, quarry 2-6 Box proxies per quarry chunk. Total <=48. At most one biome collider per chunk, ACTIVE-only, warm retains visuals but disables BiomeBody collision_layer 0. Clipping via footprint center, no duplication.

### 12.4 Streaming, telemetry, persistence, compatibility
- ChunkManager mirrors terrain/water pipeline: new counters biome verts/tris/colliders/instances and biome_gen/mat ms, holder biome and biome_gen_ms in thread_build, materialize creates Biome_X_Y/BiomeMesh/BiomeBody/BiomeMultimesh. ACTIVE-only biome physics, at most 9 active biome colliders (3x3). Per-chunk biome_gen_ms worker + biome_mat_ms main within FRAME_BUDGET_MS 12. Debug lines expose biome verts/tris/colliders/instances t_biome_gen/t_biome_mat active biome (warm). Save_state persists only seed/version/discovery/deltas never biome geometry. Generator version stays 2 additive outside dense core, urban_basin 0 instances, no trench carve, design folding C001/C002 deferred docs.

## 13. Settlement & Road slice P4.1 (deterministic anchors and hierarchical road/bridge corridors)

### 13.1 Vocab and constants (authoritative in `WorldConstants`)
- Settlement vocab `SETTLEMENT_VOCAB`: `village`, `hamlet`, `farmstead`, `isolated_farm`, `town` (town sparingly at arterial intersections, never inside `URBAN_INNER_M`).
- Road hierarchy vocab `ROAD_HIERARCHY_VOCAB`: `primary`, `secondary`, `track`.
- Site radii: village `48-90`, hamlet `26-46`, farmstead `16-28` (deterministic via `unit_float("settlement_jitter")`).
- Spacing: `SETTLEMENT_SPACING_VILLAGE 700`, `HAMLET 420`, `FARMSTEAD 220` plus `1.8 * radius` to any stronger accepted anchor, yielding `12-36` total anchors in `[-3072,3072)` playable annulus plus scattered outliers, deterministic and not per-chunk speckles (macro-cell `1024` / landscape `256` spacing, verified via >8 macro cells).
- Gates: `4-8` deterministic `city_gate` nodes on ring `URBAN_OUTER_M +-60` plus inner ring `URBAN_INNER_M+80` optionally, scored as hamlet, kept 4-8 strongest; each gate center `Vector2(cos(phi),sin(phi))*radius`, `radius 18`, `id gate_<k>`.
- Road widths: `ROAD_WIDTH_PRIMARY 7.0`, `SECONDARY 5.0`, `TRACK 3.5`; lifts: `ROAD_LIFT_M 0.04`, `BRIDGE_DECK_LIFT_M 0.35`, `BRIDGE_WIDTH_EXTRA 0.6`; sampling every `12 m`; budgets: road ribbon `<=96 verts / <=64 tris` typical, junction `<=160/96`, `MAX_ROAD_VERTS/TRIS_PER_CHUNK 160/96`, `MAX_ROAD_SEGMENTS_PER_CHUNK 8`, `MAX_ACTIVE_ROAD_COLLIDERS 9`; `FRAME_BUDGET_MS 12`.
- Colors (vertex-colored, no texture import): primary `7a7a78` paved grey, secondary `8b7f6e` gravel tan, track `6e5d4b` dirt brown, bridge deck `6a6a6a` + abutment `5a4a3a`; `StandardMaterial3D vertex_color_use_as_albedo=true`.

### 13.2 Generation contract (layered macro-cell contiguous, hydrology-constrained)
- Settlement scoring uses `WorldSeed.sample_coherent` / `sample_coherent_signed` / `unit_float` with explicit settlement/road domains (`settlement`, `settlement_field`, `settlement_jitter`, `settlement_gate_phi`, `settlement_gate_radius`, `road`, `road_mid`, `road_width`, `road_hierarchy`, etc.) seed-separated from terrain/hydro/geology/biome, `floori` lattice for negative coords, `MACRO_CELL_M 1024` / `LANDSCAPE_CELL_M 256`.
- Per-macro-cell candidate generation: each `1024 m` cell places `0-2` candidates with seeded jitter via `unit_float("settlement_jitter", [cx,cy,k])`, then scored: base `sample_coherent(p, settlement_field, 520)`, slope gate `<22 hamlet/farmstead` and `<14 village` and `cliff` reject, flood gate `> BANK+FLOOD+14 village`, `> BANK+8 hamlet`, `>2 farmstead` plus `is_floodplain` rejects villages and `water_body_at != ""` rejects all, soil/fertility/strata bias (`loess/alluvial` + `fertility >0.48` farmstead, `>0.42` hamlet, `rocky_quarry` biome rejects except deferred quarry outpost), water access peak `dist 80-520` villages, spacing inhibition greedily by scored suitability with minimum separations above and `1.8*radius`, urban exclusion no anchor inside `URBAN_OUTER+180` unless gate satellite `520-880` (rare). Pure, additive, `GENERATOR_VERSION` stays 2.
- Gates: `phi_k = unit_float("settlement_gate_phi", [k]) * TAU` for `k 0..7` filtered by hamlet suitability at ring radius; keep 4-8 strongest.
- Road graph: nodes = settlement anchors + city_gates + hydrology `crossing_candidates` that roads elect to use (each `crossing_candidates` within `480` of any settlement/gate kept if edge would need to cross its water, at most 9 strongest; each becomes `kind crossing` node). Edges = deterministic MST over all non-crossing nodes using world distance weighted by `1 + 0.25*slope_penalty + 0.30*water_penalty + 0.10*forest_penalty` (slope sampled every 32 m, water large unless through kept crossing corridor, forest biases to village rims), seeded Kruskal stable sort by weight then id, then `1-3` extra seeded loops where second shortest alternative shortens detour `>22%`. Hierarchy: `city_gate` + `village`/primary-crossing => `primary 7.0`; `village--hamlet`/`village--village` non-primary => `secondary 5.0`; remaining `track 3.5`. Geometry: 3-point bezier `a -> mid -> b` where `mid = lerp(a,b,0.5) + perpendicular * offset`, `offset = sample_coherent_signed((a+b)*0.5, road_mid, 300) * clamp(length*0.08,6,28)` plus second nudge, sampled every 12 m, filtered to reject subsegments with avg slope `>= CLIFF_SLOPE_DEG` or hydrology water crossing outside kept crossing corridor (reroute via nearby crossing within 420 else drop edge). Bridges: wherever polyline crosses `distance_to_water < bank+3` and `water_body_at != ""`, crossing subpolyline promoted to `is_bridge=true`, deck length = water width + `2*4` abutments, deck width = road width + `0.6`. Pure, deterministic for `(seed, coord)` via `WorldSeed`, inclusive of negative coords, world-space shared edges.

### 13.3 Road chunk manifest and materialization (flat ribbon + primitive bridge deck, 96/64 vs 17x17 terrain)
- Per-chunk manifest via `RoadChunkBuilder.build_manifest(WorldPlan, coord)` clipped to `64 m` rect inflated by `half_width+2`. Keys: `coord, origin, size, road_segments (clipped), bridge_segments (clipped), road_vertices, road_triangles, road_colliders, bridge_vertices, bridge_triangles, bridge_colliders, has_road, has_bridge, road_widths, hierarchies, colors, road_gen_ms`. Deterministic for `(seed, coord)`.
- Sampling: `road_network.road_segments_in(rect)` already clipped; for each clipped polyline `n>=2`, tessellate flat ribbon: per segment `(p0,p1)` compute left/right `perp * width*0.5`, vertices at `terrain.height_at(p)+ROAD_LIFT_M 0.04` (bridge decks at `water_level_at(p0)+BRIDGE_DECK_LIFT_M 0.35` over water tapering to terrain+lift at abutments), normals `Vector3.UP`, indices two triangles per quad. Bridge decks are simple Box-like flat strip, not truss. Palette as above, vertex colors via `StandardMaterial3D`.
- Collision budget: at most **one road collider per chunk** (0 if dry), one aggregated `ConcavePolygonShape3D` (or two `BoxShape3D` strips) under `StaticBody3D RoadBody` (`collision_layer 1`, `mask 0`, `backface_collision=true`). Bridge decks share same body. Warm retains ribbon visuals but collision disabled (`collision_layer=0`) — ACTIVE-only road physics, analogous to terrain/water/biome.
- Clipping: only segments whose centerline lies inside inflated rect are emitted; shared edges produce no duplication because each ribbon segment belongs to chunks it actually crosses — but each chunk's mesh is clipped to its own rect so adjacent chunks agree within `SEAM_CONTINUITY_TOL_M 0.02` at shared border (world-space polyline at same world param). Urban compatibility: rural ribbons suppressed inside `URBAN_INNER_M 350` unless gate within `90 m` (short primary stub into city). Hydrology compatibility: over-water ribbon is `is_bridge` only; no dirt/road collider placed with `water_body_at != ""` unless `is_bridge` true and `water_id` matches.
- Budgets: each road chunk bounded at `<=96 verts / <=64 tris / 1 collider` typical, multi-segment junction `<=160/96` still 1 collider within `FRAME_BUDGET_MS 12` combined with city/terrain/water/biome. `road_gen_ms` worker + `road_mat_ms` main measured within 12 ms combined (road target `<=2.5 ms`). ChunkManager stats show `t_road_gen/t_road_mat` per ring and not inflate `t_water_*`/`t_terrain_*`/`t_biome_*`.

### 13.4 Streaming, telemetry, persistence, compatibility
- `WorldConstants` is single source for settlement/road numerics (vocab, cells, widths, thresholds, caps, 96/64, lift 0.04/0.35). Builders/tests import, never duplicate inline numbers. `WorldSeed` domain separation includes settlement/road domains.
- `WorldPlan` facade owns `SettlementPlan` + `RoadNetworkPlan` and forwards `settlement_anchors`, `settlements_in`, `nearest_settlement`, `city_gates`, `road_graph`, `road_segments_in`, `road_hierarchy_at`, `distance_to_road`.
- `ChunkManager` mirrors terrain/water/biome pipeline: counters `_road_vertices_total/_road_triangles_total/_road_colliders_total/_road_bridges_total/_road_mat_ms_total`, per-chunk `road_vertices/road_triangles/road_colliders/road_bridges/road_manifest/road_gen_ms/road_mat_ms/layers_road`, stats keys and timings `road_gen_ms/road_mat_ms`. Thread-safe build holds `holder["road"]` and `road_gen_ms` measured inside worker (private `WorldPlan`), exactly as terrain/water/biome. Active-ring rule: road collider counted toward `active road` only when chunk state ACTIVE; at most 9 active road colliders (3x3). Warm retains visual `RoadMesh` but disables `RoadBody` collision (`collision_layer=0`). `debug_lines()` as `road verts|tris|colliders|bridges t_road_gen|t_road_mat active road (warm)`. Also exposes settlement anchors total. Early `_collect_finished_jobs(pc)` before streaming recalc plus `MAX_MATERIALIZATIONS_PER_FRAME 1` and Variant freed-Zombie guard (`is_instance_valid` + `!is_queued_for_deletion()` + `is_inside_tree()` before `global_transform`) keep pacing stable.
- Save state: `ChunkManager.save_state()` persists `seed/version/discovery/deltas/facts` only — never generated settlement anchors, road polylines, ribbon vertices/indices/collision shapes nor water/biome geometry. Settlement/road graph deterministic from `seed` and re-derived on load; per-chunk road manifests deterministic from `seed+coord`. `WORLD_SCHEMA_VERSION` may be noted but `GENERATOR_VERSION` stays 2 additive outside dense core. No new autoload, project setting, or large asset import beyond settlement/road constants and road streaming stats.
- Compatibility/migration: `GENERATOR_VERSION` stays 2, additive outside dense historic core (`urban_basin` inside 350 m has no rural anchor except gate stubs, rural roads carry `has_road=false` inside 350) and does not carve heightfields or river CX/width/level or building footprints. Old saves follow existing mismatch path (warning + regeneration). Never silently reinterpret old destruction/door delta keys. No new large asset import; probe roads with vertex-colored ribbon + primitive bridge deck Box; textured road or village building meshes remain later milestones. Procedural placement stays GDScript with deterministic seeds.
- Telemetry and docs: `docs/world/WORLD-CONTRACT.md` §13 documents vocab, scoring gates, graph construction, hierarchy widths, polyline smoothing, sampling manifest 1 ribbon + 1 collider 96/64, ACTIVE-only rule, save exclusion, compatibility/migration. `ARCHITECTURE.md`/`DEVELOPMENT.md` document settlement/road module map, streaming telemetry (`t_gen/t_mat/.../t_road_gen/t_road_mat`, `active terrain|water|biome|road`), ACTIVE-only city/terrain/water/biome/road collision, new 9th gate `--roadtest`/`--settlementtest` alias, plus folded HEAD streaming pacing `MAX_MATERIALIZATIONS_PER_FRAME 1` + early `_collect_finished_jobs` + freed-Zombie Variant guard, `tools/run_suite.py` 400 timeout for citytest/roadtest, and folding C001-C003 deferred docs (windowed proof, ACTIVE-only, water district_hint + bank vertex-color, streaming pacing, timeout, shutdown noise guards).

