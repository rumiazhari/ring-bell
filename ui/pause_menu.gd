extends CanvasLayer
## PauseMenu — the in-game ESC overlay: Resume / Options (Graphics, Sound) / Exit.
##
## WHY AN AUTOLOAD CanvasLayer: the menu must exist in every session without the
## world scene owning its lifecycle, and it must keep working while the tree is
## paused. `process_mode = ALWAYS` is what makes a pause menu able to UN-pause the
## game — with the default (INHERIT) a paused tree would freeze the very menu
## that is supposed to close it.
##
## LAYER: 120 sits above the HUD (40) and the spawn menu (110), so pressing ESC
## with any in-game UI open still yields a usable menu.
##
## This file is LAYOUT + WIRING ONLY. Every control reads and writes a value in
## core/autoload/game_settings.gd, which owns all engine calls, persistence and
## the option tables. Both tabs are BUILT FROM those tables, so a new graphics
## knob is one entry in GameSettings — not a hand-written widget here.

signal menu_opened
signal menu_closed

const Settings := preload("res://core/autoload/game_settings.gd")

const LABEL_WIDTH := 260
const TAB_HEIGHT := 424
const PANEL_WIDTH := 760

const SOUND_ROWS := [
	{"key": "master", "label": "Master volume"},
	{"key": "music", "label": "Music"},
	{"key": "sfx", "label": "Effects (SFX)"},
	{"key": "ambience", "label": "Ambience"},
	{"key": "ui", "label": "Interface (UI)"},
]

## graphics key -> row label, in display order. CheckButton rows only.
const GRAPHICS_CHECKS := [
	{"key": "fxaa", "label": "FXAA", "hint": "Cheap full-screen anti-aliasing"},
	{"key": "taa", "label": "TAA", "hint": "Temporal AA — ignored while FSR 2.2 is selected"},
	{"key": "shadows", "label": "Dynamic shadows", "hint": "Sun shadows from buildings and actors"},
	{"key": "ssao", "label": "Ambient occlusion (SSAO)", "hint": "Adds contact shading; costs frame time"},
	{"key": "glow", "label": "Post-processing: glow", "hint": "Bloom around lit windows and the sun"},
	{"key": "volumetric_fog", "label": "Post-processing: volumetric fog", "hint": "Sun shafts / light mist"},
	{"key": "distance_fog", "label": "Post-processing: distance fog", "hint": "Atmospheric depth towards the horizon"},
	{"key": "vsync", "label": "V-Sync", "hint": "Match the display refresh rate"},
]

const MAX_FPS_CHOICES := [
	{"label": "30", "value": 30},
	{"label": "60", "value": 60},
	{"label": "90", "value": 90},
	{"label": "120", "value": 120},
	{"label": "144", "value": 144},
	{"label": "Unlimited", "value": 0},
]

const SHADOW_QUALITY_IDS := ["low", "medium", "high", "ultra"]
const SHADOW_QUALITY_LABELS := ["Low (512)", "Medium (1024)", "High (2048)", "Ultra (8192)"]
const VIEW_DISTANCE_IDS := ["near", "default", "far"]
const VIEW_DISTANCE_LABELS := ["Near", "Default", "Far"]
const CUSTOM_PRESET := "custom"

var _root: Control
var _dim: ColorRect
var _panel: PanelContainer
var _page_main: VBoxContainer
var _page_options: VBoxContainer
var _page_exit: VBoxContainer
var _tabs: TabContainer
var _graphics_tab: ScrollContainer
var _sound_tab: ScrollContainer
var _resume_button: Button
var _preset_option: OptionButton
var _msaa_option: OptionButton
var _upscaler_option: OptionButton
var _shadow_quality_option: OptionButton
var _view_distance_option: OptionButton
var _max_fps_option: OptionButton
var _render_scale_slider: HSlider
var _render_scale_value: Label
var _checks := {}
var _sound_sliders := {}
var _sound_values := {}
var _mute_check: CheckButton
var _exit_confirm: VBoxContainer
var _quit_button: Button
var _did_pause := false
var _syncing := false


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


# ================= lifecycle =================

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause_menu"):
		return
	# ESC backs out one screen first, exactly like every other game menu.
	if is_open() and _page_options.visible:
		_show_main_page()
	else:
		toggle()
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func is_open() -> bool:
	return visible


func toggle() -> void:
	if is_open():
		close()
	elif session_available():
		open()


