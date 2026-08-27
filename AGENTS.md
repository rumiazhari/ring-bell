# Ring Bell agent rules

This repository is the Ring Bell pilot for a strict Luna → Muse workflow.
Read these files before any work:

1. `AUTOPILOT_POLICY.md`
2. `AUTOPILOT_STATE.json`
3. `ARCHITECTURE.md`
4. `DEVELOPMENT.md`
5. `TODO.md`

## Role routing

- `lunaringbell` is the architect, game designer, technical director, and
  reviewer. Luna chooses milestones, designs interfaces, defines acceptance
  criteria, and reviews actual implementation. Luna must not edit production
  code; Luna may edit only control-plane/spec/review files.
- `museringbell` is the implementation engineer and QA worker. Muse may edit
  production code only for the currently approved Kanban task. Muse must not
  choose the next milestone, create roadmap work, or turn a completed task
  into cosmetic busywork.
- Hermes Kanban is the durable handoff and execution state. Use its structured
  task/review transitions, not Bot Chat prose, for authority.

## Kanban lifecycle safety

- A Muse implementation card stays in `review` after `kanban_request_review`.
  It must never be reassigned or reused as a Luna card.
- The supervisor creates a separate idempotent Luna review card linked to the
  Muse card. `kanban.review_dispatch` is disabled for this pilot so a review
  status can never accidentally respawn the builder.
- Every card explicitly pins its model/provider: Luna is
  `gpt-5.6-luna`/`openai-codex`; Muse is
  `muse-spark-1.2-contributor`/`opencode-go`.
- Only one Ring Bell task may be `ready` or `running` for this checkout at a
  time. If an active task already owns the checkout, the supervisor must not
  create another one.

## Scope guard

Before editing, confirm that the requested change is in the current approved
specification and that `AUTOPILOT_STATE.json` is in `authorized_build` or
`building`. If the next task is ambiguous, the state is stale, or a change
requires architectural redesign, stop and escalate to Luna.

The current user directive prioritizes functional interiors, traversal,
world/gameplay systems, persistence, and player-facing value over additional
Prague facade ornament. Do not add another facade-only detail unless Luna's
current specification explicitly authorizes it as part of a higher-value
system.

## Test and Git gates

Use the repository harness:

```text
python tools/run_suite.py --citytest 120
python tools/run_suite.py --smoke 120
python tools/run_suite.py --cityruntime 180
python tools/run_suite.py --havoctest 180
python tools/run_suite.py --walkthrough 240
```

Judge success by `finished with 0 failure(s)`. The documented Windows
`3221225477` shutdown code is acceptable only when the log contains that
zero-failure line. Do not weaken assertions or hide errors.

Commit coherent stable implementation units with concise messages. Before a
new milestone, the previous approved checkpoint must be committed. Never use
historical OneDrive paths. Never delete files; move unwanted artifacts into a
project `junk/` directory.

## Crash and escalation protocol

Long work must keep the Kanban heartbeat alive and preserve useful commits.
If the same failure persists through three serious repairs, or if the fix
would alter a core API/architecture, use a structured Luna escalation rather
than brute-forcing. On completion, record changed files, commit(s), tests,
acceptance results, residual risks, and next decision in the Kanban handoff and
`AUTOPILOT_STATE.json`/`.hermes/autopilot/reports/` as appropriate.
