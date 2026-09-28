extends SceneTree
## Drives the menus with real key and gamepad button events only (no Game.request_* calls), the
## way a player does: the title hub column (Campaign, Time Attack, Garage, Settings <-> Quit),
## the settings sheet from the hub (change values, close with Done), the garage (car selector,
## livery picker, Back), the Time Attack page (Time Trial / Free Roam picker, map cards, Back)
## and a Time Trial started from a card, the pause menu (Restart, Settings, Main menu), the
## results buttons (Next map), and the campaign: New journey from the hub, SS1 driven, results
## Continue, quit mid-liaison, the hub's Continue label and the "Start a new journey" confirm
## dialog (No via Esc, then Yes). The autopilot does the laps. Prints CHECK lines and a summary;
## exits non-zero on failures.
##
##   timeout 600 $S --headless --disable-crash-handler --path . -s res://tools/game/ui_input.gd

const LAP_SPEED := 3.0

var main: Node
var game: Node
var ui: Node
var t0 := 0
var reached: Dictionary = {}
var marked: Dictionary = {}
var failures: Array[String] = []
## A step the rest depends on failed (a state never came, the pause menu never showed): waits
## end at once and the remaining sections are skipped, so a broken flow ends with a summary.
var stuck := false


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
	for section: Callable in [_hub, _settings_from_hub, _garage, _time_attack, _time_trial_run, _campaign]:
		if stuck:
			_log("ABORT before %s: a step the rest depends on failed" % section.get_method())
			break
		await section.call()
	_log("SUMMARY: %d failures" % failures.size())
	for f in failures:
		_log("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


# ---------------------------------------------------------------- hub column

func _hub() -> void:
	var title: Node = ui.title
	await _until(func() -> bool: return _focus() == title._campaign_item, 10.0)
	_check(_focus() == title._campaign_item, "hub focuses the Campaign item (%s)" % _focus_name())
	var st: Dictionary = game.campaign_status()
	_check(not bool(st["started"]) and title._campaign_item._title_text == "New journey",
			"fresh profile: Campaign item reads 'New journey' (%s)" % title._campaign_item._title_text)
	_check(not title._new_journey_item.visible, "fresh profile: 'Start a new journey' hidden")
	await _key(KEY_DOWN)
	await _check_focus(title._time_attack_item, "Down: Time Attack")
	await _key(KEY_DOWN)
	await _check_focus(title._garage_item, "Down: Garage")
	await _pad(JOY_BUTTON_DPAD_DOWN)
	await _check_focus(title._settings_item, "D-pad down: Settings")
	await _key(KEY_DOWN)
	await _check_focus(title._settings_item, "Down on Settings stays (bottom of the column)")
	await _key(KEY_RIGHT)
	await _check_focus(title._quit_item, "Right: Quit")
	await _pad(JOY_BUTTON_DPAD_LEFT)
	await _check_focus(title._settings_item, "D-pad left: back on Settings")
	await _key(KEY_UP)
	await _check_focus(title._garage_item, "Up: Garage")
	await _pad(JOY_BUTTON_DPAD_UP)
	await _check_focus(title._time_attack_item, "D-pad up: Time Attack")
	await _key(KEY_UP)
	await _check_focus(title._campaign_item, "Up: Campaign (no new-journey row on a fresh profile)")
	await _key(KEY_UP)
	await _check_focus(title._campaign_item, "Up on Campaign stays (top of the column)")


# ---------------------------------------------------------------- settings from the hub

func _settings_from_hub() -> void:
	var title: Node = ui.title
	for i in 3:
		await _key(KEY_DOWN)
	await _check_focus(title._settings_item, "Down x3: Settings")
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
	await _until(func() -> bool: return _focus() == title._settings_item, 2.0)
	_check(_focus() == title._settings_item, "focus returns to the Settings item (%s)" % _focus_name())


# ---------------------------------------------------------------- garage

func _garage() -> void:
	var title: Node = ui.title
	var panel: Node = title._garage
	await _key(KEY_UP)
	await _check_focus(title._garage_item, "Up: Garage")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return str(game.menu_view) == "garage" and _focus() == panel.car_selector, 5.0)
	_check(title.view == "garage" and str(game.menu_view) == "garage", "Enter opens the garage (view %s, menu_view %s)" % [title.view, game.menu_view])
	_check(_focus() == panel.car_selector, "garage focuses the car selector (%s)" % _focus_name())
	var cars: Array = panel._cars
	if cars.size() > 1:
		var id0 := str(game.get_setting("car_id"))
		await _key(KEY_RIGHT)
		_check(str(game.get_setting("car_id")) == str(cars[1]["id"]), "Right on the car selector picks %s (%s)" % [cars[1]["id"], game.get_setting("car_id")])
		await _seconds(2.0)
		await _pad(JOY_BUTTON_DPAD_LEFT)
		_check(str(game.get_setting("car_id")) == str(cars[0]["id"]), "D-pad left back to %s (%s)" % [cars[0]["id"], game.get_setting("car_id")])
		_check(str(cars[0]["id"]) == id0, "car choice back where it started")
		await _seconds(2.0)
	else:
		_log("NOTE one car scene in the project: car selector switch skipped")
	await _key(KEY_UP)
	await _check_focus(panel.livery_picker, "Up: livery picker")
	var c0 := int(game.get_setting("car_color"))
	await _key(KEY_RIGHT)
	_check(int(game.get_setting("car_color")) == c0 + 1, "Right on the livery picker picks paint %d (%s)" % [c0 + 1, game.get_setting("car_color")])
	await _key(KEY_LEFT)
	_check(int(game.get_setting("car_color")) == c0, "Left back to paint %d (%s)" % [c0, game.get_setting("car_color")])
	await _seconds(0.5)
	await _pad(JOY_BUTTON_B)
	await _until(func() -> bool: return title.view == "title" and _focus() == title._garage_item, 5.0)
	_check(title.view == "title" and str(game.menu_view) == "title", "B leaves the garage (view %s, menu_view %s)" % [title.view, game.menu_view])
	_check(_focus() == title._garage_item, "focus back on the Garage item (%s)" % _focus_name())


