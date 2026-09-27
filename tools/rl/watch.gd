extends SceneTree
## The trained driver in the real game, hands off: the title, then a stage started through
## Game.request_start with AutoDrive's auto-drive on (and its ghosts, the training generations,
## racing along) - what a player gets with I / G / V, driven by a harness. A check needs no
## pixels, so it runs headless:
##
##   timeout 900 nice -n 10 $S --headless --disable-crash-handler --audio-driver Dummy --fixed-fps 60 \
##       --path . -s res://tools/rl/watch.gd -- route=hanami cycle=8
##
## Pictures need `--summer-offscreen` instead of `--headless`: stills=<dir> saves a PNG just before
## every camera cut and on the results card, `--write-movie <file>.avi` records footage. Rendered
## runs currently take focus from fullscreen apps (docs/CONTRACTS.md): shoot everything in one run.
##
## Options: route, mode (time_trial | free_roam), ghosts (1: the generations race along), cycle
## (seconds per camera target, 0: stay on the player's car), seconds (limit after the start),
## policy (another driver file), stills.
## Prints WATCH lines: the start, each camera cut, the finish with the stage time, or where the
## car was when time ran out.

var opts := {"route": "hanami", "mode": "time_trial", "ghosts": "1", "cycle": "0", "seconds": "240", "policy": ""}
var game: Node
var main: Node
var clock: float = 0.0
var _shots: int = 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	game = root.get_node("Game")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _process(delta: float) -> bool:
	clock += delta
	return false


func _run() -> void:
	await _until(func() -> bool: return game.state == game.State.MENU, 90.0)
	var ai: Node = main.get_node("AutoDrive") # untyped: AutoDrive needs the Game autoload to compile
	if str(opts["policy"]) != "":
		ai.policy = DrivePolicy.load_file(str(opts["policy"]))
	if ai.policy == null:
		printerr("watch: no driver (%s)" % ai.DRIVER)
		game.request_quit(2)
		return
	ai.auto_drive = true
	ai.ghosts_on = opts["ghosts"] == "1"
	await _seconds(2.0)
	game.request_start(str(opts["route"]), str(opts["mode"]))
	await _until(func() -> bool: return game.state in [game.State.COUNTDOWN, game.State.RACING, game.State.FREE_ROAM], 90.0)
	print("WATCH start route=%s mode=%s policy=%s ghosts=%d" % [opts["route"], opts["mode"], ai.policy.path.get_file(), ai.ghosts.size()])
	var t0 := clock
	var cycle := float(opts["cycle"])
	var next_cut := t0 + cycle
	var done := func() -> bool: return game.state in [game.State.FINISHED, game.State.ARRIVED]
	while clock - t0 < float(opts["seconds"]) and not done.call():
		await process_frame
		if cycle > 0.0 and clock >= next_cut:
			_still("ghost%d" % ai.watching if ai.watching >= 0 else "player")
			ai.watch_next()
			next_cut += cycle
			print("WATCH t=%.0f progress=%.2f kmh=%.0f watching=%d" % [clock - t0, main.session.progress,
					main.car.linear_velocity.length() * 3.6, ai.watching])
	if not done.call():
		print("WATCH timeout after %.0f s: progress %.2f, elapsed %.1f, rescues %d" % [clock - t0,
				main.session.progress, main.session.elapsed, ai.rescues])
	else:
		print("WATCH finish time=%.2f rescues=%d" % [main.session.elapsed, ai.rescues])
		await _seconds(8.5) # the finish beat, slow-motion orbit and results card
		_still("results")
	game.request_quit()


## A PNG of the frame into stills=<dir> (rendered runs only; headless has no pixels).
func _still(label: String) -> void:
	if not opts.has("stills") or DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(str(opts["stills"]))
	var file := "%s/%02d_%s.png" % [opts["stills"], _shots, label]
	root.get_texture().get_image().save_png(file)
	print("WATCH still %s" % file)
	_shots += 1


func _seconds(s: float) -> void:
	var end := clock + s
	while clock < end:
		await process_frame


func _until(ok: Callable, limit: float) -> void:
	var end := clock + limit
	while not ok.call():
		if clock > end:
			printerr("watch: timed out waiting")
			game.request_quit(3)
			return
		await process_frame
