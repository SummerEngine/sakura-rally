class_name CarInput
extends RefCounted
## Reads the InputMap actions for the player car and shapes them for keyboard and gamepad.
## Keyboard: steering ramps in (slower at speed) and snaps back to centre faster; pedals ramp briefly.
## Gamepad: light smoothing plus a response curve for precise small corrections.

## Keyboard steering rate towards full lock (1/s) at standstill and at high speed.
var key_steer_rate_low: float = 5.0
var key_steer_rate_high: float = 2.4
## Keyboard rate back to centre / across centre (1/s).
var key_return_rate: float = 8.0
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
		var toward_centre := absf(raw) < absf(steer) or signf(raw) != signf(steer)
		var t := clampf(absf(speed_kmh) / 140.0, 0.0, 1.0)
		var rate := key_return_rate if toward_centre else lerpf(key_steer_rate_low, key_steer_rate_high, t)
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
