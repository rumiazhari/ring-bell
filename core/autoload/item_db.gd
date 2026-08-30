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
	&"pipe": {
		"name": "Steel Pipe",
		"kind": KIND_WEAPON_MELEE,
		"damage": 22.0,
		"reach": 1.9,
		"cooldown": 0.8,
	},
	&"kitchen_knife": {
		"name": "Kitchen Knife",
		"kind": KIND_WEAPON_MELEE,
		"damage": 14.0,
		"reach": 1.4,
		"cooldown": 0.55,
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
	"cooldown": 0.7,
}


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
