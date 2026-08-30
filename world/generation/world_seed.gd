class_name WorldSeed
extends RefCounted
## Deterministic randomness foundation for procedural city generation.
##
## Every random decision anywhere in generation MUST come from here, seeded by
## [world_seed, purpose string hash, integer coords...]. Two chunk builds for
## the same coordinates under the same world seed therefore produce identical
## results no matter which neighbors were generated first - this is the core
## determinism contract (enforced by debug/world_test.gd --citytest).
##
## GENERATOR_VERSION must be bumped whenever generation logic changes in a way
## that would alter existing city layouts; saves carry it so old worlds are
## never silently regenerated into something else.

const CHUNK_SIZE := 64                 # meters per streaming chunk edge
const GENERATOR_VERSION := 2

# ProjectSettings key so a seed can be forced via override files / CLI.
const SEED_SETTING := "world/generation/seed"
const DEFAULT_SEED := 19041207

# SplitMix64-style avalanche constants. Written as their two's-complement
# negatives because GDScript rejects hex literals >= 2^63.
const GOLDEN := -0x61C8864680B583EB     # == 0x9E3779B97F4A7C15
const MIX_A := -0x40A7B892E31B1A47      # == 0xBF58476D1CE4E5B9
const MIX_B := -0x6B2FB644ECCEEE15      # == 0x94D049BB133111EB


static func get_world_seed() -> int:
	if ProjectSettings.has_setting(SEED_SETTING):
		return int(ProjectSettings.get_setting(SEED_SETTING))
	return DEFAULT_SEED


static func set_world_seed(value: int) -> void:
	ProjectSettings.set_setting(SEED_SETTING, value)

## Chunk coordinate for a world XZ position.
static func chunk_coord(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / float(CHUNK_SIZE)), floori(z / float(CHUNK_SIZE)))


## World-space rect of one chunk.
static func chunk_rect(coord: Vector2i) -> Rect2:
	var origin := Vector2(coord) * float(CHUNK_SIZE)
	return Rect2(origin, Vector2(CHUNK_SIZE, CHUNK_SIZE))


## Mixes one int through SplitMix64 (avalanche). Wraps mod 2^64 like C ints.
static func mix64(x: int) -> int:
	x += GOLDEN
	x = (x ^ (x >> 30)) * MIX_A
	x = (x ^ (x >> 27)) * MIX_B
	return x ^ (x >> 31)

## Stable positive hash for a purpose name ("roads", "parcels", ...).
static func str_hash(purpose: String) -> int:
	var h := 1469598103934665603    # FNV-1a offset basis
	for i in purpose.length():
		h = (h ^ purpose.unicode_at(i)) * 1099511628211
	return h


## Combine arbitrary integer parts (seed, purpose hash, coords) into one seed.
static func combine(parts: Array) -> int:
	var h := 0
	for p: int in parts:
		h = mix64(h ^ p)
	if h == -9223372036854775808:   # absi() edge case
		return 4611686018427387904
	return absi(h)


## Fresh RNG for [world_seed, purpose, coords...]. NEVER share it across
## purposes or coordinates; derive a new one instead so evaluation order of
## unrelated systems can never change each other's streams.
static func rng_for(purpose: String, parts: Array = []) -> RandomNumberGenerator:
	var all_parts := [get_world_seed(), str_hash(purpose)]
	all_parts.append_array(parts)
	var gen := RandomNumberGenerator.new()
	gen.seed = combine(all_parts)
	return gen

## Uniform float in [0,1) straight from the mixed hash - no RNG object needed.
## Ideal for point lookups (district noise) where allocating an RNG is waste.
static func unit_float(purpose: String, parts: Array) -> float:
	return float(combine([get_world_seed(), str_hash(purpose)] + parts) % 1000003) \
			/ 1000003.0

# --- Stateless coordinate sampling (P2 terrain) -------------------------------

