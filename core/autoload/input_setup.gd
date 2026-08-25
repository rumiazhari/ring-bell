extends Node
## Registers all gameplay input actions at startup, before any other autoload runs.
##
## WHY IN CODE: the input map stays deterministic and diffable, and headless
## validation runs exercise the exact same setup the editor would.
## Add new actions here; do not scatter InputMap calls across systems.

func _enter_tree() -> void:
	_add_action(&"move_forward", [_key(KEY_W), _key(KEY_UP)])
	_add_action(&"move_back", [_key(KEY_S), _key(KEY_DOWN)])
	_add_action(&"move_left", [_key(KEY_A), _key(KEY_LEFT)])
	_add_action(&"move_right", [_key(KEY_D), _key(KEY_RIGHT)])
	_add_action(&"sprint", [_key(KEY_SHIFT)])
	_add_action(&"interact", [_key(KEY_E)])
	_add_action(&"attack", [_mouse(MOUSE_BUTTON_LEFT)])
	_add_action(&"jump", [_key(KEY_SPACE)])
	_add_action(&"camera_rotate_left", [_key(KEY_Q)])
	_add_action(&"camera_rotate_right", [_key(KEY_R)])
	_add_action(&"eat", [_key(KEY_F)])
	_add_action(&"use_medical", [_key(KEY_G)])
	_add_action(&"weapon_1", [_key(KEY_1)])
	_add_action(&"weapon_2", [_key(KEY_2)])
	_add_action(&"weapon_3", [_key(KEY_3)])
	_add_action(&"weapon_4", [_key(KEY_4)])


func _add_action(action: StringName, events: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for ev in events:
		InputMap.action_add_event(action, ev)


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	return ev


func _mouse(button: MouseButton) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	return ev