# ---------------------------------------------------------------- time attack page

func _time_attack() -> void:
	var title: Node = ui.title
	var ta: Node = title._time_attack
	await _key(KEY_UP)
	await _check_focus(title._time_attack_item, "Up: Time Attack")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return _is_card(ta), 3.0)
	_check(title.view == "time_attack" and ta.visible, "Enter opens the Time Attack page (view %s)" % title.view)
	_check(_focus() == _card(ta, "hanami"), "page focuses the Hanami card (%s)" % _focus_name())
	await _key(KEY_UP)
	await _check_focus(ta.mode_picker, "Up: mode picker")
	await _key(KEY_RIGHT)
	_check(ta.mode_picker.selected == 1 and ta.mode() == "race", "Right on the picker: Race")
	_check(_visible_ids(ta) == ["hanami", "momiji"], "Race cards are the stages (%s)" % [_visible_ids(ta)])
	await _key(KEY_RIGHT)
	_check(ta.mode_picker.selected == 2 and ta.mode() == "free_roam", "Right again: Free Roam")
	_check(_visible_ids(ta) == ["hanami", "momiji"], "Free Roam cards are the stages (%s)" % [_visible_ids(ta)])
	await _key(KEY_LEFT)
	await _key(KEY_LEFT)
	_check(ta.mode_picker.selected == 0 and ta.mode() == "time_trial", "Left twice on the picker: Time Trial")
	_check(_visible_ids(ta) == ["hanami", "momiji"], "Time Trial cards are the stages (%s)" % [_visible_ids(ta)])
	await _key(KEY_DOWN)
	await _check_focus(_card(ta, "hanami"), "Down: Hanami card")
	await _key(KEY_RIGHT)
	await _check_focus(_card(ta, "momiji"), "Right: Momiji card")
	await _key(KEY_RIGHT)
	await _check_focus(_card(ta, "momiji"), "Right on the last card stays")
	await _pad(JOY_BUTTON_DPAD_LEFT)
	await _check_focus(_card(ta, "hanami"), "D-pad left: Hanami card")
	await _key(KEY_DOWN)
	await _check_focus(ta.back_button, "Down: Back button")
	await _key(KEY_ESCAPE)
	await _until(func() -> bool: return title.view == "title" and _focus() == title._time_attack_item, 2.0)
	_check(title.view == "title" and str(game.menu_view) == "title", "Esc returns to the hub (view %s)" % title.view)
	_check(_focus() == title._time_attack_item, "focus back on the Time Attack item (%s)" % _focus_name())

	# Start a Time Trial on Hanami from its card.
	await _seconds(0.8)
	await _key(KEY_ENTER)
	await _until(func() -> bool: return _focus() == _card(ta, "hanami"), 3.0)
	_check(_focus() == _card(ta, "hanami") and ta.mode() == "time_trial", "Enter: page again on Hanami, Time Trial (%s, %s)" % [_focus_name(), ta.mode()])
	await _seconds(0.6)
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"COUNTDOWN", 60.0)
	_check(game.map_id == "hanami" and game.mode == game.MODE_TIME_TRIAL, "Enter on the Hanami card starts a Hanami time trial (%s %s)" % [game.map_id, game.mode])
	_mark()
	await _until_state(&"RACING", 10.0)


