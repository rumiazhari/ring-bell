# SPEC-C003 — Czech Rural Mosaic: Deterministic Biomes, Geology and Streamed Rural Dressing

Status: ARCHITECT-READY FOR CONTROLLER AUTHORIZATION
Milestone ID: `P3.1-RURAL-MOSAIC`
Owner: `lunaringbell` (architecture/design/review); `museringbell` (implementation/QA)
State revision: 0

## Player-facing objective

Beyond the dense 350 m historic basin and the Vltava-like river valley, the world must read as Bohemian countryside rather than endless identical rolling hills. From the plaza the player can walk outward and cross distinct rural regions: river floodplain and wet meadow along the banks, arable fields with hedgerow parcels, pasture/orchard mosaics on gentle rolling terrain, contiguous deciduous/mixed upland forest on ridges, and sparse rocky/quarry outcrops where geology allows. Each region has ground tint and lightweight instanced dressing (tree/shrub proxies, hedgerow boxes, field-edge fences) streamed with the same budget discipline as terrain/water, giving landmarks, cover, and future foraging/farming/mining sites. The valley already explains where the city sits; the mosaic now explains how the land is used and where the next roads and villages will belong.

This is the next bounded milestone because hydrology is landed and streamed (P2.2: CX 620+-90, meander 72+18, 38-50 width, 9x9 water 81/128 9 active, 8/8 harnesses green, GENERATOR_VERSION 2). Terrain is streamed (17x17 289/512 1 collider 9 active). The world beyond the city is still one repeating heightfield palette: without biome/geology every bearing looks the same, so exploration has no readable choice and future settlement/road placement would be arbitrary. Biome and geology are the macro-plan's "geographic logic precedes decoration" gate for farms, villages, forests, quarries, roads, and caverns — they must be established before Phase 4 settlement/hierarchical transport.

This slice is deliberately thin and additive: no new city archetype, no road graph or bridge mesh, no lake/reservoir basin formation, no terrain trench carve through the historic core, no underground, no swimming, no authored modular assets, no toon shader rework. It adds deterministic Czech biome/geology classification as pure plan data plus a single low-cost chunk dressing layer streamed beside city+terrain+water with measured ACTIVE-only budgets.

## Current baseline and constraints

The inspected canonical checkout is `C:/Vibe Code project/Godot Project/ring-bell` at Git head `e32f0aa` (accept_with_deferred for P2.2-HYDRO-ANCHORS). Controller state is `enabled=true phase=architecting cycle=3`. Evidence:

