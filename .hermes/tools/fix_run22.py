"""run 22 fixes.

A. Two circulation cells are the same circulation system: a landing meeting a
   corridor needs a PASSAGE, not a door. The old code routed every boundary
   through DOOR_EDGE_MIN (1.25 m, sized for a door leaf plus jambs), so a 1.19 m
   shared edge between two halls was sealed -- and because the reachability gate
   checks that circulation is one connected component, the plan was thrown away.
   Shallow plates hit this every time.

B. The probe read FloorPlanPlanner.last_reject AFTER the fact. For a floor the
   planner was never asked about (the pre-overhaul path chose it) that value is
   whatever the previous floor left behind -- usually the empty string -- and the
   reject report claimed 12 unknown reasons instead of saying so.
"""
import io
import sys

PLAN = "world/generation/floorplan/floor_plan_planner.gd"
PROBE = "debug/floorplan_probe.gd"


def edit(path, pairs):
    src = io.open(path, encoding="utf-8").read()
    for old, new in pairs:
        assert src.count(old) == 1, "%s: %d hits for %r" % (path, src.count(old), old[:70])
        src = src.replace(old, new)
    io.open(path, "w", encoding="utf-8", newline="\n").write(src)
    print("patched %s (%d edits)" % (path, len(pairs)))


edit(PLAN, [
    (
        "## Shortest shared edge that can hold a 0.95 aperture plus jambs.\n"
        "const DOOR_EDGE_MIN := 1.25\n",
        "## Shortest shared edge that can hold a 0.95 aperture plus jambs.\n"
        "const DOOR_EDGE_MIN := 1.25\n"
        "## Two circulation cells are the same circulation system: the edge only\n"
        "## has to carry the aperture (0.95) plus slim jambs. Sealing a 1.19 m\n"
        "## landing-to-corridor edge splits the floor's circulation in two, and\n"
        "## the reachability gate rightly rejects that plan.\n"
        "const PASSAGE_EDGE_MIN := 1.15\n",
    ),
    (
        "static func _add_boundary(parts: Array, door_list: Array, a_i: int, b_i: int,\n"
        "\t\te: Dictionary, with_door: bool) -> bool:",
        "static func _add_boundary(parts: Array, door_list: Array, a_i: int, b_i: int,\n"
        "\t\te: Dictionary, with_door: bool, edge_min: float = DOOR_EDGE_MIN) -> bool:",
    ),
    (
        "\tif with_door and hi - lo >= DOOR_EDGE_MIN:",
        "\tif with_door and hi - lo >= edge_min:",
    ),
    (
        "\t# 1. circulation connects to circulation - the hall always reaches the spine.\n"
        "\tfor e: Dictionary in adj:\n"
        "\t\tvar a: Dictionary = cells[int(e[\"i\"])]\n"
        "\t\tvar b: Dictionary = cells[int(e[\"j\"])]\n"
        "\t\tif bool(a[\"circ\"]) and bool(b[\"circ\"]):\n"
        "\t\t\tif _add_boundary(parts, door_list, int(e[\"i\"]), int(e[\"j\"]), e, true):",
        "\t# 1. circulation connects to circulation - the hall always reaches the spine.\n"
        "\t# Two circ cells open to each other with a passage (PASSAGE_EDGE_MIN): a\n"
        "\t# landing and its corridor are one space, and a sealed edge between them\n"
        "\t# would split the floor's circulation into two components.\n"
        "\tfor e: Dictionary in adj:\n"
        "\t\tvar a: Dictionary = cells[int(e[\"i\"])]\n"
        "\t\tvar b: Dictionary = cells[int(e[\"j\"])]\n"
        "\t\tif bool(a[\"circ\"]) and bool(b[\"circ\"]):\n"
        "\t\t\tif _add_boundary(parts, door_list, int(e[\"i\"]), int(e[\"j\"]), e, true,\n"
        "\t\t\t\t\tPASSAGE_EDGE_MIN):",
    ),
])

edit(PROBE, [
    (
        "\t\t\t\t\tvar why := FloorPlanPlanner.last_reject\n",
        "\t\t\t\t\tvar why := FloorPlanPlanner.last_reject\n"
        "\t\t\t\t\tif why == \"\":\n"
        "\t\t\t\t\t\t# The planner was never consulted for this floor (the\n"
        "\t\t\t\t\t\t# pre-overhaul path chose it), so its static last_reject is\n"
        "\t\t\t\t\t\t# stale. Say that instead of reporting a blank reason.\n"
        "\t\t\t\t\t\twhy = \"not reported: pre-overhaul path planned this floor (planner not consulted)\"\n",
    ),
])

print("run 22 patches applied")
if sys.argv[1:] == ["--check"]:
    print("check-only")
