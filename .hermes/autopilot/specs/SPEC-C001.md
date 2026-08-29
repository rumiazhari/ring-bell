# SPEC-C001 — Collision-Backed City Traversal Closeout

Status: ARCHITECT-READY FOR CONTROLLER AUTHORIZATION
Milestone ID: `P0.5-TRAVERSAL-CLOSEOUT`
Owner: `lunaringbell` (architecture/design/review); `museringbell` (implementation/QA)
State revision: 0

## Player-facing objective

In the default streamed CITY, an ordinary survivor can approach a generated
multi-storey building, open its real physical entrance, walk through the
interior, climb every generated storey on the real staircase, reach the roof,
return to the street, and close the door so it blocks the opening again. The
route must be reliable under ordinary physics, not a probe-only teleport or an
intangible-collision shortcut.

This is the next bounded milestone because the repository has already invested
in deterministic city geometry, terrain materialization, dynamic doors,
interior partitions, stairs, cutaway presentation, destruction, and streaming,
but the central player-facing traversal loop is not yet trustworthy. Closing
that loop gives the player a meaningful shelter/exploration route and removes a
blocking dependency before hydrology, rural regions, or upper survivor routes
are layered onto the world.

This milestone is deliberately a reliability closeout, not a new content pass.
It must leave the existing terrain and city foundations intact and make their
actual collision behavior honest.

## Current baseline and constraints

The inspected canonical checkout is `C:/Vibe Code project/Godot Project/ring-bell`
at Git head `a328484`. The v2 controller state is enabled and currently
architecting cycle 1. Existing evidence in `tools/` shows:

- `--citytest` ends with `finished with 0 failure(s)` and already covers
  deterministic city/chunk plans, building ownership, interiors, stairs,
  doors, facade apertures, destruction, streaming, and terrain compatibility.
- `--terrainmaterialtest` ends with `finished with 0 failure(s)`, including
  17x17 terrain manifests, shared positive/negative seams, one terrain
  collider per chunk, active-ring budgets, materialization, and save exclusion
  of generated terrain.
- `--cityruntime` currently ends with one failure:
  `closed leaf blocks doorway ray`. Its other current door, streaming, stair,
  camera, and destruction-persistence checks pass.
- `--walkthrough` currently ends with four failures: the no-teleport route
  stalls between the entrance and stairwell, the climb and descent do not
  complete, and the player does not walk back out. Its closed-door checks pass
  before and after the attempted route, which means the route failure must not
  be hidden by weakening those checks.
- `--havoctest` currently ends with one failure:
  `destructible prop placed with clear shot`. The test's real physics fixture
  must become reliable; accepting a skipped or unhit prop is not allowed.
- The legacy `--smoke` contract and the deterministic terrain contract remain
  required. Unrelated dirty files and user work must be preserved.

The current `Door` contract is authoritative: a closed leaf blocks the doorway,
an opening/open leaf clears the aperture while remaining collidable at its
swung position, and only a destroyed door loses its collision. `ChunkManager`
continues to own streamed entities and persistence. `BuildingBuilder` remains
the source of stair/landing geometry; `walkthrough_probe.gd` is evidence, not a
replacement for correct geometry.

## Scope

### 1. Repair the physical door invariant

Trace the existing `Door` hinge, leaf transform, collision layer/mask,
freeze/activation, and physics synchronization rather than adding a second
blocking shape. Correct the root cause so the existing geometric doorway ray
through the manifest aperture center hits the actual `Leaf` rigid body while
closed. The implementation must preserve:

- the manifest position as the aperture center and the existing hinge/leaf
  ownership model;
- `open()`, `close()`, `is_open()`, `is_solid()`, and
  `is_passage_clear()` semantics;
- a solid leaf during closed, opening, open, and closing poses;
- an open doorway that is physically clear without excluding the leaf RID;
- deterministic exterior and interior door IDs and existing door persistence.

