class_name EnvironmentAmbience
extends Node3D
## Exterior ambience for the Ring Bell environment subsystem.
##
## The loops are *generated*, not shipped: a filtered-noise rain bed, a slower
## wind bed and a thunder crack are synthesised from the world seed at startup.
## That keeps three promises at once - nothing copyrighted is downloaded, the
## project still has working ambience hooks before an audio pass exists, and the
## asset slots are explicit (drop a real .ogg into `STREAM_SLOTS` later and it
## replaces the generated stream without touching any call site).
##
## Volume is driven by the weather: rain rises with precipitation, wind rises
## with gusted wind speed, and both are cut when the player is under a roof
## (`exposure`), which is the audio half of the indoor/outdoor requirement.
##
## Headless / no-audio runs are a no-op: with a Dummy audio driver the players
## are never started, but the event bookkeeping (thunder count, levels) still
## happens so tests can assert on it.

## Drop-in asset slots.  Null == synthesise instead.
const STREAM_SLOTS := {
	"rain": "",
	"wind": "",
	"thunder": "",
}

const MIX_RATE := 22050

var rain_level := 0.0
var wind_level := 0.0
var thunder_plays := 0

var _rain: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _thunder: AudioStreamPlayer
var _streams: Dictionary = {}
var _enabled := true
var _audio_ok := true
var _generated := false


func _init() -> void:
	name = "EnvironmentAmbience"


func _ready() -> void:
	_audio_ok = AudioServer.get_driver_name() != "Dummy"
	_build_players()
	call_deferred("_generate")


func set_enabled(value: bool) -> void:
	_enabled = value
	if not value:
		_stop_all()


func _build_players() -> void:
	if _rain != null:
		return
	_rain = _make_player("RainBed")
	_wind = _make_player("WindBed")
	_thunder = _make_player("Thunder")


