extends SceneTree
## Exercises the game flows the playthrough does not. Prints CHECK lines and a final summary;
## exits non-zero on failures. Headless or windowed (windowed also saves frames to `out`).
##
## flow=core (default): free roam in the world (every gate open), pause and resume through the
## UI's input path, a manual car reset, restart during the countdown, launch control on the
## start line, camera cycling, all three quality presets (FPS measured on the same stretch of
## road), and a Time Trial start on each stage (its route, its grid, gates closed).
##
## flow=campaign: the whole campaign from the title to the finale in one continuous drive. The
## autopilot drives both stages and the liaison; results Continue, the finale and its end card
## are pressed through the UI's input path. Checked on the way: SS1 ends at rest on Hanami's
## finish stop, the results say the stage is complete with the next-stage side panel, Continue
## opens the hanami_branch gate in view and the liaison starts from the exact pose SS1 ended in,
## the road sign HUD, the arrival at rest on Momiji's grid, SS2's start card and countdown on
## the spot, no LOADING and no cover from SS1 to SS2, SS2 at rest on Momiji's finish stop, the
## classification, the title's finished state; then a save resumed at each leg (SS1 grid, the
## liaison at Hanami's finish stop with the gate open, SS2 grid) and quitting mid-liaison.
##
##   timeout 400 $S --disable-crash-handler --path . -s res://tools/game/flows.gd -- map=hanami
##   timeout 900 $S --headless --disable-crash-handler --path . -s res://tools/game/flows.gd -- \
##       flow=campaign speed=3

