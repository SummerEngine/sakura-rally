extends SceneTree
## Exercises the game flows the playthrough does not. Prints CHECK lines and a final summary;
## exits non-zero on failures. Headless or windowed (windowed also saves frames to `out`).
##
## flow=core (default): free roam in the world (every gate open), pause and resume through the
## UI's input path, a manual car reset, the other roads of the world in free roam (the branch
## and the Momiji loop: no off-route notice, R lands on the road the car is beside), restart
## during the countdown, launch control on the start line, camera cycling, all three quality
## presets (FPS measured on the same stretch of each stage, both stages in one run), and a Time
## Trial start on each stage (its route, its grid, gates closed).
##
## flow=campaign: the whole campaign from the title to the finale in one continuous drive. The
## autopilot drives both stages and the liaison; results Continue, Start on the arrival card, the
## finale and its end card are pressed through the UI's input path. Checked on the way: SS1 ends
## at rest on Hanami's finish stop, the results say the stage is complete with the next-stage side
## panel, Continue opens the hanami_branch gate in view and the liaison starts from the exact pose
## SS1 ended in, the road sign HUD with the stages' tachometer in the same place, the arrival at
## rest on Momiji's grid, the arrival card waiting for Start (SS2 never starts on its own), SS2's
## start card and countdown on the spot, no LOADING and no cover from SS1 to SS2, SS2 at rest on
## Momiji's finish stop, the classification, the title's finished state; then a save resumed at
## each leg (SS1 grid, the liaison at Hanami's finish stop with the gate open and R on the branch
## landing on the branch, SS2 grid), quitting mid-liaison, and Esc on the arrival card (back to
## the title with the save at SS2).
##
## flow=race: a race on `map`. The grid: the player's car in the last slot behind the six rivals
## (slowest on pole, each in its own car and colours with a RaceBot), every car colliding with the
## others and held through the countdown, the gates closed. The rivals drive off at GO; the race
## HUD shows the position card and the lap. A RaceBot at gold pace drives the player's car
## through both laps: the position improves from last, every checkpoint reaches the HUD, the lap
## counter turns to the final lap. The finish: the results say RACE, stamp the position and list
## the classification in running order; the finishers come to rest one behind the other past the
## line in finishing order, and the rivals still racing fill in their rows as they finish. Pause
## says RACE; Retry builds a fresh grid; the title clears every car of the race. Rendered, it also
## logs frame times for 10 s at normal speed behind the pack and saves frames of the first
## overtakes and of the first real bump.
##
##   timeout 400 $S --headless --disable-crash-handler --path . -s res://tools/game/flows.gd -- map=hanami
##   timeout 900 $S --headless --disable-crash-handler --path . -s res://tools/game/flows.gd -- \
##       flow=campaign speed=3
##   timeout 900 $S --headless --disable-crash-handler --path . -s res://tools/game/flows.gd -- \
##       flow=race map=hanami speed=3

var opts := {"flow": "core", "map": "hanami", "out": "/tmp/flows", "speed": "3"}
var main: Node
var game: Node
var t0 := 0
var reached: Dictionary = {}
var marked: Dictionary = {}
var notices: Array[String] = []
var failures: Array[String] = []
## Screen rect of the stage HUD's tachometer while SS1 runs (the liaison's must match it).
var race_tach := Rect2()


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
	elif opts["flow"] == "race":
		await _run_race()
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

	# every road of the world is a road in free roam: parked on the branch or the Momiji loop,
	# no off-route notice; R from beside it lands back on that road, not on the Hanami loop
	for spot: Array in [["liaison", 0.5], ["liaison", 0.8], ["momiji", 0.3], ["momiji", 0.7]]:
		await _roam_road_check(car, spot[0], spot[1])

	# quality presets: the same stretch of each stage (free roam drives every road), 4 s of
	# autopilot each
	for id: String in ["hanami", "momiji"]:
		var stage: Track = main.map.routes[id]["track"]
		for q in ["low", "medium", "high"]:
			game.set_setting("quality", q)
			car.reset_to(stage.transform_at_progress(stage.length * 0.3, 0.0, 0.3))
			car.controlled_by_player = false
			var ap := Autopilot.new()
			ap.curve = stage.to_curve()
			car.add_child(ap)
			await _seconds(1.5)
			var samples: Array[float] = []
			var start := Time.get_ticks_msec()
			while Time.get_ticks_msec() - start < 4000:
				await process_frame
				samples.append(1.0 / maxf(root.get_process_delta_time(), 1e-4))
			samples.sort()
			_log("QUALITY %s %s: p10=%.0f median=%.0f msaa=%d scale=%.2f shadow=%s" % [id, q,
					samples[samples.size() / 10], samples[samples.size() / 2], root.msaa_3d,
					root.scaling_3d_scale, main.map.atmosphere.sun.directional_shadow_max_distance])
			await shot("quality_%s_%s" % [id, q])
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