- `--import`, `--hydrotest`, `--citytest`, `--terrainmaterialtest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each end with `finished with 0 failure(s)` per REVIEW-C002-R00; Windows `3221225477` with marker and faint `ObjectDB !is_inside_tree()` on shutdown are cosmetic and not failures.
- `WorldSeed.GENERATOR_VERSION` remains 2. Saves persist `seed/version/discovery/deltas` only; generated city/terrain/water never serialized. World origin `(0,0)` Prague basin, `CHUNK_SIZE_M=64`, ACTIVE 1 (3x3=9) WARM 2 (5x5) UNLOAD 3, MAX_INFLIGHT 2.
- `TerrainPlan` is layered deterministic heightfield (terrain/ridge/valley/soil/geology domains) with `WorldPlan` facade; `TerrainChunkBuilder` 17x17 per 64 m (289 verts 512 tris 1 Concave, 9 active, world-space shared edges within `SEAM_CONTINUITY_TOL_M 0.02`).
- `HydrologyPlan` is pure Vltava-like primary CX `620+S*90` (530-710) meander `72*sin(z/1350+phi)+18*coherent Signed`, width `38+12*coherent 38-50`, level `-1.2+-0.6`, `BANK_W 9` `FLOODPLAIN_W 26`, 2 bezier tributaries 14-22; `WaterChunkBuilder` 9x9 per 64 m (81 verts 128 tris 1 collider if wet 9 active) muted teal `4a7a94` bank color transition 1.5 m visual only, `ChunkManager` worker `private WorldPlan` + `plan_mutex`, `t_gen/t_mat/t_terrain_gen/t_terrain_mat/t_water_gen/t_water_mat` telemetry and ACTIVE-only physics (warm visuals, active physics).
- `WorldConstants` documents `CHUNK/LANDSCAPE/MACRO_CELLS`, `WORLD_HALF_EXTENT 8192`, `TERRAIN_MIN/MAX -12/120`, `CLIFF_SLOPE 35 BUILDABLE 22`, `WATER_LEVEL_Y -2.0` datum vs `WATER_LEVEL_MEAN -1.2`, hydrology corridor/meander/width/bank/floodplain/level/trib constants, `BIOME/GEOLOGY vocab single-source`.
- Deferred findings to fold naturally (no polish-only loop):
  1. Archive one authentic normal windowed CITY run (1200x720, not `--shot`) showing WASD/E door swing (closed blocks/open clears without RID exclusion/swung collidable), stair climb to roof with camera following, F3 overlay (`active water` + `t_water_gen/t_water_mat`), then 600-900 m east walk to river valley showing continuous teal water `4a7a94` bank `9 m` floodplain `26 m` across seams — current `SPEC-C002-windowed.png/log` are synthetic PIL placeholders and do not satisfy C001+C002 windowed proof.
  2. Reduce cosmetic headless shutdown noise where feasible without masking failures: `smoke/walkthrough/havoctest` still emit `ObjectDB !is_inside_tree` and Windows `3221225477` with marker — guard remaining `global_transform` reads after `queue_free` and quiet marker-present exit reporting.
  3. Water manifest contract polish: `district` hint missing from manifest (spec mentioned hint) and 1.5 m bank ribbon is presently vertex-color transition not earth geometry — confirm choice or add narrow bank geometry when terrain trench carve through 350 m basin is designed, keeping 81/128 or justifying 17x17.

Previous terrain/city/hydrology contracts remain authoritative: deterministic per `(seed, coord)` via `WorldSeed` domain-separated `sample_coherent` (`floori` lattice + smoothstep), no `String.hash()` or time/scene state, worker-safe private plans, one merged vertex-colored ArrayMesh per chunk per layer, ACTIVE-only colliders.

## Gameplay value

Improves at least four enjoyment pillars in one thin slice while preserving budgets:

- **Exploration and discovery** — contiguous forest belts on uplands, arable fields/hedgerows on gentle terrain, wet meadows/floodplain margins along the river, and rocky/quarry patches become readable landmarks across kilometers. The player chooses to skirt a forest edge, cross exposed field, or follow floodplain, and can return by the same landmark.
- **Agency and meaningful choice** — field vs forest vs floodplain offer different cover, movement cost, and future resource implications (foraging, tillage, timber, quarry). Upland forest vs lowland field contrast already constrains where a farm, village, road, or quarry will later read as plausible without forcing it now.
- **Coherent Czech identity** — Bohemian rolling hills + floodplain meadow + deciduous/mixed upland forest + orchard/pasture mosaic + limestone/sandstone quarry palette make the basin recognizably Czech without claiming a 1:1 Prague map. Continental setting (no sea) and `WATER_BODIES` vocabulary stay as P2.2.
- **Performance and stability foundation** — biomes reuse the measured streaming discipline: deterministic manifests, shared-edge continuity, bounded verts/tris/instances/colliders, ACTIVE-only physics (warm visuals retained), `t_biome_gen/t_biome_mat` telemetry within `FRAME_BUDGET_MS 12`, save exclusion of generated biome dressing, `GENERATOR_VERSION` stays 2 (additive).

Cosmetic polish accompanies but does not replace the playable system: biome ground tints are vertex-colored proxies and trees/hedgerows are primitive MultiMesh/Box proxies, not imported modular assets or shader rework.

## Scope

### 1. Deterministic geology plan

Create `world/generation/geology_plan.gd` as a pure plan (no Node access, no unseeded randomness, no chunk-local state) and expose it through `world/generation/world_plan.gd` facade.

Required queries (exact names may be adjusted but semantics must exist and be used by biome classification and later materializers):

- `strata_at(p: Vector2) -> StringName` — bedrock class `&"alluvial" | &"loess" | &"limestone" | &"sandstone" | &"granite_like"` (vocab subset of geology constants) driven by layered `sample_coherent` fields.
- `soil_at(p: Vector2) -> StringName` — surface soil derived from strata + elevation/moisture.
- `quarry_suitability_at(p: Vector2) -> float` — 0..1 deterministic score (high on limestone/sandstone uplands and steep/cliff masks).
- `fertility_at(p: Vector2) -> float` — 0..1 for arable/pasture suitability (high on loess/alluvial gentle terrain).
- `cave_potential_at(p: Vector2) -> float` — 0..1 for future underground task; exposed now as deterministic scalar, not yet materialized.
- `geology_profile(rect: Rect2, step: float) -> Dictionary` helper for tests/debug.

Generation contract:

- Geology fields use `WorldSeed.sample_coherent` / `sample_coherent_signed` with explicit domains and cell sizes (authoritative in `WorldConstants`: e.g. `GEOLOGY_CELL 700`, `GEOLOGY_RIDGE_CELL 380`, `SOIL_CELL 220`) and seed separation from terrain/hydrology domains. No RNG sharing, no per-query mutable state, handles negative world coordinates via `floori`.
- Deterministic bands: lowlands near center/east-west bias map toward `alluvial/loess`; forested upland bands toward `limestone/sandstone`; limited `granite_like` on highest ridges. Bands are `sample_coherent`-driven, not hard-coded per-chunk art.
- Contract is pure and additive: does not mutate `TerrainPlan` heights, does not carve `CityPlan` blocks, `GENERATOR_VERSION` stays 2.

### 2. Deterministic biome plan

Create `world/generation/biome_plan.gd` as a pure plan that reads `TerrainPlan`, `HydrologyPlan`, and `GeologyPlan` (injected by `WorldPlan`) plus its own moisture/temperature fields.

Required queries:

- `biome_at(p: Vector2) -> StringName` — core vocab (subset of `WorldConstants.BIOME_VOCAB`): at minimum `&"urban_basin"`, `&"river_floodplain"`, `&"wet_meadow"`, `&"arable_field"`, `&"pasture_orchard"` (or split `&"pasture"`/`&"orchard"`), `&"deciduous_forest"`, `&"mixed_upland_forest"`, `&"rocky_quarry"`; additional `&"marsh"` or `&"industrial_corridor"` may appear but only inside `WATER_BODIES` vocab discipline.
- `biome_id_at(p: Vector2) -> String` — stable id for the biome regime (e.g. `field_cluster_12x4` or `forest_belt_N`) for debug.
- `is_forest(p: Vector2) -> bool` / `is_field(p: Vector2) -> bool` / `is_floodplain(p: Vector2) -> bool` / `is_quarry(p: Vector2) -> bool` helpers.
- `moisture_at(p: Vector2) -> float` and `temperature_at(p: Vector2) -> float` — deterministic 0..1 fields traced for tests.
- `biome_density_at(p: Vector2) -> float` — 0..1 instance density param for forest/hedgerow/field-edge logic.
- `surface_tint_at(p: Vector2) -> Color` — deterministic ground tint (for overlay vertex colors) consistent with biome.

Generation contract (layered, macro-cell contiguous):

1. Micro rules override macro noise where geography forces identity:
   - `d = hydrology.distance_to_water(p)`; `half = hydrology.river_half_width_at(p.y)`; if `abs(dist_to_center) <= half+BANK_W` or `hydrology.is_floodplain(p)` (floodplain band) → `river_floodplain` or `wet_meadow` (wet_meadow is 0-16 m outside floodplain where `moisture_at > 0.62` and `terrain.slope_at(p) < BUILDABLE_MAX_SLOPE_DEG` and `terrain.terrain_class_at(p) != &"cliff"`).
   - Within `URBAN_INNER_M 350` flat → `urban_basin` (preserves city dressing; no biome dressing inside 350 except street planters etc, which this slice does not add).
   - `quarry_suitability_at(p) > 0.72` and (`slope >= 28°` or `terrain_class==cliff` or `strata==limestone` on upland ≥15 m) → `rocky_quarry` (sparse, deterministic patches, not per-chunk speckles).
2. Else macro Czech mosaic: deterministic moisture/temperature + geology fertility + elevation/slope gate:
   - `moisture = sample_coherent_signed(Vector2(p.x*0.6, p.y*0.6), &"biome_moisture", BIOME_MOISTURE_CELL 360)` mapped 0..1.
   - `temperature = sample_coherent(Vector2(p.x*0.45, p.y*0.45), &"biome_temp", BIOME_TEMP_CELL 520)` etc.
   - Macro forest field `forest_field = sample_coherent(p, &"biome_forest_field", 420)` — continuous regions ≥ 240 m extent; `forest_field > 0.52` on suitable slope/elevation biases forest belts, else fields/pasture. Low-frequency `mixed_upland` qualifier on `height_at(p) >= TERRAIN_UPLAND_HEIGHT_M 38` or `terrain_class==upland` → `mixed_upland_forest`, otherwise `deciduous_forest`.
   - Gentle slope `< 12°`, `fertility > 0.55`, outside floodplain/wet_meadow/forest/quarry → `arable_field`; moderate fertility + rolling_hill → `pasture_orchard` / `pasture` vs `orchard` split by a second `sample_coherent` threshold.
3. Contiguity rule: biome classification is evaluated at world coords and sampled on a 256 m `LANDSCAPE_CELL_M` lattice tendency (smoothstep) so a single 64 m chunk does not independently decide forest speckles. Classification must produce contiguous parcels ≥ 1 landscape cell where rural, and biome transitions are at most one-sample wide at 4-8 m resolution. Speckled per-sample random forest is a failure.
4. Pure and deterministic: every query is function of `seed + domain + world coordinates` via `WorldSeed.sample_coherent*` or helpers; no RNG sharing between unrelated biome/geology queries; no chunk visit order dependence; inclusive of negative world coordinates.

### 3. Rural chunk materialization

Create `world/streaming/biome_chunk_builder.gd` and integrate through `WorldPlan` + `ChunkManager`.

Manifest per 64 m chunk via `static build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary`:

- Keys: `coord, origin, size, resolution, biome_ids (PackedStringArray|Array[StringName]), material_ids (Array[StringName]), class_ids, colors (PackedColorArray ground tints), biome_gen_ms, density, instance_count, instances (Array[Transform3D] or Dictionary packed), has_forest, has_field, has_quarry, is_wet_margin, biome_vertices, biome_triangles, biome_colliders, biome_nodes`. Deterministic for `(seed, coord)`.
- Sampling: 9x9 grid at 8 m spacing over chunk rect (81 samples at world-space origin + i*8, j*8) with shared world-space edge handling matching terrain's and water's world-space edge convention so adjacent chunks agree on the biome tiling within a tolerance derived from shared-edge biome agreement (not floating height tolerance, but vocab agreement at boundaries). For each sample `p`, query `biome_at(p)` / `geology.strata_at(p)` / `water_body_at(p)` / `terrain.height_at(p)` to decide class and `surface_tint_at(p)` for `colors`. Store `biome_ids`/`colors` per sample.
- Visual ground overlay: one `ArrayMesh` per chunk that carries a biotope tint: vertices at `(x, terrain_height_at(p)+0.03, z)` bilinearly interpolated across the 9x9 grid (the `+0.03` lifts the overlay above terrain to avoid z-fighting without extra depth bias), vertex colors = `surface_tint_at`. Indices share the same winding rule as terrain/water; draw as single surface StandardMaterial with `vertex_color_use_as_albedo=true` (no texture import). This is the measured rural ground dressing (81 verts / <=128 tris per chunk, documented low-cost choice vs 17x17 289/512; use 9x9 and keep `water_gen_ms`-like `biome_gen_ms`).
- Instanced dressing: for samples classified as forest/quarry/field-edge, generate deterministic per-sample primitive proxies:
  - Forest (`deciduous_forest`/`mixed_upland_forest`): up to 1 tree proxy per 8 m cell where `biome_density_at(p) > 0.48` and not inside floodplain/water — capped at **48 per chunk** for forest-dominant chunks, **0-12** for transitional chunks, 0 elsewhere. Each instance is a `Transform3D` (translation + yaw from seeded hash, scale variation 0.9-1.15) placed at terrain height. Materialized via a single `MultiMeshInstance3D` (one `MultiMesh` per chunk, `BoxMesh` or `CapsuleMesh` proxy, vertex-colored) — no per-tree Node.
  - Field (`arable_field`/`pasture_orchard`): hedgerow/field-edge strip as 1-2 `Box` proxies along parcel boundaries where `sample_coherent(Vector2(...), &"biome_field_edge", 180)` crosses a threshold, max **12 per chunk**, length aligned to world axes (no rotation complexity), height 0.45-0.75 m.
  - Quarry (`rocky_quarry`): 2-6 rock/boulder `Box` proxies per quarry chunk where `quarry_suitability > 0.72`.
  Total instance budget per chunk **<= 48 forest or <=12 field + <=6 quarry**; overlapping vocab caps still enforce global **<=48**.
- Collision budget: at most **one biome collider per chunk** (0 if no trunks/boulders). Forest trunks optionally register as a sparse aggregated `ConcavePolygonShape3D` or a small set of `BoxShape3D` under one `StaticBody3D BiomeBody` (collision_layer 1, mask 0), `backface_collision=true` for mesh colliders. Non-forest/non-quarry chunks have 0. Do not add per-instance bodies, no per-waypoint volumes, no navmesh. Warm retains `MultiMesh` visuals but collision is disabled (`collision_layer=0` or `MeshBatcher` style `disable_collision`) — **ACTIVE-only biome physics**, analogous to terrain/water.
- Clipping: only proxies whose center lies inside the chunk rect are emitted; shared edges produce no duplication because each proxy belongs to exactly one chunk via footprint center (same ownership rule as buildings).

Materialization `static materialize(parent: Node3D, manifest: Dictionary) -> Dictionary`:

- Creates `Biome_X_Y` Node3D under chunk `Chunk_X_Y`, with `BiomeMesh` (`MeshInstance3D` overlay) and optional `BiomeBody` (`StaticBody3D` + `CollisionShape3D`) and optional `BiomeMultimesh` (`MultiMeshInstance3D`) under same parent. Mirrors `TerrainChunkBuilder.materialize` / `WaterChunkBuilder.materialize` signature so `ChunkManager` can measure `biome_mat_ms`. Returns stats `biome_vertices, biome_triangles, biome_colliders, biome_instances, biome_gen_ms, biome_mat_ms, biome_nodes`.
- Urban compatibility: biome manifests are generated for all chunks, but interior `URBAN_INNER_M 350` flat yields `urban_basin` with `is_wet_margin=false` and `instance_count=0` — no rural proxies inside dense core, preserving city dressing.
- Hydrology compatibility: water-covered samples are `river_floodplain`/`wet_meadow` not forest/field; no tree proxy is placed where `hydrology.water_body_at(p) != &""`.

### 4. Streaming, telemetry, docs, and cleanup

- Extend `world/generation/world_constants.gd` with authoritative biome/geology constants (subset, all under `WorldConstants`): `BIOME_VOCAB`, `GEOLOGY_STRATA_VOCAB`, `GEOLOGY_SOIL_VOCAB`, `BIOME_MOISTURE_CELL`, `BIOME_TEMP_CELL`, `GEOLOGY_CELL`, `GEOLOGY_RIDGE_CELL`, `SOIL_CELL`, biome moisture/forest thresholds, `BIOME_DENSITY_FOREST_MIN` etc., `MAX_BIOME_INSTANCES_PER_CHUNK`, `BIOME_OVERLAY_RESOLUTION=9`, `BIOME_INSTANCE_CAP_FOREST 48` / `FIELD_EDGE 12` / `QUARRY 6`, ground overlay budget 81/128, `FRAME_BUDGET_MS 12` shared. No builder or test may duplicate these numerics.
- Extend `world/generation/world_seed.gd` with domain names for biome/geology: add entries such as `&"biome"`, `&"biome_moisture"`, `&"biome_temp"`, `&"biome_forest_field"`, `&"biome_orchard"`, `&"biome_field_edge"`, `&"geology"`, `&"geology_ridge"`, `&"geology_soil"` to domain separation (or extend `TERRAIN_DOMAINS`/`HYDRO_DOMAINS` explicitly; must remain explicit and ordered).
- Extend `WorldPlan` facade to own `GeologyPlan` + `BiomePlan` and forward `biome_at / strata_at / is_forest / quarry_suitability_at` etc.; `WorldPlan._init` constructs all four plans from same seed; plans are `RefCounted` pure.
- `ChunkManager`: mirror terrain/water pipeline — new counters `_biome_vertices_total/_biome_triangles_total/_biome_colliders_total/_biome_instances_total/_biome_mat_ms_total`, new per-chunk record fields `biome_vertices/biome_triangles/biome_colliders/biome_instances/biome_manifest/biome_gen_ms/biome_mat_ms/layers_biome`, new stats keys and timings `biome_gen_ms/biome_mat_ms`. Thread-safe build holds `holder["biome"]` and `biome_gen_ms` measured inside worker (private `WorldPlan`), exactly as terrain/water. Active-ring rule: biome collider (and instance collision body) counted toward `active biome` only when chunk state ACTIVE; at most 9 active biome colliders (3x3). Warm retains visual `BiomeMesh` + `MultiMesh` but disables `BiomeBody` collision (`collision_layer=0`). Wire `debug_lines()` as `biome verts|tris|colliders|instances t_biome_gen|t_biome_mat active biome (warm)`.
- `docs/world/WORLD-CONTRACT.md`: add section 12 Biome & Geology slice `P3.1` documenting vocab, generation contract (macro 256 m contiguity, hydrology/slope/geology gate, moisture/temperature cells), sampling resolution 9x9 vs 17x17 justification, overlay lift `0.03 m`, instance caps 48/12/6, `ACTIVE-only` rule, save exclusion, compatibility/migration note (`GENERATOR_VERSION` stays 2, additive).
- `ARCHITECTURE.md` and `DEVELOPMENT.md`: add/update sections documenting biome/geology module map, streaming telemetry (`t_gen/t_mat/t_terrain_gen/t_terrain_mat/t_water_gen/t_water_mat/t_biome_gen/t_biome_mat`, `active terrain|water|biome`), ACTIVE-only city/terrain/water/biome collision optimization as intentional budgeted optimization versus previous warm+active assumption, new 9th gate `--biometest`. Keep edits narrow and factual.
- Water manifest contract polish (fold deferred #3): extend `WaterChunkBuilder.build_manifest` to include `district_hint: StringName` (e.g. `&"urban_basin" | &"rural_plateau" | &"river_valley"` derived deterministically from radial distance `p.length()` and `hydrology.distance_to_water(p)`) so the spec's earlier “district hint” promise is honored; document that the 1.5 m earth bank ribbon remains a **vertex-color transition without extra geometry** as the budgeted choice for this slice, keeping 81 verts / <=128 tris / 1 collider wet-chunk budget. Enclosing a narrow earth-geometry strip will be evaluated when/if terrain trench carve through the historic basin is designed (deferred truthfully, not silently omitted).
- Headless harness noise (fold deferred #2): where `world/main.gd` and `debug/{smoke_test,walkthrough_probe,havoc_test,city_runtime_test}.gd` fetch `global_transform`/`global_position` after `queue_free` during shutdown, guard with `is_instance_valid(node) and node.is_inside_tree()` before reading transforms; ensure any `ObjectDB !is_inside_tree()` script warnings are quelled without masking real failures, and quiet `tools/run_suite.py` wrapper noise when `finished with 0 failure(s)` marker is present (Windows `3221225477` exit with marker is a pass).
- Manual archive (fold deferred #1): during this cycle's ordinary windowed proof, capture at least one normal **WINDOWED CITY** run (not `--shot`): WASD approach to a qualifying multi-storey building, E door swing through entry, stair climb to roof, F3 overlay visible (now showing `active biome` plus `t_biome_gen`/`t_biome_mat` alongside `active water/terrain`), then walk 600-900 m east to the river valley. The valley walk must now also show **biome continuity**: distinct ground-tint transition (floodplain/wet meadow → arable field → forest upland) and instanced proxies (hedgerows/trees/boulders) without 64 m seam cracks or flicker as chunks warm-stream. Store `png` + `log` under `.hermes/autopilot/reports/` or `junk/` and reference path in the builder handoff. This single capture satisfies the surviving C001+C002 windowed proof and the new mosaic proof.

## System ownership and interfaces

| System | Owns | Required invariant |
|---|---|---|
| `WorldSeed` | Seeded domains + `sample_coherent` helpers | No unseeded randomness; biome/geology domains domain-separated from terrain/hydrology. |
| `WorldConstants` | All biome/geology numerics (vocab, cells, thresholds, caps, 81/128, moisture bounds) | Builders/tests import, never duplicate inline numbers. |
| `GeologyPlan` | Strata/soil/quarry/fertility/cave potential pure queries | Deterministic per `(seed, world XZ)`, order-independent, handles negative coords. |
| `BiomePlan` | `biome_at`, forest/field/floodplain/quarry predicates, density/tint | Deterministic macro-cell contiguous Czech mosaic reading terrain+hydrology+geology+moisture/temp; 256 m landscape tendency. |
| `WorldPlan` | Facade owning `TerrainPlan+HydrologyPlan+GeologyPlan+BiomePlan` | Forwards all queries; constructed once per worker thread; pure. |
| `TerrainPlan` / `TerrainChunkBuilder` | Heightfield + 17x17 manifests | Unchanged this cycle; no water/biome-driven trench carve yet. |
| `WaterChunkBuilder` | Per-chunk water manifest + materialization | World-space shared edges, one teal mesh + at most one collider per wet chunk; now adds `district_hint`. |
| `BiomeChunkBuilder` | Per-chunk biome manifest + materialization | World-space shared edges, one overlay mesh (81/128) + one MultiMesh (≤48 instances) + at most one collider; ACTIVE-only physics. |
| `ChunkManager` | Streaming, ACTIVE/WARM/COLD, telemetry, deltas | Thread build measures `biome_gen_ms`; materialize measures `biome_mat_ms`; budgets enforced; no navmesh/grid. |
| `CityPlan` / `ChunkBuilder` / `BuildingBuilder` | Deterministic city blocks/buildings/interiors | Unchanged; river+biomes placed outside dense core so no footprint overlap this slice. |
| `debug/biome_test.gd` (or `terrain_biome_test.gd`) | Pure biome/geology + material + streaming proof harness | Asserts determinism, contiguity, vocab validity, budgets, seams, save exclusion. |

Public interfaces remain compatible; no new autoload or project setting is authorized. Small diagnostic helpers stay in their owner.

## Construction sequence

### Phase 0 — Reproduce and protect the baseline

1. Preserve all unrelated dirty files and user work (do not reset/clean).
2. Run focused gates and capture their current markers: `python tools/run_suite.py --import 120` and `python tools/run_suite.py --hydrotest 120` and `python tools/run_suite.py --citytest 120` as sanity; full matrix per below after build.
3. Add behavioral assertions/diagnostics FIRST (RED): geology/biome determinism (same seed shuffled vs forward identical, different seed differs, negative coords in vocab, contiguous forest/field clusters ≥ landscape cell, no speckling), river-floodplain exclusion, forest upland vs field gentle-slope gate, quarry geology gate, biome materialization budgets (81/128, ≤48 instances, ≤1 collider, ≤9 active biome), shared-edge biome agreement, save exclusion. Run with failing/empty implementation to confirm they fail for expected reason; do not retain a test written only after the implementation already passes.

### Phase 1 — Plan layer

1. Extend `world/generation/world_constants.gd` with biome/geology constants (documented, authoritative): vocab arrays, cell sizes, thresholds, instance caps, overlay resolution 9.
2. Extend `world/generation/world_seed.gd` domain list to include biome/geology domains (explicit `StringName` entries).
3. Implement `world/generation/geology_plan.gd` with pure strata/soil/quarry/fertility/cave queries using only `WorldSeed` helpers.
4. Implement `world/generation/biome_plan.gd` with pure Czech mosaic reading `TerrainPlan` height/slope/class + `HydrologyPlan` distance/floodplain + `GeologyPlan` strata/suitability + moisture/temp fields via `sample_coherent`.
5. Extend `world/generation/world_plan.gd` to own `GeologyPlan` + `BiomePlan` and forward `biome_*`/`geology_*` queries (plus `surface_tint_at` etc.).
6. Run `--biometest` focused checks (plan determinism, contiguity, vocab validity, geographic gates) before materialization; keep failures honest.

### Phase 2 — Materialization + streaming

1. Implement `world/streaming/biome_chunk_builder.gd` manifest + materialize (9x9 overlay 81 verts / <=128 tris, 48/12/6 instance caps, at most one collider per chunk, MultiMesh + overlay + `BiomeBody`, lift `0.03 m`, world-space shared edges, urban inner flat emits `urban_basin` with 0 instances).
2. Integrate into `ChunkManager._thread_build` (private `WorldPlan`, `holder["biome"] + biome_gen_ms`) and `_materialize` (create `Biome_X_Y`, measure `biome_mat_ms`, record per-chunk `biome_*` stats and totals). Add `t_biome_gen`/`t_biome_mat` to debug stats lines and respect ACTIVE-only biome collider counting (warm disables `BiomeBody`).
3. Polish `WaterChunkBuilder` district hint (`district_hint`) without changing its 81/128/1 budget; document bank ribbon vertex-color choice in that builder's header and in `WORLD-CONTRACT.md`.
4. Extend `world/main.gd` wiring: `WorldPlan` constructed with current seed, passed via `setup_world`; wire new biome harness flag `--biometest` (plus `--biomematerialtest` alias if two flags desired — single harness covering plan+material approved as long as budgets/seams asserted).
5. Update `docs/world/WORLD-CONTRACT.md` §12, `ARCHITECTURE.md`/`DEVELOPMENT.md` streaming/collision notes (ACTIVE-only clarification now includes biome) as the same coherent commit series; guard headless `global_transform` reads after `queue_free` and quiet marker-present exit reporting.

### Phase 3 — Persistence, regression, and evidence closeout

1. Prove generated biome dressing is NOT serialized: `ChunkManager.save_state()` payload has no biome geometry/vertices/instances; `WorldPlan` seed/version handles mismatches via existing warning + regeneration path. Determinism survives unload/reload of biome chunks (same manifest after re-build, same overlay colors and instance transforms).
2. Run full required matrix and judge by explicit `finished with 0 failure(s)` marker (Windows `3221225477` acceptable only with marker). Include windowed manual proof: windowed CITY run (WASD/E, door, stairs, roof, F3 with `active biome`/`t_biome_*`) + hill/field/forest walk to river valley showing biome tint + instanced proxies + water continuity, capture PNG/log, store under `.hermes/autopilot/reports/SPEC-C003-windowed.*` or `junk/` and reference in handoff.
3. Commit coherent units (constants/seed, geology plan, biome plan, world plan facade, biome builder, water district polish, streaming, docs, harness) without rewriting history; request independent Luna review with changed paths, commit IDs, test outputs, player-facing evidence, and residual risk. The builder must not edit `AUTOPILOT_STATE.json`.

## Explicit acceptance criteria

1. `--biometest` finishes with `finished with 0 failure(s)`. In particular: same-seed geology and biome queries identical regardless of query/build order, including negative coordinates; different seed materially differs (≥3/9 probes differ); at least 40 probes along 512 m transects through rural area show **contiguous** biome clusters (no speckling — run-length of single biome ≥ 192 m, i.e. ≥ 3×64 m chunks, for forest and field belts) and biome ids are within `WorldConstants.BIOME_VOCAB`.
2. Geographic validity holds for the canonical seed and at least four alternate seeds: river `river_floodplain`/`wet_meadow` only within `BANK_W+FLOODPLAIN_W` (+16 m wet margin) of water where `slope < BUILDABLE_MAX_SLOPE_DEG` and `terrain_class != cliff`; forest only on slope/elevation-compatible sites outside water/floodplain (deciduous on basin/rolling, mixed on upland≥38 m); `arable_field`/`pasture_orchard` only on gentle slope `< 12-14°` and `fertility/quarry_suitability` gate outside floodplain/forest; `rocky_quarry` only where `quarry_suitability > 0.72` and (`slope ≥ 28°` or `terrain_class==cliff` or limestone upland). Focused assertions use real `WorldConstants` thresholds (not duplicated numerics). Hydrology distance correctly maps floodplain→wet margin→upland transect at a sample Z beyond `URBAN_OUTER_M`.
3. `--biometest` (or the single biome harness) also proves rural materialization budgets and seams: chunk biome manifests per `(seed, coord)` are byte-identical across two builds with shuffled chunk order (`biome_ids` PackedStringArray plus `colors`/`instances`); shared-edge biome agreements hold at positive and negative boundaries (adjacent 9x9 north/south and east/west edges agree on `biome_at` vocab for ≥ 7/9 edge samples within macro-cell tolerance — allows at most 2 transitional transition samples); each chunk carries at most **1 biome collider** (0 if no forest/quarry proxies), `biome_instances ≤ 48` (forest-dominant) and field hedgerow ≤12 + quarry ≤6; the 3x3 ACTIVE ring carries at most **9 active biome colliders**; each biome chunk has bounded **81 verts / <=128 tris** for overlay (9x9) plus bounded instance count and `biome_mat_ms` measured per chunk. Harness enumerates at least **9 resident biome chunks** around a rural transect (field → forest → quarry-adjacent) to assert the budget.
4. `ChunkManager` streams biome dressing together with terrain+water+city without duplication: load a 3x3 ACTIVE ring around a rural hill near the forest/field edge, claim `_biome_colliders_total <=9` and `active biome == biome in ACTIVE`, walk 480 m away beyond `UNLOAD_RADIUS` until the biome chunks unload, return and verify the same biome manifests regenerate (same overlay colors, same instance transforms, same vertex/triangle/collider/instance counts) and the debug stats line contains `t_biome_gen`/`t_biome_mat`. Generated biome geometry (overlay vertices/instances/collision shapes) does not enter `save_state()` payload (save dict has no `biome_vertices/biome_triangles/biome_instances/biome_manifest` arrays).
5. Determinism and buildability are preserved after biome: `WorldSeed.GENERATOR_VERSION` unchanged (still 2 — biome/geology additive, does not alter city block topology or terrain heights or water level), `WorldPlan` remains pure (no scene mutation on query), `CityPlan` deterministic building IDs and `TerrainPlan` 17x17 manifests unchanged for same seed/coord, spawn anchor still found dry at `urban_basin`, multi-storey building samples unchanged — proved by `--citytest` plus `--terrainmaterialtest` plus `--hydrotest` each finishing with `finished with 0 failure(s)` and retained overlap/door/stair/facade/material assertions (no duplicate buildings, no missing stair zone coverage, no terrain seam regression, hydrology CX/meander/width still 530-710/72/38-50).
6. Existing streaming and survival budgets are not weakened: `--citytest`, `--terrainmaterialtest`, `--hydrotest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each finish with `finished with 0 failure(s)` (window `3221225477` with marker is not a failure; `ObjectDB !is_inside_tree()` noise reduced where feasible by guards — at least `main.gd` + one probe harness guarded; remaining faint noise documented not masked). In particular: closed leaf still blocks aperture center, open doorway clear without RID exclusion, swung leaf collidable, walkthrough still climbs 5 storeys and back with no position writes/skips/floor-band pass, havoctest prop clear-shot and damage honest, city `active<=9` / terrain `9` / water `≤9` collider budgets intact.
7. Ordinary player-facing proof is archived: a normal **WINDOWED CITY** run (not headless `--shot`) shows WASD movement, E door swing (closed blocks, open clears without RID exclusion, swung collidable), stair climb to roof with camera following, F3 overlay with `active biome` and `t_biome_gen`/`t_biome_mat` visible alongside `active water/terrain`, then a walk east ~600-900 m to the river valley showing **continuous** biome ground-tint transition (field/pasture → wet meadow/floodplain → water `4a7a94` bank `9 m` floodplain `26 m`) with instanced proxies (trees/hedgerows/rock piles) visible and without cracks at 64 m seams or flicker as chunks warm-stream. At least one `PNG` and its `log` are committed under `.hermes/autopilot/reports/SPEC-C003-windowed.*` (or `junk/` if large) and referenced in the builder handoff. Any remaining minor presentation issue (e.g. `active biome` warm count rounding) is reported for a later design rather than masked. As part of the same handoff, `ARCHITECTURE.md` and `DEVELOPMENT.md` are updated to document **ACTIVE-only city/terrain/water/biome collision** (warm visuals without Static/BiomeBody), `t_biome_*` telemetry, biome/geology vocab and 81/48 budget, and the water `district_hint` + bank ribbon vertex-color budgeted decision, folding the surviving C001/C002 deferred documentation findings.

