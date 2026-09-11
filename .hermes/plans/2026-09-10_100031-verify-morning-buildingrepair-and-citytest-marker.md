# Plan — Verify & finish the Sep-10 morning work (buildingrepairtest + citytest completion marker)

**Date:** 2026-09-10 10:00
**Branch:** `copilot/worldgen-fix` @ `281fee5` (9 commits ahead of origin/master)
**Status basis:** fresh `tools/out_*.txt` logs from 09:22–09:38 today; BUILD_RESULT.md says NOT COMPLETE / NOT ACCEPTED as of Sep 9 20:59; nobody owned this morning's run yet.

## Goal

Confirm this morning's Sep-10 morning work (the `--buildingrepairtest` harness and `debug/city_building_repair_test.gd` — the interior-uses/room-programs repair tests + 7 building-type captures) belongs to a coherent verified state, and decide/execute whether to commit it. One small known-good fix in scope is giving `--citytest` a proper `finished with N failure(s)` marker.

## Current context / assumptions (verified today)

- Astra's last logged job ended Sep 9 20:59 with a full streaming regression `0 failure(s)` and stop. NOT COMPLETE / NOT ACCEPTED; no commit/push.
- This morning (09:22–09:38, Sep 10) someone ran: `--import` boot OK, `--citytest` (12 PASS, **no completion marker**), `--cityruntime` (21 PASS, `finished with 0 failure(s)`), and a **new** `--buildingrepairtest` — 1971 generated buildings listed under 7 use types (`government retail residential police office workshop hospital`), `finished with 0 failure(s)`, plus 7 PNG captures in `captures/building-repair/` and prior artifacts moved to `junk/building-repair-20260910/` (per policy: files are mobed to junk, never deleted).
- The new test file `debug/city_building_repair_test.gd` is untracked and **not mentioned anywhere in BUILD_RESULT.md** — this morning's run is genuinely unattributed. No autopilots are live; only the resident `godot-ai.exe` helper was running.
- Working tree: 29 modified files (~+2536/−522), 67 untracked paths including the new test + repair scripts. All of the urban overhaul is still uncommitted on top of `281fee5`.

## Architecture / proposed approach

Three reads → one test fix → one commit decision. The core open question is only *provenance + commit boundary*: (a) what exactly the new test asserts, (b) whether `--citytest` truly finished (its log ends right after overlap validation with no marker — likely a truncation or a harness flag mis-splice in the shared `tools/run_suite.py`), and (c) whether the user wants any of this committed, since the standing rule is: only commit/push on explicit ask.

## Step-by-step tasks

All commands from `C:/Vibe Code project/Godot Project/ring-bell/`. Godot 4.7.2 at system PATH; suites run via `python tools/run_suite.py --<flag> <timeout>`.

### Phase 1 — Read-only verification (~no-op risk)

1. **Audit the new test file** — read all of `debug/city_building_repair_test.gd` (210 lines; the first 60 show a `--city-plan-check` branch asserting every generated building has ≥10×14 footprint and that `InteriorPlan.ROOM_PROGRAMS` all appear in city manifest, plus per-use `InteriorPlan.build_for_building` validity/determinism/furniture checks).
   - Command: `cat debug/city_building_repair_test.gd | head -210`
   - Verify each check string in the code matches the 7 captures' names (`captures/building-repair/{government,hospital,office,police,residential,retail,workshop}.png`).
   - Expected: no assertion silently disabled; `check()` increments `failures` like other suite tests.

2. **Trace where the test is wired up** — find the flag registration.
   - Command: `grep -R "buildingrepairtest" world/ debug/ project.godot tools/`
   - Confirm: `world/main.gd` has a `--buildingrepairtest` branch (it must be among the 29 modified files) and `tools/run_suite.py` maps it to `tools/out_buildingrepairtest.txt` with a ~120–180 s timeout.

3. **Re-run `--citytest` solo to settle the missing marker** (~150 s).
   - Command: `cd "C:/Vibe Code project/Godot Project/ring-bell" && python tools/run_suite.py --citytest 240 2>&1 | tail -4`
   - Expected: `finished with N failure(s)` as the last CityTest line. Compare `N` against the 12 PASS lines we already saw; if the run genuinely dies mid-way it will be a post-pass crash, not a logic failure. Git-bash; forward-slash paths only.

### Phase 2 — Completion-marker hygiene fix (small, safe)

4. **Fix `--citytest` exit marker if missing.** In `debug/city_test.gd` (look for the class with `[CityTest] PASS` prints) add at end of `_run_all`:
   ```gdscript
   print("[CityTest] finished with %d failure(s)" % failures)
   ```
   This is consistent with `[CityRuntime]`, `[BuildingRepair]`, and all other suite tests. If the marker already exists, skip — the 09:31 truncation was likely just a short timeout window during the morning batch and Phase 1 step 1.3 will prove it.
   - Verify: re-run `python tools/run_suite.py --citytest 240 2>&1 | tail -2` → new last line must be `[CityTest] finished with N failure(s)`.

5. **Re-run `--buildingrepairtest` once to reproduce this morning's green result with the current working tree** (~30 s).
   - Command: `python tools/run_suite.py --buildingrepairtest 120 2>&1 | tail -3`
   - Expected identical outcome: `[BuildingRepair] finished with 0 failure(s)`.

### Phase 3 — Report (no commit unless asked)

6. **Summarize findings in this plan's follow-up note.** If Phase 1–2 all pass, report:
   - The Sep-10 morning work did not regress: import/citytest/cityruntime/buildingrepairtest all green.
   - The completion-marker hygiene fix landed (or was found unnecessary).
   - No commit/push was made — that is a user decision per policy.

## Tests / validation

- `python tools/run_suite.py --citytest 240` → last CityTest line: `finished with 0 failure(s)` (tail of previous log had 12 PASS and 0 FAIL, so 0 is expected).
- `python tools/run_suite.py --buildingrepairtest 120` → last line: `[BuildingRepair] finished with 0 failure(s)`.
- Any run whose last line is NOT that marker counts as unresolved, not pass.

## Risks

- `--citytest` full re-run is slow (~150 s) with possible GPU contention if any sibling Godot process resurrects — never launch while one is running (`tasklist | grep -i Godot`, only the resident `godot-ai.exe` may be present).
- Godot exit code is sometimes `3221225477` after success — judge by the printed `finished with N failure(s)` line, not exit code.
- Committing is explicitly out of scope here: both Astra's tree state and the new repair test have a standing no-commit-without-ask rule; the plan's only write is step 4's one-line print if needed.
