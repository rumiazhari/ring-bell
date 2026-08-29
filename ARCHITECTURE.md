# Ring Bell - Architecture

3D top-down open-world zombie survival RPG centered on realistic survivor
simulation. This document maps the codebase: what owns what, how data flows,
and where new systems plug in. Read this before editing.
**Golden rules**
1. Small focused files; one responsibility each.
2. Simulation facts live in `WorldState`, never in quest/dialogue scripts.
3. Quests and dialogue query world state - they never fake or copy NPCs.
4. No giant scripts, no hidden behavior, no hard-coded actor IDs in logic.
5. Death is permanent for NPCs. Stories branch around the dead.
6. City generation is deterministic: same seed + same coords => same result,
   regardless of chunk visit order. Never mutate the plan from materialization.
7. Chunks materialize geometry; they never own buildings conceptually. A
   building has a global ID and belongs to exactly one chunk (its footprint
   center) so streaming can never duplicate or tear it.

---

## Module map

```
core/
  autoload/            Singletons (see "Autoload contracts" below)
    input_setup.gd     Registers InputMap actions in code (deterministic)
    event_bus.gd       Global signal hub
    game_clock.gd      Game minutes since day 1; day/night queries
    item_db.gd         Item definition table (pure data)
    actor_registry.gd  Live node lookup + spatial queries by persistent_id
    world_state.gd     PERSISTENT world facts: flags + death records
    quest_manager.gd   Quest state machine; forwards events to quest defs
    save_manager.gd    JSON save/load orchestration
    debug_overlay.gd   F3 stats/log overlay, F5/F9 quicksave/load, T timescale
  save/                (reserved for save helpers)

actors/
  survivor/survivor.gd        Shared human body: movement, stamina, melee,
                              survival ticks, death->corpse conversion
  survivor/player_controller.gd  Input -> survivor; interaction scan
  zombie/zombie.gd            Slow shambler: wander/chase/investigate/attack

components/           Data+behavior units attached to actors at runtime
  identity_component.gd     persistent_id - THE cross-system link
  health_component.gd       hp, infection, death signal
  needs_component.gd        hunger/thirst/fatigue (0=best, 100=worst)
  inventory_component.gd    {item_id: count} stacks
  interactable_component.gd Marks a body usable by the player scan

ai/
  npc_brain.gd        Utility AI: think tick scores goals, executes actions
                      (IDLE/WANDER/EAT/SLEEP/FLEE) as tiny state machines

narrative/
  quests/quest_base.gd         Base class: pure logic, no scene access
  quests/quest_find_hana.gd    The P0 narrative test (see below)
  dialogue/dialogue_data.gd    Trees built AT OPEN TIME from world state;
                               coded string effects applied by UI
  dialogue/dialogue_ui.gd      Bottom-panel presentation only

world/
  main.gd/.tscn          Entry scene; SaveManager "world provider";
                         picks world mode: legacy block vs streamed city
  level_builder.gd       LEGACY P0 test block (smoke tests still use it)
  population.gd          Spawn manifest: survivors, zombies, positions
  food_crate.gd          Lootable container; also feeds NPC brains
  day_night_controller.g Sun energy/color, ambient, streetlamps vs clock

  generation/          P0.5 deterministic city plan + P2 terrain + P2.2 hydrology + P3.1 biome/geology + P4.1 settlement/roads + P4.2 rural building fabric (pure functions of seed+coords)
    world_seed.gd        WorldSeed: seed storage, GENERATOR_VERSION, splitmix
                         RNG helpers, sample_coherent lattice + domain separation (terrain/hydro/geology/biome/settlement/road/rural building domains)
    world_constants.gd   Authoritative numerics: CHUNK_SIZE, WORLD_BOUNDS, height/slope thresholds,
                         hydrology corridor/meander/width/bank/floodplain/water-level, biome/geology/settlement/road/rural vocab/widths/lifts/caps/footprints/heights/spacing/seams/budgets, budget tolerances
    world_plan.gd        Facade owning TerrainPlan + HydrologyPlan + GeologyPlan + BiomePlan + SettlementPlan + RoadNetworkPlan + RuralBuildingPlan (pure, per-worker)
    city_plan.gd         Hierarchical macro plan: districts -> road grid ->
                         urban blocks -> plazas -> parcels/building specs.
                         Cached per instance; queries are order-independent
    terrain_plan.gd      Layered heightfield: ridge/valley/temperature sampling, urban radial mask
    hydrology_plan.gd    Vltava-like primary river (CX 620+-90, meander 72+18) + 2 bezier tributaries,
                         width/level/distance/flow/crossing queries (pure, deterministic)
    settlement_plan.gd   Deterministic settlement anchors + city gates: macro-cell scoring, slope/flood/fertility gates, spacing inhibition (pure, deterministic)
    road_network_plan.gd Hierarchical MST+sparse-loop road graph constrained to hydrology crossing_candidates, smoothed polylines (pure, deterministic)
    rural_building_plan.gd Deterministic rural shelters clustered around settlement anchors, road/slope/flood/water/city-flat gated, cardinal yaw, door facing road/settlement (pure, deterministic)
    building_builder.gd  One building spec -> batched geometry ops (shell,
                         floors, stairs, roof, balconies, windows)
    chunk_builder.gd     Materializes ONE city chunk: ground, roads, blocks,
                         buildings via BuildingBuilder, props; MeshBatcher out

  streaming/           P0.5 chunk lifecycle + P2 terrain + P2.2 water + P3.1 biome + P4.1 roads + P4.2 rural building fabric
    chunk_manager.gd     Tracks player chunk; budgeted load/unload queues;
                         ACTIVE/WARM/COLD rings; worker-thread fill_batcher + build_manifest;
                         materializes city + terrain + water + biome + road + rural building fabric; stats for F3 overlay (t_gen/t_mat/t_terrain_gen/t_terrain_mat/t_water_gen/t_water_mat/t_biome_gen/t_biome_mat/t_road_gen/t_road_mat/t_rural_gen/t_rural_mat)
                         Streaming pacing: MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) before streaming recalc; Variant freed-Zombie guard (debug/streaming_regression_test.gd checks is_instance_valid + is_inside_tree before storing)
    mesh_batcher.gd      Collects (box,color,collide) tuples during build,
                         flushes to ONE merged vertex-colored ArrayMesh +
                         one StaticBody3D per chunk (ACTIVE-only physics, see below)
    terrain_chunk_builder.gd  17x17 height samples per 64 m chunk (289 verts / 512 tris), one mesh + one Concave per chunk
    water_chunk_builder.gd    9x9 water samples per 64 m chunk (81 verts / <=128 tris, <=1 collider), muted-teal mesh + bank ribbon
    biome_chunk_builder.gd    9x9 biome overlay per 64 m chunk (81 verts / <=128 tris, <=1 collider, <=48 instances), vertex-colored field/forest dressing
    road_chunk_builder.gd     Per-chunk road/bridge ribbon: tessellated flat vertex-colored strip at terrain+0.04 (bridge deck at water+0.35), <=96 verts / <=64 tris typical (junction <=160/96), at most 1 Concave per chunk, ACTIVE-only physics
    rural_building_chunk_builder.gd Per-chunk rural shells: batched vertex-colored boxes at terrain+0.01 per settlement building (footprint 6-10x8-14, height 4.2+2.9*floors, cardinal yaw, plaster/brick/timber walls, roof 8a3a2a/5a5a5a), <=192 verts / <=144 tris typical (dense <=320/240 village), at most 1 Concave per chunk, ACTIVE-only physics + `Door` leaves per building (<=6 doors/village chunk)

ui/hud.gd             Clock, vitals bars, quest tracker, prompts, banners,
                      death screen (all code-built)
debug/smoke_test.gd   Headless regression harness (--smoke / --soak modes)
debug/world_test.gd   Headless city determinism harness (--citytest)
debug/terrain_test.gd                Pure terrain plan checks
debug/terrain_material_test.gd       Terrain manifest + streaming budgets
debug/hydrology_test.gd              Hydrology determinism + water manifest budgets (--hydrotest / --hydromaterialtest)
debug/biome_test.gd                  Biome/geology determinism + dressing budgets (--biometest / --biomematerialtest)
debug/road_test.gd                   Settlement + road determinism + road/bridge budgets + streaming (--roadtest / --settlementtest / --roadmaterialtest)
debug/rural_test.gd                  Rural building determinism + shell budgets + streaming (--ruraltest / --settlementbuildingtest / --ruralfabrictest)
debug/city_runtime_test.gd           Streamed-city integration (physics rays, stairs, doors, destruction)
debug/walkthrough_probe.gd           Honest player traversal (WASD through doors, stairs 5 storeys)
debug/havoc_test.gd                  Havoc physics + firearms integration
debug/streaming_regression_test.gd   Freed-Zombie guard + 1-per-frame pacing regression (MAX_MATERIALIZATIONS_PER_FRAME 1)
camera/follow_camera.gd Elevated rotatable rig; group "camera_rig"
```

