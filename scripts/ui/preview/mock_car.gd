extends Node
## Stand-in for the real car in the UI preview: exposes the read-only part of the car runtime
## API (docs/CONTRACTS.md) that the HUD reads, driven by a tiny drivetrain model. Uses the
## throttle / brake actions when pressed, otherwise an autopilot that accelerates through the
## gears and lifts for "corners" so rpm, gears and speed all move believably.

signal gear_changed(new_gear: int, old_gear: int)

const RATIOS := [3.4, 2.3, 1.7, 1.32, 1.05, 0.86]
const FINAL := 3.9
const WHEEL_R := 0.33
const SHIFT_TIME := 0.18

var rpm := 900.0
var idle_rpm := 900.0
var max_rpm := 7800.0
var throttle := 0.0
var brake := 0.0
var handbrake := 0.0
var steer := 0.0
var gear := 1
var is_shifting := false
var boost := 0.0
var speed_kmh := 0.0
var airborne_time := 0.0
var top_speed_kmh := 0.0
var autopilot := true
var running := false ## false = parked at idle (intro / countdown)

var _shift_t := 0.0
var _time := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func reset() -> void:
	rpm = idle_rpm
	gear = 1
	speed_kmh = 0.0
	top_speed_kmh = 0.0
	is_shifting = false
	_shift_t = 0.0
	_time = 0.0


func _wheel_rpm(g: int, kmh: float) -> float:
	var wheel_rps := kmh / 3.6 / (TAU * WHEEL_R)
	return wheel_rps * 60.0 * RATIOS[g - 1] * FINAL


func _process(delta: float) -> void:
	_time += delta
	var manual := Input.is_action_pressed("throttle") or Input.is_action_pressed("brake")
	if manual or not autopilot:
		throttle = Input.get_action_strength("throttle")
		brake = Input.get_action_strength("brake")
	else:
		# Straights with a lift + brake every ~6 s, one longer "hairpin" every ~17 s.
		var phase := fmod(_time, 6.2)
		throttle = 0.0 if phase > 4.9 else 1.0
		brake = 0.7 if phase > 5.1 and phase < 5.7 else 0.0
		if fmod(_time, 17.0) > 15.0:
			throttle = 0.25
			brake = 0.35
	if not running:
		# Parked: blip the throttle during the countdown for a little life.
		throttle = 0.35 if fmod(_time, 1.3) < 0.25 else 0.0
		brake = 0.0
		speed_kmh = 0.0
		var target_idle := idle_rpm + throttle * 3800.0
		rpm = lerpf(rpm, target_idle, 1.0 - exp(-(9.0 if throttle > 0.0 else 3.0) * delta))
		return

	var ratio: float = RATIOS[gear - 1]
	var drive := throttle * 26.0 * ratio / RATIOS[0] * (0.0 if is_shifting else 1.0)
	if rpm >= max_rpm - 50.0:
		drive = 0.0
	var drag := 0.00055 * speed_kmh * speed_kmh + 1.2
	speed_kmh = maxf(0.0, speed_kmh + (drive * 3.6 - drag - brake * 60.0) * delta)
	top_speed_kmh = maxf(top_speed_kmh, speed_kmh)

	if is_shifting:
		_shift_t -= delta
		if _shift_t <= 0.0:
			is_shifting = false
	var target_rpm := maxf(idle_rpm, _wheel_rpm(gear, speed_kmh))
	rpm = lerpf(rpm, minf(target_rpm, max_rpm), 1.0 - exp(-14.0 * delta))
	if not is_shifting:
		if rpm > max_rpm - 450.0 and gear < RATIOS.size() and throttle > 0.5:
			_shift(gear + 1)
		elif gear > 1 and _wheel_rpm(gear - 1, speed_kmh) < max_rpm - 1600.0 and rpm < 3200.0:
			_shift(gear - 1)


func _shift(g: int) -> void:
	var old := gear
	gear = g
	is_shifting = true
	_shift_t = SHIFT_TIME
	gear_changed.emit(g, old)