# ---------------------------------------------------------------- race

func _run_race() -> void:
	var ui: CanvasLayer = main.ui
	var route := str(opts["map"])
	_mark()
	game.request_start(route, game.MODE_RACE)
	await _until_state(&"INTRO", 60.0)
	var car: Car = game.player_car
	var rivals: Array[Car] = main.rivals
	_check(game.mode == game.MODE_RACE and game.race == main.race and main.race != null and rivals.size() == game.RIVALS.size(),
			"race: %d rivals on the grid, a RaceField" % rivals.size())
	_check(_near(car, main._grid_slot(rivals.size()), 0.5), "race: the player's car in the last slot (%s)" % _off(car, main._grid_slot(rivals.size())))
	var on_slots := true
	var slow_first := true
	var targets: Dictionary = {}
	for g in rivals.size():
		on_slots = on_slots and _near(rivals[g], main._grid_slot(g), 0.5)
		var entrant: RaceField.Entrant = main.race.entrants[g + 1]
		var rival := _rival(str(entrant.info["name"]))
		targets[entrant.info["name"]] = game.rival_lap_time(rival, route)
		if g > 0:
			slow_first = slow_first and float(targets[entrant.info["name"]]) <= float(targets[main.race.entrants[g].info["name"]])
		_check(rivals[g].get_node_or_null(^"RaceBot") is RaceBot and rivals[g].has_node(^"NameTag") and not rivals[g].controlled_by_player,
				"race: %s on slot %d, lap target %s, a RaceBot and a name tag" % [entrant.info["name"], g, game.format_time(targets[entrant.info["name"]])])
	_check(on_slots and slow_first, "race: rivals on their slots, slowest on pole")
	var all: Array[Car] = [car]
	all.append_array(rivals)
	var contacts := true
	for c in all:
		contacts = contacts and c.car_contacts and c.launch_hold
	_check(contacts, "race: every car collides with the others and is held on the grid")
	_check(_gates_open() == 0, "race: branch gates closed (%d open)" % _gates_open())
	var grid_pos: Array[Vector3] = []
	for c in all:
		grid_pos.append(c.global_position)
	await _seconds(1.6)
	await shot("race_intro")
	_mark()
	await _until_state(&"COUNTDOWN", 20.0)
	await _seconds(1.5)
	var held := true
	for k in all.size():
		held = held and all[k].global_position.distance_to(grid_pos[k]) < 0.5
	_check(held, "race: every car held through the countdown")
	await shot("race_countdown")
	_mark()
	await _until_state(&"RACING", 10.0)
	await _seconds(0.5)
	var hud: Control = ui.hud
	_check(hud.shown and hud._tr.visible and hud._pos_value.text == str(all.size()) and hud._best_label.text == "LAP 1 / %d" % game.RACE_LAPS,
			"race HUD: position %s%s, %s" % [hud._pos_value.text, hud._pos_of.text, hud._best_label.text])
	await _event(&"pause")
	await _seconds(0.5)
	var pm: Control = ui.pause_menu
	_check(game.paused and str(pm._sub.text).ends_with("RACE") and pm._restart.visible, "race: pause menu (%s)" % pm._sub.text)
	await _event(&"pause")
	await _seconds(5.3)
	var moved := 0
	for g in rivals.size():
		moved += int(rivals[g].global_position.distance_to(grid_pos[g + 1]) > 30.0)
	_check(moved == rivals.size(), "race: the rivals drove off at GO (%d of %d beyond 30 m)" % [moved, rivals.size()])
	await shot("race_start")

	# A RaceBot at gold pace drives the player's car to the flag.
	var cps: Array[float] = []
	var grab_cp := func(_i: int, _t: int, _s: float, interval: float) -> void: cps.append(interval)
	game.checkpoint_passed.connect(grab_cp)
	var result := {}
	var grab := func(r: Dictionary) -> void: result.merge(r, true)
	game.race_finished.connect(grab)
	var gold := float((game.get_map(route)["medals"] as Dictionary)["gold"])
	var driver := RaceBot.new()
	driver.name = "RaceBot"
	driver.track = main.map.track
	driver.pace = RaceBot.pace_for_lap(route, gold, str(game.current_car()["id"]))
	driver.field = (rivals[0].get_node(^"RaceBot") as RaceBot).field
	driver.phase = rivals.size() % DriveHands.DECISION_TICKS
	car.controlled_by_player = false
	car.add_child(driver)
	var bumps: Array[float] = []
	var grab_bump := func(strength: float, _p: Vector3, _o: Car) -> void: bumps.append(strength)
	car.bumped.connect(grab_bump)
	if DisplayServer.get_name() != "headless":
		# Rendered: frame times for 10 s at normal speed, the whole field in view ahead.
		var frames: Array[float] = []
		var t0 := Time.get_ticks_usec()
		var last := t0
		while Time.get_ticks_usec() - t0 < 10000000:
			await process_frame
			var now := Time.get_ticks_usec()
			frames.append((now - last) / 1000.0)
			last = now
		frames.sort()
		_log("race: frame time over 10 s behind the pack at %s: median %.1f ms, 95th percentile %.1f ms, worst %.1f ms (%d frames)"
				% [str(root.size), frames[int(frames.size() * 0.5)], frames[int(frames.size() * 0.95)], frames.back(), frames.size()])
	Engine.time_scale = float(opts["speed"])
	var best_pos := all.size()
	var last_pos := all.size()
	var pass_shots := 0
	var bump_shot := false
	var final_lap := false
	var start := Time.get_ticks_msec()
	while game.state == game.State.RACING and Time.get_ticks_msec() - start < 600000:
		var p: int = main.race.player_position()
		best_pos = mini(best_pos, p)
		final_lap = final_lap or hud._best_label.text == "FINAL LAP"
		if p < last_pos and pass_shots < 3:
			pass_shots += 1
			await shot("race_pass_%d" % pass_shots)
		last_pos = p
		if not bump_shot and not bumps.is_empty() and bumps.max() >= 0.2:
			bump_shot = true
			await shot("race_bump")
		await process_frame
	game.checkpoint_passed.disconnect(grab_cp)
	game.race_finished.disconnect(grab)
	car.bumped.disconnect(grab_bump)
	_log("race: the player's car was bumped %d times (strongest %.2f)" % [bumps.size(), bumps.max() if not bumps.is_empty() else 0.0])
	_check(game.state == game.State.FINISHED, "race: the player finished (%s)" % game.format_time(float(result.get("time", INF))))
	_check(best_pos < all.size(), "race: the player passed rivals (best P%d)" % best_pos)
	_check(final_lap, "race: the lap counter reached FINAL LAP")
	var n_cp: int = game.RACE_LAPS * main.race.checkpoints.size() - 1
	var known := 0
	for v in cps:
		known += int(not is_nan(v))
	_check(cps.size() == n_cp and known * 2 >= n_cp, "race: %d checkpoints reached the HUD (%d of %d with an interval)" % [cps.size(), known, n_cp])
	var rows: Array = result.get("classification", [])
	var pos := int(result.get("position", 0))
	var ordered := rows.size() == all.size()
	for k in range(1, rows.size()):
		var a: Dictionary = rows[k - 1]
		var b: Dictionary = rows[k]
		ordered = ordered and (bool(a["finished"]) or not bool(b["finished"])) \
				and (not bool(b["finished"]) or float(a["time"]) <= float(b["time"]))
	_check(bool(result.get("race", false)) and pos >= 1 and pos <= all.size() and int(result.get("field", 0)) == all.size() and ordered
			and bool((rows[pos - 1] as Dictionary)["player"]) and (result.get("laps", []) as Array).size() == game.RACE_LAPS,
			"race result: P%d of %d, laps %s, best lap %s, classification in order" % [pos, int(result.get("field", 0)),
			str(result.get("laps", [])), game.format_time(float(result.get("best_lap", INF)))])
	_check(not bool(result.get("is_record", false)) and str(result.get("medal", "")) == "", "race: no record, no medal")
	Engine.time_scale = 1.0
	var res: Control = ui.results
	await _until(func() -> bool: return root.gui_get_focus_owner() == res._retry, 15.0)
	_check(str(res._kind_label.text).begins_with("RACE") and res._hanko.visible and str(res._hanko.text) == "%d位" % pos
			and str(res._position_value.text) == "P%d of %d" % [pos, all.size()] and res._next.visible and not res._continue.visible,
			"race results: %s, seal %s, %s, Retry focused" % [res._kind_label.text, res._hanko.text, res._position_value.text])
	await _seconds(1.5)
	await shot("race_results")
	await _until_rest(car, 20.0)
	_check(_near(car, main._parc_slot(pos), 4.0), "race: the player's car came to rest at its place past the line (%s)" % _off(car, main._parc_slot(pos)))

	# The rivals still racing finish; their rows fill in and they stop in finishing order.
	Engine.time_scale = float(opts["speed"])
	start = Time.get_ticks_msec()
	while main.race.finishers < all.size() and Time.get_ticks_msec() - start < 240000:
		await process_frame
	await _seconds(8.0)
	Engine.time_scale = 1.0
	var parked := 0
	for e: RaceField.Entrant in main.race.order:
		parked += int(e.finished and _near(e.car, main._parc_slot(e.position), 4.0) and e.car.linear_velocity.length() < 0.5)
		var laps := PackedStringArray()
		for lt in e.lap_times:
			laps.append(game.format_time(lt))
		_log("RACE %d. %s  %s  laps %s  (target lap %s)" % [e.position, e.info["name"], game.format_time(e.time),
				", ".join(laps), game.format_time(float(targets.get(e.info["name"], NAN)))])
	var dashes := 0
	for ch in res._splits_box.get_children():
		dashes += int(ch is Label and (ch as Label).text == "—")
	_check(main.race.finishers == all.size() and dashes == 0, "race: every car finished and the classification filled in (%d finishers, %d open rows)"
			% [main.race.finishers, dashes])
	_check(parked == all.size(), "race: all %d finishers at rest one behind the other past the line (%d parked)" % [all.size(), parked])
	await shot("race_parc")

	# Retry: a fresh grid.
	var old_rivals := rivals.duplicate()
	_mark()
	await _event(&"ui_accept")
	await _until_state(&"INTRO", 60.0)
	var fresh: bool = main.rivals.size() == game.RIVALS.size() and main.race.elapsed == 0.0 and main.race.finishers == 0
	for r in old_rivals:
		fresh = fresh and not is_instance_valid(r)
	_check(fresh and _near(game.player_car, main._grid_slot(game.RIVALS.size()), 0.5), "race: Retry builds a fresh grid")
	_mark()
	game.request_menu()
	await _until_state(&"MENU", 60.0)
	await process_frame
	_check(main.rivals.is_empty() and main.race == null and game.race == null and get_nodes_in_group(&"race_rival").is_empty(),
			"race: the title clears every car of the race")
	_check(Engine.time_scale == 1.0 and not paused, "back on the title with normal time")