## World architecture (P0.5 + P2 terrain + P2.2 hydrology + P3.1 biome/geology + P4.1 settlement/roads + P4.2 rural building fabric)

Two strictly separated layers (now seven plan owners behind one facade):

```
PLAN LAYER (pure, immutable, cheap)          MATERIAL LAYER (scene nodes)
WorldPlan(world_seed)                         ChunkManager
  .terrain: TerrainPlan                         .load_chunk(coord) -> city + terrain + water + biome + road + rural
  .hydrology: HydrologyPlan                  threads: fill_batcher + terrain/water/biome/road/rural manifests
  .geology: GeologyPlan
  .biome: BiomePlan
  .settlement: SettlementPlan
  .road_network: RoadNetworkPlan
  .rural_building: RuralBuildingPlan
  .district_at(cell)  --\
  .roads_near(rect)     \
  .blocks_in(rect)      reads  ChunkBuilder.build(...) + TerrainChunkBuilder + WaterChunkBuilder + BiomeChunkBuilder + RoadChunkBuilder + RuralBuildingChunkBuilder
  .buildings_in(rect)   ---->    -> MeshBatcher/MultiMesh (city)
  .building_by_id(id)            -> Terrain Mesh+Concave (1/chunk)
  .height_at(p)                  -> Water Mesh+Concave (1/chunk if wet)
  .water_body_at(p)              -> Biome Mesh+Concave+MultiMesh (1/chunk)
  .settlement_anchors()          -> Road Mesh+Concave (1/chunk, <=96/64 typical)
  .road_segments_in(rect)        -> Rural Mesh+Concave+Door leaves (1/chunk, <=192/144 typical, dense <=320/240)
  .rural_buildings_in(rect)      unload => queue_free subtree (city+terrain+water+biome+road+rural together)
```

