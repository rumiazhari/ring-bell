# Luna Review 001 — P1-INTERIORS-TRAVERSAL revision 1

Date: 2026-08-27
Reviewer: `lunaringbell`
Verdict: **CONTINUATION AUTHORIZED; IMPLEMENTATION NOT ACCEPTED**

## Review scope

This review inspected the canonical repository at `C:/Vibe Code project/Godot Project/ring-bell`, the control-plane state, `SPEC-001.md`, commits `6c36a6c` and `14f05bc`, the current working diff, the relevant generation/streaming/door/harness scripts, and fresh suite output. No production code, tests, scenes, assets, or project settings were edited.

The current Git implementation head is `14f05bc`:

- `6c36a6c` adds only `world/generation/interior_plan.gd` (262 lines).
- `14f05bc` adds the canonical `spec["use"]` field while retaining `style["room_type"]` as a compatibility value.
- `git grep` finds no consumer of `InteriorPlan`, `InteriorStation`, `station_id`, or `interior_looted` outside the new plan file.
- The current uncommitted diff is control-plane/supervisor state (`AUTOPILOT_STATE.json`, `tools/pilot_supervisor.py`) plus the approved specification and generated cache; it contains no completed P1 materialization integration.

## Architecture and player-facing assessment

### What is correctly aligned

1. `CityPlan` now exposes a deterministic canonical residential/retail `use` value and keeps the legacy room-type field additively.
2. `InteriorPlan` is placed in the plan layer and uses seeded `WorldSeed` randomness rather than scene access or unseeded randomness.
3. Existing `Door`, chunk ownership, floor layers, and WorldState/delta architecture remain the intended extension points.
4. No new facade-only production feature was included in the reviewed P1 commits.
5. The script import/parse gate passes.

### Why the implementation is not accepted

The plan is not connected to the material layer or to gameplay. `ChunkBuilder.fill_batcher()` still calls the existing `BuildingBuilder.build()` without an interior manifest. `BuildingBuilder.build()` still emits the open-floor shell and legacy `style.room_type` furniture program; it does not emit manifest partitions or room-scoped station geometry. `ChunkBuilder.build()` still spawns only the existing exterior `Door` manifests; there is no `InteriorStation` entity and no internal-door materialization. `ChunkManager` therefore cannot persist station consumption or internal-door state.

The new validator also does not yet establish the full contract. Its small-footprint fallback marks one entry/sleeping room as `service` rather than emitting a toilet-kind room, and its connectivity check trusts the partition graph without checking that each partition is inside the boundary, adjacent to both rooms, that openings are valid, or that the resulting collision space is traversable. In the four-room grid case, the partition chain includes the room-order edge B-to-C even though those rectangles are diagonal/non-adjacent; the graph can report connected while the emitted wall/opening geometry would not be a valid shared boundary. These defects are correctable within SPEC-001 and must be covered by behavioral plan tests.

The player-facing P1 loop is therefore absent: no usable bed/rest action, no one-time retail loot action, no HUD notices for those actions, no internal doors, no room partitions, no no-teleport interior route, and no station persistence.

## Fresh verification evidence

Commands were run against the current repository through `tools/run_suite.py`:

| Gate | Result | Evidence |
|---|---|---|
| `python tools/run_suite.py --import 120` | PASS, exit 0 | `[Import] boot OK - all scripts parsed, world build skipped` |
| `python tools/run_suite.py --citytest 300` | PASS, exit 0; Windows child code 3221225477 | Ends with `finished with 0 failure(s)` but has no P1 interior-plan assertions. |
| `python tools/run_suite.py --smoke 120` | PASS, exit 0 | Ends with `finished with 0 failure(s)`; legacy mode remains intact. |
| `python tools/run_suite.py --cityruntime 300` | FAIL, exit 1 | `FAIL closed leaf blocks doorway ray`; ends with `finished with 1 failure(s)`. Other existing runtime checks pass. |
| `python tools/run_suite.py --havoctest 180` | FAIL, child code 3221225477 | `FAIL destructible prop placed with clear shot`; ends with `finished with 1 failure(s)`. |
| `python tools/run_suite.py --walkthrough 300` | FAIL, exit 1 | `FAIL walked door -> stairwell without teleport`, `FAIL climbed all 5 storeys to deck`, `FAIL descended to ground floor`, `FAIL walked out of the building`; ends with `finished with 4 failure(s)`. |

The shutdown code `3221225477` is treated as acceptable only for the runs that contain the required zero-failure line. It does not make the failing havoctest pass.

