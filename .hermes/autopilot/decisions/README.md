# Machine decisions

The architect writes `ARCHITECT-C###.json`. The reviewer writes `REVIEW-C###-R##.json`. The deterministic controller validates identity, phase, revision cap, local paths, and specification hashes before mutating state.

Allowed review verdicts: `accept`, `accept_with_deferred`, `revise`, and `recovery_required`. Minor findings must use `accept_with_deferred`; direct `revise` is principal-only and capped at two rounds.