- The plan NEVER touches the scene tree; chunks NEVER make random choices -
  all randomness comes from WorldSeed.rng([seed, purpose_hash, coords...]) or WorldSeed.sample_coherent* with explicit domains (terrain/ridge/valley/soil/moisture/temperature/geology/settlement/road/hydro_*/rural_building*).
- Determinism contract: any two chunk builds for the same coord under the
  same seed produce identical node trees and identical collision shapes,
  regardless of which neighbors were built first. `--citytest`, `--terrainmaterialtest`, `--hydrotest`, `--biometest`, `--roadtest`, and `--ruraltest` enforce this (including negative coords and shuffled build order).
- Chunk size is 64 m (`WorldSeed.CHUNK_SIZE`). Active ring = chebyshev <= 1
  (geometry + physics), warm ring <= 2 (resident visuals, no physics), beyond = unloaded (hysteresis `UNLOAD_RADIUS = WARM_RADIUS + 1 = 3`). Buildings are owned by the chunk containing their footprint center; with a 64 m grid and <= 20 m deep lots this keeps every visible building resident while its chunk is active or warm.
- **ACTIVE-only collision (intentional budgeted optimization, clarified from P0.5 assumption):** warm chunks retain their merged city `MeshInstance3D` visuals and terrain/water/biome/road/rural meshes, but their `StaticBody3D`/water `WaterBody`/biome `BiomeBody`/road `RoadBody`/rural `RuralBody` collision is disabled (`collision_layer=0` or batcher.disable_collision()). Only chunks with state ACTIVE contribute to `colliders`/`terrain_colliders`/`water_colliders`/`biome_colliders`/`road_colliders`/`rural_colliders` and to the F3 `active terrain` / `active water` / `active biome` / `active road` / `active rural` counts. This keeps physics at a 3x3 budget (9 city + 9 terrain + at most 9 water + at most 9 biome + at most 9 road + at most 9 rural colliders = 54 peak, typically <=45+rural) while warm visuals stay resident for seamless streaming. Previous docs assumed warm+active physics; that assumption is corrected here and now includes road and rural (folded C001-C004).
- **Budgets:** city geometry batched to ONE vertex-colored ArrayMesh + one StaticBody3D per chunk (ACTIVE-only). Terrain: 17x17 samples per 64 m chunk (4 m spacing, 289 verts / 512 tris, 1 Concave per chunk, 9 active max). Water: 9x9 samples per 64 m chunk (8 m spacing, 81 verts / <=128 tris, at most 1 Concave per wet chunk, 0 if dry, 9 active water max). Biome: 9x9 overlay per 64 m chunk (8 m spacing, 81 verts / <=128 tris, at most 1 biome Concave per forest/quarry chunk, 0 if field/urban, 9 active biome max) plus at most one MultiMeshInstance3D (<=48 forest instances or <=12 field + <=6 quarry) per chunk. Road: flat ribbon per 64 m chunk at terrain+0.04 (bridge deck at water+0.35) with widths 7.0/5.0/3.5 m, <=96 verts / <=64 tris typical (junction <=160/96), at most 1 Concave per chunk, 0 if dry, 9 active road max, shared-edge centerlines within 0.02 m. Rural: batched boxes per building at terrain+0.01, footprint 6-10x8-14 (village 8-10x10-12, barn 8-10x10-14), height 4.2+2.9*floors, plaster/brick/timber+roof 8a3a2a/5a5a5a vertex-colored, <=192 verts / <=144 tris typical (dense <=320/240, hamlet/farmstead 1-2 buildings, village 4-6), at most 1 Concave per chunk, 0 if dry, 9 active rural max, doors <=6 per village chunk, road setback >=4 m from centerline, spacing >=8 m. Per-chunk timings `t_gen/t_mat` (city) plus `t_terrain_gen/t_terrain_mat` and `t_water_gen/t_water_mat` and `t_biome_gen/t_biome_mat` and `t_road_gen/t_road_mat` and `t_rural_gen/t_rural_mat` are measured inside the worker (`_thread_build` with private WorldPlan) and on the main thread (`materialize`) and exposed via `ChunkManager.debug_lines()` and F3 overlay. Water district_hint `urban_basin|rural_plateau|river_valley` derived from radial distance and distance_to_water; bank ribbon remains vertex-color transition without extra geometry as budgeted choice (81/128) deferred until terrain trench carve. Settlement vocab village/hamlet/farmstead/isolated_farm/town, road hierarchy primary/secondary/track, gates 4-8 on URBAN_OUTER+-60, spacing village 700 / hamlet 420 / farmstead 220 + 1.8*radius, bridge rule: roads cross water only at hydrology crossing_candidates with is_bridge true; rural building vocab village_house/cottage/barn/farmhouse/stable/shed with counts village 4-6/hamlet 2-3/farmstead 1-2, spacing 8 m, road setback 4 m, cardinal yaw, door faces road/settlement, no building inside floodplain/water/cliff or inside URBAN_INNER_M except gate barn, slope gates `<14` village_house else `<22`, distance_to_water > BANK_W+2.
- Persistence = deterministic regeneration + deltas. Saves store the seed,
  generator version, discovered-chunk set and per-chunk modification dicts (destroyed cells, damage, door states). Raw generated geometry (city meshes, terrain heights, water surfaces, biome overlays, road ribbons, rural shells) is NEVER serialized.
