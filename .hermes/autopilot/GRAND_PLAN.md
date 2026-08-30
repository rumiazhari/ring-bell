# Ring Bell — Grand Plan (Generation 8)

**Date:** 2026-08-31  
**Git HEAD:** 45ae639 (`fix(world): authoritative surface + bounded city composition`)  
**Anchored source:** `.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md` SHA `06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`  
**Parent:** `VISION.md`

This is the CURRENT finite strategic plan. Architect must archive it to `.hermes/autopilot/history/GRAND_PLAN_8.md` when materially complete, audit the game against `VISION.md`, and generate generation 9. Builder must never select work outside this plan.

---

## 1. Actual Implemented State (verified against Git HEAD, code, tests)

**World foundation (Arcs A–C materially complete for first slice):**
- Terrain 17×17 per 64m chunk (289 verts/512 tris, 1 collider, ACTIVE-only, `t_terrain_gen/mat` within 12ms) with urban mask `INNER 350 / OUTER 600` and seam 0.02 — `--terrainmaterialtest` pass
- Hydrology Vltava-like primary `CX 530-710` + 2 tributaries, width 38-50/14-22, banks 9m/floodplain 26m, water 9×9 per chunk (81/128/1 collider) — `--hydrotest` pass
- Biome/Geology Czech mosaic 9×9 overlay (81/128/1 collider, ≤48 forest instances) with valleys, moisture/temperature/fertility gates, quarry suitability — `--biometest` pass
- Settlement anchors 12-36 spaced village 700/hamlet 420/farmstead 220+1.8r with slope/flood/fertility gates, city gates 4-8, road graph MST+sparse (primary 7.0/secondary 5.0/track 3.5, `is_bridge` only at crossing_candidates, ≤96/64 typical) — `--roadtest` pass
- Rural building fabric 1-6 per settlement clustered around anchors, road setback 4m, spacing 8m, cardinal yaw, interior partition + furniture (bed/shelf/table/stove) + FoodCrate + Well (1/hamlet 1-2/village) + Forage (bush/mushroom/herb 45/30/25) + Hearth stove/bed (Cook/Sleep via GameClock) + Workbench (mill/press/bake) + Granary chest (flour/bread) — all batched vertex-colored, 1 shell+well collider/chunk, forage/hearth/workbench/granary Area3D ACTIVE-only — `--ruraltest` pass (0 failures)
- ChunkManager streams city+terrain+water+biome+road+rural with ACTIVE/WARM/COLD, `MAX_MATERIALIZATIONS_PER_FRAME 1`, early `_collect_finished_jobs`, freed-Zombie guard, `t_gen/t_mat` telemetry, `save_state()` stores deltas only, unified 54 peak — `--citytest`, `--cityruntime`, `--walkthrough`, `--havoctest`, `--smoke` pass

**Player experience:**
- Spawn at plaza anchor on urban flat, F3 overlay shows `chunk | active | warm | verts|tris|colliders|t_gen|t_mat` for all layers
- WASD/E door (closed blocks without RID exclusion, open clears swung leaf collidable), stairs to roof, camera follows, walk 480m beyond UNLOAD_RADIUS unloads deterministically then regenerates identical manifests
- Rural transect 600-900m east along road to river valley shows continuous teal water bank+floodplain across seams + tilled parcels/hedgerows + orchard rows + hamlet shells with hearth/stove/bed/workbench/granary
- Character locomotion P-C1..C4: skeleton-driven in-place 19 clips, vault/mantle/ledge hang 4cm IK, crouch/slide 15 clips, wall-run/shimmy chained flow 19 clips, stamina gate, ACTIVE 12/9/2.0
- Deferred loading spawn menu + main_menu + loading_screen additive on main.gd with headless/test bypass, 14 deterministic WorldPlan spawns

**Generation contract preserved:** `GENERATOR_VERSION 2` additive throughout, WorldPlan pure facet, stable IDs, determinism byte-identical shuffled including negative coords.

