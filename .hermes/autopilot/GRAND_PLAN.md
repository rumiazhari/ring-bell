# Ring Bell Grand Plan Charter

## Product command

Build Ring Bell continuously as a coherent, enjoyable game—not as a sequence of isolated technical demonstrations. The architect owns the architecture of the entire project and expands this charter into bounded executable milestones. The builder implements only those designs.

**North-star principle:** maximize sustained player enjoyment while preserving technical integrity and the user's long-term world vision.

## Anchored source plan

The detailed macro-world plan remains at:

`.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md`

SHA-256:

`06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`

The architect may refine sequencing as the real repository evolves, but must not silently replace the source vision. Any deliberate change to a fundamental product assumption must be recorded as an architectural decision with rationale and impact.

## World vision

Ring Bell is a deterministic, geographically coherent Czech-inspired industrial low-fantasy survival world. Prague is the principal urban reference, surrounded by natural and industrial regions. Zombie-controlled streets remain dangerous while meaningful survivor civilization develops vertically across rooftops, bridges, farms, workshops, lifts, ledges, and improvised safe routes.

The player controls one ordinary survivor—not a uniquely important protagonist. Other survivors have their own schedules, needs, work, affiliations, relationships, travel, injuries, and deaths. The world should generate stories through systems, spatial constraints, scarcity, and social behavior rather than only through scripted heroics.

The target architecture keeps the seed-driven, chunk-streamed foundation and places `WorldPlan` above `CityPlan`. Terrain, hydrology, biomes, geology, settlements, roads, underground regions, and vertical survivor networks are stable world-coordinate plans. Chunk builders materialize approved plan data; they do not invent geography independently.

## Enjoyment pillars

The architect evaluates every proposed milestone against these pillars:

1. **Agency and meaningful choice** — the player chooses routes, risks, resources, alliances, work, shelter, and recovery strategies.
2. **Exploration and discovery** — readable landmarks, distinct regions, vertical routes, hidden spaces, environmental stories, and useful reasons to travel.
3. **Survival pressure with recovery** — danger and scarcity create decisions, but failures teach, produce stories, and allow believable recovery rather than arbitrary punishment.
4. **Tactile game feel** — movement, collision, interaction, tools, doors, traversal, combat, sound, camera, and feedback feel legible and satisfying.
5. **Emergent living world** — NPC autonomy, settlement activity, hazards, resource flows, destruction, weather/time, and world events interact deterministically but not identically between seeds.
6. **Progression through capability** — player and community progression unlocks routes, knowledge, infrastructure, safety, production, and social possibilities rather than only larger numbers.
7. **Coherent identity** — Czech/Prague geography, architecture, agriculture, industry, materials, and low-fantasy technology form one readable world.
8. **Performance and stability** — streaming, collision, save/load, generation budgets, and tests protect enjoyment; technical foundations must survive ordinary play.

A milestone that improves no pillar is not authorized. Cosmetic polish may support a playable milestone but may not substitute for one.

## Long-range construction arcs

These arcs express direction, not a fixed task queue. The architect selects the next bounded milestone from actual dependencies and current player value.

### A. Stable playable geography

- world-coordinate terrain with continuous elevation and explicit slope/cliff behavior;
- city basin compatibility and ordinary traversal to surrounding terrain;
- streamed ACTIVE/WARM/COLD ownership with measured collision and frame budgets;
- reliable save/load that stores world deltas, not generated geometry.

### B. Hydrology and regional character

- Vltava-like primary river, tributaries, streams, floodplains, reservoirs/lakes, banks, bridges, docks, and industrial water use;
- geography-constrained routes and settlements;
- deterministic water identity and crossing opportunities.

### C. Biomes, geology, rural and industrial regions

- forests, farms, orchards, meadows, villages, quarries, mines, rail/warehouse corridors, and polluted industrial belts;
- region-specific resources, hazards, travel choices, and visual/material identity;
- modular assets and toon-outline presentation tied to gameplay categories.

### D. Functional buildings and underground space

- realistic building footprints, circulation, stairs, rooms, service spaces, furniture categories, and use programs;
- basements, sewers, caves, mineshafts, service tunnels, collapse/flood zones, and believable entrances;
- interiors and underground routes that affect shelter, work, exploration, and danger.

### E. Vertical survivor civilization

- roof paths, bridges, ladders, lifts, ledges, farms, workshops, dwellings, markets, and social spaces;
- clear transitions between dangerous street level and improvised upper civilization;
- construction, maintenance, access, ownership, safety, and failure as gameplay systems.

### F. Survival, society, and emergence

- needs, injuries, infection/disease where appropriate, resources, crafting/repair, work, schedules, affiliations, relationships, death, and community memory;
- settlements and individuals act without treating the player as the world center;
- systemic events and resource networks create changing opportunities and conflicts.

### G. Presentation and game feel

- readable toon-outline visual language, Czech material palettes, weather/time atmosphere, strong audio feedback, animation, interaction clarity, and accessible UI;
- polish is integrated with the systems it communicates.

## Architect operating rules

For each cycle, the architect must:

1. inspect the actual repository, current Git/worktree state, accepted/deferred work, tests, and player-facing behavior;
2. choose the smallest milestone that delivers meaningful enjoyment or unlocks a necessary near-term enjoyment gain;
3. explain dependencies and why this milestone comes next;
4. produce clear technical construction: interfaces, ownership, data flow, files/systems, phases, budgets, persistence, compatibility, and rollback;
5. define 3–7 acceptance criteria that prove behavior independently rather than through one aggregate/fallback result;
6. name required automated and ordinary player-facing evidence;
7. forbid unrelated scope;
8. hand the finished design to the deterministic controller—never directly to an autonomous builder.

## Continuity and anti-stale rule

After every accepted or principally sound milestone, immediately design the next milestone. Carry minor findings forward into the next related design. Direct revision is reserved for principal design conflicts and is limited to two rounds. If two revisions cannot close the work, stop patching the same implementation and design a fresh recovery milestone that restores forward progress.

Continuous building means continuous architect-led progression, not infinite repair, duplicate tasks, overlapping writers, or lowered quality bars.
