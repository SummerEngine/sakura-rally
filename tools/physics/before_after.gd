extends SceneTree
## Before/after keyboard scenario for docs/PHYSICS.md. Self-contained (its own flat gravel field,
## plain Input.action_press on the InputMap actions, only Car API that ep1 already had), so the
## same file runs on the ep1 tag and on this branch:
##
##   timeout 300 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/physics/before_after.gd
##
## 1. Hairpin: accelerate to 130 km/h, brake hard at that marker down to 50 km/h (stopping
##    distance), then full lock left on throttle until the car has turned 180 deg (time through,
##    max body slip, outcome).
## 2. Panic steer at 140 km/h: full lock left for 1.5 s with the throttle held, lifted, or the
##    brake pressed, then centre on throttle (max body slip, heading reversal, slip 1 s after
##    centring).

const DT := 1.0 / 120.0
const ACTIONS: Array[StringName] = [&"steer_left", &"steer_right", &"throttle", &"brake", &"handbrake"]

var car: Car


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var field := StaticBody3D.new()
	field.set_meta(&"surface", &"gravel")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 2.0, 4000.0)
	shape.shape = box
	shape.position = Vector3(0.0, -1.0, 0.0)
	field.add_child(shape)
	root.add_child(field)
	car = (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	root.add_child(car)
	await _hairpin()
	for pedal: Array in [[&"throttle"], [], [&"brake"]]:
		await _panic(pedal)
	_keys([])
	root.get_node("Game").request_quit(0)


func _hairpin() -> void:
	await _run_up(130.0)
	var marker := car.global_position
	var t := 0.0
	var stop_dist := -1.0
	while car.speed_kmh > 50.0 and t < 10.0:
		_keys([&"brake"])
		await _tick()
		t += DT
	stop_dist = _flat(car.global_position - marker)
	var h0 := _heading()
	var turned := 0.0
	var prev := h0
	var max_slip := 0.0
	var through := -1.0
	var outcome := "turned 180 deg"
	while t < 20.0:
		_keys([&"steer_left", &"throttle"])
		await _tick()
		t += DT
		var h := _heading()
		turned += angle_difference(prev, h)
		prev = h
		max_slip = maxf(max_slip, absf(_slip_deg()))
		if absf(turned) >= PI:
			through = t
			break
	if through < 0.0:
		outcome = "did not complete the turn"
	if max_slip > 90.0:
		outcome += ", spun (slip > 90 deg)"
	print("RESULT hairpin: 130-50 braking %.1f m, time through (marker to 180 deg) %s, max body slip %.0f deg, %s" % [
			stop_dist, ("%.2f s" % through) if through > 0.0 else "-", max_slip, outcome])


func _panic(pedal: Array) -> void:
	await _run_up(140.0)
	var h0 := _heading()
	var max_slip := 0.0
	var reversed := false
	var t := 0.0
	while t < 1.5:
		_keys([&"steer_left"] + pedal)
		await _tick()
		t += DT
		max_slip = maxf(max_slip, absf(_slip_deg()))
		reversed = reversed or car.linear_velocity.dot(-car.global_transform.basis.z) < 0.0
	var turned := rad_to_deg(absf(angle_difference(h0, _heading())))
	t = 0.0
	while t < 1.0:
		_keys([&"throttle"])
		await _tick()
		t += DT
		max_slip = maxf(max_slip, absf(_slip_deg()))
		reversed = reversed or car.linear_velocity.dot(-car.global_transform.basis.z) < 0.0
	print("RESULT panic 140 (%s): max body slip %.0f deg, heading %.0f deg after 1.5 s, slip 1 s after centring %.1f deg, %s, %.0f km/h" % [
			"throttle" if pedal.has(&"throttle") else ("brake" if pedal.has(&"brake") else "lift"),
			max_slip, turned, absf(_slip_deg()), "SPUN (travelling backwards)" if reversed else "no spin", car.speed_kmh])


## Straight run-up on throttle from a standstill to the given speed (no steering needed on the
## open field).
func _run_up(kmh: float) -> void:
	_keys([])
	car.controlled_by_player = false
	car.reset_to(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.05, 1500.0)))
	for i in 120:
		await _tick()
	car.controlled_by_player = true
	var t := 0.0
	while car.speed_kmh < kmh and t < 40.0:
		_keys([&"throttle"])
		await _tick()
		t += DT


func _keys(down: Array) -> void:
	for a in ACTIONS:
		if a in down:
			if not Input.is_action_pressed(a):
				Input.action_press(a)
		elif Input.is_action_pressed(a):
			Input.action_release(a)


func _tick() -> void:
	await physics_frame


func _heading() -> float:
	var f := -car.global_transform.basis.z
	return atan2(-f.x, -f.z)


func _slip_deg() -> float:
	var v := car.linear_velocity
	var fwd := -car.global_transform.basis.z
	if Vector2(v.x, v.z).length() < 3.0:
		return 0.0
	return rad_to_deg(angle_difference(atan2(-fwd.x, -fwd.z), atan2(-v.x, -v.z)))


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()
