extends Node
## GameSettings — the single authority for player-facing OPTIONS (graphics + sound).
##
## WHY AN AUTOLOAD: options must be reachable without a world (they are read
## before the first chunk streams), must survive every scene change, and must be
## the ONE place that knows how an option name maps onto the engine. UI
## (ui/pause_menu.gd) only reads and writes VALUES here; nothing else calls
## RenderingServer / AudioServer / DisplayServer for player preferences.
##
## GRAPHICS VOCABULARY = the engine's own knobs (viewport MSAA / FXAA / TAA, 3D
## scaling mode, shadow atlas, environment effects, camera far plane, max FPS,
## VSync). A future custom shader / occlusion culling / post-process / DLSS pass
## plugs in as NEW KEYS in this file, not as a new settings system:
##   * `UPSCALERS` already speaks the engine's SCALING_3D_MODE vocabulary and
##     carries a per-entry `mode`, so DLSS/TSR is one added line + one OptionButton
##     item in ui/pause_menu.gd (the UI is built from these tables, not hand-coded).
##   * every effect is re-applied by `apply_graphics()` from saved values, so
##     toggles need no new plumbing when scenes are rebuilt.
##
## PERSISTENCE: user://settings.json — plain JSON, human-editable, diffable.
## Unknown/missing keys fall back to the DEFAULTS below, so adding an option
## never invalidates an existing file.

signal changed(section: StringName, key: String, value: Variant)

const SETTINGS_PATH := "user://settings.json"

## Defaults reproduce the PRE-OPTIONS look exactly (4x MSAA as project.godot
## asks, shadows on at the project's 2048 atlas, glow + volumetric + distance fog
## as the day/night controller builds them, full render scale, no frame cap),
## so shipping this menu changes nothing until the player touches it.
const GRAPHICS_DEFAULTS := {
	"preset": "high",
	"msaa": 2,                  # index into MSAA_LABELS
	"fxaa": false,
	"taa": false,
	"upscaler": "bilinear",
	"render_scale": 1.0,        # 0.5 - 1.0, feeds Viewport.scaling_3d_scale
	"shadows": true,
	"shadow_quality": "high",
	"ssao": false,
	"glow": true,
	"volumetric_fog": true,
	"distance_fog": true,
	"view_distance": "default",
	"max_fps": 0,               # 0 = uncapped
	"vsync": true,
}

const SOUND_DEFAULTS := {
	"master": 0.8,
	"music": 0.7,
	"sfx": 0.9,
	"ambience": 0.7,
	"ui": 0.8,
	"mute": false,
}

## Buses created at startup so future audio has deterministic routing targets.
## The project ships no bus layout, so today everything would land on Master.
const BUSES := {
	"Master": "",
	"Music": "Master",
	"SFX": "Master",
	"Ambience": "Master",
	"UI": "Master",
}

## sound key -> AudioServer bus name
const BUS_SETTING := {
	"master": "Master",
	"music": "Music",
	"sfx": "SFX",
	"ambience": "Ambience",
	"ui": "UI",
}

const MSAA_LABELS := ["Off", "2x", "4x", "8x"]

const UPSCALERS := [
	{"id": "bilinear", "label": "Bilinear", "mode": Viewport.SCALING_3D_MODE_BILINEAR},
	{"id": "fsr1", "label": "FSR 1.0", "mode": Viewport.SCALING_3D_MODE_FSR},
	{"id": "fsr2", "label": "FSR 2.2", "mode": Viewport.SCALING_3D_MODE_FSR2},
]

## Dithered entries an OptionButton can show as disabled placeholders. They are
## NOT applied; they document the exact slot a future implementation fills.
const UPSCALERS_RESERVED := [
	{"id": "dlss", "label": "DLSS (reserved)"},
	{"id": "tsr", "label": "TSR (reserved)"},
]

## shadow_quality -> RenderingServer directional shadow atlas size.
## "high" == the project's rendering/lights_and_shadows/directional_shadow/size,
## so the default preset keeps the shipped shadow resolution.
const SHADOW_ATLAS := {"low": 512, "medium": 1024, "high": 2048, "ultra": 8192}

