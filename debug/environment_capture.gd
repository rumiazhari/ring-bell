extends Node
## Environment visual matrix capture + readability metrics (criteria 24, 25, 34).
##
##   godot --path "<project>" -- --envcapture      (needs a real renderer)
##   godot --headless --path "<project>" -- --envcapture   -> prints SKIPPED
##
## Builds a small street-canyon fixture (ground plane, block silhouettes, two
## warm gas-lamp style lights) and captures the ten representative environment
## combinations into res://captures/environment/, printing objective readability
## metrics for each frame: mean luminance, 1st/99th percentile, crushed-black %
## and blown-highlight %.  The thresholds exist to catch "unplayable", not to
## grade art.
##
## The fixture is intentionally independent of the streamed city: this harness
## must run while the city/interior track is mid-overhaul.

const OUT_DIR := "res://captures/environment"
const SETTLE_FRAMES := 14
## How many frames the flash is sampled over before taking the brightest.
const FLASH_SAMPLE_FRAMES := 30
const SAMPLE_STEP := 3

## min_mean / max_dark_pct per entry: night is dim but never black, storms are
## dramatic but the silhouette stays above the floor.
const MATRIX := [
	{"name": "01-clear-morning", "hour": 8, "minute": 0, "weather": "clear",
		"min_mean": 0.18, "max_dark": 25.0},
	{"name": "02-clear-noon", "hour": 12, "minute": 0, "weather": "clear",
		"min_mean": 0.22, "max_dark": 25.0},
	{"name": "03-sunset", "hour": 18, "minute": 30, "weather": "partly_cloudy",
		"min_mean": 0.14, "max_dark": 30.0},
	{"name": "04-clear-midnight", "hour": 0, "minute": 0, "weather": "clear",
		"min_mean": 0.03, "max_dark": 55.0},
	{"name": "05-fog-morning", "hour": 7, "minute": 0, "weather": "fog",
		"min_mean": 0.14, "max_dark": 30.0},
	{"name": "06-cloudy-afternoon", "hour": 15, "minute": 0, "weather": "cloudy",
		"min_mean": 0.18, "max_dark": 25.0},
	{"name": "07-light-rain-day", "hour": 11, "minute": 0, "weather": "light_rain",
		"min_mean": 0.15, "max_dark": 28.0},
	{"name": "08-heavy-rain-night", "hour": 22, "minute": 0, "weather": "heavy_rain",
		"min_mean": 0.03, "max_dark": 55.0},
	{"name": "09-storm-day", "hour": 14, "minute": 0, "weather": "storm",
		"min_mean": 0.12, "max_dark": 32.0},
	{"name": "10-storm-night", "hour": 23, "minute": 0, "weather": "storm",
		"min_mean": 0.03, "max_dark": 55.0},
]

var env: EnvironmentManager
var _camera: Camera3D
var _lines: Array[String] = []
var _failures := 0
var _captured := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[EnvCapture] SKIPPED - headless (dummy renderer cannot capture 3D)")
		get_tree().quit(0)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build_world()
	await get_tree().process_frame
	await get_tree().process_frame
	# The HUD (which includes the environment debug panel) is hidden for the
	# matrix: these frames exist to judge lighting, not to photograph their own
	# readout.  The printed summary carries the same numbers.
	_set_hud_visible(false)
	env = EnvironmentManager.instance_or_null()
	if env == null:
		printerr("[EnvCapture] no EnvironmentManager was created")
		get_tree().quit(1)
		return
	GameClock.paused = true

	for entry in MATRIX:
		await _capture(entry)
	await _capture_flash()
	await _capture_wetness()
	_set_hud_visible(true)
	_write_summary()

	print("[EnvCapture] captured %d frames, %d metric failure(s)" % [_captured, _failures])
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


# ----------------------------------------------------------------- fixture
func _build_world() -> void:
	var world := Node3D.new()
	world.name = "EnvCaptureWorld"
	add_child(world)

	# The manager is created before the fixture geometry so the environment
	# globals exist before any fixture shader compiles against them.
	var mgr := EnvironmentManager.new()
	world.add_child(mgr)

	# Ground: a wide slab so the street reads as pavement rather than void.
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(600.0, 1.0, 600.0)
	ground.mesh = ground_mesh
	ground.material_override = _material(Color(0.30, 0.29, 0.28))
	ground.position = Vector3(0.0, -0.5, 0.0)
	world.add_child(ground)

	# Street canyon: block silhouettes on both sides of a 16 m street, plus a
	# couple of taller corners so shadows and fog have something to bite on.
	var heights := [14.0, 18.0, 11.0, 22.0, 16.0, 12.0]
	var z := -60.0
	for h in heights:
		for side in [-1.0, 1.0]:
			var block := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(22.0, h, 26.0)
			block.mesh = mesh
			block.material_override = _material(
					Color(0.34, 0.31, 0.30) if side < 0.0 else Color(0.29, 0.28, 0.30))
			block.position = Vector3(side * 19.0, h * 0.5, z)
			world.add_child(block)
		z += 30.0

	# Two warm lamps: the reference for "night must remain playable".
	for lamp_z in [-24.0, 12.0]:
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.82, 0.55)
		lamp.light_energy = 2.4
		lamp.omni_range = 34.0
		lamp.position = Vector3(-9.0, 7.5, lamp_z)
		world.add_child(lamp)

	_camera = Camera3D.new()
	_camera.name = "EnvCaptureCamera"
	_camera.far = 900.0
	_camera.fov = 62.0
	world.add_child(_camera)
	_camera.position = Vector3(4.0, 6.0, 34.0)
	_camera.look_at(Vector3(0.0, 7.0, -40.0), Vector3.UP)
	_camera.current = true