func _make_player(node_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = node_name
	# GameSettings creates an "Ambience" bus, so the ambience volume slider and
	# mute already govern this without any extra plumbing.
	p.bus = &"Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else &"Master"
	p.volume_db = -80.0
	add_child(p)
	return p


func is_enabled() -> bool:
	return _enabled


func _generate() -> void:
	if _generated:
		return
	_generated = true
	var slot_rain := String(STREAM_SLOTS.get("rain", ""))
	var slot_wind := String(STREAM_SLOTS.get("wind", ""))
	var slot_thunder := String(STREAM_SLOTS.get("thunder", ""))
	_streams["rain"] = _load_or_make(slot_rain, func() -> AudioStream:
		return _make_loop("rain", EnvironmentConfig.AMBIENCE_RAIN_LOOP_SECONDS, 0.34, 0.30, 1.7, 0.35, 0.0))
	_streams["wind"] = _load_or_make(slot_wind, func() -> AudioStream:
		return _make_loop("wind", EnvironmentConfig.AMBIENCE_WIND_LOOP_SECONDS, 0.055, 0.42, 0.28, 0.55, 0.0))
	_streams["thunder"] = _load_or_make(slot_thunder, func() -> AudioStream:
		return _make_thunder())
	if _rain != null:
		_rain.stream = _streams["rain"]
		_wind.stream = _streams["wind"]
		_thunder.stream = _streams["thunder"]


func _load_or_make(path: String, fallback: Callable) -> AudioStream:
	if not path.is_empty() and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is AudioStream:
			return res
	return fallback.call() as AudioStream


# ----------------------------------------------------------------- synthesis
## One-pole filtered noise with slow amplitude modulation and a seamless loop
## (the tail is crossfaded into the head, so LOOP_FORWARD does not click).
func _make_loop(purpose: String, seconds: float, lowpass: float, amp: float,
		mod_hz: float, mod_depth: float, sub_hz: float) -> AudioStreamWAV:
	# `WorldSeed.combine` mixes integers only, so the loop name is folded into the
	# purpose string and the tunables arrive as fixed-point ints.
	var rng := WorldSeed.rng_for("environment_ambience_" + purpose,
			[int(seconds * 1000.0), int(lowpass * 1000.0)])
	var count := int(seconds * float(MIX_RATE))
	var samples := PackedFloat32Array()
	samples.resize(count)
	var filtered := 0.0
	var sub_phase := 0.0
	for i in count:
		var white := rng.randf_range(-1.0, 1.0)
		filtered = lerpf(filtered, white, lowpass)
		var t := float(i) / float(MIX_RATE)
		var mod := 1.0 - mod_depth + mod_depth * (0.5 + 0.5 * sin(TAU * mod_hz * t))
		var v := filtered * amp * mod
		if sub_hz > 0.0:
			sub_phase += TAU * sub_hz / float(MIX_RATE)
			v += sin(sub_phase) * amp * 0.22 * mod
		samples[i] = v
	var cross := mini(int(0.06 * float(MIX_RATE)), count / 4)
	for i in cross:
		var w := float(i) / float(cross)
		samples[i] = lerpf(samples[i], samples[count - cross + i], w)
	return _to_stream(samples, true)


## Crack-then-rumble thunder: a fast attack envelope plus a long filtered tail.
func _make_thunder() -> AudioStreamWAV:
	var rng := WorldSeed.rng_for("environment_ambience_thunder",
			[int(EnvironmentConfig.AMBIENCE_THUNDER_SECONDS * 1000.0)])
	var seconds := EnvironmentConfig.AMBIENCE_THUNDER_SECONDS
	var count := int(seconds * float(MIX_RATE))
	var samples := PackedFloat32Array()
	samples.resize(count)
	var filtered := 0.0
	var sub := 0.0
	for i in count:
		var t := float(i) / float(MIX_RATE)
		var white := rng.randf_range(-1.0, 1.0)
		filtered = lerpf(filtered, white, 0.05)
		var rumble := exp(-t * 1.25) * (1.0 - exp(-t * 26.0))
		var crack := exp(-t * 9.0) * (1.0 - exp(-t * 240.0))
		sub += TAU * 42.0 / float(MIX_RATE)
		samples[i] = filtered * rumble * 0.95 + sin(sub) * crack * 0.55
	return _to_stream(samples, false)


func _to_stream(samples: PackedFloat32Array, looped: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = bytes
	if looped:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = samples.size()
	return stream


# -------------------------------------------------------------------- levels
func update_frame(precipitation: float, storm: float, wind_speed: float, shelter: float) -> void:
	if not _generated:
		_generate()
	if not _enabled:
		return
	var indoor := clampf(shelter, 0.0, 1.0)
	var cut := 1.0 - indoor * (1.0 - EnvironmentConfig.AMBIENCE_INDOOR_CUT)
	rain_level = clampf(precipitation, 0.0, 1.0) * cut
	wind_level = clampf(wind_speed / 14.0, 0.0, 1.0) * cut
	_set_loop(_rain, rain_level, EnvironmentConfig.AMBIENCE_RAIN_DB_MAX + clampf(storm, 0.0, 1.0) * 3.0)
	_set_loop(_wind, wind_level, EnvironmentConfig.AMBIENCE_WIND_DB_MAX)


func _set_loop(player: AudioStreamPlayer, level: float, db_max: float) -> void:
	if player == null:
		return
	if level <= 0.02:
		if player.playing:
			player.stop()
		return
	var db := db_max + linear_to_db(clampf(level, 0.0001, 1.0))
	if player.playing:
		player.volume_db = db
	elif _audio_ok:
		player.volume_db = db
		player.play()


## Thunder fires *after* the flash; the delay is the manager's business, this
## only cares about how loud and how far away it sounded.
func play_thunder(intensity: float, distance_m: float) -> void:
	thunder_plays += 1
	if not _enabled or not _generated:
		return
	var atten := clampf(distance_m / 1400.0, 0.0, 1.0)
	var db := EnvironmentConfig.AMBIENCE_THUNDER_DB_MAX - atten * 26.0 \
			+ clampf(intensity, 0.0, 1.0) * 4.0
	_thunder_db = db
	if _audio_ok and _thunder != null:
		_thunder.stop()
		_thunder.volume_db = db
		_thunder.pitch_scale = 0.86 + clampf(intensity, 0.0, 1.0) * 0.24
		_thunder.play()


var _thunder_db := -80.0


func _stop_all() -> void:
	for p in [_rain, _wind, _thunder]:
		if p != null and p.playing:
			p.stop()


func last_thunder_db() -> float:
	return _thunder_db


func stream_bytes(kind: String) -> int:
	var s: Variant = _streams.get(kind)
	if s is AudioStreamWAV:
		return (s as AudioStreamWAV).data.size()
	return 0


func state() -> Dictionary:
	return {
		"enabled": _enabled,
		"audio": _audio_ok,
		"rain_level": snappedf(rain_level, 0.001),
		"wind_level": snappedf(wind_level, 0.001),
		"thunder_plays": thunder_plays,
	}
