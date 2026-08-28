# Ring Bell Autopilot v2

This directory contains the fresh architect→builder handoff artifacts. The legacy control plane, reports, specs, locks, profiles, scripts, and 19 exported board tasks are preserved at:

`C:/junk/ring-bell-autopilot-legacy-20260829-000738`

## Active components

- `GRAND_PLAN.md` — enjoyment-first product charter anchored to the saved macro-world plan.
- `specs/` — architect construction specifications and bounded revision specifications.
- `decisions/` — machine-readable architect/review decisions consumed by the deterministic controller.
- `reports/` — human-readable implementation review reports.
- `AUTOPILOT_STATE.json` — sole machine lifecycle state at repository root.
- `AUTOPILOT_POLICY.md` — role, review, revision, and continuity rules.
- `tools/ring_bell_autopilot_v2.py` — sole deterministic lifecycle controller.
- Kanban board `ring-bell-v2` — sole execution board.

## Lifecycle

`paused → needs_architect → architecting → ready_to_build → building → awaiting_review → reviewing`

Review then produces one of:

- accept / accept-with-deferred → next architect cycle;
- principal revise → bounded revision builder (maximum two rounds);
- recovery-required → next architect cycle with an explicit recovery design.

Review cards are independent and carry nonblocking `review_of_task` metadata. They never use a Kanban parent dependency.

## No-start state

The state and controller schedule are intentionally paused. Do not run `resume`, dispatch, or fire the schedule until the user explicitly asks to start.
