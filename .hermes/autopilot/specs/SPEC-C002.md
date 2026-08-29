# SPEC-C002 — Vltava-Anchored Hydrology Slice

Status: ARCHITECT-READY FOR CONTROLLER AUTHORIZATION
Milestone ID: `P2.2-HYDRO-ANCHORS`
Owner: `lunaringbell` (architecture/design/review); `museringbell` (implementation/QA)
State revision: 0

## Player-facing objective

From the streamed Prague basin the player can leave the dense historic core, follow readable rolling hills toward a deterministic Vltava-like river valley, see a continuous water surface with banks and floodplain, and recognize bridge-ready crossing corridors where a future road graph will span the water. The valley is the first landscape-scale landmark beyond buildings: it explains why the city sits where it does, gives a useful reason to travel, and creates a natural geographic constraint for the next biome/settlement layers. No new building archetype or economy is required — the gain is a believable, explorable Czech river corridor that frames longer journeys.

This is the next bounded milestone because traversal through buildings is now honest (P0.5-C001 closeout: 7/7 harnesses green, closed leaf blocks aperture center, walkthrough climbs 5 storeys and back with no teleports). Terrain is streamed with measured budgets (17x17 terrain mesh, 1 collider/chunk, 9 active terrain bodies). The world beyond the 350 m urban flat is still featureless hills: without water, every direction looks the same and there is no geographic logic to constrain future farms, forests, roads, or villages. Hydrology must be established before biome, geology, settlement and road layers can be placed plausibly, per the macro plan's "geographic logic precedes decoration" rule.

This milestone is deliberately a thin playable slice, not the full macro-world. It adds one deterministic primary river plus 2 seed-driven tributaries, clipped water surfaces and banks, and their streaming/telemetry contracts, while explicitly postponing in-city river carving, road bridges, lakes/reservoirs beyond a placeholder, underground water, and any terrain-trench rework inside the 350 m historic core.

## Current baseline and constraints

The inspected canonical checkout is `C:/Vibe Code project/Godot Project/ring-bell` at Git head `f0bfe4f` (accept_with_deferred for P0.5-TRAVERSAL-CLOSEOUT). Controller state is `enabled=true phase=architecting cycle=2`. Evidence:

