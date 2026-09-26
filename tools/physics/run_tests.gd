extends SceneTree
## Headless vehicle telemetry: drives the car through scripted scenarios on the proving ground and
## prints metrics with pass/fail against the targets in docs/PHYSICS.md.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 600 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/physics/run_tests.gd [-- only=skidpad,jump soak=300]
##
## --fixed-fps 120 makes every frame exactly one physics tick, so the run is faster than real time
## and deterministic in step size.

const DT := 1.0 / 120.0

var ground: Node
var car: Car
var results: Array[Dictionary] = []
var nan_detected: bool = false
var max_speed_seen: float = 0.0
var max_spin_seen: float = 0.0
var impacts: Array[float] = []
var landings: Array[float] = []
var cost_samples: PackedInt32Array = PackedInt32Array()
var options: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() == 2:
			options[kv[0]] = kv[1]
	ground = load("res://scenes/test/physics_test.tscn").instantiate()
	root.add_child(ground)
	car = load("res://scenes/car/car.tscn").instantiate() as Car
	root.add_child(car)
	car.impact.connect(func(s: float, _p: Vector3) -> void: impacts.append(s))
	car.landed.connect(func(s: float) -> void: landings.append(s))
	await physics_frame
	await _run_all()
	_print_report()
	quit()


func _want(test_name: String) -> bool:
	if not options.has("only"):
		return true
	return test_name in str(options["only"]).split(",")


func _run_all() -> void:
	if _want("accel"):
		await test_accel(&"tarmac", "runway_tarmac", 4.5, 6.0)
		await test_accel(&"gravel", "runway_gravel", 5.5, 8.5)
	if _want("topspeed"):
		await test_top_speed()
	if _want("brake"):
		await test_brake("runway_tarmac", "tarmac", 38.0, 45.0)
		await test_brake("runway_gravel", "gravel", 44.0, 60.0)
	if _want("skidpad"):
		var ranges := {"tarmac": [0.95, 1.2], "gravel": [0.7, 0.9], "dirt": [0.65, 0.85], "grass": [0.45, 0.65], "sand": [0.4, 0.6]}
		for s: String in ["tarmac", "gravel", "dirt", "grass", "sand"]:
			await test_skidpad(s, float(ranges[s][0]), float(ranges[s][1]))
	if _want("stability"):
		await test_stability()
	if _want("handbrake"):
		await test_handbrake()
	if _want("jump"):
		await test_jump()
	if _want("slope"):
		await test_slope("slope_up")
		await test_slope("slope_across")
	if _want("reset"):
		await test_reset()
	if _want("autopilot"):
		await test_autopilot()
	if _want("soak"):
		await test_soak(float(options.get("soak", "300")))


# ---------------------------------------------------------------- helpers

func _record(test_name: String, value: String, target: String, ok: bool) -> void:
	results.append({"name": test_name, "value": value, "target": target, "ok": ok})
	print("  %-34s %-26s %-22s %s" % [test_name, value, target, "PASS" if ok else "FAIL"])


func _controls(thr: float, brk: float, steer: float, hb: bool = false) -> void:
	car.input_throttle = thr
	car.input_brake = brk
	car.input_steer = steer
	car.input_handbrake = hb


func _tick() -> void:
	await physics_frame
	var v := car.linear_velocity
	var w := car.angular_velocity
	var p := car.global_position
	if not (v.is_finite() and w.is_finite() and p.is_finite()):
		nan_detected = true
	max_speed_seen = maxf(max_speed_seen, v.length())
	max_spin_seen = maxf(max_spin_seen, w.length())
	cost_samples.append(car.step_usec)


func _ticks(n: int) -> void:
	for i in n:
		await _tick()


func _place(spawn_name: String, settle: float = 1.0) -> void:
	_controls(0.0, 0.0, 0.0)
	car.reset_to(ground.spawn(spawn_name))
	await _ticks(int(settle / DT))


