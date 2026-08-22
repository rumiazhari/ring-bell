class_name NeedsComponent
extends Node
## Survival needs for one actor. All values are 0..100 where 100 = worst
## (fully starving / exhausted). Rates are defined per GAME minute so time
## scale changes (debug or sleeping) affect them consistently.
##
## Effects (kept deliberately simple for P0):
##   - hunger/thirst/fatigue reduce movement speed near the top of the scale
##   - starving/dehydrated actors slowly lose health (handled by owner tick)

const STARVING_HP_DRAIN_PER_SEC := 1.2     # at hunger >= 95, scaled by overshoot
const DEHYDRATION_HP_DRAIN_PER_SEC := 1.6

@export var hunger_rate := 0.055           # per game minute
@export var thirst_rate := 0.075
@export var fatigue_rate := 0.04

var hunger := 30.0
var thirst := 35.0
var fatigue := 20.0

## Set true by the owner while sprinting; accelerates fatigue.
var exerting := false

## Set true while sleeping: needs slow down and fatigue recovers.
var sleeping := false


func tick(delta: float) -> void:
	var game_minutes := delta * GameClock.time_scale
	if sleeping:
		fatigue = clampf(fatigue - fatigue_rate * 4.0 * game_minutes, 0.0, 100.0)
		hunger = clampf(hunger + hunger_rate * 0.4 * game_minutes, 0.0, 100.0)
		thirst = clampf(thirst + thirst_rate * 0.5 * game_minutes, 0.0, 100.0)
		return
	var exertion_mult := 3.0 if exerting else 1.0
	hunger = clampf(hunger + hunger_rate * game_minutes, 0.0, 100.0)
	thirst = clampf(thirst + thirst_rate * game_minutes, 0.0, 100.0)
	fatigue = clampf(fatigue + fatigue_rate * game_minutes * exertion_mult, 0.0, 100.0)


## Health drain from extreme deprivation; called by owning actor.
## Returns hp lost this frame.
func deprivation_damage(delta: float) -> float:
	if sleeping:
		return 0.0
	var dmg := 0.0
	if hunger > 95.0:
		dmg += STARVING_HP_DRAIN_PER_SEC * (hunger - 95.0) / 5.0
	if thirst > 95.0:
		dmg += DEHYDRATION_HP_DRAIN_PER_SEC * (thirst - 95.0) / 5.0
	return dmg * delta


func eat(hunger_reduction: float) -> void:
	hunger = clampf(hunger - hunger_reduction, 0.0, 100.0)


func drink(thirst_reduction: float) -> void:
	thirst = clampf(thirst - thirst_reduction, 0.0, 100.0)


## Movement speed multiplier from condition (never above 1.0).
func speed_multiplier() -> float:
	var mult := 1.0
	mult *= remap_clamped(hunger, 70.0, 100.0, 1.0, 0.6)
	mult *= remap_clamped(thirst, 70.0, 100.0, 1.0, 0.6)
	mult *= remap_clamped(fatigue, 80.0, 100.0, 1.0, 0.7)
	return mult


static func remap_clamped(value: float, in_from: float, in_to: float, out_from: float, out_to: float) -> float:
	var t := clampf((value - in_from) / maxf(in_to - in_from, 0.001), 0.0, 1.0)
	return lerpf(out_from, out_to, t)


func save_state() -> Dictionary:
	return {"hunger": hunger, "thirst": thirst, "fatigue": fatigue}


func load_state(data: Dictionary) -> void:
	hunger = float(data.get("hunger", hunger))
	thirst = float(data.get("thirst", thirst))
	fatigue = float(data.get("fatigue", fatigue))