const TERRAIN_DOMAINS: Array[StringName] = [&"terrain", &"ridge", &"valley", &"soil", &"moisture", &"temperature", &"geology", &"settlement"]
const HYDRO_DOMAINS: Array[StringName] = [&"hydro", &"hydro_cx", &"hydro_phi", &"hydro_meander2", &"hydro_width", &"hydro_level", &"hydro_trib_ax", &"hydro_trib_az", &"hydro_trib_cz", &"hydro_trib_mid"]
const GEOLOGY_DOMAINS: Array[StringName] = [&"geology", &"geology_ridge", &"geology_soil", &"geology_strata", &"geology_fertility", &"geology_quarry", &"geology_cave"]
const BIOME_DOMAINS: Array[StringName] = [&"biome", &"biome_moisture", &"biome_temp", &"biome_forest_field", &"biome_orchard", &"biome_field_edge", &"biome_density", &"biome_tint"]
const SETTLEMENT_DOMAINS: Array[StringName] = [&"settlement", &"settlement_field", &"settlement_jitter", &"settlement_gate_phi", &"settlement_gate_radius", &"settlement_jitter_count"]
const ROAD_DOMAINS: Array[StringName] = [&"road", &"road_mid", &"road_width", &"road_hierarchy", &"road_extra"]
const RURAL_BUILDING_DOMAINS: Array[StringName] = [&"rural_building", &"rural_building_count", &"rural_building_radius", &"rural_building_angle", &"rural_building_fp_x", &"rural_building_fp_y", &"rural_building_yaw", &"rural_building_palette", &"rural_building_nudge"]
const RURAL_INTERIOR_DOMAINS: Array[StringName] = [&"rural_interior", &"rural_interior_wall", &"rural_interior_wall_gap", &"rural_furniture", &"rural_crate", &"rural_crate_contents"]
const RURAL_RESOURCE_DOMAINS: Array[StringName] = [&"rural_well", &"rural_well_radius", &"rural_well_angle", &"rural_well_nudge", &"rural_forage", &"rural_forage_kind", &"rural_forage_density"]

## Stateless coherent noise in [0,1] for world position p.
## Uses floor-based lattice indexing + smoothstep (3t^2-2t^3) bilinear interpolation
## so the field is C0 continuous at every lattice and chunk boundary, including
## negative coordinates. No RNG stream is shared between queries.
static func sample_coherent(p: Vector2, domain: StringName, cell_size: float, seed: int = -1) -> float:
	var s: int = seed if seed != -1 else get_world_seed()
	var fx := p.x / cell_size
	var fy := p.y / cell_size
	var ix0 := floori(fx)
	var iy0 := floori(fy)
	var ix1 := ix0 + 1
	var iy1 := iy0 + 1
	var tx := fx - float(ix0)
	var ty := fy - float(iy0)
	var sx := tx * tx * (3.0 - 2.0 * tx)
	var sy := ty * ty * (3.0 - 2.0 * ty)
	var h00 := _lattice_unit(s, domain, ix0, iy0)
	var h10 := _lattice_unit(s, domain, ix1, iy0)
	var h01 := _lattice_unit(s, domain, ix0, iy1)
	var h11 := _lattice_unit(s, domain, ix1, iy1)
	var lx0 := lerpf(h00, h10, sx)
	var lx1 := lerpf(h01, h11, sx)
	return lerpf(lx0, lx1, sy)

## Same as sample_coherent but mapped to [-1,1].
static func sample_coherent_signed(p: Vector2, domain: StringName, cell_size: float, seed: int = -1) -> float:
	return sample_coherent(p, domain, cell_size, seed) * 2.0 - 1.0

## Explicit-seed helper for tests: does not mutate global seed state.
static func sample_coherent_with_seed(p: Vector2, domain: StringName, cell_size: float, explicit_seed: int) -> float:
	return sample_coherent(p, domain, cell_size, explicit_seed)

static func _lattice_unit(seed_val: int, domain: StringName, ix: int, iy: int) -> float:
	return float(combine([seed_val, str_hash(String(domain)), ix, iy]) % 1000003) / 1000003.0
