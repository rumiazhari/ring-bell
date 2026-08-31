# AUTOPILOT TASK — The ONLY current implementation assignment

**Task:** Deterministic industrial corridor belt as distinct biome/material near road/rail intersections (M2 bounded slice)

**Grand Plan:** Generation 8 — M2 Industrial corridor biome

**Player-facing goal:** The player traveling along primary/secondary road corridors near quarry geology now reads a distinct industrial belt — contaminated ground palette 7a6a6a/brown-grey with slag-like tint, quarry-adjacent but road-bound — giving wayfinding, resource hints (slag/ore) and visual identity for future industrial gameplay without breaking existing terrain/water/biome/road/rural/cave streaming or budgets. Gives Czech industrial history reading.

## Context

Repository HEAD fd08c9c already streams deterministic cave entrance anchors (24/12/0 collider ACTIVE-only portal) with unified 54-peak and `GENERATOR_VERSION 2` additive. `WorldConstants.BIOME_VOCAB` is `urban_basin/river_floodplain/wet_meadow/arable_field/pasture_orchard/pasture/orchard/deciduous_forest/mixed_upland_forest/rocky_quarry` — no `industrial_corridor` yet. `GeologyPlan.strata_at` yields limestone/sandstone uplands with quarry_suitability>0.72, and `RoadNetworkPlan` MST+sparse provides primary 7.0/secondary 5.0/track 3.5 ribbons with is_bridge only at crossing_candidates. Macro plan Phase Arc C expects a readable industrial corridor belt with contaminated ground palette near rail/road intersections, slag heaps, polluted ground material, not just road graph. This task opens that pipe with the smallest verifiable slice: biome vocab extension + deterministic siting + 9×9 overlay palette, no new buildings/mines yet.

## Scope

**Implement:**

1. `world/generation/world_constants.gd` authoritative numerics: `BIOME_VOCAB` extended with `&"industrial_corridor"` (keep existing order, add at end before check), `INDUSTRIAL_CORRIDOR_VOCAB [&"industrial_corridor"]`, `INDUSTRIAL_ROAD_DISTANCE_MAX 80.0`, `INDUSTRIAL_QUARRY_SUITABILITY_MIN 0.52` (or reuse QUARRY_SUITABILITY_THRESHOLD 0.72 with relaxed 0.52 for corridor), `INDUSTRIAL_SLOPE_MAX_DEG 22.0`, `INDUSTRIAL_MIN_PARCEL_M 48.0`, `INDUSTRIAL_CORRIDOR_LIFT_M 0.03` (overlay lift same as biome), `COL_INDUSTRIAL_CORRIDOR 7a6a6a` + `COL_INDUSTRIAL_DARK 5e5850` slag, `INDUSTRIAL_PALETTE_VARIANT 0.08`, road setback `INDUSTRIAL_ROAD_SETBACK 0.0` (must be near road), building gap `INDUSTRIAL_BUILDING_GAP 4.0`, `MAX_INDUSTRIAL_INSTANCES 6` of global 48 (or reuse biome caps, but industrial ground is tint not instances). No duplicate inline numbers elsewhere.

2. `world/generation/world_seed.gd` — add `INDUSTRIAL_CORRIDOR_DOMAINS` ordered `[&"industrial_corridor", &"industrial_corridor_density"]` seed-separated from terrain/hydro/geology/biome/settlement/road/rural_building etc., handles negative coords via floori, no RNG sharing.

3. `world/generation/geology_plan.gd` — keep as is (strata limestone/sandstone/granite_like already industrial substrates); if adding coal/iron, add as alias to limestone with deterministic mapping via new domain, but keep GENERATOR_VERSION stays 2. Document that industrial corridor uses existing limestone/sandstone/granite_like as `industrial_substrate` (no new strata needed for M2).

