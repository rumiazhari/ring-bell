"""Print full reject reasons from a floorplan-probe log, one per archetype class.

    python .hermes/tools/show_reject_full.py .hermes/probe_runN.log [char_limit]
"""
import io
import json
import re
import sys

PAT = re.compile(r'"((?:[^"\\]|\\.)*)": (\d+)')


def main():
    log = sys.argv[1] if len(sys.argv) > 1 else ".hermes/probe_run14.log"
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 900
    t = io.open(log, encoding="utf-8", errors="replace").read()
    i = t.find("planner_rejections=")
    if i < 0:
        print("no planner_rejections in", log)
        return
    seg = t[i + len("planner_rejections="):]
    j = seg.find("ARCHETYPE_ONLY")
    if j > 0:
        seg = seg[:j]
    seen = set()
    for m in PAT.finditer(seg):
        try:
            r = json.loads('"' + m.group(1) + '"')
        except ValueError:
            continue
        tag = r.split(":")[0]
        if tag in seen:
            continue
        seen.add(tag)
        print("===== x%s  %s" % (m.group(2), tag))
        print(r[:limit].replace("\\t", "  "))
        print()


if __name__ == "__main__":
    main()
