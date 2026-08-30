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
	lines.append(_locomotion_line())
	for line in _chunk_lines():
		lines.append(line)
	for quest_id: StringName in QuestManager.QUEST_DEFS:
		lines.append("quest '%s': %s" % [quest_id, _quest_state_text(quest_id)])
	return "\n".join(lines)


## Streaming + population stats from the streamed city, when running.
func _chunk_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for manager in get_tree().get_nodes_in_group(&"chunk_manager"):
		for line in (manager as ChunkManager).debug_lines():
			out.append("world | " + line)
	for spawner in get_tree().get_nodes_in_group(&"city_spawner"):
		if spawner.has_method("debug_lines"):
			for line in spawner.call("debug_lines"):
				out.append("world | " + str(line))
	return out


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


func _locomotion_line() -> String:
	var player := ActorRegistry.get_actor(&"player")
	if player == null or not is_instance_valid(player):
		return "loco: no player"
	if not player.has_method("get_locomotion"):
		return "loco: no locomotion"
	var loco: CharacterLocomotion = player.get_locomotion() as CharacterLocomotion
	if loco == null or not is_instance_valid(loco):
		return "loco: no locomotion"
	var speed: float = 0.0
	if player is CharacterBody3D:
		speed = Vector2((player as CharacterBody3D).velocity.x, (player as CharacterBody3D).velocity.z).length()
	var state_str: String = player.get_locomotion_state() if player.has_method("get_locomotion_state") else "?"
	var blend: float = loco.blend
	var strafe: float = loco.strafe
	var slope: float = loco.slope_deg
	var foot: float = loco.foot_slide
	var anim_ms: float = loco.get_anim_ms() if loco.has_method("get_anim_ms") else 0.0
	var active_chars: int = CharacterLocomotion.active_char_count()
	var skinned: int = CharacterLocomotion.skinned_count()
	var vault: int = 1 if loco.state == CharacterLocomotion.State.VAULT else 0
	var mantle: int = 1 if loco.state == CharacterLocomotion.State.MANTLE else 0
	var hang: int = 1 if loco.state == CharacterLocomotion.State.HANG else 0
	var hand_snap_cm: float = loco.hand_snap * 100.0 if loco.has_method("get_hand_snap") else 0.0
	var stamina_val: float = 0.0
	if player.has_method("get_stamina"):
		stamina_val = player.get_stamina()
	elif "stamina" in player:
		stamina_val = float(player.get("stamina"))
	return "loco: %s blend %.2f speed %.1f strafe %.1f slope %.1f foot_slide %.3f vault %d mantle %d hang %d hand_snap %.1fcm stamina %.0f anim_ms %.2f active_chars %d/12 skinned %d/9" % [state_str, blend, speed, strafe, slope, foot, vault, mantle, hang, hand_snap_cm, stamina_val, anim_ms, active_chars, skinned]


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
