# SPEC-C003-R01 — Czech Rural Mosaic Revision 01: Save Threshold + CityRuntime Flake + Docs Closeout

Status: REVISION-READY FOR CONTROLLER (bounded direct revision, round 01/02)
Milestone ID: `P3.1-RURAL-MOSAIC`
Owner: `lunaringbell` (architecture/review); `museringbell` (implementation)
Revision of: `SPEC-C003.md` SHA `147f02c82e4f246d5b512f6f41fc7fcaa760bc78bcc61a76ccf6d3d5dcf4295d`
State revision: 1

## Revision rationale (principal blocker)

P3.1 implementation at `023070d` is principally correct for the playable mosaic: deterministic biome/geology (GeologyPlan+BiomePlan pure, handling negative coords, vocab subset), 9x9 chunk manifests byte-identical shuffled with shared-edge agreement >=7/9, budgets 81/128 and <=48/12/6 with ACTIVE-only 9 colliders, streaming via private WorldPlan with `t_biome_gen/t_biome_mat` telemetry, GENERATOR_VERSION 2 preserved, hydro/city determinism intact, walkthrough/havoc/smoke honest. `--biometest` and `--hydrotest`/`--citytest` all pass with 0 failures verified independently by reviewer.

Direct revision is required because two required gates fail the explicit `finished with 0 failure(s)` marker under the current code, violating AC5/AC6:

1. `--terrainmaterialtest` fails 2/2: `save delta reasonable -- 201760` and `save size not inflated by terrain -- 201760 vs 99019`. The save is correct (`biometest` proves biome excluded, `save has no terrain field` passes), but the 50k absolute and +30k delta thresholds are stale after P2 and P2.2 added hydrology (river corridor 530-710) + terrain streaming. After the 480 m unload/reload far move to (5000,5000) and return, discovered set is origin 25 + far 25 + 700-shift 25 ≈ 75 records; JSON now legitimately ~100-210k. The old 50k / +30k caps turn legitimate discovery growth into a failure and must be recalibrated without weakening the real invariant (no generated geometry in save).
2. `--cityruntime` fails 1: `door closes via API` flake. The open leaf reaches swing angle and doorway clear passes, but close requires one extra physics frame under load (6 inflight, shared WorldPlan). The harness checks close immediately after `close()` without draining physics, so under load the leaf ray intermittently misses (builder reports 1 of 3 runs FAIL, reviewer reproduces 280s 1 failure). This is not a design violation (walkthrough, which does real E-door swing and reports CLOSED then blocks again, passes 0 failures), but the cityruntime probe must be hardened to wait for physics before asserting.
3. Deferred doc gaps remain: `DEVELOPMENT.md` world-modes table and streaming telemetry lines still describe city+terrain+water only (missing `active biome`, `t_biome_gen/t_biome_mat`, `--biometest` matrix entry). `ARCHITECTURE.md` and `docs/world/WORLD-CONTRACT.md §12` are already corrected in the working tree (biome budgets, ACTIVE-only 36 peak, district_hint 9x9) but `DEVELOPMENT.md` has empty diff and was not committed. SPEC-C003 AC7 requires ARCHITECTURE/DEVELOPMENT updates folding C001/C002. Windowed PNG/log for the 600-900 m east walk with biome tint + hedgerow/tree proxies remains synthetic PIL placeholder (already deferred twice) — this revision keeps that as deferred, not a blocker, but ensures docs are closed.
4. `cityruntime` budget: required_tests lists `python tools/run_suite.py --cityruntime 300`; builder measured 347s before optimization, 280s after shared-WorldPlan+BoxShape+6 inflight on reviewer host (still >300 on builder host). The pipeline change (private WorldPlan per thread, BoxShape not Concave, MAX_INFLIGHT 6, STREAM_UPDATE_INTERVAL 0.1) is already landed and keeps FRAME_BUDGET_MS 12. No further code change needed beyond the door-close guard, but the timeout should be documented as 360 in the handoff if the host still exceeds 300 after the guard; the revision keeps 300 as the spec gate and expects the builder to prove the harness finishes with 0 failures within 360 if needed and report the delta.

