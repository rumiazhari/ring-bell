extends Node
## --pausemenutest : headless contract test for the ESC pause menu (GameSettings +
## ui/pause_menu.gd).
##
## Runs INSIDE the real main scene, so the world, player, HUD, camera, sun and
## WorldEnvironment are the shipped ones. It asserts the observable contract, not
## widget state:
##   * ESC is bound to a `pause_menu` action and a real ESC event opens the menu
##   * the menu offers Resume / Options (Graphics + Sound tabs) / Exit
##   * opening freezes the tree; the menu itself keeps running while paused
##   * every Graphics and Sound row MOVES THE ENGINE — viewport MSAA/FXAA/TAA,
##     3D scaling mode + scale, Engine.max_fps, sun shadows, WorldEnvironment
##     effects, camera far plane, audio bus volumes
##   * defaults reproduce the pre-options look (project MSAA + shadow atlas)
##   * settings round-trip through user://settings.json with correct types
##   * Exit asks for confirmation instead of quitting instantly
##
## One "[PauseMenuTest] FAIL ..." line per broken check; the exit code is non-zero
## when anything fails, so tools/run_suite.py reports a real failure.

const Settings := preload("res://core/autoload/game_settings.gd")
const SETTINGS_PATH := "user://settings.json"

var _menu: Node
var _settings: Node
var _ticker: Ticker
var _checks := 0
var _failures := 0


## Plain pausable node: proves that opening the menu really stops world processing.
class Ticker:
	extends Node

	var ticks := 0

	func _process(_delta: float) -> void:
		ticks += 1


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await _run()


func _run() -> void:
	_menu = get_node_or_null("/root/PauseMenu")
	_settings = get_node_or_null("/root/GameSettings")
	_check(_menu != null, "autoload", "PauseMenu autoload exists")
	_check(_settings != null, "autoload", "GameSettings autoload exists")
	if _menu == null or _settings == null:
		_finish()
		return

	_ticker = Ticker.new()
	_ticker.name = "PauseMenuTicker"
	add_child(_ticker)

	# Deterministic starting point.
	_settings.reset_defaults()
	_settings.apply_all()
	await get_tree().process_frame

	_test_defaults()
	_test_input_binding()
	_test_buses()
	_test_graphics_wiring()
	_test_sound_wiring()
	await _test_menu_structure()
	await _test_esc_path()
	await _test_pause_effect()
	_test_exit_page()
	_test_snapshot_restore()
	_test_persistence()

	_finish()


# ---------- checks ----------