## Required automated verification

From the canonical repository root, run these commands after implementation (judge by harness marker, not exit code). The 8-gate gameplay matrix below is the formal `required_tests` gate; `--import` is an additional fast preflight (boot-parse check) that must also be green before the matrix:

```text
python tools/run_suite.py --import 120
python tools/run_suite.py --biometest 300
python tools/run_suite.py --hydrotest 300
python tools/run_suite.py --citytest 300
python tools/run_suite.py --terrainmaterialtest 300
python tools/run_suite.py --cityruntime 300
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --havoctest 240
python tools/run_suite.py --smoke 180
```

Every command must produce its harness marker `finished with 0 failure(s)`. A Windows child exit code `3221225477` is acceptable only when that explicit zero-failure marker is present. A timeout, missing marker, partial output, or nonzero failure count is not a pass. The formal `required_tests` decision array lists the 8 gameplay gates (`--biometest` through `--smoke`, 8 entries, `1-8` per policy); `--import` is a mandatory preflight alongside them. If the implementation exposes a second alias `--biomematerialtest`, running it with `300` must also end with `finished with 0 failure(s)` and does not relax the biome harness above. The builder should run focused checks after each RED-GREEN step as well as this final matrix. `tools/run_suite.py` remains the only invoked runner; direct `godot --headless -- ...` is not a substitute for the matrix above.

