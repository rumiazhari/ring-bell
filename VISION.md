# Ring Bell — Vision

Permanent product charter. Highest-level source of truth. Architect may refine wording when evidence requires clarification, but must NEVER casually change core vision.

## Identity

Ring Bell is a deterministic, geographically coherent Czech-inspired industrial low-fantasy survival world. Prague is the principal urban reference, surrounded by natural and industrial regions. Zombie-controlled streets remain dangerous while meaningful survivor civilization develops vertically across rooftops, bridges, farms, workshops, lifts, ledges, and improvised safe routes.

The player controls one ordinary survivor — not a uniquely important protagonist. Other survivors have their own schedules, needs, work, affiliations, relationships, travel, injuries, and deaths. The world generates stories through systems, spatial constraints, scarcity, and social behavior rather than only scripted heroics.

The world is seed-driven and chunk-streamed. `WorldPlan` sits above `CityPlan`. Terrain, hydrology, biomes, geology, settlements, roads, underground regions, and vertical survivor networks are stable world-coordinate plans. Chunk builders materialize approved plan data; they never invent geography independently.

## World Constraints (non-negotiable)

- **Deterministic, not identical** — same seed+coords → same result regardless of chunk visit order, query order, worker scheduling, save/load. Different seed → materially different world.
- **Geographic logic precedes decoration** — elevation, water, geology, biome, settlement suitability, and transport corridors before buildings, props, NPCs, art.
- **No flat-world shortcut** — every outdoor chunk has sampled terrain with continuous elevation, explicit water surfaces, slopes, banks, cliffs, entrances where appropriate.
- **Czech/Prague reference, not 1:1 map** — fictional but recognizably Bohemian in climate, settlement morphology, architecture, agriculture, forests, river valley, industrial history.
- **Continental basin (Prague-centered)** — one Vltava-like primary river + tributaries, lakes/reservoirs, streams, floodplains, hills, forests, farms, villages, quarries/mines. Sea vocabulary exists in API but no sea in first 16 km continental map.
- **Civilization ≠ ground city** — ground layer dangerous/zombie-dominated; upper layer is living improvised survivor society (bridges, roof farms, workshops, hanging routes, roof shacks, social activity).
- **Player is not protagonist** — one ordinary survivor among autonomous NPCs.
- **Realistic building scale** — footprints support several rooms per floor, circulation, stairs, service spaces, furniture categories, use programs. Facade generator alone insufficient.
- **Assets staged, not postponed indefinitely** — first geography milestone may use proxy meshes, but each subsequent category must have explicit path to textured modular assets + toon-outline presentation.
- **No facade-only milestone** — functional world/gameplay systems over Prague facade ornament.

## Enjoyment Pillars (every milestone must improve ≥1)

1. **Agency and meaningful choice** — routes, risks, resources, alliances, work, shelter, recovery.
2. **Exploration and discovery** — landmarks, distinct regions, vertical routes, hidden spaces, environmental stories, reasons to travel.
3. **Survival pressure with recovery** — danger/scarcity create decisions; failures teach and allow believable recovery, not arbitrary punishment.
4. **Tactile game feel** — movement, collision, interaction, tools, doors, traversal, combat, sound, camera, legible feedback.
5. **Emergent living world** — NPC autonomy, settlement activity, hazards, resource flows, destruction, weather/time, world events interact deterministically but not identically between seeds.
6. **Progression through capability** — unlock routes, knowledge, infrastructure, safety, production, social possibilities (not just larger numbers).
7. **Coherent identity** — Czech geography, architecture, agriculture, industry, materials, low-fantasy tech as one readable world.
8. **Performance and stability** — streaming, collision, save/load, generation budgets, tests protect enjoyment.

A milestone improving no pillar is not authorized. Cosmetic polish may support a playable milestone but may not substitute for one.

## Spatial Contract

- Units meters; X/Z horizontal, Y elevation; Vector2 plan points are world (x,z) never chunk-local.
- **64 m** simulation/render chunk (streaming, physics, batching) — `WorldConstants.CHUNK_SIZE_M`
- **256 m** landscape cell (terrain field lattice) — `WorldConstants.LANDSCAPE_CELL_M`
- **1024 m** macro cell (regional composition) — `WorldConstants.MACRO_CELL_M`
- World origin (0,0) = Prague basin reference; initial bounded world 16 km × 16 km = [-8192, 8192) XZ; outside legal for expansion but not part of initial playable boundary.
- Vertical datums: `terrain_y` sampled [-12, 120], `water_level` -1.2±0.6 along flow axis, `building_ground_y` terrain at footprint, `lower_city_y` -15.0, `upper_civilization_y` 120.0, sky dressing 500.0.

