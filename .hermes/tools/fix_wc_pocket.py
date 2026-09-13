# WC-sized pockets + tighter circulation bands (anchors from the live file).
#
# 1. The pocket trigger was aligned to the validator's ceiling
#    (maxf(6.0, 0.13 * floor_area)) instead of to what a WC is: on a 163 m2
#    warehouse plate 0.13 * total = 21.2, so a 21.0 m2 toilet passed untouched
#    and 124 WCs over 8 m2 survived. A WC over its OWN declared maximum is
#    mis-sized whatever the floor area is. The pocket target likewise aims at
#    the declared maximum instead of 6% of the floor.
# 2. The surplus a pocket leaves became 'storage' unconditionally (10 m2 store
#    rooms sprinkled through the plans); it is a room, so it takes the kind the
#    floor is already made of, with storage as the fallback.
# 3. Circulation is 0.362 of archetype floors against 0.10-0.20 for real
#    housing. The stair band in _slice_rooms (3.0 x 0.32 -> 2.6 x 0.26) and the
#    entrance hall of the wide-plate grammar (0.30 -> 0.24 of plate depth) are
#    capped tighter, so the freed depth goes to the rooms on either side.

import io
import sys

PLANNER = 'world/generation/floorplan/floor_plan_planner.gd'

HELPER = '''## What the floor left over after a service pocket becomes. A spare room of the
## kind the floor is already made of is still a room -- another office on an
## office floor, another sleeping room in a flat. Storage is the fallback.
static func _pocket_fill_kind(frame: FloorPlanFrame, cells: Array, rect: Rect2) -> StringName:
	var probe := {"kind": &"room", "rect": rect, "circ": false,
			"facade": frame.facade_edges_of(rect),
			"flen": frame.facade_length_of(rect)}
	var counts := {}
	for c: Dictionary in cells:
		if bool(c["circ"]):
			continue
		var k: StringName = c["kind"]
		if FloorProgram.is_service(k):
			continue
		probe["kind"] = k
		if not _can_host(k, probe):
			continue
		counts[k] = int(counts.get(k, 0)) + 1
	var best: StringName = &""
	var best_n := 0
	for k2 in counts:
		if int(counts[k2]) > best_n:
			best_n = int(counts[k2])
			best = k2
	if best != &"" and _can_host(best, probe):
		return best
	probe["kind"] = &"storage"
	if _can_host(&"storage", probe):
		return &"storage"
	return &"landing"


static func _service_pockets(frame: FloorPlanFrame, cells: Array) -> void:'''

EDITS = [
    (
        """		var area := r.size.x * r.size.y
		# The same ceiling the validator gates on: a service room may take
		# neither more than its declared maximum nor a slice of the floor.
		if area <= maxf(float(spec["max_area"]), 0.13 * total):
			continue
		var target := clampf(maxf(float(spec["max_area"]), 0.06 * total),
				2.6, area * 0.45)""",
        """		var area := r.size.x * r.size.y
		# A WC past its own declared maximum is mis-sized, whatever the floor
		# area is: the validator's 13% ceiling still tolerates a 21 m2 toilet on
		# a 163 m2 warehouse plate, and a 21 m2 toilet is not a toilet.
		if area <= float(spec["max_area"]) * 1.05:
			continue
		var target := clampf(float(spec["max_area"]), 2.6, area * 0.45)""",
    ),
    (
        """		# The remainder is spare floor, not a second WC: storage is the same
		# filler the assignment already uses for cells left over.
		var probe := {"kind": &"storage", "rect": keep, "circ": false}
		c["rect"] = keep
		c["kind"] = &"storage" if _can_host(&"storage", probe) else &"landing\"""",
        """		# The remainder is spare floor, not a second WC: it becomes a room of
		# the kind this floor is already made of, storage only as a last resort,
		# which is the filler the assignment itself falls back on.
		c["rect"] = keep
		c["kind"] = _pocket_fill_kind(frame, cells, keep)""",
    ),
    (
        """static func _service_pockets(frame: FloorPlanFrame, cells: Array) -> void:""",
        HELPER,
    ),
    (
        """	var band := clampf(maxf(core.size.y, 2.4), 2.4, minf(3.0, maxf(2.4, zone.size.y * 0.32)))""",
        """	var band := clampf(maxf(core.size.y, 2.4), 2.4, minf(2.6, maxf(2.2, zone.size.y * 0.26)))""",
    ),
    (
        """		var hall_d := clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.30))""",
        """		var hall_d := clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.24))""",
    ),
]


def main() -> int:
    raw = io.open(PLANNER, encoding='utf-8').read()
    crlf = '\r\n' in raw
    t = raw.replace('\r\n', '\n') if crlf else raw
    ok = True
    for i, (old, new) in enumerate(EDITS):
        n = t.count(old)
        print('edit %d: %d match(es)' % (i + 1, n))
        if n != 1:
            ok = False
            continue
        t = t.replace(old, new, 1)
    if not ok:
        print('FAIL: an anchor did not match exactly once; nothing written')
        return 1
    io.open(PLANNER, 'w', encoding='utf-8', newline='').write(
        t.replace('\n', '\r\n') if crlf else t)
    print('wrote all %d edits' % len(EDITS))
    return 0


if __name__ == '__main__':
    sys.exit(main())