## Ordinary player-facing proof

Run default CITY windowed (1200x720 windowed is fine, optionally larger). Spawn at plaza, toggle F3. With WASD approach a qualifying building (`int(floors)>=2`, `BuildingBuilder.has_stairs_for` true); closed entrance must stop the capsule. Press E, door visibly swings and remains solid at the swung position, walk through aperture, cross entry corridor, climb visible stairwell to every floor and roof deck, reverse and leave, close door from outside and verify it blocks again. Then walk east (or toward deterministic river `CX` ~620 m) **600-900 m** over rolling hills — the walk should cross **readable biome transitions**: urban fringe → arable field/pasture with hedgerow strips → (optional orchard/pasture mosaic) → wet meadow margin near floodplain → river banks/floodplain meadow contrast → teal water surface; on a forested bearing uphill, a contiguous forest edge should appear with darker ground and tree proxies. Stand on a bank hill and on a forest edge hill and observe (a) biome overlay continuity across streamed chunks (no cracks at 64 m seams, ground tint interpolates, no flicker as chunks warm-stream), (b) water continuity alongside biome (no cracks at 64 m seams, no flicker), (c) instanced trees/hedgerows pop in only within ACTIVE ring and remain stable without duplication. If a failure occurs, retain PNG/log with exact player `global_position`, `WorldSeed` value, `biome_at(p)` / `strata_at(p)` / `distance_to_water(p)` and river centerline X at that Z. Do not compensate with teleport or disabled collision. A screenshot built with `--shot` in headless is not sufficient for this proof due to dummy renderer; the archived PNG must be from a real windowed run.

