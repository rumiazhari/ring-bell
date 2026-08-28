# Ring Bell Macro-Scale Procedural World Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Evolve Ring Bell from a flat, city-only procedural prototype into a deterministic, geographically coherent Czech-inspired industrial low-fantasy world where Prague is the principal urban reference, natural regions surround the city, and the meaningful survivor civilization occupies an elevated layer above zombie-controlled streets.

**Architecture:** Keep the existing deterministic, seed-driven, chunk-streamed architecture, but introduce a world-plan layer above `CityPlan`. `WorldPlan` will derive terrain, hydrology, biomes, geology, settlements, roads, caves, and vertical survivor networks from stable world coordinates; chunk builders will only materialize data returned by that plan. The current city generator becomes the urban implementation for the Prague metropolitan region rather than the definition of the entire world.

**Tech Stack:** Godot 4.7.x, GDScript, `WorldSeed` domain-separated deterministic RNG/hash functions, `ChunkManager` streaming, batched `ArrayMesh` geometry during prototyping, imported GLB/glTF modular assets, `ShaderMaterial`/spatial shaders for toon-outline shading, JSON save deltas, and the existing headless Godot test harness.

---

## 1. Current context and non-negotiable constraints

### Current repository state

The current project is at `C:/Vibe Code project/Godot Project/ring-bell`.

The existing architecture provides:

- `WorldSeed` with deterministic seed/hash/RNG helpers.
- A 64 m streamed chunk grid in `world/streaming/chunk_manager.gd`.
- `CityPlan` in `world/generation/city_plan.gd`, currently based on a flat XZ plane and a deterministic urban road/block/building hierarchy.
- `ChunkBuilder` in `world/streaming/chunk_builder.gd`, which currently emits flat ground, roads, blocks, parks, props, and buildings.
- `BuildingBuilder` in `world/generation/building_builder.gd`, which currently emits mostly placeholder box geometry with Prague-inspired facade dressing.
- `InteriorPlan` in `world/generation/interior_plan.gd`, already moving toward semantic rooms but limited to residential/retail programs.
- A legacy hand-built test block still used by older smoke/soak tests.
- Current Ring Bell control state paused on `P1-INTERIORS-TRAVERSAL`; the repository rules prohibit beginning a new architectural milestone without an explicit Luna/specification transition.

At planning time, the checkout also has existing uncommitted changes in `debug/city_runtime_test.gd` and `world/generation/building_builder.gd`. These must be preserved and reviewed before implementation; no macro-world work should overwrite or silently absorb them.

### Design constraints

1. **Deterministic does not mean identical.** A seed generates one stable world. A different seed generates a different world. Loading, chunk visit order, save/load, and worker scheduling must not alter the result.
2. **Geographic logic precedes decoration.** Elevation, water, geology, biome, settlement suitability, and transport corridors must be established before buildings, props, NPCs, and art dressing.
3. **No flat-world shortcut.** Every outdoor chunk must have a sampled terrain surface with continuous elevation, explicit water surfaces, slopes, banks, cliffs, and underground entrances where appropriate.
4. **Czech/Prague is the main reference, not a literal 1:1 map.** The first world should be fictional but recognizably Bohemian/Czech in climate, settlement morphology, architecture, agriculture, forests, river valley, and industrial history.
5. **The main Prague region is continental.** It should contain a Vltava-like river, tributaries, lakes/reservoirs, streams, floodplains, hills, forests, farms, villages, and quarries/mines. A true sea is not geographically appropriate to a Prague-centered Czech setting. The plan therefore defines a coast-capable world API but postpones a sea coastline to a later outer-region expansion unless the design is intentionally changed to a fictional coastal Czech basin.
6. **Civilization is not synonymous with the ground city.** The ground layer is dangerous and zombie-dominated; the upper layer is a living, improvised survivor society with bridges, roof farms, workshops, hanging routes, roof shacks, and social activity.
7. **The player is not the protagonist.** The player controls one ordinary survivor. NPCs have their own schedules, needs, affiliations, work, travel, deaths, and relationships. Existing narrative systems must not assume that the player is uniquely important.
8. **Realistic building scale is required.** A building footprint must support several rooms per floor, circulation, stairs, service spaces, furniture categories, and different building-use programs. A facade generator alone is insufficient.
9. **Assets are staged, not postponed indefinitely.** The first geography milestone may use simple terrain/road proxy meshes for correctness, but each subsequent region/building category must have an explicit path to textured modular models and the toon-outline presentation.
10. **Do not add another facade-only milestone.** The current project rules explicitly prioritize functional world/gameplay systems over more Prague facade ornament.

---

## 2. Target world model

### 2.1 Spatial scales

Use three related spatial scales while retaining the existing 64 m streaming unit:

- **64 m simulation/render chunk:** existing `WorldSeed.CHUNK_SIZE`; owns geometry, collision, dynamic entities, and persistence deltas.
- **256 m landscape cell:** four-by-four chunk neighborhood used for terrain classification, hydrology continuity, vegetation density, road hierarchy, and local geology. It avoids making every 64 m chunk independently decide its biome.
- **1,024 m macro cell:** used for regional composition, settlement hierarchy, major rivers, mountain/ridge systems, forest belts, agricultural belts, industrial corridors, and cave/mineshaft districts.

Initial playable target:

