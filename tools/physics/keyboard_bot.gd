extends Autopilot
## Keyboard proxy driver: the Autopilot's line, speed profile and steering target, played on
## digital keys through the real input path (InputMap actions -> CarInput shaping -> Car), the
## way a keyboard player drives: steering taps (bang-bang with hysteresis, see KeyTaps), on/off
## throttle and brake, no key faster than a quick human tap. The car is switched to
## `controlled_by_player`.
##
## Used by tools/physics/run_tests.gd (keyboard-bot laps of the real maps) and
## tools/physics/map_drive.gd. Releases every key it pressed when it leaves the tree.

const KeyTaps := preload("res://tools/physics/key_taps.gd")

## Steering tap band and deadzone (KeyTaps.steer_band / steer_deadzone).
@export var steer_band: float = 0.006
@export var steer_deadzone: float = 0.04
## Throttle key on above / off below these analog throttle requests; brake likewise.
@export var throttle_on: float = 0.55
@export var throttle_off: float = 0.3
@export var brake_on: float = 0.35
@export var brake_off: float = 0.08
## Shortest time (s) between two changes of the same key.
@export var min_key_time: float = 0.05

## The analog steering the taps are aiming for this tick (for traces).
var wanted_steer: float = 0.0

var _keys := KeyTaps.new()


func _ready() -> void:
	super()
	if _car != null:
		_car.controlled_by_player = true


func _exit_tree() -> void:
	_keys.release_all()


func _apply(delta: float, steer: float, thr: float, brk: float, _speed_error: float) -> void:
	_keys.steer_band = steer_band
	_keys.steer_deadzone = steer_deadzone
	_keys.min_key_time = min_key_time
	_keys.tick(delta)
	wanted_steer = steer
	_keys.steer_towards(steer, _car.player_input.steer, delta)
	var throttle_key := _keys.is_held(&"throttle")
	if thr > throttle_on:
		throttle_key = true
	elif thr < throttle_off:
		throttle_key = false
	var brake_key := _keys.is_held(&"brake")
	if brk > brake_on:
		brake_key = true
	elif brk < brake_off:
		brake_key = false
	_keys.pedals(throttle_key, brake_key)