## Performance, persistence, and compatibility boundaries

- Preserve `64 m` chunks, ACTIVE `<=1`, WARM `<=2`, hysteresis `UNLOAD=3`, one merged city mesh/static per chunk (city ACTIVE-only), one terrain mesh/collider per chunk (9 active, 289/512), plus at most one water mesh/collider per wet chunk (9 active water max, 81/128) plus at most one biome overlay mesh (81/128) and at most one `MultiMeshInstance3D` (≤48 instances) plus at most one biome collider per chunk (9 active biome max). Active colliders total ≤ 9 city + 9 terrain + 9 water + 9 biome = 36 peak (3x3). Do not introduce a 2D collider grid, per-waypoint bodies, navmesh generation, or dense per-sample physics.
- Per-chunk budgets: terrain 289/512 1 collider, water 81/128 1 collider, biome overlay 81/128 1 MultiMesh ≤48 instances 1 collider — document choice and enforce it; per-chunk `biome_gen_ms` (worker) + `biome_mat_ms` (main) measured and kept within `FRAME_BUDGET_MS 12` combined with city/terrain/water (water already ~0.4+1.1 ms; biome target ≤2.5 ms combined). ChunkManager stats must show `t_biome_gen`/`t_biome_mat` per ring and not inflate `t_water_*` or `t_terrain_*`.
- Prefer repairs that do not change generated city/terrain/water cell topology or stable IDs. **Do not bump `WorldSeed.GENERATOR_VERSION` in this slice**: biome/geology are additive outside the dense historic core (`urban_basin` inside 350 m stays 0 instances) and do not carve heightfields or river CX/width/level or building footprints. If a generator change becomes unavoidable, document it deliberately in `docs/world/WORLD-CONTRACT.md`, add migration/warning note, and prove old saves follow the existing mismatch path (warning + regeneration). Never silently reinterpret old destruction/door delta keys.
- `ChunkManager` saves `seed/version/discovery/deltas/facts` only — never generated biome overlay vertices/instances/collision shapes nor water geometry. Biome/geology manifests are deterministic from `seed+coord`. `WORLD_SCHEMA_VERSION` may be noted but `GENERATOR_VERSION` stays **2**. No new autoload, project setting, or large asset import is authorized beyond the biome/geology constants and biome streaming stats already described.
- No new large asset import. Probe hydrology/biome with vertex-colored meshes + primitive MultiMesh proxies; textured/modular vegetation and banks remain later milestones. Keep procedural placement in GDScript but use deterministic seeds.