## Keeps the car on a straight line along -Z at lane x (for runways).
func _lane_steer(lane_x: float) -> float:
	var fwd := -car.global_transform.basis.z
	var e := car.global_position.x - lane_x
	return clampf(-0.06 * e - 2.0 * fwd.x, -1.0, 1.0)


## Wraps the car back to the start of a runway keeping its velocity (unlimited straight).
func _wrap_runway() -> void:
	if car.global_position.z < -380.0:
		var p := car.global_position
		p.z += 780.0
		car.global_position = p
		car.reset_physics_interpolation()


func _heading() -> float:
	var f := -car.global_transform.basis.z
	return atan2(f.x, -f.z)


# ---------------------------------------------------------------- scenarios

func test_accel(surface: StringName, spawn_name: String, lo: float, hi: float) -> void:
	await _place(spawn_name)
	var lane := car.global_position.x
	var t := 0.0
	var t100 := -1.0
	while t < 15.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
		t += DT
		if car.speed_kmh >= 100.0:
			t100 = t
			break
	_record("0-100 km/h %s" % surface, "%.2f s" % t100, "%.1f-%.1f s" % [lo, hi], t100 >= lo and t100 <= hi)


func test_top_speed() -> void:
	await _place("runway_tarmac")
	var lane := car.global_position.x
	var top := 0.0
	for i in int(45.0 / DT):
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
		_wrap_runway()
		top = maxf(top, car.speed_kmh)
	_record("top speed", "%.1f km/h (gear %d)" % [top, car.gear], "180-200 km/h", top >= 180.0 and top <= 200.0)


func test_brake(spawn_name: String, surface: String, lo: float, hi: float) -> void:
	await _place(spawn_name)
	var lane := car.global_position.x
	while car.speed_kmh < 108.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
		_wrap_runway()
	var start := Vector3.ZERO
	var started := false
	var t := 0.0
	while t < 12.0:
		_controls(0.0, 1.0, _lane_steer(lane))
		await _tick()
		t += DT
		if not started and car.speed_kmh <= 100.0:
			start = car.global_position
			started = true
		if started and car.speed_kmh < 0.3:
			break
	var d := Vector2(car.global_position.x - start.x, car.global_position.z - start.z).length()
	_record("100-0 braking %s" % surface, "%.1f m" % d, "%.0f-%.0f m" % [lo, hi], d >= lo and d <= hi)


func test_skidpad(surface: String, lo: float, hi: float) -> void:
	await _place("pad_" + surface, 0.5)
	var radius := 30.0
	var spawn_xf: Transform3D = ground.spawn("pad_" + surface)
	var centre := spawn_xf.origin + Vector3(-radius, 0.0, 0.0)
	var target_speed := 25.0 / 3.6
	var window: Array[float] = []
	var best := 0.0
	var t := 0.0
	while t < 60.0:
		var pos := car.global_position
		var rel := Vector2(pos.x - centre.x, pos.z - centre.z)
		var r := rel.length()
		var theta := atan2(rel.y, rel.x)
		# Counter-clockwise seen from above (towards -Z first from +X).
		var ahead_theta := theta - 9.0 / radius
		var tgt := centre + Vector3(cos(ahead_theta), 0.0, sin(ahead_theta)) * radius
		var local := car.global_transform.affine_inverse() * tgt
		var dist := maxf(Vector2(local.x, local.z).length(), 1.0)
		var k := 2.0 * sin(atan2(local.x, -local.z)) / dist
		var steer := atan(k * Car.WHEELBASE) / car.steer_lock_at(car.speed_kmh)
		var speed := car.linear_velocity.length()
		target_speed += DT * 0.35
		var err := target_speed - speed
		_controls(clampf(0.25 + err * 0.4, 0.0, 1.0), 0.0, clampf(steer, -1.0, 1.0))
		await _tick()
		t += DT
		var yaw_rate := car.angular_velocity.dot(car.global_transform.basis.y)
		var a_lat := absf(speed * yaw_rate) / 9.81
		if absf(r - radius) < 2.0 and t > 4.0:
			window.append(a_lat)
			if window.size() > 120:
				window.pop_front()
				var avg := 0.0
				for a in window:
					avg += a
				best = maxf(best, avg / window.size())
		else:
			window.clear()
	_record("skidpad R30 %s" % surface, "%.2f g" % best, "%.2f-%.2f g" % [lo, hi], best >= lo and best <= hi)


