extends CanvasLayer
## LoadingScreen — shown from MainMenu while the world streams in.
## Avoids first-frame spike: world is built on main thread with chunk
## streaming, player is gated until terrain body exists (same gate as city).

var _panel: Panel
var _bar: ProgressBar
var _label: Label
var _sub_label: Label

func _ready() -> void:
	layer = 120
	_build_ui()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.09, 0.98)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "LOADING WORLD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.82))
	title.add_theme_color_override("font_outline_color", Color.BLACK)
	title.add_theme_constant_override("outline_size", 6)
	vbox.add_child(title)

	_label = Label.new()
	_label.text = "Generating terrain..."
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.88))
	vbox.add_child(_label)

	_sub_label = Label.new()
	_sub_label.text = ""
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.add_theme_font_size_override("font_size", 12)
	_sub_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	vbox.add_child(_sub_label)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(420, 18)
	_bar.max_value = 100.0
	_bar.value = 8.0
	_bar.show_percentage = false
	vbox.add_child(_bar)

	var hint := Label.new()
	hint.text = "Streaming 3x3 chunks — please wait for terrain collision"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.68))
	vbox.add_child(hint)

func set_progress(percent: float, text: String = "") -> void:
	if _bar:
		_bar.value = clampf(percent, 0.0, 100.0)
	if _label and text != "":
		_label.text = text

func set_sub_text(text: String) -> void:
	if _sub_label:
		_sub_label.text = text

func set_indeterminate(b: bool) -> void:
	if _bar:
		_bar.step = 1.0 if not b else 0.0
