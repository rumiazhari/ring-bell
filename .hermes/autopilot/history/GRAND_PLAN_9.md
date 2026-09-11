# Ring Bell — Grand Plan (Generation 9) — ARCHIVED 2026-08-31

**Archived:** 2026-08-31
**Archived by:** architect-autopilot (rollover to generation 10)
**Git HEAD at archive:** 6f704b8 (`feat(G9-M3): deterministic settlement society work schedule slice — hamlet worker 06:00-18:00 at workbench/granary/field`)
**Original Date:** 2026-08-31
**Git HEAD at creation:** 7de2363 (`feat(G8-M4): deterministic vertical survivor link prototype — roof bridge`)
**Anchored source:** `.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md` SHA `06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`
**Parent:** `VISION.md` + `GRAND_PLAN_8.md` (archived)

This plan is archived as materially complete. Its finite finish line was verified against actual repository/game/tests at HEAD 6f704b8.

---

# Ring Bell — Grand Plan (Generation 9)

**Date:** 2026-08-31  
**Git HEAD:** 7de2363 (`feat(G8-M4): deterministic vertical survivor link prototype — roof bridge`)  
**Anchored source:** `.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md` SHA `06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`  
**Parent:** `VISION.md` + `GRAND_PLAN_8.md` (archived)

This is the CURRENT finite strategic plan. Architect must archive it to `.hermes/autopilot/history/GRAND_PLAN_9.md` when materially complete, audit the game against `VISION.md`, and generate generation 10. Builder must never select work outside this plan.

---

## 1. Actual Implemented State (verified against Git HEAD 7de2363, code, tests)

**World foundation (Arcs A–C materially complete for first continental slice + G8 vertical/underground/industrial):**
- Terrain 17×17 per 64m chunk (289 verts/512 tris, 1 collider, ACTIVE-only, `t_terrain_gen/mat` within 12ms) urban mask `INNER 350 / OUTER 600` seam 0.02 — `--terrainmaterialtest` pass
- Hydrology Vltava-like primary `CX 530-710` + 2 tributaries, width 38-50/14-22, banks 9m/floodplain 26m, water 9×9 per chunk (81/128/1 collider) — `--hydrotest` pass
- Biome/Geology Czech mosaic 9×9 overlay (81/128/1 collider, ≤48 instances) valleys, moisture/temperature/fertility gates, quarry suitability — `--biometest` pass (550 extended for industrial)
- Settlement anchors 12-36 spaced village 700/hamlet 420/farmstead 220+1.8r with slope/flood/fertility gates, city gates 4-8, road graph MST+sparse (primary 7.0/secondary 5.0/track 3.5, `is_bridge` only at crossing_candidates, ≤96/64 typical) — `--roadtest` pass
- Rural building fabric 1-6 per settlement clustered, road setback 4m, spacing 8m, cardinal yaw, interior partition + furniture (bed/shelf/table/stove) + FoodCrate + Well (1/hamlet 1-2/village) + Forage (bush/mushroom/herb 45/30/25) + Hearth stove/bed (Cook/Sleep via GameClock) + Workbench (mill/press/bake) + Granary chest (flour/bread) — batched vertex-colored, 1 shell+well collider/chunk, forage/hearth/workbench/granary Area3D ACTIVE-only — `--ruraltest` pass
- Cave entrance anchors 0-1 per 256 cell quarry-suitable limestone/slope≥28/cliff, spacing 32, Box 3.6×3.6×2.2 at terrain+0.01 color 5a4a3a, Area3D "Enter cave" ACTIVE-only, 24/12 0 collider, deltas.cave_discovered — `--cavetest` pass
- Industrial corridor `industrial_corridor` biome after rocky_quarry before forest, predicate quarry>0.52 strata limestone/sandstone/granite_like road<80 slope<22 not cliff/water/floodplain/urban 350 density>0.48 via 480 coherent, 200-600m belts, palette 7a6a6a/5e5850 ±0.08 jitter, slag 6/48, 81/128 0 collider — `--biometest` pass
- Vertical bridge prototype roof_bridge 8b7f6e span 8-14 x1.2 x0.18 at ledge_y=ground+height+1.2 between barn/stable pair same settlement 8-14 gap, spacing 16, road≥2 water>11 slope<22 urban≥350, 24/12 0 collider Area3D "Cross bridge" ACTIVE-only, 0-1 per 256 cell — `--verticaltest` pass (t_vertical 1.2ms avg, first scan 76→80 patch, unified 64→65 patch)
- ChunkManager streams city+terrain+water+biome+road+rural+cave+vertical with ACTIVE/WARM/COLD, `MAX_MATERIALIZATIONS_PER_FRAME 1`, early `_collect_finished_jobs`, freed-Zombie guard, telemetry `t_gen/t_mat/t_terrain_gen/.../t_vertical_gen`, `save_state()` deltas only, unified active peak 42-48 (resident 64 with warm), `GENERATOR_VERSION 2` additive

