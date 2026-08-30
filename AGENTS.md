# Ring Bell Agent Rules

## Canonical checkout

`C:/Vibe Code project/Godot Project/ring-bell`

Never use a OneDrive copy.

## Permanent Hierarchy (repository is recoverable state)

1. `VISION.md` — permanent product charter, highest truth. Preserve core vision; never casually change.
2. `.hermes/autopilot/GRAND_PLAN.md` — CURRENT finite strategic plan. When materially complete, Architect archives to `.hermes/autopilot/history/GRAND_PLAN_<generation>.md` and generates next from VISION + Git HEAD + actual game/tests/debt.
3. `.hermes/autopilot/AUTOPILOT_TASK.md` — ONLY current implementation assignment. Exactly ONE bounded task at a time. No task IDs, no Kanban, no cycle numbers, no external orchestration DB. Fingerprint is SHA256 of file content.
4. `.hermes/autopilot/BUILD_RESULT.md` — Builder overwrites after every attempt with: fingerprint, HEAD before/after, summary, changed files, tests, pass/fail, player-facing verification, limitations, completion belief, blocker. Architect verifies against actual repo, not prose.

Archived obsolete Kanban/controller state: `junk/autopilot-kanban-v2-archive-20260831-010858/` (89 files + 53KB/42KB board exports). Never use `AUTOPILOT_STATE.json`, decision JSON, Kanban boards, or old controller scripts — they are archived.

## Read First

Every autonomous role must read:
1. `VISION.md`
2. `.hermes/autopilot/GRAND_PLAN.md`
3. `.hermes/autopilot/AUTOPILOT_TASK.md`
4. `.hermes/autopilot/BUILD_RESULT.md` (previous result if any)
5. `ARCHITECTURE.md`, `DEVELOPMENT.md`, and relevant source/tests
6. current Git status/history and actual playable game

Repository is truth. No hidden in-memory state required.

## Hard Role Boundary

- `architect-autopilot` is architect/planning/review ONLY. May read VISION/GRAND_PLAN/repo/tests/game, decide next dependency, write exactly ONE bounded `AUTOPILOT_TASK.md`, review Builder vs repo, issue bounded correction, determine Grand Plan completion, generate next Grand Plan, archive completed plans, send Telegram. **Must NEVER edit production code, game scenes/assets/tests/project settings.**
- `builder-autopilot` is builder. Reads VISION/GRAND_PLAN/TASK/ARCHITECTURE/DEVELOPMENT/code/tests/Git, implements ONLY current `AUTOPILOT_TASK.md`, owns production code/tests/scenes/assets. TDD where applicable, never weaken tests to get green, run all relevant suites via `tools/run_suite.py`, player-facing verification, preserve unrelated work, commit+push to `origin/master`, write `BUILD_RESULT.md`, send Telegram. **Must NEVER select roadmap work or edit planning artifacts beyond BUILD_RESULT.**
- Both use `muse-spark-1.2-contributor` via `opencode-go` with `agent.reasoning_effort=max` (ultra). Meta data-training prompt: answer `y`.
- One writer only: Builder holds `.hermes/autopilot/builder.lock` (PID/timestamp/host, stale 30m recovery). Architect modifies planning only.
- After every accepted milestone: Builder pushes and both roles notify Telegram `518829299` with concise human emoji summary, but Telegram is observability only — never lifecycle state, never blocking.

## Construction Discipline

- Bounded milestones from `VISION`+`GRAND_PLAN`+`ACTUAL REPO` prioritizing player value/dependency/correctness, not novelty.
- One active writer, strict TDD, run every gate in task via `tools/run_suite.py`, judge by `finished with 0 failure(s)` marker (Windows 3221225477 with marker = pass).
- Never weaken assertions, hide errors, accept pending work as done, or teleport when traversal required.
- Preserve unrelated dirty/WIP files. Never reset/clean checkout. Never delete; move to `junk/`.
- Commit coherent verified construction; push to `origin/master`; record honest BUILD_RESULT.

## Review Discipline

- Architect inspects actual repo/diff/commits/tests/game behavior, not prose alone.
- Minor findings deferred to later related milestone. Only principal design conflicts justify bounded revision.
- Max 2 direct revisions; after cap, fresh recovery cycle not third patch.
- No Kanban parent dependencies; no duplicated external machine state.

## Recovery (repository-derived, stall-resistant)

- After restart/crash/timeout/interrupt, either agent reconstructs from Git + VISION + GRAND_PLAN + AUTOPILOT_TASK + BUILD_RESULT. No in-memory state.
- Fingerprint SHA256 of `AUTOPILOT_TASK.md` in BUILD_RESULT prevents repeat execution of same completed task.
- Heartbeats `.hermes/autopilot/runtime/architect_heartbeat.json` / `builder_heartbeat.json` are observability only (timestamp/action/task_hash/HEAD/failure_count), not authoritative. Stale >20m triggers watchdog.
- Watchdog `.hermes/autopilot/runtime` is dumb: `ring_bell_watchdog.py` every 3m ensures loops alive, clears stale `builder.lock`, sends deduped recovery Telegram. Never decides milestones.
- Telegram ledger `.hermes/autopilot/runtime/telegram_notifications.json` deduplicates (event fingerprint + timestamp), loss never stalls development. Telegram failure retries independently, never blocks.
- Bounded exponential backoff for provider/network failures; keep retrying indefinitely rather than dead state; preserve evidence, recover/retry, continue. Escalation: first transients no Telegram; after sustained failure one warning; another after materially longer interval; recovery notification once successful.
