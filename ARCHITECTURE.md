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
                         materializes city + terrain + water + biome + road + rural building fabric+hearth; stats for F3 overlay (t_gen/t_mat/t_terrain_gen/t_terrain_mat/t_water_gen/t_water_mat/t_biome_gen/t_biome_mat/t_road_gen/t_road_mat/t_rural_gen/t_rural_mat with hearth stove/bed)
                         Streaming pacing: MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) before streaming recalc; Variant freed-Zombie guard (debug/streaming_regression_test.gd checks is_instance_valid + !is_queued_for_deletion() + is_inside_tree() before global_transform) — extended to hearth Stove/Bed Area3D disable path; unified rural shell+well 1 collider per chunk peak 54 not 63, forage/hearth Area3D monitorable ACTIVE-only
    mesh_batcher.gd      Collects (box,color,collide) tuples during build,
                         flushes to ONE merged vertex-colored ArrayMesh +
                         one StaticBody3D per chunk (ACTIVE-only physics, see below)
    terrain_chunk_builder.gd  17x17 height samples per 64 m chunk (289 verts / 512 tris), one mesh + one Concave per chunk
    water_chunk_builder.gd    9x9 water samples per 64 m chunk (81 verts / <=128 tris, <=1 collider), muted-teal mesh + bank ribbon
    biome_chunk_builder.gd    9x9 biome overlay per 64 m chunk (81 verts / <=128 tris, <=1 collider, <=48 instances), vertex-colored field/forest dressing
    road_chunk_builder.gd     Per-chunk road/bridge ribbon: tessellated flat vertex-colored strip at terrain+0.04 (bridge deck at water+0.35), <=96 verts / <=64 tris typical (junction <=160/96), at most 1 Concave per chunk, ACTIVE-only physics
    rural_building_chunk_builder.gd Per-chunk rural shells+interiors+renewables+hearth: batched vertex-colored boxes at terrain+0.01 per settlement building (footprint 6-10x8-14, height 4.2+2.9*floors, cardinal yaw, plaster/brick/timber walls, roof 8a3a2a/5a5a5a) plus interior 0-1 partition wall (thickness 0.15 inset 0.5 gap 0.95 doorway) +1-3 furniture proxies (bed/shelf/table/stove) +0-3 FoodCrate per village (1/hamlet, ItemDB 40/25/20/15) + village wells (1/hamlet 1-2/village stone ring 0.9x1.8 baked into same Concave unified) + forage patches (2-5 per vicinity bush/mushroom/herb ItemDB 40/25/20/15 distinct weights 45/30/25) + hearth stove/bed (0-1 per building reusing furniture anchor >=0.9/1.0 gates, stove Cook meal Canned Food x1 -> hunger -40 via NeedsComponent, bed Sleep until dawn 480 min -> fatigue -40 via GameClock, Area3D monitorable ACTIVE-only, visuals already in furniture mesh 0 extra verts), <=280 verts / <=210 tris typical (dense <=480/360 village with 6 buildings+2 wells+4 forage+2 stoves+2 beds, hamlet 1-2 buildings+1 well+2 forage+1 hearth <=280/210), at most 1 shell+well Concave per chunk (forage/hearth Area3D no collider, unified peak 54 not 63), ACTIVE-only physics + Door leaves per building (<=6 doors/village) + FoodCrate leaves (<=3) + Well Area3D leaves (<=2) + ForagePatch Area3D leaves (<=4) + Stove/Bed Area3D leaves (<=2/2 hearth <=4)

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
  .road_segments_in(rect)        -> Rural Mesh+Concave+Door leaves (1/chunk, <=280/210 typical, dense <=480/360)
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
- **Budgets:** city geometry batched to ONE vertex-colored ArrayMesh + one StaticBody3D per chunk (ACTIVE-only). Terrain: 17x17 samples per 64 m chunk (4 m spacing, 289 verts / 512 tris, 1 Concave per chunk, 9 active max). Water: 9x9 samples per 64 m chunk (8 m spacing, 81 verts / <=128 tris, at most 1 Concave per wet chunk, 0 if dry, 9 active water max). Biome: 9x9 overlay per 64 m chunk (8 m spacing, 81 verts / <=128 tris, at most 1 biome Concave per forest/quarry chunk, 0 if field/urban, 9 active biome max) plus at most one MultiMeshInstance3D (<=48 forest instances or <=12 field + <=6 quarry) per chunk. Road: flat ribbon per 64 m chunk at terrain+0.04 (bridge deck at water+0.35) with widths 7.0/5.0/3.5 m, <=96 verts / <=64 tris typical (junction <=160/96), at most 1 Concave per chunk, 0 if dry, 9 active road max, shared-edge centerlines within 0.02 m. Rural: batched boxes per building at terrain+0.01, footprint 6-10x8-14 (village 8-10x10-12, barn 8-10x10-14), height 4.2+2.9*floors, plaster/brick/timber+roof 8a3a2a/5a5a5a vertex-colored, <=280 verts / <=210 tris typical (dense <=480/360, hamlet/farmstead 1-2 buildings+1 well+2 forage, village 4-6 buildings+2 wells+4 forage), at most 1 Concave per chunk, 0 if dry, 9 active rural max, doors <=6 per village chunk, road setback >=4 m from centerline, spacing >=8 m. Character: 15 clips (7+Vault 0.55/Mantle 0.85/Hang 1.2 loop/ClimbUp 0.70/CrouchIdle 1.2 loop/CrouchWalk 0.70 loop/Slide 0.90/StandUp 0.35) in-place with capsule lerp 0.18s (CAP_STAND 1.70/CAP_CROUCH 1.25/CAP_SLIDE 1.00, one CapsuleShape3D RID reused, caps_h via locomotion.capsule_height lerped with max_diff/CAP_LERP, headroom sphere 0.25 at +1.55, SLIDE 6.0-6.5 drain 18/s block 15, CROUCH_WALK 1.2 clamped), at most one Skeleton3D+AnimationTree per survivor/zombie, ACTIVE-only `active_chars <=12` `skinned/warm <=9` `animation_ms <=2.0` aggregate (t_anim_ms via Time.get_ticks_usec around locomotion.update, F3 caps_h/crouch/slide), warm disables AnimationTree (active false) while retaining visual including CROUCH_IDLE/SLIDE frozen pose and vault/mantle progress without pop and HANG frozen pose without pop, no per-frame RID/Concave (capsule height property reuse, hands IK reuses bone poses). Per-chunk timings `t_gen/t_mat` (city) plus `t_terrain_gen/t_terrain_mat` and `t_water_gen/t_water_mat` and `t_biome_gen/t_biome_mat` and `t_road_gen/t_road_mat` and `t_rural_gen/t_rural_mat` plus `t_anim_ms` (character) are measured inside the worker (`_thread_build` with private WorldPlan) and on the main thread (`materialize`) and via `CharacterLocomotion.update` and exposed via `ChunkManager.debug_lines()` and F3 overlay `loco:` line. Water district_hint `urban_basin|rural_plateau|river_valley` derived from radial distance and distance_to_water; bank ribbon remains vertex-color transition without extra geometry as budgeted choice (81/128) deferred until terrain trench carve. Settlement vocab village/hamlet/farmstead/isolated_farm/town, road hierarchy primary/secondary/track, gates 4-8 on URBAN_OUTER+-60, spacing village 700 / hamlet 420 / farmstead 220 + 1.8*radius, bridge rule: roads cross water only at hydrology crossing_candidates with is_bridge true; rural building vocab village_house/cottage/barn/farmhouse/stable/shed with counts village 4-6/hamlet 2-3/farmstead 1-2, spacing 8 m, road setback 4 m, cardinal yaw, door faces road/settlement, no building inside floodplain/water/cliff or inside URBAN_INNER_M except gate barn, slope gates `<14` village_house else `<22`, distance_to_water > BANK_W+2.
- Persistence = deterministic regeneration + deltas. Saves store the seed,
  generator version, discovered-chunk set and per-chunk modification dicts (destroyed cells, damage, door states). Raw generated geometry (city meshes, terrain heights, water surfaces, biome overlays, road ribbons, rural shells) is NEVER serialized.