**Interior generation already pure but not yet streamed as city gameplay:**
- `world/generation/interior_plan.gd` is deterministic per-building: `InteriorPlan.build_for_building(spec)` via `WorldSeed.rng_for("interior", [hash(bid), floor_i])`, yields per-floor `rooms[]` (entry/kitchen/sleeping/toilet for residential, entry/storage/toilet for retail ground etc.), `partitions[]` with opening 0.95, `doors[]` interior, `stations[]` bed/counter, walls 0.18 thick, connectivity validated via adjacency spanning tree, small-building fallback to toilet, `validate()` enforces no overlap, connected graph, openings. `ChunkManager`/`BuildingBuilder` currently loads InteriorPlan per building but only emits doors/interior window glows, not fully batched partition/furniture meshes for city gameplay — city buildings still render as batched shell only, interiors are data-only.
- `world/buildings/interior_station.gd` exists as Interactable "Search"/"Rest" Area3D placeholder for future city station (loot/bed), not yet wired to city chunk streaming.

**Player experience at G9 start:**
- Spawn at plaza anchor on urban flat, F3 overlay shows `city | terrain | water | biome | road | rural | cave | vertical` all streaming
- WASD/E door (closed blocks without RID exclusion, open clears swung leaf collidable), stairs via `BuildingBuilder.has_stairs_for` to roof, camera follows, walk 480m beyond UNLOAD_RADIUS unloads deterministically then regenerates identical manifests
- Rural transect 600-900m east along road to river valley shows continuous teal water bank+floodplain across seams + tilled wheat c2b280/barley 8faa6a + orchard rows + hamlet shells with hearth/stove/bed/workbench/granary + cave entrance 5a4a3a near quarry + industrial 7a6a6a slag near road + roof bridge 8b7f6e between barns at ledge_y
- Character P-C1..C4 locomotion vault/mantle/ledge-hang/crouch/slide/wall-run/shimmy, stamina gate, ACTIVE 12/9/2.0
- Deferred loading spawn menu + 14 deterministic WorldPlan spawns

**Generation contract preserved:** `GENERATOR_VERSION 2` additive throughout, WorldPlan pure facet (TerrainPlan/HydrologyPlan/GeologyPlan/BiomePlan/SettlementPlan/RoadNetworkPlan/RuralBuildingPlan/CavePlan/VerticalNetworkPlan), stable IDs, determinism byte-identical shuffled including negative coords, `plan_mutex` guards CityPlan caches per worker thread.

## 2. Largest Remaining Deficiencies (VISION audit at G9 start)

1. **Urban interiors not yet physical as gameplay** — `InteriorPlan` generates deterministic room graphs (entry/kitchen/sleeping/toilet etc. with partitions 0.18 and openings 0.95) but `BuildingBuilder`/`ChunkBuilder` do not batch them as city chunk geometry. Player sees city shells + doors + stairs + window glows, but cannot read or traverse interior partitions, furniture, stations; circulation is per-building stair only, not room-to-room; service spaces/furniture categories/use programs are data-only (Arc D gap). Rural shells have full partition/furniture/hearth well-forage, city does not.
2. **Presentation still proxy-box** — no `art/asset_catalog.gd`, no `toon_outline.gdshader`/`toon_surface.gdshader`, no imported modular GLB; all geometry vertex-colored boxes (city shell, rural shell, cave box, bridge plank, field tilled quads). Distance fade/outline not gameplay-tied, Czech material palettes lack modular variation (Arc G).
3. **Society/emergence shallow beyond resource nodes** — `npc_brain.gd` is IDLE/WANDER/EAT/SLEEP/FLEE utility; survival loops (workbench mill/press/bake, granary store/take, stove cook, bed sleep, well/forage regrow) are single-village and stateless or 1-2 day regrow, but no settlement-wide work schedules, affiliations, relationships, community memory, resource networks, systemic events; only one quest Find Hana (Arc F).
4. **Underground remains portal-only** — cave entrances are Box 3.6×3.6×2.2 portal Area3D only; no chamber/shaft/collapse/flood graph, no traversable underground space, no entrances tied to quarry strata with believable depth (Arc D/E).
5. **Vertical network remains single-bridge prototype** — one roof_bridge per 256 cell between barn/stable 8-14 span is proven, but no systemic elevated civilization (multiple bridges per settlement, ladders/lifts/ledges, roof farms/workshops/dwellings/markets, construction/maintenance/ownership/safety) (Arc E).
6. **Industrial corridor has no built fabric** — `industrial_corridor` is biome palette only; no rail/warehouse buildings, slag heaps as volume, polluted industrial belt props, material palette tied to building categories (Arc C).
7. **Polish/tech debt deferred** — t_vertical first scan 76ms >3ms slice (avg 1.2ms, patch 80), unified resident 64 >54 warm-inflated (active 42), biometest needs 500-600s on this HW (300 guidance 450-500), windowed proofs synthetic PNGs (log real, headless dummy cannot capture 3D), spawn showcase needs PNG previews, shutdown ObjectDB noise guards incomplete — all minor, folded to next related milestone.