4. `world/generation/biome_plan.gd` — extend pure `biome_at(p)` to yield `&"industrial_corridor"` with precedence: after `river_floodplain/wet_meadow/urban_basin/rocky_quarry` and before forest/arable (so quarry still wins on steep limestone, but industrial wins on gentle road-adjacent quarry). Siting predicate: `geology.quarry_suitability_at(p) > INDUSTRIAL_QUARRY_SUITABILITY_MIN (0.52)` and `strata in {limestone,sandstone,granite_like}` and `road_network.distance_to_road(p) < INDUSTRIAL_ROAD_DISTANCE_MAX 80` and `terrain.slope_at(p) < INDUSTRIAL_SLOPE_MAX_DEG 22` and `terrain.terrain_class_at(p) != cliff` and `hydrology.water_body_at(p)==&""` and `not hydrology.is_floodplain(p)` and `hydrology.distance_to_water(p) > BANK_W+2` and `p.length() >= URBAN_INNER_M 350` (suppressed inside urban). Add coherent field `industrial_corridor_density` via `WorldSeed.sample_coherent(p, industrial_corridor_density, 480)` >0.48 gate to avoid speckle and ensure contiguous 200-600 m belts. Handles negative coords via floori, deterministic byte-identical shuffled, seed-separated.

5. Extend `BiomePlan._is_arable_family` etc. helpers if needed, and add `is_industrial(p)` helper.

6. `world/streaming/biome_chunk_builder.gd` — extend 9×9 overlay to use industrial palette when `biome_at == industrial_corridor`: vertex color `7a6a6a` with dark variant `5e5850` via `industrial_corridor_density` jitter +-0.08 per sample, same `81 verts / <=128 tris` per chunk, lift `0.03` (reuse `BIOME_OVERLAY_LIFT_M`), at most 1 biome collider per chunk (industrial ground has 0 collider like field, not forest), MultiMesh instances `<=6` slag proxies capped of global 48 if desired (small Box 0.6x0.4x0.6 color 7a6a6a), deterministic, no duplication at +/-/-Z (shared-edge agreement >=7/9), fits within `FRAME_BUDGET_MS 12` together with field tilled 96/64 and canopy 12.

7. `world/generation/world_plan.gd` facade owns enriched `BiomePlan` and forwards `is_industrial` pure queries (private instance per worker thread, plan_mutex guards CityPlan).

8. `world/streaming/chunk_manager.gd` — no new counters needed (industrial is biome overlay, reuse biome counters), but ensure `t_biome_gen/mat` includes industrial derivation and `debug_lines()` shows industrial tint via same `biome verts|tris|colliders|instances|field_parcels|...` already, plus maybe `industrial` count in biome instances stats. Keep `MAX_MATERIALIZATIONS_PER_FRAME 1` + early `_collect_finished_jobs(pc)` + freed-Zombie guard extended, unified 54 peak not 63 (industrial Area3D not counted, 0 collider).

9. Update `docs/world/WORLD-CONTRACT.md` §23 with industrial corridor contract (vocab, siting gates, palette 7a6a6a, 9×9 overlay 81/128, ACTIVE-only, save exclusion, GENERATOR_VERSION stays 2, additive outside dense core), and `ARCHITECTURE.md`/`DEVELOPMENT.md` module map + telemetry + gate docs for `--biometest` updated to include industrial.

**Do NOT implement (out of scope):** quarry shafts/mines, slag heaps as separate mesh/terrain carve, rail assets, warehouse buildings, underground/cave graph extensions, city interior program, vertical network bridges, asset import beyond vertex-colored palette, sea/lake generation, building interior changes.

## Acceptance Criteria (prove independently, not one aggregate fallback)

1. **Determinism & siting** — same-seed `biome_at(p)` and `biome_at` via `BiomePlan`/`WorldPlan` byte-identical shuffled including negative coords, different seed materially differs (≥3/9 probes differ + ≥30% placements differ OR biome vocab differs), `industrial_corridor` occurs only where `quarry_suitability>0.52` and `strata in {limestone,sandstone,granite_like}` and `distance_to_road<80` and `slope<22` not cliff/water/floodplain/urban 350 and industrial_density>0.48, at least 2 distinct industrial belts (200-600 m) in 5-seed world transect, no entrance inside URBAN_INNER_M 350, industrial not inside water/floodplain/cliff.

