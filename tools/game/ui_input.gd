extends SceneTree
## Drives the menus with real key and gamepad button events only (no Game.request_* calls), the
## way a player does: title navigation (mode, livery, map cards), the settings sheet (change
## values, close with Done), the pause menu (Restart, Settings, Main menu) and the results
## buttons (Next map); the autopilot does the laps. Prints CHECK lines and a summary; exits
## non-zero on failures.
##
##   timeout 600 $S --disable-crash-handler --path . -s res://tools/game/ui_input.gd

var main: Node
var game: Node
var ui: Node
var t0 := 0
var reached: Dictionary = {}
var marked: Dictionary = {}
var failures: Array[String] = []


func _initialize() -> void:
	root.size = Vector2i(1920, 1080)
	game = root.get_node("Game")
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1
		_log("STATE %s" % (game.State as Dictionary).find_key(s)))
	t0 = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	ui = main.ui
	await _until_state(&"MENU", 60.0)
	var title: Node = ui.title
	var cards: Array = title._cards
	await _until(func() -> bool: return _focus() == cards[0], 10.0)
	_check(_focus() == cards[0], "title focuses the Hanami card (%s)" % _focus_name())

	# ---------------------------------------------------------------- title pickers
	await _key(KEY_UP)
	await _check_focus(title._swatches, "Up: livery picker")
	await _key(KEY_RIGHT)
	_check(int(game.get_setting("car_color")) == 1, "Right on livery picks paint 1 (%s)" % game.get_setting("car_color"))
	await _key(KEY_LEFT)
	_check(int(game.get_setting("car_color")) == 0, "Left on livery back to paint 0")
	await _key(KEY_UP)
	await _check_focus(title._mode, "Up: mode picker")
	await _key(KEY_RIGHT)
	_check(title._mode.selected == 1, "Right on mode selects Free Roam")
	await _key(KEY_LEFT)
	_check(title._mode.selected == 0, "Left on mode back to Time Trial")

	# ---------------------------------------------------------------- settings from the title
	await _key(KEY_DOWN)
	await _key(KEY_DOWN)
	await _check_focus(cards[0], "Down, Down: back on the Hanami card")
	await _key(KEY_DOWN)
	await _check_focus(title._settings_btn, "Down: Settings button")
	await _key(KEY_ENTER)
	var settings: Node = ui.settings
	await _until(func() -> bool: return settings.is_open and _focus() == settings._rows[0].get_child(1), 3.0)
	_check(settings.is_open, "Enter opens settings")
	_check(_focus() == settings._rows[0].get_child(1), "settings focus the first row (%s)" % _focus_name())
	for i in 4:
		await _key(KEY_DOWN)
	await _check_focus(settings._controls["transmission"], "Down x4: Gearbox row")
	await _key(KEY_RIGHT)
	_check(game.get_setting("transmission") == "manual", "Right: gearbox manual")
	await _key(KEY_LEFT)
	_check(game.get_setting("transmission") == "auto", "Left: gearbox automatic")
	await _key(KEY_DOWN)
	await _key(KEY_DOWN)
	await _check_focus(settings._controls["units"], "Down x2: Speed row")
	await _key(KEY_RIGHT)
	_check(game.get_setting("units") == "mph", "Right: units mph")
	await _key(KEY_LEFT)
	_check(game.get_setting("units") == "kmh", "Left: units km/h")
	await _key(KEY_DOWN)
	await _key(KEY_DOWN)
	await _check_focus(settings._done, "Down x2: Done")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return not settings.is_open, 2.0)
	_check(not settings.is_open, "Enter on Done closes settings")
	await _until(func() -> bool: return _focus() == title._settings_btn, 2.0)
	_check(_focus() == title._settings_btn, "focus returns to the Settings button (%s)" % _focus_name())

	# ---------------------------------------------------------------- start Momiji from its card
	await _key(KEY_UP)
	await _key(KEY_RIGHT)
	await _check_focus(cards[1], "Up, Right: Momiji card")
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"COUNTDOWN", 60.0)
	_check(game.map_id == "momiji" and game.mode == game.MODE_TIME_TRIAL, "Enter starts Momiji time trial (%s %s)" % [game.map_id, game.mode])
	_mark()
	await _until_state(&"RACING", 10.0)

	# ---------------------------------------------------------------- pause menu: Restart
	await _seconds(0.5)
	await _key(KEY_ESCAPE)
	var pause: Node = ui.pause_menu
	await _until(func() -> bool: return pause.is_open and _focus() == pause._resume, 2.0)
	_check(game.paused and pause.is_open and _focus() == pause._resume, "Esc pauses, focus on Resume (%s)" % _focus_name())
	await _key(KEY_DOWN)
	await _check_focus(pause._buttons[1], "Down: Restart")
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"COUNTDOWN", 30.0)
	_check(not game.paused and game.state == game.State.COUNTDOWN, "Restart runs a fresh countdown, unpaused")
	_mark()
	await _until_state(&"RACING", 10.0)

	# ---------------------------------------------------------------- autopilot lap to the results
	var car: Car = game.player_car
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.map.track.to_curve()
	car.add_child(ap)
	Engine.time_scale = 2.0
	_mark()
	await _until_state(&"FINISHED", 200.0)
	Engine.time_scale = 1.0
	var results: Node = ui.results
	await _until(func() -> bool: return _focus() == results._retry, 15.0)
	_check(_focus() == results._retry, "results focus Retry (%s)" % _focus_name())

	# ---------------------------------------------------------------- results: Next map on the gamepad
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _check_focus(results._next, "D-pad right: Next map")
	_mark()
	await _pad(JOY_BUTTON_A)
	await _until_state(&"COUNTDOWN", 60.0)
	_check(game.map_id == "hanami" and game.mode == game.MODE_TIME_TRIAL, "A on Next map starts Hanami time trial (%s)" % game.map_id)
	_mark()
	await _until_state(&"RACING", 10.0)

	# ---------------------------------------------------------------- pause on the gamepad: settings, main menu
	await _seconds(0.5)
	await _pad(JOY_BUTTON_START)
	await _until(func() -> bool: return pause.is_open and _focus() == pause._resume, 2.0)
	_check(game.paused and pause.is_open, "Start pauses")
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _check_focus(pause._buttons[2], "D-pad down x2: Settings")
	await _pad(JOY_BUTTON_A)
	await _until(func() -> bool: return settings.is_open, 2.0)
	_check(settings.is_open and game.paused, "A opens settings over the pause menu")
	await _pad(JOY_BUTTON_B)
	await _until(func() -> bool: return not settings.is_open and _focus() == pause._buttons[2], 2.0)
	_check(not settings.is_open and pause.is_open, "B closes settings, pause menu stays")
	_check(_focus() == pause._buttons[2], "focus back on Settings (%s)" % _focus_name())
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _check_focus(pause._buttons[3], "D-pad down: Main menu")
	_mark()
	await _pad(JOY_BUTTON_A)
	await _until_state(&"MENU", 60.0)
	await _until(func() -> bool: return _is_card(cards), 10.0)
	_check(not game.paused and not paused and Engine.time_scale == 1.0, "Main menu: unpaused, normal time")
	_check(_is_card(cards), "title focuses a map card again (%s)" % _focus_name())

	_log("SUMMARY: %d failures" % failures.size())
	for f in failures:
		_log("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


# ---------------------------------------------------------------- input

func _key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	await _send(ev)


func _pad(button: JoyButton) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	await _send(ev)


## Press, hold two frames, release, settle two frames (focus moves and tweens start).
func _send(ev: InputEvent) -> void:
	ev.set("pressed", true)
	Input.parse_input_event(ev)
	await process_frame
	await process_frame
	var up := ev.duplicate() as InputEvent
	up.set("pressed", false)
	Input.parse_input_event(up)
	await process_frame
	await process_frame


# ---------------------------------------------------------------- helpers

func _focus() -> Control:
	return root.gui_get_focus_owner()


func _focus_name() -> String:
	var f := _focus()
	if f == null:
		return "no focus"
	var label := str(f.get("text")) if f.get("text") != null else ""
	return "%s %s" % [f.get_class(), label] if label != "" else "%s %s" % [f.get_class(), f.name]


func _check_focus(expected: Control, what: String) -> void:
	await _until(func() -> bool: return _focus() == expected, 1.0)
	_check(_focus() == expected, "%s (%s)" % [what, _focus_name()])


func _is_card(cards: Array) -> bool:
	return cards.any(func(c: Control) -> bool: return c == _focus())


func _check(ok: bool, what: String) -> void:
	_log("CHECK %s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _log(msg: String) -> void:
	print("[%7.2f] %s" % [(Time.get_ticks_msec() - t0) / 1000.0, msg])


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call() and (Time.get_ticks_msec() - start) / 1000.0 < timeout:
		await process_frame


func _mark() -> void:
	marked = reached.duplicate()


func _until_state(state_name: StringName, timeout: float) -> void:
	var s: int = game.State[state_name]
	var start := Time.get_ticks_msec()
	while int(reached.get(s, 0)) <= int(marked.get(s, 0)):
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout:
			_log("TIMEOUT waiting for %s (state=%s)" % [state_name, (game.State as Dictionary).find_key(game.state)])
			return
		await process_frame
