class_name MeleeTypes
extends RefCounted
## Behaviour of each melee weapon *class*. Data lives in ItemDB per weapon;
## what a class means -- how wide it swings, how many bodies it catches, how it
## treats structures, which swing directions it owns -- lives here so gameplay
## code never grows an if/elif ladder per weapon.

const BLADE := &"blade"
const BLUNT := &"blunt"
const AXE := &"axe"
const POLEARM := &"polearm"
const FIST := &"fist"

const ALL: Array[StringName] = [BLADE, BLUNT, AXE, POLEARM, FIST]

const LABELS := {
	BLADE: "Blade",
	BLUNT: "Blunt",
	AXE: "Axe",
	POLEARM: "Polearm",
	FIST: "Bare hands",
}

## Swing arc width in degrees, centred on the aim direction.
const ARCS := {
	BLADE: 110.0,
	BLUNT: 132.0,
	AXE: 140.0,
	POLEARM: 58.0,
	FIST: 92.0,
}

## Bodies one clean swing can catch (checked nearest-first).
const CLEAVE := {
	BLADE: 1,
	BLUNT: 2,
	AXE: 2,
	POLEARM: 1,
	FIST: 1,
}

## How hard the class pushes a body it connects with.
const STAGGER := {
	BLADE: 1.6,
	BLUNT: 4.2,
	AXE: 3.0,
	POLEARM: 3.4,
	FIST: 1.2,
}

## Damage multiplier against structures (doors, crates, barricades).
## A blade ruins flesh; a wrench ruins carpentry.
const STRUCTURAL := {
	BLADE: 0.45,
	BLUNT: 1.45,
	AXE: 1.30,
	POLEARM: 0.80,
	FIST: 0.20,
}

## Ordered swing pools. Order is the tie-breaker for a straight-ahead aim
## (see MeleeSwingLibrary.direction_for), so each class gets its signature
## opening move first.
const POOLS := {
	BLADE: [&"Thrust", &"Chop", &"DiagR", &"DiagL", &"SlashR", &"SlashL", &"Sweep"],
	BLUNT: [&"Chop", &"SlashR", &"SlashL", &"Smash", &"Sweep"],
	AXE: [&"Chop", &"DiagR", &"DiagL", &"Sweep", &"Smash"],
	POLEARM: [&"Thrust", &"Chop", &"Sweep", &"SlashR", &"SlashL"],
	FIST: [&"Thrust", &"SlashR", &"SlashL", &"Chop"],
}

## Speed the swing clip plays at, relative to its authored length.
## Heavier classes move a little slower so the pose reads as weight.
const CLIP_SPEED := {
	BLADE: 1.15,
	BLUNT: 0.85,
	AXE: 0.95,
	POLEARM: 1.0,
	FIST: 1.2,
}

## Melee class of a falling-back item that predates the class system.
const DEFAULT_TYPE := BLUNT


static func label(type: StringName) -> String:
	return String(LABELS.get(type, LABELS[DEFAULT_TYPE]))


static func arc_deg(type: StringName) -> float:
	return float(ARCS.get(type, ARCS[DEFAULT_TYPE]))


static func cleave(type: StringName) -> int:
	return int(CLEAVE.get(type, CLEAVE[DEFAULT_TYPE]))


static func stagger(type: StringName) -> float:
	return float(STAGGER.get(type, STAGGER[DEFAULT_TYPE]))


static func structural_scale(type: StringName) -> float:
	return float(STRUCTURAL.get(type, STRUCTURAL[DEFAULT_TYPE]))


static func swing_pool(type: StringName) -> Array:
	return (POOLS.get(type, POOLS[DEFAULT_TYPE]) as Array).duplicate()


static func clip_speed(type: StringName) -> float:
	return float(CLIP_SPEED.get(type, 1.0))


## Bare hands have no authored heavy swing, so a heavy request becomes a
## committed strike with the same clip instead of a dead button.
static func has_heavy(type: StringName) -> bool:
	for clip in swing_pool(type):
		if MeleeSwingLibrary.is_heavy(clip as StringName):
			return true
	return false
