extends Node
## Static registry of structural materials for the destruction system.
##
## Every destructible object declares one material id from MATERIALS. The
## material decides how much incoming damage the object actually absorbs
## (strength), how heavy debris pieces are (density -> explosion impulses),
## and how violently it shatters (debris energy multiplier).
##
## Strength ladder (higher = tougher): glass < flesh < wood < concrete < steel.

const MATERIALS := {
	&"glass": {
		"name": "Glass",
		"strength": 0.35,          # damage divisor
		"density": 1.2,            # kg/m^3-ish scale for debris mass
		"debris_energy": 1.4,      # shatter scatter multiplier
		"debris_color": Color(0.65, 0.78, 0.82),
	},
	&"flesh": {
		"name": "Flesh",
		"strength": 0.5,
		"density": 1.0,
		"debris_energy": 0.9,
		"debris_color": Color(0.55, 0.12, 0.12),
	},
	&"wood": {
		"name": "Wood",
		"strength": 1.0,
		"density": 0.8,
		"debris_energy": 1.1,
		"debris_color": Color("6e5233"),
	},
	&"concrete": {
		"name": "Concrete",
		"strength": 2.6,
		"density": 2.4,
		"debris_energy": 0.7,
		"debris_color": Color("8d887c"),
	},
	&"steel": {
		"name": "Steel",
		"strength": 4.5,
		"density": 3.5,
		"debris_energy": 0.55,
		"debris_color": Color("5a6066"),
	},
}


func get_material(id: StringName) -> Dictionary:
	if MATERIALS.has(id):
		return MATERIALS[id]
	push_warning("MaterialDB: unknown material id '%s'" % id)
	return MATERIALS[&"wood"]


## Damage that actually erodes an object of this material.
func effective_damage(raw_amount: float, id: StringName) -> float:
	return raw_amount / float(get_material(id).get("strength", 1.0))
