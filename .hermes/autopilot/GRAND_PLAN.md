# Ring Bell — Grand Plan (Generation 10)

**Date:** 2026-08-31  
**Git HEAD:** 6f704b8 (`feat(G9-M3): deterministic settlement society work schedule slice — hamlet worker 06:00-18:00 at workbench/granary/field`)  
**Anchored source:** `.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md` SHA `06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`  
**Parent:** `VISION.md` + `GRAND_PLAN_9.md` (archived)

This is the CURRENT finite strategic plan. Architect must archive it to `.hermes/autopilot/history/GRAND_PLAN_10.md` when materially complete, audit the game against `VISION.md`, and generate generation 11. Builder must never select work outside this plan.

---

## 1. Actual Implemented State (verified against Git HEAD 6f704b8, code, tests)

**World foundation (Arcs A–C materially complete + G8 vertical/underground/industrial + G9 city interior/asset/society):**
- Terrain 17×17 per 64m chunk (289 verts/512 tris, 1 collider, ACTIVE-only, `t_terrain_gen/mat` within 12ms) urban mask `INNER 350 / OUTER 600` seam 0.02 — `--terrainmaterialtest` pass
- Hydrology Vltava-like primary `CX 530-710` + 2 tributaries, width 38-50/14-22, banks 9m/floodplain 26m, water 9×9 per chunk (81/128/1 collider) — `--hydrotest` pass
- Biome/Geology Czech mosaic 9×9 overlay (81/128/1 collider, ≤48 instances) valleys, moisture/temperature/fertility gates, quarry suitability — `--biometest` pass (550 extended for industrial)
- Settlement anchors 12-36 spaced village 700/hamlet 420/farmstead 220+1.8r with slope/flood/fertility gates, city gates 4-8, road graph MST+sparse (primary 7.0/secondary 5.0/track 3.5, `is_bridge` only at crossing_candidates, ≤96/64 typical) — `--roadtest` pass
- Rural building fabric 1-6 per settlement clustered, road setback 4m, spacing 8m, cardinal yaw, interior partition + furniture (bed/shelf/table/stove) + FoodCrate + Well (1/hamlet 1-2/village) + Forage (bush/mushroom/herb 45/30/25) + Hearth stove/bed (Cook/Sleep via GameClock) + Workbench (mill/press/bake) + Granary chest (flour/bread) — batched vertex-colored, 1 shell+well collider/chunk, forage/hearth/workbench/granary Area3D ACTIVE-only — `--ruraltest` pass
- Cave entrance anchors 0-1 per 256 cell quarry-suitable limestone/slope≥28/cliff, spacing 32, Box 3.6×3.6×2.2 at terrain+0.01 color 5a4a3a, Area3D "Enter cave" ACTIVE-only, 24/12 0 collider, deltas.cave_discovered — `--cavetest` pass
- Industrial corridor `industrial_corridor` biome after rocky_quarry before forest, predicate quarry>0.52 strata limestone/sandstone/granite_like road<80 slope<22 not cliff/water/floodplain/urban 350 density>0.48 via 480 coherent, 200-600m belts, palette 7a6a6a/5e5850 ±0.08 jitter, slag 6/48, 81/128 0 collider — `--biometest` pass
- Vertical bridge prototype roof_bridge 8b7f6e span 8-14 x1.2 x0.18 at ledge_y=ground+height+1.2 between barn/stable pair same settlement 8-14 gap, spacing 16, road≥2 water>11 slope<22 urban≥350, 24/12 0 collider Area3D "Cross bridge" ACTIVE-only, 0-1 per 256 cell — `--verticaltest` pass (t_vertical 1.2ms avg, first scan 76→80 patch, unified 64→65 patch)
- City interior residential ground floor — `InteriorPlan.build_for_building(spec)` via `WorldSeed.rng_for("interior", [hash(bid), floor_i])` yields 3-4 rooms (entry/kitchen/sleeping/toilet) with partitions 0.18 + opening 0.95 + furniture bed/shelf/table + stations bed/counter batched as vertex-colored under city chunk, ACTIVE-only, 320/240 per chunk additive to 1500/2480 typ 1247/2361+192/96, 1 collider per city chunk stays 1 aggregated, warm visuals retained but disabled — `--citytest` pass (with asset+society extension)
- Asset pipeline opening — `art/asset_catalog.gd` pure registry `AssetCatalog` categories wall/roof/door/prop `register/resolve/has/list/catalog` thread-safe, one modular `art/modules/wall_2m.glb` 920 bytes (2.0×2.05×0.18) probed via `MeshBatcher._asset_instances` visual-only at city partition center scale 1.0 fallback Box a8a090, caps 4 per city chunk, 0 collider, 54 peak — `--citytest` pass
- Society work schedule — `SocietyPlan` pure per-hamlet 0-1 worker where nearest workbench/granary/field_parcel within 90, id `soc_worker_<hamlet_id>` home anchor center work_site nearest within 90 tie lexicographic suppressed urban 350 never village distance ≤90 valid kinds 5-seed matrix distinct, `WorldPlan` forwards `society_workers*`, `NPCBrain` WORK state 06-18 via `GameClock.total_minutes%1440` hunger<70 fatigue<70 speed 2.2 arrive 1.8 scoring 0.78-0.88 above IDLE/WANDER below FLEE/EAT/SLEEP, execution via `survivor._work_speed_override` capped no teleport wall slide, `ChunkManager` debug `society workers %d shift 06-18` 0 collider — `--citytest` society extension + `--smoke` pass
- ChunkManager streams city+terrain+water+biome+road+rural+cave+vertical+industrial+city interior+asset+society with ACTIVE/WARM/COLD, `MAX_MATERIALIZATIONS_PER_FRAME 1`, early `_collect_finished_jobs`, freed-Zombie guard, telemetry `t_gen/t_mat/t_terrain_gen/.../t_vertical_gen/t_city_interior_gen`, `save_state()` deltas only including `deltas.cave_discovered|granaries|field_crops|fruit_patches|crates|wells|forage` (society stateless), unified active peak 42-48 (resident 64 with warm), `GENERATOR_VERSION 2` additive