- `--citytest`, `--terrainmaterialtest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each end with `finished with 0 failure(s)` per REVIEW-C001-R00 (recent headless re-run confirms cityruntime green). `WorldSeed.GENERATOR_VERSION` remains 2, saves store seed/version/discovery/deltas only, generated geometry excluded.
- `TerrainPlan` is layered deterministic heightfield with `WorldPlan` facade, `TerrainChunkBuilder` 17x17 manifest per 64 m chunk, urban compatibility radial mask `URBAN_INNER_M=350` flat to 0 and transition to `URBAN_OUTER_M=600`. Ground ownership: city flat box only where chunk rect wholly inside 350, otherwise terrain owns ground — no competing flat/terrain surfaces at boundary.
- `ChunkManager` pipelines worker-thread `fill_batcher` + `build_manifest` (private plans, plan_mutex) and main-thread `materialize`; budgets `t_gen/t_mat/t_terrain_gen/t_terrain_mat`, ACTIVE `<=1` (3x3=9), WARM `<=2` (5x5), hysteresis `UNLOAD=3`, ACTIVE-only city collision (warm visuals, active physics) as budgeted optimization.
- `WorldConstants` documents `WATER_LEVEL_Y=-2.0` as datum only, `WATER_BODIES` vocabulary names sea|lake|river|reservoir but no water generated in P2, `sea` explicitly not generated in continental Prague basin.
- Deferred findings from C001 to fold naturally:
  1. Archive one normal windowed CITY run (WASD/E door swing, stair climb to roof, F3 overlay) as PNG/log — headless `--shot` cannot capture due to dummy renderer null texture.
  2. Document ACTIVE-only city collision (warm visuals without Static, active physics) as intentional budgeted optimization versus previous warm+active Static assumption in ARCHITECTURE.md/DEVELOPMENT.md.
  3. Reduce cosmetic headless shutdown noise: Windows exit 3221225477 when marker present and ObjectDB `!is_inside_tree()` warnings on smoke/walkthrough shutdown.

Previous terrain and city contracts remain authoritative: 64 m chunks, deterministic per `(seed, coord)` via `WorldSeed` domain-separated `sample_coherent` (floor lattice + smoothstep), no `String.hash()` or time/scene state, worker-safe private plans, one merged vertex-colored ArrayMesh per chunk per layer, one terrain collider per chunk.

## Gameplay value

Improves at least three enjoyment pillars in one thin slice:

- **Exploration and discovery** — a continuous river valley becomes the first extra-urban landmark readable from hills and from the city edge. The player chooses to follow it, seek a ford/bridge corridor, or use it to orient.
- **Agency and meaningful choice** — water is a constraint: crossing corridors are wider than streets, floodplain vs bank vs hills give risk/reward (exposed crossing vs longer detour). Future farm/road/settlement placement will inherit that constraint.
- **Coherent Czech identity** — a Vltava-like north-south valley with Bohemian rolling hills makes the fictional basin recognizably Bohemian without claiming to be a 1:1 Prague map. The setting stays continental (no sea in this slice).
- **Performance and stability foundation** — hydrology is introduced with the same measured budget discipline as terrain: per-chunk manifest determinism, seam continuity within `SEAM_CONTINUITY_TOL_M`, one water collider per chunk max, 9 active water bodies max, explicit `t_hydro_gen/t_hydro_mat` timings, save exclusion of generated water.

Cosmetic polish accompanies but does not replace the playable system: water material colors and bank dressing are minimal vertex-colored proxies, not authored textures or post-processing.

## Scope

### 1. Deterministic hydrology plan

Create `world/generation/hydrology_plan.gd` as a pure plan (no Node access, no unseeded randomness, no chunk-local state) and expose it through `world/generation/world_plan.gd` facade.

Required queries (exact names may be adjusted, but semantics must exist and be used by the materializer):

- `river_center_x_at(z: float) -> float` — centerline X of the primary corridor at world Z.
- `river_width_at(z: float) -> float` — half-width or full width parameter (36–60 m full width range, smoothly varying with meander scale).
- `water_level_at(p: Vector2) -> float` — water surface Y at plan point (mean about `-1.2`, variation `±0.6` along flow axis; constant across width within a chunk).
- `water_body_at(p: Vector2) -> StringName` — `&"river"`, `&"tributary"`, or `&""` (dry). Vocabulary must be subset of `WorldConstants.WATER_BODIES` plus empty.
- `water_body_id_at(p: Vector2) -> String` — stable ID such as `river_main` or `trib_<k>` for the body containing `p`, empty if dry.
- `distance_to_water(p: Vector2) -> float` — signed distance to nearest water edge (negative inside water).
- `bank_distance_at(p: Vector2) -> float` — distance to nearest bank line (0 at edge).
- `flow_direction_at(p: Vector2) -> Vector2` — deterministic unit XZ flow (primary flows northward `+Z` with meander-driven lateral wobble; tributaries flow toward their confluence).
- `crossing_candidates(rect: Rect2) -> Array[Dictionary]` — at least one bridging corridor per ~800 m along primary where `|distance_to_water|` < bank+floodplain and terrain slope < `BUILDABLE_MAX_SLOPE_DEG`. Each dict: `{id, center: Vector2, width, axis, water_id}`.

Generation contract:

- Primary corridor is deterministic from seed: mean center `CX = 620 + S*90` where `S` is `WorldSeed.unit_float("hydro_cx") * 2 - 1` (so corridor sits outside dense core, `~530–710` m east of origin, clearly beyond `URBAN_OUTER_M=600` for most of its length). Meander `MX(z) = A * sin(z/W + phi)` with `A=72.0`, `W=1350.0`, `phi` seeded, plus secondary `18 * sample_coherent_signed(Vector2(0,z), &"hydro_meander2", 600)`. This keeps the river readable, out of the historic core, and not revisiting spawn plaza.
- Width varies smoothly: `38 + 12 * sample_coherent(Vector2(0,z), &"hydro_width", 900)` → 38–50 m full width (~19–25 half). Entrusted to `WorldConstants` range.
- Tributaries: 2 seeded streams. Each has an anchor `Ax` outside corridor `CX ± (260 ±80)`, upstream seed `Az` ~ `-2200 + k*1400` plus seeded jitter, confluence `Cz` deterministically where `Ax` line approaches primary within 180 m. Tributary centerline is a quadratic bezier anchor→mid→confluence, width 14–22 m, water level inherits primary level minus small fall `0.015 * (Cz - z)` northward fall.
- Valley alignment: the HydrologyPlan owns the river; TerrainPlan remains unchanged this cycle (valley depression at `x=-180` stays as small decorative bias, not forced to match new corridor). Water materializer will visually span banks/floodplain over existing terrain height; a full terrain trench carve through the basin is deferred.
- Monotonic flow: `flow_direction` must be unit length, northward `.y > 0.35` (XZ `y` component for `Vector2(x,z)`) along primary, and `dot(tributary_flow, direction_to_confluence) > 0.45` for tributaries.
- Floodplain/banks: `BANK_W=9.0`, `FLOOD_W=26.0` (documented in WorldConstants). `is_floodplain(p)` when `abs(dist_to_center) in (half+bank, half+bank+flood]` and `terrain_class != cliff`.

Pure and deterministic: every query is function of `seed + domain + world coordinates` via `WorldSeed.sample_coherent*` or `unit_float`; no RNG sharing between unrelated hydrology queries; no chunk visit order dependence; inclusive of negative world coordinates.

### 2. Water chunk materialization

Create `world/streaming/water_chunk_builder.gd` and integrate through `WorldPlan` + `ChunkManager`.

Manifest per 64 m chunk via `static build_manifest(world_plan: WorldPlan, coord: Vector2i) -> Dictionary`:

- Keys: `coord, origin, size, resolution, water_vertices, water_triangles, water_colliders, heights (water surface Y per sample), normals, material_ids, class_ids (water/dry), district hint, gen_ms`. Deterministic for `(seed, coord)`.
- Sampling: 9x9 or 17x17 grid at 8 m or 4 m spacing over chunk rect (choose 9x9 = 81 samples, 128 triangles for minimal budget; document choice). For each sample `p`, query `water_body_at(p)` to decide wet/dry, set `water_y = water_level_at(p)` if wet else `NAN`. Shared world-space edges matching terrain's world-space edge handling so adjacent chunks agree on the centerline sampling within `SEAM_CONTINUITY_TOL_M`.
- Visual water surface: one `ArrayMesh` per wet chunk: vertices at `(x, water_y, z)` interpolated bilinearly across the wet polygon, clipped to chunk rect (water outside rect omitted). Vertex colors via `WorldConstants` water palette (muted Vltava teal). Indices share the same winding rule as terrain.
- Banks: add a narrow bank ribbon along water edge (visual `ALLEY_FLOOR`-like earth, 1.5 m wide, visual only) to hide the terrain/water Z-fighting seam; no extra collider.
- Collision budget: at most one `ConcavePolygonShape3D` per wet chunk (water surface query surface, `backface_collision=true`). Dry chunks have 0 water colliders. Do not add per-sample or per-triangle bodies, no per-waypoint volumes.

Materialization `static materialize(parent: Node3D, manifest: Dictionary) -> Dictionary`:

- Creates `Water_X_Y` Node3D under chunk `Chunk_X_Y`, with `WaterMesh` MeshInstance3D and `WaterBody` StaticBody3D + ConcavePolygonShape3D (when wet). Mirrors terrain materialization signature so ChunkManager can measure `water_mat_ms`. Returns stats `water_vertices, water_triangles, water_colliders, water_gen_ms, water_mat_ms, water_nodes`.

Urban compatibility: water manifests are generated for all chunks, but the primary corridor sitting `>530` m from origin means the spawn chunk `0,0` stays dry; no building footprint overlap check is required this slice. If any city block would intersect future in-city water, that block's handling is deferred (documented out of scope).

### 3. Streaming, telemetry, docs, and cleanup

- Extend `world/generation/world_constants.gd` with authoritative hydrology constants: `HYDRO_CORRIDOR_CX_MEAN`, `HYDRO_CORRIDOR_JITTER`, `HYDRO_MEANDER_AMPL/ WAVELENGTH`, `RIVER_WIDTH_MIN/MAX`, `TRIBUTARY_WIDTH_MIN/MAX`, `BANK_W`, `FLOODPLAIN_W`, `WATER_LEVEL_MEAN`, `WATER_LEVEL_VAR`, `TRIB_COUNT`. No builder or test may duplicate these numerics.
- Extend `world/generation/world_seed.gd` with domain names for hydrology: add `&"hydro"`, `&"hydro_meander2"`, `&"hydro_width"` etc. to domain separation (or reuse `TERRAIN_DOMAINS` extended list; must remain explicit).
- Extend `WorldPlan` facade to own `HydrologyPlan` and forward water queries; `WorldPlan._init` constructs both plans from same seed.
- `ChunkManager`: mirror terrain pipeline — new counters `_water_vertices_total/_water_triangles_total/_water_colliders_total/_water_mat_ms_total`, new per-chunk record fields `water_vertices/water_triangles/water_colliders/water_manifest/layers_water`, new stats keys `water_vertices/water_triangles/water_colliders` and timings `water_gen_ms/water_mat_ms`. Thread-safe build holds `holder["water"]` and `water_gen_ms` measured inside worker (private WorldPlan). Active-ring rule: water collider counted toward `active water` only when chunk state ACTIVE, analogous to terrain; at most 9 active water colliders (3x3). Warm retains visual WaterMesh but may keep water collision disabled if builder chooses active-only (document choice).
- `docs/world/WORLD-CONTRACT.md`: add section 11 Hydrology slice `P2.2` documenting corridor, meander, width, level, banks/floodplain, tributaries, sea-excluded decision, manifest keys, collision budget, compatibility_mode string, and the explicit deferral of in-city trench + bridge graph.
- `ARCHITECTURE.md` and `DEVELOPMENT.md`: add/update sections documenting streaming telemetry (t_gen/t_mat/t_water_gen/t_water_mat, active water/terrain counts), and the ACTIVE-only city collision optimization (warm visuals without Static, active physics) versus previous assumption. Keep edits narrow and factual.
- Headless harness noise: where `world/main.gd` or smoke/walkthrough probes fetch `global_transform` after queue_free during shutdown, guard with `is_instance_valid` + `is_inside_tree()` before reading transforms; ensure any `ObjectDB` script warnings are quelled without masking real failures. Document that Windows exit `3221225477` with `finished with 0 failure(s)` remains a pass.
- Manual archive (folding C001 deferred): during this cycle's ordinary windowed proof, capture at least one normal WINDOWED CITY run (not `--shot`): WASD approach to a qualifying multi-storey building, E door swing through entry, stair climb to roof, F3 overlay visible, then walk 600–900 m east to the river valley and observe water surface/banks/floodplain from a hill. Store `png` + `log` under `.hermes/autopilot/reports/` or `junk/` and reference path in the builder handoff. This satisfies the prior windowed-screenshot deferred finding plus the new river proof.

## System ownership and interfaces

| System | Owns | Required invariant |
|---|---|---|
| `WorldSeed` | Seeded domains + `sample_coherent` helpers | No unseeded randomness; hydrology domains domain-separated. |
| `WorldConstants` | All hydrology numerics (CX, meander, width, level, bank/flood) | Builders/tests import, never duplicate inline numbers. |
| `HydrologyPlan` | Primary river + 2 tributaries pure queries | Deterministic per `(seed, world XZ)`, order-independent, covers negative coords. |
| `WorldPlan` | Facade owning `TerrainPlan` + `HydrologyPlan` | Forwards terrain + water queries; constructed once per worker thread. |
| `TerrainPlan` / `TerrainChunkBuilder` | Terrain heightfield + 17x17 manifests | Unchanged this cycle; no water-driven trench carve yet. |
| `WaterChunkBuilder` | Per-chunk water manifest + materialization | World-space shared edges, one mesh + at most one collider per wet chunk. |
| `ChunkManager` | Streaming, ACTIVE/WARM/COLD, telemetry, deltas | Thread build measures `water_gen_ms`; materialize measures `water_mat_ms`; budgets enforced. |
| `CityPlan` / `ChunkBuilder` / `BuildingBuilder` | Deterministic city blocks/buildings/interiors | Unchanged; river placed outside dense core so no footprint overlap this slice. |
| `debug/hydrology_test.gd` (or `hydro_test.gd`) | Pure hydrology + material proof harness | Asserts determinism, continuity, material budgets, seam, save exclusion. |

Public interfaces remain compatible; no new autoload or project setting is authorized. Small diagnostic helpers stay in their owner.

## Construction sequence

### Phase 0 — Reproduce and protect the baseline

1. Preserve all unrelated dirty files and user work (do not reset/clean).
2. Run focused gates and capture their current markers:
   `python tools/run_suite.py --import 120` and `python tools/run_suite.py --citytest 120` as sanity; full matrix per below after build.
3. Add behavioral assertions/diagnostics FIRST (RED): hydrology plan determinism (same seed shuffled vs forward identical, different seed differs, negative coords in vocab), river continuity probe at chunk seams, tributary convergence dot, bank/floodplain distances, flow unit length, water manifest edge equality, budget counters, save exclusion. Run with failing/empty implementation to confirm they fail for the expected reason; do not retain a test written only after the implementation already passes.

### Phase 1 — Plan layer

1. Extend `world/generation/world_constants.gd` with hydrology constants (documented, authoritative).
2. Extend `world/generation/world_seed.gd` domain list to include hydrology domains.
3. Implement `world/generation/hydrology_plan.gd` with pure meander + width + tributary bezier + level + signed distance + flow + crossing candidates, using only `WorldSeed` helpers.
4. Extend `world/generation/world_plan.gd` to own `HydrologyPlan` and forward `water_*` queries.
5. Run `--hydrotest` focused checks (plan determinism, continuity, tributaries) before materialization; keep failures honest.

### Phase 2 — Materialization + streaming

1. Implement `world/streaming/water_chunk_builder.gd` manifest + materialize (9x9 low-cost or justified 17x17), world-space shared edges, clipped water surface mesh, bank visual ribbon, at most one collider per wet chunk.
2. Integrate into `ChunkManager._thread_build` (private WorldPlan, holder["water"] + `water_gen_ms`) and `_materialize` (create Water_X_Y, measure `water_mat_ms`, record per-chunk `water_*` stats and totals). Add `t_water_gen`/`t_water_mat` to debug stats lines and respect ACTIVE-only water collider counting if chosen.
3. Extend `world/main.gd` wiring: `WorldPlan` constructed with current seed, passed via `setup_world`; wire new hydro harness flag(s) in `main.gd` (`--hydrotest`, plus alias `--hydromaterialtest` if two flags desired — but single hydro harness covering both is acceptable as long as budgets/seams are asserted).
4. Update `docs/world/WORLD-CONTRACT.md` hydrology section and `ARCHITECTURE.md`/`DEVELOPMENT.md` streaming/collision notes (ACTIVE-only clarification) as the same coherent commit series.

### Phase 3 — Persistence, regression, and evidence closeout

1. Prove generated water is NOT serialized: `ChunkManager.save_state()` payload has no water geometry; `WorldPlan` seed/version handles mismatches via existing warning + regeneration path. Determinism survives unload/reload of water chunks (same manifest after re-build).
2. Run full required matrix and judge by explicit `finished with 0 failure(s)` marker (Windows `3221225477` acceptable only with marker). Include windowed manual proof: windowed CITY run (WASD/E, door, stairs, roof, F3) + hill walk to river valley, capture PNG/log, store under `.hermes/autopilot/reports/SPEC-C002-windowed.*` or `junk/` and reference in handoff.
3. Commit coherent units (plan, constants/seed, builder, streaming, docs, harness) without rewriting history; request independent Luna review with changed paths, commit IDs, test outputs, player-facing evidence, and residual risk. The builder must not edit `AUTOPILOT_STATE.json`.

## Explicit acceptance criteria

1. `--hydrotest` finishes with `finished with 0 failure(s)`. In particular: same-seed hydrology queries and water manifests are identical regardless of query/build order, negative coordinates included; different seed materially differs; at least 40 probes along primary centerline spaced 64 m show continuous water across every chunk seam; both tributaries approach the primary corridor monotonically and meet within 600 m of the seeded confluence.
2. Geographic validity holds for the canonical seed and at least four alternate seeds: primary centerline uses the deterministic mean CX `530–710` m plus seeded meander `±72` m with smooth width `38–50` m; water is absent on cliff-class slopes or ridge hilltops (sample 200 random points: any point with `slope >= CLIFF_SLOPE_DEG` and `terrain_class==cliff` is dry except where hydrology explicitly places a lake placeholder); bank/floodplain distances are monotonic from center; flow direction is unit length with northward component `>0.35` on the primary and `>0.45` convergence dot on tributaries. Focused assertions use real `WorldConstants` thresholds.
3. `--hydrotest` (or the single hydro harness) also proves water materialization budgets and seams: chunk water manifests per `(seed, coord)` are byte-identical across two builds with shuffled chunk order; shared-edge water heights and centerline positions match within `SEAM_CONTINUITY_TOL_M` (0.02) at positive and negative boundaries; each chunk carries at most 1 water collider (0 if dry); the 3x3 ACTIVE ring carries at most 9 active water colliders; each wet chunk has bounded vertices/triangles (e.g. 81 verts / 128 tris for 9x9, or 289/512 if 17x17 — document choice) and `water_mat_ms` measured per chunk. The harness enumerates at least 9 resident water chunks around the river to assert the budget.
4. `ChunkManager` streams water together with terrain and city without duplication: load a 3x3 ACTIVE ring around a hilltop near the river, claim `_water_colliders_total <=9` and `active water == water in ACTIVE`, walk 480 m away beyond `UNLOAD_RADIUS` until the river chunks unload, return and verify the same water manifests regenerate (same vertex count/triangles/collider count) and the debug stats line contains `t_water_gen`/`t_water_mat`. Generated water geometry does not enter `save_state()` payload (assert save dict has no vertex/triangle arrays).
5. Determinism and buildability are preserved after water: `WorldSeed.GENERATOR_VERSION` unchanged (no city manifest change), `WorldPlan` remains pure, `CityPlan` deterministic IDs unchanged, spawn anchor still found, and multi-storey buildings remain former samples — proved by `--citytest` finishing with `finished with 0 failure(s)` plus the retained overlap/door/stair/facade assertions (no duplicate buildings, no missing stair zone coverage).
6. Existing streaming and survival budgets are not weakened: `--citytest`, `--terrainmaterialtest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each finish with `finished with 0 failure(s)` (window `3221225477` with marker is not a failure; ObjectDB `!is_inside_tree()` noise reduced where feasible). In particular: closed leaf still blocks aperture center, open doorway clear without RID exclusion, swung leaf collidable, walkthrough still climbs 5 storeys and back with no position writes/skips, havoctest prop clear-shot and damage still honest.
7. Ordinary player-facing proof is archived: a normal WINDOWED CITY run (not headless `--shot`) shows WASD movement, E door swing (closed blocks, open clears), stair climb to roof with camera following, F3 overlay with `active water` and `t_water_*` stats visible, then a walk east ~600–800 m to the river valley showing continuous water surface, banks, and floodplain contrast with surrounding meadow/upland. At least one PNG and its run log are committed under `.hermes/autopilot/reports/` (or `junk/` if large) and referenced in the builder handoff. Any remaining minor presentation issue is reported for a later design rather than masked. As part of the same handoff, `ARCHITECTURE.md` and `DEVELOPMENT.md` are updated to document ACTIVE-only city collision (warm visuals without Static) and water/terrain budgets, folding the C001 deferred documentation finding.

