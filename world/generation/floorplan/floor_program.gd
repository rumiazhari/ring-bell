class_name FloorProgram
extends RefCounted
## Room programme (what the floor plan must contain) and room quality rules.
##
## This is the "room program" half of the floor-plan overhaul: given a building
## use and a floor index, it says which rooms that floor should contain, in
## priority order, and it holds the per-kind quality rules (minimum usable
## side, minimum area, whether the kind wants an exterior facade) that the
## planner uses to fit/validate a candidate plan.
##
## Rules are declared here so archetypes stay about *arrangement*, not about
## numbers sprinkled through the subdivision code.

## tier: 0 = principal public room, 1 = normal occupied room,
##       2 = secondary/served room, 3 = service room (toilet, store).
## facade: 2 = strongly wants an exterior wall, 1 = wants one, 0 = does not.
const KIND := {
	&"living": {"tier": 0, "min_side": 2.85, "min_area": 13.0, "facade": 2, "private": false, "service": false},
	&"sleeping": {"tier": 1, "min_side": 2.55, "min_area": 9.0, "facade": 1, "private": true, "service": false},
	&"kitchen": {"tier": 1, "min_side": 2.10, "min_area": 6.5, "facade": 1, "private": false, "service": false},
	&"toilet": {"tier": 3, "min_side": 1.15, "min_area": 1.4, "max_area": 6.0, "facade": 0, "private": true, "service": true},
	&"storage": {"tier": 3, "min_side": 1.45, "min_area": 2.4, "facade": 0, "private": false, "service": true},
	&"sales": {"tier": 0, "min_side": 3.40, "min_area": 16.0, "facade": 2, "private": false, "service": false},
	&"taproom": {"tier": 0, "min_side": 3.40, "min_area": 18.0, "facade": 2, "private": false, "service": false},
	&"office": {"tier": 1, "min_side": 2.55, "min_area": 8.0, "facade": 1, "private": false, "service": false},
	&"archive": {"tier": 3, "min_side": 1.80, "min_area": 4.0, "facade": 0, "private": false, "service": true},
	&"meeting": {"tier": 1, "min_side": 2.85, "min_area": 10.0, "facade": 1, "private": false, "service": false},
	&"reception": {"tier": 1, "min_side": 2.55, "min_area": 8.0, "facade": 1, "private": false, "service": false},
	&"holding": {"tier": 2, "min_side": 1.80, "min_area": 4.5, "facade": 0, "private": true, "service": true},
	&"ward": {"tier": 0, "min_side": 3.40, "min_area": 16.0, "facade": 2, "private": false, "service": false},
	&"surgery": {"tier": 1, "min_side": 2.55, "min_area": 9.0, "facade": 1, "private": false, "service": false},
	&"dispensary": {"tier": 2, "min_side": 1.80, "min_area": 4.5, "facade": 0, "private": false, "service": true},
	&"council": {"tier": 0, "min_side": 3.60, "min_area": 18.0, "facade": 2, "private": false, "service": false},
	&"workshop": {"tier": 1, "min_side": 2.85, "min_area": 10.0, "facade": 1, "private": false, "service": false},
	&"machine_shop": {"tier": 0, "min_side": 3.60, "min_area": 18.0, "facade": 2, "private": false, "service": false},
	&"toolstore": {"tier": 3, "min_side": 1.45, "min_area": 2.4, "facade": 0, "private": false, "service": true},
	&"craft": {"tier": 1, "min_side": 2.55, "min_area": 9.0, "facade": 1, "private": false, "service": false},
	&"warehouse": {"tier": 0, "min_side": 4.00, "min_area": 24.0, "facade": 2, "private": false, "service": false},
	&"store_room": {"tier": 3, "min_side": 1.60, "min_area": 3.0, "facade": 0, "private": false, "service": true},
	&"loading": {"tier": 2, "min_side": 2.40, "min_area": 7.0, "facade": 1, "private": false, "service": true},
	&"entry": {"tier": 9, "min_side": 1.20, "min_area": 2.0, "facade": 0, "private": false, "service": false},
	&"hall": {"tier": 9, "min_side": 1.20, "min_area": 2.0, "facade": 0, "private": false, "service": false},
	&"corridor": {"tier": 9, "min_side": 1.00, "min_area": 1.5, "facade": 0, "private": false, "service": false},
	&"landing": {"tier": 9, "min_side": 1.00, "min_area": 1.4, "facade": 0, "private": false, "service": false},
	&"stair_hall": {"tier": 9, "min_side": 1.00, "min_area": 1.2, "facade": 0, "private": false, "service": false},
}