- Generator versioning: saves carry `generator_version`; on mismatch the
  loader warns and regenerates baseline geometry (migration tooling later). `GENERATOR_VERSION` remains 2 through P2, P2.2, P3.1, P4.1 and P4.2 because settlement/road/rural building fabric/hydrology/biome are additive outside the dense historic core (`URBAN_INNER_M=350` flat has no rural anchor except gate barn stubs, rural roads carry `has_road=false` inside 350, river CX 530-710 m) and do not carve city blocks or terrain trench in this slice.
- Streaming pipeline: `ChunkManager._thread_build` builds city batcher + `TerrainChunkBuilder.build_manifest` + `WaterChunkBuilder.build_manifest` + `BiomeChunkBuilder.build_manifest` + `RoadChunkBuilder.build_manifest` + `RuralBuildingChunkBuilder.build_manifest` on WorkerThreadPool with a private `WorldPlan` (plan_mutex guards CityPlan caches), measuring `terrain_gen_ms`/`water_gen_ms`/`biome_gen_ms`/`road_gen_ms`/`rural_gen_ms`; `_materialize` creates `Chunk_X_Y` plus `Terrain_X_Y`, `Water_X_Y`, `Biome_X_Y`, `Road_X_Y`, and `Rural_X_Y` children, measuring `terrain_mat_ms`/`water_mat_ms`/`biome_mat_ms`/`road_mat_ms`/`rural_mat_ms`; early `_collect_finished_jobs(pc)` before streaming recalc plus `MAX_MATERIALIZATIONS_PER_FRAME 1` and Variant freed-Zombie guard (check `is_instance_valid` + `!is_queued_for_deletion()` + `is_inside_tree()` before storing? Actually guard pattern per `debug/streaming_regression_test.gd`: `is_instance_valid(node) and node.is_inside_tree()` before `global_transform`) keep frame budget stable (folded from HEAD 2a423d9, documented here). Water meshes use muted Vltava teal vertex colors; a 1.5 m earth bank ribbon hides the terrain/water seam visually without extra collider. Road ribbons are vertex-colored grey/gravel/dirt per hierarchy plus bridge deck grey, lift 0.04 / 0.35 to avoid z-fighting; shared-edge centerline agreement within 0.02 m at both + and - borders; at most one road collider per chunk, ACTIVE-only, 96/64 typical, 160/96 at junctions. Rural shells are vertex-colored plaster/brick/timber+roof 8a3a2a/5a5a5a boxes at terrain+0.01, lift 0.04, at most one rural collider per chunk, ACTIVE-only, 280/210 typical (dense 480/360 village+well+forage), cardinal yaw, door faces road/settlement, road setback 4 m, spacing 8 m, building center ownership gives no duplication.

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

