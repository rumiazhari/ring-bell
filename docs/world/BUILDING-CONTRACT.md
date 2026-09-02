# Ring Bell — Universal Building Contract (G10-P2A)

**Version:** 1.0.0 · **Status:** LIVE (city pipeline + rural house family migrated)

One mandatory, reusable building standard so all future player-facing
buildings — city, village, hamlet, farm, industrial, suburban,
institutional — share the same structural quality. No future agent may
invent another cheap building builder.

## 1. Core architecture — separate the WHAT from the HOW

1. **WORLD / SETTLEMENT / CITY PLAN** decides WHERE a building exists and
   WHAT it is (kind, use, district, footprint, storeys, entrance).
   - `CityPlan` stamps `quality`, `archetype`, `circulation` on every spec.
   - `RuralBuildingPlan` stamps the same on every rural building.
2. **BUILDING ARCHETYPE** (`world/generation/building_archetype.gd`)
   defines program/identity: `house`, `cottage`, `tenement`, `shop_house`,
   `barn`, `stable`, `shed` (live) and `inn`, `factory`, `warehouse`,
   `school`, `hospital` (reserved). Each archetype declares its family,
   minimum quality, bulk single-hall status and roof vocabulary.
3. **UNIVERSAL BUILDING SPEC** (`world/generation/building_spec.gd`)
   — one canonical dictionary shape: id, archetype/use/district, footprint
   (rect fast-path + polygon-ready `points`), floors/floor heights,
   entrances, windows, rooms & connections, vertical circulation, roof
   family, facade materials, exterior/interior features, and quality.
4. **UNIVERSAL BUILDING ASSEMBLER**
   (`world/generation/universal_building_assembler.gd`) — THE ONLY normal
   path that constructs player-facing enterable buildings.

**Not locked to Rect2:** the spec carries `points` (local CCW polygon) and
every validator rule is derived from footprint geometry, not Rect2 API.
Organic Prague blocks can feed polygons later; the rect implementations
stay in sync as the polygon's hull.

## 2. Quality levels (exactly three)

| Level | Meaning |
|---|---|
| `FULL_BUILDING` | enterable, full structure/interior/collision |
| `DISTANT_LOD` | visual simplification of a FULL building (requires `lod_of`) |
| `PROP_STRUCTURE` | explicitly non-enterable (outhouse, kiosk, lean-to, tiny shed) |

A house, apartment, inn, factory etc. may **never** be silently downgraded
to PROP_STRUCTURE. `BuildingContractValidator` rejects the classification.

## 3. Mandatory building invariants (FULL_BUILDING)

Where applicable to the archetype (validated, not aspirational):

- structural exterior walls with collision — one wall per facade side per
  storey (validator counts colliding segments, ≥4 sides);
- genuine door/window apertures — never decorative openings pasted over
  solid walls; the validator proves no sealing collider occupies ≥80% of
  any opening (city box path) and no collider vertex sits inside the door
  aperture (rural raw path);
- ground slab (below grade, top flush with the walkable surface);
- intermediate floor/ceiling slabs (every storey, with the stairwell/shaft
  hole — coverage rule ≥38–55% of the inner footprint by storey);
- proper roof (parapet + membrane or pitched shell for city; gabled ridge
  for rural);
- functional dynamic door leaves (Door entities from plan manifests);
- physically navigable interior (partitions with doorway openings, keep-out
  corridors);
- rooms appropriate to archetype, connected to the entrance (graph
  reachability over partitions-with-openings; single-hall archetypes are
  exempt from multi-room layouts);
- reachable intended upper floors (stairs fit check via
  `BuildingBuilder.has_stairs_for`, or ladder for rural two-storey);
- wall/window/door proportions within human scale;
- terrain grounding — no floating or buried shell (±1.0 m surface
  authority, slab flush at grade);
- deterministic generation from world seed/spec;
- compatible chunk streaming and storey visibility (city storey layers
  preserved).

## 4. Validator rules (`world/generation/building_contract_validator.gd`)

`validate_spec(spec, surface_fn)`:
- id present; quality ∈ the three levels; DISTANT_LOD requires `lod_of`;
- archetype known; classification (house-as-PROP rejected);
- footprint area ≥ 12 m², side ≥ 2.5 m; floors 1..8; floor_h 2.2..4.6;
- entrance(s): ≥1 for FULL; width 0.8–2.0 m, height 1.9–2.8 m; on the
  footprint edge (city: on `door_edge` facade; rural: on the rotated
  footprint edge);
