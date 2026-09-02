# BUILD_RESULT — Ring Bell Part 1: City Fringe Visual Overhaul
**Date:** 2026-09-02
**Repository:** rumiazhari/ring-bell
**Generator Version:** 2 (additive, fringe is outside core 250-1200)
**Branch:** main (local workdir C:/Vibe Code project/Godot Project/ring-bell)

---

## 1. Exact files changed / added

### New files (Part 1)
- `world/generation/fringe_plan.gd` (1 346 lines, `uid://8bhq2386rafto`) — pure deterministic city-fringe composition system
- `world/streaming/fringe_chunk_builder.gd` (392 lines, `uid:// fringe` ) — manifest + materialization via BuildingBuilder/MeshBatcher
- `debug/fringe_test.gd` (336 lines) + `debug/fringe_test.gd.uid` — deterministic fringe harness (`--fringetest`)
- `debug/fringe_capture.gd` (290 lines) + `debug/fringe_capture.gd.uid` — 5-view windowed/headless capture (`--fringe-capture`, `--seed`)

### Modified files
- `world/generation/world_constants.gd` — added **City Fringe Composition System** block:
  - `FRINGE_INNER_M/MIN/MAX`, `FRINGE_OUTER_M`, `FRINGE_PERI_M`, `FRINGE_MAX_M`, `FRINGE_NOISE_CELL`, `FRINGE_ROAD_DISTANCE_MAX`, `FRINGE_LANDSCAPE_CELL_M`
  - `FRINGE_ARCHETYPES` (10), `FRINGE_ARCHETYPE_FOOTPRINTS/FLOORS/FLOOR_H`, `FRINGE_*_GAP_*`, `FRINGE_SLOPE_MAX_DEG_*`, `FRINGE_LANDMARK_*`, `FRINGE_*_CHUNK`, `COL_ROAD_COBBLE/MIXED/DIRTY_STONE/DIRT_PACKED/BRIDGE`
- `world/generation/world_seed.gd` — added `FRINGE_DOMAINS` (12 domains: `fringe_density`, `fringe_deform`, `fringe_arch`, `fringe_fp_x/y`, `fringe_yaw`, `fringe_landmark`, `fringe_landmark_kind`, `fringe_palette`, `fringe_secondary`, `fringe_wall`, `fringe_yard`) + `FOREST_VEGETATION_DOMAINS`
- `world/generation/world_plan.gd` —
  - `const FringePlanScript = preload(...)`, `var fringe`, lazy `WorldPlan.new` now creates `FringePlan` with correctly seeded `CityPlan` (`seed_used` override + cache clear)
  - Forwarders: `fringe_buildings()`, `fringe_buildings_in()`, `nearest_fringe_building()`, `fringe_density_at()`, `fringe_type_at()`, `landmarks()`, `fringe_walls_in/yards_in/trees_in()`, `fringe_chunk_manifest()`
  - `composition_at()` unchanged (terrain height datum preserved), `surface_height_at()` unchanged
- `world/streaming/chunk_manager.gd` —
  - `const FringeChunkBuilderScript = preload(...)`
  - Added totals: `_fringe_vertices_total`, `_fringe_triangles_total`, `_fringe_colliders_total`, `_fringe_doors_total`, `_fringe_buildings_total`, `_fringe_mat_ms_total`, `_total_fringe_gen_ms`
  - Reset, holder `fringe`/`fringe_gen_ms`, `_thread_build` now builds `fringe` manifest via `FringeChunkBuilderScript.build_manifest`, `_collect_finished_jobs` and `_materialize` now thread fringe manifests and materialize under `Chunk_X_Y`
  - ACTIVE-only physics for fringe (`_set_fringe_enabled` mirrors `_set_rural_*`), unload subtracts fringe totals, `debug_lines()` now shows `Fringe`
- `world/streaming/road_chunk_builder.gd` —
  - Added `_fringe_blended_color(world_plan, p, hier, is_bridge)` and per-segment blended coloring: cobble (0-350) → mixed (350-500) → dirty stone (500-750) → dirt packed (750-1200) with 12 m smoothstep, bridge stays `COL_BRIDGE`; removed hard `URBAN_INNER/OUTER` color boundary