## P4.3 Rural Interior & Scavenge — this cycle (delta from P4.2)

- RuralBuildingPlan now enriched with deterministic interiors: 0-1 partition wall (village_house/cottage/farmhouse, thickness 0.15 length lerp 0.55-0.85*min-0.4 gap 0.90-1.10 inset 0.5 not overlapping door swing 1.0), 1-3 furniture proxies per building (bed/shelf/table/stove) against walls >=0.9, crate 0-3 per village chunk 1 per hamlet 1-4 items ItemDB 40/25/20/15. Domains added: rural_interior, rural_interior_wall, rural_interior_wall_gap, rural_furniture, rural_crate, rural_crate_contents (ordered). Generation via WorldSeed.unit_float domain-separated, handles negative coords, additive GENERATOR_VERSION stays 2.
- RuralBuildingChunkBuilder now batches shell+interior walls+furniture into one ArrayMesh vertex-colored (wall darker *0.88 furniture bed 9e8b6a shelf 6b5a4a table 7a6a5a stove 4a4a4a) and one aggregated shell+interior Concave per chunk (furniture visual only) + Door leaves + FoodCrate leaves per crate manifest. Budgets: verts <=400 tris <=300 per chunk typical hamlet/farmstead <=240/180, doors <=6 per village crates <=3 furniture <=6, 3x3 ACTIVE <=9 rural colliders <=9 active crates when ACTIVE (warm collision_layer 0 and crate enabled false).
- ChunkManager streaming: worker private WorldPlan measures t_rural_gen now shell+interior+crate, main t_rural_mat with FoodCrate instantiation, debug_lines rural verts|tris|colliders|doors|buildings|crates|furniture t_rural_gen|t_rural_mat active rural (warm), ACTIVE-only rural shell and crate (warm visuals retained). MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) before streaming recalc + Variant freed-Zombie guard is_instance_valid && !is_queued_for_deletion() && is_inside_tree() before global_transform (debug/streaming_regression_test.gd).
- Persistence: save_state() persists seed/version/discovery/deltas including deltas.crates : {crate_id: {item:count}} sibling to doors/damage; generated rural shells/interiors/furniture/crate polylines never serialized, re-derived deterministically, crate deltas re-applied before materialize (matching dead_doors).
- Budgets not weakened: city 9/terrain 9/water <=9/biome <=9/road <=9/rural <=9 shell colliders intact (<=54 peak <=63 with 9 active crates ACTIVE-only) t_rural_gen/mat within FRAME_BUDGET_MS 12.
- Windowed proof archived: .hermes/autopilot/reports/SPEC-C006-windowed.png+log (1200x720 windowed CITY, WASD/E door, stairs, F3 overlay with active rural + t_rural_gen/mat and crates, 600-900m east along rural road corridor to river valley with continuous rural shells+bridge+hedgerow and through open door partition 0.95 + furniture + crate prompt Search shelves (Canned Food x1) via E, prompt updates). Prior synthetic SPEC-C002--C005 windowed placeholders correctly deferred and referenced.
- Tools: run_suite 400 timeout for citytest/roadtest/ruraltest (450 guidance for slower CI), headless inside_tree guards extended to crate path, ObjectDB !is_inside_tree noise reduced where feasible, WORLD-CONTRACT §15 added.

## P4.4 Rural Homestead Renewables — this cycle (delta from P4.3)