## view_distance -> multiplier on the camera's own far plane (captured when the
## camera is first resolved), so rigs that set their own `far` stay in charge.
const VIEW_DISTANCE_FACTOR := {"near": 0.35, "default": 1.0, "far": 3.0}

const PRESETS := [
	{"id": "low", "label": "Low"},
	{"id": "medium", "label": "Medium"},
	{"id": "high", "label": "High"},
	{"id": "ultra", "label": "Ultra"},
]

## Preset -> the graphics keys it writes. Anything absent keeps its default.
const PRESET_VALUES := {
	"low": {
		"msaa": 0, "fxaa": false, "taa": false, "upscaler": "bilinear",
		"render_scale": 0.7, "shadows": false, "shadow_quality": "low",
		"ssao": false, "glow": false, "volumetric_fog": false,
		"distance_fog": false, "view_distance": "near",
	},
	"medium": {
		"msaa": 1, "fxaa": true, "taa": false, "upscaler": "bilinear",
		"render_scale": 1.0, "shadows": true, "shadow_quality": "medium",
		"ssao": false, "glow": true, "volumetric_fog": false,
		"distance_fog": true, "view_distance": "default",
	},
	"high": {
		"msaa": 2, "fxaa": false, "taa": false, "upscaler": "bilinear",
		"render_scale": 1.0, "shadows": true, "shadow_quality": "high",
		"ssao": false, "glow": true, "volumetric_fog": true,
		"distance_fog": true, "view_distance": "default",
	},
	"ultra": {
		"msaa": 2, "fxaa": false, "taa": true, "upscaler": "bilinear",
		"render_scale": 1.0, "shadows": true, "shadow_quality": "ultra",
		"ssao": true, "glow": true, "volumetric_fog": true,
		"distance_fog": true, "view_distance": "far",
	},
}

var _graphics := {}
var _sound := {}
var _save_timer: Timer
var _camera: Camera3D
var _base_far := 4000.0   # Camera3D's own default; captured per resolved camera
var _sun: DirectionalLight3D
var _env: Environment


func _ready() -> void:
	_ensure_buses()
	reset_defaults()
	load_from_disk()
	# Persist lazily: sliders fire value_changed continuously while dragging.
	_save_timer = Timer.new()
	_save_timer.name = "SaveTimer"
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.5
	# ALWAYS: the options menu is used while get_tree().paused, and a paused
	# timer would never fire, silently dropping the player's settings.
	_save_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_save_timer.timeout.connect(save_to_disk)
	add_child(_save_timer)
	# Apply immediately: MSAA / scaling / FPS cap / VSync are viewport- and
	# engine-level and must be in force before the first frame. The scene-level
	# targets (camera far plane, sun shadows, environment effects) do not exist
	# yet and resolve to null here — `refresh()` re-applies them once a world is
	# actually running.
	apply_all()
	var tree := get_tree()
	if tree != null:
		tree.node_added.connect(_on_node_added)


## The world scene — and with it the camera, sun and WorldEnvironment — is built
## long after this autoload starts, and is rebuilt for every new session or
## save-load. Re-applying when those targets appear is what makes a SAVED
## preference (shadows off, glow off, shorter view distance) survive into a fresh
## world without the player opening the options menu first.
func _on_node_added(node: Node) -> void:
	if node is WorldEnvironment or node is Camera3D or node is DirectionalLight3D:
		call_deferred("refresh")


# ---------- values ----------

func graphics(key: String) -> Variant:
	if _graphics.has(key):
		return _graphics[key]
	return GRAPHICS_DEFAULTS.get(key)


func sound(key: String) -> Variant:
	if _sound.has(key):
		return _sound[key]
	return SOUND_DEFAULTS.get(key)


func set_graphics(key: String, value: Variant) -> void:
	if not GRAPHICS_DEFAULTS.has(key):
		push_warning("[GameSettings] unknown graphics key '%s' ignored" % key)
		return
	_graphics[key] = value
	apply_graphics()
	_schedule_save()
	changed.emit(&"graphics", key, value)


func set_sound(key: String, value: Variant) -> void:
	if not SOUND_DEFAULTS.has(key):
		push_warning("[GameSettings] unknown sound key '%s' ignored" % key)
		return
	_sound[key] = value
	apply_sound()
	_schedule_save()
	changed.emit(&"sound", key, value)


