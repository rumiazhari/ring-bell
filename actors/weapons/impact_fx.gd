class_name ImpactFX
extends RefCounted
## Per-damage-type impact burst fired where a melee swing actually connects.
##
## One burst per landed hit, pooled behind a hard live cap so a crowd fight
## cannot spawn unbounded particle systems. The PROFILE (colour, count, speed,
## gravity, spread, size, life) is picked from the weapon class's impact family
## - see MeleeTypes.impact() - so the three physical events read differently in
## motion: a blade throws a fast thin red spray, a blunt blow puffs a heavier
## slower brown cloud, a point weapon squirts a narrow cone.
##
## Rendered as one CPUParticles3D per burst (no GPU requirement), parented to
## the scene root rather than the actor so the burst survives the actor's death
## in the same frame. Every burst reaps itself on a timer.

## Hard cap on simultaneous bursts. Dropped bursts are counted, never leaked.
const MAX_LIVE := 24
## Bursts older than life + this many seconds are force-reaped even if the
## particle system never reports finished (headless, paused tree, freed actor).
const REAP_GRACE := 0.35

const SLASH := &"slash"
const CRUSH := &"crush"
const PIERCE := &"pierce"

## Impact family -> burst profile.
const PROFILES := {
	SLASH: {
		"color": Color(0.44, 0.05, 0.05), "amount": 16, "speed": 3.6,
		"gravity": 11.0, "spread": 46.0, "life": 0.55, "size": 0.055,
		"label": "blood spray",
	},
	CRUSH: {
		"color": Color(0.40, 0.28, 0.21), "amount": 20, "speed": 2.5,
		"gravity": 16.0, "spread": 62.0, "life": 0.75, "size": 0.07,
		"label": "dust and chips",
	},
	PIERCE: {
		"color": Color(0.52, 0.06, 0.05), "amount": 12, "speed": 4.8,
		"gravity": 13.0, "spread": 26.0, "life": 0.45, "size": 0.04,
		"label": "narrow jet",
	},
}

## Structure hits reuse the weapon family's motion but borrow the material's
## colour, so a pipe on a door reads as splinters and an axe on glass as shards.
const STRUCTURE_TINTS := {
	&"wood": Color(0.42, 0.29, 0.16),
	&"metal": Color(0.62, 0.60, 0.52),
	&"glass": Color(0.60, 0.72, 0.74),
	&"stone": Color(0.44, 0.44, 0.43),
	&"cloth": Color(0.35, 0.33, 0.30),
	&"flesh": Color(0.44, 0.05, 0.05),
}

static var _live := 0
static var spawned := 0
static var dropped := 0


# --- Queries -----------------------------------------------------------------

static func impact_of(melee_type: StringName) -> StringName:
	return MeleeTypes.impact(melee_type)


static func profile(melee_type: StringName, tint := Color(0, 0, 0, 0)) -> Dictionary:
	var fam := impact_of(melee_type)
	var def: Dictionary = PROFILES.get(fam, PROFILES[CRUSH])
	var out := def.duplicate()
	if tint.a > 0.0:
		out["color"] = tint
	return out


static func label(melee_type: StringName) -> String:
	return String(profile(melee_type).get("label", ""))


static func live_count() -> int:
	return _live


static func stats() -> Dictionary:
	return {"live": _live, "spawned": spawned, "dropped": dropped, "cap": MAX_LIVE}


static func reset_stats() -> void:
	_live = 0
	spawned = 0
	dropped = 0


# --- Spawn -------------------------------------------------------------------

## Where a burst belongs: the burst must outlive the actor it was spawned
## against (a corpse freed in the same frame would take the burst with it), so
## prefer the current scene, and fall back to the tree root in a bare test rig.
static func parent_for(node: Node) -> Node:
	if node == null or not is_instance_valid(node):
		return null
	var tree := node.get_tree()
	if tree == null:
		return node.get_parent()
	return tree.current_scene if tree.current_scene != null else tree.root


## Burst at `point` travelling along `dir` for a landed hit of `melee_type`.
## `parent` should outlive the actor (the scene root). Returns the burst node,
## or null when the live cap is saturated.
static func spawn(parent: Node, point: Vector3, dir: Vector3, melee_type: StringName,
		force := 1.0, tint := Color(0, 0, 0, 0)) -> Node3D:
	if parent == null or not is_instance_valid(parent):
		return null
	if _live >= MAX_LIVE:
		dropped += 1
		return null
	var prof := profile(melee_type, tint)
	var root := Node3D.new()
	root.name = "ImpactFX_%s" % impact_of(melee_type)
	parent.add_child(root)
	root.global_position = point

	var p := CPUParticles3D.new()
	p.name = "Burst"
	p.emitting = true
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = maxi(4, int(round(float(prof["amount"]) * clampf(force, 0.6, 1.8))))
	p.lifetime = float(prof["life"])
	p.direction = dir.normalized() if dir.length() > 0.001 else Vector3.UP
	p.spread = float(prof["spread"])
	var speed := float(prof["speed"]) * clampf(0.7 + force * 0.3, 0.7, 1.6)
	p.initial_velocity_min = speed * 0.55
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -float(prof["gravity"]), 0)
	p.scale_amount_min = float(prof["size"]) * 0.6
	p.scale_amount_max = float(prof["size"])
	p.color = prof["color"] as Color
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 4
	mesh.rings = 2
	p.mesh = mesh
	root.add_child(p)

	var timer := Timer.new()
	timer.name = "Reap"
	timer.one_shot = true
	timer.wait_time = float(prof["life"]) + REAP_GRACE
	timer.timeout.connect(func() -> void: release(root))
	root.add_child(timer)
	timer.start()

	root.set_meta(&"impact", impact_of(melee_type))
	root.set_meta(&"profile", prof)
	_live += 1
	spawned += 1
	return root


## Burst for a structural hit, tinted by the material being hit.
static func spawn_structure(parent: Node, point: Vector3, dir: Vector3,
		melee_type: StringName, material_id: StringName, force := 1.0) -> Node3D:
	var tint: Color = STRUCTURE_TINTS.get(material_id, Color(0, 0, 0, 0))
	return spawn(parent, point, dir, melee_type, force, tint)


## Reap one burst. Safe to call twice (the particle `finished` signal and the
## reap timer race on purpose).
static func release(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	if root.get_meta(&"released", false):
		return
	root.set_meta(&"released", true)
	_live = maxi(0, _live - 1)
	root.queue_free()