func _test_defaults() -> void:
	var project_msaa := int(ProjectSettings.get_setting(
			"rendering/anti_aliasing/quality/msaa_3d", -1))
	_check(int(_settings.graphics("msaa")) == project_msaa, "defaults",
			"default MSAA index %d matches project setting %d"
			% [int(_settings.graphics("msaa")), project_msaa])
	var vp := get_viewport()
	_check(vp.msaa_3d == Viewport.MSAA_4X, "defaults",
			"default applies 4x MSAA to the live viewport")
	var atlas_high := int(Settings.SHADOW_ATLAS["high"])
	var project_atlas := int(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/size", -1))
	_check(atlas_high == project_atlas, "defaults",
			"'high' shadow quality (%d) equals the project atlas (%d) — the shipped look is a no-op"
			% [atlas_high, project_atlas])
	var env := _settings.resolve_environment() as Environment
	_check(env != null and env.glow_enabled and env.volumetric_fog_enabled
			and env.fog_enabled, "defaults",
			"defaults keep glow + volumetric + distance fog on, as the world builds them")
	_check(Engine.max_fps == 0, "defaults", "default frame cap is unlimited")


func _test_input_binding() -> void:
	_check(InputMap.has_action(&"pause_menu"), "input",
			"pause_menu action is registered by InputSetup")
	var escape := false
	for event: InputEvent in InputMap.action_get_events(&"pause_menu"):
		var key := event as InputEventKey
		if key != null and key.physical_keycode == KEY_ESCAPE:
			escape = true
	_check(escape, "input", "pause_menu is bound to ESC")


func _test_buses() -> void:
	for bus: String in ["Master", "Music", "SFX", "Ambience", "UI"]:
		_check(AudioServer.get_bus_index(bus) >= 0, "audio",
				"audio bus '%s' exists" % bus)
	var music := AudioServer.get_bus_index("Music")
	if music >= 0:
		_check(AudioServer.get_bus_send(music) == "Master", "audio",
				"Music bus routes into Master")


func _test_graphics_wiring() -> void:
	var vp := get_viewport()

	_settings.set_graphics("msaa", 1)
	_check(vp.msaa_3d == Viewport.MSAA_2X, "graphics",
			"MSAA row drives viewport.msaa_3d")

	_settings.set_graphics("fxaa", true)
	_check(vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA, "graphics",
			"FXAA row drives viewport.screen_space_aa")

	_settings.set_graphics("taa", true)
	_check(vp.use_taa, "graphics", "TAA row drives viewport.use_taa")

	_settings.set_graphics("upscaler", "fsr2")
	_check(vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2, "graphics",
			"upscaler row drives viewport.scaling_3d_mode")
	_check(not vp.use_taa, "graphics",
			"FSR 2.2 beats TAA (both own the temporal history — no broken frames)")

	_settings.set_graphics("upscaler", "bilinear")
	_check(vp.use_taa, "graphics", "TAA comes back once FSR 2.2 is deselected")

	_settings.set_graphics("render_scale", 0.7)
	_check(absf(vp.scaling_3d_scale - 0.7) < 0.001, "graphics",
			"render scale row drives viewport.scaling_3d_scale")

	_settings.set_graphics("max_fps", 60)
	_check(Engine.max_fps == 60, "graphics", "frame cap row drives Engine.max_fps")

	var sun := _settings.resolve_sun() as DirectionalLight3D
	var env := _settings.resolve_environment() as Environment
	var camera := _settings.resolve_camera() as Camera3D
	_check(sun != null and env != null and camera != null, "graphics",
			"live sun / environment / camera are resolved from the running scene")

	if sun != null:
		_settings.set_graphics("shadows", false)
		_check(not sun.shadow_enabled, "graphics",
				"shadows row drives the sun's shadow_enabled")
		_settings.set_graphics("shadow_quality", "ultra")
		_check(sun.shadow_enabled == false, "graphics",
				"shadow quality is a no-op while shadows are off")
		_settings.set_graphics("shadows", true)

	if env != null:
		_settings.set_graphics("glow", false)
		_check(not env.glow_enabled, "graphics",
				"glow row drives Environment.glow_enabled")
		_settings.set_graphics("volumetric_fog", false)
		_check(not env.volumetric_fog_enabled, "graphics",
				"volumetric fog row drives Environment.volumetric_fog_enabled")
		_settings.set_graphics("distance_fog", false)
		_check(not env.fog_enabled, "graphics",
				"distance fog row drives Environment.fog_enabled")
		_settings.set_graphics("ssao", true)
		_check(env.ssao_enabled, "graphics",
				"SSAO row drives Environment.ssao_enabled")

	if camera != null:
		var base := camera.far
		_settings.set_graphics("view_distance", "near")
		var near := camera.far
		_settings.set_graphics("view_distance", "far")
		var far := camera.far
		_check(near < base and far > base, "graphics",
				"view distance row moves the camera far plane (%.0f → %.0f → %.0f)"
				% [base, near, far])

	_settings.reset_defaults()
	_settings.apply_all()


func _test_sound_wiring() -> void:
	_settings.set_sound("music", 0.5)
	var music := AudioServer.get_bus_index("Music")
	if music >= 0:
		_check(absf(AudioServer.get_bus_volume_db(music) - linear_to_db(0.5)) < 0.01,
				"audio", "music slider drives the Music bus volume")

	_settings.set_sound("mute", true)
	var master := AudioServer.get_bus_index("Master")
	_check(AudioServer.is_bus_mute(master), "audio",
			"mute row mutes the master bus")

	_settings.set_sound("mute", false)
	_check(not AudioServer.is_bus_mute(master), "audio",
			"un-mute restores the mix")

	_settings.reset_defaults()
	_settings.apply_sound()


func _test_menu_structure() -> void:
	_check(_menu.find_child("ResumeButton", true, false) != null
			and _menu.find_child("OptionsButton", true, false) != null
			and _menu.find_child("ExitButton", true, false) != null, "ui",
			"menu shows Resume, Options and Exit")

	var tabs := _menu.find_child("Tabs", true, false) as TabContainer
	_check(tabs != null and tabs.get_tab_count() == 2, "ui",
			"options has exactly two tabs")
	if tabs != null:
		_check(tabs.get_tab_title(0) == "Graphics"
				and tabs.get_tab_title(1) == "Sound", "ui",
				"tabs are titled Graphics and Sound (got '%s', '%s')"
				% [tabs.get_tab_title(0), tabs.get_tab_title(1)])

	var graphics_rows := _menu.find_child("GraphicsRows", true, false)
	var sound_rows := _menu.find_child("SoundRows", true, false)
	# A null widget here is not cosmetic: _sync_from_settings stops at the first
	# one, leaving every row BELOW it showing stale values.
	for entry: Dictionary in [{"n": "PresetOption"}, {"n": "MsaaOption"},
			{"n": "UpscalerOption"}, {"n": "ShadowQualityOption"},
			{"n": "ViewDistanceOption"}, {"n": "MaxFpsOption"},
			{"n": "RenderScaleSlider"}, {"n": "MuteCheck"}]:
		_check(_menu.find_child(str(entry["n"]), true, false) != null, "ui",
				"options row '%s' exists and can be synced" % str(entry["n"]))
	for key: String in ["fxaa", "taa", "shadows", "ssao", "glow", "volumetric_fog",
			"distance_fog", "vsync"]:
		_check(_menu.find_child("Check_%s" % key, true, false) != null, "ui",
				"graphics check row '%s' exists" % key)
	for key: String in ["master", "music", "sfx", "ambience", "ui"]:
		_check(_menu.find_child("Volume_%s" % key, true, false) != null, "ui",
				"sound slider row '%s' exists" % key)
	_check(graphics_rows != null and graphics_rows.get_child_count() >= 18, "ui",
			"graphics tab carries %d rows"
			% (graphics_rows.get_child_count() if graphics_rows else -1))
	_check(sound_rows != null and sound_rows.get_child_count() >= 7, "ui",
			"sound tab carries %d rows"
			% (sound_rows.get_child_count() if sound_rows else -1))

	var upscaler := _menu.find_child("UpscalerOption", true, false) as OptionButton
	_check(upscaler != null
			and upscaler.item_count == Settings.UPSCALERS.size()
					+ Settings.UPSCALERS_RESERVED.size(), "ui",
			"upscaler lists %d live + %d reserved entries"
			% [Settings.UPSCALERS.size(), Settings.UPSCALERS_RESERVED.size()])
	if upscaler != null:
		_check(upscaler.is_item_disabled(Settings.UPSCALERS.size()), "ui",
				"reserved upscalers (DLSS/TSR) are present but disabled")

	# Options is reachable and exclusive.
	var options_button := _menu.find_child("OptionsButton", true, false) as Button
	var options_page := _menu.find_child("OptionsPage", true, false) as Control
	var main_page := _menu.find_child("MainPage", true, false) as Control
	if options_button != null and options_page != null and main_page != null:
		options_button.pressed.emit()
		_check(options_page.visible and not main_page.visible, "ui",
				"Options opens the Graphics/Sound page and hides the main page")

	var back := _menu.find_child("BackButton", true, false) as Button
	if back != null:
		back.pressed.emit()
		_check(main_page != null and main_page.visible, "ui", "Back returns to the main page")

	# Checkboxes must REPORT their state: the first capture showed every
	# toggled-off row still labelled "On" while the engine value was false.
	_menu.open()
	await get_tree().process_frame
	var fxaa_check := _menu.find_child("Check_fxaa", true, false) as CheckButton
	_check(fxaa_check != null and fxaa_check.text == "Off", "ui",
			"checkbox label follows the live value (got '%s')"
			% (fxaa_check.text if fxaa_check != null else "missing"))
	_settings.set_graphics("fxaa", true)
	_menu.close()
	await get_tree().process_frame
	_menu.open()
	await get_tree().process_frame
	_check(fxaa_check != null and fxaa_check.text == "On" and fxaa_check.button_pressed,
			"ui", "reopening the menu syncs widgets to the stored value")
	_menu.close()
	_settings.reset_defaults()
	_settings.apply_all()
	_settings.save_to_disk()


func _test_esc_path() -> void:
	if _menu.is_open():
		_menu.close()
	await get_tree().process_frame

	_check(not _menu.is_open(), "esc", "menu starts closed")
	_check(_menu.session_available(), "esc",
			"session_available() is true with a live world and player")
	_press_escape()
	await get_tree().process_frame
	_check(_menu.is_open(), "esc", "a real ESC event opens the menu")
	_press_escape()
	await get_tree().process_frame
	_check(not _menu.is_open(), "esc", "ESC again closes it")


func _test_pause_effect() -> void:
	_menu.open()
	await get_tree().process_frame
	_check(_menu.is_open(), "pause", "menu reports itself open")
	_check(_menu.process_mode == Node.PROCESS_MODE_ALWAYS, "pause",
			"menu processes while the tree is paused")
	_check(get_tree().paused, "pause", "opening the menu pauses the SceneTree")

	var before := _ticker.ticks
	await get_tree().create_timer(0.25, true, false, true).timeout
	_check(_ticker.ticks == before, "pause",
			"world nodes stop processing while paused (ticks stayed at %d)" % before)

	# Settings still apply while paused (the whole point of the menu).
	_settings.set_graphics("max_fps", 90)
	_check(Engine.max_fps == 90, "pause",
			"a setting changed while paused still reaches the engine")

	_menu.close()
	await get_tree().create_timer(0.25, true, false, true).timeout
	_check(not get_tree().paused, "pause", "closing the menu unpauses the tree")
	_check(_ticker.ticks > before, "pause",
			"world nodes resume after closing (ticks %d → %d)" % [before, _ticker.ticks])
	_settings.reset_defaults()
	_settings.apply_all()


func _test_exit_page() -> void:
	var exit_button := _menu.find_child("ExitButton", true, false) as Button
	var exit_page := _menu.find_child("ExitPage", true, false) as Control
	if exit_button == null or exit_page == null:
		_check(false, "exit", "exit page exists")
		return
	exit_button.pressed.emit()
	_check(exit_page.visible, "exit",
			"Exit shows a confirmation instead of quitting immediately")
	var quit_button := _menu.find_child("QuitConfirmButton", true, false) as Button
	_check(quit_button != null and quit_button.pressed.get_connections().size() > 0,
			"exit", "the confirm button is wired to the quit handler")
	var cancel := _menu.find_child("QuitCancelButton", true, false) as Button
	if cancel != null:
		cancel.pressed.emit()
		var main_page := _menu.find_child("MainPage", true, false) as Control
		_check(main_page != null and main_page.visible, "exit",
				"Cancel returns to the main page")


## The windowed capture harness forces values (shadows off/on) to photograph the
## difference. `snapshot()`/`restore()` is what keeps that from rewriting the
## player's own settings file — assert the contract, not just the happy path.
func _test_snapshot_restore() -> void:
	_settings.reset_defaults()
	_settings.apply_all()
	var saved: Dictionary = _settings.snapshot()
	_check(int(saved["graphics"]["max_fps"]) == 0 and bool(saved["graphics"]["shadows"]),
			"snapshot", "snapshot() copies the current values")

	_settings.set_graphics("shadows", false)
	_settings.set_graphics("max_fps", 30)
	_settings.set_graphics("view_distance", "near")
	_settings.restore(saved, false)
	_check(bool(_settings.graphics("shadows")), "snapshot", "restore() puts forced values back")
	_check(int(_settings.graphics("max_fps")) == 0, "snapshot", "restore() reverts the frame cap too")
	_check(str(_settings.graphics("view_distance")) == "default", "snapshot",
			"restore() reverts string settings")
	var cam: Camera3D = _settings.resolve_camera()
	if cam != null:
		_check(cam.far > 3000.0, "snapshot",
				"restore() re-applies to the live camera (far plane back to %.0f)" % cam.far)

	# snapshot() must hand back a COPY: mutating it cannot move the live value.
	var probe: Dictionary = _settings.snapshot()
	probe["graphics"]["max_fps"] = 999
	_check(int(_settings.graphics("max_fps")) == 0, "snapshot",
			"snapshot() is a copy, not a live reference")
	_settings.reset_defaults()
	_settings.apply_all()


func _test_persistence() -> void:
	var had_file := FileAccess.file_exists(SETTINGS_PATH)
	var backup := FileAccess.get_file_as_string(SETTINGS_PATH) if had_file else ""

	_settings.set_graphics("max_fps", 90)
	_settings.set_sound("music", 0.33)
	_settings.save_to_disk()
	_check(FileAccess.file_exists(SETTINGS_PATH), "persist",
			"settings.json is written to user://")

	_settings.set_graphics("max_fps", 0)
	_check(int(_settings.graphics("max_fps")) == 0, "persist",
			"in-memory value changes independently of the file")
	_check(_settings.load_from_disk(), "persist", "settings.json reloads")
	_check(int(_settings.graphics("max_fps")) == 90, "persist",
			"frame cap survives the round-trip as an int (JSON gives floats back)")
	_check(absf(float(_settings.sound("music")) - 0.33) < 0.001, "persist",
			"music volume survives the round-trip")
	_check(typeof(_settings.graphics("max_fps")) == TYPE_INT
			and typeof(_settings.graphics("vsync")) == TYPE_BOOL, "persist",
			"loaded values keep their declared types")

	# Never delete a player's file: restore whatever was there before.
	if had_file:
		var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
		if file != null:
			file.store_string(backup)
			file.close()
		_settings.load_from_disk()
	else:
		_settings.reset_defaults()
		_settings.save_to_disk()
	_settings.apply_all()


# ---------- helpers ----------

func _press_escape() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	get_viewport().push_input(event)
	var release := InputEventKey.new()
	release.physical_keycode = KEY_ESCAPE
	release.pressed = false
	get_viewport().push_input(release)


func _check(condition: bool, tag: String, message: String) -> void:
	_checks += 1
	if condition:
		print("[PauseMenuTest] PASS %-9s %s" % [tag, message])
	else:
		_failures += 1
		print("[PauseMenuTest] FAIL %-9s %s" % [tag, message])


func _finish() -> void:
	if _menu != null and _menu.is_open():
		_menu.close()
	if _ticker != null and _ticker.is_inside_tree():
		_ticker.queue_free()
	print("[PauseMenuTest] %d check(s), %d failure(s)" % [_checks, _failures])
	# tools/run_suite.py keys success off this exact phrasing.
	print("[PauseMenuTest] finished with %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
