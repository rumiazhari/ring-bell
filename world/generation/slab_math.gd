class_name SlabMath
extends RefCounted
## Deterministic rectangle-subtraction helpers for slab/facade apertures.
##
## subtract_rect(a, hole) returns the four non-overlapping strips around the
## hole (N/S/W/E in rect-local terms), clamped to `a`. The union of the strips
## equals EXACTLY a minus intersection(a, hole): no gaps, no overlaps, no
## slivers - degenerate strips are dropped. Pure static math so tests can
## verify coverage numerically without any scene tree.

const EPS := 0.001


## The up-to-four strips of `a` outside `hole`. Order: N (y-low), S (y-high),
## W (x-low), E (x-high) - matching BuildingBuilder's facade encoding.
static func subtract_rect(a: Rect2, hole: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if a.size.x <= EPS or a.size.y <= EPS:
		return out
	# Clip the hole to `a`; a hole that misses entirely changes nothing.
	var h := a.intersection(hole)
	if h.size.x <= 0.0 or h.size.y <= 0.0:
		return [a]
	# North strip: full width, below the hole.
	_push_rect(out, Rect2(a.position.x, a.position.y,
			a.size.x, h.position.y - a.position.y))
	# South strip: full width, above the hole.
	_push_rect(out, Rect2(a.position.x, h.end.y,
			a.size.x, a.end.y - h.end.y))
	# West strip: between hole's y-span and the west edge.
	_push_rect(out, Rect2(a.position.x, h.position.y,
			h.position.x - a.position.x, h.size.y))
	# East strip: between hole's y-span and the east edge.
	_push_rect(out, Rect2(h.end.x, h.position.y,
			a.end.x - h.end.x, h.size.y))
	return out


## Union area of non-overlapping rects.
static func total_area(rects: Array[Rect2]) -> float:
	var s := 0.0
	for r in rects:
		s += r.get_area()
	return s


## Pairwise-overlap check: true when no two rects share interior area.
static func overlaps_any(rects: Array[Rect2]) -> bool:
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var x := rects[i].intersection(rects[j])
			if x.size.x > EPS and x.size.y > EPS:
				return true
	return false


## Point-in-any-rect test with an inclusive tolerance band on edges
## (used to classify a sample as "covered" vs "in the aperture").
static func covers_point(rects: Array[Rect2], p: Vector2) -> bool:
	for r in rects:
		if r.has_point(p):
			return true
	return false


static func _push_rect(out: Array[Rect2], r: Rect2) -> void:
	if r.size.x > EPS and r.size.y > EPS:
		out.append(r)
