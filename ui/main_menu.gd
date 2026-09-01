extends CanvasLayer
## MainMenu — additive start screen that does NOT load the world.
## Headless / test flags bypass it entirely (see world/main.gd gate).
## Flow: Start Game -> spawn grid | Load Game -> immediate stream | Quit

signal spawn_selected(kind: StringName)
signal load_game_requested
signal quit_requested

var _root_vbox: VBoxContainer
var _spawn_panel: Panel
var _grid: GridContainer
var _load_btn: Button
var _status: Label

func _ready() -> void:
	layer = 110
	_build_ui()
	_refresh_load_button()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.07, 0.1, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_root_vbox = VBoxContainer.new()
	_root_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_root_vbox.add_theme_constant_override("separation", 14)
	_root_vbox.custom_minimum_size = Vector2(680, 0)
	center.add_child(_root_vbox)

	var title := Label.new()
	title.text = "RING  BELL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(0.97, 0.93, 0.84))
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 8)
	_root_vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Czech survival — choose where to wake up"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", Color(0.82, 0.81, 0.78))
	_root_vbox.add_child(subtitle)

	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(520, 2)
	_root_vbox.add_child(sep)

	# Primary actions
	var btn_row := VBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	_root_vbox.add_child(btn_row)

	var start_btn := _make_primary_button("▶  START GAME — Choose Spawn")
	start_btn.pressed.connect(_on_start_pressed)
	btn_row.add_child(start_btn)

	_load_btn = _make_button("↻  LOAD GAME", _on_load_pressed)
	btn_row.add_child(_load_btn)

	var quit_btn := _make_button("✕  QUIT", _on_quit_pressed)
	btn_row.add_child(quit_btn)

	_status = Label.new()
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.85, 0.75, 0.65))
	_root_vbox.add_child(_status)

	# Spawn selector panel — hidden until Start pressed
	_spawn_panel = Panel.new()
	_spawn_panel.visible = false
	_spawn_panel.custom_minimum_size = Vector2(640, 320)
	_spawn_panel.self_modulate = Color(1, 1, 1, 0.98)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.11, 0.11, 0.14, 0.96)
	panel_style.corner_radius_top_left = 10
	panel_style.corner_radius_top_right = 10
	panel_style.corner_radius_bottom_left = 10
	panel_style.corner_radius_bottom_right = 10
	panel_style.content_margin_left = 14
	panel_style.content_margin_right = 14
	panel_style.content_margin_top = 12
	panel_style.content_margin_bottom = 12
	_spawn_panel.add_theme_stylebox_override("panel", panel_style)
	_root_vbox.add_child(_spawn_panel)

	var spawn_vbox := VBoxContainer.new()
	spawn_vbox.add_theme_constant_override("separation", 8)
	_spawn_panel.add_child(spawn_vbox)

	var spawn_title := Label.new()
	spawn_title.text = "WHERE DO YOU WANT TO SPAWN?  (instant test)"
	spawn_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spawn_title.add_theme_font_size_override("font_size", 12)
	spawn_title.add_theme_color_override("font_color", Color(0.95, 0.9, 0.78))
	spawn_vbox.add_child(spawn_title)

	var spawn_hint := Label.new()
	spawn_hint.text = "World streams AFTER you pick — main menu costs nothing"
	spawn_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spawn_hint.add_theme_font_size_override("font_size", 10)
	spawn_hint.add_theme_color_override("font_color", Color(0.68, 0.68, 0.72))
	spawn_vbox.add_child(spawn_hint)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 6)
	spawn_vbox.add_child(_grid)

	for kind in SpawnPoints.SPAWN_KINDS:
		var id: StringName = kind["id"] as StringName
		var label: String = kind["label"] as String
		var desc: String = kind["desc"] as String
		var b := Button.new()
		b.text = "%s  —  %s" % [label, desc]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(300, 28)
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(_on_spawn_pick.bind(id))
		_grid.add_child(b)

	var back_btn := Button.new()
	back_btn.text = "← Back"
	back_btn.custom_minimum_size = Vector2(120, 26)
	back_btn.add_theme_font_size_override("font_size", 11)
	back_btn.pressed.connect(_on_back_pressed)
	spawn_vbox.add_child(back_btn)

	var footer := Label.new()
	footer.text = "F3 = debug  |  F5 quicksave  |  F9 quickload  |  Spawns are deterministic per seed"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 9)
	footer.add_theme_color_override("font_color", Color(0.60, 0.60, 0.64))
	_root_vbox.add_child(footer)

func _make_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(520, 36)
	b.add_theme_font_size_override("font_size", 14)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b

func _make_primary_button(text: String) -> Button:
	var b := _make_button(text, Callable())
	b.add_theme_color_override("font_hover_color", Color(1, 0.95, 0.72))
	b.add_theme_font_size_override("font_size", 15)
	return b

func _refresh_load_button() -> void:
	if _load_btn == null:
		return
	var has: bool = false
	if Engine.has_singleton("SaveManager"):
		has = SaveManager.has_save()
	else:
		# direct file check fallback
		has = FileAccess.file_exists("user://saves/save_01.json")
	_load_btn.disabled = not has
	if not has:
		_load_btn.tooltip_text = "No save found at user://saves/save_01.json"
	else:
		_load_btn.tooltip_text = "Load last save — world will stream first, then restore"

# ---------- Signals ----------

func _on_start_pressed() -> void:
	_spawn_panel.visible = true
	_status.text = "Pick a spawn — world will load after."

func _on_back_pressed() -> void:
	_spawn_panel.visible = false
	_status.text = ""

func _on_spawn_pick(kind: StringName) -> void:
	_status.text = "Spawning at %s..." % SpawnPoints.label_for(kind)
	spawn_selected.emit(kind)

func _on_load_pressed() -> void:
	if _load_btn.disabled:
		_status.text = "No save to load."
		return
	load_game_requested.emit()

func _on_quit_pressed() -> void:
	quit_requested.emit()
	get_tree().quit()