# ---------------------------------------------------------------- pause, laps, results

func _time_trial_run() -> void:
	var title: Node = ui.title
	var ta: Node = title._time_attack
	var pause: Node = ui.pause_menu
	var settings: Node = ui.settings

	# Pause menu: Restart.
	await _seconds(0.5)
	await _key(KEY_ESCAPE)
	if not await _pause_menu_up("Esc pauses"):
		return
	await _key(KEY_DOWN)
	await _check_focus(pause._restart, "Down: Restart")
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"COUNTDOWN", 30.0)
	_check(not game.paused and game.state == game.State.COUNTDOWN, "Restart runs a fresh countdown, unpaused")
	_mark()
	await _until_state(&"RACING", 10.0)

	# Autopilot lap to the results.
	_drive()
	_mark()
	await _until_state(&"FINISHED", 200.0)
	Engine.time_scale = 1.0
	_check(game.state == game.State.FINISHED, "autopilot finishes the Hanami lap")
	var results: Node = ui.results
	await _until(func() -> bool: return _focus() == results._retry, 15.0)
	_check(_focus() == results._retry, "results focus Retry (%s)" % _focus_name())

	# Results: Next map on the gamepad.
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _check_focus(results._next, "D-pad right: Next map")
	_mark()
	await _pad(JOY_BUTTON_A)
	await _until_state(&"COUNTDOWN", 60.0)
	_check(game.map_id == "momiji" and game.mode == game.MODE_TIME_TRIAL, "A on Next map starts a Momiji time trial (%s)" % game.map_id)
	_mark()
	await _until_state(&"RACING", 10.0)

	# Pause on the gamepad: settings, main menu.
	await _seconds(0.5)
	await _pad(JOY_BUTTON_START)
	if not await _pause_menu_up("Start pauses"):
		return
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
	await _check_focus(pause._menu, "D-pad down: Main menu")
	_mark()
	await _pad(JOY_BUTTON_A)
	await _until_state(&"MENU", 60.0)
	await _until(func() -> bool: return _focus() == _card(ta, "momiji"), 10.0)
	_check(not game.paused and not paused and Engine.time_scale == 1.0, "Main menu: unpaused, normal time")
	_check(title.view == "time_attack" and _focus() == _card(ta, "momiji"), "back on the Time Attack page, Momiji card focused (%s)" % _focus_name())
	await _pad(JOY_BUTTON_B)
	await _until(func() -> bool: return title.view == "title" and _focus() == title._time_attack_item, 3.0)
	_check(title.view == "title" and _focus() == title._time_attack_item, "B: hub, focus on Time Attack (%s)" % _focus_name())