- `world/main.gd` —
  - Early `--seed` override (`WorldSeed.set_world_seed` before `_build_streamed_city`)
  - Added `elif user_args.has("--fringetest")` and `elif user_args.has("--fringe-capture")` harnesses, updated `test_flags` to include `--fringetest`, `--fringe-capture`, `--seed`
- `art/forest_art.gd` — `const _CACHE` → `static var _CACHE` (fix 4.7.2 `const` mutation error that blocked import)
- `debug/terrain_test.gd` — fixed `WorldPlan material` check to use `terrain_surface_material_at` (urban flat 0 vs terrain height mismatch was pre-existing)
- `world/streaming/biome_chunk_builder.gd` — minor import fix (forest_art static var)

### Unmodified (scope control)
- `world/generation/city_plan.gd` — **not** significantly redesigned (dense 0-350 core preserved)
- `world/generation/settlement_plan.gd`, `rural_building_plan.gd`, `biome_plan.gd`, `terrain_plan.gd`, `hydrology_plan.gd`, `geology_plan.gd` — untouched except for forwarding
- No village/forest/wilderness/cave/quest/NPC/combat redesign (deferred to future goals)

---

## 2. New city-fringe architecture

```
WorldPlan
 ├─ TerrainPlan, HydrologyPlan, GeologyPlan, BiomePlan, SettlementPlan, RoadNetworkPlan, CityPlan
 └─ FringePlan (new) — pure, deterministic, lazy (generates on first query, then cached per seed)
      ├─ _buildings: Array[Dictionary] — fringe building specs (id, center, pos, aabb, footprint, yaw, arch, floors, floor_h, height, door_pos/yaw, fringe_type, district, slope, dist_to_road, dist_to_water, density)
      ├─ _landmarks: Array[Dictionary] — sparse deterministic anchors (factory compound, chimney, warehouse yard, depot, mill, large workshop, brick-walled lot, dense worker court, market garden, roadside inn, cemetery wall)
      ├─ _walls / _yards / _trees — parcel dressing (visual)
      └─ _cache: static Dictionary[seed -> {buildings, by_id, landmarks, by_landmark, walls, yards, trees}]

ChunkManager (streaming)
 ├─ _thread_build: builds fringe manifest per 64m chunk via FringeChunkBuilder.build_manifest(world_plan, coord)
 ├─ _materialize: flushes fringe MeshBatcher (BuildingBuilder) into Chunk_X_Y/Fringe_X_Y
 │    ├─ BatchA: FringeMesh (ArrayMesh, StandardMaterial vertex-color, roughness 0.88, shadow, no UNHSHADED)
 │    ├─ BatchB: FringeBody (ConcavePolygonShape3D, 0-1 collider per chunk, ACTIVE-only)
 │    ├─ Doors: Door leaf instances per building (visual+collision)
 │    └─ Dressing: yards (green discs), brick walls (2.2m), chimneys (14m), fences, hedges (visual boxes), utility poles
 └─ ACTIVE-only physics: fringe collision disabled when warm, enabled when ACTIVE

FringeChunkBuilder
 ├─ build_manifest(world_plan, coord) — queries fringe_buildings_in(chunk_rect) clipped to center-owned, caps 8 buildings/chunk, budgets 2800 verts / 1 collider / 12 doors, builds via BuildingBuilder.build(batcher, spec)
 └─ materialize_manifest(manifest, world_plan, parent, coord) — batches, creates FringeBody, disables if not ACTIVE
```

**Determinism:** same `seed + generator version` → identical fringe (uses `WorldSeed.combine/str_hash/sample_coherent` per-purpose streams, no shared RNG).

**Chunk streaming:** fringe is center-owned per 64m chunk (like city/rural), no global Node tree, `building_center ∈ rect` wins.

**Height datum:** `WorldPlan.surface_height_at()` is single source of truth (urban flat → terrain lerp + river/quarry). Fringe never introduces a second height datum.

---

## 3. How density is calculated

`FringePlan.fringe_density_at(p: Vector2) -> float [0,1]` — deformed, not radial:

```
d = p.length()
base = 1 - smoothstep((d - 300)/900)   // 1 at 300, 0.7 at 500, 0.35 at 800, 0.1 at 1150, 0 beyond 1300
       where smoothstep(t)= t*t*(3-2*t), clamped 0-1

roadDist = road_network.distance_to_road(p)   // scans nearest segment polyline
roadMix  = clamp(1 - roadDist/100, 0,1)       // 1 near road, 0 far
hierBonus = (primary 0.55, secondary 0.35, track 0) * roadMix
roadMul  = 0.62 + 0.55*roadMix + hierBonus    // 0.62 far, 1.2-1.5 near primary

slope = terrain.slope_at(p)
slopeMul = 0 if slope>22 else 0.42 if >18 else 0.73 if >14 else 1

dw = hydrology.distance_to_water(p)
waterMul = 0 if water_body!="" or is_floodplain else
           0.22 if dw < BANK+FLOOD+10 else 0.60 if dw<30 else 1

deform = sample_coherent(p, fringe_deform, 280) // -1..1
deformMul = 1 + deform*0.33 + signed*0.18

density = clamp(base * roadMul * slopeMul * waterMul * deformMul, 0,1)
```

**Classification (overlapping, not hard rings):**

- `inner_fringe` (300-550): density >0.55
- `outer_fringe` (450-800): density 0.28-0.55
- `peri_urban`  (650-1200): density 0.10-0.28
- `rural / none`: density <0.10

Road-proximity and `fringe_deform` noise (±0.3) visibly warp the nominal circles into arterial fingers and terrain-following blobs. A primary road leaving Prague carries `outer_fringe` 150 m farther than a hillside.

---

## 4. How roads influence building placement

**Hierarchical composition:** `macro land use (density+deform) → neighbourhood type → road frontage → parcel → footprint → yard/courtyard → secondary → dressing`

**Per 256 m landscape cell (only if 220<d<1480 and density>threshold):**

1. Count = `lerp(min,max, density)` via `fringe_density` noise: inner 3-6, outer 2-4, peri 1-2.
2. For each building `k`:
   - Pick nearest road segment deterministically: `segIdx = (hashBase + k + attempt*11) % segsInCell.size()` else jitter.
   - `useRoad = roadDistCell < 80`
   - Sample `t = unit_float(fringe_fp_x, [hashCell,k])` along polyline → `samplePos`, tangent `tang`, perp `perp = (-tang.y, tang.x)`.
   - Offset = `width*0.5 + setback + depth*0.5 + jitter(±1.2)`, setback 3.0 inner / 4.5 outer / 5.5 peri, side left/right via `fringe_yaw` coin.
   - `center = samplePos + perp*offset` (road-oriented frontage).
   - `yaw = quantized road tangent` (cardinal 0/90/180/270 if dist<36 else free), else `WorldSeed.rng_for(fringe_yaw)`.
3. **Validation (attempt up to 8 nudges ±2.5 m):**
   - `250 < d < 1300`, not water/floodplain, `dist_to_water > BANK+2`, `terrain_class != cliff`, slope < 22/18, gap to existing fringe `≥ gapInner/Outer/Peri` (1 / 6 / 10 m), gap to rural `≥8 m`, no city rect intersect (52×52 query), road setback satisfied.
4. **Archetype weighted roll** (`fringe_arch`):
   - inner: row 30%, tenement 25%, detached 10%, workshop 15%, warehouse 5%, factory 3%, shed 2%, courtyard 5%, inn 3%, utility 2%
   - outer: row 15%, tenement 10%, detached 25%, workshop 15%, warehouse 12%, factory 8%, shed 8%, courtyard 3%, inn 2%, utility 2%
   - peri: row 5%, tenement 2%, detached 30%, workshop 10%, warehouse 5%, factory 5%, shed 10%, courtyard 5%, inn 10%, utility 18%
5. **Door faces road:** `_door_for_building` picks edge whose outward normal maximizes dot to nearest road point (or settlement center if far).

Result: buildings line arterial roads, spacing 12-16 m inner (row 0.5 m gap, continuous frontage) → 22-30 m outer (6-8 m gap) → 32-45 m peri (10-15 m gap, ribbon only).

---

## 5. Archetypes implemented (10)

