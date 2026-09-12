"""Two structural fixes in floor_plan_planner.gd (run 15).

A. Revert the stair-band split. The band's far side (a passage + a room beside
   the shaft) severed the rear room band from circulation: the rear slabs then
   bordered a service room instead of circulation and `_reach_ok` rejected every
   one of those floors (199 legacy floors in run 14, 46 in run 13). The stair
   band is circulation across the full band width again.

B. Wide plates get a corridor parallel to the STREET. On a 13.3 x 6.9 m plate the
   party-wall spine puts the entrance column between the corridor and the rooms,
   so every depth slice but the first reaches the corridor only through another
   room (37 spine-flat rejects in run 14). Wide plates now use the shallow-house
   plan: a corridor along the street, one room tract behind it, and an entrance
   bay (hall, stair, chamber) that swallows the entrance box.
"""
import io
import sys

PATH = "world/generation/floorplan/floor_plan_planner.gd"
lines = io.open(PATH, encoding="utf-8").read().split("\n")

# ---- A. locate the band block by content, not by line number -------------
a_start = None
a_end = None
for i, l in enumerate(lines):
    if l.startswith("\tvar cw_cell := minf(clampf(core.size.x"):
        a_start = i
    if a_start is not None and "band_d - walk" in l:
        a_end = i
if a_start is None or a_end is None:
    sys.exit("A: band block not found")
assert "walk" in lines[a_end] and "cw_cell" in lines[a_start + 6], lines[a_end]
band_new = """\t# The stair band is circulation ACROSS THE FULL WIDTH of the plate. Anything
\t# narrower severs the room bands in front of and behind it from the corridor:
\t# a room given walls beside the shaft blocks the band behind it, and those
\t# rooms then reach circulation only through a service room, which the
\t# reachability gate rejects -- correctly. The shaft stands inside this band,
\t# so it reads as the stair hall it is, not as an empty lobby."""
lines[a_start:a_end + 1] = band_new.split("\n")

# ---- B. wide-plate branch in _skeleton ----------------------------------
sk = None
for i, l in enumerate(lines):
    if l.startswith("\tvar central := bool(arch.get(\"central_spine\""):
        sk = i
        break
if sk is None:
    sys.exit("B: central spine line not found")
else_i = None
for i in range(sk, sk + 40):
    if lines[i] == "\telse:":
        else_i = i
        break
if else_i is None:
    sys.exit("B: spine else not found")
wide = """\telif W > D * 1.15:
\t\t# ---- 5b. Wide plate: the corridor runs PARALLEL TO THE STREET, not along a
\t\t# party wall. On a 13.3 x 6.9 m plate a party-wall spine puts the entrance
\t\t# column between the corridor and the rooms, so every depth slice but the
\t\t# first can reach the corridor only through another room -- the reject dumps
\t\t# show exactly that. The shallow-house plan real ones use instead: a
\t\t# corridor along the street, one room tract behind it (courtyard-lit), and
\t\t# an entrance bay that cuts the plate from the street to the courtyard with
\t\t# the hall at the door, the stair behind it and a chamber behind that.
\t\tvar bxw := bx1 - bx0
\t\tvar bay_w := clampf(maxf(bxw + 0.9, 2.6), 2.6, minf(3.2, W * 0.45))
\t\tvar bay_x := clampf((bx0 + bx1) * 0.5 - bay_w * 0.5, 0.0, maxf(0.0, W - bay_w))
\t\tvar hall_d := clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.40))
\t\tvar shaft_d := 0.0
\t\tif frame.has_core and D - hall_d >= 2.6:
\t\t\tshaft_d = clampf(frame.core.size.y, 2.4, D - hall_d)
\t\tvar tail_d := D - hall_d - shaft_d
\t\tif tail_d < 1.5:
\t\t\t# A 40 cm strip behind the stair is not a room: the stair hall takes
\t\t\t# it, or the hall does on a floor with no core of its own.
\t\t\tif shaft_d > 0.0:
\t\t\t\tshaft_d = maxf(0.0, D - hall_d)
\t\t\telse:
\t\t\t\thall_d = D
\t\t\ttail_d = D - hall_d - shaft_d
\t\tcells.append(_hall_cell(Rect2(bay_x, 0.0, bay_w, hall_d),
\t\t\t\tint(p.get("floor_i", 0)) == 0))
\t\tif shaft_d > 0.0:
\t\t\tcells.append(_locked_cell(&"stair_hall",
\t\t\t\t\tRect2(bay_x, hall_d, bay_w, shaft_d), true))
\t\tif tail_d >= 1.5:
\t\t\tcells.append(_cell(&"room", Rect2(bay_x, D - tail_d, bay_w, tail_d), false))
\t\t# The corridor along the street, either side of the bay.
\t\tif bay_x >= 1.2:
\t\t\tcells.append(_corridor(Rect2(0.0, 0.0, bay_x, cw)))
\t\tif W - (bay_x + bay_w) >= 1.2:
\t\t\tcells.append(_corridor(Rect2(bay_x + bay_w, 0.0, W - bay_x - bay_w, cw)))
\t\t# The room tract behind the corridor: every slab of it borders the
\t\t# corridor, so every room takes its own door off circulation.
\t\tif bay_x >= 1.5:
\t\t\t_slice_x(cells, Rect2(0.0, cw, bay_x, D - cw), arch)
\t\tif W - (bay_x + bay_w) >= 1.5:
\t\t\t_slice_x(cells, Rect2(bay_x + bay_w, cw, W - bay_x - bay_w, D - cw), arch)"""
lines[else_i:else_i] = wide.split("\n")
io.open(PATH, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
print("A: band block lines", a_start + 1, "-", a_end + 1, "replaced")
print("B: wide branch inserted before line", else_i + 1)