# ---------------------------------------------------------------- campaign

func _campaign() -> void:
	var title: Node = ui.title
	var pause: Node = ui.pause_menu
	var results: Node = ui.results
	var legs: Array = game.CAMPAIGN
	await _key(KEY_UP)
	await _check_focus(title._campaign_item, "Up: Campaign")
	_check(title._campaign_item._title_text == "New journey", "Campaign item still reads 'New journey' (%s)" % title._campaign_item._title_text)
	await _seconds(0.5)
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"INTRO", 60.0)
	_check(game.campaign_active and int(game.campaign_status()["leg"]) == 0, "Enter on New journey: leg 0 (%s)" % game.campaign_status()["leg"])
	_check(game.map_id == legs[0]["map"], "%s starts (%s)" % [legs[0]["code"], game.map_id])
	_mark()
	await _until_state(&"COUNTDOWN", 30.0)
	_mark()
	await _until_state(&"RACING", 10.0)
	_drive()
	_mark()
	await _until_state(&"FINISHED", 200.0)
	Engine.time_scale = 1.0
	_check(int(game.campaign_status()["leg"]) == 1, "%s finished: next leg 1 (%s)" % [legs[0]["code"], game.campaign_status()["leg"]])
	await _until(func() -> bool: return _focus() == results._continue, 15.0)
	_check(_focus() == results._continue, "campaign results focus Continue (%s)" % _focus_name())
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"LIAISON", 30.0)
	_check(game.map_id == legs[1]["map"] and game.campaign_leg == 1 and int(reached.get(game.State.LOADING, 0)) == int(marked.get(game.State.LOADING, 0)),
			"Enter on Continue: the liaison drives on without loading (%s, leg %s)" % [game.map_id, game.campaign_leg])
	await _seconds(1.0)

	# Quit to the title mid-liaison through the pause menu (keys).
	await _key(KEY_ESCAPE)
	if not await _pause_menu_up("Esc pauses the liaison"):
		return
	_check(not pause._restart.visible, "liaison pause menu has no Restart")
	await _key(KEY_DOWN)
	await _check_focus(pause._buttons[2], "Down: Settings (Restart skipped)")
	await _key(KEY_DOWN)
	await _check_focus(pause._menu, "Down: Quit to title")
	_check(pause._menu.text == "Quit to title", "campaign pause reads 'Quit to title' (%s)" % pause._menu.text)
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"MENU", 60.0)
	await _until(func() -> bool: return _focus() == title._campaign_item, 10.0)
	var st: Dictionary = game.campaign_status()
	var next_title := str((st["next"] as Dictionary).get("title", ""))
	_check(bool(st["started"]) and int(st["leg"]) == 1 and not game.campaign_active, "quit keeps the journey at leg 1 (%s)" % st["leg"])
	_check(title.view == "title" and _focus() == title._campaign_item, "hub focuses the Campaign item (%s)" % _focus_name())
	_check(title._campaign_item._title_text == "Continue · %s" % next_title, "Campaign item reads 'Continue · %s' (%s)" % [next_title, title._campaign_item._title_text])
	_check(title._new_journey_item.visible, "'Start a new journey' shows")

	# Start a new journey: the confirm dialog, No via Esc, then Yes.
	var confirm: Node = title._confirm
	await _key(KEY_DOWN)
	await _check_focus(title._new_journey_item, "Down: Start a new journey")
	await _key(KEY_ENTER)
	await _until(func() -> bool: return confirm.is_open and _focus() == confirm._no, 2.0)
	_check(confirm.is_open, "Enter opens the confirm dialog")
	_check(_focus() == confirm._no, "confirm focuses No (%s)" % _focus_name())
	await _key(KEY_ESCAPE)
	await _until(func() -> bool: return not confirm.is_open and _focus() == title._new_journey_item, 2.0)
	_check(not confirm.is_open and game.state == game.State.MENU, "Esc closes the dialog, still on the title")
	_check(_focus() == title._new_journey_item, "focus back on Start a new journey (%s)" % _focus_name())
	_check(int(game.campaign_status()["leg"]) == 1, "journey kept at leg 1")
	await _seconds(0.5)
	await _pad(JOY_BUTTON_A)
	await _until(func() -> bool: return confirm.is_open and _focus() == confirm._no, 2.0)
	_check(confirm.is_open and _focus() == confirm._no, "A reopens the dialog on No (%s)" % _focus_name())
	await _key(KEY_RIGHT)
	await _check_focus(confirm._yes, "Right: Yes")
	_mark()
	await _key(KEY_ENTER)
	await _until_state(&"INTRO", 60.0)
	st = game.campaign_status()
	_check(not confirm.is_open, "Yes closes the dialog")
	_check(game.state != game.State.MENU and game.campaign_active, "Yes starts a new journey (state %s)" % (game.State as Dictionary).find_key(game.state))
	_check(int(st["leg"]) == 0 and not bool(st["started"]) and (st["results"] as Dictionary).is_empty(), "journey reset to leg 0, no results (%s)" % st["leg"])


