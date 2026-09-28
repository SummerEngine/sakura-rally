extends SceneTree
## What N stripped cars (no visuals, no audio) cost headless on one route: map build time,
## physics ticks per wall second and the mean Car.step_usec. Each car follows the centre line
## with a crude pure-pursuit so the load looks like driving, not parking.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 300 nice -n 10 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/rl/bench.gd -- map=hanami cars=16 seconds=20 soft=1

const RLCar := preload("res://tools/rl/rl_car.gd")

var opts := {"map": "hanami", "cars": "16", "seconds": "20", "car": "sakura", "soft": "1"}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var t_build := Time.get_ticks_msec()
	var map := MapWorld.new()
	map.name = "Map"
	map.map_id = opts["map"]
	root.add_child(map)
	await map.build()
	print("BUILD map=%s ms=%d" % [opts["map"], Time.get_ticks_msec() - t_build])
	if opts["soft"] == "0" and map.soft_course != null:
		map.soft_course.set_physics_process(false)
	var track := map.track
	var n := int(opts["cars"])
	var cars: Array[Car] = []
	for k in n:
		var car := RLCar.spawn(root, str(game.get_car(opts["car"])["scene"]))
		cars.append(car)
	await physics_frame
	for k in n:
		cars[k].place_at_rest(track.transform_at_progress(track.length * float(k) / n))
	for i in 30:
		await physics_frame
	var ticks := int(float(opts["seconds"]) * 120.0)
	var hints: PackedInt32Array = []
	hints.resize(n)
	hints.fill(-1)
	var usec_sum := 0
	var t0 := Time.get_ticks_usec()
	for t in ticks:
		for k in n:
			var car := cars[k]
			var i := track.nearest(car.global_position, hints[k], 12)
			hints[k] = i
			var s := track.abs_s(i, car.global_position)
			var aim := track.position_at_abs(s + 18.0)
			var local := car.global_transform.affine_inverse() * aim
			car.input_steer = clampf(atan2(local.x, -local.z) * 2.0, -1.0, 1.0)
			var v := car.speed_kmh
			car.input_throttle = 1.0 if v < 70.0 else 0.0
			car.input_brake = 0.4 if v > 85.0 else 0.0
			usec_sum += car.step_usec
		await physics_frame
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	var off := 0
	for k in n:
		var car := cars[k]
		var i := track.nearest(car.global_position)
		if absf(track.lateral(i, car.global_position)) > track.half_width(i) + track.verge:
			off += 1
	print("BENCH map=%s cars=%d soft=%s ticks=%d wall=%.2fs ticks_per_s=%.0f car_s_per_s=%.1f step_usec=%.0f off_road=%d" % [
			opts["map"], n, opts["soft"], ticks, wall, ticks / wall, ticks * n / 120.0 / wall,
			float(usec_sum) / (ticks * n), off])
	game.request_quit()
