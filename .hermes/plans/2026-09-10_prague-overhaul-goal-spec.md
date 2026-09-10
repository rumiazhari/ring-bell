# Goal spec — Prague historic-core overhaul (continued from Astra)

Source: user prompt sent to "GPT 6 Astra"; Astra's run exhausted tokens ~2026-09-10 23:10.
This file is the standing definition of the work. Re-read it after any context compression.

Repo: `rumiazhari/ring-bell`
Worktree: `C:/Vibe Code project/Godot Project/ring-bell` (branch `copilot/worldgen-fix`)
Astra's baseline: `7b92460` — everything after it is uncommitted local work.

## Where Astra left it (recovery notes)

- Compiles: **NO**. `world/generation/historic_street_plan.gd:95` has an `if` with no
  indented body (`best = k` on line 96 sits at the same tab depth), which breaks the
  preload in `city_plan.gd:3` → `world_plan.gd` → `fringe_chunk_builder` →
  `chunk_manager` → `debris_manager`.
- Committed: **nothing** (HEAD == `origin/copilot/worldgen-fix` == `7b92460`).
- Untracked new plan files: `historic_street_plan.gd`, `urban_block_plan.gd`,
  `parcel_plan.gd`, `historic_interior_plan.gd`, `roof_plan.gd`, `debug/prague_test.gd`,
  `docs/world/PRAGUE-MORPHOLOGY.md`.
- Modified + uncommitted: `city_plan.gd`, `world_plan.gd`, `world_seed.gd`
  (`GENERATOR_VERSION` 2 → 4), `building_builder.gd`, `interior_plan.gd`,
  `pavement_plan.gd`, `building_contract_validator.gd`, `chunk_builder.gd`,
  `mesh_batcher.gd`, `main.gd`.
- Last artifacts: `.hermes/autopilot/reports/prague-street-faces.{svg,png}` (22:52).
- `docs/world/PRAGUE-MORPHOLOGY.md` is Astra's own honest status doc: research
  constraints + implementation boundary, explicitly *not* acceptance.
- Known-failing before the overload: `--cityruntime` 2 failures
  ("destroyed/opened door states survive streaming"); `--praguetest` never ran green.

## Goal

A single coherent overhaul of the Prague-inspired historic urban core so its morphology,
buildings, interiors, circulation, roofscape and street network become substantially
closer to real historic Prague (Staré Město-like), while preserving Ring Bell's
deterministic procedural-world architecture, streaming performance, gameplay
usability, save compatibility and all existing non-urban systems.

This is NOT a façade beautification task. Make the underlying urban morphology
structurally believable. Do not fake it with decoration — make the structure real.

## 1. Historic street topology

The orthogonal grid must no longer dominate the historic core. Historic-core streets
form an organic but deterministic graph with: crooked alignments, gradual bends, short
irregular segments, T-/Y-junctions, occasional four-ways, offset intersections, streets
terminating against buildings or public spaces, short dead ends, narrow lanes,
pedestrian passages, irregular connections between important routes, occasional wider
historic routes, and plazas/church/civic spaces acting as network anchors.
No arbitrary spaghetti: the network stays geographically coherent and navigable.

Width distribution target for the historic core (approximate, not rigid per-street):
~25–35% narrow lanes/passages 3.5–5.5 m; ~40–50% ordinary streets 5.5–8 m;
~15–25% important streets 8–11 m; only ~3–8% wide interventions 12–16 m.
Outside the historic core the more regular logic may dominate. Historic-core avenue
frequency must be much lower than generic city behaviour. Width may vary gradually
along a street. Avoid modern American road assumptions; historic streets are often
shared-surface/cobbled rather than asphalt vehicle corridors.

## 2. Block morphology

Streets produce blocks, not the reverse: irregular polygons, elongated blocks,
trapezoids, wedges, occasional near-triangles, non-parallel opposing edges, variable
block depth, irregular corners. Avoid every block converging on similar dimensions;
a Prague-like tendency is ~50–70 m on one axis and ~80–130 m on the other, with
significant variation. Do NOT replace the 88 m grid with another rectangular grid.

## 3. Historical plot morphology

Plots/parcels are generated first, inside blocks, and are persistent conceptual objects.
Typical historic-core tendency: frontage ~6–15 m, total depth ~25–45 m, some shallower
and deeper exceptions, party-wall adjacency common. A street-facing building must NOT
automatically consume the entire property. The concept is
`BLOCK → PLOT → BUILDING WINGS → ROOMS`, not `BLOCK → RECTANGULAR BUILDING → ROOMS`.
Plot IDs must be deterministic and stable.

## 4. Building compounds / wings

Multiple connected masses: street/front wing, optional side wing(s), optional rear wing,
internal courtyard, entrance passage, stair core, service zones. Common forms: I, L, U,
narrow courtyard house, front wing + rear annex, corner compound. Not decorative
attachments — they belong to a coherent building/plot structure. Frontage often ~6–15 m
while the property extends 25–45+ m behind it.

