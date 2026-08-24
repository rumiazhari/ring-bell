class_name InteriorProbe
extends RefCounted
## Deterministic interior-state detection (P1).
##
## Replaces the generously-grown footprint check with REAL geometric tests:
##   - XZ inside the building's actual interior boundary (footprint shrunk
##     by the wall thickness) - standing IN a wall or doorway threshold is
##     not "inside";
##   - Y must correspond to a valid storey of this building: within
##     [floor_i*fh - SLAB_T, floor_i*fh + fh] for some floor_i < n, or on
##     the roof deck [n*fh - SLAB_T, n*fh + PARAPET];
##   - small hysteresis band so jitter at the boundary cannot toggle the
##     state every frame.
##
## Pure static math - unit-testable without a scene tree.

const WALL_T := 0.35          # keep in sync with BuildingBuilder.WALL_T
const SLAB_T := 0.22          # keep in sync with BuildingBuilder.SLAB_T
const ROOF_MARGIN := 1.2      # how far above the deck still counts as roof
const ENTER_EPS := 0.05       # extra margin required to ENTER
const EXIT_EPS := 0.30        # allowed overhang before EXITING


## Interior test with hysteresis. `was_inside` is the previous state.
## Returns {inside: bool, floor: int}  floor = -1 when not inside;
## floor == n means the roof deck.
static func evaluate(xz: Vector2, y: float, spec: Dictionary,
		was_inside: bool) -> Dictionary:
	var fp: Rect2 = spec["rect"]
	var fh := float(spec["floor_h"])
	var n := mini(int(spec["floors"]), 8)

	# Interior XZ boundary with hysteresis: entering demands a point clearly
	# past the wall face (WALL_T + ENTER_EPS); leaving tolerates a small
	# overhang back into the wall band (WALL_T - EXIT_EPS) before the state
	# flips - threshold jitter cannot toggle the state every frame.
	var shrink := WALL_T + (ENTER_EPS if not was_inside else -EXIT_EPS)
	shrink = maxf(shrink, 0.0)
	var inner := fp.grow(-shrink)
	if not inner.has_point(xz):
		return {"inside": false, "floor": -1}

	# Valid storey under the feet: slab top of level i sits at i*fh.
	# A point belongs to storey i while y is in [i*fh - SLAB_T, (i+1)*fh).
	var rel := y + SLAB_T * 0.5
	if rel < 0.0:
		return {"inside": false, "floor": -1}
	var fi := int(floor(rel / fh))
	if fi > n:
		return {"inside": false, "floor": -1}
	if fi == n and y > n * fh + ROOF_MARGIN:
		return {"inside": false, "floor": -1}
	return {"inside": true, "floor": fi}


## Which camera-facing facades to fade for an inside observer at xz.
## A facade fades when its outward normal points TOWARD the camera
## horizontally, i.e. dot(normal, cam_dir_xz) > 0.35 (some tolerance so
## near-axis views do not flicker two walls at once). Returns subset of
## ["N", "E", "S", "W"].
static func faded_facades(xz: Vector2, cam_pos: Vector2) -> Array:
	var out: Array = []
	var dir := cam_pos - xz
	if dir.length_squared() < 0.0001:
		return out
	dir = dir.normalized()
	if dir.y < -0.35:      # camera north of us: its view enters through N
		out.append("N")
	if dir.x > 0.35:
		out.append("E")
	if dir.y > 0.35:
		out.append("S")
	if dir.x < -0.35:
		out.append("W")
	return out


## Layer key suffix for one facade of one storey: "<storey>:<facade>".
static func facade_suffix(floor_i: int, facade: String) -> String:
	return "%d:%s" % [floor_i, facade]
