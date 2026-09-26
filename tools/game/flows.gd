extends SceneTree
## Exercises the game flows the playthrough does not: free roam, pause and resume through
## the UI's input path, a manual car reset, restart during the countdown, launch control on
## the start line, camera cycling, and all three quality presets (FPS measured on the same
## stretch of road). Prints CHECK lines and a final summary; exits non-zero on failures.
##
##   timeout 400 $S --disable-crash-handler --path . -s res://tools/game/flows.gd -- map=hanami

var opts := {"map": "hanami", "out": "/tmp/flows"}
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

	_log("SUMMARY: %d failures" % failures.size())
	for f in failures:
		_log("  FAIL %s" % f)
	quit(1 if failures.size() > 0 else 0)


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
	await RenderingServer.frame_post_draw
	var path := "%s/%s.png" % [opts["out"], name_]
	root.get_texture().get_image().save_png(path)
	_log("SHOT %s" % path)