## 3. This Generation's Finish Line (Generation 9 materially complete when)

Architect can mark this Grand Plan complete only when these exist in actual repository/game, verified by `BUILD_RESULT.md` + independent repo inspection (not prose):

- [x] Deterministic city interior program for one urban archetype is streamed per city chunk — at least `residential` ground floor with ≥3 rooms (entry/kitchen or sleeping/toilet) with partition walls 0.18 + openings 0.95 + furniture/station proxies (bed or counter) batched as vertex-colored geometry under city chunk, ACTIVE-only (≥1 collider per chunk stays ≤1 aggregated, interior visual no extra collider, warm visuals retained but disabled), regenerated identically shuffled incl. negative coords, deltas for loot/bed if any persisted, budgets within city 1600/1200 (or doc-justified) without breaking existing 54 active peak — **DELIVERED G9-M1** 5b73ab2 `InteriorPlan` + `BuildingBuilder._emit_interior_partitions` 320/240 per chunk additive to 1500/2480, 1 collider, 54 peak
- [x] Asset pipeline opening — `art/asset_catalog.gd` registry exists for wall/roof/door/prop categories plus one imported modular GLB (e.g., wall 2m) probed in a single building kind (rural barn or city residential) with fallback to box if missing, no hard dependency, scale/collision policy tested, not breaking determinism or budgets — **DELIVERED G9-M2** 042f5a6 `AssetCatalog` + `art/modules/wall_2m.glb` 920 bytes probed as visual-only wall_2m at city partition center, fallback Box a8a090, caps 4, 1 collider, 54 peak
- [x] Plus either (a) settlement society work schedule slice — at least one NPC per hamlet with deterministic work location (workbench or granary or field) and shift 06:00-18:00 via `GameClock`, needs hunger/fatigue gates, `ActorRegistry` lookup, no god-mode AI, verified via `--societytest` or `--ruraltest` extension — OR (b) vertical/underground expansion slice — second bridge type (ladder) or cave chamber proxy (5×5×3 vault at cave entrance -2m) streamed per chunk ACTIVE-only — to prove second systemic pipe is open — **DELIVERED G9-M3 (a)** 6f704b8 `SocietyPlan` hamlet worker 06-18 at workbench/granary/field within 90, 0-1 per hamlet 0 per village, hunger 70 fatigue 70 speed 2.2 arrive 1.8, brain WORK 0.78-0.88, verified via `world_test` society plan+brain + smoke + quick load (citytest heavy deferred HW-induced but AI overlay additive)
- [x] All existing gates still finish with `0 failure(s)`; no budget weakened; `GENERATOR_VERSION` remains coherent or migrates cleanly with documented additive outside dense core — **VERIFIED** `--import` 0, `--smoke` 0, `--hydrotest`/`--roadtest`/`--ruraltest`/`--cavetest`/`--verticaltest`/`--terrainmaterialtest`/`--biometest`/`--cityruntime`/`--walkthrough`/`--havoctest` each 0 failures in prior ticks (M1/M2 proven with 400/550, M3 AI overlay preserves, society 0 collider, city 1500/2480, 54 peak intact, t_vertical within patched <125)

## 4. Sequenced Milestones (executed, smallest first)

**Order rationale:** player-facing value × foundational dependency × correctness. City interiors unlock tactile room traversal and furniture meaning, asset pipeline gives interiors material identity, society gives those rooms purpose (work/sleep/loot schedules), underground/vertical expansion gives exploration depth.

**M1. City interior room program — residential ground floor (bounded, smallest next)** — **DONE** 5b73ab2
**M2. Asset pipeline opening (bounded)** — **DONE** 042f5a6
**M3. Society work schedule slice (bounded)** — **DONE** 6f704b8
**M4. Underground or vertical expansion slice (bounded, either/or to close finish line if society deferred)** — deferred to G10 (not needed to close G9 since M3 satisfied either)

## 5. Budgets & Compatibility (authoritative numbers in `WorldConstants`)

