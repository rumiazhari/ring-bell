extends Node
## Static registry of item definitions.
##
## Items are pure data here so gameplay code never hard-codes stats.
## Long-term these become .tres Resources; call sites will not change.

const KIND_FOOD := &"food"
const KIND_MEDICAL := &"medical"
const KIND_WEAPON_MELEE := &"weapon_melee"
const KIND_WEAPON_GUN := &"weapon_gun"

const ITEMS := {
	&"canned_food": {
		"name": "Canned Food",
		"kind": KIND_FOOD,
		"hunger_reduction": 40.0,
	},
	&"water_bottle": {
		"name": "Water Bottle",
		"kind": KIND_FOOD,
		"thirst_reduction": 45.0,
	},
	&"bandage": {
		"name": "Bandage",
		"kind": KIND_MEDICAL,
		"heal_amount": 25.0,
	},
	&"antibiotics": {
		"name": "Antibiotics",
		"kind": KIND_MEDICAL,
		"infection_reduction": 0.6,  # fraction of current infection removed
	},
	&"apple": {
		"name": "Apple",
		"kind": KIND_FOOD,
		"hunger_reduction": 18.0,
	},
	&"plum": {
		"name": "Plum",
		"kind": KIND_FOOD,
		"hunger_reduction": 16.0,
	},
	&"pear": {
		"name": "Pear",
		"kind": KIND_FOOD,
		"hunger_reduction": 14.0,
	},
	&"cherry": {
		"name": "Cherry",
		"kind": KIND_FOOD,
		"hunger_reduction": 12.0,
	},
	&"wheat_grain": {
		"name": "Wheat Grain",
		"kind": KIND_FOOD,
		"hunger_reduction": 12.0,
	},
	&"barley_grain": {
		"name": "Barley Grain",
		"kind": KIND_FOOD,
		"hunger_reduction": 10.0,
	},
	&"flour": {
		"name": "Flour",
		"kind": KIND_FOOD,
		"hunger_reduction": 14.0,
	},
	&"bread": {
		"name": "Bread",
		"kind": KIND_FOOD,
		"hunger_reduction": 42.0,
	},
	&"cider": {
		"name": "Cider",
		"kind": KIND_FOOD,
		"hunger_reduction": 8.0,
		"thirst_reduction": 38.0,
	},
	&"pipe": {
		"name": "Steel Pipe",
		"kind": KIND_WEAPON_MELEE,
		"damage": 22.0,
		"reach": 1.9,
		"cooldown": 0.8,
		"melee_type": &"blunt",
		"stamina_cost": 12.0,
		"stagger": 3.0,
		"structural_scale": 1.4,
		"model": &"pipe",
	},
	&"kitchen_knife": {
		"name": "Kitchen Knife",
		"kind": KIND_WEAPON_MELEE,
		"damage": 14.0,
		"reach": 1.4,
		"cooldown": 0.55,
		"melee_type": &"blade",
		"stamina_cost": 6.0,
		"stagger": 0.8,
		"structural_scale": 0.4,
		"model": &"kitchen_knife",
	},

	# --- Melee arsenal (Victorian steampunk; the primary way to fight) --------
	# `melee_type` picks the swing behaviour from MeleeTypes, `model` the
	# procedural mesh from MeleeWeaponModels. Weapons are melee-first: firearms
	# are salvage, not the default loadout (see WeaponSystem.ARSENAL_MELEE).
	&"cane_sabre": {
		"name": "Brass Cane-Sabre",
		"kind": KIND_WEAPON_MELEE,
		"melee_type": &"blade",
		"damage": 20.0,
		"reach": 2.0,
		"arc_deg": 125.0,
		"cooldown": 0.62,
		"stamina_cost": 9.0,
		"stagger": 1.7,
		"structural_scale": 0.45,
		"model": &"cane_sabre",
		"flavour": "A gentleman's cane with a blued blade in the barrel.",
	},
	&"pipe_wrench": {
		"name": "Steamfitter's Wrench",
		"kind": KIND_WEAPON_MELEE,
		"melee_type": &"blunt",
		"damage": 34.0,
		"reach": 2.0,
		"arc_deg": 118.0,
		"cooldown": 1.05,
		"stamina_cost": 17.0,
		"stagger": 5.0,
		"structural_scale": 1.6,
		"model": &"pipe_wrench",
		"flavour": "Two feet of iron jaw and brass valve wheel.",
	},
	&"boarding_axe": {
		"name": "Boarding Axe",
		"kind": KIND_WEAPON_MELEE,
		"melee_type": &"axe",
		"damage": 29.0,
		"reach": 2.4,
		"arc_deg": 155.0,
		"cooldown": 0.88,
		"stamina_cost": 14.0,
		"stagger": 3.2,
		"structural_scale": 1.3,
		"model": &"boarding_axe",
		"flavour": "Riveted aether-rig axe, brass counterweight at the poll.",
	},
	&"boiler_lance": {
		"name": "Boiler Lance",
		"kind": KIND_WEAPON_MELEE,
		"melee_type": &"polearm",
		"damage": 26.0,
		"reach": 3.5,
		"arc_deg": 180.0,
		"cooldown": 0.95,
		"stamina_cost": 13.0,
		"stagger": 3.6,
		"structural_scale": 0.8,
		"model": &"boiler_lance",
		"two_handed": true,
		"flavour": "A steam-pipe lance with a valve-wheel guard.",
	},

	# --- Firearms (hitscan unless "projectile" set) ---------------------------
	# damage applies to living AND structures; structures convert it through
	# MaterialDB strength (steel shrugs off bullets that shred wood).
	&"smg": {
		"name": "Scrap SMG",
		"kind": KIND_WEAPON_GUN,
		"damage": 9.0,             # per bullet
		"cooldown": 0.11,          # ~9 rounds/s, automatic
		"auto": true,
		"pellets": 1,
		"spread_deg": 2.2,
		"range": 60.0,
		"knockback": 0.8,
		"tracer_color": Color(1.0, 0.92, 0.55),
	},
	&"shotgun": {
		"name": "Pump Shotgun",
		"kind": KIND_WEAPON_GUN,
		"damage": 8.0,             # per pellet
		"cooldown": 0.95,
		"auto": false,
		"pellets": 7,
		"spread_deg": 11.0,
		"range": 26.0,
		"knockback": 2.4,
		"structural_scale": 1.6,   # heavy shot chews wood
		"tracer_color": Color(1.0, 0.75, 0.45),
	},
	&"rocket_launcher": {
		"name": "Rocket Launcher",
		"kind": KIND_WEAPON_GUN,
		"projectile": &"rocket",
		"speed": 24.0,
		"damage": 130.0,           # at blast center
		"explosion_radius": 5.5,
		"cooldown": 1.7,
		"auto": false,
	},
}