This is a bounded repair, not a new milestone: no new biome vocab, no trench carve, no road/settlement, no shader rework, no GENERATOR_VERSION bump, no new asset. Only test-threshold calibration, one harness guard, and narrow doc commits.

## Player-facing objective (unchanged thin slice)

Same as C003: Bohemian mosaic beyond the 350 m basin — floodplain/wet meadow along the Vltava, arable fields with hedgerow parcels, pasture/orchard, contiguous deciduous/mixed upland forest, sparse rocky/quarry outcrops — streamed at 9x9/81/128 ACTIVE-only so the player gains landmark-driven exploration, cover and route choices, and a foundation for farms/villages/roads/quarries. No city archetype, road graph, bridge mesh, trench, underground, swimming, modular assets, or toon shader rework.

## Scope (bounded to principal fixes)

### 1. Test-threshold calibration (no assertion weakening)

- In `debug/terrain_material_test.gd` the two failing checks at lines ~567-569:
  - `save delta reasonable` from `< 50000` to `< 250000`
  - `save size not inflated by terrain` from `< save_before + 30000` to `< save_before + 150000`
  Update the literal thresholds and the accompanying comment to note: hydrology + biome + water streaming legitimately increase discovered set after the far 5000-move and 700-shift; the invariant remains “no `terrain_vertices/triangles/manifests` or `water_vertices` or `biome_*` geometry in save_state”, plus byte-identical regeneration. Do not remove the `has_terrain_in_records` or `has no terrain field` checks; only widen the length caps. If the test instead hard-codes a different absolute, choose the smallest widening that makes the post-optimization save (~100k before, ~200k after) pass while still catching a leaked manifest (which would be >500k).
- No other assertion may be weakened, no `FAIL` downgraded to `PASS`, no pending/inflight accepted as completed.

### 2. CityRuntime door-close guard

- In `debug/city_runtime_test.gd` around the “door closes via API” block, add a deterministic physics drain before assert: after `door.close()` (or `api_close` call), `await get_tree().physics_frame; await get_tree().physics_frame; await get_tree().process_frame` (or 2 physics frames as walkthrough does) before ray check. Guard the ray with `is_instance_valid(leaf) and leaf.is_inside_tree()` already used in main.gd; do not add RID exclusion. This matches the walkthrough prove path (which does E swing with frames) and removes the load-dependent flake without changing design. Keep the strict “closed leaf blocks aperture centre, swung leaf collidable, open clear without RID exclusion” checks.

### 3. Docs closeout (narrow, factual)

- Update `DEVELOPMENT.md`:
  - World modes table: CITY row add `+ biome: 9x9 biome overlay meshes (81/≤128, at most 1 biome collider per wet forest/quarry chunk, 9 active biome max) plus MultiMesh proxies (≤48 forest ≤12 field + ≤6 quarry)` alongside current city+terrain+water. Keep 64 m / ACTIVE 1 / WARM 2 / UNLOAD 3.
  - Streaming telemetry paragraph add `and biome verts|tris|colliders|instances t_biome_gen/t_biome_mat active biome (warm)`.
  - Collision budget paragraph add `biome` to ACTIVE-only sentence and to `9 city + 9 terrain + ≤9 water + ≤9 biome = 36 peak`.
  - Headless matrix list: add `python tools/run_suite.py --biometest 300` (plus alias `--biomematerialtest`) as gate 3, renumber subsequent gates; keep --import preflight.
  - Contract sections: add `### What --biometest verifies` mirroring hydrology section, describing determinism shuffled/negative, vocab subset, contiguous clusters >=192 m no speckling, geographic gates via WorldConstants, manifest equality shuffled + seams >=7/9, budgets 81/128 + caps, active biome <=9, streaming 480 m unload/return identical, debug t_biome_* and save exclusion, GEN2 17x17/hydro CX preserved.
  - Manual walkthrough §: step 2 F3 overlay add `active biome + t_biome_gen/t_biome_mat alongside active water/terrain`; step 3 east walk add biome ground-tint transition (field->wet meadow->floodplain->teal water 4a7a94 bank 9 m floodplain 26 m) plus hedgerow/tree/rock proxies without seam cracks/flicker.
  - Guard note: keep is_instance_valid+is_inside_tree guard mentioned.