## 2. Largest Remaining Deficiencies (VISION audit)

1. **Underground not yet physical** — no `cave_plan.gd` / `underground_chunk_builder.gd` (quarries have suitability but no graph: entrances/shafts/chambers/collapse/flood). Player cannot enter cave/mine/sewer/basement (Arc D/E gap).
2. **Vertical survivor network absent** — no `vertical_network_plan.gd` (roof bridges/ladders/lifts/ledge farms). Traversal is per-building, not systemic elevated civilization; no construction/maintenance gameplay (Arc E).
3. **Industrial corridor missing as distinct region** — `BIOME_VOCAB` lacks `industrial_corridor` (vocab is urban/river/wet/arable/pasture/orchard/forest/quarry). Rail/warehouse corridor is road graph only, without polluted belt, slag heaps, contaminated ground, material palette (Arc C industrial belt).
4. **Urban interiors still placeholder** — rural shells have partition/furniture/hearth well-forage, but city buildings lack semantic room programs (residential/retail/civic), interior plan still prototype (Arc D).
5. **Presentation uses proxy boxes** — no `art/asset_catalog.gd`, no `toon_outline.gdshader`/`toon_surface.gdshader`, no imported modular GLB; all geometry vertex-colored boxes; distance fade/outline not gameplay-tied (Arc G).
6. **Society/emergence shallow** — `npc_brain.gd` is IDLE/WANDER/EAT/SLEEP/FLEE utility; no schedules, affiliations, work, relationships, community memory, resource networks, systemic events; only one quest Find Hana; survival loops (workbench/granary) are single-village, not settlement networks (Arc F).
7. **Polish debts deferred** — windowed proof PNGs are still small/placeholder for several specs; shutdown noise guards incomplete; spawn showcase needs PNG previews when headless dummy renderer cannot capture 3D (deferred finding).

## 3. This Generation's Finish Line (Generation 8 materially complete when)

Architect can mark this Grand Plan complete only when these exist in actual repository/game, verified by `BUILD_RESULT.md` + independent repo inspection (not prose):

- [ ] Deterministic underground entrances associated with quarry-suitable geology are streamed per chunk (entrance portal + at least chamber proxy, ACTIVE-only, ≤400/300 budget, regenerated identically, deltas persisted)
- [ ] At least one industrial corridor belt readable as distinct biome/material near rail/road intersections with contaminated ground palette
- [ ] Plus either (a) city interior room program for one building archetype OR (b) vertical network link prototype (roof bridge between two rural barns) — to prove D/E pipe is open
- [ ] All existing gates still finish with `0 failure(s)`; no budget weakened; `GENERATOR_VERSION` remains coherent or migrates cleanly

## 4. Sequenced Milestones (Architect selects next bounded task from these, smallest first)

**Order rationale:** player-facing value × foundational dependency × correctness.

**M1. Underground entrance foundation (bounded)** — pure `CavePlan.cave_entrances_in(rect)` seeded per quarry `suitability>0.72`+slope≥28/cliff, 0-1 per 256m cell near settlement, entrance box at `terrain+0.01` with slope/water/road gates, streamed via `UndergroundChunkBuilder` 1 mesh+0 collider (Area3D portal ACTIVE-only), budget within existing 480/360 not expanded without justification, `deltas.cave_discovered` persistence, no hidden errors, at least 9 resident underground chunks around quarry transect.

**M2. Industrial corridor biome** — extend `GeologyPlan`+`BiomePlan` to yield `industrial_corridor` where `geology in {limestone|coal|iron} && road distance < 80 && settlement kind industrial`, palette 7a6a6a/rock, deterministic, 9×9 overlay 81/128 not duplicated, `—biometest` updated.

**M3. City interior program slice (one archetype)** — expand `InteriorPlan`+`BuildingBuilder` for `worker_house` 3-room semantics with partition + furniture proxies streamed with city chunk (≤1 collider, ACTIVE-only), door/stair contracts preserved, walkthrough climbs still honest.