- WorldConstants: MAX_RURAL_VERTS/TRIS raised 400/300 -> 480/360 (typical 240/180 -> 280/210) to carry wells+forage (well 24 verts/12 tris, forage 24/12); new constants RURAL_WELL_RADIUS 0.9 HEIGHT 1.8 MAX_PER_CHUNK 2 MAX_PER_VILLAGE 2/HAMLET1/FARMSTEAD1, RURAL_FORAGE_MAX_PER_CHUNK 4 VILLAGE5/HAMLET3 VICINITY120 ALLOW_BIOMES arable_field/pasture/pasture_orchard/orchard/deciduous/mixed_upland/wet_meadow, ROAD_SETBACK well4.0 forage2.0, BUILDING_GAP well8 forage6, WELL_SPACING6 FORAGE_SPACING4, vocab bush_berry/mushroom_cluster/herb_patch, colors well 8b7f6e water2b3a4a beam6b5a4a bush5a7a3a mush8a6a4a herb6a8a5a. Justification: village core 6 buildings+2 wells+4 forage still within 480/360, hamlet 1-2+1 well+2 forage <=280/210.
- WorldSeed: added RURAL_RESOURCE_DOMAINS ordered [&"rural_well",&"rural_well_radius",&"rural_well_angle",&"rural_well_nudge",&"rural_forage",&"rural_forage_kind",&"rural_forage_density"] domain-separated from building/interior.
- RuralBuildingPlan enriched additive (GENERATOR_VERSION stays 2): deterministic wells (village 1-2 hamlet1 strict farmstead0-1 isolated0-1 via unit_float rural_well, polar offset lerp 0.35-0.65*radius + TAU jitter, validated flat <14/<22 not cliff/water/floodplain road4.0 building gap8 well spacing6, 8+12 attempts + fallback for hamlet strict 1) and forage (per settlement vicinity 2-5 village3-5 hamlet2-3 farmstead1-2 via rural_forage, rad 12-120 + +-3 jitter, allowed biomes slope<14/22 road2.0 building6 well6 forage4, cap 4 per chunk) with ItemDB weighted 40/25/20/15 single item, pure handles negative coords.
- RuralBuildingChunkBuilder: manifests now include well_manifests/forage_manifests + rural_wells/rural_forage/well/forage vertices/triangles; batched single ArrayMesh now shell+interior walls+furniture+well boxes (24/12) + forage boxes (24/12) vertex-colored, single shell+well Concave per chunk (forage Area3D no collider), has_rural extended to well/forage, per-chunk caps wells<=2 forage<=4 doors<=6 crates<=3 furniture<=6; materialize creates Rural_* plus Door+FoodCrate+Well (StaticBody+Interactable Draw water) +ForagePatch (Area3D Forage bushes) leaves; budgets 480/360 enforced.
- ChunkManager: t_rural_gen now shell+interior+crate+well+forage, t_rural_mat with Well/Forage instantiation; debug_lines rural verts|tris|colliders|doors|buildings|crates|furniture|wells|forage t_rural_gen|t_rural_mat active rural (warm); totals _rural_wells_total/_rural_forage_total; ACTIVE-only shell+well collider + crate/well/forage interactability (warm RuralBody layer0, crates/wells enabled==ACTIVE && not empty/depleted, forage monitorable==ACTIVE && not depleted); persistence deltas.wells {depleted,depleted_at_day} and deltas.forage {depleted,depleted_at_day,contents} sibling to crates/doors/damage, re-applied before materialize with GameClock refill well at 04:00 next day (total_minutes >= depleted_at_day*1440+240) and forage after 2 days (day >= depleted_at_day+2); save_state() snapshot wells/forage.
- Docs: WORLD-CONTRACT §16 Rural Homestead Renewables, ARCHITECTURE streaming notes 280/210 480/360 justification wells<=2 forage<=4 Well/ForagePatch ItemDB table + regrow 1 day 04:00/2 days, ACTIVE-only clarified for wells/forage+crates, pacing 1-per-frame + freed-Zombie guard verbatim, run_suite 400, §16 folding C001-C006 deferred docs.

## P4.5 Rural Hearth Habitation — this cycle (delta from P4.4)

- WorldConstants: added RURAL_HEARTH_VOCAB [&"stove",&"bed"] subset of furniture, RURAL_STOVE_MAX_PER_CHUNK 2 / RURAL_BED_MAX_PER_CHUNK 2 / RURAL_HEARTH_MAX_PER_CHUNK 4, COL_FURNITURE_STOVE 4a4a4a COL_FURNITURE_BED 9e8b6a, STOVE_HUNGER_REDUCTION 40 BED_FATIGUE_REDUCTION 40 BED_SLEEP_MINUTES 480 WELL_REFILL_HOUR 4 FORAGE_REGROW_DAYS 2. Documented unified peak 54 not 63 (9 city+9 terrain+9 water+9 biome+9 road+9 rural where rural is single shell+well Concave, forage/hearth Area3D monitorable ACTIVE-only, no collider). Hearth reuses furniture mesh vertices (24 verts already counted) so 480/360 dense 280/210 typical unchanged.

- WorldSeed: reused existing RURAL_FURNITURE domains for hearth (no new domain, GENERATOR_VERSION stays 2); forage kind weights corrected from duplicate bush fallback (0-0.40/0.40-0.65/0.65-0.85/else bush) to distinct 45/30/25 (bush_berry 0-0.45, mushroom_cluster 0.45-0.75, herb_patch 0.75-1.0) via rural_forage_kind domain, settlement-vicinity contract documented as authoritative (per-landscape-cell 256 m distribution deferred to field-parcel cultivation).

- RuralBuildingPlan enriched additive (GENERATOR_VERSION stays 2): deterministic hearth via _build_hearth reusing furniture anchors where kind==stove/bed (id rural_stove_%s / rural_bed_%s, pos/yaw/size copied, inherits >=0.9 from walls and 1.0 from door swing via furniture gates, inside inset 0.5). Added public queries rural_hearths_in(rect) + nearest_rural_hearth(p,kind) + hearths_for_settlement, flat clipped list sorted by id. Interior now {walls,furniture,crate,hearth:{stove:{},bed:{}}} and cache invalidated if stale without hearth. Forage kind mapping fixed, settlement-vicinity documented.

- RuralBuildingChunkBuilder: manifests now include hearth_manifests/stove_manifests/bed_manifests + rural_hearths/rural_stoves/rural_beds + has_hearth/has_stove/has_bed; batched single ArrayMesh shell+interior walls+furniture (including stove/bed visuals) + well boxes + forage boxes, single shell+well Concave per chunk (well baked, forage/hearth Area3D no collider), has_rural extended to well/hearth, per-chunk caps stoves<=2 beds<=2 hearth<=4; materialize creates Rural_* plus Door+FoodCrate+Well Area3D +ForagePatch Area3D +Stove Area3D +Bed Area3D leaves (monitorable ACTIVE-only, visuals already in mesh 0 extra verts/colliders), budgets 480/360 enforced, peak 54 unified verified via body count == rural_colliders.