## True only during an actual game session: the world scene is up, its populating
## UI is gone, and a player actor exists. ESC in the main menu / while a spawn is
## still streaming must not pause anything.
func session_available() -> bool:
	if not is_inside_tree() or get_tree() == null:
		return false
	var root := get_tree().root
	if root == null:
		return false
	if root.find_child("MainMenu", true, false) != null:
		return false
	if root.find_child("LoadingScreen", true, false) != null:
		return false
	return ActorRegistry.get_actor(&"player") != null


func open() -> void:
	if is_open():
		return
	var settings := _settings()
	if settings != null:
		# Bind the LIVE camera / sun / environment before showing values, so the
		# controls reflect (and immediately control) the running world.
		settings.refresh()
	_sync_from_settings()
	_show_main_page()
	visible = true
	_did_pause = not get_tree().paused
	get_tree().paused = true
	if _resume_button != null:
		_resume_button.grab_focus()
	menu_opened.emit()


func close() -> void:
	if not is_open():
		return
	visible = false
	if _did_pause and get_tree() != null:
		get_tree().paused = false
	_did_pause = false
	_show_main_page()
	var settings := _settings()
	if settings != null:
		settings.save_to_disk()
	menu_closed.emit()


func _settings() -> Node:
	return get_node_or_null("/root/GameSettings")


# ================= build =================

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.color = Color(0.02, 0.03, 0.05, 0.74)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_dim)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 30)
	column.add_child(title)

	var hint := Label.new()
	hint.name = "HintLabel"
	hint.text = "ESC resumes · the world is frozen while this menu is open"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	column.add_child(hint)

	column.add_child(_separator())

	_page_main = _build_main_page()
	column.add_child(_page_main)
	_page_options = _build_options_page()
	column.add_child(_page_options)
	_page_exit = _build_exit_page()
	column.add_child(_page_exit)


func _build_main_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = "MainPage"
	page.add_theme_constant_override("separation", 8)

	_resume_button = _make_button("Resume", "ResumeButton")
	_resume_button.pressed.connect(close)
	page.add_child(_resume_button)

	var options := _make_button("Options", "OptionsButton")
	options.pressed.connect(_show_options_page)
	page.add_child(options)

	var exit := _make_button("Exit", "ExitButton")
	exit.pressed.connect(_show_exit_page)
	page.add_child(exit)

	return page


func _build_options_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = "OptionsPage"
	page.add_theme_constant_override("separation", 8)

	var head := Label.new()
	head.name = "OptionsHeading"
	head.text = "OPTIONS"
	head.add_theme_font_size_override("font_size", 18)
	page.add_child(head)

	var tabs := TabContainer.new()
	tabs.name = "Tabs"
	tabs.custom_minimum_size = Vector2(0, TAB_HEIGHT)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.clip_tabs = false
	_tabs = tabs
	page.add_child(tabs)

	_graphics_tab = _build_graphics_tab()
	_sound_tab = _build_sound_tab()
	tabs.add_child(_graphics_tab)
	tabs.add_child(_sound_tab)

	var back := _make_button("Back", "BackButton")
	back.pressed.connect(_show_main_page)
	page.add_child(back)

	return page


