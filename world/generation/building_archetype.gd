class_name BuildingArchetype
extends RefCounted
## Ring Bell UNIVERSAL BUILDING CONTRACT — archetype registry (G10-P2A).
##
## An ARCHETYPE defines a building's PROGRAM/IDENTITY: what the building IS,
## what quality it may claim, how it must be validated, and what interior it
## is expected to contain. The world/settlement/city PLAN layer decides WHERE
## a building exists and WHAT it is (kind/use/district); the archetype maps
## that program onto the contract's validation rules; the Universal
## Building Assembler is the only normal construction path.
##
## Quality levels (exactly three, enforced by BuildingContractValidator):
##   FULL_BUILDING   enterable, full structure/interior/collision
##   DISTANT_LOD     visual simplification of a FULL building (needs lod_of)
##   PROP_STRUCTURE  explicitly non-enterable (outhouse, kiosk, lean-to, shed)
##
## A house, apartment, inn, factory, etc. may NEVER be silently downgraded
## to PROP_STRUCTURE. Barns/stables are FULL one-room halls (no arbitrary
## multi-room layouts required — validate according to archetype).

const FAMILY_RESIDENTIAL := &"residential"
const FAMILY_COMMERCIAL := &"commercial"
const FAMILY_UTILITY := &"utility"
const FAMILY_INDUSTRIAL := &"industrial"
const FAMILY_INSTITUTIONAL := &"institutional"

## min_quality: the LOWEST quality this archetype may claim.
## bulk: true = single-hall archetypes that must NOT be forced into
##        arbitrary multi-room layouts.
## roof_families: allowed roof vocab.
## program_hint: short human description used in docs/tests.
const ARCHETYPES: Dictionary = {
	&"house": {
		"family": FAMILY_RESIDENTIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"gabled", &"pitched", &"flat"],
		"notes": "dwelling; 1+ rooms, entry room, windows on inhabited sides",
	},
	&"cottage": {
		"family": FAMILY_RESIDENTIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"gabled"],
		"notes": "small rural dwelling; 1-2 rooms, entry, windowed",
	},
	&"tenement": {
		"family": FAMILY_RESIDENTIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"flat", &"pitched"],
		"notes": "multi-storey urban dwelling; stairs required above ground",
	},
	&"shop_house": {
		"family": FAMILY_COMMERCIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"flat", &"pitched"],
		"notes": "street retail program; entry + sales, storage/toilet",
	},
	&"barn": {
		"family": FAMILY_UTILITY, "min_quality": &"FULL_BUILDING",
		"bulk": true, "roof_families": [&"gabled"],
		"notes": "one-room agricultural hall; door aeration, loft vent",
	},
	&"stable": {
		"family": FAMILY_UTILITY, "min_quality": &"FULL_BUILDING",
		"bulk": true, "roof_families": [&"gabled"],
		"notes": "one-room animal shelter; wide door, loft vent",
	},
	&"shed": {
		"family": FAMILY_UTILITY, "min_quality": &"PROP_STRUCTURE",
		"bulk": true, "roof_families": [&"gabled"],
		"notes": "tiny non-enterable store; PROP_STRUCTURE allowed",
	},
	&"outhouse": {
		"family": FAMILY_UTILITY, "min_quality": &"PROP_STRUCTURE",
		"bulk": true, "roof_families": [&"gabled"],
		"notes": "non-enterable privy; PROP_STRUCTURE",
	},
	&"kiosk": {
		"family": FAMILY_COMMERCIAL, "min_quality": &"PROP_STRUCTURE",
		"bulk": true, "roof_families": [&"gabled", &"flat"],
		"notes": "non-enterable stall; PROP_STRUCTURE",
	},
	# Reserved for later milestones (registered so classification is never
	# accidental; G10-P2A does NOT implement geometry for these yet).
	&"inn": {
		"family": FAMILY_COMMERCIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"gabled", &"pitched"],
		"notes": "reserved: tavern lodging program",
	},
	&"factory": {
		"family": FAMILY_INDUSTRIAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"flat", &"gabled"],
		"notes": "reserved: industrial hall with machine floor",
	},
	&"warehouse": {
		"family": FAMILY_INDUSTRIAL, "min_quality": &"FULL_BUILDING",
		"bulk": true, "roof_families": [&"flat", &"gabled"],
		"notes": "reserved: single open storage hall",
	},
	&"school": {
		"family": FAMILY_INSTITUTIONAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"flat", &"pitched"],
		"notes": "reserved: corridor + classrooms program",
	},
	&"hospital": {
		"family": FAMILY_INSTITUTIONAL, "min_quality": &"FULL_BUILDING",
		"bulk": false, "roof_families": [&"flat"],
		"notes": "reserved: ward + treatment program",
	},
}

## Normalize legacy kind/use strings onto contract archetypes. Every plan
## layer may keep its own vocabulary; the contract maps it deterministically.
static func archetype_for(kind_or_use: StringName) -> StringName:
	match String(kind_or_use):
		"village_house", "farmhouse", "house", "residential", "courtyard_house":
			return &"house"
		"cottage", "detached_cottage":
			return &"cottage"
		"shop_house", "retail", "shop":
			return &"shop_house"
		"tenement", "apartment", "apartment_block", "worker_row_house", "small_tenement":
			return &"tenement"
		"barn":
			return &"barn"
		"stable":
			return &"stable"
		"shed", "tool_shed", "utility_building":
			return &"shed"
		"outhouse":
			return &"outhouse"
		"kiosk", "stall":
			return &"kiosk"
		"inn", "tavern", "roadside_inn":
			return &"inn"
		"factory", "mill", "small_factory", "workshop":
			return &"factory"
		"warehouse", "industrial_shed":
			return &"warehouse"
		"school":
			return &"school"
		"hospital":
			return &"hospital"
	return StringName(String(kind_or_use))


static func has(archetype: StringName) -> bool:
	return ARCHETYPES.has(archetype)


static func family(archetype: StringName) -> StringName:
	var entry: Dictionary = ARCHETYPES.get(archetype, {})
	return entry.get("family", &"") as StringName


static func min_quality(archetype: StringName) -> StringName:
	var entry: Dictionary = ARCHETYPES.get(archetype, {})
	return entry.get("min_quality", &"FULL_BUILDING") as StringName


## True when the archetype is a single-hall program that must not be
## forced into arbitrary multi-room layouts (shed, barn, warehouse...).
static func is_bulk(archetype: StringName) -> bool:
	var entry: Dictionary = ARCHETYPES.get(archetype, {})
	return bool(entry.get("bulk", false))


static func notes(archetype: StringName) -> String:
	var entry: Dictionary = ARCHETYPES.get(archetype, {})
	return str(entry.get("notes", ""))


## The program's expected room kinds are advisory, not a hard schema: the
## validator enforces CONNECTIVITY + entry + scale, and lets the plan decide
## the concrete room split. Kept here for documentation and future plans.
static func room_program(archetype: StringName, floors: int) -> Array[StringName]:
	match archetype:
		&"house", &"cottage", &"tenement":
			return [&"entry", &"sleeping", &"toilet"]
		&"shop_house":
			return [&"entry", &"storage", &"toilet"]
		&"barn", &"stable", &"warehouse":
			return [&"hall"]
		&"shed", &"outhouse", &"kiosk":
			return []
	return []