## 5. Courtyards

First-class urban feature, varying shape/size derived from the plot. Real functions:
light/access, circulation, work/service, storage, social space, possible survivor
activity, possible traversal routes. Typical span ~4–12 m but derived, not forced.
Adjacent plots may occasionally form connected courtyard systems.

## 6. Passages and permeability

Support street→courtyard, courtyard→courtyard, courtyard→rear lane, street→street,
covered carriage passages, narrow pedestrian cuts, archway-like ground-floor entrances.
This is a secondary traversal network through blocks. Do not overgenerate; some blocks
stay impermeable. Passages must be deterministic, structurally valid, physically
traversable and tied to building geometry, and must support later gameplay (escape,
shortcuts, stealth, survivor routes, shops, roofs, faction control).

## 7. Building height and street enclosure

Height is not chosen independently of street morphology. Historic core ~3–6 storeys
with occasional 2- and 7-storey exceptions; street width and neighbour heights produce
believable enclosure (narrow 4–6 m streets feel vertically enclosed); important streets
and squares tolerate taller façades and larger setbacks. Avoid dramatic random
alternation every parcel — local continuity with controlled variation.

## 8. Ground-floor functions

Remove the "whole building is residential or retail" concept. Assign use at
room/floor/zone level — ground: entrance passage, shop, workshop, tavern/food, storage,
service room, caretaker dwelling, stairs, rear working courtyard; upper: apartments,
rented rooms, offices, workshops, institutional; basement: cellar, storage, workshop,
utility/service, shelter; attic: storage, workshop, dwelling, survivor-use space.

## 9. Interior layout

Replace generic equal-rectangle splitting in the historic core. Derive from façade/window
access, street vs courtyard orientation, passage location, stair core, plot depth, wing,
floor use, party walls, service access. Believable sequences such as
`street room → middle room → courtyard room`, `shop → back room → passage/stair → courtyard`,
`entry hall → stair → chamber → kitchen/service`. Avoid a neat 2×2 room grid on every
residential floor; vary room sizes; floors need not share one plan. Keep accessibility and
gameplay readability.

## 10. Vertical circulation

Every accessible upper storey has believable circulation: main stair, landing, stair hall,
courtyard stair, occasional secondary/service stairs where justified, cellar stairs, attic
stairs. Never unreachable floors. Stairs are not a geometry afterthought — the stair core
shapes the floor plan around it.

## 11. Cellars and basements

Proper historic-cellar abstraction at the plan level with persistent cellar manifests
(single-room, vaulted, multi-room, linked, storage, workshop, partially older
substructure). Do NOT fully materialize a huge underground system if performance/scope
make it unsafe — only materialize what is robust within current gameplay and collision
budgets. Cellars are the future connection point to Ring Bell's underground systems.

## 12. Roofscape

Actual roof morphology, not generic roof selection: controlled distributions of gabled,
hipped, mansard-like forms, courtyard-facing slopes, dormers, chimneys, parapet/cornice
variation, attic volumes and differing ridge orientations. Roof geometry follows the
footprint — L/U compounds must not receive one giant generic roof box. Historic streets
produce a coherent roofscape viewed from rooftop level (Ring Bell has vertical survivor
civilization).

## 13. Façade grammar

Façades generated from underlying structure. Window/door positions correspond to floor
heights, room locations, stair cores, shops, passages, structural bays, frontage. Support
carriage entrances, shopfronts, residential entrances, courtyard entrances, asymmetry,
varied bay widths, corner treatment. Prague identity is not solved by randomly added
ornaments.

## 14. Public-space hierarchy

tiny widening → pocket square → church forecourt → market square → major square → alley
junction → courtyard → passage. Squares are not rectangular empty blocks; geometry emerges
from the street/building network and buildings define their edges.

## 15. Landmark hierarchy

Deterministic landmark/site reservation where architecturally appropriate: church, tower,
civic building, guild/market structure, palace/manor-scale compound, gate/remnant,
industrial landmark where contextually appropriate. Do not attempt detailed landmark art
if it destabilizes the overhaul — at minimum the plan reserves and represents landmark
footprints, and landmarks influence nearby streets, squares, sightlines and height
hierarchy.

## 16. Historical layering

Deterministic "age/layer" metadata for plots/buildings: medieval core structure, later
enlarged rear wing, rebuilt façade, Baroque-era modification, later shopfront, patched
roof, blocked doorway, converted workshop. Use the metadata to influence geometry or use
where practical — not as flavour text.

## 17. Material/surface logic

Historic-core streets must not default visually to asphalt. District-aware surface
categories: cobble, stone setts, stone paving, worn mixed paving, later asphalt
intervention, courtyard paving, dirt/service yard — using existing low-cost rendering
architecture, no large new texture/runtime cost.

## 18. Prague morphology validation