func _build_graphics_tab() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "Graphics"   # TabContainer uses the child name as the tab title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var box := VBoxContainer.new()
	box.name = "GraphicsRows"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	# --- quality preset ---
	var preset_labels: PackedStringArray = PackedStringArray()
	for entry: Dictionary in Settings.PRESETS:
		preset_labels.append(str(entry["label"]))
	preset_labels.append("Custom")
	_preset_option = _add_option_row(box, "Quality preset", preset_labels, 0,
			_on_preset_selected, "A starting point — every row below stays editable",
			"PresetOption")

	_section(box, "Anti-aliasing & upscaling")

	_msaa_option = _add_option_row(box, "Anti-aliasing (MSAA)",
			PackedStringArray(Settings.MSAA_LABELS), 0,
			func(index: int) -> void: _write_graphics("msaa", index), "", "MsaaOption")
	_checks["fxaa"] = _add_check_row(box, "fxaa")
	_checks["taa"] = _add_check_row(box, "taa")

	var upscalers: PackedStringArray = PackedStringArray()
	for entry: Dictionary in Settings.UPSCALERS:
		upscalers.append(str(entry["label"]))
	_upscaler_option = _add_option_row(box, "Upscaling", upscalers, 0,
			_on_upscaler_selected, "Internal resolution handles render scale below",
			"UpscalerOption")
	# Reserved slots: visible so the roadmap is legible in-game, disabled because
	# nothing implements them yet (GameSettings.UPSCALERS_RESERVED).
	for entry: Dictionary in Settings.UPSCALERS_RESERVED:
		_upscaler_option.add_item(str(entry["label"]))
		_upscaler_option.set_item_disabled(_upscaler_option.item_count - 1, true)

	var scale_row := _add_slider_row(box, "3D render scale", 0.5, 1.0, 0.05, 1.0,
			_on_render_scale_changed, "RenderScaleSlider")
	_render_scale_slider = scale_row["slider"]
	_render_scale_value = scale_row["value"]

	_section(box, "Shadows")

	_checks["shadows"] = _add_check_row(box, "shadows")
	_shadow_quality_option = _add_option_row(box, "Shadow quality",
			PackedStringArray(SHADOW_QUALITY_LABELS), 2,
			_on_shadow_quality_selected, "Directional shadow atlas size",
			"ShadowQualityOption")

	_section(box, "Post-processing")

	_checks["ssao"] = _add_check_row(box, "ssao")
	_checks["glow"] = _add_check_row(box, "glow")
	_checks["volumetric_fog"] = _add_check_row(box, "volumetric_fog")
	_checks["distance_fog"] = _add_check_row(box, "distance_fog")

	_section(box, "Performance")

	_view_distance_option = _add_option_row(box, "View distance",
			PackedStringArray(VIEW_DISTANCE_LABELS), 1,
			_on_view_distance_selected, "Camera far plane — the cheapest win on big cities",
			"ViewDistanceOption")

	var fps_labels: PackedStringArray = PackedStringArray()
	for entry: Dictionary in MAX_FPS_CHOICES:
		fps_labels.append(str(entry["label"]))
	_max_fps_option = _add_option_row(box, "Frame rate cap", fps_labels,
			MAX_FPS_CHOICES.size() - 1, _on_max_fps_selected, "", "MaxFpsOption")

	_checks["vsync"] = _add_check_row(box, "vsync")

	_note(box, "Every row here is a key in GameSettings. A future custom shader, "
			+ "occlusion culling, more post-processing or DLSS/TSR drops in as a new "
			+ "entry in those tables — the menu builds itself from them.")

	return scroll


func _build_sound_tab() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "Sound"   # TabContainer uses the child name as the tab title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var box := VBoxContainer.new()
	box.name = "SoundRows"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	_section(box, "Mixer")

	for row: Dictionary in SOUND_ROWS:
		var key := str(row["key"])
		var parts := _add_slider_row(box, str(row["label"]), 0.0, 1.0, 0.02, 0.8,
				func(value: float) -> void: _on_volume_changed(key, value),
				"Volume_%s" % key)
		_sound_sliders[key] = parts["slider"]
		_sound_values[key] = parts["value"]

	_mute_check = _add_check_row_raw(box, "Mute all", false,
			func(pressed: bool) -> void: _write_sound("mute", pressed),
			"Silences the master bus; individual volumes are remembered", "MuteCheck")

	_note(box, "Ring Bell ships no audio yet. These buses (Master, Music, SFX, "
			+ "Ambience, UI) are created at startup so future sound routes to the "
			+ "right slider from day one, and the mix is saved like any other option.")

	return scroll


func _build_exit_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = "ExitPage"
	page.add_theme_constant_override("separation", 8)

	var head := Label.new()
	head.name = "ExitHeading"
	head.text = "Exit"
	head.add_theme_font_size_override("font_size", 18)
	page.add_child(head)

	var question := Label.new()
	question.name = "ExitQuestion"
	question.text = "Quit Ring Bell to the desktop?"
	page.add_child(question)

	var warning := Label.new()
	warning.name = "ExitWarning"
	warning.text = "Anything not saved from the in-game save menu is lost."
	warning.add_theme_font_size_override("font_size", 12)
	warning.add_theme_color_override("font_color", Color(0.85, 0.7, 0.45))
	page.add_child(warning)

	_quit_button = _make_button("Yes, quit to desktop", "QuitConfirmButton")
	_quit_button.pressed.connect(_on_quit_confirmed)
	page.add_child(_quit_button)

	var cancel := _make_button("Cancel", "QuitCancelButton")
	cancel.pressed.connect(_show_main_page)
	page.add_child(cancel)

	_exit_confirm = page
	return page


# ================= pages =================