## Acceptance mapping

All ten SPEC-001 acceptance criteria remain the governing contract. Current evidence is:

1. **Not met:** no sampled residential/retail manifest validation test across the canonical and four alternate seeds.
2. **Not met:** canonical use metadata exists, but there is no integrated manifest proof for every eligible building and the fallback/required-room semantics are incomplete.
3. **Not met:** current citytest has no InteriorPlan bounds, non-overlap, adjacency/opening, graph, station-ID, or internal-door assertions.
4. **Not met:** no collision-backed partitions, room-scoped furniture integration, internal doors, or dynamic stations are materialized.
5. **Not met:** bed/rest and retail one-time loot behavior are not implemented.
6. **Not met:** walkthrough still has four failures and does not complete the no-teleport route.
7. **Not met:** cityruntime still fails the closed-door physics assertion and has no station/internal-door persistence coverage.
8. **Not met:** three required gameplay gates do not print zero failures.
9. **Currently preserved in reviewed P1 commits:** no existing smoke/soak assertion was weakened and no facade-only implementation was added. This remains a constraint for the next build, not a milestone acceptance.
10. **Not met:** the partial implementation does not have a complete Muse closeout with all acceptance results and residual-risk evidence.

## Decision and next bounded builder task

Continuation is the highest-value path; changing milestone direction would be premature. Keep `AUTOPILOT_STATE.json` at `phase: authorized_build` and do not mark the milestone accepted.

The next and only authorized builder task is:

> **Ring Bell build P1-INTERIORS-TRAVERSAL revision 1** — integrate `InteriorPlan` into the existing CityPlan/BuildingBuilder/ChunkBuilder path; fix the manifest fallback and validate bounds, adjacency/openings, graph reachability, stable IDs, and required rooms across the canonical plus four alternate seeds; emit collision-backed room partitions with clear apertures and room-scoped furniture; spawn internal `Door` and `InteriorStation` entities exactly once under the owning chunk; implement bed/rest and one-time retail storage behavior with HUD notices and namespaced WorldState persistence; preserve floor-gate visibility/collision behavior; repair the existing closed-door physics root cause and the no-teleport walkthrough; add real citytest/cityruntime assertions; then run every SPEC-001 gate. Assignee `museringbell`, two-hour runtime budget, three retries, implementation only within SPEC-001, and request Luna review on completion.

The task must demonstrate the exact outcomes below before acceptance:

- `InteriorPlan.validate()` returns no errors for sampled eligible residential and retail buildings from the canonical seed and at least four alternate seeds.
- Every generated floor has a valid bounded connected room graph, a service/toilet room, matching valid partition openings/doors, and no furniture/station route seal; small footprints use a genuinely valid reduced program.
- A real streamed residential and retail building each has collision-backed partitions, apertures, room-scoped furniture, dynamic internal doors, and at least one usable station with no ownership duplication.
- Bed interaction lowers fatigue once without changing time or position and emits a HUD notice. Retail interaction grants exactly one allowed ItemDB item, marks `interior_looted:<station_id>`, emits a HUD notice, and does not duplicate after repeat use, unload/reload, or save/load.
- Door physics preserves a solid closed leaf, a solid swung open leaf, a traversable aperture, and correct close/re-block behavior.
- `--walkthrough` completes entry, connected room traversal, every-storey climb, roof arrival, descent, exit, close, and closed-door blocking with zero failures and no in-route teleport.
- `--cityruntime` proves deterministic ownership/IDs, floor-gate presentation without collision removal, internal/exterior door behavior, station behavior, streaming, and persistence with zero failures.
- `--citytest`, `--smoke`, `--cityruntime`, `--havoctest`, and `--walkthrough` each end with `finished with 0 failure(s)`; no test semantics may be weakened.

## Out of scope

No new facade ornament, roof dressing, new archetype, new autoload, project setting, first-person camera, navigation/navmesh system, full P0 cast migration, economy/faction system, broad destruction rewrite, or test weakening is authorized. Do not hide the known havoctest failure or reclassify the cityruntime/walkthrough failures as acceptable.

## Rollback notes

Keep `5202744` as the pre-P1 implementation checkpoint and preserve the existing plan-only commits for review. If the integrated candidate cannot meet the contract, revert/quarantine only the candidate implementation commits without rewriting history, restore `phase: needs_architect` with the exact failing log, and verify citytest/smoke remain green. If generated geometry or save compatibility changes, increment the generator version deliberately and retain the old-save warning path.