Do not move the test ray until it hits an arbitrary convenient point, add a
parallel invisible blocker, disable the leaf collision while open, or treat a
physics-query race as a pass. The runtime check must identify the leaf itself
as the closed blocker and the swung leaf itself as the open blocker.

### 2. Make the existing generated entrance/stair route physically traversable

Use the current `BuildingBuilder.stair_zone_world()`, `LANE_W`, `LAND`,
`flight_run()`, and `ramp_height_at()` contracts as the single source for the
route. Repair only the geometry, collision, and route instrumentation needed to
make a qualifying generated building traversable:

- the entrance aperture and entry corridor must have capsule clearance;
- interior partitions and furniture must not seal the manifest's entry-to-stair
  path or place a wall across an intended opening;
- ramp tops must meet both landing planes, and their underside/landing seams
  must not create a depenetration wedge;
- landing slabs may extend under flight ends and ramp colliders may be trimmed
  as needed, while the walkable top remains flush;
- the route must work for the existing opposite-edge door mapping and for the
  sampled multi-storey footprints, not only for one hard-coded building;
- no new per-waypoint trigger, teleport volume, navmesh, or collision-heavy
  grid is authorized.

Use the short ray ladder and forward capsule-sweep diagnostics described by the
Godot development guidance when a body stalls. A body that is frozen at a
seam with clear forward rays is a generator collision defect, not permission
to skip a waypoint.

The walkthrough harness may add diagnostics and correct arrival tolerances,
but after its one initial resident-wait drop-off it must never write the
player's position, skip an un-reached waypoint, disable environment collision,
or accept a route based only on Y height. A timeout/stall remains a failure and
must print enough position/target information to reproduce it.

### 3. Keep physics-fixture and streaming evidence honest

Repair the existing `--havoctest` known-tree fixture only as necessary to make
its dynamically spawned destructible prop receive a real clear-shot ray and
then take real weapon damage. A physics-frame wait or a space-query retry is
allowed to synchronize a newly added body; changing the assertion to accept a
missing prop, a different collider, or no damage is not.

The existing streamed-city path must still materialize one owned building
subtree and one set of exterior/interior doors per owner chunk. No duplicate
entities, hidden collision removal, or second destructive rebake may be added
as a traversal workaround. Preserve the current destruction delta and door
state round trips.

## System ownership and interfaces

| System | Owns | Required invariant |
|---|---|---|
| `WorldSeed` | Seed/versioned deterministic inputs | No new unseeded route or fixture randomness. |
| `Door` | Hinge, leaf physics, interaction, state | The leaf is the physical blocker in every non-destroyed pose. |
| `BuildingBuilder` | Stair/landing/partition collision geometry | Walkable tops are flush; no seam wedge or route-sealing wall. |
| `InteriorPlan` | Room/opening manifest | Existing room/door topology remains deterministic and bounded. |
| `MeshBatcher` | Batched static collision/mesh cells | Do not add duplicate invisible blockers or alter cell-key semantics casually. |
| `ChunkBuilder` | One chunk materialization | Building and door ownership remains exactly once per owner chunk. |
| `ChunkManager` | Streaming states and persistence deltas | Unload/reload restores the same IDs and saved door/destruction facts. |
| `debug/city_runtime_test.gd` | Runtime physics/streaming proof | Assertions inspect actual colliders, transforms, and state. |
| `debug/walkthrough_probe.gd` | No-teleport player route proof | Only the initial resident-wait drop-off may place the player. |
| `debug/havoc_test.gd` | Real combat/damage fixture proof | A present prop must be hit and damaged through physics/weapons. |

Public interfaces should remain compatible. If a small diagnostic helper is
needed, keep it in the relevant owner and test it through the real runtime
path; do not create a new global singleton or project setting.

## Construction sequence

### Phase 0 — Reproduce and protect the failures

1. Inspect the current dirty worktree and preserve unrelated changes.
2. Run the focused `cityruntime`, `walkthrough`, and `havoctest` gates and
   capture their current failure lines.