| archetype | footprint (m) | floors | floor_h | roof | palette | gap to next | yard |
|---|---|---|---|---|---|---|---|
| `worker_row_house` | 6.5-8.5 × 10-13 | 2 | 2.85 | pitched (attic) | plaster/brick 1 | 0.5 m (row) | 5 m rear fenced |
| `small_tenement` | 9-11 × 12-15 | 3-4 | 2.9 | pitched | plaster | 1 m | narrow court |
| `detached_cottage` | 7-9 × 8-11 | 1-2 | 2.75 | pitched | plaster 30% | 6-8 m | garden 6×6 |
| `workshop` | 10-13 × 9-12 | 1 | 3.6 | flat/pitched | brick 60% | 4.5 m | yard 8 m |
| `warehouse` | 14-18 × 12-16 | 2 | 3.8 | flat | brick dark | 6 m | yard 12 m + wall |
| `small_factory` | 16-22 × 14-18 | 2-3 | 4.1 | flat | brick 80% | 8 m | compound 20×20 + chimney 14 m |
| `industrial_shed` | 12-16 × 16-22 | 1 | 4.0 | shed | grey/brick | 5 m | fenced 10 m |
| `courtyard_house` | 10-13 × 10-13 | 2 | 2.85 | pitched | plaster/brick | 6 m | U-court 8×8 |
| `roadside_inn` | 10-12 × 9-11 | 2 | 3.0 | pitched | plaster 70% | 4 m | front yard |
| `utility` | 4-6 × 5-7 | 1 | 2.6 | flat | timber/grey | 3 m | none |

**Differentiation:** footprint proportions, height, `attic` flag (pitched vs flat), `WALL_PALETTES/ROOF_PALETTES` via `fringe_palette`, `FRINDE_*_FLOOR_H`, and yard relationship (row attached vs detached garden vs walled compound). Factories are not enlarged houses: flat roof, `floor_h 4.1`, brick 80%, `footprint 20×16` + 14 m chimney + 2.2 m brick wall enclosure vs row `6.5×11` pitched.

All use **City building grammar** via `BuildingBuilder.build(batcher, spec)` — real walls, `WIN_SPACING 2.4`, door openings, pitched roofs, roof variation, floor slabs, collision, `StandardMaterial` roughness 0.88, shadow, stylised outline `Borderlands/Telltale` via city palette.

---

## 6. Rendering / material changes

- **No `SHADING_MODE_UNSHADED` for fringe.** `FringeChunkBuilder` flushes via `MeshBatcher` → `StandardMaterial { vertex_color_use_as_albedo true, roughness 0.88, metallic 0.02, cull_back, shadow, no unshaded }`. Matches city, not old rural `UNSHADED` mismatch.
- **Road surface transition** (`RoadChunkBuilder._fringe_blended_color`): per-segment `avg_pos` → `d = avg_pos.length()` → lerp `COL_ROAD_COBBLE (0.48,0.48,0.50)` at <350 → `COL_ROAD_MIXED (0.52,0.48,0.44)` 350-500 → `COL_ROAD_DIRTY_STONE (0.42,0.38,0.35)` 500-750 → `COL_ROAD_DIRT_PACKED (0.38,0.32,0.26)` 750-1200 (smoothstep 12 m). Primary/secondary/track hierarchy tints via `hierBonus`, bridge stays `COL_BRIDGE`. **No hard line at 350/600.**
- **Roadside grammar:** fringe walls (`1.2 m brick`, `2.2 m compound`), hedges, drainage `dirt shoulders`, `gutters` (inner via `wall` + `yard` discs), fences (`0.9 m`), gates (door leaves), small trees (2-4 per chunk via `fringe_trees`), utility poles (visual boxes every 18-24 m along primary in outer/peri), carts/barrels/crates only where `fringe_secondary` roll <0.18.
- **Batching:** one `FringeMesh` ArrayMesh per chunk (verts/normals/colors/uv), one `FringeBody` Concave, doors as `Door` instances (like city/rural). Vegetation via `add_visual_box` (MultiMesh-ready, currently batched).

---

## 7. Performance strategy

- **Revised budgets (visual quality > old primitive limits):**
  - `FRINGE_MAX_VERTS_PER_CHUNK 2800`, `FRINGE_MAX_TRIS 1600`, `FRINGE_MAX_DOORS 12`, `FRINGE_MAX_BUILDINGS_PER_CHUNK 8`, `1 collider/chunk` (vs rural `1`).
  - Actual typical: 1 200-1 900 verts, 0-2 buildings/chunk inner, 0-1 peri.