- circulation: floors ≥ 2 requires `stairs` (city, with fit check) or
  `ladder` (rural);
- rooms (via `InteriorPlan` manifest): no overlaps, min 1.0 m rooms, entry
  room present, full graph connectivity from the entry room; rural house:
  partition-with-opening or furniture present;
- grounding: |ground_y − surface| ≤ 1.0 m when a surface callback is given.

`validate_build(spec, batcher)` (city box path):
- registered: the spec id must be registered by the universal assembler
  (else **assembler bypass**);
- aperture clearance (doors + every derived window): no colliding
  non-glass box seals ≥80% along × ≥80% height AND whose thickness
  interval straddles the wall plane (awnings, pilasters, interior
  partitions, railings, corner piers and slab panels cannot trip it);
- ≥4 structural wall segments per storey (one per facade side);
- ground slab + every storey slab coverage;
- roof geometry present;
- stairs materialised (rotated colliding ramps ≥ floors);
- grounding of the whole collider set (≤1.2 m buried, ≤0.35 m floating).

`validate_rural_build(building, evidence, collider_verts)` (rural path):
- assembler evidence present (`assembled == true`);
- door aperture empty of collider vertices (real scan of the Concave soup);
- one structural wall per side (vertices in each wall band, human height);
- ground slab + upper slab (two-storey) collider presence;
- roof evidence, interior (partition+opening or furniture), ladder evidence.

`unregistered_structural(batcher, registered_ids)` — **anti-trash scan**:
every colliding box with a non-empty reveal layer must belong to a
registered contract building; anything else is a bypass.

## 5. Hard anti-trash rule

No world-generation subsystem may directly construct a normal enterable
building using BoxMesh, raw `_append_box()`, or an independent custom wall
system. CityPlan/FringePlan/SettlementPlan/RuralBuildingPlan produce specs;
**UniversalBuildingAssembler** does the assembly. Direct primitive
construction remains allowed only for:

- explicit props (PROP_STRUCTURE);
- temporary debug visualization;
- distant LOD;
- non-building scenery.

Enforcement: batcher registration + `unregistered_structural` +
`validate_build`'s registration gate + the `--buildingcontracttest` harness.

## 6. Reuse of the reference quality engine

The city `BuildingBuilder` is preserved AS the universal city grammar:

- `UniversalBuildingAssembler.build_into(batcher, spec)` contract-stamps
  the spec, registers the id, then delegates to `BuildingBuilder.build`
  — byte-identical city geometry;
- the rural house family reuses `RuralArt`'s proven low-level primitives
  (`_append_quad`, `_append_wall_quad`, `_local_point`, collision boxes)
  inside the new aperture-composing grammar
  (`art/universal_building_art.gd`), and `SlabMath.subtract_rect` for the
  ladder shaft slab split — no duplicated vertex math, no new shell
  builder.

## 7. Migration status (fidelity to the real game)

| Pipeline | Status |
|---|---|
| City buildings | **Migrated** — via assembler → BuildingBuilder (visual/functional parity, validated) |
| Rural `house` family (`village_house`, `cottage`, `farmhouse`) | **Migrated** — aperture-composed walls, real windows+panes, door aperture, ground/upper slab, ladder, gabled roof, partition + opening, colliding furniture |
| Rural `barn` / `stable` / `shed` | **Pending migration** — still legacy rural art path, explicitly whitelisted in `UniversalBuildingAssembler.build_rural_into` (returns false), tracked here; their archetypes are registered so classification cannot regress |
| Fringe suburban houses | Routed through the assembler by the fringe builder (door sizes per spec) |
| `inn`, `factory`, `warehouse`, `school`, `hospital` | Reserved archetypes — geometry pending future milestones |

## 8. Test gates

`--buildingcontracttest` (debug/building_contract_test.gd):
malformed-spec rejection matrix · bypass detection · city conformance over
real CityPlan chunks (registration 1:1, no unregistered structural, every
spec+build passes) · rural conformance over real WorldPlan houses (spec +
build + budgets 720/420) · rural tamper matrix (solid geometry in doorway,
missing evidence, door off footprint).

Regression gates: `--citytest`, `--cityruntime`, `--ruraltest`, `--smoke`.