**Player experience at G10 start:**
- Spawn at plaza anchor on urban flat, F3 overlay shows `city | terrain | water | biome | road | rural | cave | vertical | society` all streaming
- WASD/E door (closed blocks without RID exclusion, open clears swung leaf collidable), stairs via `BuildingBuilder.has_stairs_for` to roof, camera follows, walk 480m beyond UNLOAD_RADIUS unloads deterministically then regenerates identical manifests
- Rural transect 600-900m east along road to river valley shows continuous teal water bank+floodplain across seams + tilled wheat c2b280/barley 8faa6a + orchard rows + hamlet shells with hearth/stove/bed/workbench/granary + cave entrance 5a4a3a near quarry + industrial 7a6a6a slag near road + roof bridge 8b7f6e between barns at ledge_y + city interior partitions a8a090 opening 0.95 via open door + asset wall_2m probe at partition center
- Hamlets now have deterministic worker at 06-18 at nearest workbench 7a6a5a Box 1.2×0.9×0.6 or granary 6b4a3a Box 1.2×0.6×0.8 or field CropPatch tilled quad within 90 at 1.8m prompt, `npc_brain WORK at <site_id>` moving 2.2 m/s without teleport, hunger/fatigue gates to EAT/SLEEP
- Character P-C1..C4 locomotion vault/mantle/ledge-hang/crouch/slide/wall-run/shimmy, stamina gate, ACTIVE 12/9/2.0
- Deferred loading spawn menu + 14 deterministic WorldPlan spawns

**Generation contract preserved:** `GENERATOR_VERSION 2` additive throughout, WorldPlan pure facet (TerrainPlan/HydrologyPlan/GeologyPlan/BiomePlan/SettlementPlan/RoadNetworkPlan/RuralBuildingPlan/CavePlan/VerticalNetworkPlan/SocietyPlan), stable IDs, determinism byte-identical shuffled including negative coords, `plan_mutex` guards CityPlan caches per worker thread.

## 2. Largest Remaining Deficiencies (VISION audit at G10 start)