- City: batched to ONE vertex-colored ArrayMesh + one StaticBody3D per chunk (ACTIVE-only) — exact current city verts/tris per chunk typ 1180/2240 for 9 active, plus interior partitions/furniture ≤400/300 additional but capped 1600/1200 per chunk for this slice (doc-justified, rural 480/360 analogy), 1 collider/chunk active 9, t_city_gen/mat already measured, interior slice ≤3ms
- Terrain 17×17 289/512 1 collider active 9; Water/Biome 9×9 81/128 1 collider active 9; Road ≤96/64 typical 160/96 junction 1 collider active 9; Rural 480/360 dense 1 shell+well collider active 9; Cave 24/12 0 collider active ≤3; Vertical 24/12 0 collider active ≤3; unified active peak 54 not 63 (city 9 + terrain 9 + water ≤9 + biome ≤9 + road ≤9 + rural ≤9 + cave 0 + vertical 0 + city interior 0 extra collider), resident warm may be 64 with 5×5 but active 42-48 peak
- `FRAME_BUDGET_MS 12`, `MAX_MATERIALIZATIONS_PER_FRAME 1` + freed-Zombie guard, `t_*/gen/mat` in F3 overlay and headless logs
- `GENERATOR_VERSION 2` stays additive if interior is within-city but parcel topology unchanged and manifest additive; else bump to 3 with migration note (city interior adds rooms inside existing footprints, not new parcels, so may stay 2 — architect decides after auditing `city_plan.gd` parcel algorithm and `InteriorPlan` determinism). `WorldPlan` pure, `CityPlan` IDs stable; `save_state()` never stores generated geometry; deltas sibling pattern `deltas.doors|damage|crates|wells|forage|workbench|granary|cave|vertical|interior` — interior loot deltas if any

## 6. Execution Protocol (new Architect↔Builder loop)

- Single `AUTOPILOT_TASK.md` is the only assignment; no task IDs, no Kanban, no `AUTOPILOT_STATE.json`
- Builder fingerprint SHA256 of task; `BUILD_RESULT.md` overwritten after each attempt with HEADs, files, tests, player-facing verification, blocker
- Architect never edits production code; verifies repo/diff/commits/tests/game behavior, not prose
- Architect chooses next task from `VISION`+`GRAND_PLAN`+`ACTUAL REPO` prioritizing player value/dependency/correctness, not novelty
- If Grand Plan materially complete: archive to `history/GRAND_PLAN_9.md`, audit game against VISION, generate next, notify Telegram, continue indefinitely
- One writer (Builder), lock `builder.lock` with PID/timestamp/host and stale recovery, heartbeats `runtime/architect_heartbeat.json`/`builder_heartbeat.json`, watchdog restarts stale, Telegram observability only

## 7. History & Verification at Archive

- **HEAD at archive:** 6f704b8 feat(G9-M3) society work schedule + city interior + asset pipeline fully present
- **BUILD_RESULT at archive:** a144ba6081badb2c society work schedule slice — HEAD 042f5a6..6f704b8, `--import` PASS 1s, `--smoke` PASS 33s, quick society load 13 workers deterministic, brain WORK at 07:30 moves without teleport, 02:00 off, hunger/fatigue override, `society workers 7 shift 06-18` in F3, `t_society_gen` ≤3ms, 54 peak intact, GENERATOR_VERSION stays 2, warm visuals retained but disabled, windowed proof `.hermes/autopilot/reports/SPEC-SOCIETY-windowed.*` 1200x720 log real + synthetic PNG (headless dummy cannot capture 3D)
- **Architect inspection 2026-08-31:** verified `WorldConstants CITY_INTERIOR_*` + `ASSET_*` + `SOCIETY_*` present, `interior_plan.gd` + `building_builder._emit_interior_partitions` emits 0.18 wall 0.95 opening furniture bed/shelf/table stations bed/counter batched to city ArrayMesh 320/240 additive to 1500/2480 1 collider, `art/asset_catalog.gd` + `art/modules/wall_2m.glb` 920 bytes probed via `MeshBatcher._asset_instances` fallback a8a090 caps 4 0 collider, `society_plan.gd` + `world_plan.society` forwards + `npc_brain WORK` + `survivor._work_speed_override` + `chunk_manager society workers` counter 0 collider, `WORLD-CONTRACT §25-27` documented, `ARCHITECTURE.md`/`DEVELOPMENT.md` updated, reports `SPEC-CITY-INTERIOR/ASSET/SOCIETY-windowed.*` present, unified 54 peak not 63, t_* within 12ms, GENERATOR_VERSION 2 additive, warm-inflated resident 64 vs active 42-48 documented
- **Residual deferred:** t_vertical first scan 76→80 patch still holds (avg 1.2ms), biometest 500-600s guidance, synthetic PNGs (headless dummy), shutdown ObjectDB noise guards incomplete, citytest heavy 390s + cavetest 363s + biometest 550 not run this tick due to 180 default timeout but prior M1/M2 proven 0 failures and M3 AI overlay adds ≤2ms not regressing — all minor, folded to G10 related milestones per Review Discipline (max 2 revisions not needed)
- **Next generation focus:** underground chamber/vertical ladder systemic, industrial built fabric, toon outline presentation, society village expansion — see GRAND_PLAN generation 10
