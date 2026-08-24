class_name HUD
extends CanvasLayer
## In-game HUD, built entirely in code.
##
## Shows: clock, vitals bars, active quest tracker, interaction prompt,
## toast notices, quest banners and a death screen.
## Reads player state via ActorRegistry - no hard references to actors.

const BAR_DEFS := [
	# [key, label, fill color]
	["hp", "HP", Color(0.85, 0.25, 0.2)],
	["stamina", "Stam", Color(0.75, 0.75, 0.3)],
	["hunger", "Hunger", Color(0.9, 0.55, 0.15)],
	["thirst", "Thirst", Color(0.25, 0.65, 0.8)],
	["fatigue", "Fatigue", Color(0.6, 0.4, 0.75)],
]

var _clock_label: Label
var _weapon_label: Label
var _bars := {}                # String key -> ProgressBar
var _quest_tracker: RichTextLabel
var _prompt_label: Label
var _notice_label: Label
var _banner_label: Label
var _death_overlay: Control
var _tracker_accum := 0.0
var _banner_tween: Tween
var _notice_tween: Tween


func _ready() -> void:
	layer = 40
	_build_ui()
	EventBus.quest_state_changed.connect(_on_quest_state_changed)


func _build_ui() -> void:
	_build_clock()
	_build_weapon_label()
	_build_vitals()
	_build_quest_tracker()
	_build_prompt_and_notice()
	_build_banner()
	_build_death_screen()


func set_weapon_label(text: String) -> void:
	_weapon_label.text = "Weapon: %s   [1-4]" % text


func _build_weapon_label() -> void:
	_weapon_label = _make_label(16, Color(0.9, 0.9, 0.82))
	_weapon_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_weapon_label.offset_left = 14.0
	_weapon_label.offset_top = 10.0
	add_child(_weapon_label)
	set_weapon_label("Fists")


func _make_label(font_size: int, color := Color.WHITE) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	return label


# --- Clock ------------------------------------------------------------------

func _build_clock() -> void:
	_clock_label = _make_label(20, Color(0.95, 0.92, 0.8))
	_clock_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_clock_label.anchor_left = 1.0
	_clock_label.offset_left = -320.0
	_clock_label.offset_right = -16.0
	_clock_label.offset_top = 10.0
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_clock_label)


# --- Vitals bars ------------------------------------------------------------

func _build_vitals() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	vbox.anchor_top = 1.0
	vbox.offset_left = 14.0
	vbox.offset_top = -160.0
	vbox.offset_bottom = -14.0
	vbox.add_theme_constant_override("separation", 4)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)

	for def in BAR_DEFS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var name_label := _make_label(12)
		name_label.text = def[1]
		name_label.custom_minimum_size = Vector2(56, 0)
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_label)

		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.value = 100.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(170, 13)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.05, 0.05, 0.06, 0.8)
		bg.set_corner_radius_all(3)
		var fill := StyleBoxFlat.new()
		fill.bg_color = def[2]
		fill.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("background", bg)
		bar.add_theme_stylebox_override("fill", fill)
		row.add_child(bar)

		vbox.add_child(row)
		_bars[def[0]] = bar


# --- Quest tracker ----------------------------------------------------------

func _build_quest_tracker() -> void:
	_quest_tracker = RichTextLabel.new()
	_quest_tracker.bbcode_enabled = true
	_quest_tracker.fit_content = true
	_quest_tracker.scroll_active = false
	_quest_tracker.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_quest_tracker.anchor_left = 1.0
	_quest_tracker.offset_left = -340.0
	_quest_tracker.offset_right = -16.0
	_quest_tracker.offset_top = 44.0
	_quest_tracker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_quest_tracker)


func refresh_quest_tracker() -> void:
	if QuestManager.QUEST_DEFS.is_empty():
		return
	var lines: PackedStringArray = []
	for quest_id: StringName in QuestManager.QUEST_DEFS:
		var state := QuestManager.get_state(quest_id)
		match state:
			QuestManager.State.ACTIVE:
				lines.append("[b]%s[/b]\n  > %s" % [
						QuestManager.get_title(quest_id),
						QuestManager.get_objective_text(quest_id)])
			QuestManager.State.FAILED:
				lines.append("[s][color=#c66]%s (failed)[/color][/s]" %
						QuestManager.get_title(quest_id))
			QuestManager.State.COMPLETED:
				lines.append("[color=#7c7]Done: %s[/color]" %
						QuestManager.get_title(quest_id))
	_quest_tracker.text = "\n".join(lines)


