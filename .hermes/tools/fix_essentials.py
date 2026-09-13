"""Third fix pass: essential rooms are no longer downgraded into nothing.

`_assign` picks the best cell for a slot, but when no cell passes `_can_host`
it takes the least-bad cell and *renames the kind* (`_downgrade`). Run 25's
reject log showed the cost: whole floors rejected with

    programme missing [&"toilet"] (use=residential floor_i=3 cells=2)

because the WC's slot landed on a marginally tight cell and became storage.
The old comment defended the mechanism ("rather than forcing a 16 m2 kitchen
into a 1.4 m sliver") and it is right about slivers -- but applying it to the
rooms that make a floor what it is produces a dwelling with no WC and a civic
floor with no office.

Policy now: the essential rooms for a use and floor depth (its CORE list, plus
the programme's service tail) get a second, slightly relaxed host test before
the downgrade path is allowed to fire. The relaxation is capped at 0.95x
min_side / 0.85x min_area, i.e. it stays *inside* the validator's own sliver
tolerances (0.92x / 0.80x), so rescuing an essential room can never manufacture
a sliver. Anything genuinely impossible still downgrades.

Also: `reject_log` is cleared per floor -- it was growing for the whole run.
"""

import io
import sys

PROGRAM = "world/generation/floorplan/floor_program.gd"
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


# --------------------------------------------------------------- floor_program
prog = read(PROGRAM)
prog = sub_once(prog,
    "static func _fill(out: Array, src: Array, target: int) -> Array:",
    '''## The rooms that make a floor what it is: without them the programme is
## not trimmed, it is broken. A dwelling with one bedroom and a kitchen is a
## smaller dwelling; a dwelling with a bedroom and no WC is not a dwelling.
static func is_essential(use: String, fi: int, kind: Variant) -> bool:
	var base: Array = GROUND.get(use, GROUND["residential"]) if fi == 0 else \\
			UPPER.get(use, UPPER["residential"])
	if base.is_empty():
		return false
	if kind == base[base.size() - 1]:
		return true
	return CORE.get(use, []).has(kind)


static func _fill(out: Array, src: Array, target: int) -> Array:''',
    "is_essential")
write(PROGRAM, prog)

# ------------------------------------------------------------------- planner
t = read(PLANNER)

t = sub_once(t,
    "	var candidates: Array = []\n",
    "	var candidates: Array = []\n	reject_log.clear()\n",
    "reject_log clear")

t = sub_once(t,
    '''		var pick := best if best >= 0 else spare
		if pick < 0:
			continue''',
    '''		if best < 0 and FloorProgram.is_essential(str(p.get("use", "residential")),
				int(p.get("floor_i", 0)), kind):
			# Essential room, no cell that can host it comfortably: search again
			# with a slightly relaxed test before allowing the downgrade below.
			# A tight WC is a WC; a downgraded slot leaves the dwelling without
			# one, which is the failure this whole pass exists to stop.
			best_fit = -1.0e9
			for i in room_cells.size():
				if used.has(i) or bool(room_cells[i].get("locked", false)):
					continue
				var f2 := _fit(kind, room_cells[i], si)
				if _can_host_soft(kind, room_cells[i]) and f2 > best_fit:
					best_fit = f2
					best = i
		var pick := best if best >= 0 else spare
		if pick < 0:
			continue''',
    "essential rescue")

t = sub_once(t,
    "static func _pick_score(c: Dictionary) -> float:",
    '''## Relaxed host test, used only to keep an essential room on a floor whose
## cells are all marginally tight. The factors stay inside the validator's own
## sliver tolerances (0.92x min_side, 0.80x min_area), so a rescued room is
## still a legal room and the plan is not rejected for the rescue itself.
static func _can_host_soft(kind: StringName, cell: Dictionary) -> bool:
	var spec := FloorProgram.spec_of(kind)
	var r: Rect2 = cell["rect"]
	if minf(r.size.x, r.size.y) < float(spec.get("min_side", 1.2)) * 0.95:
		return false
	return r.size.x * r.size.y >= float(spec.get("min_area", 1.0)) * 0.85


static func _pick_score(c: Dictionary) -> float:''',
    "can_host_soft")

write(PLANNER, t)
print("patched: essential-room rescue + reject_log reset")
