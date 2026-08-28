# Ring Bell Autopilot v2 Policy

## Authority

1. **User** owns the product vision and final exceptional decisions.
2. **`.hermes/autopilot/GRAND_PLAN.md`** is the durable product charter derived from the user's command and the saved macro-world plan.
3. **`AUTOPILOT_STATE.json`** is the only machine control state.
4. **Git** is implementation truth.
5. **Kanban board `ring-bell-v2`** is task/run truth.
6. **`tools/ring_bell_autopilot_v2.py`** is the only lifecycle controller.

There is no legacy Markdown state, second controller, root lock, health-controller duplicate, or autonomous builder roadmap.

## Roles

### Architect and reviewer — `lunaringbell`

- Uses `gpt-5.6-luna` through `openai-codex` at reasoning effort `max` (the highest Codex-supported GPT-5.6 tier; this is the configured Luna Ultra mapping).
- Owns the architecture of the entire game, milestone selection, technical construction design, interfaces, sequencing, acceptance criteria, rollback design, and implementation review.
- Expands the grand plan one bounded milestone at a time according to the actual repository and player experience.
- May edit only specifications, decisions, reports, and control documentation.
- Must not edit production code, tests, scenes, assets, or project settings.

### Builder — `museringbell`

- Uses the same exact model/provider/reasoning pin.
- Implements only the architect-approved specification and bounded revision specifications.
- Uses TDD, runs required project gates, preserves unrelated user/WIP files, commits coherent verified work, and requests review with structured evidence.
- Must not select roadmap work, change priorities, broaden scope, redesign architecture, create reviewer tasks, or edit machine control state.

## Enjoyment-first architecture

Every architect specification must explain how it improves at least one of:

- meaningful player choice and agency;
- readable exploration, discovery, and world variety;
- satisfying movement, interaction, audiovisual feedback, or game feel;
- survival risk/reward, resource decisions, progression, or recovery;
- emergent NPC/world behavior and replayability;
- coherent Czech-inspired world identity and player legibility.

Prefer playable systems and foundations that unlock future play. Cosmetic work may accompany a gameplay milestone but may not replace one. Do not create facade-only milestones.

## Efficient milestone contract

Each architect cycle produces exactly one specification with:

- one bounded gameplay outcome;
- an explicit construction sequence and affected interfaces;
- 3–7 independently verifiable acceptance criteria;
- 1–8 required tests/manual proofs;
- named out-of-scope work;
- performance/collision/save compatibility where relevant;
- rollback and escalation boundaries;
- a SHA-256 recorded in the architect decision.

The deterministic controller creates exactly one builder card per cycle/revision using an idempotency key. Only one task may be `ready` or `running` on the board.

## Review and revision policy

The architect reviews the actual repository, diff/commits, tests, logs, and player-facing behavior—not only the builder summary.

Allowed review decisions:

- **`accept`** — the design is correctly and principally complete.
- **`accept_with_deferred`** — the design is principally correct; minor or low-value findings are added to `deferred_findings` and folded into a later related design.
- **`revise`** — a principal design/behavior conflict blocks acceptance. The architect writes one bounded revision specification before the builder returns.
- **`recovery_required`** — after the revision limit, or when patching is architecturally wrong, end direct rework and route to a fresh architect cycle that designs a safe recovery milestone.

Hard rules:

1. Minor findings cannot trigger a direct revision.
2. Maximum direct revision rounds per milestone: **2**.
3. A third direct revision is invalid.
4. Review cards are independent, nonblocking cards. They reference `review_of_task` and `review_of_run` in their body and are never dependency children.
5. Every completed build card is closed after its independent review. A revision gets a fresh, idempotent builder card.
6. After `accept`, `accept_with_deferred`, or `recovery_required`, state returns to `needs_architect` for the next cycle. The pipeline continues without allowing the builder to choose work.

## Continuous but non-looping operation

Once explicitly started, the single paused no-agent scheduler runs deterministic controller ticks. Healthy ticks are silent. The controller advances one transition per tick and dispatches at most one role task. It never calls an LLM itself.

“Always continue” means:

- accepted work immediately leads to the next architect cycle;
- minor findings travel forward instead of reopening the same build;
- principal blockers receive at most two direct revisions;
- exhausted revisions become a new architect recovery design, not another patch loop;
- infrastructure failures remain visible and retry on later scheduled ticks without model fallback.

It does **not** mean overlapping writers, infinite retries, hidden test failures, weakened assertions, or autonomous builder roadmap selection.

## No-start gate

Current state is `enabled=false`, `phase=paused`. Configuration, validation, audit, and dry-run inspection are allowed. No architect, builder, reviewer, dispatcher, or scheduled controller may run until the user explicitly authorizes start.

## File preservation

Never delete files. Preserve unwanted or superseded artifacts under the project `junk/` folder, or under `C:/junk` for system-level archives. Never reset or clean unrelated dirty work.
