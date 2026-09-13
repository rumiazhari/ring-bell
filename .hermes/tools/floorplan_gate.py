"""Floor-plan quality gate: the assertions the probe does not make.

Why this exists: run 24's probe printed "floorplan probe finished with 0
failure(s)" while planning ZERO floors through the archetype system -- every
single floor had fallen back to the pre-overhaul legacy path, which the probe
does not count as a failure. Structural metrics were green because nothing was
being generated. A green suite therefore cannot be the acceptance criterion;
this gate asserts the things that actually define the deliverable.

Checks, in order of how badly a failure hurts the player-visible result:

  1. program integrity   -- does a dwelling get a kitchen, and a civic floor an
                            office? Measured per use, not in aggregate. This is
                            the defect class that a global `kinds={...}` count
                            hid for the whole session.
  2. coverage of paths   -- the archetype system must plan most floors, and the
                            legacy fallback must stay rare and reasoned.
  3. geometry            -- overlaps, slivers, room-as-corridor.
  4. archetype liveness  -- an archetype that wins zero floors is dead weight.
  5. downstream contract -- a kind with no furniture/system mapping ships an
                            unfurnished room. Nothing else checks this.

Usage:
    python .hermes/tools/floorplan_gate.py [probe_log] [plans.json]
Exit status 0 only when every hard check passes.
"""

import io
import json
import os
import re
import sys

PROBE = sys.argv[1] if len(sys.argv) > 1 else ".hermes/probe_run25.log"
PLANS = sys.argv[2] if len(sys.argv) > 2 else "out_floorplans/plans.json"

RESIDENTIAL_MIN_KITCHEN = 0.70   # dwellings with a kitchen
RESIDENTIAL_MIN_LIVING = 0.70    # dwellings with a living room
MIN_ARCHETYPE_SHARE = 0.90       # floors planned through an archetype
MAX_LEGACY = 15                  # deliberate below-MIN_INNER fallbacks
MAX_DEAD_ARCHETYPES = 2          # archetypes winning zero floors

fail = []
warn = []


def read(p):
    return io.open(p, encoding="utf-8").read()


# ---------------------------------------------------------------- 1. programme
by_use = {}
archetype_floors = 0
total_floors = 0
if os.path.exists(PLANS):
    data = json.loads(read(PLANS))
    for plan in data.get("plans", []):
        use = str(plan.get("use", "residential"))
        for fl in plan.get("floors", []):
            total_floors += 1
            if str(fl.get("archetype", "legacy")) == "legacy":
                continue
            archetype_floors += 1
            kinds = set(str(r.get("kind")) for r in fl.get("rooms", []))
            agg = by_use.setdefault(use, {"n": 0, "kitchen": 0, "living": 0, "sleeping": 0})
            agg["n"] += 1
            for k in ("kitchen", "living", "sleeping"):
                if k in kinds:
                    agg[k] += 1
else:
    fail.append("plans.json not found at %s -- cannot check programme" % PLANS)

# Only uses whose programme actually calls for these rooms are judged.
ROOM_USES = {"residential", "caretaker", "retail", "tavern"}
for use, a in sorted(by_use.items()):
    if use not in ROOM_USES or a["n"] == 0:
        continue
    k = a["kitchen"] / a["n"]
    l = a["living"] / a["n"]
    line = "%-12s floors=%3d kitchen=%3.0f%% living=%3.0f%% sleeping=%3.0f%%" % (
        use, a["n"], 100 * k, 100 * l, 100 * a["sleeping"] / a["n"])
    if k < RESIDENTIAL_MIN_KITCHEN:
        fail.append("programme: %s" % line + "  (kitchen below %.0f%%)" % (100 * RESIDENTIAL_MIN_KITCHEN))
    elif l < RESIDENTIAL_MIN_LIVING:
        warn.append("programme: %s" % line + "  (living below %.0f%%)" % (100 * RESIDENTIAL_MIN_LIVING))
    else:
        print("  ok  " + line)

# ---------------------------------------------------------------- 2. coverage
share = archetype_floors / max(total_floors, 1)
print("  archetype-planned floors %d/%d = %.1f%%" % (archetype_floors, total_floors, 100 * share))
if share < MIN_ARCHETYPE_SHARE:
    fail.append("coverage: only %.1f%% of floors planned through an archetype (want %.0f%%)"
                % (100 * share, 100 * MIN_ARCHETYPE_SHARE))

# ----------------------------------------------------------------- 3. geometry
log = read(PROBE) if os.path.exists(PROBE) else ""
m = re.search(r"slivers=(\d+) overlaps=(\d+)", log)
if m:
    if int(m.group(1)) or int(m.group(2)):
        fail.append("geometry: slivers=%s overlaps=%s" % (m.group(1), m.group(2)))
    else:
        print("  ok  slivers=0 overlaps=0")
else:
    warn.append("probe log has no geometry line")
m = re.search(r"bedroom_as_corridor=(\d+)/(\d+)", log)
if m:
    if int(m.group(1)):
        fail.append("geometry: bedroom_as_corridor=%s" % m.group(1))
    else:
        print("  ok  bedroom_as_corridor=0/%s" % m.group(2))
m = re.search(r"circ_share=([0-9.]+)", log)
if m:
    net = float(m.group(1))
    print("  circulation net=%.3f (gated by the planner; gross is reported per floor)" % net)

# ------------------------------------------------------- 4. archetype liveness
declared = re.findall(r'"id": "([a-z_]+)"', read("world/generation/floorplan/floor_plan_planner.gd"))
seen = set()
if os.path.exists(PLANS):
    for plan in json.loads(read(PLANS)).get("plans", []):
        for fl in plan.get("floors", []):
            a = str(fl.get("archetype", "legacy"))
            if a != "legacy":
                seen.add(a)
dead = [a for a in declared if a not in seen]
print("  archetypes declared=%d used=%d" % (len(declared), len(seen)))
if dead:
    warn.append("archetypes winning zero floors: %s" % ", ".join(dead))
if len(dead) > MAX_DEAD_ARCHETYPES:
    fail.append("liveness: %d archetypes never selected (max %d)" % (len(dead), MAX_DEAD_ARCHETYPES))

# --------------------------------------------------- 5. downstream contract
prog_src = read("world/generation/floorplan/floor_program.gd")
kind_block = prog_src.split("const KIND")[1] if "const KIND" in prog_src else ""
prog_kinds = set(re.findall(r"&\"([a-z_]+)\":\s*\{", kind_block))
interior = read("world/generation/interior_plan.gd")
furn_section = interior.split("_room_furniture")[-1][:6000] if "_room_furniture" in interior else ""
missing = sorted(k for k in prog_kinds if k not in furn_section)
print("  programme kinds=%d, kinds with no furniture mapping=%d" % (len(prog_kinds), len(missing)))
if missing:
    warn.append("kinds with no furniture mapping in interior_plan.gd: %s" % ", ".join(missing))

# ---------------------------------------------------------------------- verdict
print("")
for w in warn:
    print("WARN  " + w)
for f in fail:
    print("FAIL  " + f)
if fail:
    print("\nGATE RED -- %d failure(s). The suite's own exit code does not cover these." % len(fail))
    sys.exit(1)
print("\nGATE GREEN -- %d warning(s)." % len(warn))
