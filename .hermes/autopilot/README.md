# Ring Bell pilot control plane

- `../../AUTOPILOT_STATE.json` is the canonical project-control state.
- `../../AUTOPILOT_STATE.schema.json` describes the required state shape.
- `../../AUTOPILOT_POLICY.md` defines Luna/Muse authority and scope.
- `specs/` contains Luna-approved milestone specifications.
- `reports/` contains builder and reviewer evidence.
- `locks/pilot.lock` is a persistent lease record; released/stale locks are
  quarantined under the project `junk/` folder rather than deleted.

Kanban task bodies must include the state revision and specification path.
Never treat Bot Chat prose or old `AUTOPILOT_STATE.md` iteration notes as
authorization for new work.
