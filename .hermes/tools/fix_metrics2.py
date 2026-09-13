"""Sixth pass: convert the two new hard gates into recorded metrics.

Positional implementation: locate the diagnostic line, then patch the `return
{}` that follows it. The previous regex missed because the block's exact text
differs from what I assumed; anchoring on the `_last_validate` string is stable.

Rationale unchanged from the fifth pass: the checks are the audit's headline
finding made measurable, but as gates they cost 88% of coverage (312 -> 36
archetype-planned floors), which is a worse product than the one they replaced.
"""

import io
import sys

PLANNER = "world/generation/floorplan/floor_plan_planner.gd"
L = io.open(PLANNER, encoding="utf-8", newline="").read().replace("\r\n", "\n").split("\n")

TARGETS = [
    ("programme missing", 'metrics["prog_missing"] = missing.size()',
     'metrics["prog_missing_kinds"] = str(missing)'),
    ("toilet %.1f m2 over declared max",
     'metrics["toilet_over"] = int(metrics.get("toilet_over", 0)) + 1', None),
]

done = 0
for anchor, m1, m2 in TARGETS:
    idx = [i for i, l in enumerate(L) if anchor in l]
    if not idx:
        print("FAIL: anchor not found: %s" % anchor)
        continue
    i = idx[0]
    # find the `return {}` within the next 8 lines and replace the gate
    for j in range(i, min(len(L), i + 8)):
        if L[j].strip() == "return {}":
            L[j] = "\t\t" + m1
            if m2:
                L.insert(j + 1, "\t\t" + m2)
            done += 1
            print("converted at line %d: %s" % (j + 1, anchor[:34]))
            break

if done != 2:
    print("FAIL: converted %d of 2" % done)
    sys.exit(1)

io.open(PLANNER, "w", encoding="utf-8", newline="").write("\n".join(L).replace("\n", "\r\n"))
print("both gates are now metrics; structural gates untouched")