## Rooms per use, ground floor (fi == 0). Ordered: principal first, the
## toilet/service tail last (the planner trims from the middle, never the tail).
const GROUND := {
	"residential": [&"living", &"kitchen", &"sleeping", &"toilet"],
	"caretaker": [&"living", &"kitchen", &"toilet"],
	"retail": [&"sales", &"store_room", &"workshop", &"toilet"],
	"tavern": [&"taproom", &"kitchen", &"store_room", &"toilet"],
	"office": [&"reception", &"office", &"archive", &"toilet"],
	"government": [&"reception", &"council", &"archive", &"toilet"],
	"police": [&"reception", &"office", &"holding", &"toilet"],
	"hospital": [&"reception", &"ward", &"dispensary", &"toilet"],
	"workshop": [&"machine_shop", &"craft", &"toolstore", &"toilet"],
	"storage": [&"warehouse", &"loading", &"store_room", &"toilet"],
}

## Rooms per use, upper floors.
const UPPER := {
	"residential": [&"living", &"sleeping", &"sleeping", &"kitchen", &"toilet"],
	"caretaker": [&"living", &"sleeping", &"kitchen", &"toilet"],
	"retail": [&"living", &"sleeping", &"kitchen", &"toilet"],
	"tavern": [&"sleeping", &"sleeping", &"living", &"toilet"],
	"office": [&"office", &"office", &"meeting", &"archive", &"toilet"],
	"government": [&"office", &"council", &"archive", &"toilet"],
	"police": [&"office", &"holding", &"archive", &"toilet"],
	"hospital": [&"ward", &"surgery", &"dispensary", &"toilet"],
	"workshop": [&"craft", &"craft", &"toolstore", &"toilet"],
	"storage": [&"store_room", &"archive", &"toolstore", &"toilet"],
}

## Kind used to pad a floor that has more usable cells than the program lists.
const EXTRA := {
	"residential": &"sleeping",
	"caretaker": &"sleeping",
	"retail": &"sleeping",
	"tavern": &"sleeping",
	"office": &"office",
	"government": &"office",
	"police": &"office",
	"hospital": &"surgery",
	"workshop": &"craft",
	"storage": &"store_room",
}

## What a floor of this use *is* (drives archetype applicability).
static func role_of(use: String, fi: int) -> StringName:
	match use:
		"retail", "tavern":
			return &"commercial" if fi == 0 else &"residential"
		"office", "government", "police", "hospital":
			return &"civic"
		"workshop", "storage":
			return &"work"
		_:
			return &"residential"


static func spec_of(kind: StringName) -> Dictionary:
	return KIND.get(kind, KIND[&"storage"])


static func is_circulation(kind: StringName) -> bool:
	var k: String = String(kind)
	return k == "hall" or k == "corridor" or k == "entry" or k == "landing" or k == "stair_hall"


static func wants_facade(kind: StringName) -> int:
	return int(spec_of(kind).get("facade", 0))


static func is_service(kind: StringName) -> bool:
	return bool(spec_of(kind).get("service", false))


static func min_side(kind: StringName) -> float:
	return float(spec_of(kind).get("min_side", 1.2))


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
## The rooms that make a floor what it is: without them the programme is
## not trimmed, it is broken. A dwelling with one bedroom and a kitchen is a
## smaller dwelling; a dwelling with a bedroom and no WC is not a dwelling.
static func is_essential(use: String, fi: int, kind: Variant) -> bool:
	var base: Array = GROUND.get(use, GROUND["residential"]) if fi == 0 else \
			UPPER.get(use, UPPER["residential"])
	if base.is_empty():
		return false
	if kind == base[base.size() - 1]:
		return true
	return CORE.get(use, []).has(kind)


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

## Programme for one floor, trimmed/padded to `cells` rooms.
static func slots(use: String, fi: int, cells: int) -> Array:
	var base: Array = GROUND.get(use, GROUND["residential"]) if fi == 0 else \
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


## Aggregate programme check used by the many-seed statistics: does the floor
## carry the rooms its use implies at this depth?
static func required_kinds(use: String, fi: int, cells: int = -1) -> Array:
	# With a cell count this is the contract the planner must satisfy, not a
	# description: the validator rejects a floor that quietly lost a room.
	if cells > 0:
		return slots(use, fi, cells)
	var base: Array = GROUND.get(use, GROUND["residential"]) if fi == 0 else \
			UPPER.get(use, UPPER["residential"])
	var out: Array = [base[0]]
	var tail: Variant = base[base.size() - 1]
	if not out.has(tail):
		out.append(tail)
	return out