## Required automated verification

From the canonical repository root, run these commands after implementation:

```text
python tools/run_suite.py --import 120
python tools/run_suite.py --hydrotest 300
python tools/run_suite.py --citytest 300
python tools/run_suite.py --terrainmaterialtest 300
python tools/run_suite.py --cityruntime 300
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --havoctest 240
python tools/run_suite.py --smoke 180
```

Every command must produce its harness marker `finished with 0 failure(s)`. A Windows child exit code `3221225477` is acceptable only when that explicit zero-failure marker is present. A timeout, missing marker, partial output, or nonzero failure count is not a pass. The builder should run focused checks after each RED-GREEN step as well as this final matrix. If the implementation exposes a second flag alias `--hydromaterialtest`, running it with `300` must also end with `finished with 0 failure(s)` and does not relax the hydro harness above.

## Ordinary player-facing proof

Run default CITY windowed (1200x720 windowed is fine). Spawn at plaza, toggle F3. With WASD approach a qualifying building (`int(floors)>=2`, `BuildingBuilder.has_stairs_for` true); closed entrance must stop the capsule. Press E, door visibly swings and remains solid at swung position, walk through aperture, cross entry corridor, climb visible stairwell to every floor and roof deck, reverse and leave, close door from outside and verify it blocks again. Then walk east (or toward the deterministic river CX) 600–900 m over rolling hills — the valley should appear as a long teal water surface with darker banks and lighter floodplain meadow contrast. Stand on a bank hill and observe water continuity across streamed chunks (no cracks at 64 m seams, no flicker as chunks warm-stream). If a failure occurs, retain PNG/log with exact player `global_position`, `WorldSeed` value, and river centerline X at that Z.

