# SPEC-001 — Playable Semantic Interiors and Traversal Loop

Status: AUTHORIZED FOR BUILD
Milestone ID: `P1-INTERIORS-TRAVERSAL`
Owner: `lunaringbell` (architecture/design); `museringbell` (implementation/QA)
State revision: 1

## Player-facing objective

In the default streamed Prague city, the player can enter a generated residential
or retail building, understand what each room is for, use a small number of
useful interior stations, move through real internal doorways and the existing
staircase, reach an upper floor/roof, and return to the street without
teleports, invisible blockers, or losing the interior state after streaming or
save/load.

This is the next milestone because the repository already has deterministic
blocks, multi-storey shells, stairs, exterior doors, furniture programs,
cutaway presentation, destruction deltas, and parkour probes, while the
player-facing city still lacks room semantics and the required walkthrough is
not reliable. It deliberately converts the existing foundation into a playable
interior loop rather than adding another facade-only detail.

## Current baseline and constraints

The implementation baseline is commit `5202744` (the two newer commits are
control-plane changes only). The current repository inspection found:

- `CityPlan._make_spec()` already distinguishes deterministic residential and
  retail programs through `style.room_type`, but a building has no room graph,
  room partitions, or interior station manifests.
- `BuildingBuilder._furnish()` emits useful furniture and collision metadata,
  but the interior is still one open floor around the stair shaft; furniture is
  not an interactable gameplay system.
- `Door` is a physical dynamic entity and `ChunkManager` already persists door
  state and destruction deltas; internal doors must extend this existing
  contract rather than invent a second door type.
- `InteriorProbe` and `ChunkManager.apply_floor_gate()` already provide
  storey-aware cutaway presentation. Collision must remain present when a
  layer is visually hidden.
- `ParkourController` is already split and the city stair probe exists, but
  `--walkthrough` currently fails to cross the open entrance, climb, descend,
  and leave. `--cityruntime` currently has one closed-door collision assertion
  failure. These are in-scope blocking defects, not reasons to weaken tests.
- Verified baseline runs: `--citytest` finished with 0 failures and `--smoke`
  finished with 0 failures. Baseline `--cityruntime` finished with 1 failure
  (`closed leaf blocks doorway ray`), `--walkthrough` finished with 4 failures,
  and `--havoctest` finished with 1 failure in its known-tree clear-shot probe.
  The implementation must not hide or reclassify those failures; the required
  gates below must be run after the change.

The one-world-seed, deterministic-plan, chunk-ownership, merged-mesh, and
WorldState/save contracts remain authoritative. Legacy `--smoke`/`--soak`
world mode must remain intact.

## Scope

### 1. Deterministic interior plan

Create a pure plan-layer module at `world/generation/interior_plan.gd`.
`InteriorPlan` receives one existing `BuildingSpec` and returns a deterministic
manifest; it never touches the scene tree and never uses unseeded randomness.
The manifest shape is fixed as follows:

```text
{
  "version": 1,
  "building_id": String,
  "use": "residential" | "retail",
  "floors": [
    {
      "floor_i": int,
      "rooms": [
        {"id": String, "kind": StringName, "rect": Rect2,
         "entry": bool, "service": bool}
      ],
      "partitions": [
        {"id": String, "a": String, "b": String,
         "rect": Rect2, "opening": Rect2}
      ],
      "doors": [Door manifest dictionaries],
      "stations": [
        {"id": String, "room_id": String, "kind": StringName,
         "position": Vector3, "yaw": float, "loot": StringName}
      ]
    }
  ]
}
```

Required programs:

- Residential: every floor has a sleeping room and a service/toilet room;
  the ground floor also has an entry/living-dining room and a kitchen zone.
- Retail: the ground floor has an entry/sales room, a storage/service room,
  and a service/toilet room; upper floors use a deterministic office/quarters
  program and still contain a service/toilet room.
- A generated floor must have a connected room graph from the stair/entry
  approach to every required room. Room rectangles, partitions, openings,
  furniture keep-outs, and door swings may not overlap illegally or escape the
  actual interior boundary.
- The planner must gracefully fall back to a smaller valid program on the
  smallest eligible footprint; it must never emit an unreachable room merely
  to satisfy a count.

Public pure APIs are:

- `InteriorPlan.build_for_building(spec: Dictionary) -> Dictionary`
- `InteriorPlan.validate(manifest: Dictionary) -> Array[String]`
- `InteriorPlan.room_at(manifest: Dictionary, floor_i: int, p: Vector2) -> Dictionary`

All stable IDs are derived from the existing building ID, floor index, room
kind, and deterministic ordinal. Query/build order must not change the result.
`CityPlan._make_spec()` may retain `style.room_type` for compatibility, but the
canonical semantic value is `spec["use"]` (with an additive migration path for
old specs).

### 2. Real geometry and dynamic interior entities

Extend `BuildingBuilder` to consume the interior manifest:

- Emit structural interior partition segments with apertures, using the same
  `MeshBatcher.add_structural_box()` collision policy as exterior walls.
- Put interior geometry under building/floor-specific layer keys so the
  existing floor gate hides only presentation above the current storey; hidden
  geometry must continue to collide.
- Keep the entrance corridor, stair zone, room graph openings, and furniture
  keep-outs clear. Do not solve the walkthrough by disabling collision or by
  moving the player through walls.
- Preserve the existing deterministic furniture placement, but constrain it by
  its owning room. Furniture that is purely decorative remains batched; only
  gameplay stations become dynamic nodes.

Extend `MeshBatcher`/`ChunkBuilder` with deterministic station manifests and
spawn them only for owned buildings. Add
`world/buildings/interior_station.gd` for a small interactable station entity.
It must use the existing `InteractableComponent` and `interactables` scan, have
a stable `station_id`, and expose:

- `setup(manifest: Dictionary)`
- `station_id`, `room_id`, `station_kind`, and `consumed` state
- `interact(player: Node3D)` (or an equivalent signal-backed public entry point)
- `save_state() -> Dictionary` / `load_state(data: Dictionary)` when needed

Required player-facing station behavior:

- Residential bed/rest station: interacting reduces the player's fatigue by a
  meaningful bounded amount and shows a HUD notice; it must not advance time or
  teleport the player.
- Retail counter/storage station: the first interaction grants one
  deterministic useful item from the bounded existing ItemDB set
  (`canned_food`, `water_bottle`, or `bandage`), then marks the stable station
  consumed and shows a HUD notice. Repeated interaction and save/load must not
  duplicate the item.
- Service/toilet rooms must be spatially present and reachable even if they do
  not yet have a gameplay action.

Use the existing `WorldState` flags for consumed station facts under a stable,
clearly namespaced key such as `interior_looted:<station_id>`. Do not add an
autoload or project-setting change for this milestone. If a gameplay event is
added, document it in `core/autoload/event_bus.gd` and emit it once per
successful station use.

### 3. Reliable physical traversal and streaming

Repair the actual runtime path exposed by `debug/walkthrough_probe.gd`:

1. Approach a closed entrance from the street.
2. Verify the closed leaf blocks the aperture.
3. Open the physical door through its public API/interaction path.
4. Walk through the opening into the ground-floor entry room.
5. Traverse the connected room graph to the staircase without teleporting.
6. Climb every generated storey using the real ramp/floor collision, reach the
   roof deck, and return down.
7. Walk back through the interior and out, close the door, and verify the closed
   aperture blocks again.

Fix the root cause of the current door-ray and walkthrough failures. In
particular, preserve the `Door` invariant that a closed leaf blocks the
aperture and an open leaf remains physically collidable at its swung position;
allowing a door to become intangible is not an acceptable fix. Use physics
synchronization/waits only in the harness where required for a real transform,
not as a substitute for correct geometry.

`ChunkManager` remains the owner of chunk records and must materialize the
interior manifest exactly once per chunk load. Internal door IDs, station IDs,
room IDs, and partition geometry must be deterministic across unload/reload.
Door open/closed/destroyed state and consumed station facts must survive the
existing save/load path. Do not serialize generated geometry.

## System ownership and interfaces

