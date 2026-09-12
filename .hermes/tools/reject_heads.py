"""Summarise a floorplan-probe log: metrics + reject reasons grouped by kind.

    python .hermes/tools/reject_heads.py .hermes/probe_runN.log
"""
import collections
import io
import json
import re
import sys

PAT = re.compile(r'"((?:[^"\\]|\\.)*)": (\d+)')


def main():
    log = sys.argv[1] if len(sys.argv) > 1 else ".hermes/probe_run14.log"
    t = io.open(log, encoding="utf-8", errors="replace").read()
    for line in t.split("\n"):
        s = line.strip()
        if s.startswith(("buildings=", "legacy_floors=", "circ_share=", "ARCHETYPE_ONLY", "principal_with_facade", "validate_error_classes")):
            print(s[:400])
    i = t.find("planner_rejections=")
    if i < 0:
        return
    seg = t[i + len("planner_rejections="):]
    j = seg.find("ARCHETYPE_ONLY")
    if j > 0:
        seg = seg[:j]
    agg = collections.Counter()
    tot = 0
    for m in PAT.finditer(seg):
        try:
            reason = json.loads('"' + m.group(1) + '"')
        except ValueError:
            continue
        n = int(m.group(2))
        tot += n
        head = reason.split(" doors_to=")[0]
        head = re.sub(r"room \d+", "room", head)
        head = re.sub(r"rect=\[[^\]]*\]", "rect=[..]", head)
        agg[head] += n
    print("\n-- rejects (%d floors) --" % tot)
    for k, v in agg.most_common(15):
        print(str(v).rjust(4), k[:180])


if __name__ == "__main__":
    main()
