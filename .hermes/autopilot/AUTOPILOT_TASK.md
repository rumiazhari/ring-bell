# AUTOPILOT TASK — The ONLY current implementation assignment

**Task:** Deterministic quarry-linked cave entrance anchors streamed per chunk (M1 bounded slice)

**Grand Plan:** Generation 8 — M1 Underground entrance foundation

**Player-facing goal:** The player exploring quarry uplands / rocky limestone can discover deterministic cave entrance portals — small entrance boxes at terrain+0.01 with portal prompt "Enter cave" — proving the underground pipe is open without breaking existing rural/terrain streaming or budgets. Gives wayfinding to future caves/mines and unlocks vertical/survival depth.

## Context

Repository HEAD 45ae639 already streams rural shells/wells/forage/hearth/workbench/granary deterministically with unified 54-peak ACTIVE-only physics and `GENERATOR_VERSION 2`. `GeologyPlan.quarry_suitability_at` >0.72 on limestone uplands with slope ≥28 or cliff identifies quarry sites, but no `cave_entrances` exist yet. Macro plan Phase 5 expects `cave_plan.gd` + `underground_chunk_builder.gd` with stable entrance graph. This task opens that pipe with the smallest verifiable slice: entrances only (no deep graph, no flooded/collapse yet).

## Scope

**Implement:**

1. `world/generation/cave_plan.gd` — pure plan `cave_entrances_in(rect: Rect2) -> Array[Dictionary]` and helpers `cave_entrances()`, `nearest_cave_entrance(p)`. Each entrance `{id, pos, yaw, kind: &"cave_entrance", settlement_id?, geology, aabb, height: 2.2, radius: 1.8}` deterministic via `WorldSeed` domains `&"cave_entrance"` + `&"cave_entrance_yaw"` (ordered, seed-separated). Siting: 0-1 per 256 m landscape cell where `quarry_suitability>0.72` and `(slope≥28 or terrain_class==cliff)` and `terrain_class != cliff` water check? Actually entrance on buildable slope <22 near cliff, not on floodplain/water, distance_to_water> BANK+2, road ≥4m not is_bridge, spacing ≥32m from other entrances and ≥8m from rural buildings/wells/forage, suppressed inside `URBAN_INNER_M 350`. Center ownership gives no duplication at +/− borders. Negative coords handled via `floori`.

2. Extend `world/generation/world_plan.gd` facade to own `CavePlan` and forward `cave_entrances*` pure queries (with `plan_mutex` guard analogous to RuralBuildingPlan, private instance per worker thread).

3. `world/streaming/underground_chunk_builder.gd` — per-chunk manifest `build_manifest(WorldPlan, coord)` keys `coord, origin, size, cave_entrances, cave_vertices, cave_triangles, cave_colliders, has_cave, cave_gen_ms` deterministic byte-identical shuffled. Materialize `Cave_X_Y/CaveMesh/CaveBody`? For this slice: entrance is **visual BoxMesh** at `terrain+0.01` (footprint 3.6×3.6, height 2.2, color 5a4a3a dark limestone, vertex-colored) plus **Area3D portal** `CavePortal` with `InteractableComponent` prompt "Enter cave" monitorable ACTIVE-only, no physics collider counted toward `54` peak (like forage). Chunk owns entrance iff `pos` inside rect. Caps `MAX_CAVE_ENTRANCES_PER_CHUNK 1`, `MAX_CAVE_VERTS_PER_CHUNK 24`, `MAX_CAVE_TRIS 12`.

4. Extend `world/streaming/chunk_manager.gd` mirroring terrain/water/biome/road/rural pipeline: counters `_cave_vertices_total/_cave_triangles_total/_cave_colliders_total/_cave_mat_ms_total`, per-chunk `cave_entrances/cave_manifest/cave_gen_ms/cave_mat_ms/layers_cave`, stats `cave_vertices/cave_triangles/cave_colliders/t_cave_gen/t_cave_mat/active cave (warm)`, telemetry in `debug_lines()` as `cave verts|tris|colliders t_cave_gen|t_cave_mat active cave (warm)`. `t_cave_gen` measured in worker via private `WorldPlan`, `t_cave_mat` on main. ACTIVE-only portal (warm retains mesh but disables Area3D `monitoring=false`/`collision_layer=0`). Streaming pacing `MAX_MATERIALIZATIONS_PER_FRAME 1` respected with early `_collect_finished_jobs(pc)` + freed-Zombie guard extended.

5. `world/generation/world_constants.gd` authoritative numerics: `CAVE_ENTRANCE_VOCAB`, caps, footprint, height, colors, spacing, road setbacks, `MAX_CAVE_ENTRANCES_PER_CHUNK`, `MAX_CAVE_VERTS/TRIS`, `SEAM_CONTINUITY_TOL_M` reuse, no duplicate inline numbers elsewhere.

6. `save_manager`/`ChunkManager.save_state()` persists only `deltas.cave_discovered: {entrance_id: true}` sibling to other deltas, never generated geometry; deterministic re-derive on load; per-chunk deltas re-applied before materialize to keep portal discovered state.