- Generator versioning: saves carry `generator_version`; on mismatch the
  loader warns and regenerates baseline geometry (migration tooling later). `GENERATOR_VERSION` remains 2 through P2, P2.2, P3.1, P4.1 and P4.2 because settlement/road/rural building fabric/hydrology/biome are additive outside the dense historic core (`URBAN_INNER_M=350` flat has no rural anchor except gate barn stubs, rural roads carry `has_road=false` inside 350, river CX 530-710 m) and do not carve city blocks or terrain trench in this slice.
- Streaming pipeline: `ChunkManager._thread_build` builds city batcher + `TerrainChunkBuilder.build_manifest` + `WaterChunkBuilder.build_manifest` + `BiomeChunkBuilder.build_manifest` + `RoadChunkBuilder.build_manifest` + `RuralBuildingChunkBuilder.build_manifest` on WorkerThreadPool with a private `WorldPlan` (plan_mutex guards CityPlan caches), measuring `terrain_gen_ms`/`water_gen_ms`/`biome_gen_ms`/`road_gen_ms`/`rural_gen_ms`; `_materialize` creates `Chunk_X_Y` plus `Terrain_X_Y`, `Water_X_Y`, `Biome_X_Y`, `Road_X_Y`, and `Rural_X_Y` children, measuring `terrain_mat_ms`/`water_mat_ms`/`biome_mat_ms`/`road_mat_ms`/`rural_mat_ms`; early `_collect_finished_jobs(pc)` before streaming recalc plus `MAX_MATERIALIZATIONS_PER_FRAME 1` and Variant freed-Zombie guard (check `is_instance_valid` + `!is_queued_for_deletion()` + `is_inside_tree()` before storing? Actually guard pattern per `debug/streaming_regression_test.gd`: `is_instance_valid(node) and node.is_inside_tree()` before `global_transform`) keep frame budget stable (folded from HEAD 2a423d9, documented here). Water meshes use muted Vltava teal vertex colors; a 1.5 m earth bank ribbon hides the terrain/water seam visually without extra collider. Road ribbons are vertex-colored grey/gravel/dirt per hierarchy plus bridge deck grey, lift 0.04 / 0.35 to avoid z-fighting; shared-edge centerline agreement within 0.02 m at both + and - borders; at most one road collider per chunk, ACTIVE-only, 96/64 typical, 160/96 at junctions. Rural shells are vertex-colored plaster/brick/timber+roof 8a3a2a/5a5a5a boxes at terrain+0.01, lift 0.04, at most one rural collider per chunk, ACTIVE-only, 192/144 typical (dense 320/240 village), cardinal yaw, door faces road/settlement, road setback 4 m, spacing 8 m, building center ownership gives no duplication.