- A finite first world of approximately **16 km x 16 km** centered on a Prague-inspired city basin, represented as a 256 x 256 grid of 64 m chunks.
- A procedurally extensible coordinate system outside the initial boundary so the architecture does not need to be replaced for future expansion.
- A first playable slice containing the city core, river corridor, one industrial belt, one rural/farm belt, one village cluster, one forested upland, one quarry/cave district, and at least one lake/reservoir.

The exact boundary should be data-driven in `WorldPlan`, not encoded in individual builders. The initial map may use a soft world edge or impassable boundary, but edge behavior must be deterministic and clearly represented to save/load.

### 2.2 World vertical layers

Define an explicit vertical coordinate contract:

- `terrain_y(x,z)`: outdoor ground elevation in meters.
- `water_level`: regional or basin-level reference height, with local reservoir levels represented by water bodies.
- `building_ground_y`: terrain height at the building footprint; building floors are relative to this datum.
- `lower_city_y`: streets, basements, sewers, mines, caves, and underground service routes.
- `upper_civilization_y`: bridges, rooftop farms, roof dwellings, ledges, workshops, and survivor routes.
- `sky/roof dressing`: visual layer only; never substitute visual meshes for collision-backed traversal.

Outdoor terrain should support an approximate playable slope limit, with cliffs and impassable faces represented explicitly. Building footprints must conform to terrain terraces or use retaining walls/foundations; buildings must not float or be silently buried in hills.

### 2.3 Czech-inspired geographic composition

Use a generated macro composition with deterministic anchor regions around the Prague reference city:

- **Prague historic/urban basin:** city center near world origin; dense historic core, civic districts, dense worker housing, industrial outskirts, rail/warehouse corridors, parks, cemeteries, and bridges.
- **Vltava-like river:** broad north/south-flowing valley through or beside the city, with floodplain, embankments, docks, bridges, mills, factories, and elevated neighborhoods overlooking it.
- **Tributaries and streams:** smaller streams converge toward the primary river, creating logical valleys rather than random blue lines.
- **Rolling Bohemian hills:** moderate elevation around the basin; terrain suitable for villages, orchards, roads, quarries, and lookout points.
- **Forest uplands:** larger contiguous forest regions on ridges and steep, less fertile terrain; include logging tracks, charcoal burners, hunting cabins, shrines, and caves.
- **Agricultural belt:** fields, meadows, hedgerows, farm roads, barns, mills, wells, orchards, and compact villages outside the city.
- **Industrial corridor:** rail and river-adjacent factories, foundries, gasworks, machine shops, warehouses, workers' rows, slag heaps, and contaminated ground; this is the main steampunk-industrial expression.
- **Lake/reservoir/quarry water:** one or more inland water bodies formed by terrain/geology rules, not arbitrary decoration.
- **Quarry/mineshaft/cavern districts:** limestone/sandstone/coal/iron-bearing regions selected by geology; surface quarries and underground networks should have plausible entrances, support structures, ventilation, and flooded sections.
- **Sea API:** `WorldPlan` must model `water_body_kind = sea|lake|river|reservoir` so a later coastal region is possible, but no sea is placed in the first Prague-centered continental map without a deliberate setting decision.

---

## 3. Proposed code architecture

### New plan-layer scripts

Create these as pure data/query modules under `world/generation/`:

- `world_plan.gd` — top-level facade that owns or composes the terrain, water, biome, settlement, road, geology, cave, and vertical-network plans. It exposes stable queries used by chunk builders.
- `terrain_plan.gd` — continuous heightfield, slope, normal, terrace, cliff, and terrain-material classification queries.
- `hydrology_plan.gd` — primary river, tributaries, lakes/reservoirs, floodplain, banks, water depth, flow direction, and bridge-crossing constraints.
- `biome_plan.gd` — temperature/moisture/elevation/soil/geology-derived biome classification and density parameters for Czech vegetation and agriculture.
- `geology_plan.gd` — rock strata, ore/mineral regions, quarry suitability, cave potential, mine district metadata, and underground material palettes.
- `settlement_plan.gd` — city, town, village, hamlet, farmstead, industrial estate, mill, station, and roadside-service anchors based on terrain/water/road suitability.
- `road_network_plan.gd` — hierarchical roads and paths connecting settlements, bridges, rail corridors, farms, quarries, forests, and city districts.
- `cave_plan.gd` — deterministic cave/cavern/mineshaft graph metadata, entrances, shafts, chambers, tunnels, collapse zones, and water connections.
- `vertical_network_plan.gd` — upper-city survivor anchors and links: roof routes, bridges, ledges, roof shacks, farms, lifts, ladders, stair towers, and safe/unsafe transitions.
- `building_program_plan.gd` — building-use programs and room/furniture requirements for urban, village, farm, industrial, civic, religious, rail, and underground structures.
- `world_constants.gd` — documented unit scales, region radii, world boundary, water/terrain tolerances, and generation version aliases.

### New materialization/build scripts

- `world/streaming/terrain_chunk_builder.gd` — terrain mesh, terrain collision, slope transitions, terraces, cliffs, and terrain material IDs.
- `world/streaming/water_chunk_builder.gd` — river/lake/reservoir surfaces, banks, shallow/deep zones, bridges, docks, and water collision/query surfaces.
- `world/streaming/biome_chunk_builder.gd` — forest, hedgerow, field, meadow, orchard, and rural prop placement using biome density data.
- `world/streaming/road_chunk_builder.gd` — hierarchical road/rail/path materialization and bridge approaches.
- `world/streaming/underground_chunk_builder.gd` — cave, cavern, mine, sewer, and basement geometry; only materializes when the relevant underground volume is active or discovered.
- `world/streaming/vertical_network_builder.gd` — survivor bridges, rooftop routes, roof farms, lifts, scaffolds, and upper-city collision/visual layers.

