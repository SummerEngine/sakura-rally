extends RefCounted
## Digital keys for the player car, pressed through the InputMap actions the way a keyboard player
## does (Input.action_press / action_release), so CarInput's keyboard shaping sits between the
## script and the car. Shared by the keyboard bot and the telemetry suite.
##
## Rules a player's hands follow: no key changes state faster than a quick tap (`min_key_time`),
## left/right and throttle/brake are never held together (a key only goes down once its partner is
## up), and every held key is released by `release_all()`.

const ACTIONS: Array[StringName] = [&"steer_left", &"steer_right", &"throttle", &"brake", &"handbrake"]

## Shortest time (s) between two changes of the same key.
var min_key_time: float = 0.05
## Steering taps: the key on the side of the wanted steering goes down when the keyboard value
## has lagged the wanted one by `steer_band` (steer x seconds, integrated) and comes up once it has
## led it by the same amount, so the taps average out to the wanted steering (bang-bang with
## hysteresis on the integrated error). Below `steer_deadzone` wanted steering no key is pressed.
var steer_band: float = 0.006
var steer_deadzone: float = 0.04

var _held: Dictionary = {}
var _since: Dictionary = {}
var _steer_debt: float = 0.0
var _steer_side: int = 0


func _init() -> void:
	for a in ACTIONS:
		_held[a] = false
		_since[a] = 1.0


## Call once per physics tick before setting keys.
func tick(dt: float) -> void:
	for a in ACTIONS:
		_since[a] += dt


func is_held(action: StringName) -> bool:
	return bool(_held[action])


## Taps the steering keys so the keyboard steering value (`current`, CarInput.steer) averages out
## to `wanted` (-1..1). Only the key on the wanted side is used; letting go returns to centre.
func steer_towards(wanted: float, current: float, dt: float) -> void:
	var side := 0 if absf(wanted) < steer_deadzone else int(signf(wanted))
	if side != _steer_side:
		_steer_side = side
		_steer_debt = 0.0
	var press := false
	if side != 0:
		_steer_debt = clampf(_steer_debt + (wanted - current) * side * dt, -steer_band * 2.0, steer_band * 2.0)
		var held := is_held(&"steer_right" if side > 0 else &"steer_left")
		press = _steer_debt > -steer_band if held else _steer_debt > steer_band
	steer_key(side if press else 0)


## Holds one steering key: -1 left, +1 right, 0 none.
func steer_key(dir: int) -> void:
	_pair(&"steer_right", dir > 0, &"steer_left", dir < 0)


## Throttle and brake keys (brake wins if both are asked for).
func pedals(throttle: bool, brake: bool) -> void:
	_pair(&"brake", brake, &"throttle", throttle and not brake)


func handbrake(on: bool) -> void:
	_press(&"handbrake", on)


func release_all() -> void:
	for a in ACTIONS:
		if is_held(a):
			Input.action_release(a)
			_held[a] = false
			_since[a] = 1.0
	_steer_debt = 0.0
	_steer_side = 0


func _pair(a: StringName, a_on: bool, b: StringName, b_on: bool) -> void:
	if not a_on:
		_press(a, false)
	if not b_on:
		_press(b, false)
	if a_on and not is_held(b):
		_press(a, true)
	if b_on and not is_held(a):
		_press(b, true)


func _press(action: StringName, on: bool) -> void:
	if on == is_held(action) or _since[action] < min_key_time:
		return
	_held[action] = on
	_since[action] = 0.0
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)