## Fixture surfaces consume the published environment globals through the
## reference shader, which is what makes the wetness frames below meaningful:
## the same material must visibly change when only the global changes.
const WETNESS_SHADER := "res://world/environment/shaders/wetness_overlay.gdshader"


func _material(c: Color) -> Material:
	var shader: Shader = load(WETNESS_SHADER)
	if shader == null:
		printerr("[EnvCapture] %s failed to load; falling back to a plain material" % WETNESS_SHADER)
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = c
		fallback.roughness = 0.85
		return fallback
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo", c)
	mat.set_shader_parameter("base_roughness", 0.85)
	return mat


# ----------------------------------------------------------------- capturing
func _capture(entry: Dictionary) -> void:
	env.force_time(float(entry["hour"]), float(entry["minute"]))
	env.force_weather(String(entry["weather"]))
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	# Diagnostic: "rain is spawned" and "rain is visible" are different claims -
	# print what the emitters actually hold for this very frame.
	for n_cp: Node in get_tree().root.find_children("*", "CPUParticles3D", true, false):
		var cp := n_cp as CPUParticles3D
		print("[EnvCapture] %s CPUParticles3D amount=%d emitting=%s" % [entry["name"], cp.amount, cp.emitting])
		if cp.emitting:
			# Facts, not impressions: how far off vertical is the fall, and is the
			# streak mesh asked to follow it?
			var flat := Vector2(cp.gravity.x, cp.gravity.z).length()
			print("[EnvCapture] %s rain fall=%s slant=%.1fdeg align_y=%s" % [
				entry["name"], str(cp.gravity), rad_to_deg(atan2(flat, absf(cp.gravity.y))),
				str(cp.particle_flag_align_y)])
	for n_gp: Node in get_tree().root.find_children("*", "GPUParticles3D", true, false):
		var gp := n_gp as GPUParticles3D
		print("[EnvCapture] %s GPUParticles3D amount=%d emitting=%s" % [entry["name"], gp.amount, gp.emitting])
	print("[EnvCapture] %s state=%s" % [entry["name"], JSON.stringify(env.state())])
	var shot := "%s/%s.png" % [OUT_DIR, entry["name"]]
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(shot)
	if err != OK:
		printerr("[EnvCapture] could not write %s (%d)" % [shot, err])
		_failures += 1
		return
	_captured += 1
	_report(entry, _metrics(img), shot)


func _capture_flash() -> void:
	env.force_time(14.0, 0.0)
	env.force_weather("storm")
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var before := _metrics(get_viewport().get_texture().get_image())
	env.force_lightning()
	# A strike is a multi-stage flash, so a single frame can land in the dark
	# trough between stages: sample the next half second and keep the brightest.
	var after: Dictionary = before
	var peak: Image = get_viewport().get_texture().get_image()
	for i in FLASH_SAMPLE_FRAMES:
		await RenderingServer.frame_post_draw
		var frame := get_viewport().get_texture().get_image()
		var m := _metrics(frame)
		if float(m["mean"]) > float(after["mean"]):
			after = m
			peak = frame
	var shot := "%s/11-lightning-flash.png" % OUT_DIR
	peak.save_png(shot)
	_captured += 1
	var lifted := float(after["mean"]) - float(before["mean"])
	_ok("11-lightning-flash lifts the frame", lifted > 0.01,
		"mean %.3f -> %.3f (+%.3f)" % [before["mean"], after["mean"], lifted])
	_lines.append("| 11-lightning-flash | storm 14:00 | mean %.3f | p99 %.2f | flash +%.3f | %s |"
			% [after["mean"], after["p99"], lifted, shot])


## Shows/hides every HUD canvas layer, so the matrix photographs the world rather
## than its own debug readout.
func _set_hud_visible(want_visible: bool) -> void:
	for node in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(node as CanvasLayer).visible = want_visible


func _shot(file_name: String) -> Image:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png("%s/%s" % [OUT_DIR, file_name])
	if err != OK:
		printerr("[EnvCapture] could not write %s/%s (%d)" % [OUT_DIR, file_name, err])
		_failures += 1
	return img


