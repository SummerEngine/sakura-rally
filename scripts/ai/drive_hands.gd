class_name DriveHands
extends RefCounted
## How the neural driver works the controls, identical in training and in the game. It picks one
## option per group every decision (DrivePolicy):
##   steer  STEER_LEVELS (a steering-wheel position, left negative)
##   pedal  0 brake, 1 neither, 2 throttle
##   hand   0 off, 1 handbrake
## and apply() moves the car's inputs towards that choice every physics tick like a gamepad
## player: the wheel follows with STEER_TIME smoothing, pedals ramp in at PEDAL_RATE and snap off.

const STEER_LEVELS: Array[float] = [-1.0, -0.5, -0.2, 0.0, 0.2, 0.5, 1.0]
const ACTION_DIMS: Array[int] = [7, 3, 2]
## Physics ticks (120 Hz) per decision: 10 decisions a second, as Gran Turismo Sophy.
const DECISION_TICKS := 12
## Same feel as CarInput's stick smoothing and pedal ramp.
const STEER_TIME := 0.045
const PEDAL_RATE := 9.0

var steer_target: float = 0.0
var throttle_target: float = 0.0
var brake_target: float = 0.0
var handbrake: bool = false


func set_action(steer: int, pedal: int, hand: int) -> void:
	steer_target = STEER_LEVELS[clampi(steer, 0, STEER_LEVELS.size() - 1)]
	throttle_target = 1.0 if pedal == 2 else 0.0
	brake_target = 1.0 if pedal == 0 else 0.0
	handbrake = hand == 1


func apply(car: Car, dt: float) -> void:
	car.input_steer += (steer_target - car.input_steer) * (1.0 - exp(-dt / STEER_TIME))
	car.input_throttle = move_toward(car.input_throttle, throttle_target, PEDAL_RATE * dt) \
			if throttle_target > car.input_throttle else throttle_target
	car.input_brake = move_toward(car.input_brake, brake_target, PEDAL_RATE * dt) \
			if brake_target > car.input_brake else brake_target
	car.input_handbrake = handbrake


## Hands off: everything released, the car's inputs too.
func release(car: Car) -> void:
	set_action(3, 1, 0)
	car.input_steer = 0.0
	car.input_throttle = 0.0
	car.input_brake = 0.0
	car.input_handbrake = false
