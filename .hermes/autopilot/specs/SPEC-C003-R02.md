# SPEC-C003-R02 — Czech Rural Mosaic Revision 02: Deterministic Door Close

Status: REVISION-READY FOR CONTROLLER (bounded direct revision, round 02/02)
Milestone ID: `P3.1-RURAL-MOSAIC`
Owner: `lunaringbell` (architecture/review); `museringbell` (implementation)
Revision of: `SPEC-C003-R01.md` SHA `a5ed9d6cdc901fb88e937741707a8faac356a175a020199f218198329ae91641`
State revision: 2

## Revision rationale (principal blocker)

P3.1 implementation at `dbbe18f` is principally correct for the rural mosaic and for R01's two calibration goals: deterministic biome/geology (GeologyPlan+BiomePlan pure, handling negative coords, vocab subset, contiguity, budgets 81/128 and <=48/12/6 ACTIVE-only 9 colliders, streaming via private WorldPlan with `t_biome_gen/t_biome_mat`, GEN2 2 preserved, hydro CX/width untouched) and docs (ARCHITECTURE, WORLD-CONTRACT §12, DEVELOPMENT 9th gate + ACTIVE-only 36 peak + `t_biome_*` committed). Reviewer independently re-ran on canonical root (Godot 4.7.2, Windows 11):

- `--terrainmaterialtest 300` now 0 failures (188s reviewer, save caps 250k/+150k, `save has no terrain field` and `save records have no terrain payload` still strict, 289/512 seam and ACTIVE budgets intact) — R01 AC1 closed.
- `--biometest 300` 0 failures, `--hydrotest 300` 0, `--citytest 300` 0, `--walkthrough 360` 0 (honest 5-storey climb, door reports CLOSED then blocks again), `--havoctest 240` 0, `--smoke 180` 0 — P3.1 mosaic still green.
- `--cityruntime 360` still flakes: reviewer observed 177s FAIL `door closes via API` with `dbbe18f`'s 3.0s + 3 physics frames + 0.5s retry, then a second 360 run PASS, i.e. 1/2 deterministic. Previous R01 log showed same 1/2 pattern with 2.6+0.6 vs 2.5+0.5. The 3.0s wait alone is not sufficient.

Root cause: `Door` physics. `door.close()` drives the `RigidBody3D Leaf` via `HingeJoint3D` with `DRIVE_TICKS_LIMIT 90` and stall/bounce logic: a leaf whose sweep is blocked until `DRIVE_TICKS_LIMIT` bounces OPEN (`_bounce_open()` sets `state=OPEN`). The cityruntime harness calls `close()` while the player capsule remains near the doorway aperture. Even though the leaf swings INTO the building (not outward), the capsule's collision with the leaf or its `0.5 m` width plus `6 inflight` streaming contention can pin the leaf past `DRIVE_TICKS_LIMIT`, causing it to bounce open and `is_open()` remains true after the wait. The walkthrough harness does not flake because it mirrors the real player procedure: it steps the player back (`-face_dir*(1.8+attempts)`) and retries up to 4 times with physics drain before asserting `CLOSED`. The R01 patch added wait+frames but did not move the player away nor retry with step-back, so the leaf remains intermittently pinned under load.

Direct revision 02 is required because `SPEC-C003-R01` AC2 (cityruntime 0 failures, 360 allowed) is still violated. This is the last allowed direct revision (round 2 of 2). The fix is strictly in `debug/city_runtime_test.gd` door-close block, mirroring walkthrough's proven retry, without weakening the strict leaf-identity / no-RID exclusion checks, without touching `world/buildings/door.gd`, `world/streaming/chunk_manager.gd`, or any plan/builder.

This is a bounded repair, not a new milestone: no new biome vocab, no trench, no road/settlement, no shader, no GENERATOR_VERSION bump, no new asset. Only the harness door-close guard and a second consecutive proof.

## Player-facing objective (unchanged thin slice)

Same as C003/R01: Bohemian mosaic beyond the 350 m basin — floodplain/wet meadow along the Vltava, arable fields with hedgerow parcels, pasture/orchard, contiguous deciduous/mixed upland forest, sparse rocky/quarry outcrops — streamed at 9x9/81/128 ACTIVE-only so the player gains landmark-driven exploration, cover and route choices, and a foundation for farms/villages/roads/quarries. No city archetype, road graph, bridge mesh, trench, underground, swimming, modular assets, or toon shader rework.

## Scope (bounded to principal fix)

### 1. CityRuntime door-close guard — mirror walkthrough (no assertion weakening)

In `debug/city_runtime_test.gd` around the `door closes via API` block (currently `_wait(3.0)` + 3 physics frames + `0.5` retry), replace with a deterministic walkthrough-mirroring guard:

- Compute the door's inward normal `inw` and doorway center `dpos` already available (`dm.position`, `dm.yaw`). Before `door.call("close")`, ensure the player is clear of the sweep: move the player 2.2 m opposite `inw` plus 0.15 m up (`Vector3(dpos.x,0.15,dpos.z) - inw*2.2`) via `player.global_position = away` (same technique walkthrough uses for its final close) or via a 0.6 s `request_move` steer away — either is acceptable if it places the capsule outside the leaf's 0.5 m sweep before close. If the player is a `Survivor` with `request_move`, prefer direct `global_position` set for determinism in headless (no navmesh); do not add new collision shapes.
- Then call `door.call("close")` and implement a retry loop matching `debug/walkthrough_probe.gd` lines 196-205: `attempts 0..3`, each attempt `await _wait(0.9)` + `await get_tree().physics_frame` x2, check `not door.call("is_open")` and break on true; on false, step the player further back `dpos - inw*(1.8+attempts)` (or `2.2+attempts*0.4`) and re-issue `close()` before next iteration. Keep the strict `is_open()` check (leaf identity not collided) as the gate; do not add RID exclusion, do not read `_open_angle` to fake a close, do not weaken the `closed leaf blocks doorway` / `open leaf clear without RID` / `swung collidable` checks.
- Keep the existing 2.0 s open wait; do not shorten it. The total close wait per attempt 0.9 s + 2 frames is within the 3.0 s budget previously, but the loop allows up to ~3.6 s in the worst retry, still under cityruntime's 60.0 s door section timeout and well under 360 s total — this is acceptable and mirrors walkthrough's 4x0.9.
- Guard any `leaf = door.call("_pivot_ref")` ray with `is_instance_valid(leaf) and leaf.is_inside_tree()` already used elsewhere; do not add new guard beyond that.

Do not edit `world/buildings/door.gd`, `world/streaming/chunk_manager.gd`, `world/generation/*`, `world/main.gd`, or any other harness. No test weakening: `FAIL` remains `FAIL`, no pending/inflight accepted as completed.

### 2. Streaming pipeline (no new feature)

Keep `world/streaming/chunk_manager.gd` at `MAX_INFLIGHT 6` and `STREAM_UPDATE_INTERVAL 0.1` with shared `WorldPlan(seed)` per worker, `BoxShape` single collider per biome chunk, private plans + `plan_mutex` already in `dbbe18f`. No trench carve, no road graph. Verify `ChunkManager.save_state()` still returns only `records` and `debug_lines()` contains `t_biome_gen`/`t_biome_mat`.

### 3. Docs closeout (no edit needed, just commit preservation)

`ARCHITECTURE.md`, `docs/world/WORLD-CONTRACT.md §12`, `DEVELOPMENT.md` (9th gate `--biometest`/`--biomematerialtest`, ACTIVE-only biome 81/128, `t_biome_*`, `district_hint`, bank-ribbon) are already correct at `dbbe18f` and must be preserved. Do not rewrite broader architecture. No windowed PNG required for this revision: keep existing synthetic `.hermes/autopilot/reports/SPEC-C002-windowed.*` as placeholder and carry the authentic 1200x720 windowed CITY run with biome tint+proxies as a single deferred finding for the next related cycle. Do not block this revision on headless `--shot` dummy renderer.

## Construction sequence

### Phase 0 — Protect baseline and prove failure

1. Preserve dirty files, no reset/clean, junk/ keep.
2. Re-run failing gate to confirm flake: `python tools/run_suite.py --cityruntime 360` (expect intermittent 1 failure `door closes via API` on at least 1 of 2 runs; reviewer observed 177s FAIL then PASS). Capture `tools/out_cityruntime.txt`. Also confirm `python tools/run_suite.py --terrainmaterialtest 300` is still 0 failures (188s). Do not edit door guard before proving the current 3.0s patch still flakes at least once in two consecutive runs.

### Phase 1 — Harness guard

1. Patch `debug/city_runtime_test.gd` door-close block as above, commit as `fix(P3.1): deterministic door close via walkthrough step-back retry`.
2. Proof: run `python tools/run_suite.py --cityruntime 360` twice consecutively; both must end with `finished with 0 failure(s)`. If either flakes, adjust the step-back distance (2.2 m ±0.4 per retry) and re-prove two consecutive passes — do not loop more than 4 attempts, do not relax assertions. Capture both logs.

### Phase 2 — Regression and handoff

1. Run full required matrix from canonical root (judge by marker `finished with 0 failure(s)`, 322... with marker is pass):
```
python tools/run_suite.py --import 120
python tools/run_suite.py --biometest 300
python tools/run_suite.py --hydrotest 300
python tools/run_suite.py --citytest 300
python tools/run_suite.py --terrainmaterialtest 300
python tools/run_suite.py --cityruntime 360   # twice consecutively, both 0 failures; document both elapsed
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --havoctest 240
python tools/run_suite.py --smoke 180
```
Every command must end with `finished with 0 failure(s)`. Timeout/missing marker is not a pass. Two consecutive cityruntime passes are required to prove determinism; a single pass after a prior flake is not sufficient for this revision.
2. Commit coherent verified unit (single harness commit), include changed file, commit ID, both cityruntime logs, and reference windowed deferred. Do not edit `AUTOPILOT_STATE.json`, do not create reviewer card, do not broaden scope.

