extends CanvasLayer
## Debug tools overlay. Built entirely in code so there are no UI scenes to break.
##
## Hotkeys:
##   F3 - toggle this overlay
##   F5 - quicksave
##   F9 - quickload
##   T  - cycle game time scale (1x / 8x / 30x)
##
## Shows: performance, clock, entity counts, player vitals, quest states and a
## rolling log of world events (the fastest way to verify that simulation and
## narrative stay connected).

const TIME_SCALES: Array[float] = [1.0, 8.0, 30.0]
const LOG_LINES := 9

var _stats_label: Label
var _log_label: Label
var _event_log: PackedStringArray = []
var _accum: float = 0.0


func _ready() -> void:
	layer = 100
	_build_ui()
	EventBus.actor_died.connect(_on_event_actor_died)
	EventBus.quest_state_changed.connect(_on_event_quest_changed)
	EventBus.flag_set.connect(_on_event_flag_set)


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.name = "DebugMargin"
	margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_stats_label = _make_label(13)
	_log_label = _make_label(12)
	_log_label.modulate = Color(1, 1, 1, 0.85)

	vbox.add_child(_stats_label)
	vbox.add_child(_log_label)
	margin.add_child(vbox)
	add_child(margin)


func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	return label


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F3:
				visible = not visible
			KEY_F5:
				SaveManager.save_game()
			KEY_F9:
				SaveManager.load_game()
			KEY_T:
				_cycle_time_scale()


func _cycle_time_scale() -> void:
	var idx := TIME_SCALES.find(GameClock.time_scale)
	var next: float = TIME_SCALES[(idx + 1) % TIME_SCALES.size()]
	GameClock.time_scale = next
	_push_log("TIME SCALE -> x%s" % next)


func _process(delta: float) -> void:
	_accum += delta
	if _accum < 0.25:
		return
	_accum = 0.0
	_stats_label.text = _build_stats_text()
	_log_label.text = "\n".join(_event_log)


# --- Stats ------------------------------------------------------------------

func _build_stats_text() -> String:
	var lines: PackedStringArray = []
	lines.append("FPS %d | Day %d %s%s | timescale x%s" % [
		Engine.get_frames_per_second(),
		GameClock.get_day(),
		GameClock.time_string(),
		" (NIGHT)" if GameClock.is_night() else "",
		GameClock.time_scale,
	])
	lines.append("survivors alive: %d | zombies alive: %d" % [
		ActorRegistry.count_alive_in_group(&"survivors"),
		ActorRegistry.count_alive_in_group(&"zombies"),
	])
	lines.append(_player_line())
	for quest_id: StringName in QuestManager.QUEST_DEFS:
		lines.append("quest '%s': %s" % [quest_id, _quest_state_text(quest_id)])
	return "\n".join(lines)


func _player_line() -> String:
	var player := ActorRegistry.get_actor(&"player")
	if player == null or not is_instance_valid(player):
		return "player: NOT SPAWNED"
	if player.health.is_dead:
		return "player: DEAD"
	return "player hp %.0f | hunger %.0f | thirst %.0f | fatigue %.0f | stamina %.0f | infection %.0f" % [
		player.health.current_health,
		player.needs.hunger,
		player.needs.thirst,
		player.needs.fatigue,
		player.stamina,
		player.health.infection * 100.0,
	]


func _quest_state_text(quest_id: StringName) -> String:
	var state := QuestManager.get_state(quest_id)
	match state:
		QuestManager.State.ACTIVE:
			return "ACTIVE - %s" % QuestManager.get_objective_text(quest_id)
		QuestManager.State.COMPLETED:
			return "COMPLETED"
		QuestManager.State.FAILED:
			return "FAILED (%s)" % QuestManager.get_fail_reason(quest_id)
	return "inactive"


# --- Event log --------------------------------------------------------------

func _push_log(line: String) -> void:
	_event_log.append("[%s] %s" % [GameClock.time_string(), line])
	while _event_log.size() > LOG_LINES:
		_event_log.remove_at(0)


func _on_event_actor_died(actor_id: StringName, killer_id: StringName) -> void:
	var who := str(killer_id) if killer_id != &"" else "?"
	_push_log("DEATH: %s (by %s)" % [actor_id, who])


func _on_event_quest_changed(quest_id: StringName, new_state: int) -> void:
	_push_log("QUEST '%s' -> state %d" % [quest_id, new_state])


func _on_event_flag_set(flag: StringName, value: Variant) -> void:
	_push_log("FLAG: %s = %s" % [flag, value])