Do not compensate with teleport or disabled collision. A screenshot built with `--shot` in headless is not sufficient for this proof due to dummy renderer; the archived PNG must be from a real windowed run.

## Performance, persistence, and compatibility boundaries

- Preserve `64 m` chunks, ACTIVE `<=1`, WARM `<=2`, hysteresis `UNLOAD=3`, one merged city mesh/static body per chunk (city ACTIVE-only), one terrain mesh/collider per chunk (9 active terrain colliders max), plus at most one water mesh/collider per wet chunk (9 active water colliders max). Do not introduce a 2D collider grid, per-waypoint bodies, or navmesh generation.
- Water vertices/triangles budget: document choice and enforce it — either 81 verts / 128 tris per wet chunk (9x9) or 289/512 (17x17). Builder must justify the choice with measured `water_gen_ms` and `water_mat_ms` versus terrain's ~t_gen/t_mat and keep per-chunk materialization under ~12 ms budgeted `FRAME_BUDGET_MS` combined with city/terrain.
- Prefer repairs that do not change generated city cell topology or stable IDs. Do not bump `WorldSeed.GENERATOR_VERSION` in this slice: the river is outside the dense historic core and does not carve city blocks, so no city manifest change is required. If a generator change becomes unavoidable, document it deliberately in `docs/world/WORLD-CONTRACT.md`, add the migration/warning note, and prove old saves follow the existing mismatch path (warning + regeneration). Never silently reinterpret old destruction/door delta keys.
- `ChunkManager` saves `seed/version/discovery/deltas/facts` only — never generated water geometry, water vertices, or water collision shapes. Hydrology remains additive; hydrology manifests are deterministic from seed+coord.
- `WORLD_SCHEMA_VERSION` may be noted but `GENERATOR_VERSION` stays 2. No new autoload, project setting, asset, world seed or save payload is authorized beyond the hydrology constants and water streaming stats already described.
- No new large asset import. Probe hydrology with vertex-colored meshes; textured/modular water and banks are later milestones.