func test_stability() -> void:
	await _place("runway_tarmac")
	var lane := car.global_position.x
	while car.speed_kmh < 150.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
		_wrap_runway()
	# Hands off at 150 km/h for 4 s, holding speed.
	var h0 := _heading()
	var yaw_max := 0.0
	for i in int(4.0 / DT):
		var err := 150.0 / 3.6 - car.linear_velocity.length()
		_controls(clampf(0.4 + err * 0.3, 0.0, 1.0), 0.0, 0.0)
		await _tick()
		_wrap_runway()
		yaw_max = maxf(yaw_max, absf(car.angular_velocity.y))
	var drift := rad_to_deg(absf(angle_difference(h0, _heading())))
	_record("150 km/h hands-off heading drift", "%.2f deg / 4 s" % drift, "< 1.5 deg", drift < 1.5)
	# Yaw kick of 0.3 rad/s: must damp out without oscillating.
	car.angular_velocity += Vector3.UP * 0.3
	var settle := -1.0
	var overshoot := 0.0
	var t := 0.0
	while t < 4.0:
		var err := 150.0 / 3.6 - car.linear_velocity.length()
		_controls(clampf(0.4 + err * 0.3, 0.0, 1.0), 0.0, 0.0)
		await _tick()
		_wrap_runway()
		t += DT
		var y := car.angular_velocity.y
		overshoot = minf(overshoot, y)
		if settle < 0.0 and absf(y) < 0.02:
			settle = t
	_record("150 km/h yaw-kick settle", "%.2f s (overshoot %.3f)" % [settle, -overshoot], "< 1.5 s", settle > 0.0 and settle < 1.5)


func test_handbrake() -> void:
	await _place("pad_gravel", 0.5)
	var p := car.global_position
	car.reset_to(Transform3D(Basis.IDENTITY, p + Vector3(0.0, 0.0, 45.0)))
	await _ticks(60)
	var lane := car.global_position.x
	while car.speed_kmh < 60.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
	var h0 := _heading()
	var peak := 0.0
	var t := 0.0
	var heading_at_1s := 0.0
	while t < 2.0:
		# Flick in with full lock + handbrake, then straighten and drive out (the assist catches it).
		var hb := t < 0.7
		_controls(0.0 if hb else 0.8, 0.0, -1.0 if hb else 0.0, hb)
		await _tick()
		t += DT
		peak = maxf(peak, absf(car.angular_velocity.y))
		if absf(t - 1.2) < DT * 0.5:
			heading_at_1s = rad_to_deg(absf(angle_difference(h0, _heading())))
	var turned := rad_to_deg(absf(angle_difference(h0, _heading())))
	_record("handbrake turn 60 km/h gravel", "%.0f deg/s peak, %.0f deg @1.2s" % [rad_to_deg(peak), heading_at_1s],
			"> 60 deg/s, > 70 deg", rad_to_deg(peak) > 60.0 and heading_at_1s > 70.0)
	var final_speed := car.speed_kmh
	_record("handbrake turn drive-out", "%.0f deg total, %.0f km/h @2s" % [turned, final_speed], "> 15 km/h forward", final_speed > 15.0)