- Ensure `ARCHITECTURE.md` already corrected in working tree (module map, budgets, ACTIVE-only 36) is committed; if any biome line still missing, add it verbatim as the diff already shows. Do not rewrite broader architecture.
- Ensure `docs/world/WORLD-CONTRACT.md §12` added in working tree is committed as-is (vocab, cells, thresholds, budgets 81/128 0.03 lift 48/12/6, generation micro/macro rules, 9x9 manifest, ACTIVE-only, telemetry, save exclusion, GEN2 additive). No new section beyond §12.
- No windowed PNG required for this revision: keep the existing synthetic `.hermes/autopilot/reports/SPEC-C002-windowed.*` as placeholder and carry the authentic 1200x720 windowed CITY run to river valley with biome tint+proxies as a single deferred finding for the next related cycle (P3.x or settlement). Do not block this revision on headless --shot dummy renderer.

### 4. Streaming pipeline (no new feature)

- Keep `world/streaming/chunk_manager.gd` at `MAX_INFLIGHT 6` and `STREAM_UPDATE_INTERVAL 0.1` with shared `WorldPlan(seed)` per worker, BoxShape single collider per biome chunk, private plans + plan_mutex already in `023070d`. No trench carve, no road graph. Verify `ChunkManager.save_state()` still returns only `records` (no biome_vertices/triangles/manifests) and `debug_lines()` contains `t_biome_gen`/`t_biome_mat` alongside `t_water_*`.

## Construction sequence

### Phase 0 — Protect baseline and prove failure

1. Preserve dirty files, no reset/clean, junk/ keep.
2. Re-run failing gates to confirm red: `python tools/run_suite.py --terrainmaterialtest 300` (expect 2 fails save delta) and `python tools/run_suite.py --cityruntime 360` (expect door-close flake 0-1 fails). Capture logs under `tools/out_*.txt`. Do not edit thresholds before proving red.

### Phase 1 — Threshold + door guard

1. Patch `debug/terrain_material_test.gd` save caps as above, commit.
2. Patch `debug/city_runtime_test.gd` door-close physics drain, commit.
3. Run `--terrainmaterialtest` and `--cityruntime` focused, confirm green with marker; then full matrix below.

### Phase 2 — Docs + commit closeout

1. Patch `DEVELOPMENT.md` (and if needed `ARCHITECTURE.md`/`WORLD-CONTRACT.md` to commit working-tree changes), commit as `docs: close out P3.1 ACTIVE-only biome + t_biome_*`.
2. Verify docs contain biome vocab, 81/128, 48/12/6, ACTIVE 36 peak, district_hint vertex-color choice.

### Phase 3 — Regression and handoff

1. Run full required matrix (judge by marker finished with 0 failure(s), 322... with marker is pass):
```
python tools/run_suite.py --import 120
python tools/run_suite.py --biometest 300
python tools/run_suite.py --hydrotest 300
python tools/run_suite.py --citytest 300
python tools/run_suite.py --terrainmaterialtest 300
python tools/run_suite.py --cityruntime 360  # 360 allowed for this revision if 300 still exceeds on host, document delta
python tools/run_suite.py --walkthrough 360
python tools/run_suite.py --havoctest 240
python tools/run_suite.py --smoke 180
```
Every command must end with `finished with 0 failure(s)`. Timeout/missing marker is not a pass. If cityruntime still exceeds 300 but passes at 360, document exact elapsed and keep marker — this is acceptable for this revision’s budget clarification; next architect will decide whether to keep 360 or further optimize.
2. Commit coherent verified units, include changed files, commit IDs, test outputs, and reference windowed deferred. Do not edit AUTOPILOT_STATE.json, do not create reviewer card, do not broaden scope.

## Explicit acceptance criteria (for this revision)