## Explicit acceptance criteria (for this revision)

1. `--terrainmaterialtest` finishes with `finished with 0 failure(s)` (the two save-delta checks remain <250k / +150k; `save has no terrain field`, `save records have no terrain payload`, and `save existing records unchanged` still pass; 289/512 seam and ACTIVE budget assertions unchanged).
2. `--cityruntime` finishes with `finished with 0 failure(s)` **twice consecutively** at 360 s (closed leaf blocks, open clears without RID exclusion, swung collidable, door closes via API passes deterministically after player step-back + physics drain + retry, far ring streaming and destruction survival intact; no position-write cheat beyond the single initial street drop-off and the bounded step-back for the door sweep).
3. Full 9-gate matrix from canonical root finishes with 0 failures each: `--import` plus `--biometest`, `--hydrotest`, `--citytest`, `--terrainmaterialtest`, `--cityruntime` (two consecutive 360s), `--walkthrough`, `--havoctest`, `--smoke` (322... with marker is pass; ObjectDB inside_tree noise guarded where feasible but not masking).
4. `DEVELOPMENT.md`, `ARCHITECTURE.md`, `docs/world/WORLD-CONTRACT.md §12` remain as at `dbbe18f` for ACTIVE-only biome and `t_biome_gen/t_biome_mat` alongside water/terrain, with `+ biome` streaming paragraph and `--biometest` contract, folding C001/C002 deferred docs. The windowed 600-900 m east walk with biome tint + hedgerow/tree proxies remains deferred to the next related design (not a blocker) and is recorded as a single deferred finding.

## Required automated verification (for this revision)

Same matrix as Phase 2, run via `tools/run_suite.py` only (direct `godot --headless` not substitute). Judge by harness marker `finished with 0 failure(s)` not exit code. The gate that matters for this revision's determinism proof is two consecutive `--cityruntime 360` runs, each with 0 failures.

## Ordinary player-facing proof (still deferred, not blocking)

The next full milestone will archive a normal windowed CITY run (1200x720, not --shot) showing WASD/E door swing, stair climb to roof, F3 with active biome + `t_biome_gen/t_biome_mat` alongside water/terrain, then walk 600-900 m east to river valley showing continuous biome tint field->wet meadow->floodplain->teal water 4a7a94 bank 9 m floodplain 26 m with hedgerow/tree proxies without seam cracks/flicker. This revision does not require a new PNG to pass; it must carry the deferred finding forward.

## Performance, persistence, compatibility

- Keep 64 m chunks, ACTIVE <=1 WARM <=2 UNLOAD 3, one merged city mesh+Static per chunk ACTIVE-only, terrain 17x17 289/512 1 collider 9 active, water 9x9 81/128 1 collider wet 9 active, biome overlay 9x9 81/128 + MultiMesh <=48/12/6 1 collider max 9 active biome = 36 peak. Per-chunk biome_gen_ms worker + biome_mat_ms main within FRAME_BUDGET_MS 12. No 2D grid, no per-waypoint bodies, no navmesh.
- Saves still seed/version/discovery/deltas only, no generated biome/water/terrain geometry; GEN2 stays 2, additive outside 350 core, no trench.
- No new autoload/project setting/large asset.

## Out of scope

No hierarchical road/rail graph, settlement/village placement, trench/dike carve through 350, street bridge mesh, lake/reservoir materialization beyond hydrology placeholder, swimming/buoyancy, vertical survivor network/caves, full shader water/biome textures, broad building refactor, teleport/intangible collision, per-chunk hard-coded hacks, test relaxation beyond the harness step-back guard above. Do not absorb unrelated dirty files or rewrite history. If repository contradicts interface, stop and report to architect.

## Rollback

Keep `e32f0aa` checkpoint, `023070d` candidate, and `dbbe18f` R01 threshold/doc commit. If this revision fails, revert only its harness commit, keep artifacts under junk/, restore controller via Kanban outcome with failure logs. Rollback must reproduce `dbbe18f` baseline: `terrainmaterialtest` 0, `biometest/hydro/city/walkthrough/havoc/smoke` 0, `cityruntime` still flakes 1/2. Do not mark failing door-close as accepted because rollback exists.

Execution note: preserve dirty files and WIP, never git reset --hard / clean -fd / delete files; move artifacts to junk/. TDD RED must show cityruntime flaking before GREEN two-consecutive passes.