func test_jump() -> void:
	await _place("jump")
	var lane := car.global_position.x
	landings.clear()
	var airtime := 0.0
	var landed_at := -1.0
	var settled_at := -1.0
	var bounces := 0
	var was_grounded := true
	var settled_for := 0.0
	var t := 0.0
	var max_pitch_rate := 0.0
	while t < 20.0:
		var err := 85.0 / 3.6 - car.linear_velocity.length()
		var thr := clampf(0.3 + err * 0.4, 0.0, 1.0) if car.global_position.z > 294.0 else 0.2
		_controls(thr, 0.0, _lane_steer(lane))
		await _tick()
		t += DT
		airtime = maxf(airtime, car.airborne_time)
		if landed_at < 0.0 and landings.size() > 0:
			landed_at = t
			was_grounded = true
		if landed_at > 0.0 and settled_at < 0.0:
			max_pitch_rate = maxf(max_pitch_rate, car.angular_velocity.length())
			var grounded := car.grounded_wheels > 0
			if was_grounded and not grounded:
				bounces += 1
			was_grounded = grounded
			var calm := car.grounded_wheels == 4 and absf(car.linear_velocity.y) < 0.35 and car.angular_velocity.length() < 0.3
			settled_for = settled_for + DT if calm else 0.0
			if settled_for >= 0.15:
				settled_at = t - settled_for
		if settled_at > 0.0 and t > landed_at + 2.0:
			break
	var land_strength: float = landings[0] if landings.size() > 0 else 0.0
	_record("jump airtime", "%.2f s (landing %.2f)" % [airtime, land_strength], "> 0.6 s", airtime > 0.6)
	var settle := settled_at - landed_at if settled_at > 0.0 else 99.0
	_record("jump landing settle", "%.2f s, %d bounces" % [settle, bounces], "< 1.0 s, 0 bounces", settle < 1.0 and bounces == 0)


func test_slope(spawn_name: String) -> void:
	await _place(spawn_name, 2.5)
	var p0 := car.global_position
	await _ticks(int(5.0 / DT))
	var drift := car.global_position.distance_to(p0) * 100.0
	_record("rest on 15° slope (%s)" % spawn_name.trim_prefix("slope_"), "%.3f cm / 5 s" % drift, "< 1 cm", drift < 1.0)


func test_reset() -> void:
	var xf := Transform3D(Basis(Vector3.BACK, PI), Vector3(-300.0, 2.0, 60.0))
	car.reset_to(xf)
	var t := 0.0
	var reset_at := -1.0
	var was_upside := false
	while t < 6.0:
		_controls(0.5, 0.0, 0.0)
		await _tick()
		t += DT
		var up_y := car.global_transform.basis.y.y
		if up_y < 0.0:
			was_upside = true
		if was_upside and up_y > 0.95 and reset_at < 0.0:
			reset_at = t
	_record("auto-reset when upside down", "%.2f s" % reset_at, "2.5-3.5 s, upright", reset_at > 2.4 and reset_at < 3.5)
	# Manual reset near the loop snaps onto the racing line.
	car.reset_to(Transform3D(Basis(Vector3.UP, 1.0), Vector3(12.0, 0.5, 20.0)))
	await _ticks(10)
	car.reset_to_track()
	await _ticks(60)
	var loop: Path3D = ground.get("loop_path")
	var closest := loop.curve.get_closest_point(car.global_position)
	var off := Vector2(car.global_position.x - closest.x, car.global_position.z - closest.z).length()
	_record("reset_car onto track line", "%.2f m from line" % off, "< 1 m", off < 1.0)
	_controls(0.0, 0.0, 0.0)


