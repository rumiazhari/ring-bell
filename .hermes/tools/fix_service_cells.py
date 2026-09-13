"""Fourth fix pass: service rooms must take the smallest adequate cell.

Run 26's reject log was dominated by one reason:

    toilet 15.5 m2 over declared max 6.0      (x27, plus 17.3 / 17.0 / 16.7 ...)

The toilet kind was declared, hosted and legal by min_side, but the *fit*
score hands every slot the cell it suits best by size and facade. A WC is not
a room that benefits from being large: it belongs in the smallest cell that
legally hosts it, leaving the big cells for the rooms that need them. Wiring
the declared `max_area` (which existed but was never consulted here) into the
choice is what makes that happen -- the planner was previously allowed to
produce a 15 m2 WC and only the validator objected, so whole floors were
discarded instead of being laid out properly.

Applies to service kinds only (WC, store, toolstore, archive, ...), in both
the normal search and the essential-room rescue.
"""

import io
import sys

PLANNER = "world/generation/floorplan/floor_plan_planner.gd"


def read(p):
    return io.open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")


def write(p, t):
    io.open(p, "w", encoding="utf-8", newline="").write(t.replace("\n", "\r\n"))


def sub_once(t, old, new, what):
    if t.count(old) != 1:
        print("FAIL %s: %d matches" % (what, t.count(old)))
        sys.exit(1)
    return t.replace(old, new)


t = read(PLANNER)

helper = '''## A service room (WC, store, toolstore) gains nothing from a large cell and
## costs the floor a room that could have used it. `max_area` is declared per
## kind for exactly this reason; prefer the smallest cell that legally hosts it
## and let the validator's ceiling stand as a hard limit rather than a filter
## that discards whole plans.
static func _serv_fit(kind: StringName, cell: Dictionary, si: int, base_fit: float) -> float:
	if not FloorProgram.is_service(kind):
		return base_fit
	var r: Rect2 = cell["rect"]
	var area := r.size.x * r.size.y
	var cap := float(FloorProgram.spec_of(kind).get("max_area", 6.0))
	if area > cap:
		# Still a legal candidate if nothing smaller exists, but ranked below
		# every cell that respects the declared ceiling.
		return base_fit - 100.0 - area
	return -area + float(si) * 0.001


static func _can_host_soft'''

t = sub_once(t, "static func _can_host_soft", helper, "serv_fit helper")

# normal search
t = sub_once(t,
    '''			var f := _fit(kind, room_cells[i], si)
			if f > spare_fit:''',
    '''			var f := _serv_fit(kind, room_cells[i], si, _fit(kind, room_cells[i], si))
			if f > spare_fit:''',
    "serv_fit normal")

# essential rescue search
t = sub_once(t,
    '''				var f2 := _fit(kind, room_cells[i], si)
				if _can_host_soft(kind, room_cells[i]) and f2 > best_fit:''',
    '''				var f2 := _serv_fit(kind, room_cells[i], si, _fit(kind, room_cells[i], si))
				if _can_host_soft(kind, room_cells[i]) and f2 > best_fit:''',
    "serv_fit rescue")

write(PLANNER, t)
print("patched: service rooms take the smallest adequate cell")