2. **Materialization budgets & seams** — manifests byte-identical shuffled, each chunk `81 verts / <=128 tris` 0/1 collider (industrial ground 0 collider like field, forest keeps 1), no duplication at shared borders (shared-edge biome agreement >=7/9 at + and - and -Z), at least 9 resident biome chunks around industrial+road transect with at least 3 industrial_corridor chunks, unified 54 peak not 63 (industrial Area3D/MultiMesh not counted, verifier scans `get_nodes_in_group("biome_chunk")` body count vs `biome_colliders`), `biome_instances <=48` per chunk (industrial slag <=6 of 48, field hedgerow 8 orchard 6 canopy 12 share).

3. **Streaming & telemetry** — ChunkManager streams biome overlay with industrial palette alongside city+terrain+water+road+rural+cave without duplication: 3×3 ACTIVE around industrial corridor claims `active biome <=9` (industrial included), walking 480 m beyond `UNLOAD_RADIUS` unloads biome chunks and returning regenerates identical manifests (center/pos/biome_ids/colors/verts/tris/colliders/instances), `debug_lines()` contains `t_biome_gen|t_biome_mat` and `biome verts|tris|colliders|instances`, `t_biome_gen/mat` within `FRAME_BUDGET_MS 12` (industrial slice ≤2 ms added), pacing 1-per-frame + freed-Zombie guard remains 0 failures.

4. **Persistence & compatibility** — `save_state()` excludes generated biome/industrial geometry (only deltas sibling pattern), deterministic re-derive on load, `GENERATOR_VERSION` stays 2 additive, `WorldPlan` pure, `CityPlan` IDs / Terrain 17×17 / hydrology CX etc unchanged proved by `--citytest + --terrainmaterialtest + --hydrotest + --biometest + --roadtest + --ruraltest + --cavetest` each 0 failures with retained seams, cave portal "Enter cave" still monitorable.

5. **Existing budgets not weakened** — `--citytest, --terrainmaterialtest, --hydrotest, --biometest, --roadtest, --ruraltest, --cavetest, --cityruntime, --walkthrough, --havoctest, --smoke` each `finished with 0 failure(s)` (3221225477 with marker not failure; guards extended), closed door leaf blocks/open clears without RID exclusion, walkthrough climbs 5 storeys no teleports, cave portal prompt still ACTIVE-only.

6. **Player-facing proof archived** — one normal windowed CITY run log+PNG under `.hermes/autopilot/reports/SPEC-INDUSTRIAL-windowed.*` shows F3 overlay `biome verts|tris|colliders|instances|field_parcels|...|industrial_corridor` alongside active road/water/terrain/rural/cave, then 600-900 m to industrial belt near road intersection (x~800-1400, road distance <80, quarry_suitability >0.52, slope <22) with contaminated ground palette 7a6a6a visible at terrain+0.03 and slag tint 5e5850, no seam cracks, referenced in `WORLD-CONTRACT §23`, `ARCHITECTURE.md`, `DEVELOPMENT.md` updated.

## Required Tests / Evidence

- `python tools/run_suite.py --biometest 300` (extended to prove industrial gates, vocab, contiguity 200-600 m belts not speckles, 9 resident biome chunks with industrial) plus `--citytest 400`, `--terrainmaterialtest 300`, `--hydrotest 300`, `--roadtest 400`, `--ruraltest 400`, `--cavetest 400`, `--cityruntime 300`, `--walkthrough 360`, `--havoctest 240`, `--smoke 180` each 0 failures.
- Determinism harness: prints `BiomeTest finished with 0 failure(s)` plus shared-edge 0.02 agreement, industrial belt proof.
- Windowed proof PNG+log (normal windowed, not --shot dummy, 1200×720) archived under `.hermes/autopilot/reports/` with visible industrial palette and F3 overlay.

## Out of Scope Forbids

- No cave shafts/chambers/tunnels beyond entrance box+portal; no flood/collapse; no mining loot beyond future slag ore; no vertical network; no city interior rooms; no asset import beyond vertex-colored industrial palette; no new autoload/project setting; no terrain trench carve.

## Delivery

Builder overwrites `BUILD_RESULT.md` (and `.hermes/autopilot/BUILD_RESULT.md`) after commit+push to `origin/master`, records task hash (SHA256 of this file), HEADs, changed files, tests with lines `finished with 0 failure(s)` or honest failure with blocker, player-facing verification, limitations, completion belief.