func _rival(name_: String) -> Dictionary:
	for r: Dictionary in game.RIVALS:
		if r["name"] == name_:
			return r
	return {}


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

	# ---- Start on the arrival card: SS2's start card and countdown on the spot
	_mark()
	await _event(&"ui_accept")
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
	await _campaign_arrival_quit(ui)


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
		var lia: Track = main.map.track
		var off := lia.transform_at_abs(lia.length * 0.5, 14.0, 0.0)
		car.place_at_rest(off)
		await _seconds(0.5)
		await _tap(&"reset_car")
		await _seconds(0.5)
		var hit := _road_at(car.global_position)
		_check(hit[0] == "liaison" and absf(hit[1] - lia.length * 0.5) < 20.0 and off.origin.distance_to(car.global_position) < 25.0,
				"R beside the branch lands on the branch (%s s=%.0f, moved %.1f m)" % [hit[0], hit[1], off.origin.distance_to(car.global_position)])
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


## The liaison resumed from the title and driven in to Momiji's grid from 120 m out: Esc on the
## arrival card goes back to the title, and the save stands at SS2.
func _campaign_arrival_quit(ui: CanvasLayer) -> void:
	game._campaign = {"leg": 1, "results": {"hanami": {"time": 130.0, "medal": "silver"}}, "finished": false}
	_mark()
	game.request_campaign(false)
	await _until_state(&"LIAISON", 60.0)
	var car: Car = game.player_car
	car.place_at_rest(main.map.track.transform_at_abs(main.map.arrival_progress - 120.0))
	await _seconds(0.3)
	_mark()
	_drive()
	await _until_state(&"ARRIVED", 60.0)
	Engine.time_scale = 1.0
	await _until(func() -> bool: return root.gui_get_focus_owner() == ui.arrival._start, 15.0)
	_mark()
	await _event(&"ui_cancel")
	await _until_state(&"MENU", 60.0)
	_check(reached.get(game.State.INTRO, 0) == marked.get(game.State.INTRO, 0) and not game.campaign_active
			and int(game.campaign_status()["leg"]) == 2,
			"Esc on the arrival card: back on the title, SS2 not started, the save at SS2 (leg %s)" % game.campaign_status()["leg"])