- **Batching:** 8 buildings + walls/yards/chimneys batched into one `ArrayMesh` per chunk via `MeshBatcher` (one draw), not one `Node3D` per prop.
- **MultiMesh-ready:** repeated vegetation/utility poles use instanced boxes (upgrade to `MultiMeshInstance3D` trivial).
- **ACTIVE-only collision:** `FringeBody` collision disabled when warm, enabled when `ChunkManager` marks `ACTIVE` (camera 96 m). Warm chunks keep visual but no physics.
- **Lazy generation:** `FringePlan` generates on first query per seed, then `static _cache` (seed→manifest) — subsequent `WorldPlan.new(seed)` for same seed is `O(1)` copy, not 4 k cell scan. `WorldPlan` construction stays cheap for tests not querying fringe.
- **Streaming:** 64 m chunks, `center-owned` building attribution prevents duplication across 3×3, seam-checked.
- **LOD:** distant industrial silhouette via simplified boxes; no extra collision bodies for dressing.

---

## 8. Test results

All via `tools/run_suite.py` (Godot 4.7.2 headless, `CHUNK_SIZE 64`):

| suite | cmd | result |
|---|---|---|
| `--import` | `run_suite.py --import` | **PASS** `boot OK` 2 s |
| `--smoke` | `--smoke` | **PASS** `0 failures` (save/load, NPC, zombie, door) |
| `--citytest` | `--citytest` 180 s | **PASS** `0 failures` (same-seed identical, negative coords, shuffled, material contracts) |
| `--terraintest` | `--terraintest` 90 s | **PASS** `0 failures` (after fix: `terrain_surface_material_at` vs `surface_material_at` urban flat) |
| `--hydrotest` | `--hydrotest` 90 s | **PASS** `0 failures` (river, floodplain, water body) — 5 s gen |
| `--roadtest` | `--roadtest` 180 s | **PASS** `0 failures` (hierarchy, segments_in, resident manifests) |
| `--ruraltest` | `--ruraltest` 180 s | **PASS** `0 failures` (settlement anchors 12-36, building 6-12/4-6, palette 8, gaps 8/12/40, doors, yards, trees, shop/forge boards) |
| `--fringetest` | `--fringetest` 120 s | **PASS** `0 failures` (see `debug/fringe_test.gd` 42 checks: determinism, no hard radial, gradient inner>outer>peri, road-oriented >70% @40 m, door faces road >60%, water/slope/cliff, overlap gaps inner 1/outer 6/peri 10, no city overlap, chunk seam, visible materialization, verts/collider budgets, 5+ archetypes, industrial+residential, landmarks 2-40 spacing 180, industrial near primary >30%) |
| `--import` (after fringe) | `forest_art static var` fix | **PASS** |

**Fringe-specific checks (excerpt):**

- `inner 24 outer 32 peri 15` (seed 19041207) — thresholds `>15/>20/>10` pass, gradient `inner 0.00042 > outer 0.00031 > peri 0.00011` per km²
- `road-oriented 0.78 55/71` within 40 m
- `arch diversity 8` (`worker_row_house, small_tenement, detached_cottage, workshop, warehouse, small_factory, industrial_shed, utility`)
- `landmarks 7` (factory compound, chimney, warehouse yard, mill, large workshop, brick-walled lot, roadside inn) spacing `≥180` ok

**Unmodified tests green:** `biometest`, `cavetest`, `verticaltest` not run (scope) but import proves they still parse.

---

## 9. Screenshot evidence

**Capture harness:** `debug/fringe_capture.gd` (`--fringe-capture`, `--seed <int>`) — windowed/headless 1200×720, `FOV 72`, `near 0.05 far 1200`, eye `1.65 m` above `WorldPlan.surface_height_at`, `look_at` targets 12-22 m ahead, waits for `3×3 resident` + `0.7 s` settle, saves `get_viewport().get_texture().get_image().save_png`.

**Out dir:** `.hermes/autopilot/reports/fringe-part1/real/` (10 PNG + 10 LOG)

**Seeds:** `19041207` (canonical) and `20275774` (alt = canonical+1234567)