1. **Underground remains portal-only** — cave entrances are Box 3.6×3.6×2.2 portal Area3D only; no chamber/shaft/collapse/flood graph, no traversable underground space, no quarry strata depth, no believable volume (Arc D/E). G9 left this as either/or, society was chosen, so underground still shallow.
2. **Vertical network remains single-bridge prototype** — one roof_bridge per 256 cell between barn/stable 8-14 span is proven, but no systemic elevated civilization (multiple bridges per settlement, ladders/lifts/ledges, roof farms/workshops/dwellings/markets, construction/maintenance/ownership/safety) (Arc E). Ladder/lift not yet.
3. **Industrial corridor has no built fabric** — `industrial_corridor` is biome palette only; no rail/warehouse buildings, slag heaps as volume, polluted industrial belt props, material palette tied to building categories (Arc C). Visual identity without gameplay.
4. **Presentation still proxy-box** — one `wall_2m.glb` probed with fallback, but no `toon_outline.gdshader`/`toon_surface.gdshader`, no imported modular set for roof/door/prop, all geometry still vertex-colored boxes; distance fade/outline not gameplay-tied, Czech material palettes lack modular variation (Arc G).
5. **Society shallow beyond hamlet 1 worker** — hamlet 1 worker 06-18 hunger 70 fatigue 70 is proven, but villages have 0 this slice, no affiliations/relationships/community memory/resource networks/systemic events, only hamlet workbench/granary/field, only one quest Find Hana (Arc F). Village workers, multi-worker hamlets, and schedules not yet.
6. **City interiors limited to residential ground floor** — residential 3-4 rooms 0.18 wall 0.95 opening furniture/stations is streamed for `use==residential` ground floor only; retail/civic, upper floors, circulation beyond ground, service spaces beyond toilet, and city station loot/bed persistence not yet (Arc D).
7. **Polish/tech debt deferred** — t_vertical first scan 76ms >3ms slice (avg 1.2ms, patch 80), unified resident 64 >54 warm-inflated (active 42-48), biometest needs 500-600s on this HW (300 guidance 450-500), windowed proofs synthetic PNGs (log real, headless dummy cannot capture 3D), spawn showcase needs PNG previews, shutdown ObjectDB noise guards incomplete — all minor, folded to next related milestone.

## 3. This Generation's Finish Line (Generation 10 materially complete when)

Architect can mark this Grand Plan complete only when these exist in actual repository/game, verified by `BUILD_RESULT.md` + independent repo inspection (not prose):

- [ ] Deterministic underground chamber proxy OR vertical ladder streamed per chunk — at least one `cave chamber` Box 5×5×3 vault at `cave_entrance_pos + Vector3(0,-2,0)` OR `ladder` 1.2×0.18×3.0 between ground and roof ledge_y, deterministic 0-1 per 256 cell where cave entrance exists (or barn/stable pair for ladder), spacing ≥32, road ≥4 water>11 slope<22 urban≥350, 24/12 additional to cave/vertical but capped 48/24 per chunk 0 collider Area3D ACTIVE-only, spacing greedily by id lexicographic, regenerated identically shuffled incl. negative coords, deltas persisted if any, budgets within cave/vertical 48/24 without breaking 54 peak
- [ ] Industrial built fabric opening OR toon outline presentation slice — at least one industrial warehouse/rail building or slag heap volume 6×4×2 as built fabric tied to `industrial_corridor` biome deterministic batched vertex-colored (1 collider per chunk stays 1 aggregated, within rural/biome budgets, 0 failures), OR `toon_outline.gdshader` + `toon_surface.gdshader` probed with fallback vertex-colored, scale/collision policy tested, not breaking determinism or budgets
- [ ] Plus either (a) society village worker expansion — at least one NPC per village with deterministic work location within 90 and shift 06-18 via GameClock, hunger/fatigue gates, OR (b) city interior second archetype — retail ground floor with ≥3 rooms streamed per city chunk — to prove second systemic pipe is open
- [ ] All existing gates still finish with `0 failure(s)`; no budget weakened; `GENERATOR_VERSION` remains coherent or migrates cleanly with documented additive outside dense core

## 4. Sequenced Milestones (Architect selects next bounded task from these, smallest first)

**Order rationale:** player-facing value × foundational dependency × correctness. Underground/vertical unlocks exploration depth and tactile traversal; industrial fabric gives Czech industrial history reading and resource hints; toon outline gives coherent identity; society village gives emergent living world beyond hamlets; city retail gives functional building variety.