## Out of scope and escalation

- No hierarchical road/rail graph, no settlement suitability or village/farm/hamlet placement, no city gate / external road connection logic in this slice.
- No terrain trench/dike carve through the 350 m historic basin, no city block water avoidance inside the urban flat, no river cutting a street/block grid, no street bridge mesh spanning water (water remains outside dense core; bank earth-geometry strip deferred as documented vertex-color choice).
- No lake/reservoir fully materialized beyond the existing hydrology placeholder vocabulary distinction (`&"lake"` vs `&"river"` vocabulary check already in prior slice) — a full inland basin/quarry-forming rule is a later hydrology/biome joint milestone.
- No swimming, buoyancy, currents affecting gameplay, water damage, or boat/dock gameplay.
- No vertical survivor network, roof farms, bridges, ledges, lifts; no cave/mine/cavern entrances, seams, or underground graph.
- No full shader water surface or biome texture/LOD (reflections, flow UVs, toon-outline tuning on vegetation) beyond flat vertex-colored overlay + primitive box proxies; no `art/toon_*` shader rework.
- No broad building/interior refactor, collision disabling, intangible doors, player teleportation, hard-coded per-chunk biome hacks (e.g. `if chunk == (8,0) -> forest`), waypoint skipping, or test relaxation.
- Do not absorb unrelated dirty files or rewrite history. If the real repository contradicts an interface above (e.g. a biome would inevitably overlay dense plazas where spec says `urban_basin` 0 instances, or a required constant name collides with Godot AI plugin), stop and report the exact path and conflict to the architect instead of inventing a second milestone.
- A principal blocker may receive at most two bounded direct revisions. A third revision, a generator-version/save migration decision that cannot be made safely without a larger migration design, or a persistent inability to prove biome contiguity/budgets without speckling must return to a fresh architect recovery cycle rather than expanding this pass.

