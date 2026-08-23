# Roadmap / TODO

## Current priority: P0.5 - Procedural City + Vertical Traversal Prototype

Development priority has shifted: the front-end/world foundation comes BEFORE
deeper survivor simulation. Relationships, memories, factions, economy,
advanced quests/psychology and settlement simulation are deferred until the
chunked world architecture exists.

Target: ONE convincing generated district slice (3x3..5x5 active chunks of
64 m x 64 m chunks), dense Prague-inspired historic core, real multi-floor
buildings with interiors/stairs/roofs, chunk streaming + persistence,
and first-person-of-view traversal (sprint/jump/vault/mantle/ledge/climb/
fall damage) working on procedural architecture. Camera stays elevated
top-down.

### Phase A - Architecture (DONE)
- [x] World seed + generator version constants (world/generation/world_seed.gd)
- [x] Chunk coordinates + ChunkManager (ACTIVE/WARM/COLD streaming)
- [x] Deterministic RNG helpers (seeded by world_seed + purpose + coords)
- [x] Headless determinism test (--citytest): order independence proven

### Phase B - Macro city (core DONE, polish pending)
- [x] District archetype layer (historic core first; archetypes extensible)
- [x] Jittered hierarchical road grid (major avenues + local streets)
- [x] Urban blocks between streets; building-framed plazas with fountain
      + abandoned market stalls
- [ ] Irregular alleys + passages through blocks (intra-block cuts)

### Phase C - Buildings (visual/structural DONE, interiors Phase D)
- [x] Attached multi-storey perimeter buildings on block edges
      (+ rear wings subdividing large courtyards)
- [x] Stable global building IDs independent of chunk visit order
- [x] Floors, switchback staircases (walkable ramps + treads), roof decks,
      parapets, bulkhead roof exits, balconies, dormers, chimneys,
      pitched roof shells, shopfront signbands
- [x] Buildings spanning chunks stay whole (owned by center chunk)

### Phase D - Interiors & props
- [ ] Semantic building use -> room layouts (residential/retail first)
- [ ] Furniture placement by room semantics + wall alignment (stairs/shaft
      and roof exits already carve real floor plates)
- [x] Exterior props via merged-mesh batches (cars, debris, trash, lamps,
      market stalls, fountains, park trees)
- [ ] Apocalypse decoration pass expanded as an independent generation stage

### Phase E - Traversal
- [ ] Split parkour into actors/traversal/parkour_controller.gd + detector
- [ ] Sprint/jump/vault/mantle/ledge grab/climb-up/drop/fall damage
- [ ] Geometry-query detection (probes), no manual trigger volumes
- [ ] Prove traversal across generated buildings; debug probe visualization
      (roofs/stairs are walkable NOW via ramps; acrobatics comes here)

### Phase F - Persistence
- [x] Persist world seed + generator version in save meta (+ mismatch warning)
- [x] Discovered-chunk records + per-chunk modification deltas (records
      round-trip verified in --citytest)
- [ ] Apply deltas on chunk rebuild; verify returning preserves changes

### Phase G - Optimization (architecture DONE, tuning pending)
- [x] ACTIVE/WARM/COLD state architecture + budgeted load/unload queues
      (~38 ms avg gen/chunk, 25 resident chunks, ~2 nodes each)
- [x] Merged vertex-colored ArrayMesh batches (one mesh + one body per chunk)
- [x] F3 debug section: player chunk, ring counts, box estimates, gen time,
      load/unload counters (--shot prints the same stats)
- [ ] Profile frame time/memory; tune active/warm radii
- [ ] LOD / occlusion passes where measured necessary

### Legacy integration (pending)
- [ ] Move P0 narrative cast INTO generated city (spawn anchors from plan)
- [ ] Retire legacy LevelBuilder test block after actor migration
- [ ] Zombie/survivor AI confined to ACTIVE chunks (COLD = records only)

