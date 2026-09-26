extends SceneTree
## One timed lap of a real map by the keyboard bot or the analog autopilot, for tuning and for
## checking the chase camera. Headless it prints the lap metrics; windowed it renders through a
## ChaseCamera and saves frames whenever the car slides.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 600 $S --disable-crash-handler --fixed-fps 60 --path . -s res://tools/physics/map_drive.gd -- \
##       map=hanami car=sakura bot=keyboard out=/tmp/map_drive slide_deg=10 shots=8
##
## map: hanami | momiji. car: an id of Game.CARS. bot: keyboard | analog.
## ap.<property>=<float> overrides a driver export for tuning (e.g. ap.corner_grip=0.8).
## Windowed runs save <out>/<map>_<car>_<bot>_NN.png (a frame when the body slip first passes
## slide_deg, then at most every 1.5 s, `shots` frames in total).

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")

var opts := {"map": "hanami", "car": "sakura", "bot": "keyboard", "out": "/tmp/map_drive", "slide_deg": "10", "shots": "8"}
var _shots_left := 0
var _next_shot := 0.0
var _pending_shot := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var headless := DisplayServer.get_name() == "headless"
	var map: MapWorld = await MapLapRunner.build_map(self, opts["map"])
	var car := (load(str(game.get_car(opts["car"])["scene"])) as PackedScene).instantiate() as Car
	root.add_child(car)
	var runner := MapLapRunner.new()
	for key in opts:
		if str(key).begins_with("ap."):
			runner.driver_props[str(key).substr(3)] = float(opts[key])
	if not headless:
		root.size = Vector2i(1600, 900)
		DirAccess.make_dir_recursive_absolute(opts["out"])
		CarLook.apply(car)
		var cam := ChaseCamera.new()
		cam.player_camera = false
		cam.target = car
		root.add_child(cam)
		cam.make_current()
		_shots_left = int(opts["shots"])
		runner.on_tick = _watch
	await physics_frame
	var r: Dictionary = await runner.lap(self, map, car, opts["bot"] == "keyboard")
	print("LAP map=%s car=%s bot=%s finished=%s time=%.2f resets=%d impacts=%d hard=%d max_impact=%.2f max_slip=%.1f top=%.0f off=%.1fs/%.1fm" % [
			opts["map"], opts["car"], opts["bot"], r["finished"], r["time"], r["resets"], r["impacts"],
			r["hard_impacts"], r["max_impact"], r["max_slip_deg"], r["top_kmh"], r["off_road_s"], r["max_off_m"]])
	game.request_quit()


func _watch(car: Car, elapsed: float) -> void:
	if _pending_shot != "" or _shots_left <= 0 or elapsed < _next_shot:
		return
	if rad_to_deg(absf(car.body_slip)) < float(opts["slide_deg"]) or car.speed_kmh < 30.0:
		return
	_next_shot = elapsed + 1.5
	_shots_left -= 1
	_pending_shot = "%s/%s_%s_%s_%02d.png" % [opts["out"], opts["map"], opts["car"], opts["bot"], int(opts["shots"]) - _shots_left]
	print("SLIDE t=%.2f slip=%.1f kmh=%.0f -> %s" % [elapsed, rad_to_deg(car.body_slip), car.speed_kmh, _pending_shot])
	_save_shot.call_deferred()


func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(_pending_shot)
	_pending_shot = ""