Planned next layers (do not implement early): interiors/furniture passes,
apocalypse damage pass, survivor modification pass, traversal graph records,
parkour controller under actors/traversal/ — plus future village building footprints, rail, and vertical networks that will populate the settlement anchors and road corridors established here.

## Autoload contracts (order matters)

| Autoload | Owns | Must NOT |
|---|---|---|
| `InputSetup` | InputMap actions | anything else |
| `EventBus` | signals only | state |
| `GameClock` | total_minutes, time_scale | gameplay effects |
| `ItemDB` | item defs | instances |
| `ActorRegistry` | live node lookup | persistence |
| `WorldState` | flags, death records | live nodes |
| `QuestManager` | quest states | scene queries |
| `SaveManager` | file IO, ordering | game rules |
| `DebugOverlay` | debug UI/hotkeys | game rules |

## Event flow (the spine)

```
Simulation (zombie bite / starvation / ...)
  -> HealthComponent.died -> Survivor._on_health_died
  -> EventBus.actor_died(actor_id, killer_id)
       -> WorldState.record_death()        (permanent fact)
       -> QuestManager._on_actor_died()
            -> active quest def .on_actor_died() -> may FAIL quest
       -> DebugOverlay log
Quest/dialogue reads WorldState + ActorRegistry -> branches react correctly
```

