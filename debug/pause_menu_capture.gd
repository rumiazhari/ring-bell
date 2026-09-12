extends Node
## --pausemenucapture : renders the ESC menu over the live streamed city.
##
## Writes PNGs to .hermes/autopilot/reports/pause-menu/ so the menu can be
## reviewed as pixels, not as a description:
##   01_gameplay_before_esc  — the world with the menu closed
##   02_esc_menu_main        — Resume / Options / Exit
##   03_options_graphics     — the Graphics tab, live values
##   04_options_sound        — the Sound tab
##   05_shadows_off          — a real toggle: sun shadows disabled from Options
##   06_shadows_on           — back on, same camera, for comparison
##
## Needs a real renderer (windowed), so do NOT pass --headless.
##
## The wait is event-driven, not a fixed sleep: the first version slept 4 s and
## photographed a black void with `resident chunks 0` while the CityPlan was
## still generating. Gate on the same things area_capture.gd does — the
## ChunkManager group, the player actor, and materialized chunks.
##
## It also has to run on a QUIET machine. With several other Godot instances
## competing for the CPU the worker-thread chunk jobs never completed at all
## (queued 25, materialized 0, for minutes at a time), so this harness waits
## generously instead of assuming a fixed build time.

const OUT_DIR := "res://.hermes/autopilot/reports/pause-menu"
const SETTLE_FRAMES := 12

var _menu: Node
var _settings: Node
var _tabs: TabContainer


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		print("[PauseMenuCapture] needs a windowed run - the dummy renderer cannot capture 3D")
		get_tree().quit(0)
		return
	DisplayServer.window_set_size(Vector2i(1280, 720))
	get_tree().create_timer(1500.0).timeout.connect(func() -> void:
		print("[PauseMenuCapture] WATCHDOG TIMEOUT - aborting")
		get_tree().quit(2))
	# The dev stat panel is a full-screen translucent text wall; it washes out
	# every frame (same reason area_capture.gd hides it).
	var overlay := get_node_or_null("/root/DebugOverlay") as CanvasLayer
	if overlay != null:
		overlay.visible = false
	_menu = get_node_or_null("/root/PauseMenu")
	_settings = get_node_or_null("/root/GameSettings")
	if _menu == null or _settings == null:
		push_error("[PauseMenuCapture] PauseMenu/GameSettings autoload missing")
		get_tree().quit(1)
		return

	if not await _world_ready():
		get_tree().quit(1)
		return

	# This runs against the REAL user profile (windowed), so whatever we force
	# for the photographs is put back at the end.
	var saved_settings: Dictionary = _settings.snapshot()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await _frames(SETTLE_FRAMES)
	await _shot("01_gameplay_before_esc")

	_menu.open()
	await _frames(SETTLE_FRAMES)
	await _shot("02_esc_menu_main")

	(_menu.find_child("OptionsButton", true, false) as Button).pressed.emit()
	await _frames(SETTLE_FRAMES)
	_tabs = _menu.find_child("Tabs", true, false) as TabContainer
	await _shot("03_options_graphics")

	# The post-processing rows (SSAO, glow, volumetric fog, distance fog, view
	# distance, frame cap, VSync) sit below the fold of the first screenful, so
	# the graphics page needs a second shot scrolled to the bottom. Horizontal
	# scrolling is disabled, so this is the whole remaining page.
	if _tabs != null:
		var graphics_scroll := _tabs.get_tab_control(0) as ScrollContainer
		if graphics_scroll != null:
			graphics_scroll.scroll_vertical = 100000
	await _frames(SETTLE_FRAMES)
	await _shot("03b_options_graphics_scrolled")

	if _tabs != null:
		_tabs.current_tab = 1
	await _frames(SETTLE_FRAMES)
	await _shot("04_options_sound")

	_menu.close()
	await _frames(4)

	# A toggle that is visible even in a still: sun shadows off, then on.
	_settings.set_graphics("shadows", false)
	await _frames(SETTLE_FRAMES)
	await _shot("05_shadows_off")
	_settings.set_graphics("shadows", true)
	await _frames(SETTLE_FRAMES)
	await _shot("06_shadows_on")

	_settings.restore(saved_settings)
	print("[PauseMenuCapture] done - images in %s" % OUT_DIR)
	get_tree().quit(0)


## Mirror of area_capture.gd: wait for the streamed world to actually exist
## before photographing it.
func _world_ready() -> bool:
	if not await _until(func() -> bool:
			return not get_tree().get_nodes_in_group(&"chunk_manager").is_empty(), 300.0):
		print("[PauseMenuCapture] no chunk manager after 300 s - world did not boot")
		return false
	var manager := get_tree().get_nodes_in_group(&"chunk_manager")[0] as ChunkManager
	if manager == null:
		print("[PauseMenuCapture] chunk_manager group holds a non-ChunkManager node")
		return false
	await _until(func() -> bool:
			return ActorRegistry.get_actor(&"player") != null, 120.0)
	var materialized := await _until(func() -> bool:
			return manager.active_count() > 0, 600.0)
	print("[PauseMenuCapture] world up: active=%d (chunks materialized=%s)"
			% [manager.active_count(), str(materialized)])
	return materialized


func _until(predicate: Callable, timeout: float) -> bool:
	var waited := 0.0
	while waited < timeout:
		if predicate.call():
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return false


func _frames(count: int) -> void:
	for _i: int in count:
		await get_tree().process_frame


func _shot(image_name: String) -> void:
	await RenderingServer.frame_post_draw
	var texture := get_viewport().get_texture()
	if texture == null:
		push_error("[PauseMenuCapture] no viewport texture for %s" % image_name)
		return
	var image := texture.get_image()
	var path := "%s/%s.png" % [OUT_DIR, image_name]
	var error := image.save_png(path)
	if error != OK:
		push_error("[PauseMenuCapture] save_png(%s) failed: %d" % [path, error])
		return
	print("[PauseMenuCapture] wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])