7. Update `docs/world/WORLD-CONTRACT.md` §19 with cave entrance contract (vocab, siting gates, manifest, budgets, ACTIVE-only, save exclusion, GENERATOR_VERSION stays 2, additive outside dense core), and `ARCHITECTURE.md`/`DEVELOPMENT.md` module map + telemetry + gate docs for `--cavetest` (? or extend `--ruraltest`?).

**Do NOT implement (out of scope):** full cave graph (shafts/chambers/branches/collapse/flooded), deep geometry, mining gameplay, vertical network bridges, industrial corridor biome, city interior program, asset import, sea/lake generation.

## Acceptance Criteria (prove independently, not one aggregate fallback)

1. **Determinism & siting** — same-seed `cave_entrances` + `cave_entrances_in` byte-identical shuffled including negative coords, different seed materially differs (≥3/9 probes differ + ≥30% placements differ), 0-1 per 256 m cell where quarry-suitable limestone/slope≥28/cliff, spacing ≥32, road ≥4 not bridge, water/floodplain/cliff gates via real `WorldConstants` for canonical +4 seeds, center ownership no duplication at +/−/−Z, at least 3 entrances in 5-seed quarry belt transect, no entrance inside `URBAN_INNER_M 350`.

2. **Materialization budgets & seams** — manifests byte-identical shuffled, each chunk ≤1 entrance ≤24 verts/12 tris 0 collider (Area3D only), no duplication at shared borders, at least 9 resident cave chunks around quarry transect with entrance vocab `cave_entrance`, unified 54 peak not 63 (cave Area3D not counted, verifier scans `get_nodes_in_group("cave_chunk")` body count vs `rural_colliders`).

3. **Streaming & telemetry** — ChunkManager streams cave entrances with city+terrain+water+biome+road+rural without duplication: 3×3 ACTIVE around quarry claims `active cave ≤3` (sparse), walking 480 m beyond `UNLOAD_RADIUS` unloads cave chunks and returning regenerates identical manifests (center/pos/yaw/kind), `debug_lines()` contains `t_cave_gen|t_cave_mat` and `cave verts|tris|colliders`, `t_cave_gen/mat` within `FRAME_BUDGET_MS 12` (cave slice ≤3 ms), `ChunkManager` pacing 1-per-frame + freed-Zombie guard remains 0 failures.

4. **Persistence & compatibility** — `save_state()` excludes generated cave geometry, only `deltas.cave_discovered` persists, deterministic re-derive on load with per-chunk deltas re-applied before materialize keeps discovered flag, `GENERATOR_VERSION` stays 2 additive, `WorldPlan` pure, `CityPlan` IDs / Terrain 17×17 / hydrology CX etc unchanged proved by `—citytest + —terrainmaterialtest + —hydrotest + —biometest + —roadtest + —ruraltest` each 0 failures with retained seams.

5. **Existing budgets not weakened** — `--citytest, --terrainmaterialtest, --hydrotest, --biometest, --roadtest, --ruraltest, --cityruntime, --walkthrough, --havoctest, --smoke` each `finished with 0 failure(s)` (3221225477 with marker not failure; guards extended to CavePortal), closed door leaf blocks/open clears without RID exclusion, walkthrough climbs 5 storeys no teleports, cave portal "Enter cave" prompt monitorable ACTIVE-only with entered flag sibling to forage/well.

6. **Player-facing proof archived** — one normal windowed CITY run log+PNG under `.hermes/autopilot/reports/SPEC-CAVE-windowed.*` shows F3 overlay `cave 1/2 verts` alongside active road/water/terrain/rural, then 600-900 m to quarry upland with entrance box 5a4a3a at terrain+0.01 portal prompt visible, no seam cracks, referenced in `WORLD-CONTRACT §19`, `ARCHITECTURE.md`, `DEVELOPMENT.md` updated.

## Required Tests / Evidence

- `python tools/run_suite.py --cavetest 400` (or `--ruraltest 400` extended) proving criteria 1-3, plus `--citytest 400`, `--terrainmaterialtest 300`, `--hydrotest 300`, `--biometest 300`, `--roadtest 400`, `--ruraltest 400`, `--cityruntime 300`, `--walkthrough 360`, `--havoctest 240`, `--smoke 180` each 0 failures.
- Determinism harness: prints `CaveTest finished with 0 failure(s)` plus shared-edge 0.02 agreement, 9 resident cave chunks proof.
- Windowed proof PNG+log (normal windowed, not --shot dummy, 1200×720) archived under `.hermes/autopilot/reports/` with visible entrance box and F3 overlay.

## Out of Scope Forbids

- No cave shafts/chambers/tunnels beyond single entrance box+portal; no flood/collapse; no mining loot; no vertical network; no industrial biome; no city interior rooms; no asset import beyond vertex-colored box; no new autoload/project setting.

## Delivery

Builder overwrites `BUILD_RESULT.md` after commit+push to `origin/master`, records task hash (SHA256 of this file), HEADs, changed files, tests with lines `finished with 0 failure(s)` or honest failure with blocker, player-facing verification, limitations, completion belief.