## Criterion 15: the wetness global must reach real shading, not just the API.
## Identical geometry and lighting, only EnvironmentManager.set_wetness() differs.
func _capture_wetness() -> void:
	env.force_time(12.0, 0.0)
	env.force_weather("clear")
	env.set_wetness(0.0)
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var dry := _metrics(_shot("12-road-dry.png"))
	env.set_wetness(1.0)
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var wet := _metrics(_shot("13-road-wet.png"))
	_captured += 2
	# The wet street reflects the sky: the frame gets glossier and *brighter*
	# overall (the diffuse albedo still darkens - see p01 in the summary), so the
	# assertions track the two facts that are robust across framing.
	_ok("the wetness global reaches fixture shaders (the frame changes)",
		absf(float(wet["mean"]) - float(dry["mean"])) > 0.01,
		"mean %.3f -> %.3f" % [dry["mean"], wet["mean"]])
	# Gloss is a *relative* lift in a low-poly fixture (a few big flat faces), so
	# the floor is a measurable +0.02 p99 rather than a large absolute jump.
	_ok("wetness turns the surface glossy (highlight percentile up)",
		float(wet["p99"]) > float(dry["p99"]) + 0.02,
		"p99 %.3f -> %.3f" % [dry["p99"], wet["p99"]])
	print("[EnvCapture]  wetness      dry mean %.3f p99 %.3f  ->  wet mean %.3f p99 %.3f"
			% [dry["mean"], dry["p99"], wet["mean"], wet["p99"]])
	_lines.append("| 12/13-road dry -> wet | clear 12:00 | mean %.3f -> %.3f | p99 %.3f -> %.3f | global wetness reaches the shader | 12-road-dry.png, 13-road-wet.png |"
			% [dry["mean"], wet["mean"], dry["p99"], wet["p99"]])


func _report(entry: Dictionary, m: Dictionary, shot: String) -> void:
	var name := String(entry["name"])
	_ok("%s is not a black or blown frame" % name,
		float(m["mean"]) > 0.01 and float(m["bright_pct"]) < 12.0,
		"mean %.3f bright %.2f%%" % [m["mean"], m["bright_pct"]])
	_ok("%s stays readable (mean >= %.2f)" % [name, entry["min_mean"]],
		float(m["mean"]) >= float(entry["min_mean"]),
		"mean %.3f" % m["mean"])
	_ok("%s keeps detail in shadow (crushed < %.0f%%)" % [name, entry["max_dark"]],
		float(m["dark_pct"]) <= float(entry["max_dark"]),
		"crushed %.2f%%" % m["dark_pct"])
	print("[EnvCapture]  %-22s mean %.3f  p01 %.3f  p99 %.3f  black %.2f%%  blown %.2f%%  %s"
			% [name, m["mean"], m["p01"], m["p99"], m["dark_pct"], m["bright_pct"], shot])
	_lines.append("| %s | %d:%02d %s | mean %.3f | p01 %.3f | p99 %.3f | black %.2f%% | blown %.2f%% | %s |"
			% [name, int(entry["hour"]), int(entry["minute"]), entry["weather"],
				m["mean"], m["p01"], m["p99"], m["dark_pct"], m["bright_pct"], shot])


func _metrics(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var hist := PackedInt32Array()
	hist.resize(64)
	var total := 0
	var sum := 0.0
	var dark := 0
	var bright := 0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := img.get_pixel(x, y)
			var l := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			sum += l
			total += 1
			if l < 0.02:
				dark += 1
			if l > 0.98:
				bright += 1
			hist[int(clampf(l, 0.0, 0.999) * 64.0)] += 1
			x += SAMPLE_STEP
		y += SAMPLE_STEP
	var n := maxf(1.0, float(total))
	return {
		"mean": sum / n,
		"p01": _percentile(hist, total, 0.01),
		"p99": _percentile(hist, total, 0.99),
		"dark_pct": 100.0 * float(dark) / n,
		"bright_pct": 100.0 * float(bright) / n,
	}


func _percentile(hist: PackedInt32Array, total: int, frac: float) -> float:
	var want := int(float(total) * frac)
	var seen := 0
	for i in hist.size():
		seen += hist[i]
		if seen >= want:
			return float(i) / 64.0
	return 1.0


# ----------------------------------------------------------------- reporting
func _ok(label: String, passed: bool, detail := "") -> void:
	if passed:
		print("[EnvCapture]  ok    %s  (%s)" % [label, detail])
		return
	_failures += 1
	print("[EnvCapture]  FAIL  %s  (%s)" % [label, detail])


func _write_summary() -> void:
	var f := FileAccess.open("%s/summary.md" % OUT_DIR, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("# Environment visual matrix")
	f.store_line("")
	f.store_line("Captured by `godot --path . -- --envcapture` "
			+ "(`debug/environment_capture.gd`) on a street-canyon fixture.")
	f.store_line("")
	f.store_line("| frame | time / weather | mean luma | p01 | p99 | crushed black | blown | file |")
	f.store_line("|---|---|---|---|---|---|---|---|")
	for line in _lines:
		f.store_line(line)
	f.store_line("")
	f.store_line("Metric failures: %d" % _failures)
	f.close()
	print("[EnvCapture] wrote %s/summary.md" % OUT_DIR)
