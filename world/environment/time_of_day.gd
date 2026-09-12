class_name TimeOfDay
extends RefCounted
## Pure, deterministic sun / moon / time-phase maths for Ring Bell.
##
## The clock itself lives in the `GameClock` autoload (`total_minutes`,
## `time_scale`, `paused`); this class only *derives* astronomical state from a
## minute-of-day, so identical input always yields an identical sun.  No RNG, no
## node state, no frame-rate dependence - which is what makes lighting
## deterministic and cheap enough to re-evaluate every frame.
##
## Model: flattened sphere earth, fixed solar declination (EnvironmentConfig),
## zenith at 13:00.  Tuned so sunrise lands on 06:00 and sunset on 20:00, which
## is the contract GameClock.is_night() and the streetlamps already use.

enum Phase { MIDNIGHT, PRE_DAWN, DAWN, MORNING, NOON, AFTERNOON, SUNSET, EVENING }

const PHASE_NAMES: Array[StringName] = [
	&"midnight", &"pre_dawn", &"dawn", &"morning",
	&"noon", &"afternoon", &"sunset", &"evening",
]

#: Dawn/dusk are the "golden hour" windows used for the phase readout only.
const DAWN_START_MINUTES := 300.0      # 05:00
const DAWN_END_MINUTES := 420.0        # 07:00
const SUNSET_START_MINUTES := 1050.0   # 17:30
const SUNSET_END_MINUTES := 1200.0     # 20:00


static func minute_of_day_of(total_minutes: float) -> float:
	return fposmod(total_minutes, float(EnvironmentConfig.MINUTES_PER_DAY))


static func day_of(total_minutes: float) -> int:
	return floori(total_minutes / float(EnvironmentConfig.MINUTES_PER_DAY)) + 1


static func hour_of(minute_of_day: float) -> float:
	return fposmod(minute_of_day, float(EnvironmentConfig.MINUTES_PER_DAY)) / 60.0


static func clock_string(minute_of_day: float) -> String:
	var m := int(floorf(fposmod(minute_of_day, 1440.0)))
	return "%02d:%02d" % [m / 60, m % 60]


## Matches GameClock.is_night() exactly (h < 6 or h >= 20).
static func is_night(minute_of_day: float) -> bool:
	var h := hour_of(minute_of_day)
	return h < 6.0 or h >= 20.0


static func phase_of(minute_of_day: float) -> int:
	var m := fposmod(minute_of_day, 1440.0)
	if m < DAWN_START_MINUTES:
		return Phase.MIDNIGHT      # 00:00 - 05:00
	if m < DAWN_END_MINUTES:
		return Phase.DAWN          # 05:00 - 07:00
	if m < 600.0:
		return Phase.MORNING       # 07:00 - 10:00
	if m < 840.0:
		return Phase.NOON          # 10:00 - 14:00
	if m < SUNSET_START_MINUTES:
		return Phase.AFTERNOON     # 14:00 - 17:30
	if m < SUNSET_END_MINUTES:
		return Phase.SUNSET        # 17:30 - 20:00
	if m < 1380.0:
		return Phase.EVENING       # 20:00 - 23:00
	return Phase.MIDNIGHT          # 23:00 - 24:00


static func phase_name(minute_of_day: float) -> StringName:
	return PHASE_NAMES[phase_of(minute_of_day)]


## Solar hour angle in radians; 0 at zenith (13:00), +/-PI at anti-zenith.
static func hour_angle_rad(minute_of_day: float) -> float:
	var zenith := EnvironmentConfig.SOLAR_ZENITH_HOUR * 60.0
	return PI * (fposmod(minute_of_day, 1440.0) - zenith) / 720.0


## Sun height above the horizon, radians.  Negative == below horizon.
static func sun_elevation_rad(minute_of_day: float) -> float:
	var lat := deg_to_rad(EnvironmentConfig.LATITUDE_DEG)
	var dec := deg_to_rad(EnvironmentConfig.SOLAR_DECLINATION_DEG)
	var ha := hour_angle_rad(minute_of_day)
	var sin_elev := sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)
	return asin(clampf(sin_elev, -1.0, 1.0))


static func sun_elevation_deg(minute_of_day: float) -> float:
	return rad_to_deg(sun_elevation_rad(minute_of_day))


## Unit vector pointing FROM the world TOWARDS the sun.
## Godot axes: +X east, -Z north, +Z south, +Y up.
static func sun_direction(minute_of_day: float) -> Vector3:
	var elev := sun_elevation_rad(minute_of_day)
	var ha := hour_angle_rad(minute_of_day)
	var lat := deg_to_rad(EnvironmentConfig.LATITUDE_DEG)
	var dec := deg_to_rad(EnvironmentConfig.SOLAR_DECLINATION_DEG)
	var cos_elev := maxf(cos(elev), 0.0001)
	var sin_az := -cos(dec) * sin(ha) / cos_elev
	var cos_az := (sin(dec) - sin(elev) * sin(lat)) / (cos_elev * cos(lat))
	var az := atan2(sin_az, cos_az)   # compass bearing, from north towards east
	return Vector3(sin(az) * cos_elev, sin(elev), -cos(az) * cos_elev)


## Stylised moon: mirror of the sun, so night always has a key light.
static func moon_direction(minute_of_day: float) -> Vector3:
	var sun := sun_direction(minute_of_day)
	return Vector3(-sun.x, sin(-sun_elevation_rad(minute_of_day)), -sun.z).normalized()


## 0.0 at/below the horizon, 1.0 once the sun is comfortably up.
## smoothstep gives zero derivative at both ends, so sunrise cannot pop.
static func daylight_factor(minute_of_day: float) -> float:
	var s := sin(sun_elevation_rad(minute_of_day))
	return smoothstep(0.0, 0.42, s)


## 1.0 at the horizon, 0.0 once the sun is high: drives the warm dawn/dusk tint.
static func dusk_warmth(minute_of_day: float) -> float:
	var s := sin(sun_elevation_rad(minute_of_day))
	return smoothstep(0.30, 0.02, s) * smoothstep(-0.18, -0.02, s)


## 0.0 while the sun is up, 1.0 deep at night.
static func night_factor(minute_of_day: float) -> float:
	var s := sin(sun_elevation_rad(minute_of_day))
	return smoothstep(0.02, -0.18, s)


## Moon brightness factor: night gate * (moon phase).  Never reaches zero so
## midnight stays navigable (success criterion 2 + requirement 8).
static func moon_visibility(minute_of_day: float, day: int) -> float:
	var phase := fposmod(float(day) / EnvironmentConfig.MOON_CYCLE_DAYS, 1.0)
	var cycle := 0.5 + 0.5 * cos(phase * TAU)      # 1.0 full .. 0.0 new
	var phase_scale := lerpf(EnvironmentConfig.MOON_MIN_VISIBILITY, 1.0, cycle)
	return night_factor(minute_of_day) * phase_scale


## Sun below the horizon AND lamps should be lit (GameClock semantics).
static func is_sunset_hour(minute_of_day: float) -> bool:
	return is_night(minute_of_day)