func reset_defaults() -> void:
	_graphics = GRAPHICS_DEFAULTS.duplicate(true)
	_sound = SOUND_DEFAULTS.duplicate(true)


## Full state as a plain Dictionary — for BEFORE/AFTER capture harnesses and for
## anything that temporarily forces a value (see `restore()`). Never mutate the
## returned copy: write through `set_graphics()` / `set_sound()`.
func snapshot() -> Dictionary:
	return {"graphics": _graphics.duplicate(true), "sound": _sound.duplicate(true)}


## Put a `snapshot()` back, applying and persisting it. A tool that forces a
## setting to photograph the difference MUST end with this (or `reset_defaults`)
## so it cannot leave its own test values in the player's settings.json.
func restore(data: Dictionary, persist := true) -> void:
	_coerce_into(data.get("graphics", {}), GRAPHICS_DEFAULTS, _graphics)
	_coerce_into(data.get("sound", {}), SOUND_DEFAULTS, _sound)
	apply_all()
	if persist:
		save_to_disk()


func apply_preset(id: String) -> void:
	if not PRESET_VALUES.has(id):
		push_warning("[GameSettings] unknown preset '%s' ignored" % id)
		return
	for key: String in PRESET_VALUES[id]:
		_graphics[key] = PRESET_VALUES[id][key]
	_graphics["preset"] = id
	apply_graphics()
	_schedule_save()
	changed.emit(&"graphics", "preset", id)


# ---------- apply ----------

func apply_all() -> void:
	apply_sound()
	apply_graphics()


func apply_graphics() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.msaa_3d = _msaa_mode(int(graphics("msaa")))
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(graphics("fxaa")) \
				else Viewport.SCREEN_SPACE_AA_DISABLED
		vp.scaling_3d_scale = clampf(float(graphics("render_scale")), 0.25, 1.0)
		vp.scaling_3d_mode = _upscaler_mode(str(graphics("upscaler")))
		# TAA and FSR 2 both own the temporal history buffer; FSR 2.2 wins when
		# selected, so the pairing can never produce a broken frame.
		vp.use_taa = bool(graphics("taa")) and str(graphics("upscaler")) != "fsr2"
	Engine.max_fps = maxi(0, int(graphics("max_fps")))
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if bool(graphics("vsync"))
				else DisplayServer.VSYNC_DISABLED)
	_apply_shadows()
	_apply_environment()
	_apply_view_distance()


func apply_sound() -> void:
	var muted := bool(sound("mute"))
	for key: String in BUS_SETTING:
		var idx := AudioServer.get_bus_index(BUS_SETTING[key])
		if idx < 0:
			continue
		var value := clampf(float(sound(key)), 0.0, 1.0)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(value, 0.0001)))
	# Muting the MASTER bus alone is the correct "mute everything" and keeps the
	# per-bus values intact for when the player unmutes.
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, muted)


func _apply_shadows() -> void:
	var sun := resolve_sun()
	var on := bool(graphics("shadows"))
	if sun != null:
		sun.shadow_enabled = on
	if on:
		var atlas := int(SHADOW_ATLAS.get(str(graphics("shadow_quality")),
				SHADOW_ATLAS["high"]))
		# is_16bits=false matches the project's own shadow setting, so the
		# default preset is a true no-op on the shipped look.
		RenderingServer.directional_shadow_atlas_set_size(atlas, false)


func _apply_environment() -> void:
	var env := resolve_environment()
	if env == null:
		return
	env.glow_enabled = bool(graphics("glow"))
	env.volumetric_fog_enabled = bool(graphics("volumetric_fog"))
	env.fog_enabled = bool(graphics("distance_fog"))
	env.ssao_enabled = bool(graphics("ssao"))


func _apply_view_distance() -> void:
	var cam := resolve_camera()
	if cam == null:
		return
	var factor := float(VIEW_DISTANCE_FACTOR.get(str(graphics("view_distance")), 1.0))
	cam.far = _base_far * factor


