class_name UniversalBuildingAssembler
extends RefCounted
## Ring Bell UNIVERSAL BUILDING CONTRACT — assembler (G10-P2A).
##
## THE ONLY NORMAL PATH that constructs player-facing enterable buildings.
## World/settlement/city plans produce BuildingSpecs; this assembler turns
## them into geometry. Direct primitive construction remains legal ONLY
## for explicit props, temporary debug visualization, distant LOD, and
## non-building scenery.
##
## City path:       build_into(b: MeshBatcher, spec) — contract-stamps the
##                  spec, registers the building id with the batcher, and
##                  delegates to the reference-quality BuildingBuilder
##                  (byte-identical city construction preserved).
## Rural path:      build_rural_into(...) — contract houses (archetype
##                  house/cottage) are composed by the aperture-based
##                  universal_building_art grammar into the rural raw-array
##                  sink (single Concave collider preserved). Non-migrated
##                  archetypes (barn/stable/shed, this milestone) return
##                  false and stay on the legacy rural art path, explicitly
##                  tracked in docs as pending migration — never re-routed
##                  through a NEW shell builder.
##
## DISTANT_LOD / PROP_STRUCTURE are allowed to bypass this assembler by
## design (they are not enterable FULL buildings).

const Art = preload("res://art/universal_building_art.gd")


## City/box path. Mutates `spec` with contract fields (contractualize) and
## registers it, then delegates. Returns the spec (same dictionary).
static func build_into(b: MeshBatcher, spec: Dictionary) -> Dictionary:
	BuildingSpec.contractualize(spec)
	var id := str(spec.get("id", "b"))
	if (spec.get("quality", WorldConstants.BUILDING_QUALITY_FULL_BUILDING) as StringName) \
			== WorldConstants.BUILDING_QUALITY_FULL_BUILDING:
		b.register_contract_building(id, spec)
	var transformed := false
	var rect: Rect2 = spec.get("rect", Rect2()) as Rect2
	var yaw := float(spec.get("yaw", 0.0))
	if not is_zero_approx(yaw) and rect.size.x > 0.0 and rect.size.y > 0.0:
		b.push_building_transform(Vector3(rect.get_center().x, 0.0,
				rect.get_center().y), yaw)
		transformed = true
	# Unknown/unmigrated archetypes still get the reference city quality path —
	# the city reference builder IS the universal city grammar.
	BuildingBuilder.build(b, spec)
	if transformed:
		b.pop_building_transform()
	return spec


## Rural raw-array path. Returns true when the building was assembled by
## the universal grammar (and registers `evidence`), false when it is a
## not-yet-migrated legacy archetype.
static func build_rural_into(verts: PackedVector3Array,
		normals: PackedVector3Array, colors: PackedColorArray,
		indices: PackedInt32Array, collider_verts: PackedVector3Array,
		collider_indices: PackedInt32Array, b: Dictionary,
		world_plan: WorldPlan, evidence: Dictionary) -> bool:
	BuildingSpec.contractualize(b)
	var quality: StringName = b.get("quality",
			WorldConstants.BUILDING_QUALITY_FULL_BUILDING) as StringName
	if quality != WorldConstants.BUILDING_QUALITY_FULL_BUILDING:
		return false
	var archetype: StringName = b.get("archetype", &"") as StringName
	if archetype != &"house" and archetype != &"cottage":
		# Barn/stable/shed and future utility archetypes are pending
		# migration (tracked in docs/world/BUILDING-CONTRACT.md). Never
		# invent a new shell builder for them.
		return false
	var center: Vector2 = b["center"] as Vector2
	var footprint: Vector2 = b["footprint"] as Vector2
	var yaw := float(b["yaw"])
	var height := float(b["height"])
	var ground: float = world_plan.surface_height_at(center) \
			+ WorldConstants.RURAL_OVERLAY_LIFT_M
	var kind: StringName = b.get("kind", &"cottage") as StringName
	var interior: Dictionary = b.get("interior", {})
	var door_width := 1.0
	var door_height := 2.1
	if kind == &"barn" or kind == &"stable":
		door_width = 1.2
		door_height = 2.2
	evidence["id"] = str(b.get("id", ""))
	evidence["quality"] = quality
	evidence["archetype"] = archetype
	evidence["kind"] = kind
	evidence["floors"] = 2 if height > 6.0 else 1
	Art.append_contract_house(verts, normals, colors, indices,
			collider_verts, collider_indices, center, footprint, yaw, ground,
			height, b.get("door_pos", center) as Vector2, door_width,
			door_height, kind, b.get("color", Color("ddd0c0")) as Color,
			b.get("roof_color", Color("8a3a2a")) as Color,
			Color("7a5a3a"), Color("415a60"), interior, evidence)
	return true


## Guard rails for the anti-trash rule.
static func is_full_quality(spec: Dictionary) -> bool:
	return (spec.get("quality",
			WorldConstants.BUILDING_QUALITY_FULL_BUILDING) as StringName) \
			== WorldConstants.BUILDING_QUALITY_FULL_BUILDING


## True when the spec is safe to assemble with the CURRENT milestone's
## universal grammar. Anything else must be routed through the universal
## assembler, not a bespoke shell pipeline.
static func is_migrated(spec: Dictionary) -> bool:
	var archetype: StringName = spec.get("archetype", &"") as StringName
	return archetype == &"house" or archetype == &"cottage" \
			or archetype == &"tenement" or archetype == &"shop_house" \
			or spec.has("rect")