# Implicit weapon used when nothing is equipped.
const FISTS := {
	"name": "Fists",
	"kind": KIND_WEAPON_MELEE,
	"damage": 8.0,
	"reach": 1.3,
	"arc_deg": 100.0,
	"cooldown": 0.7,
	"melee_type": &"fist",
	"stamina_cost": 5.0,
	"stagger": 1.2,
	"structural_scale": 0.2,
	"model": &"fists",
}

## The melee-first loadout the player starts with, in slot order.
const MELEE_ARSENAL: Array[StringName] = [
	&"cane_sabre", &"pipe_wrench", &"boarding_axe", &"boiler_lance",
]

## Every weapon that swings rather than shoots (kept explicit so loot tables
## and tests can enumerate the melee set without filtering ItemDB by hand).
const MELEE_WEAPON_IDS: Array[StringName] = [
	&"cane_sabre", &"pipe_wrench", &"boarding_axe", &"boiler_lance",
	&"pipe", &"kitchen_knife",
]


func get_def(id: StringName) -> Dictionary:
	if ITEMS.has(id):
		return ITEMS[id]
	push_warning("ItemDB: unknown item id '%s'" % id)
	return {}


func get_weapon_def(id: StringName) -> Dictionary:
	if id == &"" or not ITEMS.has(id):
		return FISTS
	var def: Dictionary = ITEMS[id]
	if def.get("kind", &"") != KIND_WEAPON_MELEE:
		return FISTS
	return def