func _campaign_stage(ui: CanvasLayer, leg: Dictionary) -> void:
	await _until(func() -> bool: return game.state == game.State.RACING, 30.0)
	race_tach = ui.hud._tach.get_global_rect()
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
	var gauge_checked := false
	while game.state == game.State.LIAISON and Time.get_ticks_msec() - start < 400000:
		if not gauge_checked and float(game.session.distance_left) < left0 * 0.5:
			gauge_checked = true
			var tach: Control = ui.liaison_hud._tach
			_check(tach.is_visible_in_tree() and tach.get_global_rect().is_equal_approx(race_tach) and tach.speed > 5.0,
					"liaison HUD: the stages' tachometer in the same place %s, live (gear %d, %.0f rpm, %.0f km/h)"
					% [tach.get_global_rect(), tach.gear, tach.rpm, tach.speed])
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
	# The card waits for the player: SS2 never starts on its own (it used to after 2.6 s, or once the
	# car was at rest, 10.6 s at most).
	var arr: Control = ui.arrival
	while game.state == game.State.ARRIVED and Time.get_ticks_msec() - arrived_ms < 11000:
		await process_frame
	_check(game.state == game.State.ARRIVED and root.gui_get_focus_owner() == arr._start and arr._quit.is_visible_in_tree(),
			"arrival card waits for the player after %.0f s: '%s' focused, '%s' beside it"
			% [(Time.get_ticks_msec() - arrived_ms) / 1000.0, arr._start.text, arr._quit.text])
	await shot("arrival_prompt")


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


