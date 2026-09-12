class_name EnvironmentConfig
extends RefCounted
## Central tunables for the Ring Bell environment subsystem.
##
## Every number an artist or another system might want to retune lives here so the
## controllers contain logic only.  Nothing in this file touches the scene tree,
## the RNG or the clock: it is pure data plus small helpers.
##
## Runtime owner: `world/environment/environment_manager.gd`.
## Design notes: `.hermes/autopilot/ENVIRONMENT_OVERHAUL.md`.

enum Quality { LOW = 0, MEDIUM = 1, HIGH = 2 }

const QUALITY_NAMES: Array[StringName] = [&"low", &"medium", &"high"]

# --------------------------------------------------------------------- time
const MINUTES_PER_DAY := 1440
## Real seconds for one in-game day.  GameClock.time_scale is "game minutes per
## real second", so a day length of 1440 s at time_scale 1.0 == 24 real minutes.
const DAY_LENGTH_SECONDS := 1440.0
const MIN_DAY_LENGTH_SECONDS := 120.0     # 2 real minutes  - fastest sane day
const MAX_DAY_LENGTH_SECONDS := 14400.0   # 4 real hours    - slowest sane day

# -------------------------------------------------------------------- solar
## Stylised Prague-ish astronomy.  Declination is tuned so the model reproduces
## the project's existing convention exactly: sun up at 06:00, down at 20:00,
## zenith at 13:00 (that is what GameClock.is_night() and the streetlamp
## contract already assume, so lamps and sun never disagree about night).
const LATITUDE_DEG := 50.08
const SOLAR_DECLINATION_DEG := 12.2
const SOLAR_ZENITH_HOUR := 13.0
const MOON_CYCLE_DAYS := 29.53
## Deepest moon contribution (new moon); 1.0 == full moon.
const MOON_MIN_VISIBILITY := 0.45

# ------------------------------------------------------------------ wetness
## Wetness rises at WETNESS_GAIN * precipitation per game minute and dries far
## slower, so a shower leaves the streets looking wet for a while afterwards.
const WETNESS_GAIN_PER_GAME_MINUTE := 0.055
const WETNESS_DRY_PER_GAME_MINUTE := 0.0042
const WETNESS_PRECIP_THRESHOLD := 0.03
const WETNESS_MAX_JUMP_MINUTES := 5.0   # clamp after load/time skips

# --------------------------------------------------------------------- wind
const GUST_FREQUENCY := 0.09        # cycles per game minute
const GUST_AMPLITUDE := 0.22        # +/- fraction of base speed

# ---------------------------------------------------------------- lightning
const LIGHTNING_MIN_REAL_GAP := 2.0       # real seconds (anti-strobe valve)
const LIGHTNING_STRIKE_MIN_GAP := 2.6     # game minutes between strikes
const LIGHTNING_STRIKE_MAX_GAP := 11.0    # game minutes
const LIGHTNING_MAX_STRIKES_PER_EPISODE := 64
const LIGHTNING_STORM_BUILD_MINUTES := 10.0
const THUNDER_SPEED_MPS := 343.0
const THUNDER_DELAY_MIN := 0.35
const THUNDER_DELAY_MAX := 11.0

# ------------------------------------------------------- weather episodes
const EPISODE_MIN_MINUTES := 60.0
const EPISODE_MAX_MINUTES := 240.0
const TRANSITION_MINUTES := 75.0          # blend window at each episode start
## Fog episodes only start in the early morning: radiation fog, not a light show.
const FOG_START_HOUR_MIN := 2
const FOG_START_HOUR_MAX := 8

# ---------------------------------------------------------- quality scaling
const QUALITY_RAIN_AMOUNT := {
	Quality.LOW: 700, Quality.MEDIUM: 1500, Quality.HIGH: 2600,
}
const QUALITY_RAIN_FPS := {
	Quality.LOW: 24, Quality.MEDIUM: 30, Quality.HIGH: 30,
}
const QUALITY_CLOUD_STEPS := {
	Quality.LOW: 2, Quality.MEDIUM: 3, Quality.HIGH: 4,
}
const QUALITY_VOLUMETRIC := {
	Quality.LOW: false, Quality.MEDIUM: true, Quality.HIGH: true,
}
const QUALITY_LIGHTNING_STAGES := {
	Quality.LOW: 2, Quality.MEDIUM: 3, Quality.HIGH: 3,
}

# --------------------------------------------------------------- readability
## Hard floors/ceilings the atmosphere controller clamps to, so no weather state
## can produce an unreadable frame.  These are the guards behind success
## criterion 24 ("the player must be able to see").
const MIN_AMBIENT_ENERGY := 0.028     # darkest night ambient (storm at midnight)
const MAX_AMBIENT_ENERGY := 0.75
const MIN_ZENITH_LUMA := 0.010        # darkest night sky zenith
const MIN_HORIZON_LUMA := 0.018       # darkest night horizon
const MIN_AMBIENT_LUMA := 0.10        # never let ambient light go pitch-grey
const MAX_TOTAL_LIGHT_ENERGY := 2.30  # sun+moon+ambient, blown-highlight guard
const MAX_VOLUMETRIC_DENSITY := 0.055
const MAX_FOG_DENSITY := 0.032

# --------------------------------------------------------------------- light
## Mirrors the legacy DayNightController anchors (which debug/world_test.gd still
## asserts).  Kept as the subsystem's own copy so no new file depends on the
## legacy controller - if the two ever disagree, the tests are the referee.
const NIGHT_SUN_ENERGY := 0.015
const DAY_SUN_ENERGY := 1.35
const NIGHT_AMBIENT_ENERGY := 0.045
const DAY_AMBIENT_ENERGY := 0.60
const MOON_MAX_ENERGY := 0.14
const MOON_MIN_ENERGY := 0.05