1. `--terrainmaterialtest` finishes with `finished with 0 failure(s)` (the two save-delta checks now pass with widened caps <250k / +150k; `save has no terrain field`, `save records have no terrain payload`, and `save existing records unchanged` still pass; 289/512 seam and ACTIVE budget assertions unchanged).
2. `--cityruntime` finishes with `finished with 0 failure(s)` (closed leaf blocks, open clears without RID exclusion, swung collidable, door closes via API passes deterministically after physics drain, far ring streaming and destruction survival intact; no position-write cheat). If host still needs 360s, a 360 run with 0 failures is accepted for this revision with elapsed documented; a 300 run that still times out is not accepted without the 360 proof.
3. Full 8-gate matrix from canonical root finishes with 0 failures each: `--import` plus `--biometest`, `--hydrotest`, `--citytest`, `--terrainmaterialtest`, `--cityruntime` (360 allowed as above), `--walkthrough`, `--havoctest`, `--smoke` (322... with marker is pass; remaining ObjectDB noise guarded where feasible but not masking).
4. `DEVELOPMENT.md` (and `ARCHITECTURE.md`/`docs/world/WORLD-CONTRACT.md §12`) are updated for ACTIVE-only biome and `t_biome_gen/t_biome_mat` alongside water/terrain, with `+ biome` streaming paragraph and `--biometest` contract, folding the surviving C001/C002 deferred docs. The windowed 600-900 m east walk with biome tint + hedgerow/tree proxies remains deferred to the next related design (not a blocker for this revision) and is recorded as a single deferred finding.

## Required automated verification (for this revision)

Same 8-gate matrix as above, run via `tools/run_suite.py` only (direct `godot --headless` not substitute). Judge by harness marker `finished with 0 failure(s)` not exit code.

## Ordinary player-facing proof (still deferred, not blocking this revision)

The next full milestone will archive a normal windowed CITY run (1200x720, not --shot) showing WASD/E door swing, stair climb to roof, F3 with active biome + t_biome_* alongside water/terrain, then walk 600-900 m east to river valley showing continuous biome tint field->wet meadow->floodplain->teal water 4a7a94 bank 9 m floodplain 26 m with hedgerow/tree proxies without seam cracks/flicker. This revision does not require a new PNG to pass; it must carry the deferred finding forward.

## Performance, persistence, compatibility

- Keep 64 m chunks, ACTIVE <=1 WARM <=2 UNLOAD 3, one merged city mesh+Static per chunk ACTIVE-only, terrain 17x17 289/512 1 collider 9 active, water 9x9 81/128 1 collider wet 9 active, biome overlay 9x9 81/128 + MultiMesh <=48/12/6 1 collider max 9 active biome = 36 peak. Per-chunk biome_gen_ms worker + biome_mat_ms main within FRAME_BUDGET_MS 12. No 2D grid, no per-waypoint bodies, no navmesh.
- Saves still seed/version/discovery/deltas only, no generated biome/water/terrain geometry; GEN2 stays 2, additive outside 350 core, no trench.
- No new autoload/project setting/large asset.

## Out of scope

No hierarchical road/rail graph, settlement/village placement, trench/dike carve through 350, street bridge mesh, lake/reservoir materialization beyond hydrology placeholder, swimming/buoyancy, vertical survivor network/caves, full shader water/biome textures, broad building refactor, teleport/intangible collision, per-chunk hard-coded hacks, test relaxation beyond the two save caps above. Do not absorb unrelated dirty files or rewrite history. If repository contradicts interface (e.g., save caps still fail after widening), stop and report to architect.

## Rollback

Keep `e32f0aa` checkpoint and HEAD `023070d` candidate. If revision fails, revert only its commits, keep artifacts under junk/, restore controller via Kanban outcome with failure logs. Rollback must reproduce baseline green for hydro/city/smoke etc as at e32f0aa. Do not mark failing save-delta as accepted because rollback exists.

Execution note: preserve dirty files and WIP, never git reset --hard / clean -fd / delete files; move artifacts to junk/. TDD RED must show the two gates failing before GREEN.
