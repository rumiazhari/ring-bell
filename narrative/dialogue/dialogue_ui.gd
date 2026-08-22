class_name DialogueUI
extends CanvasLayer
## Minimal dialogue panel driven by DialogueData trees.
##
## Flow: main.gd connects survivor interactions to open_for(); this UI renders
## the current node and applies coded effects through DialogueData.apply_effect.
## The game does NOT pause during dialogue - the simulation keeps running,
## so an NPC can even die mid-conversation (we close cleanly).

signal dialogue_opened
signal dialogue_closed

const PANEL_WIDTH := 720.0

var _npc: Survivor = null
var _player: Survivor = null
var _tree := {}
var _panel: PanelContainer
var _speaker_label: Label
var _body_label: RichTextLabel
var _options_box: VBoxContainer


func _ready() -> void:
	layer = 50
	visible = false
	_build_ui()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	# Anchor center-bottom, offset up from screen edge.
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH * 0.5
	_panel.offset_right = PANEL_WIDTH * 0.5
	_panel.offset_top = -260.0
	_panel.offset_bottom = -24.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.92)
	style.border_color = Color(0.55, 0.45, 0.25)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_panel.add_child(vbox)

	_speaker_label = Label.new()
	_speaker_label.add_theme_font_size_override("font_size", 18)
	_speaker_label.add_theme_color_override("font_color", Color(0.9, 0.82, 0.55))
	vbox.add_child(_speaker_label)

	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled = true
	_body_label.fit_content = true
	_body_label.custom_minimum_size = Vector2(PANEL_WIDTH - 40.0, 70.0)
	_body_label.add_theme_font_size_override("normal_font_size", 15)
	vbox.add_child(_body_label)

	_options_box = VBoxContainer.new()
	_options_box.add_theme_constant_override("separation", 4)
	vbox.add_child(_options_box)


func is_open() -> bool:
	return visible


## npc must be alive; player is the interacting survivor (receives rewards).
func open_for(npc: Survivor, player: Survivor) -> void:
	if npc == null or not is_instance_valid(npc) or npc.health.is_dead:
		return
	_npc = npc
	_player = player
	_tree = DialogueData.build_tree(npc.identity.persistent_id)
	if _tree.is_empty() or not _tree.has("start"):
		return
	npc.health.died.connect(_on_npc_died, CONNECT_ONE_SHOT)
	visible = true
	dialogue_opened.emit()
	_show_node(&"start")


func close() -> void:
	if not visible:
		return
	visible = false
	_tree = {}
	_npc = null
	_player = null
	dialogue_closed.emit()


func _show_node(node_id: StringName) -> void:
	if not _tree.has(node_id):
		close()
		return
	var node: Dictionary = _tree[node_id]
	_speaker_label.text = _npc.identity.display_name
	_body_label.text = node.get("text", "...")

	for child in _options_box.get_children():
		# Remove immediately so stale buttons can't be clicked this frame;
		# queue_free only handles memory cleanup.
		_options_box.remove_child(child)
		child.queue_free()
	var options: Array = node.get("options", [])
	for option in options:
		var button := Button.new()
		button.text = option.get("label", "...")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_choose.bind(option))
		_options_box.add_child(button)


func _choose(option: Dictionary) -> void:
	# The NPC may have died while we were talking - simulation keeps running.
	if _npc == null or not is_instance_valid(_npc) or _npc.health.is_dead:
		close()
		return

	var effect: Variant = option.get("effect")
	if effect != null and effect != &"" and effect != "":
		DialogueData.apply_effect(StringName(effect), _npc, _player)

	var next: Variant = option.get("next")
	if next != null and _tree.has(StringName(next)):
		_show_node(StringName(next))
	else:
		close()


func _on_npc_died(_source_id: StringName) -> void:
	close()