## The autopilot takes the player car for the rest of the run.
func _drive() -> void:
	if stuck:
		return
	var car: Car = game.player_car
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.drive_curve()
	ap.closed = main.map.track.closed
	car.add_child(ap)
	main.autopilot = ap
	Engine.time_scale = LAP_SPEED


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
	var label := ""
	if f.get("text") != null and str(f.get("text")) != "":
		label = str(f.get("text"))
	elif f.get("_title_text") != null:
		label = str(f.get("_title_text"))
	elif f.get("map") is Dictionary:
		label = "card %s" % (f.get("map") as Dictionary).get("id", "")
	return "%s %s" % [f.get_class(), label if label != "" else str(f.name)]


func _check_focus(expected: Control, what: String) -> void:
	await _until(func() -> bool: return _focus() == expected, 1.0)
	_check(_focus() == expected, "%s (%s)" % [what, _focus_name()])


func _card(ta: Node, id: String) -> Control:
	for c: Control in ta.cards:
		if str(c.map.get("id", "")) == id:
			return c
	return null


func _visible_ids(ta: Node) -> Array:
	return ta._visible_cards().map(func(c: Control) -> String: return str(c.map.get("id", "")))


func _is_card(ta: Node) -> bool:
	return ta.cards.any(func(c: Control) -> bool: return c == _focus())


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
	while not stuck and not cond.call() and (Time.get_ticks_msec() - start) / 1000.0 < timeout:
		await process_frame


## The pause menu shows (paused, visible, focus on Resume); otherwise the run is stuck.
func _pause_menu_up(what: String) -> bool:
	var pause: Node = ui.pause_menu
	var up := func() -> bool: return game.paused and pause.is_open and pause.is_visible_in_tree() and _focus() == pause._resume
	await _until(up, 2.0)
	var ok: bool = up.call()
	_check(ok, "%s: menu shows, focus on Resume (paused %s, open %s, visible %s, %s)"
			% [what, game.paused, pause.is_open, pause.is_visible_in_tree(), _focus_name()])
	if not ok:
		stuck = true
	return ok


func _mark() -> void:
	marked = reached.duplicate()


func _until_state(state_name: StringName, timeout: float) -> void:
	var s: int = game.State[state_name]
	var start := Time.get_ticks_msec()
	while int(reached.get(s, 0)) <= int(marked.get(s, 0)):
		if stuck:
			return
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout:
			_check(false, "timed out waiting for %s (state %s)" % [state_name, (game.State as Dictionary).find_key(game.state)])
			stuck = true
			return
		await process_frame
