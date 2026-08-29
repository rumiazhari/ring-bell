class_name GeologyPlan
extends RefCounted
## Pure geology plan: strata, soil, quarry suitability, fertility, cave potential.
## No Node access, no unseeded randomness, no chunk-local state.
## Every query is deterministic function of seed + world coordinates via WorldSeed helpers.
## Uses cell sizes authoritative in WorldConstants: GEOLOGY_CELL 700, GEOLOGY_RIDGE_CELL 380, SOIL_CELL 220.

var seed_used: int

func _init(seed: int = WorldSeed.get_world_seed()) -> void:
	seed_used = seed

## Bedrock class
func strata_at(p: Vector2) -> StringName:
	var d := p.length()
	# Radial bias: near center lowlands => alluvial/loess, uplands => limestone/sandstone, high ridges => granite_like
	var base: float = WorldSeed.sample_coherent(p, &"geology", WorldConstants.GEOLOGY_CELL, seed_used)
	var ridge_s: float = WorldSeed.sample_coherent_signed(p, &"geology_ridge", WorldConstants.GEOLOGY_RIDGE_CELL, seed_used)
	var rf := clampf((d - 800.0) / 3000.0, 0.0, 1.0)
	# biased value 0..1 with radial and ridge influence
	var biased := base + rf * 0.35 + ridge_s * 0.08
	biased = clampf(biased, 0.0, 1.0)
	if biased < 0.22:
		return &"alluvial"
	elif biased < 0.44:
		return &"loess"
	elif biased < 0.68:
		# limestone vs sandstone split with ridge
		if ridge_s > 0.0:
			return &"limestone"
		else:
			return &"sandstone"
	elif biased < 0.88:
		if ridge_s > -0.2:
			return &"sandstone"
		else:
			return &"limestone"
	else:
		return &"granite_like"

func soil_at(p: Vector2) -> StringName:
	var strata := strata_at(p)
	var soil_n: float = WorldSeed.sample_coherent(p, &"geology_soil", WorldConstants.SOIL_CELL, seed_used)
	# soil vocab maps 1-1 from strata but with slight variation for meadow/peat near wet areas (kept within vocab)
	match strata:
		&"alluvial":
			return &"alluvial_soil"
		&"loess":
			return &"loess_soil"
		&"limestone":
			return &"limestone_soil"
		&"sandstone":
			return &"sandstone_soil"
		&"granite_like":
			return &"granite_soil"
		_:
			return &"alluvial_soil"

func quarry_suitability_at(p: Vector2) -> float:
	var strata := strata_at(p)
	var base_suit: float = 0.15
	match strata:
		&"limestone":
			base_suit = 0.65
		&"sandstone":
			base_suit = 0.60
		&"granite_like":
			base_suit = 0.70
		&"loess":
			base_suit = 0.18
		&"alluvial":
			base_suit = 0.12
	var ridge_v: float = WorldSeed.sample_coherent(p, &"geology_ridge", WorldConstants.GEOLOGY_RIDGE_CELL, seed_used)
	var quarry_n: float = WorldSeed.sample_coherent(p, &"geology_quarry", WorldConstants.GEOLOGY_RIDGE_CELL, seed_used)
	var hf: float = WorldSeed.sample_coherent(p, &"geology", 48.0, seed_used)
	var d := p.length()
	var rf := clampf((d - 800.0) / 3000.0, 0.0, 1.0)
	var v := base_suit + ridge_v * 0.20 + quarry_n * 0.12 + hf * 0.18 + rf * 0.08
	return clampf(v, 0.0, 1.0)

func fertility_at(p: Vector2) -> float:
	var strata := strata_at(p)
	var base_f: float = 0.3
	match strata:
		&"loess":
			base_f = 0.78
		&"alluvial":
			base_f = 0.75
		&"limestone":
			base_f = 0.35
		&"sandstone":
			base_f = 0.40
		&"granite_like":
			base_f = 0.15
	var soil_n: float = WorldSeed.sample_coherent(p, &"geology_soil", WorldConstants.SOIL_CELL, seed_used)
	var d := p.length()
	var rf := clampf((d - 800.0) / 3000.0, 0.0, 1.0)
	# Lowlands near center more fertile, uplands less
	var v := base_f + (soil_n - 0.5) * 0.20 + (1.0 - rf) * 0.08
	return clampf(v, 0.0, 1.0)

func cave_potential_at(p: Vector2) -> float:
	var strata := strata_at(p)
	var cave_n: float = WorldSeed.sample_coherent(p, &"geology_cave", WorldConstants.GEOLOGY_RIDGE_CELL, seed_used)
	var d := p.length()
	var rf := clampf((d - 600.0) / 2500.0, 0.0, 1.0)
	var base: float = 0.1
	match strata:
		&"limestone":
			base = 0.55 + cave_n * 0.30 + rf * 0.10
		&"granite_like":
			base = 0.40 + cave_n * 0.25 + rf * 0.08
		&"sandstone":
			base = 0.25 + cave_n * 0.20
		&"loess":
			base = 0.08 + cave_n * 0.10
		&"alluvial":
			base = 0.05 + cave_n * 0.08
	return clampf(base, 0.0, 1.0)

func geology_profile(rect: Rect2, step: float) -> Dictionary:
	if step <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return {}
	var nx := int(ceil(rect.size.x / step)) + 1
	var ny := int(ceil(rect.size.y / step)) + 1
	if nx * ny > 100000:
		return {}
	var strata_samples: Array[StringName] = []
	strata_samples.resize(nx * ny)
	var soil_samples: Array[StringName] = []
	soil_samples.resize(nx * ny)
	var quarry_samples := PackedFloat32Array()
	quarry_samples.resize(nx * ny)
	var fertility_samples := PackedFloat32Array()
	fertility_samples.resize(nx * ny)
	var cave_samples := PackedFloat32Array()
	cave_samples.resize(nx * ny)
	var idx := 0
	for j in ny:
		for i in nx:
			var x := rect.position.x + float(i) * step
			var y := rect.position.y + float(j) * step
			if x > rect.end.x:
				x = rect.end.x
			if y > rect.end.y:
				y = rect.end.y
			var p := Vector2(x, y)
			strata_samples[idx] = strata_at(p)
			soil_samples[idx] = soil_at(p)
			quarry_samples[idx] = quarry_suitability_at(p)
			fertility_samples[idx] = fertility_at(p)
			cave_samples[idx] = cave_potential_at(p)
			idx += 1
	return {
		"rect": rect,
		"step": step,
		"nx": nx,
		"ny": ny,
		"strata": strata_samples,
		"soil": soil_samples,
		"quarry": quarry_samples,
		"fertility": fertility_samples,
		"cave": cave_samples,
	}