- New world nodes: world/stove.gd (class Stove extends Area3D, Interactable "Cook meal (Canned Food x1)" -> "Stove — needs Canned Food", consumes 1 canned_food and needs.eat(40), monitorable ACTIVE-only, set_active_enabled) and world/bed.gd (class Bed extends Area3D, Interactable "Sleep until dawn", advances GameClock 480 and needs.fatigue -40, monitorable ACTIVE-only). Well.gd converted from StaticBody3D to Area3D (collision_layer 0, monitorable ACTIVE-only, shared Concave, no second WellBody, set_active_enabled).

- ChunkManager: added totals _rural_hearths_total/_rural_stoves_total/_rural_beds_total, per-chunk record fields rural_hearths/stoves/beds + hearths_active/stoves_active/beds_active, debug_lines rural verts|tris|colliders|doors|buildings|crates|furniture|wells|forage|hearth|stoves|beds t_rural_gen|t_rural_mat active rural (warm) (now includes hearth), ACTIVE-only unified rural shell+well collider + crate/well/forage/hearth (warm RuralBody layer0 and crate/well/forage/hearth enabled==ACTIVE && not depleted/empty, stove additionally checks canned_food, forage/hearth monitorable==ACTIVE && not depleted, is_instance_valid && !is_queued_for_deletion() && is_inside_tree() guards extended to hearth path). Persistence: hearth stateless (no deltas.hearth), wells/forage deltas re-applied before materialize with GameClock refill well at 04:00 next day (total_minutes >= depleted_at_day*1440+240) and forage after 2 days (day >= depleted_at_day+2) now proven via GameClock.advance in harness and patch size check.

- Docs: WORLD-CONTRACT §17 Rural Hearth Habitation added, ARCHITECTURE streaming notes updated to 280/210 480/360 with wells<=2 forage<=4 stoves<=2 beds<=2 hearth<=4 Well Area3D + Stove/Bed ItemDB/Needs/GameClock table + regrow 04:00/2 days + 480 min sleep, ACTIVE-only clarified for hearth, unified 54 peak not 63, pacing 1-per-frame + freed-Zombie guard verbatim (is_instance_valid + !is_queued_for_deletion() + is_inside_tree()), run_suite 400, §17 folding C001-C007 deferred docs.



## P5.1 Field-Parcel Cultivation — this cycle (delta from P4.5)

- WorldConstants: added FIELD_PARCEL_VOCAB [&"wheat",&"barley",&"potato",&"beet"] CROP_VOCAB reuse, FIELD_PARCEL_SIZE_MIN Vector2(18,14) MAX Vector2(64,48), FIELD_PARCEL_MAX_PER_LANDSCAPE_CELL 3 MAX_PER_CHUNK 4 FIELD_DENSITY_MIN 0.38 FIELD_CROP_MAX_PER_CHUNK 4 ROAD_SETBACK 3.0 BUILDING_GAP 8.0 SPACING_MIN 4.0 WELL_FORAGE_GAP 6.0 CROP_GROW_DAYS 2 CROP_REGROW_DAYS 2 FIELD_PARCEL_LIFT_M 0.02 HEDGEROW_HEIGHT 0.6 HEDGEROW_COLOR 5a7a3a COL_FIELD_WHEAT c2b280 COL_FIELD_BARLEY 8faa6a COL_FIELD_POTATO 6e635a COL_FIELD_BEET 6a8a5a MAX_FIELD_VERTS 96 MAX_FIELD_TRIS 64 FIELD_HEDGEROW_MAX_PER_CHUNK 8. Justification: overlay 81/128 + tilled 96/64 per chunk typical 64/32 for 2 parcels dense 96/64 for 4 parcels, hedgerow 2 per parcel <=8 of global 48, field Area3D not counted to 54 peak.

- WorldSeed: added FIELD_PARCEL_DOMAINS ordered [&"field_parcel",&"field_parcel_density",&"field_parcel_crop",&"field_parcel_yaw"] seed-separated from terrain/hydro/geology/biome/settlement/road/rural_building/rural_interior/rural_resource, handles negative coords via floori.

- BiomePlan enriched additive (GENERATOR_VERSION stays 2): deterministic field parcels per 256 m landscape cell (LANDSCAPE_CELL_M) with village-adjacent +1 bias (cell center within settlement.radius*1.4 of village) and density coherent noise field_parcel_density at cell center plus unit_float field_parcel for precise 0-3 variety, density threshold 0.38 below which 0 parcels even in arable. Per-parcel siting: pos = cell_origin + lerp(12,256-12) via field_parcel unit_float, size lerp(18,64) and (14,48), inset 2.0 from cell border, validated aabb fully inside allowed biome (arable_field/pasture/pasture_orchard/orchard) terrain_class !=cliff slope <12 (arable) /14 (pasture/orchard) hydrology water_body=="" not floodplain distance_to_water > BANK+2 road >=3.0 never is_bridge and >=8 building >=6 well/forage spacing >=4 between parcels via aabb_gap, height variance 0.8 across aabb corners else 12 nudge attempts; if violated parcel dropped. Orientation yaw 0/PI*0.5 cardinal aligned to nearest track tangent if dist_to_road <40 else quantized 0/90 via field_parcel_yaw, crop_kind weighted wheat 35 barley 30 potato 20 beet 15 via field_parcel_crop, planted_day deterministic 0+int(unit_float*7) growth days_since_plant via GameClock.get_day() planted+2 harvestable else Growing, contents mapping wheat->canned_food barley->water_bottle potato->bandage beet->antibiotics ItemDB 40/25/20/15, id stable field_parcel_<cx>_<cy>_<k>, landscape_cell/macro_cell/settlement_id stored, pure handles negative coords.