3. Add or tighten the smallest behavioral assertions/diagnostics first:
   closed-ray collider identity, door pose/transform, route stall position and
   target, physics-frame fixture readiness, and no-position-write route proof.
4. Run each focused check and confirm it fails for the expected existing
   behavior before changing production code. Do not retain a test written only
   after the implementation already passes.

### Phase 1 — Door root-cause repair

1. Trace the manifest aperture center through `Door._ready()` to the hinge and
   leaf collision shape.
2. Correct transform/hinge synchronization or physics activation while keeping
   the leaf RID and collision layer intact.
3. Re-run the closed/open/close runtime checks, including a ray that aims at the
   actual swung leaf and a ray that does not exclude its RID.
4. Confirm door IDs and saved open/destroyed states remain stable after a real
   chunk unload/reload.

### Phase 2 — Route geometry repair

1. Use the failing route's ray ladder/capsule sweep to identify the first
   obstructing structural cell or seam.
2. Repair the generator-side aperture, partition opening, landing overlap, or
   ramp collider bounds; keep visual and collision geometry aligned.
3. Keep route waypoints derived from the generated stair zone and use progress
   diagnostics rather than skips. Test at least opposite door edges and more
   than one building footprint/seed.
4. Verify entry, every-storey ascent, roof arrival, exact reverse descent, and
   exit using only `request_move()` plus ordinary `move_and_slide()` physics.

### Phase 3 — Fixture, persistence, and regression closeout

1. Make the havoctest prop fixture wait for actual physics registration and
   choose only a candidate whose real ray hits its own body.
2. Exercise door/destruction state through stream-out/stream-in and the current
   save-state path; generated geometry must not enter saves.
3. Run all required gates in the documented order, judge the explicit
   `finished with 0 failure(s)` marker, and report exact results.
4. Commit coherent implementation units and request the independent Luna review
   with changed paths, commit IDs, outputs, player-facing evidence, and
   residual risk. The builder must not change `AUTOPILOT_STATE.json`.

## Explicit acceptance criteria

1. `--cityruntime` finishes with `finished with 0 failure(s)`. In particular,
   the closed doorway ray hits the actual `Door` leaf, the open aperture is
   clear without RID exclusion, the swung leaf remains collidable, close
   re-blocks the aperture, and IDs/open/destroyed state survive streaming.
2. `--walkthrough` finishes with `finished with 0 failure(s)` and proves the
   complete generated route: approach closed entrance, open it, walk through
   the entry/interior, climb every storey, reach the roof, descend, leave,
   close, and verify the closed door blocks again. After the initial
   resident-wait drop-off, the route contains no player-position writes,
   waypoint skips, collision-mask bypasses, or teleports.
3. For the canonical seed and at least four alternate seeds, sampled eligible
   multi-storey buildings have bounded entry corridors, valid partition
   openings, and stair/landing collision geometry that is continuous at both
   ramp endpoints. The focused assertions use real manifest/geometry data and
   still pass the existing opposite-edge door/stair mapping checks.
4. `--havoctest` finishes with `finished with 0 failure(s)`: the destructible
   prop is present, its own collider receives the clear-shot ray, and weapon /
   explosion damage is observed through the existing physics path. No assertion
   accepts a missing, skipped, or unhit fixture.
5. `--citytest` finishes with `finished with 0 failure(s)` and retains
   deterministic plan/chunk/building/door/interior results across query/build
   order, negative coordinates, chunk ownership, and destruction persistence;
   no duplicate building or dynamic door/station entity is introduced.
6. `--terrainmaterialtest` and `--smoke` each finish with
   `finished with 0 failure(s)`. Terrain seam/material/collider budgets, save
   exclusion of generated terrain, legacy population/combat/quest behavior,
   and existing active-ring streaming budgets are not weakened.
7. A normal windowed CITY run provides ordinary player-facing evidence of the
   same route with WASD/E and no scripted placement after drop-off: the door
   visibly swings and remains solid, the capsule crosses the aperture, stairs
   feel continuous at landings, the camera follows the climb, and the player
   returns outside without falling through or walking through walls. Any
   remaining minor presentation issue is reported for a later design rather
   than masked in this milestone.