func _on_quest_state_changed(_quest_id: StringName, new_state: int) -> void:
	refresh_quest_tracker()
	match new_state:
		QuestManager.State.ACTIVE:
			flash_banner("New task: %s" % QuestManager.get_title(_quest_id), Color(0.95, 0.88, 0.6))
		QuestManager.State.COMPLETED:
			flash_banner("Task complete: %s" % QuestManager.get_title(_quest_id), Color(0.5, 0.9, 0.45))
		QuestManager.State.FAILED:
			flash_banner("Failed: %s" % QuestManager.get_fail_reason(_quest_id), Color(0.9, 0.35, 0.3))


# --- Prompt / notice / banner ----------------------------------------------

func _build_prompt_and_notice() -> void:
	_prompt_label = _make_label(17, Color(0.95, 0.95, 0.9))
	_anchor_center_bottom(_prompt_label, -120.0)
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_prompt_label)

	_notice_label = _make_label(14, Color(0.8, 0.9, 1.0))
	_anchor_center_bottom(_notice_label, -158.0)
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.modulate.a = 0.0
	add_child(_notice_label)


func _anchor_center_bottom(control: Control, y_offset: float) -> void:
	control.anchor_left = 0.5
	control.anchor_right = 0.5
	control.anchor_top = 1.0
	control.anchor_bottom = 1.0
	control.grow_horizontal = Control.GROW_DIRECTION_BOTH
	control.offset_left = -300.0
	control.offset_right = 300.0
	control.offset_top = y_offset
	control.offset_bottom = y_offset + 30.0


func set_interact_prompt(text: String) -> void:
	_prompt_label.text = text


func flash_notice(text: String) -> void:
	_notice_label.text = text
	_notice_label.modulate.a = 1.0
	if _notice_tween != null and _notice_tween.is_valid():
		_notice_tween.kill()
	_notice_tween = create_tween()
	_notice_tween.tween_interval(1.4)
	_notice_tween.tween_property(_notice_label, "modulate:a", 0.0, 0.8)


func _build_banner() -> void:
	_banner_label = _make_label(22, Color(0.98, 0.93, 0.7))
	_banner_label.anchor_left = 0.5
	_banner_label.anchor_right = 0.5
	_banner_label.offset_left = -400.0
	_banner_label.offset_right = 400.0
	_banner_label.offset_top = 64.0
	_banner_label.offset_bottom = 100.0
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.modulate.a = 0.0
	add_child(_banner_label)


func flash_banner(text: String, color: Color) -> void:
	_banner_label.text = text
	_banner_label.add_theme_color_override("font_color", color)
	_banner_label.modulate.a = 1.0
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_interval(2.6)
	_banner_tween.tween_property(_banner_label, "modulate:a", 0.0, 1.0)


# --- Death screen -----------------------------------------------------------

func _build_death_screen() -> void:
	_death_overlay = Control.new()
	_death_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_overlay.visible = false
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_death_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.02, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_overlay.add_child(dim)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_death_overlay.add_child(vbox)

	var big := _make_label(42, Color(0.9, 0.25, 0.2))
	big.text = "YOU DIED"
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(big)

	var sub := _make_label(16, Color(0.8, 0.78, 0.75))
	sub.text = "The world moves on without you.\n(F9 loads your last save)"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)


func show_death_screen() -> void:
	_death_overlay.visible = true


func hide_death_screen() -> void:
	_death_overlay.visible = false


# --- Per-frame updates ------------------------------------------------------

func _process(delta: float) -> void:
	_update_clock()
	_update_bars()

	_tracker_accum += delta
	if _tracker_accum >= 0.5:
		_tracker_accum = 0.0
		refresh_quest_tracker()


func _update_clock() -> void:
	var night_tag := "  NIGHT" if GameClock.is_night() else ""
	_clock_label.text = "Day %d   %s%s" % [GameClock.get_day(), GameClock.time_string(), night_tag]


func _update_bars() -> void:
	var player: Survivor = ActorRegistry.get_actor(&"player")
	if player == null or not is_instance_valid(player):
		for key in _bars:
			_bars[key].value = 0.0
		return

	_bars["hp"].value = 100.0 * player.health.current_health / maxf(player.health.max_health, 1.0)
	_bars["stamina"].value = player.stamina
	_bars["hunger"].value = player.needs.hunger
	_bars["thirst"].value = player.needs.thirst
	_bars["fatigue"].value = player.needs.fatigue