| System | Owns | Interface/invariant |
|---|---|---|
| `WorldSeed` | Seeded randomness/version | Every plan and station roll is seeded by building/floor/semantic purpose. |
| `CityPlan` | Building use and immutable building specs | Adds canonical `use`/interior manifest access without scene references. |
| `InteriorPlan` | Room graph, partitions, doors, station manifests | Pure, deterministic, validated; no Node/scene access. |
| `BuildingBuilder` | Static interior shell, partition collision, room-scoped furniture | Emits only through `MeshBatcher`; no dynamic gameplay nodes. |
| `MeshBatcher` | Batched static geometry and deterministic dynamic manifests | Interior structural cells carry stable IDs/layers/material metadata. |
| `ChunkBuilder` | One chunk materialization | Spawns dynamic `Door` and `InteriorStation` entities exactly once. |
| `Door` | Physical hinge, interaction, destruction, door state | Existing public open/close/is_open/save contract remains valid for exterior and interior doors. |
| `InteriorStation` | Player interaction and station-local presentation | Uses `InteractableComponent`; stable ID prevents duplicate loot/rest actions. |
| `ChunkManager` | Streaming, ownership, delta records, floor gate | Never duplicates buildings; persistence is seed + deltas/facts. |
| `WorldState` | Persistent consumed-station facts | Station loot is one-time and survives save/load. |
| `Main`/HUD | Wiring and player-facing notices | CITY only; legacy narrative mode remains unchanged. |
| Debug harnesses | Behavioral proof | Tests fail on blocked routes; no weakened assertions or teleports. |

Invariants:

1. Same seed + same building spec gives byte-equivalent normalized interior
   manifests regardless of query order.
2. Every emitted structural partition is inside its building and every room
   opening has exactly one matching door or intentional open passage.
3. Every required room is reachable from the entry/stair graph using collision-
   free walkable space; furniture/stations never seal the required route.
4. Visual floor gating changes visibility only; it never changes collision or
   station/door state.
5. A streamed chunk has one owner for all building interior entities, and an
   unload/reload does not duplicate them.
6. Station consumption and door state are persistent facts, not regenerated
   random outcomes.

## Implementation phases

### Phase 0 — Characterize and protect the baseline

Reproduce the current `--cityruntime`, `--walkthrough`, and `--havoctest`
failures, record their exact output, and add focused checks before changing
behavior. Do not modify unrelated facade code or mask a failing baseline.

### Phase 1 — Plan-layer room schema

Implement `InteriorPlan`, canonical `spec["use"]`, manifest validation, stable
IDs, residential/retail fallback programs, and deterministic city-test coverage
for room counts, service-room guarantees, bounds, graph connectivity, and
same-seed equality.

### Phase 2 — Collision-backed rooms and stations

Emit partition apertures and room-scoped furniture, add dynamic internal doors
and `InteriorStation`, wire existing interaction/HUD paths, and test both
archetypes through the real chunk materialization path. Keep station count
bounded to the minimal bed/rest and retail counter/storage stations needed for
the loop.

### Phase 3 — Streaming, persistence, and cutaway integration

Materialize and unload internal entities with the building owner, restore door
states, persist consumed station flags, and verify floor-gate visibility while
collision remains active. Extend city runtime coverage for an unload/reload and
save/load round trip.

### Phase 4 — Traversal proof and closeout

Repair entrance/room/stair route geometry and the physical door timing issue,
then make `--walkthrough` exercise entry, station use, all floors, roof, return,
and closed-door blocking. Run every required gate below and request Luna review
with changed files, commit IDs, exact outputs, acceptance mapping, and residual
risks.

## Explicit acceptance criteria

1. `InteriorPlan.validate()` returns no errors for all sampled residential and
   retail buildings in the canonical seed and at least four alternate seeds.
2. Every eligible generated building has canonical use metadata and a valid
   deterministic interior manifest; every floor has a service/toilet room,
   and the required archetype rooms are present where the footprint allows.
3. `--citytest` contains passing assertions for manifest determinism, bounds,
   non-overlap, required room kinds, service-room presence, room-graph
   connectivity, station IDs, and internal-door manifest consistency.
4. A real streamed residential building and a real streamed retail building
   each materialize room partitions with apertures, room-scoped furniture, at
   least one usable station, and dynamic internal doors. No entity is duplicated
   on chunk ownership boundaries.
5. Interacting with a bed changes fatigue once without time advance; interacting
   with a retail counter/storage grants exactly one allowed item and persists
   the consumed fact through save/load and chunk unload/reload. HUD prompts and
   notices identify the action.
6. The complete no-teleport route in `--walkthrough` finishes with 0 failures:
   closed entrance block, open entry, ground-floor room traversal, every-storey
   stair climb, roof arrival, descent, exit, close, and closed-door block.