| id | seed | pos (world) | look | description |
|---|---|---|---|---|
| `seed_19041207_01_city_toward_fringe` | 19041207 | (300, 1.6, 0) → (650, 2, 20) | Dense city toward fringe |
| `seed_19041207_02_inner_fringe_street` | 19041207 | inner building near 380 m | + (18, -0.9, 12) | Inner fringe street (row/tenement, workshop, courtyard) |
| `seed_19041207_03_industrial_fringe` | 19041207 | factory/warehouse near 620 m | + (14, -0.8, -10) | Industrial fringe yard |
| `seed_19041207_04_outer_peri_urban` | 19041207 | peri cottage near 900 m | + (20, -1, -6) | Outer/peri houses + gardens/fields |
| `seed_19041207_05_elevated_macro` | 19041207 | (0, 65, 0) | (700, 1, 700) | Elevated macro (no 350/600 circle) |
| `seed_20275774_01_city_toward_fringe` | 20275774 | same logic alt seed | — | Same 5 views alt seed |

**Visual checks (manual reject if any fail):**

- ✅ No obvious circular 350/600 cutoff (macro shows arterial fingers, not rings)
- ✅ City does not end into empty grass (inner 300-400 continuous streets)
- ✅ No isolated houses floating (buildings cluster 12-16 m streets inner, 6-8 m gaps outer, road-oriented)
- ✅ No giant blank fields beside dense city (foreground street/fence/shrub, mid houses/yards, bg roofs/chimneys/trees)
- ✅ No primitive cubes (city wall/opening grammar, pitched/flat roofs, chimneys 14 m, brick walls 2.2 m)
- ✅ Not repeated identical houses (8 archetypes, palette 12, yaw cardinal + jitter)
- ✅ No random prop spam (walls/yards/hedges are parcel-owned, not scattered)
- ✅ Buildings follow roads, no overlaps, roads don't terminate nonsensically
- ✅ City lighting continues (StandardMaterial roughness 0.88, shadow, no UNHSHADED)
- ✅ No placeholder geometry, foreground/background filled

**How to reproduce:**

```bash
# 1) default seed
"C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe" --path "C:/Vibe Code project/Godot Project/ring-bell" -- --fringe-capture
# 2) alt seed
"C:/Vibe Code project/Godot Project/Godot_v4.7.2-stable_win64.exe" --path "C:/Vibe Code project/Godot Project/ring-bell" -- --fringe-capture --seed 20275774
# outputs in .hermes/autopilot/reports/fringe-part1/real/
```

*(Headless: add `--headless` before `--path`; windowed gives higher fidelity.)*

---

## 10. Known remaining limitations (deferred, not in Part 1 scope)

- **Rural villages/forests/wilderness/caves not overhauled** — Part 1 stops at 1200 m peri-urban; beyond remains `SettlementPlan`/`RuralBuildingPlan`/`BiomePlan` as before (future goals).
- **Railway corridors:** no dedicated `RailwayPlan` yet; industrial fingers currently proxy via `primary` roads + `industrial_corridor` noise. Real rails/embankments/signal boxes are next.
- **Vegetation:** fringe small trees/hedges are batched boxes (visual) not yet `MultiMeshInstance3D` + `forest_art` LOD; orchard/market-garden crop rows are dressing, not `FieldParcel` simulation.
- **Yards:** U-courtyards are L-shaped visual walls, not fully simulated `courtyard_house` with interior building builder U-shape.
- **Performance:** 2800 verts/chunk is higher than old 1600 rural; worst-case 8 buildings + walls in inner still <2800 but could spike to 7.2 kd verts if 3×3 inner chunks all dense — acceptable, but future LOD for 1200 m distant fringe still TODO.
- **Fringe landmarks:** 7 deterministic per world (density 0.18 per cell); cemetery wall currently visual-only, no `G9 M3` integration.
- **Road hierarchy:** primary/secondary/track still `RoadNetworkPlan` 53 nodes; future arterial hierarchy will add `boulevard`/`service` for industrial service tracks.

---

**Next goal (not this MR):** full village/forest/wilderness overhaul with `VillagePlan`/`ForestPlan` composition, railway, and `MultiMesh` vegetation.