func _show_main_page() -> void:
	_page_main.visible = true
	_page_options.visible = false
	_page_exit.visible = false


func _show_options_page() -> void:
	_sync_from_settings()
	_page_main.visible = false
	_page_options.visible = true
	_page_exit.visible = false


func _show_exit_page() -> void:
	_page_main.visible = false
	_page_options.visible = false
	_page_exit.visible = true
	if _quit_button != null:
		_quit_button.grab_focus()


func _on_quit_confirmed() -> void:
	var settings := _settings()
	if settings != null:
		settings.save_to_disk()
	get_tree().quit()


# ================= callbacks =================

func _on_preset_selected(index: int) -> void:
	var settings := _settings()
	if settings == null or index >= Settings.PRESETS.size():
		return
	settings.apply_preset(str(Settings.PRESETS[index]["id"]))
	_sync_from_settings()


func _on_upscaler_selected(index: int) -> void:
	if index >= Settings.UPSCALERS.size():
		return   # a reserved (disabled) slot
	_write_graphics("upscaler", str(Settings.UPSCALERS[index]["id"]))


func _on_shadow_quality_selected(index: int) -> void:
	_write_graphics("shadow_quality", SHADOW_QUALITY_IDS[clampi(index, 0,
			SHADOW_QUALITY_IDS.size() - 1)])


func _on_view_distance_selected(index: int) -> void:
	_write_graphics("view_distance", VIEW_DISTANCE_IDS[clampi(index, 0,
			VIEW_DISTANCE_IDS.size() - 1)])


func _on_max_fps_selected(index: int) -> void:
	var clamped := clampi(index, 0, MAX_FPS_CHOICES.size() - 1)
	_write_graphics("max_fps", int(MAX_FPS_CHOICES[clamped]["value"]))


func _on_render_scale_changed(value: float) -> void:
	if _syncing:
		return
	_render_scale_value.text = "%d%%" % roundi(value * 100.0)
	_write_graphics("render_scale", value)


func _on_volume_changed(key: String, value: float) -> void:
	if _syncing:
		return
	var label: Label = _sound_values.get(key)
	if label != null:
		label.text = "%d%%" % roundi(value * 100.0)
	_write_sound(key, value)


func _on_check_toggled(key: String, section: String, pressed: bool) -> void:
	if section == "graphics":
		_write_graphics(key, pressed)
	else:
		_write_sound(key, pressed)


## Any hand-tuned row moves the preset dropdown to "Custom" so the header never
## claims a quality level the values no longer match.
func _write_graphics(key: String, value: Variant) -> void:
	if _syncing:
		return
	var settings := _settings()
	if settings == null:
		return
	settings.set_graphics(key, value)
	if key != "preset" and str(settings.graphics("preset")) != CUSTOM_PRESET:
		settings.set_graphics("preset", CUSTOM_PRESET)
	_preset_option.select(_preset_index(str(settings.graphics("preset"))))


func _write_sound(key: String, value: Variant) -> void:
	if _syncing:
		return
	var settings := _settings()
	if settings != null:
		settings.set_sound(key, value)


# ================= widgets =================

func _make_button(text: String, node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(0, 38)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return button


func _section(parent: VBoxContainer, text: String) -> void:
	parent.add_child(_separator())
	var label := Label.new()
	label.name = "Section_%s" % text.replace(" ", "")
	label.text = text.to_upper()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.62, 0.72, 0.9))
	parent.add_child(label)


func _note(parent: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.name = "Note"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(PANEL_WIDTH - 120, 0)
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.7))
	parent.add_child(label)


func _separator() -> HSeparator:
	var line := HSeparator.new()
	line.name = "Separator"
	return line