**M1. Underground chamber proxy — cave chamber vault at entrance (bounded, smallest next)**
- Pure `CavePlan` already generates entrance Box 3.6×3.6×2.2 via `WorldSeed` domains `cave_entrance` spacing 32 — extend to also generate chamber Box 5×5×3 at `entrance_pos + Vector3(0,-2,0)` with `is_chamber` flag, deterministic 0-1 per entrance where entrance exists, same spacing 32, road≥4 water>11 slope<22 urban≥350, handles negative coords, byte-identical shuffled, different seed differs, at least 3 chambers in 5-seed matrix, at least 1 resident cave chunk with chamber
- Extend `world/generation/world_constants.gd` with `CAVE_CHAMBER_VOCAB`, `CAVE_CHAMBER_SIZE Vector3(5,5,3)`, `CAVE_CHAMBER_OFFSET Vector3(0,-2,0)`, `CAVE_CHAMBER_COLOR 4a3a2a`, `MAX_CAVE_VERTS/TRIS_PER_CHUNK 48/24` (24/12 entrance +24/12 chamber), `MAX_CAVE_CHAMBERS_PER_CHUNK 1`, spacing 32, no duplicate inline numbers elsewhere
- Extend `world/generation/world_seed.gd` with `CAVE_CHAMBER_DOMAINS` ordered `[&"cave_chamber"]` seed-separated via floori, no RNG sharing
- Extend `world/streaming/underground_chunk_builder.gd` to batch chamber Box 5×5×3 at terrain+0.01-2.0? Actually at entrance_y -2.0 (terrain-2) with `COL_CAVE_CHAMBER`, 24/12 additional but capped 48/24 per chunk, 0 collider Area3D only (or optional StaticBody not counted to 54 peak), ACTIVE-only, no duplication at +/-/-Z (center ownership), fits within FRAME_BUDGET_MS 12 together with entrance 24/12, t_cave_gen/mat within 12ms
- Extend `world/streaming/chunk_manager.gd` mirroring cave/vertical pipeline: counters `_cave_vertices_total/_triangles_total/_entrances_total/_chambers_total`, `t_cave_gen/mat` already exists but document chamber slice ≤3ms, debug_lines `cave verts|tris|colliders|entrances|chambers`, pacing `MAX_MATERIALIZATIONS_PER_FRAME 1` + freed-Zombie guard extended to CaveChamber
- Document in `docs/world/WORLD-CONTRACT.md` new §28 (vocab, siting gates, manifest, budgets, ACTIVE-only, save exclusion, GENERATOR_VERSION stays 2 additive inside quarry upland but chamber is within cave cell — additive, no parcel topology change, else bump to 3 with migration), and `ARCHITECTURE.md`/`DEVELOPMENT.md` module map + telemetry + gate docs for `--cavetest` extension

**M2. Industrial built fabric opening (bounded)**
- `world/generation/world_constants.gd` authoritative numerics for warehouse/slag: `INDUSTRIAL_WAREHOUSE_VOCAB`, `INDUSTRIAL_WAREHOUSE_FOOTPRINT 10×14`, `INDUSTRIAL_SLAG_SIZE 6×4×2`, `COL_INDUSTRIAL_WAREHOUSE`, `MAX_INDUSTRIAL_BUILDINGS_PER_CHUNK`, reuse `industrial_corridor` siting gates road<80 quarry>0.52 slope<22 not cliff/water/floodplain/urban 350 density>0.48
- `world/generation/industrial_plan.gd` or extend `RuralBuildingPlan`/`BiomePlan` to generate 0-1 warehouse per industrial belt cell, deterministic, spacing, not duplicating rural shells
- `world/streaming/biome_chunk_builder.gd` or new `industrial_chunk_builder.gd` to batch warehouse Box 10×14×6 + slag Box 6×4×2 at terrain+0.03, vertex-colored 7a6a6a/5e5850, 1 collider per chunk stays 1 aggregated, caps within 480/360 analogy, 54 peak intact
- Verify via `--biometest` or `--ruraltest` extension: determinism shuffled incl negative, different seed differs, at least 2 distinct industrial built belts in 5-seed matrix, at least 1 resident industrial chunk with fabric, 0 failures

**M3. Toon outline presentation slice (bounded)**
- `art/toon_outline.gdshader` + `art/toon_surface.gdshader` with fallback vertex-colored, `art/asset_catalog.gd` extend to `material` category, probe in one building kind (city residential wall or rural barn) with `FileAccess.exists` vs `ResourceLoader.exists`, never hard crash, fallback to box, scale 1.0, no new collider, determinism preserved
- Verify via `--citytest` or `--ruraltest` extension: catalog deterministic, shader probed without error, fallback path tested, no budget inflated, 54 peak intact

**M4. Society village worker expansion OR city retail interior (bounded, either/or to close if industrial/toon deferred)**
- Option A: Village worker — extend `SocietyPlan` to assign 1 per village where nearest workbench/granary/field within 90, same 06-18 hunger 70 fatigue 70 speed 2.2, caps 1 per village, never farmstead, deterministic
- Option B: City retail interior — extend `BuildingBuilder._emit_interior_partitions` to also handle `use==retail` ground floor with 3 rooms (entry/storage/toilet) same 0.18/0.95 budgets, furniture counter/shelf, station counter
- Only one of A/B needed to satisfy finish line's plus either if industrial/toon is not yet fully proven

Architect may reorder M2-M4 if repo evidence shows a different dependency is ripe, but must justify against pillars and explain why. No facade-only milestone. No scope creep beyond one bounded task per cycle.

## 5. Budgets & Compatibility (authoritative numbers in `WorldConstants`)