var opts := {"flow": "core", "map": "hanami", "out": "/tmp/flows", "speed": "3"}
var main: Node
var game: Node
var t0 := 0
var reached: Dictionary = {}
var marked: Dictionary = {}
var notices: Array[String] = []
var failures: Array[String] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	root.size = Vector2i(1920, 1080)
	game = root.get_node("Game")
	game.set_setting("quality", "high")
	game.set_setting("camera", "chase")
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1
		_log("STATE %s" % (game.State as Dictionary).find_key(s)))
	game.notice.connect(func(text: String) -> void:
		notices.append(text)
		_log("NOTICE %s" % text))
	t0 = Time.get_ticks_msec()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_state(&"MENU", 60.0)
	await _seconds(1.0)
	if opts["flow"] == "campaign":
		await _run_campaign()
	else:
		await _run_core()
	_log("SUMMARY: %d failures" % failures.size())
	for f in failures:
		_log("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


func _run_core() -> void:
	# ---------------------------------------------------------------- free roam
	_mark()
	game.request_start(opts["map"], game.MODE_FREE_ROAM)
	await _until_state(&"FREE_ROAM", 60.0)
	_check(game.state == game.State.FREE_ROAM, "free roam reached")
	var car: Car = game.player_car
	_check(car != null and car.controlled_by_player and not car.launch_hold, "player car live in free roam")
	_check(main.map.gates.size() > 0 and _gates_open() == main.map.gates.size(), "free roam opens every gate (%d of %d)" % [_gates_open(), main.map.gates.size()])
	Input.action_press(&"throttle")
	await _seconds(3.0)
	Input.action_release(&"throttle")
	_check(car.speed_kmh > 30.0, "car accelerates under throttle (%.0f km/h)" % car.speed_kmh)

	# camera cycle through the real action
	var cam_before := str(main.chase.mode)
	await _tap(&"camera_next")
	_check(str(main.chase.mode) != cam_before, "camera_next cycles %s -> %s" % [cam_before, main.chase.mode])
	main.chase.set_mode("chase")

	# pause / resume through the UI's pause action
	await _event(&"pause")
	await _seconds(0.4)
	_check(game.paused and paused, "pause action pauses the tree")
	var pm: Control = main.ui.pause_menu
	_check(pm.is_visible_in_tree() and root.gui_get_focus_owner() == pm._resume, "pause menu on screen, focus on Resume")
	var pos_paused := car.global_position
	await _seconds(0.8)
	_check(car.global_position.distance_to(pos_paused) < 0.01, "car frozen while paused")
	await shot("pause")
	await _event(&"pause")
	await _seconds(0.4)
	_check(not game.paused and not paused, "pause action resumes")

	# manual reset: shove the car off the road, press R
	var track: Track = main.map.track
	var i := track.nearest(car.global_position)
	var off := Transform3D(Basis(Vector3.FORWARD, 2.6), car.global_position + track.right(i) * 25.0 + Vector3.UP * 3.0)
	car.reset_to(off)
	await _seconds(0.3)
	await _tap(&"reset_car")
	await _seconds(0.5)
	var j := track.nearest(car.global_position)
	var lat := absf(track.lateral(j, car.global_position))
	_check(lat < track.half_width(j) + 0.5 and car.global_transform.basis.y.y > 0.95, "R puts the car back on the road (lat %.1f m)" % lat)

	# free roam goes anywhere: back on the road halfway round, the route (and R) carry on there
	var session: RaceSession = main.session
	var far_s := track.length * 0.5
	car.reset_to(track.transform_at_progress(far_s, 0.0, 0.3))
	await _seconds(0.6)
	_check(absf(session.progress - 0.5) < 0.02, "free roam picks the route up where the car rejoins (progress %.3f)" % session.progress)
	await _tap(&"reset_car")
	await _seconds(0.5)
	var k := track.nearest(car.global_position)
	var ds := absf(wrapf(track.progress_of(k, car.global_position) - far_s, -track.length * 0.5, track.length * 0.5))
	_check(ds < 20.0, "R in free roam lands on the nearest road (%.0f m along from the rejoin point)" % ds)

	# quality presets: same road stretch, 4 s of autopilot each
	var fps := {}
	for q in ["low", "medium", "high"]:
		game.set_setting("quality", q)
		car.reset_to(track.transform_at_progress(track.length * 0.3, 0.0, 0.3))
		car.controlled_by_player = false
		var ap := Autopilot.new()
		ap.curve = track.to_curve()
		car.add_child(ap)
		await _seconds(1.5)
		var samples: Array[float] = []
		var start := Time.get_ticks_msec()
		while Time.get_ticks_msec() - start < 4000:
			await process_frame
			samples.append(1.0 / maxf(root.get_process_delta_time(), 1e-4))
		samples.sort()
		fps[q] = [samples[samples.size() / 10], samples[samples.size() / 2]]
		_log("QUALITY %s: p10=%.0f median=%.0f msaa=%d scale=%.2f shadow=%s" % [q, fps[q][0], fps[q][1],
				root.msaa_3d, root.scaling_3d_scale, main.map.atmosphere.sun.directional_shadow_max_distance])
		await shot("quality_%s" % q)
		ap.queue_free()
		car.controlled_by_player = true
	_check(root.msaa_3d == Viewport.MSAA_4X and is_equal_approx(root.scaling_3d_scale, 1.0), "high preset restores 4x MSAA, full scale")

	# ---------------------------------------------------------------- restart into time trial countdown
	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	_mark()
	game.request_start(opts["map"], game.MODE_TIME_TRIAL)
	await _until_state(&"COUNTDOWN", 60.0)
	car = game.player_car
	Input.action_press(&"throttle")
	await _seconds(1.2)
	_log("launch control: rpm=%.0f gear=%d speed=%.2f" % [car.rpm, car.gear, car.speed_kmh])
	_check(car.gear == 0 and absf(car.speed_kmh) < 0.5, "held in neutral on the line")
	_check(car.rpm > 4000.0 and car.rpm < 5000.0, "launch control holds ~4600 rpm (%.0f)" % car.rpm)
	Input.action_release(&"throttle")
	# restart in the middle of the countdown: the old countdown must not leak into the new run
	_mark()
	game.request_restart()
	await _until_state(&"COUNTDOWN", 60.0)
	var countdown_at := Time.get_ticks_msec()
	_mark()
	await _until_state(&"RACING", 10.0)
	var took := (Time.get_ticks_msec() - countdown_at) / 1000.0
	_check(took > 2.8 and took < 3.6, "fresh countdown after restart runs its full 3 s (%.2f s)" % took)
	car = game.player_car
	Input.action_press(&"throttle")
	await _seconds(1.5)
	Input.action_release(&"throttle")
	_check(car.gear >= 1 and car.speed_kmh > 15.0, "launch off the line (%.0f km/h, gear %d)" % [car.speed_kmh, car.gear])
	_check(game.session.running, "timer runs after GO")
	await shot("launch")

	# ---------------------------------------------------------------- Time Attack on each stage
	for m: Dictionary in game.MAPS:
		_mark()
		game.request_menu()
		await _until_state(&"MENU", 60.0)
		_mark()
		game.request_start(m["id"], game.MODE_TIME_TRIAL)
		await _until_state(&"COUNTDOWN", 60.0)
		car = game.player_car
		_check(main.map.route_id == m["id"] and _near(car, main.map.spawn, 1.0) and _gates_open() == 0,
				"time trial %s: its route, on its grid (%s), gates closed" % [m["id"], _off(car, main.map.spawn)])
		_mark()
		await _until_state(&"RACING", 10.0)
		_check(game.session.running and game.session.checkpoint_total > 0, "time trial %s: timer runs, %d checkpoints" % [m["id"], game.session.checkpoint_total])
		await shot("time_trial_%s" % m["id"])

	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	_check(Engine.time_scale == 1.0 and not paused, "back on the title with normal time")


# ---------------------------------------------------------------- campaign

func _run_campaign() -> void:
	var ui: CanvasLayer = main.ui
	var legs: Array = game.CAMPAIGN
	_check(not bool(game.campaign_status()["started"]), "fresh profile: campaign not started")
	_mark()
	game.request_campaign(true)
	_check(game.campaign_active, "request_campaign(true) starts the campaign")

	# ---- SS1 on the Hanami grid
	await _until_state(&"INTRO", 60.0)
	_check(game.map_id == legs[0]["map"] and main.map.route_id == legs[0]["map"] and game.campaign_leg == 0,
			"SS1: Hanami route selected (map %s, route %s, leg %d)" % [game.map_id, main.map.route_id, game.campaign_leg])
	_check(_near(game.player_car, main.map.spawn, 1.0), "SS1: car on the Hanami grid (%s)" % _off(game.player_car, main.map.spawn))
	_check(_gates_open() == 0, "SS1: branch gates closed (%d open)" % _gates_open())
	await _seconds(1.6)
	await shot("intro_SS1")
	# From here to SS2's countdown nothing loads and the screen is never covered.
	var loads := int(reached.get(game.State.LOADING, 0))
	var covered := [false]
	var watch_cover := func() -> void: covered[0] = covered[0] or ui.is_screen_covered()
	process_frame.connect(watch_cover)
	await _campaign_stage(ui, legs[0])
	var car: Car = game.player_car
	var stop: Transform3D = main.map.finish_stop
	await _until_rest(car, 20.0)
	_check(_near(car, stop, 4.0), "SS1: the car came to rest at Hanami's finish stop (%s)" % _off(car, stop))
	await _campaign_results(ui, legs[0], legs[2])
	var pose := car.global_transform

	# ---- Continue: the gate opens in view, the liaison drives on from the same spot
	_mark()
	await _event(&"ui_accept")
	await _seconds(1.3)
	var gate: Node3D = main.map.gates.get("%s_branch" % legs[0]["map"])
	_check(gate != null and main.gate_cam.current, "Continue: the camera looks over the car at the hanami_branch gate")
	await shot("gate_opening")
	await _until_state(&"LIAISON", 20.0)
	_check(gate != null and bool(gate.is_open), "the hanami_branch gate is open")
	_check(game.player_car == car and car.global_transform.origin.distance_to(pose.origin) < 0.3
			and car.global_transform.basis.z.dot(pose.basis.z) > 0.995,
			"liaison starts from the pose SS1 ended in (moved %.2f m, same car)" % car.global_transform.origin.distance_to(pose.origin))
	_check(main.map.route_id == "liaison" and game.mode == game.MODE_LIAISON and game.campaign_leg == 1, "liaison route selected (route %s)" % main.map.route_id)
	_check(car.controlled_by_player and ui.liaison_hud.shown and not ui.hud.shown and not game.session.running,
			"liaison: the player drives, road sign HUD, no timer")
	_check(game.session.progress < 0.02, "liaison progress runs from Hanami's finish stop (%.3f)" % game.session.progress)
	var sign_text: String = ui.liaison_hud._code.text + " " + ui.liaison_hud._dest.text
	_check(not sign_text.contains("L1"), "road sign shows no leg code (%s)" % sign_text)
	await _seconds(1.5)
	await shot("liaison_hud")
	await _campaign_pause(ui, legs[1])
	await _campaign_liaison(ui, legs[1])

	# ---- SS2 start card and countdown on the spot
	await _until_state(&"INTRO", 20.0)
	var at_card := car.global_transform.origin
	_check(game.player_car == car and main.map.route_id == legs[2]["map"] and game.campaign_leg == 2, "SS2: Momiji route selected on the same car")
	_check(_near(car, main.map.spawn, 3.0), "SS2: car on Momiji's grid (%s)" % _off(car, main.map.spawn))
	_check(ui.race_intro.card_visible and ui.race_intro._kicker.text.begins_with("SS2"), "SS2 start card up (%s)" % ui.race_intro._kicker.text)
	_check(_gates_open() == 0, "SS2: branch gates closed again (%d open)" % _gates_open())
	await _seconds(1.6)
	await shot("start_card_SS2")
	_mark()
	await _until_state(&"COUNTDOWN", 20.0)
	await _seconds(1.2)
	await shot("countdown_SS2")
	_check(car.global_transform.origin.distance_to(at_card) < 0.5, "SS2 counts down on the spot (moved %.2f m)" % car.global_transform.origin.distance_to(at_card))
	process_frame.disconnect(watch_cover)
	_check(int(reached.get(game.State.LOADING, 0)) == loads and not covered[0],
			"no LOADING and no cover from SS1 to SS2 (%d loads, covered %s)" % [int(reached.get(game.State.LOADING, 0)) - loads, covered[0]])
	await _campaign_stage(ui, legs[2])
	stop = main.map.finish_stop
	await _until_rest(car, 20.0)
	_check(_near(car, stop, 4.0), "SS2: the car came to rest at Momiji's finish stop (%s)" % _off(car, stop))
	await _campaign_results(ui, legs[2], {})

	# ---- finale
	_mark()
	await _event(&"ui_accept")
	await _until_state(&"FINALE", 60.0)
	_check(ui.finale.shown and ui.finale.phase == 1, "finale: classification up")
	var table: Array = game.campaign_classification()
	_check(table.size() == game.RIVALS.size() + 1, "classification has you + %d rivals" % game.RIVALS.size())
	var ordered := true
	for i in range(1, table.size()):
		ordered = ordered and float(table[i]["total"]) >= float(table[i - 1]["total"])
	_check(ordered, "classification sorted by total time")
	await _seconds(5.5)
	await shot("finale_board")
	_check(root.gui_get_focus_owner() == ui.finale._continue, "finale: Continue has focus")
	await _event(&"ui_accept")
	await _seconds(4.5)
	_check(ui.finale.phase == 2, "finale: end card")
	await shot("finale_end")
	_check(root.gui_get_focus_owner() == ui.finale._back, "end card: Back to title has focus")
	_mark()
	await _event(&"ui_accept")
	await _until_state(&"MENU", 60.0)
	var st: Dictionary = game.campaign_status()
	_check(bool(st["finished"]) and not game.campaign_active, "back on the title with the campaign finished")
	await _seconds(2.5)
	await shot("title_finished")
	_check(Engine.time_scale == 1.0 and not paused, "title with normal time, unpaused")

	# ---- resume at each leg (an unfinished save from an earlier session)
	for li in legs.size():
		await _campaign_resume(ui, li)


## A save at leg `li` resumed from the title: SS1 on the Hanami grid, the liaison at Hanami's
## finish stop with the gate open, SS2 on the Momiji grid. The liaison is also quit mid-drive
## through the pause menu: the save stays at the liaison.
func _campaign_resume(ui: CanvasLayer, li: int) -> void:
	var leg: Dictionary = game.CAMPAIGN[li]
	game._campaign = {"leg": li, "results": {"hanami": {"time": 130.0, "medal": "silver"}} if li > 0 else {}, "finished": false}
	_mark()
	game.request_campaign(false)
	await _until_state(&"INTRO", 60.0)
	var car: Car = game.player_car
	var liaison: bool = leg["kind"] == "liaison"
	_check(main.map.route_id == leg["map"] and game.campaign_leg == li, "resume leg %d: route %s" % [li, main.map.route_id])
	var at: Transform3D = main.map.spawn
	if liaison:
		main.map.select_route("hanami")
		at = main.map.finish_stop
		main.map.select_route("liaison")
	_check(_near(car, at, 1.0), "resume leg %d: car at %s (%s)" % [li, "Hanami's finish stop" if liaison else "the grid", _off(car, at)])
	var gate: Node3D = main.map.gates.get("hanami_branch")
	_check(gate != null and bool(gate.is_open) == liaison, "resume leg %d: hanami_branch gate %s" % [li, "open" if liaison else "closed"])
	await _seconds(1.6)
	await shot("resume_%d" % li)
	_mark()
	await _until_state(&"LIAISON" if liaison else &"COUNTDOWN", 20.0)
	if liaison:
		_check(car.controlled_by_player and ui.liaison_hud.shown, "resume liaison: the player drives off")
		Input.action_press(&"throttle")
		await _seconds(2.0)
		Input.action_release(&"throttle")
		_check(car.speed_kmh > 15.0, "resume liaison: the car drives off (%.0f km/h)" % car.speed_kmh)
		await _event(&"pause")
		await _seconds(0.6)
		_mark()
		ui.pause_menu._menu.pressed.emit()
		await _until_state(&"MENU", 60.0)
		_check(not game.campaign_active and int(game.campaign_status()["leg"]) == li,
				"quit mid-liaison keeps the save at leg %d (status %s)" % [li, game.campaign_status()["leg"]])
		await _seconds(1.5)
		await shot("title_in_progress")
		return
	_check(car.launch_hold and game.state == game.State.COUNTDOWN, "resume leg %d: countdown on the grid" % li)
	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	_check(int(game.campaign_status()["leg"]) == li, "quit keeps the save at leg %d" % li)


func _campaign_stage(ui: CanvasLayer, leg: Dictionary) -> void:
	await _until(func() -> bool: return game.state == game.State.RACING, 30.0)
	await _campaign_pause(ui, leg)
	var result := {}
	var grab := func(r: Dictionary) -> void: result.merge(r, true)
	game.race_finished.connect(grab)
	_drive()
	_mark()
	var start := Time.get_ticks_msec()
	while game.state == game.State.RACING and Time.get_ticks_msec() - start < 400000:
		await process_frame
	Engine.time_scale = 1.0
	game.race_finished.disconnect(grab)
	_check(game.state == game.State.FINISHED, "%s: stage finished" % leg["code"])
	_check(bool(result.get("campaign", false)) and int(result.get("standing", 0)) >= 1,
			"%s: campaign result, P%d of %d, %s %s" % [leg["code"], result.get("standing", 0), result.get("field", 0),
			game.format_time(float(result.get("time", INF))), result.get("medal", "")])


## The results card of a campaign stage: stage complete, Continue focused, the next-stage sign.
func _campaign_results(ui: CanvasLayer, leg: Dictionary, next: Dictionary) -> void:
	var res: Control = ui.results
	await _until(func() -> bool: return root.gui_get_focus_owner() == res._continue, 15.0)
	await _seconds(1.5)
	await shot("results_%s" % leg["code"])
	_check(res._continue.visible and not res._next.visible and res._menu.text == "Quit to title",
			"%s: results show Continue / Retry stage / Quit to title" % leg["code"])
	_check(str(res._kind_label.text).contains("STAGE COMPLETE"), "%s: results say the stage is complete (%s)" % [leg["code"], res._kind_label.text])
	_check(root.gui_get_focus_owner() == res._continue, "%s: Continue has focus" % leg["code"])
	var want := str(next.get("title", "Rally classification"))
	_check(res._next_sign.visible and str(res._next_name.text) == want,
			"%s: side panel says what comes next (%s · %s · %s)" % [leg["code"], res._next_kicker.text, res._next_name.text, res._next_line.text])


func _campaign_liaison(ui: CanvasLayer, leg: Dictionary) -> void:
	var car: Car = game.player_car
	var left0: float = game.session.distance_left
	_drive()
	_mark()
	var start := Time.get_ticks_msec()
	while game.state == game.State.LIAISON and Time.get_ticks_msec() - start < 400000:
		await process_frame
	var arrived_ms := Time.get_ticks_msec()
	Engine.time_scale = 1.0
	_check(game.state == game.State.ARRIVED, "%s: arrived at Momiji's grid (%.0f m driven)" % [leg["code"], left0 - float(game.session.distance_left)])
	_check(int(game.campaign_status()["leg"]) > game.campaign_leg, "arrival saves the next leg")
	await _seconds(1.4)
	await shot("arrival")
	while game.state == game.State.ARRIVED and car.speed_kmh >= 1.0:
		await process_frame
	var rest_s := (Time.get_ticks_msec() - arrived_ms) / 1000.0
	var arrival: Transform3D = main.map.arrival
	_check(car.speed_kmh < 1.0 and _near(car, arrival, 3.0),
			"arrival stop: %.1f km/h, %s from the grid, at rest by %.1f s into the arrival beat" % [car.speed_kmh, _off(car, arrival), rest_s])


func _near(car: Car, xf: Transform3D, metres: float) -> bool:
	return car != null and Vector2(car.global_position.x - xf.origin.x, car.global_position.z - xf.origin.z).length() < metres


func _off(car: Car, xf: Transform3D) -> String:
	if car == null:
		return "no car"
	return "%.1f m" % Vector2(car.global_position.x - xf.origin.x, car.global_position.z - xf.origin.z).length()


func _gates_open() -> int:
	var n := 0
	for id: String in main.map.gates:
		n += int(bool(main.map.gates[id].is_open))
	return n


func _until_rest(car: Car, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while car.linear_velocity.length() > 0.3 and (Time.get_ticks_msec() - start) / 1000.0 < timeout:
		await process_frame


func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call() and (Time.get_ticks_msec() - start) / 1000.0 < timeout:
		await process_frame


## Opens the pause menu through the pause action and checks the campaign items.
func _campaign_pause(ui: CanvasLayer, leg: Dictionary) -> void:
	await _event(&"pause")
	await _seconds(0.6)
	var pm: Control = ui.pause_menu
	var stage: bool = leg["kind"] == "stage"
	_check(game.paused and pm.is_visible_in_tree() and root.gui_get_focus_owner() == pm._resume
			and pm._restart.visible == stage and (not stage or pm._restart.text == "Retry stage")
			and pm._menu.text == "Quit to title",
			"%s: campaign pause menu on screen, focus on Resume (%s)" % [leg["code"], "retry" if stage else "no retry"])
	await shot("pause_%s" % leg["code"])
	await _event(&"pause")
	await _seconds(0.3)
	_check(not game.paused, "%s: resumed" % leg["code"])


## The autopilot takes the player car for the rest of the leg (Main drops it on arrival).
func _drive() -> void:
	var car: Car = game.player_car
	car.controlled_by_player = false
	var ap := Autopilot.new()
	ap.curve = main.drive_curve()
	ap.closed = main.map.track.closed
	car.add_child(ap)
	main.autopilot = ap
	Engine.time_scale = float(opts["speed"])


func _check(ok: bool, what: String) -> void:
	_log("CHECK %s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _log(msg: String) -> void:
	print("[%7.2f] %s" % [(Time.get_ticks_msec() - t0) / 1000.0, msg])


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


## Presses at the start of a process frame (before node _process), the way OS input
## arrives. Timer callbacks run after _process, so a press made there would stamp a
## process frame that _process-polling nodes (the camera) have already finished.
func _tap(action: StringName) -> void:
	await process_frame
	Input.action_press(action)
	await physics_frame
	await physics_frame
	await process_frame
	Input.action_release(action)


## A real input event, so _unhandled_input handlers (the UI's pause) see it.
func _event(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
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


func shot(name_: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [opts["out"], name_]
	root.get_texture().get_image().save_png(path)
	_log("SHOT %s" % path)
