class_name WindSystem
extends RefCounted
## Wind — PLACEHOLDER (not yet simulated).
##
## This file exists so the tree meshes carry everything a future wind system
## needs, without a single vertex ever being regenerated.
##
## CONTRACT (do not break this when implementing real wind):
##   * Every tree vertex carries a sway weight in the mesh's second UV channel
##     (Mesh.ARRAY_TEX_UV2), packed as Vector2(sway_weight, phase) where
##     sway_weight is 0.0 at the root/base (buttress wedges are exactly 0.0)
##     and ~1.0 at twig tips, and phase is a per-tree rotation offset in
##     radians so neighbouring trees never sway in lockstep.
##   * Sway weight is baked per tree *segment* (all vertices of one branch or
##     trunk segment share the weight of that segment's midpoint). Blending
##     between segments happens naturally because the weights increase along
##     the tree.
##   * A future wind implementation is therefore a vertex shader (or a
##     MultiMesh/instance uniform "wind time + direction + strength") that
##     reads ARRAY_TEX_UV2.y for phase and .x for weight:
##         offset = wind_dir * strength * weight * sin(time * freq + phase)
##     No geometry rebuild, no CPU cost per tree.
##
## Until then, `sway_offset()` returns zero and nothing moves: the trees are
## static, and the placeholder costs one Vector2 per vertex.

## Global switch for the (future) simulation. Kept false so nothing animates
## while the wind system is still a stub.
static var enabled := false

## Placeholder clock. A real system owns this; the stub never advances it.
static var time_s := 0.0

## Maximum horizontal displacement (metres) a vertex with sway weight 1.0 would
## travel at full strength. Documented now so the geometry budget can be judged.
const MAX_SWAY_M := 0.35

## Wind field sample — PLACEHOLDER: calm everywhere.
static func wind_at(_world_pos: Vector3) -> Vector3:
	return Vector3.ZERO


## Placeholder displacement for one vertex. `sway` is the baked UV2 pair
## (weight, phase). Returns zero for now — the signature is the hook the
## future system fills in.
static func sway_offset(_sway: Vector2, _world_pos: Vector3) -> Vector3:
	return Vector3.ZERO


## Human-readable state, for audits and the doctor.
static func describe() -> Dictionary:
	return {
		"implemented": false,
		"enabled": enabled,
		"time_s": time_s,
		"max_sway_m": MAX_SWAY_M,
		"uv2_layout": "x = sway weight (0 at root .. 1 at twig tips), y = phase (radians)",
	}