- WorldPlan facade owns BiomePlan enriched and forwards field_parcels_in(rect) / nearest_field_parcel(p) / field_parcels() / crop_patch_for_parcel(parcel_id) pure queries, plus existing biome_at etc., constructed once per worker thread, plan_mutex guards CityPlan caches exactly as before. WorldPlan._init now injects settlement/road/rural refs into BiomePlan via set_world_refs for village_adjacent and road/building gaps.

- BiomeChunkBuilder extended additive: manifest per 64 m chunk via build_manifest(world_plan, coord) now includes field_parcel_manifests (Array clipped by center inside rect, per-parcel id/center/pos/aabb/biome/crop_kind/size/yaw/planted_day/growth_stage/is_grown/contents) plus field_parcels/field_crops/field_vertices/field_triangles/field_hedgerow counts, tilled quad vertices at terrain+0.02 with crop-specific vertex colors c2b280/8faa6a/6e635a/6a8a5a plus hedgerow MultiMesh at parcel borders via field hedgerow Box 2.0x0.6x0.4 vertex-colored 5a7a3a (2 per parcel capped 8 of 48), at most 1 biome collider per chunk (0/1) plus <=4 field parcels <=4 CropPatch hedgerow <=8 of 48, overlay 81/128 plus field tilled <=96/64 per chunk typical 64/32 dense 96/64, biome_instances <=48, 3x3 ACTIVE <=9 biome colliders monitorable not counted to 54 peak not 63, t_biome_gen/mat within FRAME_BUDGET_MS 12. Materialize creates Biome_X_Y Node3D with BiomeMesh (batched overlay 81 plus tilled quads) + BiomeMultimesh (forest+field_edge+hedgerow) + optional BiomeBody BoxShape 0.6x1.2x0.6 aggregated + per-parcel CropPatch Area3D leaves parented under same Biome_X_Y as CropPatch_<parcel_id> nodes, mirroring Well/ForagePatch/Stove/Bed pattern but under biome tree, measures biome_mat_ms, returns stats field_parcels/field_crops/field_vertices/field_triangles/field_hedgerow.

- New world node: world/crop_patch.gd (class CropPatch extends Area3D, Interactable "Harvest wheat (Wheat x1)" -> "Picked clean — regrows in 2 days" and "Growing — ready in N days" when not is_grown, yields 1 ItemDB item via InventoryComponent/GameClock day staging planted+2 harvestable, depleted 2 days regrow, monitorable ACTIVE-only, collision_layer 0, no collider counted, set_active_enabled, save_state deltas.field_crops).

- ChunkManager: added totals _field_parcels_total/_field_crops_total/_field_vertices_total/_field_triangles_total/_field_hedgerow_total, per-chunk record fields field_parcels/field_crops/field_vertices/field_triangles/field_hedgerow/field_parcels_active/field_crops_active, t_biome_gen now overlay+tilled+hedgerow+CropPatch derivation within same biome_gen_ms, debug_lines biome verts|tris|colliders|instances|field_parcels|field_crops t_biome_gen|t_biome_mat active biome (warm) plus F3 overlay active biome 81/128 plus t_biome_gen/mat and field_parcels/field_crops alongside active road/water/terrain/rural hearth, ACTIVE-only CropPatch Area3D monitorable (warm monitorable=false + Interactable.enabled=false when warm or depleted or not grown, same pattern as rural Well/ForagePatch), hedgerow visuals retained when warm but BiomeBody collision_layer 0 when warm, single BiomeBody 1 collider sharing overlay+tilled, hedgerow MultiMesh not collider. Persistence: save_state() persists seed/version/discovery/deltas including deltas.field_crops {crop_id:{depleted,depleted_at_day,contents,planted_day,crop_kind}} sibling to crates/wells/forage/doors/damage, generated field parcels/crop quads/hedgerow never serialized, re-derived deterministically, deltas re-applied before materialize with GameClock regrow 2 days and is_grown gate planted+2 proven via GameClock.advance mock, Variant freed-Zombie guard extended to CropPatch path (is_instance_valid + !is_queued_for_deletion() + is_inside_tree() before global_transform) and MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) pacing retained.

- Docs: WORLD-CONTRACT §18 Field-Parcel Cultivation added, ARCHITECTURE streaming notes updated to 81/128+96/64 tilled CropPatch ACTIVE-only 1 collider/9 active unified 54 peak, 280/210 480/360 with wells<=2 forage<=4 stoves<=2 beds<=2 hearth<=4 plus field_parcels<=4 field_crops<=4 hedgerow<=8 of 48, tiling lift 0.02, crop GROW 2 REGROW 2 ItemDB 40/25/20/15, ACTIVE-only clarified for CropPatch, pacing 1-per-frame + freed-Zombie guard verbatim, run_suite 300 for biometest (400 for citytest/roadtest/ruraltest), WORLD-CONTRACT §18, folding C001-C008 deferred docs.



## P5.2 Orchard Row Cultivation — this cycle (delta from P5.1)

