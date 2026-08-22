# Roadmap / TODO

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

## Prototype 0.5 - polish slice (next)

- [ ] NavigationServer navmesh baking for real pathing (replace steering)
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

## Milestone M3 - World generation & presentation

- [ ] Constrained hierarchical city generation:
      districts -> parcels -> building archetypes -> rooms -> furniture ->
      loot tables -> inhabitants
- [ ] Interior readability: wall fading by camera sector, not just roofs
- [ ] Darkness affecting perception/stealth/AI vision radii
- [ ] Component-based destruction: doors/windows/barricades expose nav routes

## Tech debt / known simplifications (P0)

- Zombie sight ignores walls (SIGHT_RADIUS only).
- Zombies are not saved; they respawn from the manifest on load.
- No LOS/pathfinding: brains steer directly and sidestep when stuck.
- Dialogue trees are GDScript-built dicts, not Resources.
- Interaction scan is a distance check over group nodes (fine for <100 actors).
- No audio, no animations, placeholder boxes everywhere.