### New asset/rendering scripts and resources

- `art/asset_catalog.gd` — metadata registry for imported modular assets, category, scale, collision policy, material family, LOD, and biome/building compatibility.
- `art/procedural_kit_catalog.gd` — deterministic selection of walls, roofs, windows, doors, furniture, farm parts, bridge parts, industrial machinery, and rural props.
- `art/material_palette.gd` — shared palette families for Czech plaster, brick, limestone, timber, oxidized steel, copper, glass, roof tile, soil, vegetation, and water.
- `art/toon_outline.gdshader` — outline/ink treatment suitable for the intended cartoonish presentation; must support depth-aware, thickness-limited outlines and avoid outlining every tiny prop indiscriminately.
- `art/toon_surface.gdshader` — stepped or banded diffuse response with controlled shadow tint, warm industrial highlights, and optional hand-painted variation.
- `art/render_style_config.gd` or a `.tres` equivalent — style toggles, outline width, shadow bands, color grading, fog, and distance fade.

### Existing files to extend, not replace

- `world/generation/world_seed.gd`: add generator-version domains and stable coordinate noise helpers; preserve existing API compatibility.
- `world/generation/city_plan.gd`: make city behavior one region/district implementation consumed by `WorldPlan`; preserve deterministic building IDs.
- `world/streaming/chunk_manager.gd`: stream terrain/water/biome/roads/underground/vertical layers while keeping ownership and hysteresis rules.
- `world/streaming/chunk_builder.gd`: become a coordinator or delegate to specialized builders; do not retain a single giant builder.
- `world/generation/building_builder.gd`: consume elevation, building programs, real asset-kit metadata, and upper-city attachments; retain static collision ownership.
- `world/generation/interior_plan.gd`: expand beyond the current residential/retail prototype only after macro-world interfaces are stable.
- `world/main.gd`: instantiate `WorldPlan`, pass it to `ChunkManager`, and choose legacy mode only for the explicit legacy test flags.
- `core/autoload/save_manager.gd`: persist world seed/version plus terrain, water, building, underground, and vertical-network deltas.
- `core/autoload/world_state.gd`: store persistent facts about discovered regions, settlement changes, deaths, ownership, and world events—not generated geometry.

Do not edit current uncommitted files until they are inspected and assigned to a specific task.

---

## 4. Implementation sequence

The sequence is intentionally macro-first. Each task should remain small enough for a focused implementation/review cycle; do not let art polish or interior detail block geographic correctness.

### Phase 0: Architecture freeze and measurement

#### Task 0.1: Capture the current baseline

- Read `AGENTS.md`, `AUTOPILOT_POLICY.md`, `AUTOPILOT_STATE.json`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, and `TODO.md`.
- Inspect and classify current changes in `debug/city_runtime_test.gd` and `world/generation/building_builder.gd`.
- Run only the existing read/validation baseline required by the active specification; do not modify the project or dispatch a new worker while the pilot is paused.
- Record existing generation timings, chunk box/collider counts, and current citytest behavior in a new review/control artifact only after the milestone is formally reauthorized.

#### Task 0.2: Write the world contract

Create `docs/world/WORLD-CONTRACT.md` defining:

- Coordinate axes and meters-to-world units.
- 64 m chunk, 256 m landscape cell, and 1,024 m macro cell.
- World boundary and origin meaning.
- Elevation/water/building/upper-city vertical layers.
- Stable ID rules and generator-version rules.
- Which queries must be pure and which nodes may be materialized.
- The continental Prague-first decision about sea placement.

#### Task 0.3: Add world-level acceptance gates

Extend the test runner and test documentation with future flags such as:

- `--worldtest`: seed/order/coordinate determinism.
- `--terraintest`: continuity, slope, material, and boundary checks.
- `--hydrotest`: river/lake/floodplain/flow checks.
- `--settlementtest`: suitability and road-network checks.
- `--undergroundtest`: cave/mineshaft graph validity.
- `--verticaltest`: upper-city link connectivity and collision checks.
- `--arttest`: asset metadata, scale, missing-resource, and material validation.

The existing `citytest`, `smoke`, `cityruntime`, `havoctest`, and `walkthrough` gates remain mandatory.

### Phase 1: Deterministic terrain foundation

#### Task 1.1: Extend deterministic coordinate noise

Modify `world/generation/world_seed.gd` additively:

- Add named domains for `terrain`, `ridge`, `valley`, `soil`, `moisture`, `temperature`, `geology`, and `settlement`.
- Implement stateless lattice/value or gradient noise helpers whose result depends only on seed, domain, integer lattice coordinates, and interpolation position.
- Never share mutable `RandomNumberGenerator` instances across unrelated systems.
- Add tests proving chunk order and query order do not change samples.

#### Task 1.2: Implement `TerrainPlan`

Create `world/generation/terrain_plan.gd` with pure queries:

- `height_at(Vector2) -> float`.
- `slope_at(Vector2) -> float`.
- `normal_at(Vector2) -> Vector3`.
- `terrain_class_at(Vector2) -> StringName`.
- `surface_material_at(Vector2) -> StringName`.
- `is_buildable(Vector2, footprint, constraints) -> bool`.
- `terrain_profile(Rect2, sample_step) -> PackedFloat32Array`.

Use layered deterministic fields rather than a single noisy surface:

1. Low-frequency basin/ridge field.
2. Valley depression aligned with hydrology anchors.
3. Medium-frequency rolling hills.
4. Small-frequency surface variation.
5. Explicit flattening/terracing near settlement anchors, roads, farms, and water banks.
6. Explicit cliff/rock masks for quarry and cave regions.

The plan must guarantee continuity at chunk boundaries by sampling world coordinates, never chunk-local random offsets.

#### Task 1.3: Materialize terrain chunks

Create `world/streaming/terrain_chunk_builder.gd` and integrate it through `chunk_builder.gd`:

- Build a grid mesh per 64 m chunk with shared-coordinate edge samples.
- Use a resolution that supports visible hills without exceeding collision budgets; begin with 17x17 vertices and measure before increasing.
- Generate a simplified collision mesh or heightfield-friendly collision representation rather than one collider per visual cell.
- Assign material IDs by `TerrainPlan.surface_material_at`, with blended visual materials where appropriate.
- Add cliff and retaining-wall proxy geometry only where required by the plan.
- Add debug mode showing chunk borders, sampled heights, slope, and terrain class.

### Phase 2: Hydrology and geographic constraints

#### Task 2.1: Define hydrology anchors and flow

Create `world/generation/hydrology_plan.gd`:

- Define a deterministic primary river corridor passing through the Prague basin.
- Generate tributary catchments that descend toward the primary river.
- Derive a monotonic flow direction from terrain plus corridor bias; prevent uphill river segments.
- Generate lakes/reservoirs where basin, geology, and dam/quarry conditions permit.
- Define river width, depth, banks, floodplain, marsh, ford, bridge, dock, and waterfall metadata.
- Expose `water_body_at`, `water_level_at`, `distance_to_water`, `flow_direction_at`, and `crossing_candidates`.

Do not draw water as random strips. Water bodies must have a source/basin/flow identity and stable IDs.

#### Task 2.2: Materialize water and banks

Create `world/streaming/water_chunk_builder.gd`:

- Generate water surfaces clipped to the current chunk.
- Generate shallow banks and floodplain materials.
- Ensure water surface and terrain intersection has no visible cracks at chunk seams.
- Add collision/query surfaces according to gameplay needs; do not make every water visual triangle a physics body.
- Add bridges, docks, levees, mills, sluice gates, and ferries only from hydrology/settlement/road manifests.
- Add water debug output for body ID, flow direction, depth, and crossing type.

#### Task 2.3: Add hydrology tests

In `debug/world_test.gd` or a dedicated `debug/hydrology_test.gd`, assert:

- Rivers are continuous across chunk boundaries.
- Tributaries approach their parent river.
- Water is not generated on top of arbitrary ridges unless represented as a lake/reservoir.
- Settlements avoid flood-risk zones unless their manifest explicitly requests a river-port, mill, dock, or stilt/flood-adapted site.
- Bridges intersect both valid banks and connect the road graph.

### Phase 3: Biomes, geology, and natural regions

#### Task 3.1: Implement Czech-inspired biome classification

Create `world/generation/biome_plan.gd` using terrain, moisture, temperature, elevation, soil, hydrology, and geology fields. Initial biome classes:

- `urban_basin`.
- `industrial_corridor`.
- `river_floodplain`.
- `wet_meadow`.
- `arable_field`.
- `orchard`.
- `pasture`.
- `deciduous_forest`.
- `mixed_upland_forest`.
- `rocky_quarry`.
- `marsh/lake_margin`.
- `village_edge`.
- `roadside/rail_corridor`.

Define density and allowed-prop rules per biome. A forest is a contiguous region with edge transitions, not a random tree count in isolated chunks.

#### Task 3.2: Implement geology

Create `world/generation/geology_plan.gd`:

- Classify bedrock/soil bands suitable for Bohemian limestone, sandstone, clay, granite-like uplands, coal/iron industrial deposits, and alluvial river soil.
- Produce deterministic quarry, mine, cavern, and cave potential masks.
- Store explicit geological region IDs so underground networks can be generated from a region, not from isolated random holes.
- Expose buildability, excavation, ore, and cave queries.

#### Task 3.3: Materialize biome vegetation and agriculture

Create `world/streaming/biome_chunk_builder.gd`:

- Place trees using stable macro/biome anchors and deterministic per-instance IDs.
- Generate fields as contiguous parcels aligned to farm roads and terrain contours.
- Generate hedgerows, drainage ditches, orchards, meadows, fences, barns, hay stacks, wells, and woodland clearings from semantic manifests.
- Keep visual vegetation instanced/batched and collision sparse.
- Reserve real collision for fences, walls, trunks, cliffs, and gameplay-critical obstacles.

#### Task 3.4: Add biome/geology validation

Assert that:

- Forests occupy contiguous suitable uplands and do not appear as isolated noise specks.
- Fields follow slopes below an allowed grade or use terraces.
- Farms are not placed in deep water, on cliffs, or inside primary roads.
- Quarries/mines occur only in compatible geological regions.
- Biome transitions are deterministic and visually continuous at chunk borders.

### Phase 4: Settlements, roads, rail, and city placement

#### Task 4.1: Implement settlement suitability

Create `world/generation/settlement_plan.gd`:

- Score sites based on slope, flood risk, water access, soil, trade routes, defensibility, existing settlement spacing, and industrial resources.
- Place a primary Prague-inspired city at/near the basin origin.
- Place secondary towns along river/rail/road intersections.
- Place villages near farm belts, mills, forest edges, and old roads.
- Place hamlets/farmsteads as small clusters, not generic single cubes.
- Allocate city districts: historic core, civic center, worker housing, industrial, rail/warehouse, market, cemetery, park, floodplain, and elevated/upper-city zones.