## Free roam on another route's road (`frac` of its length): parked 4 s without the off-route
## notice, then R from 14 m beside the road lands on that road near the same spot.
func _roam_road_check(car: Car, route: String, frac: float) -> void:
	var t: Track = main.map.routes[route]["track"]
	var s := t.length * frac
	car.place_at_rest(t.transform_at_abs(s, 0.0, 0.0))
	var before := notices.size()
	await _seconds(4.5)
	_check(not notices.slice(before).has("Off the route — press R to reset"),
			"free roam: parked on the %s road (s=%.0f), no off-route notice" % [route, s])
	var off := t.transform_at_abs(s, 14.0, 0.0)
	car.place_at_rest(off)
	await _seconds(0.5)
	await _tap(&"reset_car")
	await _seconds(0.5)
	var hit := _road_at(car.global_position)
	var moved := off.origin.distance_to(car.global_position)
	_check(hit[0] == route and absf(hit[1] - s) < 20.0 and moved < 25.0,
			"free roam: R beside the %s road lands on it (%s s=%.0f, moved %.1f m)" % [route, hit[0], hit[1], moved])


## The route whose road is nearest to pos, and the distance along it: [id, s].
func _road_at(pos: Vector3) -> Array:
	var best: Array = ["", 0.0]
	var best_d := INF
	for id: String in main.map.routes:
		var t: Track = main.map.routes[id]["track"]
		var j := t.nearest(pos)
		var d := pos.distance_to(t.point(j))
		if d < best_d:
			best_d = d
			best = [id, t.dist(j)]
	return best


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