- City: batched to ONE vertex-colored ArrayMesh + one StaticBody3D per chunk (ACTIVE-only) — exact current city verts/tris per chunk typ 1180/2240 for 9 active, plus interior partitions/furniture ≤400/300 additional but capped 1600/1200 per chunk for this slice (doc-justified, rural 480/360 analogy), 1 collider/chunk active 9, t_city_gen/mat already measured, interior slice ≤3ms, asset slice ≤2ms, society 0 collider
- Terrain 17×17 289/512 1 collider active 9; Water/Biome 9×9 81/128 1 collider active 9; Road ≤96/64 typical 160/96 junction 1 collider active 9; Rural 480/360 dense 1 shell+well collider active 9; Cave 24/12 entrance alone 48/24 with chamber 0 collider active ≤3; Vertical 24/12 0 collider active ≤3; unified active peak 54 not 63 (city 9 + terrain 9 + water ≤9 + biome ≤9 + road ≤9 + rural ≤9 + cave 0 + vertical 0 + city interior 0 extra collider + asset 0 + society 0), resident warm may be 64 with 5×5 but active 42-48 peak
- `FRAME_BUDGET_MS 12`, `MAX_MATERIALIZATIONS_PER_FRAME 1` + freed-Zombie guard, `t_*/gen/mat` in F3 overlay and headless logs
- `GENERATOR_VERSION 2` stays additive if chamber is within-cave but no new parcels outside 350, and industrial fabric is within industrial_corridor but parcel topology unchanged, and asset shader is materialization-only, so may stay 2 with audit note, else bump to 3 with migration. `WorldPlan` pure, `CityPlan` IDs stable; `save_state()` never stores generated geometry; deltas sibling pattern `deltas.doors|damage|crates|wells|forage|workbench|granary|cave|vertical|interior|asset` — chamber loot deltas if any, society stateless
- Tests required per milestone: same-seed determinism shuffled incl. negative coords, different-seed differs, geographic gates via real `WorldConstants`, budgets/seams, streaming ACTIVE/WARM dedup + unload/reload identical, determinism/buildability preserved, existing budgets not weakened (city/terrain/hydro/biome/road/rural/cave/vertical/cityruntime/walkthrough/havoctest/smoke 0 failures), windowed proof PNG+log under `.hermes/autopilot/reports/` when traversal/visual involved

## 6. Execution Protocol (new Architect↔Builder loop)

- Single `AUTOPILOT_TASK.md` is the only assignment; no task IDs, no Kanban, no `AUTOPILOT_STATE.json`
- Builder fingerprint SHA256 of task; `BUILD_RESULT.md` overwritten after each attempt with HEADs, files, tests, player-facing verification, blocker
- Architect never edits production code; verifies repo/diff/commits/tests/game behavior, not prose
- Architect chooses next task from `VISION`+`GRAND_PLAN`+`ACTUAL REPO` prioritizing player value/dependency/correctness, not novelty
- If Grand Plan materially complete: archive to `history/GRAND_PLAN_10.md`, audit game against VISION, generate next, notify Telegram, continue indefinitely
- One writer (Builder), lock `builder.lock` with PID/timestamp/host and stale recovery, heartbeats `runtime/architect_heartbeat.json`/`builder_heartbeat.json`, watchdog restarts stale, Telegram observability only

## 7. History

- G9 archived 2026-08-31 at HEAD 6f704b8 — city interior residential ground floor + asset pipeline wall_2m GLB + society hamlet worker 06-18 delivered, unified 54 peak, GENERATOR_VERSION 2, underground still portal-only, vertical single-bridge, industrial palette only, presentation proxy-box — all verified via citytest/society + import + smoke with 0 failures (citytest heavy deferred HW-induced but AI overlay additive, prior M1/M2 proven 400/550)
- G8 archived 2026-08-31 at HEAD 7de2363 — vertical bridge prototype + cave entrance + industrial corridor delivered, unified 54 peak, GENERATOR_VERSION 2, interior generation pure but city interiors not yet streamed, asset pipeline not yet, society shallow — all verified via vertical/cave/industrial tests with 0 failures (biometest 550 extended, vertical 76→80/64→65 patches)
- Prior stalled controller at cycle 9 P5.1-FIELD-PARCELS archived to `junk/autopilot-kanban-v2-archive-20260831-010858/` (89 files + 53KB/42KB kanban exports). No valid player-facing completion after HEAD 45ae639; new plan audits actual playable game, not stale cycle counters.
- Preserved knowledge from `docs/world/WORLD-CONTRACT.md` (§1-27) and prior specs C001-C007 / C009-C012 / G8-M1/M2/M4 / G9-M1/M2/M3, deferred findings folded into next related milestone rather than third revision.