The settlement manifest must include a stable `settlement_id`, type, center, bounds, elevation strategy, population capacity, economic role, and allowed building programs.

#### Task 4.2: Implement hierarchical transport

Create `world/generation/road_network_plan.gd`:

- Build a graph with national/long-distance roads, city avenues, town roads, village roads, farm tracks, forest tracks, rail, and footpaths.
- Route major paths around steep terrain and through logical passes.
- Add bridges where graph connectivity requires crossing the river/lakes.
- Align industrial development with rail and river freight where plausible.
- Use existing `CityPlan` road logic only inside the city district, but have city gates connect to the external graph.
- Include road surface, width, material, traffic role, and traversal restrictions in manifests.

#### Task 4.3: Refactor `CityPlan` into a district provider

Modify `world/generation/city_plan.gd` so it receives a city-region context from `WorldPlan`:

- Preserve stable building IDs for the existing city seed where possible.
- Add district-level inputs for terrain elevation, street grade, industrial/worker/market zones, river adjacency, and upper-city density.
- Do not allow city blocks to be generated over water, cliffs, or invalid terrain.
- Add city boundary/gate interfaces to external roads and settlements.

#### Task 4.4: Materialize roads and rail

Create `world/streaming/road_chunk_builder.gd`:

- Use terrain-conforming road ribbons/meshes, embankments, cuts, retaining walls, sleepers, rails, crossings, and bridges.
- Keep collision strips coarse and budgeted.
- Ensure road elevation samples are continuous across chunks.
- Add industrial road wear, mud, cobbles, rail soot, and floodplain degradation through material IDs rather than random color noise.

### Phase 5: Caves, caverns, mineshafts, and underground city

#### Task 5.1: Generate underground graphs

Create `world/generation/cave_plan.gd`:

- Generate a stable graph per geological district: entrance, shaft, corridor, chamber, branch, collapse, flooded section, mine stop, and exit.
- Use graph generation plus constrained geometry, not unrestricted voxel noise.
- Give each node/edge a stable ID and depth range.
- Connect surface entrances to quarries, forests, villages, industrial sites, river banks, and city basements where logically appropriate.
- Support mines for clay, limestone, coal, iron, and stone with period-appropriate infrastructure.

#### Task 5.2: Materialize underground chunks

Create `world/streaming/underground_chunk_builder.gd`:

- Materialize only discovered/nearby underground volumes.
- Use modular tunnel/cavern meshes with collision, not thousands of independent box colliders.
- Add supports, rails, carts, ladders, pumps, water seepage, collapse debris, lamps, and loot/work stations from manifests.
- Define safe navigation links between surface, lower city, basements, caves, and mines.

#### Task 5.3: Test underground consistency

Assert:

- Every exposed entrance connects to at least one valid underground node.
- No generated tunnel ends outside its owning geology/volume bounds unless explicitly marked collapsed.
- Flooded sections correspond to hydrology or groundwater metadata.
- Underground IDs and states survive unload/reload/save/load.
- Physics/collider counts remain within measured budgets.

### Phase 6: Upper-level survivor civilization and zombie ground layer

#### Task 6.1: Define the two-layer city simulation

Create `docs/world/UPPER-CITY-DESIGN.md` and corresponding data contracts:

- Ground layer: streets, plazas, basements, sewers, lower entrances, abandoned shops, wrecks, and zombie lanes/hordes.
- Upper layer: occupied floors, roofs, bridges, roof farms, workshops, water tanks, lifts, ladders, ledges, roof shacks, watch posts, and social spaces.
- Transition layer: stairwells, internal doors, balconies, scaffold paths, lifts, broken staircases, controlled gates, and dangerous climbs.

A building must be able to have a different ground state and upper state. A zombie presence on the street does not imply that the upper floors are dead.

#### Task 6.2: Generate the vertical survivor network

Implement `world/generation/vertical_network_plan.gd`:

- Select occupied building floors based on structural condition, floor area, access, water, food, defensibility, and adjacency to other occupied buildings.
- Connect nearby roofs/floors with bridges, planks, pipes, scaffold walks, ladders, and improvised lifts.
- Generate roof farms, rainwater collection, workshops, sleeping rooms, markets, communal kitchens, and guard/lookout points.
- Allow gaps, collapsed routes, locked gates, unsafe ledges, and one-way transitions.
- Assign route safety, ownership/faction, capacity, and maintenance requirements.
- Use stable link IDs so route destruction and repairs persist.

#### Task 6.3: Split population and zombie spawning by layer

Extend `world/city_spawner.gd`, `world/population.gd`, and zombie spawning:

- Spawn survivors from settlement/upper-network manifests, not only the old fixed cast.
- Spawn zombies from ground walkability, noise/food/event rules, and horde corridors.
- Keep zombie simulation confined to active chunks and record only persistent facts for cold chunks.
- Add survivor occupations: farmer, scavenger, mechanic, trader, guard, medic, cook, builder, miner, and courier.
- Make NPC schedules and decisions autonomous; do not encode the player as a unique world role.
- Preserve existing narrative compatibility while moving the old named cast into generated city anchors in a later integration task.

#### Task 6.4: Add ordinary-survivor player contract

Modify player-facing systems so:

- The player is one survivor with ordinary starting skills, needs, inventory, and social standing.
- NPCs can ignore, help, trade with, recruit, distrust, injure, or outlive the player.
- Other NPCs can complete or fail local tasks without the player.
- Death and world changes continue when the player is elsewhere, subject to simulation policy.
- Quests are local/world-state events, not proof that the player is the chosen protagonist.

### Phase 7: Realistic building programs, interiors, and assets

This phase begins only after the terrain/settlement/vertical-network contracts are stable.

#### Task 7.1: Expand building programs

Extend `world/generation/building_program_plan.gd` and `world/generation/interior_plan.gd` with program templates:

- Prague historic apartment/tenement.
- Worker row house.
- Townhouse/corner house.
- Village cottage and farmhouse.
- Barn, stable, granary, mill, and workshop.
- Factory, foundry, machine shop, boiler room, gasworks, and warehouse.
- Station, depot, post office, school, clinic, tavern, church, bathhouse, and civic hall.
- Shop, market hall, apothecary, butcher, baker, and general store.
- Mine office, hoist house, barracks, and underground station.

Each program must specify room graph, min/max room sizes, service rooms, circulation, stair/lift requirements, door semantics, furniture categories, upper-city suitability, and ground/upper access.

#### Task 7.2: Make interiors geometry-real

- Use collision-backed partitions and doors.
- Place furniture against walls or semantic anchors.
- Preserve room connectivity and valid floor area.
- Avoid placing furniture in stair shafts, door swings, or upper-city route corridors.
- Keep bed, workbench, cooking, storage, water, farming, and trade stations usable.
- Persist changes and consumption through `WorldState`/`SaveManager` deltas.

#### Task 7.3: Introduce modular proper models/textures

Create an importable asset workflow:

- Store source/imported model assets under a documented `art/` or `assets/` hierarchy.
- Use GLB/glTF modular pieces with real-world scale metadata.
- Define collision policy per asset: static, simplified convex, capsule, no collision, or gameplay-specific.
- Add texture sets for plaster, brick, stone, timber, tile, rusted steel, copper, glass, soil, crop, moss, and water.
- Add validation for missing textures, incorrect scale, missing LOD/collision metadata, and invalid material assignments.
- Keep procedural placement in GDScript but use authored models for hero structures, major landmarks, machinery, bridges, furniture families, and repeated modular kits.

#### Task 7.4: Implement the intended visual style

- Add `art/toon_surface.gdshader` for controlled banded lighting and painterly palette response.
- Add `art/toon_outline.gdshader` or a depth/normal outline pass for cartoonish ink edges.
- Use outline width based on screen/depth distance and category so interiors and dense vegetation do not become noisy.
- Add a restrained Borderlands/Telltale-inspired color grade: warm desaturated materials, strong silhouettes, selective saturated props, readable shadow masses, and grime/decay accents.
- Add period-correct industrial visual motifs: riveted steel, belts, boilers, pipes, gas lamps, telegraph wires, rail infrastructure, tiled roofs, plaster, brick, timber, cobbles, and painted signage.
- Validate performance on active/warm rings before enabling outlines on every object.

### Phase 8: Persistence, migration, and performance

#### Task 8.1: Version the world generator

Modify `WorldSeed.GENERATOR_VERSION` only with a migration note. Save metadata must include:

- Seed.
- Generator version.
- World schema version.
- Initial world boundary/configuration.
- Discovered landscape cells/chunks.
- Discovered settlements, caves, and underground nodes.
- Persistent deltas for terrain, water structures, buildings, doors, stations, vertical links, farms, and resource depletion.

Generated baseline geometry must not be serialized.

#### Task 8.2: Apply deltas on first materialization

Ensure all chunk layers consume deltas before the first scene materialization, matching the existing persistence-first approach in `ChunkManager`. Verify that destroyed bridges, opened/closed doors, harvested crops, mined resources, repaired routes, and occupied/unoccupied upper-city nodes survive unload/reload and save/load.

#### Task 8.3: Measure budgets

Add debug metrics for:

- Terrain vertices/triangles/colliders per chunk.
- Water surface and bank counts.
- Road/rail geometry and collision counts.
- Vegetation instances and visible collision count.
- Underground nodes/triangles/colliders.
- Upper-city links and dynamic entities.
- Materialization milliseconds and worker generation milliseconds.
- GPU draw calls/material count/outline cost.
- Active/warm memory and streaming latency.

Use measurements to choose terrain resolution, LOD radii, instance batching, collision simplification, and outline scope. Do not increase geometry density speculatively.

### Phase 9: Integration and acceptance

#### Task 9.1: Add world overview/debug tools

Extend debug tools to show:

- Current terrain class, biome, geology, water body, settlement, and district.
- Height/slope/flow vectors.
- City/road/rail/bridge graph overlays.
- Cave/mineshaft entrances and depth.
- Upper-city route graph and occupied floors.
- Zombie ground density and survivor upper-layer population.
- Seed, generator version, active/warm/cold chunk counts, and per-layer timings.

#### Task 9.2: Build deterministic world test matrix

Run a matrix over at least the canonical seed, two alternate seeds, negative coordinates, chunk-border positions, city edge, river edge, forest edge, farm edge, quarry edge, and underground entrances. Compare:

- Plan hashes.
- Terrain samples and profiles.
- Water-body manifests.
- Biome/settlement/road/cave/vertical-network IDs.
- Chunk manifests and collision manifests.

#### Task 9.3: Run full regression gates

Use the repository harness commands:

