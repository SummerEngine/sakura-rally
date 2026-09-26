extends SceneTree
## Rendered proof of the title flyover: boots the real main scene to the title screen and saves
## the frame (1600x900 under --summer-offscreen) whenever the menu car is well into a slide, at
## most one per `gap` seconds, plus the car's slip and speed in the file name. Needs a renderer:
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 120 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
##       -s res://tools/showoff/flyover_frames.gd [-- out=/tmp/showoff seconds=80 car=sakura \
##       slip=15 gap=1.2]
##
## Then e.g. `ffmpeg -pattern_type glob -i '/tmp/showoff/slide_*.png' -vf
## scale=640:-1,tile=3x3 -frames:v 1 /tmp/showoff/sheet.png`. Stops early if frames stop being
## drawn (the window is occluded), and says so.

var opts := {"out": "/tmp/showoff", "seconds": "80", "car": "", "slip": "15", "gap": "1.2"}
var main: Node
var game: Node


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	game = root.get_node("Game")
	if str(opts["car"]) != "":
		game.set_setting("car_id", opts["car"]) # a -s harness never saves settings (Game.persistent)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	var start := Time.get_ticks_msec()
	while game.state != game.State.MENU:
		await process_frame
		if Time.get_ticks_msec() - start > 60000:
			print("TIMEOUT waiting for the title")
			quit(1)
			return
	var seconds := float(opts["seconds"])
	var slip_on := float(opts["slip"])
	var gap := float(opts["gap"])
	var t := 0.0
	var last := -INF
	var saved := 0
	var drawn := Engine.get_frames_drawn()
	var stalled := 0.0
	while t < seconds:
		await process_frame
		var dt := get_root().get_process_delta_time()
		t += dt
		var now := Engine.get_frames_drawn()
		stalled = stalled + dt if now == drawn else 0.0
		drawn = now
		if stalled > 2.0:
			print("STALLED: no frames drawn for 2 s (window occluded?) after %d frames saved" % saved)
			break
		var car: Car = main.car
		if car == null or not is_instance_valid(car):
			continue
		var lv := car.local_velocity
		var kmh := car.linear_velocity.length() * 3.6
		var slip := rad_to_deg(absf(atan2(lv.x, maxf(-lv.z, 0.5)))) if kmh > 18.0 else 0.0
		if slip >= slip_on and t - last >= gap:
			last = t
			var img := root.get_texture().get_image()
			var path := "%s/slide_%02d_t%05.1f_slip%02d_kmh%03d.png" % [opts["out"], saved, t, int(slip), int(kmh)]
			img.save_png(path)
			saved += 1
			print("FRAME %s %dx%d frames_drawn=%d" % [path, img.get_width(), img.get_height(), now])
	print("SAVED %d frames in %.0f s of flyover" % [saved, t])
	quit(0)
