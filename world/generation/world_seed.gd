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
const GENERATOR_VERSION := 1

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
