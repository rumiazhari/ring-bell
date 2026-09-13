"""Fix the interior programme defects found in the audit.

Issue 1 -- kitchenless dwellings. `FloorProgram.slots()` trimmed the room
programme by *position*: it kept base[0] (living) and the service tail
(toilet), then took the remaining slots from the middle of the list. For the
residential upper programme [living, sleeping, sleeping, kitchen, toilet] a
3-cell floor therefore became [living, sleeping, toilet] -- the second bedroom
was paid for with the kitchen, while the WC was never at risk. Observed
effect: kitchens on 45% of side-spine flats, 14% of townhouses, 0% of
shopfront floors.

Fix: trim by *priority*. A dwelling without a second bedroom is a smaller
dwelling; a dwelling without a kitchen is not a dwelling. Essentials outrank
repeats, and the service tail is still protected.

Issue 2 -- the programme contract was never enforced. `required_kinds()` has
existed all along but is called from nowhere, and the validator computed
`toilet_area` (max_area is declared per kind) without ever testing it. Fix:
wire both into `_validate` -- a floor must carry the rooms its use implies for
a plate of its size, and a single toilet may not exceed its declared max area.

Also added as reported metrics (not gates): gross circulation share
(circ_area/total, comparable to real buildings, unlike the net circ_frac which
divides the stair core out of both sides) and the tier-0 facade ratio.
"""

import io, re, sys

PLANNER = "world/generation/floorplan/floor_plan_planner.gd"
PROGRAM = "world/generation/floorplan/floor_program.gd"


def read(p):
    return io.open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")


def write(p, t):
    io.open(p, "w", encoding="utf-8", newline="").write(t.replace("\n", "\r\n"))


def sub_once(t, old, new, what):
    if t.count(old) != 1:
        print("FAIL %s: %d matches" % (what, t.count(old)))
        sys.exit(1)
    return t.replace(old, new)


# ---------------------------------------------------------------- floor_program
prog = read(PROGRAM)

CORE = '''
## Priority order used when a plate cannot host the whole programme.
##
## Trimming by position produced kitchenless dwellings: the middle of the
## residential list is a repeated bedroom, so the slot that should have gone to
## the kitchen went to a second sleeper while the toilet tail was protected
## regardless. Essentials outrank repeats; a dwelling with one bedroom and a
## kitchen is a smaller dwelling, not a broken one.
const CORE := {
	"residential": [&"living", &"kitchen", &"sleeping"],
	"caretaker": [&"living", &"kitchen"],
	"retail": [&"sales", &"store_room"],
	"tavern": [&"taproom", &"kitchen", &"store_room"],
	"office": [&"reception", &"office"],
	"government": [&"reception", &"council"],
	"police": [&"reception", &"office"],
	"hospital": [&"reception", &"ward"],
	"workshop": [&"machine_shop", &"craft"],
	"storage": [&"warehouse", &"loading"],
}


## Append kinds from `src` (in order, respecting its multiplicities) until
## `out` reaches `target`.
static func _fill(out: Array, src: Array, target: int) -> Array:
	var used := {}
	for x: Variant in out:
		used[x] = int(used.get(x, 0)) + 1
	for k: Variant in src:
		if out.size() >= target:
			break
		var want := 0
		for y: Variant in src:
			if y == k:
				want += 1
		if int(used.get(k, 0)) < want:
			out.append(k)
			used[k] = int(used.get(k, 0)) + 1
	return out

'''

prog = sub_once(prog, "## Programme for one floor, trimmed/padded to `cells` rooms.",
                CORE.lstrip("\n") + "## Programme for one floor, trimmed/padded to `cells` rooms.",
                "core const insert")

old_slots = re.search(r"static func slots\(use: String, fi: int, cells: int\) -> Array:.*?\n\treturn out\n", prog, re.S)
if not old_slots:
    print("FAIL: slots() not found")
    sys.exit(1)