Adding consequences later = add another subscriber to `EventBus` signals.
Signal list is documented at the top of `event_bus.gd` - keep it current.

## Why quests cannot break

A quest NEVER stores its own copy of an NPC. `QuestFindHana` asks:

- `WorldState.is_dead("npc_hana")` -> fail/grief branch
- `WorldState.has_flag("met_hana")` -> objective advances even if you met her
  *before* the quest started
- live position via `ActorRegistry.get_actor()` if we need it

If Hana dies of infection while you are elsewhere, the quest fails on its own
and Kenji's dialogue switches to grief because his tree checks death first.

## Key design decisions

- **Components created in `_ready()` from a config dict** (`Survivor.configure`)
  so spawning works identically for new game, load, and tests. No .tscn wiring.
- **Two world modes.** `main.gd` picks LEGACY (LevelBuilder test block, used by
  `--smoke`/`--soak`/`--legacy-block`) or CITY (ChunkManager streams the
  procedural city). Legacy stays until the P0 cast migrates into the city.
- **No NavigationServer yet.** Steering + wall sliding + stuck sidestep is
  enough for one block; navmesh baking is a planned upgrade (TODO).
- **Melee hits use direct-space sphere queries**, not Area3D bookkeeping:
  deterministic, cheap, symmetric for player/zombies.
- **Survivors don't collide with each other** (mask excludes their layer) to
  prevent crowding jams; they DO collide with walls and zombies.
- **Needs rates are per GAME minute**, so debug time-scale changes affect
  simulation consistently.
- **Dialogue trees are built at open time** by querying state - conditions can
  never be stale. Upgrade path: same shape moved into Resources + evaluator.
- **Zombies are transient** (not saved); NPC deaths persist via WorldState so
  dead NPCs never respawn after load. Player death is deliberately NOT a
  world fact (recoverable via F9).
- **UI is built in code** (HUD, DialogueUI, DebugOverlay): nothing breaks when
  scripts change; scenes stay trivial (`main.tscn` is one node + script).
- **City geometry is batched**: all boxes of a chunk merge into ONE
  vertex-colored ArrayMesh + one StaticBody3D via MeshBatcher (~2 nodes per
  chunk regardless of prop density). Decorative objects get NO scripted nodes.
  Terrain and water reuse the same pattern: one terrain mesh+Concave and at most one water mesh+Concave per chunk, all parented under the same `Chunk_X_Y` node so streaming unloads them atomically.
- **Streaming stays additive:** hydrology (`HydrologyPlan` + `WaterChunkBuilder`) is owned by `WorldPlan`/`ChunkManager` but `TerrainPlan` remains unchanged this cycle (valley bias at `x=-180` decorative only). The river at `CX 620+-90` is outside the `URBAN_INNER_M=350` flat and beyond `URBAN_OUTER_M=600` transition, so the spawn chunk stays dry and no building footprint overlap check is required. Future in-city trench carving and bridge meshes are deferred.

## Extension points (already wired)

- New world event: declare signal in `EventBus`, emit from source, subscribe
  where consequences belong.
- New quest: script extending `QuestBase`, register in `QuestManager.QUEST_DEFS`.
- New item: entry in `ItemDB.ITEMS`; kinds drive eating/medical handling.
- New need: field + rate in `NeedsComponent`; read it in `NPCBrain._think()`
  and/or `NeedsComponent.speed_multiplier()`.
- Settlements/economy/factions: faction id already exists in IdentityComponent;
  `WorldState.flags` can hold arbitrary typed values today.
- Hydrology consumers: query `WorldPlan.water_body_at / water_level_at / distance_to_water / flow_direction_at / crossing_candidates` or `HydrologyPlan` directly; never duplicate the CX/meander/width math — import `WorldConstants`.