**M4. Vertical link prototype** — `VerticalNetworkPlan` simple roof bridge between two rural barns (`span 8-14m`, foot anchors on parapets, `ledge_y = building_ground_y + height + 1.2`, load-bearing check, Area3D transition ACTIVE-only, no street-level duplication).

**M5. Asset pipeline opening** — `art/asset_catalog.gd` registry for wall/roof/door/prop categories plus one imported GLB wall module probed in a single rural building kind (fallback to box if missing, no hard dependency, scale/collision policy tested).

**M6. Society slice** — settlement work schedule: one NPC per hamlet with deterministic work location (workbench/granary) and shift 06:00-18:00 via `GameClock`, needs hunger/fatigue gates, `ActorRegistry` lookup, no god-mode AI.

Architect may reorder M2-M6 if repo evidence shows a different dependency is ripe, but must justify against pillars and explain why. No facade-only milestone. No scope creep beyond one bounded task per cycle.

## 5. Budgets & Compatibility (authoritative numbers in `WorldConstants`)

- Terrain 17×17 289/512 1 collider/chunk active 9; Water/Biome 9×9 81/128 1 collider active 9; Road ≤96/64 typical 160/96 junction 1 collider active 9; Rural 480/360 dense 1 shell+well collider active 9 unified 54 peak (forage/hearth/workbench Area3D no collider, ACTIVE-only monitorable)
- `FRAME_BUDGET_MS 12`, `MAX_MATERIALIZATIONS_PER_FRAME 1` + freed-Zombie guard, `t_*/gen/mat` in F3 overlay and headless logs
- `GENERATOR_VERSION 2` stays additive until underground/vertical justifies bump; `WorldPlan` pure, `CityPlan` IDs stable; `save_state()` never stores generated geometry; deltas sibling pattern `deltas.doors|damage|crates|wells|forage|workbench|granary|cave`
- Tests required per milestone: same-seed determinism shuffled incl. negative coords, different-seed differs, geographic gates via real `WorldConstants`, budgets/seams, streaming ACTIVE/WARM dedup + unload/reload identical, determinism/buildability preserved, existing budgets not weakened (city/terrain/hydro/biome/road/rural/cityruntime/walkthrough/havoctest/smoke 0 failures), windowed proof PNG+log under `.hermes/autopilot/reports/` when traversal/visual involved.

## 6. Execution Protocol (new Architect↔Builder loop)

- Single `AUTOPILOT_TASK.md` is the only assignment; no task IDs, no Kanban, no `AUTOPILOT_STATE.json`
- Builder fingerprint SHA256 of task; `BUILD_RESULT.md` overwritten after each attempt with HEADs, files, tests, player-facing verification, blocker
- Architect never edits production code; verifies repo/diff/commits/tests/game behavior, not prose
- Architect chooses next task from `VISION`+`GRAND_PLAN`+`ACTUAL REPO` prioritizing player value/dependency/correctness, not novelty
- If Grand Plan materially complete: archive to `history/GRAND_PLAN_8.md`, audit game against VISION, generate next, notify Telegram, continue indefinitely
- One writer (Builder), lock `builder.lock` with PID/timestamp/host and stale recovery, heartbeats `runtime/architect_heartbeat.json`/`builder_heartbeat.json`, watchdog restarts stale, Telegram observability only

## 7. History

- Preserved knowledge from `docs/world/WORLD-CONTRACT.md` (§1-18) and prior specs C001-C007 / C009-C012, deferred findings folded into next related milestone rather than third revision.
- Prior stalled controller at cycle 9 P5.1-FIELD-PARCELS archived to `junk/autopilot-kanban-v2-archive-20260831-010858/` (89 files + 53KB/42KB kanban exports). No valid player-facing completion after HEAD 45ae639; new plan audits actual playable game, not stale cycle counters.

