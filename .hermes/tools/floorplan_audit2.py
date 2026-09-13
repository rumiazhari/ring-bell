"""Second-pass audit of the generated plans, run against the probe's plans.json.

Where floorplan_gate.py asserts thresholds, this prints the structural facts
that were never measured, so a human can judge them:

  * windows      -- rooms that want a facade and have none (a bedroom with no
                    window is not a bedroom)
  * stairs       -- does the stair shaft land in the same place on every floor
                    of a building? Floors are planned independently, so a
                    mismatch means the stair does not stack.
  * entry        -- exactly one entry per floor, and is it on an open facade?
  * doors        -- rooms authored with no connecting door
  * aspect       -- the most elongated room on each floor (a 1.2 x 9 m room is
                    a corridor whatever it is called)
  * programme    -- rooms produced vs rooms the programme asked for
  * circulation  -- gross share per archetype, including the stair shaft
"""

import io
import json
import sys
from collections import Counter, defaultdict

PLANS = sys.argv[1] if len(sys.argv) > 1 else "out_floorplans/plans.json"
data = json.loads(io.open(PLANS, encoding="utf-8").read())

no_window = Counter()
no_window_want = Counter()
doors_missing = Counter()
entry_off_facade = 0
entry_count_bad = 0
aspect_worst = []
stair_rects = defaultdict(list)
circ_gross = defaultdict(lambda: [0.0, 0.0])
prog_short = Counter()
rooms_short = 0
floor_kinds = defaultdict(Counter)

WANTS_FACADE = {"living", "sleeping", "kitchen", "office", "ward", "taproom", "sales",
                "craft", "machine_shop", "warehouse", "reception", "council"}

for plan in data.get("plans", []):
    bid = plan.get("building_id", plan.get("id", "?"))
    for fl in plan.get("floors", []):
        if str(fl.get("archetype", "legacy")) == "legacy":
            continue
        rooms = fl.get("rooms", [])
        entries = [r for r in rooms if r.get("entry")]
        if len(entries) != 1:
            entry_count_bad += 1
        elif not entries[0].get("facade"):
            entry_off_facade += 1
        circ_area = 0.0
        total = 0.0
        for r in rooms:
            k = str(r.get("kind"))
            rect = r.get("rect", [0, 0, 0, 0])
            w, h = float(rect[2]), float(rect[3])
            area = w * h
            total += area
            floor_kinds[fl.get("archetype")][k] += 1
            if k in ("corridor", "hall", "landing", "stair_hall"):
                circ_area += area
            if k in WANTS_FACADE and not r.get("facade"):
                no_window[k] += 1
                no_window_want[k] += 1
            if int(r.get("doors", 1)) == 0:
                doors_missing[k] += 1
            if min(w, h) > 0.1:
                a = max(w, h) / min(w, h)
                aspect_worst.append((a, k, round(w, 2), round(h, 2), bid))
            if k == "stair_hall":
                stair_rects[bid].append((int(fl.get("floor_i", 0)), round(float(rect[0]), 2), round(float(rect[1]), 2)))
        circ_gross[fl.get("archetype")][0] += circ_area
        circ_gross[fl.get("archetype")][1] += total
        want = int(fl.get("programme_size", len(rooms)))
        if len(rooms) < want:
            rooms_short += 1
            prog_short[fl.get("archetype")] += 1

print("== windows: rooms that want a facade and have none ==")
if no_window:
    for k, n in no_window.most_common():
        print("   %-12s %4d rooms without any facade edge" % (k, n))
else:
    print("   none")

print("\n== doors: rooms authored with zero connecting doors ==")
print("   %s" % (dict(doors_missing) if doors_missing else "none"))

print("\n== entry ==")
print("   floors without exactly one entry: %d" % entry_count_bad)
print("   entries not on an open facade:    %d" % entry_off_facade)

print("\n== stairs: does the shaft stack across floors of one building? ==")
misaligned = 0
for bid, rects in sorted(stair_rects.items()):
    if len(rects) < 2:
        continue
    xs = set(r[1] for r in rects)
    ys = set(r[2] for r in rects)
    if len(xs) > 1 or len(ys) > 1:
        misaligned += 1
        if misaligned <= 6:
            print("   %-28s %s" % (bid[:28], rects))
print("   buildings whose stair moves between floors: %d of %d" % (misaligned, len(stair_rects)))

print("\n== most elongated rooms (aspect = long/short) ==")
for a, k, w, h, bid in sorted(aspect_worst, reverse=True)[:6]:
    print("   %5.1f:1  %-10s %.2f x %.2f m  %s" % (a, k, w, h, bid[:24]))

print("\n== gross circulation share per archetype (incl. stair shaft) ==")
for arch, (c, t) in sorted(circ_gross.items(), key=lambda kv: -kv[1][0] / max(kv[1][1], 0.1)):
    print("   %-26s %.3f" % (arch, c / max(t, 0.1)))

print("\n== rooms produced vs programme size ==")
print("   floors short of their programme: %d %s" % (rooms_short, dict(prog_short) if prog_short else ""))

print("\n== kind mix by archetype (top kinds) ==")
for arch, cnt in sorted(floor_kinds.items()):
    print("   %-26s %s" % (arch, ", ".join("%s=%d" % kv for kv in cnt.most_common(9))))
