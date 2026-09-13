"""Second fix pass: candidate starvation + the programme gate's cell count.

Run 24 exposed both, honestly: the probe reported "0 failure(s)" while planning
*zero* archetype floors, because every floor fell back to legacy. That is the
exact trap the brief warns about -- green tests, bad output.

(a) The programme gate asked slots() for a programme sized by `cells.size()`,
    which counts circulation cells too. A floor of 4 rooms + 2 circulation
    cells was therefore required to carry a 6-room programme, so *every* plan
    was rejected. It must count the room cells only, the same number `_assign`
    uses.

(b) Archetype selection stopped after 3 candidates (`if candidates.size() >= 3:
    break`). Each archetype contributes two mirrorings, so the first applicable
    archetype consumed the whole list and archetypes declared later were never
    even constructed. That is why prague_deep_tenement, office_corridor_suite,
    tavern_taproom_ground and warehouse_loading_ground won 0 of 312 floors
    while still being applicable to plates in the probe's own footprint zoo --
    and why they never appeared in a reject log either: `last_reject` only
    holds the final candidate's reason.

(c) With the whole list explored, add an explicit priority so the specific
    archetype beats the generic fallback for the plate it was written for,
    instead of relying on incidental score differences.

(d) Keep a per-floor list of candidate rejections so a losing archetype's
    reason is visible, not just the last one tried.
"""

import io, sys

PLANNER = "world/generation/floorplan/floor_plan_planner.gd"

PRIORITY = {
    # generic fallbacks: applicable to any plate of their role
    "prague_side_spine_flat": 0,
    "shopfront_rear_service": 0,
    "civic_reception_hall": 0,
    "workshop_hall_ground": 0,
    # written for a particular plate shape or programme
    "prague_narrow_townhouse": 1,
    "prague_deep_tenement": 1,
    "office_corridor_suite": 1,
    "tavern_taproom_ground": 1,
    "warehouse_loading_ground": 1,
    # gated on a measured footprint property, so they cannot be generic
    "prague_compact_flat": 2,
    "courtyard_double_front": 2,
}


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

# (a) programme gate counts room cells, not all cells
t = sub_once(t,
    '\tvar want_kinds: Array = FloorProgram.required_kinds(str(p.get("use", "residential")),\n'
    '\t\t\tint(p.get("floor_i", 0)), cells.size())',
    '\tvar room_n := 0\n'
    '\tfor c4: Dictionary in cells:\n'
    '\t\tif not bool(c4["circ"]):\n'
    '\t\t\troom_n += 1\n'
    '\tvar want_kinds: Array = FloorProgram.required_kinds(str(p.get("use", "residential")),\n'
    '\t\t\tint(p.get("floor_i", 0)), room_n)',
    "programme gate cell count")

t = sub_once(t,
    '\t\t\tstr(missing), str(p.get("use", "?")), int(p.get("floor_i", 0)), cells.size()]',
    '\t\t\tstr(missing), str(p.get("use", "?")), int(p.get("floor_i", 0)), room_n]',
    "programme gate message")

# (b) stop starving the candidate list, and (c) apply priority
old_sel = '''	var role := FloorProgram.role_of(str(p.get("use", "residential")), int(p.get("floor_i", 0)))
	var candidates: Array = []
	for arch: Dictionary in ARCHETYPES:
		if not (role in arch["roles"]):
			continue
		if candidates.size() >= 3:
			break
		if not _applicable(arch, frame0, p):
			continue'''
new_sel = '''	var role := FloorProgram.role_of(str(p.get("use", "residential")), int(p.get("floor_i", 0)))
	var candidates: Array = []
	# Every applicable archetype is constructed. Capping this at three (and
	# adding both mirrorings of each archetype before moving on) meant the
	# first applicable archetype filled the list and the rest were never
	# built -- the reason four archetypes never won a single floor.
	for arch: Dictionary in ARCHETYPES:
		if not (role in arch["roles"]):
			continue
		if not _applicable(arch, frame0, p):
			continue'''
t = sub_once(t, old_sel, new_sel, "candidate cap")

old_pick = '''	var best: Dictionary = candidates[0]
	var best_score := _score(best["cand"], best["frame"])
	for c: Dictionary in candidates:
		var s := _score(c["cand"], c["frame"])
		if s > best_score:
			best_score = s
			best = c'''
new_pick = '''	var best: Dictionary = candidates[0]
	var best_score := _pick_score(best)
	for c: Dictionary in candidates:
		var s := _pick_score(c)
		if s > best_score:
			best_score = s
			best = c'''
t = sub_once(t, old_pick, new_pick, "best pick")

t = sub_once(t,
    'static func _score(cand: Dictionary, frame: FloorPlanFrame) -> float:',
    '''## Selection score: quality first, then an explicit priority so that the
## archetype written for a plate shape outranks the generic fallback for it.
## Relying on incidental score differences is what let a generic archetype win
## 43% of all floors and a sister archetype win none.
static func _pick_score(c: Dictionary) -> float:
	return _score(c["cand"], c["frame"]) + float(c.get("arch", {}).get("priority", 0)) * 3.0


static func _score(cand: Dictionary, frame: FloorPlanFrame) -> float:''',
    "pick score fn")

# (d) remember why each candidate lost
t = sub_once(t,
    'static func _applicable(arch: Dictionary, frame: FloorPlanFrame, p: Dictionary) -> bool:',
    '''## Reasons the candidates for the floor currently being planned were
## rejected. `last_reject` keeps only the final one, which hid the fact that
## whole archetypes were being discarded unseen.
static var reject_log: Array = []


static func _applicable(arch: Dictionary, frame: FloorPlanFrame, p: Dictionary) -> bool:''',
    "reject log decl")

t = sub_once(t,
    '''			if cand.is_empty():
				continue''',
    '''			if cand.is_empty():
				if _last_validate != "":
					reject_log.append("%s%s: %s" % [str(arch["id"]),
							" (mirrored)" if mirrored else "", _last_validate])
				continue''',
    "reject log append")

for aid, pri in PRIORITY.items():
    old = '"id": "%s",' % aid
    new = '"id": "%s", "priority": %d,' % (aid, pri)
    t = sub_once(t, old, new, "priority " + aid)

write(PLANNER, t)
print("patched %s: candidate cap lifted, priority added, program gate fixed" % PLANNER)
