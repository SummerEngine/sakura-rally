extends SceneTree
## Headless vehicle telemetry: drives each car through scripted scenarios on the proving ground,
## then laps the real maps, and prints metrics with pass/fail against the targets in
## docs/PHYSICS.md.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 1200 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/physics/run_tests.gd [-- car=sakura only=skidpad,panic soak=300 maps=hanami]
##
## car: sakura | hayate | all (default). only: comma list of the group names in _run_car() and
## "maps". --fixed-fps 120 makes every frame exactly one physics tick, so the run is faster than
## real time and deterministic in step size.
##
## Everything except the straight-line braking tests and the skidpads drives through the real
## keyboard path: `controlled_by_player = true` and Input.action_press/action_release on the
## InputMap actions (KeyTaps), so CarInput's keyboard shaping is part of every result.

const DT := 1.0 / 120.0
const KeyTaps := preload("res://tools/physics/key_taps.gd")
const KeyboardBot := preload("res://tools/physics/keyboard_bot.gd")
const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")

## Per-car targets. Ranges are [lo, hi]; a single number is an upper bound.
const TARGETS := {
	"sakura": {
		"accel_tarmac": [3.3, 3.9], "accel_gravel": [3.8, 4.6], "accel60_tarmac": 2.0,
		"top": [182.0, 195.0], "brake_tarmac": [27.0, 33.0], "brake_gravel": [31.0, 38.0],
		"drift_slip": [25.0, 45.0],
	},
	"hayate": {
		"accel_tarmac": [4.3, 5.2], "accel_gravel": [4.8, 6.4], "accel60_tarmac": 2.8,
		"top": [175.0, 190.0], "brake_tarmac": [25.0, 33.0], "brake_gravel": [29.0, 38.0],
		"drift_slip": [30.0, 50.0],
	},
}
const SKIDPAD := {"tarmac": [1.15, 1.35], "gravel": [0.92, 1.08], "dirt": [0.88, 1.02], "grass": [0.60, 0.75], "sand": [0.55, 0.70]}
## Medal factors over the analog reference lap (gold, silver, bronze), as in Game.MAPS.
const MEDAL_FACTORS := [1.1, 1.22, 1.42]