func test_autopilot() -> void:
	var ap := Autopilot.new()
	ap.path = ground.get("loop_path")
	car.add_child(ap)
	car.reset_to(ground.spawn("loop_start"))
	await _ticks(30)
	impacts.clear()
	var max_err := 0.0
	var off_ticks := 0
	var lap_times: Array[float] = []
	ap.lap_completed.connect(func(lt: float) -> void: lap_times.append(lt))
	var cost_start := cost_samples.size()
	var t := 0.0
	while lap_times.size() < 4 and t < 400.0:
		await _tick()
		t += DT
		if t > 3.0:
			max_err = maxf(max_err, absf(ap.lateral_error))
			if absf(ap.lateral_error) > 5.0 - 0.9:
				off_ticks += 1
	var crashes := 0
	for s in impacts:
		if s > 0.25:
			crashes += 1
	var laps_str := ", ".join(lap_times.map(func(x: float) -> String: return "%.1f" % x))
	# First "lap" is the partial run from the start line; the next three are full flying laps.
	var full := lap_times.slice(1, 4)
	_record("autopilot laps (3 flying)", laps_str + " s", "3 laps", full.size() == 3)
	_record("autopilot max line error", "%.2f m, %d ticks off" % [max_err, off_ticks], "wheels on road", off_ticks == 0)
	_record("autopilot crashes", "%d impacts > 0.25" % crashes, "0", crashes == 0)
	var sum := 0
	var worst := 0
	for i in range(cost_start, cost_samples.size()):
		sum += cost_samples[i]
		worst = maxi(worst, cost_samples[i])
	var n := maxi(cost_samples.size() - cost_start, 1)
	_record("physics cost per tick (car)", "%d us avg, %d us max" % [sum / n, worst], "< 400 us avg", sum / n < 400)
	ap.queue_free()
	await _tick()


func test_soak(seconds: float) -> void:
	nan_detected = false
	max_speed_seen = 0.0
	max_spin_seen = 0.0
	var ap := Autopilot.new()
	ap.path = ground.get("loop_path")
	car.add_child(ap)
	ap.enabled = false
	var t := 0.0
	var phase := 0
	var resets := 0
	impacts.clear()
	landings.clear()
	while t < seconds:
		match phase % 4:
			0:
				ap.enabled = true
				ap.rebuild()
				car.reset_to(ground.spawn("loop_start"))
				for i in int(60.0 / DT):
					await _tick()
				ap.enabled = false
				t += 60.0
			1:
				car.reset_to(ground.spawn("jump"))
				for i in int(12.0 / DT):
					var err := 95.0 / 3.6 - car.linear_velocity.length()
					_controls(clampf(0.3 + err * 0.4, 0.0, 1.0), 0.0, _lane_steer(-250.0))
					await _tick()
				t += 12.0
			2:
				car.reset_to(ground.spawn("wall"))
				for i in int(9.0 / DT):
					_controls(1.0, 0.0, 0.15 * sin(i * DT * 2.0))
					await _tick()
				t += 9.0
				resets += 1
			3:
				car.reset_to(ground.spawn("bumps"))
				for i in int(10.0 / DT):
					_controls(1.0, 0.0, _lane_steer(-530.0))
					await _tick()
				car.reset_to(ground.spawn("banked"))
				for i in int(12.0 / DT):
					var err := 75.0 / 3.6 - car.linear_velocity.length()
					var steer := 0.0 if i < 300 else -0.35
					_controls(clampf(0.3 + err * 0.4, 0.0, 1.0), 0.0, steer)
					await _tick()
				t += 22.0
		phase += 1
	ap.queue_free()
	var hard_hits := 0
	for s in impacts:
		if s > 0.5:
			hard_hits += 1
	_record("soak %.0f s (loop, jumps, wall, bumps, banking)" % t,
			"NaN=%s vmax=%.0f m/s wmax=%.1f rad/s" % [nan_detected, max_speed_seen, max_spin_seen],
			"no NaN, v<70, w<15", not nan_detected and max_speed_seen < 70.0 and max_spin_seen < 15.0)
	_record("soak events", "%d impacts (%d hard), %d landings" % [impacts.size(), hard_hits, landings.size()], "signals fire", impacts.size() > 0 and landings.size() > 0)


func _print_report() -> void:
	var passed := 0
	print("")
	print("| Test | Result | Target | |")
	print("|---|---|---|---|")
	for r in results:
		if r["ok"]:
			passed += 1
		print("| %s | %s | %s | %s |" % [r["name"], r["value"], r["target"], "PASS" if r["ok"] else "FAIL"])
	print("")
	print("RESULT %d/%d passed" % [passed, results.size()])
