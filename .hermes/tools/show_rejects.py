"""Summarise a floorplan-probe log: metrics lines plus the planner_rejections histogram.

Usage: python .hermes/tools/show_rejects.py .hermes/probe_run10.log [max_chars_per_reason]
"""
import io
import sys

path = sys.argv[1] if len(sys.argv) > 1 else ".hermes/probe_run.log"
width = int(sys.argv[2]) if len(sys.argv) > 2 else 220
text = io.open(path, encoding="utf-8", errors="replace").read()

for line in text.split("\n"):
    s = line.strip()
    if not s:
        continue
    if "planner_rejections=" in s:
        body = s.split("planner_rejections=", 1)[1]
        body = body.replace('\\"', '"').strip()
        if body.startswith("{"):
            body = body[1:]
        if body.endswith("}"):
            body = body[:-1]
        rows = []
        for chunk in body.split(", "):
            chunk = chunk.strip().strip('"')
            if '": ' in chunk:
                k, v = chunk.rsplit('": ', 1)
                try:
                    rows.append((k, int(v.strip())))
                except ValueError:
                    pass
        rows.sort(key=lambda kv: -kv[1])
        print("REJECT KINDS %d  TOTAL %d" % (len(rows), sum(v for _, v in rows)))
        for k, v in rows:
            print("%4d x %s" % (v, k[:width]))
        continue
    print(s[:width])