- WorldConstants: added ORCHARD_PARCEL_VOCAB [&"apple",&"plum",&"pear",&"cherry"] FRUIT_VOCAB reuse, ORCHARD_PARCEL_SIZE_MIN Vector2(20,16) MAX Vector2(68,52), ORCHARD_PARCEL_MAX_PER_LANDSCAPE_CELL 2 MAX_PER_CHUNK 3 ORCHARD_DENSITY_MIN 0.42 ORCHARD_CROP_MAX_PER_CHUNK 3 FRUIT_MAX_PER_CHUNK 3 ROAD_SETBACK 3.0 BUILDING_GAP 8.0 SPACING_MIN 4.0 WELL_FORAGE_GAP 6.0 FRUIT_GROW_DAYS 3 FRUIT_REGROW_DAYS 3 ORCHARD_PARCEL_LIFT_M 0.04 HEDGEROW_TRUE 2.0x0.45-0.75x0.4 5a7a3a TRUNK 6b5a4a 0.35x1.8x0.35 CANOPY 1.4x1.0x1.4 COL_CANOPY 3a7a3a/4a6a4a/6a8a5a/7a5a6a HEDGEROW_TRUE_LENGTH 2.0 WIDTH 0.4 ORCHARD_TREE_SPACING 5.0 ROW_SPACING 5.5 ORCHARD_MAX_SLOPE 14 ORCHARD_HEDGEROW_MAX_PER_CHUNK 6 MAX_ORCHARD_INSTANCES 12. Corrected FIELD_PARCEL_LIFT_M 0.02->0.04 (tilled quads now terrain+0.04 0.01 above overlay 0.03 exposing furrows), hedgerow upgraded to true-mesh 2.0x0.45-0.75x0.4 vertex-colored 5a7a3a with height jitter 0.45-0.75 (not stretched). Justification: overlay 81/128 + tilled 96/64 at 0.04 plus orchard canopy 12 of 48 plus hedgerow 8 field +6 orchard of 48, total instances <=48, orchard Area3D <=3 fruit patches per chunk monitorable ACTIVE-only not counted to 54 peak not 63.

- WorldSeed: added ORCHARD_PARCEL_DOMAINS ordered [&"orchard_parcel",&"orchard_parcel_density",&"orchard_parcel_fruit",&"orchard_parcel_yaw"] after FIELD_PARCEL_DOMAINS, seed-separated, handles negative coords via floori.

- ItemDB: added distinct fruit items apple/plum/pear/cherry as KIND_FOOD with hunger_reduction 18/16/14/12 (apple 18 plum 16 pear 14 cherry 12) distinct names, keep canned_food 40 etc unchanged; at least apple+plum harvestable via FruitPatch distinct 40/30/15/15 weighted.

- BiomePlan enriched additive (GENERATOR_VERSION stays 2): deterministic orchard parcels per 256 m landscape cell (LANDSCAPE_CELL_M) with village-adjacent +1 bias (cell center within settlement.radius*1.35 of village) and orchard_density coherent noise at cell center plus unit_float orchard_parcel for precise 0-2 variety, density threshold 0.42 below which 0 parcels even in orchard. Per-parcel siting: pos = cell_origin + lerp(14,256-14) via orchard_parcel unit_float, size lerp(20,68) and (16,52) inset 2.0 from cell border, validated aabb fully inside allowed biome (orchard/pasture_orchard) terrain_class !=cliff slope <14 hydrology water_body=="" not floodplain distance_to_water > BANK+2 road >=3.0 never is_bridge and >=8 building >=6 well/forage spacing >=4 via aabb_gap, height variance 0.9 across aabb corners else 12 nudge attempts; if violated parcel dropped. Orientation yaw 0/PI*0.5 cardinal aligned to nearest track tangent if dist_to_road <40 else quantized 0/90 via orchard_parcel_yaw, fruit_kind weighted apple 40 plum 30 pear 15 cherry 15 via orchard_parcel_fruit, planted_day deterministic 0+int(unit_float*7) growth via GameClock.get_day() planted+3 harvestable else Growing, contents mapping fruit->fruit ItemDB, id stable orchard_parcel_<cx>_<cy>_<k>, landscape_cell/macro_cell/settlement_id stored, tree_rows 3 if size.x <40 else 4 trees_per_row 3 if size.y <30 else 4-5 via orchard_parcel domain spaced 5.0/5.5 jitter +-0.6, tree_instances at terrain+0.04 trunk 0.35x1.8 + canopy 1.4x1.0x1.4, pure handles negative coords. Also corrected FIELD_PARCEL_LIFT_M to 0.04.

- WorldPlan facade owns BiomePlan enriched and forwards orchard_parcels_in(rect) / nearest_orchard_parcel(p) / orchard_parcels() / fruit_patch_for_parcel(parcel_id) pure queries plus existing field_parcels_in etc., constructed once per worker thread, plan_mutex guards CityPlan caches exactly as before. WorldPlan._init injects settlement/road/rural refs into BiomePlan via set_world_refs for village_adjacent and road/building gaps for both field and orchard.

