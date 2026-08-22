class_name HealthComponent
extends Node
## Health, injury aftermath (infection) and death signaling for one actor.
##
## Owns: current_health, infection progression, dead flag + died signal.
## Does NOT own: needs, movement, AI reactions. The owning actor coordinates
## those (see survivor.gd tick_survival).
##
## Infection is the P0 stand-in for Project-Zomboid-style consequences:
## bites may infect, infection slowly drains health, antibiotics reduce it.

signal damaged(amount: float, source_id: StringName)
signal healed(amount: float)
signal died(source_id: StringName)

const INFECTION_RATE_PER_GAME_MIN := 0.004   # infection growth per game minute
const INFECTION_HEALTH_DRAIN_MAX := 1.6      # hp/sec at full infection
const REGEN_HP_PER_SEC := 0.8                # natural regen when fed and rested

@export var max_health := 100.0

var current_health: float = max_health
var infection := 0.0                         # 0..1
var is_dead := false


func damage(amount: float, source_id: StringName = &"") -> void:
	if is_dead or amount <= 0.0:
		return
	current_health = maxf(current_health - amount, 0.0)
	damaged.emit(amount, source_id)
	if current_health <= 0.0:
		_die(source_id)


func heal(amount: float) -> void:
	if is_dead or amount <= 0.0:
		return
	var applied := minf(amount, max_health - current_health)
	current_health += applied
	healed.emit(applied)


## A zombie bite: direct damage plus an infection risk roll.
func apply_bite(damage: float, source_id: StringName) -> void:
	damage(damage, source_id)
	if not is_dead and randf() < 0.35:
		infection = clampf(infection + 0.25, 0.0, 1.0)


func treat_infection(fraction_removed: float) -> void:
	infection = clampf(infection * (1.0 - fraction_removed), 0.0, 1.0)


## Called every physics frame by the owning actor.
## `can_regen` lets the owner gate regen on its own needs state.
func tick(delta: float, can_regen: bool) -> void:
	if is_dead:
		return
	if infection > 0.0:
		var game_minutes := delta * GameClock.time_scale
		infection = clampf(infection + INFECTION_RATE_PER_GAME_MIN * game_minutes, 0.0, 1.0)
		current_health -= INFECTION_HEALTH_DRAIN_MAX * infection * delta
		if current_health <= 0.0:
			_die(&"infection")
	elif can_regen and current_health < max_health:
		current_health = minf(current_health + REGEN_HP_PER_SEC * delta, max_health)


func _die(source_id: StringName) -> void:
	if is_dead:
		return
	is_dead = true
	current_health = 0.0
	died.emit(source_id)


func save_state() -> Dictionary:
	return {
		"hp": current_health,
		"infection": infection,
	}


func load_state(data: Dictionary) -> void:
	current_health = clampf(float(data.get("hp", max_health)), 0.0, max_health)
	infection = clampf(float(data.get("infection", 0.0)), 0.0, 1.0)