## Out of scope and escalation

- No terrain trench carve through the 350 m historic basin, no city block water avoidance logic inside the urban flat, no river cutting a street/block grid, no street bridge mesh spanning water in this slice.
- No lake/reservoir fully materialized beyond at most one placeholder probe body type distinction (`&"reservoir"` vs `&"river"` vocabulary check) — a full lake basin/quarry forming rule is a later hydrology/biome milestone.
- No road-network or settlement suitability logic adapting to hydrology (flood-risk scoring, bridge graph, village/farm placement near water).
- No swimming, buoyancy, currents affecting gameplay, water damage, or boat/dock gameplay.
- No biome, geology, forest/field/orchard, hedgerow, quarry/mineshaft, or vertical-network implementation.
- No full shader water surface (reflections, flow UVs, toon outline tuning) beyond flat vertex-colored surface + bank earth strip.
- No broad building/interior refactor, collision disabling, intangible doors, player teleportation, hard-coded per-chunk river hacks, waypoint skipping, or test relaxation.
- Do not absorb unrelated dirty files or rewrite history. If the real repository contradicts an interface above (e.g. water corridor would inevitably intersect dense plazas), stop and report the exact path and conflict to the architect instead of inventing a second milestone.
- A principal blocker may receive at most two bounded direct revisions. A third revision, a generator-version/save migration decision that cannot be made safely, or a persistent inability to prove river continuity/budgets must return to a fresh architect recovery cycle rather than expanding this pass.

## Rollback and recovery

Keep the pre-candidate `f0bfe4f` checkpoint and all unrelated user changes intact. The builder should commit hydrology plan, water builder, streaming, docs, and harness evidence as coherent reviewable units without rewriting history. If the candidate fails review, revert or quarantine only its implementation commits, leave generated artifacts under `junk/` rather than deleting them, and restore the controller through the prescribed Kanban outcome with exact failure logs. A rollback must reproduce the known baseline honestly: `--citytest`, `--terrainmaterialtest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` each green as at `f0bfe4f`, plus no water artifacts. Do not mark a failing water assertion as accepted merely because rollback is available.