var ground: Node
var car: Car
var car_id: String = ""
var keys := KeyTaps.new()
var results: Array[Dictionary] = []
var nan_detected: bool = false
var max_speed_seen: float = 0.0
var max_spin_seen: float = 0.0
var impacts: Array[float] = []
var landings: Array[float] = []
var cost_samples: PackedInt32Array = PackedInt32Array()
var options: Dictionary = {}
var reference_laps: Dictionary = {} ## "map/car" -> analog lap time


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() == 2:
			options[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var cars: Array[String] = []
	var which := str(options.get("car", "all"))
	for c in game.CARS:
		if which == "all" or which == c["id"]:
			cars.append(str(c["id"]))
	ground = load("res://scenes/test/physics_test.tscn").instantiate()
	root.add_child(ground)
	for id in cars:
		await _spawn_car(id)
		await _run_car()
		await _drop_car()
	ground.queue_free()
	ground = null
	await physics_frame
	if _want("maps"):
		for map_id in str(options.get("maps", "hanami,momiji")).split(","):
			await test_map(map_id, cars)
	_print_report()
	game.request_quit()


func _spawn_car(id: String) -> void:
	car_id = id
	var game := root.get_node("Game")
	car = (load(str(game.get_car(id)["scene"])) as PackedScene).instantiate() as Car
	root.add_child(car)
	car.impact.connect(func(s: float, _p: Vector3) -> void: impacts.append(s))
	car.landed.connect(func(s: float) -> void: landings.append(s))
	await physics_frame


func _drop_car() -> void:
	_kb_end()
	car.queue_free()
	car = null
	await physics_frame


func _want(test_name: String) -> bool:
	if not options.has("only"):
		return true
	return test_name in str(options["only"]).split(",")


func _t(key: String) -> Variant:
	return TARGETS[car_id][key]


func _run_car() -> void:
	if _want("accel"):
		await test_accel(&"tarmac", "runway_tarmac")
		await test_accel(&"gravel", "runway_gravel")
	if _want("topspeed"):
		await test_top_speed()
	if _want("brake"):
		await test_brake("runway_tarmac", "tarmac")
		await test_brake("runway_gravel", "gravel")
		await test_brake_130_50()
		await test_brake_steered()
	if _want("skidpad"):
		for s: String in ["tarmac", "gravel", "dirt", "grass", "sand"]:
			await test_skidpad(s)
	if _want("stability"):
		await test_stability()
	if _want("turnin"):
		await test_turn_in(&"tarmac")
		await test_turn_in(&"gravel")
	if _want("panic"):
		for s: StringName in [&"tarmac", &"gravel", &"dirt"]:
			for kmh in [130.0, 160.0]:
				await test_panic(s, kmh)
	if _want("slalom"):
		await test_slalom()
	if _want("drift"):
		await test_drift()
	if _want("handbrake"):
		await test_handbrake()
	if _want("crash"):
		await test_walls()
		await test_pole(0.16, "pole (r 0.16)")
		await test_pole(0.3, "tree trunk (r 0.3)")
		await test_rock()
		await test_hairpin_wall()
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
	var n := "%s: %s" % [car_id, test_name] if car_id != "" else test_name
	results.append({"name": n, "value": value, "target": target, "ok": ok})
	print("  %-44s %-40s %-24s %s" % [n, value, target, "PASS" if ok else "FAIL"])


func _range_ok(v: float, r: Variant) -> bool:
	if r is Array:
		return v >= float(r[0]) and v <= float(r[1])
	return v <= float(r)


func _range_str(r: Variant, fmt: String) -> String:
	if r is Array:
		return (fmt + "-" + fmt) % [r[0], r[1]]
	return ("<= " + fmt) % r


## Direct (analog) controls, used only by the straight-line braking tests and the skidpads.
func _controls(thr: float, brk: float, steer: float, hb: bool = false) -> void:
	car.input_throttle = thr
	car.input_brake = brk
	car.input_steer = steer
	car.input_handbrake = hb


## Hands the car to the keyboard path with every key up.
func _kb_begin() -> void:
	keys.release_all()
	car.player_input.reset()
	car.controlled_by_player = true


func _kb_end() -> void:
	keys.release_all()
	if car != null:
		car.controlled_by_player = false
		car.player_input.reset()
		_controls(0.0, 0.0, 0.0)


func _tick() -> void:
	keys.tick(DT)
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


func _place(spawn_name: String, settle: float = 1.0, keyboard: bool = true) -> void:
	_kb_end()
	car.reset_to(ground.spawn(spawn_name))
	await _ticks(int(settle / DT))
	if keyboard:
		_kb_begin()


## Wanted analog steering that keeps the car on a straight line along -Z at lane x.
func _lane_steer(lane_x: float) -> float:
	var fwd := -car.global_transform.basis.z
	var e := car.global_position.x - lane_x
	return clampf(-0.06 * e - 2.0 * fwd.x, -1.0, 1.0)


## Keyboard lane keeping: steering taps towards _lane_steer.
func _kb_lane(lane_x: float) -> void:
	keys.steer_towards(_lane_steer(lane_x), car.player_input.steer, DT)


## Keyboard speed hold: throttle key below the target, off above it.
func _kb_hold_speed(kmh: float) -> void:
	var v := car.speed_kmh
	if v < kmh - 1.0:
		keys.pedals(true, false)
	elif v > kmh + 1.0:
		keys.pedals(false, false)


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


func _slip_deg() -> float:
	var lv := car.local_velocity
	if Vector2(lv.x, lv.z).length() < 4.0:
		return 0.0
	return rad_to_deg(atan2(lv.x, -lv.z))


## Keyboard run-up on a plaza to `kmh`, lane-kept, then `settle` s holding it.
func _kb_run_up(spawn_name: String, kmh: float, settle: float = 0.8) -> float:
	await _place(spawn_name)
	var lane := car.global_position.x
	var t := 0.0
	while car.speed_kmh < kmh and t < 40.0:
		_kb_lane(lane)
		keys.pedals(true, false)
		await _tick()
		t += DT
	var s := 0.0
	while s < settle:
		_kb_lane(lane)
		_kb_hold_speed(kmh)
		await _tick()
		s += DT
	return lane


# ---------------------------------------------------------------- straight line

func test_accel(surface: StringName, spawn_name: String) -> void:
	await _place(spawn_name)
	var lane := car.global_position.x
	var t := 0.0
	var t60 := -1.0
	var t100 := -1.0
	while t < 15.0:
		_kb_lane(lane)
		keys.pedals(true, false)
		await _tick()
		t += DT
		if t60 < 0.0 and car.speed_kmh >= 60.0:
			t60 = t
		if car.speed_kmh >= 100.0:
			t100 = t
			break
	var r: Variant = _t("accel_" + surface)
	_record("0-100 km/h %s" % surface, "%.2f s" % t100, _range_str(r, "%.1f") + " s", _range_ok(t100, r))
	if surface == &"tarmac":
		var r60: Variant = _t("accel60_tarmac")
		_record("0-60 km/h tarmac", "%.2f s" % t60, _range_str(r60, "%.1f") + " s", t60 > 0.0 and _range_ok(t60, r60))


func test_top_speed() -> void:
	await _place("runway_tarmac")
	var lane := car.global_position.x
	var top := 0.0
	for i in int(50.0 / DT):
		_kb_lane(lane)
		keys.pedals(true, false)
		await _tick()
		_wrap_runway()
		top = maxf(top, car.speed_kmh)
	var r: Variant = _t("top")
	_record("top speed", "%.1f km/h (gear %d)" % [top, car.gear], _range_str(r, "%.0f") + " km/h", _range_ok(top, r))


## Straight-line braking with direct controls from above `from_kmh`; distance from from_kmh
## down to to_kmh.
func _brake_distance(spawn_name: String, from_kmh: float, to_kmh: float) -> float:
	await _place(spawn_name, 1.0, false)
	var lane := car.global_position.x
	while car.speed_kmh < from_kmh + 8.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
		_wrap_runway()
	var started := false
	var t := 0.0
	var travelled := 0.0
	while t < 12.0:
		_controls(0.0, 1.0, _lane_steer(lane))
		await _tick()
		t += DT
		_wrap_runway()
		if not started and car.speed_kmh <= from_kmh:
			started = true
		if started:
			var v := car.linear_velocity
			travelled += Vector2(v.x, v.z).length() * DT
			if car.speed_kmh <= maxf(to_kmh, 0.3):
				break
	_controls(0.0, 0.0, 0.0)
	return travelled


func test_brake(spawn_name: String, surface: String) -> void:
	var d := await _brake_distance(spawn_name, 100.0, 0.0)
	var r: Variant = _t("brake_" + surface)
	_record("100-0 braking %s" % surface, "%.1f m" % d, _range_str(r, "%.0f") + " m", _range_ok(d, r))


func test_brake_130_50() -> void:
	var d := await _brake_distance("runway_gravel", 130.0, 50.0)
	_record("130-50 braking gravel", "%.1f m" % d, "<= 50 m", d <= 50.0)


## Full brake from 150 km/h on the tarmac plaza with 0.2 steer held: the car must not rotate
## away from its path.
func test_brake_steered() -> void:
	await _place("plaza_tarmac", 1.0, false)
	var lane := car.global_position.x
	while car.speed_kmh < 150.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await _tick()
	var max_slip := 0.0
	var t := 0.0
	while t < 8.0 and car.speed_kmh > 15.0:
		_controls(0.0, 1.0, 0.2)
		await _tick()
		t += DT
		max_slip = maxf(max_slip, absf(_slip_deg()))
	_controls(0.0, 0.0, 0.0)
	_record("150-0 braking, 0.2 steer held", "%.1f deg max body slip" % max_slip, "< 8 deg", max_slip < 8.0)


func test_skidpad(surface: String) -> void:
	await _place("pad_" + surface, 0.5, false)
	var radius := 30.0
	var spawn_xf: Transform3D = ground.spawn("pad_" + surface)
	var centre := spawn_xf.origin + Vector3(-radius, 0.0, 0.0)
	var target_speed := 25.0 / 3.6
	var window: Array[float] = []
	var best := 0.0
	var t := 0.0
	var course := NAN
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
		# Lateral acceleration from the turn rate of the velocity itself (not the body's yaw rate,
		# which also counts changes of body slip while the car slides in or out of the circle).
		var v_flat := Vector2(car.linear_velocity.x, car.linear_velocity.z)
		var now_course := v_flat.angle()
		var a_lat := 0.0 if is_nan(course) else absf(speed * angle_difference(course, now_course) / DT) / 9.81
		course = now_course
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
	var rr: Array = SKIDPAD[surface]
	_record("skidpad R30 %s" % surface, "%.2f g" % best, "%.2f-%.2f g" % [rr[0], rr[1]], _range_ok(best, rr))


func test_stability() -> void:
	await _place("runway_tarmac")
	var lane := car.global_position.x
	while car.speed_kmh < 150.0:
		_kb_lane(lane)
		keys.pedals(true, false)
		await _tick()
		_wrap_runway()
	# Settle on the lane, then hands off (no steering key) at 150 km/h for 4 s.
	for i in int(1.5 / DT):
		_kb_lane(lane)
		_kb_hold_speed(150.0)
		await _tick()
		_wrap_runway()
	keys.steer_key(0)
	await _ticks(int(0.3 / DT))
	var h0 := _heading()
	for i in int(4.0 / DT):
		keys.steer_key(0)
		_kb_hold_speed(150.0)
		await _tick()
		_wrap_runway()
	var drift := rad_to_deg(absf(angle_difference(h0, _heading())))
	_record("150 km/h hands-off heading drift", "%.2f deg / 4 s" % drift, "< 1.5 deg", drift < 1.5)
	# Yaw kick of 0.3 rad/s: must damp out without oscillating.
	car.angular_velocity += Vector3.UP * 0.3
	var settle := -1.0
	var overshoot := 0.0
	var t := 0.0
	while t < 4.0:
		_kb_hold_speed(150.0)
		await _tick()
		_wrap_runway()
		t += DT
		var y := car.angular_velocity.y
		overshoot = minf(overshoot, y)
		if settle < 0.0 and absf(y) < 0.02:
			settle = t
	_record("150 km/h yaw-kick settle", "%.2f s (overshoot %.3f)" % [settle, -overshoot], "< 1.5 s", settle > 0.0 and settle < 1.5)


# ---------------------------------------------------------------- handling (keyboard)

## Digital full lock at 90 km/h: time until the yaw rate reaches 80 % of its steady value.
func test_turn_in(surface: StringName) -> void:
	await _kb_run_up("plaza_" + surface, 90.0)
	var trace := PackedFloat32Array()
	var t := 0.0
	while t < 2.0:
		keys.steer_key(1)
		_kb_hold_speed(90.0)
		await _tick()
		t += DT
		trace.append(absf(car.angular_velocity.dot(car.global_transform.basis.y)))
	keys.steer_key(0)
	var steady := 0.0
	var n := 0
	for i in range(int(1.2 / DT), trace.size()):
		steady += trace[i]
		n += 1
	steady /= maxf(n, 1)
	var t80 := -1.0
	for i in trace.size():
		if trace[i] >= 0.8 * steady:
			t80 = (i + 1) * DT
			break
	_record("turn-in 90 km/h %s (digital)" % surface, "%.2f s to 80 %% of %.0f deg/s" % [t80, rad_to_deg(steady)],
			"<= 0.35 s", t80 > 0.0 and t80 <= 0.35)
	await _ticks(int(1.0 / DT))


## Digital full lock for 1.5 s at speed with the throttle held, lifted, or full brake; then
## centre (all keys up) and watch the recovery.
func test_panic(surface: StringName, kmh: float) -> void:
	var parts: Array[String] = []
	var all_ok := true
	for mode in ["throttle", "lift", "brake"]:
		await _kb_run_up("plaza_" + surface, kmh)
		var max_slip := 0.0
		var reversed := false
		var t := 0.0
		while t < 1.5:
			keys.steer_key(-1)
			keys.pedals(mode == "throttle", mode == "brake")
			await _tick()
			t += DT
			max_slip = maxf(max_slip, absf(_slip_deg()))
			reversed = reversed or absf(_slip_deg()) > 90.0
		keys.steer_key(0)
		keys.pedals(false, false)
		var calm_at := -1.0
		t = 0.0
		while t < 2.5:
			await _tick()
			t += DT
			var s := absf(_slip_deg())
			if t <= 1.0:
				max_slip = maxf(max_slip, s)
			reversed = reversed or s > 90.0
			if s < 3.0:
				if calm_at < 0.0:
					calm_at = t
			else:
				calm_at = -1.0
		var limit := 25.0 if mode == "brake" else 20.0
		var ok := max_slip < limit and not reversed and calm_at >= 0.0 and calm_at <= 1.0
		all_ok = all_ok and ok
		parts.append("%s %.0f°/%.2fs" % [mode, max_slip, calm_at])
	_record("panic steer %s %.0f km/h" % [surface, kmh], ", ".join(parts),
			"slip < 20° (brake 25°), < 3° in 1 s", all_ok)


## Digital left/right every 0.9 s at 110 km/h on gravel for 6 s, throttle held to 110.
func test_slalom() -> void:
	await _kb_run_up("plaza_gravel", 110.0)
	var max_slip := 0.0
	var min_speed := 999.0
	var t := 0.0
	while t < 6.0:
		keys.steer_key(1 if int(t / 0.9) % 2 == 0 else -1)
		_kb_hold_speed(110.0)
		await _tick()
		t += DT
		max_slip = maxf(max_slip, absf(_slip_deg()))
		min_speed = minf(min_speed, car.speed_kmh)
	keys.steer_key(0)
	_record("slalom 110 km/h gravel (0.9 s)", "%.1f deg max slip, %.0f km/h min" % [max_slip, min_speed],
			"< 20 deg, > 90 km/h", max_slip < 20.0 and min_speed > 90.0)
	await _ticks(int(1.0 / DT))


## Gravel at 80 km/h: handbrake tap (0.35 s) with left lock, then throttle and digital steering
## holding the slide for 2.5 s, then centre and drive out.
func test_drift() -> void:
	await _kb_run_up("plaza_gravel", 80.0)
	var peak := 0.0
	var held := 0.0
	var best_held := 0.0
	var t := 0.0
	var r: Array = _t("drift_slip")
	var mid := (float(r[0]) + float(r[1])) * 0.5
	while t < 0.35:
		keys.steer_key(-1)
		keys.pedals(false, false)
		keys.handbrake(true)
		await _tick()
		t += DT
		peak = maxf(peak, _slip_deg())
	keys.handbrake(false)
	t = 0.0
	var steer_dir := -1
	while t < 2.5:
		# Left drift: the slip is positive. Steer into the slide below the wanted angle,
		# countersteer above it (hysteresis), throttle held.
		var s := _slip_deg()
		if s > mid + 4.0:
			steer_dir = 1
		elif s < mid - 4.0:
			steer_dir = -1
		keys.steer_key(steer_dir)
		keys.pedals(true, false)
		await _tick()
		t += DT
		peak = maxf(peak, s)
		held = held + DT if s >= 20.0 else 0.0
		best_held = maxf(best_held, held)
	keys.steer_key(0)
	var straight_at := -1.0
	t = 0.0
	while t < 2.0:
		keys.pedals(true, false)
		await _tick()
		t += DT
		if straight_at < 0.0 and absf(_slip_deg()) < 5.0:
			straight_at = t
		if straight_at >= 0.0 and t >= 1.2:
			break
	var exit_speed := car.speed_kmh
	keys.pedals(false, false)
	_record("drift gravel 80 km/h: slip", "%.0f deg peak, held %.1f s" % [peak, best_held],
			"%.0f-%.0f deg, >= 1.5 s" % [r[0], r[1]], _range_ok(peak, r) and best_held >= 1.5)
	_record("drift gravel: catch by centring", "%.2f s to < 5 deg, %.0f km/h" % [straight_at, exit_speed],
			"<= 1.2 s, > 45 km/h", straight_at >= 0.0 and straight_at <= 1.2 and exit_speed > 45.0)


func test_handbrake() -> void:
	await _place("pad_gravel", 0.5, false)
	var p := car.global_position
	car.reset_to(Transform3D(Basis.IDENTITY, p + Vector3(0.0, 0.0, 45.0)))
	await _ticks(60)
	_kb_begin()
	var lane := car.global_position.x
	while car.speed_kmh < 60.0:
		_kb_lane(lane)
		keys.pedals(true, false)
		await _tick()
	var h0 := _heading()
	var peak := 0.0
	var t := 0.0
	var heading_at_1s := 0.0
	while t < 2.0:
		# Flick in with full lock + handbrake, then centre and drive out (the assists catch it).
		var hb := t < 0.7
		keys.steer_key(-1 if hb else 0)
		keys.handbrake(hb)
		keys.pedals(not hb, false)
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


# ---------------------------------------------------------------- crashes and walls

const LAYER_PROPS := 4 ## the layer MapWorld puts barriers and prop colliders on
const WALL_LOSS := {10: [5.0, 10.0], 25: [15.0, 25.0], 45: [30.0, 45.0]}

var _obstacles: Array[Node] = []


func _obstacle_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_PROPS
	body.collision_mask = 0
	root.add_child(body)
	_obstacles.append(body)
	return body


func _add_box(body: StaticBody3D, size: Vector3, xf: Transform3D) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	body.shape_owner_set_transform(owner_id, xf)


func _add_cylinder(body: StaticBody3D, radius: float, height: float, base: Vector3) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	body.shape_owner_set_transform(owner_id, Transform3D(Basis(), base + Vector3.UP * height * 0.5))


func _clear_obstacles() -> void:
	for o in _obstacles:
		o.queue_free()
	_obstacles.clear()


func _touching(body: Node) -> bool:
	return car.get_colliding_bodies().has(body)


func _flat_fwd() -> Vector3:
	var f := -car.global_transform.basis.z
	f.y = 0.0
	return f.normalized()


## Metrics of a crash from the moment of first contact: speed, rotation, airtime, spins.
class CrashLog:
	var v0 := 0.0
	var v_min := 999.0
	var yaw_max := 0.0
	var turned := 0.0
	var air := 0.0
	var max_slip := 0.0
	var min_up := 1.0
	var _headings: Array[float] = []

	## yaw_max is the rate the heading actually turns, over 0.1 s windows (a one-tick solver spike
	## at the moment of contact is not what the driver sees).
	func sample(c: Car, t: float, dt: float, h0: float, heading: float) -> void:
		if t <= 0.5:
			v_min = minf(v_min, c.linear_velocity.length())
		_headings.append(heading)
		var window := int(round(0.1 / dt))
		if _headings.size() > window:
			yaw_max = maxf(yaw_max, absf(rad_to_deg(angle_difference(_headings[-1 - window], heading))) / (window * dt))
		turned = maxf(turned, absf(rad_to_deg(angle_difference(h0, heading))))
		if c.grounded_wheels == 0:
			air += dt
		var lv := c.local_velocity
		if Vector2(lv.x, lv.z).length() > 4.0:
			max_slip = maxf(max_slip, absf(rad_to_deg(atan2(lv.x, -lv.z))))
		min_up = minf(min_up, c.global_transform.basis.y.y)


## Runs straight at `kmh` on the tarmac plaza into an obstacle built by `build(origin, fwd)`,
## lane-kept until the first contact, then throttle held with the wheel centred for `after` s.
func _crash_run(kmh: float, build: Callable, after: float, sampler: Callable = Callable()) -> CrashLog:
	var lane := await _kb_run_up("plaza_tarmac", kmh, 0.3)
	var body: StaticBody3D = build.call(car.global_position * Vector3(1, 0, 1), _flat_fwd())
	var log := CrashLog.new()
	var t := 0.0
	var prev_speed := car.linear_velocity.length()
	while t < 8.0 and not _touching(body):
		_kb_lane(lane)
		_kb_hold_speed(kmh)
		prev_speed = car.linear_velocity.length()
		await _tick()
		t += DT
	log.v0 = prev_speed
	var h0 := _heading()
	keys.steer_key(0)
	t = 0.0
	while t < after:
		keys.pedals(true, false)
		await _tick()
		t += DT
		log.sample(car, t, DT, h0, _heading())
		if sampler.is_valid():
			sampler.call(t)
	keys.pedals(false, false)
	_clear_obstacles()
	return log


func test_walls() -> void:
	for kmh in [90.0, 130.0]:
		for angle in [10, 25, 45]:
			var wall_dir: Array[Vector3] = [Vector3.ZERO]
			var build := func(origin: Vector3, fwd: Vector3) -> StaticBody3D:
				var body := _obstacle_body()
				# Guardrail: 0.25 m thick, 1.0 m tall, 150 m long, crossing the car's path 25 m
				# ahead at `angle`, running off to the right.
				wall_dir[0] = fwd.rotated(Vector3.UP, -deg_to_rad(angle))
				var a := origin + fwd * 25.0
				var centre := a + wall_dir[0] * 65.0
				_add_box(body, Vector3(0.25, 1.0, 150.0),
						Transform3D(Basis.looking_at(wall_dir[0], Vector3.UP), centre + Vector3.UP * 0.5))
				return body
			var head_err := [0.0, 0.0]
			var sampler := func(t: float) -> void:
				if t >= 1.0 and head_err[1] == 0.0:
					head_err[1] = 1.0
					head_err[0] = rad_to_deg(_flat_fwd().angle_to(wall_dir[0]))
			var log := await _crash_run(kmh, build, 1.5, sampler)
			var loss := 100.0 * (1.0 - log.v_min / maxf(log.v0, 0.1))
			var r: Array = WALL_LOSS[angle]
			var spins := 1 if log.max_slip > 75.0 else 0
			var he: float = head_err[0]
			var ok: bool = loss >= float(r[0]) and loss <= float(r[1]) and log.yaw_max < 90.0 and he < 10.0 \
					and log.air < 0.05 and spins == 0
			_record("wall %d° at %.0f km/h" % [angle, kmh],
					"loss %.0f %%, yaw %.0f°/s, head %.0f° @1s, air %.2f s, spins %d" % [loss, log.yaw_max, he, log.air, spins],
					"loss %.0f-%.0f %%, yaw < 90°/s, head < 10°, air < 0.05 s, 0 spins" % [r[0], r[1]], ok)


## Quarter-overlap hit on a thin pole (or a tree trunk) at 80 km/h.
func test_pole(radius: float, label: String) -> void:
	var build := func(origin: Vector3, fwd: Vector3) -> StaticBody3D:
		var body := _obstacle_body()
		var right := fwd.cross(Vector3.UP)
		# A quarter of the car's width (1.74 m) overlaps the pole, on the right.
		_add_cylinder(body, radius, 6.0, origin + fwd * 25.0 + right * (0.87 - 0.435 + radius))
		return body
	var log := await _crash_run(80.0, build, 3.0)
	var ok := log.turned < 90.0 and log.air < 0.2 and log.min_up > 0.5
	_record("%s hit 80 km/h (quarter overlap)" % label,
			"rotation %.0f°, yaw %.0f°/s, air %.2f s, %.0f km/h after" % [log.turned, log.yaw_max, log.air, car.speed_kmh],
			"rotation < 90°, air < 0.2 s, upright", ok)


## A 0.4 m rock in the car's path at 70 km/h.
func test_rock() -> void:
	var build := func(origin: Vector3, fwd: Vector3) -> StaticBody3D:
		var body := _obstacle_body()
		_add_cylinder(body, 0.5, 0.4, origin + fwd * 25.0)
		return body
	var log := await _crash_run(70.0, build, 3.0)
	var ok := log.air < 0.3 and log.min_up > 0.5
	_record("0.4 m rock at 70 km/h", "air %.2f s, min up %.2f, rotation %.0f°, %.0f km/h after" % [log.air, log.min_up, log.turned, car.speed_kmh],
			"air < 0.3 s, no roll-over", ok)


## 90° right-hander (road radius 20 m, 8 m wide) taken too fast at 100 km/h with a guardrail on
## the outside: full lock and throttle held from the turn-in point. The car should scrape round
## and leave along the exit road.
func test_hairpin_wall() -> void:
	var lane := await _kb_run_up("plaza_tarmac", 100.0, 0.3)
	var origin := car.global_position * Vector3(1, 0, 1)
	var fwd := _flat_fwd()
	var right := fwd.cross(Vector3.UP)
	var turn_in := origin + fwd * 30.0
	var centre := turn_in + right * 20.0
	var body := _obstacle_body()
	var r_out := 24.0
	# Outside rail: 40 m straight before the corner, the 90° arc, 60 m along the exit.
	_add_box(body, Vector3(0.25, 1.0, 40.0), Transform3D(Basis.looking_at(fwd, Vector3.UP), turn_in - right * 4.0 - fwd * 20.0 + Vector3.UP * 0.5))
	var seg := 5.0
	var a := 0.0
	while a < 90.0:
		var mid := deg_to_rad(a + seg * 0.5)
		var radial := (-right).rotated(Vector3.UP, -mid)
		var tangent := radial.cross(Vector3.UP) * -1.0
		var p := centre + radial * r_out
		_add_box(body, Vector3(0.25, 1.0, 2.0 * r_out * tan(deg_to_rad(seg * 0.5)) + 0.15),
				Transform3D(Basis.looking_at(tangent, Vector3.UP), p + Vector3.UP * 0.5))
		a += seg
	var exit_dir := right
	var exit_start := centre + fwd * r_out
	_add_box(body, Vector3(0.25, 1.0, 60.0), Transform3D(Basis.looking_at(exit_dir, Vector3.UP), exit_start + exit_dir * 30.0 + Vector3.UP * 0.5))
	var t := 0.0
	while t < 6.0 and (car.global_position - origin).dot(fwd) < 30.0:
		_kb_lane(lane)
		_kb_hold_speed(100.0)
		await _tick()
		t += DT
	var contact_at := -1.0
	var exit_at := -1.0
	var log := CrashLog.new()
	var h0 := _heading()
	t = 0.0
	while t < 8.0:
		keys.steer_key(1)
		keys.pedals(true, false)
		await _tick()
		t += DT
		if contact_at < 0.0 and _touching(body):
			contact_at = t
			log.v0 = car.linear_velocity.length()
		if contact_at >= 0.0:
			log.sample(car, t - contact_at, DT, h0, _heading())
			var v := car.linear_velocity * Vector3(1, 0, 1)
			if _flat_fwd().angle_to(exit_dir) < deg_to_rad(15.0) and v.length() > 5.0 and v.normalized().dot(exit_dir) > 0.9:
				exit_at = t - contact_at
				break
	keys.steer_key(0)
	keys.pedals(false, false)
	var exit_kmh := car.speed_kmh
	_clear_obstacles()
	var spins := 1 if log.max_slip > 75.0 else 0
	var ok := contact_at >= 0.0 and exit_at >= 0.0 and exit_at <= 2.0 and spins == 0 and log.air < 0.05
	_record("hairpin with outside rail, 100 km/h",
			("contact %s, out along the road %.2f s later at %.0f km/h, yaw %.0f°/s, spins %d" % [
				"yes" if contact_at >= 0.0 else "no", exit_at, exit_kmh, log.yaw_max, spins]),
			"exit <= 2.0 s after contact, 0 spins", ok)


# ---------------------------------------------------------------- chassis

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
		# Throttle to 85 km/h up to the kicker, then off; lane taps throughout.
		if car.global_position.z > 294.0:
			_kb_hold_speed(85.0)
		else:
			keys.pedals(false, false)
		_kb_lane(lane)
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
	_kb_end()
	var xf := Transform3D(Basis(Vector3.BACK, PI), Vector3(-300.0, 2.0, 60.0))
	car.reset_to(xf)
	_kb_begin()
	var t := 0.0
	var reset_at := -1.0
	var was_upside := false
	while t < 6.0:
		keys.pedals(true, false)
		await _tick()
		t += DT
		var up_y := car.global_transform.basis.y.y
		if up_y < 0.0:
			was_upside = true
		if was_upside and up_y > 0.95 and reset_at < 0.0:
			reset_at = t
	_record("auto-reset when upside down", "%.2f s" % reset_at, "2.5-3.5 s, upright", reset_at > 2.4 and reset_at < 3.5)
	# Manual reset near the loop snaps onto the racing line.
	_kb_end()
	car.reset_to(Transform3D(Basis(Vector3.UP, 1.0), Vector3(12.0, 0.5, 20.0)))
	await _ticks(10)
	car.reset_to_track()
	await _ticks(60)
	var loop: Path3D = ground.get("loop_path")
	var closest := loop.curve.get_closest_point(car.global_position)
	var off := Vector2(car.global_position.x - closest.x, car.global_position.z - closest.z).length()
	_record("reset_car onto track line", "%.2f m from line" % off, "< 1 m", off < 1.0)


## The analog autopilot (menu flyover, demo, finish cruise) on the proving-ground loop.
func test_autopilot() -> void:
	_kb_end()
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
	car.remove_child(ap)
	ap.free()
	_controls(0.0, 0.0, 0.0)
	await _tick()


## Mixed abuse through the keyboard path: keyboard-bot laps of the loop, jumps, wall hits, the
## bumpy lane and the banked turn.
func test_soak(seconds: float) -> void:
	nan_detected = false
	max_speed_seen = 0.0
	max_spin_seen = 0.0
	var t := 0.0
	var phase := 0
	impacts.clear()
	landings.clear()
	while t < seconds:
		match phase % 4:
			0:
				_kb_end()
				var bot: Autopilot = KeyboardBot.new()
				bot.path = ground.get("loop_path")
				car.add_child(bot)
				car.reset_to(ground.spawn("loop_start"))
				for i in int(60.0 / DT):
					await _tick()
				car.remove_child(bot)
				bot.free()
				_kb_end()
				t += 60.0
			1:
				await _place("jump", 0.1)
				for i in int(12.0 / DT):
					_kb_hold_speed(95.0)
					_kb_lane(-250.0)
					await _tick()
				t += 12.0
			2:
				await _place("wall", 0.1)
				for i in int(9.0 / DT):
					keys.pedals(true, false)
					keys.steer_towards(0.15 * sin(i * DT * 2.0), car.player_input.steer, DT)
					await _tick()
				t += 9.0
			3:
				await _place("bumps", 0.1)
				for i in int(10.0 / DT):
					keys.pedals(true, false)
					_kb_lane(-530.0)
					await _tick()
				await _place("banked", 0.1)
				for i in int(12.0 / DT):
					_kb_hold_speed(75.0)
					keys.steer_towards(0.0 if i < 300 else -0.35, car.player_input.steer, DT)
					await _tick()
				t += 22.0
		phase += 1
	_kb_end()
	var hard_hits := 0
	for s in impacts:
		if s > 0.5:
			hard_hits += 1
	_record("soak %.0f s (loop, jumps, wall, bumps, banking)" % t,
			"NaN=%s vmax=%.0f m/s wmax=%.1f rad/s" % [nan_detected, max_speed_seen, max_spin_seen],
			"no NaN, v<70, w<15", not nan_detected and max_speed_seen < 70.0 and max_spin_seen < 15.0)
	_record("soak events", "%d impacts (%d hard), %d landings" % [impacts.size(), hard_hits, landings.size()], "signals fire", impacts.size() > 0 and landings.size() > 0)


# ---------------------------------------------------------------- real maps

## Timed standing-start laps of a real map: the analog autopilot (reference) and the keyboard
## bot (the "can a keyboard player drive it" proxy) for each car.
func test_map(map_id: String, cars: Array[String]) -> void:
	var map: MapWorld = await MapLapRunner.build_map(self, map_id)
	var runner := MapLapRunner.new()
	for id in cars:
		await _spawn_car(id)
		var ref: Dictionary = await runner.lap(self, map, car, false)
		reference_laps["%s/%s" % [map_id, id]] = ref["time"]
		_record("%s analog lap" % map_id, "%.2f s, %d resets, %d hard, off %.1f s" % [ref["time"], ref["resets"], ref["hard_impacts"], ref["off_road_s"]],
				"clean", ref["finished"] and ref["resets"] == 0 and ref["hard_impacts"] == 0)
		var kb: Dictionary = await runner.lap(self, map, car, true)
		var ratio: float = kb["time"] / maxf(ref["time"], 1e-3)
		_record("%s keyboard-bot lap" % map_id,
				"%.2f s (x%.3f), %d resets, %d hard, slip %.0f°" % [kb["time"], ratio, kb["resets"], kb["hard_impacts"], kb["max_slip_deg"]],
				"clean, slip < 25°, <= x1.12",
				kb["finished"] and kb["resets"] == 0 and kb["hard_impacts"] == 0 and kb["max_slip_deg"] < 25.0 and ratio <= 1.12)
		await _drop_car()
	car_id = ""
	map.queue_free()
	await physics_frame


func _print_report() -> void:
	var passed := 0
	print("")
	print("| Test | Result | Target | |")
	print("|---|---|---|---|")
	for r in results:
		if r["ok"]:
			passed += 1
		print("| %s | %s | %s | %s |" % [r["name"], r["value"], r["target"], "PASS" if r["ok"] else "FAIL"])
	if not reference_laps.is_empty():
		print("")
		print("Medals from the analog reference laps (gold / silver / bronze = %.2f / %.2f / %.2f x):" % MEDAL_FACTORS)
		for key: String in reference_laps:
			var lt: float = reference_laps[key]
			print("  %s: %.2f s -> %.1f / %.1f / %.1f" % [key, lt, lt * MEDAL_FACTORS[0], lt * MEDAL_FACTORS[1], lt * MEDAL_FACTORS[2]])
	print("")
	print("RESULT %d/%d passed" % [passed, results.size()])