## Required automated verification

From the canonical repository root, run these commands after implementation:

```text
python tools/run_suite.py --import 120
python tools/run_suite.py --citytest 300
python tools/run_suite.py --terrainmaterialtest 300
python tools/run_suite.py --cityruntime 300
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --havoctest 240
python tools/run_suite.py --smoke 180
```

Every command must produce its harness marker `finished with 0 failure(s)`.
A Windows child exit code `3221225477` is acceptable only when that explicit
zero-failure marker is present. A timeout, missing marker, partial output, or
nonzero failure count is not a pass. The builder should run focused checks after
each RED-GREEN step as well as this final matrix.

## Ordinary player-facing proof

Run the default CITY mode windowed and select the same kind of qualifying
building used by the walkthrough. Approach the closed entrance normally; the
leaf must stop the survivor rather than an invisible substitute. Press E and
walk through the opening. Cross the entry corridor, follow the visible stair
well to every floor and the roof deck, then reverse the route and leave. Close
the door from outside and walk into it again to observe the physical block.
Use F3 to confirm the active-ring/terrain counters remain bounded. If a
failure occurs, retain the screenshot/log and exact player/building position;
do not compensate with a teleport or disabled collision.

## Performance, persistence, and compatibility boundaries

- Preserve the current `64 m` chunks, ACTIVE Chebyshev radius `<= 1`, WARM
  radius `<= 2`, one merged city mesh/static body per chunk, one terrain
  collider per materialized terrain chunk, and maximum nine active terrain
  colliders. Do not introduce a full 2D collider grid, per-waypoint bodies, or
  navmesh generation.
- Preserve stable building, exterior/interior door, station, and destruction
  cell identifiers. `ChunkManager` saves seed/version/discovery/deltas/facts,
  never generated geometry. Door open/closed/destroyed state remains a delta.
- Prefer repairs that do not change generated cell topology or stable IDs. If
  changing topology is unavoidable, increment `WorldSeed.GENERATOR_VERSION`
  deliberately, add the required migration/warning note to
  `docs/world/WORLD-CONTRACT.md`, and prove old saves are handled by the
  existing mismatch path. Never silently reinterpret old destruction keys.
- No new autoload, project setting, asset, world seed, or save payload is
  authorized. Hydrology, water materialization, biomes, geology, settlements,
  rural/industrial regions, navmesh, and upper-civilization networks remain
  later milestones.

## Out of scope and escalation

- No river, lake, hydrology, biome, geology, road-network, settlement, or
  underground implementation in this cycle.
- No new interior archetype, station gameplay, NPC/faction/economy system,
  full navigation system, camera redesign, or facade ornament pass.
- No broad destruction rewrite, collision disabling, intangible doors, player
  teleportation, hard-coded per-building route, waypoint skipping, or test
  relaxation.
- Do not absorb unrelated dirty files or rewrite history. If the real
  repository contradicts an interface above, stop and report the exact path
  and conflict to the architect instead of inventing a second milestone.
- A principal blocker may receive at most two bounded direct revisions. A third
  revision, a generator-version/save migration decision that cannot be made
  safely, or a persistent inability to prove the route must return to a fresh
  architect recovery cycle rather than expanding this pass.

## Rollback and recovery

Keep the pre-candidate `a328484` checkpoint and all unrelated user changes
intact. The builder should commit door repair, route geometry, and fixture /
regression evidence as coherent reviewable units without rewriting history.
If the candidate fails review, revert or quarantine only its implementation
commits, leave generated artifacts under `junk/` rather than deleting them,
and restore the controller through the prescribed Kanban outcome with exact
failure logs. A rollback must reproduce the known baseline honestly: citytest
and terrainmaterialtest green, cityruntime's closed-leaf failure,
walkthrough's route failures, and havoctest's clear-shot failure. Do not mark a
failure as accepted merely because rollback is available.