```text
python tools/run_suite.py --citytest 120
python tools/run_suite.py --smoke 120
python tools/run_suite.py --cityruntime 180
python tools/run_suite.py --havoctest 180
python tools/run_suite.py --walkthrough 240
```

Add and run the new macro-world suites when implemented. Judge success by explicit `finished with 0 failure(s)`, not merely process exit status. A Windows shutdown code is acceptable only when the zero-failure marker is present, per the repository rules.

#### Task 9.4: Manual acceptance walkthrough

A successful macro-world prototype must demonstrate, without teleport cheats:

1. Starting in or near the Prague-inspired city.
2. Walking from a ground street into an interior.
3. Reaching an upper survivor route.
4. Crossing a bridge between buildings.
5. Seeing roof farming and upper-level civilian activity.
6. Returning to a zombie-populated lower street.
7. Following a road toward a river, bridge, village, farm, or forest.
8. Entering a quarry/cave/mineshaft route.
9. Observing terrain, water, and biome continuity across streamed chunk boundaries.
10. Saving, unloading/reloading, and confirming world modifications persist.

---

## 5. Likely files to change

### Documentation/specification

- `docs/world/WORLD-CONTRACT.md` — new.
- `docs/world/UPPER-CITY-DESIGN.md` — new.
- `docs/world/GEOGRAPHY-BIOMES.md` — new.
- `docs/world/BUILDING-PROGRAMS.md` — new.
- `ARCHITECTURE.md` — update after interfaces are implemented.
- `TODO.md` — replace the city-only priority with approved macro-world phases only after control-plane authorization.
- `AUTOPILOT_STATE.json` and `.hermes/autopilot/specs/` — update only through the Luna-controlled workflow, not as an implementation shortcut.

### Generation

- `world/generation/world_seed.gd` — modify.
- `world/generation/world_constants.gd` — new.
- `world/generation/world_plan.gd` — new.
- `world/generation/terrain_plan.gd` — new.
- `world/generation/hydrology_plan.gd` — new.
- `world/generation/biome_plan.gd` — new.
- `world/generation/geology_plan.gd` — new.
- `world/generation/settlement_plan.gd` — new.
- `world/generation/road_network_plan.gd` — new.
- `world/generation/cave_plan.gd` — new.
- `world/generation/vertical_network_plan.gd` — new.
- `world/generation/building_program_plan.gd` — new.
- `world/generation/city_plan.gd` — modify as a city-region provider.
- `world/generation/building_builder.gd` — modify after macro contracts stabilize.
- `world/generation/interior_plan.gd` — extend in the building-program phase.

### Streaming/materialization

- `world/streaming/chunk_manager.gd` — modify.
- `world/streaming/chunk_builder.gd` — refactor into coordinator.
- `world/streaming/terrain_chunk_builder.gd` — new.
- `world/streaming/water_chunk_builder.gd` — new.
- `world/streaming/biome_chunk_builder.gd` — new.
- `world/streaming/road_chunk_builder.gd` — new.
- `world/streaming/underground_chunk_builder.gd` — new.
- `world/streaming/vertical_network_builder.gd` — new.
- `world/main.gd` — modify.
- `world/city_spawner.gd` and `world/population.gd` — modify for generated settlements/layers.

### Simulation/persistence

- `core/autoload/save_manager.gd` — modify.
- `core/autoload/world_state.gd` — modify.
- `core/autoload/event_bus.gd` — add documented world/settlement/route/resource signals.
- `actors/zombie/zombie.gd` — modify only when ground-layer spawning/pathing is specified.
- `actors/survivor/survivor.gd` and `actors/survivor/player_controller.gd` — modify for ordinary-survivor/upper-layer gameplay.

### Tests/tools

- `debug/world_test.gd` — extend or split.
- `debug/terrain_test.gd` — new.
- `debug/hydrology_test.gd` — new.
- `debug/settlement_test.gd` — new.
- `debug/underground_test.gd` — new.
- `debug/vertical_network_test.gd` — new.
- `debug/art_validation_test.gd` — new.
- `tools/run_suite.py` — modify for new flags and log capture.
- Existing `debug/city_runtime_test.gd`, `debug/havoc_test.gd`, and `debug/walkthrough_probe.gd` — extend only when the current P1 review permits it.

### Art/rendering

- `art/asset_catalog.gd` — new.
- `art/procedural_kit_catalog.gd` — new.
- `art/material_palette.gd` — new.
- `art/toon_surface.gdshader` — new.
- `art/toon_outline.gdshader` — new.
- `art/render_style_config.tres` or equivalent — new.
- Imported model/texture directories — new, with documented scale/collision/LOD metadata.

---

## 6. Testing and validation strategy

### Determinism

For the same seed:

- Query `WorldPlan` in different orders.
- Build chunks in different orders.
- Build on worker threads with private plan instances.
- Save/unload/reload.
- Compare stable plan and chunk manifests.

Expected: identical IDs, positions, geometry manifests, collision manifests, water topology, settlement graph, cave graph, and upper-network links.

### Geographic validity

- Terrain edge samples match within floating-point tolerance.
- No water-body discontinuities at chunk boundaries.
- Rivers descend or follow explicitly permitted engineered structures.
- Roads avoid impossible slopes or receive bridges/cuts/retaining structures.
- Farms, villages, and towns meet suitability constraints.
- Forests and agricultural belts are contiguous and regionally coherent.
- Mines/caves are geologically plausible and graph-connected.

### Gameplay validity

