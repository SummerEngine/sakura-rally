class_name CarInput
extends RefCounted
## Reads the InputMap actions for the player car and shapes them for keyboard and gamepad.
## Keyboard: steering ramps in (slower at speed); letting go returns it to centre (more gently at
## speed, so taps through a long corner average out instead of dropping to straight between
## taps); the opposite key swings it across centre fast. Pedals ramp briefly.
## Gamepad: light smoothing plus a response curve for precise small corrections.

## Keyboard steering rate towards full lock (1/s) at standstill and at high speed. The lock
## itself shrinks with speed (Car.steer_lock_at), so a quick ramp stays gentle at speed.
var key_steer_rate_low: float = 6.0
var key_steer_rate_high: float = 4.5
## Keyboard rate back to centre after letting go (1/s) at standstill and at high speed.
var key_release_rate_low: float = 9.0
var key_release_rate_high: float = 4.5
## Keyboard rate across centre while the opposite key is held (1/s).
var key_return_rate: float = 9.0
## Stick response exponent (>1 = finer control around centre).
var stick_exponent: float = 1.35
var pedal_rate: float = 9.0

var steer: float = 0.0
var throttle: float = 0.0
var brake: float = 0.0
var handbrake: bool = false
var analog_steer: bool = false


func read(dt: float, speed_kmh: float) -> void:
	var raw := Input.get_axis(&"steer_left", &"steer_right")
	var stick := 0.0
	for device in Input.get_connected_joypads():
		var v := Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
		if absf(v) > absf(stick):
			stick = v
	if absf(stick) > 0.2:
		analog_steer = true
	elif absf(raw) > 0.99 and absf(stick) < 0.05:
		analog_steer = false

	if analog_steer:
		var shaped := signf(raw) * pow(absf(raw), stick_exponent)
		steer += (shaped - steer) * (1.0 - exp(-dt / 0.045))
	else:
		var t := clampf(absf(speed_kmh) / 140.0, 0.0, 1.0)
		var rate := lerpf(key_steer_rate_low, key_steer_rate_high, t)
		if raw == 0.0:
			rate = lerpf(key_release_rate_low, key_release_rate_high, t)
		elif raw * steer < 0.0:
			rate = key_return_rate
		steer = move_toward(steer, raw, rate * dt)

	var thr_raw := Input.get_action_strength(&"throttle")
	var brk_raw := Input.get_action_strength(&"brake")
	throttle = move_toward(throttle, thr_raw, pedal_rate * dt) if thr_raw > throttle else thr_raw
	brake = move_toward(brake, brk_raw, pedal_rate * dt) if brk_raw > brake else brk_raw
	handbrake = Input.is_action_pressed(&"handbrake")


func reset() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	handbrake = false
