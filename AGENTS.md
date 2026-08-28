# Ring Bell Agent Rules

## Canonical checkout

`C:/Vibe Code project/Godot Project/ring-bell`

Never use a OneDrive copy.

## Read first

Every autonomous role must read:

1. `AUTOPILOT_STATE.json`
2. `AUTOPILOT_POLICY.md`
3. `.hermes/autopilot/GRAND_PLAN.md`
4. the current approved specification or revision specification
5. `ARCHITECTURE.md`, `DEVELOPMENT.md`, and relevant source/tests
6. current Git status and recent commits

`AUTOPILOT_STATE.json` is the only machine state. Do not recreate or use `AUTOPILOT_STATE.md`.

## Hard role boundary

- `lunaringbell` is architect and reviewer. It designs the entire project and reviews implementation, but never edits production code/tests/scenes/assets/project settings.
- `museringbell` is builder. It implements only the approved design, but never selects milestones or edits control state.
- Both use `gpt-5.6-luna` via `openai-codex` with `agent.reasoning_effort=max` (Luna Ultra mapping).
- `tools/ring_bell_autopilot_v2.py` alone creates lifecycle tasks and mutates state.

## Construction discipline

- One active writer only.
- Strict TDD for new behavior and bug fixes.
- Run every gate named by the active specification through `tools/run_suite.py`.
- Judge Godot gates by their documented `finished with N failure(s)` marker; a Windows shutdown code is acceptable only when the required success marker is present.
- Never weaken assertions, hide errors, accept pending/inflight work as completed behavior, or replace ordinary movement with teleportation when the specification requires player traversal.
- Preserve all unrelated dirty files and user work. Never reset or clean the checkout.
- Never delete files; move unwanted artifacts into project `junk/`.
- Commit coherent verified construction and include exact changed files, commits, tests, player-facing evidence, and residual risk in the review handoff.

## Review discipline

- Review the actual repository and evidence, not prose alone.
- Minor findings are deferred to a later related milestone.
- Only principal design conflicts justify direct revision.
- Maximum direct revisions: two.
- After the cap, use a fresh recovery architecture cycle rather than a third patch loop.
- Review cards are independent nonblocking cards; never add a Kanban parent dependency to the source build.

## No-start gate

If `enabled=false` or `phase=paused`, do not create, promote, claim, dispatch, implement, review, or resume any Ring Bell task. Only validation/audit/configuration is allowed until the user explicitly starts v2.