- Upper survivor routes have collision and usable transitions.
- Ground zombie routes do not accidentally use upper-only links.
- Survivor stations and roof farms are usable and persist state.
- Player can traverse city-to-river, city-to-village, and city-to-forest paths without teleports.
- NPCs remain autonomous and the player is not assigned a unique protagonist flag.

### Rendering/assets

- Imported models are at realistic scale.
- Materials are assigned by semantic family.
- Missing asset references fail `--arttest` clearly.
- Toon outlines remain readable without excessive draw-call or overdraw cost.
- LOD transitions do not expose chunk seams or destroy silhouette readability.

### Performance

Start with measured budgets rather than fixed assumptions. At minimum record:

- Generation and materialization time for the active 3x3 ring.
- Memory and node counts for the warm 5x5 ring.
- Terrain collider counts per chunk.
- Upper-network dynamic entity counts.
- Frame time with water, vegetation, interiors, and outlines enabled.

Any system that exceeds budget must reduce representation complexity or streaming scope before adding more detail.

---

## 7. Risks, tradeoffs, and open decisions

### Risk: scope becomes too large for one milestone

Mitigation: make the first macro milestone a complete geographic skeleton, not a fully art-authored 16 km world. Require the first playable slice to contain every requested region type, then expand content density incrementally.

### Risk: infinite procedural world conflicts with authored Prague quality

Mitigation: use procedural macro geography and settlement placement, but use authored region archetypes and modular asset kits for the Prague basin, industrial corridor, villages, farms, and mines. A seed controls variation within constraints.

### Risk: a fully random river/road system looks implausible

Mitigation: use deterministic anchor graphs and constrained routing. Randomness chooses among valid alternatives; it does not replace geographic rules.

### Risk: terrain collision and streamed buildings disagree

Mitigation: make terrain height/building datum queries come from the same `WorldPlan`; terrace/flatten settlement plots explicitly; run edge and doorway probes at generated sites.

### Risk: underground geometry causes collider explosion

Mitigation: use graph-driven modular volumes and simplified collision, materialize only discovered/nearby sections, and measure per-chunk collider counts before increasing detail.

### Risk: upper-city traversal becomes a second unrelated game

Mitigation: store it as a network of building anchors and links derived from settlement conditions. It should reuse building floors, doors, stations, and existing traversal contracts rather than invent a separate scene hierarchy.

### Risk: toon shading makes interiors or forests visually noisy

Mitigation: outline by semantic category/depth, use material flags to disable outlines on small clutter, and validate with screenshots plus frame-time measurements.

### Open decision 1: sea

**Recommended decision:** no true sea in the initial Prague-centered continental map. Implement a coast-capable `WaterBody` schema and reserve a future outer macro region for sea/coastal gameplay. If the user wants a sea in the first world, the setting must explicitly change from Czech-inspired continental geography to a fictional coastal basin, or Prague must become an inland city beside a much larger fictional sea beyond the main map.

### Open decision 2: world boundary

**Recommended decision:** begin with a deterministic 16 km x 16 km bounded world containing all requested region types, while preserving coordinate-based generation outside the boundary for future expansion. This is safer for streaming, navigation, QA, and content density than promising an immediately infinite world.

### Open decision 3: camera/traversal presentation

The existing project describes an elevated/top-down camera while the roadmap also mentions first-person traversal. This needs a formal decision before upper-city implementation: retain an elevated camera with readable cutaway/floor gating, add a close zoom mode, or support a controlled camera transition for interiors. The plan assumes the current camera contract remains until explicitly changed.

### Open decision 4: authored versus procedural landmark density

**Recommended decision:** procedural placement for most roads, blocks, fields, vegetation, and minor buildings; authored modular kits for Prague landmarks, major factories, bridges, stations, churches, mine machinery, and important survivor hubs. This gives replayability without making the world visually generic.

---

## 8. Definition of done for the macro-world milestone

The macro-world milestone is complete only when all of the following are true:

- The world is no longer a flat city-only plane.
- A canonical seed produces a coherent Prague-inspired urban basin with surrounding river, lake/reservoir, hills, forest, farms, villages, industrial corridor, quarry, cave, and mineshaft regions.
- Terrain, water, biomes, settlements, roads, geology, and underground graphs are deterministic and chunk-order independent.
- Roads and bridges connect the city to external settlements and natural regions.
- Buildings conform to terrain and retain realistic multi-room program metadata.
- The upper survivor civilization is represented by collision-backed routes, occupied floors, bridges, roof farms, roof dwellings, workshops, and social/service stations.
- Zombies are primarily organized around the lower city/street layer while survivors continue autonomous activity above.
- The player is represented as an ordinary survivor, not a chosen-one role.
- Proper modular models/textures and toon-outline shading are proven on a representative city, rural, industrial, and upper-city slice.
- Persistence preserves meaningful changes across chunk streaming and save/load.
- New macro-world tests and all existing regression gates report `finished with 0 failure(s)`.
- Luna has reviewed the actual implementation, test evidence, performance evidence, and remaining risks before the next expansion milestone is authorized.

## 9. Execution handoff

This document is a design/implementation plan only. Before implementation:

1. Resolve the current paused `P1-INTERIORS-TRAVERSAL` workflow and inspect its uncommitted changes.
2. Have Luna approve this macro-world scope as a new specification/milestone.
3. Split the plan into bounded Kanban tasks with one checkout owner at a time.
4. Use a fresh implementation worker per approved task, followed by spec-compliance and code-quality review.
5. Do not permit workers to turn the macro-world milestone into facade-only ornament work.
