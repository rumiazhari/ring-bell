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

  generation/          P0.5 deterministic city plan (pure functions of seed+coords)
    world_seed.gd        WorldSeed: seed storage, GENERATOR_VERSION, splitmix
                         RNG helpers - every random choice flows through here
    city_plan.gd         Hierarchical macro plan: districts -> road grid ->
                         urban blocks -> plazas -> parcels/building specs.
                         Cached per instance; queries are order-independent
    building_builder.gd  One building spec -> batched geometry ops (shell,
                         floors, stairs, roof, balconies, windows)
    chunk_builder.gd     Materializes ONE chunk: ground, roads, blocks,
                         buildings via BuildingBuilder, props; MeshBatcher out

  streaming/           P0.5 chunk lifecycle
    chunk_manager.gd     Tracks player chunk; budgeted load/unload queues;
                         ACTIVE/WARM/COLD rings; stats for F3 overlay
    mesh_batcher.gd      Collects (box,color,collide) tuples during build,
                         flushes to ONE merged vertex-colored ArrayMesh +
                         one StaticBody3D per chunk

ui/hud.gd             Clock, vitals bars, quest tracker, prompts, banners,
                      death screen (all code-built)
debug/smoke_test.gd   Headless regression harness (--smoke / --soak modes)
debug/world_test.gd   Headless city determinism harness (--citytest)
camera/follow_camera.gd Elevated rotatable rig; group "camera_rig"
```

## World architecture (P0.5)

Two strictly separated layers:

```
PLAN LAYER (pure, immutable, cheap)          MATERIAL LAYER (scene nodes)
CityPlan(world_seed)                          ChunkManager
  .district_at(cell)                 reads     .load_chunk(coord)
  .roads_near(rect)                  ---->       ChunkBuilder.build(...)
  .blocks_in(rect)                               -> MeshBatcher/MultiMesh
  .buildings_in(rect)                            -> StaticBody3D collision
  .building_by_id(id)                        unload => queue_free subtree
```

- The plan NEVER touches the scene tree; chunks NEVER make random choices -
  all randomness comes from WorldSeed.rng([seed, purpose_hash, coords...]).
- Determinism contract: any two chunk builds for the same coord under the
  same seed produce identical node trees and identical collision shapes,
  regardless of which neighbors were built first. `--citytest` enforces this.
- Chunk size is 64 m (`WorldSeed.CHUNK_SIZE`). Active ring = chebyshev <= 1
  (geometry + physics), warm ring <= 2 (kept resident, future throttling),
  beyond = unloaded. Buildings are owned by the chunk containing their
  footprint center; with a 64 m grid and <= 20 m deep lots this keeps every
  visible building resident while its chunk is active or warm.
- Persistence = deterministic regeneration + deltas. Saves store the seed,
  generator version, discovered-chunk set and per-chunk modification dicts.
  Raw generated geometry is NEVER serialized.
- Generator versioning: saves carry `generator_version`; on mismatch the
  loader warns and regenerates baseline geometry (migration tooling later).

Planned next layers (do not implement early): interiors/furniture passes,
apocalypse damage pass, survivor modification pass, traversal graph records,
parkour controller under actors/traversal/.

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

## Extension points (already wired)

- New world event: declare signal in `EventBus`, emit from source, subscribe
  where consequences belong.
- New quest: script extending `QuestBase`, register in `QuestManager.QUEST_DEFS`.
- New item: entry in `ItemDB.ITEMS`; kinds drive eating/medical handling.
- New need: field + rate in `NeedsComponent`; read it in `NPCBrain._think()`
  and/or `NeedsComponent.speed_multiplier()`.
- Settlements/economy/factions: faction id already exists in IdentityComponent;
  `WorldState.flags` can hold arbitrary typed values today.
