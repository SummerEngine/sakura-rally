extends SceneTree
## Exercises the game flows the playthrough does not. Prints CHECK lines and a final summary;
## exits non-zero on failures. Headless or windowed (windowed also saves frames to `out`).
##
## flow=core (default): free roam, pause and resume through the UI's input path, a manual car
## reset, restart during the countdown, launch control on the start line, camera cycling, and
## all three quality presets (FPS measured on the same stretch of road).
##
## flow=campaign: the whole campaign from the title to the finale and back. The autopilot
## drives both stages and the liaison; results Continue, the finale and its end card are
## pressed through the UI's input path. On the way: the pause menu of a stage and of the
## liaison, quitting mid-liaison and resuming at the start of that leg, the arrival stop, the
## classification, and the title's finished state.
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

	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	_check(Engine.time_scale == 1.0 and not paused, "back on the title with normal time")


# ---------------------------------------------------------------- campaign

func _run_campaign() -> void:
	var ui: CanvasLayer = main.ui
	_check(not bool(game.campaign_status()["started"]), "fresh profile: campaign not started")
	_mark()
	game.request_campaign(true)
	_check(game.campaign_active, "request_campaign(true) starts the campaign")
	var legs: Array = game.CAMPAIGN
	var resumed := false
	var li := 0
	while li < legs.size():
		var leg: Dictionary = legs[li]
		await _until_state(&"JOURNEY", 60.0)
		_check(game.state == game.State.JOURNEY and ui.journey.shown, "%s: journey map up" % leg["code"])
		_check(int(game.campaign_status()["leg"]) == li, "%s: campaign status points at leg %d" % [leg["code"], li])
		await _seconds(1.4)
		await shot("journey_%d_travel%s" % [li, "_resumed" if resumed else ""])
		_check(ui.journey.traveling or li == 0, "%s: the car marker travels on the map" % leg["code"])
		_mark()
		await _until_state(&"INTRO", 60.0)
		_check(game.map_id == leg["map"] and game.campaign_leg == li, "%s: leg %s loads (map %s)" % [leg["code"], li, game.map_id])
		await _seconds(1.6)
		await shot("intro_%d" % li)
		if leg["kind"] == "stage":
			await _campaign_stage(ui, leg)
		else:
			if not resumed:
				# Quit to the title mid-liaison: progress stays at the start of this leg.
				await _until_state(&"LIAISON", 20.0)
				await _campaign_pause(ui, leg)
				_mark()
				await _event(&"pause")
				await _seconds(0.6)
				ui.pause_menu._menu.pressed.emit()
				await _until_state(&"MENU", 60.0)
				_check(not game.campaign_active and int(game.campaign_status()["leg"]) == li,
						"quit mid-liaison keeps the save at leg %d (status %s)" % [li, game.campaign_status()["leg"]])
				await _seconds(1.0)
				await shot("title_in_progress")
				_mark()
				game.request_campaign(false)
				resumed = true
				continue
			await _campaign_liaison(ui, leg)
		li += 1
	# After the last stage: the marker drives to the goal, then the finale.
	await _until_state(&"JOURNEY", 60.0)
	await _seconds(1.4)
	await shot("journey_goal")
	_mark()
	await _until_state(&"FINALE", 60.0)
	_check(ui.finale.shown and ui.finale.phase == 1, "finale: classification up")
	var table: Array = game.campaign_classification()
	_check(table.size() == game.RIVALS.size() + 1, "classification has you + %d rivals" % game.RIVALS.size())
	var ordered := true
	for i in range(1, table.size()):
		ordered = ordered and float(table[i]["total"]) >= float(table[i - 1]["total"])
	_check(ordered, "classification sorted by total time")
	await _seconds(2.0)
	await shot("finale_board_a")
	await _seconds(3.5)
	await shot("finale_board")
	_check(root.gui_get_focus_owner() == ui.finale._continue, "finale: Continue has focus")
	await _event(&"ui_accept")
	await _seconds(1.0)
	await shot("finale_end_a")
	await _seconds(3.5)
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


func _campaign_stage(ui: CanvasLayer, leg: Dictionary) -> void:
	await _until_state(&"COUNTDOWN", 20.0)
	await _until_state(&"RACING", 10.0)
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
	await _seconds(5.5)
	await shot("results_%s" % leg["code"])
	_check(ui.results._continue.visible and not ui.results._next.visible and ui.results._menu.text == "Quit to title",
			"%s: results show Continue / Retry stage / Quit to title" % leg["code"])
	_check(root.gui_get_focus_owner() == ui.results._continue, "%s: Continue has focus" % leg["code"])
	_mark()
	await _event(&"ui_accept")


func _campaign_liaison(ui: CanvasLayer, leg: Dictionary) -> void:
	await _until_state(&"LIAISON", 20.0)
	var car: Car = game.player_car
	_check(car.controlled_by_player and car.speed_kmh > 10.0, "%s: handed over rolling (%.0f km/h)" % [leg["code"], car.speed_kmh])
	_check(ui.liaison_hud.shown and not ui.hud.shown and not game.session.running, "%s: calm HUD, no timer" % leg["code"])
	await _seconds(1.5)
	await shot("liaison_hud")
	var left0: float = game.session.distance_left
	_drive()
	_mark()
	var start := Time.get_ticks_msec()
	while game.state == game.State.LIAISON and Time.get_ticks_msec() - start < 400000:
		await process_frame
	var arrived_ms := Time.get_ticks_msec()
	Engine.time_scale = 1.0
	_check(game.state == game.State.ARRIVED, "%s: arrived (%.0f m driven)" % [leg["code"], left0 - float(game.session.distance_left)])
	_check(int(game.campaign_status()["leg"]) > game.campaign_leg, "arrival saves the next leg")
	await _seconds(1.2)
	await shot("arrival_a")
	await _seconds(1.6)
	await shot("arrival")
	# The car rolls in under the arrival card; it has to be at rest at the time control before
	# the beat hands over to the journey map.
	while game.state == game.State.ARRIVED and car.speed_kmh >= 3.0:
		await process_frame
	var rest_s := (Time.get_ticks_msec() - arrived_ms) / 1000.0
	var arrival_d := Vector2(car.global_position.x - main.map.arrival.origin.x, car.global_position.z - main.map.arrival.origin.z).length()
	_check(game.state == game.State.ARRIVED and car.speed_kmh < 3.0 and arrival_d < main.map.arrival_radius + 6.0,
			"arrival stop: %.1f km/h, %.1f m from the time control, at rest by %.1f s into the arrival beat" % [car.speed_kmh, arrival_d, rest_s])
	_mark()


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