# ----------------------------------------------------------------------- sky
const SKY_BASE_HAZE := 0.06
const SKY_FOG_HAZE := 0.55
const SKY_SUN_GAIN := 1.0
const SKY_MOON_GAIN := 2.2
const SKY_CLOUD_SCALE := 3.1
const SKY_CLOUD_HEIGHT := 0.34
## Sky-plane drift per (game minute * m/s of wind): clouds visibly move with wind.
const SKY_CLOUD_DRIFT := 0.0009
const STAR_MAX := 0.85

# ----------------------------------------------------------------------- fog
const NIGHT_FOG_DENSITY := 0.008
const DAY_FOG_DENSITY := 0.0025
const NIGHT_FOG_ENERGY := 0.12
const DAY_FOG_ENERGY := 0.18
const FOG_DENSITY_SCALE := 7.0
const PRECIP_FOG_DENSITY := 0.004
const VOL_FOG_DENSITY_NIGHT := 0.022
const VOL_FOG_DENSITY_DAY := 0.005
const VOL_FOG_EMISSION_NIGHT := 0.52
const VOL_FOG_EMISSION_DAY := 0.08
const VOL_FOG_ALBEDO := Color(0.60, 0.63, 0.70)
const VOL_FOG_EMISSION := Color(0.86, 0.68, 0.42)

# ---------------------------------------------------------------------- glow
const GLOW_NIGHT := 0.62
const GLOW_DAY := 0.28
const GLOW_STRENGTH := 1.0
const GLOW_BLOOM := 0.12
const GLOW_HDR_THRESHOLD := 0.88
const GLOW_HDR_SCALE := 1.6

# ---------------------------------------------------------------------- rain
const RAIN_MIN_PRECIPITATION := 0.02
const RAIN_FALL_SPEED := 19.0        # m/s
const RAIN_STREAK_LENGTH := 0.62     # m
const RAIN_STREAK_WIDTH := 0.028
const RAIN_BOX_METERS := 44.0        # horizontal extent of the local rain box
const RAIN_BOX_HEIGHT := 30.0
const RAIN_BOX_LIFT := 9.0           # above the camera
const RAIN_LIFETIME := 1.55
const RAIN_COLOR := Color(0.72, 0.79, 0.90, 0.30)
const RAIN_COLOR_STORM := Color(0.62, 0.70, 0.86, 0.40)
## How much of the wind vector bends the fall (0 == straight down).
const RAIN_WIND_FACTOR := 0.55

# ------------------------------------------------------------------- shelter
const SHELTER_PROBE_INTERVAL := 0.25   # real seconds between roof raycasts
const SHELTER_PROBE_DISTANCE := 9.0
const SHELTER_RAIN_REDUCTION := 0.92   # rain cut when fully indoors
const SHELTER_INDOOR_THRESHOLD := 0.60
const SHELTER_SMOOTHING := 3.0         # per-second blend towards the probe result

# ------------------------------------------------------------------ ambience
const AMBIENCE_RAIN_LOOP_SECONDS := 1.6
const AMBIENCE_WIND_LOOP_SECONDS := 2.4
const AMBIENCE_THUNDER_SECONDS := 2.2
const AMBIENCE_RAIN_DB_MAX := -12.0
const AMBIENCE_WIND_DB_MAX := -16.0
const AMBIENCE_THUNDER_DB_MAX := -8.0
const AMBIENCE_INDOOR_CUT := 0.28      # rain/wind multiplier when fully sheltered



static func sky_cloud_steps(quality: int) -> int:
	return cloud_steps(quality)


## Particles actually emitted for a given precipitation level (sub-linear, so
## light drizzle is cheap and a storm is dense without being quadratic).
static func rain_particle_budget(quality: int, precipitation: float) -> int:
	var base := float(rain_amount(quality))
	return int(round(base * pow(clampf(precipitation, 0.0, 1.0), 0.75)))


static func quality_from_preset(preset: String) -> int:
	match preset:
		"low":
			return Quality.LOW
		"medium":
			return Quality.MEDIUM
		"high", "ultra":
			return Quality.HIGH
	return Quality.MEDIUM


static func quality_name(quality: int) -> StringName:
	var q := clampi(quality, 0, QUALITY_NAMES.size() - 1)
	return QUALITY_NAMES[q]


static func rain_amount(quality: int) -> int:
	return int(QUALITY_RAIN_AMOUNT.get(clampi(quality, 0, 2), 1500))


static func rain_fixed_fps(quality: int) -> int:
	return int(QUALITY_RAIN_FPS.get(clampi(quality, 0, 2), 30))


static func cloud_steps(quality: int) -> int:
	return int(QUALITY_CLOUD_STEPS.get(clampi(quality, 0, 2), 3))


static func volumetric_enabled(quality: int) -> bool:
	return bool(QUALITY_VOLUMETRIC.get(clampi(quality, 0, 2), true))


static func lightning_stages(quality: int) -> int:
	return int(QUALITY_LIGHTNING_STAGES.get(clampi(quality, 0, 2), 3))


## GameClock.time_scale that produces `seconds` real seconds per game day.
static func time_scale_for_day_length(seconds: float) -> float:
	var clamped := clampf(seconds, MIN_DAY_LENGTH_SECONDS, MAX_DAY_LENGTH_SECONDS)
	return float(MINUTES_PER_DAY) / clamped


static func day_length_seconds(time_scale: float) -> float:
	return float(MINUTES_PER_DAY) / maxf(time_scale, 0.001)
