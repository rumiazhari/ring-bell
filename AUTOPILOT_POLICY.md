# Ring Bell Autopilot Authority Policy

This repository uses a bounded Luna → Muse pilot. The policy is part of the
project control plane and is loaded by Hermes, Kanban workers, and other coding
agents.

## Authority hierarchy

1. The user owns the game vision and final product decisions.
2. Luna (`lunaringbell`) owns milestone choice, architecture, gameplay design,
   interfaces, priorities, acceptance criteria, and final review.
3. Muse (`museringbell`) owns implementation, tests, local refactoring, and
   coherent Git checkpoints inside the current approved specification.
4. Hermes Kanban owns durable task state, claims, handoffs, retries, and review
   routing.
5. `AUTOPILOT_STATE.json` is the canonical project-control state. Git is the
   canonical implementation state. Kanban is the canonical execution state.

## Scope lock

- Muse must not select the next milestone or create roadmap tasks.
- Muse must not resume facade-detail work when the approved specification is
  about interiors, traversal, simulation, persistence, or another higher-value
  gameplay/system milestone.
- Muse must not change architecture, public interfaces, or gameplay behavior
  outside the current specification without escalating to Luna.
- Muse must not weaken assertions, skip required gates, or hide failures.
- Muse must request Luna review when the milestone is complete or when an
  architectural conflict, cross-system regression, ambiguity, repeated failure,
  documentation mismatch, or technical-debt increase appears.
- Luna may inspect the entire repository but must not edit production code.
  Luna may edit only `AUTOPILOT_STATE.json`, files below
  `.hermes/autopilot/`, and review/specification documentation.
- Only one actor may hold the Ring Bell pilot lease at a time.
- Never delete files. Quarantine unwanted artifacts under a project `junk/`
  directory instead.
- Never use historical OneDrive paths. The canonical repository is
  `C:/Vibe Code project/Godot Project/ring-bell`.

## Required Luna design output

A Luna specification must identify:

- milestone ID and player-facing objective;
- architecture and subsystem ownership;
- interfaces and invariants;
- implementation phases;
- explicit acceptance criteria;
- tests and manual/player-facing verification;
- out-of-scope work;
- rollback/recovery considerations;
- the exact Muse task and its bounded runtime/retry budget.

## Required Muse closeout

Muse must leave structured evidence containing changed files, commits, tests,
acceptance results, remaining risks, and any escalation reason. Muse must call
the Kanban review transition rather than inventing a follow-up task.

## Required review behavior

Luna must inspect actual Git state, actual code, test output, and player-facing
behavior where possible. Passing tests is necessary but not sufficient for
acceptance.
