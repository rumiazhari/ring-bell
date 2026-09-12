"""Reject statistics from a floorplan-probe log.

Parses the `planner_rejections={...}` block (a JSON object mapping reason ->
count) and prints: totals, counts by archetype, counts by reason family, and
the frame sizes seen per archetype -- enough to tell a whole archetype failing
apart from a single footprint class failing.
"""
import io
import json
import re
import sys
import collections

path = sys.argv[1] if len(sys.argv) > 1 else ".hermes/probe_run15.log"
s = io.open(path, encoding="utf-8", errors="replace").read()
i = s.find("planner_rejections=")
if i < 0:
    sys.exit("no planner_rejections block in " + path)
j = s.find("{", i)
depth = 0
end = -1
for k in range(j, len(s)):
    if s[k] == "{":
        depth += 1
    elif s[k] == "}":
        depth -= 1
        if depth == 0:
            end = k
            break
block = s[j:end + 1]
try:
    d = json.loads(block)
except Exception as e:                                   # pragma: no cover
    sys.exit("parse failed: %s" % e)

by_arch = collections.Counter()
by_fam = collections.Counter()
sizes = collections.defaultdict(collections.Counter)
total = 0
for reason, n in d.items():
    n = int(n)
    total += n
    m = re.match(r"^([a-z_]+):\s*(.*)$", reason)
    arch = m.group(1) if m else "(pre-archetype)"
    rest = m.group(2) if m else reason
    fam = re.sub(r"\(.*\)", "(SIZE)", rest)
    fam = re.sub(r"\d+\.\d+/\d+\.\d+", "N/N", fam)
    fam = re.sub(r"^reachability\b.*", "reachability ...", fam)
    by_arch[arch] += n
    by_fam[fam] += n
    sm = re.search(r"\((\d+\.\d)x(\d+\.\d)\)", reason)
    if sm:
        sizes[arch][sm.group(0)] += n

print("total rejects: %d  (distinct reasons: %d)" % (total, len(d)))
print()
print("by archetype:")
for k, v in by_arch.most_common(20):
    print("  %5d  %s" % (v, k))
print()
print("by reason family:")
for k, v in by_fam.most_common(20):
    print("  %5d  %s" % (v, k[:110]))
print()
for arch in list(by_arch)[:8]:
    if sizes[arch]:
        ex = ", ".join("%s x%d" % (a, b) for a, b in sizes[arch].most_common(5))
        print("sizes %-26s %s" % (arch, ex))
