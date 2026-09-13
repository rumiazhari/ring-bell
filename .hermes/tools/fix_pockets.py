# Service pocket + circulation rebalance.
#
# 1. _service_pockets(): a service room (the WC) that has taken a cell far
#    bigger than its declared max_area is split into a correctly sized pocket
#    plus a remainder room. Previously such a cell tripped the validator's
#    hard gate `toilet_area > maxf(6.5, 0.13 * total)`, which threw the whole
#    archetype plan away -- 125 of 312 floors fell back to the legacy interior
#    for exactly this reason. Shrinking the WC is the fix; relaxing the gate
#    would leave room-sized toilets in the product.
# 2. Two circulation bands are capped tighter so room bands get deeper: the
#    hall was pinned at its 0.40*D ceiling, leaving 2.4-2.6 m slabs of room.

import io
import sys

PLANNER = 'world/generation/floorplan/floor_plan_planner.gd'

NEW_FUNC = '''## Service pocket.
##
## A WC is a small room, but on a deep plate every cell the band grammar makes
## is a 15-21 m2 slab. The toilet slot takes one of those, and the validator --
## correctly -- refuses a WC that eats 13% of the floor, so the whole archetype
## plan was discarded and the building fell back to the legacy interior. Taking
## the surplus away is the fix, not a looser gate: the cell is split, the WC
## keeps a pocket of its own size, and the rest of the cell stays a room. The
## pocket spans the cell's full width (or height), so it keeps the edge it had
## on the hall and still takes its own door off circulation.
static func _service_pockets(frame: FloorPlanFrame, cells: Array) -> void:
\tvar total := 0.0
\tfor c0: Dictionary in cells:
\t\tvar r0: Rect2 = c0["rect"]
\t\ttotal += r0.size.x * r0.size.y
\tif total <= 0.0:
\t\treturn
\tvar extra: Array = []
\tfor c: Dictionary in cells:
\t\tif bool(c["circ"]):
\t\t\tcontinue
\t\tvar k: StringName = c["kind"]
\t\tvar spec := FloorProgram.spec_of(k)
\t\tif not bool(spec.get("service", false)) or not spec.has("max_area"):
\t\t\tcontinue
\t\tvar r: Rect2 = c["rect"]
\t\tvar area := r.size.x * r.size.y
\t\t# The same ceiling the validator gates on: a service room may take
\t\t# neither more than its declared maximum nor a slice of the floor.
\t\tif area <= maxf(float(spec["max_area"]), 0.13 * total):
\t\t\tcontinue
\t\tvar target := clampf(maxf(float(spec["max_area"]), 0.06 * total),
\t\t\t\t2.6, area * 0.45)
\t\tvar rem_side := FloorProgram.min_side(&"storage")
\t\tvar side_min := FloorProgram.min_side(k)
\t\tvar pocket := Rect2()
\t\tvar keep := Rect2()
\t\tvar d := clampf(target / maxf(r.size.x, 0.1), side_min, 2.35)
\t\tif r.size.y - d >= rem_side:
\t\t\tpocket = Rect2(r.position.x, r.end.y - d, r.size.x, d)
\t\t\tkeep = Rect2(r.position.x, r.position.y, r.size.x, r.size.y - d)
\t\telse:
\t\t\tvar w := clampf(target / maxf(r.size.y, 0.1), side_min, 2.35)
\t\t\tif r.size.x - w < rem_side:
\t\t\t\tcontinue
\t\t\tpocket = Rect2(r.end.x - w, r.position.y, w, r.size.y)
\t\t\tkeep = Rect2(r.position.x, r.position.y, r.size.x - w, r.size.y)
\t\t# The remainder is spare floor, not a second WC: storage is the same
\t\t# filler the assignment already uses for cells left over.
\t\tvar probe := {"kind": &"storage", "rect": keep, "circ": false}
\t\tc["rect"] = keep
\t\tc["kind"] = &"storage" if _can_host(&"storage", probe) else &"landing"
\t\tc["tier"] = int(FloorProgram.spec_of(c["kind"]).get("tier", 3))
\t\tc["facade"] = frame.facade_edges_of(keep)
\t\tc["flen"] = frame.facade_length_of(keep)
\t\tvar pc := _cell(k, pocket, false)
\t\tpc["facade"] = frame.facade_edges_of(pocket)
\t\tpc["flen"] = frame.facade_length_of(pocket)
\t\tpc["tier"] = int(spec.get("tier", 3))
\t\textra.append(pc)
\tfor e: Dictionary in extra:
\t\tcells.append(e)


'''

OLD_CALL = '\treturn {}\n\tvar bnd := _boundaries(cells)'
NEW_CALL = '\treturn {}\n\t# A service room too big for its own kind is shrunk before the walls\n\t# and doors are derived, so the pocket is a real room with a real door.\n\t_service_pockets(frame, cells)\n\tvar bnd := _boundaries(cells)'

OLD_HALL = 'clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.40))'
NEW_HALL = 'clampf(maxf(front_d, 1.6), 1.6, maxf(1.6, D * 0.30))'

OLD_BAND = 'var band := clampf(maxf(core.size.y, 2.4), 2.4, minf(3.8, maxf(2.4, zone.size.y * 0.45)))'
NEW_BAND = 'var band := clampf(maxf(core.size.y, 2.4), 2.4, maxf(core.size.y, minf(3.0, maxf(2.4, zone.size.y * 0.32))))'

ANCHOR_DEF = 'static func _boundaries(cells: Array) -> Dictionary:'


def main() -> int:
    raw = io.open(PLANNER, encoding='utf-8').read()
    crlf = '\r\n' in raw
    t = raw.replace('\r\n', '\n') if crlf else raw

    for name, old, new in (
            ('call', OLD_CALL, NEW_CALL),
            ('hall_cap', OLD_HALL, NEW_HALL),
            ('stair_band', OLD_BAND, NEW_BAND),
            ('func_def', ANCHOR_DEF, NEW_FUNC + ANCHOR_DEF),
    ):
        n = t.count(old)
        print('%-11s matches=%d' % (name, n))
        if n != 1:
            print('FAIL: anchor %s matched %d times' % (name, n))
            return 1
        t = t.replace(old, new, 1)

    out = t.replace('\n', '\r\n') if crlf else t
    io.open(PLANNER, 'w', encoding='utf-8', newline='').write(out)
    print('patched', PLANNER, len(raw), '->', len(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