- BiomeChunkBuilder extended additive: manifest per 64 m chunk via build_manifest(world_plan, coord) now includes orchard_parcel_manifests (Array clipped by center inside rect, per-parcel id/center/pos/aabb/biome/fruit_kind/size/yaw/planted_day/growth_stage/is_grown/contents/tree_instances/tree_rows/trees_per_row) plus orchard_parcels/fruit_patches/orchard_vertices/orchard_triangles/orchard_hedgerow/orchard_instances counts, canopy MultiMesh rows 3-4 rows 3-5 trees 5.0 spacing trunk 6b5a4a + canopy 3a7a3a/4a6a4a etc at terrain+0.04 plus hedgerow true-mesh at parcel borders via orchard hedgerow Box 2.0x0.45-0.75x0.4 vertex-colored 5a7a3a (2 per parcel capped 6 of 48) plus existing field hedgerow true-mesh 2.0x0.45-0.75x0.4 (2 per parcel capped 8), at most 1 biome collider per chunk (0/1) plus <=4 field parcels <=3 orchard parcels <=4 CropPatch <=3 FruitPatch hedgerow <=8 field <=6 orchard of 48 plus canopy <=12 of 48, overlay 81/128 plus field tilled <=96/64 at 0.04 plus orchard canopy 12 of 48, biome_instances <=48, 3x3 ACTIVE <=9 biome colliders monitorable not counted to 54 peak not 63, t_biome_gen/mat within FRAME_BUDGET_MS 12. Materialize creates Biome_X_Y Node3D with BiomeMesh (batched overlay 81 plus tilled quads at 0.04) + BiomeMultimesh (forest+field_edge+hedgerow+canopy true-mesh) with StandardMaterial3D vertex_color_use_as_albedo true albedo 5a7a3a + optional BiomeBody BoxShape + per-parcel CropPatch Area3D + per-parcel FruitPatch Area3D leaves parented under same Biome_X_Y as FruitPatch_<parcel_id> nodes, mirroring Well/ForagePatch/Stove/Bed/CropPatch pattern but under biome tree, measures biome_mat_ms, returns stats orchard_parcels/fruit_patches/orchard_hedgerow/orchard_instances. Corrected tilled lift 0.04 and hedgerow true-mesh not stretched.

- New world node: world/fruit_patch.gd (class FruitPatch extends Area3D, Interactable "Harvest apples (Apple x1)" -> "Picked clean — regrows in 3 days" and "Growing — ready in N days" when not is_grown, yields 1 ItemDB fruit apple/plum/pear/cherry via InventoryComponent/GameClock day staging planted+3 harvestable, depleted 3 days regrow, monitorable ACTIVE-only, collision_layer 0, no collider counted, set_active_enabled, save_state deltas.fruit_patches). Extends ObjectDB inside_tree guards to FruitPatch path.

- ChunkManager: added totals _orchard_parcels_total/_fruit_patches_total/_orchard_vertices_total/_orchard_triangles_total/_orchard_instances_total/_orchard_hedgerow_total, per-chunk record fields orchard_parcels/fruit_patches/orchard_vertices/orchard_triangles/orchard_hedgerow/orchard_instances/orchard_parcels_active/fruit_patches_active, t_biome_gen now overlay+tilled 0.04+hedgerow true-mesh+canopy+fruit derivation within same biome_gen_ms, debug_lines biome verts|tris|colliders|instances|field_parcels|field_crops|orchard_parcels|fruit_patches t_biome_gen|t_biome_mat active biome (warm) plus F3 overlay active biome 81/128 plus t_biome_gen/mat and field_parcels/field_crops/orchard_parcels/fruit_patches alongside active road/water/terrain/rural hearth, ACTIVE-only FruitPatch Area3D monitorable (warm monitorable=false + Interactable.enabled=false when warm or depleted or not grown, same pattern as CropPatch), hedgerow+canopy visuals retained when warm but BiomeBody collision_layer 0 when warm, single BiomeBody 1 collider sharing overlay+tilled, hedgerow+canopy MultiMesh not collider. Persistence: save_state() persists seed/version/discovery/deltas including deltas.fruit_patches {fruit_id:{depleted,depleted_at_day,contents,planted_day,fruit_kind}} sibling to field_crops/crates/wells/forage/doors/damage, generated orchard parcels/canopy quads/hedgerow true-mesh never serialized, re-derived deterministically, deltas re-applied before materialize with GameClock regrow 3 days and is_grown gate planted+3 proven via GameClock.advance mock, Variant freed-Zombie guard extended to FruitPatch path (is_instance_valid + !is_queued_for_deletion() + is_inside_tree() before global_transform) and MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) pacing retained.

- Docs: WORLD-CONTRACT §19 Orchard Row Cultivation added, ARCHITECTURE streaming notes updated to 81/128+96/64 tilled 0.04 + canopy 12 of 48 + FruitPatch ACTIVE-only 1 collider/9 active unified 54 peak, 280/210 480/360 with wells<=2 forage<=4 stoves<=2 beds<=2 hearth<=4 plus field_parcels<=4 field_crops<=4 orchard_parcels<=3 fruit_patches<=3 hedgerow<=8 field <=6 orchard 12 canopy of 48, tiling lift 0.04, fruit GROW 3 REGROW 3 ItemDB apple 18 plum 16 pear 14 cherry 12 weighted 40/30/15/15, ACTIVE-only clarified for FruitPatch, pacing 1-per-frame + freed-Zombie guard verbatim, run_suite 300 for biometest (400 for citytest/roadtest/ruraltest), WORLD-CONTRACT §19, folding C001-C009 deferred docs, deduplicated P5.1 duplicate section.

- Streaming pacing retained: MAX_MATERIALIZATIONS_PER_FRAME 1 with early _collect_finished_jobs(pc) before streaming recalc + Variant freed-Zombie guard is_instance_valid && !is_queued_for_deletion() && is_inside_tree() before global_transform documented verbatim in streaming section, not just commit message.

