class_name MeleeCombos
extends RefCounted
## Data-only move trees and guard tuning for each melee weapon.
##
## A combo is intentionally keyed by weapon id first.  The melee type is only
## the compatibility fallback for older loot (pipe, kitchen_knife, or a new
## item that has not received a bespoke tree yet).

const TYPE_DEFAULTS := {
	&"blade": &"cane_sabre",
	&"blunt": &"pipe_wrench",
	&"axe": &"boarding_axe",
	&"polearm": &"boiler_lance",
	&"fist": &"fists",
}

const COMBOS := {
	&"boiler_lance": {
		"chain": [&"LanceThrustHigh", &"LanceThrustLow", &"LanceWideSweep"],
		"heavy": &"LanceCharge",
		"unique": &"LanceSpiralSweep",
		"guard": &"LanceGuardHold",
		"counter": &"LanceCounter",
		"reach": 3.5,
		"arc_deg": 180.0,
		"guard_absorb": 0.70,
		"parry_window": 0.22,
		"block_cost": 11.0,
		"steps": [
			{"stamina": 13.0, "damage_scale": 1.00, "speed_scale": 1.08},
			{"stamina": 14.0, "damage_scale": 1.08, "speed_scale": 1.02},
			{"stamina": 16.0, "damage_scale": 1.22, "speed_scale": 0.94},
		],
	},
	&"boarding_axe": {
		"chain": [&"AxeChopR", &"AxeChopL", &"AxeCleave"],
		"heavy": &"AxeHookDrag",
		"unique": &"AxeRend",
		"guard": &"AxeGuardHold",
		"counter": &"AxeCounter",
		"reach": 2.4,
		"arc_deg": 155.0,
		"guard_absorb": 0.62,
		"parry_window": 0.14,
		"block_cost": 14.0,
		"steps": [
			{"stamina": 14.0, "damage_scale": 1.00, "speed_scale": 1.00},
			{"stamina": 15.0, "damage_scale": 1.12, "speed_scale": 0.94},
			{"stamina": 17.0, "damage_scale": 1.28, "speed_scale": 0.88},
		],
	},
	&"pipe_wrench": {
		"chain": [&"WrenchOverhead", &"WrenchBackhand", &"WrenchCrush"],
		"heavy": &"WrenchSlam",
		"unique": &"WrenchHookPull",
		"guard": &"WrenchGuardHold",
		"counter": &"WrenchCounter",
		"reach": 2.0,
		"arc_deg": 118.0,
		"guard_absorb": 0.78,
		"parry_window": 0.0,
		"block_cost": 9.0,
		"steps": [
			{"stamina": 17.0, "damage_scale": 1.00, "speed_scale": 0.96},
			{"stamina": 18.0, "damage_scale": 1.10, "speed_scale": 0.90},
			{"stamina": 20.0, "damage_scale": 1.32, "speed_scale": 0.82},
		],
	},
	&"cane_sabre": {
		"chain": [&"SabreSlashR", &"SabreSlashL", &"SabreDiagR"],
		"heavy": &"SabreThrust",
		"unique": &"SabreWhirl",
		"guard": &"SabreGuardHold",
		"counter": &"SabreRiposte",
		"reach": 2.0,
		"arc_deg": 125.0,
		"guard_absorb": 0.50,
		"parry_window": 0.26,
		"block_cost": 7.0,
		"steps": [
			{"stamina": 9.0, "damage_scale": 1.00, "speed_scale": 1.18},
			{"stamina": 9.0, "damage_scale": 1.08, "speed_scale": 1.14},
			{"stamina": 10.0, "damage_scale": 1.18, "speed_scale": 1.06},
		],
	},
	&"fists": {
		"chain": [&"JabR", &"JabL", &"HookR", &"Shove"],
		"heavy": &"",
		"unique": &"Shove",
		"guard": &"FistsGuardHold",
		"counter": &"",
		"reach": 1.3,
		"arc_deg": 100.0,
		"guard_absorb": 0.25,
		"parry_window": 0.0,
		"block_cost": 5.0,
		"steps": [
			{"stamina": 5.0, "damage_scale": 1.00, "speed_scale": 1.24},
			{"stamina": 5.0, "damage_scale": 1.04, "speed_scale": 1.20},
			{"stamina": 6.0, "damage_scale": 1.12, "speed_scale": 1.08},
			{"stamina": 8.0, "damage_scale": 1.28, "speed_scale": 0.96},
		],
	},
}


## Resolve a weapon-specific tree, or use the tree belonging to its class.
## Fallback weapons keep their own ItemDB reach/arc while borrowing the class
## moves and guard identity.
static func definition(weapon_id: StringName, melee_type: StringName,
		fallback_reach := 1.5, fallback_arc := 100.0) -> Dictionary:
	var source_id: StringName = weapon_id
	var bespoke := COMBOS.has(source_id)
	if not bespoke:
		source_id = StringName(TYPE_DEFAULTS.get(melee_type, &"pipe_wrench"))
	var source: Dictionary = (COMBOS.get(source_id, {}) as Dictionary).duplicate(true)
	var chain: Array = source.get("chain", []) as Array
	if chain.is_empty():
		chain = MeleeTypes.swing_pool(melee_type)
	var out: Dictionary = source.duplicate(true)
	out["chain"] = chain.duplicate()
	if not bespoke:
		out["reach"] = fallback_reach
		out["arc_deg"] = fallback_arc
	var heavy: StringName = StringName(out.get("heavy", &""))
	if heavy == &"":
		for candidate in MeleeTypes.swing_pool(melee_type):
			var candidate_name: StringName = candidate as StringName
			if MeleeSwingLibrary.is_heavy(candidate_name):
				heavy = candidate_name
				break
	out["heavy"] = heavy
	out["unique"] = StringName(out.get("unique", &""))
	out["guard"] = StringName(out.get("guard", &"GuardHold"))
	out["counter"] = StringName(out.get("counter", &""))
	out["reach"] = float(out.get("reach", fallback_reach))
	out["arc_deg"] = float(out.get("arc_deg", fallback_arc))
	out["guard_absorb"] = clampf(float(out.get("guard_absorb", 0.25)), 0.0, 0.95)
	out["parry_window"] = maxf(0.0, float(out.get("parry_window", 0.0)))
	out["block_cost"] = maxf(0.0, float(out.get("block_cost", 5.0)))
	var steps: Array = out.get("steps", []) as Array
	while steps.size() < chain.size():
		steps.append({"stamina": 5.0, "damage_scale": 1.0, "speed_scale": 1.0})
	out["steps"] = steps
	return out


static func chain_for(weapon_id: StringName, melee_type: StringName) -> Array:
	return (definition(weapon_id, melee_type).get("chain", []) as Array).duplicate()


static func step_for(combo: Dictionary, step_index: int) -> Dictionary:
	var steps: Array = combo.get("steps", []) as Array
	if steps.is_empty():
		return {"stamina": 5.0, "damage_scale": 1.0, "speed_scale": 1.0}
	var index := clampi(step_index - 1, 0, steps.size() - 1)
	return (steps[index] as Dictionary).duplicate()


static func has_heavy(combo: Dictionary) -> bool:
	return StringName(combo.get("heavy", &"")) != &""