## Architecture Principles

- **Two layers strictly separated:** PLAN (pure, immutable, cheap: WorldPlan/TerrainPlan/HydrologyPlan/... queries) vs MATERIALIZATION (scene nodes: ChunkManager/Builders create meshes/collision). Plans never touch scene tree; chunks never make random choices — all randomness via `WorldSeed.rng` domain-separated.
- **Determinism contract** verified by `--citytest`, `--terrainmaterialtest`, `--hydrotest`, `--biometest`, `--roadtest`, `--ruraltest` etc. Chunk size 64 m, ACTIVE ring chebyshev ≤1, WARM ≤2, COLD >2 with hysteresis UNLOAD=3. ACTIVE-only physics (warm visuals without StaticBody) — 9 city+9 terrain+9 water+9 biome+9 road+9 rural colliders max (54 peak).
- **Save/load** stores world deltas/manifest deltas, never generated geometry. `GENERATOR_VERSION` remains 2 while additive; `WORLD_SCHEMA_VERSION = 1`.

## Long-Range Arcs (direction, not fixed queue)

**A. Stable playable geography** — continuous elevation, slope/cliff, city basin compatibility, streamed ACTIVE/WARM/COLD ownership with measured collision/frame budgets, reliable save/load of world deltas.

**B. Hydrology and regional character** — Vltava-like river + tributaries, floodplains, banks, bridges/docks, deterministic water identity and crossing opportunities, geography-constrained routes/settlements.

**C. Biomes, geology, rural and industrial regions** — forests, farms, orchards, meadows, villages, quarries, mines, rail/warehouse corridors, polluted industrial belts; region-specific resources/hazards/travel and visual/material identity; modular assets + toon-outline presentation tied to categories.

**D. Functional buildings and underground space** — realistic footprints, circulation, stairs, rooms, service spaces, furniture categories, use programs; basements, sewers, caves, mineshafts, service tunnels, collapse/flood zones, believable entrances; interiors/underground affect shelter, work, exploration, danger.

**E. Vertical survivor civilization** — roof paths, bridges, ladders, lifts, ledges, farms, workshops, dwellings, markets, social spaces; clear transition between dangerous street level and improvised upper civilization; construction/maintenance/access/ownership/safety/failure as gameplay.

**F. Survival, society, emergence** — needs, injuries, infection/disease, resources, crafting/repair, work, schedules, affiliations, relationships, death, community memory; settlements/individuals act without treating player as world center; systemic events/resource networks create changing opportunities/conflicts.

**G. Presentation and game feel** — readable toon-outline visual language, Czech material palettes, weather/time atmosphere, strong audio feedback, animation, interaction clarity, accessible UI; polish integrated with systems it communicates.

## Technical Ambitions

- Seed-driven deterministic generation with domain-separated RNG (`terrain`, `ridge`, `valley`, `hydro_*`, `biome_*`, `geology_*`, `settlement_*`, `road_*`, `rural_*` etc.)
- Chunk builders materialize plan data with budgeted geometry: terrain 17×17 (289 verts/512 tris), water/biome 9×9 (81/128), road ribbon ≤96/64 typical, rural shells ≤480/360 dense, all ACTIVE-only physics, 1 collider/chunk, `FRAME_BUDGET_MS 12`
- Headless validation harness with `finished with 0 failure(s)` marker; Windows exit 3221225477 with marker is pass; `tools/run_suite.py` wrappers with timeouts (400s for city/road/rural)
- Streaming pacing `MAX_MATERIALIZATIONS_PER_FRAME 1` with early `_collect_finished_jobs(pc)` + freed-Zombie guard

## What "Done" Looks Like

Ring Bell succeeds when a new seed delivers a fresh but coherent Czech basin: you spawn in a Prague-like urban basin, traverse real terrain/hydrology to enter contiguous rural belts (fields → hedgerows → villages → forests → quarry uplands), cross water only at bridges/fords, navigate buildings with correct circulation/doors/stairs, find working rural interiors (partitions, furniture, hearths, wells, forage, workbenches, granaries) tied to harvest/craft loops, and experience tactile traversal (sprint/jump/vault/mantle/crouch/slide/wall-run/shimmy) with responsive camera — all streamed deterministically, performant, and persistently saved.

Source anchor: `.hermes/plans/2026-08-27_224936-ring-bell-macro-world-plan.md` SHA `06bf72c031b2bbf94bc162825388711e4c3f47e0b55a7f78a5dcd76072bfbca8`