## Rollback and recovery

Keep the pre-candidate `e32f0aa` checkpoint and all unrelated user changes intact. The builder should commit biome/geology constants+domains, geology/biome pure plans, world facade, biome builder, water district hint polish, streaming integration, `WORLD-CONTRACT` §12 + `ARCHITECTURE.md`/`DEVELOPMENT.md` telemetry/active-only clarifications, and harness evidence as coherent reviewable units without rewriting history.

If the candidate fails review, revert or quarantine only its implementation commits, leave generated artifacts (e.g. windowed PNG) under `junk/` rather than deleting them, and restore the controller through the prescribed Kanban outcome with exact failure logs. A rollback must reproduce the known baseline honestly: `--hydrotest`, `--citytest`, `--terrainmaterialtest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each green as at `e32f0aa`, plus no biome nodes/artifacts and no water `district_hint` key (pre-polish). Do not mark a failing biome assertion as accepted merely because rollback is available; a failing proof of contiguity, a missing `t_biome_*` stat, or a speckled forest must remain a failure.

Execution note for the builder: preserve every unrelated dirty file and user WIP. Never `git reset --hard`, `git clean -fd`, or delete files; move unwanted artifacts to project `junk/`. TDD RED must show biome/geology harness failing for the correct reason before GREEN; a test written only after implementation already passes is not evidence.