## Gun defs pass through only for KIND_WEAPON_GUN items; "" otherwise.
func get_gun_def(id: StringName) -> Dictionary:
	if id != &"" and ITEMS.has(id):
		var def: Dictionary = ITEMS[id]
		if def.get("kind", &"") == KIND_WEAPON_GUN:
			return def
	return {}


func item_name(id: StringName) -> String:
	if id == &"":
		return FISTS["name"]
	return String(get_def(id).get("name", id))


## Melee def with every field the combat system reads filled in.
## Class defaults come from MeleeTypes so a new weapon only has to declare what
## makes it different (see ITEMS).
func get_melee_def(id: StringName) -> Dictionary:
	var def: Dictionary = FISTS if (id == &"" or not ITEMS.has(id)) else ITEMS[id]
	if def.get("kind", &"") != KIND_WEAPON_MELEE:
		def = FISTS
	var type: StringName = def.get("melee_type", MeleeTypes.DEFAULT_TYPE)
	var out := def.duplicate()
	out["melee_type"] = type
	out["type_label"] = MeleeTypes.label(type)
	var fallback_reach := float(def.get("reach", FISTS["reach"]))
	var fallback_arc := float(def.get("arc_deg", MeleeTypes.arc_deg(type)))
	var combo_id: StringName = id if id != &"" and ITEMS.has(id) else &"fists"
	var combo: Dictionary = MeleeCombos.definition(
			combo_id, type, fallback_reach, fallback_arc)
	out["combo"] = combo
	out["combo_chain"] = (combo.get("chain", []) as Array).duplicate()
	out["heavy_clip"] = StringName(combo.get("heavy", &""))
	out["unique_clip"] = StringName(combo.get("unique", &""))
	out["guard_clip"] = StringName(combo.get("guard", &""))
	out["counter_clip"] = StringName(combo.get("counter", &""))
	out["guard_absorb"] = float(combo.get("guard_absorb", 0.25))
	out["parry_window"] = float(combo.get("parry_window", 0.0))
	out["block_cost"] = float(combo.get("block_cost", 5.0))
	out["arc_deg"] = float(combo.get("arc_deg", fallback_arc))
	out["cleave"] = int(def.get("cleave", MeleeTypes.cleave(type)))
	out["stagger"] = float(def.get("stagger", MeleeTypes.stagger(type)))
	out["structural_scale"] = float(def.get(
			"structural_scale", MeleeTypes.structural_scale(type)))
	out["clip_speed"] = float(def.get("clip_speed", MeleeTypes.clip_speed(type)))
	# Keep the old field name for callers, but the weapon's combo chain is now
	# the authoritative pool for a light attack.
	out["swing_pool"] = (combo.get("chain", []) as Array).duplicate()
	out["damage"] = float(def.get("damage", FISTS["damage"]))
	out["reach"] = float(combo.get("reach", fallback_reach))
	out["cooldown"] = float(def.get("cooldown", FISTS["cooldown"]))
	out["stamina_cost"] = float(def.get("stamina_cost", FISTS["stamina_cost"]))
	out["model"] = StringName(def.get("model", &"fists"))
	out["two_handed"] = bool(def.get("two_handed", false))
	return out


func is_melee_weapon(id: StringName) -> bool:
	if id == &"":
		return true
	return ITEMS.has(id) and ITEMS[id].get("kind", &"") == KIND_WEAPON_MELEE


## Display string for HUD labels: "Boarding Axe - Axe".
func melee_label(id: StringName) -> String:
	var def := get_melee_def(id)
	return "%s - %s" % [def["name"], def["type_label"]]
