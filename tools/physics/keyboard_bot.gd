extends Autopilot
## Keyboard proxy driver: the Autopilot's line, speed profile and steering target, played on
## digital keys through the real input path (InputMap actions -> CarInput shaping -> Car), the
## way a keyboard player drives. Steering is bang-bang with hysteresis against the ramped
## keyboard steering value, throttle and brake are on/off, and no key changes state faster than
## a quick human tap (`min_key_time`). The car is switched to `controlled_by_player`.
##
## Used by tools/physics/run_tests.gd (keyboard-bot laps of the real maps) and
## tools/physics/map_drive.gd. Releases every key it pressed when it leaves the tree.

## Steering taps: the key on the side of the wanted steering goes down when the keyboard value
## has lagged the wanted one by `steer_band` (steer x seconds, integrated) and comes up once it
## has led it by the same amount, so the taps average out to the wanted steering. Below
## `steer_deadzone` wanted steering no key is pressed.
@export var steer_band: float = 0.006
@export var steer_deadzone: float = 0.04
## Throttle key on above / off below these analog throttle requests; brake likewise.
@export var throttle_on: float = 0.55
@export var throttle_off: float = 0.3
@export var brake_on: float = 0.35
@export var brake_off: float = 0.08
## Shortest time (s) between two changes of the same key.
@export var min_key_time: float = 0.05

const ACTIONS: Array[StringName] = [&"steer_left", &"steer_right", &"throttle", &"brake", &"handbrake"]

var _held: Dictionary = {}
var _since: Dictionary = {}
var _steer_debt: float = 0.0
var _steer_side: int = 0


func _ready() -> void:
	super()
	for a in ACTIONS:
		_held[a] = false
		_since[a] = 1.0
	if _car != null:
		_car.controlled_by_player = true


func _exit_tree() -> void:
	for a in ACTIONS:
		if _held.get(a, false):
			Input.action_release(a)
			_held[a] = false


func _apply(delta: float, steer: float, thr: float, brk: float, _speed_error: float) -> void:
	for a in ACTIONS:
		_since[a] += delta
	# Like a player tapping: only the key on the side of the wanted steering is used, and it is
	# held while the keyboard value owes steering to the wanted one (bang-bang on the integrated
	# error, with hysteresis). Releasing lets the return-to-centre bring the value back.
	var current := _car.player_input.steer
	var side := 0 if absf(steer) < steer_deadzone else int(signf(steer))
	var right := false
	var left := false
	if side != _steer_side:
		_steer_side = side
		_steer_debt = 0.0
	if side != 0:
		var owed := (steer - current) * side
		_steer_debt = clampf(_steer_debt + owed * delta, -steer_band * 2.0, steer_band * 2.0)
		var held := bool(_held[&"steer_right" if side > 0 else &"steer_left"])
		var press := _steer_debt > -steer_band if held else _steer_debt > steer_band
		right = press and side > 0
		left = press and side < 0
	_pair(&"steer_right", right, &"steer_left", left)
	var throttle_key := bool(_held[&"throttle"])
	if thr > throttle_on:
		throttle_key = true
	elif thr < throttle_off:
		throttle_key = false
	var brake_key := bool(_held[&"brake"])
	if brk > brake_on:
		brake_key = true
	elif brk < brake_off:
		brake_key = false
	_pair(&"brake", brake_key, &"throttle", throttle_key and not brake_key)


## Two keys a player does not hold together: releases go first, and a key is only pressed
## once the other one is up.
func _pair(a: StringName, a_on: bool, b: StringName, b_on: bool) -> void:
	if not a_on:
		_press(a, false)
	if not b_on:
		_press(b, false)
	if a_on and not bool(_held[b]):
		_press(a, true)
	if b_on and not bool(_held[a]):
		_press(b, true)


func _press(action: StringName, on: bool) -> void:
	if on == bool(_held[action]) or _since[action] < min_key_time:
		return
	_held[action] = on
	_since[action] = 0.0
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)
