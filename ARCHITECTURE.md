# Ring Bell - Architecture

3D top-down open-world zombie survival RPG centered on realistic survivor
simulation. This document maps the Prototype 0 codebase: what owns what,
how data flows, and where new systems plug in. Read this before editing.

**Golden rules**

1. Small focused files; one responsibility each.
2. Simulation facts live in `WorldState`, never in quest/dialogue scripts.
3. Quests and dialogue query world state - they never fake or copy NPCs.
4. No giant scripts, no hidden behavior, no hard-coded actor IDs in logic.
5. Death is permanent for NPCs. Stories branch around the dead.

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
  main.gd/.tscn          Entry scene; SaveManager "world provider"
  level_builder.gd       Deterministic test block from code (boxes)
  population.gd          Spawn manifest: survivors, zombies, positions
  food_crate.gd          Lootable container; also feeds NPC brains
  day_night_controller.g Sun energy/color, ambient, streetlamps vs clock

ui/hud.gd             Clock, vitals bars, quest tracker, prompts, banners,
                      death screen (all code-built)
debug/smoke_test.gd   Headless regression harness (--smoke / --soak modes)
camera/follow_camera.gd Elevated rotatable rig; group "camera_rig"
```

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

## Extension points (already wired)

- New world event: declare signal in `EventBus`, emit from source, subscribe
  where consequences belong.
- New quest: script extending `QuestBase`, register in `QuestManager.QUEST_DEFS`.
- New item: entry in `ItemDB.ITEMS`; kinds drive eating/medical handling.
- New need: field + rate in `NeedsComponent`; read it in `NPCBrain._think()`
  and/or `NeedsComponent.speed_multiplier()`.
- Settlements/economy/factions: faction id already exists in IdentityComponent;
  `WorldState.flags` can hold arbitrary typed values today.