# ---------- live scene targets ----------
## Resolved lazily and re-checked on every apply: the world scene (and therefore
## the camera, sun and environment) is built long AFTER this autoload's _ready,
## and can be rebuilt by a save-load, so caching bindings across frames would
## silently skip half the settings.

func resolve_camera() -> Camera3D:
	if _camera != null and is_instance_valid(_camera) and _camera.is_inside_tree():
		return _camera
	_camera = null
	var vp := get_viewport()
	if vp != null:
		_camera = vp.get_camera_3d()
	if _camera == null:
		var root := get_tree().root if get_tree() != null else null
		if root != null:
			for node: Node in root.find_children("*", "Camera3D", true, false):
				if (node as Camera3D).current:
					_camera = node as Camera3D
					break
	if _camera != null:
		_base_far = _camera.far
	return _camera


func resolve_sun() -> DirectionalLight3D:
	if _sun != null and is_instance_valid(_sun) and _sun.is_inside_tree():
		return _sun
	_sun = null
	var root := get_tree().root if get_tree() != null else null
	if root != null:
		var found := root.find_children("*", "DirectionalLight3D", true, false)
		if not found.is_empty():
			_sun = found[0] as DirectionalLight3D
	return _sun


func resolve_environment() -> Environment:
	_env = null
	var node := resolve_environment_node()
	if node != null:
		_env = node.environment
	return _env


func resolve_environment_node() -> WorldEnvironment:
	var root := get_tree().root if get_tree() != null else null
	if root == null:
		return null
	var found := root.find_children("*", "WorldEnvironment", true, false)
	if found.is_empty():
		return null
	return found[0] as WorldEnvironment


## Re-resolve the world targets and re-apply. Called when the pause menu opens:
## that is the one moment the player's live camera/environment definitely exist.
func refresh() -> void:
	_camera = null
	_sun = null
	_env = null
	apply_graphics()


# ---------- persistence ----------

func _schedule_save() -> void:
	if _save_timer != null and _save_timer.is_inside_tree():
		_save_timer.start()


func save_to_disk() -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[GameSettings] cannot write %s (error %d)" % [
				SETTINGS_PATH, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify({
		"version": 1,
		"graphics": _graphics,
		"sound": _sound,
	}, "\t"))
	file.close()


func load_from_disk() -> bool:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return false
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[GameSettings] %s is not a JSON object; using defaults"
				% SETTINGS_PATH)
		return false
	var data: Dictionary = parsed
	_coerce_into(data.get("graphics", {}), GRAPHICS_DEFAULTS, _graphics)
	_coerce_into(data.get("sound", {}), SOUND_DEFAULTS, _sound)
	return true


## Copy only KNOWN keys, converting each to its default's type. JSON gives every
## number back as a float, and an unknown key from a future/older build must
## never reach the apply functions.
func _coerce_into(source: Variant, defaults: Dictionary, target: Dictionary) -> void:
	if typeof(source) != TYPE_DICTIONARY:
		return
	var data: Dictionary = source
	for key: String in defaults:
		if not data.has(key):
			continue
		var fallback: Variant = defaults[key]
		var value: Variant = data[key]
		match typeof(fallback):
			TYPE_BOOL:
				target[key] = bool(value)
			TYPE_INT:
				target[key] = int(value)
			TYPE_FLOAT:
				target[key] = float(value)
			_:
				target[key] = str(value)


# ---------- helpers ----------

func _ensure_buses() -> void:
	for bus_name: String in BUSES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			AudioServer.add_bus()
			idx = AudioServer.get_bus_count() - 1
			AudioServer.set_bus_name(idx, bus_name)
		var send: String = BUSES[bus_name]
		if send != "":
			AudioServer.set_bus_send(idx, send)


func _msaa_mode(index: int) -> Viewport.MSAA:
	match clampi(index, 0, 3):
		0:
			return Viewport.MSAA_DISABLED
		1:
			return Viewport.MSAA_2X
		2:
			return Viewport.MSAA_4X
		_:
			return Viewport.MSAA_8X


func _upscaler_mode(id: String) -> Viewport.Scaling3DMode:
	for entry: Dictionary in UPSCALERS:
		if str(entry["id"]) == id:
			return entry["mode"]
	return Viewport.SCALING_3D_MODE_BILINEAR