func _row(parent: VBoxContainer, label_text: String, control: Control,
		hint: String, node_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % node_name
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.add_child(label)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

	if hint != "":
		var hint_label := Label.new()
		hint_label.text = hint
		hint_label.add_theme_font_size_override("font_size", 11)
		hint_label.add_theme_color_override("font_color", Color(0.58, 0.6, 0.66))
		row.add_child(hint_label)

	parent.add_child(row)
	return row


func _add_option_row(parent: VBoxContainer, label_text: String,
		items: PackedStringArray, selected: int, callback: Callable,
		hint: String = "", node_name: String = "Option") -> OptionButton:
	var option := OptionButton.new()
	option.name = node_name
	option.custom_minimum_size = Vector2(190, 30)
	for item: String in items:
		option.add_item(item)
	option.select(clampi(selected, 0, maxi(items.size() - 1, 0)))
	option.item_selected.connect(callback)
	_row(parent, label_text, option, hint, node_name)
	return option


func _add_check_row(parent: VBoxContainer, key: String) -> CheckButton:
	var label := ""
	var hint := ""
	for entry: Dictionary in GRAPHICS_CHECKS:
		if str(entry["key"]) == key:
			label = str(entry["label"])
			hint = str(entry["hint"])
			break
	return _add_check_row_raw(parent, label, false,
			func(pressed: bool) -> void: _on_check_toggled(key, "graphics", pressed),
			hint, "Check_%s" % key)


func _add_check_row_raw(parent: VBoxContainer, label_text: String, pressed: bool,
		callback: Callable, hint: String, node_name: String) -> CheckButton:
	var check := CheckButton.new()
	check.name = node_name
	# The label must report the STATE. A constant "On" label made every
	# toggled-off row read as enabled in the first capture.
	check.text = "On" if pressed else "Off"
	check.button_pressed = pressed
	check.toggled.connect(callback)
	check.toggled.connect(func(pressed_now: bool) -> void:
		check.text = "On" if pressed_now else "Off")
	_row(parent, label_text, check, hint, node_name)
	return check


func _add_slider_row(parent: VBoxContainer, label_text: String, min_value: float,
		max_value: float, step: float, value: float, callback: Callable,
		node_name: String) -> Dictionary:
	var slider := HSlider.new()
	slider.name = node_name
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(220, 24)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(callback)

	var value_label := Label.new()
	value_label.name = "%sValue" % node_name
	value_label.text = "%d%%" % roundi(value * 100.0)
	value_label.custom_minimum_size = Vector2(56, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var holder := HBoxContainer.new()
	holder.name = "%sHolder" % node_name
	holder.add_theme_constant_override("separation", 8)
	holder.add_child(slider)
	holder.add_child(value_label)

	_row(parent, label_text, holder, "", node_name)
	return {"slider": slider, "value": value_label}


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.075, 0.1, 0.97)
	style.border_color = Color(0.32, 0.38, 0.5)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(0)
	return style


# ================= view sync =================

## Push saved values into every widget WITHOUT triggering the write callbacks.
func _sync_from_settings() -> void:
	var settings := _settings()
	if settings == null:
		return
	_syncing = true

	_preset_option.select(_preset_index(str(settings.graphics("preset"))))
	_msaa_option.select(clampi(int(settings.graphics("msaa")), 0, 3))
	_upscaler_option.select(_upscaler_index(str(settings.graphics("upscaler"))))

	_render_scale_slider.value = float(settings.graphics("render_scale"))
	_render_scale_value.text = "%d%%" % roundi(
			float(settings.graphics("render_scale")) * 100.0)

	_shadow_quality_option.select(maxi(
			SHADOW_QUALITY_IDS.find(str(settings.graphics("shadow_quality"))), 0))
	_view_distance_option.select(maxi(
			VIEW_DISTANCE_IDS.find(str(settings.graphics("view_distance"))), 0))
	_max_fps_option.select(_max_fps_index(int(settings.graphics("max_fps"))))

	for key: String in _checks:
		var check: CheckButton = _checks[key]
		var on := bool(settings.graphics(key))
		check.set_pressed_no_signal(on)
		check.text = "On" if on else "Off"

	for key: String in _sound_sliders:
		var slider: HSlider = _sound_sliders[key]
		slider.value = float(settings.sound(key))
		var label: Label = _sound_values[key]
		label.text = "%d%%" % roundi(float(settings.sound(key)) * 100.0)

	_mute_check.set_pressed_no_signal(bool(settings.sound("mute")))
	_mute_check.text = "On" if bool(settings.sound("mute")) else "Off"

	_syncing = false


func _preset_index(id: String) -> int:
	for i: int in Settings.PRESETS.size():
		if str(Settings.PRESETS[i]["id"]) == id:
			return i
	return Settings.PRESETS.size()   # "Custom"


func _upscaler_index(id: String) -> int:
	for i: int in Settings.UPSCALERS.size():
		if str(Settings.UPSCALERS[i]["id"]) == id:
			return i
	return 0


func _max_fps_index(value: int) -> int:
	for i: int in MAX_FPS_CHOICES.size():
		if int(MAX_FPS_CHOICES[i]["value"]) == value:
			return i
	return MAX_FPS_CHOICES.size() - 1