A dedicated automated morphology validation layer (`--praguetest` or equivalent integrated
into city validation). It statistically inspects many blocks/seeds and verifies plausible
distributions for: street width, segment length, intersection types, intersection angles,
dead ends, T-junction frequency, block aspect ratio, block area, plot frontage, plot depth,
courtyard presence, courtyard area fraction, passage frequency, building storeys, roof
types, mixed-use frequency, stair accessibility. It must NOT assert one exact map — verify
distributions and structural invariants, deterministically.

## 19. Gameplay compatibility

The city must stay good for movement, combat, zombie pursuit, line-of-sight, exploration,
hiding, interiors, rooftops, survivor bridges, navigation, future NPC routines and future
Neighborly-inspired social simulation. Maintain traversal width; no pathological space
where NPCs or the player cannot move.

## 20. Determinism

Non-negotiable: `seed + world coordinates + generator version` yields identical results
regardless of chunk visit order, query order, worker scheduling or save/load order. No
global or uncontrolled RNG — domain-separated deterministic RNG through the existing
`WorldSeed` architecture. No scene-tree state may influence PLAN generation.

## 21. PLAN vs MATERIALIZATION separation

PLAN: pure, immutable/query-like, cheap, deterministic, no scene tree.
MATERIALIZATION: meshes, collision, doors, stations, actors, visuals.
Materializers must not invent structural urban facts. New plan-layer classes where
useful (`HistoricStreetPlan`, `UrbanBlockPlan`, `ParcelPlan`, `BuildingCompoundPlan`,
`CourtyardPlan`, `PassagePlan`, `RoofPlan`) — but avoid gratuitous abstraction or dozens
of meaningless micro-files.

## 22. Streaming compatibility

64 m chunks; large plots/compounds may cross chunk boundaries. Do NOT duplicate or split
conceptual buildings to fit chunks — one stable owner ID/chunk per compound while geometry
may span boundaries. Warm/active/cold streaming stays safe.

## 23. Save compatibility

Generated geometry stays reproducible; persistent saves store only meaningful
deltas/state. If procedural output changes substantially, handle generator versioning
explicitly and correctly — never silently reinterpret old saves. If `GENERATOR_VERSION`
must change, document exactly why (Astra already bumped 2 → 4).

## 24. Performance

Do not destroy streaming budgets; measure the impact. Avoid one node per detail, excessive
StaticBody3D counts, huge object trees, draw-call multiplication, pathological mesh
fragmentation. Prefer batched geometry; dynamic objects only where behaviour is needed.

## 25. Research grounding

Consult credible Prague architectural/urban morphology references (IPR Praha, Prague
heritage management documentation, ČVUT Faculty of Architecture, Staletá Praha
archaeological studies, peer-reviewed urban morphology, documented historic plans) and
extract measurable constraints. Do not rely on tourism photos, Pinterest, game screenshots
or generic "European city" references. Document constraints + source rationale in project
documentation. Do not copy an actual Prague map 1:1 — Ring Bell stays fictional and
procedural.

## 26. Scope discipline

Do not spend this task on zombies, combat, quests, dialogue, weapons, unrelated rural
systems, generic AI, unrelated UI or unrelated art polish — touch them only where
compatibility with the urban overhaul absolutely requires it.

## 27. Migration strategy

Inspect current architecture → identify reusable pieces → create the improved plan
representation → adapt existing building/materialization systems → migrate tests → remove
obsolete logic only once the replacement is verified. Preserve useful existing
deterministic infrastructure.

## 28. Validation

Run all relevant existing tests; at minimum verify project import, deterministic city
generation, no parcel/building overlaps, stable IDs, chunk-order independence, negative
coordinates, interior reachability, stair accessibility, doors/passages traversability,
city runtime tests, streaming regression, smoke tests. Add new tests for the Prague
morphology system. A pass must reflect real assertions, not merely absence of crashes.

## 29. Visual/manual validation

Use debug visualization/probes to inspect representative historic-core areas for several
seeds: street pattern, block irregularity, building depth, courtyard visibility, passages,
corners, roofscape, ground-floor entrances, traversability. If the result is mathematically
valid but still looks like a rectangular grid, keep improving it.

## 30. Documentation

Update `ARCHITECTURE.md`, `DEVELOPMENT.md`, relevant world-contract documentation and the
build-result/autopilot documentation if used by the repo. Document the new morphology
hierarchy, IDs, ownership rules, RNG domains, budgets, validation distributions and known
limitations.

## Architectural hierarchy target

`WorldPlan` → historic street graph → public spaces/landmarks → urban blocks → plots →
building compounds → wings/courtyards/passages → floor plans → rooms/stairs/cellars/roofs →
materialization. Do not collapse this back into one giant `CityPlan.gd`; do not fragment it
into dozens of meaningless micro-files.

## Final delivery requirements

Do not stop after analysis. Implement the strongest coherent version that fits safely
inside the repository and testing constraints. At completion: run the relevant test
suites; fix failures caused by this work; inspect representative generated output; update
documentation; summarize major architectural changes; report all compromises/deferred
items; report test evidence; report the final commit SHA. Commit all changes and ALWAYS
PUSH the completed work — do not leave it only in the local working tree.
