class_name CityInteriorState
extends RefCounted
## Single authority for the city "player is inside a building" signal.
##
## One caller (world/main.gd) used to inline this: probe the buildings around
## the player with InteriorProbe (real interior boundary + valid storey +
## hysteresis), then feed the result to BOTH the cutaway floor gate and the
## gameplay camera's interior presentation. The camera's interior mode and the
## cutaway therefore always agree, and the camera-flutter harness
## (debug/q3_camera_interior_flutter.gd) exercises this exact path instead of a
## copy of it.
##
## Pure plan math - no scene tree, no RNG, deterministic.

## How far around the player to look for a building to test against. A building
## the player is inside always intersects this box, so the scan stays cheap.
const SEARCH_RADIUS_M := 1.5

## Extra room above a building's top storey that still counts as its shell when
## the camera asks whether a hit belongs to the building the player is inside
## (roof deck, parapet, bulkhead).
const SHELL_HEADROOM_M := 1.5

## Room below the building datum that still counts as the same shell (foundation
## and ground-floor slab).
const SHELL_FOOTROOM_M := 1.0


## Returns {inside: bool, floor: int, spec: Dictionary} for a world point.
## floor = -1 when outside; floor == int(spec["floors"]) means the roof deck.
## `ground_cache` memoises ChunkBuilder._grounded_spec per building id (the
## caller owns it so the cost is paid once, not per frame).
static func evaluate(city_plan: CityPlan, world_plan: WorldPlan, p3: Vector3,
		was_inside: bool, prev_tag: String, ground_cache: Dictionary) -> Dictionary:
	var out := {"inside": false, "floor": -1, "spec": {}}
	if city_plan == null:
		return out
	var p := Vector2(p3.x, p3.z)
	for candidate: Dictionary in city_plan.buildings_in_rect(
			Rect2(p - Vector2.ONE * SEARCH_RADIUS_M,
					Vector2.ONE * (SEARCH_RADIUS_M * 2.0))):
		var candidate_id := str(candidate.get("id", ""))
		if not ground_cache.has(candidate_id):
			ground_cache[candidate_id] = ChunkBuilder._grounded_spec(candidate, world_plan)
		var spec: Dictionary = ground_cache[candidate_id]
		var res: Dictionary = InteriorProbe.evaluate(p, p3.y, spec,
				was_inside and candidate_id == prev_tag)
		if bool(res["inside"]):
			out["inside"] = true
			out["floor"] = int(res["floor"])
			out["spec"] = spec
			return out
	return out


## The camera's view of one building's own shell: the plan footprint (unrotated,
## as stored), the rigid yaw that takes it into world space, and the vertical
## band [y_min, y_max] of the whole building. FollowCamera uses it to let the
## boom pass through the building the player is INSIDE (the cutaway hides that
## geometry from the camera while keeping collision), while still clamping
## against every other building.
static func shell_of(spec: Dictionary) -> Dictionary:
	var rect: Rect2 = spec.get("rect", Rect2())
	var yaw := float(spec.get("yaw", 0.0))
	var fh := float(spec.get("floor_h", 3.0))
	var n := mini(int(spec.get("floors", 1)), 8)
	var gy := float(spec.get("building_ground_y", spec.get("ground_y", 0.0)))
	return {
		"rect": rect,
		"yaw": yaw,
		"y": Vector2(gy - SHELL_FOOTROOM_M, gy + fh * float(n) + SHELL_HEADROOM_M),
	}