### Legacy integration (pending)
- [ ] Move P0 narrative cast INTO generated city (spawn anchors from plan)
- [ ] Retire legacy LevelBuilder test block after actor migration
- [ ] Zombie/survivor AI confined to ACTIVE chunks (COLD = records only)

## Prototype 0 - DONE (this codebase)

- [x] Project skeleton, folder structure, input map in code
- [x] Autoload set: EventBus, GameClock, ItemDB, ActorRegistry, WorldState,
      QuestManager, SaveManager, DebugOverlay
- [x] Component system: identity / health(+infection) / needs / inventory /
      interactable
- [x] Survivor body: movement, stamina+exhaustion, melee attack, corpse death
- [x] PlayerController (camera-relative move, interact scan, eat/med keys)
- [x] NPCBrain utility AI: IDLE/WANDER/EAT/SLEEP/FLEE + stuck sidestep
- [x] Zombies: slow wander/chase/investigate(noise)/attack; corpses stay
- [x] Test block: roads, apartment interior, convenience store, crates,
      park, props, streetlamps, boundary
- [x] Follow camera: rotate/zoom, smooth follow, camera-relative input
- [x] Roof hiding when player is inside a building footprint
- [x] Day/night lighting + night lamps
- [x] World events -> WorldState -> quests/dialogue reaction chain
- [x] Quest "Where Is Hana?" incl. pre-met shortcut + independent-death fail
      + grief dialogue branch
- [x] Data-driven-lite dialogue with coded effects
- [x] Save/load: clock, flags, deaths, quest states, survivors, crate stock;
      dead NPCs never respawn; zombies respawn fresh (documented)
- [x] HUD: clock, vitals bars, quest tracker, prompts, banners, death screen
- [x] Debug overlay + hotkeys (F3/F5/F9/T)
- [x] Headless regression harness (--smoke, --soak), all green

## Prototype 0.6 - polish slice (deferred behind P0.5)

- [ ] NavigationServer navmesh baking for real pathing (replace steering)
      + chunk-local navmeshes connected across chunk borders
- [ ] Line-of-sight check for zombie sight (walls currently ignored)
- [ ] Melee visual feedback: swing arc mesh, hit flash, knockback stagger
- [ ] Loot prompts per item choice instead of one-item-per-press
- [ ] Sleep skip: rest until morning (time acceleration while sleeping)
- [ ] Basic sound cues (attack hit, zombie aggro, quest jingle)
- [ ] Corpse persistence visuals after load (spawn a corpse marker)

## Milestone M1 - Survivor depth

- [ ] Skills improving through use (melee/athletics/medicine/scavenging first)
- [ ] Body-part injuries + bleeding + bandage targeting
- [ ] Traits/personality data affecting NPCBrain score weights
- [ ] Relationships & memory records (met X at place Y, witnessed Z)
- [ ] Recruit/command companions (follow, hold, loot) with loyalty checks
- [ ] Firearms prototype (ammo scarcity, noise attraction via EventBus)

## Milestone M2 - World simulation

- [ ] Factions as Resources + relationship matrices
- [ ] Settlements: population, food/water storage, simple jobs queue
- [ ] Autonomous settlement roles (guard/farm/haul/heal) on top of NPCBrain
- [ ] Economy v0: barter prices driven by local scarcity
- [ ] Time-scheduled world events (raids, migrations, weather hooks)

## Milestone M3 - World presentation (post-P0.5 remainder)

- [ ] Interior readability: wall fading by camera sector, not just roofs
- [ ] Darkness affecting perception/stealth/AI vision radii
- [ ] Component-based destruction: doors/windows/barricades expose nav routes
      (P0.5 delivers the city itself; see P0.5 phases above)

## Tech debt / known simplifications (P0)

- Zombie sight ignores walls (SIGHT_RADIUS only).
- Zombies are not saved; they respawn from the manifest on load.
- No LOS/pathfinding: brains steer directly and sidestep when stuck.
- Dialogue trees are GDScript-built dicts, not Resources.
- Interaction scan is a distance check over group nodes (fine for <100 actors).
- No audio, no animations, placeholder boxes everywhere.