7. `--cityruntime` finishes with 0 failures, including closed/open door physics,
   internal door interaction, deterministic IDs after streaming, station state,
   floor-gate behavior, and persistence round trips.
8. `--citytest`, `--smoke`, `--cityruntime`, `--havoctest`, and `--walkthrough`
   all print `finished with 0 failure(s)`. A Windows shutdown code is acceptable
   only when that line is present; a missing/partial run is not a pass.
9. No existing smoke/soak quest, combat, destruction, lighting, or legacy-mode
   assertion is weakened or removed. No facade-only production work is included.
10. The implementation is committed as coherent units and the Muse handoff
    names changed files, commits, tests, acceptance results, residual risks,
    and any escalation reason.

## Required automated verification

From the canonical repository root, run these commands after implementation:

```text
python tools/run_suite.py --import 120
python tools/run_suite.py --citytest 300
python tools/run_suite.py --smoke 120
python tools/run_suite.py --cityruntime 300
python tools/run_suite.py --havoctest 180
python tools/run_suite.py --walkthrough 300
```

Judge each result by its log's `finished with 0 failure(s)` line. The two 300
second limits are intentional: the current deterministic city suites can take
more than the older 120/180 second defaults on this Windows workspace.

Focused checks should include pure manifest validation and a real runtime route;
assertions must inspect node identity/geometry/state and not just source text or
constant values.

## Manual/player-facing verification

Run the default CITY mode windowed. At the plaza, approach a visible building
and use the normal controls (WASD, E, camera rotate/zoom):

1. Close/open the entrance and observe the prompt change; the closed leaf must
   visibly and physically block the opening.
2. Enter without a teleport. Rotate the camera and confirm the floor cutaway
   reveals the current room while partitions, furniture, and the far wall
   still read as a coherent space.
3. Use the bed in a residential room and confirm fatigue drops with a HUD
   notice and no time jump. In a retail room, use the counter/storage once and
   confirm the inventory changes; press E again and confirm no duplicate item.
4. Follow the stairs to the roof and back down, crossing internal doorways as
   needed. Return to the street and close the entrance.
5. Quicksave, move away until the building unloads, return, and quickload. The
   building layout/IDs are unchanged, the consumed station remains consumed,
   and door state is restored. Capture any failure as a reproducible log rather
   than compensating with a teleport or disabled collision.

## Out of scope and scope guard

- No additional Prague facade ornament, new roof dressing, or cosmetic-only
  material pass.
- No new city seed requirement, multi-map system, or handcrafted replacement
  for the deterministic city.
- No migration of Kenji/Hana or the full P0 cast into CITY; that is a later
  milestone after the interior loop is trustworthy.
- No NavigationServer/navmesh, faction/economy, advanced stealth/AI vision,
  full sleep/time-skip system, firearms redesign, or broad destruction rewrite.
- No mall/school/university/workshop archetypes in this pass; the room schema
  must be extensible, but only residential and retail programs are authorized.
- No new autoload, scene asset, project setting, or first-person camera.
- Do not change test semantics to accept teleporting, no-collision passages,
  inaccessible rooms, duplicate loot, or a missing zero-failure line.

Any request outside this list, any need to change a core public interface, or
any repeated failure after three serious repairs must be escalated to Luna
through Kanban instead of being improvised.

## Rollback and recovery

Keep the pre-milestone implementation checkpoint intact. Muse should commit
plan, geometry/entities, and traversal/persistence fixes as reviewable units;
never rewrite history or delete files. If the candidate is rejected, revert the
candidate commits (or quarantine unwanted generated artifacts under `junk/`)
and restore `AUTOPILOT_STATE.json` to `needs_architect` with the exact failing
log and a new reason. If the interior manifest changes generated geometry or
save compatibility, increment the generator version deliberately and retain
old-save warning behavior; do not silently reinterpret old deltas. A rollback
must leave the baseline citytest/smoke behavior reproducible.

## Exact Muse handoff

The supervisor must create exactly one implementation task after this state is
authorized:

- Title: `Ring Bell build P1-INTERIORS-TRAVERSAL revision 1`
- Assignee: `museringbell`
- Approved specification: `.hermes/autopilot/specs/SPEC-001.md`
- Runtime budget: 2 hours
- Retry budget: 3 retries
- Constraints: implementation only within this specification; request Luna
  review on completion; escalate architecture ambiguity instead of inventing a
  second milestone.
