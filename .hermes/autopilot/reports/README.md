# Architect review reports

Each independent review writes a human-readable `REVIEW-C###-R##.md` plus its machine decision under `../decisions/`. Reports must cite the reviewed task/run, commits/diff, exact tests/log markers, player-facing evidence, compatibility risks, and the reason for the verdict.

Passing tests are necessary but not sufficient. Review the actual implementation against the design. Minor findings are deferred; principal conflicts alone justify bounded revision.