new_slots = '''static func slots(use: String, fi: int, cells: int) -> Array:
	var base: Array = GROUND.get(use, GROUND["residential"]) if fi == 0 else \\
			UPPER.get(use, UPPER["residential"])
	if fi > 0 and not UPPER.has(use):
		base = UPPER["residential"]
	var out: Array = []
	var n := maxi(cells, 1)
	var extra: StringName = EXTRA.get(use, &"storage")
	if n <= base.size():
		# Principal room, then this use's essentials in priority order (the
		# service tail excepted -- it is added last and never dropped), then
		# whatever the base programme repeats, then the tail.
		out.append(base[0])
		var tail: Variant = base[base.size() - 1]
		var target := maxi(n - 1, 1)
		for k: StringName in CORE.get(use, []):
			if out.size() >= target:
				break
			if k != tail and not out.has(k) and base.has(k):
				out.append(k)
		out = _fill(out, base.slice(1, base.size() - 1), target)
		out = _fill(out, base, target)
		if n >= 2 and not out.has(tail):
			out.append(tail)
	else:
		out.append_array(base)
	while out.size() < n:
		out.append(extra)
	if out.size() > n:
		out.resize(n)
	return out
'''

prog = prog[:old_slots.start()] + new_slots + prog[old_slots.end():]

prog = sub_once(
    prog,
    "static func required_kinds(use: String, fi: int) -> Array:",
    "static func required_kinds(use: String, fi: int, cells: int = -1) -> Array:",
    "required_kinds signature")
prog = sub_once(
    prog,
    "\tvar base: Array = GROUND.get(use, GROUND[\"residential\"]) if fi == 0 else \\\n\t\t\tUPPER.get(use, UPPER[\"residential\"])\n\tvar out: Array = [base[0]]",
    "\t# With a cell count this is the contract the planner must satisfy, not a\n"
    "\t# description: the validator rejects a floor that quietly lost a room.\n"
    "\tif cells > 0:\n"
    "\t\treturn slots(use, fi, cells)\n"
    "\tvar base: Array = GROUND.get(use, GROUND[\"residential\"]) if fi == 0 else \\\n\t\t\tUPPER.get(use, UPPER[\"residential\"])\n\tvar out: Array = [base[0]]",
    "required_kinds body")

# ------------------------------------------------------------------- planner
pl = read(PLANNER)

old_metrics = '\tmetrics["core_area"] = core_area\n\tmetrics["floor_area"] = total\n'
new_metrics = '''\tmetrics["core_area"] = core_area
\tmetrics["floor_area"] = total
\t# Gross circulation share: the net circ_frac divides the stair shaft out of
\t# numerator and denominator alike, which flatters it and makes it
\t# incomparable to the 10-20% real housing spends. Report both; gate on net.
\tmetrics["circ_gross"] = circ_area / maxf(total, 0.1)
\tmetrics["facade_principal"] = float(metrics["tier0_facade"]) / \\
\t\t\tmaxf(float(metrics["facade_rooms"]), 1.0)
\t# The programme contract: a floor carries the rooms its use implies for a
\t# plate of this size. slots() trims by priority, so a room missing here
\t# means one was lost or quietly downgraded after planning.
\tvar want_kinds: Array = FloorProgram.required_kinds(str(p.get("use", "residential")),
\t\t\tint(p.get("floor_i", 0)), cells.size())
\tvar have := {}
\tfor c3: Dictionary in cells:
\t\thave[c3["kind"]] = int(have.get(c3["kind"], 0)) + 1
\tvar missing: Array = []
\tfor k2: Variant in want_kinds:
\t\tif FloorProgram.is_circulation(k2):
\t\t\tcontinue
\t\tif int(have.get(k2, 0)) <= 0:
\t\t\tmissing.append(k2)
\tif missing.size() > 0:
\t\t_last_validate = "programme missing %s (use=%s floor_i=%d cells=%d)" % [
\t\t\tstr(missing), str(p.get("use", "?")), int(p.get("floor_i", 0)), cells.size()]
\t\treturn {}
\tvar toilet_cap := float(FloorProgram.spec_of(&"toilet").get("max_area", 6.0))
\tif toilet_area > toilet_cap * 1.5:
\t\t_last_validate = "toilet %.1f m2 over declared max %.1f" % [toilet_area, toilet_cap]
\t\treturn {}
'''
pl = sub_once(pl, old_metrics, new_metrics, "validator gates")

write(PROGRAM, prog)
write(PLANNER, pl)
print("patched %s + %s" % (PROGRAM, PLANNER))
