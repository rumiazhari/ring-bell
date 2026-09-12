class_name FloorPlanFrame
extends RefCounted
## Canonical local floor-plan frame.
##
## Every archetype plans inside ONE local rectangle whose origin is the
## entrance, local +y runs inward (away from the entrance facade) and local
## +x runs "right" along the facade. That lets the archetypes be written once
## in a single orientation and then be fitted to any footprint/entrance edge
## (and optionally mirrored) by this frame instead of nine special cases.
##
## The frame is a pure transform on the unrotated plan frame that
## `InteriorPlan` already uses for room rects and door positions:
##   plan_point = (local_point + origin).x * ex + (local_point + origin).y * ey
## with (ex, ey) a signed axis pair and det(ex, ey) == +1 so no accidental
## mirror is introduced. Mirroring (archetype variety) negates ex only.
##
## All members are plain data; nothing here allocates or searches.

## Wall half-thickness used by InteriorPlan when it builds partitions.
const WALL_T := 0.18
## Interior inset from the footprint edge to the inner wall face.
const INSET := 0.37

const EDGE_FRONT := 0
const EDGE_BACK := 1
const EDGE_RIGHT := 2
const EDGE_LEFT := 3

## Plan-frame facade edges (raw building frame).
const PE_N := 0
const PE_E := 1
const PE_S := 2
const PE_W := 3

var rect := Rect2()          ## footprint (plan frame)
var inner := Rect2()         ## interior inner wall faces (plan frame)
var size := Vector2.ZERO     ## local size (x along facade, y inward)
var ex := Vector2.RIGHT      ## local +x in plan frame (may be mirrored)
var ey := Vector2.DOWN       ## local +y in plan frame (always inward)
var origin := Vector2.ZERO
var mirrored := false
var door_edge := 0           ## plan-frame edge that holds the entrance (0..3)
var yaw := 0.0               ## building yaw (radians, Godot y-down convention)
var face_open: Array[bool] = [true, true, true, true]  ## by local edge
var core := Rect2()          ## stair zone, local frame (empty when no stairs)
var has_core := false

## Inputs, all in the plan frame:
##   rect:Rect2, door_edge:int, yaw:float, core:Rect2, entry_box:Rect2,
##   open_by_plan_edge:Array[bool] (4 entries), mirrored:bool
static func build(p: Dictionary) -> FloorPlanFrame:
	var f := FloorPlanFrame.new()
	f.rect = p.get("rect", Rect2(0.0, 0.0, 10.0, 10.0))
	f.inner = Rect2(f.rect.position + Vector2(INSET, INSET),
			f.rect.size - Vector2(INSET * 2.0, INSET * 2.0))
	f.door_edge = int(p.get("door_edge", 0))
	f.yaw = float(p.get("yaw", 0.0))
	f.mirrored = bool(p.get("mirrored", false))
	match f.door_edge:
		1:
			f.ex = Vector2(0.0, 1.0)
			f.ey = Vector2(-1.0, 0.0)
		2:
			f.ex = Vector2(-1.0, 0.0)
			f.ey = Vector2(0.0, -1.0)
		3:
			f.ex = Vector2(0.0, -1.0)
			f.ey = Vector2(1.0, 0.0)
		_:
			f.ex = Vector2(1.0, 0.0)
			f.ey = Vector2(0.0, 1.0)
	if f.mirrored:
		f.ex = -f.ex
	# Local origin = min corner of the mapped inner rect, so local coordinates
	# always run 0..size even when the frame is mirrored (ex negated) - without
	# this the mirrored frame would map to -size..0 and every archetype written
	# for 0..size would silently fail on one of the two orientations.
	var lo := Vector2(f.inner.position.dot(f.ex), f.inner.position.dot(f.ey))
	var hi := Vector2(f.inner.end.dot(f.ex), f.inner.end.dot(f.ey))
	f.origin = Vector2(minf(lo.x, hi.x), minf(lo.y, hi.y))
	f.size = (hi - lo).abs()
	# Facade openness per local edge. Interior faces of an attached (party)
	# wall must not be treated as windows.
	var open: Array = p.get("open_by_plan_edge", [true, true, true, true])
	var right_pe := PE_E
	if f.door_edge == 1 or f.door_edge == 3:
		right_pe = PE_W
	if f.mirrored:
		right_pe = PE_W if right_pe == PE_E else PE_E
	var left_pe := PE_W if right_pe == PE_E else PE_E
	var back_pe := _opposite(f.door_edge)
	f.face_open[EDGE_FRONT] = bool(open[f.door_edge]) if open.size() > f.door_edge else true
	f.face_open[EDGE_BACK] = bool(open[back_pe]) if open.size() > back_pe else true
	f.face_open[EDGE_RIGHT] = bool(open[right_pe]) if open.size() > right_pe else true
	f.face_open[EDGE_LEFT] = bool(open[left_pe]) if open.size() > left_pe else true
	var core_plan: Rect2 = p.get("core", Rect2())
	if core_plan.size.x > 0.5 and core_plan.size.y > 0.5:
		f.core = f.rect_to_local(core_plan)
		f.has_core = true
	return f


static func _opposite(edge: int) -> int:
	match edge:
		0:
			return 2
		1:
			return 3
		2:
			return 0
		_:
			return 1


func to_plan(p: Vector2) -> Vector2:
	var q := p + origin
	return q.x * ex + q.y * ey


func to_local(p: Vector2) -> Vector2:
	var q := Vector2(p.dot(ex), p.dot(ey))
	return q - origin


## Map an axis-aligned rect from a start/end pair (bounds, so a mirrored
## frame - where the mapping flips the axis - still yields a positive size).
static func _bounds(a: Vector2, b: Vector2) -> Rect2:
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	return Rect2(lo, hi - lo)


func rect_to_plan(r: Rect2) -> Rect2:
	return _bounds(to_plan(r.position), to_plan(r.end))


func rect_to_local(r: Rect2) -> Rect2:
	return _bounds(to_local(r.position), to_local(r.end))


func center_local() -> Vector2:
	return size * 0.5


## Local edge indexes of `r` that sit on the plan boundary (within `tol`) and
## whose facade is usable. Used for facade-preference scoring.
func facade_edges_of(r: Rect2, tol := 0.06) -> Array[int]:
	var out: Array[int] = []
	if r.position.y <= tol and face_open[EDGE_FRONT]:
		out.append(EDGE_FRONT)
	if r.end.y >= size.y - tol and face_open[EDGE_BACK]:
		out.append(EDGE_BACK)
	if r.position.x <= tol and face_open[EDGE_LEFT]:
		out.append(EDGE_LEFT)
	if r.end.x >= size.x - tol and face_open[EDGE_RIGHT]:
		out.append(EDGE_RIGHT)
	return out


func facade_length_of(r: Rect2, tol := 0.06) -> float:
	var total := 0.0
	for e in facade_edges_of(r, tol):
		match e:
			EDGE_FRONT, EDGE_BACK:
				total += r.size.x
			_:
				total += r.size.y
	return total


func clamp_to_inner(r: Rect2) -> Rect2:
	var p := Vector2(maxf(r.position.x, 0.0), maxf(r.position.y, 0.0))
	var e := Vector2(minf(r.end.x, size.x), minf(r.end.y, size.y))
	return Rect2(p, (e - p).max(Vector2.ZERO))


func describe() -> String:
	return "frame edge=%d mirror=%s size=%.2fx%.2f core=%s open=%s" % [
		door_edge, str(mirrored), size.x, size.y, str(core), str(face_open)]
